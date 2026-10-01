//! A Cloud Storage that speaks the XML API's multipart upload, the JSON
//! API's resumable sessions, and the little of the JSON API a transfer
//! needs beside them: metadata reads, deletes, and media reads of a whole
//! object or one range of it. Kept in memory and safe to use from several
//! tasks at once. fake-gcs-server has no multipart uploads, finishes a
//! truncated object on a resumable status query, and has no faults on
//! demand, so this is what `uploadParallel`, `downloadParallel` and
//! `uploadFile` are tested against, faults and all. Test code only.
//!
//! Sessions follow what Google documents: bytes append at the offset the
//! server holds and resent prefixes are ignored, a status query (`bytes
//! */T`) finishes a session whose bytes are all there, as an empty
//! finalize would, a finished session keeps answering 200 with its object
//! while that object stands, an unknown or dropped session answers 404,
//! a cancel answers 499 and so does everything sent to that session
//! afterwards, as measured against Google, and a finish carrying
//! `X-Goog-Hash` refuses a mismatched object with 400 before it exists.
//!
//! It holds uploads to the rules Google documents: part numbers 1 to
//! 10,000, a part sent again replaces itself, the finish names parts in
//! ascending order with the ETags they were given, every part but the last
//! is at least `min_part_size`, and a finish or part for an upload that is
//! gone answers 404 `NoSuchUpload`. Finishing replaces any object of the
//! name, with a new generation.
//!
//! Buckets, their settings and the rules on them are `FakeBuckets`'s,
//! served through here so that the same transport, fault plan and lock
//! cover them.
//!
//! With `soft_delete` on, the objects' bucket keeps what a delete removes,
//! as Cloud Storage measured on 2026-09-29 does: a soft-deleted generation
//! reads only by its generation, never as bytes, and a restore makes a new
//! live generation of it with its metadata, leaves it restorable again,
//! and moves the live object it replaces into soft delete itself. A
//! restore is held to its conditions against the live object; a live or
//! unknown generation is 404, and with `soft_delete` off every restore is
//! 400. Only a delete and a restore soft-delete an object here: an upload
//! that replaces one frees it, which no test depends on.
//!
//! With `requester_pays` on, every request must name a project to bill,
//! as Cloud Storage measured on 2026-09-29 holds anyone but a bucket's
//! owners to, and only `billable` is one the caller may bill: a JSON
//! request by the `userProject` parameter, an XML request by the
//! `x-goog-user-project` header, and a resumable session by the URL it was
//! given, which carries the project its start named. Without one, the
//! answer is production's 400; with another, its 403. Whether requester
//! pays is on or not, a `userProject` and a header that disagree, or a
//! `userProject` named twice, fail the test that sent them: this library
//! must never send either.
//!
//! Encryption keys are held to what Cloud Storage measured on 2026-09-30
//! does. An object stored under a customer-supplied key refuses a read or
//! a media read without the key, or with another, with production's 400,
//! and an object stored without one refuses a request that sends one. A
//! read of such an object without its key leaves out `crc32c`. An XML
//! upload begun under a key refuses a part or finish without it or with
//! another, and its finish, like that of an upload under a Cloud KMS key,
//! names no `x-goog-hash`. A malformed key, a key and a KMS key together,
//! and a KMS key version are refused as production refuses them, and with
//! `kms_granted` off, any KMS key is 403. A key, a copy-source key or a
//! KMS key on any request this library must never send one on fails the
//! test that sent it: a resumable session's chunks, a delete, a move, a
//! restore, the XML part list and abort, and every bucket request.
//!
//! Idempotency tokens are held to what Cloud Storage measured on
//! 2026-09-30 does. A one-request upload, a delete or a move that succeeds
//! with a token keeps its answer, by token and resource, for `dedup_ns` of
//! the clock; a repeat with the token in that time gets the kept answer and
//! is not run again, whatever changed in between. A failure is not kept. A
//! resumable session's start runs again, as production's does. A token on
//! a read, the XML API, or a session's chunks fails the test that sent it.
//!
//! Holds and retention policies are held to what Cloud Storage measured on
//! 2026-09-30 does. An object keeps its holds, absent until set and
//! `false` once released, and a metageneration that a patch moves. Under a
//! hold, or its bucket's retention policy in `buckets` (the period running
//! on this fake's clock from the object's creation, or from its
//! event-based hold's release), a delete, an overwrite (by one request, at
//! a session's final PUT, or at an XML finish) and a move of it are
//! refused 403, with production's reasons and messages: the JSON API's
//! `retentionPolicyNotMet`, or `forbidden` for a hold; the XML API's
//! `RetentionPolicyNotMet` and `ObjectUnderActiveHold`. A condition is
//! checked first. New objects get the bucket's default event-based hold
//! unless their metadata says `eventBasedHold: false`. `objects.patch`
//! sets and releases holds, and takes nothing else.
//!
//! Object retention, in a bucket created with it, is held to the same
//! day's measurements: an upload or a patch names both its mode and its
//! time, in the future and with a zone, and not beside an event-based
//! hold, or is refused 400 with production's words; the object is kept
//! until its time; a patch extends it freely, while shortening, removing
//! (both fields null; `{}` changes nothing) or locking an unlocked one
//! needs `overrideUnlockedRetention=true`, and a locked one only extends.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const Header = core.transport.Header;
const Method = core.transport.Method;
const xml = @import("xml.zig");
const FakeBuckets = @import("fake_buckets.zig").FakeBuckets;

