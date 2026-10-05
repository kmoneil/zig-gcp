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
    /// When this version stopped being the live one, in a bucket that keeps
    /// versions. Null for a live object.
    time_deleted: ?[]const u8 = null,
    /// When a soft-deleted object was deleted. Null for any other.
    soft_delete_time: ?[]const u8 = null,
    /// When a soft-deleted object stops being restorable. Fixed at the
    /// delete: a later change to the bucket's retention leaves it be.
    hard_delete_time: ?[]const u8 = null,
    /// Tells apart soft-deleted objects of one name and generation, which
    /// only buckets with hierarchical namespace have: what
    /// `RestoreOptions.restore_token` takes.
    restore_token: ?[]const u8 = null,
    /// The Cloud KMS key version that encrypts the object, as
    /// `projects/P/locations/L/keyRings/R/cryptoKeys/K/cryptoKeyVersions/N`.
    /// Null for an object under Google's own key or a customer-supplied
    /// one. A write may name it as it is: the version goes before sending.
    kms_key_name: ?[]const u8 = null,
    /// The SHA-256 of the customer-supplied key that encrypts the object,
    /// or null for any other. Cloud Storage keeps only this, and reports it
    /// to anyone who may read the object's metadata; `EncryptionKey.sha256`
    /// gives the same for a key, to tell which one this is. Such an object
    /// read without its key reports no `crc32c` and no `md5`.
    encryption_key_sha256: ?[32]u8 = null,
    /// Held until released: neither deleted nor replaced, nor moved, though
    /// its metadata stays editable. A write refused for it is
    /// `error.ObjectRetained`.
    temporary_hold: bool = false,
    /// The same, and under a retention policy the period runs from the
    /// hold's release rather than from the object's creation.
    event_based_hold: bool = false,
    /// RFC 3339: the earliest time the object may be deleted or replaced,
    /// the later of its bucket's retention policy and its own retention.
    /// Null where neither applies, and while an event-based hold defers
    /// the policy.
    retention_expiration_time: ?[]const u8 = null,
    /// Its own retention, in a bucket with object retention enabled.
    retention: ?ObjectRetention = null,
    /// Its access control list, read only when asked for:
    /// `GetOptions.with_acl`, `ListOptions.with_acl`. Null when not asked
    /// for, when the caller may not read it (that takes
    /// `storage.objects.getIamPolicy`), and in a bucket with uniform
    /// bucket-level access, which keeps none.
    acl: ?[]const AclEntry = null,
    /// Who owns it, as `acl` is read: the account that wrote it.
    owner: ?AclEntity = null,

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
    /// Every version of every object, noncurrent ones included, by name
    /// and then by generation. Noncurrent versions carry `time_deleted`.
    /// A bucket that keeps no versions lists its live objects.
    versions: bool = false,
    /// Only soft-deleted objects, which the bucket keeps restorable for its
    /// soft delete retention; a bucket without soft delete refuses the
    /// listing. Not together with `versions`.
    soft_deleted: bool = false,
    /// Only names matching this glob, such as `logs/**/*.gz`: `*` matches
    /// within a folder, `**` across folders.
    match_glob: ?[]const u8 = null,
    /// Add folders to `prefixes` whether or not objects sit under them: a
    /// hierarchical-namespace bucket's folders, and any bucket's managed
    /// folders. Cloud Storage takes it only with the `/` delimiter, so
    /// without one it is refused before sending, as measured 2026-10-02.
    include_folders_as_prefixes: bool = false,
    /// Read each object's access control list and owner too
    /// (`projection=full`).
    with_acl: bool = false,
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
    /// Place a temporary hold on the composite as it is made.
    temporary_hold: bool = false,
    /// Place an event-based hold on the composite (true), or not even where
    /// the bucket's default would (false). Null: as the bucket's default
    /// says.
    event_based_hold: ?bool = null,
    /// The composite's own retention.
    retention: ?ObjectRetention = null,
    /// Hard-deletes every source once the composite exists, which is what
    /// Google advises for parallel composite uploads, to keep the parts
    /// from being billed. Irreversible, and the wrong choice where soft
    /// delete, object versioning, a retention policy or a hold is in play.
    /// A compose that deletes its sources is never retried without a
    /// precondition: the second attempt would find them gone.
    delete_sources: bool = false,
    /// `if_generation_match` is what makes this safe to retry.
    preconditions: Preconditions = .{},
    /// Encrypt the composite with this Cloud KMS key instead of the
    /// bucket's default, which a compose that names none gets, whatever
    /// keys its sources are under.
    kms_key_name: ?[]const u8 = null,
    /// A canned access control list for the composite, which otherwise
    /// gets the bucket's default object list, as a copy does.
    predefined_acl: ?PredefinedAcl = null,
};

