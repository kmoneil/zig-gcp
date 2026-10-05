//! A Firestore for tests, behind the `Transport` seam: documents in any
//! number of databases, kept and refused as the emulator kept and refused
//! them when measured on 2026-10-04 (`_tmp/firestore-m1/`), with its words
//! where it had any. It is written from what the server did, not from this
//! library's encoder: it parses request JSON and field paths with code of
//! its own, so a body or mask the encoder gets wrong is refused or
//! misapplied here as the server would. Test code only, and used from one
//! task at a time.
//!
//! What it models:
//!
//! - Values: the eleven kinds, each refused as the emulator refused it (no
//!   kind, two kinds, nested arrays, maps and arrays over 20 deep, empty,
//!   reserved and over-long names, strings over 1,048,487 bytes, latitude
//!   and longitude out of range, timestamps outside the years 1 to 9999).
//!   Timestamps keep microseconds and drop the rest. Answers write
//!   `nullValue` as JSON null, integers as strings, doubles as Java prints
//!   them (`3.0`, `1.0E300`), -0.0 as 0.0, a geo point without its zero
//!   coordinate, and an empty array or map as `{}`.
//! - Paths and ids: reserved `__x__` ids, ids over 1,500 bytes, and the
//!   field path grammar the emulator's refusals state, with its words.
//! - `get` with read masks, `listDocuments` by name with masks and paging
//!   (an empty collection answers `{}`), `listCollectionIds` at any level
//!   (a collection exists while a document lies below it), and
//!   `createDocument`, which chooses a 20-character id when none is given.
//! - `commit`: updates with and without masks (a masked path with no value
//!   deletes, a path through a non-map replaces it with a map, emptied
//!   maps stay), deletes, and the `exists` and `updateTime` preconditions,
//!   applied in order and atomically: one refusal applies none. Every
//!   write of a commit takes the commit's time.
//! - Faults: `refuse_next` answers the next requests 503 untouched;
//!   `lose_answers` lets the next writes land and then answers them 503,
//!   as a lost answer.
//!
//! Not modelled: ordering a list by a field, read times, transactions,
//! transforms, queries, `showMissing`, and the `updateTime` query
//! parameters, which the emulator misreads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Writer = std.Io.Writer;
const core = @import("core");
const tp = core.transport;

