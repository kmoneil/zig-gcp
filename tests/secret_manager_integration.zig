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
//! Set GCP_TEST_KMS_KEY to a Cloud KMS key named in full, on which the
//! project's Secret Manager service agent holds
//! roles/cloudkms.cryptoKeyEncrypterDecrypter, and the key tests run too:
//! automatic replication for a key in `global`, otherwise a user-managed
//! replica in the key's location, and a regional secret when that is
//! GCP_TEST_LOCATION. Keys cost money by the month, so none is assumed.
//!
//! Without those, every test skips. Each test creates secrets named
//! `zigps-<random>-<what>` labelled `zig-gcp-test=1` and deletes them, even
//! when it fails; the last test sweeps up anything a crashed run left
//! behind. The principal needs Secret Manager Admin on the test project.

const std = @import("std");
const secret_manager = @import("secret_manager");
const pubsub = @import("pubsub");
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
        return f.arena.allocator().print("{s}-{s}", .{ f.prefix, what });
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

    /// Waits for `access` of `ref` to fail with `want`. A version's state is
    /// eventually consistent for access: measured on 2026-10-02, a version
    /// disabled moments before was still served, twice in one run, and
    /// refused on the next try. Allows a minute.
    fn expectAccessRefused(f: *Fixture, secret: secret_manager.Secret, ref: secret_manager.VersionRef, want: anyerror) !void {
        var tries: usize = 0;
        while (true) : (tries += 1) {
            if (secret.access(ref)) |served| {
                var v = served;
                v.deinit();
                if (tries == 60) return error.TestStillServed;
                try testing.io.sleep(.fromSeconds(1), .awake);
            } else |err| {
                if (err != want) return f.report(err);
                return;
            }
        }
    }

    /// Waits for `access` of `ref` to serve `bytes`, as above.
    fn expectAccessServed(f: *Fixture, secret: secret_manager.Secret, ref: secret_manager.VersionRef, bytes: []const u8) !void {
        var tries: usize = 0;
        while (true) : (tries += 1) {
            if (secret.access(ref)) |served| {
                var v = served;
                defer v.deinit();
                try testing.expectEqualStrings(bytes, v.bytes());
                return;
            } else |err| {
                if (err != error.FailedPrecondition or tries == 60) return f.report(err);
                try testing.io.sleep(.fromSeconds(1), .awake);
            }
        }
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
    const filter = try f.arena.allocator().print("name:{s}", .{secret.id});
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
    try f.expectAccessRefused(secret, .{ .number = 1 }, error.FailedPrecondition);
    try testing.expectEqual(400, f.diag.http_status);

    var on = version.enable() catch |err| return f.report(err);
    defer on.deinit();
    try testing.expectEqual(.enabled, on.value.state);
    try f.expectAccessServed(secret, .{ .number = 1 }, "s3cr3t");

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
        .replication = .{ .user_managed = &.{ .{ .location = "europe-west1" }, .{ .location = "us-east1" } } },
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

/// A secret's IAM, end to end: the member is the project's Cloud Storage
/// service agent, whose address the project's number gives, and the
/// secret's own name gives the number.
fn iamCycle(f: *Fixture, secret: secret_manager.Secret) !void {
    const a = f.arena.allocator();
    var info = secret.get() catch |err| return f.report(err);
    defer info.deinit();
    var parts = std.mem.splitScalar(u8, info.value.name, '/');
    _ = parts.next();
    const number = parts.next().?;
    const member = try a.print("serviceAccount:service-{s}@gs-project-accounts.iam.gserviceaccount.com", .{number});
    const shouting = try a.print("serviceAccount:{s}", .{try std.ascii.allocUpperString(a, member["serviceAccount:".len..])});
    const role = "roles/secretmanager.secretAccessor";

    var fresh = secret.iamPolicy() catch |err| return f.report(err);
    defer fresh.deinit();
    try testing.expectEqualStrings("ACAB", fresh.value.etag.?);
    try testing.expectEqual(0, fresh.value.bindings.len);

    var granted = secret.addIamBinding(role, member) catch |err| return f.report(err);
    defer granted.deinit();
    try testing.expect(granted.value.grants(role, member));
    // Held already, asked in capitals: nothing written, so the etag stands.
    var again = secret.addIamBinding(role, shouting) catch |err| return f.report(err);
    defer again.deinit();
    try testing.expectEqualStrings(granted.value.etag.?, again.value.etag.?);

    var held = secret.testIamPermissions(&.{ "secretmanager.secrets.get", "secretmanager.versions.access" }) catch |err| return f.report(err);
    defer held.deinit();
    try testing.expectEqual(2, held.value.len);

    // A condition, written as version 3 by itself.
    var current = secret.iamPolicy() catch |err| return f.report(err);
    defer current.deinit();
    var conditional = current.value;
    conditional.bindings = try std.mem.concat(a, secret_manager.iam.Binding, &.{ current.value.bindings, &.{.{
        .role = "roles/secretmanager.viewer",
        .members = &.{member},
        .condition = "{\"title\":\"until 2030\",\"expression\":\"request.time < timestamp(\\\"2030-01-01T00:00:00Z\\\")\"}",
    }} });
    var conditioned = secret.setIamPolicy(conditional) catch |err| return f.report(err);
    defer conditioned.deinit();
    try testing.expectEqual(3, conditioned.value.version);
    try testing.expect(conditioned.value.hasConditions());

    var revoked = secret.removeIamBinding(role, shouting) catch |err| return f.report(err);
    defer revoked.deinit();
    try testing.expect(!revoked.value.grants(role, member));
    // The conditional binding stays.
    try testing.expect(revoked.value.hasConditions());
    var gone = secret.removeIamBinding(role, member) catch |err| return f.report(err);
    defer gone.deinit();
    try testing.expectEqualStrings(revoked.value.etag.?, gone.value.etag.?);

    // A write under an etag another write has moved on is Aborted.
    var stale = secret.iamPolicy() catch |err| return f.report(err);
    defer stale.deinit();
    var first = secret.setIamPolicy(try secret_manager.iam.withMember(a, stale.value, role, member)) catch |err| return f.report(err);
    first.deinit();
    try testing.expectError(error.Aborted, secret.setIamPolicy(try secret_manager.iam.withMember(a, stale.value, "roles/secretmanager.secretVersionManager", member)));

    // A secret that does not exist: none held, not NotFound.
    var none = f.client.secret(try f.name("missing")).testIamPermissions(&.{"secretmanager.secrets.get"}) catch |err| return f.report(err);
    defer none.deinit();
    try testing.expectEqual(0, none.value.len);
}

test "IAM: a secret's policy granted once in any case, tested, conditional, revoked, and stale" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();
    const secret = f.create("iam", .{}) catch |err| return f.report(err);
    try iamCycle(&f, secret);
}

