//! Metadata updates: the JSON API's `patch`, which changes what an object
//! says about itself and leaves its bytes, and its generation, alone.
//!
//! A patch merges. Every field left out of the body keeps the value it
//! had, so the caller states what changes rather than what the object
//! should become. Custom metadata merges one level deeper, where Cloud
//! Storage reads three different requests:
//!
//! - `{"metadata":{"k":"v"}}` sets `k` and leaves the other entries.
//! - `{"metadata":{"k":null}}` removes `k` and leaves the other entries.
//! - `{"metadata":null}` removes every entry.
//!
//! A JSON object has one `metadata` value, so the third cannot be combined
//! with either of the others. `types.MetadataEdit` makes that
//! unrepresentable instead of refusing it at runtime.

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

/// Patches `object`'s metadata. The caller has begun the call and checked
/// both names.
pub fn update(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    options: types.MetadataUpdate,
) Error!types.Owned(types.ObjectInfo) {
    try check(client.diagnostics, options);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.objectPath(
        scratch.allocator(),
        bucket,
        object,
        options.generation,
        options.preconditions,
    );
    const body = try encode(scratch.allocator(), options);

    var result: types.Owned(types.ObjectInfo) = try .init(client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(client, result.arena, .{
        .method = .PATCH,
        .path = path,
        .body = body,
        // A patch that succeeded and lost its response has already moved
        // the metageneration, so repeating it under that condition fails
        // rather than applying twice.
        .retry = options.preconditions.makesMetadataWriteSafe() or client.retry_unconditional_writes,
    });
    result.value = codec.decodeObject(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(client, err, "object");
    return result;
}

/// Refuses what Cloud Storage could not store, or could store only
/// ambiguously, and says why in `diag`. Values never reach it: custom
/// metadata can hold anything the caller put there.
pub fn check(
    diag: ?*core.Diagnostics,
    options: types.MetadataUpdate,
) error{InvalidMetadataUpdate}!void {
    const fixed = [_]struct { name: []const u8, value: ?[]const u8 }{
        .{ .name = "content_type", .value = options.content_type },
        .{ .name = "cache_control", .value = options.cache_control },
        .{ .name = "content_disposition", .value = options.content_disposition },
        .{ .name = "content_encoding", .value = options.content_encoding },
        .{ .name = "content_language", .value = options.content_language },
    };
    for (fixed) |field| {
        const value = field.value orelse continue;
        // The empty string clears the field; anything else becomes a
        // response header, so it is what a header value may hold.
        if (value.len != 0 and !isHeaderText(value)) {
            if (diag) |d| d.print("{s}: a value is printable ASCII and spaces, since it comes back as a header", .{field.name});
            return error.InvalidMetadataUpdate;
        }
    }
    const changes = switch (options.edit) {
        .keep, .clear => return,
        .change => |list| list,
    };
    for (changes, 0..) |change, i| {
        if (change.key.len == 0) {
            if (diag) |d| d.print("metadata change {d} has no key", .{i});
            return error.InvalidMetadataUpdate;
        }
        if (!isHeaderText(change.key)) {
            if (diag) |d| d.print("metadata change {d}: a key is printable ASCII and spaces", .{i});
            return error.InvalidMetadataUpdate;
        }
        if (change.value) |value| if (!isHeaderText(value)) {
            if (diag) |d| d.print("metadata key {s}: a value is printable ASCII and spaces, since it comes back as a header", .{change.key});
            return error.InvalidMetadataUpdate;
        };
        for (changes[0..i]) |earlier| if (std.mem.eql(u8, earlier.key, change.key)) {
            if (diag) |d| d.print("metadata key {s} appears twice; one patch gives a key one fate", .{change.key});
            return error.InvalidMetadataUpdate;
        };
    }
}

/// The `objects.patch` body: only what the options ask to change.
pub fn encode(arena: Allocator, options: types.MetadataUpdate) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    write(&jw, options) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn write(jw: *Stringify, options: types.MetadataUpdate) Stringify.Error!void {
    try jw.beginObject();
    const fixed = [_]struct { name: []const u8, value: ?[]const u8 }{
        .{ .name = "contentType", .value = options.content_type },
        .{ .name = "cacheControl", .value = options.cache_control },
        .{ .name = "contentDisposition", .value = options.content_disposition },
        .{ .name = "contentEncoding", .value = options.content_encoding },
        .{ .name = "contentLanguage", .value = options.content_language },
    };
    for (fixed) |field| {
        const value = field.value orelse continue;
        try jw.objectField(field.name);
        try jw.write(value);
    }
    switch (options.edit) {
        .keep => {},
        .clear => {
            try jw.objectField("metadata");
            try jw.write(null);
        },
        .change => |changes| {
            try jw.objectField("metadata");
            try jw.beginObject();
            for (changes) |change| {
                try jw.objectField(change.key);
                // Null is how Cloud Storage is told to remove the key.
                if (change.value) |value| try jw.write(value) else try jw.write(null);
            }
            try jw.endObject();
        },
    }
    try jw.endObject();
}

/// What a response header can carry back: printable ASCII and spaces, the
/// shape `validate.isUserAgent` already states for the header this library
/// sends.
fn isHeaderText(text: []const u8) bool {
    for (text) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

const testing = std.testing;
const test_util = @import("test_util.zig");

const object_json =
    \\{"name":"a","bucket":"my-bucket","generation":"7","metageneration":"3",
    \\ "contentType":"text/plain","cacheControl":"public, max-age=60",
    \\ "contentDisposition":"attachment","contentEncoding":"gzip",
    \\ "contentLanguage":"en","metadata":{"reviewer":"kim"}}
;

/// The options beside the body they must produce. Written out by hand from
/// the three rules in the module comment.
const Golden = struct {
    label: []const u8,
    options: types.MetadataUpdate,
    body: []const u8,
};

const goldens = [_]Golden{
    .{
        .label = "nothing at all is an empty patch, which Cloud Storage accepts",
        .options = .{},
        .body = "{}",
    },
    .{
        .label = "one fixed field",
        .options = .{ .content_type = "text/plain" },
        .body = "{\"contentType\":\"text/plain\"}",
    },
    .{
        .label = "every fixed field, in the order the wire names them",
        .options = .{
            .content_type = "text/html",
            .cache_control = "public, max-age=60",
            .content_disposition = "attachment; filename=\"a\"",
            .content_encoding = "gzip",
            .content_language = "en-GB",
        },
        .body = "{\"contentType\":\"text/html\",\"cacheControl\":\"public, max-age=60\"," ++
            "\"contentDisposition\":\"attachment; filename=\\\"a\\\"\"," ++
            "\"contentEncoding\":\"gzip\",\"contentLanguage\":\"en-GB\"}",
    },
    .{
        .label = "an empty string clears a field, where null would leave it",
        .options = .{ .cache_control = "" },
        .body = "{\"cacheControl\":\"\"}",
    },
    .{
        .label = "keep sends no metadata key at all",
        .options = .{ .content_type = "text/plain", .edit = .keep },
        .body = "{\"contentType\":\"text/plain\"}",
    },
    .{
        .label = "change sets and removes, and says nothing about other keys",
        .options = .{ .edit = .{ .change = &.{
            .{ .key = "reviewer", .value = "kim" },
            .{ .key = "draft", .value = null },
        } } },
        .body = "{\"metadata\":{\"reviewer\":\"kim\",\"draft\":null}}",
    },
    .{
        .label = "an empty change list still sends an object, which changes nothing",
        .options = .{ .edit = .{ .change = &.{} } },
        .body = "{\"metadata\":{}}",
    },
    .{
        .label = "clear removes every entry",
        .options = .{ .edit = .clear },
        .body = "{\"metadata\":null}",
    },
    .{
        .label = "fields and custom entries together",
        .options = .{
            .content_type = "application/json",
            .edit = .{ .change = &.{.{ .key = "origin", .value = "zig" }} },
        },
        .body = "{\"contentType\":\"application/json\",\"metadata\":{\"origin\":\"zig\"}}",
    },
};

test "golden: the patch body, written from the rules by hand" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    for (goldens) |golden| {
        errdefer std.debug.print("golden: {s}\n", .{golden.label});
        try testing.expectEqualStrings(golden.body, try encode(arena_state.allocator(), golden.options));
    }
}

test "updateMetadata: the request, and the object it answers with" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = object_json } }}, .{});
    defer h.deinit();
    var info = try h.client.bucket("my-bucket").object("dir/a b.txt").updateMetadata(.{
        .content_type = "text/plain",
        .edit = .{ .change = &.{.{ .key = "reviewer", .value = "kim" }} },
    });
    defer info.deinit();
    try h.expectRequest(
        0,
        .PATCH,
        "https://storage.googleapis.com/storage/v1/b/my-bucket/o/dir%2Fa%20b.txt",
        "{\"contentType\":\"text/plain\",\"metadata\":{\"reviewer\":\"kim\"}}",
    );
    // The four fields v1 could set and never read back.
    try testing.expectEqualStrings("public, max-age=60", info.value.cache_control.?);
    try testing.expectEqualStrings("attachment", info.value.content_disposition.?);
    try testing.expectEqualStrings("gzip", info.value.content_encoding.?);
    try testing.expectEqualStrings("en", info.value.content_language.?);
    try testing.expectEqualStrings("kim", info.value.metadataValue("reviewer").?);
}