pub const FakeFirestore = struct {
    gpa: Allocator,
    /// Holds everything stored. Replaced documents stay in it until
    /// `deinit`.
    store: std.heap.ArenaAllocator,
    /// By database id and path: `(default)|cities/LA`.
    docs: std.StringArrayHashMapUnmanaged(*Doc) = .empty,
    /// The server's clock in microseconds since the epoch, moved on by
    /// every commit: 2026-10-04T00:00:00Z to begin with.
    now_us: i64 = 1_791_072_000_000_000,
    /// Requests served, by every route.
    requests: u32 = 0,
    /// The next this many requests answer 503 UNAVAILABLE and change
    /// nothing.
    refuse_next: u32 = 0,
    /// The next this many writes land and then answer 503 UNAVAILABLE.
    lose_answers: u32 = 0,
    /// For the ids `createDocument` chooses.
    prng: std.Random.DefaultPrng = .init(0x5eed),

    pub const Reply = struct { status: u16, body: []const u8 };

    /// What one write of a commit answers.
    const WriteOutcome = struct { has_time: bool = false, transform_results: []const Val = &.{} };

    pub const Doc = struct {
        fields: []const Entry,
        create_us: i64,
        update_us: i64,
    };

    pub const Entry = struct { name: []const u8, value: Val };

    /// A stored value, as the server keeps it.
    pub const Val = union(enum) {
        null,
        boolean: bool,
        integer: i64,
        double: f64,
        timestamp_us: i64,
        string: []const u8,
        bytes: []const u8,
        reference: []const u8,
        geo: [2]f64,
        array: []const Val,
        map: []const Entry,
    };

    pub fn init(gpa: Allocator) FakeFirestore {
        return .{ .gpa = gpa, .store = .init(gpa) };
    }

    pub fn deinit(self: *FakeFirestore) void {
        self.docs.deinit(self.gpa);
        self.store.deinit();
        self.* = undefined;
    }

    pub fn transport(self: *FakeFirestore) tp.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const self: *FakeFirestore = @ptrCast(@alignCast(ptr));
        const reply = self.serve(req.method, req.url, req.body orelse "", arena) catch return error.OutOfMemory;
        return .{ .status = reply.status, .body = reply.body };
    }

    /// A document as stored, for tests to inspect; null when there is none.
    pub fn doc(self: *const FakeFirestore, database_id: []const u8, path: []const u8) ?*const Doc {
        var buf: [8192]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}|{s}", .{ database_id, path }) catch return null;
        return self.docs.get(key);
    }

    /// How many documents the database holds.
    pub fn count(self: *const FakeFirestore, database_id: []const u8) usize {
        var n: usize = 0;
        for (self.docs.keys()) |key| {
            if (std.mem.startsWith(u8, key, database_id) and key.len > database_id.len and key[database_id.len] == '|') n += 1;
        }
        return n;
    }

    const Route = struct {
        project: []const u8,
        database: []const u8,
        /// Decoded segments below `documents`.
        segments: []const []const u8,
        verb: ?[]const u8,
        query: []const u8,
    };

    pub fn serve(self: *FakeFirestore, method: tp.Method, url: []const u8, body: []const u8, arena: Allocator) Allocator.Error!Reply {
        self.requests += 1;
        if (self.refuse_next > 0) {
            self.refuse_next -= 1;
            return fail(arena, 503, "UNAVAILABLE", "The service is currently unavailable.");
        }
        const route = (try parseUrl(arena, url)) orelse return fail(arena, 404, "NOT_FOUND", "fake: no such route");
        if (route.verb) |verb| {
            if (method == .POST and std.mem.eql(u8, verb, "commit") and route.segments.len == 0) return self.commit(arena, route, body);
            if (method == .POST and std.mem.eql(u8, verb, "listCollectionIds") and route.segments.len % 2 == 0) return self.listCollectionIds(arena, route, body);
            if (method == .POST and std.mem.eql(u8, verb, "batchGet") and route.segments.len == 0) return self.batchGet(arena, route, body);
            return fail(arena, 400, "INVALID_ARGUMENT", "fake: verb not modelled");
        }
        if (route.segments.len == 0) return fail(arena, 404, "NOT_FOUND", "fake: no such route");
        if (try idRefusal(arena, route.segments)) |r| return r;
        const document = route.segments.len % 2 == 0;
        switch (method) {
            .GET => return if (document) self.get(arena, route) else self.list(arena, route),
            .POST => if (!document) return self.create(arena, route, body),
            else => {},
        }
        return fail(arena, 400, "INVALID_ARGUMENT", "fake: method not modelled");
    }

    // Routes

    fn get(self: *FakeFirestore, arena: Allocator, route: Route) Allocator.Error!Reply {
        const path = try join(arena, route.segments);
        const mask = try queryAll(arena, route.query, "mask.fieldPaths");
        const masks = (try parseMasks(arena, mask)) orelse return try badPath(arena, mask);
        const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ route.database, path });
        const d = self.docs.get(key) orelse return fail(arena, 404, "NOT_FOUND", try std.fmt.allocPrint(arena, "Document ({s}) not found.", .{try fullName(arena, route, path)}));
        return ok(arena, try renderDoc(arena, try fullName(arena, route, path), d, if (mask.len > 0) masks else null));
    }

    fn list(self: *FakeFirestore, arena: Allocator, route: Route) Allocator.Error!Reply {
        const collection = try join(arena, route.segments);
        if (queryOne(route.query, "orderBy")) |order| {
            if (!std.mem.eql(u8, order, "__name__") and !std.mem.eql(u8, order, "__name__ asc")) {
                return fail(arena, 400, "INVALID_ARGUMENT", "fake: ordering by a field is not modelled");
            }
        }
        const mask = try queryAll(arena, route.query, "mask.fieldPaths");
        const masks = (try parseMasks(arena, mask)) orelse return try badPath(arena, mask);
        const page_size = pageSize(route.query) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Page size must be nonnegative.");
        const start = pageStart(route.query) orelse return fail(arena, 400, "INVALID_ARGUMENT", "invalid page token");

        var ids: std.ArrayList([]const u8) = .empty;
        const prefix = try std.fmt.allocPrint(arena, "{s}|{s}/", .{ route.database, collection });
        for (self.docs.keys()) |key| {
            if (!std.mem.startsWith(u8, key, prefix)) continue;
            const rest = key[prefix.len..];
            if (std.mem.indexOfScalar(u8, rest, '/') != null) continue;
            try ids.append(arena, rest);
        }
        std.mem.sort([]const u8, ids.items, {}, lessBytes);

        var out: Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        const end = if (page_size == 0) ids.items.len else @min(ids.items.len, start + page_size);
        const from = @min(start, ids.items.len);
        writeList(self, &jw, arena, route, collection, ids.items[from..end], if (mask.len > 0) masks else null, if (end < ids.items.len) end else null) catch return error.OutOfMemory;
        return ok(arena, out.written());
    }

    fn writeList(
        self: *FakeFirestore,
        jw: *Stringify,
        arena: Allocator,
        route: Route,
        collection: []const u8,
        ids: []const []const u8,
        masks: ?[]const []const []const u8,
        next: ?usize,
    ) !void {
        try jw.beginObject();
        if (ids.len > 0) {
            try jw.objectField("documents");
            try jw.beginArray();
            for (ids) |id| {
                const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ collection, id });
                const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ route.database, path });
                try writeDoc(jw, arena, try fullName(arena, route, path), self.docs.get(key).?, masks);
            }
            try jw.endArray();
        }
        if (next) |n| {
            try jw.objectField("nextPageToken");
            try jw.print("\"fake-{d}\"", .{n});
        }
        try jw.endObject();
    }

    fn listCollectionIds(self: *FakeFirestore, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const parent = try join(arena, route.segments);
        const tree = parseJson(arena, body) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
        if (tree != .object) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
        var page_size: usize = 0;
        var start: usize = 0;
        if (tree.object.get("pageSize")) |v| page_size = std.fmt.parseInt(usize, numberText(v) orelse "x", 10) catch
            return fail(arena, 400, "INVALID_ARGUMENT", "Page size must be nonnegative.");
        if (tree.object.get("pageToken")) |v| {
            if (v != .string) return fail(arena, 400, "INVALID_ARGUMENT", "invalid page token");
            start = tokenStart(v.string) orelse return fail(arena, 400, "INVALID_ARGUMENT", "invalid page token");
        }

        var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        const prefix = if (parent.len == 0)
            try std.fmt.allocPrint(arena, "{s}|", .{route.database})
        else
            try std.fmt.allocPrint(arena, "{s}|{s}/", .{ route.database, parent });
        for (self.docs.keys()) |key| {
            if (!std.mem.startsWith(u8, key, prefix)) continue;
            const rest = key[prefix.len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
            try seen.put(arena, rest[0..slash], {});
        }
        const ids = seen.keys();
        std.mem.sort([]const u8, ids, {}, lessBytes);
        const from = @min(start, ids.len);
        const end = if (page_size == 0) ids.len else @min(ids.len, from + page_size);

        var out: Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeIds(&jw, ids[from..end], if (end < ids.len) end else null) catch return error.OutOfMemory;
        return ok(arena, out.written());
    }

    fn writeIds(jw: *Stringify, ids: []const []const u8, next: ?usize) !void {
        try jw.beginObject();
        if (ids.len > 0) {
            try jw.objectField("collectionIds");
            try jw.write(ids);
        }
        if (next) |n| {
            try jw.objectField("nextPageToken");
            try jw.print("\"fake-{d}\"", .{n});
        }
        try jw.endObject();
    }

    /// Answers in the order of the documents' names, not the order asked,
    /// which the server does not keep either, and a name asked twice once.
    fn batchGet(self: *FakeFirestore, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const tree = parseJson(arena, body) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
        if (tree != .object) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
        if (tree.object.get("readTime") != null or tree.object.get("transaction") != null or tree.object.get("newTransaction") != null) {
            return fail(arena, 400, "INVALID_ARGUMENT", "fake: read times and transactions are not modelled");
        }
        var masks: ?[]const []const []const u8 = null;
        if (tree.object.get("mask")) |m| {
            var texts: std.ArrayList([]const u8) = .empty;
            if (m != .object) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
            if (m.object.get("fieldPaths")) |pj| {
                if (pj != .array) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
                for (pj.array.items) |item| {
                    if (item != .string) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
                    try texts.append(arena, item.string);
                }
            }
            masks = (try parseMasks(arena, texts.items)) orelse return try badPath(arena, texts.items);
        }
        var asked: std.StringArrayHashMapUnmanaged(void) = .empty;
        if (tree.object.get("documents")) |docs| {
            if (docs != .array) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
            for (docs.array.items) |item| {
                if (item != .string) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
                try asked.put(arena, item.string, {});
            }
        }
        const ordered = asked.keys();
        std.mem.sort([]const u8, ordered, {}, lessBytes);
        var out: Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        jw.beginArray() catch return error.OutOfMemory;
        for (ordered) |name| {
            const prefix = try std.fmt.allocPrint(arena, "projects/{s}/databases/", .{route.project});
            // Measured: a name in another database is answered missing.
            const in_db = try std.fmt.allocPrint(arena, "projects/{s}/databases/{s}/documents/", .{ route.project, route.database });
            if (!std.mem.startsWith(u8, name, prefix)) return fail(arena, 400, "INVALID_ARGUMENT", "Document name is not in this project.");
            var d: ?*Doc = null;
            if (std.mem.startsWith(u8, name, in_db)) {
                const path = name[in_db.len..];
                var n: usize = 0;
                var it = std.mem.splitScalar(u8, path, '/');
                while (it.next()) |_| n += 1;
                if (n % 2 != 0) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Document name \"{s}\" lacks \"/\".", .{name}));
                d = self.docs.get(try std.fmt.allocPrint(arena, "{s}|{s}", .{ route.database, path }));
            }
            writeBatchElement(&jw, arena, name, d, masks, self.now_us) catch return error.OutOfMemory;
        }
        jw.endArray() catch return error.OutOfMemory;
        return ok(arena, out.written());
    }

    fn writeBatchElement(jw: *Stringify, arena: Allocator, name: []const u8, d: ?*Doc, masks: ?[]const []const []const u8, now_us: i64) !void {
        try jw.beginObject();
        if (d) |found| {
            try jw.objectField("found");
            try writeDoc(jw, arena, name, found, masks);
        } else {
            try jw.objectField("missing");
            try jw.write(name);
        }
        try jw.objectField("readTime");
        try writeTime(jw, now_us);
        try jw.endObject();
    }

    fn create(self: *FakeFirestore, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const collection = try join(arena, route.segments);
        var id_buf: [20]u8 = undefined;
        const id = queryOne(route.query, "documentId") orelse self.newId(&id_buf);
        const decoded_id = try percentDecode(arena, id);
        if (try idRefusal(arena, &.{decoded_id})) |r| return r;
        const tree = parseJson(arena, body) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
        if (tree != .object) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
        if (tree.object.get("name") != null) return fail(arena, 400, "INVALID_ARGUMENT", "Document name must not be set.");
        var parser: ValueParser = .{ .arena = arena };
        const fields = if (tree.object.get("fields")) |f| (parser.entries(f, 0, true) orelse return parser.refusal()) else &.{};

        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ collection, decoded_id });
        const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ route.database, path });
        if (self.docs.get(key) != null) return alreadyExists(arena, route, path);
        self.now_us += 1000;
        const d = try self.keep(key, fields, self.now_us, self.now_us);
        if (self.lose()) return lost(arena);
        return ok(arena, try renderDoc(arena, try fullName(arena, route, path), d, null));
    }

    fn commit(self: *FakeFirestore, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const tree = parseJson(arena, body) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
        if (tree != .object) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
        const writes = tree.object.get("writes") orelse return self.committed(arena, &.{});
        if (writes != .array) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");

        // Every write is applied to a staging copy; one refusal and none
        // of them land.
        var staged: std.StringArrayHashMapUnmanaged(?*Doc) = .empty;
        const commit_us = self.now_us + 1000;
        const results = try arena.alloc(WriteOutcome, writes.array.items.len);
        for (writes.array.items, results) |w, *outcome| {
            outcome.* = .{};
            if (try self.stage(arena, route, w, commit_us, &staged, outcome)) |refusal| return refusal;
        }
        self.now_us = commit_us;
        var it = staged.iterator();
        while (it.next()) |entry| {
            const key = try self.store.allocator().dupe(u8, entry.key_ptr.*);
            if (entry.value_ptr.*) |d| {
                try self.docs.put(self.gpa, key, d);
            } else {
                _ = self.docs.orderedRemove(key);
            }
        }
        if (self.lose()) return lost(arena);
        return self.committed(arena, results);
    }

    fn committed(self: *FakeFirestore, arena: Allocator, results: []const WriteOutcome) Allocator.Error!Reply {
        var out: Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeCommitted(&jw, results, self.now_us) catch return error.OutOfMemory;
        return ok(arena, out.written());
    }

    fn writeCommitted(jw: *Stringify, results: []const WriteOutcome, now_us: i64) !void {
        // Measured: a commit of no writes answers `{}`.
        if (results.len == 0) {
            try jw.beginObject();
            try jw.endObject();
            return;
        }
        try jw.beginObject();
        try jw.objectField("writeResults");
        try jw.beginArray();
        for (results) |outcome| {
            try jw.beginObject();
            if (outcome.has_time) {
                try jw.objectField("updateTime");
                try writeTime(jw, now_us);
            }
            if (outcome.transform_results.len > 0) {
                try jw.objectField("transformResults");
                try jw.beginArray();
                for (outcome.transform_results) |v| try writeVal(jw, v);
                try jw.endArray();
            }
            try jw.endObject();
        }
        try jw.endArray();
        try jw.objectField("commitTime");
        try writeTime(jw, now_us);
        try jw.endObject();
    }

    /// Applies one write to `staged`; a refusal when the write is refused.
    fn stage(
        self: *FakeFirestore,
        arena: Allocator,
        route: Route,
        w: std.json.Value,
        commit_us: i64,
        staged: *std.StringArrayHashMapUnmanaged(?*Doc),
        outcome: *WriteOutcome,
    ) Allocator.Error!?Reply {
        if (w != .object) return try fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
        const o = w.object;
        const update = o.get("update");
        const delete = o.get("delete");
        if ((update == null) == (delete == null)) return try fail(arena, 400, "INVALID_ARGUMENT", "A write must have exactly one operation.");
        const name = if (update) |u| (if (u == .object) u.object.get("name") else null) else delete;
        const name_text = if (name) |n| (if (n == .string) n.string else null) else null;
        const path = try self.pathOf(arena, route, name_text orelse "") orelse
            return try fail(arena, 400, "INVALID_ARGUMENT", "Document name is not in this database.");
        const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ route.database, path });
        const current: ?*Doc = if (staged.get(key)) |s| s else self.docs.get(key);

        if (o.get("currentDocument")) |pre| {
            if (try preconditionRefusal(arena, route, path, current, pre)) |r| return r;
        }

        if (delete != null) {
            if (o.get("updateTransforms") != null) return try fail(arena, 400, "INVALID_ARGUMENT", "A delete cannot carry transforms.");
            try staged.put(arena, key, null);
            return null;
        }
        var parser: ValueParser = .{ .arena = arena };
        const body_fields = if (update.?.object.get("fields")) |f| (parser.entries(f, 0, true) orelse return try parser.refusal()) else &.{};
        var fields: []const Entry = body_fields;
        if (o.get("updateMask")) |m| {
            const paths_json = if (m == .object) m.object.get("fieldPaths") else null;
            var texts: std.ArrayList([]const u8) = .empty;
            if (paths_json) |pj| {
                if (pj != .array) return try fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
                for (pj.array.items) |p| {
                    if (p != .string) return try fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
                    try texts.append(arena, p.string);
                }
            }
            const masks = (try parseMasks(arena, texts.items)) orelse return try badPath(arena, texts.items);
            var result: []const Entry = if (current) |c| c.fields else &.{};
            for (masks) |segments| {
                if (segments.len == 1 and std.mem.eql(u8, segments[0], "__name__")) continue;
                result = if (lookup(body_fields, segments)) |v|
                    try setAt(arena, result, segments, v)
                else
                    try deleteAt(arena, result, segments);
            }
            fields = result;
        }
        if (o.get("updateTransforms")) |t| {
            const applied = try applyTransforms(arena, fields, t, commit_us);
            switch (applied) {
                .refused => |r| return r,
                .done => |done| {
                    fields = done.fields;
                    outcome.transform_results = try deepCopyVals(self.store.allocator(), done.results);
                },
            }
        }
        const d = try self.store.allocator().create(Doc);
        d.* = .{
            .fields = try deepCopy(self.store.allocator(), fields),
            .create_us = if (current) |c| c.create_us else commit_us,
            .update_us = commit_us,
        };
        try staged.put(arena, key, d);
        outcome.has_time = true;
        return null;
    }

    fn preconditionRefusal(arena: Allocator, route: Route, path: []const u8, current: ?*Doc, pre: std.json.Value) Allocator.Error!?Reply {
        if (pre != .object) return try fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
        if (pre.object.get("exists")) |e| {
            if (e != .bool) return try fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
            if (e.bool and current == null) return try fail(arena, 404, "NOT_FOUND", try std.fmt.allocPrint(arena, "No document to update: {s}", .{try fullName(arena, route, path)}));
            if (!e.bool and current != null) return try alreadyExists(arena, route, path);
        }
        if (pre.object.get("updateTime")) |t| {
            const wanted_us: i64 = us: {
                if (t != .string) return try fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
                const ts = core.timestamp.parse(t.string) catch return try fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
                // A time finer than the server keeps matches no version.
                if (@mod(ts.nanoseconds, std.time.ns_per_us) != 0) break :us -1;
                break :us @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_us));
            };
            const stored: i64 = if (current) |c| c.update_us else 0;
            if (stored != wanted_us) return try fail(arena, 400, "FAILED_PRECONDITION", try std.fmt.allocPrint(
                arena,
                "the stored version ({d}) does not match the required base version ({d})",
                .{ stored, @max(wanted_us, 0) },
            ));
        }
        return null;
    }

    // Helpers

    fn keep(self: *FakeFirestore, key: []const u8, fields: []const Entry, create_us: i64, update_us: i64) Allocator.Error!*Doc {
        const a = self.store.allocator();
        const d = try a.create(Doc);
        d.* = .{ .fields = try deepCopy(a, fields), .create_us = create_us, .update_us = update_us };
        try self.docs.put(self.gpa, try a.dupe(u8, key), d);
        return d;
    }

    fn lose(self: *FakeFirestore) bool {
        if (self.lose_answers == 0) return false;
        self.lose_answers -= 1;
        return true;
    }

    fn newId(self: *FakeFirestore, buf: *[20]u8) []const u8 {
        const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
        for (buf) |*c| c.* = alphabet[self.prng.random().uintLessThan(usize, alphabet.len)];
        return buf;
    }

    /// The path of `name` below this request's database, or null when it
    /// names another database or no document.
    fn pathOf(self: *FakeFirestore, arena: Allocator, route: Route, name: []const u8) Allocator.Error!?[]const u8 {
        _ = self;
        const prefix = try std.fmt.allocPrint(arena, "projects/{s}/databases/{s}/documents/", .{ route.project, route.database });
        if (!std.mem.startsWith(u8, name, prefix)) return null;
        const path = name[prefix.len..];
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |segment| : (n += 1) if (segment.len == 0) return null;
        if (n % 2 != 0) return null;
        return path;
    }
};

fn lessBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn ok(arena: Allocator, body: []const u8) Allocator.Error!FakeFirestore.Reply {
    _ = arena;
    return .{ .status = 200, .body = body };
}

fn fail(arena: Allocator, code: u16, status: []const u8, message: []const u8) Allocator.Error!FakeFirestore.Reply {
    return .{ .status = code, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = code,
        .message = message,
        .status = status,
    } }, .{}) };
}

fn lost(arena: Allocator) Allocator.Error!FakeFirestore.Reply {
    return fail(arena, 503, "UNAVAILABLE", "The service is currently unavailable.");
}

fn alreadyExists(arena: Allocator, route: FakeFirestore.Route, path: []const u8) Allocator.Error!FakeFirestore.Reply {
    return fail(arena, 409, "ALREADY_EXISTS", try std.fmt.allocPrint(arena, "Document already exists: {s}", .{try fullName(arena, route, path)}));
}

fn badPath(arena: Allocator, texts: []const []const u8) Allocator.Error!FakeFirestore.Reply {
    for (texts) |t| {
        if (t.len >= 1500) return fail(arena, 400, "INVALID_ARGUMENT", "property path is longer than 1500 bytes.");
        _ = splitFieldPath(arena, t) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Reserved => return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid reserved name in field path {s}", .{t})),
            error.Invalid => return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(
                arena,
                "Invalid property path \"{s}\". Unquoted property paths must match regex ([a-zA-Z_][a-zA-Z_0-9]*), and quoted property paths must match regex (`(?:[^`\\\\]|(?:\\\\.))+`)",
                .{t},
            )),
        };
    }
    return fail(arena, 400, "INVALID_ARGUMENT", "fake: bad field path");
}

