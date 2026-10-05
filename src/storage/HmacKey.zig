//! A cheap handle on one HMAC key, by its access ID: what S3-style tools,
//! signed URLs and POST policies authenticate with in place of an RSA key.
//! Making one sends nothing. `Client.createHmacKey` makes a key and
//! `Client.listHmacKeys` finds them.
//!
//! Measured in production on 2026-10-05:
//!
//! - A key is ACTIVE when made, and signs at once: a URL signed with one
//!   0.2 s old worked. An account holds at most 10 keys that are not
//!   deleted, inactive ones included; the eleventh is 400 "Service account
//!   HMAC key limit reached", and a delete frees a slot at once.
//! - Only ACTIVE and INACTIVE may be set. A change to the state a key has
//!   already is 400 "Update must modify the credential.", and here a
//!   success, since the key is as asked. A stale etag is 412, checked
//!   first: so a repeat of a change that landed meets the etag its own
//!   change moved, and a read of the key tells whether it is as asked.
//! - Only an INACTIVE key may be deleted, at once after deactivation. A
//!   deleted key is still read, as DELETED, and listed with
//!   `show_deleted`; deleting it again is 400 "Key is already deleted.",
//!   here a success.
//! - A deactivated key's signatures were refused, 401 `KeyInactive`,
//!   within 5 minutes; Google documents up to 3.

const HmacKey = @This();

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;

/// Borrowed; the handle must not outlive it.
client: *Client,
/// Borrowed; the handle must not outlive it.
access_id: []const u8,
/// The project that owns the key's service account. Null:
/// `Options.project_id`. Borrowed.
project: ?[]const u8 = null,

pub const StateOptions = struct {
    /// Change the key only while its etag is this: what makes the change
    /// safe to retry. A stale one is `error.FailedPrecondition`, unless
    /// the key is already as asked, as it is after a repeat of a change
    /// that landed.
    etag: ?[]const u8 = null,
};

/// The key's metadata, a deleted key's included for a while after.
/// `error.NotFound` for a key the project does not have.
pub fn get(self: HmacKey) Error!types.Owned(types.HmacKeyInfo) {
    rpc.begin(self.client);
    return self.read();
}

/// Makes the key ACTIVE or INACTIVE, and answers it as it then is. A key
/// already in that state is answered as read: the change holds either
/// way. Retried only under `options.etag`. A deactivated key's signatures
/// are refused within minutes.
pub fn setState(self: HmacKey, state: types.HmacKeyState, options: StateOptions) Error!types.Owned(types.HmacKeyInfo) {
    rpc.begin(self.client);
    var copy: Client = undefined;
    var local: core.Diagnostics = .{};
    return self.heard(&copy, &local).changeState(state, options);
}

/// Deletes the key, which must be INACTIVE first: an ACTIVE one is
/// `error.InvalidArgument`, in Cloud Storage's words. Retried: a repeat of
/// a delete that landed finds the key deleted, which is done.
pub fn delete(self: HmacKey) Error!void {
    rpc.begin(self.client);
    var copy: Client = undefined;
    var local: core.Diagnostics = .{};
    return self.heard(&copy, &local).remove();
}

/// Makes the key INACTIVE, then deletes it, back to back, as production
/// allows. A key deleted already is done.
pub fn deactivateAndDelete(self: HmacKey) Error!void {
    rpc.begin(self.client);
    var copy: Client = undefined;
    var local: core.Diagnostics = .{};
    const key = self.heard(&copy, &local);
    var inactive = key.changeState(.inactive, .{}) catch |err| {
        if (err == error.InvalidArgument and key.said("Deleted keys cannot be updated")) return;
        return err;
    };
    inactive.deinit();
    return key.remove();
}

/// This handle on a client that keeps diagnostics: `copy`, with `local`,
/// when its own keeps none, since what a refusal says decides whether it
/// is one. The copy owns nothing and must not outlive the call.
fn heard(self: HmacKey, copy: *Client, local: *core.Diagnostics) HmacKey {
    if (self.client.diagnostics != null) return self;
    copy.* = self.client.*;
    copy.diagnostics = local;
    var key = self;
    key.client = copy;
    return key;
}