test "regional: IAM on a regional secret, as on a global one" {
    var f: Fixture = undefined;
    if (!try f.init(true)) return error.SkipZigTest;
    defer f.deinit();
    const secret = f.create("iam-regional", .{}) catch |err| return f.report(err);
    try iamCycle(&f, secret);
}

/// Update, read back and clear every setting milestone 1 adds, and the
/// refusal production makes that the library cannot: an alias to a
/// version the secret does not have.
fn updateCycle(f: *Fixture) !void {
    const secret = try f.create("update", .{});
    for ([_][]const u8{ "v1", "v2" }) |data| {
        var added = secret.addVersion(data) catch |err| return f.report(err);
        added.deinit();
    }
    var set = secret.update(.{
        .labels = .{ .set = &.{ test_label, .{ .key = "team", .value = "payments" } } },
        .annotations = .{ .set = &.{ .{ .key = "Owner", .value = "Ann <ann@example.com>" }, .{ .key = &@as([64]u8, @splat('a')), .value = "line\nbreak" } } },
        .aliases = .{ .set = &.{ .{ .name = "prod", .version = 2 }, .{ .name = "Prod", .version = 1 }, .{ .name = "Latest", .version = 1 } } },
        .expiry = .{ .set = .{ .after_s = 86_400 } },
        .version_destroy_delay_s = .{ .set = 86_400 },
    }) catch |err| return f.report(err);
    defer set.deinit();
    try testing.expectEqualStrings("payments", set.value.label("team").?);
    try testing.expectEqualStrings("Ann <ann@example.com>", set.value.annotation("Owner").?);
    try testing.expectEqualStrings("line\nbreak", set.value.annotation(&@as([64]u8, @splat('a'))).?);
    try testing.expectEqual(2, set.value.alias("prod").?);
    try testing.expectEqual(1, set.value.alias("Prod").?);
    try testing.expect(set.value.expire_time.len > 0);
    try testing.expectEqual(86_400, set.value.version_destroy_delay_s.?);

    var read = secret.get() catch |err| return f.report(err);
    defer read.deinit();
    try testing.expectEqualStrings(set.value.etag, read.value.etag);
    try testing.expectEqualStrings(set.value.expire_time, read.value.expire_time);

    try testing.expectError(error.InvalidArgument, secret.update(.{ .aliases = .{ .set = &.{.{ .name = "next", .version = 3 }} } }));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "don't exist") != null);

    var cleared = secret.update(.{
        .annotations = .clear,
        .aliases = .clear,
        .expiry = .clear,
        .version_destroy_delay_s = .clear,
    }) catch |err| return f.report(err);
    defer cleared.deinit();
    try testing.expectEqual(0, cleared.value.annotations.len);
    try testing.expectEqual(0, cleared.value.aliases.len);
    try testing.expectEqualStrings("", cleared.value.expire_time);
    try testing.expectEqual(null, cleared.value.version_destroy_delay_s);
    // What the update left alone stays.
    try testing.expectEqualStrings("payments", cleared.value.label("team").?);

    // An expiry given as a time is read back as that time.
    var timed = secret.update(.{ .expiry = .{ .set = .{ .at = "2100-01-01T09:00:00-05:00" } } }) catch |err| return f.report(err);
    defer timed.deinit();
    try testing.expectEqualStrings("2100-01-01T14:00:00Z", timed.value.expire_time);
}