pub const FakeMultipart = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    uploads: std.ArrayList(Upload) = .empty,
    sessions: std.ArrayList(Session) = .empty,
    objects: std.ArrayList(Stored) = .empty,
    /// Generations deleted while `soft_delete` was on.
    soft_deleted: std.ArrayList(Stored) = .empty,
    /// The objects' bucket keeps deleted objects restorable.
    soft_delete: bool = false,
    /// The objects' bucket, and every bucket served, bills the requester.
    requester_pays: bool = false,
    /// The one project a requester may bill.
    billable: []const u8 = "extractctl",
    /// Cloud Storage's service agent may use every Cloud KMS key; off,
    /// none, and a write naming one is production's 403.
    kms_granted: bool = true,
    /// Answers kept by idempotency token, oldest first.
    kept: std.ArrayList(Kept) = .empty,
    /// How long a kept answer answers a repeat: measured, at least 115 s
    /// and less than 130 s.
    dedup_ns: i96 = 120 * std.time.ns_per_s,
    /// Buckets and their settings, apart from the objects above, which
    /// belong to whatever bucket a request names.
    buckets: FakeBuckets,
    next_upload: u32 = 1,
    next_session: u32 = 1,
    next_generation: u64 = 1_000,
    /// Every part but the last must be at least this at the finish, as
    /// Google's 5 MiB. Tests lower it.
    min_part_size: u64 = 5 * 1024 * 1024,
    /// Decides each request's fate; null lets every request through.
    faults: ?FaultPlan = null,
    /// Opened by a test to release requests the plan made wait.
    gate: std.Io.Event = .unset,
    /// How long a `stall` holds its request.
    stall_ms: u32 = 500,
    /// A move checks its destination's conditions before its source, so a
    /// move repeated after one that landed answers 412, not 404. Which
    /// Cloud Storage does, no documentation says.
    move_checks_destination_first: bool = false,
    counts: Counts = .{},

    pub const Counts = struct {
        starts: u32 = 0,
        parts: u32 = 0,
        finishes: u32 = 0,
        aborts: u32 = 0,
        /// ListParts pages served, answered or not.
        lists: u32 = 0,
        reads: u32 = 0,
        deletes: u32 = 0,
        /// Media reads, of a whole object or a range, answered or not.
        media: u32 = 0,
        /// Body bytes the media reads delivered: half the body for a cut,
        /// none for an answer that was lost.
        media_bytes: u64 = 0,
        moves: u32 = 0,
        restores: u32 = 0,
        session_starts: u32 = 0,
        session_puts: u32 = 0,
        /// Repeats answered with a kept answer, and not run again.
        deduplicated: u32 = 0,
        /// `objects.patch` requests.
        patches: u32 = 0,
        /// Writes refused because the object was held or retained.
        kept_refusals: u32 = 0,
        session_cancels: u32 = 0,
        /// One-request `uploadType=multipart` uploads.
        inserts: u32 = 0,
        /// Payload bytes sessions accepted as new, resent prefixes not
        /// counted.
        session_bytes: u64 = 0,
        /// Payload bytes sessions ignored as already stored: what a
        /// client that resends what the server holds wastes.
        session_stale_bytes: u64 = 0,
    };

    pub const Kind = enum { start, part, finish, abort, list, read, delete, media, move, session_start, session_put, session_cancel, insert, bucket, restore, patch };

    pub const Fault = enum {
        none,
        /// A 503, and nothing done.
        unavailable,
        /// The connection drops before anything is done.
        reset,
        /// Done, then the connection drops: the answer is lost.
        lose_answer,
        /// A part is stored with a byte flipped; a finish stores the object
        /// with a byte flipped. Either way the answer describes what was
        /// stored, as a corrupted transfer would leave it. A media read
        /// serves its bytes with one flipped, and the object keeps them. A
        /// move answers with another object's checksum.
        corrupt,
        /// The upload is gone, and the answer is 404 `NoSuchUpload`. A media
        /// read finds the object overwritten just before it: the generation
        /// moves on, and a read pinned to the old one answers 404.
        gone,
        /// A finish answers 200 with an `<Error>` body, and does nothing.
        error_200,
        /// The request waits until `gate` opens or its task is canceled.
        wait,
        /// The request is held `stall_ms` before it is answered, as a slow
        /// link holds it: long enough for a client's timeout to fire.
        stall,
        /// A media read sends half its body, then the connection drops.
        cut,
        /// A range read answers 206 a byte short of what was asked for.
        short,
        /// A range read answers 206 with a byte more than was asked for,
        /// where the object has one.
        long,
        /// A move finds another writer's object put under its destination
        /// name just before it is served; an upload of one request or a
        /// delete, under its own name. A repeat meets it too.
        clobber,
        /// The request fails with `error.Canceled`, as a canceled task's
        /// would, though nothing canceled it.
        canceled,
    };

    pub const FaultPlan = struct {
        ctx: ?*anyopaque = null,
        /// Called under the lock, once per request. `part` is the part
        /// number for a part, 1 plus the first byte asked for on a media
        /// read (1 for a whole object), else 0.
        decide: *const fn (ctx: ?*anyopaque, kind: Kind, part: u32) Fault,
    };

    /// A write's answer, kept by its idempotency token.
    const Kept = struct {
        /// The token, the kind of write and its resource, joined.
        key: []u8,
        at_ns: i96,
        status: u16,
        headers: []Header,
        body: []u8,
    };

    const Upload = struct {
        id: []u8,
        name: []u8,
        content_type: []u8,
        metadata: []Header,
        parts: std.AutoArrayHashMapUnmanaged(u32, Part) = .empty,
        /// The SHA-256 of the customer-supplied key its start named.
        key_sha256: ?[32]u8 = null,
        /// The Cloud KMS key its start named. Owned.
        kms_key_name: ?[]u8 = null,
    };

    const Part = struct {
        bytes: []u8,
        etag: []u8,
    };

    /// One resumable session. A finished one stays, remembering the
    /// object it made, as Google's do for their week.
    const Session = struct {
        id: []u8,
        bucket: []u8,
        name: []u8,
        content_type: []u8,
        /// From `X-Upload-Content-Length`, or null.
        declared: ?u64,
        /// The crc32c the opening metadata claimed, or null.
        metadata_crc: ?u32,
        /// The metadata said `contentEncoding: gzip`.
        gzip: bool = false,
        bytes: std.ArrayList(u8) = .empty,
        /// The generation the finish made, once it has.
        done: ?u64 = null,
        /// Cancelled before it finished: its bytes are gone, and it
        /// answers 499 to everything.
        cancelled: bool = false,
        /// The keys its start named. The name is owned.
        key_sha256: ?[32]u8 = null,
        kms_key_name: ?[]u8 = null,
        /// The holds and retention its start's metadata asked for.
        holds: Holds = .{},
        retention: ?Retention = null,
    };

    /// An object's own retention.
    pub const Retention = struct {
        locked: bool,
        until_ns: i96,
    };

    /// An object's holds: null until set, `false` once released.
    pub const Holds = struct {
        temporary: ?bool = null,
        event_based: ?bool = null,
    };

    /// An object the fake holds.
    pub const Stored = struct {
        name: []u8,
        generation: u64,
        bytes: []u8,
        content_type: []u8,
        /// The `x-goog-meta-` headers the start carried, names lowercased.
        metadata: []Header,
        /// For an object stored gzip-compressed: what a media read gets
        /// instead of `bytes`, whole, as Cloud Storage decompresses it.
        served: ?[]u8 = null,
        /// The SHA-256 of the customer-supplied key it is stored under.
        key_sha256: ?[32]u8 = null,
        /// The Cloud KMS key it is stored under, without a version. Owned.
        kms_key_name: ?[]u8 = null,
        holds: Holds = .{},
        /// Its own retention: until when, on the fake's clock.
        retention: ?Retention = null,
        /// Moved by every patch.
        metageneration: u64 = 1,
        /// When its retention period started, on the fake's clock: its
        /// creation, or its event-based hold's latest release.
        retained_from_ns: i96 = 0,
    };

    pub fn init(gpa: Allocator, io: std.Io) FakeMultipart {
        return .{ .gpa = gpa, .io = io, .buckets = .init(gpa) };
    }

    pub fn deinit(self: *FakeMultipart) void {
        for (self.uploads.items) |*u| freeUpload(self.gpa, u);
        self.uploads.deinit(self.gpa);
        for (self.sessions.items) |*s| freeSession(self.gpa, s);
        self.sessions.deinit(self.gpa);
        for (self.objects.items) |*o| freeStored(self.gpa, o);
        self.objects.deinit(self.gpa);
        for (self.soft_deleted.items) |*o| freeStored(self.gpa, o);
        self.soft_deleted.deinit(self.gpa);
        for (self.kept.items) |*k| freeKept(self.gpa, k);
        self.kept.deinit(self.gpa);
        self.buckets.deinit();
        self.* = undefined;
    }

    /// Sessions opened and neither finished nor cancelled. Call once every
    /// task using the fake has returned.
    pub fn openSessions(self: *const FakeMultipart) usize {
        var n: usize = 0;
        for (self.sessions.items) |s| {
            if (s.done == null and !s.cancelled) n += 1;
        }
        return n;
    }

    /// The bytes a live session holds. Call once every task using the
    /// fake has returned.
    pub fn sessionHolds(self: *const FakeMultipart, id_suffix: []const u8) ?u64 {
        for (self.sessions.items) |s| {
            if (std.mem.endsWith(u8, id_suffix, s.id)) return s.bytes.items.len;
        }
        return null;
    }

    pub fn transport(self: *FakeMultipart) core.transport.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send, .sendStream = sendStream } };
    }

    /// Uploads started and neither finished nor aborted. Call once every
    /// task using the fake has returned.
    pub fn openUploads(self: *const FakeMultipart) usize {
        return self.uploads.items.len;
    }

    /// Stores an object directly, as another writer would have, replacing
    /// any object of the name.
    pub fn put(self: *FakeMultipart, name: []const u8, bytes: []const u8) Allocator.Error!void {
        const owned_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned_name);
        const owned_bytes = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(owned_bytes);
        const content_type = try self.gpa.dupe(u8, "application/octet-stream");
        errdefer self.gpa.free(content_type);
        const metadata = try self.gpa.alloc(Header, 0);
        errdefer self.gpa.free(metadata);
        try self.objects.ensureUnusedCapacity(self.gpa, 1);
        if (self.liveIndex(name)) |i| {
            var replaced = self.objects.orderedRemove(i);
            freeStored(self.gpa, &replaced);
        }
        self.objects.appendAssumeCapacity(.{
            .name = owned_name,
            .generation = self.next_generation,
            .bytes = owned_bytes,
            .content_type = content_type,
            .metadata = metadata,
            .retained_from_ns = self.now(),
        });
        self.next_generation += 1;
    }

    /// Stores an object as gzip-compressed, as another writer would have:
    /// `stored` is what Cloud Storage keeps, sizes and hashes, and
    /// `decompressed` what a media read gets.
    /// `plain`, gzip-compressed by std and stored so, served decompressed to
    /// a request that does not take gzip as sent.
    pub fn putGzipped(self: *FakeMultipart, name: []const u8, plain: []const u8) Allocator.Error!void {
        const stored = try gzipAlloc(self.gpa, plain, .default);
        defer self.gpa.free(stored);
        try self.putGzip(name, stored, plain);
    }

    pub fn putGzip(self: *FakeMultipart, name: []const u8, stored: []const u8, decompressed: []const u8) Allocator.Error!void {
        const served = try self.gpa.dupe(u8, decompressed);
        errdefer self.gpa.free(served);
        try self.put(name, stored);
        self.objects.items[self.objects.items.len - 1].served = served;
    }

    /// Parts held by uploads still open: what is billed until an abort.
    /// An upload left behind by a lost answer to its start holds none.
    /// Call once every task using the fake has returned.
    pub fn openParts(self: *const FakeMultipart) usize {
        var n: usize = 0;
        for (self.uploads.items) |u| n += u.parts.count();
        return n;
    }

    /// The live object named `name`, or null. Call once every task using
    /// the fake has returned.
    pub fn object(self: *const FakeMultipart, name: []const u8) ?*const Stored {
        for (self.objects.items) |*o| if (std.mem.eql(u8, o.name, name)) return o;
        return null;
    }

    fn fromPtr(ptr: *anyopaque) *FakeMultipart {
        return @ptrCast(@alignCast(ptr));
    }

    fn send(ptr: *anyopaque, req: core.transport.Request, arena: Allocator) core.transport.Error!core.transport.Response {
        const self = fromPtr(ptr);
        const res = try self.handle(req.method, req.url, null, req.headers, req.body orelse "", false, arena);
        return .{ .status = res.status, .body = res.body, .headers = res.headers };
    }

    fn sendStream(ptr: *anyopaque, req: core.transport.StreamRequest, arena: Allocator) core.transport.StreamError!core.transport.StreamResponse {
        const self = fromPtr(ptr);
        const body: []const u8 = switch (req.body) {
            .none => "",
            .segments => |segments| try std.mem.concat(arena, u8, segments),
            .stream => |source| b: {
                // Exactly the declared length, as the real transport sends.
                const buf = try arena.alloc(u8, @intCast(source.len));
                source.reader.readSliceAll(buf) catch |err| return switch (err) {
                    error.ReadFailed => error.ReadFailed,
                    error.EndOfStream => error.EndOfStream,
                };
                break :b buf;
            },
        };
        const res = try self.handle(req.method, req.url, req.content_type, req.headers, body, req.accept_encoding == .gzip_as_sent, arena);
        if (req.head_out) |out| out.* = .{ .status = res.status, .headers = res.headers };
        if (req.sink == .writer and res.status >= 200 and res.status < 300) {
            if (res.cut) {
                req.sink.writer.writeAll(res.body[0 .. res.body.len / 2]) catch return error.WriteFailed;
                return error.ConnectionResetByPeer;
            }
            req.sink.writer.writeAll(res.body) catch return error.WriteFailed;
            return .{ .status = res.status, .headers = res.headers, .bytes_streamed = res.body.len };
        }
        return .{ .status = res.status, .headers = res.headers, .body = res.body };
    }

    const Reply = struct {
        status: u16,
        headers: []const Header = &.{},
        body: []const u8 = "",
        /// Send half the body, then drop the connection.
        cut: bool = false,
    };

    /// One request, whichever entry it came through. The URL is parsed
    /// outside the lock; everything that reads or changes state is inside.
    /// `accept_gzip` is a request that takes gzip as sent, which Cloud
    /// Storage answers with a gzip object's stored bytes.
    fn handle(
        self: *FakeMultipart,
        method: Method,
        url: []const u8,
        content_type: ?[]const u8,
        headers: []const Header,
        body: []const u8,
        accept_gzip: bool,
        arena: Allocator,
    ) core.transport.Error!Reply {
        const target = try parseTarget(arena, url);
        const kind: Kind = switch (target) {
            // A request this fake does not serve fails the test that sent it.
            .json => |j| switch (method) {
                .GET => if (j.media) .media else .read,
                .DELETE => .delete,
                .PATCH => .patch,
                else => return error.HttpProtocolError,
            },
            .move => if (method == .POST) .move else return error.HttpProtocolError,
            .resumable => if (method == .POST) .session_start else return error.HttpProtocolError,
            .insert => if (method == .POST) .insert else return error.HttpProtocolError,
            .bucket => .bucket,
            .restore => if (method == .POST) .restore else return error.HttpProtocolError,
            .session => switch (method) {
                .PUT => .session_put,
                .DELETE => .session_cancel,
                else => return error.HttpProtocolError,
            },
            .xml => |x| switch (x.query) {
                .uploads => .start,
                .part => .part,
                .upload => switch (method) {
                    .POST => .finish,
                    .DELETE => .abort,
                    .GET => .list,
                    else => return error.HttpProtocolError,
                },
            },
        };
        const part_number: u32 = switch (target) {
            .xml => |x| if (x.query == .part) x.query.part.number else 0,
            .json => |j| if (j.media) mediaPart(headers) else 0,
            .session => if (kind == .session_put) sessionPart(headers) else 0,
            .move, .resumable, .insert, .bucket, .restore => 0,
        };
        if (try self.billingRefusal(target, url, headers, arena)) |refusal| return refusal;
        if (try keyRefusal(kind, target, url, headers, arena)) |refusal| return refusal;
        if (try tokenRefusal(kind, method, headers, arena)) |refusal| return refusal;
        // Cloud Storage and fake-gcs-server take a request body sent with
        // `Content-Encoding: gzip` apart and store it plain. This library
        // never sends one: an object it compresses is stored compressed,
        // and the encoding goes in the metadata. A request that carries
        // one fails the test that sent it.
        if (headerValue(headers, "Content-Encoding") != null) return .{
            .status = 400,
            .body = "{\"error\":{\"code\":400,\"message\":\"this fake takes no request Content-Encoding\"}}",
        };

        self.mutex.lockUncancelable(self.io);
        const fault: Fault = if (self.faults) |plan| plan.decide(plan.ctx, kind, part_number) else .none;
        switch (fault) {
            .wait => {
                // Waiting holds no lock, so the other tasks go on.
                self.mutex.unlock(self.io);
                try self.gate.wait(self.io);
                self.mutex.lockUncancelable(self.io);
            },
            .stall => {
                self.mutex.unlock(self.io);
                try self.io.sleep(.fromMilliseconds(self.stall_ms), .awake);
                self.mutex.lockUncancelable(self.io);
            },
            .unavailable => {
                self.mutex.unlock(self.io);
                return .{ .status = 503, .body = "<Error><Code>ServiceUnavailable</Code><Message>try again</Message></Error>" };
            },
            .reset => {
                self.mutex.unlock(self.io);
                return error.ConnectionResetByPeer;
            },
            .canceled => {
                self.mutex.unlock(self.io);
                return error.Canceled;
            },
            else => {},
        }
        defer self.mutex.unlock(self.io);

        // Another writer acts before the request arrives, whether or not
        // it is a repeat.
        if (fault == .clobber) if (try clobbered(arena, kind, target, content_type, body)) |name| try self.put(name, "another writer's bytes");
        // A repeat of a write that succeeded with this token is answered
        // with the kept answer, and not run again.
        const kept_key = try keptKey(arena, kind, target, headers, content_type, body);
        if (kept_key) |key| if (self.keptAnswer(key)) |answer| {
            self.counts.deduplicated += 1;
            const reply: Reply = .{
                .status = answer.status,
                .headers = try arena.dupe(Header, answer.headers),
                .body = try arena.dupe(u8, answer.body),
            };
            if (fault == .lose_answer) return error.ConnectionResetByPeer;
            return reply;
        };

        const reply = switch (target) {
            .json => |j| try self.json(kind, j, headers, body, accept_gzip, fault, arena),
            .xml => |x| try self.multipartRequest(kind, x, content_type, headers, body, fault, arena),
            .move => |m| try self.moveObject(m, fault, arena),
            .resumable => |r| try self.sessionStart(r, content_type, headers, body, arena),
            .insert => |t| try self.insertObject(t, content_type, headers, body, arena),
            .bucket => |t| bucket: {
                const r = try self.buckets.serve(method, t, body, arena);
                break :bucket Reply{ .status = r.status, .body = r.body };
            },
            .restore => |t| try self.restoreObject(t, arena),
            .session => |id| if (kind == .session_put)
                try self.sessionPut(id, headers, body, fault, arena)
            else
                self.sessionCancel(id),
        };
        if (kept_key) |key| if (reply.status >= 200 and reply.status < 300) try self.keep(key, reply);
        if (fault == .lose_answer) return error.ConnectionResetByPeer;
        if (kind == .media and reply.status >= 200 and reply.status < 300) {
            self.counts.media_bytes += if (reply.cut) reply.body.len / 2 else reply.body.len;
        }
        return reply;
    }

    fn json(self: *FakeMultipart, kind: Kind, target: JsonTarget, headers: []const Header, body: []const u8, accept_gzip: bool, fault: Fault, arena: Allocator) Allocator.Error!Reply {
        const not_found: Reply = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"No such object\",\"errors\":[{\"reason\":\"notFound\"}]}}" };
        const index = for (self.objects.items, 0..) |o, i| {
            if (std.mem.eql(u8, o.name, target.name) and (target.generation == null or target.generation.? == o.generation)) break i;
        } else null;
        switch (kind) {
            .read => {
                self.counts.reads += 1;
                if (target.soft_deleted) return self.readSoftDeleted(target, arena);
                const o = &self.objects.items[index orelse return not_found];
                // A metadata read needs no key; one it is sent must fit.
                const given = requestKey(headers, object_key_prefix);
                if (given != .none) if (keyFault(o.key_sha256, given)) |key_fault| return jsonKeyReply(key_fault);
                switch (target.conditions.check(o)) {
                    .hold => {},
                    .match_failed => return condition_failed,
                    // A failing `…NotMatch` condition on a read is a 304,
                    // as HTTP's If-None-Match is.
                    .not_match_failed => return .{ .status = 304, .body = "" },
                }
                // Without its key, an object under one names no checksum.
                return .{ .status = 200, .body = try objectJson(self, arena, o, o.name, o.generation, target.bucket, false, given != .none) };
            },
            .media => {
                self.counts.media += 1;
                if (fault == .gone) {
                    for (self.objects.items) |*o| if (std.mem.eql(u8, o.name, target.name)) {
                        o.generation = self.next_generation;
                        self.next_generation += 1;
                    };
                    return not_found;
                }
                const o = &self.objects.items[index orelse return not_found];
                if (keyFault(o.key_sha256, requestKey(headers, object_key_prefix))) |key_fault| return mediaKeyReply(key_fault);
                return media(o, headers, accept_gzip, fault, arena);
            },
            .delete => {
                self.counts.deletes += 1;
                const i = index orelse return not_found;
                if (try self.keptRefusal(.json, target.bucket, &self.objects.items[i], arena)) |refusal| return refusal;
                if (self.soft_delete) try self.soft_deleted.ensureUnusedCapacity(self.gpa, 1);
                var removed = self.objects.orderedRemove(i);
                if (self.soft_delete) {
                    self.soft_deleted.appendAssumeCapacity(removed);
                } else {
                    freeStored(self.gpa, &removed);
                }
                return .{ .status = 204 };
            },
            .patch => return self.patchObject(target, index, body, arena),
            else => unreachable,
        }
    }

    /// `objects.patch`, of holds alone: every other field fails the test
    /// that sent it. Releasing an event-based hold starts the retention
    /// period over.
    fn patchObject(self: *FakeMultipart, target: JsonTarget, index: ?usize, body: []const u8, arena: Allocator) Allocator.Error!Reply {
        self.counts.patches += 1;
        const i = index orelse return .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"No such object\",\"errors\":[{\"reason\":\"notFound\"}]}}" };
        const o = &self.objects.items[i];
        switch (target.conditions.check(o)) {
            .hold => {},
            .match_failed, .not_match_failed => return condition_failed,
        }
        const bad = "{\"error\":{\"code\":400,\"message\":\"this fake patches holds alone: ";
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return .{ .status = 400, .body = bad ++ "a body that is not JSON\"}}" };
        if (parsed != .object) return .{ .status = 400, .body = bad ++ "a body that is not an object\"}}" };
        var holds = o.holds;
        var retention = o.retention;
        var it = parsed.object.iterator();
        while (it.next()) |entry| {
            const value = entry.value_ptr.*;
            if (std.mem.eql(u8, entry.key_ptr.*, "retention")) {
                switch (try self.retentionChange(target, o.retention, value, arena)) {
                    .refused => |reply| return reply,
                    .next => |next| retention = next,
                }
                continue;
            }
            if (value != .bool) return .{ .status = 400, .body = bad ++ "a field that is not a boolean\"}}" };
            if (std.mem.eql(u8, entry.key_ptr.*, "temporaryHold")) {
                holds.temporary = value.bool;
            } else if (std.mem.eql(u8, entry.key_ptr.*, "eventBasedHold")) {
                holds.event_based = value.bool;
            } else return .{ .status = 400, .body = bad ++ "another field\"}}" };
        }
        if (retention != null and (holds.event_based orelse false)) return try jsonRefusal(arena, 400, "invalid", "Retention and event based holds cannot be configured together.");
        if (o.holds.event_based orelse false and !(holds.event_based orelse false)) o.retained_from_ns = self.now();
        o.holds = holds;
        o.retention = retention;
        o.metageneration += 1;
        return .{ .status = 200, .body = try objectJson(self, arena, o, o.name, o.generation, target.bucket, false, false) };
    }

    const RetentionOutcome = union(enum) { next: ?Retention, refused: Reply };

    /// What a patch's `retention` makes of `old`, as measured.
    fn retentionChange(self: *FakeMultipart, target: JsonTarget, old: ?Retention, value: std.json.Value, arena: Allocator) Allocator.Error!RetentionOutcome {
        const unlocked_words = "The unlocked object retention cannot be removed and its retention period cannot be shortened without overriding unlocked retention intent and permission.";
        const locked_words = "The locked object retention cannot be removed. Its retention mode cannot be changed and its retention period cannot be shortened.";
        const removing = switch (value) {
            .null => true,
            .object => |fields| removal: {
                // `{}` changes nothing.
                if (fields.count() == 0) return .{ .next = old };
                const mode = fields.get("mode") orelse break :removal false;
                const until = fields.get("retainUntilTime") orelse break :removal false;
                break :removal mode == .null and until == .null;
            },
            else => return .{ .refused = try jsonRefusal(arena, 400, "invalid", "retention is not an object") },
        };
        if (removing) {
            const current = old orelse return .{ .next = null };
            if (current.locked) return .{ .refused = try jsonRefusal(arena, 403, "forbidden", locked_words) };
            if (!target.override_unlocked_retention) return .{ .refused = try jsonRefusal(arena, 403, "forbidden", unlocked_words) };
            return .{ .next = null };
        }
        const next = switch (try self.parseRetention(target.bucket, value, arena)) {
            .refused => |reply| return .{ .refused = reply },
            .ok => |r| r,
        };
        const current = old orelse return .{ .next = next };
        const shortens = next.until_ns < current.until_ns;
        if (current.locked) {
            if (!next.locked or shortens) return .{ .refused = try jsonRefusal(arena, 403, "forbidden", locked_words) };
            return .{ .next = next };
        }
        if ((shortens or next.locked) and !target.override_unlocked_retention) {
            return .{ .refused = try jsonRefusal(arena, 403, "forbidden", unlocked_words) };
        }
        return .{ .next = next };
    }

    const ParsedRetention = union(enum) { ok: Retention, refused: Reply };

    /// A retention as an upload or a patch names it, held to production's
    /// 400s: both fields, a known mode, a time with a zone and in the
    /// future, in a bucket with object retention.
    fn parseRetention(self: *const FakeMultipart, bucket: []const u8, value: std.json.Value, arena: Allocator) Allocator.Error!ParsedRetention {
        const fields = switch (value) {
            .object => |o| o,
            else => return .{ .refused = try jsonRefusal(arena, 400, "invalid", "retention is not an object") },
        };
        if (!self.buckets.objectRetention(bucket)) return .{ .refused = try jsonRefusal(arena, 400, "invalid", "Object retention is not enabled on the bucket.") };
        const mode = fields.get("mode") orelse return .{ .refused = try jsonRefusal(arena, 400, "invalid", "Missing retention mode. Both mode and retain until time are required.") };
        const until = fields.get("retainUntilTime") orelse return .{ .refused = try jsonRefusal(arena, 400, "invalid", "Missing retain until time. Both mode and retain until time are required.") };
        if (mode != .string or until != .string) return .{ .refused = try jsonRefusal(arena, 400, "invalid", "retention's fields are not strings") };
        const locked = if (std.mem.eql(u8, mode.string, "Locked"))
            true
        else if (std.mem.eql(u8, mode.string, "Unlocked"))
            false
        else
            return .{ .refused = try jsonRefusal(arena, 400, "invalid", try std.fmt.allocPrint(arena, "Invalid value for: {s} is not a valid value", .{mode.string})) };
        const at = core.timestamp.parse(until.string) catch return .{ .refused = try jsonRefusal(
            arena,
            400,
            "invalid",
            "Parse Error: Invalid value for type.googleapis.com/google.protobuf.Timestamp field: 'Field 'retainUntilTime', Illegal timestamp format; timestamps must end with 'Z' or have a valid timezone offset.'.",
        ) };
        const until_ns = at.nanoseconds - wall_base_s * std.time.ns_per_s;
        if (until_ns <= self.now()) return .{ .refused = try jsonRefusal(arena, 400, "invalid", "Retain until time cannot be in the past.") };
        return .{ .ok = .{ .locked = locked, .until_ns = until_ns } };
    }

    const UploadRetention = union(enum) { ok: ?Retention, refused: Reply };

    /// An upload's retention, if its metadata names one, refused beside an
    /// event-based hold.
    fn uploadRetention(self: *const FakeMultipart, bucket: []const u8, meta: Meta, arena: Allocator) Allocator.Error!UploadRetention {
        const value = meta.retention orelse return .{ .ok = null };
        if (meta.eventBasedHold orelse false) return .{ .refused = try jsonRefusal(arena, 400, "invalid", "Retention and event based holds cannot be configured together.") };
        return switch (try self.parseRetention(bucket, value, arena)) {
            .ok => |r| .{ .ok = r },
            .refused => |reply| .{ .refused = reply },
        };
    }

    /// The fake's clock.
    fn now(self: *const FakeMultipart) i96 {
        return std.Io.Clock.awake.now(self.io).nanoseconds;
    }

    /// When the object's retention ends, on the fake's clock, or null when
    /// no policy applies, or an event-based hold defers it.
    fn retainedUntil(self: *const FakeMultipart, bucket: []const u8, o: *const Stored) ?i96 {
        const own: ?i96 = if (o.retention) |r| r.until_ns else null;
        const period = self.buckets.retentionPeriod(bucket) orelse return own;
        if (o.holds.event_based orelse false) return own;
        const policy = o.retained_from_ns + @as(i96, period) * std.time.ns_per_s;
        return if (own) |until| @max(until, policy) else policy;
    }

    /// The holds a new object in `bucket` gets: those asked for, and the
    /// bucket's default event-based hold unless the upload said false.
    fn newHolds(self: *const FakeMultipart, bucket: []const u8, asked: Holds) Holds {
        var holds = asked;
        if (holds.event_based == null and self.buckets.defaultEventBasedHold(bucket)) holds.event_based = true;
        return holds;
    }

    const Api = enum { json, xml };

    /// Production's refusal of a write that would delete, replace or move
    /// `o` while it is held or retained, else null.
    fn keptRefusal(self: *FakeMultipart, api: Api, bucket: []const u8, o: *const Stored, arena: Allocator) Allocator.Error!?Reply {
        const hold: ?[]const u8 = if (o.holds.temporary orelse false)
            "Temporary"
        else if (o.holds.event_based orelse false)
            "Event-Based"
        else
            null;
        if (hold) |kind| {
            self.counts.kept_refusals += 1;
            const details = try std.fmt.allocPrint(arena, "Object '{s}/{s}' is under active {s} hold and cannot be deleted, overwritten or archived until hold is removed.", .{ bucket, o.name, kind });
            return switch (api) {
                .json => try jsonRefusal(arena, 403, "forbidden", details),
                .xml => .{ .status = 403, .body = try std.fmt.allocPrint(arena, "<?xml version='1.0' encoding='UTF-8'?><Error><Code>ObjectUnderActiveHold</Code><Message>Object overwrite or deletion is not allowed due to active hold on the object.</Message><Details>{s}</Details></Error>", .{details}) },
            };
        }
        const until = self.retainedUntil(bucket, o) orelse return null;
        if (self.now() >= until) return null;
        self.counts.kept_refusals += 1;
        const details = try std.fmt.allocPrint(arena, "Object '{s}/{s}' is subject to bucket's retention policy or object retention and cannot be deleted or overwritten until {s}", .{ bucket, o.name, try rfc3339(arena, until) });
        return switch (api) {
            .json => try jsonRefusal(arena, 403, "retentionPolicyNotMet", details),
            .xml => .{ .status = 403, .body = try std.fmt.allocPrint(arena, "<?xml version='1.0' encoding='UTF-8'?><Error><Code>RetentionPolicyNotMet</Code><Message>Object overwrite or deletion is not allowed due to retention policy.</Message><Details>{s}</Details></Error>", .{details}) },
        };
    }

    /// `keptRefusal` for the live object `name`, if there is one.
    fn keptLive(self: *FakeMultipart, api: Api, bucket: []const u8, name: []const u8, arena: Allocator) Allocator.Error!?Reply {
        const i = self.liveIndex(name) orelse return null;
        return self.keptRefusal(api, bucket, &self.objects.items[i], arena);
    }

    /// The answer to a request requester pays refuses, or to one this
    /// library must never send, else null. Read before the lock: it
    /// touches no state.
    fn billingRefusal(self: *const FakeMultipart, target: Target, url: []const u8, headers: []const Header, arena: Allocator) Allocator.Error!?Reply {
        const bad = "{\"error\":{\"code\":400,\"message\":\"this fake refuses what this library must never send: ";
        var param: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, url, '?')) |q| {
            var params = std.mem.splitScalar(u8, url[q + 1 ..], '&');
            while (params.next()) |p| if (std.mem.startsWith(u8, p, "userProject=")) {
                if (param != null) return .{ .status = 400, .body = bad ++ "userProject twice\"}}" };
                param = try decode(arena, p["userProject=".len..]);
            };
        }
        const header = headerValue(headers, "x-goog-user-project");
        if (param != null and header != null and !std.mem.eql(u8, param.?, header.?)) {
            return .{ .status = 400, .body = bad ++ "a userProject and an x-goog-user-project that disagree\"}}" };
        }
        if (!self.requester_pays) return null;
        // A create bills no one: there is no bucket yet.
        if (target == .bucket and target.bucket.name == null) return null;
        const missing = "Bucket is a requester pays bucket but no user project provided.";
        const named = switch (target) {
            .xml => header orelse return .{
                .status = 400,
                .body = "<?xml version='1.0' encoding='UTF-8'?><Error><Code>UserProjectMissing</Code><Message>" ++ missing ++ "</Message></Error>",
            },
            // A media read's refusal is plain text.
            .json => |j| param orelse return .{
                .status = 400,
                .body = if (j.media) missing else "{\"error\":{\"code\":400,\"message\":\"" ++ missing ++ "\",\"errors\":[{\"reason\":\"required\"}]}}",
            },
            else => param orelse return .{
                .status = 400,
                .body = "{\"error\":{\"code\":400,\"message\":\"" ++ missing ++ "\",\"errors\":[{\"reason\":\"required\"}]}}",
            },
        };
        if (!std.mem.eql(u8, named, self.billable)) return .{
            .status = 403,
            .body = "{\"error\":{\"code\":403,\"message\":\"the caller does not have serviceusage.services.use access to the Google Cloud project.\",\"errors\":[{\"reason\":\"forbidden\"}]}}",
        };
        return null;
    }

    /// The kept answer for `key`, if one is young enough.
    fn keptAnswer(self: *FakeMultipart, key: []const u8) ?*const Kept {
        const at = self.now();
        for (self.kept.items) |*k| {
            if (std.mem.eql(u8, k.key, key) and at - k.at_ns <= self.dedup_ns) return k;
        }
        return null;
    }

    /// Keeps a successful write's answer for its repeats.
    fn keep(self: *FakeMultipart, key: []const u8, reply: Reply) Allocator.Error!void {
        const owned_key = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned_key);
        const headers = try dupeHeaders(self.gpa, reply.headers);
        errdefer freeHeaders(self.gpa, headers);
        const body = try self.gpa.dupe(u8, reply.body);
        errdefer self.gpa.free(body);
        try self.kept.append(self.gpa, .{
            .key = owned_key,
            .at_ns = self.now(),
            .status = reply.status,
            .headers = headers,
            .body = body,
        });
    }

    const WriteKeys = union(enum) {
        ok: struct { key_sha256: ?[32]u8, kms_key_name: ?[]const u8 },
        refused: Reply,
    };

    /// The keys a write names, checked as Cloud Storage checks them: a
    /// customer key's three headers must agree, it cannot come with a KMS
    /// key, a KMS key version is malformed, and without `kms_granted` any
    /// KMS key is refused.
    fn writeKeys(self: *const FakeMultipart, given: RequestKey, kms_key_name: ?[]const u8, xml_api: bool) WriteKeys {
        const key_sha256: ?[32]u8 = switch (given) {
            .none => null,
            .key => |digest| digest,
            .malformed => return .{ .refused = if (xml_api) xmlKeyReply(.malformed) else jsonKeyReply(.malformed) },
        };
        if (kms_key_name) |name| {
            if (key_sha256 != null) return .{ .refused = .{
                .status = 409,
                .body = "{\"error\":{\"code\":409,\"message\":\"Cannot provide both a Cloud KMS key and a csk encoded encryption scheme.\",\"errors\":[{\"reason\":\"conflict\"}]}}",
            } };
            if (std.mem.indexOf(u8, name, "/cryptoKeyVersions/") != null) return .{ .refused = .{
                .status = 400,
                .body = "{\"error\":{\"code\":400,\"message\":\"Malformed Cloud KMS crypto key\",\"errors\":[{\"reason\":\"invalid\"}]}}",
            } };
            if (!self.kms_granted) return .{ .refused = .{
                .status = 403,
                .body = if (xml_api)
                    "<?xml version='1.0' encoding='UTF-8'?><Error><Code>AccessDenied</Code><Message>Permission denied on Cloud KMS key. Please ensure that your Cloud Storage service account has been authorized to use this key.</Message></Error>"
                else
                    "{\"error\":{\"code\":403,\"message\":\"Permission denied on Cloud KMS key. Please ensure that your Cloud Storage service account has been authorized to use this key.\",\"errors\":[{\"reason\":\"forbidden\"}]}}",
            } };
        }
        return .{ .ok = .{ .key_sha256 = key_sha256, .kms_key_name = kms_key_name } };
    }

    /// A soft-deleted generation's metadata, which only its generation
    /// reads.
    fn readSoftDeleted(self: *FakeMultipart, target: JsonTarget, arena: Allocator) Allocator.Error!Reply {
        const generation = target.generation orelse return .{
            .status = 400,
            .body = "{\"error\":{\"code\":400,\"message\":\"You must specify a generation.\",\"errors\":[{\"reason\":\"required\"}]}}",
        };
        for (self.soft_deleted.items) |*o| if (std.mem.eql(u8, o.name, target.name) and o.generation == generation) {
            return .{ .status = 200, .body = try objectJson(self, arena, o, o.name, o.generation, target.bucket, false, false) };
        };
        return .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"No such object\",\"errors\":[{\"reason\":\"notFound\"}]}}" };
    }

    /// `objects.restore`: a new live generation made from a soft-deleted
    /// one, which stays where it is.
    fn restoreObject(self: *FakeMultipart, target: RestoreTarget, arena: Allocator) Allocator.Error!Reply {
        self.counts.restores += 1;
        if (!self.soft_delete) return .{
            .status = 400,
            .body = "{\"error\":{\"code\":400,\"message\":\"bucket soft delete policy must be set.\",\"errors\":[{\"reason\":\"invalid\"}]}}",
        };
        const generation = target.generation orelse return .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Required parameter: generation\"}}" };
        const source_index = for (self.soft_deleted.items, 0..) |o, i| {
            if (std.mem.eql(u8, o.name, target.name) and o.generation == generation) break i;
        } else return .{
            .status = 404,
            .body = try std.fmt.allocPrint(arena, "{{\"error\":{{\"code\":404,\"message\":\"No such object: {s}/{s}\",\"errors\":[{{\"reason\":\"notFound\"}}]}}}}", .{ target.bucket, target.name }),
        };
        const live = self.liveIndex(target.name);
        const holds = if (live) |i| target.conditions.check(&self.objects.items[i]) == .hold else target.conditions.checkAbsent();
        if (!holds) return condition_failed;

        // Everything that can fail first: once the lists change, nothing
        // may.
        var copy = try copyStored(self.gpa, &self.soft_deleted.items[source_index], self.next_generation);
        errdefer freeStored(self.gpa, &copy);
        copy.metageneration = 1;
        copy.retained_from_ns = self.now();
        // A restore needs no key, and answers without the checksums of an
        // object under one.
        const reply_body = try objectJson(self, arena, &copy, copy.name, copy.generation, target.bucket, false, false);
        try self.objects.ensureUnusedCapacity(self.gpa, 1);
        try self.soft_deleted.ensureUnusedCapacity(self.gpa, 1);
        self.next_generation += 1;
        if (live) |i| self.soft_deleted.appendAssumeCapacity(self.objects.orderedRemove(i));
        self.objects.appendAssumeCapacity(copy);
        return .{ .status = 200, .body = reply_body };
    }

    /// `objects.move`: the source, pinned to its generation, renamed to the
    /// destination under the destination's conditions, with a new
    /// generation, atomically. The source goes; an object it replaces goes.
    fn moveObject(self: *FakeMultipart, target: MoveTarget, fault: Fault, arena: Allocator) Allocator.Error!Reply {
        self.counts.moves += 1;
        const not_found: Reply = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"No such object\",\"errors\":[{\"reason\":\"notFound\"}]}}" };
        const destination_holds = if (self.liveIndex(target.destination)) |d|
            target.conditions.check(&self.objects.items[d]) == .hold
        else
            target.conditions.checkAbsent();
        if (self.move_checks_destination_first and !destination_holds) return condition_failed;
        const s = self.liveIndex(target.source) orelse return not_found;
        if (target.if_source_generation_match) |g| if (self.objects.items[s].generation != g) return condition_failed;
        if (!destination_holds) return condition_failed;
        if (std.mem.eql(u8, target.source, target.destination)) return .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"same name\"}}" };
        // A move takes its source away and replaces its destination.
        if (try self.keptRefusal(.json, target.bucket, &self.objects.items[s], arena)) |refusal| return refusal;
        if (try self.keptLive(.json, target.bucket, target.destination, arena)) |refusal| return refusal;

        // The reply and the new name first: once the objects change,
        // nothing may fail.
        const generation = self.next_generation;
        // So does a move.
        const reply_body = try objectJson(self, arena, &self.objects.items[s], target.destination, generation, target.bucket, fault == .corrupt, false);
        const name = try self.gpa.dupe(u8, target.destination);
        self.next_generation += 1;
        if (self.liveIndex(target.destination)) |d| {
            var replaced = self.objects.orderedRemove(d);
            freeStored(self.gpa, &replaced);
        }
        const moved = &self.objects.items[self.liveIndex(target.source).?];
        self.gpa.free(moved.name);
        moved.name = name;
        moved.generation = generation;
        moved.metageneration = 1;
        moved.retained_from_ns = self.now();
        return .{ .status = 200, .body = reply_body };
    }

    fn liveIndex(self: *const FakeMultipart, name: []const u8) ?usize {
        for (self.objects.items, 0..) |o, i| if (std.mem.eql(u8, o.name, name)) return i;
        return null;
    }

    /// An object's bytes as the media endpoint serves them: whole, or the one
    /// range asked for, with the whole object's hash either way, as
    /// fake-gcs-server sends it. An object stored gzip-compressed is served
    /// decompressed and whole, the range ignored, as Cloud Storage
    /// transcodes it.
    /// A gzip object comes decompressed, whole whatever range was asked,
    /// unless the request takes gzip as sent: then its stored bytes come,
    /// ranges and all, with `Content-Encoding: gzip`, as Cloud Storage and
    /// fake-gcs-server serve them.
    fn media(o: *const Stored, headers: []const Header, accept_gzip: bool, fault: Fault, arena: Allocator) Allocator.Error!Reply {
        const hash = core.crc32c.toBase64(core.crc32c.hash(o.bytes));
        var reply_headers: std.ArrayList(Header) = .empty;
        try reply_headers.append(arena, .{ .name = "x-goog-generation", .value = try std.fmt.allocPrint(arena, "{d}", .{o.generation}) });
        try reply_headers.append(arena, .{ .name = "x-goog-hash", .value = try std.fmt.allocPrint(arena, "crc32c={s}", .{&hash}) });
        try reply_headers.append(arena, .{ .name = "x-goog-stored-content-length", .value = try std.fmt.allocPrint(arena, "{d}", .{o.bytes.len}) });
        if (o.served) |served| {
            try reply_headers.append(arena, .{ .name = "x-goog-stored-content-encoding", .value = "gzip" });
            if (!accept_gzip) return .{ .status = 200, .headers = reply_headers.items, .body = served, .cut = fault == .cut };
            try reply_headers.append(arena, .{ .name = "Content-Encoding", .value = "gzip" });
        }
        const size = o.bytes.len;
        var start: usize = 0;
        var end: usize = size;
        var partial = false;
        if (requestedRange(headers)) |range| {
            if (range.start >= size) {
                try reply_headers.append(arena, .{ .name = "Content-Range", .value = try std.fmt.allocPrint(arena, "bytes */{d}", .{size}) });
                return .{ .status = 416, .headers = reply_headers.items, .body = "<Error><Code>InvalidRange</Code></Error>" };
            }
            start = @intCast(range.start);
            if (range.last) |last| end = @intCast(@min(last + 1, size));
            partial = true;
        }
        switch (fault) {
            .short => if (end - start > 1) {
                end -= 1;
            },
            .long => if (partial and end < size) {
                end += 1;
            },
            else => {},
        }
        var body: []const u8 = o.bytes[start..end];
        if (fault == .corrupt and body.len > 0) {
            const flipped = try arena.dupe(u8, body);
            flipped[flipped.len / 2] ^= 0x01;
            body = flipped;
        }
        if (partial) try reply_headers.append(arena, .{
            .name = "Content-Range",
            .value = try std.fmt.allocPrint(arena, "bytes {d}-{d}/{d}", .{ start, end - 1, size }),
        });
        return .{ .status = if (partial) 206 else 200, .headers = reply_headers.items, .body = body, .cut = fault == .cut };
    }

    fn multipartRequest(
        self: *FakeMultipart,
        kind: Kind,
        target: XmlTarget,
        content_type: ?[]const u8,
        headers: []const Header,
        body: []const u8,
        fault: Fault,
        arena: Allocator,
    ) Allocator.Error!Reply {
        const gone: Reply = .{ .status = 404, .body = "<?xml version='1.0' encoding='UTF-8'?><Error><Code>NoSuchUpload</Code><Message>The requested upload was not found.</Message></Error>" };
        switch (kind) {
            .start => {
                self.counts.starts += 1;
                const keys = switch (self.writeKeys(requestKey(headers, object_key_prefix), headerValue(headers, "x-goog-encryption-kms-key-name"), true)) {
                    .ok => |k| k,
                    .refused => |reply| return reply,
                };
                // The reply first: once the upload is stored, nothing
                // may fail and free what it owns.
                const id_text = try std.fmt.allocPrint(arena, "VXBs+{d}=", .{self.next_upload});
                const reply_body = try std.fmt.allocPrint(arena, "<?xml version='1.0' encoding='UTF-8'?>\n" ++
                    "<InitiateMultipartUploadResult xmlns='http://s3.amazonaws.com/doc/2006-03-01/'>" ++
                    "<Bucket>{s}</Bucket><Key>{s}</Key><UploadId>{s}</UploadId></InitiateMultipartUploadResult>", .{ target.bucket, target.name, id_text });
                const id = try self.gpa.dupe(u8, id_text);
                errdefer self.gpa.free(id);
                const name = try self.gpa.dupe(u8, target.name);
                errdefer self.gpa.free(name);
                const stored_type = try self.gpa.dupe(u8, content_type orelse "");
                errdefer self.gpa.free(stored_type);
                const metadata = try metaHeaders(self.gpa, headers);
                errdefer freeHeaders(self.gpa, metadata);
                const kms = if (keys.kms_key_name) |k| try self.gpa.dupe(u8, k) else null;
                errdefer if (kms) |k| self.gpa.free(k);
                try self.uploads.append(self.gpa, .{
                    .id = id,
                    .name = name,
                    .content_type = stored_type,
                    .metadata = metadata,
                    .key_sha256 = keys.key_sha256,
                    .kms_key_name = kms,
                });
                self.next_upload += 1;
                return .{ .status = 200, .body = reply_body };
            },
            .part => {
                self.counts.parts += 1;
                const upload_id = target.query.part.upload_id;
                const index = self.uploadIndex(upload_id) orelse return gone;
                if (fault == .gone) return self.drop(index, gone);
                if (keyFault(self.uploads.items[index].key_sha256, requestKey(headers, object_key_prefix))) |key_fault| return xmlKeyReply(key_fault);
                const number = target.query.part.number;
                if (number < 1 or number > 10_000) return .{ .status = 400, .body = "<Error><Code>InvalidArgument</Code></Error>" };
                const bytes = try self.gpa.dupe(u8, body);
                errdefer self.gpa.free(bytes);
                if (fault == .corrupt and bytes.len > 0) bytes[bytes.len / 2] ^= 0x01;
                const crc = core.crc32c.hash(bytes);
                const hash = core.crc32c.toBase64(crc);
                const etag_text = try std.fmt.allocPrint(arena, "\"{x:0>8}{d}\"", .{ crc, bytes.len });
                const reply_headers = try replyHeaders(arena, &.{
                    .{ .name = "ETag", .value = etag_text },
                    .{ .name = "x-goog-hash", .value = try std.fmt.allocPrint(arena, "crc32c={s}", .{&hash}) },
                });
                const etag = try self.gpa.dupe(u8, etag_text);
                errdefer self.gpa.free(etag);
                const u = &self.uploads.items[index];
                const slot = try u.parts.getOrPut(self.gpa, number);
                if (slot.found_existing) freePart(self.gpa, slot.value_ptr);
                slot.value_ptr.* = .{ .bytes = bytes, .etag = etag };
                return .{ .status = 200, .headers = reply_headers };
            },
            .finish => {
                self.counts.finishes += 1;
                const index = self.uploadIndex(target.query.upload) orelse return gone;
                if (fault == .gone) return self.drop(index, gone);
                if (keyFault(self.uploads.items[index].key_sha256, requestKey(headers, object_key_prefix))) |key_fault| return xmlKeyReply(key_fault);
                if (fault == .error_200) return .{ .status = 200, .body = "<Error><Code>InternalError</Code><Message>We encountered an internal error. Please try again.</Message></Error>" };
                return self.finishUpload(target.bucket, index, body, fault, arena);
            },
            .abort => {
                self.counts.aborts += 1;
                const index = self.uploadIndex(target.query.upload) orelse return gone;
                return self.drop(index, .{ .status = 204 });
            },
            .list => {
                self.counts.lists += 1;
                const index = self.uploadIndex(target.query.upload) orelse return gone;
                if (fault == .gone) return self.drop(index, gone);
                return self.listParts(index, target, arena);
            },
            .read, .delete, .media, .move, .session_start, .session_put, .session_cancel, .insert, .bucket, .restore, .patch => unreachable,
        }
    }

    /// One ListParts page: the parts past `marker`, ascending, at most
    /// `max_parts` of them, with `IsTruncated` and `NextPartNumberMarker`
    /// leading to the next. As Cloud Storage, no checksum appears anywhere.
    fn listParts(self: *FakeMultipart, index: usize, target: XmlTarget, arena: Allocator) Allocator.Error!Reply {
        const u = &self.uploads.items[index];
        const numbers = try arena.dupe(u32, u.parts.keys());
        std.mem.sort(u32, numbers, {}, std.sort.asc(u32));
        var from: usize = 0;
        while (from < numbers.len and numbers[from] <= target.marker) from += 1;
        const count = @min(numbers.len - from, target.max_parts);
        const page = numbers[from..][0..count];
        const truncated = from + count < numbers.len;

        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        const print = struct {
            fn go(writer: *std.Io.Writer, comptime format: []const u8, args: anytype) Allocator.Error!void {
                writer.print(format, args) catch return error.OutOfMemory;
            }
        }.go;
        try print(w, "<?xml version='1.0' encoding='UTF-8'?>" ++
            "<ListPartsResult xmlns='http://s3.amazonaws.com/doc/2006-03-01/'>" ++
            "<Bucket>{s}</Bucket><Key>{s}</Key><UploadId>{s}</UploadId>" ++
            "<PartNumberMarker>{d}</PartNumberMarker><MaxParts>{d}</MaxParts>", .{
            target.bucket, target.name, u.id, target.marker, target.max_parts,
        });
        if (truncated) try print(w, "<NextPartNumberMarker>{d}</NextPartNumberMarker>", .{page[page.len - 1]});
        try print(w, "<IsTruncated>{s}</IsTruncated>", .{if (truncated) "true" else "false"});
        for (page) |number| {
            const part = u.parts.get(number).?;
            try print(w, "<Part><PartNumber>{d}</PartNumber>" ++
                "<LastModified>2026-09-24T00:00:00.000Z</LastModified>" ++
                "<ETag>{s}</ETag><Size>{d}</Size></Part>", .{ number, part.etag, part.bytes.len });
        }
        try print(w, "</ListPartsResult>", .{});
        return .{ .status = 200, .body = out.written() };
    }

    fn finishUpload(self: *FakeMultipart, bucket: []const u8, index: usize, body: []const u8, fault: Fault, arena: Allocator) Allocator.Error!Reply {
        const invalid_part: Reply = .{ .status = 400, .body = "<Error><Code>InvalidPart</Code></Error>" };
        const u = &self.uploads.items[index];
        // Refused after its parts went up, and the upload stays open.
        if (try self.keptLive(.xml, bucket, u.name, arena)) |refusal| return refusal;
        const root = xml.parse(arena, body) catch return invalid_part;
        if (!std.mem.eql(u8, root.name, "CompleteMultipartUpload") or root.children.len == 0) return invalid_part;
        var assembled: std.ArrayList(u8) = .empty;
        defer assembled.deinit(self.gpa);
        var previous: u32 = 0;
        for (root.children, 0..) |part, i| {
            const number = std.fmt.parseInt(u32, part.childText("PartNumber") orelse "", 10) catch return invalid_part;
            if (number <= previous) return .{ .status = 400, .body = "<Error><Code>InvalidPartOrder</Code></Error>" };
            previous = number;
            const stored = u.parts.get(number) orelse return invalid_part;
            if (!std.mem.eql(u8, stored.etag, part.childText("ETag") orelse "")) return invalid_part;
            const last = i + 1 == root.children.len;
            if (!last and stored.bytes.len < self.min_part_size) return .{ .status = 400, .body = "<Error><Code>EntityTooSmall</Code></Error>" };
            try assembled.appendSlice(self.gpa, stored.bytes);
        }
        if (fault == .corrupt and assembled.items.len > 0) assembled.items[0] ^= 0x01;

        const generation = self.next_generation;
        const bytes = try assembled.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(bytes);
        const hash = core.crc32c.toBase64(core.crc32c.hash(bytes));
        // The reply, and room for the object, before anything changes. An
        // upload under a key of either kind finishes with no checksum.
        const keyed = u.key_sha256 != null or u.kms_key_name != null;
        const all_headers = [_]Header{
            .{ .name = "x-goog-generation", .value = try std.fmt.allocPrint(arena, "{d}", .{generation}) },
            .{ .name = "x-goog-hash", .value = try std.fmt.allocPrint(arena, "crc32c={s}", .{&hash}) },
        };
        const reply_headers = try replyHeaders(arena, all_headers[0..if (keyed) 1 else 2]);
        try self.objects.ensureUnusedCapacity(self.gpa, 1);
        self.next_generation += 1;
        // A finish replaces any object of the name.
        for (self.objects.items, 0..) |o, i| if (std.mem.eql(u8, o.name, u.name)) {
            var old = self.objects.orderedRemove(i);
            freeStored(self.gpa, &old);
            break;
        };
        // The upload's name, content type and metadata move to the object.
        self.objects.appendAssumeCapacity(.{
            .name = u.name,
            .generation = generation,
            .bytes = bytes,
            .content_type = u.content_type,
            .metadata = u.metadata,
            .key_sha256 = u.key_sha256,
            .kms_key_name = u.kms_key_name,
            // The XML API sets no hold; the bucket's default applies.
            .holds = self.newHolds(bucket, .{}),
            .retained_from_ns = self.now(),
        });
        u.name = u.name[0..0];
        u.content_type = u.content_type[0..0];
        u.metadata = u.metadata[0..0];
        u.kms_key_name = null;
        var removed = self.uploads.orderedRemove(index);
        freeUpload(self.gpa, &removed);
        return .{
            .status = 200,
            .headers = reply_headers,
            .body = "<?xml version='1.0' encoding='UTF-8'?><CompleteMultipartUploadResult><ETag>\"fake-etag\"</ETag></CompleteMultipartUploadResult>",
        };
    }

    fn uploadIndex(self: *const FakeMultipart, id: []const u8) ?usize {
        for (self.uploads.items, 0..) |u, i| if (std.mem.eql(u8, u.id, id)) return i;
        return null;
    }

    const session_not_found: Reply = .{ .status = 404, .body = "No such upload." };
    /// What Google answers a cancel, and everything sent to the session
    /// after it.
    const session_cancelled: Reply = .{ .status = 499 };

    /// Opens a session: the object's name and claimed checksum come from
    /// the metadata body, the conditions from the query, and they are
    /// checked here, at the opening `objects.insert`.
    fn sessionStart(
        self: *FakeMultipart,
        target: ResumableTarget,
        content_type: ?[]const u8,
        headers: []const Header,
        body: []const u8,
        arena: Allocator,
    ) Allocator.Error!Reply {
        self.counts.session_starts += 1;
        _ = content_type;
        const keys = switch (self.writeKeys(requestKey(headers, object_key_prefix), target.kms_key_name, false)) {
            .ok => |k| k,
            .refused => |reply| return reply,
        };
        const meta = std.json.parseFromSliceLeaky(Meta, arena, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"bad metadata\"}}" },
        };
        if (meta.name.len == 0) return .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"no name\"}}" };
        const held = if (self.liveIndex(meta.name)) |i|
            target.conditions.check(&self.objects.items[i]) == .hold
        else
            target.conditions.checkAbsent();
        if (!held) return condition_failed;
        const retention = switch (try self.uploadRetention(target.bucket, meta, arena)) {
            .refused => |reply| return reply,
            .ok => |r| r,
        };

        const declared: ?u64 = if (headerValue(headers, "X-Upload-Content-Length")) |text|
            std.fmt.parseInt(u64, text, 10) catch null
        else
            null;
        const metadata_crc: ?u32 = if (meta.crc32c) |text| core.crc32c.fromBase64(text) catch null else null;
        const id_text = try std.fmt.allocPrint(arena, "sess-{d}", .{self.next_session});
        // As Google's, the session URL carries the project its start billed.
        const location = if (target.user_project) |project|
            try std.fmt.allocPrint(arena, "{s}/upload/session/{s}?userProject={s}", .{ target.origin, id_text, project })
        else
            try std.fmt.allocPrint(arena, "{s}/upload/session/{s}", .{ target.origin, id_text });
        const id = try self.gpa.dupe(u8, id_text);
        errdefer self.gpa.free(id);
        const name = try self.gpa.dupe(u8, meta.name);
        errdefer self.gpa.free(name);
        const stored_type = try self.gpa.dupe(u8, meta.contentType orelse "application/octet-stream");
        errdefer self.gpa.free(stored_type);
        const bucket = try self.gpa.dupe(u8, target.bucket);
        errdefer self.gpa.free(bucket);
        const kms = if (keys.kms_key_name) |k| try self.gpa.dupe(u8, k) else null;
        errdefer if (kms) |k| self.gpa.free(k);
        try self.sessions.append(self.gpa, .{
            .id = id,
            .bucket = bucket,
            .name = name,
            .content_type = stored_type,
            .declared = declared,
            .metadata_crc = metadata_crc,
            .gzip = meta.gzip(),
            .key_sha256 = keys.key_sha256,
            .kms_key_name = kms,
            .holds = .{ .temporary = meta.temporaryHold, .event_based = meta.eventBasedHold },
            .retention = retention,
        });
        self.next_session += 1;
        return .{ .status = 200, .headers = try replyHeaders(arena, &.{.{ .name = "Location", .value = location }}) };
    }

    fn sessionIndex(self: *const FakeMultipart, id: []const u8) ?usize {
        for (self.sessions.items, 0..) |s, i| if (std.mem.eql(u8, s.id, id)) return i;
        return null;
    }

    /// One PUT to a session: a chunk, the empty finalize, or the status
    /// query, which are the same request, told apart only by what the
    /// session already holds.
    fn sessionPut(self: *FakeMultipart, id: []const u8, headers: []const Header, body: []const u8, fault: Fault, arena: Allocator) Allocator.Error!Reply {
        self.counts.session_puts += 1;
        const index = self.sessionIndex(id) orelse return session_not_found;
        if (self.sessions.items[index].cancelled) return session_cancelled;
        if (fault == .gone) {
            var removed = self.sessions.orderedRemove(index);
            freeSession(self.gpa, &removed);
            return session_not_found;
        }
        const s = &self.sessions.items[index];
        if (s.done) |generation| {
            // A finished session keeps answering with its object while
            // that object stands.
            for (self.objects.items) |*o| {
                if (o.generation == generation and std.mem.eql(u8, o.name, s.name)) {
                    return .{ .status = 200, .body = try objectJson(self, arena, o, o.name, generation, s.bucket, false, true) };
                }
            }
            return session_not_found;
        }
        const range = sessionRange(headers) orelse return .{ .status = 400, .body = "no Content-Range" };
        switch (range) {
            .query => |total| {
                if (total) |declared| if (s.bytes.items.len == declared) {
                    return self.finishSession(index, headers, arena);
                };
                return sessionProgress(arena, s.bytes.items.len);
            },
            .chunk => |chunk| {
                if (chunk.end < chunk.start or body.len != chunk.end - chunk.start + 1) {
                    return .{ .status = 400, .body = "the body does not match its Content-Range" };
                }
                // Cloud Storage holds an upload to the length its opening
                // declared.
                if (s.declared) |declared| {
                    const past = chunk.end + 1 > declared;
                    const other_total = if (chunk.total) |total| total != declared else false;
                    if (past or other_total) return .{ .status = 400, .body = "the upload's length is not the X-Upload-Content-Length it declared" };
                }
                const held = s.bytes.items.len;
                if (chunk.start > held) return sessionProgress(arena, held);
                // Bytes already stored cannot be overwritten; the tail is
                // new.
                const fresh = body[@intCast(held - chunk.start)..];
                try s.bytes.appendSlice(self.gpa, fresh);
                self.counts.session_bytes += fresh.len;
                self.counts.session_stale_bytes += body.len - fresh.len;
                if (fault == .corrupt and fresh.len > 0) {
                    s.bytes.items[s.bytes.items.len - fresh.len / 2 - 1] ^= 0x01;
                }
                if (chunk.total) |declared| if (s.bytes.items.len == declared) {
                    return self.finishSession(index, headers, arena);
                };
                return sessionProgress(arena, s.bytes.items.len);
            },
        }
    }

    /// Finishes a session into an object, checking the checksum the
    /// finishing request carries and the one the metadata claimed, before
    /// the object exists.
    fn finishSession(self: *FakeMultipart, index: usize, headers: []const Header, arena: Allocator) Allocator.Error!Reply {
        const s = &self.sessions.items[index];
        const actual = core.crc32c.hash(s.bytes.items);
        const claimed: ?u32 = if (headerValue(headers, "X-Goog-Hash")) |value| crc32cFromHash(value) else null;
        const mismatch: Reply = .{
            .status = 400,
            .body = "{\"error\":{\"code\":400,\"message\":\"Provided CRC32C does not match calculated CRC32C\",\"errors\":[{\"reason\":\"invalid\"}]}}",
        };
        if (claimed) |wanted| if (wanted != actual) return mismatch;
        if (s.metadata_crc) |wanted| if (wanted != actual) return mismatch;
        // Refused at the final PUT, after every byte went up.
        if (try self.keptLive(.json, s.bucket, s.name, arena)) |refusal| return refusal;

        const o = try self.store(s.bucket, s.name, s.bytes.items, s.content_type, s.gzip, s.key_sha256, s.kms_key_name, s.holds);
        o.retention = s.retention;
        s.done = o.generation;
        s.bytes.clearAndFree(self.gpa);
        return .{ .status = 200, .body = try objectJson(self, arena, o, o.name, o.generation, s.bucket, false, true) };
    }

    /// Stores `bytes` as the live object `name` at the next generation,
    /// replacing any. One whose metadata said gzip is served decompressed
    /// to a request that does not take gzip as sent, as Cloud Storage
    /// transcodes it; its bytes are not checked here, and ones that do not
    /// decompress are served as nothing.
    fn store(
        self: *FakeMultipart,
        bucket: []const u8,
        name: []const u8,
        bytes: []const u8,
        content_type: []const u8,
        gzip: bool,
        key_sha256: ?[32]u8,
        kms_key_name: ?[]const u8,
        holds: Holds,
    ) Allocator.Error!*Stored {
        const owned_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned_name);
        const kms = if (kms_key_name) |k| try self.gpa.dupe(u8, k) else null;
        errdefer if (kms) |k| self.gpa.free(k);
        const owned_bytes = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(owned_bytes);
        const stored_type = try self.gpa.dupe(u8, content_type);
        errdefer self.gpa.free(stored_type);
        const metadata = try self.gpa.alloc(Header, 0);
        errdefer self.gpa.free(metadata);
        const served: ?[]u8 = if (gzip) try gunzipOrEmpty(self.gpa, bytes) else null;
        errdefer if (served) |d| self.gpa.free(d);
        try self.objects.ensureUnusedCapacity(self.gpa, 1);
        const generation = self.next_generation;
        self.next_generation += 1;
        if (self.liveIndex(name)) |i| {
            var replaced = self.objects.orderedRemove(i);
            freeStored(self.gpa, &replaced);
        }
        self.objects.appendAssumeCapacity(.{
            .name = owned_name,
            .generation = generation,
            .bytes = owned_bytes,
            .content_type = stored_type,
            .metadata = metadata,
            .served = served,
            .key_sha256 = key_sha256,
            .kms_key_name = kms,
            .holds = self.newHolds(bucket, holds),
            .retained_from_ns = self.now(),
        });
        return &self.objects.items[self.objects.items.len - 1];
    }

    /// A one-request `uploadType=multipart` upload: the metadata part, then
    /// the data, checked against the metadata's crc32c and the query's
    /// conditions before the object exists.
    fn insertObject(self: *FakeMultipart, target: InsertTarget, content_type: ?[]const u8, headers: []const Header, body: []const u8, arena: Allocator) Allocator.Error!Reply {
        self.counts.inserts += 1;
        const keys = switch (self.writeKeys(requestKey(headers, object_key_prefix), target.kms_key_name, false)) {
            .ok => |k| k,
            .refused => |reply| return reply,
        };
        const bad: Reply = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"bad multipart body\"}}" };
        const parts = splitMultipart(arena, content_type orelse return bad, body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Malformed => return bad,
        };
        const meta = std.json.parseFromSliceLeaky(Meta, arena, parts.metadata, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return bad,
        };
        if (meta.name.len == 0) return bad;
        const held = if (self.liveIndex(meta.name)) |i|
            target.conditions.check(&self.objects.items[i]) == .hold
        else
            target.conditions.checkAbsent();
        if (!held) return condition_failed;
        if (meta.crc32c) |text| {
            const wanted = core.crc32c.fromBase64(text) catch return bad;
            if (wanted != core.crc32c.hash(parts.data)) return .{
                .status = 400,
                .body = "{\"error\":{\"code\":400,\"message\":\"Provided CRC32C does not match calculated CRC32C\",\"errors\":[{\"reason\":\"invalid\"}]}}",
            };
        }
        if (try self.keptLive(.json, target.bucket, meta.name, arena)) |refusal| return refusal;
        const holds: Holds = .{ .temporary = meta.temporaryHold, .event_based = meta.eventBasedHold };
        const retention = switch (try self.uploadRetention(target.bucket, meta, arena)) {
            .refused => |reply| return reply,
            .ok => |r| r,
        };
        const o = try self.store(target.bucket, meta.name, parts.data, meta.contentType orelse "application/octet-stream", meta.gzip(), keys.key_sha256, keys.kms_key_name, holds);
        o.retention = retention;
        return .{ .status = 200, .body = try objectJson(self, arena, o, o.name, o.generation, target.bucket, false, true) };
    }

    fn sessionCancel(self: *FakeMultipart, id: []const u8) Reply {
        self.counts.session_cancels += 1;
        const index = self.sessionIndex(id) orelse return session_not_found;
        const s = &self.sessions.items[index];
        if (s.done == null) {
            // A live session stays, answering 499 from now on.
            s.cancelled = true;
            s.bytes.clearAndFree(self.gpa);
            return session_cancelled;
        }
        var removed = self.sessions.orderedRemove(index);
        freeSession(self.gpa, &removed);
        return session_cancelled;
    }

    fn drop(self: *FakeMultipart, index: usize, reply: Reply) Reply {
        var removed = self.uploads.orderedRemove(index);
        freeUpload(self.gpa, &removed);
        return reply;
    }
};

