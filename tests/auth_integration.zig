//! Integration tests for auth, against Google.
//!
//! - AUTH_TEST_CREDENTIALS: the path of an `authorized_user` credentials
//!   file, such as ~/.config/gcloud/application_default_credentials.json.
//!   The tests trade its refresh token at Google's token endpoint.
//! - PUBSUB_TEST_PROJECT as well: a read-only Pub/Sub call made with the
//!   token, to show Google accepts it.
//!
//! With AUTH_TEST_CREDENTIALS unset, every test skips. No test prints a token.

const std = @import("std");
const auth = @import("auth");
const pubsub = @import("pubsub");
const testing = std.testing;

const scopes: []const []const u8 = &.{"https://www.googleapis.com/auth/cloud-platform"};

test "a real refresh: the token endpoint trades the refresh token for an access token" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    const path = env.get("AUTH_TEST_CREDENTIALS") orelse return error.SkipZigTest;
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
    const path = env.get("AUTH_TEST_CREDENTIALS") orelse return error.SkipZigTest;
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
