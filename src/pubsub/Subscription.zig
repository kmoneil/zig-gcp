//! A subscription handle: a client pointer and a short id. Making one sends
//! nothing. It borrows both, so it must not outlive the client or the memory
//! behind `id`.

const Subscription = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const iam = @import("iam.zig");
const logging = @import("logging.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const url = @import("url.zig");
const validate = @import("validate.zig");
const Error = @import("errors.zig").Error;
const Diagnostics = core.Diagnostics;
const Owned = types.Owned;

client: *Client,
/// The client builds the full name, `projects/{project}/subscriptions/{id}`.
id: []const u8,

/// Creates the subscription on `config.topic_id` in the same project.
/// Messages published before this call are not delivered to it. Every
/// setting is checked first, including the rules the emulator does not
/// enforce, so what works there does not fail in production.
pub fn create(self: Subscription, config: types.SubscriptionConfig) Error!Owned(types.SubscriptionInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "subscription", self.id);
    try rpc.checkId(c, "topic", config.topic_id);
    try validate.subscriptionConfig(config, c.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.resourcePath(a, c.project_id, .subscriptions, self.id, "");
    const topic_name = try url.resourceName(a, c.project_id, .topics, config.topic_id);
    const dead_letter: ?[]const u8 = if (config.dead_letter_policy) |policy| try topicName(a, c, policy.topic) else null;
    const body = try codec.encodeSubscription(a, topic_name, config, dead_letter);
    return fetch(c, .{ .method = .PUT, .path = path, .body = body });
}

/// Changes what `changes` names, and nothing else, and returns the
/// subscription as it is then. A policy is replaced whole, and labels as a
/// set. The topic, the ordering and the filter are fixed at creation.
pub fn update(self: Subscription, changes: types.SubscriptionUpdate) Error!Owned(types.SubscriptionInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "subscription", self.id);
    try validate.subscriptionUpdate(changes, c.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.resourcePath(a, c.project_id, .subscriptions, self.id, "");
    const dead_letter: ?[]const u8 = switch (changes.dead_letter_policy) {
        .set => |policy| try topicName(a, c, policy.topic),
        .keep, .clear => null,
    };
    const body = try codec.encodeSubscriptionUpdate(a, changes, dead_letter);
    return fetch(c, .{ .method = .PATCH, .path = path, .body = body });
}

/// A dead-letter topic as the server takes it: a full name as given, or an
/// id in the client's project.
fn topicName(arena: Allocator, c: *Client, topic: []const u8) Allocator.Error![]const u8 {
    if (validate.isTopicName(topic)) return topic;
    return url.resourceName(arena, c.project_id, .topics, topic);
}

pub fn get(self: Subscription) Error!Owned(types.SubscriptionInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "subscription", self.id);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try url.resourcePath(scratch.allocator(), c.project_id, .subscriptions, self.id, "");
    return fetch(c, .{ .method = .GET, .path = path });
}

pub fn delete(self: Subscription) Error!void {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "subscription", self.id);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try url.resourcePath(scratch.allocator(), c.project_id, .subscriptions, self.id, "");
    return rpc.executeDiscard(c, .{ .method = .DELETE, .path = path });
}

/// The subscription's IAM policy, asked for as version 3. A fresh
/// subscription's is empty, with the etag "ACAB". Needs
/// `pubsub.subscriptions.getIamPolicy`. The emulator answers every IAM call
/// `error.Unimplemented`.
pub fn iamPolicy(self: Subscription) Error!Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return r.readPolicy();
}

/// Writes `policy` as the subscription's, whole, and returns it as stored,
/// as `Topic.setIamPolicy` does. Pub/Sub takes no conditional bindings: one
/// is `error.InvalidArgument`, before sending. Needs
/// `pubsub.subscriptions.setIamPolicy`.
pub fn setIamPolicy(self: Subscription, policy: core.iam.Policy) Error!Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return iam.set(r, policy);
}

/// Grants `member` the role `role` on the subscription, unless it holds it
/// already without a condition, as `Topic.addIamBinding` does. A
/// dead-letter policy needs one: Pub/Sub's service agent,
/// `serviceAccount:service-{project number}@gcp-sa-pubsub.iam.gserviceaccount.com`,
/// with `roles/pubsub.subscriber` here and `roles/pubsub.publisher` on the
/// dead-letter topic. A subscription refuses the topic-only
/// `roles/pubsub.publisher` with `error.InvalidArgument`. Needs
/// `pubsub.subscriptions.getIamPolicy` and `setIamPolicy`.
pub fn addIamBinding(self: Subscription, role: []const u8, member: []const u8) Error!Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return iam.change(r, .{ .grant = .{ .role = role, .member = member } });
}

/// Takes `member` out of the subscription's binding of `role` without a
/// condition, unless it is not there, as `Topic.removeIamBinding` does.
pub fn removeIamBinding(self: Subscription, role: []const u8, member: []const u8) Error!Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return iam.change(r, .{ .revoke = .{ .role = role, .member = member } });
}

/// The permissions the caller holds on the subscription, of `permissions`,
/// as `Topic.testIamPermissions` answers them: such as
/// `pubsub.subscriptions.consume`.
pub fn testIamPermissions(self: Subscription, permissions: []const []const u8) Error!Owned([]const []const u8) {
    const r = try self.iamResource();
    return iam.testPermissions(r, permissions);
}

fn iamResource(self: Subscription) Error!iam.Resource {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "subscription", self.id);
    return .{ .client = c, .collection = .subscriptions, .id = self.id };
}

