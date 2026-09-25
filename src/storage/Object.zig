//! A cheap handle on one object: metadata, existence, deletion, uploads
//! from memory or any reader, downloads that stream into any writer with
//! ranges and mid-body resume, server-side copies, and generation
//! preconditions on all of it, checksummed in both directions. Making one
//! sends nothing.

const Object = @This();

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const compose_impl = @import("compose.zig");
const copy_impl = @import("copy.zig");
const dl = @import("download.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const metadata = @import("metadata.zig");
const multipart = @import("multipart.zig");
const names = @import("names.zig");
const parallel = @import("parallel.zig");
const parallel_download = @import("parallel_download.zig");
const post_policy = @import("post_policy.zig");
const resumable = @import("resumable.zig");
const rpc = @import("rpc.zig");
const signing = @import("signing.zig");
const types = @import("types.zig");
const upload_file = @import("upload_file.zig");
const validate = @import("validate.zig");
const Error = errors.Error;

/// Borrowed; the handle must not outlive it.
client: *Client,
/// Borrowed; the handle must not outlive it.
bucket: []const u8,
/// Borrowed; the handle must not outlive it.
name: []const u8,

/// The object's metadata: the live generation, or the one `options` names.
pub fn get(self: Object, options: types.GetOptions) Error!types.Owned(types.ObjectInfo) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.bucket);
    try rpc.checkObjectName(self.client, self.name);
    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    const path = try names.objectPath(scratch.allocator(), self.bucket, self.name, options.generation, options.preconditions);

    var result: types.Owned(types.ObjectInfo) = try .init(self.client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(self.client, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeObject(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(self.client, err, "object");
    return result;
}

/// A V4 signed URL: whoever holds it can make the one request it describes
/// on this object until it expires, with no credentials of their own, as a
/// browser downloading a private file or uploading straight into the
/// bucket does. `signer` signs as a service account, which must itself be
/// allowed to make the request. Nothing is sent to Cloud Storage; a signer
/// that signs through IAM makes one call there.
///
/// The URL points at the client's endpoint, or at `options.style`'s host.
/// It is a bearer credential until it expires, so it is never logged.
pub fn signedUrl(self: Object, signer: core.Signer, options: types.SignedUrlOptions) Error!types.Owned([]const u8) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.bucket);
    try rpc.checkObjectName(self.client, self.name);
    return signing.signUrl(self.client, signer, self.bucket, self.name, options);
}

/// A V4 POST policy that stores this object: what a plain HTML form may
/// upload, stated in advance and signed, for a browser that cannot send
/// the headers a signed PUT pins. The policy names this object exactly, so
/// the form stores that name and no other; `Bucket.postPolicy` is the one
/// that allows a prefix. Everything else is as `signedUrl` says: `signer`
/// signs as a service account, which must itself be allowed to write, and
/// nothing is sent to Cloud Storage.
///
/// The returned fields are the form's hidden inputs. The form must also
/// send `file`, last, holding the bytes. The fields are a bearer
/// credential together until they expire, so they are never logged.
pub fn postPolicy(self: Object, signer: core.Signer, options: types.PostPolicyOptions) Error!types.Owned(types.PostPolicy) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.bucket);
    try rpc.checkObjectName(self.client, self.name);
    if (options.key != null) {
        if (self.client.diagnostics) |d| d.print("this object's name is the policy's key; only Bucket.postPolicy takes one", .{});
        return error.InvalidPostPolicyOptions;
    }
    return post_policy.signPolicy(self.client, signer, self.bucket, .{ .exact = self.name }, options);
}

/// Writes this object from `sources`, in order, without moving any bytes:
/// 1 to 32 objects in this bucket, which may include this one, so an
/// append is a compose whose first source is the destination. Every source
/// must share a storage class with the rest.
///
/// Nothing is inherited. The composite's metadata is what `options` says,
/// and an unset content type becomes the default. The result has no MD5,
/// which no composite has, and a CRC32C that Cloud Storage derives from
/// its components', so `download` verifies it as it verifies anything.
pub fn composeFrom(
    self: Object,
    sources: []const types.ComposeSource,
    options: types.ComposeOptions,
) Error!types.Owned(types.ObjectInfo) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.bucket);
    try rpc.checkObjectName(self.client, self.name);
    return compose_impl.compose(self.client, self.bucket, self.name, sources, options);
}

/// Changes what this object says about itself, leaving its bytes and its
/// generation where they are, and answers the object as it now stands.
/// Every field the options leave null keeps the value it had, and
/// `options.edit` says what becomes of the custom metadata: keep it, set
/// and remove the keys it names, or clear the lot.
///
/// A patch bumps the metageneration, so `if_metageneration_match` is what
/// makes one safe to repeat: a `generation` condition says nothing here,
/// since the generation does not move.
pub fn updateMetadata(self: Object, options: types.MetadataUpdate) Error!types.Owned(types.ObjectInfo) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.bucket);
    try rpc.checkObjectName(self.client, self.name);
    return metadata.update(self.client, self.bucket, self.name, options);
}

/// Sugar over `get`: whether a live object has this name. `NotFound`
/// becomes false; every other failure stays an error.
pub fn exists(self: Object) Error!bool {
    var info = self.get(.{}) catch |err| switch (err) {
        error.NotFound => return false,
        else => |e| return e,
    };
    info.deinit();
    return true;
}

/// Deletes the object: the live generation, or the one `options` names.
/// Without a `generation` the delete is not retried, unless
/// `retry_unconditional_writes` opted in: the first attempt may have
/// succeeded before the connection dropped, and a blind repeat could then
/// remove someone else's newer object.
pub fn delete(self: Object, options: types.DeleteOptions) Error!void {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.bucket);
    try rpc.checkObjectName(self.client, self.name);
    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    const path = try names.objectPath(scratch.allocator(), self.bucket, self.name, options.generation, options.preconditions);
    try rpc.executeDiscard(self.client, .{
        .method = .DELETE,
        .path = path,
        .retry = options.generation != null or
            options.preconditions.makesWriteSafe() or
            self.client.retry_unconditional_writes,
    });
}

/// Uploads bytes already in memory. At or below `single_request_limit` the
/// whole thing is one `multipart/related` request; above it, the resumable
/// protocol sends chunks sliced straight from `data`. Either way the
/// metadata carries the data's CRC-32C, which the server verifies before
/// the object exists, and the data is never copied. Peak extra memory: a
/// few kilobytes of framing.
///
/// A multipart upload is not retried unless `retry_unconditional_writes`
/// opted in: the first attempt may have landed before its response was
/// lost, and a blind repeat would overwrite whatever is there by then. A
/// resumable upload always retries: its offsets make a repeat safe, and a
/// lost session simply starts over from the same bytes.
pub fn upload(self: Object, data: []const u8, options: types.UploadOptions) Error!types.Owned(types.ObjectInfo) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.bucket);
    try rpc.checkObjectName(self.client, self.name);
    try checkUploadOptions(self.client, options);
    try refuseCheckpoint(self.client, options);
    if (options.size) |size| if (size != data.len) {
        if (self.client.diagnostics) |d| d.print("options.size says {d} bytes, the data has {d}", .{ size, data.len });
        return error.InvalidArgument;
    };

    var checksum: ?[8]u8 = null;
    if (self.client.verify_checksums) {
        const computed = core.crc32c.hash(data);
        if (options.crc32c) |given| if (given != computed) {
            if (self.client.diagnostics) |d| d.print(
                "checksum mismatch before sending: the data hashes to {d}, options.crc32c says {d}",
                .{ computed, given },
            );
            return error.ChecksumMismatch;
        };
        checksum = core.crc32c.toBase64(computed);
    } else if (options.crc32c) |given| {
        // Verification is off, but a checksum the caller asserts still
        // travels, for the server to check.
        checksum = core.crc32c.toBase64(given);
    }

    if (data.len > self.client.single_request_limit) {
        return resumable.run(self.client, self.bucket, self.name, .{ .slice = data }, options, checksum);
    }

    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    const path = try names.uploadMultipartPath(scratch.allocator(), self.bucket, options.preconditions);
    const parts = try multipart.build(scratch.allocator(), self.client.io, self.name, options, checksum);

    var result: types.Owned(types.ObjectInfo) = try .init(self.client.gpa);
    errdefer result.deinit();
    const res = rpc.executeStream(self.client, result.arena, .{
        .method = .POST,
        .path = path,
        .content_type = parts.content_type,
        .body = .{ .segments = &.{ parts.opening, data, parts.closing } },
        .retry = options.preconditions.makesWriteSafe() or self.client.retry_unconditional_writes,
    }) catch |err| switch (err) {
        // The sink is a buffer; there is no caller writer to fail.
        error.WriteFailed => unreachable,
        error.FailedPrecondition => return rpc.ambiguous412(
            self.client,
            options.preconditions.makesWriteSafe() or self.client.retry_unconditional_writes,
        ),
        else => |e| return e,
    };
    result.value = codec.decodeObject(result.arena.allocator(), res.body) catch |err|
        return rpc.decodeFailed(self.client, err, "object");
    return result;
}