fn metaHeaders(gpa: Allocator, headers: []const Header) Allocator.Error![]Header {
    var list: std.ArrayList(Header) = .empty;
    errdefer {
        for (list.items) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        list.deinit(gpa);
    }
    for (headers) |h| {
        if (h.name.len <= "x-goog-meta-".len or !std.ascii.startsWithIgnoreCase(h.name, "x-goog-meta-")) continue;
        const name = try std.ascii.allocLowerString(gpa, h.name["x-goog-meta-".len..]);
        errdefer gpa.free(name);
        const value = try gpa.dupe(u8, h.value);
        errdefer gpa.free(value);
        try list.append(gpa, .{ .name = name, .value = value });
    }
    return list.toOwnedSlice(gpa);
}

fn replyHeaders(arena: Allocator, headers: []const Header) Allocator.Error![]const Header {
    return arena.dupe(Header, headers);
}

fn dupeHeaders(gpa: Allocator, headers: []const Header) Allocator.Error![]Header {
    const out = try gpa.alloc(Header, headers.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(out);
    }
    for (headers, out) |h, *copy| {
        const name = try gpa.dupe(u8, h.name);
        errdefer gpa.free(name);
        copy.* = .{ .name = name, .value = try gpa.dupe(u8, h.value) };
        done += 1;
    }
    return out;
}

