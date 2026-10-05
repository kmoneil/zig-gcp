//! Integration tests against the Firestore emulator, and against
//! production on demand.
//!
//! The emulator: set FIRESTORE_EMULATOR_HOST, such as `127.0.0.1:8087`.
//! Each test works in a project of its own, `zigps-` and 8 random hex
//! digits, which the emulator creates on first use, and empties that
//! project's databases through the emulator's documented endpoint after
//! the test, even when the test fails.
//!
//! Production: leave FIRESTORE_EMULATOR_HOST unset, and set
//! FIRESTORE_TEST_PRODUCTION=1 beside GCP_TEST_PROJECT, GCP_TEST_TOKEN and
//! FIRESTORE_TEST_DATABASE, a named database made for the run and deleted
//! after it, as `tests/firestore_gcp_integration.zig` takes them. Billed
//! (a named database beside another gets no free quota), so never in CI.
//! Each test empties the whole database after itself, documents that
//! exist only as the parent of a subcollection included, so the next one
//! starts from nothing, as on the emulator. Where production answers
//! otherwise, the test says what each side does. A few tests skip there:
//! they need a second database, or measure this library rather than the
//! server. Two queries need composite indexes there, made before the run:
//! `items` by `rank` descending then `__name__`, and `cities` by `state`
//! then `population` (`docs/development.md` has the commands).
//!
//! With neither, every test skips.

const std = @import("std");
const core = @import("core");
const firestore = @import("firestore");
const testing = std.testing;
const Value = firestore.Value;
const Field = firestore.Field;

const Fixture = struct {
    env: std.process.Environ.Map,
    diag: firestore.Diagnostics,
    client: firestore.Client,
    /// On the emulator, "zigps-" and 8 random hex digits, unique per test;
    /// in production, the project named.
    project: []const u8,
    project_buf: [14]u8,
    database: []const u8,
    /// Null in production.
    emulator: ?firestore.Endpoint,
    /// In production, the token every client sends.
    token: core.StaticToken,
    /// Databases besides `(default)` that the test used, to empty too.
    named: ?[]const u8 = null,

    /// Returns false when no server is configured; the test should skip.
    fn init(f: *Fixture) !bool {
        return f.initDatabase(null);
    }

    /// `init` with a database of the test's own naming: on the emulator
    /// only, since production has only the run's.
    fn initNamed(f: *Fixture, database_id: []const u8) !bool {
        return f.initDatabase(database_id);
    }

    fn initDatabase(f: *Fixture, named: ?[]const u8) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        f.diag = .{};
        f.named = null;
        f.emulator = firestore.Endpoint.fromEnv(&f.env);
        if (f.emulator != null) {
            var random: [4]u8 = undefined;
            testing.io.random(&random);
            f.project = try std.fmt.bufPrint(&f.project_buf, "zigps-{x}", .{random});
            f.database = named orelse "(default)";
            f.named = named;
        } else {
            const wanted = f.env.get("FIRESTORE_TEST_PRODUCTION") orelse "";
            const project = f.env.get("GCP_TEST_PROJECT");
            const token = f.env.get("GCP_TEST_TOKEN");
            const database = f.env.get("FIRESTORE_TEST_DATABASE");
            if (!std.mem.eql(u8, wanted, "1") or project == null or token == null or database == null or named != null) {
                f.env.deinit();
                return false;
            }
            if (std.mem.eql(u8, database.?, "(default)")) return error.RefusedDefaultDatabase;
            f.project = project.?;
            f.database = database.?;
            f.token = .{ .token = std.mem.trim(u8, token.?, &std.ascii.whitespace) };
        }
        var with_diag = f.options();
        with_diag.diagnostics = &f.diag;
        f.client = try .init(gpa, testing.io, with_diag);
        return true;
    }

    fn production(f: *const Fixture) bool {
        return f.emulator == null;
    }

    /// What a client of the test's server and database is made with, for
    /// tests that need another.
    fn options(f: *Fixture) firestore.Client.Options {
        return .{
            .project_id = f.project,
            .database_id = f.database,
            .endpoint = f.emulator,
            .token_provider = if (f.emulator == null) f.token.provider() else null,
            .user_agent = "zig-gcp-firestore-integration/0.1",
        };
    }

    fn deinit(f: *Fixture) void {
        if (f.production()) {
            f.wipe();
        } else {
            f.clear("(default)");
            if (f.named) |db| f.clear(db);
        }
        f.client.deinit();
        f.env.deinit();
    }

    /// Empties one database of the test's project on the emulator.
    fn clear(f: *Fixture, database_id: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const url = std.fmt.allocPrint(arena.allocator(), "{s}/emulator/v1/projects/{s}/databases/{s}/documents", .{ f.client.base_url, f.project, database_id }) catch return;
        _ = f.client.transport.send(.{ .method = .DELETE, .url = url, .timeout_ms = 10_000 }, arena.allocator()) catch {};
    }

    /// Deletes every document of the production database.
    fn wipe(f: *Fixture) void {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        f.wipeBelow(arena.allocator(), "") catch |err| std.debug.print("emptying the database failed: {t}\n", .{err});
    }

    fn wipeBelow(f: *Fixture, a: std.mem.Allocator, parent: []const u8) anyerror!void {
        var token: ?[]const u8 = null;
        while (true) {
            var page = if (parent.len == 0)
                try f.client.listCollectionIds(.{ .page_token = token })
            else
                try f.client.doc(parent).listCollectionIds(.{ .page_token = token });
            defer page.deinit();
            for (page.value.collection_ids) |id| {
                const collection = if (parent.len == 0) try a.dupe(u8, id) else try std.fmt.allocPrint(a, "{s}/{s}", .{ parent, id });
                try f.wipeCollection(a, collection);
            }
            token = if (page.value.next_page_token) |t| try a.dupe(u8, t) else break;
        }
    }

    /// Deletes the documents of `collection` and everything below them.
    /// Listed with `showMissing`, which the client does not send, to find
    /// the documents that exist only as parents.
    fn wipeCollection(f: *Fixture, a: std.mem.Allocator, collection: []const u8) anyerror!void {
        var token: ?[]const u8 = null;
        while (true) {
            var url: std.Io.Writer.Allocating = .init(a);
            try url.writer.print("{s}/v1/projects/{s}/databases/{s}/documents", .{ f.client.base_url, f.project, f.database });
            var segments = std.mem.splitScalar(u8, collection, '/');
            while (segments.next()) |segment| {
                try url.writer.writeByte('/');
                try core.query.writeSegment(&url.writer, segment);
            }
            var params: core.query.Params = .init(&url.writer);
            try params.add("showMissing", "true");
            try params.add("mask.fieldPaths", "__name__");
            try params.add("pageSize", "300");
            if (token) |t| try params.add("pageToken", t);
            const reply = try f.client.transport.send(.{ .method = .GET, .url = url.written(), .bearer = f.token.token, .timeout_ms = 30_000 }, a);
            if (reply.status != 200) {
                std.debug.print("listing {s} answered {d}: {s}\n", .{ collection, reply.status, reply.body });
                return error.WipeFailed;
            }
            const Page = struct {
                documents: []const struct { name: []const u8 } = &.{},
                nextPageToken: ?[]const u8 = null,
            };
            const page = try std.json.parseFromSliceLeaky(Page, a, reply.body, .{ .ignore_unknown_fields = true });
            for (page.documents) |d| {
                const marker = "/documents/";
                const at = std.mem.indexOf(u8, d.name, marker) orelse return error.WipeFailed;
                const path = d.name[at + marker.len ..];
                try f.wipeBelow(a, path);
                try f.client.doc(path).delete(.{});
            }
            token = page.nextPageToken orelse break;
        }
    }

    fn doc(f: *Fixture, path: []const u8) firestore.Document {
        return f.client.doc(path);
    }
};

