//! Integration tests for auth, against Google.
//!
//! - AUTH_TEST_CREDENTIALS: the path of a credentials file, either an
//!   `authorized_user` one such as
//!   ~/.config/gcloud/application_default_credentials.json, or a
//!   `service_account` key file. Each test runs when the file is the type
//!   it exercises, and skips otherwise.
//! - PUBSUB_TEST_PROJECT as well: a read-only Pub/Sub call made with the
//!   token, to show Google accepts it.
//!
//! With AUTH_TEST_CREDENTIALS unset, every test skips. No test prints a token.

const std = @import("std");
const auth = @import("auth");
const pubsub = @import("pubsub");
const testing = std.testing;

const scopes: []const []const u8 = &.{"https://www.googleapis.com/auth/cloud-platform"};

/// The declared type of the file AUTH_TEST_CREDENTIALS names, or null when
/// the variable is unset. A test for the other type should skip.
fn credentialsType(env: *const std.process.Environ.Map, arena: std.mem.Allocator) !?[]const u8 {
    const path = env.get("AUTH_TEST_CREDENTIALS") orelse return null;
    const json = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(64 * 1024));
    const Wire = struct { type: ?[]const u8 = null };
    const wire = try std.json.parseFromSliceLeaky(Wire, arena, json, .{ .ignore_unknown_fields = true });
    return wire.type orelse "";
}

test "a real refresh: the token endpoint trades the refresh token for an access token" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var type_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer type_arena.deinit();
    const kind = try credentialsType(&env, type_arena.allocator()) orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, kind, "authorized_user")) return error.SkipZigTest;
    const path = env.get("AUTH_TEST_CREDENTIALS").?;
    var diag: auth.Diagnostics = .{};
    errdefer std.debug.print("diagnostics: HTTP {d} {s}: {s}\n", .{ diag.http_status, diag.status(), diag.message() });

    var user: auth.AuthorizedUser = try .initFromFile(testing.allocator, testing.io, path, .{ .diagnostics = &diag });
    defer user.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = user.provider();

    const first = try p.getToken(testing.io, arena.allocator(), scopes);
    try testing.expect(auth.TokenProvider.isValidToken(first));
    // The second call is served from the cache.
    try testing.expectEqualStrings(first, try p.getToken(testing.io, arena.allocator(), scopes));
    // After invalidate, the refresh token is traded again.
    p.invalidate();
    try testing.expect(auth.TokenProvider.isValidToken(try p.getToken(testing.io, arena.allocator(), scopes)));
}

test "a real refresh, then a Pub/Sub call with the token" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var type_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer type_arena.deinit();
    const kind = try credentialsType(&env, type_arena.allocator()) orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, kind, "authorized_user")) return error.SkipZigTest;
    const path = env.get("AUTH_TEST_CREDENTIALS").?;
    const project = env.get("PUBSUB_TEST_PROJECT") orelse return error.SkipZigTest;
    var diag: auth.Diagnostics = .{};
    errdefer std.debug.print("diagnostics: HTTP {d} {s}: {s}\n", .{ diag.http_status, diag.status(), diag.message() });

    var user: auth.AuthorizedUser = try .initFromFile(testing.allocator, testing.io, path, .{ .diagnostics = &diag });
    defer user.deinit();
    var client: pubsub.Client = try .init(testing.allocator, testing.io, .{
        .project_id = project,
        .token_provider = user.provider(),
        .diagnostics = &diag,
    });
    defer client.deinit();
    var page = try client.listTopics(.{ .page_size = 1 });
    page.deinit();
}