fn freeHeaders(gpa: Allocator, headers: []Header) void {
    for (headers) |h| {
        gpa.free(h.name);
        gpa.free(h.value);
    }
    gpa.free(headers);
}

fn freePart(gpa: Allocator, part: *FakeMultipart.Part) void {
    gpa.free(part.bytes);
    gpa.free(part.etag);
}

fn freeSession(gpa: Allocator, s: *FakeMultipart.Session) void {
    if (s.kms_key_name) |k| gpa.free(k);
    gpa.free(s.id);
    gpa.free(s.bucket);
    gpa.free(s.name);
    gpa.free(s.content_type);
    s.bytes.deinit(gpa);
}

/// A 308 with how far the session stands, `Range` absent when it holds
/// nothing, as Google answers.
fn sessionProgress(arena: Allocator, held: usize) Allocator.Error!FakeMultipart.Reply {
    if (held == 0) return .{ .status = 308 };
    return .{ .status = 308, .headers = try arena.dupe(Header, &.{.{
        .name = "Range",
        .value = try std.fmt.allocPrint(arena, "bytes=0-{d}", .{held - 1}),
    }}) };
}

/// What one `Content-Range` on a session PUT asks: a chunk of bytes, or
/// the query-or-finalize form.
const SessionRange = union(enum) {
    /// `bytes */T`, T null for `*`.
    query: ?u64,
    chunk: struct { start: u64, end: u64, total: ?u64 },
};