/// Uploads from a stream through the resumable protocol, one `chunk_size`
/// buffer of memory: the current chunk stays there until the server
/// confirms it, so a resume never needs the reader to go backwards.
///
/// With `options.crc32c` the server verifies the checksum; without it the
/// bytes are hashed as they stream and compared with the finished object's
/// checksum, and on a mismatch the object is deleted again, pinned to the
/// generation just created, before `error.ChecksumMismatch` comes back. A
/// lost session is `error.UploadSessionLost`: the earlier bytes are gone
/// and the reader cannot supply them again, so the caller reopens the
/// source and retries.
pub fn uploadFrom(self: Object, reader: *std.Io.Reader, options: types.UploadOptions) Error!types.Owned(types.ObjectInfo) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.bucket);
    try rpc.checkObjectName(self.client, self.name);
    try checkUploadOptions(self.client, options);
    try refuseCheckpoint(self.client, options);

    const checksum: ?[8]u8 = if (options.crc32c) |given| core.crc32c.toBase64(given) else null;
    const buffer = try self.client.gpa.alloc(u8, self.client.chunk_size);
    defer self.client.gpa.free(buffer);
    var hasher: core.crc32c.Hasher = .init();
    const verify_after = self.client.verify_checksums and options.crc32c == null;

    var result = try resumable.run(self.client, self.bucket, self.name, .{ .reader = .{
        .r = reader,
        .buffer = buffer,
        .declared = options.size,
        .hasher = if (verify_after) &hasher else null,
    } }, options, checksum);
    if (!verify_after) return result;
    errdefer result.deinit();

    // The object exists by the time the checksum can be compared. On a
    // mismatch it is deleted again, pinned to the generation just created,
    // so nobody else's newer object can be removed.
    const expected = result.value.crc32c orelse {
        logging.warn("upload of {s} finished, but the server named no crc32c to verify against", .{self.name});
        return result;
    };
    const streamed = hasher.final();
    if (streamed == expected) return result;
    self.delete(.{ .generation = result.value.generation }) catch |err| {
        logging.warn("deleting the mismatched upload of {s} failed with {t}", .{ self.name, err });
    };
    // After the delete, whose own begin cleared the diagnostics.
    if (self.client.diagnostics) |d| d.print(
        "checksum mismatch after upload: the stream hashed to {d}, the object stores {d}; the object was deleted again",
        .{ streamed, expected },
    );
    return error.ChecksumMismatch;
}

/// Uploads `source` as this object in parts sent `options.concurrency` at
/// a time, each on a client and connection of its own, and has Cloud
/// Storage join them: the XML API's multipart upload. For large objects on
/// fast links, where one connection is the limit.
///
/// Every part is checked against the checksum Cloud Storage stored for it,
/// and the parts' checksums combine into the whole object's, which must
/// match `options.crc32c` before anything is joined, and the joined object
/// afterwards. On any failure the upload is aborted, so no part is left
/// behind to be billed; a process that dies mid-upload leaves its parts
/// until the bucket's `AbortIncompleteMultipartUpload` lifecycle rule runs.
///
/// Without `options.preconditions` it replaces whatever has the name, as
/// the multipart upload always does, and the result is read back with one
/// metadata request, which needs `storage.objects.get`. With them, the
/// object is read under them first, so a condition that already fails
/// refuses the upload before a byte is sent; the upload finishes under a
/// temporary name, `zig-gcp-tmp/` and random hex digits; and
/// `objects.move` renames it into place only if the conditions still
/// hold, which answers with the result. A refused move, or any failure
/// after the finish, deletes the temporary object again; a process that
/// dies in between leaves it for a lifecycle rule on the prefix. The move
/// needs `storage.objects.move`, which Storage Object User grants and
/// Storage Object Creator does not.
///
/// Retries never write twice, so it retries as a resumable upload does,
/// always. Against an emulator, which has no multipart uploads, the object
/// goes up as one ordinary upload, with the conditions applied to it.
pub fn uploadParallel(self: Object, source: types.ParallelSource, options: types.ParallelUploadOptions) Error!types.Owned(types.ObjectInfo) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.bucket);
    try rpc.checkObjectName(self.client, self.name);
    return parallel.upload(self.client, self.bucket, self.name, source, options);
}

/// Server-side copy to `dest`, looping over rewrite calls until the
/// service reports done; the caller never sees a rewrite token. The copy
/// runs on this object's client, `dest` only naming the destination.
///
/// With no change in `options`, the copy carries the source's metadata as
/// it is. A change, a storage class included, first reads the source and
/// sends its metadata back with the change applied, pinned to the
/// generation and metageneration it read, so a copy never mixes two
/// versions: Cloud Storage takes any metadata a copy sends as the whole of
/// the copy's, and a copy that sent only the change would lose everything
/// else. Copying an object onto itself with a new `storage_class` is how a
/// class changes on demand. ACLs, holds and retention are never copied.
///
/// The first call is retried only when the destination carries
/// `if_generation_match`, or the client opted into unconditional retries;
/// follow-up calls hold a rewrite token, which makes them safe anyway.
pub fn copyTo(self: Object, dest: Object, options: types.CopyOptions) Error!types.Owned(types.ObjectInfo) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.bucket);
    try rpc.checkObjectName(self.client, self.name);
    try rpc.checkBucketName(self.client, dest.bucket);
    try rpc.checkObjectName(self.client, dest.name);
    return copy_impl.copy(self.client, self.bucket, self.name, dest.bucket, dest.name, options);
}

/// Uploads the file through the resumable protocol, reading it at offsets
/// in `chunk_size` chunks, one buffer of memory: `uploadFrom` for a file.
/// The request that finishes the upload carries the whole file's CRC32C,
/// which Cloud Storage checks before the object ever exists, so there is
/// no read back and no delete afterwards. The file must not change until
/// the call returns; its size comes from the file itself, so
/// `options.size` must stay null. A lost session starts over from the
/// file, bounded like a retry.
///
/// With `options.checkpoint`, an upload a process left unfinished carries
/// on in a later one: the session is asked where it stands, the file's
/// first bytes are re-read to rebuild the running checksum, which the
/// finishing request still spans whole, and sending continues from there.
/// A session that expired, or a file that changed, starts over. The state
/// holds the session URL, which is a credential: `storage.CheckpointFile`
/// keeps it readable by its owner only, and a custom store should guard
/// it as it guards credentials. It is also what a Storage Object Creator
/// role, which cannot read objects back, can resume.
pub fn uploadFile(self: Object, file: std.Io.File, options: types.UploadOptions) Error!types.Owned(types.ObjectInfo) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.bucket);
    try rpc.checkObjectName(self.client, self.name);
    try checkUploadOptions(self.client, options);
    if (options.size != null) {
        if (self.client.diagnostics) |d| d.print("uploadFile takes its size from the file; leave options.size null", .{});
        return error.InvalidArgument;
    }
    return upload_file.upload(self.client, self.bucket, self.name, file, options);
}

