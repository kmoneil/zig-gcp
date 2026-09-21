//! Integration tests against real Secret Manager. There is no emulator, so
//! these need a real project and a real token:
//!
//!     GCP_TEST_PROJECT=my-project \
//!     GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
//!     zig build test-integration-gcp
//!
//! Set GCP_TEST_LOCATION as well, to a location such as `europe-west3`, and
//! the regional tests run too.
//!
//! Without those, every test skips. Each test creates secrets named
//! `zigps-<random>-<what>` labelled `zig-gcp-test=1` and deletes them, even
//! when it fails; the last test sweeps up anything a crashed run left
//! behind. The principal needs Secret Manager Admin on the test project.

const std = @import("std");
const secret_manager = @import("secret_manager");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Every test secret carries this, so a sweep can find them all.
const test_label: secret_manager.Label = .{ .key = "zig-gcp-test", .value = "1" };

const Fixture = struct {
    env: std.process.Environ.Map,
    token: secret_manager.StaticToken,
    diag: secret_manager.Diagnostics,
    client: secret_manager.Client,
    arena: std.heap.ArenaAllocator,
    /// Ids to delete when the test ends, whatever happened.
    created: std.ArrayList([]const u8),
    /// "zigps-" plus 8 random hex digits, unique per test.
    prefix: [14]u8,

    /// Returns false when no project is configured; the test should skip.
    /// `regional` asks for a client in `GCP_TEST_LOCATION`, and returns
    /// false when that is unset.
    fn init(f: *Fixture, regional: bool) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        f.diag = .{};
        f.arena = .init(gpa);
        errdefer f.arena.deinit();
        f.created = .empty;

        var random: [4]u8 = undefined;
        testing.io.random(&random);
        _ = try std.fmt.bufPrint(&f.prefix, "zigps-{x}", .{random});

        const project = f.env.get("GCP_TEST_PROJECT") orelse return f.skip();
        const token = f.env.get("GCP_TEST_TOKEN") orelse return f.skip();
        const location = f.env.get("GCP_TEST_LOCATION");
        if (regional and location == null) return f.skip();
        f.token = .{ .token = std.mem.trim(u8, token, &std.ascii.whitespace) };
        f.client = try .init(gpa, testing.io, .{
            .project_id = project,
            .location = if (regional) location else null,
            .token_provider = f.token.provider(),
            .diagnostics = &f.diag,
            .user_agent = "zig-gcp-secret-manager-integration/0.1",
        });
        return true;
    }

    fn skip(f: *Fixture) bool {
        f.arena.deinit();
        f.env.deinit();
        return false;
    }

    /// Deletes everything the test created.
    fn deinit(f: *Fixture) void {
        for (f.created.items) |id| f.client.secret(id).delete() catch {};
        f.created.deinit(testing.allocator);
        f.client.deinit();
        f.arena.deinit();
        f.env.deinit();
    }

    /// A unique id for this run, such as `zigps-1a2b3c4d-access`.
    fn name(f: *Fixture, what: []const u8) ![]const u8 {
        return std.fmt.allocPrint(f.arena.allocator(), "{s}-{s}", .{ f.prefix, what });
    }

    /// Creates a labelled secret and registers it for cleanup.
    fn create(f: *Fixture, what: []const u8, config: secret_manager.SecretConfig) !secret_manager.Secret {
        const id = try f.name(what);
        var labelled = config;
        labelled.labels = &.{test_label};
        try f.created.append(testing.allocator, id);
        var created = try f.client.secret(id).create(labelled);
        created.deinit();
        return f.client.secret(id);
    }

    /// Prints the server's own words when a call fails unexpectedly.
    fn report(f: *const Fixture, err: anyerror) anyerror {
        std.debug.print("error.{t}", .{err});
        if (f.diag.http_status != 0) std.debug.print(" (HTTP {d} {s})", .{ f.diag.http_status, f.diag.status() });
        if (f.diag.message().len != 0) std.debug.print(": {s}", .{f.diag.message()});
        std.debug.print("\n", .{});
        return err;
    }
};

test "a secret's life: create, get, list by label, delete, gone" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();

    const secret = f.create("life", .{}) catch |err| return f.report(err);
    var got = secret.get() catch |err| return f.report(err);
    defer got.deinit();
    try testing.expectEqualStrings(secret.id, got.value.id());
    try testing.expectEqualStrings("1", got.value.label("zig-gcp-test").?);
    // Names come back with the project number, not the id that was sent.
    try testing.expect(std.mem.indexOf(u8, got.value.name, "/secrets/") != null);
    try testing.expect(got.value.create_time.len > 0);

    // The filter grammar the sweep depends on.
    const filter = try std.fmt.allocPrint(f.arena.allocator(), "name:{s}", .{secret.id});
    var listed = f.client.listSecrets(.{ .filter = filter }) catch |err| return f.report(err);
    defer listed.deinit();
    try testing.expectEqual(1, listed.value.secrets.len);
    try testing.expectEqualStrings(secret.id, listed.value.secrets[0].id());

    try secret.delete();
    try testing.expectError(error.NotFound, secret.get());
    // Deleting twice reports what the second attempt finds.
    try testing.expectError(error.NotFound, secret.delete());
}

