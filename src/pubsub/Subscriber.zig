//! A worker loop over a subscription: pulls messages, hands each one to a
//! handler, keeps leases alive while handlers run, then acknowledges what
//! succeeded and releases what failed. Delivery is at least once: a handler
//! must tolerate the occasional duplicate, which Pub/Sub itself already
//! requires.
//!
//! ```zig
//! var subscriber = try pubsub.Subscriber.init(gpa, io, .{
//!     .subscription_id = "orders-worker",
//!     .client = .{ .project_id = "my-project", .token_provider = creds.provider() },
//!     .concurrency = 4,
//! });
//! defer subscriber.deinit();
//! try subscriber.run(handler); // until subscriber.stop(), or a fatal error
//! ```
//!
//! `run` blocks the calling task and runs everything else on tasks of its
//! own: one puller, one janitor for acknowledgements and lease extensions,
//! and `concurrency` handler tasks. Transient failures anywhere are retried
//! with backoff forever; an error retrying cannot fix, such as the
//! subscription being deleted, stops the loop and comes back from `run`.
//! A refusal that concerns single messages never stops it: an ack the
//! server refused is counted in `Stats.ack_failed`, and its message may be
//! delivered again. `stop` is safe to call from a handler or from another
//! task: the loop stops pulling, finishes the handlers already running,
//! releases what was buffered but not started, flushes acknowledgements
//! and returns.
//!
//! On a subscription with exactly-once delivery, the server refuses an
//! acknowledgement or a lease extension that comes after the lease lapsed.
//! There the subscriber extends leases by at least 60 s, extends each
//! pulled message's lease once before any handler sees it, dropping those
//! the server refuses, and retries acks the server refused only for now.
//! It learns that a subscription has exactly-once delivery by reading the
//! subscription when `run` starts, or from the first refusal that says so:
//! `roles/pubsub.subscriber` may pull and acknowledge, but not read the
//! subscription.
//!
//! A subscriber runs once. It must not be moved after `init`, and its
//! handler is called from `concurrency` tasks at once, so what the handler
//! touches must tolerate that.

const Subscriber = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const Subscription = @import("Subscription.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Diagnostics = core.Diagnostics;
const Error = errors.Error;

gpa: Allocator,
io: std.Io,
/// Owned copy of `Options.subscription_id`.
subscription_id: []const u8,
/// Pulls, on the task `run` spawns for it.
puller: Client,
/// Acknowledges, releases and extends, so a held pull never delays an ack.
janitor: Client,
concurrency: u16,
max_outstanding: u32,
extension_period_s: ?u32,
max_extension_s: u32,
/// Where `run` reports the details of a fatal failure. Borrowed.
caller_diag: ?*Diagnostics,
pull_diag: Diagnostics,
janitor_diag: Diagnostics,

// Shared state. Everything below `mutex` is guarded by it, except the
// queue, which synchronizes itself.
mutex: std.Io.Mutex,
/// Signaled when a message resolves, when `stop` is called, and when a
/// fatal error is recorded.
cond: std.Io.Condition,
queue: std.Io.Queue(*Tracked),
queue_buffer: []*Tracked,
/// Scratch for the janitor's lease snapshot, sized `max_outstanding`.
extend_buffer: [][]const u8,
/// What the server said of each id in `extend_buffer`.
extend_results: []types.AckResult,
stopping: bool,
/// Every task must end now, cancel delivered or not: `run` is being
/// canceled, or its drain is past the workers. The janitor heeds this
/// and not `stopping`, since a drain still needs leases extended and
/// resolved messages sent.
halted: bool,
ran: bool,
fatal: ?Error,
fatal_diag: Diagnostics,
/// Tests only: overrides the janitor's tick, the puller's outage backoff
/// and the backoff after an ack refused for now, which otherwise pace
/// themselves in seconds.
tick_override_ms: ?i64,
/// Tests only: overrides how long an ack refused for now is retried.
give_up_override_ms: ?i64,
/// What each lease extension sets a message's deadline to: set when `run`
/// starts, and raised to the exactly-once floor if that is learned later.
period_s: u32,
/// The subscription has exactly-once delivery, as read when `run` started
/// or learned from a refusal since.
exactly_once: bool,
/// Messages pulled and not yet resolved, in no order.
inflight: std.ArrayList(*Tracked),
/// Resolved messages' ack ids, waiting for the janitor. Each list keeps
/// room for every message in flight, so resolving never allocates; only
/// the janitor frees an id, so the ids it snapshots stay valid while it
/// sends them.
to_ack: std.ArrayList(Pending),
to_nack: std.ArrayList(Pending),
counts: Stats,

/// With exactly-once delivery, leases are extended by at least this much,
/// as every Google client does: an ack that comes after the lease lapsed
/// is refused, not taken.
const exactly_once_min_period_s = 60;
/// The lease period when the subscription cannot be read for its own.
const fallback_period_s = 60;
/// Acknowledgements and releases go out this soon after the first one
/// waits, batched with whatever came meanwhile.
const ack_delay_ms = 100;
/// An ack refused for now is retried for this long after its message
/// resolved, and then counted as failed, as Google's clients do.
const give_up_ms = 10 * std.time.ms_per_min;
/// The backoff after a refusal for now: 1 s, doubling, at most 64 s.
const first_ack_backoff_ms = 1000;
const max_ack_backoff_ms = 64_000;

/// What a handler receives and how it answers: return to acknowledge the
/// message, or return an error to release it for redelivery.
pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Called from one of `concurrency` tasks. The message and all of
        /// its fields are only valid until this returns.
        handle: *const fn (ptr: *anyopaque, io: std.Io, message: types.ReceivedMessage) anyerror!void,
    };

    pub fn handle(self: Handler, io: std.Io, message: types.ReceivedMessage) anyerror!void {
        return self.vtable.handle(self.ptr, io, message);
    }
};

pub const Options = struct {
    /// The subscription to pull from, such as "orders-worker".
    subscription_id: []const u8,
    /// How to reach the server: the subscriber runs two clients with these
    /// options. A custom `transport` here is used from two tasks at once
    /// and must tolerate that; the built-in one is per-client and safe.
    client: Client.Options,
    /// Handler tasks running at once.
    concurrency: u16 = 1,
    /// The most unresolved messages held at once, counting the ones being
    /// handled and the ones buffered. Pulling pauses at the cap.
    max_outstanding: u32 = 1000,
    /// What each lease extension sets a message's remaining deadline to,
    /// 10 to 600 seconds. Null means the subscription's own ack deadline,
    /// read once when `run` starts, or 60 s when the credentials may not
    /// read the subscription. With exactly-once delivery, at least 60 s.
    extension_period_s: ?u32 = null,
    /// How long after arrival a message's lease stops being extended. A
    /// handler stuck longer than this is presumed dead, and the server
    /// redelivers the message elsewhere.
    max_extension_s: u32 = 600,
};

/// Counters since `run` started. A consistent snapshot from `stats`. Once
/// `run` has returned after `stop`, every message received is counted
/// exactly once among `acked`, `ack_failed`, `nacked` and
/// `receipt_refused`.
pub const Stats = struct {
    /// Messages received from the server.
    received: u64 = 0,
    /// Acknowledgements the server took.
    acked: u64 = 0,
    /// Acknowledgements the server refused, or that were given up after
    /// retrying: those messages may be delivered again. Only a
    /// subscription with exactly-once delivery refuses an acknowledgement
    /// that came too late; others take it.
    ack_failed: u64 = 0,
    /// Messages released: the handler failed, or `stop` shed them.
    nacked: u64 = 0,
    /// Exactly-once delivery only: messages dropped before any handler saw
    /// them, because the server refused to extend their lease on receipt.
    /// The server delivers them again.
    receipt_refused: u64 = 0,
    /// Handler calls that returned an error.
    handler_failures: u64 = 0,
    /// Lease extensions the server took, counting each message in each
    /// batch.
    extended: u64 = 0,
};

/// Validates the options and builds the two clients. Sends nothing.
pub fn init(gpa: Allocator, io: std.Io, options: Options) Error!Subscriber {
    const diag = options.client.diagnostics;
    if (diag) |d| d.clear();
    if (!validate.isResourceId(options.subscription_id)) {
        if (diag) |d| d.print(
            "invalid subscription id: ids are 3 to 255 characters from [A-Za-z0-9-_.~+%], start with a letter, and do not start with \"goog\"",
            .{},
        );
        return error.InvalidResourceId;
    }
    if (options.concurrency == 0 or options.max_outstanding == 0 or options.max_extension_s == 0) {
        if (diag) |d| d.print("invalid subscriber options: concurrency, max_outstanding and max_extension_s must be at least 1", .{});
        return error.InvalidOptions;
    }
    if (options.extension_period_s) |period| if (period < validate.min_ack_deadline_seconds or period > validate.max_ack_deadline_seconds) {
        if (diag) |d| d.print("invalid extension_period_s: {d} to {d} seconds", .{ validate.min_ack_deadline_seconds, validate.max_ack_deadline_seconds });
        return error.InvalidOptions;
    };

    // The clients keep their diagnostics internal, because two tasks write
    // them; a fatal failure's details are copied out when `run` returns.
    var client_options = options.client;
    client_options.diagnostics = null;
    var puller: Client = try .init(gpa, io, client_options);
    errdefer puller.deinit();
    var janitor: Client = try .init(gpa, io, client_options);
    errdefer janitor.deinit();
    const subscription_id = try gpa.dupe(u8, options.subscription_id);
    errdefer gpa.free(subscription_id);
    const queue_buffer = try gpa.alloc(*Tracked, options.max_outstanding);
    errdefer gpa.free(queue_buffer);
    const extend_buffer = try gpa.alloc([]const u8, options.max_outstanding);
    errdefer gpa.free(extend_buffer);
    const extend_results = try gpa.alloc(types.AckResult, options.max_outstanding);
    errdefer gpa.free(extend_results);

    return .{
        .gpa = gpa,
        .io = io,
        .subscription_id = subscription_id,
        .puller = puller,
        .janitor = janitor,
        .concurrency = options.concurrency,
        .max_outstanding = options.max_outstanding,
        .extension_period_s = options.extension_period_s,
        .max_extension_s = options.max_extension_s,
        .caller_diag = diag,
        .pull_diag = .{},
        .janitor_diag = .{},
        .mutex = .init,
        .cond = .init,
        .queue = .init(queue_buffer),
        .queue_buffer = queue_buffer,
        .extend_buffer = extend_buffer,
        .extend_results = extend_results,
        .stopping = false,
        .halted = false,
        .ran = false,
        .fatal = null,
        .fatal_diag = .{},
        .tick_override_ms = null,
        .give_up_override_ms = null,
        .period_s = fallback_period_s,
        .exactly_once = false,
        .inflight = .empty,
        .to_ack = .empty,
        .to_nack = .empty,
        .counts = .{},
    };
}

/// `run` must have returned, or never been called.
pub fn deinit(self: *Subscriber) void {
    // Anything unresolved after a canceled run is released by its lease
    // lapsing on the server; here it is only memory.
    for (self.inflight.items) |tracked| {
        tracked.batch.release(self.gpa);
        self.gpa.free(tracked.ack_id);
        self.gpa.destroy(tracked);
    }
    self.inflight.deinit(self.gpa);
    for (self.to_ack.items) |p| self.gpa.free(p.ack_id);
    self.to_ack.deinit(self.gpa);
    for (self.to_nack.items) |p| self.gpa.free(p.ack_id);
    self.to_nack.deinit(self.gpa);
    self.gpa.free(self.extend_results);
    self.gpa.free(self.extend_buffer);
    self.gpa.free(self.queue_buffer);
    self.gpa.free(self.subscription_id);
    self.janitor.deinit();
    self.puller.deinit();
    self.* = undefined;
}

/// Stops the loop: no more pulling, handlers already running finish and
/// their messages are acknowledged or released, buffered messages are
/// released unhandled, and `run` returns. Safe to call from a handler or
/// from another task; calling it before `run` makes `run` return at once.
pub fn stop(self: *Subscriber) void {
    self.mutex.lockUncancelable(self.io);
    self.stopping = true;
    self.cond.broadcast(self.io);
    self.mutex.unlock(self.io);
    self.queue.close(self.io);
}

/// Raises the flags every task watches, so each ends even when its cancel
/// never lands: on macOS, std's unwinder can swallow a pending cancel
/// (docs/zig-std-workarounds.md), and a cancel arrives once, so a task
/// that missed its own would run on, and `run` would wait on it forever.
/// The puller watches `stopping`, the workers their closed queue, and the
/// janitor `halted`, each within a bounded wait.
fn halt(self: *Subscriber) void {
    self.mutex.lockUncancelable(self.io);
    self.stopping = true;
    self.halted = true;
    self.cond.broadcast(self.io);
    self.mutex.unlock(self.io);
    self.queue.close(self.io);
}

/// A consistent snapshot of the counters.
pub fn stats(self: *Subscriber) Stats {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.counts;
}

/// Runs until `stop` or a fatal error, blocking the calling task. A
/// subscriber runs once.
pub fn run(self: *Subscriber, handler: Handler) Error!void {
    const io = self.io;
    {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.ran) {
            if (self.caller_diag) |d| d.print("a Subscriber runs once; init another to run again", .{});
            return error.InvalidOptions;
        }
        self.ran = true;
        if (self.stopping) return;
    }
    self.puller.diagnostics = &self.pull_diag;
    self.janitor.diagnostics = &self.janitor_diag;

    // The lease period and exactly-once delivery, from the subscription
    // itself unless the period is configured. Reading it also proves the
    // subscription exists before any task starts.
    var period: u32 = self.extension_period_s orelse fallback_period_s;
    var exactly_once = false;
    if (self.extension_period_s == null) {
        if (self.puller.subscription(self.subscription_id).get()) |got| {
            var info = got;
            defer info.deinit();
            period = std.math.clamp(info.value.ack_deadline_seconds, validate.min_ack_deadline_seconds, validate.max_ack_deadline_seconds);
            exactly_once = info.value.enable_exactly_once_delivery;
        } else |err| switch (err) {
            // Allowed to pull and acknowledge, as `roles/pubsub.subscriber`
            // is, but not to read the subscription. Pulling says soon
            // enough whether even that is refused.
            error.PermissionDenied => logging.warn(
                "may not read subscription {s}, which needs pubsub.subscriptions.get ({s}); extending leases by {d} s, and learning from the server's answers whether it has exactly-once delivery",
                .{ self.subscription_id, self.pull_diag.message(), fallback_period_s },
            ),
            else => {
                if (self.caller_diag) |d| d.* = self.pull_diag;
                return err;
            },
        }
    }
    if (exactly_once) period = @max(period, exactly_once_min_period_s);
    {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.period_s = period;
        self.exactly_once = exactly_once;
    }

    var puller_task = io.concurrent(pullerLoop, .{self}) catch return concurrencyUnavailable(self);
    var puller_running = true;
    defer if (puller_running) discard(puller_task.cancel(io));
    var janitor_task = io.concurrent(janitorLoop, .{self}) catch {
        // The flags go up before the defer above cancels the puller, in
        // case that cancel never lands (docs/zig-std-workarounds.md).
        self.halt();
        return concurrencyUnavailable(self);
    };
    var janitor_running = true;
    defer if (janitor_running) discard(janitor_task.cancel(io));
    var workers: std.Io.Group = .init;
    defer workers.cancel(io);
    // Runs before the cancel above, on every way out. Before Zig 0.17, a
    // worker parked in the queue's own wait could miss a cancel: std's
    // queue, like its Condition, took a message handed over as the cancel
    // landed and dropped the cancel. A closed queue sends every worker home
    // whatever std does.
    defer self.queue.close(io);
    for (0..self.concurrency) |_| workers.concurrent(io, workerLoop, .{ self, handler }) catch {
        var d: Diagnostics = .{};
        d.print("this Io cannot run concurrent tasks, which a Subscriber needs", .{});
        self.recordFatal(error.InvalidOptions, &d);
        break;
    };

    // Wait for stop() or a fatal failure. Cancellation lands here too, and
    // the defers above take the tasks down with us. The flags go up before
    // any of them waits on a cancel: on macOS, std's unwinder can swallow
    // a task's pending cancel (docs/zig-std-workarounds.md), and a task
    // that missed its own must still find out it is over.
    errdefer self.halt();
    {
        self.mutex.lock(io) catch |err| return err;
        defer self.mutex.unlock(io);
        while (!self.stopping and self.fatal == null) try self.cond.wait(io, &self.mutex);
    }

    // Teardown, in dependency order: stop the intake, drain the workers,
    // then flush with the janitor's client once its task is gone.
    discard(puller_task.cancel(io));
    puller_running = false;
    self.queue.close(io);
    workers.await(io) catch {};
    // The janitor's work ends with the workers'. The flag goes up first,
    // in case its cancel never lands (docs/zig-std-workarounds.md).
    self.halt();
    discard(janitor_task.cancel(io));
    janitor_running = false;
    self.flush(.final) catch {};

    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    // What the last flush could not send is given up, and deinit frees it:
    // the server delivers those messages again, which at-least-once allows.
    self.counts.ack_failed += self.to_ack.items.len;
    if (self.fatal) |err| {
        if (self.caller_diag) |d| d.* = self.fatal_diag;
        return err;
    }
}