/// Pulls up to `options.max_messages` messages. With no messages available
/// the server may hold the request open for a while before returning none,
/// unless `options.return_immediately` is set.
pub fn pull(self: Subscription, options: types.PullOptions) Error!Owned(types.PullResult) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "subscription", self.id);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.resourcePath(a, c.project_id, .subscriptions, self.id, ":pull");
    const body = try codec.encodePull(a, validate.clampPullMessages(options.max_messages), options.return_immediately);

    var result: Owned(types.PullResult) = try .init(c.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(c, result.arena, .{ .method = .POST, .path = path, .body = body });
    result.value = codec.decodePull(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(c, err, "pull");
    return result;
}

/// Acknowledges messages. Ids that do not fit in one 512 KB request go in
/// several, and every request is sent. If the server refused any id, the
/// call then fails with the first refusal's error, and `Diagnostics` counts
/// the refused ids. A subscription with exactly-once delivery refuses an
/// ack that comes after the message's lease lapsed; `ackWithResults` says
/// which ones. An empty list sends nothing.
pub fn ack(self: Subscription, ack_ids: []const []const u8) Error!void {
    return self.sendAckIds(ack_ids, null, null);
}

/// Like `ack`, but instead of failing on a refused id, says what became of
/// each: `results[i]` for `ack_ids[i]`, and the two must be the same length.
/// `Diagnostics` describes the refusals, when there were any. An error
/// means the answer for some ids is unknown: the subscription is gone or
/// closed to these credentials, the call could not be made, or no answer
/// came after the retries. Results filled before it stay valid, and the
/// rest read `.other`.
pub fn ackWithResults(self: Subscription, ack_ids: []const []const u8, results: []types.AckResult) Error!void {
    return self.sendAckIds(ack_ids, null, results);
}

/// Sets the ack deadline of the messages to `seconds` from now, 0 to 600.
/// Splits requests and fails like `ack`.
pub fn modifyAckDeadline(self: Subscription, ack_ids: []const []const u8, seconds: u32) Error!void {
    rpc.begin(self.client);
    try validate.modifyDeadline(seconds, self.client.diagnostics);
    return self.sendAckIds(ack_ids, seconds, null);
}

/// `modifyAckDeadline` with a result per id, as `ackWithResults`.
pub fn modifyAckDeadlineWithResults(
    self: Subscription,
    ack_ids: []const []const u8,
    seconds: u32,
    results: []types.AckResult,
) Error!void {
    rpc.begin(self.client);
    try validate.modifyDeadline(seconds, self.client.diagnostics);
    return self.sendAckIds(ack_ids, seconds, results);
}

/// Makes the messages available for redelivery now: `modifyAckDeadline(ack_ids, 0)`.
pub fn nack(self: Subscription, ack_ids: []const []const u8) Error!void {
    return self.modifyAckDeadline(ack_ids, 0);
}

/// `nack` with a result per id, as `ackWithResults`.
pub fn nackWithResults(self: Subscription, ack_ids: []const []const u8, results: []types.AckResult) Error!void {
    return self.modifyAckDeadlineWithResults(ack_ids, 0, results);
}

fn sendAckIds(
    self: Subscription,
    ack_ids: []const []const u8,
    deadline_seconds: ?u32,
    results_out: ?[]types.AckResult,
) Error!void {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "subscription", self.id);
    if (results_out) |r| if (r.len != ack_ids.len) {
        if (c.diagnostics) |d| d.print("results has {d} entries for {d} ack ids; it needs one for each", .{ r.len, ack_ids.len });
        return error.InvalidArgument;
    };
    // The server rejects an empty list, and there is nothing to do.
    if (ack_ids.len == 0) return;
    try validate.ackIds(ack_ids, c.diagnostics);

    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const suffix = if (deadline_seconds == null) ":acknowledge" else ":modifyAckDeadline";
    const path = try url.resourcePath(a, c.project_id, .subscriptions, self.id, suffix);
    const fixed_bytes = (try codec.encodeAckIds(a, &.{}, deadline_seconds)).len;
    // Check every id before sending anything, so a bad id cannot leave the
    // call half done.
    for (ack_ids, 0..) |id, i| {
        if (fixed_bytes + codec.jsonStringLen(id) > validate.max_ack_request_bytes) {
            if (c.diagnostics) |d| d.print("ack id {d} is too long to fit in a request", .{i});
            return error.InvalidArgument;
        }
    }
    const results = results_out orelse try a.alloc(types.AckResult, ack_ids.len);
    // What no answer reaches, after an error, reads as unanswered.
    @memset(results, .other);
    var chunks: codec.AckChunks = .{
        .ids = ack_ids,
        .fixed_bytes = fixed_bytes,
        .max_bytes = validate.max_ack_request_bytes,
        .max_ids = validate.max_ack_ids_per_request,
    };
    var tally: Tally = .{};
    while (true) {
        const start = chunks.pos;
        // The check above rejects every id that would fail here. This stays
        // so that if the two ever disagree, the call fails, not the process.
        const chunk = chunks.next() catch |err| {
            if (c.diagnostics) |d| d.print("ack id {d} is too long to fit in a request", .{chunks.pos});
            return err;
        } orelse break;
        try self.sendChunk(path, chunk, results[start..][0..chunk.len], deadline_seconds, &tally);
    }
    if (tally.refused() == 0) return;
    tally.report(c.diagnostics, ack_ids.len);
    if (results_out == null) return tally.first.?;
}

/// Sends one request's worth of ids and gives each a result. What the
/// server refused for now is sent again, with the client's backoff and up
/// to its `max_attempts`: only the refused ids when the answer names them,
/// all of them when it does not. An id the server took is never sent
/// again: on an exactly-once subscription, production refuses a second
/// lease extension of it, and the emulator a second ack.
fn sendChunk(
    self: Subscription,
    path: []const u8,
    ids: []const []const u8,
    results: []types.AckResult,
    deadline_seconds: ?u32,
    tally: *Tally,
) Error!void {
    const c = self.client;
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    // Positions in `ids` still to send, and the ids themselves.
    const positions = try scratch.allocator().alloc(usize, ids.len);
    for (positions, 0..) |*p, i| p.* = i;
    var pending: []usize = positions;
    const send_ids = try scratch.allocator().alloc([]const u8, ids.len);

    var response: std.heap.ArenaAllocator = .init(c.gpa);
    defer response.deinit();
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        _ = response.reset(.retain_capacity);
        for (pending, 0..) |i, k| send_ids[k] = ids[i];
        const body = try codec.encodeAckIds(response.allocator(), send_ids[0..pending.len], deadline_seconds);
        var answer: ?[]const u8 = null;
        _ = rpc.execute(c, &response, .{
            .method = .POST,
            .path = path,
            .body = body,
            // This loop retries, and resends only what was not taken.
            .retry = false,
            .error_body_out = &answer,
        }) catch |err| {
            const refusal = answer orelse {
                // No answer at all, so whether the ids were taken is unknown.
                if (!core.isRetryable(err) or attempt >= c.retry.max_attempts) return err;
                try backoff(c, attempt, err, pending.len);
                continue;
            };
            switch (err) {
                // About the subscription or the caller, not about the ids.
                error.NotFound, error.PermissionDenied, error.Unauthenticated => return err,
                else => {},
            }
            var kept: usize = 0;
            var transient_reason: []const u8 = "";
            if (try exactlyOnceRefusals(response.allocator(), refusal)) |refused| {
                for (pending) |i| {
                    const value = refused.get(ids[i]) orelse {
                        // Not listed: taken. Production answers this way:
                        // a live id sent beside a lapsed one is acked,
                        // though the request as a whole is refused.
                        results[i] = .ok;
                        continue;
                    };
                    if (std.mem.startsWith(u8, value, "TRANSIENT_")) {
                        if (transient_reason.len == 0) transient_reason = value;
                        pending[kept] = i;
                        kept += 1;
                        continue;
                    }
                    results[i] = if (std.mem.eql(u8, value, "PERMANENT_FAILURE_INVALID_ACK_ID")) .invalid_ack_id else .other;
                    tally.note(results[i], err, c.diagnostics, value);
                }
            } else if (core.isRetryable(err)) {
                kept = pending.len;
            } else {
                for (pending) |i| {
                    results[i] = .other;
                    tally.note(.other, err, c.diagnostics, "");
                }
            }
            pending = pending[0..kept];
            if (pending.len == 0) return;
            if (attempt >= c.retry.max_attempts) {
                for (pending) |i| {
                    results[i] = .transient;
                    tally.note(.transient, err, c.diagnostics, transient_reason);
                }
                return;
            }
            try backoff(c, attempt, err, pending.len);
            continue;
        };
        for (pending) |i| results[i] = .ok;
        return;
    }
}

