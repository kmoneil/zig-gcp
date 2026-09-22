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
//! `stop` is safe to call from a handler or from another task: the loop
//! stops pulling, finishes the handlers already running, releases what was
//! buffered but not started, flushes acknowledgements and returns.
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
cond: core.Condition,
queue: std.Io.Queue(*Tracked),
queue_buffer: []*Tracked,
/// Scratch for the janitor's lease snapshot, sized `max_outstanding`.
extend_buffer: [][]const u8,
stopping: bool,
ran: bool,
fatal: ?Error,
fatal_diag: Diagnostics,
/// Tests only: overrides the janitor's tick and the puller's outage
/// backoff, which otherwise pace themselves in seconds.
tick_override_ms: ?i64,
/// Messages pulled and not yet resolved, in no order.
inflight: std.ArrayList(*Tracked),
/// Ack ids whose messages succeeded or failed, awaiting the next flush.
/// The ids are owned by these lists.
to_ack: std.ArrayList([]u8),
to_nack: std.ArrayList([]u8),
counts: Stats,

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
    /// 1 to 600 seconds. Null means the subscription's own ack deadline,
    /// fetched once when `run` starts.
    extension_period_s: ?u32 = null,
    /// How long after arrival a message's lease stops being extended. A
    /// handler stuck longer than this is presumed dead, and the server
    /// redelivers the message elsewhere.
    max_extension_s: u32 = 600,
};

/// Counters since `run` started. A consistent snapshot from `stats`.
pub const Stats = struct {
    /// Messages received from the server.
    received: u64 = 0,
    /// Messages acknowledged after their handler returned.
    acked: u64 = 0,
    /// Messages released: the handler failed, or `stop` shed them.
    nacked: u64 = 0,
    /// Handler calls that returned an error.
    handler_failures: u64 = 0,
    /// Lease extensions sent, counting each message in each batch.
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
        .stopping = false,
        .ran = false,
        .fatal = null,
        .fatal_diag = .{},
        .tick_override_ms = null,
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
    for (self.to_ack.items) |id| self.gpa.free(id);
    self.to_ack.deinit(self.gpa);
    for (self.to_nack.items) |id| self.gpa.free(id);
    self.to_nack.deinit(self.gpa);
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

    // The lease extension period, from the subscription itself unless
    // configured. This also proves the subscription exists before any task
    // starts.
    const period: u32 = self.extension_period_s orelse period: {
        var info = self.puller.subscription(self.subscription_id).get() catch |err| {
            if (self.caller_diag) |d| d.* = self.pull_diag;
            return err;
        };
        defer info.deinit();
        break :period std.math.clamp(info.value.ack_deadline_seconds, validate.min_ack_deadline_seconds, validate.max_ack_deadline_seconds);
    };

    var puller_task = io.concurrent(pullerLoop, .{self}) catch return concurrencyUnavailable(self);
    var puller_running = true;
    defer if (puller_running) discard(puller_task.cancel(io));
    var janitor_task = io.concurrent(janitorLoop, .{ self, period }) catch {
        discard(puller_task.cancel(io));
        puller_running = false;
        return concurrencyUnavailable(self);
    };
    var janitor_running = true;
    defer if (janitor_running) discard(janitor_task.cancel(io));
    var workers: std.Io.Group = .init;
    defer workers.cancel(io);
    // Runs before the cancel above, on every way out. A worker parked in
    // the queue's own wait can miss a cancel: std's queue, like its
    // Condition, takes a message handed over as the cancel lands and drops
    // the cancel. A closed queue sends every worker home anyway.
    defer self.queue.close(io);
    for (0..self.concurrency) |_| workers.concurrent(io, workerLoop, .{ self, handler }) catch {
        var d: Diagnostics = .{};
        d.print("this Io cannot run concurrent tasks, which a Subscriber needs", .{});
        self.recordFatal(error.InvalidOptions, &d);
        break;
    };

    // Wait for stop() or a fatal failure. Cancellation lands here too, and
    // the defers above take the tasks down with us.
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
    discard(janitor_task.cancel(io));
    janitor_running = false;
    // What this cannot send stays listed, and deinit frees it; the server
    // redelivers those messages, which at-least-once allows.
    self.flush(period) catch {};

    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
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
        self.dispatch(result) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.recordFatal(error.OutOfMemory, null);
            return;
        };
    }
}

