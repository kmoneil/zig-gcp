//! Public data types: object and bucket metadata, listing options and
//! pages, and what a signed URL allows. Results come wrapped in core's
//! `Owned`, re-exported here.

const std = @import("std");
const core = @import("core");

pub const Owned = core.Owned;

/// Where a transfer keeps what a later process needs to carry it on.
pub const Checkpoint = @import("checkpoint.zig").Checkpoint;

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
    /// Null when the object carries none, which is the usual case: Cloud
    /// Storage stores these only when something set them.
    cache_control: ?[]const u8,
    content_disposition: ?[]const u8,
    /// `gzip` on an object stored compressed; see the download options.
    content_encoding: ?[]const u8,
    content_language: ?[]const u8,
    /// Every real object has one; emulators may omit it.
    crc32c: ?u32,
    /// Composite objects have none.
    md5: ?[16]u8,
    /// How many non-composite objects this one is made of, or null when it
    /// is not a composite. Cloud Storage counts it for nothing else.
    component_count: ?u32,
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

    /// Whether these conditions make a metadata write idempotent, which is
    /// a different question: a patch that succeeded and lost its response
    /// has already moved the metageneration, so repeating it under
    /// `if_metageneration_match` fails rather than applying twice. A
    /// generation condition says nothing about that, since a patch leaves
    /// the generation where it was.
    pub fn makesMetadataWriteSafe(self: Preconditions) bool {
        return self.if_metageneration_match != null;
    }
};

/// One object a compose reads from.
pub const ComposeSource = struct {
    /// A name in the destination's bucket. Sources cannot come from
    /// another bucket, and must share a storage class.
    name: []const u8,
    /// Compose one specific generation of it, rather than the live one.
    generation: ?u64 = null,
    /// Compose only if that source is at this generation.
    if_generation_match: ?u64 = null,
};

/// What `Object.composeFrom` writes, beside the sources it reads.
pub const ComposeOptions = struct {
    /// The composite's own metadata: nothing is inherited from the
    /// sources, so an unset content type becomes the default.
    content_type: []const u8 = "application/octet-stream",
    cache_control: ?[]const u8 = null,
    content_encoding: ?[]const u8 = null,
    metadata: []const Metadata = &.{},
    /// Hard-deletes every source once the composite exists, which is what
    /// Google advises for parallel composite uploads, to keep the parts
    /// from being billed. Irreversible, and the wrong choice where soft
    /// delete, object versioning, a retention policy or a hold is in play.
    /// A compose that deletes its sources is never retried without a
    /// precondition: the second attempt would find them gone.
    delete_sources: bool = false,
    /// `if_generation_match` is what makes this safe to retry.
    preconditions: Preconditions = .{},
};

/// What a patch does to an object's custom metadata. Cloud Storage reads
/// three different requests here, and cannot be asked for two at once,
/// since a JSON object has one `metadata` value.
pub const MetadataEdit = union(enum) {
    /// Send no `metadata` at all: every entry keeps its value.
    keep,
    /// Set the entries that carry a value, remove the entries that carry
    /// none, and leave every key not named here exactly as it was.
    change: []const MetadataChange,
    /// Send `"metadata":null`: remove every entry.
    clear,
};

/// One custom metadata entry a patch sets or removes.
pub const MetadataChange = struct {
    key: []const u8,
    /// Null removes the key.
    value: ?[]const u8,
};

/// What `Object.updateMetadata` changes. A field left null keeps the value
/// it had; an empty string clears it.
pub const MetadataUpdate = struct {
    content_type: ?[]const u8 = null,
    cache_control: ?[]const u8 = null,
    content_disposition: ?[]const u8 = null,
    content_encoding: ?[]const u8 = null,
    content_language: ?[]const u8 = null,
    edit: MetadataEdit = .keep,
    /// Change one older generation's metadata instead of the live one.
    generation: ?u64 = null,
    /// `if_metageneration_match` is what makes this safe to retry.
    preconditions: Preconditions = .{},
};