fn sessionRange(headers: []const Header) ?SessionRange {
    const value = headerValue(headers, "Content-Range") orelse return null;
    const rest = std.mem.trim(u8, value, " \t");
    if (!std.ascii.startsWithIgnoreCase(rest, "bytes ")) return null;
    const spec = rest["bytes ".len..];
    const slash = std.mem.indexOfScalar(u8, spec, '/') orelse return null;
    const total: ?u64 = if (std.mem.eql(u8, spec[slash + 1 ..], "*"))
        null
    else
        std.fmt.parseInt(u64, spec[slash + 1 ..], 10) catch return null;
    const head = spec[0..slash];
    if (std.mem.eql(u8, head, "*")) return .{ .query = total };
    const dash = std.mem.indexOfScalar(u8, head, '-') orelse return null;
    const start = std.fmt.parseInt(u64, head[0..dash], 10) catch return null;
    const end = std.fmt.parseInt(u64, head[dash + 1 ..], 10) catch return null;
    return .{ .chunk = .{ .start = start, .end = end, .total = total } };
}

/// What a fault plan sees as a session PUT's `part`: 1 plus the chunk's
/// first byte, or 0 for the query-or-finalize form.
fn sessionPart(headers: []const Header) u32 {
    const range = sessionRange(headers) orelse return 0;
    return switch (range) {
        .query => 0,
        .chunk => |chunk| std.math.cast(u32, chunk.start +| 1) orelse std.math.maxInt(u32),
    };
}