fn backoff(c: *Client, attempt: u32, err: Error, count: usize) Error!void {
    const delay_ms = c.retry.backoffMs(attempt, core.rpc.entropy(c.io));
    logging.warn("{d} ack ids were refused for now with {t}; sending them again in {d} ms (attempt {d} of {d})", .{
        count, err, delay_ms, attempt + 1, c.retry.max_attempts,
    });
    try c.io.sleep(.fromMilliseconds(delay_ms), .awake);
}

/// Pub/Sub's reason for an exactly-once refusal, whose metadata maps each
/// refused ack id to why.
const exactly_once_reason = "EXACTLY_ONCE_ACKID_FAILURE";

/// The ids an exactly-once refusal lists, each with what it says of it, or
/// null when the answer lists none, as the emulator's never do.
fn exactlyOnceRefusals(arena: Allocator, body: []const u8) Allocator.Error!?std.StringHashMapUnmanaged([]const u8) {
    var refused: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (try core.errors.decodeErrorInfos(arena, body)) |info| {
        if (!std.mem.eql(u8, info.reason, exactly_once_reason)) continue;
        for (info.metadata) |entry| try refused.put(arena, entry.key, entry.value);
    }
    return if (refused.count() > 0) refused else null;
}

/// What a call's refusals came to: counts, and the first refusal's error
/// and words, for the caller's error and for `Diagnostics`.
const Tally = struct {
    invalid: usize = 0,
    transient: usize = 0,
    other: usize = 0,
    first: ?Error = null,
    http_status: u16 = 0,
    status_buf: [Diagnostics.max_status_len]u8 = undefined,
    status_len: usize = 0,
    reason_buf: [64]u8 = undefined,
    reason_len: usize = 0,
    message_buf: [320]u8 = undefined,
    message_len: usize = 0,

    fn refused(t: *const Tally) usize {
        return t.invalid + t.transient + t.other;
    }

    /// Counts one refused id. The first also keeps its error, the reason
    /// Pub/Sub gave for it, and what `diag` says of its response.
    fn note(t: *Tally, result: types.AckResult, err: Error, diag: ?*const Diagnostics, reason: []const u8) void {
        switch (result) {
            .ok => unreachable,
            .invalid_ack_id => t.invalid += 1,
            .transient => t.transient += 1,
            .other => t.other += 1,
        }
        if (t.first != null) return;
        t.first = err;
        const r = core.errors.truncateUtf8(reason, t.reason_buf.len);
        @memcpy(t.reason_buf[0..r.len], r);
        t.reason_len = r.len;
        const d = diag orelse return;
        t.http_status = d.http_status;
        @memcpy(t.status_buf[0..d.status().len], d.status());
        t.status_len = d.status().len;
        const m = core.errors.truncateUtf8(d.message(), t.message_buf.len);
        @memcpy(t.message_buf[0..m.len], m);
        t.message_len = m.len;
    }

    /// Replaces the details of the call's last request with the whole
    /// call's: how many ids were refused, why, and the server's words.
    fn report(t: *const Tally, diag: ?*Diagnostics, total: usize) void {
        const d = diag orelse return;
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print("{d} of {d} ack ids were refused", .{ t.refused(), total }) catch {};
        if (t.reason_len > 0) w.print(" ({s})", .{t.reason_buf[0..t.reason_len]}) catch {};
        if (t.message_len > 0) w.print(": {s}", .{t.message_buf[0..t.message_len]}) catch {};
        d.set(t.http_status, t.status_buf[0..t.status_len], w.buffered());
    }
};

fn fetch(c: *Client, call: rpc.Call) Error!Owned(types.SubscriptionInfo) {
    var result: Owned(types.SubscriptionInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, call);
    result.value = codec.decodeSubscription(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "subscription");
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;

const empty_ok: test_util.FakeTransport.Reply = .{ .respond = .{ .body = "{\n}\n" } };

test "golden: create, get, delete, pull, ack, modifyAckDeadline and nack" {
    const subscription_body =
        \\{"name":"projects/p/subscriptions/work","topic":"projects/p/topics/orders",
        \\"pushConfig":{},"ackDeadlineSeconds":30,"enableMessageOrdering":true,"messageRetentionDuration":"604800s"}
    ;
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = subscription_body } },
        .{ .respond = .{ .body = subscription_body } },
        empty_ok,
        .{ .respond = .{ .body =
        \\{"receivedMessages":[{"ackId":"projects/p/subscriptions/work:7","message":{"data":"aGVsbG8=",
        \\"attributes":{"origin":"zig"},"messageId":"42","publishTime":"2026-09-18T10:00:00.123Z"},"deliveryAttempt":1}]}
        } },
        empty_ok,
        empty_ok,
        empty_ok,
    }, .{});
    defer h.deinit();
    const work = h.client.subscription("work");
    const base = "http://localhost:8085/v1/projects/p/subscriptions/work";

    var created = try work.create(.{ .topic_id = "orders", .ack_deadline_seconds = 30, .enable_message_ordering = true });
    defer created.deinit();
    try h.expectRequest(0, .PUT, base, "{\"topic\":\"projects/p/topics/orders\",\"ackDeadlineSeconds\":30,\"enableMessageOrdering\":true}");
    try testing.expectEqualStrings("projects/p/subscriptions/work", created.value.name);
    try testing.expectEqualStrings("projects/p/topics/orders", created.value.topic);
    try testing.expectEqual(30, created.value.ack_deadline_seconds);
    try testing.expect(created.value.enable_message_ordering);

    var got = try work.get();
    defer got.deinit();
    try h.expectRequest(1, .GET, base, null);

    try work.delete();
    try h.expectRequest(2, .DELETE, base, null);

    var batch = try work.pull(.{ .max_messages = 10 });
    defer batch.deinit();
    try h.expectRequest(3, .POST, base ++ ":pull", "{\"maxMessages\":10}");
    const m = batch.value.messages[0];
    try testing.expectEqualStrings("projects/p/subscriptions/work:7", m.ack_id);
    try testing.expectEqualStrings("hello", m.data);
    try testing.expectEqualStrings("zig", m.attribute("origin").?);
    try testing.expectEqualStrings("42", m.message_id);
    try testing.expectEqual(1, m.delivery_attempt);

    try work.ack(&.{m.ack_id});
    try h.expectRequest(4, .POST, base ++ ":acknowledge", "{\"ackIds\":[\"projects/p/subscriptions/work:7\"]}");

    try work.modifyAckDeadline(&.{m.ack_id}, 600);
    try h.expectRequest(5, .POST, base ++ ":modifyAckDeadline", "{\"ackIds\":[\"projects/p/subscriptions/work:7\"],\"ackDeadlineSeconds\":600}");

    try work.nack(&.{m.ack_id});
    try h.expectRequest(6, .POST, base ++ ":modifyAckDeadline", "{\"ackIds\":[\"projects/p/subscriptions/work:7\"],\"ackDeadlineSeconds\":0}");
    try h.expectRequestCount(7);
}