test "creating the same secret twice is AlreadyExists" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();

    const secret = f.create("twice", .{}) catch |err| return f.report(err);
    try testing.expectError(error.AlreadyExists, secret.create(.{ .labels = &.{test_label} }));
}

test "a version added is a version read back, checksum and all" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();

    const secret = f.create("access", .{}) catch |err| return f.report(err);
    var added = secret.addVersion("s3cr3t") catch |err| return f.report(err);
    defer added.deinit();
    try testing.expectEqual(1, added.value.number().?);
    try testing.expectEqual(.enabled, added.value.state);
    // The server verified the checksum this client sent with the bytes.
    try testing.expect(added.value.client_specified_payload_checksum);

    var value = secret.access(.latest) catch |err| return f.report(err);
    defer value.deinit();
    try testing.expectEqualStrings("s3cr3t", value.bytes());
    try testing.expect(value.checksum_verified);
    try testing.expect(std.mem.endsWith(u8, value.version_name, "/versions/1"));
    try testing.expectEqual(1, value.versionNumber().?);
}

test "binary safety: all 256 byte values, and a trailing newline, survive" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();

    var every_byte: [256]u8 = undefined;
    for (&every_byte, 0..) |*b, i| b.* = @intCast(i);
    const secret = f.create("binary", .{}) catch |err| return f.report(err);
    var added = secret.addVersion(&every_byte) catch |err| return f.report(err);
    added.deinit();

    var value = secret.access(.latest) catch |err| return f.report(err);
    defer value.deinit();
    try testing.expectEqualSlices(u8, &every_byte, value.bytes());
    try testing.expect(value.checksum_verified);

    // The library trims nothing: a secret written with `echo` keeps its
    // newline.
    var second = secret.addVersion("from-echo\n") catch |err| return f.report(err);
    second.deinit();
    var newline = secret.access(.latest) catch |err| return f.report(err);
    defer newline.deinit();
    try testing.expectEqualStrings("from-echo\n", newline.bytes());
}

test "versions stack up: latest moves, numbers do not" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();

    const secret = f.create("versions", .{}) catch |err| return f.report(err);
    var first = secret.addVersion("first") catch |err| return f.report(err);
    first.deinit();
    var second = secret.addVersion("second") catch |err| return f.report(err);
    defer second.deinit();
    try testing.expectEqual(2, second.value.number().?);

    var latest = secret.access(.latest) catch |err| return f.report(err);
    defer latest.deinit();
    try testing.expectEqualStrings("second", latest.bytes());
    try testing.expectEqual(2, latest.versionNumber().?);

    var one = secret.access(.{ .number = 1 }) catch |err| return f.report(err);
    defer one.deinit();
    try testing.expectEqualStrings("first", one.bytes());
}

test "disable, access, enable: a version can be taken out of service" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();

    const secret = f.create("disable", .{}) catch |err| return f.report(err);
    var added = secret.addVersion("s3cr3t") catch |err| return f.report(err);
    added.deinit();
    const version = secret.version(.{ .number = 1 });

    var off = version.disable() catch |err| return f.report(err);
    defer off.deinit();
    try testing.expectEqual(.disabled, off.value.state);
    // Production answers FAILED_PRECONDITION, with HTTP 400.
    try testing.expectError(error.FailedPrecondition, secret.access(.{ .number = 1 }));
    try testing.expectEqual(400, f.diag.http_status);

    var on = version.enable() catch |err| return f.report(err);
    defer on.deinit();
    try testing.expectEqual(.enabled, on.value.state);
    var value = secret.access(.{ .number = 1 }) catch |err| return f.report(err);
    defer value.deinit();
    try testing.expectEqualStrings("s3cr3t", value.bytes());

    // Both are idempotent: production answers 200 and the same state, so a
    // lost answer costs nothing to ask again.
    var again = version.enable() catch |err| return f.report(err);
    defer again.deinit();
    try testing.expectEqual(.enabled, again.value.state);
    var off_again = version.disable() catch |err| return f.report(err);
    defer off_again.deinit();
    var off_twice = version.disable() catch |err| return f.report(err);
    defer off_twice.deinit();
    try testing.expectEqual(.disabled, off_twice.value.state);
}

test "destroy: the bytes go, the version stays" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();

    const secret = f.create("destroy", .{}) catch |err| return f.report(err);
    var added = secret.addVersion("s3cr3t") catch |err| return f.report(err);
    added.deinit();
    const version = secret.version(.{ .number = 1 });

    var gone = version.destroy() catch |err| return f.report(err);
    defer gone.deinit();
    try testing.expectEqual(.destroyed, gone.value.state);
    try testing.expect(gone.value.destroy_time.len > 0);
    try testing.expectError(error.FailedPrecondition, secret.access(.{ .number = 1 }));

    var got = version.get() catch |err| return f.report(err);
    defer got.deinit();
    try testing.expectEqual(.destroyed, got.value.state);
    try testing.expect(got.value.destroy_time.len > 0);

    // Destroying is the one state change that is not idempotent: the
    // second attempt says the first one worked.
    try testing.expectError(error.FailedPrecondition, version.destroy());
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "already DESTROYED") != null);
    // Nothing brings a destroyed version back, either.
    try testing.expectError(error.FailedPrecondition, version.enable());
}

