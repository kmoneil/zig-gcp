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