test "pull clamps max_messages and passes return_immediately" {
    var h: Harness = undefined;
    try h.init(&.{ empty_ok, .{ .respond = .{ .body = "" } } }, .{});
    defer h.deinit();
    const work = h.client.subscription("work");
    var none = try work.pull(.{ .max_messages = 0, .return_immediately = true });
    defer none.deinit();
    try testing.expectEqual(0, none.value.messages.len);
    try h.expectRequest(0, .POST, "http://localhost:8085/v1/projects/p/subscriptions/work:pull", "{\"maxMessages\":1,\"returnImmediately\":true}");
    // An entirely empty body is a pull with no messages.
    var blank = try work.pull(.{ .max_messages = 5000 });
    defer blank.deinit();
    try testing.expectEqual(0, blank.value.messages.len);
    try h.expectRequest(1, .POST, "http://localhost:8085/v1/projects/p/subscriptions/work:pull", "{\"maxMessages\":1000}");
}

test "ack with no ids sends nothing" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.client.subscription("work").ack(&.{});
    try h.client.subscription("work").nack(&.{});
    try h.expectRequestCount(0);
}

test "ack chunking: ids crossing 512 KB go in several requests, in order" {
    const gpa = testing.allocator;
    // 1200 ids of 1000 bytes: 1003 bytes each on the wire with quotes and a
    // comma, so 522 fit under 512 KiB with the 13-byte envelope.
    const id_count = 1200;
    const storage = try gpa.alloc(u8, id_count * 1000);
    defer gpa.free(storage);
    const ids = try gpa.alloc([]const u8, id_count);
    defer gpa.free(ids);
    for (ids, 0..) |*id, i| {
        const s = storage[i * 1000 ..][0..1000];
        @memset(s, 'a' + @as(u8, @intCast(i % 26)));
        _ = std.fmt.bufPrint(s, "{d:0>6}", .{i}) catch unreachable;
        id.* = s;
    }
    var h: Harness = undefined;
    try h.init(&.{ empty_ok, empty_ok, empty_ok }, .{});
    defer h.deinit();
    try h.client.subscription("work").ack(ids);
    try h.expectRequestCount(3);

    var seen: usize = 0;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (h.fake.requests.items, [_]usize{ 522, 522, 156 }) |r, expected| {
        try testing.expect(r.body.?.len <= 512 * 1024);
        const Body = struct { ackIds: []const []const u8 };
        const body = try std.json.parseFromSliceLeaky(Body, arena.allocator(), r.body.?, .{});
        try testing.expectEqual(expected, body.ackIds.len);
        for (body.ackIds) |id| {
            try testing.expectEqualStrings(ids[seen], id);
            seen += 1;
        }
    }
    try testing.expectEqual(id_count, seen);
}

test "ack chunking: many short ids are capped at 2500 per request" {
    const gpa = testing.allocator;
    const ids = try gpa.alloc([]const u8, 6000);
    defer gpa.free(ids);
    @memset(ids, "projects/p/subscriptions/work:1");
    var h: Harness = undefined;
    try h.init(&.{ empty_ok, empty_ok, empty_ok }, .{});
    defer h.deinit();
    try h.client.subscription("work").modifyAckDeadline(ids, 60);
    try h.expectRequestCount(3);
}

test "ack chunking: a refused chunk stops nothing; the call fails once every chunk went" {
    const gpa = testing.allocator;
    const ids = try gpa.alloc([]const u8, 5001);
    defer gpa.free(ids);
    @memset(ids, "x");
    var h: Harness = undefined;
    try h.init(&.{
        empty_ok,
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"status\":\"INVALID_ARGUMENT\",\"message\":\"Invalid ack id\"}}" } },
        empty_ok,
    }, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidArgument, h.client.subscription("work").ack(ids));
    // Every chunk was sent: the ids of the other two are none of the
    // refused request's business.
    try h.expectRequestCount(3);
    try testing.expectEqualStrings("2500 of 5001 ack ids were refused: Invalid ack id", h.diag.message());
    try testing.expectEqualStrings("INVALID_ARGUMENT", h.diag.status());
    try testing.expectEqual(400, h.diag.http_status);
}

test "ack: a too-long id anywhere in the list fails before any request" {
    // Regression: the check ran chunk by chunk, so earlier chunks were acked
    // before the call failed.
    const gpa = testing.allocator;
    const huge = try gpa.alloc(u8, 600 * 1024);
    defer gpa.free(huge);
    @memset(huge, 'z');
    const ids = try gpa.alloc([]const u8, 3001);
    defer gpa.free(ids);
    @memset(ids[0..3000], "projects/p/subscriptions/work:1");
    ids[3000] = huge;
    var h: Harness = undefined;
    try h.init(&.{ empty_ok, empty_ok }, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidArgument, h.client.subscription("work").ack(ids));
    try h.expectRequestCount(0);
    try testing.expectEqualStrings("ack id 3000 is too long to fit in a request", h.diag.message());
}

test "ack: an id too long for any request is InvalidArgument before sending" {
    const gpa = testing.allocator;
    const huge = try gpa.alloc(u8, 512 * 1024);
    defer gpa.free(huge);
    @memset(huge, 'z');
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidArgument, h.client.subscription("work").ack(&.{huge}));
    try h.expectRequestCount(0);
    try testing.expectEqualStrings("ack id 0 is too long to fit in a request", h.diag.message());
}