pub const UploadOptions = struct {
    content_type: []const u8 = "application/octet-stream",
    cache_control: ?[]const u8 = null,
    content_disposition: ?[]const u8 = null,
    /// `gzip` marks the object as stored compressed, which changes how
    /// downloads behave; see the download options.
    content_encoding: ?[]const u8 = null,
    content_language: ?[]const u8 = null,
    /// Custom metadata. Keys must not be empty.
    metadata: []const Metadata = &.{},
    /// The known checksum of the whole object. Checked against the data
    /// before anything is sent, and passed on for the server to verify.
    crc32c: ?u32 = null,
    /// The total size, when known. `uploadFrom` works without it; with it,
    /// a reader that ends early is `error.UnexpectedEndOfStream` and one
    /// with more is `error.StreamTooLong`. `upload` checks it against the
    /// slice it was given; `uploadFile` takes its size from the file and
    /// refuses one.
    size: ?u64 = null,
    /// `.does_not_exist` makes an upload create-only and safe to retry.
    preconditions: Preconditions = .{},
    /// Where `uploadFile` keeps what a later process needs to carry the
    /// upload on: the session URL, which is a credential, so the built-in
    /// `storage.CheckpointFile` keeps it readable by its owner only and a
    /// custom store should guard it as it guards credentials. Only
    /// `uploadFile` takes one; `upload` and `uploadFrom` refuse it, since
    /// memory and streams do not outlive a process.
    checkpoint: ?Checkpoint = null,
};

/// Where `Object.uploadParallel` reads its parts.
pub const ParallelSource = union(enum) {
    /// Bytes in memory. Each part is a slice of them; nothing is copied.
    data: []const u8,
    /// A regular file opened for reading. Each part is read at its own
    /// offset, so the file must allow positional reads, and it must not
    /// change until the upload returns.
    file: std.Io.File,
};

pub const ParallelUploadOptions = struct {
    content_type: []const u8 = "application/octet-stream",
    cache_control: ?[]const u8 = null,
    content_disposition: ?[]const u8 = null,
    content_encoding: ?[]const u8 = null,
    content_language: ?[]const u8 = null,
    /// Sent as `x-goog-meta-` headers, the only way the XML API takes
    /// custom metadata. So a key is lowercase letters, digits and
    /// `!#$%&'*+-.^_`|~`, a value printable ASCII without a space at either
    /// end, which HTTP would trim, and all of it together at most 8 KiB.
    metadata: []const Metadata = &.{},
    /// The known checksum of the whole object, checked against the parts'
    /// before they are joined, so a mismatch writes nothing.
    crc32c: ?u32 = null,
    /// 5 MiB to 5 GiB, grown when the object would otherwise need more
    /// than 10,000 parts. Every part but the last is this size.
    part_size: u64 = 32 * 1024 * 1024,
    /// Parts in flight at once, each on a connection of its own: 1 to 64.
    concurrency: u16 = 8,
    /// How long one part may take, far past `Client.Options.request_timeout_ms`,
    /// which still bounds the small requests: at the default a 32 MiB part
    /// may cross its connection at about 110 KiB/s. 0 removes the limit.
    part_timeout_ms: u32 = 300_000,
    /// How long the finish may take: Google says "several minutes". 0
    /// removes the limit.
    finish_timeout_ms: u32 = 600_000,
    /// Conditions on the object's name. When empty, the upload replaces
    /// whatever is there, as the multipart upload always does. When set,
    /// they are checked before a byte is sent, the upload finishes under a
    /// temporary name, and `objects.move` puts it in place only if they
    /// still hold. `.does_not_exist` makes the upload create-only. The move
    /// needs `storage.objects.move`, which Storage Object User grants and
    /// Storage Object Creator does not.
    preconditions: Preconditions = .{},
    /// Where an upload from a file keeps what a later process needs to
    /// carry it on: the upload's id, since which parts the server holds is
    /// the server's to say. A resumed call re-reads the held parts from
    /// the file, so the whole is verified across runs and a file changed
    /// in between is caught, and sends only the rest.
    /// `storage.CheckpointFile` is the built-in store. A memory source
    /// refuses one, since only a file outlives the process, and an
    /// emulator endpoint ignores it, since its one ordinary upload cannot
    /// resume.
    checkpoint: ?Checkpoint = null,
};

/// Where `Object.downloadParallel` writes.
pub const ParallelDestination = union(enum) {
    /// Memory of at least the object's size. The object fills it from the
    /// start; `DownloadResult.bytes_written` says how far.
    buffer: []u8,
    /// A regular file opened for writing, not appending. Its length becomes
    /// exactly the object's, and each range is written at its own offset.
    file: std.Io.File,
};