fn read(self: HmacKey) Error!types.Owned(types.HmacKeyInfo) {
    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    const path = try self.keyPath(scratch.allocator());
    var result: types.Owned(types.HmacKeyInfo) = try .init(self.client.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self.client, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeHmacKeyInfo(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(self.client, err, "HMAC key");
    return result;
}

fn changeState(self: HmacKey, state: types.HmacKeyState, options: StateOptions) Error!types.Owned(types.HmacKeyInfo) {
    const name = codec.hmacStateName(state) orelse {
        if (self.client.diagnostics) |d| d.print("a key is made ACTIVE or INACTIVE; delete deletes it", .{});
        return error.InvalidArgument;
    };
    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    const path = try self.keyPath(scratch.allocator());
    const body = try codec.encodeHmacUpdate(scratch.allocator(), name, options.etag);
    var result: types.Owned(types.HmacKeyInfo) = try .init(self.client.gpa);
    errdefer result.deinit();
    const response = rpc.execute(self.client, result.arena, .{
        .method = .PUT,
        .path = path,
        .body = body,
        // A repeat of a change that landed is refused as no change, which
        // is answered below; without an etag it could undo another
        // writer's change made in between.
        .retry = options.etag != null or self.client.retry_unconditional_writes,
    }) catch |err| {
        // The key is already as asked: no change to make.
        if (err == error.InvalidArgument and self.said("Update must modify the credential")) {
            result.deinit();
            return self.read();
        }
        // The etag moved: by another writer, or by this change itself,
        // landed with its answer lost. The key's state tells them apart
        // where it matters.
        if (err == error.FailedPrecondition and options.etag != null) {
            var current = self.read() catch return err;
            const now = current.value.state;
            if (now == state) {
                result.deinit();
                return current;
            }
            current.deinit();
            if (self.client.diagnostics) |d| d.print("the etag is stale: the key changed since it was read, and is {t}", .{now});
        }
        return err;
    };
    result.value = codec.decodeHmacKeyInfo(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(self.client, err, "HMAC key");
    return result;
}

fn remove(self: HmacKey) Error!void {
    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    const path = try self.keyPath(scratch.allocator());
    rpc.executeDiscard(self.client, .{ .method = .DELETE, .path = path, .retry = true }) catch |err| {
        if (err == error.InvalidArgument and self.said("Key is already deleted")) return;
        return err;
    };
}

fn keyPath(self: HmacKey, arena: std.mem.Allocator) Error![]u8 {
    if (self.access_id.len == 0) {
        if (self.client.diagnostics) |d| d.print("the access ID is empty", .{});
        return error.InvalidArgument;
    }
    const project = self.project orelse try rpc.requireProject(self.client);
    return names.hmacKeyPath(arena, project, self.access_id);
}

/// Whether the last refusal began with `words`. The handle has been
/// `heard`, so there are diagnostics to read.
fn said(self: HmacKey, words: []const u8) bool {
    return std.mem.startsWith(u8, self.client.diagnostics.?.message(), words);
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Reply = test_util.FakeTransport.Reply;

const test_access_id = "GOOG1E-TEST-ONLY-NOT-A-REAL-ACCESS-ID";
const account = "zigps-hmac-2e5a9e@extractctl.iam.gserviceaccount.com";
// Shaped as production answered, every value made up: an access ID and a
// secret that look like a real key's would be taken for one by secret
// scanners, so these cannot.
const created =
    \\{"kind":"storage#hmacKey","metadata":{"kind":"storage#hmacKeyMetadata",
    \\ "id":"extractctl/GOOG1E-TEST-ONLY-NOT-A-REAL-ACCESS-ID",
    \\ "selfLink":"https://www.googleapis.com/storage/v1/projects/extractctl/hmacKeys/GOOG1E-TEST-ONLY-NOT-A-REAL-ACCESS-ID",
    \\ "accessId":"GOOG1E-TEST-ONLY-NOT-A-REAL-ACCESS-ID","projectId":"extractctl",
    \\ "serviceAccountEmail":"zigps-hmac-2e5a9e@extractctl.iam.gserviceaccount.com","state":"ACTIVE",
    \\ "timeCreated":"2026-10-05T15:36:10.539Z","updated":"2026-10-05T15:36:10.539Z","etag":"NzVlOGUzOWY="},
    \\ "secret":"TEST_ONLY_not_a_real_secret_000000000000"}
;
const metadata =
    \\{"kind":"storage#hmacKeyMetadata","accessId":"GOOG1E-TEST-ONLY-NOT-A-REAL-ACCESS-ID",
    \\ "projectId":"extractctl","serviceAccountEmail":"zigps-hmac-2e5a9e@extractctl.iam.gserviceaccount.com",
    \\ "state":"ACTIVE","timeCreated":"2026-10-05T15:36:10.539Z","updated":"2026-10-05T15:36:10.539Z","etag":"NzVlOGUzOWY="}
;
const inactive_answer =
    \\{"accessId":"GOOG1E-TEST-ONLY-NOT-A-REAL-ACCESS-ID","state":"INACTIVE","etag":"OWNkOTI0YmQ="}
;

fn refusal(comptime status: u16, comptime reason: []const u8, comptime message: []const u8) Reply {
    return .{ .respond = .{ .status = status, .body = std.fmt.comptimePrint("{{\"error\":{{\"code\":{d},\"message\":\"{s}\",\"errors\":[{{\"message\":\"{s}\",\"domain\":\"global\",\"reason\":\"{s}\"}}]}}}}", .{ status, message, message, reason }) } };
}

test "golden: create sends the account once, and answers the secret beside the metadata" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = created } }}, .{});
    defer h.deinit();
    var key = try h.client.createHmacKey(account, .{});
    defer key.deinit();
    try h.expectRequest(0, .POST, "https://storage.googleapis.com/storage/v1/projects/extractctl/hmacKeys?serviceAccountEmail=zigps-hmac-2e5a9e%40extractctl.iam.gserviceaccount.com", null);
    try testing.expectEqualStrings(test_access_id, key.value.info.access_id);
    try testing.expectEqual(.active, key.value.info.state);
    try testing.expectEqualStrings("NzVlOGUzOWY=", key.value.info.etag);
    try testing.expectEqualStrings("TEST_ONLY_not_a_real_secret_000000000000", key.value.secret);
    // Its memory is zeroed when freed.
    try testing.expect(key.wiping != null);
}

