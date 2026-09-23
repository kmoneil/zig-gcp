//! Compose: one object written from up to 32 others in the same bucket,
//! server-side, with no bytes moving. It is how an append works, since the
//! destination may be one of its own sources, and what a parallel
//! composite upload is finished with.
//!
//! The rules Cloud Storage states, which section 4 of the spec collects:
//! - 1 to 32 sources a call. Larger joins are repeated composes, which is
//!   allowed: a composite may itself be a source, and `componentCount` is
//!   a 32-bit field.
//! - Every source is in the destination's bucket, and all of them share a
//!   storage class.
//! - A composite has no MD5. It has a CRC32C, which Cloud Storage derives
//!   from its components', so `download` verifies one as it verifies
//!   anything else.
//! - Nothing is inherited: the composite's metadata is what this call
//!   sends, and an unset content type becomes the default.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Stringify = std.json.Stringify;
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Error = @import("errors.zig").Error;

/// The most sources one call may read: "You can compose between 1 and 32
/// source objects."
pub const max_sources = 32;

/// Writes `object` from `sources`. The caller has begun the call and
/// checked the destination's names.
pub fn compose(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    sources: []const types.ComposeSource,
    options: types.ComposeOptions,
) Error!types.Owned(types.ObjectInfo) {
    try check(client.diagnostics, sources, options);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.composePath(scratch.allocator(), bucket, object, options.preconditions);
    const body = try encode(scratch.allocator(), sources, options);

    var result: types.Owned(types.ObjectInfo) = try .init(client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(client, result.arena, .{
        .method = .POST,
        .path = path,
        .body = body,
        // A repeat of a compose that deletes its sources finds them gone
        // and fails for a reason that has nothing to do with the first
        // attempt, so that one needs a precondition whatever the client's
        // default says.
        .retry = options.preconditions.makesWriteSafe() or
            (client.retry_unconditional_writes and !options.delete_sources),
    });
    result.value = codec.decodeObject(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(client, err, "object");
    return result;
}

/// Refuses what Cloud Storage would, and what it would accept but almost
/// nobody means, and says why in `diag`.
pub fn check(
    diag: ?*core.Diagnostics,
    sources: []const types.ComposeSource,
    options: types.ComposeOptions,
) error{InvalidComposeSources}!void {
    if (sources.len == 0 or sources.len > max_sources) {
        if (diag) |d| d.print("a compose reads 1 to {d} sources, not {d}", .{ max_sources, sources.len });
        return error.InvalidComposeSources;
    }
    for (sources, 0..) |source, i| {
        if (!validate.isObjectName(source.name)) {
            if (diag) |d| d.print("source {d} is not an object name: 1 to {d} bytes of UTF-8, no carriage return or line feed", .{ i, validate.max_object_name_len });
            return error.InvalidComposeSources;
        }
        if (source.generation) |generation| if (source.if_generation_match) |wanted| {
            if (generation != wanted) {
                if (diag) |d| d.print("source {d} names generation {d} and requires {d}; both cannot hold", .{ i, generation, wanted });
                return error.InvalidComposeSources;
            }
        };
        for (sources[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.name, source.name) and earlier.generation == source.generation) {
                if (diag) |d| d.print("source {d} repeats {s} at the same generation; Cloud Storage would concatenate it twice, which is rarely what a loop meant", .{ i, source.name });
                return error.InvalidComposeSources;
            }
        }
    }
    // The destination's custom metadata becomes one JSON object, so a
    // repeated key is a body with two entries of one name, which Cloud
    // Storage resolves as it pleases. A property found this one.
    if (validate.metadataFault(options.metadata)) |fault| {
        if (diag) |d| {
            if (fault.repeated) {
                d.print("destination metadata key {s} appears twice; one object gives a key one value", .{options.metadata[fault.index].key});
            } else {
                d.print("destination metadata {d} has no key", .{fault.index});
            }
        }
        return error.InvalidComposeSources;
    }
}

/// The `objects.compose` body.
pub fn encode(
    arena: Allocator,
    sources: []const types.ComposeSource,
    options: types.ComposeOptions,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    write(&jw, sources, options) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn write(
    jw: *Stringify,
    sources: []const types.ComposeSource,
    options: types.ComposeOptions,
) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("sourceObjects");
    try jw.beginArray();
    for (sources) |source| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(source.name);
        if (source.generation) |generation| {
            try jw.objectField("generation");
            try jw.write(generation);
        }
        if (source.if_generation_match) |wanted| {
            try jw.objectField("objectPreconditions");
            try jw.beginObject();
            try jw.objectField("ifGenerationMatch");
            try jw.write(wanted);
            try jw.endObject();
        }
        try jw.endObject();
    }
    try jw.endArray();
    try jw.objectField("destination");
    try jw.beginObject();
    try jw.objectField("contentType");
    try jw.write(options.content_type);
    if (options.cache_control) |value| {
        try jw.objectField("cacheControl");
        try jw.write(value);
    }
    if (options.content_encoding) |value| {
        try jw.objectField("contentEncoding");
        try jw.write(value);
    }
    if (options.metadata.len > 0) {
        try jw.objectField("metadata");
        try jw.beginObject();
        for (options.metadata) |entry| {
            try jw.objectField(entry.key);
            try jw.write(entry.value);
        }
        try jw.endObject();
    }
    try jw.endObject();
    if (options.delete_sources) {
        try jw.objectField("deleteSourceObjects");
        try jw.write(true);
    }
    try jw.endObject();
}