test "the payload limit is exactly 65,536 bytes" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();

    const gpa = testing.allocator;
    const payload = try gpa.alloc(u8, secret_manager.limits.max_payload_bytes + 1);
    defer gpa.free(payload);
    // Not one repeated byte: a checksum over a uniform payload proves less.
    for (payload, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

    const secret = f.create("limit", .{}) catch |err| return f.report(err);
    var added = secret.addVersion(payload[0..secret_manager.limits.max_payload_bytes]) catch |err| return f.report(err);
    added.deinit();
    var value = secret.access(.latest) catch |err| return f.report(err);
    defer value.deinit();
    try testing.expectEqualSlices(u8, payload[0..secret_manager.limits.max_payload_bytes], value.bytes());
    try testing.expect(value.checksum_verified);

    // One byte more never leaves this process.
    try testing.expectError(error.PayloadTooLarge, secret.addVersion(payload));
    try testing.expectError(error.EmptyPayload, secret.addVersion(""));
}

test "paging: listVersions walks the pages and stops" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();

    const secret = f.create("paging", .{}) catch |err| return f.report(err);
    for (0..5) |i| {
        var buf: [16]u8 = undefined;
        var added = secret.addVersion(try std.fmt.bufPrint(&buf, "value-{d}", .{i})) catch |err| return f.report(err);
        added.deinit();
    }

    var seen: usize = 0;
    var pages: usize = 0;
    var token: ?[]const u8 = null;
    while (true) {
        var page = secret.listVersions(.{ .page_size = 2, .page_token = token }) catch |err| return f.report(err);
        defer page.deinit();
        pages += 1;
        seen += page.value.versions.len;
        try testing.expect(page.value.versions.len <= 2);
        for (page.value.versions) |version| try testing.expect(version.number() != null);
        const next = page.value.next_page_token orelse break;
        // The token points into the page, which is freed at the end of this
        // iteration.
        token = try f.arena.allocator().dupe(u8, next);
        try testing.expect(pages < 10);
    }
    try testing.expectEqual(5, seen);
    try testing.expectEqual(3, pages);
}

test "user-managed replication: two locations, one usable secret" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();

    const secret = f.create("replicated", .{
        .replication = .{ .user_managed = &.{ "europe-west1", "us-east1" } },
    }) catch |err| return f.report(err);
    var added = secret.addVersion("s3cr3t") catch |err| return f.report(err);
    added.deinit();
    var value = secret.access(.latest) catch |err| return f.report(err);
    defer value.deinit();
    try testing.expectEqualStrings("s3cr3t", value.bytes());
}

test "regional: its own namespace, on its own host" {
    var f: Fixture = undefined;
    if (!try f.init(true)) return error.SkipZigTest;
    defer f.deinit();

    const secret = f.create("regional", .{}) catch |err| return f.report(err);
    var added = secret.addVersion("s3cr3t") catch |err| return f.report(err);
    defer added.deinit();
    try testing.expectEqual(1, added.value.number().?);
    var value = secret.access(.latest) catch |err| return f.report(err);
    defer value.deinit();
    try testing.expectEqualStrings("s3cr3t", value.bytes());
    try testing.expect(value.checksum_verified);
    // The name carries the location the secret lives in.
    try testing.expect(std.mem.indexOf(u8, value.version_name, "/locations/") != null);

    var got = secret.get() catch |err| return f.report(err);
    defer got.deinit();
    try testing.expectEqualStrings(secret.id, got.value.id());

    // A global client cannot see it: the two are separate namespaces.
    var global: secret_manager.Client = try .init(testing.allocator, testing.io, .{
        .project_id = f.client.project_id,
        .token_provider = f.token.provider(),
    });
    defer global.deinit();
    try testing.expectError(error.NotFound, global.secret(secret.id).get());
}

test "sweep: delete anything a crashed run left behind" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();

    // Only this project's test secrets, by the label every one of them
    // carries. A secret that is not ours is never touched.
    const filter = try std.fmt.allocPrint(
        f.arena.allocator(),
        "labels.{s}={s}",
        .{ test_label.key, test_label.value },
    );
    var deleted: usize = 0;
    var page = f.client.listSecrets(.{ .page_size = 100, .filter = filter }) catch |err| return f.report(err);
    defer page.deinit();
    for (page.value.secrets) |info| {
        const id = info.id();
        // Leave this run's own secrets alone; their tests clean up after
        // themselves.
        if (std.mem.startsWith(u8, id, &f.prefix)) continue;
        if (!std.mem.startsWith(u8, id, "zigps-")) continue;
        f.client.secret(id).delete() catch continue;
        deleted += 1;
    }
    if (deleted > 0) std.debug.print("swept {d} leftover test secret(s)\n", .{deleted});
}
