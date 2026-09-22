//! Signs bytes as a service account, in the `std.mem.Allocator` interface
//! shape: a pointer plus a table of functions. A signed URL is built on
//! it: the URL names the account and carries the account's signature over
//! the request it allows. Whether the private key sits in a file on this
//! machine or stays with Google is the signer's business.

const Signer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const TokenProvider = @import("TokenProvider.zig");
const test_util = @import("testing.zig");

ptr: *anyopaque,
vtable: *const VTable,

/// Every way signing can fail. Closed, like `TokenProvider.Error`, whose
/// cases it includes: a signer that signs through IAM needs a token first,
/// and one on Google Cloud asks the metadata server who it is.
pub const Error = error{
    /// IAM Credentials refused to sign: the caller lacks
    /// `iam.serviceAccounts.signBlob` on the account (the Service Account
    /// Token Creator role grants it), the account does not exist or is
    /// disabled, or the API is not enabled. `Diagnostics` says which.
    SigningRejected,
    /// No usable signature: a key that fails its own check, or an answer
    /// from IAM without a signature of the right size.
    SigningFailed,
} || TokenProvider.Error;

pub const VTable = struct {
    /// The account's email, which a signed URL names as its signer. Copied
    /// into `arena`.
    email: *const fn (ptr: *anyopaque, io: std.Io, arena: Allocator) Error![]const u8,
    /// RSASSA-PKCS1-v1_5 with SHA-256 over `message`, as that account: the
    /// scheme Cloud Storage calls `GOOG4-RSA-SHA256`. Copied into `arena`.
    sign: *const fn (ptr: *anyopaque, io: std.Io, arena: Allocator, message: []const u8) Error![]const u8,
    /// How long, in seconds, a signature made now is sure to stay
    /// verifiable: 12 hours through IAM, whose Google-managed keys rotate;
    /// null for a key file, whose key lasts until its owner deletes it.
    lifetime_s: *const fn (ptr: *anyopaque) ?u32,
};

pub fn email(self: Signer, io: std.Io, arena: Allocator) Error![]const u8 {
    return self.vtable.email(self.ptr, io, arena);
}

pub fn sign(self: Signer, io: std.Io, arena: Allocator, message: []const u8) Error![]const u8 {
    return self.vtable.sign(self.ptr, io, arena, message);
}

/// Seconds a signature made now is sure to stay verifiable, or null when
/// only the key's owner can end it.
pub fn lifetimeS(self: Signer) ?u32 {
    return self.vtable.lifetime_s(self.ptr);
}

test "the wrappers pass their arguments through" {
    var fake: test_util.FakeSigner = .{ .lifetime_s = 43_200 };
    const s = fake.signer();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings(fake.account, try s.email(std.testing.io, arena.allocator()));
    try std.testing.expectEqualSlices(u8, fake.signature, try s.sign(std.testing.io, arena.allocator(), "string to sign"));
    try std.testing.expectEqualStrings("string to sign", fake.lastMessage());
    try std.testing.expectEqual(1, fake.calls);
    try std.testing.expectEqual(43_200, s.lifetimeS());

    fake.fail = error.SigningRejected;
    try std.testing.expectError(error.SigningRejected, s.sign(std.testing.io, arena.allocator(), "again"));
    try std.testing.expectError(error.SigningRejected, s.email(std.testing.io, arena.allocator()));
    try std.testing.expectEqual(2, fake.calls);
}