fn fullName(arena: Allocator, route: FakeFirestore.Route, path: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "projects/{s}/databases/{s}/documents/{s}", .{ route.project, route.database, path });
}

fn join(arena: Allocator, segments: []const []const u8) Allocator.Error![]const u8 {
    return std.mem.join(arena, "/", segments);
}

/// The emulator's refusals of ids in a path.
fn idRefusal(arena: Allocator, segments: []const []const u8) Allocator.Error!?FakeFirestore.Reply {
    for (segments) |s| {
        if (s.len > 1500) return try fail(arena, 400, "INVALID_ARGUMENT", "The key path element name is longer than 1500 bytes.");
        if (s.len >= 5 and std.mem.startsWith(u8, s, "__") and std.mem.endsWith(u8, s, "__"))
            return try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Resource id \"{s}\" is invalid because it is reserved.", .{s}));
        if (s.len == 0) return try fail(arena, 400, "INVALID_ARGUMENT", "Document name has an empty segment.");
    }
    return null;
}

fn parseUrl(arena: Allocator, url: []const u8) Allocator.Error!?FakeFirestore.Route {
    const at = std.mem.indexOf(u8, url, "/v1/projects/") orelse return null;
    const rest = url[at + "/v1/projects/".len ..];
    const q = std.mem.indexOfScalar(u8, rest, '?');
    const path = rest[0 .. q orelse rest.len];
    const query = if (q) |i| rest[i + 1 ..] else "";
    var it = std.mem.splitScalar(u8, path, '/');
    const project = it.next() orelse return null;
    if (!std.mem.eql(u8, it.next() orelse "", "databases")) return null;
    const database = it.next() orelse return null;
    var docs = it.next() orelse return null;
    var verb: ?[]const u8 = null;
    var raw: std.ArrayList([]const u8) = .empty;
    // A verb follows the last segment after a colon; ids may hold colons
    // of their own, so only a known verb at the very end counts.
    const remaining = it.rest();
    if (it.index == null) {
        if (std.mem.indexOfScalar(u8, docs, ':')) |c| {
            verb = docs[c + 1 ..];
            docs = docs[0..c];
        }
    } else {
        var segs = std.mem.splitScalar(u8, remaining, '/');
        while (segs.next()) |s| try raw.append(arena, s);
        const last = raw.items[raw.items.len - 1];
        for ([_][]const u8{ ":listCollectionIds", ":commit", ":batchGet" }) |v| if (std.mem.endsWith(u8, last, v)) {
            verb = v[1..];
            raw.items[raw.items.len - 1] = last[0 .. last.len - v.len];
        };
    }
    if (!std.mem.eql(u8, docs, "documents")) return null;
    const segments = try arena.alloc([]const u8, raw.items.len);
    for (raw.items, segments) |r, *s| s.* = try percentDecode(arena, r);
    return .{ .project = project, .database = database, .segments = segments, .verb = verb, .query = query };
}

fn percentDecode(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const out = try arena.alloc(u8, text.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |b| {
                out[n] = b;
                n += 1;
                i += 2;
                continue;
            } else |_| {}
        }
        out[n] = text[i];
        n += 1;
    }
    return out[0..n];
}

/// Every value of the query parameter `name`, decoded.
fn queryAll(arena: Allocator, query: []const u8, name: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, try percentDecode(arena, pair[0..eq]), name)) continue;
        try out.append(arena, try percentDecode(arena, pair[eq + 1 ..]));
    }
    return out.items;
}

/// The first value of `name`, still encoded; ids and tokens here need no
/// decoding but `documentId`, which the caller decodes.
fn queryOne(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

/// The page size, 0 when absent, null when refused.
fn pageSize(query: []const u8) ?usize {
    const text = queryOne(query, "pageSize") orelse return 0;
    return std.fmt.parseInt(usize, text, 10) catch null;
}

fn pageStart(query: []const u8) ?usize {
    const token = queryOne(query, "pageToken") orelse return 0;
    return tokenStart(token);
}

fn tokenStart(token: []const u8) ?usize {
    if (!std.mem.startsWith(u8, token, "fake-")) return null;
    return std.fmt.parseInt(usize, token["fake-".len..], 10) catch null;
}

fn parseJson(arena: Allocator, body: []const u8) ?std.json.Value {
    const text = if (std.mem.trim(u8, body, " \t\r\n").len == 0) "{}" else body;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{ .parse_numbers = false }) catch null;
}

fn numberText(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .number_string, .string => |s| s,
        else => null,
    };
}

/// Splits a field path by the grammar the emulator's refusal states.
fn splitFieldPath(arena: Allocator, text: []const u8) error{ OutOfMemory, Invalid, Reserved }![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (true) {
        if (i >= text.len) return error.Invalid;
        var name: std.ArrayList(u8) = .empty;
        if (text[i] == '`') {
            i += 1;
            while (true) {
                if (i >= text.len) return error.Invalid;
                if (text[i] == '`') break;
                if (text[i] == '\\') {
                    i += 1;
                    if (i >= text.len) return error.Invalid;
                }
                try name.append(arena, text[i]);
                i += 1;
            }
            i += 1;
            if (name.items.len == 0) return error.Invalid;
        } else {
            const start = i;
            while (i < text.len and text[i] != '.') : (i += 1) {
                const c = text[i];
                const fine = std.ascii.isAlphabetic(c) or c == '_' or (i > start and std.ascii.isDigit(c));
                if (!fine) return error.Invalid;
            }
            if (i == start) return error.Invalid;
            try name.appendSlice(arena, text[start..i]);
        }
        const n = name.items;
        if (n.len >= 5 and std.mem.startsWith(u8, n, "__") and std.mem.endsWith(u8, n, "__") and
            !(std.mem.eql(u8, n, "__name__") and out.items.len == 0 and i == text.len)) return error.Reserved;
        try out.append(arena, n);
        if (i == text.len) return out.items;
        if (text[i] != '.') return error.Invalid;
        i += 1;
    }
}

/// Each mask path split into names, or null when one is refused.
fn parseMasks(arena: Allocator, texts: []const []const u8) Allocator.Error!?[]const []const []const u8 {
    const out = try arena.alloc([]const []const u8, texts.len);
    for (texts, out) |t, *o| {
        if (t.len >= 1500) return null;
        o.* = splitFieldPath(arena, t) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
    }
    return out;
}

// Values in

const ValueParser = struct {
    arena: Allocator,
    status: []const u8 = "INVALID_ARGUMENT",
    message: []const u8 = "Payload isn't valid for request.",

    fn refusal(p: *ValueParser) Allocator.Error!FakeFirestore.Reply {
        return fail(p.arena, 400, p.status, p.message);
    }

    fn refuse(p: *ValueParser, message: []const u8) ?[]const FakeFirestore.Entry {
        p.message = message;
        return null;
    }

    fn entries(p: *ValueParser, v: std.json.Value, depth: usize, top: bool) ?[]const FakeFirestore.Entry {
        if (v != .object) return null;
        const out = p.arena.alloc(FakeFirestore.Entry, v.object.count()) catch return null;
        var it = v.object.iterator();
        var i: usize = 0;
        while (it.next()) |e| : (i += 1) {
            const name = e.key_ptr.*;
            if (name.len == 0) return p.refuse("The property.name is the empty string.");
            if (name.len > 1500) return p.refuse("The property.name is longer than 1500 bytes.");
            if (name.len >= 5 and std.mem.startsWith(u8, name, "__") and std.mem.endsWith(u8, name, "__")) {
                return p.refuse(if (top)
                    std.fmt.allocPrint(p.arena, "field name {s} is reserved", .{name}) catch return null
                else
                    std.fmt.allocPrint(p.arena, "field name '{s}' is reserved.", .{name}) catch return null);
            }
            out[i] = .{ .name = name, .value = p.value(e.value_ptr.*, name, depth, false) orelse return null };
        }
        return out;
    }

    fn value(p: *ValueParser, v: std.json.Value, field: []const u8, depth: usize, in_array: bool) ?FakeFirestore.Val {
        if (v != .object) return null;
        if (v.object.count() == 0) {
            p.message = "Cannot convert firestore.v1.Value with type unset.";
            return null;
        }
        if (v.object.count() != 1) {
            p.message = "Payload isn't valid for request.";
            return null;
        }
        const kind = v.object.keys()[0];
        const inner = v.object.values()[0];
        const eq = std.mem.eql;
        if (eq(u8, kind, "nullValue")) return .null;
        if (eq(u8, kind, "booleanValue")) return if (inner == .bool) .{ .boolean = inner.bool } else null;
        if (eq(u8, kind, "integerValue")) return .{ .integer = std.fmt.parseInt(i64, numberText(inner) orelse return null, 10) catch return null };
        if (eq(u8, kind, "doubleValue")) return .{ .double = double(inner) orelse return null };
        if (eq(u8, kind, "timestampValue")) {
            if (inner != .string) return null;
            const ts = core.timestamp.parse(inner.string) catch return null;
            if (!core.timestamp.inRange(ts)) return null;
            return .{ .timestamp_us = @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_us)) };
        }
        if (eq(u8, kind, "stringValue")) {
            if (inner != .string) return null;
            if (inner.string.len > 1_048_487) {
                p.message = std.fmt.allocPrint(p.arena, "The value of property \"{s}\" is longer than 1048487 bytes.", .{field}) catch return null;
                return null;
            }
            return .{ .string = inner.string };
        }
        if (eq(u8, kind, "bytesValue")) {
            if (inner != .string) return null;
            return .{ .bytes = core.base64.decode(p.arena, inner.string) catch return null };
        }
        if (eq(u8, kind, "referenceValue")) {
            if (inner != .string) return null;
            return .{ .reference = inner.string };
        }
        if (eq(u8, kind, "geoPointValue")) {
            if (inner != .object) return null;
            const lat = if (inner.object.get("latitude")) |x| double(x) orelse return null else 0;
            const lon = if (inner.object.get("longitude")) |x| double(x) orelse return null else 0;
            if (!(lat >= -90 and lat <= 90)) {
                p.message = std.fmt.allocPrint(p.arena, "Geo point latitude '{d}' outside permitted range -90.0 to 90.0.", .{lat}) catch return null;
                return null;
            }
            if (!(lon >= -180 and lon <= 180)) {
                p.message = std.fmt.allocPrint(p.arena, "Geo point longitude '{d}' outside permitted range -180.0 to 180.0.", .{lon}) catch return null;
                return null;
            }
            return .{ .geo = .{ lat, lon } };
        }
        if (eq(u8, kind, "arrayValue")) {
            if (in_array) {
                p.message = "Nested arrays are not allowed";
                return null;
            }
            if (depth + 1 > 20) return p.tooDeep(field);
            if (inner != .object) return null;
            const values = inner.object.get("values") orelse return .{ .array = &.{} };
            if (values != .array) return null;
            const out = p.arena.alloc(FakeFirestore.Val, values.array.items.len) catch return null;
            for (values.array.items, out) |item, *o| o.* = p.value(item, "array", depth + 1, true) orelse return null;
            return .{ .array = out };
        }
        if (eq(u8, kind, "mapValue")) {
            if (depth + 1 > 20) return p.tooDeep(field);
            if (inner != .object) return null;
            const fields = inner.object.get("fields") orelse return .{ .map = &.{} };
            return .{ .map = p.entries(fields, depth + 1, false) orelse return null };
        }
        return null;
    }

    fn tooDeep(p: *ValueParser, field: []const u8) ?FakeFirestore.Val {
        p.message = std.fmt.allocPrint(p.arena, "Property {s} contains an invalid nested entity.", .{field}) catch return null;
        return null;
    }

    fn double(v: std.json.Value) ?f64 {
        const text = numberText(v) orelse return null;
        if (v == .string) {
            if (std.mem.eql(u8, text, "NaN")) return std.math.nan(f64);
            if (std.mem.eql(u8, text, "Infinity")) return std.math.inf(f64);
            if (std.mem.eql(u8, text, "-Infinity")) return -std.math.inf(f64);
        }
        return std.fmt.parseFloat(f64, text) catch null;
    }
};

// Masks applied

fn lookup(fields: []const FakeFirestore.Entry, segments: []const []const u8) ?FakeFirestore.Val {
    for (fields) |e| if (std.mem.eql(u8, e.name, segments[0])) {
        if (segments.len == 1) return e.value;
        return switch (e.value) {
            .map => |m| lookup(m, segments[1..]),
            else => null,
        };
    };
    return null;
}