fn expectDiag(f: *const Fixture, part: []const u8) !void {
    if (std.mem.indexOf(u8, f.diag.message(), part) == null) {
        std.debug.print("diagnostics: {s}\n", .{f.diag.message()});
        return error.TestUnexpectedDiagnostics;
    }
}

/// Equality as the wire sees it: NaN equals NaN.
fn expectValueEqual(expected: Value, actual: Value) !void {
    try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .null => {},
        .boolean => |b| try testing.expectEqual(b, actual.boolean),
        .integer => |i| try testing.expectEqual(i, actual.integer),
        .double => |d| if (std.math.isNan(d)) try testing.expect(std.math.isNan(actual.double)) else try testing.expectEqual(d, actual.double),
        .timestamp => |t| try testing.expectEqual(t.nanoseconds, actual.timestamp.nanoseconds),
        .string => |s| try testing.expectEqualStrings(s, actual.string),
        .bytes => |b| try testing.expectEqualSlices(u8, b, actual.bytes),
        .reference => |r| try testing.expectEqualStrings(r, actual.reference),
        .geo_point => |g| {
            try testing.expectEqual(g.latitude, actual.geo_point.latitude);
            try testing.expectEqual(g.longitude, actual.geo_point.longitude);
        },
        .array => |items| {
            try testing.expectEqual(items.len, actual.array.len);
            for (items, actual.array) |e, a| try expectValueEqual(e, a);
        },
        .map => |fields| {
            try testing.expectEqual(fields.len, actual.map.len);
            for (fields) |e| try expectValueEqual(e.value, firestore.getField(actual.map, e.name) orelse return error.TestMissingField);
        },
    }
}

test "values: every kind goes in and comes back" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();

    const ts_ns: i96 = 1_791_153_779_123_456_789;
    const fields: []const Field = &.{
        .{ .name = "null", .value = .null },
        .{ .name = "false", .value = .{ .boolean = false } },
        .{ .name = "true", .value = .{ .boolean = true } },
        .{ .name = "zero", .value = .{ .integer = 0 } },
        .{ .name = "max", .value = .{ .integer = std.math.maxInt(i64) } },
        .{ .name = "min", .value = .{ .integer = std.math.minInt(i64) } },
        .{ .name = "pi", .value = .{ .double = 3.141592653589793 } },
        .{ .name = "three", .value = .{ .double = 3 } },
        .{ .name = "tiny", .value = .{ .double = 5e-324 } },
        .{ .name = "huge", .value = .{ .double = 1.7976931348623157e308 } },
        .{ .name = "nan", .value = .{ .double = std.math.nan(f64) } },
        .{ .name = "inf", .value = .{ .double = std.math.inf(f64) } },
        .{ .name = "-inf", .value = .{ .double = -std.math.inf(f64) } },
        .{ .name = "ts", .value = .{ .timestamp = .{ .nanoseconds = ts_ns } } },
        .{ .name = "epoch", .value = .{ .timestamp = .{ .nanoseconds = 0 } } },
        .{ .name = "first", .value = .{ .timestamp = core.timestamp.min } },
        .{ .name = "string", .value = .{ .string = "é\"\\\n\x00 ünïcödé 🔥" } },
        .{ .name = "empty", .value = .{ .string = "" } },
        .{ .name = "bytes", .value = .{ .bytes = "\x00\xff\xfe\x80" } },
        .{ .name = "ref", .value = .{ .reference = "projects/p/databases/(default)/documents/c/x" } },
        .{ .name = "geo", .value = .{ .geo_point = .{ .latitude = 0, .longitude = -118.25 } } },
        .{ .name = "array", .value = .{ .array = &.{ .{ .integer = 1 }, .{ .string = "two" }, .{ .map = &.{.{ .name = "in", .value = .{ .array = &.{} } }} } } } },
        .{ .name = "emptyarray", .value = .{ .array = &.{} } },
        .{ .name = "emptymap", .value = .{ .map = &.{} } },
        .{ .name = "a-b.c`d\\é", .value = .{ .map = &.{.{ .name = "x y", .value = .{ .boolean = true } }} } },
    };
    _ = try f.doc("values/all").set(fields, .{});
    var got = try f.doc("values/all").get(.{});
    defer got.deinit();
    try testing.expectEqual(fields.len, got.value.fields.len);
    for (fields) |field| {
        const back = got.value.get(field.name) orelse {
            std.debug.print("missing field {s}\n", .{field.name});
            return error.TestMissingField;
        };
        var expected = field.value;
        // Measured: the server keeps microseconds, and drops the rest.
        if (std.mem.eql(u8, field.name, "ts")) expected = .{ .timestamp = .{ .nanoseconds = ts_ns - 789 } };
        expectValueEqual(expected, back) catch |err| {
            std.debug.print("field {s}: sent {any}, got {any}\n", .{ field.name, field.value, back });
            return err;
        };
    }
}

test "values: what the emulator changes on the way" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    _ = try f.doc("values/neg").set(&.{.{ .name = "z", .value = .{ .double = -0.0 } }}, .{});
    var got = try f.doc("values/neg").get(.{});
    defer got.deinit();
    // The emulator answers -0.0 as 0.0; equal either way as numbers.
    try testing.expectEqual(@as(f64, 0), got.value.get("z").?.double);
}