const testing = std.testing;
const test_util = @import("test_util.zig");

const composite_json =
    \\{"name":"joined","bucket":"b","generation":"9","metageneration":"1",
    \\ "size":"300","contentType":"text/plain","crc32c":"8P9ykg==","componentCount":3}
;

/// The sources and options beside the body they must produce, written out
/// by hand from the rules in the module comment.
const Golden = struct {
    label: []const u8,
    sources: []const types.ComposeSource,
    options: types.ComposeOptions = .{},
    body: []const u8,
};

const goldens = [_]Golden{
    .{
        .label = "one source, and the default content type nothing inherits",
        .sources = &.{.{ .name = "part-1" }},
        .body = "{\"sourceObjects\":[{\"name\":\"part-1\"}]," ++
            "\"destination\":{\"contentType\":\"application/octet-stream\"}}",
    },
    .{
        .label = "three sources keep the order they were given",
        .sources = &.{ .{ .name = "c" }, .{ .name = "a" }, .{ .name = "b" } },
        .options = .{ .content_type = "text/plain" },
        .body = "{\"sourceObjects\":[{\"name\":\"c\"},{\"name\":\"a\"},{\"name\":\"b\"}]," ++
            "\"destination\":{\"contentType\":\"text/plain\"}}",
    },
    .{
        .label = "a pinned generation, and a precondition of its own",
        .sources = &.{
            .{ .name = "part-1", .generation = 7 },
            .{ .name = "part-2", .if_generation_match = 4 },
        },
        .body = "{\"sourceObjects\":[{\"name\":\"part-1\",\"generation\":7}," ++
            "{\"name\":\"part-2\",\"objectPreconditions\":{\"ifGenerationMatch\":4}}]," ++
            "\"destination\":{\"contentType\":\"application/octet-stream\"}}",
    },
    .{
        .label = "the destination's own metadata",
        .sources = &.{.{ .name = "p" }},
        .options = .{
            .content_type = "application/json",
            .cache_control = "no-store",
            .content_encoding = "gzip",
            .metadata = &.{.{ .key = "origin", .value = "zig" }},
        },
        .body = "{\"sourceObjects\":[{\"name\":\"p\"}],\"destination\":{" ++
            "\"contentType\":\"application/json\",\"cacheControl\":\"no-store\"," ++
            "\"contentEncoding\":\"gzip\",\"metadata\":{\"origin\":\"zig\"}}}",
    },
    .{
        .label = "deleteSourceObjects appears only when asked",
        .sources = &.{.{ .name = "p" }},
        .options = .{ .delete_sources = true },
        .body = "{\"sourceObjects\":[{\"name\":\"p\"}]," ++
            "\"destination\":{\"contentType\":\"application/octet-stream\"}," ++
            "\"deleteSourceObjects\":true}",
    },
    .{
        .label = "the destination may be its own first source, which is an append",
        .sources = &.{ .{ .name = "log" }, .{ .name = "tail" } },
        .body = "{\"sourceObjects\":[{\"name\":\"log\"},{\"name\":\"tail\"}]," ++
            "\"destination\":{\"contentType\":\"application/octet-stream\"}}",
    },
};