/// An object's own retention, in a bucket created with
/// `BucketConfig.object_retention`: it is kept until `retain_until`, as a
/// retention policy keeps it, and a write that would delete, replace or
/// move it is `error.ObjectRetained`. Not together with an event-based
/// hold.
pub const ObjectRetention = struct {
    mode: Mode,
    /// RFC 3339 with `Z` or an offset, in the future and at most 100 years
    /// ahead.
    retain_until: []const u8,

    pub const Mode = enum {
        /// Extended freely; shortened, removed or locked only with
        /// `MetadataUpdate.override_unlocked_retention`.
        unlocked,
        /// Extended only: never shortened, unlocked or removed, override
        /// or not.
        locked,
        /// A mode the server sent that this library does not know. Never
        /// sent: a write carrying it is refused.
        unknown,
    };
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
    /// Place (true) or release (false) a temporary hold. Null leaves it.
    temporary_hold: ?bool = null,
    /// Place (true) or release (false) an event-based hold, which under a
    /// retention policy starts the period over. Null leaves it.
    event_based_hold: ?bool = null,
    /// The object's own retention: `.set` extends it, or places it on an
    /// object without; shortening, removing (`.clear`) or locking an
    /// unlocked one also needs `override_unlocked_retention`. A locked one
    /// is only ever extended.
    retention: Change(ObjectRetention) = .keep,
    /// Allows shortening, removing or locking an unlocked retention. Needs
    /// `storage.objects.overrideUnlockedRetention`. Without it, such a
    /// change is `error.PermissionDenied`, as is any but an extension of a
    /// locked one.
    override_unlocked_retention: bool = false,
    /// Change one older generation's metadata instead of the live one.
    generation: ?u64 = null,
    /// Replace the object's whole access control list with a canned one.
    /// The owner keeps OWNER whatever the list.
    predefined_acl: ?PredefinedAcl = null,
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
    /// Compress the data with gzip on its way up and store it that way,
    /// with `Content-Encoding: gzip`, as `gcloud storage cp -z` does. The
    /// object's size and checksum are then the compressed bytes', and a
    /// download decompresses it again. `content_encoding` must be left
    /// null, since this sets it, and `crc32c` names the data before
    /// compression. With `Client.verify_checksums`, the compressed bytes
    /// are decompressed again as they are made, and must give back the
    /// data before the upload may finish. Data already compressed, such as
    /// images, video or archives, only grows.
    gzip: ?Gzip = null,
    /// Encrypt the object with this Cloud KMS key,
    /// `projects/P/locations/L/keyRings/R/cryptoKeys/K`, instead of the
    /// bucket's default key, or Google's own where the bucket has none.
    /// The key must be in the bucket's location, and Cloud Storage's
    /// service agent for the project, which `Client.serviceAgent` names,
    /// must hold `roles/cloudkms.cryptoKeyEncrypterDecrypter` on it. Not
    /// together with a customer-supplied key.
    kms_key_name: ?[]const u8 = null,
    /// Place a temporary hold on the object as it is written: it cannot be
    /// deleted, replaced or moved until `updateMetadata` releases the hold.
    temporary_hold: bool = false,
    /// Place an event-based hold on the object (true), or not even where
    /// the bucket's default would (false). Null: as the bucket's default
    /// says.
    event_based_hold: ?bool = null,
    /// The object's own retention, in a bucket with object retention.
    retention: ?ObjectRetention = null,
    /// A canned access control list for the object, in place of the
    /// bucket's default object list. A bucket with uniform bucket-level
    /// access refuses any (`error.UniformAccessEnabled`), and one under
    /// public access prevention refuses `.public_read` and
    /// `.authenticated_read` (`error.PublicAccessPrevented`).
    predefined_acl: ?PredefinedAcl = null,
};

/// How `UploadOptions.gzip` compresses.
pub const Gzip = struct {
    /// 1 (fastest) to 9 (smallest), as `gzip -1` to `gzip -9`. At 6, Zig's
    /// compressor takes text to about 13% of its size at about 110 MiB/s
    /// in `ReleaseFast`; at 9, about the same size at 44 MiB/s; at 1, 17%
    /// at 200 MiB/s. A Debug build is about eight times slower.
    level: u4 = 6,
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
    /// As `UploadOptions.kms_key_name`.
    kms_key_name: ?[]const u8 = null,
    /// As `UploadOptions.predefined_acl`.
    predefined_acl: ?PredefinedAcl = null,
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
    /// For an object stored gzip-compressed: true, the default, fetches it
    /// in one verified stream and decompresses it here, since a
    /// decompressor must see the bytes in order; false fetches its stored
    /// bytes in ranges, several at once, like any object's, and writes them
    /// as they are. Other objects are unaffected.
    decompress: bool = true,
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
    /// A soft-deleted generation's metadata, which `generation` must name.
    /// Its bytes cannot be read, only restored.
    soft_deleted: bool = false,
    /// With `soft_deleted`, in a bucket with hierarchical namespace: which
    /// of the soft-deleted objects of that name and generation.
    restore_token: ?[]const u8 = null,
    /// Read the object's access control list and owner too
    /// (`projection=full`).
    with_acl: bool = false,
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
    /// Encrypt the copy with this Cloud KMS key. A copy that names none
    /// gets the destination bucket's default key, else Google's own: the
    /// source's key does not carry over, as measured.
    kms_key_name: ?[]const u8 = null,
    /// Holds for the copy, which never carries the source's: a temporary
    /// hold, and an event-based one (true), or none even where the
    /// bucket's default would place one (false). Setting either is a
    /// change, and reads the source first as the fields above do.
    temporary_hold: bool = false,
    event_based_hold: ?bool = null,
    /// The copy's own retention, which it never carries from the source.
    /// Setting it is a change, as the holds are.
    retention: ?ObjectRetention = null,
    /// A canned access control list for the copy. Without one, the copy
    /// gets the destination bucket's default object list with the caller
    /// as owner, never the source's list, as measured 2026-10-05.
    predefined_acl: ?PredefinedAcl = null,
};