test "create is never sent again after a lost answer, and says what may be left" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ .{ .respond = .{ .status = 503, .body = "{}" } }, .{ .respond = .{ .body = created } } }, .{ .retry_unconditional_writes = true });
    defer h.deinit();
    try testing.expectError(error.Unavailable, h.client.createHmacKey(account, .{ .project = "other-project" }));
    try h.expectRequestCount(1);
    try h.expectRequest(0, .POST, "https://storage.googleapis.com/storage/v1/projects/other-project/hmacKeys?serviceAccountEmail=zigps-hmac-2e5a9e%40extractctl.iam.gserviceaccount.com", null);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "may or may not have made a key") != null);
    // A refusal is a refusal: nothing was made.
    h.fake.deinit();
    h.fake = .init(testing.allocator, &.{refusal(400, "invalid", "Service account HMAC key limit reached")});
    h.client.transport = h.fake.transport();
    try testing.expectError(error.InvalidArgument, h.client.createHmacKey(account, .{}));
    try testing.expectEqualStrings("Service account HMAC key limit reached", h.diag.message());
    try testing.expectError(error.InvalidArgument, h.client.createHmacKey("", .{}));
}

test "create: an answer without its secret is InvalidResponse, and says a key may be there" {
    for ([_][]const u8{
        "{\"metadata\":{\"accessId\":\"GOOG1EX\",\"state\":\"ACTIVE\"}}",
        "{\"metadata\":{\"accessId\":\"GOOG1EX\"},\"secret\":\"\"}",
        "{\"secret\":\"TEST_ONLY_not_a_real_secret_000000000000\"}",
    }) |body| {
        var h: test_util.Harness = undefined;
        try h.init(&.{.{ .respond = .{ .body = body } }}, .{});
        defer h.deinit();
        try testing.expectError(error.InvalidResponse, h.client.createHmacKey(account, .{}));
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), "may have made a key") != null);
    }
}