/// Only `uploadFile` and the parallel calls resume: memory and streams do
/// not outlive a process.
fn refuseCheckpoint(client: *Client, options: types.UploadOptions) Error!void {
    if (options.checkpoint == null) return;
    if (client.diagnostics) |d| d.print("a checkpoint needs a source a later process can read again: uploadFile takes one, memory and streams cannot", .{});
    return error.InvalidArgument;
}

fn checkUploadOptions(client: *Client, options: types.UploadOptions) Error!void {
    // The content type becomes a header line inside the multipart body.
    if (!core.transport.isValidHeaderValue(options.content_type)) {
        if (client.diagnostics) |d| d.print("invalid content type: expected a header value", .{});
        return error.InvalidArgument;
    }
    // An empty key was already refused here; a repeated one was not, and
    // made a body carrying two entries of one name.
    if (validate.metadataFault(options.metadata)) |fault| {
        if (client.diagnostics) |d| {
            if (fault.repeated) {
                d.print("invalid metadata: key {s} appears twice; one object gives a key one value", .{options.metadata[fault.index].key});
            } else {
                d.print("invalid metadata: keys must not be empty", .{});
            }
        }
        return error.InvalidArgument;
    }
}

/// Streams the object into `writer`, hashing the bytes as they pass and
/// comparing the result with the checksum the server sent beside them. The
/// writer is never flushed here: its buffer belongs to the caller.
///
/// A transient failure mid-body resumes where the bytes stopped, pinned to
/// the generation the first response named, so an overwrite in between
/// fails cleanly with `error.NotFound` instead of splicing two objects. The
/// attempt counter resets whenever a request delivers bytes, so a flaky
/// link that keeps making progress never runs out of attempts. Validation
/// still covers the whole object across resumes; it is skipped, with
/// `checksum_verified = false`, for a `range` read and for an object
/// decompressed in transit, which also cannot resume.
///
/// On `error.ChecksumMismatch` the bytes are already in the writer and must
/// be discarded.
pub fn download(self: Object, writer: *std.Io.Writer, options: types.DownloadOptions) Error!types.DownloadResult {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.bucket);
    try rpc.checkObjectName(self.client, self.name);
    const range_end: ?u64 = if (options.range) |r| e: {
        const len = r.length orelse break :e null;
        const past_end = std.math.add(u64, r.offset, len) catch 0;
        if (len == 0 or past_end == 0) {
            if (self.client.diagnostics) |d| d.print("invalid range: length must be at least 1, and the range must fit in 64 bits", .{});
            return error.InvalidArgument;
        }
        break :e past_end - 1;
    } else null;
    const base_offset: u64 = if (options.range) |r| r.offset else 0;

    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    var response: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer response.deinit();

    // Everything the transport delivers is hashed and counted on its way
    // to the caller, unbuffered, so the count is the resume offset and the
    // hash spans resumes.
    var counting: core.CountingWriter = .init(writer);
    var hashing: std.Io.Writer.Hashed(core.crc32c.Hasher) = .initHasher(&counting.writer, .init(), &.{});

    var generation: ?u64 = options.generation;
    var transcoded: ?bool = null;
    // The checksum named by the response the writer's bytes began with. A
    // resume is a range read, and production names no checksum on a range
    // short of the whole object, so a resumed download is checked against
    // this. A request from byte 0 starts the bytes over, and replaces it.
    var whole_crc: ?u32 = null;
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        const delivered = counting.count;
        const start = base_offset + delivered;
        const resuming = delivered > 0;
        const wants_partial = options.range != null or resuming;
        const path = try names.objectMediaPath(scratch.allocator(), self.bucket, self.name, generation, options.preconditions);
        var range_buf: [64]u8 = undefined;
        var header_storage: [1]core.transport.Header = undefined;
        var headers: []const core.transport.Header = &.{};
        if (wants_partial) {
            header_storage[0] = .{ .name = "Range", .value = dl.formatRange(&range_buf, start, range_end) };
            headers = header_storage[0..1];
        }

        var head: ?core.transport.StreamRequest.Head = null;
        const outcome = rpc.executeStream(self.client, &response, .{
            .method = .GET,
            .path = path,
            .headers = headers,
            .sink = .{ .writer = &hashing.writer },
            // Resuming is this loop's business: the engine must never
            // repeat a request whose bytes it cannot take back.
            .retry = false,
            .head_out = &head,
        });
        // The first head names what is being read, whether or not its body
        // survived.
        if (head) |h| if (h.status < 300) {
            if (generation == null) if (h.header("x-goog-generation")) |text| {
                generation = std.fmt.parseInt(u64, text, 10) catch null;
            };
            if (transcoded == null) transcoded = dl.isTranscoded(h);
            if (!wants_partial) {
                whole_crc = if (h.header("x-goog-hash")) |value| dl.crc32cFromHashHeader(value) else null;
            }
        };

        const err: Error = if (outcome) |res| {
            return self.finishStream(res, options, wants_partial, start, generation, transcoded orelse false, whole_crc, &counting, &hashing);
        } else |err| switch (err) {
            // The caller's writer failed; whatever it holds is theirs to
            // discard.
            error.WriteFailed => return error.WriteFailed,
            else => |e| e,
        };

        // A 416 for a range starting at 0 is how an empty object answers:
        // that is the whole object, not a failure.
        if (err == error.OutOfRange and base_offset == 0 and options.range != null and counting.count == 0) {
            if (self.client.diagnostics) |d| d.clear();
            return .{ .bytes_written = 0, .generation = generation orelse 0, .checksum_verified = false, .crc32c = hashing.hasher.final() };
        }

        // The attempt counter resets on progress: only a link that
        // delivers nothing runs the attempts down.
        if (counting.count > delivered) attempt = 0;
        if (!core.isRetryable(err) or attempt >= self.client.retry.max_attempts) return err;
        if (counting.count > 0) {
            if (transcoded orelse false) {
                if (self.client.diagnostics) |d| d.print("a transcoded download cannot resume: offsets in the decompressed stream mean nothing to the server", .{});
                return err;
            }
            if (generation == null) {
                if (self.client.diagnostics) |d| d.print("cannot resume: the server named no generation to pin the remainder to", .{});
                return err;
            }
        }
        const delay_ms = rpc.backoffMs(self.client, attempt);
        logging.warn("GET {s} (alt=media) failed with {t}; resuming at byte {d} in {d} ms", .{
            self.name, err, base_offset + counting.count, delay_ms,
        });
        try self.client.io.sleep(.fromMilliseconds(delay_ms), .awake);
    }
}

/// The end of a streamed body: confirm the server sent what was asked for,
/// then verify the checksum where one can apply. `whole_crc` is what the
/// response the bytes began with named, which a resumed download meets:
/// the generation is pinned, so it describes every byte, and the last
/// response, a range short of the whole object, names none.
fn finishStream(
    self: Object,
    res: core.transport.StreamResponse,
    options: types.DownloadOptions,
    wants_partial: bool,
    start: u64,
    generation: ?u64,
    transcoded: bool,
    whole_crc: ?u32,
    counting: *const core.CountingWriter,
    hashing: *std.Io.Writer.Hashed(core.crc32c.Hasher),
) Error!types.DownloadResult {
    if (wants_partial) {
        // A 200 to a Range request means the server ignored it and sent
        // the whole object from the start: not what the bytes claim to be.
        if (res.status != 206) {
            if (self.client.diagnostics) |d| d.print("the server ignored the range request and answered {d}", .{res.status});
            return error.InvalidResponse;
        }
        if (res.header("Content-Range")) |value| {
            if (dl.contentRangeStart(value)) |got| if (got != start) {
                if (self.client.diagnostics) |d| d.print("the range starts at byte {d}, not the requested {d}", .{ got, start });
                return error.InvalidResponse;
            };
        }
    }

    var verified = false;
    if (self.client.verify_checksums and options.range == null and !transcoded) {
        const named: ?u32 = if (res.header("x-goog-hash")) |value| dl.crc32cFromHashHeader(value) else null;
        if (whole_crc orelse named) |expected| {
            const got = hashing.hasher.final();
            if (got != expected) {
                if (self.client.diagnostics) |d| d.print(
                    "checksum mismatch: {d} bytes hash to {d}, the server said {d}; discard what the writer holds",
                    .{ counting.count, got, expected },
                );
                return error.ChecksumMismatch;
            }
            verified = true;
        }
        if (!verified) logging.warn("download of {s} carried no crc32c to verify against", .{self.name});
    }
    return .{
        .bytes_written = counting.count,
        .generation = generation orelse 0,
        .checksum_verified = verified,
        .crc32c = hashing.hasher.final(),
    };
}