test "invalid arguments fail before any request" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const work = h.client.subscription("work");
    try testing.expectError(error.InvalidArgument, work.modifyAckDeadline(&.{"a"}, 601));
    try testing.expectError(error.InvalidArgument, work.ack(&.{ "a", "\xc0" }));
    try testing.expectError(error.InvalidArgument, work.create(.{ .topic_id = "orders", .ack_deadline_seconds = 9 }));
    try testing.expectError(error.InvalidResourceId, work.create(.{ .topic_id = "x" }));
    try testing.expectError(error.InvalidResourceId, h.client.subscription("s").pull(.{}));
    try testing.expectError(error.InvalidResourceId, h.client.subscription("goog-sub").ack(&.{"a"}));
    try h.expectRequestCount(0);
}

test "a subscription whose topic was deleted" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"name\":\"projects/p/subscriptions/work\",\"topic\":\"_deleted-topic_\"}" } }}, .{});
    defer h.deinit();
    var got = try h.client.subscription("work").get();
    defer got.deinit();
    try testing.expectEqualStrings("_deleted-topic_", got.value.topic);
    try testing.expectEqual(0, got.value.ack_deadline_seconds);
}

/// Production's refusal of late acks on an exactly-once subscription, as
/// captured on 2026-09-27, listing `ids` with `value`.
fn exactlyOnceRefusal(comptime status: u16, comptime api_status: []const u8, comptime value: []const u8, comptime ids: []const []const u8) test_util.FakeTransport.Reply {
    comptime var metadata: []const u8 = "";
    inline for (ids, 0..) |id, i| {
        metadata = metadata ++ (if (i > 0) "," else "") ++ "\"" ++ id ++ "\":\"" ++ value ++ "\"";
    }
    return .{ .respond = .{
        .status = status,
        .body = "{\"error\":{\"code\":" ++ std.fmt.comptimePrint("{d}", .{status}) ++
            ",\"message\":\"Some acknowledgement ids in the request were invalid. This could be because the acknowledgement ids have expired or the acknowledgement ids were malformed.\"" ++
            ",\"status\":\"" ++ api_status ++ "\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.DebugInfo\",\"detail\":\"x\"}," ++
            "{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"EXACTLY_ONCE_ACKID_FAILURE\",\"domain\":\"pubsub.googleapis.com\",\"metadata\":{" ++
            metadata ++ "}}]}}",
    } };
}

const base_url = "http://localhost:8085/v1/projects/p/subscriptions/work";

test "ackWithResults: an exactly-once refusal names what it refused, and the rest were taken" {
    const refusal = exactlyOnceRefusal(400, "INVALID_ARGUMENT", "PERMANENT_FAILURE_INVALID_ACK_ID", &.{ "late-a", "late-c" });
    var h: Harness = undefined;
    try h.init(&.{ refusal, refusal }, .{});
    defer h.deinit();
    const work = h.client.subscription("work");
    const ids = [_][]const u8{ "late-a", "live-b", "late-c", "live-d" };
    var results: [4]types.AckResult = undefined;
    logging.capture.reset();

    try work.ackWithResults(&ids, &results);
    try testing.expectEqualSlices(types.AckResult, &.{ .invalid_ack_id, .ok, .invalid_ack_id, .ok }, &results);
    // Nothing was sent again: what was taken is done, and what was refused
    // for good cannot succeed.
    try h.expectRequestCount(1);
    try testing.expectEqual(400, h.diag.http_status);
    try testing.expectEqualStrings("INVALID_ARGUMENT", h.diag.status());
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "2 of 4 ack ids were refused (PERMANENT_FAILURE_INVALID_ACK_ID): Some acknowledgement ids"));

    // `ack` says the same as an error.
    try testing.expectError(error.InvalidArgument, work.ack(&ids));
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "2 of 4 ack ids were refused (PERMANENT_FAILURE_INVALID_ACK_ID)"));

    // Ack ids are not this library's to log or repeat.
    for (ids) |id| {
        try testing.expect(std.mem.indexOf(u8, logging.capture.text(), id) == null);
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), id) == null);
    }
}

test "ackWithResults: ids refused for now are sent again, alone, until taken" {
    var h: Harness = undefined;
    try h.init(&.{
        exactlyOnceRefusal(503, "UNAVAILABLE", "TRANSIENT_FAILURE_ACK_ID", &.{"b"}),
        exactlyOnceRefusal(400, "INVALID_ARGUMENT", "TRANSIENT_FAILURE_UNORDERED_ACK_ID", &.{"b"}),
        empty_ok,
    }, .{});
    defer h.deinit();
    var results: [3]types.AckResult = undefined;
    try h.client.subscription("work").ackWithResults(&.{ "a", "b", "c" }, &results);
    try testing.expectEqualSlices(types.AckResult, &.{ .ok, .ok, .ok }, &results);
    try h.expectRequest(0, .POST, base_url ++ ":acknowledge", "{\"ackIds\":[\"a\",\"b\",\"c\"]}");
    try h.expectRequest(1, .POST, base_url ++ ":acknowledge", "{\"ackIds\":[\"b\"]}");
    try h.expectRequest(2, .POST, base_url ++ ":acknowledge", "{\"ackIds\":[\"b\"]}");
    try h.expectRequestCount(3);
    // Every id was taken in the end, so the call leaves no failure behind.
    try testing.expectEqual(0, h.diag.http_status);
}

test "ackWithResults: ids still refused for now when the retries run out" {
    const transient = exactlyOnceRefusal(503, "UNAVAILABLE", "TRANSIENT_FAILURE_ACK_ID", &.{ "b", "c" });
    var h: Harness = undefined;
    try h.init(&.{ transient, transient, transient, transient }, .{ .retry = .{ .max_attempts = 2 } });
    defer h.deinit();
    const work = h.client.subscription("work");
    var results: [3]types.AckResult = undefined;
    try work.ackWithResults(&.{ "a", "b", "c" }, &results);
    try testing.expectEqualSlices(types.AckResult, &.{ .ok, .transient, .transient }, &results);
    try h.expectRequest(1, .POST, base_url ++ ":acknowledge", "{\"ackIds\":[\"b\",\"c\"]}");
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "2 of 3 ack ids were refused (TRANSIENT_FAILURE_ACK_ID)"));
    try testing.expectEqual(503, h.diag.http_status);

    try testing.expectError(error.Unavailable, work.ack(&.{ "a", "b", "c" }));
    try h.expectRequestCount(4);
}

