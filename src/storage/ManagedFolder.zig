//! A cheap handle on one managed folder: a prefix with an IAM policy of
//! its own, on any bucket with uniform bucket-level access. Making one
//! sends nothing.
//!
//! A grant on `teams/data/` applies to every object whose name begins with
//! it, additively with the bucket's policy and every enclosing managed
//! folder's: what one of them grants, no inner one can take away. A fresh
//! policy carries no bindings at all, and its etag is the policy's own: it
//! does not move with the bucket, unlike a bucket's, as measured on
//! 2026-10-02. Paths are normalized and refused as folder paths are, plus
//! the rules Cloud Storage enforces only here: 1,024 bytes, 15 levels, no
//! carriage return or line feed, and not under `.well-known/acme-challenge/`.

const ManagedFolder = @This();

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const iam = @import("iam.zig");
const managed_folders = @import("managed_folders.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;

/// Borrowed; the handle must not outlive it.
client: *Client,
/// Borrowed; the handle must not outlive it.
bucket: []const u8,
/// The managed folder's path, with or without its trailing slash.
/// Borrowed; the handle must not outlive it.
name: []const u8,
/// As `Bucket.billing_project`: the project this handle's requests bill.
billing_project: ?[]const u8 = null,

pub const DeleteOptions = struct {
    /// Delete it although objects or child managed folders sit under it,
    /// which needs `storage.managedFolders.setIamPolicy`. Off, such a
    /// delete is `error.FolderNotEmpty`.
    allow_non_empty: bool = false,
    /// Delete only while the managed folder's metageneration is this.
    if_metageneration_match: ?u64 = null,
};

/// This handle, billing `project` for every request it makes, as
/// `Bucket.withBillingProject` says.
pub fn withBillingProject(self: ManagedFolder, project: []const u8) ManagedFolder {
    var copy = self;
    copy.billing_project = project;
    return copy;
}

fn billing(self: ManagedFolder, copy: *Client) Error!ManagedFolder {
    rpc.begin(self.client);
    try rpc.checkBillingProject(self.client, self.billing_project);
    copy.* = rpc.billed(self.client, self.billing_project orelse self.client.billing_project);
    var billed_self = self;
    billed_self.client = copy;
    return billed_self;
}

/// Creates the managed folder, and returns it as kept. One that exists is
/// `error.AlreadyExists`; a bucket without uniform bucket-level access
/// refuses with `error.FailedPrecondition` in its own words, the same 412
/// a stale precondition gets. A child may be created before its parents.
/// In a hierarchical bucket the folders along the path are created too,
/// and outlive the managed folder, as measured. Safe to retry: a create
/// whose answer was lost reads the managed folder back rather than send
/// again, since the idempotency token dedupes nothing here.
pub fn create(self: ManagedFolder) Error!types.Owned(types.ManagedFolderInfo) {
    var client: Client = undefined;
    const billed = try self.billing(&client);
    rpc.begin(billed.client);
    try rpc.checkBucketName(billed.client, billed.bucket);
    return managed_folders.create(billed.client, billed.bucket, billed.name);
}

/// The managed folder's metadata.
pub fn get(self: ManagedFolder) Error!types.Owned(types.ManagedFolderInfo) {
    var client: Client = undefined;
    const billed = try self.billing(&client);
    rpc.begin(billed.client);
    try rpc.checkBucketName(billed.client, billed.bucket);
    return managed_folders.get(billed.client, billed.bucket, billed.name);
}

/// Deletes the managed folder. One with an object or a child managed
/// folder under it is `error.FolderNotEmpty`, unless
/// `DeleteOptions.allow_non_empty` bypasses that, which needs the
/// setIamPolicy permission. Safe to retry: a lost first success shows up
/// as `error.NotFound`.
pub fn delete(self: ManagedFolder, options: DeleteOptions) Error!void {
    var client: Client = undefined;
    const billed = try self.billing(&client);
    rpc.begin(billed.client);
    try rpc.checkBucketName(billed.client, billed.bucket);
    return managed_folders.delete(billed.client, billed.bucket, billed.name, options.allow_non_empty, .{
        .if_metageneration_match = options.if_metageneration_match,
    });
}

/// The managed folder's IAM policy, asked for as version 3, conditional
/// bindings included. A fresh one has no bindings at all. Needs
/// `storage.managedFolders.getIamPolicy`, and a token for
/// `Scope.full_control` or `.cloud_platform`, as bucket policies do.
pub fn iamPolicy(self: ManagedFolder) Error!types.Owned(core.iam.Policy) {
    var client: Client = undefined;
    const r = try self.iamResource(&client);
    return r.readPolicy();
}

/// Writes `policy` as the managed folder's, whole, and returns it as
/// stored, as `Bucket.setIamPolicy` writes a bucket's: a stale etag is
/// `error.Aborted`, and the etag here is the policy's own, moved only by
/// its writes. Conditional bindings are taken; a role outside Cloud
/// Storage's is refused.
pub fn setIamPolicy(self: ManagedFolder, policy: core.iam.Policy) Error!types.Owned(core.iam.Policy) {
    var client: Client = undefined;
    const r = try self.iamResource(&client);
    return iam.set(r, policy);
}

/// Grants `member` the role `role` on the managed folder, unless it holds
/// it already without a condition, the way `Bucket.addIamBinding` grants:
/// read, change, write under the read's etag, starting over on a
/// concurrent change. The grant scopes every object under the prefix.
pub fn addIamBinding(self: ManagedFolder, role: []const u8, member: []const u8) Error!types.Owned(core.iam.Policy) {
    var client: Client = undefined;
    const r = try self.iamResource(&client);
    return iam.change(r, .{ .grant = .{ .role = role, .member = member } });
}

/// Takes `member` out of the managed folder's binding of `role` without a
/// condition, unless it is not there.
pub fn removeIamBinding(self: ManagedFolder, role: []const u8, member: []const u8) Error!types.Owned(core.iam.Policy) {
    var client: Client = undefined;
    const r = try self.iamResource(&client);
    return iam.change(r, .{ .revoke = .{ .role = role, .member = member } });
}

/// The permissions the caller holds on the managed folder, of
/// `permissions`: at most 84, none twice, as buckets take them. A bucket
/// permission here is production's bare 400 "Invalid argument.".
pub fn testIamPermissions(self: ManagedFolder, permissions: []const []const u8) Error!types.Owned([]const []const u8) {
    var client: Client = undefined;
    const r = try self.iamResource(&client);
    return iam.testPermissions(r, permissions);
}

fn iamResource(self: ManagedFolder, copy: *Client) Error!iam.Resource {
    const billed = try self.billing(copy);
    rpc.begin(billed.client);
    try rpc.checkBucketName(billed.client, billed.bucket);
    var scratch: std.heap.ArenaAllocator = .init(billed.client.gpa);
    defer scratch.deinit();
    // Checked here so the IAM calls refuse what create would; the name the
    // resource keeps is the caller's, which the paths normalize again.
    _ = try managed_folders.normalizedChecked(billed.client, scratch.allocator(), billed.name);
    return .{ .client = billed.client, .bucket = billed.bucket, .managed_folder = billed.name };
}

test {
    _ = @import("managed_folders.zig");
}
