//! A handle for one secret. Cheap: a client pointer and an id. Creating one
//! sends nothing, and the handle borrows both, so it must outlive neither.

const Secret = @This();

const std = @import("std");

const Client = @import("Client.zig");
const SecretValue = @import("SecretValue.zig");
const Version = @import("Version.zig");
const errors = @import("errors.zig");
const types = @import("types.zig");
const Error = errors.Error;

client: *Client,
/// The secret's id, such as `db-password`. The library builds the full
/// resource name, with or without the client's location.
id: []const u8,

/// A handle for one of this secret's versions. Sends nothing.
pub fn version(self: Secret, ref: types.VersionRef) Version {
    return .{ .client = self.client, .secret_id = self.id, .ref = ref };
}

/// Fetches the bytes of one version. Shorthand for
/// `self.version(ref).access()`; the caller owns the result and must
/// `deinit` it, which wipes the bytes.
pub fn access(self: Secret, ref: types.VersionRef) Error!SecretValue {
    return self.version(ref).access();
}