test "update: every setting set, read back and cleared" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();
    try updateCycle(&f);
}

test "regional: update, as on a global secret" {
    var f: Fixture = undefined;
    if (!try f.init(true)) return error.SkipZigTest;
    defer f.deinit();
    try updateCycle(&f);
}

/// A write under an etag read before another change is `error.Aborted`,
/// and changes nothing; under the current etag it goes through.
fn preconditionCycle(f: *Fixture) !void {
    const secret = try f.create("precondition", .{});
    var added = secret.addVersion("v1") catch |err| return f.report(err);
    defer added.deinit();
    var first = secret.get() catch |err| return f.report(err);
    defer first.deinit();
    var moved = secret.update(.{ .labels = .{ .set = &.{ test_label, .{ .key = "step", .value = "1" } } }, .etag = first.value.etag }) catch |err| return f.report(err);
    defer moved.deinit();
    try testing.expect(!std.mem.eql(u8, first.value.etag, moved.value.etag));

    try testing.expectError(error.Aborted, secret.update(.{ .labels = .{ .set = &.{test_label} }, .etag = first.value.etag }));
    try testing.expect(std.mem.startsWith(u8, f.diag.message(), "The etag provided"));
    try testing.expectError(error.Aborted, secret.deleteIf(first.value.etag));
    var still = secret.get() catch |err| return f.report(err);
    defer still.deinit();
    try testing.expectEqualStrings("1", still.value.label("step").?);

    const v = secret.version(.{ .number = 1 });
    var disabled = v.disableIf(added.value.etag) catch |err| return f.report(err);
    defer disabled.deinit();
    try testing.expectEqual(.disabled, disabled.value.state);
    try testing.expectError(error.Aborted, v.enableIf(added.value.etag));
    try testing.expectError(error.Aborted, v.destroyIf(added.value.etag));
    var enabled = v.enableIf(disabled.value.etag) catch |err| return f.report(err);
    defer enabled.deinit();
    try testing.expectEqual(.enabled, enabled.value.state);
    // A version's changes leave the secret's etag where it was.
    var after = secret.get() catch |err| return f.report(err);
    defer after.deinit();
    try testing.expectEqualStrings(moved.value.etag, after.value.etag);

    secret.deleteIf(after.value.etag) catch |err| return f.report(err);
    try testing.expectError(error.NotFound, secret.get());
}

test "preconditions: a stale etag is Aborted on update, deleteIf, enableIf, disableIf and destroyIf" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();
    try preconditionCycle(&f);
}