test "golden: the compose body, written from the rules by hand" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    for (goldens) |golden| {
        errdefer std.debug.print("golden: {s}\n", .{golden.label});
        try testing.expectEqualStrings(
            golden.body,
            try encode(arena_state.allocator(), golden.sources, golden.options),
        );
    }
}

test "composeFrom: the request, and the composite it answers with" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = composite_json } }}, .{});
    defer h.deinit();
    var info = try h.client.bucket("b").object("dir/joined").composeFrom(&.{
        .{ .name = "part-1" },
        .{ .name = "part-2" },
        .{ .name = "part-3" },
    }, .{ .content_type = "text/plain" });
    defer info.deinit();
    try h.expectRequest(
        0,
        .POST,
        "https://storage.googleapis.com/storage/v1/b/b/o/dir%2Fjoined/compose",
        "{\"sourceObjects\":[{\"name\":\"part-1\"},{\"name\":\"part-2\"},{\"name\":\"part-3\"}]," ++
            "\"destination\":{\"contentType\":\"text/plain\"}}",
    );
    // A composite reports how many objects it is made of, and no md5.
    try testing.expectEqual(3, info.value.component_count.?);
    try testing.expectEqual(null, info.value.md5);
    try testing.expectEqual(0xf0ff7292, info.value.crc32c.?);
}

test "composeFrom: preconditions reach the query, and there is no generation" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = composite_json } }}, .{});
    defer h.deinit();
    var info = try h.client.bucket("b").object("joined").composeFrom(
        &.{.{ .name = "p" }},
        .{ .preconditions = .{ .if_generation_match = 0, .if_metageneration_match = 2 } },
    );
    defer info.deinit();
    const sent = try h.fake.request(0);
    try testing.expectEqualStrings(
        "https://storage.googleapis.com/storage/v1/b/b/o/joined/compose?ifGenerationMatch=0&ifMetagenerationMatch=2",
        sent.url,
    );
}

test "composeFrom: 1 to 32 sources, and what is refused outside that" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = composite_json } }}, .{});
    defer h.deinit();
    const obj = h.client.bucket("b").object("joined");
    try testing.expectError(error.InvalidComposeSources, obj.composeFrom(&.{}, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "1 to 32 sources") != null);

    var many: [max_sources + 1]types.ComposeSource = undefined;
    var buffer: [max_sources + 1][8]u8 = undefined;
    for (&many, &buffer, 0..) |*source, *name, i| {
        source.* = .{ .name = std.fmt.bufPrint(name, "p{d}", .{i}) catch unreachable };
    }
    try testing.expectError(error.InvalidComposeSources, obj.composeFrom(&many, .{}));
    // Exactly 32 is allowed.
    var info = try obj.composeFrom(many[0..max_sources], .{});
    info.deinit();
    try h.expectRequestCount(1);
}