fn discard(result: std.Io.Cancelable!void) void {
    result catch {};
}

fn concurrencyUnavailable(self: *Subscriber) Error {
    if (self.caller_diag) |d| d.print("this Io cannot run concurrent tasks, which a Subscriber needs", .{});
    return error.InvalidOptions;
}

/// One pulled message, from arrival to its ack or release.
const Tracked = struct {
    /// Owned copy: it outlives the batch, in `to_ack` or `to_nack`.
    ack_id: []u8,
    message: types.ReceivedMessage,
    batch: *Batch,
    /// On the boot clock, which keeps counting while the machine sleeps.
    received_at: std.Io.Timestamp,
    /// Position in `inflight`, kept current by swapRemove.
    index: usize,
    /// The server refused to extend this message's lease, so no ack of it
    /// can be taken any more. Written and read under the mutex.
    lease_lost: bool = false,
};

/// A resolved message's ack id, waiting for the janitor.
const Pending = struct {
    ack_id: []u8,
    /// When the message resolved, on the boot clock.
    resolved_at: std.Io.Timestamp,
    /// Not sent before this: after a refusal for now, the janitor backs off.
    not_before: std.Io.Timestamp,
    /// Refusals for now so far, which set the next backoff.
    refusals: u8 = 0,
    /// The server refused to extend the lease: an ack can no longer be
    /// taken, so it is counted as failed without being sent, and a release
    /// is dropped.
    lease_lost: bool = false,
};

/// One pull's response, alive until every message in it resolves: the
/// messages' fields point into it.
const Batch = struct {
    result: types.Owned(types.PullResult),
    /// Messages still pointing into `result`. Workers release theirs at
    /// once and outside any lock, so the count is atomic: a lost decrement
    /// would keep the batch forever, a doubled one free it twice.
    live: std.atomic.Value(usize),

    fn release(batch: *Batch, gpa: Allocator) void {
        // The last release frees. acq_rel orders every holder's reads of
        // the result before the free.
        const before = batch.live.fetchSub(1, .acq_rel);
        std.debug.assert(before > 0);
        if (before > 1) return;
        batch.result.deinit();
        gpa.destroy(batch);
    }
};

fn pullerLoop(self: *Subscriber) std.Io.Cancelable!void {
    const io = self.io;
    const subscription = self.puller.subscription(self.subscription_id);
    var failures: u6 = 0;
    while (true) {
        // Flow control: wait until there is room for at least one message.
        var want: u32 = 0;
        {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            while (!self.stopping and self.inflight.items.len >= self.max_outstanding) {
                try self.cond.wait(io, &self.mutex);
            }
            if (self.stopping) return;
            want = @intCast(self.max_outstanding - self.inflight.items.len);
        }

        var result = subscription.pull(.{ .max_messages = want }) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            if (!core.isRetryable(err)) {
                self.recordFatal(err, &self.pull_diag);
                return;
            }
            // The client already retried with backoff; an error here means
            // an outage outlasting one call. Keep trying, further apart.
            failures +|= 1;
            const delay_ms = self.tick_override_ms orelse
                @min(@as(i64, 1000) << @min(failures - 1, 5), 30_000);
            logging.warn("pull failed with {t}; pulling again in {d} ms", .{ err, delay_ms });
            try io.sleep(.fromMilliseconds(delay_ms), .awake);
            continue;
        };
        failures = 0;
        if (result.value.messages.len == 0) {
            result.deinit();
            continue;
        }
        const receipts = self.receipt(subscription, result.value.messages) catch |err| {
            result.deinit();
            if (err == error.Canceled) return error.Canceled;
            self.recordFatal(err, &self.pull_diag);
            return;
        };
        defer if (receipts) |r| self.gpa.free(r);
        self.dispatch(result, receipts) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.recordFatal(error.OutOfMemory, null);
            return;
        };
    }
}

/// With exactly-once delivery, extends a pulled batch's leases once before
/// any handler sees it, as Google's clients do, and returns what the server
/// said of each message; an ack of one refused as invalid could never be
/// taken. Null when there is nothing to check: the subscription has no
/// exactly-once delivery, or the extension failed without a word per
/// message, which leaves the pull's own leases standing.
fn receipt(self: *Subscriber, subscription: Subscription, messages: []const types.ReceivedMessage) Error!?[]types.AckResult {
    const io = self.io;
    const gpa = self.gpa;
    const period = p: {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.exactly_once) return null;
        break :p self.period_s;
    };
    const ids = try gpa.alloc([]const u8, messages.len);
    defer gpa.free(ids);
    for (messages, ids) |m, *id| id.* = m.ack_id;
    const results = try gpa.alloc(types.AckResult, messages.len);
    errdefer gpa.free(results);
    subscription.modifyAckDeadlineWithResults(ids, period, results) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory, error.NotFound, error.PermissionDenied, error.Unauthenticated => return err,
        else => {
            logging.warn("extending the leases of {d} pulled messages failed with {t}; handling them anyway", .{ messages.len, err });
            gpa.free(results);
            return null;
        },
    };
    return results;
}

/// Registers a pull's messages and hands them to the workers, dropping any
/// the receipt refused as invalid. On failure partway, what was dispatched
/// resolves normally, the rest is undone, and its leases lapse on the
/// server.
fn dispatch(self: *Subscriber, pulled: types.Owned(types.PullResult), receipts: ?[]const types.AckResult) !void {
    const io = self.io;
    const gpa = self.gpa;
    var result = pulled;
    const messages = result.value.messages;
    const batch = gpa.create(Batch) catch |err| {
        result.deinit();
        return err;
    };
    batch.* = .{ .result = result, .live = .init(messages.len) };
    const now = std.Io.Timestamp.now(io, .boot);

    for (messages, 0..) |message, i| {
        if (receipts) |r| if (r[i] == .invalid_ack_id) {
            // Its lease is already gone, so no ack of it could be taken.
            // The server delivers it again, with a new ack id.
            self.mutex.lockUncancelable(io);
            self.counts.received += 1;
            self.counts.receipt_refused += 1;
            self.mutex.unlock(io);
            logging.debug("the server refused to extend the lease of {s} on receipt; dropping it for redelivery", .{message.message_id});
            batch.release(gpa);
            continue;
        };
        const failed: ?anyerror = fail: {
            const tracked = gpa.create(Tracked) catch |err| break :fail err;
            const ack_id = gpa.dupe(u8, message.ack_id) catch |err| {
                gpa.destroy(tracked);
                break :fail err;
            };
            tracked.* = .{
                .ack_id = ack_id,
                .message = message,
                .batch = batch,
                .received_at = now,
                .index = undefined,
            };
            self.mutex.lockUncancelable(io);
            tracked.index = self.inflight.items.len;
            const appended = a: {
                // Room on both lists for every message in flight and this
                // one, so that resolving it can never fail for memory.
                const room = self.inflight.items.len + 1;
                self.to_ack.ensureTotalCapacity(gpa, self.to_ack.items.len + room) catch break :a false;
                self.to_nack.ensureTotalCapacity(gpa, self.to_nack.items.len + room) catch break :a false;
                self.inflight.append(gpa, tracked) catch break :a false;
                self.assertRoom();
                break :a true;
            };
            if (appended) self.counts.received += 1;
            self.mutex.unlock(io);
            if (!appended) {
                gpa.free(ack_id);
                gpa.destroy(tracked);
                break :fail error.OutOfMemory;
            }
            self.queue.putOne(io, tracked) catch |err| switch (err) {
                // Stopping: release what the workers will never take.
                error.Closed => self.resolve(tracked, .released),
                // Canceled at the hand-off, which locks the queue: this
                // message is released as a closed queue's would be, and
                // only the ones after it never dispatch. Releasing it again
                // with them freed the batch under the messages before it.
                error.Canceled => {
                    self.resolve(tracked, .released);
                    for (i + 1..messages.len) |_| batch.release(gpa);
                    return error.Canceled;
                },
            };
            break :fail null;
        };
        if (failed) |err| {
            // This message and the rest of the batch never dispatch: drop
            // their references so the batch's memory goes with them.
            for (i..messages.len) |_| batch.release(gpa);
            return err;
        }
    }
}

const Outcome = enum { acked, released };

/// Moves a message from in flight to the janitor's ack or release list,
/// and wakes whoever waits on room or on progress. Never allocates: room
/// was kept for it when it arrived.
fn resolve(self: *Subscriber, tracked: *Tracked, outcome: Outcome) void {
    const io = self.io;
    const gpa = self.gpa;
    const now = std.Io.Timestamp.now(io, .boot);
    self.mutex.lockUncancelable(io);
    const moved = self.inflight.swapRemove(tracked.index);
    if (self.inflight.items.len > tracked.index) self.inflight.items[tracked.index].index = tracked.index;
    std.debug.assert(moved == tracked);
    const pending: Pending = .{
        .ack_id = tracked.ack_id,
        .resolved_at = now,
        .not_before = now,
        .lease_lost = tracked.lease_lost,
    };
    switch (outcome) {
        .acked => self.to_ack.appendAssumeCapacity(pending),
        .released => {
            self.to_nack.appendAssumeCapacity(pending);
            self.counts.nacked += 1;
        },
    }
    self.cond.broadcast(io);
    self.mutex.unlock(io);
    tracked.batch.release(gpa);
    gpa.destroy(tracked);
}

fn workerLoop(self: *Subscriber, handler: Handler) std.Io.Cancelable!void {
    const io = self.io;
    while (true) {
        const tracked = self.queue.getOne(io) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };
        const shedding = shed: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            break :shed self.stopping;
        };
        if (shedding) {
            self.resolve(tracked, .released);
            continue;
        }
        if (handler.handle(io, tracked.message)) {
            self.resolve(tracked, .acked);
        } else |err| {
            if (err == error.Canceled) {
                self.resolve(tracked, .released);
                return error.Canceled;
            }
            logging.debug("handler failed with {t}; releasing {s}", .{ err, tracked.message.message_id });
            self.mutex.lockUncancelable(io);
            self.counts.handler_failures += 1;
            self.mutex.unlock(io);
            self.resolve(tracked, .released);
        }
    }
}

fn janitorLoop(self: *Subscriber) std.Io.Cancelable!void {
    const io = self.io;
    var next_extension_ms = std.Io.Clock.awake.now(io).toMilliseconds() + self.tickMs();
    while (true) {
        try io.sleep(.fromMilliseconds(@min(ack_delay_ms, self.tickMs())), .awake);
        {
            // `halt` stands in for a cancel that never landed: without
            // this, a swallowed cancel would leave the loop ticking forever
            // and run() waiting on it (docs/zig-std-workarounds.md).
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.halted) return;
        }
        // A cancel that lands during a flush has to end the loop here. The
        // request that noticed it has acknowledged it, and std delivers a
        // cancel once: the sleep above would never see it again, and run()
        // would wait for this task forever.
        try self.flush(.resolved);
        const now_ms = std.Io.Clock.awake.now(io).toMilliseconds();
        if (now_ms >= next_extension_ms) {
            try self.flush(.leases);
            next_extension_ms = now_ms + self.tickMs();
        }
    }
}

/// How often leases are extended: every half period, which keeps at least
/// half a period in hand.
fn tickMs(self: *Subscriber) i64 {
    if (self.tick_override_ms) |ms| return ms;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return @max(500, @as(i64, self.period_s) * 500);
}

const Flush = enum {
    /// The acknowledgements and releases whose time has come.
    resolved,
    /// Lease extensions for what is still in flight.
    leases,
    /// Every acknowledgement and release left, backoffs or not, as `run`
    /// returns.
    final,
};

/// Sends what `what` names. Refusals of single messages are counted and
/// logged; failures the retries could not get past keep what was not sent
/// for a later flush; failures that say the subscription is gone or closed
/// to these credentials stop the subscriber. `error.Canceled` is returned,
/// never swallowed, with whatever was not sent put back.
fn flush(self: *Subscriber, what: Flush) std.Io.Cancelable!void {
    switch (what) {
        .resolved, .final => {
            try self.sendResolved(.ack, what == .final);
            try self.sendResolved(.nack, what == .final);
        },
        .leases => try self.extendLeases(),
    }
}

const IdKind = enum { ack, nack };

fn listFor(self: *Subscriber, what: IdKind) *std.ArrayList(Pending) {
    return switch (what) {
        .ack => &self.to_ack,
        .nack => &self.to_nack,
    };
}

/// Sends the acknowledgements or releases that are due, all of them when
/// `everything` is set, and settles each by what the server said of it.
fn sendResolved(self: *Subscriber, what: IdKind, everything: bool) std.Io.Cancelable!void {
    const io = self.io;
    const gpa = self.gpa;
    var due: std.ArrayList(Pending) = .empty;
    defer due.deinit(gpa);
    {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const list = self.listFor(what);
        if (list.items.len == 0) return;
        // No memory for the snapshot: the next wake tries again.
        due.ensureTotalCapacity(gpa, list.items.len) catch return;
        const now = std.Io.Timestamp.now(io, .boot);
        var i: usize = 0;
        while (i < list.items.len) {
            if (everything or list.items[i].not_before.nanoseconds <= now.nanoseconds) {
                due.appendAssumeCapacity(list.swapRemove(i));
            } else i += 1;
        }
    }
    if (due.items.len == 0) return;

    // What can still be taken goes to the server; the rest is settled here.
    const ids = gpa.alloc([]const u8, due.items.len) catch return self.keep(what, due.items);
    defer gpa.free(ids);
    const results = gpa.alloc(types.AckResult, due.items.len) catch return self.keep(what, due.items);
    defer gpa.free(results);
    var sent: usize = 0;
    for (due.items) |p| {
        if (p.lease_lost) continue;
        ids[sent] = p.ack_id;
        sent += 1;
    }
    if (sent > 0) {
        const subscription = self.janitor.subscription(self.subscription_id);
        const outcome = switch (what) {
            .ack => subscription.ackWithResults(ids[0..sent], results[0..sent]),
            .nack => subscription.nackWithResults(ids[0..sent], results[0..sent]),
        };
        outcome catch |err| {
            if (err == error.Canceled) {
                self.keep(what, due.items);
                return error.Canceled;
            }
            switch (err) {
                error.NotFound, error.PermissionDenied, error.Unauthenticated => {
                    self.keep(what, due.items);
                    return self.recordFatal(err, &self.janitor_diag);
                },
                else => {},
            }
            // No answer to be had, after the client's own retries: every
            // id is refused for now.
            logging.warn("{t} of {d} messages failed with {t}; trying again later", .{ what, sent, err });
            @memset(results[0..sent], .transient);
        };
    }
    self.settle(what, due.items, results[0..sent]);
}