/// Downloads this object in ranges fetched `options.concurrency` at a
/// time, each on a client and connection of its own. Every range is pinned
/// to the generation the opening metadata read names and written at its
/// offset, and the whole is verified by combining the ranges' CRC32Cs with
/// the object's. For large objects on fast links, where one connection is
/// the limit.
///
/// Each range is fetched with `download`, so it resumes where a dropped
/// connection or a timeout left it, and an overwrite partway through fails
/// with `error.NotFound` instead of splicing two objects. An empty object
/// is not read at all. An object stored gzip-compressed is fetched whole by
/// one worker, as `download` fetches it: decompressed and unverified, since
/// Cloud Storage ignores a range while it decompresses.
///
/// A file destination is set to exactly the object's length first. On any
/// failure the destination holds whatever arrived and must be discarded,
/// so write a file under a temporary name and rename it on success,
/// unless a checkpoint records what it holds.
///
/// With `options.checkpoint`, a download into a file that a process left
/// unfinished carries on in a later one: the checkpoint records each
/// written range, the resumed call re-reads those from the file, which
/// rebuilds their checksums and catches a file changed in between, and
/// only the rest is fetched, pinned to the same generation. The whole is
/// verified as always, and the checkpoint is cleared when the download
/// finishes, or when its bytes are discredited. `storage.CheckpointFile`
/// is the built-in store.
pub fn downloadParallel(self: Object, destination: types.ParallelDestination, options: types.ParallelDownloadOptions) Error!types.DownloadResult {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.bucket);
    try rpc.checkObjectName(self.client, self.name);
    return parallel_download.download(self.client, self.bucket, self.name, destination, options);
}

/// Downloads the whole object, or the `range` of it, into memory: at most
/// `max_bytes`, anything larger failing with `error.ObjectTooLarge`
/// without being held. Everything else is `download` with the library's
/// own buffer as the writer, resumes included.
pub fn downloadAlloc(self: Object, max_bytes: usize, options: types.DownloadOptions) Error!types.Owned(types.Downloaded) {
    var result: types.Owned(types.Downloaded) = try .init(self.client.gpa);
    errdefer result.deinit();
    var sink: dl.CappedAllocating = .init(result.arena.allocator(), max_bytes);
    const outcome = self.download(&sink.writer, options) catch |err| switch (err) {
        error.WriteFailed => {
            if (sink.out_of_memory) return error.OutOfMemory;
            if (self.client.diagnostics) |d| d.print("the object is larger than max_bytes ({d})", .{max_bytes});
            return error.ObjectTooLarge;
        },
        else => |e| return e,
    };
    result.value = .{ .data = sink.written(), .result = outcome };
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");

test "golden: get, a pinned generation, and delete" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"reports/2026/q3.txt\",\"bucket\":\"my-bucket\",\"size\":\"12\",\"generation\":\"7\"}" } },
        .{ .respond = .{ .body = "{\"name\":\"reports/2026/q3.txt\",\"generation\":\"6\"}" } },
        .{ .respond = .{ .status = 204, .body = "" } },
    }, .{});
    defer h.deinit();
    const obj = h.client.bucket("my-bucket").object("reports/2026/q3.txt");

    var live = try obj.get(.{});
    defer live.deinit();
    try h.expectRequest(
        0,
        .GET,
        "https://storage.googleapis.com/storage/v1/b/my-bucket/o/reports%2F2026%2Fq3.txt",
        null,
    );
    try testing.expectEqual(12, live.value.size);
    try testing.expectEqual(7, live.value.generation);

    var pinned = try obj.get(.{ .generation = 6 });
    defer pinned.deinit();
    try h.expectRequest(
        1,
        .GET,
        "https://storage.googleapis.com/storage/v1/b/my-bucket/o/reports%2F2026%2Fq3.txt?generation=6",
        null,
    );

    try obj.delete(.{ .generation = 7 });
    try h.expectRequest(
        2,
        .DELETE,
        "https://storage.googleapis.com/storage/v1/b/my-bucket/o/reports%2F2026%2Fq3.txt?generation=7",
        null,
    );
}

test "exists: found, missing, and a failure that is neither" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"a\"}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"errors\":[{\"reason\":\"notFound\"}]}}" } },
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"code\":403,\"errors\":[{\"reason\":\"forbidden\"}]}}" } },
    }, .{});
    defer h.deinit();
    const obj = h.client.bucket("my-bucket").object("a");
    try testing.expect(try obj.exists());
    try testing.expect(!try obj.exists());
    try testing.expectError(error.PermissionDenied, obj.exists());
}

test "delete retries only when it can do so safely" {
    var h: test_util.Harness = undefined;
    const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{
        .status = 503,
        .body = "{\"error\":{\"code\":503,\"errors\":[{\"reason\":\"backendError\"}]}}",
    } };
    try h.init(&.{
        // Without a generation: one attempt, no retry.
        unavailable,
        // With a generation: retried to success.
        unavailable,
        .{ .respond = .{ .status = 204, .body = "" } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();
    const obj = h.client.bucket("my-bucket").object("a");

    try testing.expectError(error.Unavailable, obj.delete(.{}));
    try h.expectRequestCount(1);
    try obj.delete(.{ .generation = 7 });
    try h.expectRequestCount(3);
}

test "delete without a generation retries when the client opted in" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .status = 204, .body = "" } },
    }, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1 }, .retry_unconditional_writes = true });
    defer h.deinit();
    try h.client.bucket("my-bucket").object("a").delete(.{});
    try h.expectRequestCount(2);
}

test "golden: upload sends one multipart request, checksum included" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body =
        \\{"name":"reports/2026/q3.txt","bucket":"my-bucket","size":"12",
        \\ "generation":"7","crc32c":"8P9ykg=="}
    } }}, .{});
    defer h.deinit();
    h.clock.random_byte = 0xab;
    const data = "hello world\n";

    var info = try h.client.bucket("my-bucket").object("reports/2026/q3.txt").upload(data, .{
        .content_type = "text/plain",
    });
    defer info.deinit();
    try testing.expectEqual(12, info.value.size);
    try testing.expectEqual(0xf0ff7292, info.value.crc32c.?);

    const sent = try h.fake.streamRequest(0);
    try testing.expectEqual(.POST, sent.method);
    try testing.expectEqualStrings(
        "https://storage.googleapis.com/upload/storage/v1/b/my-bucket/o?uploadType=multipart",
        sent.url,
    );
    try testing.expectEqualStrings("multipart/related; boundary=zig_gcp_abababababababab", sent.content_type.?);
    try testing.expectEqualStrings("ya29.test-token", sent.bearer.?);
    const expected_body = "--zig_gcp_abababababababab\r\n" ++
        "Content-Type: application/json; charset=UTF-8\r\n\r\n" ++
        "{\"name\":\"reports/2026/q3.txt\",\"contentType\":\"text/plain\",\"crc32c\":\"8P9ykg==\"}" ++
        "\r\n--zig_gcp_abababababababab\r\nContent-Type: text/plain\r\n\r\n" ++
        data ++
        "\r\n--zig_gcp_abababababababab--\r\n";
    try testing.expectEqualStrings(expected_body, sent.body_prefix);
    try testing.expectEqual(expected_body.len, sent.body_len);
}