test "check: names, repeats, and a generation that fights its precondition" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const obj = h.client.bucket("b").object("joined");
    try testing.expectError(error.InvalidComposeSources, obj.composeFrom(&.{.{ .name = "" }}, .{}));
    try testing.expectError(error.InvalidComposeSources, obj.composeFrom(&.{.{ .name = "a\nb" }}, .{}));
    // The same name at the same generation twice is legal and almost never meant.
    try testing.expectError(error.InvalidComposeSources, obj.composeFrom(&.{
        .{ .name = "p" },
        .{ .name = "p" },
    }, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "repeats p") != null);
    // At different generations it is deliberate, so it stands.
    try testing.expectError(error.InvalidComposeSources, obj.composeFrom(&.{
        .{ .name = "p", .generation = 1, .if_generation_match = 2 },
    }, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "both cannot hold") != null);
    try h.expectRequestCount(0);
}

test "composeFrom: the same name at two generations is deliberate, and allowed" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = composite_json } }}, .{});
    defer h.deinit();
    var info = try h.client.bucket("b").object("joined").composeFrom(&.{
        .{ .name = "p", .generation = 1 },
        .{ .name = "p", .generation = 2 },
    }, .{});
    defer info.deinit();
    try h.expectRequestCount(1);
}

test "composeFrom: deleting the sources is never retried unconditionally" {
    // A plain compose is retried once the client opts in.
    var plain: test_util.Harness = undefined;
    try plain.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .body = composite_json } },
    }, .{ .retry_unconditional_writes = true });
    defer plain.deinit();
    var info = try plain.client.bucket("b").object("joined").composeFrom(&.{.{ .name = "p" }}, .{});
    defer info.deinit();
    try plain.expectRequestCount(2);

    // One that deletes its sources is not: the repeat would find them gone.
    var deleting: test_util.Harness = undefined;
    try deleting.init(&.{.{ .respond = .{ .status = 503, .body = "{}" } }}, .{
        .retry_unconditional_writes = true,
    });
    defer deleting.deinit();
    try testing.expectError(error.Unavailable, deleting.client.bucket("b").object("joined").composeFrom(
        &.{.{ .name = "p" }},
        .{ .delete_sources = true },
    ));
    try deleting.expectRequestCount(1);

    // Under a precondition it is safe either way.
    var conditional: test_util.Harness = undefined;
    try conditional.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .body = composite_json } },
    }, .{});
    defer conditional.deinit();
    var safe = try conditional.client.bucket("b").object("joined").composeFrom(
        &.{.{ .name = "p" }},
        .{ .delete_sources = true, .preconditions = .{ .if_generation_match = 0 } },
    );
    defer safe.deinit();
    try conditional.expectRequestCount(2);
}

test "composeFrom: names are checked like every other call" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidBucketName, h.client.bucket("has space").object("a").composeFrom(&.{.{ .name = "p" }}, .{}));
    try testing.expectError(error.InvalidObjectName, h.client.bucket("b").object("a\nb").composeFrom(&.{.{ .name = "p" }}, .{}));
    try h.expectRequestCount(0);
}

fn composeEverything(gpa: Allocator) !void {
    var fake: test_util.FakeTransport = .init(gpa, &.{.{ .respond = .{ .body = composite_json } }});
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var token: test_util.FakeTokenProvider = .{ .token = "ya29.test-token" };
    var client: Client = try .init(gpa, clock.io(), .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    var info = try client.bucket("b").object("joined").composeFrom(&.{
        .{ .name = "p1", .generation = 3 },
        .{ .name = "p2", .if_generation_match = 4 },
    }, .{
        .content_type = "text/plain",
        .metadata = &.{.{ .key = "k", .value = "v" }},
        .delete_sources = true,
    });
    info.deinit();
}

test "composeFrom: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, composeEverything, .{});
}

// Properties. Each states a rule of the module comment independently of
// the code above, and holds it to arbitrary input.

const Drawn = struct {
    sources: []const types.ComposeSource,
    options: types.ComposeOptions,
};