/// Settles sent ids by what the server said, in `due` order, skipping the
/// ones whose lease was lost, which were not sent.
fn settle(self: *Subscriber, what: IdKind, due: []Pending, results: []const types.AckResult) void {
    const io = self.io;
    const gpa = self.gpa;
    const now = std.Io.Timestamp.now(io, .boot);
    const give_up_ns = @as(i96, self.give_up_override_ms orelse give_up_ms) * std.time.ns_per_ms;
    var taken: usize = 0;
    var refused: usize = 0;
    var given_up: usize = 0;
    var kept: usize = 0;
    var learned = false;
    var next: usize = 0;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    for (due) |p| {
        const result: types.AckResult = if (p.lease_lost) .invalid_ack_id else r: {
            defer next += 1;
            break :r results[next];
        };
        switch (result) {
            .ok => taken += 1,
            .invalid_ack_id, .other => {
                refused += 1;
                if (result == .invalid_ack_id and !p.lease_lost) learned = true;
            },
            .transient => {
                if (now.nanoseconds - p.resolved_at.nanoseconds >= give_up_ns) {
                    given_up += 1;
                } else {
                    // Kept for a later flush, compacted to the front of
                    // `due`: never ahead of the entry being read.
                    var again = p;
                    again.refusals +|= 1;
                    again.not_before = now.addDuration(.fromMilliseconds(self.ackBackoffMs(again.refusals)));
                    due[kept] = again;
                    kept += 1;
                    continue;
                }
            },
        }
        gpa.free(p.ack_id);
    }
    self.reinsert(what, due[0..kept]);
    if (what == .ack) {
        self.counts.acked += taken;
        self.counts.ack_failed += refused + given_up;
    }
    if (learned) self.learnExactlyOnce();
    if (refused + given_up > 0) {
        logging.warn("the server refused {d} of {d} {t}s, and {d} more were given up after retrying; those messages may be delivered again", .{
            refused, due.len, what, given_up,
        });
    }
    if (kept > 0) logging.debug("{d} {t}s were refused for now; trying again later", .{ kept, what });
}

/// Puts entries taken for a flush back on their list, for a later flush.
fn keep(self: *Subscriber, what: IdKind, entries: []const Pending) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.reinsert(what, entries);
}

/// Puts entries back on their list, with room kept there for every message
/// in flight besides: a plain append could take room a message in flight
/// counts on, since the puller may have registered new messages while
/// these were out of the list, and resolving one would then find none.
/// Without memory for them, they are given up: their messages come again.
/// The caller holds the mutex.
fn reinsert(self: *Subscriber, what: IdKind, entries: []const Pending) void {
    const gpa = self.gpa;
    const list = self.listFor(what);
    list.ensureTotalCapacity(gpa, list.items.len + entries.len + self.inflight.items.len) catch {
        for (entries) |p| gpa.free(p.ack_id);
        if (what == .ack) self.counts.ack_failed += entries.len;
        return;
    };
    list.appendSliceAssumeCapacity(entries);
    self.assertRoom();
}

/// Every message in flight has room on both lists, so that resolving it
/// cannot fail. The caller holds the mutex.
fn assertRoom(self: *const Subscriber) void {
    std.debug.assert(self.to_ack.capacity >= self.to_ack.items.len + self.inflight.items.len);
    std.debug.assert(self.to_nack.capacity >= self.to_nack.items.len + self.inflight.items.len);
}

/// The wait before sending again an id refused for now `refusals` times.
fn ackBackoffMs(self: *Subscriber, refusals: u8) i64 {
    const first: i64 = self.tick_override_ms orelse first_ack_backoff_ms;
    const shift: u6 = @intCast(@min(refusals -| 1, 16));
    return @min(first << shift, max_ack_backoff_ms);
}

/// Records that the subscription has exactly-once delivery, learned from a
/// refusal: leases are extended by at least 60 s from now on, and each
/// pulled message's lease is extended once before a handler sees it. The
/// caller holds the mutex.
fn learnExactlyOnce(self: *Subscriber) void {
    if (self.exactly_once) return;
    self.exactly_once = true;
    self.period_s = @max(self.period_s, exactly_once_min_period_s);
    logging.warn("subscription {s} has exactly-once delivery, as a refused acknowledgement shows; extending leases by at least {d} s", .{
        self.subscription_id, exactly_once_min_period_s,
    });
}

/// Extends the lease of every message in flight for less than
/// `max_extension_s`. A lease the server refuses to extend is lost: it is
/// extended no more, and its ack will be counted as failed without being
/// sent. A failure with no word per message leaves the leases to lapse on
/// their own, and the next tick tries again.
fn extendLeases(self: *Subscriber) std.Io.Cancelable!void {
    const io = self.io;
    var count: usize = 0;
    var period: u32 = undefined;
    {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        period = self.period_s;
        // The ids stay valid outside the lock: only this task frees them.
        const cutoff_ns = @as(i96, self.max_extension_s) * std.time.ns_per_s;
        const now = std.Io.Timestamp.now(io, .boot);
        for (self.inflight.items) |tracked| {
            if (tracked.lease_lost) continue;
            if (now.nanoseconds - tracked.received_at.nanoseconds > cutoff_ns) continue;
            self.extend_buffer[count] = tracked.ack_id;
            count += 1;
        }
    }
    if (count == 0) return;
    const ids = self.extend_buffer[0..count];
    const results = self.extend_results[0..count];
    self.janitor.subscription(self.subscription_id).modifyAckDeadlineWithResults(ids, period, results) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        switch (err) {
            error.NotFound, error.PermissionDenied, error.Unauthenticated => return self.recordFatal(err, &self.janitor_diag),
            else => {},
        }
        // The leases still stand until the deadline; the next tick tries
        // again.
        logging.warn("extending {d} leases failed with {t}", .{ count, err });
        return;
    };

    var taken: usize = 0;
    var lost: usize = 0;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    for (ids, results) |id, result| switch (result) {
        .ok => taken += 1,
        // Refused for now: the lease still stands, and the next tick tries
        // again.
        .transient => {},
        .invalid_ack_id, .other => {
            // Found only if it is still in flight; one that resolved since
            // has its ack refused the ordinary way.
            for (self.inflight.items) |tracked| {
                if (tracked.ack_id.ptr != id.ptr) continue;
                tracked.lease_lost = true;
                lost += 1;
                break;
            }
            if (result == .invalid_ack_id) self.learnExactlyOnce();
        },
    };
    self.counts.extended += taken;
    if (lost > 0) logging.warn("the server refused to extend {d} leases; their messages may be delivered again", .{lost});
    if (taken > 0) logging.debug("extended {d} leases to {d} s", .{ taken, period });
}

/// Records the first fatal error with the diagnostics that explain it, and
/// stops the loop.
fn recordFatal(self: *Subscriber, err: Error, diag: ?*const Diagnostics) void {
    const io = self.io;
    logging.warn("stopping: {t}", .{err});
    self.mutex.lockUncancelable(io);
    if (self.fatal == null) {
        self.fatal = err;
        if (diag) |d| self.fatal_diag = d.*;
    }
    self.stopping = true;
    self.cond.broadcast(io);
    self.mutex.unlock(io);
    self.queue.close(io);
}

// Tests drive a real subscriber, with all of its tasks, against an
// in-memory Pub/Sub behind the `Transport` seam: deliveries block until a
// test publishes, and every acknowledgement, release and lease extension
// is recorded. Unlike `FakeTransport`, this one is safe to use from the
// subscriber's tasks at once.

const testing = std.testing;
const test_util = @import("test_util.zig");
const Transport = core.transport.Transport;
const TransportError = core.transport.Error;
const Request = core.transport.Request;
const Response = core.transport.Response;