/// `fields` with the value at `segments` set, maps made or replaced on
/// the way, as the emulator replaced a string it was asked to reach into.
fn setAt(arena: Allocator, fields: []const FakeFirestore.Entry, segments: []const []const u8, v: FakeFirestore.Val) Allocator.Error![]const FakeFirestore.Entry {
    var out: std.ArrayList(FakeFirestore.Entry) = .empty;
    try out.appendSlice(arena, fields);
    for (out.items) |*e| if (std.mem.eql(u8, e.name, segments[0])) {
        if (segments.len == 1) {
            e.value = v;
        } else {
            const inner: []const FakeFirestore.Entry = switch (e.value) {
                .map => |m| m,
                else => &.{},
            };
            e.value = .{ .map = try setAt(arena, inner, segments[1..], v) };
        }
        return out.items;
    };
    const value: FakeFirestore.Val = if (segments.len == 1) v else .{ .map = try setAt(arena, &.{}, segments[1..], v) };
    try out.append(arena, .{ .name = segments[0], .value = value });
    return out.items;
}

/// `fields` without the value at `segments`; maps emptied stay.
fn deleteAt(arena: Allocator, fields: []const FakeFirestore.Entry, segments: []const []const u8) Allocator.Error![]const FakeFirestore.Entry {
    var out: std.ArrayList(FakeFirestore.Entry) = .empty;
    for (fields) |e| {
        if (!std.mem.eql(u8, e.name, segments[0])) {
            try out.append(arena, e);
            continue;
        }
        if (segments.len == 1) continue;
        switch (e.value) {
            .map => |m| try out.append(arena, .{ .name = e.name, .value = .{ .map = try deleteAt(arena, m, segments[1..]) } }),
            else => try out.append(arena, e),
        }
    }
    return out.items;
}

/// Only the fields `masks` name, as a read mask returns them.
fn projected(arena: Allocator, fields: []const FakeFirestore.Entry, masks: []const []const []const u8) Allocator.Error![]const FakeFirestore.Entry {
    var out: []const FakeFirestore.Entry = &.{};
    for (masks) |segments| {
        if (segments.len == 1 and std.mem.eql(u8, segments[0], "__name__")) continue;
        if (lookup(fields, segments)) |v| out = try setAt(arena, out, segments, v);
    }
    return out;
}

fn deepCopy(a: Allocator, fields: []const FakeFirestore.Entry) Allocator.Error![]const FakeFirestore.Entry {
    const out = try a.alloc(FakeFirestore.Entry, fields.len);
    for (fields, out) |f, *o| o.* = .{ .name = try a.dupe(u8, f.name), .value = try copyVal(a, f.value) };
    return out;
}

fn copyVal(a: Allocator, v: FakeFirestore.Val) Allocator.Error!FakeFirestore.Val {
    return switch (v) {
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .bytes => |b| .{ .bytes = try a.dupe(u8, b) },
        .reference => |r| .{ .reference = try a.dupe(u8, r) },
        .array => |items| blk: {
            const out = try a.alloc(FakeFirestore.Val, items.len);
            for (items, out) |item, *o| o.* = try copyVal(a, item);
            break :blk .{ .array = out };
        },
        .map => |m| .{ .map = try deepCopy(a, m) },
        else => v,
    };
}

// Transforms applied

const Applied = union(enum) {
    refused: FakeFirestore.Reply,
    done: struct { fields: []const FakeFirestore.Entry, results: []const FakeFirestore.Val },
};

fn applyTransforms(arena: Allocator, start: []const FakeFirestore.Entry, transforms: std.json.Value, commit_us: i64) Allocator.Error!Applied {
    if (transforms != .array) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.") };
    var fields = start;
    var paths: std.ArrayList([]const []const u8) = .empty;
    const results = try arena.alloc(FakeFirestore.Val, transforms.array.items.len);
    for (transforms.array.items, results) |t, *result| {
        if (t != .object) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.") };
        const path_json = t.object.get("fieldPath") orelse return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.") };
        if (path_json != .string) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.") };
        const segments = (try parseMasks(arena, &.{path_json.string})) orelse return .{ .refused = try badPath(arena, &.{path_json.string}) };
        const path = segments[0];
        // Measured: one field and one inside it cannot both be transformed.
        for (paths.items) |other| {
            const n = @min(other.len, path.len);
            var same_prefix = true;
            for (other[0..n], path[0..n]) |x, y| if (!std.mem.eql(u8, x, y)) {
                same_prefix = false;
            };
            if (same_prefix and other.len != path.len) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(
                arena,
                "Cannot transform property {s} and its nested property at the same time.",
                .{(if (other.len < path.len) other else path)[n - 1]},
            )) };
        }
        try paths.append(arena, path);

        const current = lookup(fields, path);
        var parser: ValueParser = .{ .arena = arena };
        const new: FakeFirestore.Val, result.* = op: {
            if (t.object.get("setToServerValue")) |v| {
                if (v != .string or !std.mem.eql(u8, v.string, "REQUEST_TIME")) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.") };
                // Measured: to the millisecond.
                const at: FakeFirestore.Val = .{ .timestamp_us = @divFloor(commit_us, 1000) * 1000 };
                break :op .{ at, at };
            }
            inline for (.{ "increment", "maximum", "minimum" }) |kind| if (t.object.get(kind)) |v| {
                const operand = parser.value(v, path[path.len - 1], 0, false) orelse return .{ .refused = try parser.refusal() };
                if (operand != .integer and operand != .double) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Input must be int64 or double.") };
                const value = if (comptime std.mem.eql(u8, kind, "increment")) increment(current, operand) else extreme(current, operand, comptime std.mem.eql(u8, kind, "maximum"));
                break :op .{ value, value };
            };
            inline for (.{ "appendMissingElements", "removeAllFromArray" }) |kind| if (t.object.get(kind)) |v| {
                if (v != .object) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.") };
                var inputs: std.ArrayList(FakeFirestore.Val) = .empty;
                if (v.object.get("values")) |values| {
                    if (values != .array) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.") };
                    // Measured: the emulator took an array among them.
                    for (values.array.items) |item| try inputs.append(arena, parser.value(item, path[path.len - 1], 1, false) orelse return .{ .refused = try parser.refusal() });
                }
                const existing: []const FakeFirestore.Val = if (current) |c| (if (c == .array) c.array else &.{}) else &.{};
                var out: std.ArrayList(FakeFirestore.Val) = .empty;
                if (comptime std.mem.eql(u8, kind, "appendMissingElements")) {
                    try out.appendSlice(arena, existing);
                    for (inputs.items) |in| {
                        for (out.items) |e| {
                            if (equivalent(e, in)) break;
                        } else try out.append(arena, in);
                    }
                } else {
                    for (existing) |e| {
                        for (inputs.items) |in| {
                            if (equivalent(e, in)) break;
                        } else try out.append(arena, e);
                    }
                }
                break :op .{ .{ .array = out.items }, .null };
            };
            return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "A transform must name one operation.") };
        };
        fields = try setAt(arena, fields, path, new);
    }
    return .{ .done = .{ .fields = fields, .results = results } };
}

/// Measured: integers saturate, a double makes a double, and a field that
/// is no number takes the operand.
fn increment(current: ?FakeFirestore.Val, operand: FakeFirestore.Val) FakeFirestore.Val {
    const c = current orelse return operand;
    if (c == .integer and operand == .integer) {
        return .{ .integer = std.math.add(i64, c.integer, operand.integer) catch
            if (operand.integer > 0) std.math.maxInt(i64) else std.math.minInt(i64) };
    }
    const a = asDouble(c) orelse return operand;
    return .{ .double = a + asDouble(operand).? };
}

/// Measured: a field that is no number takes the operand, NaN wins, and
/// of two equal numbers the stored one stays, type and all.
fn extreme(current: ?FakeFirestore.Val, operand: FakeFirestore.Val, maximum: bool) FakeFirestore.Val {
    const c = current orelse return operand;
    if (asDouble(c) == null) return operand;
    if (isNan(c)) return c;
    if (isNan(operand)) return operand;
    const order = compareNumbers(c, operand);
    if (order == .eq) return c;
    return if ((order == .lt) == maximum) operand else c;
}

fn asDouble(v: FakeFirestore.Val) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .double => |d| d,
        else => null,
    };
}

fn isNan(v: FakeFirestore.Val) bool {
    return v == .double and std.math.isNan(v.double);
}

/// Exact for two integers; through doubles otherwise.
fn compareNumbers(a: FakeFirestore.Val, b: FakeFirestore.Val) std.math.Order {
    if (a == .integer and b == .integer) return std.math.order(a.integer, b.integer);
    return std.math.order(asDouble(a).?, asDouble(b).?);
}

/// Firestore's equality for the array transforms, as measured: numbers
/// across integer and double, NaN equal to NaN, maps by field whatever
/// their order.
fn equivalent(a: FakeFirestore.Val, b: FakeFirestore.Val) bool {
    if (asDouble(a) != null and asDouble(b) != null) {
        if (isNan(a) or isNan(b)) return isNan(a) and isNan(b);
        return compareNumbers(a, b) == .eq;
    }
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .boolean => |x| x == b.boolean,
        .timestamp_us => |x| x == b.timestamp_us,
        .string => |x| std.mem.eql(u8, x, b.string),
        .bytes => |x| std.mem.eql(u8, x, b.bytes),
        .reference => |x| std.mem.eql(u8, x, b.reference),
        .geo => |x| x[0] == b.geo[0] and x[1] == b.geo[1],
        .array => |x| arr: {
            if (x.len != b.array.len) break :arr false;
            for (x, b.array) |p, q| if (!equivalent(p, q)) break :arr false;
            break :arr true;
        },
        .map => |x| map: {
            if (x.len != b.map.len) break :map false;
            for (x) |e| {
                const other = lookup(b.map, &.{e.name}) orelse break :map false;
                if (!equivalent(e.value, other)) break :map false;
            }
            break :map true;
        },
        .integer, .double => unreachable,
    };
}

fn deepCopyVals(a: Allocator, values: []const FakeFirestore.Val) Allocator.Error![]const FakeFirestore.Val {
    const out = try a.alloc(FakeFirestore.Val, values.len);
    for (values, out) |v, *o| o.* = try copyVal(a, v);
    return out;
}

// Values out

fn renderDoc(arena: Allocator, name: []const u8, d: *const FakeFirestore.Doc, masks: ?[]const []const []const u8) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeDoc(&jw, arena, name, d, masks) catch return error.OutOfMemory;
    return out.written();
}

fn writeDoc(jw: *Stringify, arena: Allocator, name: []const u8, d: *const FakeFirestore.Doc, masks: ?[]const []const []const u8) !void {
    const fields = if (masks) |m| try projected(arena, d.fields, m) else d.fields;
    try writeDocFields(jw, name, d, fields);
}

fn writeDocFields(jw: *Stringify, name: []const u8, d: *const FakeFirestore.Doc, fields: []const FakeFirestore.Entry) !void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(name);
    // Measured: a document with no fields, or a mask that matched none,
    // has no `fields` member at all.
    if (fields.len > 0) {
        try jw.objectField("fields");
        try writeEntries(jw, fields);
    }
    try jw.objectField("createTime");
    try writeTime(jw, d.create_us);
    try jw.objectField("updateTime");
    try writeTime(jw, d.update_us);
    try jw.endObject();
}

fn writeEntries(jw: *Stringify, fields: []const FakeFirestore.Entry) Stringify.Error!void {
    try jw.beginObject();
    for (fields) |f| {
        try jw.objectField(f.name);
        try writeVal(jw, f.value);
    }
    try jw.endObject();
}

fn writeVal(jw: *Stringify, v: FakeFirestore.Val) Stringify.Error!void {
    try jw.beginObject();
    switch (v) {
        .null => {
            try jw.objectField("nullValue");
            try jw.write(null);
        },
        .boolean => |b| {
            try jw.objectField("booleanValue");
            try jw.write(b);
        },
        .integer => |i| {
            try jw.objectField("integerValue");
            try jw.print("\"{d}\"", .{i});
        },
        .double => |d| {
            try jw.objectField("doubleValue");
            try writeJavaDouble(jw, d);
        },
        .timestamp_us => |us| {
            try jw.objectField("timestampValue");
            try writeTime(jw, us);
        },
        .string => |s| {
            try jw.objectField("stringValue");
            try jw.write(s);
        },
        .bytes => |b| {
            try jw.objectField("bytesValue");
            try core.base64.writeJsonString(jw, b);
        },
        .reference => |r| {
            try jw.objectField("referenceValue");
            try jw.write(r);
        },
        .geo => |g| {
            try jw.objectField("geoPointValue");
            try jw.beginObject();
            if (g[0] != 0) {
                try jw.objectField("latitude");
                try writeJavaDouble(jw, g[0]);
            }
            if (g[1] != 0) {
                try jw.objectField("longitude");
                try writeJavaDouble(jw, g[1]);
            }
            try jw.endObject();
        },
        .array => |items| {
            try jw.objectField("arrayValue");
            try jw.beginObject();
            if (items.len > 0) {
                try jw.objectField("values");
                try jw.beginArray();
                for (items) |item| try writeVal(jw, item);
                try jw.endArray();
            }
            try jw.endObject();
        },
        .map => |m| {
            try jw.objectField("mapValue");
            try jw.beginObject();
            if (m.len > 0) {
                try jw.objectField("fields");
                try writeEntries(jw, m);
            }
            try jw.endObject();
        },
    }
    try jw.endObject();
}

