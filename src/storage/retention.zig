//! Retention policies and holds: how a write that Cloud Storage refuses
//! because it keeps the object is told from one refused for a missing
//! permission, both being HTTP 403.
//!
//! Measured against Cloud Storage on 2026-09-30:
//!
//! - Under a bucket's retention policy every object, old and new, is kept
//!   for the period from its creation, or from its event-based hold's
//!   release; its `retentionExpirationTime` says until when, and is absent
//!   while an event-based hold defers it. A delete (pinned or not), an
//!   overwrite by upload, compose or rewrite, a rewrite in place and a move
//!   of it are refused with 403 `retentionPolicyNotMet`, "Object '...' is
//!   subject to bucket's retention policy or object retention and cannot be
//!   deleted or overwritten until <time>". A compose that would delete a
//!   retained source fails whole. A condition is checked first: 412 before
//!   403. A metadata patch goes through.
//! - A held object refuses the same writes with 403 reason `forbidden`, the
//!   reason a missing permission has too, and the message "Object '...' is
//!   under active Temporary hold and cannot be deleted, overwritten or
//!   archived until hold is removed." (or "Event-Based hold"). Google
//!   documents the reason `objectUnderActiveHold`, which no response had.
//! - A resumable upload over a kept object starts, takes every byte, and is
//!   refused at its final PUT. An XML multipart upload starts and takes its
//!   parts, and is refused at its complete: `RetentionPolicyNotMet` or
//!   `ObjectUnderActiveHold`, with the upload left open to abort.
//! - A locked policy's removal is 403 `retentionPolicyNotMet` too, "Bucket
//!   '...' has a locked Retention Policy which cannot be removed.": no
//!   object is kept there, so it stays `PermissionDenied`.

const std = @import("std");
const core = @import("core");

/// Whether a failure is Cloud Storage keeping an object rather than a
/// missing permission, from the reason and message it sent, which `diag`
/// holds.
pub fn isRetained(err: anyerror, diag: *const core.Diagnostics) bool {
    if (err != error.PermissionDenied) return false;
    const reason = diag.status();
    const message = diag.message();
    // The JSON API's `retentionPolicyNotMet` and the XML API's
    // `RetentionPolicyNotMet`.
    if (std.ascii.eqlIgnoreCase(reason, "retentionPolicyNotMet")) return !std.mem.startsWith(u8, message, "Bucket ");
    if (std.ascii.eqlIgnoreCase(reason, "objectUnderActiveHold")) return true;
    if (std.mem.eql(u8, reason, "forbidden")) {
        return std.mem.indexOf(u8, message, "is under active ") != null and std.mem.indexOf(u8, message, " hold ") != null;
    }
    return false;
}

/// Whether an object's retention can be sent, saying why not in `diag`:
/// each refusal is one of Cloud Storage's 400s, as measured. A time in
/// the past is left to the server, whose clock decides.
pub fn checkObjectRetention(diag: ?*core.Diagnostics, retention: types.ObjectRetention, event_based_hold: ?bool) bool {
    if (retention.mode == .unknown) {
        if (diag) |d| d.print("retention: a mode this library does not know is never sent", .{});
        return false;
    }
    _ = core.timestamp.parse(retention.retain_until) catch {
        if (diag) |d| d.print("retention: retain_until is not an RFC 3339 time with Z or an offset", .{});
        return false;
    };
    if (event_based_hold orelse false) {
        if (diag) |d| d.print("retention and an event-based hold cannot be configured together", .{});
        return false;
    }
    return true;
}

const types = @import("types.zig");
const testing = std.testing;
const test_util = @import("test_util.zig");
const codec = @import("codec.zig");
const xml = @import("xml.zig");
const Client = @import("Client.zig");
const FakeMultipart = test_util.FakeMultipart;
const Harness = test_util.Harness;
const Reply = test_util.FakeTransport.Reply;

/// Production's bodies, as measured.
const retained_json =
    \\{"error":{"code":403,"message":"Object 'zigps-ret-3bbbb6-r/p' is subject to bucket's retention policy or object retention and cannot be deleted or overwritten until 2026-09-30T15:58:01.185839-07:00","errors":[{"message":"Object 'zigps-ret-3bbbb6-r/p' is subject to bucket's retention policy or object retention and cannot be deleted or overwritten until 2026-09-30T15:58:01.185839-07:00","domain":"global","reason":"retentionPolicyNotMet"}]}}
;
const held_json =
    \\{"error":{"code":403,"message":"Object 'zigps-ret-3bbbb6-h/th' is under active Temporary hold and cannot be deleted, overwritten or archived until hold is removed.","errors":[{"message":"Object 'zigps-ret-3bbbb6-h/th' is under active Temporary hold and cannot be deleted, overwritten or archived until hold is removed.","domain":"global","reason":"forbidden"}]}}
;
const event_held_json =
    \\{"error":{"code":403,"message":"Object 'zigps-ret-3bbbb6-h/eh' is under active Event-Based hold and cannot be deleted, overwritten or archived until hold is removed.","errors":[{"message":"Object 'zigps-ret-3bbbb6-h/eh' is under active Event-Based hold and cannot be deleted, overwritten or archived until hold is removed.","domain":"global","reason":"forbidden"}]}}
;
const locked_bucket_json =
    \\{"error":{"code":403,"message":"Bucket 'zigps-ret-0a3279-lock' has a locked Retention Policy which cannot be removed.","errors":[{"message":"Bucket 'zigps-ret-0a3279-lock' has a locked Retention Policy which cannot be removed.","domain":"global","reason":"retentionPolicyNotMet"}]}}
;
const denied_json =
    \\{"error":{"code":403,"message":"someone@example.com does not have storage.objects.delete access to the Google Cloud Storage object. Permission 'storage.objects.delete' denied on resource (or it may not exist).","errors":[{"message":"someone@example.com does not have storage.objects.delete access to the Google Cloud Storage object. Permission 'storage.objects.delete' denied on resource (or it may not exist).","domain":"global","reason":"forbidden"}]}}
;
const retained_xml = "<?xml version='1.0' encoding='UTF-8'?><Error><Code>RetentionPolicyNotMet</Code><Message>Object overwrite or deletion is not allowed due to retention policy.</Message><Details>Object 'zigps-ret-886451-y/kept' is subject to bucket's retention policy or object retention and cannot be deleted or overwritten until 2026-09-30T17:04:50.584991-07:00</Details></Error>";
const held_xml = "<?xml version='1.0' encoding='UTF-8'?><Error><Code>ObjectUnderActiveHold</Code><Message>Object overwrite or deletion is not allowed due to active hold on the object.</Message><Details>Object 'zigps-ret-886451-x/held' is under active Temporary hold and cannot be deleted, overwritten or archived until hold is removed.</Details></Error>";