test "upload: a wrong caller checksum fails before anything is sent" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{}" } }}, .{});
    defer h.deinit();
    const obj = h.client.bucket("my-bucket").object("a");
    try testing.expectError(error.ChecksumMismatch, obj.upload("hello world\n", .{ .crc32c = 1 }));
    try testing.expectEqual(0, h.fake.stream_requests.items.len);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "checksum mismatch") != null);

    // The right one is simply confirmed.
    var info = try obj.upload("hello world\n", .{ .crc32c = 0xf0ff7292 });
    info.deinit();
}

test "upload: verification off sends nothing computed, but forwards an asserted checksum" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ .{ .respond = .{ .body = "{}" } }, .{ .respond = .{ .body = "{}" } } }, .{
        .verify_checksums = false,
    });
    defer h.deinit();
    const obj = h.client.bucket("my-bucket").object("a");

    var plain = try obj.upload("data", .{});
    plain.deinit();
    try testing.expect(std.mem.indexOf(u8, (try h.fake.streamRequest(0)).body_prefix, "crc32c") == null);

    // An asserted checksum travels unchecked: the server is the verifier.
    var asserted = try obj.upload("data", .{ .crc32c = 1 });
    asserted.deinit();
    try testing.expect(std.mem.indexOf(u8, (try h.fake.streamRequest(1)).body_prefix, "\"crc32c\":\"AAAAAQ==\"") != null);
}

test "upload retries only when the client opted in" {
    const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 503, .body = "{}" } };
    var h: test_util.Harness = undefined;
    try h.init(&.{unavailable}, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();
    try testing.expectError(error.Unavailable, h.client.bucket("b").object("a").upload("data", .{}));
    try testing.expectEqual(1, h.fake.stream_requests.items.len);

    var opted: test_util.Harness = undefined;
    try opted.init(&.{ unavailable, .{ .respond = .{ .body = "{}" } } }, .{
        .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 },
        .retry_unconditional_writes = true,
    });
    defer opted.deinit();
    var info = try opted.client.bucket("b").object("a").upload("data", .{});
    info.deinit();
    try testing.expectEqual(2, opted.fake.stream_requests.items.len);
}

test "upload refuses options that cannot travel" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const obj = h.client.bucket("b").object("a");
    try testing.expectError(error.InvalidArgument, obj.upload("d", .{ .content_type = "text/plain\r\nX: y" }));
    try testing.expectError(error.InvalidArgument, obj.upload("d", .{ .metadata = &.{.{ .key = "", .value = "v" }} }));
    try testing.expectEqual(0, h.fake.stream_requests.items.len);
}

test "golden: downloadAlloc verifies the checksum and reads the headers" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{
        .body = "hello world\n",
        .headers = &.{
            .{ .name = "x-goog-hash", .value = "crc32c=8P9ykg==,md5=b1kCrCNwJL3QwXbLkwY9xA==" },
            .{ .name = "x-goog-generation", .value = "1758448800123456" },
        },
    } }}, .{});
    defer h.deinit();

    var got = try h.client.bucket("my-bucket").object("reports/2026/q3.txt").downloadAlloc(1024, .{});
    defer got.deinit();
    try testing.expectEqualStrings("hello world\n", got.value.data);
    try testing.expectEqual(12, got.value.result.bytes_written);
    try testing.expectEqual(1758448800123456, got.value.result.generation);
    try testing.expect(got.value.result.checksum_verified);
    try testing.expectEqual(0xf0ff7292, got.value.result.crc32c);

    const sent = try h.fake.streamRequest(0);
    try testing.expectEqual(.GET, sent.method);
    try testing.expectEqualStrings(
        "https://storage.googleapis.com/storage/v1/b/my-bucket/o/reports%2F2026%2Fq3.txt?alt=media",
        sent.url,
    );
    try testing.expectEqual(.writer, sent.sink);
}

test "downloadAlloc: a checksum mismatch discards the data" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{
        .body = "hello worls\n",
        .headers = &.{.{ .name = "x-goog-hash", .value = "crc32c=8P9ykg==" }},
    } }}, .{});
    defer h.deinit();
    try testing.expectError(
        error.ChecksumMismatch,
        h.client.bucket("b").object("a").downloadAlloc(1024, .{}),
    );
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "checksum mismatch") != null);
}

test "downloadAlloc: no checksum to check, or checking turned off, is not verified" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "hello world\n" } },
        // The transcoded case: the stored checksum covers compressed bytes
        // that are not what arrived, so even a header is not verifiable.
        .{ .respond = .{ .body = "hello world\n", .headers = &.{
            .{ .name = "x-goog-hash", .value = "crc32c=AAAAAQ==" },
            .{ .name = "x-goog-stored-content-encoding", .value = "gzip" },
        } } },
    }, .{});
    defer h.deinit();
    const obj = h.client.bucket("b").object("a");

    var bare = try obj.downloadAlloc(1024, .{});
    defer bare.deinit();
    try testing.expect(!bare.value.result.checksum_verified);
    try testing.expectEqual(0, bare.value.result.generation);

    var transcoded = try obj.downloadAlloc(1024, .{});
    defer transcoded.deinit();
    try testing.expect(!transcoded.value.result.checksum_verified);
    try testing.expectEqualStrings("hello world\n", transcoded.value.data);
    // Unverifiable, yet the checksum of what arrived is still reported.
    try testing.expectEqual(0xf0ff7292, transcoded.value.result.crc32c);
    try testing.expectEqual(0xf0ff7292, bare.value.result.crc32c);
}

test "downloadAlloc: an object above max_bytes is ObjectTooLarge" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "hello world\n" } }}, .{});
    defer h.deinit();
    try testing.expectError(
        error.ObjectTooLarge,
        h.client.bucket("b").object("a").downloadAlloc(11, .{}),
    );
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "larger than max_bytes") != null);

    // At the boundary it fits exactly.
    var at_cap: test_util.Harness = undefined;
    try at_cap.init(&.{.{ .respond = .{ .body = "hello world\n" } }}, .{});
    defer at_cap.deinit();
    var got = try at_cap.client.bucket("b").object("a").downloadAlloc(12, .{});
    defer got.deinit();
    try testing.expectEqualStrings("hello world\n", got.value.data);
}

test "downloadAlloc resumes after a cut connection and rides out a 503" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        // Five bytes arrive with the head, then the connection drops.
        .{ .respond = .{
            .body = "hello world\n",
            .headers = &.{
                .{ .name = "x-goog-generation", .value = "7" },
                .{ .name = "x-goog-hash", .value = "crc32c=8P9ykg==" },
            },
            .cut_after = 5,
        } },
        // The resume request runs into a 503, which touches no bytes.
        .{ .respond = .{ .status = 503, .body = "{}" } },
        // The retried resume delivers the rest, pinned to the generation.
        // Like production, it names no checksum: Cloud Storage sends
        // x-goog-hash on a range only when the range spans the whole object.
        .{ .respond = .{
            .status = 206,
            .body = " world\n",
            .headers = &.{.{ .name = "Content-Range", .value = "bytes 5-11/12" }},
        } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();

    var got = try h.client.bucket("b").object("a").downloadAlloc(1024, .{});
    defer got.deinit();
    // The two halves joined without duplication, and the first response's
    // checksum still covers the whole object.
    try testing.expectEqualStrings("hello world\n", got.value.data);
    try testing.expect(got.value.result.checksum_verified);
    try testing.expectEqual(12, got.value.result.bytes_written);
    try testing.expectEqual(7, got.value.result.generation);
    // Across the resume, the checksum spans both halves.
    try testing.expectEqual(0xf0ff7292, got.value.result.crc32c);
    try testing.expectEqual(3, h.fake.stream_requests.items.len);
    try testing.expectEqual(2, h.clock.sleep_count);

    // The first request asked for the live object, plainly.
    const first = try h.fake.streamRequest(0);
    try testing.expectEqualStrings("https://storage.googleapis.com/storage/v1/b/b/o/a?alt=media", first.url);
    try testing.expectEqual(null, first.header("Range"));
    // Both resume requests pinned the generation and asked for the rest.
    for (1..3) |i| {
        const resume_req = try h.fake.streamRequest(i);
        try testing.expectEqualStrings(
            "https://storage.googleapis.com/storage/v1/b/b/o/a?alt=media&generation=7",
            resume_req.url,
        );
        try testing.expectEqualStrings("bytes=5-", resume_req.header("Range").?);
    }
}