test "values: the server's own limits, past the client's checks" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    // A 1,500-byte name is the limit, and the emulator takes it.
    const long = core.testing.repeat("k", 1500);
    _ = try f.doc("limits/name").set(&.{.{ .name = long, .value = .null }}, .{});
    // But a mask of the same 1,500 bytes is one past what the server takes,
    // which the client now refuses itself.
    try testing.expectError(error.InvalidResourceId, f.doc("limits/name").update(&.{.{ .name = long, .value = .{ .integer = 1 } }}, .{}));
    try expectDiag(&f, "longer than 1500 bytes");
    // A reference to a collection: refused by the client already.
    try testing.expectError(error.InvalidArgument, f.doc("limits/ref").set(&.{.{ .name = "r", .value = .{ .reference = "projects/p/databases/(default)/documents/c" } }}, .{}));
}

test "documents: create, read, write, update, delete" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const cities = f.client.collection("cities");

    var la = try cities.create(&.{
        .{ .name = "name", .value = .{ .string = "Los Angeles" } },
        .{ .name = "population", .value = .{ .integer = 3_900_000 } },
    }, .{ .document_id = "LA" });
    defer la.deinit();
    try testing.expectEqualStrings("LA", la.value.id());
    try testing.expectEqual(la.value.create_time.nanoseconds, la.value.update_time.nanoseconds);

    // A second create of the same id.
    try testing.expectError(error.AlreadyExists, cities.create(&.{}, .{ .document_id = "LA" }));

    // An id of the library's own choosing.
    var auto = try cities.create(&.{.{ .name = "name", .value = .{ .string = "Somewhere" } }}, .{});
    defer auto.deinit();
    try testing.expectEqual(20, auto.value.id().len);
    var auto_read = try cities.doc(auto.value.id()).get(.{});
    defer auto_read.deinit();
    try testing.expectEqualStrings("Somewhere", auto_read.value.get("name").?.string);

    // update under the update time just read, then again under the stale one.
    const doc = cities.doc("LA");
    const updated = try doc.update(&.{.{ .name = "population", .value = .{ .integer = 4_000_000 } }}, .{
        .precondition = .{ .update_time = la.value.update_time },
    });
    try testing.expect(updated.update_time.nanoseconds > la.value.update_time.nanoseconds);
    try testing.expectError(error.FailedPrecondition, doc.update(&.{.{ .name = "population", .value = .{ .integer = 1 } }}, .{
        .precondition = .{ .update_time = la.value.update_time },
    }));
    try expectDiag(&f, "does not match the required base version");
    try expectDiag(&f, "an earlier attempt may have landed");

    var after = try doc.get(.{});
    defer after.deinit();
    try testing.expectEqual(4_000_000, after.value.get("population").?.integer);
    try testing.expectEqualStrings("Los Angeles", after.value.get("name").?.string);
    try testing.expectEqual(updated.update_time.nanoseconds, after.value.update_time.nanoseconds);

    // set replaces the whole document.
    _ = try doc.set(&.{.{ .name = "only", .value = .{ .boolean = true } }}, .{});
    var replaced = try doc.get(.{});
    defer replaced.deinit();
    try testing.expectEqual(1, replaced.value.fields.len);

    // update needs the document; set with exists == false refuses one.
    try testing.expectError(error.NotFound, cities.doc("SF").update(&.{.{ .name = "x", .value = .null }}, .{}));
    try testing.expectError(error.AlreadyExists, doc.set(&.{}, .{ .precondition = .{ .exists = false } }));
    // Without a precondition, update writes a missing document.
    _ = try cities.doc("SF").update(&.{.{ .name = "x", .value = .null }}, .{ .precondition = null });

    // delete, then the missing document.
    try doc.delete(.{ .precondition = .{ .exists = true } });
    try testing.expectError(error.NotFound, doc.get(.{}));
    try expectDiag(&f, "not found");
    try doc.delete(.{});
    try testing.expectError(error.NotFound, doc.delete(.{ .precondition = .{ .exists = true } }));
}

test "documents: masks delete, reach into maps, and read back part of a document" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const doc = f.doc("masks/m");
    _ = try doc.set(&.{
        .{ .name = "address", .value = .{ .map = &.{
            .{ .name = "city", .value = .{ .string = "LA" } },
            .{ .name = "zip", .value = .{ .string = "90001" } },
        } } },
        .{ .name = "nickname", .value = .{ .string = "City of Angels" } },
        .{ .name = "a-b", .value = .{ .map = &.{.{ .name = "c`d", .value = .{ .integer = 1 } }} } },
    }, .{});

    // address.city changes, zip stays, nickname goes, a-b.c`d changes.
    _ = try doc.update(&.{
        .{ .name = "address", .value = .{ .map = &.{.{ .name = "city", .value = .{ .string = "Los Angeles" } }} } },
        .{ .name = "a-b", .value = .{ .map = &.{.{ .name = "c`d", .value = .{ .integer = 2 } }} } },
    }, .{ .mask = &.{ "address.city", "nickname", "`a-b`.`c\\`d`" } });
    var got = try doc.get(.{});
    defer got.deinit();
    try testing.expectEqualStrings("Los Angeles", got.value.get("address").?.get("city").?.string);
    try testing.expectEqualStrings("90001", got.value.get("address").?.get("zip").?.string);
    try testing.expectEqual(null, got.value.get("nickname"));
    try testing.expectEqual(2, got.value.get("a-b").?.get("c`d").?.integer);

    // Deleting the last field of a map leaves the map, empty.
    _ = try doc.update(&.{}, .{ .mask = &.{"`a-b`.`c\\`d`"} });
    var emptied = try doc.get(.{});
    defer emptied.deinit();
    try testing.expectEqual(0, emptied.value.get("a-b").?.map.len);

    // A read mask returns part of the document; __name__ alone none of it.
    var part = try doc.get(.{ .mask = &.{ "address.zip", "missing" } });
    defer part.deinit();
    try testing.expectEqual(1, part.value.fields.len);
    try testing.expectEqual(1, part.value.get("address").?.map.len);
    try testing.expectEqualStrings("90001", part.value.get("address").?.get("zip").?.string);
    var bare = try doc.get(.{ .mask = &.{"__name__"} });
    defer bare.deinit();
    try testing.expectEqual(0, bare.value.fields.len);
}