fn diagnosed(arena: std.mem.Allocator, body: []const u8, is_xml: bool) !core.Diagnostics {
    const decoded = (if (is_xml) try xml.decodeError(arena, body) else try core.errors.decodeErrorBody(arena, body)).?;
    var d: core.Diagnostics = .{};
    d.set(403, decoded.status, decoded.message);
    return d;
}

test "isRetained: every refusal measured for a kept object, and none for a permission or a bucket" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct { body: []const u8, xml: bool = false, kept: bool };
    const cases = [_]Case{
        .{ .body = retained_json, .kept = true },
        .{ .body = held_json, .kept = true },
        .{ .body = event_held_json, .kept = true },
        .{ .body = retained_xml, .xml = true, .kept = true },
        .{ .body = held_xml, .xml = true, .kept = true },
        // Documented, never seen.
        .{ .body = "{\"error\":{\"code\":403,\"message\":\"Object replacement or deletion is not allowed due to an active hold on the object.\",\"errors\":[{\"reason\":\"objectUnderActiveHold\"}]}}", .kept = true },
        .{ .body = locked_bucket_json, .kept = false },
        .{ .body = denied_json, .kept = false },
        .{ .body = "<?xml version='1.0' encoding='UTF-8'?><Error><Code>AccessDenied</Code><Message>Access denied.</Message></Error>", .xml = true, .kept = false },
    };
    for (cases) |case| {
        errdefer std.debug.print("body: {s}\n", .{case.body});
        const d = try diagnosed(arena, case.body, case.xml);
        try testing.expectEqual(case.kept, isRetained(error.PermissionDenied, &d));
        // Only a 403 is ever a kept object's.
        try testing.expect(!isRetained(error.NotFound, &d));
    }
}

test "ObjectRetained: from a delete, an upload and a resumable upload's final PUT, with or without client diagnostics" {
    const refused: Reply = .{ .respond = .{ .status = 403, .body = retained_json } };
    var h: Harness = undefined;
    try h.init(&.{
        refused,
        .{ .respond = .{ .status = 403, .body = held_json } },
        refused,
        .{ .respond = .{ .status = 403, .body = denied_json } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();
    const obj = h.client.bucket("b").object("p");
    try testing.expectError(error.ObjectRetained, obj.delete(.{ .generation = 7 }));
    // The server's words stay, time and all.
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "cannot be deleted or overwritten until 2026-09-30T15:58:01.185839-07:00") != null);
    try testing.expectEqualStrings("retentionPolicyNotMet", h.diag.status());
    try testing.expectError(error.ObjectRetained, obj.upload("data", .{ .preconditions = .{ .if_generation_match = 7 } }));
    // Never retried.
    try testing.expectEqual(2, h.fake.requests.items.len + h.fake.stream_requests.items.len);

    // A client that keeps no diagnostics gets the same answer.
    h.client.diagnostics = null;
    try testing.expectError(error.ObjectRetained, obj.delete(.{ .generation = 7 }));
    try testing.expectError(error.PermissionDenied, obj.delete(.{ .generation = 7 }));

    // A resumable upload: its start went through, and its final PUT is
    // refused after every byte.
    var r: Harness = undefined;
    try r.init(&.{
        .{ .respond = .{ .body = "", .headers = &.{.{ .name = "Location", .value = "https://storage.example.test/upload/session/s1" }} } },
        .{ .respond = .{ .status = 403, .body = event_held_json } },
    }, .{ .single_request_limit = 16 });
    defer r.deinit();
    const data = "a resumable upload's bytes, all 40 of them";
    try testing.expectError(error.ObjectRetained, r.client.bucket("b").object("eh").upload(data, .{}));
    try testing.expectEqual(data.len, (try r.fake.streamRequest(1)).body_len);
    try testing.expect(std.mem.indexOf(u8, r.diag.message(), "under active Event-Based hold") != null);
}

test "a locked policy's refusal to go stays PermissionDenied: no object is kept" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .status = 403, .body = locked_bucket_json } }}, .{});
    defer h.deinit();
    try testing.expectError(error.PermissionDenied, h.client.bucket("b").update(.{ .retention_period_s = .clear }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "has a locked Retention Policy") != null);
}

test "golden: holds and a policy read back as production sent them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A released temporary hold reads `false`; an object never held names
    // none.
    const released = try codec.decodeObject(arena,
        \\{"kind":"storage#object","name":"th","bucket":"zigps-ret-3bbbb6-h","generation":"1790805519645279",
        \\ "metageneration":"3","contentType":"text/plain","size":"4","crc32c":"2fSt1g==","temporaryHold":false,
        \\ "timeCreated":"2026-09-30T21:58:39.652Z","updated":"2026-09-30T21:58:42.536Z","metadata":{"k":"v"}}
    );
    try testing.expect(!released.temporary_hold);
    try testing.expect(!released.event_based_hold);
    try testing.expectEqual(null, released.retention_expiration_time);
    const kept = try codec.decodeObject(arena,
        \\{"name":"temp","bucket":"b","generation":"1","metageneration":"1","temporaryHold":true,"eventBasedHold":true,
        \\ "retentionExpirationTime":"2026-09-30T22:09:01.223Z"}
    );
    try testing.expect(kept.temporary_hold and kept.event_based_hold);
    try testing.expectEqualStrings("2026-09-30T22:09:01.223Z", kept.retention_expiration_time.?);

    const unlocked = try codec.decodeBucket(arena,
        \\{"name":"zigps-ret-3bbbb6-p","metageneration":"1","location":"US-CENTRAL1",
        \\ "retentionPolicy":{"retentionPeriod":"3600","effectiveTime":"2026-09-30T21:57:51.487Z"},
        \\ "softDeletePolicy":{"retentionDurationSeconds":"0"}}
    );
    try testing.expectEqual(3600, unlocked.retention_policy.?.period_s);
    try testing.expectEqualStrings("2026-09-30T21:57:51.487Z", unlocked.retention_policy.?.effective_time.?);
    try testing.expect(!unlocked.retention_policy.?.locked);
    try testing.expect(!unlocked.default_event_based_hold);
    const locked = try codec.decodeBucket(arena,
        \\{"name":"zigps-ret-0a3279-lock","metageneration":"2","defaultEventBasedHold":true,
        \\ "retentionPolicy":{"retentionPeriod":"60","effectiveTime":"2026-09-30T22:58:19.243Z","isLocked":true}}
    );
    try testing.expect(locked.retention_policy.?.locked);
    try testing.expect(locked.default_event_based_hold);
    // A policy without a period could not be sent back.
    try testing.expectError(error.InvalidResponse, codec.decodeBucket(arena, "{\"name\":\"b\",\"retentionPolicy\":{}}"));
    try testing.expectError(error.InvalidResponse, codec.decodeBucket(arena, "{\"name\":\"b\",\"retentionPolicy\":{\"retentionPeriod\":\"0\"}}"));
}