/// What an update does to a setting that can be taken away: `.keep`,
/// `.set`, or `.clear`. Core's, shared with the other modules.
pub const Change = core.Change;

/// A bucket's label: a key and a value that describe it for billing
/// reports, searches and policies. Keys are 1 to 63 characters and values
/// up to 63, each at most 128 bytes, of lowercase letters, digits, `_` and
/// `-`, and a key starts with a lowercase letter. Letters beyond ASCII
/// count too, uppercase ones excepted.
pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

/// One label an update sets or removes.
pub const LabelChange = struct {
    key: []const u8,
    /// Null removes the label.
    value: ?[]const u8,
};

/// What an update does to a bucket's labels.
pub const LabelEdit = union(enum) {
    /// Every label keeps its value.
    keep,
    /// Set the labels that carry a value, remove those that carry none,
    /// and leave every other label as it was. An empty list changes
    /// nothing and sends nothing: Cloud Storage takes an empty set of
    /// labels for "remove them all".
    change: []const LabelChange,
    /// Remove every label.
    clear,
};

/// Whether a bucket's objects may ever be made public.
pub const PublicAccessPrevention = enum {
    /// As the organization's policy says, which allows it unless the
    /// policy enforces prevention.
    inherited,
    /// Never: an ACL or IAM grant to `allUsers` or `allAuthenticatedUsers`
    /// is refused, and existing ones stop working.
    enforced,
    /// A value the server sent that this library does not know. Never
    /// sent: a config or update carrying it is refused.
    unknown,
};

/// What an access control list entry grants. A bucket's list takes all
/// three; an object's, and a bucket's default object list, take `owner`
/// and `reader` only.
pub const AclRole = enum {
    owner,
    /// Buckets only: create, replace and delete the bucket's objects.
    writer,
    reader,
    /// A role the server sent that this library does not know. Never sent.
    unknown,
};

/// Who an access control list entry grants to, as Cloud Storage spells it:
/// `user-EMAIL`, `group-EMAIL`, `domain-DOMAIN`, `project-TEAM-NUMBER`,
/// `allUsers` or `allAuthenticatedUsers`. It is written into a request
/// when sent, so building one allocates nothing.
pub const AclEntity = union(enum) {
    /// A Google account or service account, by email. Cloud Storage keeps
    /// emails in lower case, as measured 2026-10-05, and refuses one it
    /// does not know.
    user: []const u8,
    /// A Google group, by email.
    group: []const u8,
    /// Every account of a Google Workspace or Cloud Identity domain.
    domain: []const u8,
    /// A project's owners, editors or viewers.
    project: Project,
    /// Anyone on the Internet. Refused under public access prevention.
    all_users,
    /// Anyone signed in to a Google account. Refused likewise.
    all_authenticated_users,
    /// A form this library does not model, such as `user-` and a numeric
    /// ID, kept as the server sent it.
    other: []const u8,

    pub const Project = struct {
        team: Team,
        /// The project's number. Cloud Storage takes an ID too, but stores
        /// the number, so an entry named by ID could never be found again.
        number: []const u8,
    };

    pub const Team = enum { owners, editors, viewers };
};

/// One entry of an access control list.
pub const AclEntry = struct {
    entity: AclEntity,
    role: AclRole,
    /// The address of a user or group entry, as Cloud Storage keeps it.
    email: ?[]const u8 = null,
    /// The domain of a domain entry.
    domain: ?[]const u8 = null,
    /// An ID Cloud Storage keeps for some entities; none of the entries
    /// measured carried one.
    entity_id: ?[]const u8 = null,
};

/// An access control list as read or written: a bucket's, its default
/// object list, or an object's, with what a guarded write needs.
pub const Acl = struct {
    entries: []const AclEntry,
    /// Who always keeps OWNER, which nothing can take from them: the
    /// bucket's project owners, or the account that wrote the object. Null
    /// for a default object list, whose objects are owned by their writers.
    owner: ?AclEntity = null,
    /// The bucket's or object's metageneration when read or written: what
    /// `AclGuard.if_metageneration_match` takes.
    metageneration: u64,
    /// The object's generation, which `AclGuard.if_generation_match`
    /// takes; null for a bucket's lists.
    generation: ?u64 = null,
};

/// The conditions a whole-list write is held to. With
/// `if_metageneration_match`, a write is safe to retry: a repeat of one
/// that landed fails rather than overwrite a change made in between.
pub const AclGuard = struct {
    if_metageneration_match: ?u64 = null,
    /// An object's only: write the list only while this is the live
    /// generation.
    if_generation_match: ?u64 = null,
};

/// A canned access control list for an object, applied whole in place of
/// any it had. The owner, who wrote the object, is always OWNER. As
/// measured 2026-10-05:
pub const PredefinedAcl = enum {
    /// The owner, and `allAuthenticatedUsers` READER.
    authenticated_read,
    /// The owner, and the bucket's project owners OWNER.
    bucket_owner_full_control,
    /// The owner, and the bucket's project owners READER.
    bucket_owner_read,
    /// The owner alone.
    private,
    /// The owner, project owners and editors OWNER, project viewers READER:
    /// a new bucket's default.
    project_private,
    /// The owner, and `allUsers` READER.
    public_read,
};