test "documents: ids that need encoding, subcollections, and odd names" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const odd = [_][]const u8{ "a b%c+d", "a:b", "été", "x?y#z", "[brackets]", "back\\slash", "dots.in.id", "...", "~tilde" };
    for (odd) |id| {
        _ = try f.client.collection("odd").doc(id).set(&.{.{ .name = "id", .value = .{ .string = id } }}, .{});
        var got = f.client.collection("odd").doc(id).get(.{}) catch |err| {
            std.debug.print("id {s}: {t}\n", .{ id, err });
            return err;
        };
        defer got.deinit();
        try testing.expectEqualStrings(id, got.value.id());
        try testing.expectEqualStrings(id, got.value.get("id").?.string);
    }

    // A subcollection below a document that does not exist.
    const tower = f.client.doc("cities/LA").collection("landmarks").doc("tower");
    _ = try tower.set(&.{}, .{});
    var t = try tower.get(.{});
    defer t.deinit();
    try testing.expectEqualStrings("cities/LA/landmarks/tower", t.value.path());
    try testing.expectError(error.NotFound, f.doc("cities/LA").get(.{}));
}

test "listing: documents by page and order, collection ids at each level" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const items = f.client.collection("items");
    for (0..7) |i| {
        var id_buf: [8]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "i{d}", .{i});
        _ = try items.doc(id).set(&.{.{ .name = "rank", .value = .{ .integer = @intCast(10 - i) } }}, .{});
    }
    _ = try f.doc("items/i0/sub/s").set(&.{}, .{});
    _ = try f.doc("other/o/deep/d").set(&.{}, .{});

    // Pages of three, by name, until the token runs out.
    var seen: usize = 0;
    var token_buf: [512]u8 = undefined;
    var token: ?[]const u8 = null;
    var pages: usize = 0;
    while (true) {
        var page = try items.list(.{ .page_size = 3, .page_token = token });
        defer page.deinit();
        pages += 1;
        for (page.value.documents, 0..) |d, i| {
            var want: [8]u8 = undefined;
            try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "i{d}", .{seen + i}), d.id());
        }
        seen += page.value.documents.len;
        const next = page.value.next_page_token orelse break;
        @memcpy(token_buf[0..next.len], next);
        token = token_buf[0..next.len];
    }
    try testing.expectEqual(7, seen);
    try testing.expect(pages >= 3);

    // Ordered by a field, descending, keys only.
    var ranked = try items.list(.{ .order_by = &.{ .{ .field = "rank", .direction = .descending }, .{ .field = "__name__" } }, .mask = &.{"__name__"} });
    defer ranked.deinit();
    try testing.expectEqual(7, ranked.value.documents.len);
    try testing.expectEqualStrings("i0", ranked.value.documents[0].id());
    try testing.expectEqual(0, ranked.value.documents[0].fields.len);

    // An empty collection is an empty page.
    var none = try f.client.collection("nothing").list(.{});
    defer none.deinit();
    try testing.expectEqual(0, none.value.documents.len);

    // Collection ids: at the root, and below documents, existing or not.
    var root = try f.client.listCollectionIds(.{});
    defer root.deinit();
    try testing.expectEqual(2, root.value.collection_ids.len);
    try testing.expectEqualStrings("items", root.value.collection_ids[0]);
    try testing.expectEqualStrings("other", root.value.collection_ids[1]);
    var one = try f.client.listCollectionIds(.{ .page_size = 1 });
    defer one.deinit();
    try testing.expectEqual(1, one.value.collection_ids.len);
    try testing.expect(one.value.next_page_token != null);
    var sub = try f.doc("items/i0").listCollectionIds(.{});
    defer sub.deinit();
    try testing.expectEqualStrings("sub", sub.value.collection_ids[0]);
    var deep = try f.doc("other/o").listCollectionIds(.{});
    defer deep.deinit();
    try testing.expectEqualStrings("deep", deep.value.collection_ids[0]);
    var empty = try f.doc("items/i1").listCollectionIds(.{});
    defer empty.deinit();
    try testing.expectEqual(0, empty.value.collection_ids.len);
}

test "named databases: separate from (default), no routing header needed" {
    var f: Fixture = undefined;
    if (!try f.initNamed("zigps-named")) return error.SkipZigTest;
    defer f.deinit();
    _ = try f.doc("c/x").set(&.{.{ .name = "where", .value = .{ .string = "named" } }}, .{});
    var got = try f.doc("c/x").get(.{});
    defer got.deinit();
    try testing.expect(std.mem.indexOf(u8, got.value.name, "/databases/zigps-named/") != null);

    // The same path in (default) is another document.
    var default: firestore.Client = try .init(testing.allocator, testing.io, .{
        .project_id = f.project,
        .endpoint = f.emulator,
    });
    defer default.deinit();
    try testing.expectError(error.NotFound, default.doc("c/x").get(.{}));
}

test "references: a full name built by the client goes in and comes back" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const name = try f.client.documentName(testing.allocator, "cities/LA");
    defer testing.allocator.free(name);
    _ = try f.doc("refs/r").set(&.{.{ .name = "city", .value = .{ .reference = name } }}, .{});
    var got = try f.doc("refs/r").get(.{});
    defer got.deinit();
    try testing.expectEqualStrings(name, got.value.get("city").?.reference);
}

