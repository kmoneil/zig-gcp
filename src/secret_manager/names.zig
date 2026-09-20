//! Resource names and request paths, global and regional.
//!
//! A global secret lives under `projects/{project}`, a regional one under
//! `projects/{project}/locations/{location}` on its own host. The two are
//! separate namespaces: production answers NOT_FOUND when a global client
//! asks for a regional secret, and refuses a regional path on the global
//! host outright.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const query = @import("core").query;
const types = @import("types.zig");

/// Which project, and which location's namespace, a path addresses.
pub const Parent = struct {
    project: []const u8,
    /// Null for global secrets.
    location: ?[]const u8 = null,
};

/// The production host that serves `location`. The caller has already
/// checked the location against `validate.isLocation`, which is what keeps
/// it from naming another host.
pub fn host(arena: Allocator, location: ?[]const u8) Allocator.Error![]u8 {
    const loc = location orelse return arena.dupe(u8, "secretmanager.googleapis.com");
    return std.fmt.allocPrint(arena, "secretmanager.{s}.rep.googleapis.com", .{loc});
}

/// `/v1/{parent}/secrets/{id}{suffix}`. `suffix` is a literal method such as
/// `:addVersion`, or "".
pub fn secretPath(arena: Allocator, parent: Parent, id: []const u8, suffix: []const u8) Allocator.Error![]u8 {
    return build(arena, struct {
        fn write(w: *Writer, p: Parent, secret_id: []const u8, tail: []const u8) Writer.Error!void {
            try writeSecret(w, p, secret_id);
            try w.writeAll(tail);
        }
    }.write, parent, id, suffix);
}

/// `/v1/{parent}/secrets?secretId={id}`: the id is a query parameter, not
/// part of the path.
pub fn createPath(arena: Allocator, parent: Parent, id: []const u8) Allocator.Error![]u8 {
    return build(arena, struct {
        fn write(w: *Writer, p: Parent, secret_id: []const u8, _: []const u8) Writer.Error!void {
            try writeCollection(w, p);
            var params: query.Params = .init(w);
            try params.add("secretId", secret_id);
        }
    }.write, parent, id, "");
}

/// `/v1/{parent}/secrets` with the list query.
pub fn secretsPath(arena: Allocator, parent: Parent, options: types.ListOptions) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    writeSecretsPath(w, parent, options) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeSecretsPath(w: *Writer, parent: Parent, options: types.ListOptions) Writer.Error!void {
    try writeCollection(w, parent);
    try writeListQuery(w, options);
}