const FakePubSub = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Wakes pulls blocked on an empty backlog.
    cond: std.Io.Condition = .init,
    pending: std.ArrayList(Msg) = .empty,
    /// Delivered and not yet acknowledged, by ack id.
    leased: std.StringHashMapUnmanaged(Msg) = .empty,
    /// Every acknowledged ack id, in order.
    acked: std.ArrayList([]u8) = .empty,
    /// Every modifyAckDeadline entry, releases (0 seconds) included.
    modacks: std.ArrayList(Modack) = .empty,
    /// The maxMessages of each pull request, in order.
    pull_wants: std.ArrayList(u32) = .empty,
    ack_calls: usize = 0,
    next_id: usize = 0,
    ack_deadline_s: u32 = 10,
    /// Fail this many pull requests with `fail_status` before behaving.
    fail_pulls: usize = 0,
    /// Fail this many acknowledge requests with `fail_status`.
    fail_acks: usize = 0,
    fail_status: u16 = 503,
    /// Answer this many pulls with no messages at all before holding, as
    /// the real server ends a long poll empty-handed at times.
    empty_pulls: usize = 0,
    /// Hold this many acknowledge requests open until they are canceled, as
    /// a server that stopped answering would. Later ones answer normally.
    hold_acks: usize = 0,
    /// Acknowledge requests being held right now.
    held_acks: usize = 0,
    /// Exactly-once delivery, as production does it: leases lapse, a
    /// message whose lease lapsed comes again under a new ack id, an ack or
    /// lease extension that comes too late is refused with a per-id answer
    /// while the rest of its request is taken, and a second ack of an
    /// acknowledged message is taken.
    exactly_once: bool = false,
    /// With `exactly_once`: how long every lease lasts, pulled or extended,
    /// whatever the request asks. Null means what it asks.
    lease_ms: ?i64 = null,
    /// Answer reads of the subscription with 403, as for an account that
    /// may only pull and acknowledge.
    refuse_get: bool = false,
    /// With `exactly_once`: answer this many acknowledge requests with a
    /// 503 that names every id as refused for now, taking none.
    transient_acks: usize = 0,
    /// With `exactly_once`: refuse every id of this many acknowledge
    /// requests as invalid, taking none and lapsing nothing.
    refuse_acks: usize = 0,
    /// With `exactly_once`: refuse every id of this many modifyAckDeadline
    /// requests as invalid, and lapse their leases.
    refuse_modacks: usize = 0,
    /// The data of every message acknowledged, in order. Owned.
    acked_data: std.ArrayList([]u8) = .empty,
    /// Every id any acknowledge request carried, taken or not, in order.
    /// Owned.
    ack_attempts: std.ArrayList([]u8) = .empty,
    /// Fail this many modifyAckDeadline requests with `fail_status`.
    fail_modacks: usize = 0,
    /// Drop the connection of this many acknowledge, or modifyAckDeadline,
    /// requests before any answer, as a network would.
    drop_acks: usize = 0,
    drop_modacks: usize = 0,
    /// The data of every message published, in order: what a seek back
    /// brings again. Owned.
    log: std.ArrayList([]u8) = .empty,
    /// Ack ids a seek made stale. An ack or a lease change with one is
    /// taken and forgotten, as production's were on 2026-10-10, with
    /// exactly-once delivery and without. Owned.
    stale: std.ArrayList([]u8) = .empty,
    /// Detached, as production's subscription is seconds after a detach:
    /// pull, acknowledge and modifyAckDeadline are refused in its words.
    detached: bool = false,

    const detached_reply: Response = .{
        .status = 400,
        .body = "{\"error\":{\"code\":400,\"message\":\"This method is not supported on detached subscriptions.\",\"status\":\"FAILED_PRECONDITION\"}}",
    };

    const Msg = struct {
        data: []u8,
        ack_id: []u8,
        /// On the awake clock. Only exactly-once leases lapse.
        lease_until_ms: i64 = std.math.maxInt(i64),
    };
    const Modack = struct { ack_id: []u8, seconds: u32 };

    fn init(gpa: Allocator, io: std.Io) FakePubSub {
        return .{ .gpa = gpa, .io = io };
    }

    fn deinit(f: *FakePubSub) void {
        for (f.pending.items) |m| {
            f.gpa.free(m.data);
            f.gpa.free(m.ack_id);
        }
        f.pending.deinit(f.gpa);
        var it = f.leased.valueIterator();
        while (it.next()) |m| {
            f.gpa.free(m.data);
            f.gpa.free(m.ack_id);
        }
        f.leased.deinit(f.gpa);
        for (f.acked.items) |id| f.gpa.free(id);
        f.acked.deinit(f.gpa);
        for (f.acked_data.items) |data| f.gpa.free(data);
        f.acked_data.deinit(f.gpa);
        for (f.ack_attempts.items) |id| f.gpa.free(id);
        f.ack_attempts.deinit(f.gpa);
        for (f.modacks.items) |m| f.gpa.free(m.ack_id);
        f.modacks.deinit(f.gpa);
        f.pull_wants.deinit(f.gpa);
        for (f.log.items) |data| f.gpa.free(data);
        f.log.deinit(f.gpa);
        for (f.stale.items) |id| f.gpa.free(id);
        f.stale.deinit(f.gpa);
        f.* = undefined;
    }

    fn transport(f: *FakePubSub) Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    /// Makes a message available for the next pull.
    fn publish(f: *FakePubSub, data: []const u8) !void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        try f.log.ensureUnusedCapacity(f.gpa, 1);
        const kept = try f.gpa.dupe(u8, data);
        errdefer f.gpa.free(kept);
        const copy = try f.gpa.dupe(u8, data);
        errdefer f.gpa.free(copy);
        const ack_id = try f.gpa.print("ack-{d}", .{f.next_id});
        errdefer f.gpa.free(ack_id);
        try f.pending.append(f.gpa, .{ .data = copy, .ack_id = ack_id });
        f.next_id += 1;
        f.log.appendAssumeCapacity(kept);
        f.cond.broadcast(f.io);
    }

    /// A seek back to before everything, on a subscription that retains
    /// what it acknowledged: every message published comes again under a
    /// new ack id, whether it was acknowledged, out on a lease or still
    /// waiting, and every ack id handed out before is stale. Applied at
    /// once, where production took 2 to 50 seconds.
    fn seekBack(f: *FakePubSub) !void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        try f.forgetDeliveries();
        try f.pending.ensureUnusedCapacity(f.gpa, f.log.items.len);
        for (f.log.items) |data| {
            const copy = try f.gpa.dupe(u8, data);
            errdefer f.gpa.free(copy);
            const ack_id = try f.gpa.print("ack-{d}", .{f.next_id});
            f.next_id += 1;
            f.pending.appendAssumeCapacity(.{ .data = copy, .ack_id = ack_id });
        }
        f.cond.broadcast(f.io);
    }

    /// A seek ahead of everything: what waits is dropped, and what is out
    /// on a lease is acknowledged by the seek, its ack id stale. What is
    /// published afterwards is delivered: a seek is no standing filter.
    fn seekAhead(f: *FakePubSub) !void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        try f.forgetDeliveries();
    }

    /// Drops the backlog, and makes every lease's ack id stale. The caller
    /// holds the mutex.
    fn forgetDeliveries(f: *FakePubSub) !void {
        try f.stale.ensureUnusedCapacity(f.gpa, f.leased.count());
        for (f.pending.items) |m| {
            f.gpa.free(m.data);
            f.gpa.free(m.ack_id);
        }
        f.pending.clearRetainingCapacity();
        var it = f.leased.valueIterator();
        while (it.next()) |m| {
            f.gpa.free(m.data);
            // The id is the lease's key too: it moves to the stale list.
            f.stale.appendAssumeCapacity(m.ack_id);
        }
        f.leased.clearRetainingCapacity();
    }

    fn isStale(f: *const FakePubSub, id: []const u8) bool {
        for (f.stale.items) |stale_id| {
            if (std.mem.eql(u8, stale_id, id)) return true;
        }
        return false;
    }

    /// Detaches the subscription: from now on a pull, a held one included,
    /// an ack and a lease change are refused.
    fn detach(f: *FakePubSub) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.detached = true;
        f.cond.broadcast(f.io);
    }

    fn isDetached(f: *FakePubSub) bool {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.detached;
    }

    /// How many acknowledgements took a message off the backlog: an ack
    /// with a stale id is taken, and takes none.
    fn ackedMessages(f: *FakePubSub) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.acked_data.items.len;
    }

    fn backlog(f: *FakePubSub) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.pending.items.len + f.leased.count();
    }

    /// How many times `ack_id` was released (a lease set to 0 seconds).
    fn releases(f: *FakePubSub, ack_id: []const u8) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        var n: usize = 0;
        for (f.modacks.items) |m| {
            if (m.seconds == 0 and std.mem.eql(u8, m.ack_id, ack_id)) n += 1;
        }
        return n;
    }

    /// How many leases were extended (a nonzero deadline).
    fn extensions(f: *FakePubSub) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        var n: usize = 0;
        for (f.modacks.items) |m| {
            if (m.seconds != 0) n += 1;
        }
        return n;
    }

    fn heldAcks(f: *FakePubSub) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.held_acks;
    }

    fn ackedCount(f: *FakePubSub) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.acked.items.len;
    }

    fn send(ptr: *anyopaque, req: Request, arena: Allocator) TransportError!Response {
        const f: *FakePubSub = @ptrCast(@alignCast(ptr));
        const settles = std.mem.endsWith(u8, req.url, ":pull") or std.mem.endsWith(u8, req.url, ":acknowledge") or
            std.mem.endsWith(u8, req.url, ":modifyAckDeadline");
        if (settles and f.isDetached()) return detached_reply;
        if (std.mem.endsWith(u8, req.url, ":pull")) return f.pull(req, arena);
        if (std.mem.endsWith(u8, req.url, ":acknowledge")) {
            if (f.take(&f.drop_acks)) return error.ConnectionResetByPeer;
            return f.acknowledge(req, arena);
        }
        if (std.mem.endsWith(u8, req.url, ":modifyAckDeadline")) {
            if (f.take(&f.drop_modacks)) return error.ConnectionResetByPeer;
            if (f.take(&f.fail_modacks)) return f.failure(arena);
            return f.modifyAckDeadline(req, arena);
        }
        if (req.method == .GET and std.mem.indexOf(u8, req.url, "/subscriptions/") != null) {
            f.mutex.lockUncancelable(f.io);
            defer f.mutex.unlock(f.io);
            if (f.refuse_get) return .{
                .status = 403,
                .body = "{\"error\":{\"code\":403,\"message\":\"User not authorized to perform this action.\",\"status\":\"PERMISSION_DENIED\"}}",
            };
            const body = try arena.print(
                "{{\"name\":\"s\",\"topic\":\"t\",\"ackDeadlineSeconds\":{d},\"enableExactlyOnceDelivery\":{}}}",
                .{ f.ack_deadline_s, f.exactly_once },
            );
            return .{ .status = 200, .body = body };
        }
        return .{ .status = 404, .body = "no such route in FakePubSub" };
    }

    /// Uses up one of `counter`, under the mutex, if any is left.
    fn take(f: *FakePubSub, counter: *usize) bool {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (counter.* == 0) return false;
        counter.* -= 1;
        return true;
    }

    fn failure(f: *FakePubSub, arena: Allocator) TransportError!Response {
        const status: []const u8 = if (f.fail_status == 404) "NOT_FOUND" else "UNAVAILABLE";
        const body = try arena.print(
            "{{\"error\":{{\"code\":{d},\"message\":\"scripted failure\",\"status\":\"{s}\"}}}}",
            .{ f.fail_status, status },
        );
        return .{ .status = f.fail_status, .body = body };
    }

    fn pull(f: *FakePubSub, req: Request, arena: Allocator) TransportError!Response {
        const Body = struct { maxMessages: u32 = 0 };
        const wanted = std.json.parseFromSliceLeaky(Body, arena, req.body orelse "{}", .{
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            // Running out of memory is not a malformed request: the
            // allocation sweeps drive this fake through a failing arena.
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.HttpProtocolError,
        };

        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        try f.sweep();
        try f.pull_wants.append(f.gpa, wanted.maxMessages);
        if (f.fail_pulls > 0) {
            f.fail_pulls -= 1;
            return f.failure(arena);
        }
        if (f.empty_pulls > 0) {
            f.empty_pulls -= 1;
            return .{ .status = 200, .body = "{\"receivedMessages\":[]}" };
        }
        // A held pull, as the real server does when there is nothing yet.
        while (f.pending.items.len == 0) {
            if (f.detached) return detached_reply;
            if (f.exactly_once and f.leased.count() > 0) {
                // Leases lapse with time, which signals nothing: look again
                // soon, as the server would hand back a lapsed message.
                f.mutex.unlock(f.io);
                const slept = f.io.sleep(.fromMilliseconds(5), .awake);
                f.mutex.lockUncancelable(f.io);
                slept catch return error.Canceled;
                try f.sweep();
            } else {
                f.cond.wait(f.io, &f.mutex) catch return error.Canceled;
            }
        }

        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        json.beginObject() catch return error.OutOfMemory;
        json.objectField("receivedMessages") catch return error.OutOfMemory;
        json.beginArray() catch return error.OutOfMemory;
        const count = @min(f.pending.items.len, @max(wanted.maxMessages, 1));
        for (f.pending.items[0..count]) |m| {
            var b64_buf: [256]u8 = undefined;
            json.beginObject() catch return error.OutOfMemory;
            json.objectField("ackId") catch return error.OutOfMemory;
            json.write(m.ack_id) catch return error.OutOfMemory;
            json.objectField("message") catch return error.OutOfMemory;
            json.beginObject() catch return error.OutOfMemory;
            json.objectField("data") catch return error.OutOfMemory;
            json.write(std.base64.standard.Encoder.encode(&b64_buf, m.data)) catch return error.OutOfMemory;
            json.objectField("messageId") catch return error.OutOfMemory;
            json.write(m.ack_id) catch return error.OutOfMemory;
            json.endObject() catch return error.OutOfMemory;
            json.endObject() catch return error.OutOfMemory;
        }
        json.endArray() catch return error.OutOfMemory;
        json.endObject() catch return error.OutOfMemory;
        const lease_until = f.nowMs() + (f.lease_ms orelse @as(i64, f.ack_deadline_s) * 1000);
        for (f.pending.items[0..count]) |m| {
            var leased = m;
            if (f.exactly_once) leased.lease_until_ms = lease_until;
            try f.leased.put(f.gpa, m.ack_id, leased);
        }
        std.mem.copyForwards(Msg, f.pending.items[0 .. f.pending.items.len - count], f.pending.items[count..]);
        f.pending.shrinkRetainingCapacity(f.pending.items.len - count);
        return .{ .status = 200, .body = out.written() };
    }

    const AckBody = struct { ackIds: []const []const u8, ackDeadlineSeconds: u32 = 0 };

    fn parseIds(req: Request, arena: Allocator) TransportError!AckBody {
        return std.json.parseFromSliceLeaky(AckBody, arena, req.body orelse "{}", .{
            .ignore_unknown_fields = true,
        }) catch error.HttpProtocolError;
    }

    fn acknowledge(f: *FakePubSub, req: Request, arena: Allocator) TransportError!Response {
        const body = try parseIds(req, arena);
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.ack_calls += 1;
        for (body.ackIds) |id| try f.ack_attempts.append(f.gpa, try f.gpa.dupe(u8, id));
        if (f.hold_acks > 0) {
            f.hold_acks -= 1;
            f.held_acks += 1;
            defer f.held_acks -= 1;
            // Nothing answers this request; only canceling it ends the wait.
            while (true) f.cond.wait(f.io, &f.mutex) catch return error.Canceled;
        }
        if (f.fail_acks > 0) {
            f.fail_acks -= 1;
            return f.failure(arena);
        }
        if (f.exactly_once) return f.acknowledgeExactlyOnce(body.ackIds, arena);
        for (body.ackIds) |id| {
            try f.acked.append(f.gpa, try f.gpa.dupe(u8, id));
            if (f.leased.fetchRemove(id)) |entry| {
                try f.acked_data.append(f.gpa, entry.value.data);
                f.gpa.free(entry.value.ack_id);
            }
        }
        return .{ .status = 200, .body = "{}" };
    }

    /// As production answers on an exactly-once subscription. The caller
    /// holds the mutex.
    fn acknowledgeExactlyOnce(f: *FakePubSub, ids: []const []const u8, arena: Allocator) TransportError!Response {
        try f.sweep();
        if (f.transient_acks > 0) {
            f.transient_acks -= 1;
            return refusal(arena, 503, ids, "TRANSIENT_FAILURE_ACK_ID");
        }
        if (f.refuse_acks > 0) {
            f.refuse_acks -= 1;
            return refusal(arena, 400, ids, "PERMANENT_FAILURE_INVALID_ACK_ID");
        }
        var refused: std.ArrayList([]const u8) = .empty;
        for (ids) |id| {
            if (f.leased.fetchRemove(id)) |entry| {
                try f.acked.append(f.gpa, try f.gpa.dupe(u8, id));
                try f.acked_data.append(f.gpa, entry.value.data);
                f.gpa.free(entry.value.ack_id);
            } else if (f.isStale(id)) {
                // Stale since a seek: taken, and forgotten.
                try f.acked.append(f.gpa, try f.gpa.dupe(u8, id));
            } else if (!f.wasAcked(id)) {
                try refused.append(arena, id);
            }
            // A second ack of an acknowledged message is taken, as
            // production takes it.
        }
        if (refused.items.len > 0) return refusal(arena, 400, refused.items, "PERMANENT_FAILURE_INVALID_ACK_ID");
        return .{ .status = 200, .body = "{}" };
    }

    fn wasAcked(f: *const FakePubSub, id: []const u8) bool {
        for (f.acked.items) |acked| {
            if (std.mem.eql(u8, acked, id)) return true;
        }
        return false;
    }

    /// Production's exactly-once refusal, naming `ids` with `value`.
    fn refusal(arena: Allocator, status: u16, ids: []const []const u8, value: []const u8) TransportError!Response {
        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        json.beginObject() catch return error.OutOfMemory;
        json.objectField("error") catch return error.OutOfMemory;
        json.beginObject() catch return error.OutOfMemory;
        json.objectField("code") catch return error.OutOfMemory;
        json.write(status) catch return error.OutOfMemory;
        json.objectField("status") catch return error.OutOfMemory;
        json.write(if (status == 503) "UNAVAILABLE" else "INVALID_ARGUMENT") catch return error.OutOfMemory;
        json.objectField("details") catch return error.OutOfMemory;
        json.beginArray() catch return error.OutOfMemory;
        json.beginObject() catch return error.OutOfMemory;
        json.objectField("@type") catch return error.OutOfMemory;
        json.write("type.googleapis.com/google.rpc.ErrorInfo") catch return error.OutOfMemory;
        json.objectField("reason") catch return error.OutOfMemory;
        json.write("EXACTLY_ONCE_ACKID_FAILURE") catch return error.OutOfMemory;
        json.objectField("metadata") catch return error.OutOfMemory;
        json.beginObject() catch return error.OutOfMemory;
        for (ids) |id| {
            json.objectField(id) catch return error.OutOfMemory;
            json.write(value) catch return error.OutOfMemory;
        }
        json.endObject() catch return error.OutOfMemory;
        json.endObject() catch return error.OutOfMemory;
        json.endArray() catch return error.OutOfMemory;
        json.endObject() catch return error.OutOfMemory;
        json.endObject() catch return error.OutOfMemory;
        return .{ .status = status, .body = out.written() };
    }

    fn nowMs(f: *const FakePubSub) i64 {
        return std.Io.Clock.awake.now(f.io).toMilliseconds();
    }

    /// Puts a leased message back on the backlog under a new ack id: the
    /// old one is gone for good. The caller holds the mutex.
    fn lapse(f: *FakePubSub, id: []const u8) !void {
        const entry = f.leased.fetchRemove(id) orelse return;
        f.gpa.free(entry.value.ack_id);
        const fresh = try f.gpa.print("ack-{d}", .{f.next_id});
        f.next_id += 1;
        try f.pending.append(f.gpa, .{ .data = entry.value.data, .ack_id = fresh });
        f.cond.broadcast(f.io);
    }

    /// Lapses every lease now, whatever its time: each message comes again
    /// under a new ack id.
    fn lapseAll(f: *FakePubSub) !void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        while (f.leased.count() > 0) {
            var it = f.leased.keyIterator();
            try f.lapse(it.next().?.*);
        }
    }

    /// Lapses every exactly-once lease whose time is up. The caller holds
    /// the mutex.
    fn sweep(f: *FakePubSub) !void {
        if (!f.exactly_once) return;
        const now = f.nowMs();
        while (true) {
            var it = f.leased.iterator();
            const expired = while (it.next()) |entry| {
                if (entry.value_ptr.lease_until_ms <= now) break entry.key_ptr.*;
            } else break;
            try f.lapse(expired);
        }
    }

    fn modifyAckDeadline(f: *FakePubSub, req: Request, arena: Allocator) TransportError!Response {
        const body = try parseIds(req, arena);
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (f.exactly_once) return f.modifyExactlyOnce(body, arena);
        for (body.ackIds) |id| {
            try f.modacks.append(f.gpa, .{
                .ack_id = try f.gpa.dupe(u8, id),
                .seconds = body.ackDeadlineSeconds,
            });
            if (body.ackDeadlineSeconds == 0) {
                // Released: back on the backlog with the same ack id.
                if (f.leased.fetchRemove(id)) |entry| {
                    try f.pending.append(f.gpa, entry.value);
                    f.cond.broadcast(f.io);
                }
            }
        }
        return .{ .status = 200, .body = "{}" };
    }

    /// As production answers on an exactly-once subscription: a lapsed,
    /// unknown or acknowledged id is refused, a live one extended or
    /// released. The caller holds the mutex.
    fn modifyExactlyOnce(f: *FakePubSub, body: AckBody, arena: Allocator) TransportError!Response {
        try f.sweep();
        for (body.ackIds) |id| try f.modacks.append(f.gpa, .{ .ack_id = try f.gpa.dupe(u8, id), .seconds = body.ackDeadlineSeconds });
        if (f.refuse_modacks > 0) {
            f.refuse_modacks -= 1;
            for (body.ackIds) |id| try f.lapse(id);
            return refusal(arena, 400, body.ackIds, "PERMANENT_FAILURE_INVALID_ACK_ID");
        }
        var refused: std.ArrayList([]const u8) = .empty;
        for (body.ackIds) |id| {
            const leased = f.leased.getPtr(id) orelse {
                // An id stale since a seek is taken, and changes nothing.
                if (!f.isStale(id)) try refused.append(arena, id);
                continue;
            };
            if (body.ackDeadlineSeconds == 0) {
                try f.lapse(id);
            } else {
                leased.lease_until_ms = f.nowMs() + (f.lease_ms orelse @as(i64, body.ackDeadlineSeconds) * 1000);
            }
        }
        if (refused.items.len > 0) return refusal(arena, 400, refused.items, "PERMANENT_FAILURE_INVALID_ACK_ID");
        return .{ .status = 200, .body = "{}" };
    }

    /// How many modifyAckDeadline entries asked for `seconds`.
    fn modacksOf(f: *FakePubSub, seconds: u32) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        var n: usize = 0;
        for (f.modacks.items) |m| {
            if (m.seconds == seconds) n += 1;
        }
        return n;
    }

    /// Whether any acknowledge request carried `ack_id`.
    fn ackAttempted(f: *FakePubSub, ack_id: []const u8) bool {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        for (f.ack_attempts.items) |id| {
            if (std.mem.eql(u8, id, ack_id)) return true;
        }
        return false;
    }

    /// How many messages acknowledged held `data`.
    fn ackedData(f: *FakePubSub, data: []const u8) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        var n: usize = 0;
        for (f.acked_data.items) |d| {
            if (std.mem.eql(u8, d, data)) n += 1;
        }
        return n;
    }
};