test "transforms: each kind, and what the emulator answers for it" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const nan = std.math.nan(f64);
    const cases = [_]struct { ?Value, firestore.Transform.Op, Value }{
        .{ .{ .integer = 5 }, .{ .increment = .{ .integer = 1 } }, .{ .integer = 6 } },
        .{ .{ .integer = std.math.maxInt(i64) }, .{ .increment = .{ .integer = 1 } }, .{ .integer = std.math.maxInt(i64) } },
        .{ .{ .integer = 5 }, .{ .increment = .{ .double = 0.5 } }, .{ .double = 5.5 } },
        .{ null, .{ .increment = .{ .integer = 3 } }, .{ .integer = 3 } },
        .{ .{ .string = "a" }, .{ .increment = .{ .integer = 2 } }, .{ .integer = 2 } },
        .{ .{ .integer = 3 }, .{ .maximum = .{ .double = 3.0 } }, .{ .integer = 3 } },
        .{ .{ .integer = 5 }, .{ .maximum = .{ .double = 7.5 } }, .{ .double = 7.5 } },
        .{ .{ .double = 1.5 }, .{ .minimum = .{ .integer = 1 } }, .{ .integer = 1 } },
        .{ .{ .integer = 0 }, .{ .maximum = .{ .double = nan } }, .{ .double = nan } },
    };
    for (cases, 0..) |case, i| {
        var id_buf: [8]u8 = undefined;
        const path = try std.fmt.bufPrint(&id_buf, "t/{d}", .{i});
        if (case[0]) |v| _ = try f.doc(path).set(&.{.{ .name = "x", .value = v }}, .{});
        var r = try f.client.commit(&.{.{ .update = .{ .path = path, .mask = &.{}, .transforms = &.{.{ .field_path = "x", .op = case[1] }}, .precondition = .{ .exists = case[0] != null } } }}, .{});
        defer r.deinit();
        expectValueEqual(case[2], r.value.writes[0].transform_results[0]) catch |err| {
            std.debug.print("case {d}: got {any}\n", .{ i, r.value.writes[0].transform_results[0] });
            return err;
        };
    }

    // Array transforms, and server time in several fields of one commit.
    _ = try f.doc("t/arr").set(&.{.{ .name = "a", .value = .{ .array = &.{ .{ .integer = 3 }, .{ .double = nan }, .null } } }}, .{});
    var r = try f.client.commit(&.{.{ .update = .{ .path = "t/arr", .mask = &.{}, .transforms = &.{
        .{ .field_path = "a", .op = .{ .append_missing = &.{ .{ .double = 3.0 }, .{ .integer = 4 }, .{ .integer = 4 } } } },
        .{ .field_path = "a", .op = .{ .remove_all = &.{.{ .double = nan }} } },
        .{ .field_path = "at", .op = .server_time },
        .{ .field_path = "nested.at", .op = .server_time },
    } } }}, .{});
    defer r.deinit();
    const results = r.value.writes[0].transform_results;
    try testing.expectEqual(Value.null, results[0]);
    try testing.expectEqual(results[2].timestamp, results[3].timestamp);
    try testing.expectEqual(0, @mod(results[2].timestamp.nanoseconds, std.time.ns_per_ms));
    var got = try f.doc("t/arr").get(.{});
    defer got.deinit();
    try expectValueEqual(.{ .array = &.{ .{ .integer = 3 }, .null, .{ .integer = 4 } } }, got.value.get("a").?);
    try testing.expectEqual(results[2].timestamp, got.value.get("nested").?.get("at").?.timestamp);

    // Through Document.update: transforms beside fields, the rest kept.
    _ = try f.doc("t/arr").update(&.{.{ .name = "label", .value = .{ .string = "x" } }}, .{ .transforms = &.{.{ .field_path = "count", .op = .{ .increment = .{ .integer = 2 } } }} });
    var updated = try f.doc("t/arr").get(.{});
    defer updated.deinit();
    try testing.expectEqual(2, updated.value.get("count").?.integer);
    try testing.expectEqualStrings("x", updated.value.get("label").?.string);
    try testing.expect(updated.value.get("a") != null);
}

test "commit: several writes land together or not at all" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    _ = try f.doc("c/exists").set(&.{}, .{});
    // The third write's precondition fails, so neither of the first two lands.
    try testing.expectError(error.NotFound, f.client.commit(&.{
        .{ .update = .{ .path = "c/new", .fields = &.{.{ .name = "v", .value = .{ .integer = 1 } }} } },
        .{ .delete = .{ .path = "c/exists" } },
        .{ .update = .{ .path = "c/missing", .fields = &.{}, .precondition = .{ .exists = true } } },
    }, .{}));
    try testing.expectError(error.NotFound, f.doc("c/new").get(.{}));
    var still = try f.doc("c/exists").get(.{});
    still.deinit();

    // Measured: a precondition sees the commit's earlier writes. Deleted by
    // the first write, the document does not exist for the second.
    var recreated = try f.client.commit(&.{
        .{ .delete = .{ .path = "c/exists" } },
        .{ .update = .{ .path = "c/exists", .fields = &.{.{ .name = "again", .value = .{ .boolean = true } }}, .precondition = .{ .exists = false } } },
    }, .{});
    recreated.deinit();
    var again = try f.doc("c/exists").get(.{});
    defer again.deinit();
    try testing.expect(again.value.get("again").?.boolean);

    // A document written twice in one commit, each write seeing the last.
    var r = try f.client.commit(&.{
        .{ .update = .{ .path = "c/twice", .fields = &.{.{ .name = "a", .value = .{ .integer = 1 } }} } },
        .{ .update = .{ .path = "c/twice", .fields = &.{.{ .name = "b", .value = .{ .integer = 2 } }}, .mask = &.{"b"} } },
        .{ .delete = .{ .path = "c/exists", .precondition = .{ .exists = true } } },
    }, .{});
    defer r.deinit();
    try testing.expectEqual(3, r.value.writes.len);
    try testing.expectEqual(r.value.commit_time, r.value.writes[0].update_time.?);
    try testing.expectEqual(null, r.value.writes[2].update_time);
    var twice = try f.doc("c/twice").get(.{});
    defer twice.deinit();
    try testing.expectEqual(2, twice.value.fields.len);
    try testing.expectError(error.NotFound, f.doc("c/exists").get(.{}));
}

test "batchGet: in the order asked, duplicates and missing included" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    _ = try f.doc("c/b").set(&.{ .{ .name = "v", .value = .{ .integer = 2 } }, .{ .name = "w", .value = .null } }, .{});
    _ = try f.doc("c/a").set(&.{.{ .name = "v", .value = .{ .integer = 1 } }}, .{});
    _ = try f.doc("c/a b%c").set(&.{.{ .name = "v", .value = .{ .integer = 3 } }}, .{});
    var r = try f.client.batchGet(&.{ "c/b", "c/none", "c/a", "c/b", "c/a b%c" }, .{ .mask = &.{"v"} });
    defer r.deinit();
    const docs = r.value.documents;
    try testing.expectEqual(5, docs.len);
    try testing.expectEqual(2, docs[0].?.get("v").?.integer);
    try testing.expectEqual(1, docs[0].?.fields.len);
    try testing.expectEqual(null, docs[1]);
    try testing.expectEqual(1, docs[2].?.get("v").?.integer);
    try testing.expectEqual(2, docs[3].?.get("v").?.integer);
    try testing.expectEqual(3, docs[4].?.get("v").?.integer);
    try testing.expect(r.value.read_time != null);
}

test "reads at a past time: get and batchGet see the document as it was" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const first = try f.doc("c/x").set(&.{.{ .name = "v", .value = .{ .integer = 1 } }}, .{});
    _ = try f.doc("c/x").set(&.{.{ .name = "v", .value = .{ .integer = 2 } }}, .{});
    var then = try f.doc("c/x").get(.{ .read_time = first.update_time });
    defer then.deinit();
    try testing.expectEqual(1, then.value.get("v").?.integer);
    var now = try f.doc("c/x").get(.{});
    defer now.deinit();
    try testing.expectEqual(2, now.value.get("v").?.integer);
    // Before the document existed: NotFound from get, null from batchGet.
    const before: std.Io.Timestamp = .{ .nanoseconds = first.update_time.nanoseconds - std.time.ns_per_us };
    try testing.expectError(error.NotFound, f.doc("c/x").get(.{ .read_time = before }));
    try expectDiag(&f, "did not exist at the read time");
    var batch = try f.client.batchGet(&.{"c/x"}, .{ .read_time = before });
    defer batch.deinit();
    try testing.expectEqual(null, batch.value.documents[0]);
}