test "ackWithResults: a refusal that names no ids, as the emulator's, applies to them all" {
    var h: Harness = undefined;
    try h.init(&.{
        // The emulator's late ack on an exactly-once subscription.
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"\",\"status\":\"INVALID_ARGUMENT\"}}" } },
        // An ErrorInfo with another reason says nothing per id either.
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"status\":\"FAILED_PRECONDITION\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"OTHER\",\"metadata\":{\"a\":\"PERMANENT_FAILURE_INVALID_ACK_ID\"}}]}}" } },
        // Retryable with no names: the whole request goes again.
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"status\":\"UNAVAILABLE\"}}" } },
        empty_ok,
    }, .{});
    defer h.deinit();
    const work = h.client.subscription("work");
    var results: [2]types.AckResult = undefined;

    try work.ackWithResults(&.{ "a", "b" }, &results);
    try testing.expectEqualSlices(types.AckResult, &.{ .other, .other }, &results);
    try testing.expectEqualStrings("2 of 2 ack ids were refused", h.diag.message());

    try work.nackWithResults(&.{ "a", "b" }, &results);
    try testing.expectEqualSlices(types.AckResult, &.{ .other, .other }, &results);
    try testing.expectEqualStrings("FAILED_PRECONDITION", h.diag.status());

    try work.modifyAckDeadlineWithResults(&.{ "a", "b" }, 30, &results);
    try testing.expectEqualSlices(types.AckResult, &.{ .ok, .ok }, &results);
    try h.expectRequest(2, .POST, base_url ++ ":modifyAckDeadline", "{\"ackIds\":[\"a\",\"b\"],\"ackDeadlineSeconds\":30}");
    try h.expectRequest(3, .POST, base_url ++ ":modifyAckDeadline", "{\"ackIds\":[\"a\",\"b\"],\"ackDeadlineSeconds\":30}");
}

test "nack: a refusal naming no ids fails with its own status" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"status\":\"FAILED_PRECONDITION\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"OTHER\",\"metadata\":{\"a\":\"PERMANENT_FAILURE_INVALID_ACK_ID\"}}]}}" } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.FailedPrecondition, h.client.subscription("work").nack(&.{ "a", "b" }));
    try testing.expectEqualStrings("FAILED_PRECONDITION", h.diag.status());
    try testing.expectEqualStrings("2 of 2 ack ids were refused", h.diag.message());
}

test "ackWithResults: failures about the subscription or the caller end the call" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"status\":\"NOT_FOUND\",\"message\":\"Resource not found\"}}" } },
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"status\":\"PERMISSION_DENIED\"}}" } },
        .{ .respond = .{ .status = 401, .body = "{\"error\":{\"status\":\"UNAUTHENTICATED\"}}" } },
        // A 404 that also lists ids still ends the call.
        exactlyOnceRefusal(404, "NOT_FOUND", "PERMANENT_FAILURE_INVALID_ACK_ID", &.{"a"}),
    }, .{});
    defer h.deinit();
    const work = h.client.subscription("work");
    var results: [2]types.AckResult = .{ .ok, .ok };
    try testing.expectError(error.NotFound, work.ackWithResults(&.{ "a", "b" }, &results));
    // Nothing is known of the ids, so they read as unanswered.
    try testing.expectEqualSlices(types.AckResult, &.{ .other, .other }, &results);
    try testing.expectEqualStrings("Resource not found", h.diag.message());
    try testing.expectError(error.PermissionDenied, work.nackWithResults(&.{ "a", "b" }, &results));
    try testing.expectError(error.Unauthenticated, work.ack(&.{ "a", "b" }));
    try testing.expectError(error.NotFound, work.ack(&.{ "a", "b" }));
    try h.expectRequestCount(4);
}

test "ackWithResults: no answer after the retries is an error, and earlier chunks keep their results" {
    const gpa = testing.allocator;
    const ids = try gpa.alloc([]const u8, 2501);
    defer gpa.free(ids);
    @memset(ids, "x");
    const results = try gpa.alloc(types.AckResult, ids.len);
    defer gpa.free(results);
    var h: Harness = undefined;
    try h.init(&.{
        empty_ok,
        .{ .fail = error.ConnectionResetByPeer },
        .{ .fail = error.ConnectionResetByPeer },
    }, .{ .retry = .{ .max_attempts = 2 } });
    defer h.deinit();
    try testing.expectError(error.ConnectionResetByPeer, h.client.subscription("work").ackWithResults(ids, results));
    for (results[0..2500]) |r| try testing.expectEqual(.ok, r);
    try testing.expectEqual(.other, results[2500]);
    try h.expectRequestCount(3);
}

test "ackWithResults: results must hold one entry per id" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    var results: [1]types.AckResult = undefined;
    try testing.expectError(error.InvalidArgument, h.client.subscription("work").ackWithResults(&.{ "a", "b" }, &results));
    try testing.expectError(error.InvalidArgument, h.client.subscription("work").nackWithResults(&.{}, &results));
    try testing.expectError(error.InvalidArgument, h.client.subscription("work").modifyAckDeadlineWithResults(&.{"a"}, 601, &results));
    try h.expectRequestCount(0);
    // An empty list with an empty slice is a call with nothing to do.
    try h.client.subscription("work").ackWithResults(&.{}, &.{});
    try h.expectRequestCount(0);
}

test "ackWithResults: every allocation failure is OutOfMemory without leaks" {
    const Reply = test_util.FakeTransport.Reply;
    const script = [_]Reply{
        exactlyOnceRefusal(503, "UNAVAILABLE", "TRANSIENT_FAILURE_ACK_ID", &.{"b\u{e9}"}),
        exactlyOnceRefusal(400, "INVALID_ARGUMENT", "PERMANENT_FAILURE_INVALID_ACK_ID", &.{"b\u{e9}"}),
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"status\":\"INVALID_ARGUMENT\",\"message\":\"no names\"}}" } },
    };
    const Run = struct {
        fn run(gpa: Allocator, replies: []const Reply) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, replies);
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var token: core.StaticToken = .{ .token = "ya29.token" };
            var diag: Diagnostics = .{};
            var client: Client = try .init(gpa, clock.io(), .{
                .project_id = "p",
                .token_provider = token.provider(),
                .transport = fake.transport(),
                .diagnostics = &diag,
            });
            defer client.deinit();
            var results: [2]types.AckResult = undefined;
            try client.subscription("work").ackWithResults(&.{ "a", "b\u{e9}" }, &results);
            try testing.expectEqualSlices(types.AckResult, &.{ .ok, .invalid_ack_id }, &results);
            // The refusal, unless an allocation failed first: that one must
            // reach the sweep as it is.
            if (client.subscription("work").modifyAckDeadline(&.{"a"}, 10)) |_| {
                return error.TestUnexpectedResult;
            } else |err| switch (err) {
                error.InvalidArgument => {},
                else => |e| return e,
            }
            try testing.expectEqual(replies.len, fake.requests.items.len);
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{@as([]const Reply, &script)});
}