test "golden: holds go out with an upload, a compose, a copy and a metadata update" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"a\",\"generation\":\"7\",\"metageneration\":\"1\",\"temporaryHold\":true}" } },
        .{ .respond = .{ .body = "", .headers = &.{.{ .name = "Location", .value = "https://storage.example.test/upload/session/s1" }} } },
        // The session's one chunk.
        .{ .respond = .{ .body = "{\"name\":\"a\",\"generation\":\"8\",\"metageneration\":\"1\",\"size\":\"38\"}" } },
        .{ .respond = .{ .body = "{\"name\":\"a\",\"generation\":\"9\",\"metageneration\":\"1\"}" } },
        .{ .respond = .{ .body = "{\"name\":\"a\",\"generation\":\"9\",\"metageneration\":\"1\"}" } },
        // The copy reads its source, then rewrites.
        .{ .respond = .{ .body = "{\"name\":\"a\",\"generation\":\"9\",\"metageneration\":\"1\",\"contentType\":\"text/plain\"}" } },
        .{ .respond = .{ .body = "{\"done\":true,\"resource\":{\"name\":\"c\",\"generation\":\"10\",\"metageneration\":\"1\"}}" } },
        .{ .respond = .{ .body = "{\"name\":\"a\",\"generation\":\"9\",\"metageneration\":\"2\"}" } },
    }, .{ .single_request_limit = 16 });
    defer h.deinit();
    const obj = h.client.bucket("b").object("a");

    var one = try obj.upload("held", .{ .temporary_hold = true, .event_based_hold = false });
    defer one.deinit();
    try testing.expect(one.value.temporary_hold);
    try testing.expect(std.mem.indexOf(u8, (try h.fake.streamRequest(0)).body_prefix, "\"temporaryHold\":true,\"eventBasedHold\":false}") != null);

    var resumed = try obj.upload("a resumable upload, over sixteen bytes", .{ .event_based_hold = true });
    defer resumed.deinit();
    try testing.expect(std.mem.indexOf(u8, (try h.fake.streamRequest(1)).body_prefix, "\"eventBasedHold\":true}") != null);
    // Neither asked: nothing sent, so the bucket's default applies.
    var plain = try obj.composeFrom(&.{.{ .name = "x" }}, .{});
    defer plain.deinit();
    try testing.expect(std.mem.indexOf(u8, (try h.fake.request(0)).body.?, "Hold") == null);

    var composed = try obj.composeFrom(&.{.{ .name = "x" }}, .{ .temporary_hold = true });
    defer composed.deinit();
    try testing.expectEqualStrings(
        "{\"sourceObjects\":[{\"name\":\"x\"}],\"destination\":{\"contentType\":\"application/octet-stream\",\"temporaryHold\":true}}",
        (try h.fake.request(1)).body.?,
    );

    // A hold makes a copy a changed one: the source's metadata, and the
    // hold, since a copy never carries the source's.
    var copied = try obj.copyTo(h.client.bucket("b").object("c"), .{ .event_based_hold = true });
    defer copied.deinit();
    try testing.expectEqual(.GET, (try h.fake.request(2)).method);
    try testing.expectEqualStrings("{\"contentType\":\"text/plain\",\"eventBasedHold\":true}", (try h.fake.request(3)).body.?);

    var released = try obj.updateMetadata(.{ .temporary_hold = false, .event_based_hold = true });
    defer released.deinit();
    try testing.expectEqualStrings("{\"temporaryHold\":false,\"eventBasedHold\":true}", (try h.fake.request(4)).body.?);
}

/// A client on the in-memory fake, which keeps and enforces holds and
/// policies as Cloud Storage does, on a simulated clock.
const Fixture = struct {
    clock: test_util.FakeClock,
    fake: FakeMultipart,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(f: *Fixture) !void {
        f.clock = .{};
        f.fake = .init(testing.allocator, f.clock.io());
        errdefer f.fake.deinit();
        f.fake.min_part_size = 1024;
        f.token = .{ .token = "ya29.retention" };
        f.diag = .{};
        f.client = try .init(testing.allocator, f.clock.io(), .{
            .project_id = "extractctl",
            .token_provider = f.token.provider(),
            .transport = f.fake.transport(),
            .diagnostics = &f.diag,
            .single_request_limit = 1024,
            .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
        });
        f.client.multipart_test = .{ .min_part_size = 1024 };
    }

    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.fake.deinit();
    }

    fn advance(f: *Fixture, seconds: u64) void {
        f.clock.now_ns += @as(i96, seconds) * std.time.ns_per_s;
    }

    fn bucket(f: *Fixture, config: types.BucketConfig) !void {
        var created = try f.client.bucket("b").create(config);
        created.deinit();
    }

    fn object(f: *Fixture, name: []const u8) @import("Object.zig") {
        return f.client.bucket("b").object(name);
    }
};

test "a policy keeps every object its period, old and new, then lets it go" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.bucket(.{});
    var old = try f.object("old").upload("before the policy", .{});
    old.deinit();
    f.advance(10);
    var changed = try f.client.bucket("b").update(.{ .retention_period_s = .{ .set = 60 } });
    changed.deinit();
    // Retroactive: kept 60 s from its creation, 50 s from now.
    try testing.expectError(error.ObjectRetained, f.object("old").delete(.{}));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "until 2026-09-30T00:01:00.000Z") != null);
    var new = try f.object("new").upload("under it", .{});
    defer new.deinit();
    try testing.expectEqualStrings("2026-09-30T00:01:10.000Z", new.value.retention_expiration_time.?);
    // Every write that would take it away is refused, a metadata update is
    // not.
    try testing.expectError(error.ObjectRetained, f.object("new").upload("over it", .{}));
    try testing.expectError(error.ObjectRetained, f.object("new").upload(test_util.repeat("over it, resumably, more than a kilobyte", 30), .{}));
    var patched = try f.object("new").updateMetadata(.{ .temporary_hold = false });
    patched.deinit();
    // A condition is checked first.
    try testing.expectError(error.FailedPrecondition, f.object("new").upload("over it", .{ .preconditions = .does_not_exist }));
    f.advance(50);
    try f.object("old").delete(.{});
    try testing.expectError(error.ObjectRetained, f.object("new").delete(.{}));
    f.advance(10);
    try f.object("new").delete(.{});
}

test "holds: set at upload or later, released by a metadata update, and the default hold unless refused" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.bucket(.{ .default_event_based_hold = true });
    var held = try f.object("h").upload("held", .{ .temporary_hold = true });
    defer held.deinit();
    try testing.expect(held.value.temporary_hold);
    try testing.expect(held.value.event_based_hold);
    var free = try f.object("f").upload("free", .{ .event_based_hold = false });
    defer free.deinit();
    try testing.expect(!free.value.event_based_hold);
    try f.object("f").delete(.{});

    try testing.expectError(error.ObjectRetained, f.object("h").delete(.{}));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "under active Temporary hold") != null);
    var once = try f.object("h").updateMetadata(.{ .temporary_hold = false });
    once.deinit();
    try testing.expectError(error.ObjectRetained, f.object("h").delete(.{}));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "under active Event-Based hold") != null);
    var twice = try f.object("h").updateMetadata(.{ .event_based_hold = false });
    defer twice.deinit();
    try testing.expect(!twice.value.temporary_hold and !twice.value.event_based_hold);
    try testing.expectEqual(3, twice.value.metageneration);
    try f.object("h").delete(.{});
}