fn putCities(f: *Fixture) !void {
    const cities = [_]struct { []const u8, []const u8, i64, ?f64, []const Value }{
        .{ "LA", "CA", 3_900_000, 34.05, &.{ .{ .string = "west" }, .{ .string = "coast" } } },
        .{ "SF", "CA", 870_000, null, &.{ .{ .string = "west" }, .{ .string = "coast" }, .{ .string = "tech" } } },
        .{ "NY", "NY", 8_300_000, 40.71, &.{ .{ .string = "east" }, .{ .string = "coast" } } },
        .{ "CHI", "IL", 2_700_000, std.math.nan(f64), &.{.{ .string = "midwest" }} },
        .{ "AUS", "TX", 960_000, 30.27, &.{ .{ .string = "south" }, .{ .string = "tech" } } },
    };
    for (cities) |c| {
        var path_buf: [16]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "cities/{s}", .{c[0]});
        _ = try f.doc(path).set(&.{
            .{ .name = "state", .value = .{ .string = c[1] } },
            .{ .name = "population", .value = .{ .integer = c[2] } },
            .{ .name = "lat", .value = if (c[3]) |lat| .{ .double = lat } else .null },
            .{ .name = "tags", .value = .{ .array = c[4] } },
        }, .{});
    }
}

fn expectQueryIds(f: *Fixture, query: firestore.Query, expected: []const []const u8) !void {
    var r = try f.client.runQuery(query, .{});
    defer r.deinit();
    var same = r.value.documents.len == expected.len;
    if (same) for (r.value.documents, expected) |d, e| {
        if (!std.mem.eql(u8, d.id(), e)) same = false;
    };
    if (!same) {
        std.debug.print("expected", .{});
        for (expected) |e| std.debug.print(" {s}", .{e});
        std.debug.print("\ngot", .{});
        for (r.value.documents) |d| std.debug.print(" {s}", .{d.id()});
        std.debug.print("\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "queries: filters, orders, cursors, offsets and limits" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    try putCities(&f);
    const cities: firestore.Query.From = .{ .collection = "cities" };
    try expectQueryIds(&f, .{ .from = cities, .where = &.{.{ .field = "state", .op = .equal, .value = .{ .string = "CA" } }} }, &.{ "LA", "SF" });
    try expectQueryIds(&f, .{ .from = cities, .where = &.{.{ .field = "population", .op = .greater_than, .value = .{ .integer = 1_000_000 } }} }, &.{ "CHI", "LA", "NY" });
    try expectQueryIds(&f, .{ .from = cities, .order_by = &.{.{ .field = "population", .direction = .descending }}, .limit = 2 }, &.{ "NY", "LA" });
    try expectQueryIds(&f, .{ .from = cities, .order_by = &.{.{ .field = "population" }}, .offset = 1, .limit = 2 }, &.{ "AUS", "CHI" });
    try expectQueryIds(&f, .{ .from = cities, .where = &.{.{ .field = "tags", .op = .array_contains, .value = .{ .string = "tech" } }} }, &.{ "AUS", "SF" });
    try expectQueryIds(&f, .{ .from = cities, .where = &.{.{ .field = "tags", .op = .array_contains_any, .value = .{ .array = &.{ .{ .string = "east" }, .{ .string = "south" } } } }} }, &.{ "AUS", "NY" });
    try expectQueryIds(&f, .{ .from = cities, .where = &.{.{ .field = "state", .op = .in, .value = .{ .array = &.{ .{ .string = "NY" }, .{ .string = "TX" } } } }} }, &.{ "AUS", "NY" });
    try expectQueryIds(&f, .{ .from = cities, .where = &.{.{ .field = "state", .op = .not_in, .value = .{ .array = &.{.{ .string = "CA" }} } }} }, &.{ "CHI", "NY", "AUS" });
    try expectQueryIds(&f, .{
        .from = cities,
        .filter = .{
            .any = &.{
                .{ .condition = .{ .field = "state", .op = .equal, .value = .{ .string = "TX" } } },
                .{ .all = &.{
                    .{ .condition = .{ .field = "state", .op = .equal, .value = .{ .string = "CA" } } },
                    .{ .condition = .{ .field = "population", .op = .less_than, .value = .{ .integer = 1_000_000 } } },
                } },
                // The inequality in one branch orders every result by population.
            },
        },
    }, &.{ "SF", "AUS" });
    // Cursors, both ends, both ways.
    const by_pop: []const firestore.Order = &.{.{ .field = "population" }};
    try expectQueryIds(&f, .{ .from = cities, .order_by = by_pop, .start_at = .{ .values = &.{.{ .integer = 960_000 }} } }, &.{ "AUS", "CHI", "LA", "NY" });
    try expectQueryIds(&f, .{ .from = cities, .order_by = by_pop, .start_at = .{ .values = &.{.{ .integer = 960_000 }}, .inclusive = false } }, &.{ "CHI", "LA", "NY" });
    try expectQueryIds(&f, .{ .from = cities, .order_by = by_pop, .end_at = .{ .values = &.{.{ .integer = 2_700_000 }} } }, &.{ "SF", "AUS", "CHI" });
    try expectQueryIds(&f, .{ .from = cities, .order_by = by_pop, .end_at = .{ .values = &.{.{ .integer = 2_700_000 }}, .inclusive = false } }, &.{ "SF", "AUS" });
    // A select returns only the fields named.
    var picked = try f.client.runQuery(.{ .from = cities, .select = &.{"state"}, .where = &.{.{ .field = "state", .op = .equal, .value = .{ .string = "NY" } }} }, .{});
    defer picked.deinit();
    try testing.expectEqual(1, picked.value.documents[0].fields.len);
    try testing.expectEqualStrings("NY", picked.value.documents[0].get("state").?.string);
}

test "queries: equality with null and NaN finds them, sent as the server's own tests" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    try putCities(&f);
    const cities: firestore.Query.From = .{ .collection = "cities" };
    // As field filters these match nothing; the library sends them unary.
    try expectQueryIds(&f, .{ .from = cities, .where = &.{.{ .field = "lat", .op = .equal, .value = .null }} }, &.{"SF"});
    try expectQueryIds(&f, .{ .from = cities, .where = &.{.{ .field = "lat", .op = .equal, .value = .{ .double = std.math.nan(f64) } }} }, &.{"CHI"});
    try expectQueryIds(&f, .{ .from = cities, .where = &.{.{ .field = "lat", .op = .not_equal, .value = .null }} }, &.{ "CHI", "AUS", "LA", "NY" });
    try expectQueryIds(&f, .{ .from = cities, .where = &.{.{ .field = "lat", .op = .is_not_nan }} }, &.{ "AUS", "LA", "NY" });
    // The ones that would match nothing are refused before sending.
    try testing.expectError(error.InvalidArgument, f.client.runQuery(.{ .from = cities, .where = &.{.{ .field = "lat", .op = .less_than, .value = .null }} }, .{}));
}

test "queries: collection groups below a parent, and the document name" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    for ([_][]const u8{ "cities/LA/landmarks/tower", "cities/LA/landmarks/park", "cities/NY/landmarks/bridge", "landmarks/moon", "cities/LA/other/landmarks" }) |path| {
        _ = try f.doc(path).set(&.{.{ .name = "path", .value = .{ .string = path } }}, .{});
    }
    try expectQueryIds(&f, .{ .from = .{ .group = "landmarks" } }, &.{ "park", "tower", "bridge", "moon" });
    try expectQueryIds(&f, .{ .from = .{ .group = "landmarks" }, .parent = "cities/LA" }, &.{ "park", "tower" });
    try expectQueryIds(&f, .{ .from = .{ .collection = "landmarks" }, .parent = "cities/NY" }, &.{"bridge"});
    const tower = try f.client.documentName(testing.allocator, "cities/LA/landmarks/tower");
    defer testing.allocator.free(tower);
    try expectQueryIds(&f, .{ .from = .{ .group = "landmarks" }, .where = &.{.{ .field = "__name__", .op = .equal, .value = .{ .reference = tower } }} }, &.{"tower"});
    // Names order segment by segment: landmarks/moon after every cities/...
    try expectQueryIds(&f, .{ .from = .{ .group = "landmarks" }, .order_by = &.{.{ .field = "__name__" }}, .start_at = .{ .values = &.{.{ .reference = tower }}, .inclusive = false } }, &.{ "bridge", "moon" });
}