/// Registers a pull's messages and hands them to the workers. On failure
/// partway, what was dispatched resolves normally, the rest is undone, and
/// its leases lapse on the server.
fn dispatch(self: *Subscriber, pulled: types.Owned(types.PullResult)) !void {
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
                self.inflight.append(gpa, tracked) catch break :a false;
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
/// and wakes whoever waits on room or on progress.
fn resolve(self: *Subscriber, tracked: *Tracked, outcome: Outcome) void {
    const io = self.io;
    const gpa = self.gpa;
    self.mutex.lockUncancelable(io);
    const moved = self.inflight.swapRemove(tracked.index);
    if (self.inflight.items.len > tracked.index) self.inflight.items[tracked.index].index = tracked.index;
    std.debug.assert(moved == tracked);
    const list = switch (outcome) {
        .acked => &self.to_ack,
        .released => &self.to_nack,
    };
    list.append(gpa, tracked.ack_id) catch {
        // No memory to remember the id: the lease lapses on the server and
        // the message redelivers, which at-least-once allows.
        gpa.free(tracked.ack_id);
    };
    switch (outcome) {
        .acked => self.counts.acked += 1,
        .released => self.counts.nacked += 1,
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

fn janitorLoop(self: *Subscriber, period_s: u32) std.Io.Cancelable!void {
    const io = self.io;
    // Extending every half period keeps at least half a period in hand.
    const tick_ms = self.tick_override_ms orelse @max(500, @as(i64, period_s) * 500);
    while (true) {
        try io.sleep(.fromMilliseconds(tick_ms), .awake);
        // A cancel that lands during a flush has to end the loop here. The
        // request that noticed it has acknowledged it, and std delivers a
        // cancel once: the sleep above would never see it again, and run()
        // would wait for this task forever.
        try self.flush(period_s);
    }
}

/// Sends the pending acknowledgements and releases, then extends the lease
/// of everything still in flight. Transient failures put the ids back for
/// the next flush; fatal ones stop the subscriber. `error.Canceled` is
/// returned, never swallowed, with whatever was not sent put back.
fn flush(self: *Subscriber, period_s: u32) std.Io.Cancelable!void {
    const io = self.io;
    const subscription = self.janitor.subscription(self.subscription_id);

    var acks: std.ArrayList([]u8) = .empty;
    var nacks: std.ArrayList([]u8) = .empty;
    var extend_count: usize = 0;
    {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        acks = self.to_ack;
        self.to_ack = .empty;
        nacks = self.to_nack;
        self.to_nack = .empty;
        // Snapshot the leases to extend. The ids stay valid outside the
        // lock: a message resolving moves its id to `to_ack`/`to_nack`,
        // which nothing frees before the flush after this one.
        const cutoff_ns = @as(i96, self.max_extension_s) * std.time.ns_per_s;
        const now = std.Io.Timestamp.now(io, .boot);
        for (self.inflight.items) |tracked| {
            if (now.nanoseconds - tracked.received_at.nanoseconds > cutoff_ns) continue;
            self.extend_buffer[extend_count] = tracked.ack_id;
            extend_count += 1;
        }
    }

    self.sendIds(subscription, &acks, .ack) catch |err| {
        // The releases taken for this flush go back whatever happened.
        self.keep(&nacks, .nack);
        if (err == error.Canceled) return error.Canceled;
        return self.recordFatal(err, &self.janitor_diag);
    };
    self.sendIds(subscription, &nacks, .nack) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        return self.recordFatal(err, &self.janitor_diag);
    };

    var sent: usize = 0;
    while (sent < extend_count) {
        const chunk = self.extend_buffer[sent..@min(sent + validate.max_ack_ids_per_request, extend_count)];
        subscription.modifyAckDeadline(chunk, period_s) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            if (!core.isRetryable(err)) return self.recordFatal(err, &self.janitor_diag);
            // The leases still stand until the deadline; the next tick
            // tries again.
            logging.warn("extending {d} leases failed with {t}", .{ chunk.len, err });
            return;
        };
        sent += chunk.len;
    }
    if (extend_count > 0) {
        self.mutex.lockUncancelable(io);
        self.counts.extended += sent;
        self.mutex.unlock(io);
        logging.debug("extended {d} leases to {d} s", .{ sent, period_s });
    }
}

const IdKind = enum { ack, nack };

/// Sends `list` as acknowledgements or releases, freeing what was sent.
/// A transient failure puts the rest back for the next flush, and so does
/// a cancel, which is then returned: the flush `run` makes on its way out
/// sends what is left.
fn sendIds(self: *Subscriber, subscription: Subscription, list: *std.ArrayList([]u8), what: IdKind) Error!void {
    const gpa = self.gpa;
    while (list.items.len > 0) {
        const chunk_len = @min(validate.max_ack_ids_per_request, list.items.len);
        const chunk = list.items[list.items.len - chunk_len ..];
        const outcome = switch (what) {
            .ack => subscription.ack(chunk),
            .nack => subscription.nack(chunk),
        };
        outcome catch |err| {
            if (err == error.Canceled) {
                self.keep(list, what);
                return error.Canceled;
            }
            if (core.isRetryable(err)) {
                logging.warn("{t} of {d} messages failed with {t}; keeping them for the next flush", .{ what, chunk.len, err });
                self.keep(list, what);
                return;
            }
            for (list.items) |id| gpa.free(id);
            list.deinit(gpa);
            list.* = .empty;
            return err;
        };
        for (chunk) |id| gpa.free(id);
        list.shrinkRetainingCapacity(list.items.len - chunk_len);
    }
    list.deinit(gpa);
    list.* = .empty;
}

/// Puts ids taken for a flush back on their list, for the next flush.
fn keep(self: *Subscriber, list: *std.ArrayList([]u8), what: IdKind) void {
    const io = self.io;
    const gpa = self.gpa;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const back = switch (what) {
        .ack => &self.to_ack,
        .nack => &self.to_nack,
    };
    back.appendSlice(gpa, list.items) catch for (list.items) |id| gpa.free(id);
    list.deinit(gpa);
    list.* = .empty;
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
    cond: core.Condition = .init,
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
    /// Hold this many acknowledge requests open until they are canceled, as
    /// a server that stopped answering would. Later ones answer normally.
    hold_acks: usize = 0,
    /// Acknowledge requests being held right now.
    held_acks: usize = 0,

    const Msg = struct { data: []u8, ack_id: []u8 };
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
        for (f.modacks.items) |m| f.gpa.free(m.ack_id);
        f.modacks.deinit(f.gpa);
        f.pull_wants.deinit(f.gpa);
        f.* = undefined;
    }

    fn transport(f: *FakePubSub) Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    /// Makes a message available for the next pull.
    fn publish(f: *FakePubSub, data: []const u8) !void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const copy = try f.gpa.dupe(u8, data);
        errdefer f.gpa.free(copy);
        const ack_id = try std.fmt.allocPrint(f.gpa, "ack-{d}", .{f.next_id});
        f.next_id += 1;
        try f.pending.append(f.gpa, .{ .data = copy, .ack_id = ack_id });
        f.cond.broadcast(f.io);
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
        if (std.mem.endsWith(u8, req.url, ":pull")) return f.pull(req, arena);
        if (std.mem.endsWith(u8, req.url, ":acknowledge")) return f.acknowledge(req, arena);
        if (std.mem.endsWith(u8, req.url, ":modifyAckDeadline")) return f.modifyAckDeadline(req, arena);
        if (req.method == .GET and std.mem.indexOf(u8, req.url, "/subscriptions/") != null) {
            const body = try std.fmt.allocPrint(
                arena,
                "{{\"name\":\"s\",\"topic\":\"t\",\"ackDeadlineSeconds\":{d}}}",
                .{f.ack_deadline_s},
            );
            return .{ .status = 200, .body = body };
        }
        return .{ .status = 404, .body = "no such route in FakePubSub" };
    }

    fn failure(f: *FakePubSub, arena: Allocator) TransportError!Response {
        const status: []const u8 = if (f.fail_status == 404) "NOT_FOUND" else "UNAVAILABLE";
        const body = try std.fmt.allocPrint(
            arena,
            "{{\"error\":{{\"code\":{d},\"message\":\"scripted failure\",\"status\":\"{s}\"}}}}",
            .{ f.fail_status, status },
        );
        return .{ .status = f.fail_status, .body = body };
    }

    fn pull(f: *FakePubSub, req: Request, arena: Allocator) TransportError!Response {
        const Body = struct { maxMessages: u32 = 0 };
        const wanted = std.json.parseFromSliceLeaky(Body, arena, req.body orelse "{}", .{
            .ignore_unknown_fields = true,
        }) catch return error.HttpProtocolError;

        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        try f.pull_wants.append(f.gpa, wanted.maxMessages);
        if (f.fail_pulls > 0) {
            f.fail_pulls -= 1;
            return f.failure(arena);
        }
        // A held pull, as the real server does when there is nothing yet.
        while (f.pending.items.len == 0) f.cond.wait(f.io, &f.mutex) catch return error.Canceled;

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
        for (f.pending.items[0..count]) |m| try f.leased.put(f.gpa, m.ack_id, m);
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
        for (body.ackIds) |id| {
            try f.acked.append(f.gpa, try f.gpa.dupe(u8, id));
            if (f.leased.fetchRemove(id)) |entry| {
                f.gpa.free(entry.value.data);
                f.gpa.free(entry.value.ack_id);
            }
        }
        return .{ .status = 200, .body = "{}" };
    }

    fn modifyAckDeadline(f: *FakePubSub, req: Request, arena: Allocator) TransportError!Response {
        const body = try parseIds(req, arena);
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
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
    active: usize = 0,
    max_active: usize = 0,
    stop_after: ?usize = null,

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
        if (h.sleep_ms > 0) try io.sleep(.fromMilliseconds(h.sleep_ms), .awake);

        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        const entry = try h.attempts.getOrPut(h.gpa, message.data);
        if (!entry.found_existing) {
            entry.key_ptr.* = try h.gpa.dupe(u8, message.data);
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
        if (h.fail_first and entry.value_ptr.* == 1) return error.NotToday;
        try h.seen.append(h.gpa, try h.gpa.dupe(u8, message.data));
        if (h.stop_after) |n| if (h.seen.items.len >= n) h.subscriber.stop();
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
    // broadcasts. std's Condition in Zig 0.16.0 drops a cancel that lands
    // while another waiter's signal is pending, and then run() never
    // returned: its next wait could not be canceled. core.Condition keeps
    // the cancel. Rather than hang the suite, this gives up after 60 s.
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
    try testing.checkAllAllocationFailures(testing.allocator, Run.initDeinit, .{});
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
    for (0..message_count) |i| {
        var buf: [16]u8 = undefined;
        try h.fake.publish(try std.fmt.bufPrint(&buf, "chaos-{d}", .{i}));
    }

    // Whatever the mix, every message is handled and the loop stops clean.
    try h.subscriber.run(h.handler.handler());
    try testing.expect(h.handler.seenCount() >= message_count);
    const counts = h.subscriber.stats();
    try testing.expectEqual(counts.received, counts.acked + counts.nacked);
}

// Named "slow property", not "fuzz": each run starts real tasks against the
// clock, about 30 ms, so the nightly fuzz job for pubsub skips it and a job
// of its own fuzzes it fewer times. `zig build test` runs it like any other.
test "slow property Subscriber: random loads, failures and limits never lose a message" {
    try test_util.fuzzBytes({}, chaosProperty, .{
        // Real tasks and real time: a few runs, not hundreds.
        .random_runs = 8,
        .max_len = 8,
        .corpus = &.{
            "\x01\x01\x00\x00\x00\x01",
            "\x18\x04\x01\x02\x02\x08",
            "\x0c\x02\x00\x01\x00\x04",
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
    return s.dispatch(pulled);
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