test "an event-based hold defers the policy, and its release starts the period" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.bucket(.{ .retention_period_s = 60 });
    var held = try f.object("e").upload("e", .{ .event_based_hold = true });
    defer held.deinit();
    try testing.expectEqual(null, held.value.retention_expiration_time);
    f.advance(100);
    var released = try f.object("e").updateMetadata(.{ .event_based_hold = false });
    defer released.deinit();
    try testing.expectEqualStrings("2026-09-30T00:02:40.000Z", released.value.retention_expiration_time.?);
    try testing.expectError(error.ObjectRetained, f.object("e").delete(.{}));
    f.advance(60);
    try f.object("e").delete(.{});
}

test "a parallel upload over a held object is refused at its finish, and aborted" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.bucket(.{});
    var held = try f.object("o").upload("held", .{ .temporary_hold = true });
    held.deinit();
    var data: [9000]u8 = undefined;
    @memset(&data, 'p');
    try testing.expectError(error.ObjectRetained, f.object("o").uploadParallel(.{ .data = &data }, .{ .part_size = 4096 }));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "active hold") != null);
    try testing.expectEqual(1, f.fake.counts.starts);
    try testing.expectEqual(0, f.fake.openUploads());
    try testing.expectEqualStrings("held", f.fake.object("o").?.bytes);
}

test "a parallel upload with conditions into a bucket that keeps objects goes up as one upload, with nothing stranded" {
    for ([_]types.BucketConfig{ .{ .retention_period_s = 3600 }, .{ .default_event_based_hold = true } }) |config| {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        try f.bucket(config);
        var data: [9000]u8 = undefined;
        @memset(&data, 'q');
        var info = try f.object("o").uploadParallel(.{ .data = &data }, .{ .part_size = 4096, .preconditions = .does_not_exist });
        defer info.deinit();
        try testing.expectEqual(data.len, info.value.size);
        // No multipart upload, no temporary object, no move.
        try testing.expectEqual(0, f.fake.counts.starts);
        try testing.expectEqual(0, f.fake.counts.moves);
        try testing.expectEqual(1, f.fake.objects.items.len);
        try testing.expectEqual(1, f.fake.counts.session_starts);
    }

    // A bucket that keeps nothing gets the parts and the move.
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.bucket(.{});
    var data: [9000]u8 = undefined;
    @memset(&data, 'r');
    var info = try f.object("o").uploadParallel(.{ .data = &data }, .{ .part_size = 4096, .preconditions = .does_not_exist });
    defer info.deinit();
    try testing.expectEqual(1, f.fake.counts.starts);
    try testing.expectEqual(1, f.fake.counts.moves);
}

/// What one name holds, as the model sees it.
const Kept = struct {
    exists: bool = false,
    temporary: bool = false,
    event_based: bool = false,
    /// When its period began, on the fake's clock: its creation, or its
    /// event-based hold's latest release.
    from_ns: i96 = 0,
    /// Its own retention.
    own: ?Own = null,

    const Own = struct { locked: bool, until_ns: i96 };
};

/// The fake's wall clock reading at `ns`: midnight UTC on 2026-09-30, plus
/// its clock, to the millisecond.
fn wallTime(buf: []u8, ns: i96) []const u8 {
    const total_ms: u64 = @intCast(1_790_726_400 * std.time.ms_per_s + @divFloor(ns, std.time.ns_per_ms));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = total_ms / std.time.ms_per_s };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const secs = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        secs.getHoursIntoDay(),
        secs.getMinutesIntoHour(),
        secs.getSecondsIntoMinute(),
        total_ms % std.time.ms_per_s,
    }) catch unreachable;
}

/// A retention time drawn around now, now and then in the past.
fn drawUntil(g: *test_util.ByteGen, now: i96) i96 {
    const ahead: i96 = @as(i96, g.intRange(u8, 0, 120)) - 10;
    return now + ahead * std.time.ns_per_s;
}

/// What an update of an object's own retention does, as measured: an
/// error the model expects, or the retention after it.
const OwnOutcome = union(enum) { refused: anyerror, next: ?Kept.Own };

fn ownChange(m: Kept, object_retention: bool, now: i96, wanted: ?Kept.Own, override: bool) OwnOutcome {
    if (!m.exists) return .{ .refused = error.NotFound };
    const next = wanted orelse {
        const current = m.own orelse return .{ .next = null };
        if (current.locked or !override) return .{ .refused = error.PermissionDenied };
        return .{ .next = null };
    };
    if (!object_retention or next.until_ns <= now) return .{ .refused = error.InvalidArgument };
    if (m.own) |current| {
        const shortens = next.until_ns < current.until_ns;
        if (current.locked and (!next.locked or shortens)) return .{ .refused = error.PermissionDenied };
        if (!current.locked and (shortens or next.locked) and !override) return .{ .refused = error.PermissionDenied };
    }
    if (m.event_based) return .{ .refused = error.InvalidArgument };
    return .{ .next = next };
}