/// Counts what passes through to `child`: the bytes held now, and the most
/// held at once. Atomic: a streamed read with a time limit runs on another
/// task.
const Peak = struct {
    child: std.mem.Allocator,
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *Peak) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn grew(self: *Peak, by: usize) void {
        const now = self.live.fetchAdd(by, .monotonic) + by;
        _ = self.peak.fetchMax(now, .monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Peak = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.grew(len);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Peak = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) self.grew(new_len - memory.len) else _ = self.live.fetchSub(memory.len - new_len, .monotonic);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Peak = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len > memory.len) self.grew(new_len - memory.len) else _ = self.live.fetchSub(memory.len - new_len, .monotonic);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Peak = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        _ = self.live.fetchSub(memory.len, .monotonic);
    }
};

/// Counts the documents and string bytes it is handed, keeping none.
const Tally = struct {
    documents: u64 = 0,
    bytes: u64 = 0,

    fn handler(t: *Tally) firestore.DocumentHandler {
        return .{ .ptr = t, .vtable = &.{ .document = document } };
    }

    fn document(ptr: *anyopaque, snapshot: firestore.Owned(firestore.Snapshot)) anyerror!void {
        const t: *Tally = @ptrCast(@alignCast(ptr));
        var s = snapshot;
        defer s.deinit();
        t.documents += 1;
        t.bytes += (s.value.get("s") orelse return error.TestExpectedField).string.len;
    }
};

test "streaming: a 200 MB answer, read one document at a time in bounded memory" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    // This measures the library; production's streaming was measured on
    // its own, and 200 MB of egress is billed.
    if (f.production()) return error.SkipZigTest;
    const big = try testing.allocator.alloc(u8, 1_000_000);
    defer testing.allocator.free(big);
    var path_buf: [16]u8 = undefined;
    for (0..200) |i| {
        // Each document its own string, so nothing in the answer repeats.
        @memset(big, 'a' + @as(u8, @intCast(i % 26)));
        _ = try f.doc(try std.fmt.bufPrint(&path_buf, "big/d{d:0>3}", .{i})).set(&.{.{ .name = "s", .value = .{ .string = big } }}, .{});
    }
    const all: firestore.Query = .{ .from = .{ .collection = "big" } };
    // Whole, it is over the transport's response limit.
    try testing.expectError(error.ResponseTooLarge, f.client.runQuery(all, .{}));

    var peak: Peak = .{ .child = testing.allocator };
    var client: firestore.Client = try .init(peak.allocator(), testing.io, f.options());
    defer client.deinit();
    var tally: Tally = .{};
    const end = try client.runQueryEach(all, .{}, tally.handler());
    try testing.expectEqual(200, end.documents);
    try testing.expectEqual(200, tally.documents);
    try testing.expectEqual(200_000_000, tally.bytes);
    // About one document's worth at a time: its JSON, its parse, and the
    // transport's buffers.
    const held = peak.peak.load(.monotonic);
    if (held > 8 << 20) {
        std.debug.print("peak {d} bytes\n", .{held});
        return error.TestUnexpectedResult;
    }
}

test "aggregations: count, sum and average, and the documents they see" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    try putCities(&f);
    _ = try f.doc("cities/NOWHERE").set(&.{.{ .name = "state", .value = .{ .string = "??" } }}, .{});
    const cities: firestore.Query = .{ .from = .{ .collection = "cities" } };
    var count = try f.client.runAggregationQuery(cities, &.{ .{ .count = .{} }, .{ .count = .{ .up_to = 2 } } }, .{});
    defer count.deinit();
    try testing.expectEqual(6, count.value.values[0].integer);
    try testing.expectEqual(2, count.value.values[1].integer);
    // Measured on the emulator: with a sum among them, the count sees only
    // the documents that have the summed field.
    var sums = try f.client.runAggregationQuery(cities, &.{ .{ .sum = "population" }, .{ .avg = "population" }, .{ .count = .{} } }, .{});
    defer sums.deinit();
    try testing.expectEqual(16_730_000, sums.value.values[0].integer);
    try testing.expectEqual(3_346_000.0, sums.value.values[1].double);
    try testing.expectEqual(5, sums.value.values[2].integer);
    var west = try f.client.runAggregationQuery(.{ .from = .{ .collection = "cities" }, .where = &.{.{ .field = "state", .op = .equal, .value = .{ .string = "CA" } }} }, &.{.{ .count = .{} }}, .{});
    defer west.deinit();
    try testing.expectEqual(2, west.value.values[0].integer);
    var nothing = try f.client.runAggregationQuery(.{ .from = .{ .collection = "none" } }, &.{ .{ .sum = "x" }, .{ .avg = "x" } }, .{});
    defer nothing.deinit();
    try testing.expectEqual(0, nothing.value.values[0].integer);
    try testing.expectEqual(Value.null, nothing.value.values[1]);
}