/// A handler for tests: records what it saw, can sleep, fail each
/// message's first delivery, count how many of it run at once, and stop
/// the subscriber after a number of successes.
const TestHandler = struct {
    gpa: Allocator,
    io: std.Io,
    subscriber: *Subscriber,
    mutex: std.Io.Mutex = .init,
    /// The data of every message a handler call returned success for.
    seen: std.ArrayList([]u8) = .empty,
    /// Data seen before, failed once each when `fail_first` is set.
    attempts: std.StringHashMapUnmanaged(usize) = .empty,
    fail_first: bool = false,
    sleep_ms: i64 = 0,
    /// Sleep this long on a message's first delivery only.
    sleep_first_ms: i64 = 0,
    /// Hold a message's first delivery until this is true of the harness,
    /// looking every 5 ms. A fixed sleep stands in for an event and races
    /// it when the machine stalls; this waits for the event itself. Panics
    /// after 10 s.
    hold_first_until: ?*const fn (*Harness) bool = null,
    active: usize = 0,
    max_active: usize = 0,
    stop_after: ?usize = null,
    /// Once this many messages were seen, the handler that saw the last of
    /// them does this to the harness before it returns: its own message is
    /// still out on its lease then, and its ack still to come.
    after_seen: ?struct { count: usize, do: *const fn (*Harness) anyerror!void } = null,

    fn deinit(h: *TestHandler) void {
        for (h.seen.items) |data| h.gpa.free(data);
        h.seen.deinit(h.gpa);
        var it = h.attempts.keyIterator();
        while (it.next()) |key| h.gpa.free(key.*);
        h.attempts.deinit(h.gpa);
    }

    fn handler(h: *TestHandler) Handler {
        return .{ .ptr = h, .vtable = &.{ .handle = handle } };
    }

    fn handle(ptr: *anyopaque, io: std.Io, message: types.ReceivedMessage) anyerror!void {
        const h: *TestHandler = @ptrCast(@alignCast(ptr));
        {
            h.mutex.lockUncancelable(io);
            h.active += 1;
            h.max_active = @max(h.max_active, h.active);
            h.mutex.unlock(io);
        }
        defer {
            h.mutex.lockUncancelable(io);
            h.active -= 1;
            h.mutex.unlock(io);
        }
        // Counted before any sleep, so a redelivery that arrives while
        // the first delivery sleeps is known as the second.
        const attempt = a: {
            h.mutex.lockUncancelable(io);
            defer h.mutex.unlock(io);
            const entry = try h.attempts.getOrPut(h.gpa, message.data);
            if (!entry.found_existing) {
                entry.key_ptr.* = try h.gpa.dupe(u8, message.data);
                entry.value_ptr.* = 0;
            }
            entry.value_ptr.* += 1;
            break :a entry.value_ptr.*;
        };
        if (h.sleep_ms > 0) try io.sleep(.fromMilliseconds(h.sleep_ms), .awake);
        if (attempt == 1 and h.sleep_first_ms > 0) try io.sleep(.fromMilliseconds(h.sleep_first_ms), .awake);
        if (attempt == 1) if (h.hold_first_until) |released| {
            const harness: *Harness = @alignCast(@fieldParentPtr("handler", h));
            const limit_ms = std.Io.Clock.awake.now(io).toMilliseconds() + 10_000;
            while (!released(harness)) {
                if (std.Io.Clock.awake.now(io).toMilliseconds() > limit_ms) {
                    @panic("a held first delivery waited 10 s for its test's event");
                }
                try io.sleep(.fromMilliseconds(5), .awake);
            }
        };

        const due = d: {
            h.mutex.lockUncancelable(io);
            defer h.mutex.unlock(io);
            if (h.fail_first and attempt == 1) return error.NotToday;
            try h.seen.append(h.gpa, try h.gpa.dupe(u8, message.data));
            if (h.stop_after) |n| if (h.seen.items.len >= n) h.subscriber.stop();
            const hook = h.after_seen orelse break :d null;
            if (h.seen.items.len != hook.count) break :d null;
            h.after_seen = null;
            break :d hook.do;
        };
        // Outside the handler's lock: what it does takes the fake's.
        if (due) |do| try do(@alignCast(@fieldParentPtr("handler", h)));
    }

    fn attemptsOf(h: *TestHandler, data: []const u8) usize {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        return h.attempts.get(data) orelse 0;
    }

    fn seenCount(h: *TestHandler) usize {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        return h.seen.items.len;
    }
};

/// A subscriber wired to a `FakePubSub`, with fast retries and ticks.
const Harness = struct {
    fake: FakePubSub,
    handler: TestHandler,
    subscriber: Subscriber,

    fn init(h: *Harness, options: struct {
        concurrency: u16 = 1,
        max_outstanding: u32 = 1000,
        extension_period_s: ?u32 = 10,
        max_extension_s: u32 = 600,
        max_attempts: u8 = 2,
        tick_ms: i64 = 50,
        give_up_ms: ?i64 = null,
    }) !void {
        const io = testing.io;
        h.fake = .init(testing.allocator, io);
        errdefer h.fake.deinit();
        h.subscriber = try .init(testing.allocator, io, .{
            .subscription_id = "worker",
            .client = .{
                .project_id = "p",
                .endpoint = .{ .url = "localhost:1", .emulator = true },
                .transport = h.fake.transport(),
                .retry = .{ .max_attempts = options.max_attempts, .initial_backoff_ms = 5, .max_backoff_ms = 20 },
            },
            .concurrency = options.concurrency,
            .max_outstanding = options.max_outstanding,
            .extension_period_s = options.extension_period_s,
            .max_extension_s = options.max_extension_s,
        });
        errdefer h.subscriber.deinit();
        h.subscriber.tick_override_ms = options.tick_ms;
        h.subscriber.give_up_override_ms = options.give_up_ms;
        h.handler = .{ .gpa = testing.allocator, .io = io, .subscriber = &h.subscriber };
    }

    fn deinit(h: *Harness) void {
        h.subscriber.deinit();
        h.handler.deinit();
        h.fake.deinit();
    }
};

/// True once `predicate` held, checked every 10 ms up to `limit_ms`.
fn waitUntil(limit_ms: i64, context: anytype, predicate: fn (@TypeOf(context)) bool) !bool {
    const io = testing.io;
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + limit_ms;
    while (!predicate(context)) {
        if (std.Io.Clock.awake.now(io).toMilliseconds() > deadline) return false;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return true;
}

test "Subscriber: delivers, acknowledges, and stops from a handler" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    for (0..5) |i| {
        var buf: [16]u8 = undefined;
        try h.fake.publish(try std.fmt.bufPrint(&buf, "message-{d}", .{i}));
    }
    h.handler.stop_after = 5;
    try h.subscriber.run(h.handler.handler());

    try testing.expectEqual(5, h.handler.seenCount());
    try testing.expectEqual(5, h.fake.ackedCount());
    const counts = h.subscriber.stats();
    try testing.expectEqual(5, counts.received);
    try testing.expectEqual(5, counts.acked);
    try testing.expectEqual(0, counts.nacked);
    try testing.expectEqual(0, counts.handler_failures);
    // On its way out, run raised the flags that end a task whose cancel
    // never landed.
    try testing.expect(h.subscriber.halted);
}

test "Subscriber: a failing handler releases the message, and redelivery succeeds" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.handler.fail_first = true;
    h.handler.stop_after = 3;
    for (0..3) |i| {
        var buf: [16]u8 = undefined;
        try h.fake.publish(try std.fmt.bufPrint(&buf, "retry-{d}", .{i}));
    }
    try h.subscriber.run(h.handler.handler());

    try testing.expectEqual(3, h.handler.seenCount());
    try testing.expectEqual(3, h.fake.ackedCount());
    const counts = h.subscriber.stats();
    try testing.expectEqual(3, counts.handler_failures);
    try testing.expectEqual(3, counts.nacked);
    try testing.expectEqual(3, counts.acked);
    // Each message went around twice: released once, then acknowledged.
    try testing.expectEqual(6, counts.received);
}

test "Subscriber: concurrency runs handlers side by side, never over the limit" {
    var h: Harness = undefined;
    try h.init(.{ .concurrency = 3 });
    defer h.deinit();
    h.handler.sleep_ms = 150;
    h.handler.stop_after = 8;
    for (0..8) |i| {
        var buf: [16]u8 = undefined;
        try h.fake.publish(try std.fmt.bufPrint(&buf, "par-{d}", .{i}));
    }
    try h.subscriber.run(h.handler.handler());
    try testing.expectEqual(8, h.handler.seenCount());
    try testing.expectEqual(3, h.handler.max_active);
}

test "Subscriber: flow control caps what one pull may bring" {
    var h: Harness = undefined;
    try h.init(.{ .max_outstanding = 4 });
    defer h.deinit();
    h.handler.stop_after = 12;
    for (0..12) |i| {
        var buf: [16]u8 = undefined;
        try h.fake.publish(try std.fmt.bufPrint(&buf, "cap-{d}", .{i}));
    }
    try h.subscriber.run(h.handler.handler());
    try testing.expectEqual(12, h.handler.seenCount());
    h.fake.mutex.lockUncancelable(testing.io);
    defer h.fake.mutex.unlock(testing.io);
    try testing.expect(h.fake.pull_wants.items.len > 0);
    for (h.fake.pull_wants.items) |want| try testing.expect(want <= 4);
}

test "Subscriber: leases are extended while a handler runs" {
    var h: Harness = undefined;
    try h.init(.{ .tick_ms = 60 });
    defer h.deinit();
    h.handler.sleep_ms = 400;
    h.handler.stop_after = 1;
    try h.fake.publish("slow one");
    try h.subscriber.run(h.handler.handler());

    try testing.expectEqual(1, h.handler.seenCount());
    try testing.expect(h.fake.extensions() >= 1);
    try testing.expect(h.subscriber.stats().extended >= 1);
    h.fake.mutex.lockUncancelable(testing.io);
    defer h.fake.mutex.unlock(testing.io);
    for (h.fake.modacks.items) |m| try testing.expectEqual(10, m.seconds);
}

test "Subscriber: stop releases what was buffered but not started" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.handler.sleep_ms = 100;
    h.handler.stop_after = 1;
    for (0..6) |i| {
        var buf: [16]u8 = undefined;
        try h.fake.publish(try std.fmt.bufPrint(&buf, "shed-{d}", .{i}));
    }
    try h.subscriber.run(h.handler.handler());

    const counts = h.subscriber.stats();
    try testing.expectEqual(1, counts.acked);
    // Everything pulled was resolved one way or the other: nothing is lost.
    try testing.expectEqual(counts.received, counts.acked + counts.nacked);
    try testing.expect(counts.nacked >= 1);
    try testing.expectEqual(1, h.fake.ackedCount());
}

test "Subscriber: a fatal pull error stops the loop and reports it" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var diag: Diagnostics = .{};
    h.subscriber.caller_diag = &diag;
    h.fake.fail_status = 404;
    h.fake.fail_pulls = 1;
    try testing.expectError(error.NotFound, h.subscriber.run(h.handler.handler()));
    try testing.expectEqual(404, diag.http_status);
    try testing.expectEqualStrings("NOT_FOUND", diag.status());
}

test "Subscriber: a transient ack failure is retried on the next flush" {
    var h: Harness = undefined;
    try h.init(.{ .max_attempts = 1, .tick_ms = 40 });
    defer h.deinit();
    h.fake.fail_acks = 1;
    try h.fake.publish("first");
    try h.fake.publish("second");

    var running = try testing.io.concurrent(Subscriber.run, .{ &h.subscriber, h.handler.handler() });
    const Acked = struct {
        fn bothAcked(f: *Harness) bool {
            return f.fake.ackedCount() >= 2;
        }
    };
    try testing.expect(try waitUntil(5_000, &h, Acked.bothAcked));
    h.subscriber.stop();
    try running.await(testing.io);
    // The failed call was counted, and the retry carried both ids.
    h.fake.mutex.lockUncancelable(testing.io);
    defer h.fake.mutex.unlock(testing.io);
    try testing.expect(h.fake.ack_calls >= 2);
}

test "Subscriber: transient pull failures are survived" {
    var h: Harness = undefined;
    try h.init(.{ .max_attempts = 1 });
    defer h.deinit();
    h.fake.fail_pulls = 2;
    h.handler.stop_after = 2;
    try h.fake.publish("a");
    try h.fake.publish("b");
    try h.subscriber.run(h.handler.handler());
    try testing.expectEqual(2, h.handler.seenCount());
}

/// Runs the harness's subscriber, and panics if it does not return within
/// `limit_ms`: a subscriber that never stops must name its test, not stall
/// the suite until CI's timeout.
fn runWithin(h: *Harness, limit_ms: i64) !void {
    const io = testing.io;
    const Runner = struct {
        fn run(s: *Subscriber, handler: Handler, returned: *std.atomic.Value(bool)) Error!void {
            defer returned.store(true, .release);
            return s.run(handler);
        }
        fn hasReturned(returned: *std.atomic.Value(bool)) bool {
            return returned.load(.acquire);
        }
    };
    var returned: std.atomic.Value(bool) = .init(false);
    var running = try io.concurrent(Runner.run, .{ &h.subscriber, h.handler.handler(), &returned });
    if (!try waitUntil(limit_ms, &returned, Runner.hasReturned)) {
        @panic("Subscriber.run did not return within the test's limit");
    }
    return running.await(io);
}

/// Every message received counted once, as `Stats` promises after `stop`.
fn expectAccounted(counts: Stats) !void {
    try testing.expectEqual(counts.received, counts.acked + counts.ack_failed + counts.nacked + counts.receipt_refused);
}

test "Subscriber: on an exactly-once subscription, an ack that comes too late is counted, and the loop runs on" {
    // Regression: the janitor took the refusal of a late ack for a fatal
    // error and stopped the whole subscriber, as Google's Go client once
    // did too (google-cloud-go#5797).
    var h: Harness = undefined;
    try h.init(.{ .concurrency = 2, .extension_period_s = null, .max_extension_s = 1, .tick_ms = 20 });
    defer h.deinit();
    h.fake.exactly_once = true;
    // Leases last a second, extended every 20 ms. At 150 ms, a macOS runner
    // that stalled for longer lapsed one early, and the message came a
    // third time.
    h.fake.lease_ms = 1000;
    // The first delivery outlives max_extension_s, so its lease lapses and
    // the message comes again; the second is handled at once. The first
    // returns once the second's ack is taken, so its own comes too late.
    const Late = struct {
        fn redeliveryAcked(harness: *Harness) bool {
            return harness.fake.ackedData("late") >= 1;
        }
    };
    h.handler.hold_first_until = Late.redeliveryAcked;
    h.handler.stop_after = 2;
    try h.fake.publish("late");
    try runWithin(&h, 20_000);

    const counts = h.subscriber.stats();
    try testing.expectEqual(2, counts.received);
    try testing.expectEqual(1, counts.acked);
    try testing.expectEqual(1, counts.ack_failed);
    try expectAccounted(counts);
    // The late ack went to the server, which refused it: the janitor had
    // not already learned from a refused extension that its lease was lost.
    try testing.expect(h.fake.ackAttempted("ack-0"));
    try testing.expectEqual(1, h.fake.ackedData("late"));
    // The subscription said it has exactly-once delivery: every lease went
    // to at least 60 s, the receipt of each pull included.
    try testing.expectEqual(0, h.fake.modacksOf(10));
    try testing.expect(h.fake.modacksOf(60) >= 2);
}