test "regional: preconditions, as on a global secret" {
    var f: Fixture = undefined;
    if (!try f.init(true)) return error.SkipZigTest;
    defer f.deinit();
    try preconditionCycle(&f);
}

test "aliases: access through them, case and all, and a move seen" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();
    const secret = try f.create("alias", .{});
    for ([_][]const u8{ "one", "two" }) |data| {
        var added = secret.addVersion(data) catch |err| return f.report(err);
        added.deinit();
    }
    var set = secret.update(.{ .aliases = .{ .set = &.{ .{ .name = "prod", .version = 1 }, .{ .name = "Prod", .version = 2 } } } }) catch |err| return f.report(err);
    set.deinit();
    {
        var lower = secret.access(.{ .alias = "prod" }) catch |err| return f.report(err);
        defer lower.deinit();
        try testing.expectEqualStrings("one", lower.bytes());
        var upper = secret.access(.{ .alias = "Prod" }) catch |err| return f.report(err);
        defer upper.deinit();
        try testing.expectEqualStrings("two", upper.bytes());
    }
    try testing.expectError(error.NotFound, secret.access(.{ .alias = "stable" }));

    var moved = secret.update(.{ .aliases = .{ .set = &.{.{ .name = "prod", .version = 2 }} } }) catch |err| return f.report(err);
    moved.deinit();
    // Production served the new version on the first try when measured;
    // the docs call aliases eventually consistent, so allow a minute.
    var tries: usize = 0;
    while (true) : (tries += 1) {
        var value = secret.access(.{ .alias = "prod" }) catch |err| return f.report(err);
        defer value.deinit();
        if (std.mem.eql(u8, value.bytes(), "two")) break;
        if (tries == 60) return error.TestAliasNeverMoved;
        try testing.io.sleep(.fromSeconds(1), .awake);
    }
}

test "delayed destruction: scheduled, refused a second time, cancelled" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();
    const secret = try f.create("delay", .{ .version_destroy_delay_s = 86_400 });
    var added = secret.addVersion("v1") catch |err| return f.report(err);
    added.deinit();
    const v = secret.version(.{ .number = 1 });
    var scheduled = v.destroy() catch |err| return f.report(err);
    defer scheduled.deinit();
    try testing.expectEqual(.disabled, scheduled.value.state);
    try testing.expect(scheduled.value.scheduled_destroy_time.len > 0);
    try testing.expectEqualStrings("", scheduled.value.destroy_time);
    try testing.expectError(error.FailedPrecondition, v.destroy());
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "already scheduled") != null);
    try f.expectAccessRefused(secret, .{ .number = 1 }, error.FailedPrecondition);
    var back = v.enable() catch |err| return f.report(err);
    defer back.deinit();
    try testing.expectEqual(.enabled, back.value.state);
    try testing.expectEqualStrings("", back.value.scheduled_destroy_time);
    try f.expectAccessServed(secret, .{ .number = 1 }, "v1");
}

test "serviceAgent: the project's Secret Manager service agent" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();
    var agent = f.client.serviceAgent() catch |err| return f.report(err);
    defer agent.deinit();
    try testing.expect(std.mem.startsWith(u8, agent.value, "service-"));
    try testing.expect(std.mem.endsWith(u8, agent.value, "@gcp-sa-secretmanager.iam.gserviceaccount.com"));
}

/// A topic and a subscription on it, both deleted when the test ends.
const Topic = struct {
    ps: pubsub.Client,
    diag: pubsub.Diagnostics,
    id: []const u8,
    sub_id: []const u8,
    name: []const u8,

    fn init(t: *Topic, f: *Fixture) !void {
        const project = f.env.get("GCP_TEST_PROJECT").?;
        t.diag = .{};
        t.id = try f.name("topic");
        t.sub_id = try f.name("watch");
        t.name = try f.arena.allocator().print("projects/{s}/topics/{s}", .{ project, t.id });
        t.ps = try .init(testing.allocator, testing.io, .{ .project_id = project, .token_provider = f.token.provider(), .diagnostics = &t.diag });
        errdefer t.ps.deinit();
        var topic = try t.ps.topic(t.id).create(.{});
        topic.deinit();
        var sub = try t.ps.subscription(t.sub_id).create(.{ .topic_id = t.id });
        sub.deinit();
    }

    fn deinit(t: *Topic) void {
        t.ps.subscription(t.sub_id).delete() catch {};
        t.ps.topic(t.id).delete() catch {};
        t.ps.deinit();
    }

    /// Grants the Secret Manager agent publisher on the topic.
    fn grant(t: *Topic, f: *Fixture) !void {
        var agent = f.client.serviceAgent() catch |err| return f.report(err);
        defer agent.deinit();
        const member = try f.arena.allocator().print("serviceAccount:{s}", .{agent.value});
        var policy = try t.ps.topic(t.id).addIamBinding("roles/pubsub.publisher", member);
        policy.deinit();
    }
};