/// Where a customer-supplied key's three headers start.
const object_key_prefix = "x-goog-encryption-";
const copy_source_key_prefix = "x-goog-copy-source-encryption-";

/// What a request's customer-key headers carry.
const RequestKey = union(enum) {
    none,
    /// The key's SHA-256: the three headers agree.
    key: [32]u8,
    /// Some of the three, or three that do not agree.
    malformed,
};

fn requestKey(headers: []const Header, comptime prefix: []const u8) RequestKey {
    const algorithm = headerValue(headers, prefix ++ "algorithm");
    const key_text = headerValue(headers, prefix ++ "key");
    const sha_text = headerValue(headers, prefix ++ "key-sha256");
    if (algorithm == null and key_text == null and sha_text == null) return .none;
    if (!std.mem.eql(u8, algorithm orelse "", "AES256")) return .malformed;
    const decoder = std.base64.standard.Decoder;
    var raw: [32]u8 = undefined;
    const k = key_text orelse return .malformed;
    if ((decoder.calcSizeForSlice(k) catch return .malformed) != 32) return .malformed;
    decoder.decode(&raw, k) catch return .malformed;
    var claimed: [32]u8 = undefined;
    const c = sha_text orelse return .malformed;
    if ((decoder.calcSizeForSlice(c) catch return .malformed) != 32) return .malformed;
    decoder.decode(&claimed, c) catch return .malformed;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&raw, &digest, .{});
    if (!std.mem.eql(u8, &digest, &claimed)) return .malformed;
    return .{ .key = digest };
}

const KeyFault = enum { missing, wrong, unexpected, malformed };

/// How a request's key fails what is stored under `stored`, or null when
/// it fits.
fn keyFault(stored: ?[32]u8, given: RequestKey) ?KeyFault {
    switch (given) {
        .malformed => return .malformed,
        .none => return if (stored != null) .missing else null,
        .key => |digest| {
            const want = stored orelse return .unexpected;
            return if (std.mem.eql(u8, &want, &digest)) null else .wrong;
        },
    }
}

const malformed_key_message = "Missing a SHA256 hash of the encryption key, or it is not base64 encoded, or it does not match the encryption key.";

fn jsonKeyReply(fault: KeyFault) FakeMultipart.Reply {
    return .{ .status = 400, .body = switch (fault) {
        .missing => "{\"error\":{\"code\":400,\"message\":\"The target object is encrypted by a customer-supplied encryption key.\",\"errors\":[{\"reason\":\"resourceIsEncryptedWithCustomerEncryptionKey\"}]}}",
        .wrong => "{\"error\":{\"code\":400,\"message\":\"The provided encryption key is incorrect.\",\"errors\":[{\"reason\":\"customerEncryptionKeyIsIncorrect\"}]}}",
        .unexpected => "{\"error\":{\"code\":400,\"message\":\"The target object is not encrypted by a customer-supplied encryption key.\",\"errors\":[{\"reason\":\"resourceNotEncryptedWithCustomerEncryptionKey\"}]}}",
        .malformed => "{\"error\":{\"code\":400,\"message\":\"" ++ malformed_key_message ++ "\",\"errors\":[{\"reason\":\"invalid\"}]}}",
    } };
}

/// A media read's refusals are plain text.
fn mediaKeyReply(fault: KeyFault) FakeMultipart.Reply {
    return .{ .status = 400, .body = switch (fault) {
        .missing => "The target object is encrypted by a customer-supplied encryption key.",
        .wrong => "The provided encryption key is incorrect.",
        .unexpected => "The target object is not encrypted by a customer-supplied encryption key.",
        .malformed => malformed_key_message,
    } };
}

fn xmlKeyReply(fault: KeyFault) FakeMultipart.Reply {
    const start = "<?xml version='1.0' encoding='UTF-8'?><Error>";
    return .{ .status = 400, .body = switch (fault) {
        .missing => start ++ "<Code>ResourceIsEncryptedWithCustomerEncryptionKey</Code><Message>The resource is encrypted with a customer encryption key.</Message><Details>The requested multipart upload is encrypted by a customer-supplied encryption key.</Details></Error>",
        .wrong => start ++ "<Code>CustomerEncryptionKeyIsIncorrect</Code><Message>The provided encryption key is incorrect.</Message><Details>The requested multipart upload is encrypted by a different customer-supplied key.</Details></Error>",
        .unexpected => start ++ "<Code>ResourceNotEncryptedWithCustomerEncryptionKey</Code><Message>The resource is not encrypted with a customer encryption key.</Message><Details>The requested multipart upload is not encrypted by a customer-supplied encryption key.</Details></Error>",
        .malformed => start ++ "<Code>InvalidArgument</Code><Message>" ++ malformed_key_message ++ "</Message></Error>",
    } };
}

/// The answer to a request carrying a key where this library must never
/// send one, else null. Read before the lock: it touches no state.
fn keyRefusal(kind: FakeMultipart.Kind, target: Target, url: []const u8, headers: []const Header, arena: Allocator) Allocator.Error!?FakeMultipart.Reply {
    const takes_key = switch (kind) {
        .start, .part, .finish, .media, .insert, .session_start, .patch => true,
        // A soft-deleted object's metadata is read without one.
        .read => !target.json.soft_deleted,
        else => false,
    };
    const what: ?[]const u8 = if (requestKey(headers, copy_source_key_prefix) != .none)
        "a copy-source key"
    else if (requestKey(headers, object_key_prefix) != .none and !takes_key)
        "a customer-supplied key"
    else if (headerValue(headers, "x-goog-encryption-kms-key-name") != null and kind != .start)
        "a KMS key header"
    else if (std.mem.indexOf(u8, url, "msKeyName=") != null and kind != .insert and kind != .session_start)
        "a KMS key parameter"
    else
        null;
    const w = what orelse return null;
    return .{ .status = 400, .body = try std.fmt.allocPrint(
        arena,
        "{{\"error\":{{\"code\":400,\"message\":\"this fake refuses what this library must never send: {s} on a {t}\"}}}}",
        .{ w, kind },
    ) };
}

/// A 400 for an idempotency token where this library sends none: on a
/// read, the XML API, or a resumable session's chunks and cancel.
fn tokenRefusal(kind: FakeMultipart.Kind, method: Method, headers: []const Header, arena: Allocator) Allocator.Error!?FakeMultipart.Reply {
    if (headerValue(headers, "X-Goog-Gcs-Idempotency-Token") == null) return null;
    const takes_token = switch (kind) {
        .delete, .move, .insert, .session_start, .restore, .patch => true,
        .bucket => method != .GET,
        else => false,
    };
    if (takes_token) return null;
    return .{ .status = 400, .body = try std.fmt.allocPrint(
        arena,
        "{{\"error\":{{\"code\":400,\"message\":\"this fake refuses what this library must never send: an idempotency token on a {t} {t}\"}}}}",
        .{ method, kind },
    ) };
}