/// A double as the emulator, in Java, printed one: `3.0`, `0.1`,
/// `1.0E300`, `4.9E-324`, and -0.0 as 0.0.
fn writeJavaDouble(jw: *Stringify, d: f64) Stringify.Error!void {
    if (std.math.isNan(d)) return jw.write("NaN");
    if (std.math.isInf(d)) return jw.write(if (d > 0) "Infinity" else "-Infinity");
    if (d == 0) return jw.print("0.0", .{});
    var buf: [64]u8 = undefined;
    const magnitude = @abs(d);
    if (magnitude >= 1e-3 and magnitude < 1e7) {
        const text = std.fmt.bufPrint(&buf, "{d}", .{d}) catch unreachable;
        if (std.mem.indexOfScalar(u8, text, '.') == null) return jw.print("{s}.0", .{text});
        return jw.print("{s}", .{text});
    }
    const text = std.fmt.bufPrint(&buf, "{e}", .{d}) catch unreachable;
    const e = std.mem.indexOfScalar(u8, text, 'e').?;
    const mantissa = text[0..e];
    if (std.mem.indexOfScalar(u8, mantissa, '.') == null) return jw.print("{s}.0E{s}", .{ mantissa, text[e + 1 ..] });
    return jw.print("{s}E{s}", .{ mantissa, text[e + 1 ..] });
}

fn writeTime(jw: *Stringify, us: i64) Stringify.Error!void {
    var buf: [core.timestamp.max_len]u8 = undefined;
    try jw.write(core.timestamp.format(&buf, .{ .nanoseconds = @as(i96, us) * std.time.ns_per_us }));
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const types = @import("types.zig");
const codec = @import("codec.zig");
const names = @import("names.zig");
const Field = types.Field;
const Value = types.Value;

/// A raw request to the fake, for what the library never sends.
fn rawRequest(server: *FakeFirestore, arena: Allocator, method: tp.Method, path: []const u8, body: []const u8) !FakeFirestore.Reply {
    const url = try std.fmt.allocPrint(arena, "https://firestore.googleapis.com/v1/projects/p/databases/(default)/documents{s}", .{path});
    return server.serve(method, url, body, arena);
}

fn expectRefusal(reply: FakeFirestore.Reply, status: u16, part: []const u8) !void {
    testing.expectEqual(status, reply.status) catch |err| {
        std.debug.print("answer: {s}\n", .{reply.body});
        return err;
    };
    if (std.mem.indexOf(u8, reply.body, part) == null) {
        std.debug.print("answer: {s}\n", .{reply.body});
        return error.TestUnexpectedAnswer;
    }
}

test "fake: documents through the client, as the emulator suite drives them" {
    var h: test_util.FakeHarness = undefined;
    try h.init(.{});
    defer h.deinit();
    const cities = h.client.collection("cities");
    var la = try cities.create(&.{.{ .name = "population", .value = .{ .integer = 3_900_000 } }}, .{ .document_id = "LA" });
    defer la.deinit();
    try testing.expectError(error.AlreadyExists, cities.create(&.{}, .{ .document_id = "LA" }));
    try h.expectDiag("Document already exists");

    const doc = cities.doc("LA");
    const updated = try doc.update(&.{.{ .name = "population", .value = .{ .integer = 4_000_000 } }}, .{ .precondition = .{ .update_time = la.value.update_time } });
    try testing.expect(updated.update_time.nanoseconds > la.value.update_time.nanoseconds);
    try testing.expectError(error.FailedPrecondition, doc.update(&.{.{ .name = "population", .value = .{ .integer = 1 } }}, .{ .precondition = .{ .update_time = la.value.update_time } }));
    try h.expectDiag("does not match the required base version");
    var got = try doc.get(.{});
    defer got.deinit();
    try testing.expectEqual(4_000_000, got.value.get("population").?.integer);
    try testing.expectEqual(la.value.create_time.nanoseconds, got.value.create_time.nanoseconds);

    try testing.expectError(error.NotFound, cities.doc("SF").update(&.{.{ .name = "x", .value = .null }}, .{}));
    try h.expectDiag("No document to update");
    try testing.expectError(error.AlreadyExists, doc.set(&.{}, .{ .precondition = .{ .exists = false } }));
    try doc.delete(.{ .precondition = .{ .exists = true } });
    try testing.expectError(error.NotFound, doc.get(.{}));
    try h.expectDiag("not found");
    try doc.delete(.{});
    try testing.expectError(error.NotFound, doc.delete(.{ .precondition = .{ .exists = true } }));
    try testing.expectEqual(0, h.server.count("(default)"));
}

test "fake: masks as the emulator applied them" {
    var h: test_util.FakeHarness = undefined;
    try h.init(.{});
    defer h.deinit();
    const doc = h.client.doc("masks/m");
    _ = try doc.set(&.{
        .{ .name = "address", .value = .{ .map = &.{
            .{ .name = "city", .value = .{ .string = "LA" } },
            .{ .name = "zip", .value = .{ .string = "90001" } },
        } } },
        .{ .name = "s", .value = .{ .string = "x" } },
        .{ .name = "nickname", .value = .{ .string = "City of Angels" } },
    }, .{});
    _ = try doc.update(&.{
        .{ .name = "address", .value = .{ .map = &.{.{ .name = "city", .value = .{ .string = "Los Angeles" } }} } },
        .{ .name = "s", .value = .{ .map = &.{.{ .name = "t", .value = .{ .boolean = true } }} } },
    }, .{ .mask = &.{ "address.city", "nickname", "s.t" } });
    var got = try doc.get(.{});
    defer got.deinit();
    try testing.expectEqualStrings("Los Angeles", got.value.get("address").?.get("city").?.string);
    try testing.expectEqualStrings("90001", got.value.get("address").?.get("zip").?.string);
    try testing.expectEqual(null, got.value.get("nickname"));
    // Measured: reaching into a string replaced it with a map.
    try testing.expect(got.value.get("s").?.get("t").?.boolean);

    _ = try doc.update(&.{}, .{ .mask = &.{ "address.city", "address.zip" } });
    var emptied = try doc.get(.{ .mask = &.{ "address", "missing" } });
    defer emptied.deinit();
    try testing.expectEqual(1, emptied.value.fields.len);
    try testing.expectEqual(0, emptied.value.get("address").?.map.len);
    var bare = try doc.get(.{ .mask = &.{"__name__"} });
    defer bare.deinit();
    try testing.expectEqual(0, bare.value.fields.len);
}

test "fake: listing and collection ids" {
    var h: test_util.FakeHarness = undefined;
    try h.init(.{});
    defer h.deinit();
    for ([_][]const u8{ "items/b", "items/a", "items/c", "items/a/sub/s", "other/o/deep/d", "zeta/z" }) |path| {
        _ = try h.client.doc(path).set(&.{}, .{});
    }
    var first = try h.client.collection("items").list(.{ .page_size = 2 });
    defer first.deinit();
    try testing.expectEqual(2, first.value.documents.len);
    try testing.expectEqualStrings("a", first.value.documents[0].id());
    try testing.expectEqualStrings("b", first.value.documents[1].id());
    var second = try h.client.collection("items").list(.{ .page_size = 2, .page_token = first.value.next_page_token });
    defer second.deinit();
    try testing.expectEqual(1, second.value.documents.len);
    try testing.expectEqual(null, second.value.next_page_token);
    var none = try h.client.collection("nothing").list(.{});
    defer none.deinit();
    try testing.expectEqual(0, none.value.documents.len);

    var root = try h.client.listCollectionIds(.{});
    defer root.deinit();
    try testing.expectEqual(3, root.value.collection_ids.len);
    try testing.expectEqualStrings("items", root.value.collection_ids[0]);
    var paged = try h.client.listCollectionIds(.{ .page_size = 2 });
    defer paged.deinit();
    try testing.expectEqual(2, paged.value.collection_ids.len);
    var rest = try h.client.listCollectionIds(.{ .page_token = paged.value.next_page_token });
    defer rest.deinit();
    try testing.expectEqualStrings("zeta", rest.value.collection_ids[0]);
    var deep = try h.client.doc("other/o").listCollectionIds(.{});
    defer deep.deinit();
    try testing.expectEqualStrings("deep", deep.value.collection_ids[0]);
}

test "fake: values refused in the emulator's words" {
    var server: FakeFirestore = .init(testing.allocator);
    defer server.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = "{\"writes\":[{\"update\":{\"name\":\"projects/p/databases/(default)/documents/c/r\",\"fields\":";
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"__x__\":{\"integerValue\":\"1\"}}", "field name __x__ is reserved" },
        .{ "{\"m\":{\"mapValue\":{\"fields\":{\"__y__\":{\"integerValue\":\"1\"}}}}}", "field name '__y__' is reserved." },
        .{ "{\"\":{\"integerValue\":\"1\"}}", "The property.name is the empty string." },
        .{ "{\"a\":{\"arrayValue\":{\"values\":[{\"arrayValue\":{\"values\":[]}}]}}}", "Nested arrays are not allowed" },
        .{ "{\"k\":{\"integerValue\":\"1\",\"stringValue\":\"x\"}}", "Payload isn't valid for request." },
        .{ "{\"k\":{}}", "Cannot convert firestore.v1.Value with type unset." },
        .{ "{\"g\":{\"geoPointValue\":{\"latitude\":91,\"longitude\":0}}}", "outside permitted range -90.0 to 90.0" },
        .{ "{\"t\":{\"timestampValue\":\"0000-12-31T00:00:00Z\"}}", "Payload isn't valid for request." },
        .{ "{\"k\":{\"unknownValue\":1}}", "Payload isn't valid for request." },
    };
    for (cases) |case| {
        const body = try std.fmt.allocPrint(a, "{s}{s}}}}}]}}", .{ w, case[0] });
        try expectRefusal(try rawRequest(&server, a, .POST, ":commit", body), 400, case[1]);
    }
    // 21 maps deep is one too many.
    var deep: Writer.Allocating = .init(a);
    try deep.writer.writeAll("{\"f\":");
    for (0..21) |_| try deep.writer.writeAll("{\"mapValue\":{\"fields\":{\"k\":");
    try deep.writer.writeAll("{\"integerValue\":\"1\"}");
    for (0..21) |_| try deep.writer.writeAll("}}}");
    try deep.writer.writeAll("}");
    try expectRefusal(try rawRequest(&server, a, .POST, ":commit", try std.fmt.allocPrint(a, "{s}{s}}}}}]}}", .{ w, deep.written() })), 400, "contains an invalid nested entity");
    // A string one byte over.
    const big = try a.alloc(u8, 1_048_488);
    @memset(big, 'x');
    try expectRefusal(try rawRequest(&server, a, .POST, ":commit", try std.fmt.allocPrint(a, "{s}{{\"s\":{{\"stringValue\":\"{s}\"}}}}}}}}]}}", .{ w, big })), 400, "The value of property \\\"s\\\" is longer than 1048487 bytes.");
    // Ids and paths.
    try expectRefusal(try rawRequest(&server, a, .GET, "/c/__x__", ""), 400, "__x__\\\" is invalid because it is reserved.");
    try expectRefusal(try rawRequest(&server, a, .GET, "/c/x?mask.fieldPaths=a-b", ""), 400, "Invalid property path \\\"a-b\\\".");
    try expectRefusal(try rawRequest(&server, a, .GET, "/c/x?mask.fieldPaths=__x__", ""), 400, "Invalid reserved name in field path __x__");
    try expectRefusal(try rawRequest(&server, a, .GET, "/c?pageSize=-1", ""), 400, "Page size must be nonnegative.");
    try expectRefusal(try rawRequest(&server, a, .GET, "/c?pageToken=garbage", ""), 400, "invalid page token");
    // Nothing was stored by any of it.
    try testing.expectEqual(0, server.count("(default)"));
}