test "regional: topics refused before the grant, then every event received and decoded" {
    var f: Fixture = undefined;
    if (!try f.init(true)) return error.SkipZigTest;
    defer f.deinit();
    var t: Topic = undefined;
    t.init(&f) catch |err| return f.report(err);
    defer t.deinit();

    const id = try f.name("events");
    try f.created.append(testing.allocator, id);
    const secret = f.client.secret(id);
    const config: secret_manager.SecretConfig = .{ .labels = &.{test_label}, .topics = &.{t.name} };
    try testing.expectError(error.TopicNotPublishable, secret.create(config));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "roles/pubsub.publisher") != null);

    try t.grant(&f);
    // A grant reached Secret Manager within a second when measured.
    var tries: usize = 0;
    var created = while (true) : (tries += 1) {
        break secret.create(config) catch |err| {
            if (err != error.TopicNotPublishable or tries == 30) return f.report(err);
            try testing.io.sleep(.fromSeconds(2), .awake);
            continue;
        };
    };
    created.deinit();
    var added = secret.addVersion("v1") catch |err| return f.report(err);
    added.deinit();
    var updated = secret.update(.{ .labels = .{ .set = &.{ test_label, .{ .key = "step", .value = "2" } } } }) catch |err| return f.report(err);
    updated.deinit();
    secret.delete() catch |err| return f.report(err);

    // A regional secret's events came within a second when measured.
    const want = [_]secret_manager.EventKind{ .secret_create, .version_add, .secret_update, .secret_delete };
    var got: [want.len]bool = @splat(false);
    var rounds: usize = 0;
    while (!std.mem.allEqual(bool, &got, true) and rounds < 30) : (rounds += 1) {
        var pulled = try t.ps.subscription(t.sub_id).pull(.{ .return_immediately = true });
        defer pulled.deinit();
        var acks: std.ArrayList([]const u8) = .empty;
        defer acks.deinit(testing.allocator);
        for (pulled.value.messages) |m| {
            try acks.append(testing.allocator, m.ack_id);
            var event = secret_manager.decodeEvent(testing.allocator, m, .{}) catch |err| return f.report(err);
            defer event.deinit();
            const e = event.value;
            if (e.kind == .topic_configured) continue;
            try testing.expectEqualStrings(id, e.secretId());
            try testing.expectEqualStrings(f.env.get("GCP_TEST_LOCATION").?, e.location.?);
            for (want, 0..) |kind, k| if (e.kind == kind) {
                got[k] = true;
            };
            switch (e.kind) {
                .version_add => {
                    try testing.expectEqual(1, e.version.?);
                    try testing.expectEqual(.enabled, e.version_info.?.state);
                },
                .secret_update => try testing.expectEqualStrings("2", e.info.?.label("step").?),
                .secret_delete => try testing.expectEqual(.requested, e.delete_type.?),
                else => {},
            }
        }
        if (acks.items.len > 0) try t.ps.subscription(t.sub_id).ack(acks.items);
        if (!std.mem.allEqual(bool, &got, true)) try testing.io.sleep(.fromSeconds(2), .awake);
    }
    try testing.expect(std.mem.allEqual(bool, &got, true));
}

