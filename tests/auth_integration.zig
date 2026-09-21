//! Integration tests for auth, against Google.
//!
//! - AUTH_TEST_CREDENTIALS: the path of a credentials file: an
//!   `authorized_user` one such as
//!   ~/.config/gcloud/application_default_credentials.json, a
//!   `service_account` key file, or an `impersonated_service_account` file
//!   whose source may act as its service account. Each test runs when the
//!   file is the type it exercises, and skips otherwise.
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

test "a real exchange: the STS trades a real subject token for an access token" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var type_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer type_arena.deinit();
    const kind = try credentialsType(&env, type_arena.allocator()) orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, kind, "external_account")) return error.SkipZigTest;
    const path = env.get("AUTH_TEST_CREDENTIALS").?;
    var diag: auth.Diagnostics = .{};
    errdefer std.debug.print("diagnostics: HTTP {d} {s}: {s}\n", .{ diag.http_status, diag.status(), diag.message() });

    var account: auth.ExternalAccount = try .initFromFile(testing.allocator, testing.io, path, .{ .diagnostics = &diag });
    defer account.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = account.provider();

    const first = try p.getToken(testing.io, arena.allocator(), scopes);
    try testing.expect(auth.TokenProvider.isValidToken(first));
    // The second call is served from the cache.
    try testing.expectEqualStrings(first, try p.getToken(testing.io, arena.allocator(), scopes));
    // After invalidate, the whole exchange runs again.
    p.invalidate();
    try testing.expect(auth.TokenProvider.isValidToken(try p.getToken(testing.io, arena.allocator(), scopes)));
}

test "a real STS refusal: Google's token exchange rejects a fabricated subject token in form" {
    // Needs no credentials, only permission to touch the network, which
    // AUTH_TEST_CREDENTIALS being set signals.
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    if (env.get("AUTH_TEST_CREDENTIALS") == null) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "subject", .data = "not-a-real-oidc-token" });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const json = try std.fmt.allocPrint(arena.allocator(),
        \\{{"type": "external_account",
        \\ "audience": "//iam.googleapis.com/projects/000000/locations/global/workloadIdentityPools/no-such-pool/providers/none",
        \\ "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
        \\ "token_url": "https://sts.googleapis.com/v1/token",
        \\ "credential_source": {{"file": ".zig-cache/tmp/{s}/subject"}}}}
    , .{&tmp.sub_path});

    var diag: auth.Diagnostics = .{};
    var account: auth.ExternalAccount = try .initFromJson(testing.allocator, testing.io, json, .{ .diagnostics = &diag });
    defer account.deinit();
    // The real endpoint answers with a real OAuth error, which proves the
    // exchange's wire format and our reading of the answer.
    try testing.expectError(error.TokenEndpointRejected, account.provider().getToken(
        testing.io,
        arena.allocator(),
        &.{"https://www.googleapis.com/auth/cloud-platform"},
    ));
    try testing.expectEqual(400, diag.http_status);
    try testing.expect(diag.status().len > 0);
    try testing.expect(diag.message().len > 0);
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

test "a real impersonation: IAM trades the source's token for one that is the service account" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var type_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer type_arena.deinit();
    const kind = try credentialsType(&env, type_arena.allocator()) orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, kind, "impersonated_service_account")) return error.SkipZigTest;
    const path = env.get("AUTH_TEST_CREDENTIALS").?;
    var diag: auth.Diagnostics = .{};
    errdefer std.debug.print("diagnostics: HTTP {d} {s}: {s}\n", .{ diag.http_status, diag.status(), diag.message() });

    var account: auth.ImpersonatedServiceAccount = try .initFromFile(testing.allocator, testing.io, path, .{ .diagnostics = &diag });
    defer account.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = account.provider();
    // The email scope too, so Google will say whose token this is.
    const with_email: []const []const u8 = &.{
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
    };
    const token = try p.getToken(testing.io, arena.allocator(), with_email);
    try testing.expect(auth.TokenProvider.isValidToken(token));
    try testing.expectEqualStrings(token, try p.getToken(testing.io, arena.allocator(), with_email));

    // Google's own word on whose token it is: the service account's, not
    // the login's that asked for it.
    var http: pubsub.transport.HttpTransport = .init(testing.allocator, testing.io, "zig-gcp-auth-integration/0.1");
    defer http.deinit();
    const body = try std.fmt.allocPrint(arena.allocator(), "access_token={s}", .{token});
    const res = try http.transport().send(.{
        .method = .POST,
        .url = "https://oauth2.googleapis.com/tokeninfo",
        .body = body,
        .content_type = .form,
        .timeout_ms = 30_000,
    }, arena.allocator());
    try testing.expectEqual(200, res.status);
    const Info = struct { email: ?[]const u8 = null };
    const info = try std.json.parseFromSliceLeaky(Info, arena.allocator(), res.body, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings(account.targetPrincipal(), info.email orelse return error.TestNoEmailInTokenInfo);
}

test "a real impersonation, then a Pub/Sub call as the service account" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var type_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer type_arena.deinit();
    const kind = try credentialsType(&env, type_arena.allocator()) orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, kind, "impersonated_service_account")) return error.SkipZigTest;
    const project = env.get("PUBSUB_TEST_PROJECT") orelse return error.SkipZigTest;
    var diag: auth.Diagnostics = .{};

    var account: auth.ImpersonatedServiceAccount = try .initFromFile(testing.allocator, testing.io, env.get("AUTH_TEST_CREDENTIALS").?, .{});
    defer account.deinit();
    var client = try pubsub.Client.init(testing.allocator, testing.io, .{
        .project_id = project,
        .token_provider = account.provider(),
        .diagnostics = &diag,
    });
    defer client.deinit();
    // The test account holds no roles. PermissionDenied means Google took
    // the token and knew whose it was; a bad token would be Unauthenticated.
    if (client.listTopics(.{ .page_size = 1 })) |page| {
        var owned = page;
        owned.deinit();
    } else |err| {
        if (err != error.PermissionDenied) {
            std.debug.print("diagnostics: HTTP {d} {s}: {s}\n", .{ diag.http_status, diag.status(), diag.message() });
            return err;
        }
    }
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