pub const ParallelDownloadOptions = struct {
    /// Download one specific generation instead of the live one.
    generation: ?u64 = null,
    /// Conditions on the metadata read that opens the download. Every
    /// range is then pinned to the generation that read named.
    preconditions: Preconditions = .{},
    /// At least 1 MiB, grown when the object would otherwise need more than
    /// 10,000 ranges. Every range but the last is this size.
    part_size: u64 = 32 * 1024 * 1024,
    /// Ranges in flight at once, each on a connection of its own: 1 to 64.
    concurrency: u16 = 8,
    /// How long one request for a range may run before it is cut and
    /// resumed where it stopped, far past `Client.Options.request_timeout_ms`,
    /// which still bounds the metadata read. A gzip-stored object is fetched
    /// in one request that cannot resume, so this bounds all of it. 0
    /// removes the limit.
    part_timeout_ms: u32 = 300_000,
    /// Where a download into a file keeps what a later process needs to
    /// carry it on: which ranges the file holds, at which generation.
    /// A resumed call re-reads those ranges from the file, so the whole is
    /// verified across runs and a file changed in between is caught, and
    /// fetches only the rest. `storage.CheckpointFile` is the built-in
    /// store. A buffer destination refuses one, since only a file outlives
    /// the process.
    checkpoint: ?Checkpoint = null,
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
    /// so a range read reports `checksum_verified = false`. A range of an
    /// object stored gzip-compressed is a range of its stored bytes, and
    /// only `decompress = false` takes one: part of a gzip stream does not
    /// decompress.
    range: ?Range = null,
    preconditions: Preconditions = .{},
    /// For an object stored gzip-compressed (`Content-Encoding: gzip`): true
    /// decompresses it here, after its stored bytes met the stored checksum;
    /// false writes the stored bytes as they are, verified the same way.
    /// Either way they come as stored, so a download of one is verified and
    /// resumes where a connection dropped, which Cloud Storage's own
    /// decompression on the way allows neither of. Other objects are
    /// unaffected.
    decompress: bool = true,
};