fn drawCompose(arena: Allocator, g: *test_util.ByteGen) !Drawn {
    var buffer: [128]u8 = undefined;
    const sources = try arena.alloc(types.ComposeSource, g.intRange(usize, 0, max_sources + 2));
    for (sources) |*source| {
        const generation: ?u64 = if (g.intRange(u8, 0, 2) == 0) null else g.int(u16);
        source.* = .{
            .name = try arena.dupe(u8, g.utf8(&buffer, 24)),
            .generation = generation,
            // Usually agreeing with the generation, sometimes not, so the
            // contradiction rule is exercised from both sides.
            .if_generation_match = switch (g.intRange(u8, 0, 3)) {
                0 => null,
                1 => generation,
                else => g.int(u16),
            },
        };
    }
    const entries = try arena.alloc(types.Metadata, g.intRange(usize, 0, 3));
    for (entries) |*entry| entry.* = .{
        .key = try arena.dupe(u8, g.utf8(&buffer, 12)),
        .value = try arena.dupe(u8, g.utf8(&buffer, 16)),
    };
    return .{
        .sources = sources,
        .options = .{
            .content_type = g.pick([]const u8, &.{ "text/plain", "application/octet-stream", "image/png" }),
            .cache_control = if (g.intRange(u8, 0, 1) == 0) null else "no-store",
            .content_encoding = if (g.intRange(u8, 0, 1) == 0) null else "gzip",
            .metadata = entries,
            .delete_sources = g.intRange(u8, 0, 1) == 0,
        },
    };
}

fn bodyProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    const d = try drawCompose(arena, &g);
    check(null, d.sources, d.options) catch return;
    const body = try encode(arena, d.sources, d.options);

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    // The sources, in the order they were given, with what each carried.
    const listed = (root.get("sourceObjects") orelse return error.TestNoSources).array.items;
    try testing.expectEqual(d.sources.len, listed.len);
    for (d.sources, listed) |source, value| {
        const entry = value.object;
        try testing.expectEqualStrings(source.name, entry.get("name").?.string);
        if (source.generation) |generation| {
            try testing.expectEqual(generation, @as(u64, @intCast(entry.get("generation").?.integer)));
        } else {
            try testing.expectEqual(null, entry.get("generation"));
        }
        if (source.if_generation_match) |wanted| {
            const pre = (entry.get("objectPreconditions") orelse return error.TestNoPrecondition).object;
            try testing.expectEqual(wanted, @as(u64, @intCast(pre.get("ifGenerationMatch").?.integer)));
        } else {
            try testing.expectEqual(null, entry.get("objectPreconditions"));
        }
    }
    // The destination carries the options and nothing else.
    const destination = (root.get("destination") orelse return error.TestNoDestination).object;
    try testing.expectEqualStrings(d.options.content_type, destination.get("contentType").?.string);
    try testing.expectEqual(d.options.cache_control != null, destination.get("cacheControl") != null);
    try testing.expectEqual(d.options.content_encoding != null, destination.get("contentEncoding") != null);
    try testing.expectEqual(d.options.metadata.len > 0, destination.get("metadata") != null);
    // deleteSourceObjects appears only when asked, and is never false.
    if (d.options.delete_sources) {
        try testing.expectEqual(true, root.get("deleteSourceObjects").?.bool);
    } else {
        try testing.expectEqual(null, root.get("deleteSourceObjects"));
    }
    try testing.expectEqual(@as(usize, if (d.options.delete_sources) 3 else 2), root.count());
}

test "fuzz compose: the body's sources are the sources, in order" {
    try test_util.fuzzBytes({}, bodyProperty, .{ .corpus = &.{
        "",
        "\x01",
        "\x03\x00\x00\x00\x00\x00\x00",
    } });
}

/// Section 6's rules, stated again.
fn allowedByRules(sources: []const types.ComposeSource, options: types.ComposeOptions) bool {
    if (validate.metadataFault(options.metadata) != null) return false;
    if (sources.len == 0 or sources.len > max_sources) return false;
    for (sources, 0..) |source, i| {
        if (!validate.isObjectName(source.name)) return false;
        if (source.generation) |generation| if (source.if_generation_match) |wanted| {
            if (generation != wanted) return false;
        };
        for (sources[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.name, source.name) and earlier.generation == source.generation) return false;
        }
    }
    return true;
}

