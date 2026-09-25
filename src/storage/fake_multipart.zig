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
//! a cancel answers 499, and a finish carrying `X-Goog-Hash` refuses a
//! mismatched object with 400 before it exists.
//!
//! It holds uploads to the rules Google documents: part numbers 1 to
//! 10,000, a part sent again replaces itself, the finish names parts in
//! ascending order with the ETags they were given, every part but the last
//! is at least `min_part_size`, and a finish or part for an upload that is
//! gone answers 404 `NoSuchUpload`. Finishing replaces any object of the
//! name, with a new generation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const Header = core.transport.Header;
const Method = core.transport.Method;
const xml = @import("xml.zig");

pub const FakeMultipart = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    uploads: std.ArrayList(Upload) = .empty,
    sessions: std.ArrayList(Session) = .empty,
    objects: std.ArrayList(Stored) = .empty,
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
        session_starts: u32 = 0,
        session_puts: u32 = 0,
        session_cancels: u32 = 0,
        /// Payload bytes sessions accepted as new, resent prefixes not
        /// counted.
        session_bytes: u64 = 0,
        /// Payload bytes sessions ignored as already stored: what a
        /// client that resends what the server holds wastes.
        session_stale_bytes: u64 = 0,
    };

    pub const Kind = enum { start, part, finish, abort, list, read, delete, media, move, session_start, session_put, session_cancel };

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
        /// name just before it is served.
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

    const Upload = struct {
        id: []u8,
        name: []u8,
        content_type: []u8,
        metadata: []Header,
        parts: std.AutoArrayHashMapUnmanaged(u32, Part) = .empty,
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
        bytes: std.ArrayList(u8) = .empty,
        /// The generation the finish made, once it has.
        done: ?u64 = null,
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
    };

    pub fn init(gpa: Allocator, io: std.Io) FakeMultipart {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *FakeMultipart) void {
        for (self.uploads.items) |*u| freeUpload(self.gpa, u);
        self.uploads.deinit(self.gpa);
        for (self.sessions.items) |*s| freeSession(self.gpa, s);
        self.sessions.deinit(self.gpa);
        for (self.objects.items) |*o| freeStored(self.gpa, o);
        self.objects.deinit(self.gpa);
        self.* = undefined;
    }

    /// Sessions opened and neither finished nor cancelled. Call once every
    /// task using the fake has returned.
    pub fn openSessions(self: *const FakeMultipart) usize {
        var n: usize = 0;
        for (self.sessions.items) |s| {
            if (s.done == null) n += 1;
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
        });
        self.next_generation += 1;
    }

    /// Stores an object as gzip-compressed, as another writer would have:
    /// `stored` is what Cloud Storage keeps, sizes and hashes, and
    /// `decompressed` what a media read gets.
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
        const res = try self.handle(req.method, req.url, null, &.{}, req.body orelse "", arena);
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
        const res = try self.handle(req.method, req.url, req.content_type, req.headers, body, arena);
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
    fn handle(
        self: *FakeMultipart,
        method: Method,
        url: []const u8,
        content_type: ?[]const u8,
        headers: []const Header,
        body: []const u8,
        arena: Allocator,
    ) core.transport.Error!Reply {
        const target = try parseTarget(arena, url);
        const kind: Kind = switch (target) {
            // A request this fake does not serve fails the test that sent it.
            .json => |j| if (method == .GET)
                (if (j.media) .media else .read)
            else if (method == .DELETE) .delete else return error.HttpProtocolError,
            .move => if (method == .POST) .move else return error.HttpProtocolError,
            .resumable => if (method == .POST) .session_start else return error.HttpProtocolError,
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
            .move, .resumable => 0,
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

        const reply = switch (target) {
            .json => |j| try self.json(kind, j, headers, fault, arena),
            .xml => |x| try self.multipartRequest(kind, x, content_type, headers, body, fault, arena),
            .move => |m| try self.moveObject(m, fault, arena),
            .resumable => |r| try self.sessionStart(r, content_type, headers, body, arena),
            .session => |id| if (kind == .session_put)
                try self.sessionPut(id, headers, body, fault, arena)
            else
                self.sessionCancel(id),
        };
        if (fault == .lose_answer) return error.ConnectionResetByPeer;
        if (kind == .media and reply.status >= 200 and reply.status < 300) {
            self.counts.media_bytes += if (reply.cut) reply.body.len / 2 else reply.body.len;
        }
        return reply;
    }

    fn json(self: *FakeMultipart, kind: Kind, target: JsonTarget, headers: []const Header, fault: Fault, arena: Allocator) Allocator.Error!Reply {
        const not_found: Reply = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"No such object\",\"errors\":[{\"reason\":\"notFound\"}]}}" };
        const index = for (self.objects.items, 0..) |o, i| {
            if (std.mem.eql(u8, o.name, target.name) and (target.generation == null or target.generation.? == o.generation)) break i;
        } else null;
        switch (kind) {
            .read => {
                self.counts.reads += 1;
                const o = &self.objects.items[index orelse return not_found];
                switch (target.conditions.check(o)) {
                    .hold => {},
                    .match_failed => return condition_failed,
                    // A failing `…NotMatch` condition on a read is a 304,
                    // as HTTP's If-None-Match is.
                    .not_match_failed => return .{ .status = 304, .body = "" },
                }
                return .{ .status = 200, .body = try objectJson(arena, o, o.name, o.generation, target.bucket, false) };
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
                return media(&self.objects.items[index orelse return not_found], headers, fault, arena);
            },
            .delete => {
                self.counts.deletes += 1;
                const i = index orelse return not_found;
                var removed = self.objects.orderedRemove(i);
                freeStored(self.gpa, &removed);
                return .{ .status = 204 };
            },
            else => unreachable,
        }
    }

    /// `objects.move`: the source, pinned to its generation, renamed to the
    /// destination under the destination's conditions, with a new
    /// generation, atomically. The source goes; an object it replaces goes.
    fn moveObject(self: *FakeMultipart, target: MoveTarget, fault: Fault, arena: Allocator) Allocator.Error!Reply {
        self.counts.moves += 1;
        const not_found: Reply = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"No such object\",\"errors\":[{\"reason\":\"notFound\"}]}}" };
        if (fault == .clobber) try self.put(target.destination, "another writer's bytes");
        const destination_holds = if (self.liveIndex(target.destination)) |d|
            target.conditions.check(&self.objects.items[d]) == .hold
        else
            target.conditions.checkAbsent();
        if (self.move_checks_destination_first and !destination_holds) return condition_failed;
        const s = self.liveIndex(target.source) orelse return not_found;
        if (target.if_source_generation_match) |g| if (self.objects.items[s].generation != g) return condition_failed;
        if (!destination_holds) return condition_failed;
        if (std.mem.eql(u8, target.source, target.destination)) return .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"same name\"}}" };

        // The reply and the new name first: once the objects change,
        // nothing may fail.
        const generation = self.next_generation;
        const reply_body = try objectJson(arena, &self.objects.items[s], target.destination, generation, target.bucket, fault == .corrupt);
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
    fn media(o: *const Stored, headers: []const Header, fault: Fault, arena: Allocator) Allocator.Error!Reply {
        const hash = core.crc32c.toBase64(core.crc32c.hash(o.bytes));
        var reply_headers: std.ArrayList(Header) = .empty;
        try reply_headers.append(arena, .{ .name = "x-goog-generation", .value = try std.fmt.allocPrint(arena, "{d}", .{o.generation}) });
        try reply_headers.append(arena, .{ .name = "x-goog-hash", .value = try std.fmt.allocPrint(arena, "crc32c={s}", .{&hash}) });
        if (o.served) |served| {
            try reply_headers.append(arena, .{ .name = "x-goog-stored-content-encoding", .value = "gzip" });
            return .{ .status = 200, .headers = reply_headers.items, .body = served, .cut = fault == .cut };
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
                try self.uploads.append(self.gpa, .{ .id = id, .name = name, .content_type = stored_type, .metadata = metadata });
                self.next_upload += 1;
                return .{ .status = 200, .body = reply_body };
            },
            .part => {
                self.counts.parts += 1;
                const upload_id = target.query.part.upload_id;
                const index = self.uploadIndex(upload_id) orelse return gone;
                if (fault == .gone) return self.drop(index, gone);
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
                if (fault == .error_200) return .{ .status = 200, .body = "<Error><Code>InternalError</Code><Message>We encountered an internal error. Please try again.</Message></Error>" };
                return self.finishUpload(index, body, fault, arena);
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
            .read, .delete, .media, .move, .session_start, .session_put, .session_cancel => unreachable,
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

    fn finishUpload(self: *FakeMultipart, index: usize, body: []const u8, fault: Fault, arena: Allocator) Allocator.Error!Reply {
        const invalid_part: Reply = .{ .status = 400, .body = "<Error><Code>InvalidPart</Code></Error>" };
        const u = &self.uploads.items[index];
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
        // The reply, and room for the object, before anything changes.
        const reply_headers = try replyHeaders(arena, &.{
            .{ .name = "x-goog-hash", .value = try std.fmt.allocPrint(arena, "crc32c={s}", .{&hash}) },
            .{ .name = "x-goog-generation", .value = try std.fmt.allocPrint(arena, "{d}", .{generation}) },
        });
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
        });
        u.name = u.name[0..0];
        u.content_type = u.content_type[0..0];
        u.metadata = u.metadata[0..0];
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
        const Meta = struct { name: []const u8 = "", contentType: ?[]const u8 = null, crc32c: ?[]const u8 = null };
        _ = content_type;
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

        const declared: ?u64 = if (headerValue(headers, "X-Upload-Content-Length")) |text|
            std.fmt.parseInt(u64, text, 10) catch null
        else
            null;
        const metadata_crc: ?u32 = if (meta.crc32c) |text| core.crc32c.fromBase64(text) catch null else null;
        const id_text = try std.fmt.allocPrint(arena, "sess-{d}", .{self.next_session});
        const location = try std.fmt.allocPrint(arena, "{s}/upload/session/{s}", .{ target.origin, id_text });
        const id = try self.gpa.dupe(u8, id_text);
        errdefer self.gpa.free(id);
        const name = try self.gpa.dupe(u8, meta.name);
        errdefer self.gpa.free(name);
        const stored_type = try self.gpa.dupe(u8, meta.contentType orelse "application/octet-stream");
        errdefer self.gpa.free(stored_type);
        const bucket = try self.gpa.dupe(u8, target.bucket);
        errdefer self.gpa.free(bucket);
        try self.sessions.append(self.gpa, .{
            .id = id,
            .bucket = bucket,
            .name = name,
            .content_type = stored_type,
            .declared = declared,
            .metadata_crc = metadata_crc,
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
                    return .{ .status = 200, .body = try objectJson(arena, o, o.name, generation, s.bucket, false) };
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

        const generation = self.next_generation;
        const name = try self.gpa.dupe(u8, s.name);
        errdefer self.gpa.free(name);
        const bytes = try self.gpa.dupe(u8, s.bytes.items);
        errdefer self.gpa.free(bytes);
        const stored_type = try self.gpa.dupe(u8, s.content_type);
        errdefer self.gpa.free(stored_type);
        const metadata = try self.gpa.alloc(Header, 0);
        errdefer self.gpa.free(metadata);
        try self.objects.ensureUnusedCapacity(self.gpa, 1);
        self.next_generation += 1;
        if (self.liveIndex(s.name)) |i| {
            var replaced = self.objects.orderedRemove(i);
            freeStored(self.gpa, &replaced);
        }
        self.objects.appendAssumeCapacity(.{
            .name = name,
            .generation = generation,
            .bytes = bytes,
            .content_type = stored_type,
            .metadata = metadata,
        });
        s.done = generation;
        s.bytes.clearAndFree(self.gpa);
        const o = &self.objects.items[self.objects.items.len - 1];
        return .{ .status = 200, .body = try objectJson(arena, o, o.name, generation, s.bucket, false) };
    }

    fn sessionCancel(self: *FakeMultipart, id: []const u8) Reply {
        self.counts.session_cancels += 1;
        const index = self.sessionIndex(id) orelse return session_not_found;
        var removed = self.sessions.orderedRemove(index);
        freeSession(self.gpa, &removed);
        // What Google answers a cancel.
        return .{ .status = 499 };
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
/// `wrong_crc`. Every object here is at metageneration 1.
fn objectJson(arena: Allocator, o: *const FakeMultipart.Stored, name: []const u8, generation: u64, bucket: []const u8, wrong_crc: bool) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    const crc = core.crc32c.toBase64(core.crc32c.hash(o.bytes) ^ @intFromBool(wrong_crc));
    jw.write(.{
        .name = name,
        .bucket = bucket,
        .size = try std.fmt.allocPrint(arena, "{d}", .{o.bytes.len}),
        .generation = try std.fmt.allocPrint(arena, "{d}", .{generation}),
        .metageneration = "1",
        .contentType = o.content_type,
        .contentEncoding = @as(?[]const u8, if (o.served != null) "gzip" else null),
        .crc32c = &crc,
        .storageClass = "STANDARD",
    }) catch return error.OutOfMemory;
    return out.written();
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
        if (c.if_metageneration_match) |m| if (m != 1) return .match_failed;
        if (c.if_generation_not_match) |g| if (g == o.generation) return .not_match_failed;
        if (c.if_metageneration_not_match) |m| if (m == 1) return .not_match_failed;
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

fn freeStored(gpa: Allocator, o: *FakeMultipart.Stored) void {
    gpa.free(o.name);
    gpa.free(o.bytes);
    gpa.free(o.content_type);
    freeHeaders(gpa, o.metadata);
    if (o.served) |served| gpa.free(served);
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
    conditions: Conditions = .{},
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
};

const Target = union(enum) {
    json: JsonTarget,
    xml: XmlTarget,
    move: MoveTarget,
    resumable: ResumableTarget,
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
        var params = std.mem.splitScalar(u8, query, '&');
        while (params.next()) |param| {
            if (try conditions.take(param)) continue;
            if (std.mem.eql(u8, param, "uploadType=resumable")) resumable_type = true;
        }
        if (!resumable_type) return error.HttpProtocolError;
        return .{ .resumable = .{ .bucket = bucket, .conditions = conditions, .origin = url[0..path_start] } };
    }
    if (std.mem.startsWith(u8, path, "/storage/v1/b/")) {
        const after = path["/storage/v1/b/".len..];
        const slash = std.mem.indexOf(u8, after, "/o/") orelse return error.HttpProtocolError;
        const bucket = try decode(arena, after[0..slash]);
        const object_part = after[slash + 3 ..];
        var generation: ?u64 = null;
        var source_generation: ?u64 = null;
        var media = false;
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
            }
        }
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
            .conditions = conditions,
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
        const reply = s.fake.handle(method, full_url, content_type, headers.items, body, arena) catch |err| switch (err) {
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