/// What a write's answer is kept under: its idempotency token, its kind and
/// its resource, or null for a request without a token, or of a kind whose
/// repeats run again (a resumable start, compose, rewrite, restore, the
/// XML API, buckets). Production keys on more than the token: the same
/// token on another object name runs normally.
fn keptKey(arena: Allocator, kind: FakeMultipart.Kind, target: Target, headers: []const Header, content_type: ?[]const u8, body: []const u8) Allocator.Error!?[]const u8 {
    const token = headerValue(headers, "X-Goog-Gcs-Idempotency-Token") orelse return null;
    const resource: []const u8 = switch (kind) {
        .delete, .patch => try std.fmt.allocPrint(arena, "{s}/{s}#{?d}", .{ target.json.bucket, target.json.name, target.json.generation }),
        .move => try std.fmt.allocPrint(arena, "{s}/{s}>{s}", .{ target.move.bucket, target.move.source, target.move.destination }),
        .insert => try std.fmt.allocPrint(arena, "{s}/{s}", .{ target.insert.bucket, try insertedName(arena, content_type, body) orelse return null }),
        else => return null,
    };
    return try std.fmt.allocPrint(arena, "{s} {t} {s}", .{ token, kind, resource });
}

/// The name a one-request upload names in its metadata, or null for a
/// body that does not parse, which the upload itself refuses.
fn insertedName(arena: Allocator, content_type: ?[]const u8, body: []const u8) Allocator.Error!?[]const u8 {
    const parts = splitMultipart(arena, content_type orelse return null, body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Malformed => return null,
    };
    const meta = std.json.parseFromSliceLeaky(struct { name: []const u8 = "" }, arena, parts.metadata, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return meta.name;
}

/// The name a `clobber` fault puts another writer's object under.
fn clobbered(arena: Allocator, kind: FakeMultipart.Kind, target: Target, content_type: ?[]const u8, body: []const u8) Allocator.Error!?[]const u8 {
    return switch (kind) {
        .move => target.move.destination,
        .delete => target.json.name,
        .insert => try insertedName(arena, content_type, body),
        else => null,
    };
}

fn freeKept(gpa: Allocator, k: *FakeMultipart.Kept) void {
    gpa.free(k.key);
    freeHeaders(gpa, k.headers);
    gpa.free(k.body);
}

fn headerValue(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// The crc32c a `X-Goog-Hash` header claims, or null.
fn crc32cFromHash(value: []const u8) ?u32 {
    var entries = std.mem.splitScalar(u8, value, ',');
    while (entries.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t");
        if (!std.ascii.startsWithIgnoreCase(trimmed, "crc32c=")) continue;
        return core.crc32c.fromBase64(trimmed["crc32c=".len..]) catch null;
    }
    return null;
}

fn freeUpload(gpa: Allocator, u: *FakeMultipart.Upload) void {
    if (u.kms_key_name) |k| gpa.free(k);
    gpa.free(u.id);
    gpa.free(u.name);
    gpa.free(u.content_type);
    freeHeaders(gpa, u.metadata);
    for (u.parts.values()) |*p| freePart(gpa, p);
    u.parts.deinit(gpa);
}

const condition_failed: FakeMultipart.Reply = .{
    .status = 412,
    .body = "{\"error\":{\"code\":412,\"message\":\"At least one of the pre-conditions you specified did not hold.\",\"errors\":[{\"reason\":\"conditionNotMet\"}]}}",
};

/// An object's resource as the JSON API answers it, under `name` and at
/// `generation`, which a move changes, with the checksum flipped when
/// `wrong_crc`. Every object here is at metageneration 1. An object under
/// a customer-supplied key names its checksum only with `keyed_request`,
/// a request that carried the key, and names the key's SHA-256 always; one
/// under a Cloud KMS key names the key's first version.
/// An Object resource as Cloud Storage writes one: holds only once set,
/// and the retention expiration where a policy applies and no event-based
/// hold defers it.
fn objectJson(
    self: *const FakeMultipart,
    arena: Allocator,
    o: *const FakeMultipart.Stored,
    name: []const u8,
    generation: u64,
    bucket: []const u8,
    wrong_crc: bool,
    keyed_request: bool,
) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    const crc = core.crc32c.toBase64(core.crc32c.hash(o.bytes) ^ @intFromBool(wrong_crc));
    const hashes = o.key_sha256 == null or keyed_request;
    var sha_text: [44]u8 = undefined;
    const expiration: ?[]const u8 = if (self.retainedUntil(bucket, o)) |until| try rfc3339(arena, until) else null;
    jw.write(.{
        .name = name,
        .bucket = bucket,
        .size = try std.fmt.allocPrint(arena, "{d}", .{o.bytes.len}),
        .generation = try std.fmt.allocPrint(arena, "{d}", .{generation}),
        .metageneration = try std.fmt.allocPrint(arena, "{d}", .{o.metageneration}),
        .contentType = o.content_type,
        .contentEncoding = @as(?[]const u8, if (o.served != null) "gzip" else null),
        .crc32c = @as(?[]const u8, if (hashes) &crc else null),
        .storageClass = "STANDARD",
        .kmsKeyName = @as(?[]const u8, if (o.kms_key_name) |k| try std.fmt.allocPrint(arena, "{s}/cryptoKeyVersions/1", .{k}) else null),
        .customerEncryption = if (o.key_sha256) |digest| @as(?struct { encryptionAlgorithm: []const u8, keySha256: []const u8 }, .{
            .encryptionAlgorithm = "AES256",
            .keySha256 = std.base64.standard.Encoder.encode(&sha_text, &digest),
        }) else null,
        .temporaryHold = o.holds.temporary,
        .eventBasedHold = o.holds.event_based,
        .retentionExpirationTime = expiration,
        .retention = if (o.retention) |r| @as(?struct { mode: []const u8, retainUntilTime: []const u8 }, .{
            .mode = if (r.locked) "Locked" else "Unlocked",
            .retainUntilTime = try rfc3339(arena, r.until_ns),
        }) else null,
    }) catch return error.OutOfMemory;
    return out.written();
}

/// A JSON API error body, as Cloud Storage writes one.
fn jsonRefusal(arena: Allocator, status: u16, reason: []const u8, message: []const u8) Allocator.Error!FakeMultipart.Reply {
    const body = try std.json.Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = status,
        .message = message,
        .errors = .{.{ .message = message, .domain = "global", .reason = reason }},
    } }, .{});
    return .{ .status = status, .body = body };
}

/// The fake's wall clock: its clock's reading past midnight UTC on
/// 2026-09-30, the day this was measured, in RFC 3339 to the millisecond.
/// The fake's wall clock starts at midnight UTC on 2026-09-30.
const wall_base_s: i96 = 1_790_726_400;

fn rfc3339(arena: Allocator, ns: i96) Allocator.Error![]const u8 {
    const base_s: i96 = wall_base_s;
    const total_ms: u64 = @intCast(@max(0, base_s * std.time.ms_per_s + @divFloor(ns, std.time.ns_per_ms)));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = total_ms / std.time.ms_per_s };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const secs = epoch.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        secs.getHoursIntoDay(),
        secs.getMinutesIntoHour(),
        secs.getSecondsIntoMinute(),
        total_ms % std.time.ms_per_s,
    });
}

/// The conditions a JSON request carries, on the object it names or, for
/// a move, on the destination.
const Conditions = struct {
    if_generation_match: ?u64 = null,
    if_generation_not_match: ?u64 = null,
    if_metageneration_match: ?u64 = null,
    if_metageneration_not_match: ?u64 = null,

    const Outcome = enum { hold, match_failed, not_match_failed };

    /// Against a live object.
    fn check(c: Conditions, o: *const FakeMultipart.Stored) Outcome {
        if (c.if_generation_match) |g| if (g != o.generation) return .match_failed;
        if (c.if_metageneration_match) |m| if (m != o.metageneration) return .match_failed;
        if (c.if_generation_not_match) |g| if (g == o.generation) return .not_match_failed;
        if (c.if_metageneration_not_match) |m| if (m == o.metageneration) return .not_match_failed;
        return .hold;
    }

    /// Against no live object: only "generation 0", meaning none, holds;
    /// every other condition names something about a live object.
    fn checkAbsent(c: Conditions) bool {
        if (c.if_generation_match) |g| if (g != 0) return false;
        return c.if_generation_not_match == null and c.if_metageneration_match == null and c.if_metageneration_not_match == null;
    }

    /// Reads one query parameter, if it is a condition.
    fn take(c: *Conditions, param: []const u8) core.transport.Error!bool {
        const fields = [_]struct { []const u8, *?u64 }{
            .{ "ifGenerationMatch=", &c.if_generation_match },
            .{ "ifGenerationNotMatch=", &c.if_generation_not_match },
            .{ "ifMetagenerationMatch=", &c.if_metageneration_match },
            .{ "ifMetagenerationNotMatch=", &c.if_metageneration_not_match },
        };
        for (fields) |field| if (std.mem.startsWith(u8, param, field[0])) {
            field[1].* = std.fmt.parseInt(u64, param[field[0].len..], 10) catch return error.HttpProtocolError;
            return true;
        };
        return false;
    }
};

/// What the fake reads of an upload's metadata.
const Meta = struct {
    name: []const u8 = "",
    contentType: ?[]const u8 = null,
    contentEncoding: ?[]const u8 = null,
    crc32c: ?[]const u8 = null,
    temporaryHold: ?bool = null,
    eventBasedHold: ?bool = null,
    retention: ?std.json.Value = null,

    fn gzip(m: Meta) bool {
        return std.ascii.eqlIgnoreCase(m.contentEncoding orelse "", "gzip");
    }
};

/// The two parts of a `multipart/related` upload body, as this library
/// frames it: JSON metadata, then the data.
fn splitMultipart(arena: Allocator, content_type: []const u8, body: []const u8) error{ OutOfMemory, Malformed }!struct { metadata: []const u8, data: []const u8 } {
    const marker = "boundary=";
    const at = std.mem.indexOf(u8, content_type, marker) orelse return error.Malformed;
    const boundary = content_type[at + marker.len ..];
    const opening = try std.fmt.allocPrint(arena, "--{s}\r\n", .{boundary});
    const middle = try std.fmt.allocPrint(arena, "\r\n--{s}\r\n", .{boundary});
    const closing = try std.fmt.allocPrint(arena, "\r\n--{s}--\r\n", .{boundary});
    if (!std.mem.startsWith(u8, body, opening) or !std.mem.endsWith(u8, body, closing)) return error.Malformed;
    const inner = body[opening.len .. body.len - closing.len];
    const meta_start = (std.mem.indexOf(u8, inner, "\r\n\r\n") orelse return error.Malformed) + 4;
    const meta_len = std.mem.indexOf(u8, inner[meta_start..], middle) orelse return error.Malformed;
    const rest = inner[meta_start + meta_len + middle.len ..];
    const data_start = (std.mem.indexOf(u8, rest, "\r\n\r\n") orelse return error.Malformed) + 4;
    return .{ .metadata = inner[meta_start..][0..meta_len], .data = rest[data_start..] };
}

/// `bytes` gzip-decompressed, or nothing when they do not decompress.
fn gunzipOrEmpty(gpa: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var in: std.Io.Reader = .fixed(bytes);
    const window = try gpa.alloc(u8, core.flate.max_window_len);
    defer gpa.free(window);
    var inflate: core.flate.Decompress = .init(&in, .gzip, window);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = inflate.reader.streamRemaining(&out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.ReadFailed => return gpa.alloc(u8, 0),
    };
    return out.toOwnedSlice();
}

/// A deep copy of `o` at another generation.
fn copyStored(gpa: Allocator, o: *const FakeMultipart.Stored, generation: u64) Allocator.Error!FakeMultipart.Stored {
    const name = try gpa.dupe(u8, o.name);
    errdefer gpa.free(name);
    const bytes = try gpa.dupe(u8, o.bytes);
    errdefer gpa.free(bytes);
    const content_type = try gpa.dupe(u8, o.content_type);
    errdefer gpa.free(content_type);
    const metadata = try dupeHeaders(gpa, o.metadata);
    errdefer freeHeaders(gpa, metadata);
    const served = if (o.served) |s| try gpa.dupe(u8, s) else null;
    errdefer if (served) |d| gpa.free(d);
    const kms = if (o.kms_key_name) |k| try gpa.dupe(u8, k) else null;
    return .{
        .name = name,
        .generation = generation,
        .bytes = bytes,
        .content_type = content_type,
        .metadata = metadata,
        .served = served,
        .key_sha256 = o.key_sha256,
        .kms_key_name = kms,
        .holds = o.holds,
        .retention = o.retention,
        .metageneration = o.metageneration,
        .retained_from_ns = o.retained_from_ns,
    };
}

fn freeStored(gpa: Allocator, o: *FakeMultipart.Stored) void {
    gpa.free(o.name);
    gpa.free(o.bytes);
    gpa.free(o.content_type);
    freeHeaders(gpa, o.metadata);
    if (o.served) |served| gpa.free(served);
    if (o.kms_key_name) |k| gpa.free(k);
}

/// The one range a `Range: bytes=a-b` or `bytes=a-` header asks for, or
/// null when there is none, or none this fake reads; fake-gcs-server then
/// serves the whole object, and so does this.
const RequestedRange = struct {
    start: u64,
    /// The last byte, inclusive, or null for everything from `start`.
    last: ?u64,
};

fn requestedRange(headers: []const Header) ?RequestedRange {
    const value = for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "range")) break h.value;
    } else return null;
    if (!std.mem.startsWith(u8, value, "bytes=")) return null;
    const spec = value["bytes=".len..];
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const start = std.fmt.parseInt(u64, spec[0..dash], 10) catch return null;
    if (dash + 1 == spec.len) return .{ .start = start, .last = null };
    const last = std.fmt.parseInt(u64, spec[dash + 1 ..], 10) catch return null;
    if (last < start) return null;
    return .{ .start = start, .last = last };
}

/// What a fault plan sees as a media read's `part`: 1 plus the first byte
/// asked for, or 1 for a whole object.
fn mediaPart(headers: []const Header) u32 {
    const range = requestedRange(headers) orelse return 1;
    return std.math.cast(u32, range.start +| 1) orelse std.math.maxInt(u32);
}

const JsonTarget = struct {
    bucket: []const u8,
    name: []const u8,
    generation: ?u64,
    /// `alt=media`: the object's bytes rather than its metadata.
    media: bool = false,
    /// `softDeleted=true`: a soft-deleted generation's metadata.
    soft_deleted: bool = false,
    conditions: Conditions = .{},
    /// `overrideUnlockedRetention=true`, on a patch.
    override_unlocked_retention: bool = false,
};