test "fake: ids and field paths that travel encoded, and ids it chooses" {
    var h: test_util.FakeHarness = undefined;
    try h.init(.{});
    defer h.deinit();
    for ([_][]const u8{ "a b%c+d", "a:b", "été", "x?y#z", "back\\slash" }) |id| {
        _ = try h.client.collection("odd").doc(id).set(&.{.{ .name = "c`d", .value = .{ .map = &.{.{ .name = "e f", .value = .{ .string = id } }} } }}, .{});
        var got = try h.client.collection("odd").doc(id).get(.{ .mask = &.{"`c\\`d`.`e f`"} });
        defer got.deinit();
        try testing.expectEqualStrings(id, got.value.id());
        try testing.expectEqualStrings(id, got.value.get("c`d").?.get("e f").?.string);
    }
    var page = try h.client.collection("odd").list(.{ .mask = &.{"`c\\`d`"} });
    defer page.deinit();
    try testing.expectEqual(5, page.value.documents.len);

    // The library always names the id; a bare POST lets the fake choose.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const made = try h.server.serve(.POST, "https://firestore.googleapis.com/v1/projects/p/databases/(default)/documents/auto", "{\"fields\":{}}", arena.allocator());
    const snapshot = try codec.decodeSnapshot(arena.allocator(), made.body);
    try testing.expectEqual(20, snapshot.id().len);
    try expectRefusal(try h.server.serve(.PATCH, "https://firestore.googleapis.com/v1/projects/p/databases/(default)/documents/c/x", "{}", arena.allocator()), 400, "not modelled");
    try expectRefusal(try h.server.serve(.GET, "https://firestore.googleapis.com/v1/projects/p/databases/(default)/documents/c?orderBy=v", "", arena.allocator()), 400, "not modelled");
    try expectRefusal(try h.server.serve(.POST, "https://firestore.googleapis.com/v1/projects/p/databases/(default)/documents/c?documentId=x", "{\"fields\":{\"s\":{\"geoPointValue\":{\"latitude\":0,\"longitude\":181}}}}", arena.allocator()), 400, "longitude");
}

test "fake: answers as the emulator wrote them" {
    var server: FakeFirestore = .init(testing.allocator);
    defer server.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const reply = try rawRequest(&server, a, .POST, "/c?documentId=dbl",
        \\{"fields":{"a":{"doubleValue":0.1},"b":{"doubleValue":3},"c":{"doubleValue":-0.0},"d":{"doubleValue":"Infinity"},"e":{"doubleValue":"NaN"},
        \\ "f":{"doubleValue":5e-324},"g":{"doubleValue":1e21},"h":{"doubleValue":1234567.0},"n":{"nullValue":"NULL_VALUE"},"i":{"integerValue":5},
        \\ "geo":{"geoPointValue":{"latitude":0,"longitude":10}},"ea":{"arrayValue":{}},"em":{"mapValue":{}},"bytes":{"bytesValue":"AP_-"},
        \\ "t":{"timestampValue":"2026-10-04T00:00:00.123456789Z"}}}
    );
    try testing.expectEqual(200, reply.status);
    for ([_][]const u8{
        "\"a\":{\"doubleValue\":0.1}",
        "\"b\":{\"doubleValue\":3.0}",
        "\"c\":{\"doubleValue\":0.0}",
        "\"d\":{\"doubleValue\":\"Infinity\"}",
        "\"e\":{\"doubleValue\":\"NaN\"}",
        "\"f\":{\"doubleValue\":5.0E-324}",
        "\"g\":{\"doubleValue\":1.0E21}",
        "\"h\":{\"doubleValue\":1234567.0}",
        "\"n\":{\"nullValue\":null}",
        "\"i\":{\"integerValue\":\"5\"}",
        "\"geo\":{\"geoPointValue\":{\"longitude\":10.0}}",
        "\"ea\":{\"arrayValue\":{}}",
        "\"em\":{\"mapValue\":{}}",
        "\"bytes\":{\"bytesValue\":\"AP/+\"}",
        "\"t\":{\"timestampValue\":\"2026-10-04T00:00:00.123456Z\"}",
    }) |part| {
        if (std.mem.indexOf(u8, reply.body, part) == null) {
            std.debug.print("missing {s} in {s}\n", .{ part, reply.body });
            return error.TestUnexpectedAnswer;
        }
    }
    // And the library reads all of it.
    _ = try codec.decodeSnapshot(a, reply.body);
}

test "fake: a commit lands whole or not at all" {
    var server: FakeFirestore = .init(testing.allocator);
    defer server.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = "projects/p/databases/(default)/documents/c/";
    try testing.expectEqual(200, (try rawRequest(&server, a, .POST, ":commit", "{\"writes\":[{\"update\":{\"name\":\"" ++ n ++ "x\",\"fields\":{}}}]}")).status);
    const before = server.now_us;
    // The second write's precondition fails, so the first does not land.
    try expectRefusal(try rawRequest(&server, a, .POST, ":commit", "{\"writes\":[{\"update\":{\"name\":\"" ++ n ++ "y\",\"fields\":{}}},{\"update\":{\"name\":\"" ++ n ++ "x\",\"fields\":{}},\"currentDocument\":{\"exists\":false}}]}"), 409, "Document already exists");
    try testing.expectEqual(null, server.doc("(default)", "c/y"));
    try testing.expectEqual(before, server.now_us);
    // Two writes, one time; a delete's result is empty.
    const both = try rawRequest(&server, a, .POST, ":commit", "{\"writes\":[{\"update\":{\"name\":\"" ++ n ++ "y\",\"fields\":{}}},{\"delete\":\"" ++ n ++ "x\"}]}");
    const r = try codec.decodeCommit(a, both.body);
    try testing.expectEqual(r.commit_time.?.nanoseconds, r.writes[0].update_time.?.nanoseconds);
    try testing.expectEqual(null, r.writes[1].update_time);
    try testing.expectEqual(null, server.doc("(default)", "c/x"));
    // Measured: a precondition sees the commit's earlier writes.
    try testing.expectEqual(200, (try rawRequest(&server, a, .POST, ":commit", "{\"writes\":[{\"delete\":\"" ++ n ++ "y\"},{\"update\":{\"name\":\"" ++ n ++ "y\",\"fields\":{}},\"currentDocument\":{\"exists\":false}}]}")).status);
    try testing.expect(server.doc("(default)", "c/y") != null);
    // A name in another database is refused.
    try expectRefusal(try rawRequest(&server, a, .POST, ":commit", "{\"writes\":[{\"delete\":\"projects/p/databases/other/documents/c/x\"}]}"), 400, "not in this database");
}

test "fake: lost answers, and how the client takes them" {
    var h: test_util.FakeHarness = undefined;
    try h.init(.{});
    defer h.deinit();
    const cities = h.client.collection("cities");

    // An unconditional set lands, loses its answer, lands again.
    h.server.lose_answers = 1;
    _ = try cities.doc("LA").set(&.{.{ .name = "v", .value = .{ .integer = 1 } }}, .{});
    try testing.expectEqual(2, h.server.requests);

    // A create under the library's own id reads its document back.
    h.server.lose_answers = 1;
    var made = try cities.create(&.{.{ .name = "v", .value = .{ .integer = 2 } }}, .{});
    defer made.deinit();
    try testing.expectEqual(2, made.value.get("v").?.integer);
    try testing.expectEqual(5, h.server.requests);
    try testing.expectEqual(2, h.server.count("(default)"));

    // Under a chosen id it is AlreadyExists, said to be ambiguous.
    h.server.lose_answers = 1;
    try testing.expectError(error.AlreadyExists, cities.create(&.{}, .{ .document_id = "SF" }));
    try h.expectDiag("an earlier attempt may have landed");
    try testing.expect(h.server.doc("(default)", "cities/SF") != null);

    // A write under an update time meets its own landed attempt.
    var la = try cities.doc("LA").get(.{});
    defer la.deinit();
    h.server.lose_answers = 1;
    try testing.expectError(error.FailedPrecondition, cities.doc("LA").update(&.{.{ .name = "v", .value = .{ .integer = 3 } }}, .{ .precondition = .{ .update_time = la.value.update_time } }));
    try h.expectDiag("an earlier attempt may have landed");
    var after = try cities.doc("LA").get(.{});
    defer after.deinit();
    try testing.expectEqual(3, after.value.get("v").?.integer);

    // Refused before landing: the retry is the only write.
    h.server.refuse_next = 2;
    _ = try cities.doc("NY").set(&.{}, .{});
    try testing.expect(h.server.doc("(default)", "cities/NY") != null);
}

test "fake: transforms answer as the emulator answered them" {
    var h: test_util.FakeHarness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.client.retry_unconditional_writes = true;
    const I = struct {
        fn int(n: i64) Value {
            return .{ .integer = n };
        }
        fn dbl(d: f64) Value {
            return .{ .double = d };
        }
    };
    // Each case: what the field held (null: missing), the transform, and
    // what the emulator answered, 2026-10-05.
    const nan = std.math.nan(f64);
    const cases = [_]struct { ?Value, types.Transform.Op, Value }{
        .{ I.int(5), .{ .increment = .{ .integer = 1 } }, I.int(6) },
        .{ I.int(std.math.maxInt(i64)), .{ .increment = .{ .integer = 1 } }, I.int(std.math.maxInt(i64)) },
        .{ I.int(std.math.minInt(i64)), .{ .increment = .{ .integer = -5 } }, I.int(std.math.minInt(i64)) },
        .{ I.int(5), .{ .increment = .{ .double = 0.5 } }, I.dbl(5.5) },
        .{ null, .{ .increment = .{ .integer = 3 } }, I.int(3) },
        .{ .{ .string = "a" }, .{ .increment = .{ .integer = 2 } }, I.int(2) },
        .{ null, .{ .increment = .{ .double = nan } }, I.dbl(nan) },
        .{ I.int(3), .{ .maximum = .{ .double = 3.0 } }, I.int(3) },
        .{ I.dbl(3.0), .{ .maximum = .{ .integer = 3 } }, I.dbl(3.0) },
        .{ I.int(5), .{ .maximum = .{ .double = 7.5 } }, I.dbl(7.5) },
        .{ I.dbl(1.5), .{ .minimum = .{ .integer = 1 } }, I.int(1) },
        .{ I.int(0), .{ .maximum = .{ .double = nan } }, I.dbl(nan) },
        .{ I.dbl(nan), .{ .minimum = .{ .integer = 4 } }, I.dbl(nan) },
        .{ null, .{ .minimum = .{ .integer = 4 } }, I.int(4) },
        .{ I.int(9), .{ .minimum = .{ .integer = 4 } }, I.int(4) },
        .{ I.int(9), .{ .maximum = .{ .integer = 4 } }, I.int(9) },
    };
    for (cases, 0..) |case, i| {
        var id_buf: [8]u8 = undefined;
        const path = try std.fmt.bufPrint(&id_buf, "t/{d}", .{i});
        var r = try h.client.commit(&.{.{ .update = .{
            .path = path,
            .fields = if (case[0]) |v| &.{.{ .name = "x", .value = v }} else &.{},
            .transforms = &.{.{ .field_path = "x", .op = case[1] }},
        } }}, .{});
        defer r.deinit();
        codec.expectValueEqual(case[2], r.value.writes[0].transform_results[0]) catch |err| {
            std.debug.print("case {d}: got {any}\n", .{ i, r.value.writes[0].transform_results[0] });
            return err;
        };
        var got = try h.client.doc(path).get(.{});
        defer got.deinit();
        try codec.expectValueEqual(case[2], got.value.get("x").?);
    }

    // The array transforms: 3 and 3.0 are one, NaN is NaN, null is null,
    // a value given twice is added once, and maps match field by field.
    _ = try h.client.doc("t/arr").set(&.{
        .{ .name = "a", .value = .{ .array = &.{ I.int(3), I.dbl(nan), .null } } },
        .{ .name = "m", .value = .{ .array = &.{.{ .map = &.{ .{ .name = "x", .value = I.int(1) }, .{ .name = "y", .value = I.int(2) } } }} } },
    }, .{ .transforms = &.{
        .{ .field_path = "a", .op = .{ .append_missing = &.{ I.dbl(3.0), I.dbl(nan), .null, I.int(4), I.int(4), I.dbl(4.0) } } },
        .{ .field_path = "b", .op = .{ .append_missing = &.{I.int(1)} } },
        .{ .field_path = "c", .op = .{ .remove_all = &.{I.int(1)} } },
        .{ .field_path = "m", .op = .{ .append_missing = &.{.{ .map = &.{ .{ .name = "y", .value = I.dbl(2.0) }, .{ .name = "x", .value = I.int(1) } } }} } },
    } });
    var arr = try h.client.doc("t/arr").get(.{});
    defer arr.deinit();
    try codec.expectValueEqual(.{ .array = &.{ I.int(3), I.dbl(nan), .null, I.int(4) } }, arr.value.get("a").?);
    try codec.expectValueEqual(.{ .array = &.{I.int(1)} }, arr.value.get("b").?);
    try codec.expectValueEqual(.{ .array = &.{} }, arr.value.get("c").?);
    try testing.expectEqual(1, arr.value.get("m").?.array.len);
    _ = try h.client.doc("t/arr").update(&.{}, .{ .transforms = &.{.{ .field_path = "a", .op = .{ .remove_all = &.{ I.dbl(3.0), I.dbl(nan) } } }} });
    var removed = try h.client.doc("t/arr").get(.{});
    defer removed.deinit();
    try codec.expectValueEqual(.{ .array = &.{ .null, I.int(4) } }, removed.value.get("a").?);

    // Server time: to the millisecond, the same in every field of a commit;
    // transforms on a nested path make the maps on the way.
    var times = try h.client.commit(&.{.{ .update = .{ .path = "t/time", .transforms = &.{
        .{ .field_path = "a", .op = .server_time },
        .{ .field_path = "deep.b", .op = .server_time },
    } } }}, .{});
    defer times.deinit();
    const ta = times.value.writes[0].transform_results[0].timestamp;
    try testing.expectEqual(ta, times.value.writes[0].transform_results[1].timestamp);
    try testing.expectEqual(0, @mod(ta.nanoseconds, std.time.ns_per_ms));
    var timed = try h.client.doc("t/time").get(.{});
    defer timed.deinit();
    try testing.expectEqual(ta, timed.value.get("deep").?.get("b").?.timestamp);
}