pub const DownloadResult = struct {
    bytes_written: u64,
    /// The generation that was downloaded, or 0 when the server did not say.
    generation: u64,
    /// False when there was nothing to verify against: the server sent no
    /// checksum, the object was decompressed in transit, or the client
    /// turned verification off.
    checksum_verified: bool,
    /// The CRC32C of the bytes written, whether or not there was a checksum
    /// to verify them against: a range's, or a decompressed object's.
    crc32c: u32,
    /// Bytes that came over the wire: `bytes_written`, but for a gzip
    /// object decompressed here, whose stored bytes are fewer.
    stored_bytes: u64,
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
    /// Everything from here to `storage_class` changes the copy's metadata
    /// on the way. Left null and `.keep`, the copy carries the source's
    /// metadata as it is. Anything else first reads the source and sends
    /// its metadata back with the change applied, since Cloud Storage
    /// takes any metadata a copy sends as the whole of the copy's: a copy
    /// that sent only a content type would lose the rest. An empty string
    /// clears a field, except `content_type`, which a changed copy always
    /// carries.
    content_type: ?[]const u8 = null,
    cache_control: ?[]const u8 = null,
    content_disposition: ?[]const u8 = null,
    content_encoding: ?[]const u8 = null,
    content_language: ?[]const u8 = null,
    edit: MetadataEdit = .keep,
    /// Such as "NEARLINE". Null leaves the class to Cloud Storage, as a
    /// copy with no change does. Copying an object onto itself with a new
    /// class is how a class changes on demand.
    storage_class: ?[]const u8 = null,
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

/// The request a signed URL allows. A signed POST can only start a
/// resumable upload, with the header `x-goog-resumable: start`; the
/// session URI it answers with then takes the bytes with no signature.
pub const SignedMethod = enum { GET, HEAD, PUT, POST, DELETE };

/// A header signed into a URL, which its holder must send with this
/// value. The same shape as the transport's.
pub const Header = core.transport.Header;

/// A query parameter signed into a URL.
pub const QueryParam = struct {
    name: []const u8,
    value: []const u8,
};

/// Where a signed URL puts the bucket's name.
pub const UrlStyle = union(enum) {
    /// `{endpoint}/{bucket}/{object}`. Works for every bucket.
    path,
    /// `{scheme}://{bucket}.{endpoint host}/{object}`, so a browser sees
    /// the bucket as an origin of its own. Needs a bucket name that is a
    /// host label, and over https one without dots, unless it is
    /// `PROJECT.appspot.com`: the certificate covers one label.
    virtual_hosted,
    /// `{scheme}://{host}/{object}`: a domain that serves one bucket. A
    /// CNAME to `c.storage.googleapis.com` serves only plain HTTP, for a
    /// bucket named like the domain, and Google's load balancer does not
    /// pass signed URLs through.
    bucket_bound: BucketBound,
};

pub const BucketBound = struct {
    /// A host, with an optional port, and nothing else: `media.example.com`.
    host: []const u8,
    scheme: core.endpoint.Scheme = .https,
};

/// One hidden input of a signed form: what the browser sends, and what the
/// policy pins it to.
pub const PostField = struct {
    name: []const u8,
    value: []const u8,
};

/// The object name a form may store.
pub const PostKey = union(enum) {
    /// One name, pinned exactly. `Object.postPolicy` fills this in.
    exact: []const u8,
    /// Any name starting with this, so the browser chooses the rest. The
    /// form's `key` field becomes `{prefix}${filename}`, and Cloud Storage
    /// replaces `${filename}` with the name of the file it was sent. An
    /// empty prefix allows any name in the bucket.
    starts_with: []const u8,
};

/// A condition on a field whose value the form chooses. A field in
/// `PostPolicyOptions.fields` needs none: it is pinned to its value.
pub const PostCondition = union(enum) {
    /// `["starts-with", "$field", prefix]`. An empty prefix allows any
    /// value, which is how a form lets the browser pick a content type.
    starts_with: struct { field: []const u8, prefix: []const u8 },
    /// `["content-length-range", min, max]`, in bytes, both inclusive.
    content_length_range: struct { min: u64, max: u64 },
};

/// A signed POST policy: where a form posts, and the hidden inputs it
/// carries. The form must also send `file`, last, holding the bytes; this
/// library never sees them.
pub const PostPolicy = struct {
    url: []const u8,
    fields: []const PostField,

    /// The value of `name`, or null when the policy has no such field.
    pub fn field(self: PostPolicy, name: []const u8) ?[]const u8 {
        for (self.fields) |f| {
            if (std.ascii.eqlIgnoreCase(f.name, name)) return f.value;
        }
        return null;
    }
};

pub const PostPolicyOptions = struct {
    /// How long the policy works, counted from now: 1 to 604,800 seconds
    /// (seven days), and at most what the signer's keys are sure to last,
    /// 43,200 through IAM. No default: a lifetime is a decision.
    expires_in_s: u32,
    /// The object name the form may store. `Object.postPolicy` names it
    /// itself and refuses one set here; `Bucket.postPolicy` needs one.
    key: ?PostKey = null,
    /// Fields the form must send with these values, each of which becomes
    /// an exact-match condition: `content-type`, `acl`, `cache-control`,
    /// `success_action_status`, `x-goog-meta-*`. Sent in this order.
    fields: []const PostField = &.{},
    /// Conditions on fields whose value the form chooses.
    conditions: []const PostCondition = &.{},
    style: UrlStyle = .path,
};

pub const SignedUrlOptions = struct {
    method: SignedMethod = .GET,
    /// How long the URL works, counted from now: 1 to 604,800 seconds
    /// (seven days), and at most what the signer's keys are sure to last,
    /// 43,200 through IAM. No default: a lifetime is a decision.
    expires_in_s: u32,
    /// Headers the holder must send with these values: a `content-type`
    /// on a PUT, `x-goog-content-length-range` to cap its size,
    /// `x-goog-if-generation-match: 0` to make it create-only. Names are
    /// case-insensitive; `host` is always signed and must not appear.
    headers: []const Header = &.{},
    /// Query parameters signed into the URL, such as
    /// `response-content-disposition` or `generation`. The holder cannot
    /// add others: Cloud Storage refuses any it finds unsigned.
    query: []const QueryParam = &.{},
    style: UrlStyle = .path,
};

const testing = std.testing;

test "ObjectInfo.metadataValue finds the first match" {
    const info: ObjectInfo = .{
        .component_count = null,
        .cache_control = null,
        .content_disposition = null,
        .content_encoding = null,
        .content_language = null,
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