test "a resumed download is held to the first response's checksum" {
    // The first response names the whole object's checksum and is cut; the
    // resume names none, as production's never does. Bytes that do not
    // match the first response's checksum are caught all the same.
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{
            .body = "hello world\n",
            .headers = &.{
                .{ .name = "x-goog-generation", .value = "7" },
                .{ .name = "x-goog-hash", .value = "crc32c=AAAAAQ==,md5=b1kCrCNwJL3QwXbLkwY9xA==" },
            },
            .cut_after = 5,
        } },
        .{ .respond = .{
            .status = 206,
            .body = " world\n",
            .headers = &.{.{ .name = "Content-Range", .value = "bytes 5-11/12" }},
        } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();

    try testing.expectError(error.ChecksumMismatch, h.client.bucket("b").object("a").downloadAlloc(1024, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "checksum mismatch") != null);
    try testing.expectEqual(2, h.fake.stream_requests.items.len);
}

test "a download that starts over is held to the checksum it started over with" {
    // Cut before any byte arrived, with no generation named to pin a
    // retry to: the retry reads whatever is live from byte 0, here a newer
    // object, and its own checksum is the one that describes the bytes.
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{
            .body = "old contents",
            .headers = &.{.{ .name = "x-goog-hash", .value = "crc32c=AAAAAQ==" }},
            .cut_after = 0,
        } },
        .{ .respond = .{
            .body = "hello world\n",
            .headers = &.{.{ .name = "x-goog-hash", .value = "crc32c=8P9ykg==" }},
        } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();

    var got = try h.client.bucket("b").object("a").downloadAlloc(1024, .{});
    defer got.deinit();
    try testing.expectEqualStrings("hello world\n", got.value.data);
    try testing.expect(got.value.result.checksum_verified);
    // The retry asked for everything again, not for a range.
    try testing.expectEqual(null, (try h.fake.streamRequest(1)).header("Range"));
}

test "a resume that names the checksum again is checked against the first" {
    // An edge cache answers a range with the whole object's checksum; the
    // first response's still decides, and here they agree.
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{
            .body = "hello world\n",
            .headers = &.{
                .{ .name = "x-goog-generation", .value = "7" },
                .{ .name = "x-goog-hash", .value = "crc32c=8P9ykg==" },
            },
            .cut_after = 5,
        } },
        .{ .respond = .{
            .status = 206,
            .body = " world\n",
            .headers = &.{
                .{ .name = "Content-Range", .value = "bytes 5-11/12" },
                .{ .name = "x-goog-hash", .value = "crc32c=8P9ykg==,md5=b1kCrCNwJL3QwXbLkwY9xA==" },
            },
        } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();

    var got = try h.client.bucket("b").object("a").downloadAlloc(1024, .{});
    defer got.deinit();
    try testing.expectEqualStrings("hello world\n", got.value.data);
    try testing.expect(got.value.result.checksum_verified);
}

test "download streams into the caller's writer and verifies" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{
        .body = "hello world\n",
        .headers = &.{
            .{ .name = "x-goog-hash", .value = "crc32c=8P9ykg==" },
            .{ .name = "x-goog-generation", .value = "7" },
        },
    } }}, .{});
    defer h.deinit();
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const result = try h.client.bucket("b").object("a").download(&out, .{});
    try testing.expectEqualStrings("hello world\n", out.buffered());
    try testing.expectEqual(12, result.bytes_written);
    try testing.expectEqual(7, result.generation);
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(core.crc32c.hash("hello world\n"), result.crc32c);
    // Downloads ask for plain bytes, so the checksum can apply.
    try testing.expectEqual(.identity, (try h.fake.streamRequest(0)).accept_encoding);
}

test "download: a range is asked for exactly and never checksum-verified" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{
            .status = 206,
            .body = " worl",
            .headers = &.{
                .{ .name = "Content-Range", .value = "bytes 5-9/12" },
                .{ .name = "x-goog-hash", .value = "crc32c=8P9ykg==" },
            },
        } },
        .{ .respond = .{
            .status = 206,
            .body = " world\n",
            .headers = &.{.{ .name = "Content-Range", .value = "bytes 5-11/12" }},
        } },
    }, .{});
    defer h.deinit();
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const obj = h.client.bucket("b").object("a");

    const bounded = try obj.download(&out, .{ .range = .{ .offset = 5, .length = 5 } });
    try testing.expectEqualStrings(" worl", out.buffered());
    try testing.expectEqual(5, bounded.bytes_written);
    try testing.expect(!bounded.checksum_verified);
    // The range's own checksum, never the header's whole-object one.
    try testing.expectEqual(core.crc32c.hash(" worl"), bounded.crc32c);
    try testing.expectEqualStrings("bytes=5-9", (try h.fake.streamRequest(0)).header("Range").?);

    out = .fixed(&buf);
    const open_ended = try obj.download(&out, .{ .range = .{ .offset = 5 } });
    try testing.expectEqual(7, open_ended.bytes_written);
    try testing.expectEqualStrings("bytes=5-", (try h.fake.streamRequest(1)).header("Range").?);
}

test "download: range refusals and lies" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        // The server ignores the range and answers 200 with everything.
        .{ .respond = .{ .status = 200, .body = "hello world\n" } },
        // The server honors a range, but the wrong one.
        .{ .respond = .{
            .status = 206,
            .body = "ello ",
            .headers = &.{.{ .name = "Content-Range", .value = "bytes 1-5/12" }},
        } },
        // The offset is past the end.
        .{ .respond = .{ .status = 416, .body = "{\"error\":{\"code\":416,\"errors\":[{\"reason\":\"requestedRangeNotSatisfiable\"}]}}" } },
        // An empty object answers 416 even at offset 0: that is success.
        .{ .respond = .{ .status = 416, .body = "{\"error\":{\"code\":416}}" } },
    }, .{ .retry = .{ .max_attempts = 1 } });
    defer h.deinit();
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const obj = h.client.bucket("b").object("a");

    try testing.expectError(error.InvalidResponse, obj.download(&out, .{ .range = .{ .offset = 5 } }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "ignored the range") != null);
    out = .fixed(&buf);
    try testing.expectError(error.InvalidResponse, obj.download(&out, .{ .range = .{ .offset = 5, .length = 5 } }));
    out = .fixed(&buf);
    try testing.expectError(error.OutOfRange, obj.download(&out, .{ .range = .{ .offset = 1000 } }));
    out = .fixed(&buf);
    const empty = try obj.download(&out, .{ .range = .{ .offset = 0 } });
    try testing.expectEqual(0, empty.bytes_written);
    try testing.expect(!empty.checksum_verified);
    try testing.expectEqual(0, empty.crc32c);

    // A zero-length range never leaves the client.
    try testing.expectError(error.InvalidArgument, obj.download(&out, .{ .range = .{ .offset = 5, .length = 0 } }));
    try testing.expectEqual(4, h.fake.stream_requests.items.len);
}