test "Subscriber: a message whose lease is refused on receipt is dropped unhandled, and comes again" {
    var h: Harness = undefined;
    try h.init(.{ .extension_period_s = null });
    defer h.deinit();
    h.fake.exactly_once = true;
    // The receipt of the first pull is refused, which lapses its lease.
    h.fake.refuse_modacks = 1;
    h.handler.stop_after = 1;
    try h.fake.publish("refused once");
    try runWithin(&h, 20_000);

    const counts = h.subscriber.stats();
    try testing.expectEqual(2, counts.received);
    try testing.expectEqual(1, counts.receipt_refused);
    try testing.expectEqual(1, counts.acked);
    try expectAccounted(counts);
    // The handler saw it once: the refused delivery never reached it.
    try testing.expectEqual(1, h.handler.attempts.get("refused once").?);
}

test "Subscriber: when the subscription cannot be read, leases go 60 s and exactly-once is learned from a refusal" {
    var h: Harness = undefined;
    try h.init(.{ .extension_period_s = null, .tick_ms = 20 });
    defer h.deinit();
    h.fake.refuse_get = true;
    h.fake.exactly_once = true;
    // The first ack is refused, as for a lease that lapsed.
    h.fake.refuse_acks = 1;
    const Probe = struct {
        fn extended(harness: *Harness) bool {
            return harness.fake.extensions() >= 1;
        }
        fn learned(s: *Subscriber) bool {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            return s.exactly_once;
        }
        fn handledTwice(handler: *TestHandler) bool {
            return handler.seenCount() >= 2;
        }
    };
    // The first delivery returns once its lease has been extended, which
    // the subscriber does at the fallback period before it learns more.
    h.handler.hold_first_until = Probe.extended;
    h.handler.stop_after = 2;
    logging.capture.reset();
    try h.fake.publish("learned");
    var running = try testing.io.concurrent(Subscriber.run, .{ &h.subscriber, h.handler.handler() });
    // The message comes again only once the refusal has taught the
    // subscriber, so the redelivery's receipt shows what it learned. On a
    // timer, a stalled machine could pull the redelivery first.
    const learned = try waitUntil(10_000, &h.subscriber, Probe.learned);
    if (learned) try h.fake.lapseAll();
    const handled = learned and try waitUntil(10_000, &h.handler, Probe.handledTwice);
    h.subscriber.stop();
    try running.await(testing.io);
    try testing.expect(handled);

    const counts = h.subscriber.stats();
    try testing.expectEqual(1, counts.ack_failed);
    try testing.expectEqual(1, counts.acked);
    try expectAccounted(counts);
    const log = logging.capture.text();
    try testing.expect(std.mem.indexOf(u8, log, "may not read subscription worker, which needs pubsub.subscriptions.get") != null);
    try testing.expect(std.mem.indexOf(u8, log, "has exactly-once delivery") != null);
    // Every lease was set to the fallback period, never to the 10 s the
    // subscription would have said: the first delivery's by extension, the
    // second's on receipt, which only exactly-once asks for.
    try testing.expectEqual(0, h.fake.modacksOf(10));
    try testing.expect(h.fake.modacksOf(60) >= 2);
}

test "Subscriber: acknowledgements go out promptly, not at the lease tick" {
    var h: Harness = undefined;
    // Leases would be extended only every 5 s.
    try h.init(.{ .tick_ms = 5000 });
    defer h.deinit();
    try h.fake.publish("prompt");
    var running = try testing.io.concurrent(Subscriber.run, .{ &h.subscriber, h.handler.handler() });
    const Acked = struct {
        fn one(f: *FakePubSub) bool {
            return f.ackedCount() >= 1;
        }
    };
    const acked = try waitUntil(1_000, &h.fake, Acked.one);
    h.subscriber.stop();
    try running.await(testing.io);
    try testing.expect(acked);
    // Counted once run has returned: the fake records the ack before the
    // janitor has the answer and counts it, so a count read at once raced
    // it, and lost under load in a ReleaseSafe run.
    try testing.expectEqual(1, h.subscriber.stats().acked);
}

test "Subscriber: an ack refused for now is sent again later, and given up at the limit" {
    {
        var h: Harness = undefined;
        try h.init(.{ .max_attempts = 1, .tick_ms = 10 });
        defer h.deinit();
        h.fake.exactly_once = true;
        h.fake.transient_acks = 2;
        try h.fake.publish("eventually");
        var running = try testing.io.concurrent(Subscriber.run, .{ &h.subscriber, h.handler.handler() });
        const Acked = struct {
            fn one(f: *FakePubSub) bool {
                return f.ackedCount() >= 1;
            }
        };
        // The janitor itself sends it again, backing off: the client makes
        // one attempt per call here, and nothing stops the subscriber yet.
        const acked = try waitUntil(5_000, &h.fake, Acked.one);
        h.subscriber.stop();
        try running.await(testing.io);
        try testing.expect(acked);
        const counts = h.subscriber.stats();
        try testing.expectEqual(1, counts.acked);
        try testing.expectEqual(0, counts.ack_failed);
        h.fake.mutex.lockUncancelable(testing.io);
        defer h.fake.mutex.unlock(testing.io);
        try testing.expectEqual(3, h.fake.ack_calls);
    }
    {
        var h: Harness = undefined;
        // A second before giving up: long enough that a stalled machine
        // still sends the ack again before the limit.
        try h.init(.{ .max_attempts = 1, .tick_ms = 10, .give_up_ms = 1000 });
        defer h.deinit();
        h.fake.exactly_once = true;
        h.fake.transient_acks = 1_000_000;
        try h.fake.publish("never");
        var running = try testing.io.concurrent(Subscriber.run, .{ &h.subscriber, h.handler.handler() });
        const GivenUp = struct {
            fn one(s: *Subscriber) bool {
                return s.stats().ack_failed >= 1;
            }
        };
        const given_up = try waitUntil(5_000, &h.subscriber, GivenUp.one);
        h.subscriber.stop();
        try running.await(testing.io);
        try testing.expect(given_up);
        const counts = h.subscriber.stats();
        try testing.expectEqual(0, counts.acked);
        try testing.expectEqual(1, counts.ack_failed);
        try expectAccounted(counts);
        h.fake.mutex.lockUncancelable(testing.io);
        defer h.fake.mutex.unlock(testing.io);
        try testing.expect(h.fake.ack_calls >= 2);
    }
}

test "Subscriber: a lease the server refuses to extend is extended no more, and its ack is never sent" {
    var h: Harness = undefined;
    // The period is set, so the subscription is not read, and exactly-once
    // is learned from the refused extension. One message at a time: the
    // redelivery, waiting on the fake since the refusal, is pulled only
    // once the first resolves, after the subscriber has learned. With room
    // for more, a stalled machine pulled it first, and it went unextended.
    try h.init(.{ .max_outstanding = 1, .tick_ms = 20 });
    defer h.deinit();
    h.fake.exactly_once = true;
    h.fake.refuse_modacks = 1;
    // The first delivery returns only once the janitor has marked its
    // lease lost. A 200 ms sleep raced the refusal on a stalled machine,
    // and the ack went out and was refused there instead.
    const Lost = struct {
        fn lease(harness: *Harness) bool {
            const s = &harness.subscriber;
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            for (s.inflight.items) |tracked| {
                if (tracked.lease_lost) return true;
            }
            return false;
        }
    };
    h.handler.hold_first_until = Lost.lease;
    h.handler.stop_after = 2;
    try h.fake.publish("lost lease");
    try runWithin(&h, 20_000);

    const counts = h.subscriber.stats();
    try testing.expectEqual(2, counts.received);
    try testing.expectEqual(1, counts.ack_failed);
    try testing.expectEqual(1, counts.acked);
    try expectAccounted(counts);
    // The first delivery, ack-0, lost its lease: its ack was settled
    // without being sent. The redelivery's went out and was taken.
    try testing.expect(!h.fake.ackAttempted("ack-0"));
    try testing.expectEqual(1, h.fake.ackedCount());
    // The refusal taught the subscriber that the subscription has
    // exactly-once delivery: the redelivery's lease went to 60 s on
    // receipt, where the configured period was 10 s.
    try testing.expect(h.fake.modacksOf(60) >= 1);
}

test "Subscriber: the last flush sends acknowledgements still backing off" {
    var h: Harness = undefined;
    // Backoffs of 5 s, longer than this test runs.
    try h.init(.{ .max_attempts = 1, .tick_ms = 5000 });
    defer h.deinit();
    h.fake.exactly_once = true;
    h.fake.transient_acks = 1;
    try h.fake.publish("backing off");
    var running = try testing.io.concurrent(Subscriber.run, .{ &h.subscriber, h.handler.handler() });
    const Refused = struct {
        fn once(f: *FakePubSub) bool {
            f.mutex.lockUncancelable(testing.io);
            defer f.mutex.unlock(testing.io);
            return f.ack_calls >= 1;
        }
    };
    // Refused for now once, and waiting out its backoff when stop comes.
    const refused = try waitUntil(2_000, &h.fake, Refused.once);
    h.subscriber.stop();
    try running.await(testing.io);
    try testing.expect(refused);
    const counts = h.subscriber.stats();
    try testing.expectEqual(1, counts.acked);
    try testing.expectEqual(0, counts.ack_failed);
    try expectAccounted(counts);
}

test "Subscriber: a lease extension or a receipt answered NotFound stops the loop" {
    for ([_]?u32{ 10, null }) |period| {
        var h: Harness = undefined;
        // A set period extends on the tick; none reads the subscription,
        // which has exactly-once delivery, and extends on receipt.
        try h.init(.{ .extension_period_s = period, .tick_ms = 20 });
        defer h.deinit();
        h.fake.exactly_once = period == null;
        h.fake.fail_status = 404;
        h.fake.fail_modacks = 1;
        h.handler.sleep_ms = 200;
        try h.fake.publish("gone");
        try testing.expectError(error.NotFound, runWithin(&h, 20_000));
        try expectAccounted(h.subscriber.stats());
    }
}

test "Subscriber: requests that get no answer are tried again later, and nothing is lost" {
    var h: Harness = undefined;
    // Exactly-once is read from the subscription, so each pull is extended
    // on receipt; the client makes two attempts, both dropped each time.
    try h.init(.{ .extension_period_s = null, .tick_ms = 20 });
    defer h.deinit();
    h.fake.exactly_once = true;
    // The receipt, and then an extension, get no answer; so does the ack.
    h.fake.drop_modacks = 4;
    h.fake.drop_acks = 2;
    h.handler.sleep_ms = 150;
    logging.capture.reset();
    try h.fake.publish("unanswered");
    var running = try testing.io.concurrent(Subscriber.run, .{ &h.subscriber, h.handler.handler() });
    const Acked = struct {
        fn one(f: *FakePubSub) bool {
            return f.ackedCount() >= 1;
        }
    };
    // The janitor sends the ack again itself, after its backoff.
    const acked = try waitUntil(10_000, &h.fake, Acked.one);
    h.subscriber.stop();
    try running.await(testing.io);
    try testing.expect(acked);

    const counts = h.subscriber.stats();
    try testing.expectEqual(1, counts.acked);
    try testing.expectEqual(0, counts.receipt_refused);
    try expectAccounted(counts);
    const log = logging.capture.text();
    // Handled anyway: the pull's own lease stood.
    try testing.expect(std.mem.indexOf(u8, log, "extending the leases of 1 pulled messages failed") != null);
    try testing.expect(std.mem.indexOf(u8, log, "ack of 1 messages failed with ConnectionResetByPeer; trying again later") != null);
}

test "Subscriber: an ack answered NotFound stops the loop and reports it" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var diag: Diagnostics = .{};
    h.subscriber.caller_diag = &diag;
    h.fake.fail_status = 404;
    h.fake.fail_acks = 1;
    try h.fake.publish("gone");
    try testing.expectError(error.NotFound, runWithin(&h, 20_000));
    try testing.expectEqualStrings("NOT_FOUND", diag.status());
    try expectAccounted(h.subscriber.stats());
}

test "Subscriber: stop before run makes run return at once, and a second run is refused" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var diag: Diagnostics = .{};
    h.subscriber.caller_diag = &diag;
    h.subscriber.stop();
    try h.subscriber.run(h.handler.handler());
    h.fake.mutex.lockUncancelable(testing.io);
    try testing.expectEqual(0, h.fake.pull_wants.items.len);
    h.fake.mutex.unlock(testing.io);
    try testing.expectError(error.InvalidOptions, h.subscriber.run(h.handler.handler()));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "runs once") != null);
}

test "Subscriber: canceling run takes every task down and leaks nothing" {
    var h: Harness = undefined;
    try h.init(.{ .concurrency = 3 });
    defer h.deinit();
    // No messages: the puller sits in a held pull.
    var running = try testing.io.concurrent(Subscriber.run, .{ &h.subscriber, h.handler.handler() });
    try testing.io.sleep(.fromMilliseconds(100), .awake);
    try testing.expectError(error.Canceled, running.cancel(testing.io));
    // The cancel raised the flags on its way out, the rescue of any task
    // whose own cancel was swallowed (docs/zig-std-workarounds.md).
    try testing.expect(h.subscriber.halted);
}

/// Rounds of canceling a busy subscriber: every resolved message
/// broadcasts, and with `max_outstanding = 1` the puller waits on the same
/// condition as `run`, so a cancel keeps landing mid-broadcast.
fn cancelBusyRounds(rounds: usize, done: *std.atomic.Value(bool)) anyerror!void {
    const io = testing.io;
    defer done.store(true, .release);
    for (0..rounds) |round| {
        var h: Harness = undefined;
        try h.init(.{ .concurrency = 2, .max_outstanding = 1 });
        defer h.deinit();
        for (0..30) |i| {
            var buf: [24]u8 = undefined;
            try h.fake.publish(try std.fmt.bufPrint(&buf, "round {d} message {d}", .{ round, i }));
        }
        var running = try io.concurrent(Subscriber.run, .{ &h.subscriber, h.handler.handler() });
        const pause_us: i64 = @intCast(100 + round % 7 * 150);
        io.sleep(.fromMicroseconds(pause_us), .awake) catch {};
        running.cancel(io) catch {};
    }
}

test "Subscriber: canceling run while handlers resolve messages never hangs" {
    // Regression. run() waits on a condition that every resolved message
    // broadcasts. std's Condition in Zig 0.16.0 dropped a cancel that
    // landed while another waiter's signal was pending, and then run()
    // never returned: its next wait could not be canceled. Zig 0.17's
    // keeps the cancel. Rather than hang the suite, this gives up after
    // 60 s.
    const io = testing.io;
    var done: std.atomic.Value(bool) = .init(false);
    var rounds = try io.concurrent(cancelBusyRounds, .{ 150, &done });
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 60_000;
    while (!done.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).toMilliseconds() > deadline) {
            @panic("Subscriber.run never returned from a cancel: the cancel was lost");
        }
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try rounds.await(io);
}