/// `/v1/{parent}/secrets/{id}/versions/{ref}{suffix}`.
pub fn versionPath(
    arena: Allocator,
    parent: Parent,
    id: []const u8,
    ref: types.VersionRef,
    suffix: []const u8,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    writeVersionPath(w, parent, id, ref, suffix) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeVersionPath(
    w: *Writer,
    parent: Parent,
    id: []const u8,
    ref: types.VersionRef,
    suffix: []const u8,
) Writer.Error!void {
    try writeSecret(w, parent, id);
    try w.writeAll("/versions/");
    switch (ref) {
        .latest => try w.writeAll("latest"),
        .number => |n| try w.print("{d}", .{n}),
        .alias => |alias| try query.writeSegment(w, alias),
    }
    try w.writeAll(suffix);
}

/// `/v1/{parent}/secrets/{id}/versions` with the list query.
pub fn versionsPath(
    arena: Allocator,
    parent: Parent,
    id: []const u8,
    options: types.ListOptions,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    writeVersionsPath(w, parent, id, options) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeVersionsPath(w: *Writer, parent: Parent, id: []const u8, options: types.ListOptions) Writer.Error!void {
    try writeSecret(w, parent, id);
    try w.writeAll("/versions");
    try writeListQuery(w, options);
}

/// The unencoded resource name of a secret, as it appears inside a body.
pub fn secretName(arena: Allocator, parent: Parent, id: []const u8) Allocator.Error![]u8 {
    if (parent.location) |loc| {
        return std.fmt.allocPrint(arena, "projects/{s}/locations/{s}/secrets/{s}", .{ parent.project, loc, id });
    }
    return std.fmt.allocPrint(arena, "projects/{s}/secrets/{s}", .{ parent.project, id });
}

/// The trailing number of a version's resource name, or null when it ends in
/// something else, as `latest` does before the server resolves it.
pub fn versionNumber(name: []const u8) ?u64 {
    return std.fmt.parseInt(u64, lastSegment(name), 10) catch null;
}

/// The last segment of a resource name.
pub fn lastSegment(name: []const u8) []const u8 {
    const at = std.mem.lastIndexOfScalar(u8, name, '/') orelse return name;
    return name[at + 1 ..];
}

fn build(
    arena: Allocator,
    comptime write: fn (*Writer, Parent, []const u8, []const u8) Writer.Error!void,
    parent: Parent,
    id: []const u8,
    tail: []const u8,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, parent, id, tail) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/v1/projects/{project}[/locations/{location}]/secrets`.
fn writeCollection(w: *Writer, parent: Parent) Writer.Error!void {
    try w.writeAll("/v1/projects/");
    try query.writeSegment(w, parent.project);
    if (parent.location) |loc| {
        try w.writeAll("/locations/");
        try query.writeSegment(w, loc);
    }
    try w.writeAll("/secrets");
}

fn writeSecret(w: *Writer, parent: Parent, id: []const u8) Writer.Error!void {
    try writeCollection(w, parent);
    try w.writeByte('/');
    try query.writeSegment(w, id);
}

fn writeListQuery(w: *Writer, options: types.ListOptions) Writer.Error!void {
    var params: query.Params = .init(w);
    try params.addNonZero("pageSize", options.page_size);
    try params.addOptional("pageToken", options.page_token);
    try params.addOptional("filter", options.filter);
}

const testing = std.testing;
const test_util = @import("test_util.zig");

const global: Parent = .{ .project = "extractctl" };
const regional: Parent = .{ .project = "extractctl", .location = "europe-west3" };

test "paths: global and regional, one per operation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "/v1/projects/extractctl/secrets?secretId=db-password",
        try createPath(a, global, "db-password"),
    );
    try testing.expectEqualStrings(
        "/v1/projects/extractctl/locations/europe-west3/secrets?secretId=db-password",
        try createPath(a, regional, "db-password"),
    );
    try testing.expectEqualStrings(
        "/v1/projects/extractctl/secrets/db-password",
        try secretPath(a, global, "db-password", ""),
    );
    try testing.expectEqualStrings(
        "/v1/projects/extractctl/secrets/db-password:addVersion",
        try secretPath(a, global, "db-password", ":addVersion"),
    );
    try testing.expectEqualStrings(
        "/v1/projects/extractctl/locations/europe-west3/secrets/db-password:addVersion",
        try secretPath(a, regional, "db-password", ":addVersion"),
    );
    try testing.expectEqualStrings(
        "/v1/projects/extractctl/secrets/db-password/versions/latest:access",
        try versionPath(a, global, "db-password", .latest, ":access"),
    );
    try testing.expectEqualStrings(
        "/v1/projects/extractctl/secrets/db-password/versions/3:destroy",
        try versionPath(a, global, "db-password", .{ .number = 3 }, ":destroy"),
    );
    try testing.expectEqualStrings(
        "/v1/projects/extractctl/locations/europe-west3/secrets/db-password/versions/prod:access",
        try versionPath(a, regional, "db-password", .{ .alias = "prod" }, ":access"),
    );
}

test "paths: the list query" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("/v1/projects/extractctl/secrets", try secretsPath(a, global, .{}));
    try testing.expectEqualStrings(
        "/v1/projects/extractctl/secrets?pageSize=2&pageToken=abc%2B%3D&filter=labels.zig-gcp-test%3D1",
        try secretsPath(a, global, .{ .page_size = 2, .page_token = "abc+=", .filter = "labels.zig-gcp-test=1" }),
    );
    try testing.expectEqualStrings(
        "/v1/projects/extractctl/secrets/db-password/versions?pageSize=100",
        try versionsPath(a, global, "db-password", .{ .page_size = 100 }),
    );
    try testing.expectEqualStrings(
        "/v1/projects/extractctl/locations/europe-west3/secrets/db-password/versions",
        try versionsPath(a, regional, "db-password", .{ .page_token = "" }),
    );
}

test "hosts: global and regional" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("secretmanager.googleapis.com", try host(a, null));
    try testing.expectEqualStrings("secretmanager.europe-west3.rep.googleapis.com", try host(a, "europe-west3"));
}

test "resource names and their parts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("projects/extractctl/secrets/db", try secretName(a, global, "db"));
    try testing.expectEqualStrings(
        "projects/extractctl/locations/europe-west3/secrets/db",
        try secretName(a, regional, "db"),
    );

    try testing.expectEqual(3, versionNumber("projects/82150720798/secrets/db/versions/3").?);
    try testing.expectEqual(1, versionNumber("1").?);
    try testing.expectEqual(null, versionNumber("projects/82150720798/secrets/db/versions/latest"));
    try testing.expectEqual(null, versionNumber(""));
    try testing.expectEqual(null, versionNumber("projects/p/secrets/db"));
    try testing.expectEqual(null, versionNumber("versions/-1"));
    try testing.expectEqual(null, versionNumber("versions/99999999999999999999999"));
    try testing.expectEqualStrings("db", lastSegment("projects/p/secrets/db"));
    try testing.expectEqualStrings("db", lastSegment("db"));
    try testing.expectEqualStrings("", lastSegment("projects/p/secrets/"));
}

fn pathProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const parent: Parent = .{
        .project = g.slice(20),
        .location = if (g.boolean()) g.slice(12) else null,
    };
    const id = g.slice(20);
    const ref: types.VersionRef = switch (g.intRange(u8, 0, 2)) {
        0 => .latest,
        1 => .{ .number = g.int(u64) },
        else => .{ .alias = g.slice(12) },
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Whatever the inputs, a path is one path: no byte of it can start a
    // query, a fragment or a new segment that was not meant to be one.
    const paths: []const []const u8 = &.{
        try secretPath(a, parent, id, ":addVersion"),
        try versionPath(a, parent, id, ref, ":access"),
        try createPath(a, parent, id),
        try secretsPath(a, parent, .{ .filter = g.slice(16), .page_token = g.slice(16) }),
        try versionsPath(a, parent, id, .{ .page_size = g.int(u32) }),
    };
    for (paths) |path| {
        try testing.expect(std.mem.startsWith(u8, path, "/v1/projects/"));
        try testing.expect(std.mem.indexOfScalar(u8, path, '#') == null);
        const query_at = std.mem.indexOfScalar(u8, path, '?') orelse path.len;
        // Exactly the separators the builder wrote: the parent, the
        // collection, the id, and the version when there is one.
        try testing.expect(std.mem.count(u8, path[0..query_at], "/") <= 9);
        for (path) |c| try testing.expect(c > ' ' and c < 0x7f);
    }
}

test "fuzz paths: arbitrary ids and filters stay inside one path" {
    try test_util.fuzzBytes({}, pathProperty, .{ .corpus = &.{
        "\x00\x00\x00\x00\x00\x00\x00\x02p1\x00\x00\x00\x00\x00\x00\x00\x00\x02id",
        "\x00\x00\x00\x00\x00\x00\x00\x01p\x01\x00\x00\x00\x00\x00\x00\x00\x03loc\x00\x00\x00\x00\x00\x00\x00\x05a/b#c",
    } });
}
