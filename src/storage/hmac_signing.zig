//! Signing with an HMAC key: `GOOG4-HMAC-SHA256`. A signed URL or POST
//! policy signed this way differs from an RSA one in three places only, as
//! Google documents and production confirmed on 2026-10-05: the algorithm
//! named, the credential's authorizer (the key's access ID, not an
//! email), and the signature, the lowercase hex of an HMAC-SHA256 under a
//! key derived from the secret:
//!
//!     k_date    = HMAC("GOOG4" + secret, YYYYMMDD)
//!     k_region  = HMAC(k_date, "auto")
//!     k_service = HMAC(k_region, "storage")
//!     k_signing = HMAC(k_service, "goog4_request")
//!     signature = HMAC(k_signing, string to sign)
//!
//! The secret is used as its text, never base64-decoded: decoded, the
//! signature fails. The date is the one already written into the scope,
//! never a second reading of the clock, which around midnight could
//! disagree with it. Any location word works; `auto` is what every Google
//! library uses.

const std = @import("std");
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

const types = @import("types.zig");

pub const algorithm = "GOOG4-HMAC-SHA256";

pub const digest_length = HmacSha256.mac_length;

/// The signing key for one day's scope, AWS's derivation chain with
/// Google's names: `prefix` is `GOOG4`, `region` `auto`, `service`
/// `storage`, `request` `goog4_request`. `arena` holds the prefixed
/// secret, so it should wipe what it frees.
pub fn signingKey(
    arena: Allocator,
    prefix: []const u8,
    secret: []const u8,
    date: []const u8,
    region: []const u8,
    service: []const u8,
    request: []const u8,
) Allocator.Error![digest_length]u8 {
    const first = try std.mem.concat(arena, u8, &.{ prefix, secret });
    defer std.crypto.secureZero(u8, first);
    var key: [digest_length]u8 = undefined;
    HmacSha256.create(&key, date, first);
    for ([_][]const u8{ region, service, request }) |part| {
        var next: [digest_length]u8 = undefined;
        HmacSha256.create(&next, part, &key);
        key = next;
        std.crypto.secureZero(u8, &next);
    }
    return key;
}

/// The signature over `message` for a scope dated `date` (`YYYYMMDD`), in
/// `arena`: 32 bytes, which the URL or policy carries as lowercase hex.
pub fn sign(arena: Allocator, signer: types.HmacSigner, date: []const u8, message: []const u8) Allocator.Error![]const u8 {
    var key = try signingKey(arena, "GOOG4", signer.secret, date, "auto", "storage", "goog4_request");
    defer std.crypto.secureZero(u8, &key);
    const out = try arena.alloc(u8, digest_length);
    HmacSha256.create(out[0..digest_length], message, &key);
    return out;
}

/// Why `signer` cannot sign, or null when it can: both halves are there,
/// and the access ID can be named in a URL's credential.
pub fn problem(signer: types.HmacSigner) ?[]const u8 {
    if (signer.access_id.len == 0) return "the HMAC signer's access ID is empty";
    if (signer.secret.len == 0) return "the HMAC signer's secret is empty";
    for (signer.access_id) |c| if (c < 0x21 or c > 0x7e or c == '/') {
        return "the HMAC signer's access ID holds a space, a slash or a byte beyond printable ASCII, which a credential cannot carry";
    };
    return null;
}

const testing = std.testing;

test "the derivation chain matches AWS's published SigV4 example" {
    // docs.aws.amazon.com, "Examples of how to derive a signing key for
    // Signature Version 4": the same chain, under AWS's names.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const key = try signingKey(arena.allocator(), "AWS4", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20120215", "us-east-1", "iam", "aws4_request");
    try testing.expectEqualStrings("f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d", &std.fmt.bytesToHex(key, .lower));
}

test "sign: the date and the secret's text both change the signature" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const signer: types.HmacSigner = .{ .access_id = "GOOG1E-TEST", .secret = "TEST_ONLY_not_a_real_secret_000000000000" };
    const one = try sign(a, signer, "20261005", "string to sign");
    try testing.expectEqual(32, one.len);
    try testing.expectEqualSlices(u8, one, try sign(a, signer, "20261005", "string to sign"));
    try testing.expect(!std.mem.eql(u8, one, try sign(a, signer, "20261006", "string to sign")));
    try testing.expect(!std.mem.eql(u8, one, try sign(a, .{ .access_id = signer.access_id, .secret = "TEST_ONLY_not_a_real_secret_000000000001" }, "20261005", "string to sign")));
}

test "problem: what cannot sign" {
    try testing.expectEqual(null, problem(.{ .access_id = "GOOG1E-TEST", .secret = "s" }));
    try testing.expect(problem(.{ .access_id = "", .secret = "s" }) != null);
    try testing.expect(problem(.{ .access_id = "a", .secret = "" }) != null);
    try testing.expect(problem(.{ .access_id = "a b", .secret = "s" }) != null);
    try testing.expect(problem(.{ .access_id = "a/b", .secret = "s" }) != null);
    try testing.expect(problem(.{ .access_id = "\xc3\xa9", .secret = "s" }) != null);
}