/// A canned access control list for a bucket, applied whole in place of
/// any it had. The project's owners are always OWNER.
pub const PredefinedBucketAcl = enum {
    /// Project owners OWNER, and `allAuthenticatedUsers` READER.
    authenticated_read,
    /// Project owners OWNER alone.
    private,
    /// Project owners and editors OWNER, project viewers READER: a new
    /// bucket's list.
    project_private,
    /// Project owners OWNER, and `allUsers` READER.
    public_read,
    /// Project owners OWNER, and `allUsers` WRITER.
    public_read_write,
};

/// A rule Cloud Storage applies to a bucket's objects, about once a day:
/// the action, taken on every object that meets every condition.
pub const LifecycleRule = struct {
    action: Action,
    condition: Condition,
    /// Set on a rule read from a bucket that carries an action or a
    /// condition this library does not know, such as the early-access
    /// `matchesPattern`. Such a rule is never sent: without what this
    /// library could not read, it would act on objects the bucket's own
    /// rule leaves alone, so a config or update that carries it is refused.
    unrecognized: bool = false,

    pub const Action = union(enum) {
        delete,
        /// Such as "NEARLINE".
        set_storage_class: []const u8,
        /// Cancels XML multipart uploads left unfinished, as parallel
        /// uploads can leave them. Takes only `age_days`, `matches_prefix`
        /// and `matches_suffix`.
        abort_incomplete_multipart_upload,
        /// An action this library does not know, on a rule read from a
        /// bucket, which is then `unrecognized`.
        unknown,
    };

    /// Every field set must hold for the action to apply, and at least
    /// one must be set; an empty list counts as not set. Dates are
    /// `YYYY-MM-DD`, midnight UTC. Days and counts are at most
    /// 2,147,483,647, and sizes at most 5 TiB.
    pub const Condition = struct {
        /// Days since the object was created.
        age_days: ?u32 = null,
        /// Objects created before this date.
        created_before: ?[]const u8 = null,
        /// Objects whose custom time is before this date.
        custom_time_before: ?[]const u8 = null,
        days_since_custom_time: ?u32 = null,
        /// Days since a version became noncurrent.
        days_since_noncurrent_time: ?u32 = null,
        /// True: live objects only. False: noncurrent versions only.
        is_live: ?bool = null,
        /// Names starting with any of these. Every prefix and suffix is 1
        /// to 1,024 bytes, and a bucket's rules name at most 1,000 of them
        /// together.
        matches_prefix: []const []const u8 = &.{},
        /// Names ending with any of these.
        matches_suffix: []const []const u8 = &.{},
        /// Objects in any of these classes, such as "STANDARD".
        matches_storage_class: []const []const u8 = &.{},
        /// Versions that became noncurrent before this date.
        noncurrent_time_before: ?[]const u8 = null,
        /// Noncurrent versions with at least this many newer versions,
        /// the live one included.
        num_newer_versions: ?u32 = null,
        size_above_bytes: ?u64 = null,
        size_below_bytes: ?u64 = null,
    };
};

/// What `Bucket.create` sends. Everything left at its default stays at
/// Cloud Storage's default, and a config with every default sends only
/// the name, the location and the class.
pub const BucketConfig = struct {
    location: []const u8 = "US",
    storage_class: []const u8 = "STANDARD",
    /// Keep every version an overwrite or a delete replaces.
    versioning: bool = false,
    /// How long a deleted object stays restorable: 0 turns soft delete
    /// off, else 604,800 to 7,776,000 seconds (7 to 90 days). Null:
    /// Cloud Storage's default, 7 days unless the organization sets
    /// another. A bucket that ever had soft delete on is itself kept,
    /// soft-deleted, after it is deleted, for the longest retention it
    /// ever had; one created with 0 and never changed goes outright.
    soft_delete_retention_s: ?u32 = null,
    /// Bill requests to the requester's project, not the bucket's.
    requester_pays: bool = false,
    /// `projects/P/locations/L/keyRings/R/cryptoKeys/K`, in the bucket's
    /// location and granted to Cloud Storage's service agent: the Cloud
    /// KMS key that encrypts objects written without a key of their own.
    default_kms_key_name: ?[]const u8 = null,
    /// At most 64, each key once.
    labels: []const Label = &.{},
    lifecycle: []const LifecycleRule = &.{},
    /// Null: as the organization's policy says.
    uniform_bucket_level_access: ?bool = null,
    /// Null: `.inherited`.
    public_access_prevention: ?PublicAccessPrevention = null,
    /// Keep every object at least this long after its creation, 1 to
    /// 3,155,760,000 seconds (100 years): until then it cannot be deleted,
    /// replaced or moved, and a write that tries is
    /// `error.ObjectRetained`. Null: no retention policy.
    retention_period_s: ?u64 = null,
    /// Place an event-based hold on every object written to the bucket
    /// that does not ask for none.
    default_event_based_hold: bool = false,
    /// Let objects carry a retention of their own. Permanent: it cannot be
    /// turned off, nor turned on later, and Cloud Storage places a lien on
    /// the project that keeps it from being deleted. Needs
    /// `storage.buckets.enableObjectRetention`.
    object_retention: bool = false,
    /// Folders become real resources: `Bucket.folder` creates, lists,
    /// deletes and renames them, and an upload creates its parents.
    /// Create-time only: a later update naming it answers 200 and silently
    /// drops it, as measured 2026-10-02, so none is ever sent. It needs
    /// uniform bucket-level access, which is sent along unless
    /// `uniform_bucket_level_access` says false, and it excludes
    /// versioning, retention policies and object retention, refused here
    /// in the server's words.
    hierarchical_namespace: bool = false,
    /// The bucket's access control list, in place of `.project_private`,
    /// which a new bucket gets. Only without uniform bucket-level access,
    /// which keeps no lists: refused before sending beside it.
    predefined_acl: ?PredefinedBucketAcl = null,
    /// The list objects written without one of their own get, in place of
    /// `.project_private`. Only without uniform bucket-level access.
    predefined_default_object_acl: ?PredefinedAcl = null,
};