test "updateMetadata: a generation and every precondition reach the query" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = object_json } }}, .{});
    defer h.deinit();
    var info = try h.client.bucket("b").object("a").updateMetadata(.{
        .generation = 7,
        .preconditions = .{ .if_generation_match = 7, .if_metageneration_match = 3 },
    });
    defer info.deinit();
    try h.expectRequest(
        0,
        .PATCH,
        "https://storage.googleapis.com/storage/v1/b/b/o/a?generation=7&ifGenerationMatch=7&ifMetagenerationMatch=3",
        "{}",
    );
}

test "updateMetadata: a metageneration condition is what makes it repeatable" {
    // Unconditional: one 503 ends the call, because a patch that lost its
    // answer may already have been applied.
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .status = 503, .body = "{}" } }}, .{});
    defer h.deinit();
    try testing.expectError(error.Unavailable, h.client.bucket("b").object("a").updateMetadata(.{}));
    try h.expectRequestCount(1);

    // Under if_metageneration_match, a repeat cannot apply twice.
    var conditional: test_util.Harness = undefined;
    try conditional.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .body = object_json } },
    }, .{});
    defer conditional.deinit();
    var info = try conditional.client.bucket("b").object("a").updateMetadata(.{
        .preconditions = .{ .if_metageneration_match = 3 },
    });
    defer info.deinit();
    try conditional.expectRequestCount(2);

    // A generation condition says nothing about a patch, which never
    // moves the generation.
    var generation: test_util.Harness = undefined;
    try generation.init(&.{.{ .respond = .{ .status = 503, .body = "{}" } }}, .{});
    defer generation.deinit();
    try testing.expectError(error.Unavailable, generation.client.bucket("b").object("a").updateMetadata(.{
        .preconditions = .{ .if_generation_match = 7 },
    }));
    try generation.expectRequestCount(1);
}