fn checkProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    const d = try drawCompose(arena, &g);
    try testing.expectEqual(
        allowedByRules(d.sources, d.options),
        check(null, d.sources, d.options) != error.InvalidComposeSources,
    );
}

test "fuzz compose: check accepts exactly what the rules allow" {
    try test_util.fuzzBytes({}, checkProperty, .{ .corpus = &.{
        "",
        "\x00",
        "\x02\x00\x00\x00\x00\x00\x00\x00\x00",
    } });
}

/// The body written a second time, from the module comment's rules, with
/// none of the code above.
fn modelBody(arena: Allocator, d: Drawn) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"sourceObjects\":[");
    for (d.sources, 0..) |source, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, "{\"name\":");
        try modelString(arena, &out, source.name);
        if (source.generation) |generation| try out.print(arena, ",\"generation\":{d}", .{generation});
        if (source.if_generation_match) |wanted| {
            try out.print(arena, ",\"objectPreconditions\":{{\"ifGenerationMatch\":{d}}}", .{wanted});
        }
        try out.append(arena, '}');
    }
    try out.appendSlice(arena, "],\"destination\":{\"contentType\":");
    try modelString(arena, &out, d.options.content_type);
    if (d.options.cache_control) |value| {
        try out.appendSlice(arena, ",\"cacheControl\":");
        try modelString(arena, &out, value);
    }
    if (d.options.content_encoding) |value| {
        try out.appendSlice(arena, ",\"contentEncoding\":");
        try modelString(arena, &out, value);
    }
    if (d.options.metadata.len > 0) {
        try out.appendSlice(arena, ",\"metadata\":{");
        for (d.options.metadata, 0..) |entry, i| {
            if (i > 0) try out.append(arena, ',');
            try modelString(arena, &out, entry.key);
            try out.append(arena, ':');
            try modelString(arena, &out, entry.value);
        }
        try out.append(arena, '}');
    }
    try out.append(arena, '}');
    if (d.options.delete_sources) try out.appendSlice(arena, ",\"deleteSourceObjects\":true");
    try out.append(arena, '}');
    return out.items;
}

fn modelString(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(arena, '"');
    for (text) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        0x08 => try out.appendSlice(arena, "\\b"),
        0x09 => try out.appendSlice(arena, "\\t"),
        0x0a => try out.appendSlice(arena, "\\n"),
        0x0c => try out.appendSlice(arena, "\\f"),
        0x0d => try out.appendSlice(arena, "\\r"),
        0x00...0x07, 0x0b, 0x0e...0x1f => try out.print(arena, "\\u{x:0>4}", .{c}),
        else => try out.append(arena, c),
    };
    try out.append(arena, '"');
}

fn modelProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    const d = try drawCompose(arena, &g);
    check(null, d.sources, d.options) catch return;
    try testing.expectEqualStrings(try modelBody(arena, d), try encode(arena, d.sources, d.options));
}

test "slow property compose: the body matches a model written from the rules" {
    try test_util.fuzzBytes({}, modelProperty, .{ .random_runs = 300, .max_len = 512 });
}

test "check: the destination's custom metadata keys, which a property found" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const obj = h.client.bucket("b").object("joined");
    try testing.expectError(error.InvalidComposeSources, obj.composeFrom(&.{.{ .name = "p" }}, .{
        .metadata = &.{ .{ .key = "k", .value = "1" }, .{ .key = "k", .value = "2" } },
    }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "appears twice") != null);
    try testing.expectError(error.InvalidComposeSources, obj.composeFrom(&.{.{ .name = "p" }}, .{
        .metadata = &.{.{ .key = "", .value = "1" }},
    }));
    try h.expectRequestCount(0);
}