/// A bucket's retention policy: every object is kept at least `period_s`
/// after its creation, or after its event-based hold's release.
pub const RetentionPolicy = struct {
    period_s: u64,
    /// RFC 3339: from when every object has been kept for the period.
    effective_time: ?[]const u8 = null,
    /// A locked policy can only be lengthened: never removed or shortened.
    locked: bool = false,
};

/// A bucket, as `create`, `get`, `update` and `listBuckets` return it.
pub const BucketInfo = struct {
    name: []const u8,
    location: []const u8,
    storage_class: []const u8,
    /// RFC 3339, as sent by the server.
    time_created: []const u8,
    /// Changes with every update: what `BucketUpdate.if_metageneration_match`
    /// compares.
    metageneration: u64 = 0,
    /// Which bucket of this name this is: a name deleted and created again
    /// is a new generation.
    generation: ?u64 = null,
    project_number: ?u64 = null,
    /// Such as "region", "dual-region" or "multi-region".
    location_type: ?[]const u8 = null,
    /// RFC 3339, when the settings last changed.
    updated: ?[]const u8 = null,
    versioning: bool = false,
    /// Null: no soft delete.
    soft_delete: ?SoftDelete = null,
    requester_pays: bool = false,
    default_kms_key_name: ?[]const u8 = null,
    /// In no particular order: Cloud Storage's changes between reads.
    labels: []const Label = &.{},
    lifecycle: []const LifecycleRule = &.{},
    uniform_bucket_level_access: bool = false,
    public_access_prevention: PublicAccessPrevention = .inherited,
    /// Null: none.
    retention_policy: ?RetentionPolicy = null,
    default_event_based_hold: bool = false,
    /// Objects may carry a retention of their own.
    object_retention: bool = false,
    /// A soft-deleted bucket's: when it was deleted, and when it stops
    /// being restorable. Null for a live one.
    soft_delete_time: ?[]const u8 = null,
    hard_delete_time: ?[]const u8 = null,
    /// Folders are real resources in this bucket.
    hierarchical_namespace: bool = false,

    pub const SoftDelete = struct {
        retention_s: u32,
        /// RFC 3339: since when this policy, or one with a longer
        /// retention, has been in force.
        effective_time: ?[]const u8 = null,
    };

    /// The value of the label named `key`, or null.
    pub fn label(self: BucketInfo, key: []const u8) ?[]const u8 {
        for (self.labels) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }
};

/// What `Object.restore` brings back.
pub const RestoreOptions = struct {
    /// The soft-deleted generation. It stays soft-deleted, and restorable
    /// again, after the restore: a restore makes a new generation.
    generation: u64,
    /// Conditions on the live object of the name, which a restore replaces.
    /// `.does_not_exist` restores only where nothing live has the name.
    /// `if_generation_match` is what makes a restore safe to retry: a
    /// repeat of one that landed fails, where without it the repeat makes a
    /// second copy and pushes the first into soft delete.
    preconditions: Preconditions = .{},
    /// Give the new object the soft-deleted one's ACL, rather than the
    /// bucket's default. Refused on a bucket with uniform bucket-level
    /// access.
    copy_source_acl: bool = false,
    /// In a bucket with hierarchical namespace, which of the soft-deleted
    /// objects of this name and generation: `ObjectInfo.restore_token`.
    restore_token: ?[]const u8 = null,
};

/// What `Bucket.bulkRestore` brings back: the newest soft-deleted
/// generation of each name that matches.
pub const BulkRestoreOptions = struct {
    /// Globs such as `logs/**`. Empty restores every name.
    match_globs: []const []const u8 = &.{},
    /// RFC 3339 bounds on when objects were soft-deleted, and on when
    /// they were first created.
    soft_deleted_after: ?[]const u8 = null,
    soft_deleted_before: ?[]const u8 = null,
    created_after: ?[]const u8 = null,
    created_before: ?[]const u8 = null,
    /// Replace live objects of the same name. Off, they are skipped.
    allow_overwrite: bool = false,
    /// Give each object its soft-deleted ACL.
    copy_source_acl: bool = false,
};