/// Drawn answers to an ack call, and a model of what the loop must do with
/// them, checked against the requests it made and the results it gave:
/// the first request carries every id; a later one carries exactly what
/// the previous answer left refused for now; an id listed as refused for
/// good, or taken, is never sent again; and each id ends as its last
/// answer says, `.other` when nothing answered it.
fn ackOutcomesProperty(_: void, input: []const u8) !void {
    const Reply = test_util.FakeTransport.Reply;
    const Kind = enum { ok, eod_400, eod_503, invalid, precondition, aborted, exhausted, internal, unavailable, not_found, denied, unauthenticated, reset, protocol, other_reason };
    const values = [_][]const u8{
        "TRANSIENT_FAILURE_ACK_ID",
        "TRANSIENT_FAILURE_UNORDERED_ACK_ID",
        "PERMANENT_FAILURE_INVALID_ACK_ID",
        "PERMANENT_FAILURE_OTHER",
        "SOMETHING_NEW",
    };
    const all_ids = [_][]const u8{ "i0", "i1", "i2", "i3", "i4", "i5" };

    var g: test_util.ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = g.intRange(usize, 1, all_ids.len);
    const ids = all_ids[0..n];
    const max_attempts = g.intRange(u8, 1, 4);

    // The script: one drawn answer per attempt the call may make.
    const kinds = try a.alloc(Kind, max_attempts);
    const listed = try a.alloc([all_ids.len]?[]const u8, max_attempts);
    const script = try a.alloc(Reply, max_attempts);
    for (kinds, listed, script) |*kind, *names, *reply| {
        kind.* = g.pick(Kind, std.enums.values(Kind));
        names.* = @splat(null);
        reply.* = switch (kind.*) {
            .ok => .{ .respond = .{ .body = "{}" } },
            .reset => .{ .fail = error.ConnectionResetByPeer },
            .protocol => .{ .fail = error.HttpProtocolError },
            .eod_400, .eod_503, .other_reason => r: {
                // Names drawn from every id, sent or not: an answer about
                // an id the request did not carry changes nothing. Under
                // another reason, the names say nothing per id at all.
                var body: std.Io.Writer.Allocating = .init(a);
                const status: u16 = if (kind.* == .eod_503) 503 else 400;
                try body.writer.print("{{\"error\":{{\"code\":{d},\"status\":\"{s}\",\"details\":[{{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"{s}\",\"metadata\":{{", .{
                    status,
                    if (status == 400) "INVALID_ARGUMENT" else "UNAVAILABLE",
                    if (kind.* == .other_reason) "SOMETHING_ELSE" else "EXACTLY_ONCE_ACKID_FAILURE",
                });
                var first = true;
                for (&all_ids, 0..) |id, i| {
                    if (!g.boolean()) continue;
                    const value = g.pick([]const u8, &values);
                    names[i] = value;
                    try body.writer.print("{s}\"{s}\":\"{s}\"", .{ if (first) "" else ",", id, value });
                    first = false;
                }
                try body.writer.writeAll("}}]}}");
                break :r .{ .respond = .{ .status = status, .body = body.written() } };
            },
            else => r: {
                const status: u16, const api: []const u8 = switch (kind.*) {
                    .invalid => .{ 400, "INVALID_ARGUMENT" },
                    .precondition => .{ 400, "FAILED_PRECONDITION" },
                    .aborted => .{ 409, "ABORTED" },
                    .exhausted => .{ 429, "RESOURCE_EXHAUSTED" },
                    .internal => .{ 500, "INTERNAL" },
                    .unavailable => .{ 503, "UNAVAILABLE" },
                    .not_found => .{ 404, "NOT_FOUND" },
                    .denied => .{ 403, "PERMISSION_DENIED" },
                    .unauthenticated => .{ 401, "UNAUTHENTICATED" },
                    else => unreachable,
                };
                const body = try a.print("{{\"error\":{{\"code\":{d},\"status\":\"{s}\"}}}}", .{ status, api });
                break :r .{ .respond = .{ .status = status, .body = body } };
            },
        };
    }

    var h: Harness = undefined;
    try h.init(script, .{ .retry = .{ .max_attempts = max_attempts } });
    defer h.deinit();
    var results: [all_ids.len]types.AckResult = undefined;
    const outcome = h.client.subscription("work").ackWithResults(ids, results[0..n]);

    // The model, walking the requests that were made.
    var expected: [all_ids.len]types.AckResult = @splat(.other);
    var expect_error = false;
    var next: std.ArrayList(usize) = .empty;
    for (0..n) |i| try next.append(a, i);
    var done = false;
    var k: usize = 0;
    while (!done) : (k += 1) {
        try testing.expect(k < h.fake.requests.items.len);
        const Body = struct { ackIds: []const []const u8 };
        const sent = try std.json.parseFromSliceLeaky(Body, a, h.fake.requests.items[k].body.?, .{});
        try testing.expectEqual(next.items.len, sent.ackIds.len);
        for (next.items, sent.ackIds) |i, id| try testing.expectEqualStrings(ids[i], id);
        const last_try = k + 1 >= max_attempts;
        var kept: std.ArrayList(usize) = .empty;
        switch (kinds[k]) {
            .ok => {
                for (next.items) |i| expected[i] = .ok;
                done = true;
            },
            .reset => if (last_try) {
                expect_error = true;
                done = true;
            } else try kept.appendSlice(a, next.items),
            .protocol, .not_found, .denied, .unauthenticated => {
                expect_error = true;
                done = true;
            },
            .invalid, .precondition, .aborted, .other_reason => {
                for (next.items) |i| expected[i] = .other;
                done = true;
            },
            .exhausted, .internal, .unavailable => if (last_try) {
                for (next.items) |i| expected[i] = .transient;
                done = true;
            } else try kept.appendSlice(a, next.items),
            .eod_400, .eod_503 => {
                var named = false;
                for (listed[k]) |v| named = named or v != null;
                if (!named) {
                    // An ErrorInfo that names nothing says nothing per id.
                    if (kinds[k] == .eod_503) {
                        if (last_try) {
                            for (next.items) |i| expected[i] = .transient;
                            done = true;
                        } else try kept.appendSlice(a, next.items);
                    } else {
                        for (next.items) |i| expected[i] = .other;
                        done = true;
                    }
                } else {
                    for (next.items) |i| {
                        const value = listed[k][i] orelse {
                            expected[i] = .ok;
                            continue;
                        };
                        if (std.mem.startsWith(u8, value, "TRANSIENT_")) {
                            try kept.append(a, i);
                        } else {
                            expected[i] = if (std.mem.eql(u8, value, "PERMANENT_FAILURE_INVALID_ACK_ID")) .invalid_ack_id else .other;
                        }
                    }
                    if (kept.items.len == 0) {
                        done = true;
                    } else if (last_try) {
                        for (kept.items) |i| expected[i] = .transient;
                        done = true;
                    }
                }
            },
        }
        if (!done) next = kept;
    }
    // No request beyond what the model allows.
    try testing.expectEqual(k, h.fake.requests.items.len);
    if (expect_error) {
        try testing.expect(std.meta.isError(outcome));
    } else {
        try outcome;
    }
    try testing.expectEqualSlices(types.AckResult, expected[0..n], results[0..n]);
}

