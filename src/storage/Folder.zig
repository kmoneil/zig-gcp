//! A cheap handle on one folder in a hierarchical-namespace bucket: create
//! it, read it, delete it. Making one sends nothing. Only such a bucket
//! has folders; on any other, every call is
//! `error.HierarchicalNamespaceRequired`.
//!
//! A path without its trailing slash names the same folder with it, as the
//! server itself normalizes, so `folder("a/b")` and `folder("a/b/")` are
//! one handle. Paths with empty, `.` or `..` segments are refused before
//! sending with `error.InvalidFolderName`: Cloud Storage takes `./` and
//! `../` verbatim, as measured on 2026-10-02, and nothing can address what
//! they leave behind safely.

const Folder = @This();

const std = @import("std");

const Client = @import("Client.zig");
const folders = @import("folders.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;

/// Borrowed; the handle must not outlive it.
client: *Client,
/// Borrowed; the handle must not outlive it.
bucket: []const u8,
/// The folder's path, with or without its trailing slash. Borrowed; the
/// handle must not outlive it.
name: []const u8,
/// As `Bucket.billing_project`: the project this handle's requests bill.
billing_project: ?[]const u8 = null,

pub const CreateOptions = struct {
    /// Create the missing parents along the way. Without it, a missing
    /// parent is `error.ParentFolderMissing`. Not idempotent either way: a
    /// recursive create of folders that all exist is 409, as measured.
    recursive: bool = false,
};

pub const DeleteOptions = struct {
    /// Delete only while the folder's metageneration is this, as
    /// `FolderInfo.metageneration` read it. A folder changed since is
    /// `error.FailedPrecondition`.
    if_metageneration_match: ?u64 = null,
};

pub const RenameOptions = struct {
    /// Rename only while the source's metageneration is this. The one
    /// condition production honors on a rename: the reference page's
    /// `ifMetagenerationMatch` is silently ignored, and the rename runs,
    /// as measured on 2026-10-02, so this library never sends it.
    if_source_metageneration_match: ?u64 = null,
};

/// This handle, billing `project` for every request it makes, as
/// `Bucket.withBillingProject` says.
pub fn withBillingProject(self: Folder, project: []const u8) Folder {
    var copy = self;
    copy.billing_project = project;
    return copy;
}

/// This handle on `copy`, a copy of its client that bills this handle's
/// project for the call now beginning.
fn billing(self: Folder, copy: *Client) Error!Folder {
    rpc.begin(self.client);
    try rpc.checkBillingProject(self.client, self.billing_project);
    copy.* = rpc.billed(self.client, self.billing_project orelse self.client.billing_project);
    var billed_self = self;
    billed_self.client = copy;
    return billed_self;
}

/// Creates the folder, which exists from then on whether or not anything
/// is ever stored under it, and returns it as kept. A folder that exists
/// is `error.AlreadyExists`. Uploads, composes and copies create their
/// missing parents themselves, so folders are created alone mostly to hold
/// a place.
///
/// Safe to retry, though the idempotency token dedupes nothing here, as
/// measured: a create whose answer was lost reads the folder back rather
/// than send again, and takes what it finds, since an identical concurrent
/// create leaves exactly what was asked for.
pub fn create(self: Folder, options: CreateOptions) Error!types.Owned(types.FolderInfo) {
    var client: Client = undefined;
    const billed = try self.billing(&client);
    rpc.begin(billed.client);
    try rpc.checkBucketName(billed.client, billed.bucket);
    return folders.create(billed.client, billed.bucket, billed.name, options.recursive);
}

/// The folder's metadata. An implicit folder, made by an upload's path,
/// reads the same as one created deliberately.
pub fn get(self: Folder) Error!types.Owned(types.FolderInfo) {
    var client: Client = undefined;
    const billed = try self.billing(&client);
    rpc.begin(billed.client);
    try rpc.checkBucketName(billed.client, billed.bucket);
    return folders.get(billed.client, billed.bucket, billed.name);
}

/// Deletes the folder, which must be empty: one holding an object or a
/// child folder is `error.FolderNotEmpty`. Folders are never removed
/// automatically, however empty. Safe to retry: a lost first success shows
/// up as `error.NotFound`.
pub fn delete(self: Folder, options: DeleteOptions) Error!void {
    var client: Client = undefined;
    const billed = try self.billing(&client);
    rpc.begin(billed.client);
    try rpc.checkBucketName(billed.client, billed.bucket);
    return folders.delete(billed.client, billed.bucket, billed.name, .{
        .if_metageneration_match = options.if_metageneration_match,
    });
}

/// Renames this folder, its child folders, its objects and its managed
/// folders to `destination`, one atomic metadata change, and waits for the
/// operation to finish, polling under the client's backoff up to its
/// retry policy's attempts: a small tree is done in the first answer, and
/// 300 folders took under a second, as measured. While it runs, writes
/// under either path answer a retryable 429, which this library's own
/// retries wait out. The renamed folder keeps its create time and
/// metageneration. A destination folder that exists is
/// `error.AlreadyExists` at once; an object of the destination's name is
/// no conflict. A rename cannot be canceled, and is never sent twice: a
/// transient failure says in `Diagnostics` how to see whether it started.
pub fn renameTo(self: Folder, destination: []const u8, options: RenameOptions) Error!types.Owned(types.FolderInfo) {
    var client: Client = undefined;
    const billed = try self.billing(&client);
    rpc.begin(billed.client);
    try rpc.checkBucketName(billed.client, billed.bucket);
    return folders.rename(billed.client, billed.bucket, billed.name, destination, options.if_source_metageneration_match);
}

/// `renameTo` without the wait: the operation as the start answered it,
/// `done` already for a small tree. `Bucket.operation` follows it by
/// `OperationInfo.id`; the finished operation carries the destination as
/// `OperationInfo.folder`.
pub fn startRenameTo(self: Folder, destination: []const u8, options: RenameOptions) Error!types.Owned(types.OperationInfo) {
    var client: Client = undefined;
    const billed = try self.billing(&client);
    rpc.begin(billed.client);
    try rpc.checkBucketName(billed.client, billed.bucket);
    return folders.startRename(billed.client, billed.bucket, billed.name, destination, options.if_source_metageneration_match);
}

test {
    // The handle's behavior is tested beside the calls, in folders.zig.
    _ = @import("folders.zig");
}