/// Uploads, deletes, holds placed and released, retention placed,
/// changed and removed on objects and on the bucket, and time passing, on
/// two names in one bucket. Every call is refused `ObjectRetained`
/// exactly when the model, written from what Cloud Storage was measured to
/// do, says the object is held or inside a period, every other refusal is
/// the one the model expects, and every object reads back with the holds,
/// the retention and the expiration the model says.
fn keptProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var period: ?u64 = if (g.boolean()) g.intRange(u8, 1, 120) else null;
    const object_retention = g.intRange(u8, 0, 2) == 0;
    // Not both: a default hold beside a retention is refused.
    const default_hold = !object_retention and g.intRange(u8, 0, 3) == 0;
    try f.bucket(.{ .retention_period_s = period, .default_event_based_hold = default_hold, .object_retention = object_retention });
    const b = f.client.bucket("b");
    const names = [_][]const u8{ "a", "b" };
    var model: [2]Kept = .{ .{}, .{} };
    var text: [2][32]u8 = undefined;

    var op: usize = 0;
    while (g.pos < g.bytes.len and op < 24) : (op += 1) {
        const which = g.byte() % 2;
        const m = &model[which];
        const o = b.object(names[which]);
        const now = f.clock.now_ns;
        const retained = if (period) |p| !m.event_based and now < m.from_ns + @as(i96, p) * std.time.ns_per_s else false;
        const owned = if (m.own) |own| now < own.until_ns else false;
        const kept = m.exists and (m.temporary or m.event_based or retained or owned);
        switch (g.byte() % 9) {
            0 => {
                const temporary = g.boolean();
                const event_based: ?bool = switch (g.byte() % 3) {
                    0 => null,
                    1 => false,
                    else => true,
                };
                const own: ?Kept.Own = if (g.intRange(u8, 0, 2) == 0) .{ .locked = g.boolean(), .until_ns = drawUntil(&g, now) } else null;
                const retention: ?types.ObjectRetention = if (own) |r| .{ .mode = if (r.locked) .locked else .unlocked, .retain_until = wallTime(&text[0], r.until_ns) } else null;
                const result = o.upload("v", .{ .temporary_hold = temporary, .event_based_hold = event_based, .retention = retention });
                if (result) |info| {
                    var held = info;
                    defer held.deinit();
                    try testing.expect(!kept);
                    try testing.expect(own == null or (object_retention and own.?.until_ns > now and !(event_based orelse false)));
                    m.* = .{ .exists = true, .temporary = temporary, .event_based = event_based orelse default_hold, .from_ns = now, .own = own };
                } else |err| switch (err) {
                    error.ObjectRetained => try testing.expect(kept),
                    // The library's own check, or the server's.
                    error.InvalidArgument => try testing.expect(own != null and ((event_based orelse false) or !object_retention or own.?.until_ns <= now)),
                    else => return err,
                }
            },
            1 => if (o.delete(.{})) {
                try testing.expect(m.exists and !kept);
                m.exists = false;
            } else |err| switch (err) {
                error.ObjectRetained => try testing.expect(kept),
                error.NotFound => try testing.expect(!m.exists),
                else => return err,
            },
            2, 3 => |kind| {
                const on = g.boolean();
                const update: types.MetadataUpdate = if (kind == 2) .{ .temporary_hold = on } else .{ .event_based_hold = on };
                // An event-based hold may not join a retention.
                const conflict = kind == 3 and on and m.own != null;
                if (o.updateMetadata(update)) |info| {
                    var held = info;
                    defer held.deinit();
                    try testing.expect(m.exists and !conflict);
                    if (kind == 2) {
                        m.temporary = on;
                    } else {
                        // A release starts the period over.
                        if (m.event_based and !on) m.from_ns = now;
                        m.event_based = on;
                    }
                } else |err| switch (err) {
                    error.NotFound => try testing.expect(!m.exists),
                    error.InvalidArgument => try testing.expect(m.exists and conflict),
                    else => return err,
                }
            },
            4 => {
                const next: ?u64 = if (g.boolean()) g.intRange(u8, 1, 120) else null;
                var updated = try b.update(.{ .retention_period_s = if (next) |p| .{ .set = p } else .clear });
                updated.deinit();
                period = next;
            },
            5, 6 => f.advance(g.intRange(u8, 0, 90)),
            else => |kind| {
                const override = g.boolean();
                const wanted: ?Kept.Own = if (kind == 7) .{ .locked = g.boolean(), .until_ns = drawUntil(&g, now) } else null;
                const change: types.Change(types.ObjectRetention) = if (wanted) |r| .{ .set = .{
                    .mode = if (r.locked) .locked else .unlocked,
                    .retain_until = wallTime(&text[1], r.until_ns),
                } } else .clear;
                const expected = ownChange(m.*, object_retention, now, wanted, override);
                if (o.updateMetadata(.{ .retention = change, .override_unlocked_retention = override })) |info| {
                    var changed = info;
                    defer changed.deinit();
                    m.own = expected.next;
                } else |err| try testing.expectEqual(expected.refused, err);
            },
        }
        // Each name reads back as the model has it.
        for (names, model) |name, want| {
            if (b.object(name).get(.{})) |info| {
                var held = info;
                defer held.deinit();
                try testing.expect(want.exists);
                try testing.expectEqual(want.temporary, held.value.temporary_hold);
                try testing.expectEqual(want.event_based, held.value.event_based_hold);
                if (want.own) |own| {
                    const r = held.value.retention orelse return error.TestExpectedRetention;
                    try testing.expectEqual(@as(types.ObjectRetention.Mode, if (own.locked) .locked else .unlocked), r.mode);
                    var buf: [32]u8 = undefined;
                    try testing.expectEqualStrings(wallTime(&buf, own.until_ns), r.retain_until);
                } else try testing.expectEqual(null, held.value.retention);
                const policy: ?i96 = if (period) |p| if (want.event_based) null else want.from_ns + @as(i96, p) * std.time.ns_per_s else null;
                const own_until: ?i96 = if (want.own) |own| own.until_ns else null;
                const until: ?i96 = if (policy) |p| (if (own_until) |u| @max(p, u) else p) else own_until;
                if (until) |u| {
                    var buf: [32]u8 = undefined;
                    try testing.expectEqualStrings(wallTime(&buf, u), held.value.retention_expiration_time orelse return error.TestExpectedExpiration);
                } else try testing.expectEqual(null, held.value.retention_expiration_time);
            } else |err| {
                try testing.expectEqual(error.NotFound, err);
                try testing.expect(!want.exists);
            }
        }
    }
}

test "heavy property holds and retention: every write refused exactly when the object is kept, as a model says" {
    try test_util.fuzzBytes({}, keptProperty, .{
        .corpus = &.{
            "",
            // A 60 s policy: upload "a" held, a delete refused, the hold
            // released, a delete refused inside the period, 90 s pass, the
            // delete goes.
            "\x01\x3b\x01\x01" ++ "\x00\x00\x01\x01\x01" ++ "\x00\x01" ++ "\x00\x02\x00" ++ "\x00\x01" ++ "\x00\x05\x5a" ++ "\x00\x01",
            // An event-based hold under a policy, released after time passed.
            "\x01\x3b\x01\x01" ++ "\x00\x00\x00\x02\x01" ++ "\x00\x05\x5a" ++ "\x00\x03\x00" ++ "\x00\x01" ++ "\x00\x05\x5a" ++ "\x00\x01",
            // Object retention: an unlocked one for 60 s refuses a delete
            // and a shortening without the override, and goes with it; a
            // locked one refuses removal even with it, and goes once its
            // time passes.
            "\x00\x00" ++ "\x00\x00\x00\x00\x00\x00\x46" ++ "\x00\x01" ++ "\x00\x07\x00\x00\x28" ++ "\x00\x08\x01" ++ "\x00\x01" ++
                "\x00\x00\x00\x00\x00\x01\x46" ++ "\x00\x08\x01" ++ "\x00\x05\x5a" ++ "\x00\x01",
        },
    });
}