test "golden: get, and a list that pages through an empty page" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = metadata } },
        .{ .respond = .{ .body = "{\"kind\":\"storage#hmacKeysMetadata\",\"items\":[" ++ metadata ++ "],\"nextPageToken\":\"t1\"}" } },
        .{ .respond = .{ .body = "{\"kind\":\"storage#hmacKeysMetadata\",\"nextPageToken\":\"t2\"}" } },
        refusal(404, "notFound", "Access ID not found in project."),
    }, .{});
    defer h.deinit();
    var got = try h.client.hmacKey(test_access_id).get();
    defer got.deinit();
    try h.expectRequest(0, .GET, "https://storage.googleapis.com/storage/v1/projects/extractctl/hmacKeys/" ++ test_access_id, null);
    try testing.expectEqualStrings(account, got.value.service_account_email);

    var first = try h.client.listHmacKeys(.{ .service_account_email = account, .show_deleted = true, .page_size = 1 });
    defer first.deinit();
    try h.expectRequest(1, .GET, "https://storage.googleapis.com/storage/v1/projects/extractctl/hmacKeys?serviceAccountEmail=zigps-hmac-2e5a9e%40extractctl.iam.gserviceaccount.com&showDeletedKeys=true&maxResults=1", null);
    try testing.expectEqual(1, first.value.keys.len);
    // A page may be empty and still carry a token: the docs say so.
    var empty = try h.client.listHmacKeys(.{ .page_token = first.value.next_page_token });
    defer empty.deinit();
    try testing.expectEqual(0, empty.value.keys.len);
    try testing.expectEqualStrings("t2", empty.value.next_page_token.?);

    try testing.expectError(error.NotFound, h.client.hmacKey("GOOG1ENONE").get());
    try testing.expectError(error.InvalidArgument, h.client.hmacKey("").get());
}

test "golden: setState sends the state and its etag, and is retried only under one" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .body = inactive_answer } },
    }, .{});
    defer h.deinit();
    const key = h.client.hmacKey(test_access_id);
    try testing.expectError(error.Unavailable, key.setState(.inactive, .{}));
    try h.expectRequest(0, .PUT, "https://storage.googleapis.com/storage/v1/projects/extractctl/hmacKeys/" ++ test_access_id, "{\"state\":\"INACTIVE\"}");
    try h.expectRequestCount(1);
    var changed = try key.setState(.inactive, .{ .etag = "NzVlOGUzOWY=" });
    defer changed.deinit();
    try h.expectRequest(2, .PUT, "https://storage.googleapis.com/storage/v1/projects/extractctl/hmacKeys/" ++ test_access_id, "{\"state\":\"INACTIVE\",\"etag\":\"NzVlOGUzOWY=\"}");
    try testing.expectEqual(.inactive, changed.value.state);
    try testing.expectError(error.InvalidArgument, key.setState(.deleted, .{}));
    try testing.expectError(error.InvalidArgument, key.setState(.unknown, .{}));
    try h.expectRequestCount(3);
}

test "setState: a key already in the state is answered as read, diagnostics kept or not; a stale etag fails" {
    for ([_]bool{ true, false }) |kept| {
        var h: test_util.Harness = undefined;
        try h.init(&.{
            refusal(400, "invalid", "Update must modify the credential."),
            .{ .respond = .{ .body = inactive_answer } },
            refusal(412, "conditionNotMet", "Cannot update keys. Etag does not match expected value."),
            // Read after the 412: still INACTIVE, so the change to ACTIVE
            // never happened.
            .{ .respond = .{ .body = inactive_answer } },
        }, .{});
        defer h.deinit();
        if (!kept) h.client.diagnostics = null;
        var same = try h.client.hmacKey(test_access_id).setState(.inactive, .{});
        defer same.deinit();
        try testing.expectEqual(.inactive, same.value.state);
        try h.expectRequest(1, .GET, "https://storage.googleapis.com/storage/v1/projects/extractctl/hmacKeys/" ++ test_access_id, null);
        try testing.expectError(error.FailedPrecondition, h.client.hmacKey(test_access_id).setState(.active, .{ .etag = "CAE=" }));
        if (kept) try testing.expect(std.mem.indexOf(u8, h.diag.message(), "is inactive") != null);
    }
}

test "setState: a stale etag on a key already as asked is answered as read: a repeat of a change that landed" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        refusal(412, "conditionNotMet", "Cannot update keys. Etag does not match expected value."),
        .{ .respond = .{ .body = inactive_answer } },
    }, .{});
    defer h.deinit();
    var off = try h.client.hmacKey(test_access_id).setState(.inactive, .{ .etag = "NzVlOGUzOWY=" });
    defer off.deinit();
    try testing.expectEqual(.inactive, off.value.state);
}