test "download: progress keeps resetting the attempt counter" {
    const full_crc = core.crc32c.toBase64(core.crc32c.hash("abcdefgh"));
    var hash_value_buf: [32]u8 = undefined;
    const hash_value = try std.fmt.bufPrint(&hash_value_buf, "crc32c={s}", .{&full_crc});

    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{
            .body = "abcdefgh",
            .headers = &.{.{ .name = "x-goog-generation", .value = "3" }},
            .cut_after = 3,
        } },
        .{ .respond = .{
            .status = 206,
            .body = "defgh",
            .headers = &.{.{ .name = "Content-Range", .value = "bytes 3-7/8" }},
            .cut_after = 2,
        } },
        .{ .respond = .{
            .status = 206,
            .body = "fgh",
            .headers = &.{.{ .name = "Content-Range", .value = "bytes 5-7/8" }},
            .cut_after = 2,
        } },
        .{ .respond = .{
            .status = 206,
            .body = "h",
            .headers = &.{
                .{ .name = "Content-Range", .value = "bytes 7-7/8" },
                .{ .name = "x-goog-hash", .value = hash_value },
            },
        } },
    }, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1 } });
    defer h.deinit();
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);

    // Four requests despite max_attempts = 2: every cut delivered bytes,
    // and progress resets the counter.
    const result = try h.client.bucket("b").object("a").download(&out, .{});
    try testing.expectEqualStrings("abcdefgh", out.buffered());
    try testing.expectEqual(8, result.bytes_written);
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(core.crc32c.hash("abcdefgh"), result.crc32c);
    try testing.expectEqual(4, h.fake.stream_requests.items.len);
}

test "download: no generation to pin means no resume" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "hello world\n", .cut_after = 5 } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try testing.expectError(
        error.ConnectionResetByPeer,
        h.client.bucket("b").object("a").download(&out, .{}),
    );
    try testing.expectEqual(1, h.fake.stream_requests.items.len);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "no generation to pin") != null);
    // The five delivered bytes are in the writer, as documented.
    try testing.expectEqualStrings("hello", out.buffered());
}

test "download: a transcoded body cannot resume" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{
            .body = "decompressed text",
            .headers = &.{
                .{ .name = "x-goog-generation", .value = "7" },
                .{ .name = "x-goog-stored-content-encoding", .value = "gzip" },
            },
            .cut_after = 6,
        } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try testing.expectError(
        error.ConnectionResetByPeer,
        h.client.bucket("b").object("a").download(&out, .{}),
    );
    try testing.expectEqual(1, h.fake.stream_requests.items.len);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "cannot resume") != null);
}

test "download: the caller's writer failing passes through" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "hello world\n" } }}, .{});
    defer h.deinit();
    var buf: [4]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try testing.expectError(error.WriteFailed, h.client.bucket("b").object("a").download(&out, .{}));
}

test "download: a pinned generation rides every request" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "x", .headers = &.{.{ .name = "x-goog-generation", .value = "9" }} } }}, .{});
    defer h.deinit();
    var buf: [8]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const result = try h.client.bucket("b").object("a").download(&out, .{ .generation = 9 });
    try testing.expectEqual(9, result.generation);
    try testing.expectEqualStrings(
        "https://storage.googleapis.com/storage/v1/b/b/o/a?alt=media&generation=9",
        (try h.fake.streamRequest(0)).url,
    );
}

test "downloadAlloc: a zero-byte object verifies against the empty checksum" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{
        .body = "",
        .headers = &.{.{ .name = "x-goog-hash", .value = "crc32c=AAAAAA==" }},
    } }}, .{});
    defer h.deinit();
    var got = try h.client.bucket("b").object("empty").downloadAlloc(1024, .{});
    defer got.deinit();
    try testing.expectEqual(0, got.value.data.len);
    try testing.expect(got.value.result.checksum_verified);
    try testing.expectEqual(0, got.value.result.crc32c);
}

test "uploadFrom verifies the finished object and deletes a mismatch" {
    const session = "https://storage.example.test/upload/session/x1";
    const opened: test_util.FakeTransport.Reply = .{ .respond = .{
        .status = 200,
        .body = "",
        .headers = &.{.{ .name = "Location", .value = session }},
    } };
    var h: test_util.Harness = undefined;
    try h.init(&.{
        opened,
        // The finished object stores a checksum that is not the stream's.
        .{ .respond = .{ .body = "{\"name\":\"a\",\"generation\":\"55\",\"crc32c\":\"AAAAAQ==\"}" } },
        // The cleanup delete.
        .{ .respond = .{ .status = 204, .body = "" } },
        // A second, honest run.
        opened,
        .{ .respond = .{ .body = "{\"name\":\"a\",\"generation\":\"56\",\"crc32c\":\"8P9ykg==\"}" } },
    }, .{});
    defer h.deinit();
    const obj = h.client.bucket("b").object("a");

    var bad: std.Io.Reader = .fixed("hello world\n");
    try testing.expectError(error.ChecksumMismatch, obj.uploadFrom(&bad, .{}));
    // The delete pinned the generation the upload just created.
    const cleanup = try h.fake.request(0);
    try testing.expectEqual(.DELETE, cleanup.method);
    try testing.expectEqualStrings("https://storage.googleapis.com/storage/v1/b/b/o/a?generation=55", cleanup.url);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "checksum mismatch after upload") != null);

    var good: std.Io.Reader = .fixed("hello world\n");
    var info = try obj.uploadFrom(&good, .{});
    defer info.deinit();
    try testing.expectEqual(56, info.value.generation);
    // Without a declared checksum, the session metadata claims none.
    try testing.expect(std.mem.indexOf(u8, (try h.fake.streamRequest(3)).body_prefix, "crc32c") == null);
}

test "uploadFrom with a declared checksum sends it and trusts the server" {
    const opened: test_util.FakeTransport.Reply = .{ .respond = .{
        .status = 200,
        .body = "",
        .headers = &.{.{ .name = "Location", .value = "https://storage.example.test/upload/session/x2" }},
    } };
    var h: test_util.Harness = undefined;
    try h.init(&.{
        opened,
        // The stored checksum does not matter: the server was the verifier.
        .{ .respond = .{ .body = "{\"name\":\"a\",\"generation\":\"57\",\"crc32c\":\"AAAAAQ==\"}" } },
    }, .{});
    defer h.deinit();
    var reader: std.Io.Reader = .fixed("hello world\n");
    var info = try h.client.bucket("b").object("a").uploadFrom(&reader, .{
        .crc32c = 0xf0ff7292,
        .size = 12,
    });
    defer info.deinit();
    const open = try h.fake.streamRequest(0);
    try testing.expect(std.mem.indexOf(u8, open.body_prefix, "\"crc32c\":\"8P9ykg==\"") != null);
    try testing.expectEqualStrings("12", open.header("X-Upload-Content-Length").?);
}

test "upload: a size that contradicts the data never leaves the client" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try testing.expectError(
        error.InvalidArgument,
        h.client.bucket("b").object("a").upload("hello world\n", .{ .size = 11 }),
    );
    try h.expectRequestCount(0);
}

test "bad object names fail before sending" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const bucket = h.client.bucket("my-bucket");
    try testing.expectError(error.InvalidObjectName, bucket.object("").get(.{}));
    try testing.expectError(error.InvalidObjectName, bucket.object(".").delete(.{}));
    try testing.expectError(error.InvalidObjectName, bucket.object("..").exists());
    try testing.expectError(error.InvalidObjectName, bucket.object("a\nb").get(.{}));
    try h.expectRequestCount(0);
}

test "preconditions ride get, download, delete and both upload protocols" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"a\"}" } },
        .{ .respond = .{ .body = "x" } },
        .{ .respond = .{ .status = 204, .body = "" } },
        .{ .respond = .{ .body = "{\"name\":\"a\"}" } },
    }, .{});
    defer h.deinit();
    const obj = h.client.bucket("b").object("a");

    var got = try obj.get(.{ .preconditions = .{ .if_metageneration_match = 3 } });
    got.deinit();
    try testing.expectEqualStrings(
        "https://storage.googleapis.com/storage/v1/b/b/o/a?ifMetagenerationMatch=3",
        (try h.fake.request(0)).url,
    );

    var out_buf: [8]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    _ = try obj.download(&out, .{ .preconditions = .{ .if_generation_match = 7 } });
    try testing.expectEqualStrings(
        "https://storage.googleapis.com/storage/v1/b/b/o/a?alt=media&ifGenerationMatch=7",
        (try h.fake.streamRequest(0)).url,
    );

    try obj.delete(.{ .preconditions = .{ .if_generation_match = 7 } });
    try testing.expectEqualStrings(
        "https://storage.googleapis.com/storage/v1/b/b/o/a?ifGenerationMatch=7",
        (try h.fake.request(1)).url,
    );

    var uploaded = try obj.upload("data", .{ .preconditions = .does_not_exist });
    uploaded.deinit();
    try testing.expectEqualStrings(
        "https://storage.googleapis.com/upload/storage/v1/b/b/o?uploadType=multipart&ifGenerationMatch=0",
        (try h.fake.streamRequest(1)).url,
    );
}