const RestoreTarget = struct {
    bucket: []const u8,
    name: []const u8,
    generation: ?u64,
    /// On the live object of the name.
    conditions: Conditions,
};

const MoveTarget = struct {
    bucket: []const u8,
    source: []const u8,
    destination: []const u8,
    if_source_generation_match: ?u64,
    /// On the destination.
    conditions: Conditions,
};

const XmlTarget = struct {
    bucket: []const u8,
    name: []const u8,
    query: Query,
    /// For a part list.
    max_parts: u32 = 1_000,
    marker: u32 = 0,

    const Query = union(enum) {
        uploads,
        part: struct { number: u32, upload_id: []const u8 },
        upload: []const u8,
    };
};

const ResumableTarget = struct {
    bucket: []const u8,
    /// Checked at the open, against the live object the metadata names.
    conditions: Conditions,
    /// Scheme, host and port, for the session URL the answer mints.
    origin: []const u8,
    /// The start's `userProject`, which the session URL carries on.
    user_project: ?[]const u8 = null,
    kms_key_name: ?[]const u8 = null,
};

const InsertTarget = struct {
    bucket: []const u8,
    /// Checked against the live object the metadata names.
    conditions: Conditions,
    kms_key_name: ?[]const u8 = null,
};

const Target = union(enum) {
    bucket: FakeBuckets.Target,
    restore: RestoreTarget,
    json: JsonTarget,
    xml: XmlTarget,
    move: MoveTarget,
    resumable: ResumableTarget,
    insert: InsertTarget,
    /// A session URL's id.
    session: []const u8,
};

/// What a URL names, decoded. Anything this fake does not serve is
/// `HttpProtocolError`, which fails the test that sent it.
fn parseTarget(arena: Allocator, url: []const u8) core.transport.Error!Target {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.HttpProtocolError;
    const path_start = std.mem.indexOfScalarPos(u8, url, scheme_end + 3, '/') orelse return error.HttpProtocolError;
    const rest = url[path_start..];
    const q = std.mem.indexOfScalar(u8, rest, '?');
    const path = rest[0 .. q orelse rest.len];
    const query = if (q) |i| rest[i + 1 ..] else "";

    if (std.mem.startsWith(u8, path, "/upload/session/")) {
        return .{ .session = try decode(arena, path["/upload/session/".len..]) };
    }
    if (std.mem.startsWith(u8, path, "/upload/storage/v1/b/")) {
        const after = path["/upload/storage/v1/b/".len..];
        const slash = std.mem.indexOf(u8, after, "/o") orelse return error.HttpProtocolError;
        const bucket = try decode(arena, after[0..slash]);
        var conditions: Conditions = .{};
        var resumable_type = false;
        var multipart_type = false;
        var user_project: ?[]const u8 = null;
        var kms_key_name: ?[]const u8 = null;
        var params = std.mem.splitScalar(u8, query, '&');
        while (params.next()) |param| {
            if (try conditions.take(param)) continue;
            if (std.mem.eql(u8, param, "uploadType=resumable")) resumable_type = true;
            if (std.mem.eql(u8, param, "uploadType=multipart")) multipart_type = true;
            if (std.mem.startsWith(u8, param, "userProject=")) user_project = try decode(arena, param["userProject=".len..]);
            if (std.mem.startsWith(u8, param, "kmsKeyName=")) kms_key_name = try decode(arena, param["kmsKeyName=".len..]);
        }
        if (multipart_type) return .{ .insert = .{ .bucket = bucket, .conditions = conditions, .kms_key_name = kms_key_name } };
        if (!resumable_type) return error.HttpProtocolError;
        return .{ .resumable = .{
            .bucket = bucket,
            .conditions = conditions,
            .origin = url[0..path_start],
            .user_project = user_project,
            .kms_key_name = kms_key_name,
        } };
    }
    if (std.mem.eql(u8, path, "/storage/v1/b")) return .{ .bucket = try bucketTarget(arena, null, query) };
    if (std.mem.startsWith(u8, path, "/storage/v1/b/") and std.mem.endsWith(u8, path, "/lockRetentionPolicy")) {
        var target = try bucketTarget(arena, try decode(arena, path["/storage/v1/b/".len .. path.len - "/lockRetentionPolicy".len]), query);
        target.lock = true;
        return .{ .bucket = target };
    }
    if (std.mem.startsWith(u8, path, "/storage/v1/b/") and
        std.mem.indexOfScalar(u8, path["/storage/v1/b/".len..], '/') == null)
    {
        return .{ .bucket = try bucketTarget(arena, try decode(arena, path["/storage/v1/b/".len..]), query) };
    }
    if (std.mem.startsWith(u8, path, "/storage/v1/b/")) {
        const after = path["/storage/v1/b/".len..];
        const slash = std.mem.indexOf(u8, after, "/o/") orelse return error.HttpProtocolError;
        const bucket = try decode(arena, after[0..slash]);
        const object_part = after[slash + 3 ..];
        var generation: ?u64 = null;
        var source_generation: ?u64 = null;
        var media = false;
        var soft_deleted = false;
        var override = false;
        var conditions: Conditions = .{};
        var params = std.mem.splitScalar(u8, query, '&');
        while (params.next()) |param| {
            if (try conditions.take(param)) continue;
            if (std.mem.startsWith(u8, param, "generation=")) {
                generation = std.fmt.parseInt(u64, param["generation=".len..], 10) catch return error.HttpProtocolError;
            } else if (std.mem.startsWith(u8, param, "ifSourceGenerationMatch=")) {
                source_generation = std.fmt.parseInt(u64, param["ifSourceGenerationMatch=".len..], 10) catch return error.HttpProtocolError;
            } else if (std.mem.eql(u8, param, "alt=media")) {
                media = true;
            } else if (std.mem.eql(u8, param, "softDeleted=true")) {
                soft_deleted = true;
            } else if (std.mem.eql(u8, param, "overrideUnlockedRetention=true")) {
                override = true;
            }
        }
        if (std.mem.endsWith(u8, object_part, "/restore")) return .{ .restore = .{
            .bucket = bucket,
            .name = try decode(arena, object_part[0 .. object_part.len - "/restore".len]),
            .generation = generation,
            .conditions = conditions,
        } };
        // A name is one strictly encoded segment, so a slash here is the
        // move's.
        if (std.mem.indexOf(u8, object_part, "/moveTo/o/")) |at| return .{ .move = .{
            .bucket = bucket,
            .source = try decode(arena, object_part[0..at]),
            .destination = try decode(arena, object_part[at + "/moveTo/o/".len ..]),
            .if_source_generation_match = source_generation,
            .conditions = conditions,
        } };
        return .{ .json = .{
            .bucket = bucket,
            .name = try decode(arena, object_part),
            .generation = generation,
            .media = media,
            .soft_deleted = soft_deleted,
            .conditions = conditions,
            .override_unlocked_retention = override,
        } };
    }

    const slash = std.mem.indexOfScalarPos(u8, path, 1, '/') orelse return error.HttpProtocolError;
    const bucket = try decode(arena, path[1..slash]);
    const name = try decode(arena, path[slash + 1 ..]);
    if (std.mem.eql(u8, query, "uploads")) return .{ .xml = .{ .bucket = bucket, .name = name, .query = .uploads } };
    var number: ?u32 = null;
    var upload_id: ?[]const u8 = null;
    var max_parts: u32 = 1_000;
    var marker: u32 = 0;
    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |param| {
        if (std.mem.startsWith(u8, param, "partNumber=")) {
            number = std.fmt.parseInt(u32, param["partNumber=".len..], 10) catch return error.HttpProtocolError;
        } else if (std.mem.startsWith(u8, param, "uploadId=")) {
            upload_id = try decode(arena, param["uploadId=".len..]);
        } else if (std.mem.startsWith(u8, param, "max-parts=")) {
            max_parts = std.fmt.parseInt(u32, param["max-parts=".len..], 10) catch return error.HttpProtocolError;
        } else if (std.mem.startsWith(u8, param, "part-number-marker=")) {
            marker = std.fmt.parseInt(u32, param["part-number-marker=".len..], 10) catch return error.HttpProtocolError;
        } else return error.HttpProtocolError;
    }
    const id = upload_id orelse return error.HttpProtocolError;
    return .{ .xml = .{
        .bucket = bucket,
        .name = name,
        .query = if (number) |n| .{ .part = .{ .number = n, .upload_id = id } } else .{ .upload = id },
        .max_parts = max_parts,
        .marker = marker,
    } };
}

/// A bucket request's query: only what this library sends.
fn bucketTarget(arena: Allocator, name: ?[]const u8, query: []const u8) core.transport.Error!FakeBuckets.Target {
    var target: FakeBuckets.Target = .{ .name = name };
    if (query.len == 0) return target;
    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |param| {
        if (std.mem.startsWith(u8, param, "project=")) {
            target.project = try decode(arena, param["project=".len..]);
        } else if (std.mem.eql(u8, param, "projection=noAcl") or std.mem.startsWith(u8, param, "userProject=")) {
            // What every bucket answer here leaves out anyway, and the
            // project `billingRefusal` has already read.
        } else if (std.mem.startsWith(u8, param, "ifMetagenerationMatch=")) {
            target.if_metageneration_match = std.fmt.parseInt(u64, param["ifMetagenerationMatch=".len..], 10) catch
                return error.HttpProtocolError;
        } else if (std.mem.startsWith(u8, param, "ifMetagenerationNotMatch=")) {
            target.if_metageneration_not_match = std.fmt.parseInt(u64, param["ifMetagenerationNotMatch=".len..], 10) catch
                return error.HttpProtocolError;
        } else if (std.mem.eql(u8, param, "enableObjectRetention=true")) {
            target.object_retention = true;
        } else return error.HttpProtocolError;
    }
    return target;
}

fn decode(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    return std.Uri.percentDecodeInPlace(try arena.dupe(u8, text));
}

/// `FakeMultipart` behind real sockets: an HTTP/1.1 server on the loopback
/// interface, a task per connection, so a client's per-worker transports,
/// streamed bodies and timeouts meet real connections. A fault that drops
/// the connection closes the socket without an answer, as a failing
/// network does.
pub const MultipartServer = struct {
    fake: *FakeMultipart,
    server: std.Io.net.Server,
    port: u16,
    connections: std.atomic.Value(u32) = .init(0),
    group: std.Io.Group = .init,

    pub fn start(io: std.Io, fake: *FakeMultipart) !MultipartServer {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        const server = try address.listen(io, .{ .reuse_address = true });
        return .{ .fake = fake, .server = server, .port = server.socket.address.getPort() };
    }

    /// Accepts connections until canceled, serving each on a task of its
    /// own.
    pub fn run(s: *MultipartServer, io: std.Io) std.Io.Cancelable!void {
        defer s.group.cancel(io);
        while (true) {
            const stream = s.server.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            _ = s.connections.fetchAdd(1, .monotonic);
            s.group.concurrent(io, serve, .{ s, io, stream }) catch {
                stream.close(io);
                return;
            };
        }
    }

    pub fn deinit(s: *MultipartServer, io: std.Io) void {
        s.server.deinit(io);
    }

    /// `http://127.0.0.1:{port}`, for an emulator endpoint.
    pub fn url(s: *const MultipartServer, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{s.port}) catch unreachable;
    }

    fn serve(s: *MultipartServer, io: std.Io, stream: std.Io.net.Stream) std.Io.Cancelable!void {
        defer stream.close(io);
        var read_buf: [16 * 1024]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var write_buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        var arena: std.heap.ArenaAllocator = .init(s.fake.gpa);
        defer arena.deinit();
        // One request after another, as a kept-alive connection sends them,
        // until the client closes it or a fault drops it.
        while (true) {
            _ = arena.reset(.retain_capacity);
            const keep_going = s.exchange(io, &reader.interface, &writer.interface, arena.allocator()) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            if (!keep_going) return;
        }
    }

    /// One request and its answer. False when the connection is done.
    fn exchange(s: *MultipartServer, io: std.Io, r: *std.Io.Reader, w: *std.Io.Writer, arena: Allocator) !bool {
        _ = io;
        const request_line = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return false,
            else => |e| return e,
        };
        var parts = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, request_line, "\r\n"), ' ');
        const method_text = parts.next() orelse return false;
        const target = try arena.dupe(u8, parts.next() orelse return false);
        const method = std.meta.stringToEnum(Method, method_text) orelse return false;

        var headers: std.ArrayList(Header) = .empty;
        var content_type: ?[]const u8 = null;
        var content_length: usize = 0;
        while (true) {
            const line = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
            const name = try arena.dupe(u8, line[0..colon]);
            const value = try arena.dupe(u8, std.mem.trim(u8, line[colon + 1 ..], " \t"));
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                content_length = try std.fmt.parseInt(usize, value, 10);
            } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
                content_type = value;
            }
            try headers.append(arena, .{ .name = name, .value = value });
        }
        const body = try arena.alloc(u8, content_length);
        try r.readSliceAll(body);

        const full_url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}{s}", .{ s.port, target });
        // A client that offers gzip takes a gzip object's stored bytes.
        const accept_gzip = for (headers.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding")) break std.mem.indexOf(u8, h.value, "gzip") != null;
        } else false;
        const reply = s.fake.handle(method, full_url, content_type, headers.items, body, accept_gzip, arena) catch |err| switch (err) {
            // Dropped, as a failing network drops it: no answer.
            error.ConnectionResetByPeer => return false,
            else => |e| return e,
        };
        try w.print("HTTP/1.1 {d} Fake\r\nContent-Length: {d}\r\n", .{ reply.status, reply.body.len });
        for (reply.headers) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
        try w.writeAll("\r\n");
        if (reply.cut) {
            // Half the promised body, then the connection drops.
            try w.writeAll(reply.body[0 .. reply.body.len / 2]);
            try w.flush();
            return false;
        }
        try w.writeAll(reply.body);
        try w.flush();
        return true;
    }
};

/// `data` gzip-compressed by std, as a test's stored object. Owned. The
/// output only fails for want of memory, so that is how any failure shows.
pub fn gzipAlloc(gpa: Allocator, data: []const u8, options: std.compress.flate.Compress.Options) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
    defer out.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var compress: std.compress.flate.Compress = std.compress.flate.Compress.init(&out.writer, window, .gzip, options) catch return error.OutOfMemory;
    compress.writer.writeAll(data) catch return error.OutOfMemory;
    compress.finish() catch return error.OutOfMemory;
    return out.toOwnedSlice();
}