/// Corrupts the first XML finish: the finished object holds other bytes.
const CorruptFinish = struct {
    done: bool = false,

    fn plan(self: *CorruptFinish) FakeMultipart.FaultPlan {
        return .{ .ctx = self, .decide = decide };
    }

    fn decide(ctx: ?*anyopaque, kind: FakeMultipart.Kind, _: u32) FakeMultipart.Fault {
        const self: *CorruptFinish = @ptrCast(@alignCast(ctx.?));
        if (kind != .finish or self.done) return .none;
        self.done = true;
        return .corrupt;
    }
};

test "an upload that finished wrong under protection says the object stays, not that it went" {
    // A parallel upload whose finish stored other bytes, in a bucket that
    // keeps them for an hour.
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.bucket(.{ .retention_period_s = 3600 });
    var corrupt: CorruptFinish = .{};
    f.fake.faults = corrupt.plan();
    var data: [9000]u8 = undefined;
    @memset(&data, 's');
    try testing.expectError(error.ChecksumMismatch, f.object("o").uploadParallel(.{ .data = &data }, .{ .part_size = 4096 }));
    try testing.expect(std.mem.endsWith(u8, f.diag.message(), "; the object stays, kept by its bucket's retention policy or a hold"));
    try testing.expect(f.fake.object("o") != null);

    // A streamed upload whose finished object stores another checksum,
    // whose delete is refused for a hold, then for anything else.
    const opened: Reply = .{ .respond = .{ .body = "", .headers = &.{.{ .name = "Location", .value = "https://storage.example.test/upload/session/x1" }} } };
    const finished: Reply = .{ .respond = .{ .body = "{\"name\":\"a\",\"generation\":\"55\",\"crc32c\":\"AAAAAQ==\"}" } };
    var h: Harness = undefined;
    try h.init(&.{
        opened,
        finished,
        .{ .respond = .{ .status = 403, .body = held_json } },
        opened,
        finished,
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"No such object\"}}" } },
    }, .{});
    defer h.deinit();
    const obj = h.client.bucket("b").object("a");
    var held: std.Io.Reader = .fixed("hello world\n");
    try testing.expectError(error.ChecksumMismatch, obj.uploadFrom(&held, .{}));
    try testing.expect(std.mem.endsWith(u8, h.diag.message(), "; the object stays, kept by its bucket's retention policy or a hold"));
    var gone: std.Io.Reader = .fixed("hello world\n");
    try testing.expectError(error.ChecksumMismatch, obj.uploadFrom(&gone, .{}));
    try testing.expect(std.mem.endsWith(u8, h.diag.message(), "; the object could not be deleted again"));
}

test "a parallel upload with conditions whose destination is held is refused at the move, and its temporary object goes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.bucket(.{});
    var held = try f.object("o").upload("held", .{ .temporary_hold = true });
    defer held.deinit();
    var data: [9000]u8 = undefined;
    @memset(&data, 't');
    try testing.expectError(error.ObjectRetained, f.object("o").uploadParallel(.{ .data = &data }, .{
        .part_size = 4096,
        .preconditions = .{ .if_generation_match = held.value.generation },
    }));
    try testing.expectEqual(1, f.fake.counts.moves);
    try testing.expectEqual(1, f.fake.objects.items.len);
    try testing.expectEqualStrings("held", f.fake.object("o").?.bytes);
}

/// Fails every bucket request: a caller who may not read the bucket.
const BucketUnreadable = struct {
    fn plan(self: *BucketUnreadable) FakeMultipart.FaultPlan {
        return .{ .ctx = self, .decide = decide };
    }

    fn decide(_: ?*anyopaque, kind: FakeMultipart.Kind, _: u32) FakeMultipart.Fault {
        return if (kind == .bucket) .unavailable else .none;
    }
};

test "a parallel upload with conditions that cannot read its bucket's policy strands its temporary object, and says so" {
    // The risk the fallback takes away, for a caller who cannot read the
    // bucket: the finished temporary object is retained, so its move and
    // its delete are both refused.
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.bucket(.{ .retention_period_s = 3600 });
    var unreadable: BucketUnreadable = .{};
    f.fake.faults = unreadable.plan();
    var data: [9000]u8 = undefined;
    @memset(&data, 'u');
    try testing.expectError(error.ObjectRetained, f.object("o").uploadParallel(.{ .data = &data }, .{ .part_size = 4096, .preconditions = .does_not_exist }));
    // Cloud Storage's own words name the stranded object, and when it can
    // go.
    try testing.expect(std.mem.startsWith(u8, f.diag.message(), "Object 'b/zig-gcp-tmp/"));
    try testing.expect(std.mem.endsWith(u8, f.diag.message(), "cannot be deleted or overwritten until 2026-09-30T01:00:00.001Z"));
    try testing.expectEqual(1, f.fake.counts.moves);
    try testing.expectEqual(null, f.fake.object("o"));
    try testing.expectEqual(1, f.fake.objects.items.len);
    try testing.expect(std.mem.startsWith(u8, f.fake.objects.items[0].name, "zig-gcp-tmp/"));
}

test "a parallel upload over a retained object is refused at its finish; a hold change under a stale condition is 412" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.bucket(.{ .retention_period_s = 3600 });
    var kept = try f.object("o").upload("kept", .{});
    defer kept.deinit();
    var data: [9000]u8 = undefined;
    @memset(&data, 'v');
    try testing.expectError(error.ObjectRetained, f.object("o").uploadParallel(.{ .data = &data }, .{ .part_size = 4096 }));
    try testing.expectEqualStrings("RetentionPolicyNotMet", f.diag.status());
    try testing.expectEqual(0, f.fake.openUploads());
    try testing.expectError(error.FailedPrecondition, f.object("o").updateMetadata(.{
        .temporary_hold = true,
        .preconditions = .{ .if_metageneration_match = kept.value.metageneration + 1 },
    }));
    try testing.expectEqual(null, f.fake.object("o").?.holds.temporary);
}

// Milestone 2: Bucket Lock and object retention.

const unlocked_until = "2026-10-01T00:00:00Z";