test "golden: delete, retried, a deleted key done, an active one refused; deactivateAndDelete" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        refusal(400, "invalid", "Key is already deleted."),
        refusal(400, "invalid", "Cannot delete keys in ACTIVE state.  Update state to 'INACTIVE' first."),
        .{ .respond = .{ .body = inactive_answer } },
        .{ .respond = .{ .status = 204, .body = "" } },
        refusal(400, "invalid", "Deleted keys cannot be updated."),
    }, .{});
    defer h.deinit();
    const key = h.client.hmacKey(test_access_id);
    // The first attempt's answer lost; the repeat finds the key deleted.
    try key.delete();
    try h.expectRequest(1, .DELETE, "https://storage.googleapis.com/storage/v1/projects/extractctl/hmacKeys/" ++ test_access_id, null);
    try testing.expectError(error.InvalidArgument, key.delete());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "ACTIVE state") != null);
    try key.deactivateAndDelete();
    try h.expectRequest(3, .PUT, "https://storage.googleapis.com/storage/v1/projects/extractctl/hmacKeys/" ++ test_access_id, "{\"state\":\"INACTIVE\"}");
    try h.expectRequest(4, .DELETE, "https://storage.googleapis.com/storage/v1/projects/extractctl/hmacKeys/" ++ test_access_id, null);
    // Deleted already: done, without a delete.
    try key.deactivateAndDelete();
    try h.expectRequestCount(6);
}

fn createSweep(gpa: std.mem.Allocator) !void {
    var fake: test_util.FakeTransport = .init(gpa, &.{.{ .respond = .{ .body = created } }});
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var client: Client = try .init(gpa, testing.io, .{ .project_id = "extractctl", .token_provider = token.provider(), .transport = fake.transport() });
    defer client.deinit();
    var key = try client.createHmacKey(account, .{});
    defer key.deinit();
    try testing.expectEqualStrings("TEST_ONLY_not_a_real_secret_000000000000", key.value.secret);
}

test "createHmacKey: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, createSweep, .{});
}

fn decodeProperty(_: void, input: []const u8) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (codec.decodeNewHmacKey(a, input)) |key| {
        try testing.expect(key.info.access_id.len > 0 and key.secret.len > 0);
    } else |_| {}
    if (codec.decodeHmacKeyInfo(a, input)) |info| try testing.expect(info.access_id.len > 0) else |_| {}
    if (codec.decodeHmacKeyPage(a, input)) |page| {
        for (page.keys) |k| try testing.expect(k.access_id.len > 0);
    } else |_| {}
}

test "fuzz HMAC key decoders: any bytes decode or fail cleanly, and a key always names its access ID" {
    try test_util.fuzzBytes({}, decodeProperty, .{ .corpus = &.{ created, metadata, "{\"items\":[" ++ metadata ++ "]}", "{\"metadata\":{}}", "[]" } });
}

// Against `FakeMultipart`'s key store, which keeps keys by the rules
// production was measured keeping them by.

const FakeFixture = struct {
    fake: test_util.FakeMultipart,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(f: *FakeFixture) !void {
        f.fake = .init(testing.allocator, testing.io);
        errdefer f.fake.deinit();
        f.token = .{ .token = "ya29.t" };
        f.diag = .{};
        f.client = try .init(testing.allocator, f.fake.io, .{
            .project_id = "extractctl",
            .token_provider = f.token.provider(),
            .transport = f.fake.transport(),
            .diagnostics = &f.diag,
            .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
        });
    }

    fn deinit(f: *FakeFixture) void {
        f.client.deinit();
        f.fake.deinit();
    }
};

const fake_account = "zigps-hmac@extractctl.iam.gserviceaccount.com";