test "a real assertion: the token endpoint trades a signed JWT for an access token" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var type_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer type_arena.deinit();
    const kind = try credentialsType(&env, type_arena.allocator()) orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, kind, "service_account")) return error.SkipZigTest;
    const path = env.get("AUTH_TEST_CREDENTIALS").?;
    var diag: auth.Diagnostics = .{};
    errdefer std.debug.print("diagnostics: HTTP {d} {s}: {s}\n", .{ diag.http_status, diag.status(), diag.message() });

    var account: auth.ServiceAccount = try .initFromFile(testing.allocator, testing.io, path, .{ .diagnostics = &diag });
    defer account.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = account.provider();

    const first = try p.getToken(testing.io, arena.allocator(), scopes);
    try testing.expect(auth.TokenProvider.isValidToken(first));
    // The second call is served from the cache.
    try testing.expectEqualStrings(first, try p.getToken(testing.io, arena.allocator(), scopes));
    // After invalidate, a new JWT is signed and traded.
    p.invalidate();
    try testing.expect(auth.TokenProvider.isValidToken(try p.getToken(testing.io, arena.allocator(), scopes)));
    // The scopes were fixed by the first call.
    try testing.expectError(error.TokenUnavailable, p.getToken(testing.io, arena.allocator(), &.{"https://www.googleapis.com/auth/pubsub"}));
}

test "a real assertion, then a Pub/Sub call the token authenticates" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var type_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer type_arena.deinit();
    const kind = try credentialsType(&env, type_arena.allocator()) orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, kind, "service_account")) return error.SkipZigTest;
    const path = env.get("AUTH_TEST_CREDENTIALS").?;
    const project = env.get("PUBSUB_TEST_PROJECT") orelse return error.SkipZigTest;
    var diag: auth.Diagnostics = .{};
    errdefer std.debug.print("diagnostics: HTTP {d} {s}: {s}\n", .{ diag.http_status, diag.status(), diag.message() });

    var account: auth.ServiceAccount = try .initFromFile(testing.allocator, testing.io, path, .{ .diagnostics = &diag });
    defer account.deinit();
    var client: pubsub.Client = try .init(testing.allocator, testing.io, .{
        .project_id = project,
        .token_provider = account.provider(),
        .diagnostics = &diag,
    });
    defer client.deinit();
    // The account may hold no role in the project. A 403 still proves the
    // token authenticated: an unusable token would be a 401.
    var page = client.listTopics(.{ .page_size = 1 }) catch |err| switch (err) {
        error.PermissionDenied => return,
        else => return err,
    };
    page.deinit();
}

test "on Google Cloud: the metadata server hands out a token for the attached account" {
    const io = testing.io;
    var diag: auth.Diagnostics = .{};
    var metadata: auth.MetadataServer = try .init(testing.allocator, io, .{ .diagnostics = &diag });
    defer metadata.deinit();
    // Off Google Cloud there is nothing to talk to, and this is how a
    // caller finds that out.
    if (!metadata.probe(io)) return error.SkipZigTest;
    errdefer std.debug.print("diagnostics: HTTP {d} {s}: {s}\n", .{ diag.http_status, diag.status(), diag.message() });

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = metadata.provider();
    const first = try p.getToken(io, arena.allocator(), scopes);
    try testing.expect(auth.TokenProvider.isValidToken(first));
    try testing.expectEqualStrings(first, try p.getToken(io, arena.allocator(), scopes));
    p.invalidate();
    try testing.expect(auth.TokenProvider.isValidToken(try p.getToken(io, arena.allocator(), scopes)));

    // The project it runs in, and a read-only call with the token.
    const project = try metadata.projectId(io, arena.allocator());
    try testing.expect(project.len > 0);
    var client: pubsub.Client = try .init(testing.allocator, io, .{
        .project_id = project,
        .token_provider = p,
        .diagnostics = &diag,
    });
    defer client.deinit();
    var page = try client.listTopics(.{ .page_size = 1 });
    page.deinit();
}

test "findDefault: the file the environment names, used against Google" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    const path = env.get("AUTH_TEST_CREDENTIALS") orelse return error.SkipZigTest;
    var diag: auth.Diagnostics = .{};
    errdefer std.debug.print("diagnostics: HTTP {d} {s}: {s}\n", .{ diag.http_status, diag.status(), diag.message() });

    // The whole chain, as an application would run it, with the first
    // source pointed at a real credentials file.
    var creds = try auth.findDefault(testing.allocator, testing.io, .{
        .credentials_path = path,
        .diagnostics = &diag,
    }, .{});
    defer creds.deinit();
    try testing.expectEqual(.env_file, creds.source);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const token = try creds.provider().getToken(testing.io, arena.allocator(), scopes);
    try testing.expect(auth.TokenProvider.isValidToken(token));
}