test "an if...NotMatch that matches is NotModified, an answer, never retried" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 304, .body = "" } },
        .{ .respond = .{ .status = 304, .body = "" } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();
    const obj = h.client.bucket("b").object("a");

    try testing.expectError(error.NotModified, obj.get(.{ .preconditions = .{ .if_generation_not_match = 7 } }));
    try h.expectRequestCount(1);
    try testing.expectEqual(304, h.diag.http_status);

    var out_buf: [8]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try testing.expectError(error.NotModified, obj.download(&out, .{ .preconditions = .{ .if_generation_not_match = 7 } }));
    // The writer saw nothing: a 304 ends at the head.
    try testing.expectEqual(0, out.buffered().len);
    try testing.expectEqual(0, h.clock.sleep_count);
}

test "preconditioned writes retry; a 412 after retries names the ambiguity" {
    const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 503, .body = "{}" } };
    const precondition_failed: test_util.FakeTransport.Reply = .{ .respond = .{
        .status = 412,
        .body = "{\"error\":{\"code\":412,\"message\":\"Precondition Failed\",\"errors\":[{\"reason\":\"conditionNotMet\"}]}}",
    } };
    var h: test_util.Harness = undefined;
    try h.init(&.{
        // The upload's first attempt fails transiently, the second lands.
        unavailable,
        .{ .respond = .{ .body = "{\"name\":\"a\"}" } },
        // A delete with if_generation_match retries the same way.
        unavailable,
        .{ .respond = .{ .status = 204, .body = "" } },
        // An upload whose retry may have landed answers 412.
        unavailable,
        precondition_failed,
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();
    const obj = h.client.bucket("b").object("a");

    var uploaded = try obj.upload("data", .{ .preconditions = .does_not_exist });
    uploaded.deinit();
    try testing.expectEqual(2, h.fake.stream_requests.items.len);

    try obj.delete(.{ .preconditions = .{ .if_generation_match = 7 } });
    try testing.expectEqual(2, h.fake.requests.items.len);

    try testing.expectError(error.FailedPrecondition, obj.upload("data", .{ .preconditions = .does_not_exist }));
    try testing.expectEqual(412, h.diag.http_status);
    try testing.expectEqualStrings("conditionNotMet", h.diag.status());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "an earlier attempt may have succeeded") != null);
}

test "unconditioned writes still do not retry" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .status = 503, .body = "{}" } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();
    const obj = h.client.bucket("b").object("a");
    // A not-match condition does not make a write idempotent.
    try testing.expectError(error.Unavailable, obj.upload("data", .{
        .preconditions = .{ .if_generation_not_match = 7 },
    }));
    try testing.expectEqual(1, h.fake.stream_requests.items.len);
    try testing.expectError(error.Unavailable, obj.delete(.{
        .preconditions = .{ .if_metageneration_match = 1 },
    }));
    try h.expectRequestCount(1);
}

test "golden: copyTo loops over rewrite calls and hides the token" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body =
        \\{"done":false,"totalBytesRewritten":"1048576","objectSize":"3145728","rewriteToken":"t+1"}
        } },
        .{ .respond = .{ .body =
        \\{"done":false,"totalBytesRewritten":"2097152","objectSize":"3145728","rewriteToken":"t2"}
        } },
        .{ .respond = .{ .body =
        \\{"done":true,"totalBytesRewritten":"3145728","objectSize":"3145728",
        \\ "resource":{"name":"copy/q3.txt","bucket":"dst-b","generation":"9","size":"3145728"}}
        } },
    }, .{});
    defer h.deinit();
    const src = h.client.bucket("src-b").object("reports/q3.txt");
    const dest = h.client.bucket("dst-b").object("copy/q3.txt");

    var copied = try src.copyTo(dest, .{ .source_generation = 5 });
    defer copied.deinit();
    try testing.expectEqualStrings("copy/q3.txt", copied.value.name);
    try testing.expectEqual(9, copied.value.generation);

    try h.expectRequest(
        0,
        .POST,
        "https://storage.googleapis.com/storage/v1/b/src-b/o/reports%2Fq3.txt/rewriteTo/b/dst-b/o/copy%2Fq3.txt?sourceGeneration=5",
        "{}",
    );
    try testing.expectEqualStrings(
        "https://storage.googleapis.com/storage/v1/b/src-b/o/reports%2Fq3.txt/rewriteTo/b/dst-b/o/copy%2Fq3.txt?sourceGeneration=5&rewriteToken=t%2B1",
        (try h.fake.request(1)).url,
    );
    try testing.expectEqualStrings(
        "https://storage.googleapis.com/storage/v1/b/src-b/o/reports%2Fq3.txt/rewriteTo/b/dst-b/o/copy%2Fq3.txt?sourceGeneration=5&rewriteToken=t2",
        (try h.fake.request(2)).url,
    );
}

test "copyTo retries the first call only under a destination condition, token calls always" {
    const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 503, .body = "{}" } };
    var h: test_util.Harness = undefined;
    try h.init(&.{
        // Unconditioned: the first call is not retried.
        unavailable,
        // Conditioned: it is.
        unavailable,
        .{ .respond = .{ .body = "{\"done\":false,\"rewriteToken\":\"t\"}" } },
        // The token call is safe to retry whatever the conditions.
        unavailable,
        .{ .respond = .{ .body = "{\"done\":true,\"resource\":{\"name\":\"c\"}}" } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();
    const src = h.client.bucket("s").object("a");
    const dest = h.client.bucket("d").object("c");

    try testing.expectError(error.Unavailable, src.copyTo(dest, .{}));
    try h.expectRequestCount(1);

    var copied = try src.copyTo(dest, .{ .preconditions = .does_not_exist });
    defer copied.deinit();
    try h.expectRequestCount(5);
}

test "copyTo refuses a loop that cannot continue" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"done\":false}" } },
        .{ .respond = .{ .body = "{\"done\":true}" } },
    }, .{});
    defer h.deinit();
    const src = h.client.bucket("s").object("a");
    const dest = h.client.bucket("d").object("c");
    // Not done, but no token to continue with.
    try testing.expectError(error.InvalidResponse, src.copyTo(dest, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "no token") != null);
    // Done, but no object resource.
    try testing.expectError(error.InvalidResponse, src.copyTo(dest, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "no object resource") != null);
}

test "upload: a repeated metadata key is refused before anything is sent" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const obj = h.client.bucket("b").object("a");
    try testing.expectError(error.InvalidArgument, obj.upload("x", .{
        .metadata = &.{ .{ .key = "k", .value = "1" }, .{ .key = "k", .value = "2" } },
    }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "appears twice") != null);
    // The same rule on the streaming path, which shares the check.
    var reader: std.Io.Reader = .fixed("x");
    try testing.expectError(error.InvalidArgument, obj.uploadFrom(&reader, .{
        .metadata = &.{ .{ .key = "k", .value = "1" }, .{ .key = "k", .value = "2" } },
    }));
    // And the empty key that was already refused.
    try testing.expectError(error.InvalidArgument, obj.upload("x", .{
        .metadata = &.{.{ .key = "", .value = "1" }},
    }));
    try testing.expectEqual(0, h.fake.stream_requests.items.len);
}