test "queries at a past time see the documents as they were" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const first = try f.doc("c/a").set(&.{.{ .name = "v", .value = .{ .integer = 1 } }}, .{});
    _ = try f.doc("c/b").set(&.{.{ .name = "v", .value = .{ .integer = 2 } }}, .{});
    _ = try f.doc("c/a").set(&.{.{ .name = "v", .value = .{ .integer = 3 } }}, .{});
    var then = try f.client.runQuery(.{ .from = .{ .collection = "c" } }, .{ .read_time = first.update_time });
    defer then.deinit();
    try testing.expectEqual(1, then.value.documents.len);
    try testing.expectEqual(1, then.value.documents[0].get("v").?.integer);
    try testing.expectEqual(first.update_time, then.value.read_time);
    var sum_then = try f.client.runAggregationQuery(.{ .from = .{ .collection = "c" } }, &.{.{ .sum = "v" }}, .{ .read_time = first.update_time });
    defer sum_then.deinit();
    try testing.expectEqual(1, sum_then.value.values[0].integer);
}

/// Adds one to `counters/c`'s `n` in a transaction, `times` times over.
const Incrementer = struct {
    client: firestore.Client,
    runs: u32 = 0,

    fn run(ptr: *anyopaque, txn: *firestore.Transaction) anyerror!void {
        const self: *Incrementer = @ptrCast(@alignCast(ptr));
        self.runs += 1;
        var got = try txn.get("counters/c", .{});
        defer got.deinit();
        try txn.update("counters/c", &.{.{ .name = "n", .value = .{ .integer = got.value.get("n").?.integer + 1 } }}, .{});
    }

    fn handler(self: *Incrementer) firestore.TransactionHandler {
        return .{ .ptr = self, .vtable = &.{ .run = run } };
    }

    fn loop(self: *Incrementer, times: u32) anyerror!void {
        for (0..times) |_| try self.client.runTransaction(self.handler(), .{ .max_attempts = 20 });
    }
};

test "transactions: concurrent increments never lose one" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    _ = try f.doc("counters/c").set(&.{.{ .name = "n", .value = .{ .integer = 0 } }}, .{});
    // Three tasks, each with a client of its own, contend for one counter.
    var workers: [3]Incrementer = undefined;
    var quick = f.options();
    quick.retry = .{ .initial_backoff_ms = 20, .max_backoff_ms = 200 };
    for (&workers) |*w| w.* = .{ .client = try .init(testing.allocator, testing.io, quick) };
    defer for (&workers) |*w| w.client.deinit();
    const times = 4;
    var futures: [3]std.Io.Future(anyerror!void) = undefined;
    for (&workers, &futures) |*w, *fut| fut.* = try testing.io.concurrent(Incrementer.loop, .{ w, times });
    var failure: ?anyerror = null;
    for (&futures) |*fut| fut.await(testing.io) catch |err| {
        failure = err;
    };
    if (failure) |err| return err;
    var got = try f.doc("counters/c").get(.{});
    defer got.deinit();
    try testing.expectEqual(3 * times, got.value.get("n").?.integer);
    var runs: u32 = 0;
    for (workers) |w| runs += w.runs;
    // Every increment landed once, however many runs it took.
    try testing.expect(runs >= 3 * times);
}

test "transactions: reads see what was there when read, and a rollback lets go" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    _ = try f.doc("c/a").set(&.{.{ .name = "v", .value = .{ .integer = 1 } }}, .{});
    var t = try f.client.beginTransaction(.read_write);
    defer t.deinit();
    var read = try f.client.batchGet(&.{ "c/a", "c/none" }, .{ .transaction = t.value });
    defer read.deinit();
    try testing.expectEqual(1, read.value.documents[0].?.get("v").?.integer);
    try testing.expectEqual(null, read.value.documents[1]);
    // Rolled back, its lock on c/a is gone: a plain write goes through at once.
    try f.client.rollback(t.value);
    _ = try f.doc("c/a").set(&.{.{ .name = "v", .value = .{ .integer = 2 } }}, .{});
    // And the transaction is over.
    try testing.expectError(error.Aborted, f.client.commit(&.{.{ .delete = .{ .path = "c/a" } }}, .{ .transaction = t.value }));
    try expectDiag(&f, "no longer valid");
    try testing.expectError(error.InvalidArgument, f.client.rollback("Zm9vYmFy"));
}

/// Reads `c/a` in a read-only transaction, and keeps what it saw.
const Reader = struct {
    seen: i64 = 0,
    fn run(ptr: *anyopaque, txn: *firestore.Transaction) anyerror!void {
        const self: *Reader = @ptrCast(@alignCast(ptr));
        var q = try txn.runQuery(.{ .from = .{ .collection = "c" } });
        defer q.deinit();
        self.seen = q.value.documents[0].get("v").?.integer;
    }
};

test "transactions: read-only, now and at a past time; a write in one is refused" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const first = try f.doc("c/a").set(&.{.{ .name = "v", .value = .{ .integer = 1 } }}, .{});
    _ = try f.doc("c/a").set(&.{.{ .name = "v", .value = .{ .integer = 2 } }}, .{});
    var reader: Reader = .{};
    const h: firestore.TransactionHandler = .{ .ptr = &reader, .vtable = &.{ .run = Reader.run } };
    try f.client.runTransaction(h, .{ .read_only = true });
    try testing.expectEqual(2, reader.seen);
    try f.client.runTransaction(h, .{ .read_only = true, .read_time = first.update_time });
    try testing.expectEqual(1, reader.seen);
    var ro = try f.client.beginTransaction(.{ .read_only = .{} });
    defer ro.deinit();
    try testing.expectError(error.InvalidArgument, f.client.commit(&.{.{ .delete = .{ .path = "c/a" } }}, .{ .transaction = ro.value }));
    try expectDiag(&f, "Cannot modify entities in a read-only transaction.");
}