/// What a long-running operation is doing: read from its metadata's type,
/// so one this library does not know is `.unknown`, never an error.
pub const OperationKind = enum { bulk_restore, rename_folder, unknown };

/// A long-running operation, as a bulk restore or a folder rename starts
/// one.
pub const OperationInfo = struct {
    /// What `Bucket.operation` and `Bucket.cancelOperation` take.
    id: []const u8,
    done: bool,
    kind: OperationKind = .unknown,
    /// Set when it ended without finishing: code 1 when it was cancelled.
    failure: ?Failure = null,
    /// Null while Cloud Storage cannot say, which it could not for any bulk
    /// restore measured; a rename answered 1, then 100.
    progress_percent: ?u8 = null,
    requested_cancellation: bool = false,
    /// A bulk restore's objects restored, skipped (a live one of the name,
    /// without `allow_overwrite`), and failed.
    succeeded: u64 = 0,
    skipped: u64 = 0,
    failed: u64 = 0,
    /// A rename's two paths, as its metadata names them.
    source_folder: ?[]const u8 = null,
    destination_folder: ?[]const u8 = null,
    /// A finished rename's destination folder, which keeps its create time
    /// and metageneration from before the rename, as measured.
    folder: ?FolderInfo = null,
    /// RFC 3339.
    create_time: ?[]const u8 = null,
    update_time: ?[]const u8 = null,
    end_time: ?[]const u8 = null,

    pub const Failure = struct {
        /// A `google.rpc.Code`; `core.errors.fromRpcCode` maps it.
        code: i32,
        message: []const u8,
    };
};

pub const OperationPage = struct {
    operations: []const OperationInfo,
    /// Pass as `page_token` to get the next page. Null on the last page.
    next_page_token: ?[]const u8,
};