test "Subscriber: init refuses what cannot work" {
    const io = testing.io;
    var diag: Diagnostics = .{};
    const client: Client.Options = .{
        .project_id = "p",
        .endpoint = .{ .url = "localhost:1", .emulator = true },
        .diagnostics = &diag,
    };
    try testing.expectError(error.InvalidResourceId, Subscriber.init(testing.allocator, io, .{
        .subscription_id = "goog-reserved",
        .client = client,
    }));
    try testing.expectError(error.InvalidOptions, Subscriber.init(testing.allocator, io, .{
        .subscription_id = "worker",
        .client = client,
        .concurrency = 0,
    }));
    try testing.expectError(error.InvalidOptions, Subscriber.init(testing.allocator, io, .{
        .subscription_id = "worker",
        .client = client,
        .extension_period_s = 5,
    }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "extension_period_s") != null);
    try testing.expectError(error.InvalidResourceId, Subscriber.init(testing.allocator, io, .{
        .subscription_id = "worker",
        .client = .{ .project_id = "", .endpoint = .{ .url = "localhost:1", .emulator = true } },
    }));
}

test "Subscriber: init failures under memory pressure are OutOfMemory without leaks" {
    const Run = struct {
        fn initDeinit(gpa: Allocator) !void {
            var subscriber: Subscriber = try .init(gpa, testing.io, .{
                .subscription_id = "worker",
                .client = .{ .project_id = "p", .endpoint = .{ .url = "localhost:1", .emulator = true } },
                .max_outstanding = 16,
            });
            subscriber.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.initDeinit, .{});
}

const Seeks = struct {
    fn back(h: *Harness) anyerror!void {
        try h.fake.seekBack();
    }

    /// A purge, and one message published after it.
    fn aheadThenOne(h: *Harness) anyerror!void {
        try h.fake.seekAhead();
        try h.fake.publish("after");
    }

    fn detach(h: *Harness) anyerror!void {
        h.fake.detach();
    }
};

test "Subscriber: a seek back mid-run brings every message again with no restart, and an ack that crossed it is taken and forgotten" {
    for ([_]bool{ false, true }) |exactly_once| {
        var h: Harness = undefined;
        try h.init(.{});
        defer h.deinit();
        h.fake.exactly_once = exactly_once;
        // Long enough that no lease lapses on its own.
        h.fake.lease_ms = 30_000;
        for ([_][]const u8{ "replay-0", "replay-1", "replay-2" }) |data| try h.fake.publish(data);
        // The handler of the third message seeks back before it returns, so
        // its own ack is sent with an id the seek made stale.
        h.handler.after_seen = .{ .count = 3, .do = Seeks.back };
        h.handler.stop_after = 6;
        try runWithin(&h, 20_000);

        // The same subscriber, never restarted, handled each one twice.
        try testing.expectEqual(6, h.handler.seenCount());
        for ([_][]const u8{ "replay-0", "replay-1", "replay-2" }) |data| {
            try testing.expectEqual(2, h.handler.attemptsOf(data));
            // Acknowledged for good by the second round, at the latest.
            try testing.expect(h.fake.ackedData(data) >= 1);
        }
        // The server answered every ack as taken, the stale ones too, so
        // the subscriber counts six. The third message's first ack took
        // nothing off the backlog: that message came again.
        const counts = h.subscriber.stats();
        try testing.expectEqual(6, counts.received);
        try testing.expectEqual(6, counts.acked);
        try testing.expectEqual(0, counts.ack_failed);
        try expectAccounted(counts);
        try testing.expectEqual(6, h.fake.ackedCount());
        try testing.expectEqual(1, h.fake.ackedData("replay-2"));
        try testing.expect(h.fake.ackedMessages() <= 5);
        try testing.expectEqual(0, h.fake.backlog());
    }
}

test "Subscriber: a seek ahead purges what waits, and the subscriber goes on to what is published after" {
    var h: Harness = undefined;
    // One message out at a time, so the rest wait on the server when the
    // first one's handler purges them.
    try h.init(.{ .max_outstanding = 1 });
    defer h.deinit();
    for ([_][]const u8{ "old-0", "old-1", "old-2" }) |data| try h.fake.publish(data);
    h.handler.after_seen = .{ .count = 1, .do = Seeks.aheadThenOne };
    h.handler.stop_after = 2;
    try runWithin(&h, 20_000);

    // Idle, not stopped: it took the one message published after the seek,
    // and the two the seek purged never came.
    try testing.expectEqual(2, h.handler.seenCount());
    try testing.expectEqual(1, h.handler.attemptsOf("old-0"));
    try testing.expectEqual(1, h.handler.attemptsOf("after"));
    try testing.expectEqual(0, h.handler.attemptsOf("old-1"));
    try testing.expectEqual(0, h.handler.attemptsOf("old-2"));
    const counts = h.subscriber.stats();
    try testing.expectEqual(2, counts.received);
    try testing.expectEqual(2, counts.acked);
    try expectAccounted(counts);
    // The seek had acknowledged `old-0` before its own ack arrived.
    try testing.expectEqual(0, h.fake.ackedData("old-0"));
    try testing.expectEqual(1, h.fake.ackedData("after"));
    try testing.expectEqual(0, h.fake.backlog());
}

test "Subscriber: a detach stops run with FailedPrecondition and the server's words, with exactly-once delivery or without" {
    for ([_]bool{ false, true }) |exactly_once| {
        var h: Harness = undefined;
        try h.init(.{});
        defer h.deinit();
        h.fake.exactly_once = exactly_once;
        h.fake.lease_ms = 30_000;
        var diag: Diagnostics = .{};
        h.subscriber.caller_diag = &diag;
        try h.fake.publish("last");
        // Detached while its one message is being handled: the pull the
        // puller holds meanwhile is refused, and so is the message's ack.
        h.handler.after_seen = .{ .count = 1, .do = Seeks.detach };

        try testing.expectError(error.FailedPrecondition, runWithin(&h, 20_000));
        try testing.expectEqual(400, diag.http_status);
        try testing.expectEqualStrings("FAILED_PRECONDITION", diag.status());
        try testing.expectEqualStrings("This method is not supported on detached subscriptions.", diag.message());
        // Nothing was acknowledged, and the stats still add up.
        const counts = h.subscriber.stats();
        try testing.expectEqual(1, counts.received);
        try testing.expectEqual(0, counts.acked);
        try expectAccounted(counts);
        try testing.expectEqual(0, h.fake.ackedCount());
    }
}

fn chaosProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const message_count = g.intRange(u8, 1, 24);
    const concurrency = g.intRange(u8, 1, 4);
    const fail_first = g.boolean();
    const fail_pulls = g.intRange(u8, 0, 2);
    const fail_acks = g.intRange(u8, 0, 2);

    var h: Harness = undefined;
    try h.init(.{
        .concurrency = concurrency,
        .max_outstanding = g.intRange(u8, 1, 8),
        .max_attempts = 1,
        .tick_ms = 20,
    });
    defer h.deinit();
    h.fake.fail_pulls = fail_pulls;
    h.fake.fail_acks = fail_acks;
    h.handler.fail_first = fail_first;
    h.handler.stop_after = message_count;
    // Drawn after everything above, so older inputs keep their meaning.
    // Exactly-once: leases that lapse, acks and extensions refused for
    // good or for now, slow first deliveries, and a subscription that is
    // read, or cannot be, or is not asked.
    if (g.boolean()) {
        h.fake.exactly_once = true;
        // Short leases and sleeps: every lapse is waited for in real time,
        // and the nightly job runs this property a hundred thousand times.
        h.fake.lease_ms = g.intRange(u8, 10, 40);
        h.fake.transient_acks = g.intRange(u8, 0, 3);
        h.fake.refuse_acks = g.intRange(u8, 0, 2);
        h.fake.refuse_modacks = g.intRange(u8, 0, 2);
        h.handler.sleep_first_ms = g.intRange(u8, 0, 25);
        switch (g.intRange(u8, 0, 2)) {
            0 => {},
            1 => h.subscriber.extension_period_s = null,
            else => {
                h.subscriber.extension_period_s = null;
                h.fake.refuse_get = true;
            },
        }
    }
    // Drawn last of all, for the same reason: a seek back at some point of
    // the run, which brings every message again and makes the ack ids out
    // then stale.
    if (g.boolean()) h.handler.after_seen = .{ .count = g.intRange(u8, 1, message_count), .do = Seeks.back };
    for (0..message_count) |i| {
        var buf: [16]u8 = undefined;
        try h.fake.publish(try std.fmt.bufPrint(&buf, "chaos-{d}", .{i}));
    }

    // Whatever the mix, every message is handled and the loop stops clean.
    try h.subscriber.run(h.handler.handler());
    try testing.expect(h.handler.seenCount() >= message_count);
    // No message is lost, seek or no seek: each one was handled, or is
    // still the server's to deliver.
    for (0..message_count) |i| {
        var buf: [16]u8 = undefined;
        const data = try std.fmt.bufPrint(&buf, "chaos-{d}", .{i});
        if (h.handler.attemptsOf(data) > 0) continue;
        h.fake.mutex.lockUncancelable(testing.io);
        defer h.fake.mutex.unlock(testing.io);
        const waiting = for (h.fake.pending.items) |m| {
            if (std.mem.eql(u8, m.data, data)) break true;
        } else false;
        var leased = h.fake.leased.valueIterator();
        const out = while (leased.next()) |m| {
            if (std.mem.eql(u8, m.data, data)) break true;
        } else false;
        if (!waiting and !out) return error.TestMessageLost;
    }
    const counts = h.subscriber.stats();
    // Every message received is counted once, and `acked` is what the
    // server took, no more.
    try testing.expectEqual(counts.received, counts.acked + counts.ack_failed + counts.nacked + counts.receipt_refused);
    try testing.expectEqual(counts.acked, h.fake.ackedCount());
    // Nothing is acknowledged that a handler did not handle.
    h.fake.mutex.lockUncancelable(testing.io);
    defer h.fake.mutex.unlock(testing.io);
    for (h.fake.acked_data.items) |data| {
        for (h.handler.seen.items) |seen| {
            if (std.mem.eql(u8, seen, data)) break;
        } else return error.TestAckedUnhandled;
    }
}

// Named "slow property", not "fuzz": each run starts real tasks against the
// clock, about 30 ms, so the nightly fuzz job for pubsub skips it and a job
// of its own fuzzes it fewer times. `zig build test` runs it like any other.
test "slow property Subscriber: random loads, failures and limits never lose a message" {
    try test_util.fuzzBytes({}, chaosProperty, .{
        // Real tasks and real time: a few runs, not hundreds.
        .random_runs = 8,
        // Room for a plain run to draw a seek, and where.
        .max_len = 10,
        .corpus = &.{
            "\x01\x01\x00\x00\x00\x01",
            "\x18\x04\x01\x02\x02\x08",
            "\x0c\x02\x00\x01\x00\x04",
            // Exactly-once, drawn by a script that mirrors ByteGen: leases
            // lapsing under slow handlers with refusals of every kind; a
            // subscription that cannot be read; and a quiet, fast one.
            "\x0b\x02\x00\x00\x01\x05\x01\x14\x02\x01\x01\x32\x01",
            "\x05\x00\x01\x01\x00\x01\x01\x00\x00\x02\x02\x3c\x02",
            "\x17\x03\x00\x00\x00\x07\x01\x64\x03\x00\x00\x00\x00",
            // A seek back: early and late on a plain subscription with
            // failing first deliveries, and in the middle of an
            // exactly-once one whose leases lapse.
            "\x0c\x02\x01\x00\x00\x04\x00\x01\x00",
            "\x17\x03\x00\x01\x01\x07\x00\x01\x16",
            "\x0b\x02\x00\x00\x01\x05\x01\x14\x02\x01\x01\x10\x00\x01\x05",
        },
    });
}

test "Subscriber: stop returns when the janitor is canceled in the middle of a flush" {
    // Regression. A request that noticed the janitor's cancel acknowledged
    // it and returned error.Canceled, and flush swallowed that, so the
    // janitor went back to its tick with the cancel already spent: std
    // delivers a cancel once. run() then waited for it forever. CI met this
    // about once in twenty runs, as an integration step that hung until
    // the job's time ran out.
    const io = testing.io;
    var h: Harness = undefined;
    try h.init(.{ .tick_ms = 10 });
    defer h.deinit();
    // The janitor's first acknowledgement is held until canceled.
    h.fake.hold_acks = 1;
    try h.fake.publish("held");

    const Runner = struct {
        fn run(s: *Subscriber, handler: Handler, returned: *std.atomic.Value(bool)) Error!void {
            defer returned.store(true, .release);
            return s.run(handler);
        }
        fn hasReturned(returned: *std.atomic.Value(bool)) bool {
            return returned.load(.acquire);
        }
        fn ackHeld(fake: *FakePubSub) bool {
            return fake.heldAcks() > 0;
        }
    };
    var returned: std.atomic.Value(bool) = .init(false);
    var running = try io.concurrent(Runner.run, .{ &h.subscriber, h.handler.handler(), &returned });

    // Handled, resolved, and now the janitor is stuck sending the ack.
    try testing.expect(try waitUntil(5_000, &h.fake, Runner.ackHeld));
    h.subscriber.stop();

    // The teardown cancels the janitor inside that request. It has to end
    // the janitor's loop rather than be swallowed by it.
    if (!try waitUntil(5_000, &returned, Runner.hasReturned)) {
        @panic("Subscriber.run never returned: the janitor lost its cancel mid-flush");
    }
    try running.await(io);

    // The ack the janitor never finished was kept, and the flush run makes
    // on its way out delivered it, so the message is not redelivered.
    try testing.expectEqual(1, h.fake.ackedCount());
    try testing.expectEqual(1, h.subscriber.stats().acked);
}

test "Subscriber: halt ends the janitor and the puller without any cancel" {
    // On macOS, std's unwinder can swallow a task's pending cancel
    // (docs/zig-std-workarounds.md), and a cancel arrives once, so the
    // task would run on and run() would wait on it forever. The flags
    // halt raises are the second line of defense: this drives each loop
    // to its end without canceling anything.
    const io = testing.io;
    const Loops = struct {
        fn janitor(s: *Subscriber, returned: *std.atomic.Value(bool)) std.Io.Cancelable!void {
            defer returned.store(true, .release);
            return s.janitorLoop();
        }
        fn puller(s: *Subscriber, returned: *std.atomic.Value(bool)) std.Io.Cancelable!void {
            defer returned.store(true, .release);
            return s.pullerLoop();
        }
        fn hasReturned(returned: *std.atomic.Value(bool)) bool {
            return returned.load(.acquire);
        }
        fn pullStarted(fake: *FakePubSub) bool {
            fake.mutex.lockUncancelable(fake.io);
            defer fake.mutex.unlock(fake.io);
            return fake.pull_wants.items.len > 0;
        }
        fn oneInFlight(s: *Subscriber) bool {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            return s.inflight.items.len == 1;
        }
    };

    // The janitor parked in its tick, and the puller in a held pull, as
    // production's is for at most one long poll.
    var h: Harness = undefined;
    try h.init(.{ .tick_ms = 10 });
    defer h.deinit();
    var janitor_returned: std.atomic.Value(bool) = .init(false);
    var puller_returned: std.atomic.Value(bool) = .init(false);
    var janitor = try io.concurrent(Loops.janitor, .{ &h.subscriber, &janitor_returned });
    var puller = try io.concurrent(Loops.puller, .{ &h.subscriber, &puller_returned });
    if (!try waitUntil(5_000, &h.fake, Loops.pullStarted)) @panic("the puller never began its pull");
    h.subscriber.halt();
    if (!try waitUntil(5_000, &janitor_returned, Loops.hasReturned)) {
        @panic("the janitor never saw the flag: halt cannot end it without a cancel");
    }
    // The server answering the held pull is what ends the puller's wait.
    try h.fake.publish("wakes the puller");
    if (!try waitUntil(5_000, &puller_returned, Loops.hasReturned)) {
        @panic("the puller never saw the flag: halt cannot end it without a cancel");
    }
    try janitor.await(io);
    try puller.await(io);
    // The message that woke it was released for redelivery, not lost: the
    // queue was closed and no worker ran.
    try testing.expectEqual(1, h.subscriber.stats().nacked);

    // A puller parked on flow control, the subscriber's own condition, is
    // woken by halt's broadcast.
    var full: Harness = undefined;
    try full.init(.{ .max_outstanding = 1 });
    defer full.deinit();
    try full.fake.publish("fills the window");
    var full_returned: std.atomic.Value(bool) = .init(false);
    var full_puller = try io.concurrent(Loops.puller, .{ &full.subscriber, &full_returned });
    if (!try waitUntil(5_000, &full.subscriber, Loops.oneInFlight)) @panic("the puller never filled the window");
    full.subscriber.halt();
    if (!try waitUntil(5_000, &full_returned, Loops.hasReturned)) {
        @panic("the puller never woke from the flow-control wait");
    }
    try full_puller.await(io);
}