test "rotation: set beside a topic, read back, cleared" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();
    var t: Topic = undefined;
    t.init(&f) catch |err| return f.report(err);
    defer t.deinit();
    try t.grant(&f);

    const secret = try f.create("rotation", .{});
    var tries: usize = 0;
    var set = while (true) : (tries += 1) {
        break secret.update(.{
            .topics = .{ .set = &.{t.name} },
            .rotation = .{ .set = .{ .next_time = "2100-01-01T00:00:00Z", .period_s = 2_592_000 } },
        }) catch |err| {
            if (err != error.TopicNotPublishable or tries == 30) return f.report(err);
            try testing.io.sleep(.fromSeconds(2), .awake);
            continue;
        };
    };
    defer set.deinit();
    try testing.expectEqualStrings(t.name, set.value.topics[0]);
    try testing.expectEqualStrings("2100-01-01T00:00:00Z", set.value.rotation.?.next_time);
    // The discovery document calls the period input only; it is read back.
    try testing.expectEqual(2_592_000, set.value.rotation.?.period_s.?);

    // Topics cannot go while a rotation needs them.
    try testing.expectError(error.InvalidArgument, secret.update(.{ .topics = .clear }));
    var cleared = secret.update(.{ .rotation = .clear, .topics = .clear }) catch |err| return f.report(err);
    defer cleared.deinit();
    try testing.expectEqual(null, cleared.value.rotation);
    try testing.expectEqual(0, cleared.value.topics.len);
}

/// A secret under `key` stores, reads and records its key version; one
/// cleared of its key wraps new versions in Google's keys.
fn keyCycle(f: *Fixture, config: secret_manager.SecretConfig, key: []const u8, what: []const u8) !void {
    const secret = try f.create(what, config);
    var info = secret.get() catch |err| return f.report(err);
    defer info.deinit();
    if (config.kms_key != null) {
        try testing.expectEqualStrings(key, info.value.kms_key.?);
    } else {
        try testing.expectEqualStrings(key, info.value.replicas[0].kms_key.?);
    }
    var added = secret.addVersion("wrapped") catch |err| return f.report(err);
    defer added.deinit();
    try testing.expectEqual(1, added.value.kms_key_versions.len);
    try testing.expect(std.mem.startsWith(u8, added.value.kms_key_versions[0].name, key));
    var value = secret.access(.{ .number = 1 }) catch |err| return f.report(err);
    defer value.deinit();
    try testing.expectEqualStrings("wrapped", value.bytes());

    var cleared = (if (config.kms_key != null)
        secret.update(.{ .kms_key = .clear })
    else
        secret.update(.{ .replica_keys = &.{.{ .location = config.replication.user_managed[0].location }} })) catch |err| return f.report(err);
    defer cleared.deinit();
    var plain = secret.addVersion("plain") catch |err| return f.report(err);
    defer plain.deinit();
    try testing.expectEqual(0, plain.value.kms_key_versions.len);
    // The first version keeps the key version that wrapped it.
    var first = secret.version(.{ .number = 1 }).get() catch |err| return f.report(err);
    defer first.deinit();
    try testing.expectEqual(1, first.value.kms_key_versions.len);
}

test "keys: a secret under GCP_TEST_KMS_KEY, global and regional" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();
    const key = f.env.get("GCP_TEST_KMS_KEY") orelse return error.SkipZigTest;
    var parts = std.mem.splitScalar(u8, key, '/');
    for (0..3) |_| _ = parts.next();
    const location = parts.next() orelse return error.TestBadKmsKey;
    if (std.mem.eql(u8, location, "global")) {
        try keyCycle(&f, .{ .kms_key = key }, key, "key-auto");
    } else {
        try keyCycle(&f, .{ .replication = .{ .user_managed = &.{.{ .location = location, .kms_key = key }} } }, key, "key-um");
        if (f.env.get("GCP_TEST_LOCATION")) |regional_location| if (std.mem.eql(u8, regional_location, location)) {
            var r: Fixture = undefined;
            if (!try r.init(true)) return;
            defer r.deinit();
            try keyCycle(&r, .{ .kms_key = key }, key, "key-reg");
        };
    }
}

test "sweep: delete anything a crashed run left behind" {
    var f: Fixture = undefined;
    if (!try f.init(false)) return error.SkipZigTest;
    defer f.deinit();

    // Only this project's test secrets, by the label every one of them
    // carries. A secret that is not ours is never touched.
    const filter = try f.arena.allocator().print(
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