test "fake: transform refusals, and transforms beside a mask" {
    var server: FakeFirestore = .init(testing.allocator);
    defer server.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = "projects/p/databases/(default)/documents/t/a";
    try expectRefusal(try rawRequest(&server, a, .POST, ":commit", "{\"writes\":[{\"update\":{\"name\":\"" ++ n ++ "\",\"fields\":{}},\"updateMask\":{\"fieldPaths\":[]},\"updateTransforms\":[{\"fieldPath\":\"m\",\"setToServerValue\":\"REQUEST_TIME\"},{\"fieldPath\":\"m.b\",\"increment\":{\"integerValue\":\"1\"}}]}]}"), 400, "Cannot transform property m and its nested property at the same time.");
    try expectRefusal(try rawRequest(&server, a, .POST, ":commit", "{\"writes\":[{\"update\":{\"name\":\"" ++ n ++ "\",\"fields\":{}},\"updateTransforms\":[{\"fieldPath\":\"n\",\"increment\":{\"stringValue\":\"x\"}}]}]}"), 400, "Input must be int64 or double.");
    try expectRefusal(try rawRequest(&server, a, .POST, ":commit", "{\"writes\":[{\"delete\":\"" ++ n ++ "\",\"updateTransforms\":[]}]}"), 400, "cannot carry transforms");
    try testing.expectEqual(0, server.count("(default)"));
    // An empty mask keeps what is there; no mask replaces it first.
    _ = try rawRequest(&server, a, .POST, ":commit", "{\"writes\":[{\"update\":{\"name\":\"" ++ n ++ "\",\"fields\":{\"keep\":{\"integerValue\":\"1\"},\"n\":{\"integerValue\":\"5\"}}}}]}");
    _ = try rawRequest(&server, a, .POST, ":commit", "{\"writes\":[{\"update\":{\"name\":\"" ++ n ++ "\",\"fields\":{}},\"updateMask\":{\"fieldPaths\":[]},\"updateTransforms\":[{\"fieldPath\":\"n\",\"increment\":{\"integerValue\":\"1\"}}]}]}");
    try testing.expectEqual(2, server.doc("(default)", "t/a").?.fields.len);
    _ = try rawRequest(&server, a, .POST, ":commit", "{\"writes\":[{\"update\":{\"name\":\"" ++ n ++ "\",\"fields\":{}},\"updateTransforms\":[{\"fieldPath\":\"n\",\"increment\":{\"integerValue\":\"1\"}}]}]}");
    try testing.expectEqual(1, server.doc("(default)", "t/a").?.fields.len);
    try testing.expectEqual(1, server.doc("(default)", "t/a").?.fields[0].value.integer);
    // Measured: a commit of nothing answers `{}`.
    try testing.expectEqualStrings("{}", (try rawRequest(&server, a, .POST, ":commit", "{\"writes\":[]}")).body);
}

test "fake: batchGet through the client, and a transform's lost answer" {
    var h: test_util.FakeHarness = undefined;
    try h.init(.{});
    defer h.deinit();
    _ = try h.client.doc("c/b").set(&.{.{ .name = "v", .value = .{ .integer = 2 } }}, .{});
    _ = try h.client.doc("c/a").set(&.{ .{ .name = "v", .value = .{ .integer = 1 } }, .{ .name = "w", .value = .null } }, .{});
    var r = try h.client.batchGet(&.{ "c/b", "c/none", "c/a", "c/b" }, .{ .mask = &.{"v"} });
    defer r.deinit();
    try testing.expectEqual(2, r.value.documents[0].?.get("v").?.integer);
    try testing.expectEqual(null, r.value.documents[1]);
    try testing.expectEqual(1, r.value.documents[2].?.get("v").?.integer);
    try testing.expectEqual(1, r.value.documents[2].?.fields.len);
    try testing.expectEqual(2, r.value.documents[3].?.get("v").?.integer);
    // The fake keeps no history.
    try testing.expectError(error.InvalidArgument, h.client.doc("c/a").get(.{ .read_time = .{ .nanoseconds = 1_791_072_000_000_000_000 } }));

    // An increment whose answer was lost landed; it is not sent again.
    h.server.lose_answers = 1;
    try testing.expectError(error.Unavailable, h.client.doc("c/a").update(&.{}, .{ .transforms = &.{.{ .field_path = "v", .op = .{ .increment = .{ .integer = 10 } } }} }));
    try h.expectDiag("may or may not have landed");
    var after = try h.client.doc("c/a").get(.{});
    defer after.deinit();
    try testing.expectEqual(11, after.value.get("v").?.integer);
    // Under the update time just read, a repeat meets its own write.
    h.server.lose_answers = 1;
    try testing.expectError(error.FailedPrecondition, h.client.doc("c/a").update(&.{}, .{
        .transforms = &.{.{ .field_path = "v", .op = .{ .increment = .{ .integer = 10 } } }},
        .precondition = .{ .update_time = after.value.update_time },
    }));
    try h.expectDiag("an earlier attempt may have landed");
    var once = try h.client.doc("c/a").get(.{});
    defer once.deinit();
    try testing.expectEqual(21, once.value.get("v").?.integer);
}

test "fake: every allocation failure through a full path is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var server: FakeFirestore = .init(testing.allocator);
            defer server.deinit();
            var clock: test_util.FakeClock = .{};
            var token: test_util.FakeTokenProvider = .{};
            var client = try @import("Client.zig").init(gpa, clock.io(), .{
                .project_id = "extractctl",
                .token_provider = token.provider(),
                .transport = server.transport(),
            });
            defer client.deinit();
            const cities = client.collection("cities");
            var made = try cities.create(&.{.{ .name = "m", .value = .{ .map = &.{.{ .name = "a-b", .value = .{ .array = &.{ .{ .integer = 1 }, .{ .string = "x" } } } }} } }}, .{ .document_id = "LA" });
            made.deinit();
            _ = try cities.doc("LA").update(&.{.{ .name = "n", .value = .{ .double = 1.5 } }}, .{ .mask = &.{ "n", "m.`a-b`" } });
            var got = try cities.doc("LA").get(.{ .mask = &.{"n"} });
            got.deinit();
            var page = try cities.list(.{});
            page.deinit();
            var ids = try client.listCollectionIds(.{});
            ids.deinit();
            try cities.doc("LA").delete(.{});
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}

// A model of the store, written once more from the rules, held against
// the fake through the client.

const Model = struct {
    arena: Allocator,
    docs: std.StringArrayHashMapUnmanaged([]const Field) = .empty,
    /// The update time the client last saw for each document.
    times: std.StringArrayHashMapUnmanaged(std.Io.Timestamp) = .empty,

    fn setAt(m: *Model, fields: []const Field, segments: []const []const u8, v: Value) Allocator.Error![]const Field {
        var out: std.ArrayList(Field) = .empty;
        try out.appendSlice(m.arena, fields);
        for (out.items) |*f| if (std.mem.eql(u8, f.name, segments[0])) {
            if (segments.len == 1) {
                f.value = v;
            } else {
                const inner: []const Field = if (f.value == .map) f.value.map else &.{};
                f.value = .{ .map = try m.setAt(inner, segments[1..], v) };
            }
            return out.items;
        };
        try out.append(m.arena, .{ .name = segments[0], .value = if (segments.len == 1) v else .{ .map = try m.setAt(&.{}, segments[1..], v) } });
        return out.items;
    }

    fn deleteAt(m: *Model, fields: []const Field, segments: []const []const u8) Allocator.Error![]const Field {
        var out: std.ArrayList(Field) = .empty;
        for (fields) |f| {
            if (!std.mem.eql(u8, f.name, segments[0])) {
                try out.append(m.arena, f);
            } else if (segments.len > 1) {
                if (f.value == .map) {
                    try out.append(m.arena, .{ .name = f.name, .value = .{ .map = try m.deleteAt(f.value.map, segments[1..]) } });
                } else try out.append(m.arena, f);
            }
        }
        return out.items;
    }

    pub fn valueAt(fields: []const Field, segments: []const []const u8) ?Value {
        const v = types.getField(fields, segments[0]) orelse return null;
        if (segments.len == 1) return v;
        return if (v == .map) valueAt(v.map, segments[1..]) else null;
    }
};

/// The model's own reading of the transforms, from the documentation and
/// what the emulator answered; see "fake: transforms answer as the
/// emulator answered them".
const ModelTransforms = struct {
    fn number(v: ?Value) ?f64 {
        const x = v orelse return null;
        return switch (x) {
            .integer => |i| @floatFromInt(i),
            .double => |d| d,
            else => null,
        };
    }

    fn fromNumeric(n: types.Numeric) Value {
        return switch (n) {
            .integer => |i| .{ .integer = i },
            .double => |d| .{ .double = d },
        };
    }

    fn increment(current: ?Value, n: types.Numeric) Value {
        const operand = fromNumeric(n);
        const c = current orelse return operand;
        if (c == .integer and n == .integer) {
            const sum = @as(i128, c.integer) + n.integer;
            return .{ .integer = @intCast(std.math.clamp(sum, std.math.minInt(i64), std.math.maxInt(i64))) };
        }
        const x = number(c) orelse return operand;
        return .{ .double = x + number(operand).? };
    }

    fn extreme(current: ?Value, n: types.Numeric, maximum: bool) Value {
        const operand = fromNumeric(n);
        const c = current orelse return operand;
        const x = number(c) orelse return operand;
        const y = number(operand).?;
        if (std.math.isNan(x)) return c;
        if (std.math.isNan(y)) return operand;
        const order: std.math.Order = if (c == .integer and n == .integer) std.math.order(c.integer, n.integer) else std.math.order(x, y);
        if (order == .eq) return c;
        return if ((order == .lt) == maximum) operand else c;
    }

    fn same(a: Value, b: Value) bool {
        if (number(a)) |x| {
            const y = number(b) orelse return false;
            if (std.math.isNan(x) or std.math.isNan(y)) return std.math.isNan(x) and std.math.isNan(y);
            if (a == .integer and b == .integer) return a.integer == b.integer;
            return x == y;
        }
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .null => true,
            .boolean => |x| x == b.boolean,
            .string => |x| std.mem.eql(u8, x, b.string),
            .map => |x| x.len == b.map.len and for (x) |f| {
                const other = types.getField(b.map, f.name) orelse break false;
                if (!same(f.value, other)) break false;
            } else true,
            else => false,
        };
    }

    fn arrayOf(current: ?Value) []const Value {
        const c = current orelse return &.{};
        return if (c == .array) c.array else &.{};
    }

    fn appendMissing(a: Allocator, current: ?Value, values: []const Value) Allocator.Error!Value {
        var out: std.ArrayList(Value) = .empty;
        try out.appendSlice(a, arrayOf(current));
        for (values) |v| {
            for (out.items) |e| {
                if (same(e, v)) break;
            } else try out.append(a, v);
        }
        return .{ .array = out.items };
    }

    fn removeAll(a: Allocator, current: ?Value, values: []const Value) Allocator.Error!Value {
        var out: std.ArrayList(Value) = .empty;
        for (arrayOf(current)) |e| {
            for (values) |v| {
                if (same(e, v)) break;
            } else try out.append(a, e);
        }
        return .{ .array = out.items };
    }
};