test "golden: object retention goes out with an upload, a compose, a copy and a patch, and comes back" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"a\",\"generation\":\"7\",\"metageneration\":\"1\",\"retention\":{\"retainUntilTime\":\"2026-10-01T00:00:00Z\",\"mode\":\"Unlocked\"},\"retentionExpirationTime\":\"2026-10-01T00:00:00Z\"}" } },
        .{ .respond = .{ .body = "{\"name\":\"a\",\"generation\":\"8\",\"metageneration\":\"1\",\"retention\":{\"retainUntilTime\":\"2026-10-01T00:00:00Z\",\"mode\":\"Locked\"}}" } },
        .{ .respond = .{ .body = "{\"name\":\"a\",\"generation\":\"9\",\"metageneration\":\"1\",\"contentType\":\"text/plain\"}" } },
        .{ .respond = .{ .body = "{\"done\":true,\"resource\":{\"name\":\"c\",\"generation\":\"10\",\"metageneration\":\"1\"}}" } },
        .{ .respond = .{ .body = "{\"name\":\"a\",\"generation\":\"9\",\"metageneration\":\"2\"}" } },
        .{ .respond = .{ .body = "{\"name\":\"a\",\"generation\":\"9\",\"metageneration\":\"3\"}" } },
    }, .{});
    defer h.deinit();
    const obj = h.client.bucket("b").object("a");
    const kept: types.ObjectRetention = .{ .mode = .unlocked, .retain_until = unlocked_until };

    var one = try obj.upload("kept", .{ .retention = kept });
    defer one.deinit();
    try testing.expect(std.mem.indexOf(u8, (try h.fake.streamRequest(0)).body_prefix, "\"retention\":{\"mode\":\"Unlocked\",\"retainUntilTime\":\"2026-10-01T00:00:00Z\"}}") != null);
    try testing.expectEqual(.unlocked, one.value.retention.?.mode);
    try testing.expectEqualStrings(unlocked_until, one.value.retention.?.retain_until);
    try testing.expectEqualStrings(unlocked_until, one.value.retention_expiration_time.?);

    var composed = try obj.composeFrom(&.{.{ .name = "x" }}, .{ .retention = .{ .mode = .locked, .retain_until = unlocked_until } });
    defer composed.deinit();
    try testing.expectEqualStrings(
        "{\"sourceObjects\":[{\"name\":\"x\"}],\"destination\":{\"contentType\":\"application/octet-stream\",\"retention\":{\"mode\":\"Locked\",\"retainUntilTime\":\"2026-10-01T00:00:00Z\"}}}",
        (try h.fake.request(0)).body.?,
    );
    try testing.expectEqual(.locked, composed.value.retention.?.mode);

    // A copy never carries its source's: naming one is a change.
    var copied = try obj.copyTo(h.client.bucket("b").object("c"), .{ .retention = kept });
    defer copied.deinit();
    try testing.expectEqualStrings("{\"contentType\":\"text/plain\",\"retention\":{\"mode\":\"Unlocked\",\"retainUntilTime\":\"2026-10-01T00:00:00Z\"}}", (try h.fake.request(2)).body.?);

    // An extension needs no override; a removal sends both fields null,
    // with it.
    var extended = try obj.updateMetadata(.{ .retention = .{ .set = kept } });
    defer extended.deinit();
    try testing.expectEqualStrings("https://storage.googleapis.com/storage/v1/b/b/o/a", (try h.fake.request(3)).url);
    var removed = try obj.updateMetadata(.{ .retention = .clear, .override_unlocked_retention = true, .preconditions = .{ .if_metageneration_match = 2 } });
    defer removed.deinit();
    const removal = try h.fake.request(4);
    try testing.expectEqualStrings("https://storage.googleapis.com/storage/v1/b/b/o/a?ifMetagenerationMatch=2&overrideUnlockedRetention=true", removal.url);
    try testing.expectEqualStrings("{\"retention\":{\"mode\":null,\"retainUntilTime\":null}}", removal.body.?);
}

test "golden: a bucket with object retention, and a lock, on the wire" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"b\",\"metageneration\":\"1\",\"objectRetention\":{\"mode\":\"Enabled\"}}" } },
        .{ .respond = .{ .body = "{\"name\":\"b\",\"metageneration\":\"5\",\"retentionPolicy\":{\"retentionPeriod\":\"60\",\"effectiveTime\":\"2026-09-30T22:58:19.243Z\",\"isLocked\":true}}" } },
    }, .{});
    defer h.deinit();
    var created = try h.client.bucket("b").create(.{ .object_retention = true });
    defer created.deinit();
    try testing.expect(created.value.object_retention);
    try h.expectRequest(0, .POST, "https://storage.googleapis.com/storage/v1/b?project=extractctl&enableObjectRetention=true", "{\"name\":\"b\",\"location\":\"US\",\"storageClass\":\"STANDARD\"}");
    var locked = try h.client.bucket("b").lockRetentionPolicy(4);
    defer locked.deinit();
    try h.expectRequest(1, .POST, "https://storage.googleapis.com/storage/v1/b/b/lockRetentionPolicy?ifMetagenerationMatch=4", null);
    try testing.expect(locked.value.retention_policy.?.locked);
    try testing.expect((try h.fake.request(1)).header(idempotency_header) != null);
}

const idempotency_header = @import("idempotency.zig").header_name;

test "checks: an object's retention needs a known mode, a time with a zone, and no event-based hold beside it" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const obj = h.client.bucket("b").object("a");
    const Case = struct { retention: types.ObjectRetention, event_based_hold: ?bool = null, says: []const u8 };
    const cases = [_]Case{
        .{ .retention = .{ .mode = .unknown, .retain_until = unlocked_until }, .says = "does not know" },
        .{ .retention = .{ .mode = .unlocked, .retain_until = "2026-10-01T00:00:00" }, .says = "with Z or an offset" },
        .{ .retention = .{ .mode = .unlocked, .retain_until = "tomorrow" }, .says = "RFC 3339" },
        .{ .retention = .{ .mode = .locked, .retain_until = unlocked_until }, .event_based_hold = true, .says = "event-based hold" },
    };
    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.says});
        try testing.expectError(error.InvalidArgument, obj.upload("x", .{ .retention = case.retention, .event_based_hold = case.event_based_hold }));
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), case.says) != null);
        try testing.expectError(error.InvalidComposeSources, obj.composeFrom(&.{.{ .name = "x" }}, .{ .retention = case.retention, .event_based_hold = case.event_based_hold }));
        try testing.expectError(error.InvalidMetadataUpdate, obj.copyTo(obj, .{ .retention = case.retention, .event_based_hold = case.event_based_hold }));
        try testing.expectError(error.InvalidMetadataUpdate, obj.updateMetadata(.{ .retention = .{ .set = case.retention }, .event_based_hold = case.event_based_hold }));
    }
    // A hold released beside a retention is fine; nothing was sent above.
    try h.expectRequestCount(0);
    try testing.expect(checkObjectRetention(null, .{ .mode = .unlocked, .retain_until = unlocked_until }, false));
}

/// Loses the answer to the next bucket request, installed just before a
/// lock: it lands, and the client never hears.
const LoseNext = struct {
    armed: bool = true,

    fn plan(self: *LoseNext) FakeMultipart.FaultPlan {
        return .{ .ctx = self, .decide = decide };
    }

    fn decide(ctx: ?*anyopaque, kind: FakeMultipart.Kind, _: u32) FakeMultipart.Fault {
        const self: *LoseNext = @ptrCast(@alignCast(ctx.?));
        if (kind != .bucket or !self.armed) return .none;
        self.armed = false;
        return .lose_answer;
    }
};