/// What `Bucket.update` changes. A field left at its default stays as it
/// is, and an update that changes nothing is refused.
pub const BucketUpdate = struct {
    versioning: ?bool = null,
    /// 0 turns soft delete off, else 604,800 to 7,776,000 seconds. What is
    /// already soft-deleted keeps the retention it was deleted under, and
    /// a deleted bucket is kept for the longest retention it ever had.
    soft_delete_retention_s: ?u32 = null,
    requester_pays: ?bool = null,
    /// `.clear`: objects written without a key of their own get Google's.
    default_kms_key_name: Change([]const u8) = .keep,
    labels: LabelEdit = .keep,
    /// Replaces every rule, as Cloud Storage keeps them as one list;
    /// `&.{}` removes them all. Changes can take 24 hours to act.
    lifecycle: ?[]const LifecycleRule = null,
    /// Once on for 90 days, it cannot be turned off.
    uniform_bucket_level_access: ?bool = null,
    public_access_prevention: ?PublicAccessPrevention = null,
    /// The class new objects get when they name none, such as "NEARLINE".
    storage_class: ?[]const u8 = null,
    /// `.set` gives the bucket a retention policy of that many seconds, 1
    /// to 3,155,760,000, or changes its period; `.clear` removes it. Every
    /// object, old and new, is kept for the period from its creation. A
    /// locked policy can only be lengthened.
    retention_period_s: Change(u64) = .keep,
    default_event_based_hold: ?bool = null,
    /// Replace the bucket's whole access control list, or its default
    /// object list, with a canned one. The project's owners keep OWNER on
    /// the bucket. Refused before sending in an update that turns uniform
    /// bucket-level access on; on a bucket that already has it, Cloud
    /// Storage refuses it (`error.UniformAccessEnabled`). A default object
    /// list change takes up to 30 seconds to reach new objects.
    predefined_acl: ?PredefinedBucketAcl = null,
    predefined_default_object_acl: ?PredefinedAcl = null,
    /// Change the bucket only while its metageneration is this: what makes
    /// the update safe to retry.
    if_metageneration_match: ?u64 = null,
    /// Change it only while its metageneration is not this. When it is,
    /// the answer is `error.NotModified` and nothing changes.
    if_metageneration_not_match: ?u64 = null,
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

/// A folder in a hierarchical-namespace bucket, as `Folder.create`, `get`
/// and `Bucket.listFolders` return it. Folders have no etag and no
/// generation: the metageneration is the only precondition handle.
pub const FolderInfo = struct {
    /// The full path with its trailing slash, such as `a/b/`.
    name: []const u8,
    bucket: []const u8,
    /// What `ifMetagenerationMatch` conditions compare. A rename keeps it,
    /// and the create time, as measured.
    metageneration: u64,
    /// RFC 3339, as sent by the server: `createTime`, not the
    /// `timeCreated` objects carry. An implicit folder's is its first
    /// object's write; a renamed folder keeps its own.
    create_time: []const u8 = "",
    update_time: []const u8 = "",
    /// The rename this folder is part of, while one is running: every
    /// write under it answers a retryable 429 until the operation ends.
    pending_rename_operation_id: ?[]const u8 = null,
};

pub const FolderPage = struct {
    folders: []const FolderInfo,
    /// Pass as `page_token` to get the next page. Null on the last page.
    next_page_token: ?[]const u8,
};

/// What `Bucket.listFolders` lists. Unlike object listing, a folders list
/// has no `prefixes` side: folders come back in `folders` either way.
pub const FolderListOptions = struct {
    /// Only folders whose paths begin with this. Cloud Storage requires it
    /// to end with `/`, so anything else is refused before sending.
    prefix: ?[]const u8 = null,
    /// The prefix folder itself and the folders one level below it, rather
    /// than the whole subtree: the `/` delimiter, the only one the server
    /// takes.
    directory_mode: bool = false,
    /// Lexicographic bounds on the paths: start included, end excluded.
    start_offset: ?[]const u8 = null,
    end_offset: ?[]const u8 = null,
    /// Results per page, at most 1,000. 0 lets the server choose.
    page_size: u32 = 0,
    /// `next_page_token` from the previous page; null for the first page.
    page_token: ?[]const u8 = null,
};

/// A managed folder: a prefix that carries an IAM policy of its own, on
/// any bucket with uniform bucket-level access. The policies add up: the
/// bucket's, then each enclosing managed folder's.
pub const ManagedFolderInfo = struct {
    /// The full path with its trailing slash, such as `teams/data/`.
    name: []const u8,
    bucket: []const u8,
    /// What `ifMetagenerationMatch` conditions compare. The IAM policy's
    /// etag is its own and does NOT move with the bucket, unlike a
    /// bucket's, as measured on 2026-10-02.
    metageneration: u64,
    /// RFC 3339, as sent by the server.
    create_time: []const u8 = "",
    update_time: []const u8 = "",
};

pub const ManagedFolderPage = struct {
    managed_folders: []const ManagedFolderInfo,
    /// Pass as `page_token` to get the next page. Null on the last page.
    next_page_token: ?[]const u8,
};

/// What `Bucket.listManagedFolders` lists: no delimiter and no offsets,
/// unlike folders.
pub const ManagedFolderListOptions = struct {
    /// Only managed folders whose paths begin with this.
    prefix: ?[]const u8 = null,
    /// Results per page. 0 lets the server choose.
    page_size: u32 = 0,
    /// `next_page_token` from the previous page; null for the first page.
    page_token: ?[]const u8 = null,
};

/// How a bucket stores names, from `Bucket.storageLayout`: the one bucket
/// read `storage.objects.list` permission is enough for, which is how a
/// caller without bucket metadata access asks "is this bucket
/// hierarchical?".
pub const StorageLayout = struct {
    location: []const u8,
    /// Such as "region", "dual-region" or "multi-region".
    location_type: []const u8,
    /// Folders are real resources here. Cloud Storage leaves the field out
    /// for a flat bucket; fake-gcs-server sends false for every bucket.
    hierarchical_namespace: bool = false,
};

/// The request a signed URL allows. A signed POST can only start a
/// resumable upload, with the header `x-goog-resumable: start`; the
/// session URI it answers with then takes the bytes with no signature.
/// One custom attribute of a notification configuration, which Cloud
/// Storage puts on every message it publishes for it.
pub const Attribute = struct {
    key: []const u8,
    value: []const u8,
};

/// A Pub/Sub topic, as a notification configuration names it.
pub const TopicName = struct {
    /// A project ID, or a project number, which Cloud Storage keeps as a
    /// number.
    project: []const u8,
    /// The topic's ID within the project.
    topic: []const u8,
};

/// What a notification's message carries besides its attributes.
pub const PayloadFormat = enum {
    /// The object's metadata, as the JSON API gives it: `JSON_API_V1`.
    json,
    /// Nothing but the attributes: `NONE`.
    none,
    /// A format this library does not know, as read back. Never sent.
    unknown,
};

/// A change to an object that Cloud Storage can publish, as measured on
/// 2026-10-01.
pub const EventType = enum {
    /// An object, or a new generation of one, came to be: an upload of any
    /// kind, a compose, a copy, a restore, the destination of a move.
    finalize,
    /// The metadata of a generation changed: any patch, holds included,
    /// even one that sets what was there.
    metadata_update,
    /// A generation went, for good or into soft delete: a delete, an
    /// overwrite in a bucket without versioning, the source of a move.
    delete,
    /// A live generation became noncurrent, in a bucket with versioning:
    /// a delete or an overwrite.
    archive,
    /// An object began to be written, in a zonal bucket.
    initialize,
    /// A type this library does not know, as read back. Never sent.
    unknown,
};

/// What `Bucket.createNotification` creates.
pub const NotificationConfig = struct {
    topic: TopicName,
    payload: PayloadFormat = .json,
    /// Null publishes every type. Neither empty, which Cloud Storage would
    /// also read as every type, nor repeated.
    events: ?[]const EventType = null,
    /// At most 5: keys of 1 to 256 bytes and values of up to 1,024, no key
    /// twice, none named like an attribute every message carries, which
    /// Cloud Storage would silently override, and none beginning with
    /// goog, in any case, which would keep every message from arriving.
    custom_attributes: []const Attribute = &.{},
    /// Only objects whose names begin with these bytes, case and all. An
    /// empty one is the same as none.
    object_name_prefix: ?[]const u8 = null,
};

/// A notification configuration, as Cloud Storage keeps it.
pub const Notification = struct {
    /// What `Bucket.getNotification` and `Bucket.deleteNotification` take.
    /// Never reused within the bucket.
    id: []const u8,
    /// As Cloud Storage gives it: `//pubsub.googleapis.com/projects/P/topics/T`.
    topic: []const u8,
    /// `topic` taken apart, or null when it has another form.
    topic_name: ?TopicName,
    payload: PayloadFormat,
    /// Empty for every type.
    events: []const EventType,
    custom_attributes: []const Attribute,
    object_name_prefix: ?[]const u8,
    etag: ?[]const u8,
};

/// One change Cloud Storage published about one object, as `decodeEvent`
/// reads it from a Pub/Sub message.
pub const ObjectEvent = struct {
    kind: EventType,
    bucket: []const u8,
    /// The object's name, as it is: Cloud Storage escapes nothing in it.
    object: []const u8,
    /// The generation the change concerns: the new one of a finalize, the
    /// one that went of a delete or an archive.
    generation: u64,
    /// When it happened, RFC 3339, as Cloud Storage sent it.
    time: []const u8,
    /// The configuration that published it, or null where an emulator
    /// leaves that out.
    config: ?ConfigRef,
    /// A finalize that replaced a live generation: the one it replaced.
    overwrote_generation: ?u64,
    /// A delete or archive of a generation that another replaced: that one.
    overwritten_by_generation: ?u64,
    payload: PayloadFormat,
    /// With a `.json` payload, the object's metadata: as it now is, or as it
    /// was before a delete. Cloud Storage leaves out its ACLs.
    info: ?ObjectInfo,
    /// The configuration's own attributes: every attribute that is not one
    /// Cloud Storage puts on its messages.
    custom_attributes: []const Attribute,
    /// The change's identity, for telling a repeat delivery apart from a
    /// new change: Cloud Storage publishes at least once and Pub/Sub
    /// delivers at least once, each repeat under a new message ID. Built
    /// from the event type, bucket, object and generation, and for a
    /// metadata update the metageneration, or without a payload the time.
    key: []const u8,

    pub const ConfigRef = struct {
        bucket: []const u8,
        id: []const u8,
    };
};

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

/// A customer-supplied AES-256 key. Cloud Storage encrypts an object with
/// it and keeps only its SHA-256, so the object cannot be read, copied or
/// composed without it, and an object whose key is lost is lost with it.
/// `Object.withEncryptionKey` hands one to a handle, which borrows it: the
/// caller keeps it alive while any handle does, and wipes it when done.
pub const EncryptionKey = struct {
    bytes: [32]u8,

    /// The 44-character base64 form that gcloud, the console and Google's
    /// libraries use. Anything else, whitespace included, is
    /// `error.InvalidEncryptionKey`. The text is the caller's to wipe.
    pub fn fromBase64(text: []const u8) error{InvalidEncryptionKey}!EncryptionKey {
        // 32 bytes are exactly 44 characters, padding included.
        const decoder = std.base64.standard.Decoder;
        const len = decoder.calcSizeForSlice(text) catch return error.InvalidEncryptionKey;
        if (len != 32) return error.InvalidEncryptionKey;
        var key: EncryptionKey = .{ .bytes = undefined };
        // The copy returned is the only one left.
        defer key.wipe();
        decoder.decode(&key.bytes, text) catch return error.InvalidEncryptionKey;
        return key;
    }

    /// What Cloud Storage reports as the object's `keySha256`, and
    /// `ObjectInfo.encryption_key_sha256` holds.
    pub fn sha256(self: *const EncryptionKey) [32]u8 {
        const Sha256 = std.crypto.hash.sha2.Sha256;
        var hasher: Sha256 = .init(.{});
        // The hasher's buffer holds the key until it is wiped.
        defer std.crypto.secureZero(u8, std.mem.asBytes(&hasher));
        hasher.update(&self.bytes);
        return hasher.finalResult();
    }

    pub fn wipe(self: *EncryptionKey) void {
        std.crypto.secureZero(u8, &self.bytes);
    }

    /// Writes the base64 of the key's SHA-256, never the key.
    pub fn format(self: *const EncryptionKey, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var text: [44]u8 = undefined;
        try w.writeAll(std.base64.standard.Encoder.encode(&text, &self.sha256()));
    }
};

const testing = std.testing;

test "EncryptionKey: the base64 form in, the SHA-256 out, and nothing else" {
    var key: EncryptionKey = try .fromBase64("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=");
    for (key.bytes, 0..) |b, i| try testing.expectEqual(@as(u8, @intCast(i)), b);
    // Computed with Python's hashlib.
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, "630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd");
    try testing.expectEqualSlices(u8, &want, &key.sha256());

    var buf: [64]u8 = undefined;
    const shown = try std.fmt.bufPrint(&buf, "{f}", .{&key});
    try testing.expectEqualStrings("Yw3NKWbEM2aRElRIu7JbT/QSpJxzLbLIq8G4WBvXEN0=", shown);

    key.wipe();
    try testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &key.bytes);

    for ([_][]const u8{
        "",
        // 31 bytes, and 33.
        "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHg==",
        "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8g",
        // No padding, or whitespace around it.
        "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
        " AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
        "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=\n",
        // URL-safe letters, and a non-canonical last digit.
        "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwd_h8=",
        "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh9=",
    }) |bad| {
        errdefer std.debug.print("accepted {s}\n", .{bad});
        try testing.expectError(error.InvalidEncryptionKey, EncryptionKey.fromBase64(bad));
    }
}

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