fn randomNumeric(g: *test_util.ByteGen) types.Numeric {
    return switch (g.intRange(u8, 0, 5)) {
        0 => .{ .integer = g.pick(i64, &.{ 0, 1, 3, -2, std.math.maxInt(i64), std.math.minInt(i64) }) },
        1 => .{ .double = g.pick(f64, &.{ 0.5, 3.0, -1.25, std.math.nan(f64), std.math.inf(f64) }) },
        else => .{ .integer = g.intRange(u8, 0, 4) },
    };
}

/// Values that collide often under Firestore's equality.
fn randomElements(g: *test_util.ByteGen, a: Allocator) Allocator.Error![]const Value {
    const pool = [_]Value{ .null, .{ .integer = 3 }, .{ .double = 3.0 }, .{ .integer = 4 }, .{ .double = std.math.nan(f64) }, .{ .string = "a" }, .{ .boolean = true }, .{ .map = &.{.{ .name = "x", .value = .{ .integer = 1 } }} }, .{ .map = &.{.{ .name = "x", .value = .{ .double = 1.0 } }} } };
    const out = try a.alloc(Value, g.intRange(u8, 0, 3));
    for (out) |*v| v.* = pool[g.intRange(usize, 0, pool.len - 1)];
    return out;
}

/// What the server keeps of a value: microseconds, and 0.0 for -0.0.
fn normalized(a: Allocator, v: Value) Allocator.Error!Value {
    return switch (v) {
        .double => |d| .{ .double = if (d == 0) 0 else d },
        .timestamp => |t| .{ .timestamp = .{ .nanoseconds = @divFloor(t.nanoseconds, 1000) * 1000 } },
        .array => |items| blk: {
            const out = try a.alloc(Value, items.len);
            for (items, out) |item, *o| o.* = try normalized(a, item);
            break :blk .{ .array = out };
        },
        .map => |fields| .{ .map = try normalizedFields(a, fields) },
        else => v,
    };
}

fn normalizedFields(a: Allocator, fields: []const Field) Allocator.Error![]const Field {
    const out = try a.alloc(Field, fields.len);
    for (fields, out) |f, *o| o.* = .{ .name = f.name, .value = try normalized(a, f.value) };
    return out;
}

/// The same fields and values, in any order.
fn expectSameFields(expected: []const Field, actual: []const Field) anyerror!void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected) |e| {
        const got = types.getField(actual, e.name) orelse return error.TestMissingField;
        try expectSameValue(e.value, got);
    }
}

fn expectSameValue(expected: Value, actual: Value) anyerror!void {
    switch (expected) {
        .map => |m| {
            if (actual != .map) return error.TestExpectedEqual;
            try expectSameFields(m, actual.map);
        },
        .array => |items| {
            if (actual != .array) return error.TestExpectedEqual;
            try testing.expectEqual(items.len, actual.array.len);
            for (items, actual.array) |e, g| try expectSameValue(e, g);
        },
        else => try codec.expectValueEqual(expected, actual),
    }
}

const model_paths = [_][]const u8{ "c/a", "c/b", "c/a/s/x", "d/y" };
const names_pool = [_][]const u8{ "k", "a-b", "é", "m" };

fn randomFields(g: *test_util.ByteGen, a: Allocator) Allocator.Error![]const Field {
    const out = try a.alloc(Field, g.intRange(u8, 0, 3));
    for (out, 0..) |*f, i| f.* = .{
        .name = try std.fmt.allocPrint(a, "{s}{d}", .{ g.pick([]const u8, &names_pool), i }),
        .value = try codec.randomValue(g, a, 2, false),
    };
    return out;
}

/// A mask path of one or two names, drawn from the names the writes
/// use: top-level fields `{k,a-b,é,m}{0,1,2}`, and the `k0` to `k2` that
/// random maps hold, so a path often reaches into a map already there.
fn randomMaskPath(g: *test_util.ByteGen, a: Allocator) Allocator.Error![]const []const u8 {
    const first = try std.fmt.allocPrint(a, "{s}{d}", .{ g.pick([]const u8, &names_pool), g.intRange(u8, 0, 2) });
    if (g.boolean()) {
        const one = try a.alloc([]const u8, 1);
        one[0] = first;
        return one;
    }
    const two = try a.alloc([]const u8, 2);
    two[0] = first;
    two[1] = try std.fmt.allocPrint(a, "{s}{d}", .{ g.pick([]const u8, &.{ "k", "a-b" }), g.intRange(u8, 0, 2) });
    return two;
}

fn maskText(a: Allocator, segments: []const []const u8) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(a);
    for (segments, 0..) |s, i| {
        if (i > 0) out.writer.writeByte('.') catch return error.OutOfMemory;
        names.writeFieldSegment(&out.writer, s) catch return error.OutOfMemory;
    }
    return out.written();
}

fn modelProperty(_: void, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var h: test_util.FakeHarness = undefined;
    try h.init(.{});
    defer h.deinit();
    var model: Model = .{ .arena = a };
    var g: test_util.ByteGen = .init(input);

    var steps: usize = 0;
    while (steps < 12 and g.pos < g.bytes.len) : (steps += 1) {
        const path = g.pick([]const u8, &model_paths);
        const doc = h.client.doc(path);
        const existing = model.docs.get(path);
        switch (g.intRange(u8, 0, 7)) {
            0 => { // set, sometimes held to exists == false
                const fields = try randomFields(&g, a);
                const must_be_new = g.intRange(u8, 0, 3) == 0;
                const result = doc.set(fields, .{ .precondition = if (must_be_new) .{ .exists = false } else null });
                if (must_be_new and existing != null) {
                    try testing.expectError(error.AlreadyExists, result);
                } else {
                    const written = try result;
                    try model.docs.put(a, path, try normalizedFields(a, fields));
                    try model.times.put(a, path, written.update_time);
                }
            },
            1 => { // update through a mask: each path given a value, or deleted
                var mask_list: std.ArrayList([]const u8) = .empty;
                var kept: std.ArrayList([]const []const u8) = .empty;
                for (0..g.intRange(u8, 1, 3)) |_| {
                    const segments = try randomMaskPath(&g, a);
                    const text = try maskText(a, segments);
                    for (mask_list.items) |other| {
                        if (names.fieldPathsOverlap(text, other)) break;
                    } else {
                        try mask_list.append(a, text);
                        try kept.append(a, segments);
                    }
                }
                // Values under some of the paths, the rest deletes; built
                // as nested maps, so every value lies under its path.
                var fields: []const Field = &.{};
                for (kept.items) |segments| if (g.intRange(u8, 0, 2) != 0) {
                    fields = try model.setAt(fields, segments, try codec.randomValue(&g, a, 2, false));
                };
                const must_exist = g.boolean();
                const result = doc.update(fields, .{ .mask = mask_list.items, .precondition = if (must_exist) .{ .exists = true } else null });
                if (must_exist and existing == null) {
                    try testing.expectError(error.NotFound, result);
                    continue;
                }
                const written = try result;
                var next: []const Field = existing orelse &.{};
                const body = try normalizedFields(a, fields);
                for (kept.items) |segments| {
                    next = if (Model.valueAt(body, segments)) |v| try model.setAt(next, segments, v) else try model.deleteAt(next, segments);
                }
                try model.docs.put(a, path, next);
                try model.times.put(a, path, written.update_time);
            },
            2 => { // delete, sometimes held to exists == true
                const must_exist = g.boolean();
                const result = doc.delete(.{ .precondition = if (must_exist) .{ .exists = true } else null });
                if (must_exist and existing == null) {
                    try testing.expectError(error.NotFound, result);
                } else {
                    try result;
                    _ = model.docs.orderedRemove(path);
                    _ = model.times.orderedRemove(path);
                }
            },
            3 => { // a write under the update time last seen, or a stale one
                const seen = model.times.get(path) orelse continue;
                const stale = g.boolean();
                const at: std.Io.Timestamp = if (stale) .{ .nanoseconds = seen.nanoseconds - 1000 } else seen;
                const result = doc.set(&.{}, .{ .precondition = .{ .update_time = at } });
                if (stale) {
                    try testing.expectError(error.FailedPrecondition, result);
                } else {
                    const written = try result;
                    try model.docs.put(a, path, &.{});
                    try model.times.put(a, path, written.update_time);
                }
            },
            5 => { // transforms alone, through a commit
                var transforms: std.ArrayList(types.Transform) = .empty;
                var texts: std.ArrayList([]const u8) = .empty;
                var segment_lists: std.ArrayList([]const []const u8) = .empty;
                for (0..g.intRange(u8, 1, 3)) |_| {
                    const segments = try randomMaskPath(&g, a);
                    const text = try maskText(a, segments);
                    // Equal paths may repeat; overlapping ones are refused.
                    for (texts.items) |other| {
                        if (names.fieldPathsOverlap(text, other) and !names.fieldPathsEqual(text, other)) break;
                    } else {
                        try texts.append(a, text);
                        try segment_lists.append(a, segments);
                        try transforms.append(a, .{ .field_path = text, .op = switch (g.intRange(u8, 0, 5)) {
                            0 => .server_time,
                            1 => .{ .increment = randomNumeric(&g) },
                            2 => .{ .maximum = randomNumeric(&g) },
                            3 => .{ .minimum = randomNumeric(&g) },
                            4 => .{ .append_missing = try randomElements(&g, a) },
                            else => .{ .remove_all = try randomElements(&g, a) },
                        } });
                    }
                }
                var result = try h.client.commit(&.{.{ .update = .{ .path = path, .mask = &.{}, .transforms = transforms.items } }}, .{});
                defer result.deinit();
                const answered = result.value.writes[0].transform_results;
                try testing.expectEqual(transforms.items.len, answered.len);
                var next: []const Field = existing orelse &.{};
                for (transforms.items, segment_lists.items, answered) |t, segments, got| {
                    const current = Model.valueAt(next, segments);
                    const value, const expected: Value = switch (t.op) {
                        .server_time => .{ got, got },
                        .increment => |n| .{ ModelTransforms.increment(current, n), ModelTransforms.increment(current, n) },
                        .maximum => |n| .{ ModelTransforms.extreme(current, n, true), ModelTransforms.extreme(current, n, true) },
                        .minimum => |n| .{ ModelTransforms.extreme(current, n, false), ModelTransforms.extreme(current, n, false) },
                        .append_missing => |values| .{ try ModelTransforms.appendMissing(a, current, values), .null },
                        .remove_all => |values| .{ try ModelTransforms.removeAll(a, current, values), .null },
                    };
                    codec.expectValueEqual(expected, got) catch |err| {
                        std.debug.print("{s} {s}: was {any}, expected {any}, got {any}\n", .{ path, t.field_path, current, expected, got });
                        return err;
                    };
                    next = try model.setAt(next, segments, try normalized(a, value));
                }
                try model.docs.put(a, path, next);
                try model.times.put(a, path, result.value.writes[0].update_time.?);
            },
            6 => { // several documents at once, some twice, some missing
                var asked: [4][]const u8 = undefined;
                const n = g.intRange(usize, 1, asked.len);
                for (asked[0..n]) |*p| p.* = g.pick([]const u8, &model_paths);
                var r = try h.client.batchGet(asked[0..n], .{});
                defer r.deinit();
                for (asked[0..n], r.value.documents) |p, d| {
                    if (model.docs.get(p)) |fields| {
                        try expectSameFields(fields, (d orelse return error.TestExpectedDocument).fields);
                    } else try testing.expectEqual(null, d);
                }
            },
            else => { // a read, checked against the model
                if (existing) |fields| {
                    var got = try doc.get(.{});
                    defer got.deinit();
                    try expectSameFields(fields, got.value.fields);
                } else try testing.expectError(error.NotFound, doc.get(.{}));
            },
        }
    }
    // Every document the model holds, and no other.
    try testing.expectEqual(model.docs.count(), h.server.count("(default)"));
    var it = model.docs.iterator();
    while (it.next()) |entry| {
        var got = try h.client.doc(entry.key_ptr.*).get(.{});
        defer got.deinit();
        expectSameFields(entry.value_ptr.*, got.value.fields) catch |err| {
            std.debug.print("{s}: model {any}\nfake {any}\n", .{ entry.key_ptr.*, entry.value_ptr.*, got.value.fields });
            return err;
        };
    }
}

test "fuzz fake: random writes agree with a model of the rules" {
    try test_util.fuzzBytes({}, modelProperty, .{ .corpus = &.{
        "\x00\x00\x02\x05\x01\x00\x01\x01\x04",
        "\x01\x01\x03\x02\x00\x01\x01\x01\x00\x02\x00\x04",
        "\x00\x02\x01\x0a\x03\x01\x01\x02\x00\x03\x00\x01\x02\x01\x04\x03\x00",
    } });
}