test "lockRetentionPolicy: locks once, answers a repeat as locked, and refuses what Cloud Storage refuses" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.bucket(.{ .retention_period_s = 60 });
    const b = f.client.bucket("b");
    // Stale: 412, and nothing locks.
    try testing.expectError(error.FailedPrecondition, b.lockRetentionPolicy(7));
    // The lock lands and its answer is lost; the repeat's 400 is read back
    // as the lock's success.
    var lose: LoseNext = .{};
    f.fake.faults = lose.plan();
    var locked = try b.lockRetentionPolicy(1);
    defer locked.deinit();
    try testing.expect(locked.value.retention_policy.?.locked);
    try testing.expectEqual(2, locked.value.metageneration);
    // The stale one, the lost one, and its repeat.
    try testing.expectEqual(3, f.fake.buckets.counts.locks);
    f.fake.faults = null;

    // Locked: it may grow, never shrink or go.
    var raised = try b.update(.{ .retention_period_s = .{ .set = 90 } });
    defer raised.deinit();
    try testing.expect(raised.value.retention_policy.?.locked);
    try testing.expectError(error.PermissionDenied, b.update(.{ .retention_period_s = .{ .set = 30 } }));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "Cannot reduce retention duration of a locked Retention Policy") != null);
    try testing.expectError(error.PermissionDenied, b.update(.{ .retention_period_s = .clear }));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "has a locked Retention Policy which cannot be removed") != null);

    // A bucket with no policy keeps the refusal's own words.
    var plain = try f.client.bucket("p").create(.{});
    plain.deinit();
    try testing.expectError(error.InvalidArgument, f.client.bucket("p").lockRetentionPolicy(1));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "does not have an unlocked retention policy") != null);
}

test "object retention: kept until its time, extended freely, shortened or removed only with the override, and a locked one only extended" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.bucket(.{ .object_retention = true });
    // The fake's clock starts at midnight UTC, 2026-09-30.
    const in_a_minute = "2026-09-30T00:01:00Z";
    const in_two = "2026-09-30T00:02:00Z";
    const in_half = "2026-09-30T00:00:30Z";
    var kept = try f.object("u").upload("u", .{ .retention = .{ .mode = .unlocked, .retain_until = in_a_minute } });
    defer kept.deinit();
    try testing.expectEqualStrings("2026-09-30T00:01:00.000Z", kept.value.retention_expiration_time.?);
    try testing.expectError(error.ObjectRetained, f.object("u").delete(.{}));
    try testing.expectError(error.ObjectRetained, f.object("u").upload("over", .{}));

    var extended = try f.object("u").updateMetadata(.{ .retention = .{ .set = .{ .mode = .unlocked, .retain_until = in_two } } });
    extended.deinit();
    try testing.expectError(error.PermissionDenied, f.object("u").updateMetadata(.{ .retention = .{ .set = .{ .mode = .unlocked, .retain_until = in_half } } }));
    try testing.expectError(error.PermissionDenied, f.object("u").updateMetadata(.{ .retention = .clear }));
    try testing.expectError(error.PermissionDenied, f.object("u").updateMetadata(.{ .retention = .{ .set = .{ .mode = .locked, .retain_until = in_two } } }));
    var removed = try f.object("u").updateMetadata(.{ .retention = .clear, .override_unlocked_retention = true });
    defer removed.deinit();
    try testing.expectEqual(null, removed.value.retention);
    try f.object("u").delete(.{});

    var locked = try f.object("k").upload("k", .{ .retention = .{ .mode = .locked, .retain_until = in_a_minute } });
    locked.deinit();
    var longer = try f.object("k").updateMetadata(.{ .retention = .{ .set = .{ .mode = .locked, .retain_until = in_two } } });
    longer.deinit();
    for ([_]types.MetadataUpdate{
        .{ .retention = .{ .set = .{ .mode = .locked, .retain_until = in_a_minute } }, .override_unlocked_retention = true },
        .{ .retention = .{ .set = .{ .mode = .unlocked, .retain_until = in_two } }, .override_unlocked_retention = true },
        .{ .retention = .clear, .override_unlocked_retention = true },
    }) |update| {
        try testing.expectError(error.PermissionDenied, f.object("k").updateMetadata(update));
        try testing.expect(std.mem.indexOf(u8, f.diag.message(), "The locked object retention cannot be removed") != null);
    }
    f.advance(120);
    try f.object("k").delete(.{});

    // What only the server can refuse: a time already past, and a bucket
    // without object retention.
    try testing.expectError(error.InvalidArgument, f.object("p").upload("p", .{ .retention = .{ .mode = .unlocked, .retain_until = "2026-09-29T00:00:00Z" } }));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "cannot be in the past") != null);
    var other = try f.client.bucket("q").create(.{});
    other.deinit();
    try testing.expectError(error.InvalidArgument, f.client.bucket("q").object("p").upload("p", .{ .retention = .{ .mode = .unlocked, .retain_until = in_two } }));
}

test "the fake: retention as production takes what this library never sends" {
    // `{}` changes nothing, and an upload naming retention beside an
    // event-based hold is refused: the library sends neither, so only raw
    // requests reach them.
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.bucket(.{ .object_retention = true });
    var kept = try f.object("o").upload("o", .{ .retention = .{ .mode = .unlocked, .retain_until = "2026-09-30T00:01:00Z" } });
    kept.deinit();
    const t = f.fake.transport();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty = try t.send(.{ .method = .PATCH, .url = "https://storage.googleapis.com/storage/v1/b/b/o/o?overrideUnlockedRetention=true", .body = "{\"retention\":{}}" }, arena);
    try testing.expectEqual(200, empty.status);
    try testing.expect(f.fake.object("o").?.retention != null);
    const both = try t.send(.{
        .method = .POST,
        .url = "https://storage.googleapis.com/upload/storage/v1/b/b/o?uploadType=resumable",
        .body = "{\"name\":\"h\",\"eventBasedHold\":true,\"retention\":{\"mode\":\"Unlocked\",\"retainUntilTime\":\"2026-09-30T00:01:00Z\"}}",
    }, arena);
    try testing.expectEqual(400, both.status);
    try testing.expect(std.mem.indexOf(u8, both.body, "Retention and event based holds cannot be configured together.") != null);
}

test "lockRetentionPolicy: a 400 whose read-back fails keeps the 400 and its words" {
    const refused: Reply = .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"Bucket 'b' does not have an unlocked retention policy.\",\"errors\":[{\"reason\":\"invalid\"}]}}" } };
    var h: Harness = undefined;
    try h.init(&.{
        refused,
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"The specified bucket does not exist.\"}}" } },
        refused,
        .{ .respond = .{ .body = "{\"name\":\"b\",\"retentionPolicy\":{}}" } },
    }, .{});
    defer h.deinit();
    for (0..2) |_| {
        try testing.expectError(error.InvalidArgument, h.client.bucket("b").lockRetentionPolicy(3));
        try testing.expectEqualStrings("Bucket 'b' does not have an unlocked retention policy.", h.diag.message());
    }
}