test "updateMetadata: retry_unconditional_writes opts back in" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .body = object_json } },
    }, .{ .retry_unconditional_writes = true });
    defer h.deinit();
    var info = try h.client.bucket("b").object("a").updateMetadata(.{});
    defer info.deinit();
    try h.expectRequestCount(2);
}

test "check: keys that are empty, repeated, or not header text" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const obj = h.client.bucket("b").object("a");
    try testing.expectError(error.InvalidMetadataUpdate, obj.updateMetadata(.{
        .edit = .{ .change = &.{.{ .key = "", .value = "v" }} },
    }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "no key") != null);
    try testing.expectError(error.InvalidMetadataUpdate, obj.updateMetadata(.{
        .edit = .{ .change = &.{
            .{ .key = "a", .value = "1" },
            .{ .key = "a", .value = null },
        } },
    }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "twice") != null);
    for ([_][]const u8{ "a\nb", "a\x00b", "a\x7fb", "caf\xc3\xa9" }) |bad| {
        errdefer std.debug.print("text: {s}\n", .{bad});
        try testing.expectError(error.InvalidMetadataUpdate, obj.updateMetadata(.{
            .edit = .{ .change = &.{.{ .key = bad, .value = "v" }} },
        }));
        try testing.expectError(error.InvalidMetadataUpdate, obj.updateMetadata(.{
            .edit = .{ .change = &.{.{ .key = "k", .value = bad }} },
        }));
        try testing.expectError(error.InvalidMetadataUpdate, obj.updateMetadata(.{ .cache_control = bad }));
    }
    // Nothing was sent for any of them.
    try h.expectRequestCount(0);
}