test "against the fake: a key made, read, listed, deactivated, deleted, and the account's limit" {
    var f: FakeFixture = undefined;
    try f.init();
    defer f.deinit();
    var made = try f.client.createHmacKey(fake_account, .{});
    defer made.deinit();
    try testing.expectEqual(61, made.value.info.access_id.len);
    try testing.expectEqual(40, made.value.secret.len);
    const key = f.client.hmacKey(made.value.info.access_id);

    var same = try key.setState(.active, .{});
    same.deinit();
    var off = try key.setState(.inactive, .{ .etag = made.value.info.etag });
    defer off.deinit();
    try testing.expectEqual(.inactive, off.value.state);
    // The etag moved: the one read before is stale.
    try testing.expectError(error.FailedPrecondition, key.setState(.active, .{ .etag = made.value.info.etag }));
    try key.delete();
    try key.delete();
    var gone = try key.get();
    defer gone.deinit();
    try testing.expectEqual(.deleted, gone.value.state);
    var live = try f.client.listHmacKeys(.{ .service_account_email = fake_account });
    defer live.deinit();
    try testing.expectEqual(0, live.value.keys.len);
    var all = try f.client.listHmacKeys(.{ .service_account_email = fake_account, .show_deleted = true });
    defer all.deinit();
    try testing.expectEqual(1, all.value.keys.len);

    // Ten that are not deleted, inactive ones included, then refused; a
    // delete frees a slot.
    var ids: [10][61]u8 = undefined;
    for (&ids) |*id| {
        var k = try f.client.createHmacKey(fake_account, .{});
        defer k.deinit();
        @memcpy(id, k.value.info.access_id);
    }
    var one_off = try f.client.hmacKey(&ids[0]).setState(.inactive, .{});
    one_off.deinit();
    try testing.expectError(error.InvalidArgument, f.client.createHmacKey(fake_account, .{}));
    try testing.expectEqualStrings("Service account HMAC key limit reached", f.diag.message());
    try testing.expectError(error.InvalidArgument, f.client.hmacKey(&ids[1]).delete());
    try f.client.hmacKey(&ids[1]).deactivateAndDelete();
    var again = try f.client.createHmacKey(fake_account, .{});
    again.deinit();

    // Accounts that cannot have keys here.
    try testing.expectError(error.NotFound, f.client.createHmacKey("nobody@extractctl.iam.gserviceaccount.com", .{}));
    try testing.expectError(error.PermissionDenied, f.client.createHmacKey("service-82150720798@gs-project-accounts.iam.gserviceaccount.com", .{}));
    try testing.expectError(error.InvalidArgument, f.client.createHmacKey("nobody", .{}));
    try testing.expectError(error.NotFound, f.client.hmacKey("GOOG1ENOSUCHKEY").get());
}

/// Loses the answer of the `which`th key request: it lands, and the
/// connection drops.
const LosesAnswer = struct {
    which: u32,
    seen: u32 = 0,
    fn plan(self: *LosesAnswer) test_util.FakeMultipart.FaultPlan {
        return .{ .ctx = self, .decide = decide };
    }
    fn decide(ctx: ?*anyopaque, kind: test_util.FakeMultipart.Kind, _: u32) test_util.FakeMultipart.Fault {
        const self: *LosesAnswer = @ptrCast(@alignCast(ctx.?));
        if (kind != .hmac) return .none;
        self.seen += 1;
        return if (self.seen == self.which) .lose_answer else .none;
    }
};

test "against the fake: a lost answer is ridden out where a repeat finds the change made, and a lost create leaves a key to find" {
    var f: FakeFixture = undefined;
    try f.init();
    defer f.deinit();
    var made = try f.client.createHmacKey(fake_account, .{});
    defer made.deinit();
    const key = f.client.hmacKey(made.value.info.access_id);

    // A deactivation under its etag lands, its answer lost: the repeat
    // finds the key as asked.
    var lose_update: LosesAnswer = .{ .which = 1 };
    f.fake.faults = lose_update.plan();
    var off = try key.setState(.inactive, .{ .etag = made.value.info.etag });
    defer off.deinit();
    try testing.expectEqual(.inactive, off.value.state);
    try testing.expectEqual(.INACTIVE, f.fake.hmac.key(made.value.info.access_id).?.state);

    // A delete lands, its answer lost: the repeat finds it deleted.
    var lose_delete: LosesAnswer = .{ .which = 1 };
    f.fake.faults = lose_delete.plan();
    try key.delete();
    try testing.expectEqual(.DELETED, f.fake.hmac.key(made.value.info.access_id).?.state);

    // A create lands, its answer lost: never sent again, and the key it
    // made, whose secret nobody has, is there to find and delete.
    var lose_create: LosesAnswer = .{ .which = 1 };
    f.fake.faults = lose_create.plan();
    try testing.expectError(error.ConnectionResetByPeer, f.client.createHmacKey(fake_account, .{}));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "may or may not have made a key") != null);
    try testing.expectEqual(2, f.fake.hmac.counts.creates);
    f.fake.faults = null;
    var orphans = try f.client.listHmacKeys(.{ .service_account_email = fake_account });
    defer orphans.deinit();
    try testing.expectEqual(1, orphans.value.keys.len);
    try f.client.hmacKey(orphans.value.keys[0].access_id).deactivateAndDelete();
}