test "a batch released from many tasks at once is freed exactly once" {
    // Regression: the count was a plain integer, decremented outside any
    // lock by workers resolving messages of one batch at once. A lost
    // decrement kept the batch forever, which the Subscriber's fuzz job
    // found as a leak about once in a few thousand runs.
    const io = testing.io;
    const tasks = 4;
    const per_task = 25_000;
    const batch = try testing.allocator.create(Batch);
    batch.* = .{ .result = try .init(testing.allocator), .live = .init(tasks * per_task) };
    batch.result.value = .{ .messages = &.{} };
    const Releaser = struct {
        fn run(b: *Batch) void {
            for (0..per_task) |_| b.release(testing.allocator);
        }
    };
    var group: std.Io.Group = .init;
    for (0..tasks) |_| try group.concurrent(io, Releaser.run, .{batch});
    try group.await(io);
    // The last release freed it; std.testing.allocator reports anything
    // left behind, and a second free would have panicked.
}

fn dispatchForTest(s: *Subscriber, pulled: types.Owned(types.PullResult)) anyerror!void {
    return s.dispatch(pulled, null);
}

test "a dispatch canceled at a hand-off releases each message once" {
    // Regression: a cancel observed by the queue hand-off of one message,
    // which locks the queue and so is a cancelation point, released that
    // message twice: once through resolve, again with the rest of the
    // batch. The batch was freed under the messages before it. Here the
    // queue holds one message, so the second hand-off waits for room, and
    // the cancel lands exactly there.
    var h: Harness = undefined;
    try h.init(.{ .max_outstanding = 1 });
    defer h.deinit();
    const io = testing.io;
    for ([_][]const u8{ "first", "second", "third" }) |data| try h.fake.publish(data);
    const pulled = try h.subscriber.puller.subscription("worker").pull(.{ .max_messages = 3 });
    try testing.expectEqual(3, pulled.value.messages.len);

    var dispatching = try io.concurrent(dispatchForTest, .{ &h.subscriber, pulled });
    // Until the second message is registered and its hand-off is waiting.
    var waited_ms: u32 = 0;
    while (true) : (waited_ms += 5) {
        h.subscriber.mutex.lockUncancelable(io);
        const registered = h.subscriber.inflight.items.len;
        h.subscriber.mutex.unlock(io);
        if (registered == 2) break;
        if (waited_ms > 5000) @panic("the dispatch never reached its second hand-off");
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try testing.expectError(error.Canceled, dispatching.cancel(io));

    // The first message still reads from a live batch.
    const first = try h.subscriber.queue.getOne(io);
    try testing.expectEqualStrings("first", first.message.data);
    h.subscriber.resolve(first, .released);
    // The second went back unhandled, and the third was never registered.
    try testing.expectEqual(0, h.subscriber.inflight.items.len);
    try testing.expectEqual(2, h.subscriber.to_nack.items.len);
}

test "acks put back keep room for every message in flight" {
    // Regression: acks refused for now went back on their list with a
    // plain append, which could take the room a message in flight counted
    // on, when the puller had registered new messages while they were
    // out; resolving the last message then failed an assertion. The chaos
    // property found it about once in six hundred runs.
    var h: Harness = undefined;
    try h.init(.{ .max_outstanding = 8 });
    defer h.deinit();
    const io = testing.io;
    const gpa = testing.allocator;
    for ([_][]const u8{ "a", "b", "c" }) |data| try h.fake.publish(data);
    const pulled = try h.subscriber.puller.subscription("worker").pull(.{ .max_messages = 3 });
    try dispatchForTest(&h.subscriber, pulled);
    try testing.expectEqual(3, h.subscriber.inflight.items.len);

    // Acks the janitor held out go back while three are in flight: one
    // more than the spare room, whatever the allocator's growth left, so
    // that an append which only makes room for themselves takes some of
    // what the messages in flight count on.
    const spare = h.subscriber.to_ack.capacity - h.subscriber.to_ack.items.len - h.subscriber.inflight.items.len;
    const held = try gpa.alloc(Pending, spare + 1);
    defer gpa.free(held);
    const zero: std.Io.Timestamp = .{ .nanoseconds = 0 };
    for (held, 0..) |*entry, i| entry.* = .{
        .ack_id = try gpa.print("held-{d}", .{i}),
        .resolved_at = zero,
        .not_before = zero,
    };
    h.subscriber.mutex.lockUncancelable(io);
    h.subscriber.reinsert(.ack, held);
    h.subscriber.mutex.unlock(io);

    // Each message in flight still resolves without allocating.
    for (0..3) |_| h.subscriber.resolve(try h.subscriber.queue.getOne(io), .acked);
    try testing.expectEqual(held.len + 3, h.subscriber.to_ack.items.len);
    try testing.expectEqual(0, h.subscriber.inflight.items.len);
}

test "acks put back without memory are given up and counted, not lost quietly" {
    const io = testing.io;
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var fake: FakePubSub = .init(testing.allocator, io);
    defer fake.deinit();
    var subscriber: Subscriber = try .init(failing.allocator(), io, .{
        .subscription_id = "worker",
        .client = .{
            .project_id = "p",
            .endpoint = .{ .url = "localhost:1", .emulator = true },
            .transport = fake.transport(),
        },
    });
    defer subscriber.deinit();
    subscriber.tick_override_ms = 50;
    const held = [_]Pending{.{
        .ack_id = try failing.allocator().dupe(u8, "held-0"),
        .resolved_at = .{ .nanoseconds = 0 },
        .not_before = .{ .nanoseconds = 0 },
    }};
    // The next allocation is the list's own growth, which fails: the
    // entry is freed and counted as failed, never kept half-registered.
    failing.fail_index = failing.alloc_index;
    subscriber.mutex.lockUncancelable(io);
    subscriber.reinsert(.ack, &held);
    subscriber.mutex.unlock(io);
    try testing.expectEqual(0, subscriber.to_ack.items.len);
    try testing.expectEqual(1, subscriber.stats().ack_failed);
}

test "run: a subscription that cannot be read at all is the caller's error" {
    const io = testing.io;
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"status\":\"NOT_FOUND\",\"message\":\"no such subscription\"}}" } },
    });
    defer fake.deinit();
    var diag: Diagnostics = .{};
    var subscriber: Subscriber = try .init(testing.allocator, io, .{
        .subscription_id = "worker",
        .extension_period_s = null,
        .client = .{
            .project_id = "p",
            .endpoint = .{ .url = "localhost:1", .emulator = true },
            .transport = fake.transport(),
            .diagnostics = &diag,
            .retry = .{ .max_attempts = 1 },
        },
    });
    defer subscriber.deinit();
    var handler: TestHandler = .{ .gpa = testing.allocator, .io = io, .subscriber = &subscriber };
    defer handler.deinit();
    // It fails before any task spawns, so the plain fake transport serves.
    try testing.expectError(error.NotFound, subscriber.run(handler.handler()));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "no such subscription") != null);
}

test "run: an Io without concurrency is refused with a word" {
    const Refused = struct {
        const vtable: std.Io.VTable = v: {
            var v = testing.io.vtable.*;
            v.concurrent = std.Io.failingConcurrent;
            break :v v;
        };
        fn io() std.Io {
            return .{ .userdata = testing.io.userdata, .vtable = &vtable };
        }
    };
    var fake: FakePubSub = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var diag: Diagnostics = .{};
    var subscriber: Subscriber = try .init(testing.allocator, Refused.io(), .{
        .subscription_id = "worker",
        .extension_period_s = 10,
        .client = .{
            .project_id = "p",
            .endpoint = .{ .url = "localhost:1", .emulator = true },
            .transport = fake.transport(),
            .diagnostics = &diag,
        },
    });
    defer subscriber.deinit();
    var handler: TestHandler = .{ .gpa = testing.allocator, .io = Refused.io(), .subscriber = &subscriber };
    defer handler.deinit();
    try testing.expectError(error.InvalidOptions, subscriber.run(handler.handler()));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "concurrent tasks") != null);
}

test "run: a janitor that cannot start takes the puller down with it" {
    const JanitorRefused = struct {
        var spawned: usize = 0;
        const vtable: std.Io.VTable = v: {
            var v = testing.io.vtable.*;
            v.concurrent = concurrent;
            break :v v;
        };
        fn io() std.Io {
            return .{ .userdata = testing.io.userdata, .vtable = &vtable };
        }
        fn concurrent(
            userdata: ?*anyopaque,
            result_len: usize,
            result_alignment: std.mem.Alignment,
            context: []const u8,
            context_alignment: std.mem.Alignment,
            start: *const fn (context: *const anyopaque, result: *anyopaque) void,
        ) std.Io.ConcurrentError!*std.Io.AnyFuture {
            spawned += 1;
            if (spawned > 1) return error.ConcurrencyUnavailable;
            return testing.io.vtable.concurrent(userdata, result_len, result_alignment, context, context_alignment, start);
        }
    };
    JanitorRefused.spawned = 0;
    var fake: FakePubSub = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var diag: Diagnostics = .{};
    var subscriber: Subscriber = try .init(testing.allocator, JanitorRefused.io(), .{
        .subscription_id = "worker",
        .extension_period_s = 10,
        .client = .{
            .project_id = "p",
            .endpoint = .{ .url = "localhost:1", .emulator = true },
            .transport = fake.transport(),
            .diagnostics = &diag,
        },
    });
    defer subscriber.deinit();
    var handler: TestHandler = .{ .gpa = testing.allocator, .io = JanitorRefused.io(), .subscriber = &subscriber };
    defer handler.deinit();
    try testing.expectError(error.InvalidOptions, subscriber.run(handler.handler()));
    // The flags went up before the puller's cancel, in case that cancel
    // never landed.
    try testing.expect(subscriber.halted);
}

test "run: workers that cannot start stop the subscriber cleanly" {
    const GroupsRefused = struct {
        const vtable: std.Io.VTable = v: {
            var v = testing.io.vtable.*;
            v.groupConcurrent = std.Io.failingGroupConcurrent;
            break :v v;
        };
        fn io() std.Io {
            return .{ .userdata = testing.io.userdata, .vtable = &vtable };
        }
    };
    var fake: FakePubSub = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var diag: Diagnostics = .{};
    var subscriber: Subscriber = try .init(testing.allocator, GroupsRefused.io(), .{
        .subscription_id = "worker",
        .extension_period_s = 10,
        .client = .{
            .project_id = "p",
            .endpoint = .{ .url = "localhost:1", .emulator = true },
            .transport = fake.transport(),
            .diagnostics = &diag,
        },
    });
    defer subscriber.deinit();
    subscriber.tick_override_ms = 10;
    var handler: TestHandler = .{ .gpa = testing.allocator, .io = GroupsRefused.io(), .subscriber = &subscriber };
    defer handler.deinit();
    try testing.expectError(error.InvalidOptions, subscriber.run(handler.handler()));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "concurrent tasks") != null);
    try testing.expect(subscriber.halted);
}

test "Subscriber: a pull with nothing in it is just pulled again" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.empty_pulls = 1;
    try h.fake.publish("after the empty one");
    h.handler.stop_after = 1;
    try h.subscriber.run(h.handler.handler());
    try testing.expectEqual(1, h.subscriber.stats().acked);
    try testing.expect(h.fake.pull_wants.items.len >= 2);
}

test "dispatch: every allocation failure is OutOfMemory, and no message leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            const io = testing.io;
            var fake: FakePubSub = .init(testing.allocator, io);
            defer fake.deinit();
            try fake.publish("a");
            try fake.publish("b");
            var subscriber: Subscriber = try .init(gpa, io, .{
                .subscription_id = "worker",
                .client = .{
                    .project_id = "p",
                    .endpoint = .{ .url = "localhost:1", .emulator = true },
                    .transport = fake.transport(),
                },
            });
            defer subscriber.deinit();
            subscriber.tick_override_ms = 50;
            const pulled = try subscriber.puller.subscription("worker").pull(.{ .max_messages = 2 });
            try dispatchForTest(&subscriber, pulled);
            // What dispatched before a failure is on the queue; resolve it
            // the usual way, which frees the batch with its last message.
            subscriber.mutex.lockUncancelable(io);
            const dispatched = subscriber.inflight.items.len;
            subscriber.mutex.unlock(io);
            for (0..dispatched) |_| subscriber.resolve(try subscriber.queue.getOne(io), .acked);
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}

test "workerLoop: a cancel parked at the empty queue is taken" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const io = testing.io;
    var worker = try io.concurrent(workerLoop, .{ &h.subscriber, h.handler.handler() });
    // Let it park in the queue's wait; a cancel landing earlier is taken
    // at the same point, the loop's only cancellation point.
    try io.sleep(.fromMilliseconds(25), .awake);
    try testing.expectError(error.Canceled, worker.cancel(io));
}

test "workerLoop: a handler that is itself canceled releases the message and ends" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const io = testing.io;
    try h.fake.publish("doomed");
    const pulled = try h.subscriber.puller.subscription("worker").pull(.{ .max_messages = 1 });
    try dispatchForTest(&h.subscriber, pulled);
    const Canceling = struct {
        fn handle(_: *anyopaque, _: std.Io, _: types.ReceivedMessage) anyerror!void {
            return error.Canceled;
        }
    };
    var ctx: u8 = 0;
    var worker = try io.concurrent(workerLoop, .{ &h.subscriber, Handler{ .ptr = &ctx, .vtable = &.{ .handle = Canceling.handle } } });
    try testing.expectError(error.Canceled, worker.await(io));
    // At-least-once holds: the message went back for redelivery.
    try testing.expectEqual(1, h.subscriber.stats().nacked);
}

test "tickMs: without an override, half the period, at least half a second" {
    const io = testing.io;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.subscriber.tick_override_ms = null;
    h.subscriber.mutex.lockUncancelable(io);
    h.subscriber.period_s = 60;
    h.subscriber.mutex.unlock(io);
    try testing.expectEqual(30_000, h.subscriber.tickMs());
    h.subscriber.mutex.lockUncancelable(io);
    h.subscriber.period_s = 0;
    h.subscriber.mutex.unlock(io);
    try testing.expectEqual(500, h.subscriber.tickMs());
}