test "check: a removal needs no value, and an empty string is not a removal" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ .{ .respond = .{ .body = object_json } }, .{ .respond = .{ .body = object_json } } }, .{});
    defer h.deinit();
    const obj = h.client.bucket("b").object("a");
    var removed = try obj.updateMetadata(.{ .edit = .{ .change = &.{.{ .key = "k", .value = null }} } });
    removed.deinit();
    try h.expectRequest(0, .PATCH, "https://storage.googleapis.com/storage/v1/b/b/o/a", "{\"metadata\":{\"k\":null}}");
    var emptied = try obj.updateMetadata(.{ .edit = .{ .change = &.{.{ .key = "k", .value = "" }} } });
    emptied.deinit();
    try h.expectRequest(1, .PATCH, "https://storage.googleapis.com/storage/v1/b/b/o/a", "{\"metadata\":{\"k\":\"\"}}");
}

test "updateMetadata: names are checked like every other call" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidBucketName, h.client.bucket("has space").object("a").updateMetadata(.{}));
    try testing.expectError(error.InvalidObjectName, h.client.bucket("b").object("a\nb").updateMetadata(.{}));
    try h.expectRequestCount(0);
}

fn patchEverything(gpa: Allocator) !void {
    // Built by hand rather than through `Harness`, whose `deinit` frees
    // both halves: here the transport must outlive a client that may
    // never have been built.
    var fake: test_util.FakeTransport = .init(gpa, &.{.{ .respond = .{ .body = object_json } }});
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var token: test_util.FakeTokenProvider = .{ .token = "ya29.test-token" };
    var client: Client = try .init(gpa, clock.io(), .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    var info = try client.bucket("b").object("a").updateMetadata(.{
        .content_type = "text/plain",
        .edit = .{ .change = &.{ .{ .key = "a", .value = "1" }, .{ .key = "b", .value = null } } },
    });
    info.deinit();
}

test "updateMetadata: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, patchEverything, .{});
}

// Properties. Each states a rule of the module comment independently of
// the code above, and holds it to arbitrary input.

/// The five fixed fields, wire name beside option name, so a property can
/// walk them without naming each one twice.
const fixed_fields = [_][2][]const u8{
    .{ "contentType", "content_type" },
    .{ "cacheControl", "cache_control" },
    .{ "contentDisposition", "content_disposition" },
    .{ "contentEncoding", "content_encoding" },
    .{ "contentLanguage", "content_language" },
};

fn drawUpdate(arena: Allocator, g: *test_util.ByteGen) !types.MetadataUpdate {
    var buffer: [128]u8 = undefined;
    var options: types.MetadataUpdate = .{};
    // Each field is absent, empty, or a drawn value.
    const values = try arena.alloc(?[]const u8, fixed_fields.len);
    for (values) |*value| value.* = switch (g.intRange(u8, 0, 2)) {
        0 => null,
        1 => "",
        else => try arena.dupe(u8, g.utf8(&buffer, 24)),
    };
    options.content_type = values[0];
    options.cache_control = values[1];
    options.content_disposition = values[2];
    options.content_encoding = values[3];
    options.content_language = values[4];
    options.edit = switch (g.intRange(u8, 0, 3)) {
        0 => .keep,
        1 => .clear,
        else => edit: {
            const changes = try arena.alloc(types.MetadataChange, g.intRange(usize, 0, 4));
            for (changes) |*change| change.* = .{
                .key = try arena.dupe(u8, g.utf8(&buffer, 16)),
                .value = if (g.intRange(u8, 0, 2) == 0) null else try arena.dupe(u8, g.utf8(&buffer, 24)),
            };
            break :edit .{ .change = changes };
        },
    };
    return options;
}

fn bodyProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    const options = try drawUpdate(arena, &g);
    check(null, options) catch return;
    const body = try encode(arena, options);

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    // Every field the options set, and no key they did not.
    var expected: usize = 0;
    const values = [_]?[]const u8{
        options.content_type,     options.cache_control,    options.content_disposition,
        options.content_encoding, options.content_language,
    };
    for (fixed_fields, values) |pair, value| {
        const want = value orelse {
            try testing.expectEqual(null, root.get(pair[0]));
            continue;
        };
        expected += 1;
        try testing.expectEqualStrings(want, (root.get(pair[0]) orelse return error.TestFieldMissing).string);
    }
    switch (options.edit) {
        .keep => try testing.expectEqual(null, root.get("metadata")),
        .clear => {
            expected += 1;
            try testing.expectEqual(std.json.Value.null, root.get("metadata").?);
        },
        .change => |changes| {
            expected += 1;
            const entries = (root.get("metadata") orelse return error.TestNoMetadata).object;
            // A repeated key cannot reach here: `check` refuses it.
            try testing.expectEqual(changes.len, entries.count());
            for (changes) |change| {
                const got = entries.get(change.key) orelse return error.TestKeyMissing;
                if (change.value) |value| {
                    try testing.expectEqualStrings(value, got.string);
                } else {
                    try testing.expectEqual(std.json.Value.null, got);
                }
            }
        },
    }
    try testing.expectEqual(expected, root.count());
}