// Named "heavy property", not "fuzz": each run builds a client and a fake
// server, so the nightly pubsub job skips it and a job of its own fuzzes it.
test "heavy property ack outcomes: every id ends as its last answer says, and what was taken is never resent" {
    // Seeds from _tmp's bytegen_seed.py, which mirrors how ByteGen reads.
    try test_util.fuzzBytes({}, ackOutcomesProperty, .{
        .corpus = &.{
            // Three ids: i1 refused for now twice, then taken; i2 refused for
            // good; i0 taken at once.
            "\x00\x00\x00\x00\x00\x00\x00\x02\x02\x00\x00\x00\x00\x00\x00\x00\x02\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x01\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
            // Refused for now until the attempts run out, with a name the
            // request never carried.
            "\x00\x00\x00\x00\x00\x00\x00\x01\x01\x00\x00\x00\x00\x00\x00\x00\x02\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x02\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
            // A dropped connection, then a 404 about the subscription.
            "\x00\x00\x00\x00\x00\x00\x00\x03\x02\x00\x00\x00\x00\x00\x00\x00\x0c\x00\x00\x00\x00\x00\x00\x00\x09\x00\x00\x00\x00\x00\x00\x00\x00",
            // A 503 naming nothing, then a refusal with a value never seen.
            "\x00\x00\x00\x00\x00\x00\x00\x05\x03\x00\x00\x00\x00\x00\x00\x00\x08\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x04\x01\x00\x00\x00\x00\x00\x00\x00\x03\x00",
            "",
        },
    });
}

test "golden: create with settings, and update" {
    const info_body =
        \\{"name":"projects/p/subscriptions/work","topic":"projects/p/topics/orders","ackDeadlineSeconds":30,
        \\"deadLetterPolicy":{"deadLetterTopic":"projects/p/topics/orders-dead","maxDeliveryAttempts":5},"labels":{"team":"zig"}}
    ;
    var h: Harness = undefined;
    try h.init(&.{ .{ .respond = .{ .body = info_body } }, .{ .respond = .{ .body = info_body } } }, .{});
    defer h.deinit();
    const work = h.client.subscription("work");

    // A dead-letter topic given as an id is named in the client's project.
    var created = try work.create(.{
        .topic_id = "orders",
        .dead_letter_policy = .{ .topic = "orders-dead" },
        .labels = &.{.{ .key = "team", .value = "zig" }},
    });
    defer created.deinit();
    try h.expectRequest(0, .PUT, base_url,
        \\{"topic":"projects/p/topics/orders","enableMessageOrdering":false,"deadLetterPolicy":{"deadLetterTopic":"projects/p/topics/orders-dead","maxDeliveryAttempts":5},"labels":{"team":"zig"}}
    );
    try testing.expectEqualStrings("zig", created.value.label("team").?);

    var updated = try work.update(.{ .ack_deadline_seconds = 30, .dead_letter_policy = .clear });
    defer updated.deinit();
    try h.expectRequest(1, .PATCH, base_url, "{\"subscription\":{\"ackDeadlineSeconds\":30},\"updateMask\":\"ackDeadlineSeconds,deadLetterPolicy\"}");
    try testing.expectEqual(30, updated.value.ack_deadline_seconds);

    // Refused before any request: nothing to change, a label the server
    // would refuse, a filter over its limit.
    try testing.expectError(error.InvalidArgument, work.update(.{}));
    try testing.expectError(error.InvalidArgument, work.create(.{ .topic_id = "orders", .labels = &.{.{ .key = "Bad", .value = "" }} }));
    try testing.expectError(error.InvalidArgument, work.create(.{ .topic_id = "orders", .filter = test_util.repeat("x", 257) }));
    try testing.expectError(error.InvalidResourceId, h.client.subscription("s").update(.{ .ack_deadline_seconds = 10 }));
    try h.expectRequestCount(2);
}

test "create and update with settings: every allocation failure is OutOfMemory without leaks" {
    const Reply = test_util.FakeTransport.Reply;
    // Escapes in the answer make std.json allocate for them, so the sweep
    // reaches those allocations too.
    const answer =
        \\{"name":"projects/p/subscriptions/work","topic":"projects/p/topics/t","filter":"attributes.k = \"\u00e9\"",
        \\"labels":{"t\u0065am":"z\u0069g"},"deadLetterPolicy":{"deadLetterTopic":"projects/p/topics/d\u0065ad"},
        \\"retryPolicy":{"minimumBackoff":"1.5s"},"expirationPolicy":{"ttl":"86400s"},"messageRetentionDuration":"600s"}
    ;
    const script = [_]Reply{ .{ .respond = .{ .body = answer } }, .{ .respond = .{ .body = answer } } };
    const Run = struct {
        fn run(gpa: Allocator, replies: []const Reply) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, replies);
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var token: core.StaticToken = .{ .token = "ya29.token" };
            var client: Client = try .init(gpa, clock.io(), .{
                .project_id = "p",
                .token_provider = token.provider(),
                .transport = fake.transport(),
            });
            defer client.deinit();
            const work = client.subscription("work");
            var created = try work.create(.{
                .topic_id = "orders",
                .filter = "attributes.k = \"\u{e9}\"",
                .dead_letter_policy = .{ .topic = "orders-dead" },
                .retry_policy = .{ .minimum = .fromMilliseconds(1500) },
                .message_retention = .fromSeconds(600),
                .expiration = .{ .after = .fromSeconds(86400) },
                .labels = &.{.{ .key = "team", .value = "zig" }},
            });
            defer created.deinit();
            try testing.expectEqualStrings("zig", created.value.label("team").?);
            var updated = try work.update(.{ .labels = &.{.{ .key = "team", .value = "zag" }}, .retry_policy = .clear });
            defer updated.deinit();
            try testing.expectEqualStrings("projects/p/topics/dead", updated.value.dead_letter_policy.?.topic);
            try testing.expectEqual(replies.len, fake.requests.items.len);
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{@as([]const Reply, &script)});
}
