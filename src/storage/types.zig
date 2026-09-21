//! Public data types: object and bucket metadata, listing options and
//! pages. Results come wrapped in core's `Owned`, re-exported here.

const std = @import("std");

pub const Owned = @import("core").Owned;

/// One entry of an object's custom metadata, a flat map of string to string.
pub const Metadata = struct {
    key: []const u8,
    value: []const u8,
};

/// An object's metadata, as `get` and `listObjects` return it.
pub const ObjectInfo = struct {
    /// The object name, slashes and all.
    name: []const u8,
    bucket: []const u8,
    size: u64,
    /// Changes with every overwrite of the object's data.
    generation: u64,
    /// Changes with every metadata update of this generation.
    metageneration: u64,
    content_type: []const u8,
    /// Every real object has one; emulators may omit it.
    crc32c: ?u32,
    /// Composite objects have none.
    md5: ?[16]u8,
    etag: []const u8,
    storage_class: []const u8,
    /// RFC 3339, as sent by the server. `core.timestamp.parse` converts it.
    time_created: []const u8,
    updated: []const u8,
    metadata: []const Metadata,

    /// The value of the custom metadata entry named `key`, or null.
    pub fn metadataValue(self: ObjectInfo, key: []const u8) ?[]const u8 {
        for (self.metadata) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }
};

pub const ListOptions = struct {
    /// Only objects whose names start with this.
    prefix: ?[]const u8 = null,
    /// Usually "/". Groups names by their next delimiter into `prefixes`,
    /// which is how "folders" are listed.
    delimiter: ?[]const u8 = null,
    /// Results per page, at most 1,000. 0 lets the server choose.
    page_size: u32 = 0,
    /// `next_page_token` from the previous page; null for the first page.
    page_token: ?[]const u8 = null,
};

pub const ObjectPage = struct {
    objects: []const ObjectInfo,
    /// The distinct "folders" under the request's prefix; empty unless a
    /// delimiter was sent.
    prefixes: []const []const u8,
    /// Pass as `page_token` to get the next page. Null on the last page.
    next_page_token: ?[]const u8,
};

/// Conditions a call must meet, matched against the object's generations
/// on the server. A failed condition is `error.FailedPrecondition` (HTTP
/// 412), except `if_generation_not_match` and `if_metageneration_not_match`
/// on a read, whose "condition met, nothing new" answer is
/// `error.NotModified` (HTTP 304). A write with `if_generation_match` is
/// safe to retry: a repeat of one that already landed fails cleanly
/// instead of overwriting whatever is there by now.
pub const Preconditions = struct {
    /// Succeed only if the live generation is exactly this. 0 means "no
    /// live object with this name".
    if_generation_match: ?u64 = null,
    if_generation_not_match: ?u64 = null,
    /// Precondition on the metadata generation of the live object.
    if_metageneration_match: ?u64 = null,
    if_metageneration_not_match: ?u64 = null,

    /// Succeed only if no live object has this name: create-only
    /// semantics, and what makes an upload safe to retry.
    pub const does_not_exist: Preconditions = .{ .if_generation_match = 0 };

    /// Whether these conditions make a write idempotent.
    pub fn makesWriteSafe(self: Preconditions) bool {
        return self.if_generation_match != null;
    }
};

pub const UploadOptions = struct {
    content_type: []const u8 = "application/octet-stream",
    cache_control: ?[]const u8 = null,
    /// `gzip` marks the object as stored compressed, which changes how
    /// downloads behave; see the download options.
    content_encoding: ?[]const u8 = null,
    /// Custom metadata. Keys must not be empty.
    metadata: []const Metadata = &.{},
    /// The known checksum of the whole object. Checked against the data
    /// before anything is sent, and passed on for the server to verify.
    crc32c: ?u32 = null,
    /// The total size, when known. `uploadFrom` works without it; with it,
    /// a reader that ends early is `error.UnexpectedEndOfStream` and one
    /// with more is `error.StreamTooLong`. `upload` checks it against the
    /// slice it was given.
    size: ?u64 = null,
    /// `.does_not_exist` makes an upload create-only and safe to retry.
    preconditions: Preconditions = .{},
};

/// A byte range of an object: `length` bytes from `offset`, or everything
/// from `offset` when `length` is null.
pub const Range = struct {
    offset: u64,
    length: ?u64 = null,
};

pub const DownloadOptions = struct {
    /// Download one specific generation instead of the live one.
    generation: ?u64 = null,
    /// Download part of the object. The checksum covers the whole object,
    /// so a range read reports `checksum_verified = false`.
    range: ?Range = null,
    preconditions: Preconditions = .{},
};

pub const DownloadResult = struct {
    bytes_written: u64,
    /// The generation that was downloaded, or 0 when the server did not say.
    generation: u64,
    /// False when there was nothing to verify against: the server sent no
    /// checksum, the object was decompressed in transit, or the client
    /// turned verification off.
    checksum_verified: bool,
};

/// A whole object in memory, with how the download went.
pub const Downloaded = struct {
    data: []const u8,
    result: DownloadResult,
};

pub const GetOptions = struct {
    /// Address one specific generation instead of the live one.
    generation: ?u64 = null,
    preconditions: Preconditions = .{},
};

pub const DeleteOptions = struct {
    /// Delete one specific generation instead of the live one. Also what
    /// makes a delete safe to retry: with it, a repeat of a delete that
    /// already happened is `error.NotFound`, never someone else's object.
    generation: ?u64 = null,
    /// `if_generation_match` also makes a delete safe to retry.
    preconditions: Preconditions = .{},
};

pub const CopyOptions = struct {
    /// Copy one specific generation of the source instead of the live one.
    source_generation: ?u64 = null,
    /// Conditions on the destination. `if_generation_match` makes the
    /// copy safe to retry.
    preconditions: Preconditions = .{},
};

/// What `Bucket.create` sends. Everything else stays at the server default.
pub const BucketConfig = struct {
    location: []const u8 = "US",
    storage_class: []const u8 = "STANDARD",
};

pub const BucketInfo = struct {
    name: []const u8,
    location: []const u8,
    storage_class: []const u8,
    /// RFC 3339, as sent by the server.
    time_created: []const u8,
};

pub const PageOptions = struct {
    /// Results per page. 0 lets the server choose.
    page_size: u32 = 0,
    /// `next_page_token` from the previous page; null for the first page.
    page_token: ?[]const u8 = null,
};

pub const BucketPage = struct {
    buckets: []const BucketInfo,
    /// Pass as `page_token` to get the next page. Null on the last page.
    next_page_token: ?[]const u8,
};

const testing = std.testing;

test "ObjectInfo.metadataValue finds the first match" {
    const info: ObjectInfo = .{
        .name = "reports/2026/q3.txt",
        .bucket = "my-bucket",
        .size = 12,
        .generation = 1,
        .metageneration = 1,
        .content_type = "text/plain",
        .crc32c = null,
        .md5 = null,
        .etag = "",
        .storage_class = "STANDARD",
        .time_created = "",
        .updated = "",
        .metadata = &.{
            .{ .key = "origin", .value = "zig" },
            .{ .key = "origin", .value = "second" },
        },
    };
    try testing.expectEqualStrings("zig", info.metadataValue("origin").?);
    try testing.expectEqual(null, info.metadataValue("missing"));
}