test "fuzz metadata: the patch body says what the options said, and no more" {
    try test_util.fuzzBytes({}, bodyProperty, .{ .corpus = &.{
        "",
        "\x00\x00\x00\x00\x00\x00",
        "\x02\x02\x02\x02\x02\x02",
        "\x01\x01\x01\x01\x01\x03\x02",
    } });
}

/// The body written a second time, from the module comment's rules, with
/// none of the code above.
fn modelBody(arena: Allocator, options: types.MetadataUpdate) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '{');
    const values = [_]?[]const u8{
        options.content_type,     options.cache_control,    options.content_disposition,
        options.content_encoding, options.content_language,
    };
    var first = true;
    for (fixed_fields, values) |pair, value| {
        const text = value orelse continue;
        if (!first) try out.append(arena, ',');
        first = false;
        try out.print(arena, "\"{s}\":", .{pair[0]});
        try modelString(arena, &out, text);
    }
    switch (options.edit) {
        .keep => {},
        .clear => {
            if (!first) try out.append(arena, ',');
            try out.appendSlice(arena, "\"metadata\":null");
        },
        .change => |changes| {
            if (!first) try out.append(arena, ',');
            try out.appendSlice(arena, "\"metadata\":{");
            for (changes, 0..) |change, i| {
                if (i > 0) try out.append(arena, ',');
                try modelString(arena, &out, change.key);
                try out.append(arena, ':');
                if (change.value) |value| {
                    try modelString(arena, &out, value);
                } else {
                    try out.appendSlice(arena, "null");
                }
            }
            try out.append(arena, '}');
        },
    }
    try out.append(arena, '}');
    return out.items;
}

/// A JSON string as the encoder writes one: no escaping beyond what JSON
/// demands, since this body is not held to any byte-for-byte outside
/// answer the way a signed policy is.
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
    const options = try drawUpdate(arena, &g);
    check(null, options) catch return;
    try testing.expectEqualStrings(try modelBody(arena, options), try encode(arena, options));
}

test "slow property metadata: the patch body matches a model written from the rules" {
    try test_util.fuzzBytes({}, modelProperty, .{ .random_runs = 300, .max_len = 512 });
}

/// Section 6's rules, stated again.
fn allowedByRules(options: types.MetadataUpdate) bool {
    const values = [_]?[]const u8{
        options.content_type,     options.cache_control,    options.content_disposition,
        options.content_encoding, options.content_language,
    };
    for (values) |value| {
        const text = value orelse continue;
        if (text.len != 0 and !isHeaderText(text)) return false;
    }
    const changes = switch (options.edit) {
        .keep, .clear => return true,
        .change => |list| list,
    };
    for (changes, 0..) |change, i| {
        if (change.key.len == 0) return false;
        if (!isHeaderText(change.key)) return false;
        if (change.value) |value| if (!isHeaderText(value)) return false;
        for (changes[0..i]) |earlier| if (std.mem.eql(u8, earlier.key, change.key)) return false;
    }
    return true;
}

fn checkProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    var options = try drawUpdate(arena, &g);
    // The draw keeps to valid UTF-8; splice in what a caller could pass.
    if (g.intRange(u8, 0, 3) == 0) options.cache_control = g.rest();
    const allowed = allowedByRules(options);
    const result = check(null, options);
    try testing.expectEqual(allowed, result != error.InvalidMetadataUpdate);
}

test "fuzz metadata: check accepts exactly what the rules allow" {
    try test_util.fuzzBytes({}, checkProperty, .{ .corpus = &.{
        "",
        "\x00\x00\x00\x00\x00\x03\x02",
        "\x02\x00\x00\x00\x00\x00",
    } });
}
