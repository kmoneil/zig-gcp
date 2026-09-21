//! A publisher: takes messages from any task, batches them into publish
//! requests, and sends those on tasks of its own. A request carrying a
//! hundred small messages takes about as long as one carrying a single
//! message, so batching turns a round trip per message into a share of one.
//! Each message gets a `Receipt` to wait on for the server's message id.
//!
//! ```zig
//! var publisher = try pubsub.Publisher.init(gpa, io, .{
//!     .topic_id = "orders",
//!     .client = .{ .project_id = "my-project", .token_provider = creds.provider() },
//! });
//! defer publisher.deinit();
//! var running = try io.concurrent(pubsub.Publisher.run, .{&publisher});
//! defer {
//!     publisher.stop(); // sends what is left; run returns when all of it has resolved
//!     running.await(io) catch {};
//! }
//!
//! // From any task:
//! const receipt = try publisher.publish(.{ .data = "hello" }, .{});
//! defer receipt.release();
//! const id = try receipt.wait();
//! ```
//!
//! `run` blocks the calling task and sends on tasks of its own: `concurrency`
//! senders, each with a client and a connection of its own, and a timer. A
//! batch goes out when a sender is free and the batch is full, by message
//! count or by request bytes, or its first message has waited
//! `max_batch_delay_ms`. Until a sender takes it, it keeps filling, so under
//! load requests grow toward the thresholds by themselves. Transient failures
//! are retried until the batch's deadline, `publish_timeout_ms` after its
//! first message was published.
//!
//! What a publisher holds is capped: `max_outstanding` messages and
//! `max_outstanding_bytes` of request body, counting everything accepted and
//! not yet resolved. At a cap, `publish` waits for room, or with
//! `when_full = .fail` refuses at once. `flush` sends everything now and
//! waits for what was accepted before it.
//!
//! A publisher runs once and must not be moved after `init`. Its allocator is
//! used from several tasks at once.

const Publisher = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.DoublyLinkedList;
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const url = @import("url.zig");
const validate = @import("validate.zig");
const Diagnostics = core.Diagnostics;
const RetryPolicy = core.RetryPolicy;

gpa: Allocator,
io: std.Io,
/// Owned: `/v1/projects/{project}/topics/{id}:publish`.
path: []const u8,
/// Owned. Sender `i` sends on `senders[i]`, which reports into
/// `sender_diags[i]`.
senders: []Client,
sender_diags: []Diagnostics,
max_batch_messages: u32,
max_batch_bytes: usize,
max_batch_delay_ms: u32,
publish_timeout_ms: u32,
max_outstanding: u32,
max_outstanding_bytes: u64,
when_full: WhenFull,
/// The backoff between attempts; its `max_attempts` does not apply, since a
/// publisher retries by time.
retry: RetryPolicy,
retry_publish: bool,
/// The clients' own limit on one request; 0 means none.
request_timeout_ms: u32,
/// Where `init` and `run` report their failures. Borrowed.
caller_diag: ?*Diagnostics,

// Shared state. Everything below `mutex` is guarded by it, except
// `timer_event`, which synchronizes itself.
mutex: std.Io.Mutex,
/// Broadcast when a batch comes due, when one resolves, and on `stop`.
cond: core.Condition,
/// Set when a batch opens, so the timer looks again.
timer_event: std.Io.Event,
unkeyed: KeyState,
/// Every batch not yet resolved, in the order it opened.
unresolved: List,
/// Open batches whose delay has not run out, in the order they opened.
waiting: List,
/// Batches a sender may take, in the order their first messages arrived.
due: List,
stopping: bool,
ran: bool,
/// Messages accepted so far. A batch notes the number of its first.
sequence: u64,
/// Messages accepted and not yet resolved, and their bytes of request body.
outstanding: u32,
outstanding_bytes: u64,
counts: Stats,

pub const Options = struct {
    /// The topic to publish to, such as "orders".
    topic_id: []const u8,
    /// How to reach the server. The publisher runs `concurrency` clients with
    /// these options. A custom `transport` is used from that many tasks at
    /// once and must tolerate it; the built-in one is per client.
    /// `diagnostics` receives the details of an `init` or `run` failure.
    client: Client.Options,
    /// Publish requests in flight at once, each on a client and connection
    /// of its own.
    concurrency: u16 = 4,
    /// A batch is full at this many messages, 1 to 1,000...
    max_batch_messages: u16 = 100,
    /// ...or at this many bytes of request body as sent, JSON with the data
    /// in base64, up to 10,485,760. A bigger message goes in a batch alone.
    max_batch_bytes: u32 = 1_000_000,
    /// A batch that is not full goes out once its first message has waited
    /// this long. 0 sends as soon as a connection is free.
    max_batch_delay_ms: u32 = 10,
    /// The most messages held at once: accepted and not yet resolved,
    /// whether buffered, in flight or waiting to be retried. At least
    /// `max_batch_messages`.
    max_outstanding: u32 = 1000,
    /// The same cap in bytes of request body. At least `max_batch_bytes`.
    /// A message bigger than this on its own is let in when nothing else is
    /// outstanding, so none waits forever.
    max_outstanding_bytes: u64 = 10_000_000,
    /// What `publish` does at either cap.
    when_full: WhenFull = .block,
    /// How long a message may take from `publish` to its result, retries
    /// included. Transient failures are retried until then; a batch still
    /// unsent then fails with `error.TimedOut`.
    publish_timeout_ms: u32 = 60_000,
};

pub const WhenFull = enum {
    /// `publish` waits for room. The wait can be canceled, and then nothing
    /// is published. Before `run` starts, it waits for `run`.
    block,
    /// `publish` returns `error.PublisherFull` at once.
    fail,
};

pub const PublishOptions = struct {
    /// Filled when `publish` itself fails, such as for a message over a
    /// limit. Many tasks publish at once, so this is per call.
    diagnostics: ?*Diagnostics = null,
};

/// `pubsub.Error`, plus what only a publisher returns.
pub const Error = errors.Error || error{
    /// `stop` was called, or `run` ended before the message's outcome was
    /// known. A request in flight when `run` was canceled may have been
    /// stored.
    PublisherStopped,
    /// `when_full` is `.fail` and a cap is reached.
    PublisherFull,
};

/// Counters since `init`. A consistent snapshot from `stats`.
pub const Stats = struct {
    /// Messages `publish` accepted.
    published: u64 = 0,
    /// Messages the server confirmed with an id.
    succeeded: u64 = 0,
    /// Messages that failed, whatever the reason.
    failed: u64 = 0,
    /// Publish requests sent, retries included.
    requests: u64 = 0,
    /// Messages accepted and not yet resolved, right now.
    outstanding: u32 = 0,
    /// Their bytes of request body.
    outstanding_bytes: u64 = 0,
};

/// One accepted message. Release it, whether or not anyone waits on it.
pub const Receipt = struct {
    batch: *Batch,
    index: u32,

    /// Blocks until the message is sent or has failed, and returns the
    /// server's message id, valid until `release`. Canceling the waiting
    /// task returns `error.Canceled` and leaves the message in flight.
    pub fn wait(self: Receipt) Error![]const u8 {
        try self.batch.resolved.wait(self.batch.io);
        return switch (self.batch.outcome) {
            .sent => |ids| ids.value.message_ids[self.index],
            .failed => |err| err,
        };
    }

    /// The details of a failure, once `wait` has returned. Valid until
    /// `release`.
    pub fn diagnostics(self: Receipt) *const Diagnostics {
        if (!self.batch.resolved.isSet()) return &no_diagnostics;
        return &self.batch.diag;
    }

    /// Needed whether or not anyone waited. The message goes out either way.
    pub fn release(self: Receipt) void {
        self.batch.unref();
    }
};

const no_diagnostics: Diagnostics = .{};

/// What a batch came to.
const Outcome = union(enum) {
    /// The server's ids, one per message, in order.
    sent: types.Owned(types.PublishResult),
    failed: Error,
};

/// The messages of one publish request, from the first message to the last
/// receipt released.
const Batch = struct {
    gpa: Allocator,
    io: std.Io,
    key: *KeyState,
    /// `publish_body_head` and the messages so far, joined by commas. There
    /// is always room left for `publish_body_tail`, which `sendBatch` appends.
    /// Freed when the batch resolves.
    body: std.ArrayList(u8),
    count: u32,
    /// The request's size once closed: the body plus its tail.
    bytes: usize,
    /// The number `publish` gave this batch's first message.
    first_sequence: u64,
    opened_at: std.Io.Timestamp,
    deadline: std.Io.Timestamp,
    state: State,
    /// Links the batch into `Publisher.unresolved` until it resolves.
    all_node: List.Node = .{},
    /// Links it into `Publisher.waiting` or `Publisher.due`, or neither.
    queue_node: List.Node = .{},
    /// One for the publisher until the batch resolves, and one per receipt
    /// not yet released. The last one frees the batch.
    refs: std.atomic.Value(u32),
    /// Set once `outcome` and `diag` are final.
    resolved: std.Io.Event = .unset,
    outcome: Outcome = undefined,
    diag: Diagnostics = .{},

    const State = enum {
        /// Taking messages; its delay has not run out.
        open,
        /// Taking messages, and a sender may take it.
        due,
        /// Taking no more messages, and a sender may take it.
        full,
        /// A sender has it.
        sending,
        resolved,
    };

    fn ofQueueNode(node: *List.Node) *Batch {
        return @alignCast(@fieldParentPtr("queue_node", node));
    }

    fn ofAllNode(node: *List.Node) *Batch {
        return @alignCast(@fieldParentPtr("all_node", node));
    }

    fn unref(b: *Batch) void {
        if (b.refs.fetchSub(1, .acq_rel) != 1) return;
        // Only a resolved batch loses its last reference: the publisher
        // holds one until then.
        switch (b.outcome) {
            .sent => |*ids| ids.deinit(),
            .failed => {},
        }
        b.body.deinit(b.gpa);
        b.gpa.destroy(b);
    }
};

/// The state batches of one ordering key share. Messages without a key
/// share `Publisher.unkeyed`.
const KeyState = struct {
    /// The batch taking this key's messages, if any.
    open: ?*Batch = null,
    /// Requests in flight.
    in_flight: u32 = 0,
    /// Batches not yet resolved.
    batches: u32 = 0,
};

/// Checks the options and builds the clients. Sends nothing.
pub fn init(gpa: Allocator, io: std.Io, options: Options) Error!Publisher {
    const diag = options.client.diagnostics;
    if (diag) |d| d.clear();
    if (!validate.isResourceId(options.topic_id)) {
        if (diag) |d| d.print(
            "invalid topic id: ids are 3 to 255 characters from [A-Za-z0-9-_.~+%], start with a letter, and do not start with \"goog\"",
            .{},
        );
        return error.InvalidResourceId;
    }
    if (optionsProblem(options)) |problem| {
        if (diag) |d| d.print("invalid publisher options: {s}", .{problem});
        return error.InvalidOptions;
    }

    // Each client checks the shared options and reports to the caller's
    // diagnostics, then reports into its own sender's from then on.
    const senders = try gpa.alloc(Client, options.concurrency);
    errdefer gpa.free(senders);
    var made: usize = 0;
    errdefer for (senders[0..made]) |*client| client.deinit();
    for (senders) |*client| {
        client.* = try .init(gpa, io, options.client);
        made += 1;
    }
    const sender_diags = try gpa.alloc(Diagnostics, options.concurrency);
    errdefer gpa.free(sender_diags);
    for (senders, sender_diags) |*client, *d| {
        d.* = .{};
        client.diagnostics = d;
    }
    // `resourcePath` expects an arena: it leaves a partial path behind when
    // it runs out of memory.
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const path = try gpa.dupe(u8, try url.resourcePath(scratch.allocator(), senders[0].project_id, .topics, options.topic_id, ":publish"));
    errdefer gpa.free(path);

    return .{
        .gpa = gpa,
        .io = io,
        .path = path,
        .senders = senders,
        .sender_diags = sender_diags,
        .max_batch_messages = options.max_batch_messages,
        .max_batch_bytes = options.max_batch_bytes,
        .max_batch_delay_ms = options.max_batch_delay_ms,
        .publish_timeout_ms = options.publish_timeout_ms,
        .max_outstanding = options.max_outstanding,
        .max_outstanding_bytes = options.max_outstanding_bytes,
        .when_full = options.when_full,
        .retry = options.client.retry,
        .retry_publish = options.client.retry_publish,
        .request_timeout_ms = options.client.request_timeout_ms,
        .caller_diag = diag,
        .mutex = .init,
        .cond = .init,
        .timer_event = .unset,
        .unkeyed = .{},
        .unresolved = .{},
        .waiting = .{},
        .due = .{},
        .stopping = false,
        .ran = false,
        .sequence = 0,
        .outstanding = 0,
        .outstanding_bytes = 0,
        .counts = .{},
    };
}

fn optionsProblem(options: Options) ?[]const u8 {
    if (options.concurrency == 0) return "concurrency must be at least 1";
    if (options.max_batch_messages == 0 or options.max_batch_messages > validate.max_messages_per_publish) {
        return "max_batch_messages must be 1 to 1000";
    }
    if (options.max_batch_bytes == 0 or options.max_batch_bytes > validate.max_publish_request_bytes) {
        return "max_batch_bytes must be 1 to 10485760";
    }
    if (options.publish_timeout_ms == 0) return "publish_timeout_ms must be at least 1";
    if (options.max_batch_delay_ms >= options.publish_timeout_ms) {
        return "max_batch_delay_ms must be less than publish_timeout_ms";
    }
    // A cap below one full batch would keep every batch from filling.
    if (options.max_outstanding < options.max_batch_messages) {
        return "max_outstanding must hold at least one full batch, max_batch_messages";
    }
    if (options.max_outstanding_bytes < options.max_batch_bytes) {
        return "max_outstanding_bytes must hold at least one full batch, max_batch_bytes";
    }
    return null;
}

/// `run` must have returned, or never been called. Messages never sent fail
/// with `error.PublisherStopped`. Receipts may outlive the publisher; the
/// allocator must outlive them.
pub fn deinit(self: *Publisher) void {
    self.abandon();
    for (self.senders) |*client| client.deinit();
    self.gpa.free(self.senders);
    self.gpa.free(self.sender_diags);
    self.gpa.free(self.path);
    self.* = undefined;
}

/// Encodes `message` into a batch and returns its receipt. Safe from any
/// task. The message is copied: the caller may free it at once. At a cap,
/// waits for room or refuses, as `Options.when_full` says.
pub fn publish(self: *Publisher, message: types.Message, options: PublishOptions) Error!Receipt {
    const diag = options.diagnostics;
    if (diag) |d| d.clear();
    try validate.publish(&.{message}, null, diag);
    // Encoded before taking the lock: base64 of a large message takes a
    // while, and the other tasks need not wait for it.
    const encoded = try codec.encodeMessage(self.gpa, message, null);
    defer self.gpa.free(encoded);

    const io = self.io;
    try self.mutex.lock(io);
    defer self.mutex.unlock(io);
    const key = &self.unkeyed;
    while (true) {
        if (self.stopping) {
            if (diag) |d| d.print("the publisher is stopped and takes no more messages", .{});
            return error.PublisherStopped;
        }
        if (self.hasRoom(key, encoded.len)) break;
        switch (self.when_full) {
            .fail => {
                if (diag) |d| d.print(
                    "the publisher is full: {d} messages and {d} bytes are waiting to be sent, and its caps are {d} and {d}",
                    .{ self.outstanding, self.outstanding_bytes, self.max_outstanding, self.max_outstanding_bytes },
                );
                return error.PublisherFull;
            },
            // Every batch that resolves broadcasts, and so does stop().
            .block => try self.cond.wait(io, &self.mutex),
        }
    }
    return self.add(key, encoded);
}

/// Sends every batch now, without waiting out delays, and returns once
/// every message accepted before the call has resolved, sent or failed.
/// Safe from any task. Before `run` starts, it waits for `run`.
pub fn flush(self: *Publisher) std.Io.Cancelable!void {
    const io = self.io;
    try self.mutex.lock(io);
    defer self.mutex.unlock(io);
    const through = self.sequence;
    self.makeAllDue();
    // The oldest unresolved batch is first, so once it began after `through`,
    // everything before has resolved.
    while (self.unresolved.first) |node| {
        if (Batch.ofAllNode(node).first_sequence >= through) return;
        try self.cond.wait(io, &self.mutex);
    }
}

/// Accepts no more messages. `run` sends everything it holds and returns
/// once every accepted message has resolved. Safe from any task, before or
/// during `run`.
pub fn stop(self: *Publisher) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.stopping = true;
    self.makeAllDue();
}

/// A consistent snapshot of the counters.
pub fn stats(self: *Publisher) Stats {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var snapshot = self.counts;
    snapshot.outstanding = self.outstanding;
    snapshot.outstanding_bytes = self.outstanding_bytes;
    return snapshot;
}

/// Sends batches until `stop` and every message accepted before it has
/// resolved, blocking the calling task. A publisher runs once. Canceling
/// `run` gives up on what is still unsent: those receipts get
/// `error.PublisherStopped`.
pub fn run(self: *Publisher) Error!void {
    const io = self.io;
    {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.ran) {
            if (self.caller_diag) |d| d.print("a Publisher runs once; init another to run again", .{});
            return error.InvalidOptions;
        }
        self.ran = true;
    }

    var timer = io.concurrent(timerLoop, .{self}) catch return self.cannotRun();
    var senders: std.Io.Group = .init;
    for (0..self.senders.len) |i| senders.concurrent(io, senderLoop, .{ self, i }) catch {
        senders.cancel(io);
        discard(timer.cancel(io));
        return self.cannotRun();
    };

    // Until stop() and the drain behind it. Cancellation lands here too, and
    // the teardown below takes the tasks down with it.
    const drained = self.awaitDrained();
    senders.cancel(io);
    discard(timer.cancel(io));
    // After a cancel, whatever is left never goes.
    self.abandon();
    return drained;
}

fn discard(result: std.Io.Cancelable!void) void {
    result catch {};
}

fn cannotRun(self: *Publisher) Error {
    if (self.caller_diag) |d| d.print("this Io cannot run concurrent tasks, which a Publisher needs", .{});
    self.abandon();
    return error.InvalidOptions;
}

fn awaitDrained(self: *Publisher) std.Io.Cancelable!void {
    const io = self.io;
    try self.mutex.lock(io);
    defer self.mutex.unlock(io);
    while (!self.stopping or self.unresolved.first != null) try self.cond.wait(io, &self.mutex);
}

/// Stops the publisher and fails every batch still unsent with
/// `error.PublisherStopped`. No sender may be running.
fn abandon(self: *Publisher) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.stopping = true;
    var stopped: Diagnostics = .{};
    stopped.print("the publisher stopped before this message was sent", .{});
    while (self.unresolved.first) |node| {
        const batch: *Batch = Batch.ofAllNode(node);
        std.debug.assert(batch.state != .sending);
        self.finish(batch, .{ .failed = error.PublisherStopped }, &stopped);
    }
}

// Batches. Everything from here to the senders runs under the mutex.

/// Appends an encoded message to `key`'s open batch, opening one when there
/// is none or when the message would take it past a threshold.
fn add(self: *Publisher, key: *KeyState, encoded: []const u8) Allocator.Error!Receipt {
    if (key.open) |open| if (!self.joins(open, encoded.len)) self.close(open);
    var fresh = false;
    const batch = key.open orelse b: {
        fresh = true;
        break :b try self.openBatch(key, encoded.len);
    };
    // The one step that can fail comes before anything changes. A fresh
    // batch already has room for its first message.
    if (!fresh) try batch.body.ensureUnusedCapacity(self.gpa, 1 + encoded.len + codec.publish_body_tail.len);

    const bytes_before = if (fresh) 0 else batch.bytes;
    if (batch.count > 0) {
        batch.body.appendAssumeCapacity(',');
        batch.bytes += 1;
    }
    batch.body.appendSliceAssumeCapacity(encoded);
    batch.bytes += encoded.len;
    batch.count += 1;
    _ = batch.refs.fetchAdd(1, .monotonic);
    self.outstanding += 1;
    self.outstanding_bytes += batch.bytes - bytes_before;
    self.sequence += 1;
    self.counts.published += 1;

    const receipt: Receipt = .{ .batch = batch, .index = batch.count - 1 };
    if (batch.count >= self.max_batch_messages or batch.bytes >= self.max_batch_bytes) self.close(batch);
    return receipt;
}

/// Whether a message of `len` encoded bytes fits in the open batch `open`.
fn joins(self: *const Publisher, open: *const Batch, len: usize) bool {
    return open.count < self.max_batch_messages and open.bytes + 1 + len <= self.max_batch_bytes;
}

/// The request bytes a message of `len` encoded bytes would add: a comma
/// and itself in `key`'s open batch, or a new batch around it.
fn bytesAdded(self: *const Publisher, key: *const KeyState, len: usize) usize {
    if (key.open) |open| if (self.joins(open, len)) return 1 + len;
    return codec.publish_body_head.len + len + codec.publish_body_tail.len;
}

/// Whether a message of `len` encoded bytes fits under the caps. With
/// nothing outstanding anything fits, so no message waits forever.
fn hasRoom(self: *const Publisher, key: *const KeyState, len: usize) bool {
    if (self.outstanding == 0) return true;
    if (self.outstanding >= self.max_outstanding) return false;
    return self.outstanding_bytes + self.bytesAdded(key, len) <= self.max_outstanding_bytes;
}

/// A new batch for `key`, with room for a first message of `first_len`
/// bytes. It is `key`'s open batch from now on.
fn openBatch(self: *Publisher, key: *KeyState, first_len: usize) Allocator.Error!*Batch {
    const gpa = self.gpa;
    const io = self.io;
    const batch = try gpa.create(Batch);
    errdefer gpa.destroy(batch);
    const head = codec.publish_body_head;
    const tail = codec.publish_body_tail;
    var body: std.ArrayList(u8) = try .initCapacity(gpa, head.len + first_len + tail.len);
    body.appendSliceAssumeCapacity(head);
    const now = std.Io.Clock.awake.now(io);
    batch.* = .{
        .gpa = gpa,
        .io = io,
        .key = key,
        .body = body,
        .count = 0,
        .bytes = head.len + tail.len,
        .first_sequence = self.sequence,
        .opened_at = now,
        .deadline = now.addDuration(.fromMilliseconds(self.publish_timeout_ms)),
        .state = .open,
        .refs = .init(1),
    };
    self.unresolved.append(&batch.all_node);
    key.open = batch;
    key.batches += 1;
    if (self.max_batch_delay_ms == 0) {
        batch.state = .due;
        self.insertDue(batch);
        self.cond.broadcast(io);
    } else {
        self.waiting.append(&batch.queue_node);
    }
    self.timer_event.set(io);
    return batch;
}

/// The batch takes no more messages and may go.
fn close(self: *Publisher, batch: *Batch) void {
    std.debug.assert(batch.key.open == batch);
    batch.key.open = null;
    switch (batch.state) {
        .open => {
            self.waiting.remove(&batch.queue_node);
            self.insertDue(batch);
        },
        .due => {},
        .full, .sending, .resolved => unreachable,
    }
    batch.state = .full;
    self.cond.broadcast(self.io);
}

/// The batch may go, and keeps taking messages until a sender takes it.
/// The caller wakes the senders.
fn makeDue(self: *Publisher, batch: *Batch) void {
    std.debug.assert(batch.state == .open);
    self.waiting.remove(&batch.queue_node);
    batch.state = .due;
    self.insertDue(batch);
}

fn makeAllDue(self: *Publisher) void {
    while (self.waiting.first) |node| self.makeDue(Batch.ofQueueNode(node));
    self.cond.broadcast(self.io);
}

/// Files a batch among the due ones by the time its first message arrived.
fn insertDue(self: *Publisher, batch: *Batch) void {
    var at = self.due.last;
    while (at) |node| : (at = node.prev) {
        const other: *Batch = Batch.ofQueueNode(node);
        if (other.opened_at.nanoseconds <= batch.opened_at.nanoseconds) {
            self.due.insertAfter(node, &batch.queue_node);
            return;
        }
    }
    self.due.prepend(&batch.queue_node);
}

/// The due batch a sender should send next, taken off the list, or null.
fn tryTake(self: *Publisher) ?*Batch {
    const node = self.due.first orelse return null;
    const batch: *Batch = Batch.ofQueueNode(node);
    self.due.remove(node);
    if (batch.key.open == batch) batch.key.open = null;
    batch.state = .sending;
    batch.key.in_flight += 1;
    return batch;
}

/// Records what became of a batch, wakes its receipts, and drops the
/// publisher's reference to it.
fn finish(self: *Publisher, batch: *Batch, outcome: Outcome, diag: ?*const Diagnostics) void {
    const key = batch.key;
    switch (batch.state) {
        .open => self.waiting.remove(&batch.queue_node),
        .due, .full => self.due.remove(&batch.queue_node),
        .sending => key.in_flight -= 1,
        .resolved => unreachable,
    }
    if (key.open == batch) key.open = null;
    key.batches -= 1;
    self.unresolved.remove(&batch.all_node);
    self.outstanding -= batch.count;
    self.outstanding_bytes -= batch.bytes;
    switch (outcome) {
        .sent => self.counts.succeeded += batch.count,
        .failed => |err| {
            self.counts.failed += batch.count;
            logging.warn("publishing {d} messages failed with {t}", .{ batch.count, err });
        },
    }
    batch.outcome = outcome;
    if (diag) |d| batch.diag = d.*;
    batch.state = .resolved;
    batch.body.clearAndFree(self.gpa);
    batch.resolved.set(self.io);
    self.cond.broadcast(self.io);
    batch.unref();
}

// The timer.

fn timerLoop(self: *Publisher) std.Io.Cancelable!void {
    const io = self.io;
    while (true) {
        const next = next: {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            // Cleared before looking, so a batch opened from here on sets it
            // again and the wait below returns at once.
            self.timer_event.reset();
            break :next self.tick();
        };
        const timeout: std.Io.Timeout = if (next) |at| .{ .deadline = .{ .raw = at, .clock = .awake } } else .none;
        self.timer_event.waitTimeout(io, timeout) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
    }
}

/// The timer's work: batches whose delay ran out come due, and due batches
/// past their deadline fail unsent. Returns when to look again, or null
/// when no batch waits for anything.
fn tick(self: *Publisher) ?std.Io.Timestamp {
    const now = std.Io.Clock.awake.now(self.io);
    const delay: std.Io.Duration = .fromMilliseconds(self.max_batch_delay_ms);
    var woke = false;
    while (self.waiting.first) |node| {
        const batch: *Batch = Batch.ofQueueNode(node);
        if (batch.opened_at.addDuration(delay).nanoseconds > now.nanoseconds) break;
        self.makeDue(batch);
        woke = true;
    }
    if (woke) self.cond.broadcast(self.io);

    // Due batches are in the order their first messages arrived, which is
    // the order of their deadlines too.
    while (self.due.first) |node| {
        const batch: *Batch = Batch.ofQueueNode(node);
        if (batch.deadline.nanoseconds > now.nanoseconds) break;
        var d: Diagnostics = .{};
        d.print("the batch was still unsent at its deadline, {d} ms after its first message", .{self.publish_timeout_ms});
        self.finish(batch, .{ .failed = error.TimedOut }, &d);
    }

    var next: ?std.Io.Timestamp = null;
    if (self.waiting.first) |node| {
        const batch: *Batch = Batch.ofQueueNode(node);
        next = batch.opened_at.addDuration(delay);
    }
    if (self.due.first) |node| {
        const batch: *Batch = Batch.ofQueueNode(node);
        if (next == null or batch.deadline.nanoseconds < next.?.nanoseconds) next = batch.deadline;
    }
    return next;
}

// The senders.

fn senderLoop(self: *Publisher, index: usize) std.Io.Cancelable!void {
    while (true) {
        const batch = try self.take();
        try self.sendAndResolve(index, batch);
    }
}

/// Waits for a batch to send.
fn take(self: *Publisher) std.Io.Cancelable!*Batch {
    const io = self.io;
    try self.mutex.lock(io);
    defer self.mutex.unlock(io);
    while (true) {
        if (self.tryTake()) |batch| return batch;
        try self.cond.wait(io, &self.mutex);
    }
}

/// Sends `batch` on sender `index`'s client and resolves it. A cancel is
/// returned, never swallowed, after the batch is resolved as stopped: std
/// delivers a cancel once, and a sender that carried on would keep `run`
/// waiting for it forever.
fn sendAndResolve(self: *Publisher, index: usize, batch: *Batch) std.Io.Cancelable!void {
    const diag = &self.sender_diags[index];
    if (self.sendBatch(&self.senders[index], diag, batch)) |ids| {
        self.resolve(batch, .{ .sent = ids }, null);
    } else |err| {
        if (err == error.Canceled) {
            var stopped: Diagnostics = .{};
            stopped.print("the publisher stopped while this batch was in flight; the server may have stored it", .{});
            self.resolve(batch, .{ .failed = error.PublisherStopped }, &stopped);
            return error.Canceled;
        }
        self.resolve(batch, .{ .failed = err }, diag);
    }
}

fn resolve(self: *Publisher, batch: *Batch, outcome: Outcome, diag: ?*const Diagnostics) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.finish(batch, outcome, diag);
}

/// Sends one batch, retrying transient failures until its deadline. The
/// last failure is returned when no time is left for another attempt.
fn sendBatch(self: *Publisher, client: *Client, diag: *Diagnostics, batch: *Batch) Error!types.Owned(types.PublishResult) {
    const io = self.io;
    // Room for the tail was kept with every message added.
    batch.body.appendSliceAssumeCapacity(codec.publish_body_tail);
    var result: types.Owned(types.PublishResult) = try .init(self.gpa);
    errdefer result.deinit();

    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        const left_ms = msUntil(io, batch.deadline);
        if (left_ms <= 0) {
            diag.print("the batch reached its deadline, {d} ms after its first message, before it could be sent", .{self.publish_timeout_ms});
            return error.TimedOut;
        }
        client.request_timeout_ms = attemptLimitMs(self.request_timeout_ms, left_ms);
        _ = result.arena.reset(.retain_capacity);
        self.countRequest();
        rpc.begin(client);
        const sent = rpc.execute(client, result.arena, .{
            .method = .POST,
            .path = self.path,
            .body = batch.body.items,
            // This loop retries, by time; each call makes one attempt.
            .retry = false,
        });
        if (sent) |body| {
            result.value = codec.decodePublish(result.arena.allocator(), body, batch.count) catch |err|
                return rpc.decodeFailed(client, err, "publish");
            return result;
        } else |err| {
            if (err == error.Canceled) return err;
            if (!self.retry_publish or !rpc.isPublishRetryable(err, diag.http_status)) return err;
            const delay_ms = self.retry.backoffMs(attempt, core.rpc.entropy(io));
            // No time for another attempt: the failure stands.
            if (delay_ms >= msUntil(io, batch.deadline)) return err;
            logging.warn("publishing {d} messages failed with {t}; retrying in {d} ms", .{ batch.count, err, delay_ms });
            try io.sleep(.fromMilliseconds(delay_ms), .awake);
        }
    }
}

fn countRequest(self: *Publisher) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.counts.requests += 1;
}

fn msUntil(io: std.Io, deadline: std.Io.Timestamp) i64 {
    return std.Io.Clock.awake.now(io).durationTo(deadline).toMilliseconds();
}

/// One attempt's limit: the clients' own, cut to the time left. A client
/// limit of 0 means none, which leaves the time left.
fn attemptLimitMs(client_limit_ms: u32, left_ms: i64) u32 {
    const left: u32 = @intCast(std.math.clamp(left_ms, 1, std.math.maxInt(u32)));
    return if (client_limit_ms == 0) left else @min(client_limit_ms, left);
}

// Tests drive the publisher two ways. Most run on one task against a fake
// clock: `sendDue` does a sender's work and `advance` the timer's, so every
// outcome is deterministic, and an allocation-failure sweep can reach the
// whole path. The rest run `run` for real, with real tasks and real time,
// against the same fake server.

/// Tests only: does a sender's work from the calling task until no batch is
/// due, on sender 0's client.
fn sendDue(self: *Publisher) std.Io.Cancelable!void {
    while (true) {
        const batch = b: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            break :b self.tryTake() orelse return;
        };
        try self.sendAndResolve(0, batch);
    }
}

/// Tests only: does the timer's work once.
fn tickNow(self: *Publisher) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    _ = self.tick();
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Transport = core.transport.Transport;
const TransportError = core.transport.Error;
const Request = core.transport.Request;
const Response = core.transport.Response;

/// A topic behind the `Transport` seam, safe to use from several tasks: it
/// stores what each publish request carries, answers with ids, and fails,
/// holds or slows requests on command.
const FakeTopic = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: core.Condition = .init,
    /// Every publish request, in the order it arrived.
    requests: std.ArrayList(Seen) = .empty,
    /// How to answer the next requests, in order. Once it runs out, every
    /// request succeeds.
    script: []const Answer = &.{},
    scripted: usize = 0,
    next_id: u64 = 1,
    in_flight: u32 = 0,
    max_in_flight: u32 = 0,
    /// Held requests, right now.
    held: u32 = 0,
    /// Held requests go once fewer than this many requests came before
    /// them: `release` lets them all go, `releaseThrough` the earliest.
    released_through: usize = 0,

    const Seen = struct {
        /// The messages' data, decoded.
        data: [][]u8,
        /// The body's size.
        bytes: usize,
        /// The request's own limit.
        timeout_ms: u32,
        /// When it arrived, on the fake's clock.
        at_ns: i96,
    };

    const Answer = union(enum) {
        /// Store the messages and answer with their ids.
        ok,
        /// Store nothing, and answer with this status.
        status: struct { u16, []const u8 },
        /// Fail as the transport would.
        fail: TransportError,
        /// Store the messages, and answer with one id too few.
        short,
        /// Wait until `release` or cancellation, then answer as `ok`.
        hold,
        /// Take this long by the fake's clock, then answer as `ok`.
        slow: u32,
        /// Take this long, then answer with this status.
        slow_status: struct { u32, u16, []const u8 },
    };

    fn deinit(f: *FakeTopic) void {
        for (f.requests.items) |seen| {
            for (seen.data) |d| f.gpa.free(d);
            f.gpa.free(seen.data);
        }
        f.requests.deinit(f.gpa);
        f.* = undefined;
    }

    fn transport(f: *FakeTopic) Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    /// Lets every held request go, and every later one through.
    fn release(f: *FakeTopic) void {
        f.releaseThrough(std.math.maxInt(usize));
    }

    /// Lets the first `n` requests go, if held.
    fn releaseThrough(f: *FakeTopic, n: usize) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.released_through = n;
        f.cond.broadcast(f.io);
    }

    fn requestCount(f: *FakeTopic) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.requests.items.len;
    }

    fn heldCount(f: *FakeTopic) u32 {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.held;
    }

    /// The message counts of the requests so far, in order.
    fn counts(f: *FakeTopic, buffer: []usize) []usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        for (f.requests.items, buffer[0..f.requests.items.len]) |seen, *n| n.* = seen.data.len;
        return buffer[0..f.requests.items.len];
    }

    const Wire = struct {
        messages: []const struct { data: ?[]const u8 = null } = &.{},
    };

    fn send(ptr: *anyopaque, req: Request, arena: Allocator) TransportError!Response {
        const f: *FakeTopic = @ptrCast(@alignCast(ptr));
        const io = f.io;
        const body = req.body orelse return error.HttpProtocolError;
        // The arena is the publisher's, so it can run out of memory under an
        // allocation-failure sweep, and that must read as what it is.
        const wire = std.json.parseFromSliceLeaky(Wire, arena, body, .{ .ignore_unknown_fields = true }) catch |err|
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.HttpProtocolError,
            };

        const index, const answer = a: {
            f.mutex.lockUncancelable(io);
            defer f.mutex.unlock(io);
            try f.record(wire, body.len, req.timeout_ms);
            f.in_flight += 1;
            f.max_in_flight = @max(f.max_in_flight, f.in_flight);
            const answer: Answer = if (f.scripted < f.script.len) f.script[f.scripted] else .ok;
            f.scripted += 1;
            break :a .{ f.requests.items.len - 1, answer };
        };
        defer {
            f.mutex.lockUncancelable(io);
            f.in_flight -= 1;
            f.mutex.unlock(io);
        }

        switch (answer) {
            .hold => {
                f.mutex.lockUncancelable(io);
                defer f.mutex.unlock(io);
                f.held += 1;
                defer f.held -= 1;
                while (index >= f.released_through) f.cond.wait(io, &f.mutex) catch return error.Canceled;
            },
            .slow => |ms| io.sleep(.fromMilliseconds(ms), .awake) catch return error.Canceled,
            .status => |s| {
                const code, const status = s;
                return errorResponse(arena, code, status);
            },
            .slow_status => |s| {
                const ms, const code, const status = s;
                io.sleep(.fromMilliseconds(ms), .awake) catch return error.Canceled;
                return errorResponse(arena, code, status);
            },
            .fail => |err| return err,
            .ok, .short => {},
        }

        const ids = wire.messages.len - @intFromBool(answer == .short);
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        {
            f.mutex.lockUncancelable(io);
            defer f.mutex.unlock(io);
            w.writeAll("{\"messageIds\":[") catch return error.OutOfMemory;
            for (0..ids) |i| {
                if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
                w.print("\"{d}\"", .{f.next_id}) catch return error.OutOfMemory;
                f.next_id += 1;
            }
            w.writeAll("]}") catch return error.OutOfMemory;
        }
        return .{ .status = 200, .body = out.written() };
    }

    fn errorResponse(arena: Allocator, code: u16, status: []const u8) TransportError!Response {
        return .{ .status = code, .body = try std.fmt.allocPrint(
            arena,
            "{{\"error\":{{\"code\":{d},\"message\":\"scripted\",\"status\":\"{s}\"}}}}",
            .{ code, status },
        ) };
    }

    /// Stores what a request carried. Holds the mutex.
    fn record(f: *FakeTopic, wire: Wire, bytes: usize, timeout_ms: u32) TransportError!void {
        const data = try f.gpa.alloc([]u8, wire.messages.len);
        var made: usize = 0;
        errdefer {
            for (data[0..made]) |d| f.gpa.free(d);
            f.gpa.free(data);
        }
        const decoder = std.base64.standard.Decoder;
        for (wire.messages, data) |m, *out| {
            const text = m.data orelse "";
            out.* = try f.gpa.alloc(u8, decoder.calcSizeForSlice(text) catch return error.HttpProtocolError);
            made += 1;
            decoder.decode(out.*, text) catch return error.HttpProtocolError;
        }
        try f.requests.append(f.gpa, .{
            .data = data,
            .bytes = bytes,
            .timeout_ms = timeout_ms,
            .at_ns = std.Io.Clock.awake.now(f.io).nanoseconds,
        });
    }
};

const TestOptions = struct {
    concurrency: u16 = 1,
    max_batch_messages: u16 = 100,
    max_batch_bytes: u32 = 1_000_000,
    max_batch_delay_ms: u32 = 10,
    publish_timeout_ms: u32 = 60_000,
    // Far above what any test publishes, except the tests of the caps.
    max_outstanding: u32 = 100_000,
    max_outstanding_bytes: u64 = 1 << 30,
    when_full: WhenFull = .block,
    retry: RetryPolicy = .{ .initial_backoff_ms = 100, .max_backoff_ms = 1_000 },
    retry_publish: bool = true,
    request_timeout_ms: u32 = 180_000,
};

fn testOptions(transport: Transport, o: TestOptions) Options {
    return .{
        .topic_id = "orders",
        .client = .{
            .project_id = "p",
            .endpoint = .{ .url = "localhost:1", .emulator = true },
            .transport = transport,
            .retry = o.retry,
            .retry_publish = o.retry_publish,
            .request_timeout_ms = o.request_timeout_ms,
        },
        .concurrency = o.concurrency,
        .max_batch_messages = o.max_batch_messages,
        .max_batch_bytes = o.max_batch_bytes,
        .max_batch_delay_ms = o.max_batch_delay_ms,
        .publish_timeout_ms = o.publish_timeout_ms,
        .max_outstanding = o.max_outstanding,
        .max_outstanding_bytes = o.max_outstanding_bytes,
        .when_full = o.when_full,
    };
}

/// A publisher on a fake clock, driven from the test's own task.
const Solo = struct {
    clock: test_util.FakeClock,
    fake: FakeTopic,
    publisher: Publisher,

    fn init(s: *Solo, options: TestOptions) !void {
        s.clock = .{};
        s.fake = .{ .gpa = testing.allocator, .io = s.clock.io() };
        errdefer s.fake.deinit();
        s.publisher = try .init(testing.allocator, s.clock.io(), testOptions(s.fake.transport(), options));
    }

    fn deinit(s: *Solo) void {
        s.publisher.deinit();
        s.fake.deinit();
    }

    /// Moves the fake clock on, then does the timer's work.
    fn advance(s: *Solo, ms: i64) void {
        s.clock.now_ns += @as(i96, ms) * std.time.ns_per_ms;
        s.publisher.tickNow();
    }

    fn publishText(s: *Solo, text: []const u8) !Receipt {
        return s.publisher.publish(.{ .data = text }, .{});
    }
};

/// The id a resolved receipt holds, or the error.
fn idOf(receipt: Receipt) Error![]const u8 {
    std.debug.assert(receipt.batch.resolved.isSet());
    return receipt.wait();
}

test "batches: a batch is full at the message count, and the rest waits out the delay" {
    var s: Solo = undefined;
    try s.init(.{ .max_batch_messages = 3 });
    defer s.deinit();
    var receipts: [7]Receipt = undefined;
    var made: usize = 0;
    defer for (receipts[0..made]) |r| r.release();
    var buf: [8]usize = undefined;
    for (&receipts, 0..) |*r, i| {
        var text: [8]u8 = undefined;
        r.* = try s.publishText(try std.fmt.bufPrint(&text, "m{d}", .{i}));
        made += 1;
        // A batch may go the moment its third message arrives, not when
        // the next one pushes it out.
        try s.publisher.sendDue();
        try testing.expectEqual((i + 1) / 3, s.fake.counts(&buf).len);
    }
    try testing.expectEqualSlices(usize, &.{ 3, 3 }, s.fake.counts(&buf));
    // The seventh waits for its delay.
    s.advance(9);
    try s.publisher.sendDue();
    try testing.expectEqual(2, s.fake.requestCount());
    s.advance(1);
    try s.publisher.sendDue();
    try testing.expectEqualSlices(usize, &.{ 3, 3, 1 }, s.fake.counts(&buf));

    for (receipts, 1..) |r, id| {
        var want: [8]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{d}", .{id}), try idOf(r));
    }
    const counts = s.publisher.stats();
    try testing.expectEqual(7, counts.published);
    try testing.expectEqual(7, counts.succeeded);
    try testing.expectEqual(3, counts.requests);
    try testing.expectEqual(0, counts.outstanding);
    try testing.expectEqual(0, counts.outstanding_bytes);
}

test "batches: a batch is full at exactly max_batch_bytes, and one byte less splits it" {
    // Three messages whose encoded forms are the same length: the body of
    // two is head + m + ',' + m + tail.
    const one = try codec.encodeMessage(testing.allocator, .{ .data = "abc" }, null);
    defer testing.allocator.free(one);
    const two_bytes = codec.publish_body_head.len + 2 * one.len + 1 + codec.publish_body_tail.len;
    try testing.expectEqual(two_bytes, codec.publishBodyLen(&.{ .{ .data = "abc" }, .{ .data = "abc" } }, null));

    for ([_]struct { u32, [3]usize, []const usize }{
        // Two fit exactly, and the batch is full, so it goes, the moment
        // the second arrives.
        .{ @intCast(two_bytes), .{ 0, 1, 1 }, &.{ 2, 1 } },
        // One byte short: each message closes the batch before it, and the
        // last one waits out its delay.
        .{ @intCast(two_bytes - 1), .{ 0, 1, 2 }, &.{ 1, 1, 1 } },
    }) |case| {
        const limit, const sent_after, const want = case;
        var s: Solo = undefined;
        try s.init(.{ .max_batch_bytes = limit });
        defer s.deinit();
        var receipts: [3]Receipt = undefined;
        var made: usize = 0;
        defer for (receipts[0..made]) |r| r.release();
        var buf: [4]usize = undefined;
        for (&receipts, sent_after) |*r, requests| {
            r.* = try s.publishText("abc");
            made += 1;
            try s.publisher.sendDue();
            try testing.expectEqual(requests, s.fake.counts(&buf).len);
        }
        s.advance(10);
        try s.publisher.sendDue();
        try testing.expectEqualSlices(usize, want, s.fake.counts(&buf));
        s.fake.mutex.lockUncancelable(s.fake.io);
        defer s.fake.mutex.unlock(s.fake.io);
        for (s.fake.requests.items) |seen| try testing.expect(seen.bytes <= limit);
    }
}

test "batches: a message bigger than max_batch_bytes goes in a batch by itself" {
    var s: Solo = undefined;
    try s.init(.{ .max_batch_bytes = 200 });
    defer s.deinit();
    const big: [300]u8 = @splat('b');
    const receipts = [_]Receipt{
        try s.publishText("small"),
        try s.publishText(&big),
        try s.publishText("after"),
    };
    defer for (receipts) |r| r.release();
    // The big one closed the first batch and filled its own at once.
    try s.publisher.sendDue();
    var buf: [4]usize = undefined;
    try testing.expectEqualSlices(usize, &.{ 1, 1 }, s.fake.counts(&buf));
    s.advance(10);
    try s.publisher.sendDue();
    try testing.expectEqualSlices(usize, &.{ 1, 1, 1 }, s.fake.counts(&buf));
    s.fake.mutex.lockUncancelable(s.fake.io);
    defer s.fake.mutex.unlock(s.fake.io);
    try testing.expectEqualStrings(&big, s.fake.requests.items[1].data[0]);
}

test "batches: no request breaks the API's limits of 1,000 messages and 10,485,760 bytes" {
    var s: Solo = undefined;
    try s.init(.{ .max_batch_messages = 1000, .max_batch_bytes = validate.max_publish_request_bytes });
    defer s.deinit();
    const gpa = testing.allocator;
    var receipts: std.ArrayList(Receipt) = .empty;
    defer {
        for (receipts.items) |r| r.release();
        receipts.deinit(gpa);
    }
    for (0..1001) |_| try receipts.append(gpa, try s.publishText("x"));
    // Three messages of 3 MiB: 4 MiB each as base64. The 1,001st small
    // message and two of them fit one request; the third starts the next.
    const big = try gpa.alloc(u8, 3 * 1024 * 1024);
    defer gpa.free(big);
    @memset(big, 'z');
    for (0..3) |_| try receipts.append(gpa, try s.publisher.publish(.{ .data = big }, .{}));
    s.advance(10);
    try s.publisher.sendDue();
    var buf: [8]usize = undefined;
    try testing.expectEqualSlices(usize, &.{ 1000, 3, 1 }, s.fake.counts(&buf));
    s.fake.mutex.lockUncancelable(s.fake.io);
    defer s.fake.mutex.unlock(s.fake.io);
    for (s.fake.requests.items) |seen| try testing.expect(seen.bytes <= validate.max_publish_request_bytes);
}

test "batches: at a delay of 0 a lone message is due at once" {
    var s: Solo = undefined;
    try s.init(.{ .max_batch_delay_ms = 0 });
    defer s.deinit();
    const receipt = try s.publishText("now");
    defer receipt.release();
    try s.publisher.sendDue();
    try testing.expectEqualStrings("1", try idOf(receipt));
}

test "batches: a due batch keeps filling until a sender takes it" {
    var s: Solo = undefined;
    try s.init(.{});
    defer s.deinit();
    const first = try s.publishText("first");
    defer first.release();
    s.advance(10);
    // Due, but no sender has come for it yet.
    const second = try s.publishText("second");
    defer second.release();
    try s.publisher.sendDue();
    var buf: [2]usize = undefined;
    try testing.expectEqualSlices(usize, &.{2}, s.fake.counts(&buf));
}

test "deadlines: transient failures are retried until the deadline, then the last one stands" {
    var s: Solo = undefined;
    try s.init(.{ .publish_timeout_ms = 5_000 });
    defer s.deinit();
    const unavailable: FakeTopic.Answer = .{ .status = .{ 503, "UNAVAILABLE" } };
    s.fake.script = &(.{unavailable} ** 64);
    const receipt = try s.publishText("doomed");
    defer receipt.release();
    s.advance(10);
    try s.publisher.sendDue();
    try testing.expectError(error.Unavailable, idOf(receipt));
    try testing.expectEqualStrings("UNAVAILABLE", receipt.diagnostics().status());
    const attempts = s.fake.requestCount();
    try testing.expect(attempts > 3);
    try testing.expectEqual(attempts, s.publisher.stats().requests);
    // Every attempt started before the deadline.
    s.fake.mutex.lockUncancelable(s.fake.io);
    defer s.fake.mutex.unlock(s.fake.io);
    for (s.fake.requests.items) |seen| try testing.expect(seen.at_ns < 5_000 * std.time.ns_per_ms);
}

test "deadlines: a failure that clears in time is survived" {
    var s: Solo = undefined;
    try s.init(.{});
    defer s.deinit();
    s.fake.script = &.{
        .{ .status = .{ 503, "UNAVAILABLE" } },
        .{ .status = .{ 409, "ABORTED" } },
        .{ .fail = error.ConnectionResetByPeer },
        .ok,
    };
    const receipt = try s.publishText("persistent");
    defer receipt.release();
    s.advance(10);
    try s.publisher.sendDue();
    try testing.expectEqualStrings("1", try idOf(receipt));
    try testing.expectEqual(4, s.fake.requestCount());
    try testing.expectEqual(1, s.publisher.stats().succeeded);
}

test "deadlines: a batch still unsent at its deadline fails with TimedOut, never sent" {
    var s: Solo = undefined;
    try s.init(.{ .publish_timeout_ms = 1_000 });
    defer s.deinit();
    const receipt = try s.publishText("late");
    defer receipt.release();
    s.advance(10);
    // No sender came; then the timer finds it past its deadline.
    s.advance(990);
    try testing.expectError(error.TimedOut, idOf(receipt));
    try testing.expect(std.mem.indexOf(u8, receipt.diagnostics().message(), "deadline") != null);
    try testing.expectEqual(0, s.fake.requestCount());
    try testing.expectEqual(1, s.publisher.stats().failed);
}

test "deadlines: retry_publish = false makes exactly one attempt" {
    var s: Solo = undefined;
    try s.init(.{ .retry_publish = false });
    defer s.deinit();
    s.fake.script = &.{.{ .status = .{ 503, "UNAVAILABLE" } }};
    const receipt = try s.publishText("once");
    defer receipt.release();
    s.advance(10);
    try s.publisher.sendDue();
    try testing.expectError(error.Unavailable, idOf(receipt));
    try testing.expectEqual(1, s.fake.requestCount());
}

test "deadlines: a failure retrying cannot fix is final at once" {
    var s: Solo = undefined;
    try s.init(.{});
    defer s.deinit();
    s.fake.script = &.{.{ .status = .{ 404, "NOT_FOUND" } }};
    const receipt = try s.publishText("nowhere");
    defer receipt.release();
    s.advance(10);
    try s.publisher.sendDue();
    try testing.expectError(error.NotFound, idOf(receipt));
    try testing.expectEqual(404, receipt.diagnostics().http_status);
    try testing.expectEqual(1, s.fake.requestCount());
}

test "deadlines: each attempt's limit is the client's, cut to the time left" {
    var s: Solo = undefined;
    try s.init(.{ .publish_timeout_ms = 20_000, .request_timeout_ms = 15_000 });
    defer s.deinit();
    s.clock.random_byte = 0; // no backoff: the clock moves only when told
    // The first attempt takes 9 s and fails; the second starts with 11 s
    // left of the 20.
    s.fake.script = &.{ .{ .slow_status = .{ 9_000, 503, "UNAVAILABLE" } }, .ok };
    const receipt = try s.publishText("tight");
    defer receipt.release();
    s.advance(10);
    try s.publisher.sendDue();
    try testing.expectEqualStrings("1", try idOf(receipt));
    s.fake.mutex.lockUncancelable(s.fake.io);
    defer s.fake.mutex.unlock(s.fake.io);
    const seen = s.fake.requests.items;
    try testing.expectEqual(2, seen.len);
    // The client's 15 s, while the batch has more than that.
    try testing.expectEqual(15_000, seen[0].timeout_ms);
    // Then the 10,990 ms left.
    try testing.expectEqual(10_990, seen[1].timeout_ms);
}

test "deadlines: a client with no request limit gets the time left" {
    var s: Solo = undefined;
    try s.init(.{ .publish_timeout_ms = 20_000, .request_timeout_ms = 0 });
    defer s.deinit();
    const receipt = try s.publishText("bounded anyway");
    defer receipt.release();
    s.advance(10);
    try s.publisher.sendDue();
    s.fake.mutex.lockUncancelable(s.fake.io);
    defer s.fake.mutex.unlock(s.fake.io);
    try testing.expectEqual(19_990, s.fake.requests.items[0].timeout_ms);
}

test "deadlines: a success the client cannot decode is final, never retried" {
    var s: Solo = undefined;
    try s.init(.{});
    defer s.deinit();
    s.fake.script = &.{.short};
    const receipt = try s.publishText("stored, probably");
    defer receipt.release();
    s.advance(10);
    try s.publisher.sendDue();
    try testing.expectError(error.InvalidResponse, idOf(receipt));
    try testing.expectEqual(1, s.fake.requestCount());
}

test "receipts: released before the batch goes, the batch still goes and is freed after" {
    var s: Solo = undefined;
    try s.init(.{});
    defer s.deinit();
    (try s.publishText("fire")).release();
    (try s.publishText("and forget")).release();
    s.advance(10);
    try s.publisher.sendDue();
    const counts = s.publisher.stats();
    try testing.expectEqual(2, counts.succeeded);
    try testing.expectEqual(1, counts.requests);
}

test "receipts: a failure no one waits for is counted and logged" {
    var s: Solo = undefined;
    try s.init(.{});
    defer s.deinit();
    s.fake.script = &.{.{ .status = .{ 404, "NOT_FOUND" } }};
    logging.capture.reset();
    (try s.publishText("unwatched")).release();
    s.advance(10);
    try s.publisher.sendDue();
    try testing.expectEqual(1, s.publisher.stats().failed);
    try testing.expect(std.mem.indexOf(u8, logging.capture.text(), "publishing 1 messages failed with NotFound") != null);
    // Never the data.
    try testing.expect(std.mem.indexOf(u8, logging.capture.text(), "unwatched") == null);
}

test "receipts: outlive the publisher" {
    var clock: test_util.FakeClock = .{};
    var fake: FakeTopic = .{ .gpa = testing.allocator, .io = clock.io() };
    defer fake.deinit();
    var publisher: Publisher = try .init(testing.allocator, clock.io(), testOptions(fake.transport(), .{}));
    const sent = try publisher.publish(.{ .data = "kept" }, .{});
    defer sent.release();
    clock.now_ns += 10 * std.time.ns_per_ms;
    publisher.tickNow();
    try publisher.sendDue();
    const unsent = try publisher.publish(.{ .data = "never sent" }, .{});
    defer unsent.release();
    publisher.deinit();

    try testing.expectEqualStrings("1", try sent.wait());
    try testing.expectError(error.PublisherStopped, unsent.wait());
    try testing.expect(std.mem.indexOf(u8, unsent.diagnostics().message(), "stopped") != null);
}

test "lifecycle: publish after stop is PublisherStopped, with a reason" {
    var s: Solo = undefined;
    try s.init(.{});
    defer s.deinit();
    s.publisher.stop();
    var diag: Diagnostics = .{};
    try testing.expectError(error.PublisherStopped, s.publisher.publish(.{ .data = "late" }, .{ .diagnostics = &diag }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "stopped") != null);
    try testing.expectEqual(0, s.publisher.stats().published);
}

test "lifecycle: stop makes every batch due at once" {
    var s: Solo = undefined;
    try s.init(.{ .max_batch_delay_ms = 50_000 });
    defer s.deinit();
    const receipt = try s.publishText("hurry");
    defer receipt.release();
    try s.publisher.sendDue();
    try testing.expectEqual(0, s.fake.requestCount());
    s.publisher.stop();
    try s.publisher.sendDue();
    try testing.expectEqualStrings("1", try idOf(receipt));
}

test "lifecycle: invalid messages are refused before anything is kept" {
    var s: Solo = undefined;
    try s.init(.{});
    defer s.deinit();
    var diag: Diagnostics = .{};
    try testing.expectError(error.InvalidMessage, s.publisher.publish(.{}, .{ .diagnostics = &diag }));
    try testing.expectEqualStrings("message 0 has no data and no attributes", diag.message());
    const too_big = try testing.allocator.alloc(u8, 7_864_300);
    defer testing.allocator.free(too_big);
    try testing.expectError(error.InvalidMessage, s.publisher.publish(.{ .data = too_big }, .{ .diagnostics = &diag }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "10485762 bytes") != null);
    try testing.expectEqual(0, s.publisher.stats().published);
}

fn expectRefused(options: Options, want: Error, text: []const u8) !void {
    try testing.expectError(want, Publisher.init(testing.allocator, testing.io, options));
    const message = options.client.diagnostics.?.message();
    if (std.mem.indexOf(u8, message, text) == null) {
        std.debug.print("diagnostics \"{s}\" lack \"{s}\"\n", .{ message, text });
        return error.TestUnexpectedDiagnostics;
    }
}

test "init refuses what cannot work, and says why" {
    var diag: Diagnostics = .{};
    var fake: FakeTopic = .{ .gpa = testing.allocator, .io = testing.io };
    defer fake.deinit();
    var base = testOptions(fake.transport(), .{});
    base.client.diagnostics = &diag;

    var o = base;
    o.topic_id = "goog-reserved";
    try expectRefused(o, error.InvalidResourceId, "invalid topic id");
    o = base;
    o.client.project_id = "";
    try expectRefused(o, error.InvalidResourceId, "invalid project id");
    o = base;
    o.concurrency = 0;
    try expectRefused(o, error.InvalidOptions, "concurrency");
    o = base;
    o.max_batch_messages = 0;
    try expectRefused(o, error.InvalidOptions, "max_batch_messages");
    o = base;
    o.max_batch_messages = 1001;
    try expectRefused(o, error.InvalidOptions, "max_batch_messages");
    o = base;
    o.max_batch_bytes = 0;
    try expectRefused(o, error.InvalidOptions, "max_batch_bytes");
    o = base;
    o.max_batch_bytes = validate.max_publish_request_bytes + 1;
    try expectRefused(o, error.InvalidOptions, "max_batch_bytes");
    o = base;
    o.publish_timeout_ms = 0;
    try expectRefused(o, error.InvalidOptions, "publish_timeout_ms");
    o = base;
    o.max_batch_delay_ms = o.publish_timeout_ms;
    try expectRefused(o, error.InvalidOptions, "max_batch_delay_ms");
    o = base;
    o.max_outstanding = o.max_batch_messages - 1;
    try expectRefused(o, error.InvalidOptions, "max_outstanding must hold");
    o = base;
    o.max_outstanding_bytes = o.max_batch_bytes - 1;
    try expectRefused(o, error.InvalidOptions, "max_outstanding_bytes must hold");
}

test "flow control: .fail refuses at the message cap, says why, and lets in again once a batch resolves" {
    var s: Solo = undefined;
    try s.init(.{ .max_batch_messages = 3, .max_outstanding = 3, .when_full = .fail });
    defer s.deinit();
    var receipts: [3]Receipt = undefined;
    for (&receipts) |*r| r.* = try s.publishText("in");
    defer for (receipts) |r| r.release();
    var diag: Diagnostics = .{};
    try testing.expectError(error.PublisherFull, s.publisher.publish(.{ .data = "over" }, .{ .diagnostics = &diag }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "full: 3 messages") != null);
    try testing.expectEqual(3, s.publisher.stats().published);

    // The full batch goes, and its room comes back.
    try s.publisher.sendDue();
    const after = try s.publishText("room again");
    defer after.release();
    try testing.expectEqual(4, s.publisher.stats().published);
}

test "flow control: the byte cap counts request bytes exactly" {
    const one = try codec.encodeMessage(testing.allocator, .{ .data = "abc" }, null);
    defer testing.allocator.free(one);
    const two: u32 = @intCast(codec.publish_body_head.len + 2 * one.len + 1 + codec.publish_body_tail.len);
    var s: Solo = undefined;
    try s.init(.{ .max_batch_bytes = two, .max_outstanding_bytes = two, .when_full = .fail });
    defer s.deinit();
    // Two messages come to exactly the cap, so both are let in.
    const a = try s.publishText("abc");
    defer a.release();
    const b = try s.publishText("abc");
    defer b.release();
    try testing.expectEqual(two, s.publisher.stats().outstanding_bytes);
    try testing.expectError(error.PublisherFull, s.publishText("abc"));
    try s.publisher.sendDue();
    try testing.expectEqual(0, s.publisher.stats().outstanding_bytes);
    const c = try s.publishText("abc");
    defer c.release();
}

test "flow control: a message bigger than the byte cap gets in when nothing else is outstanding" {
    var s: Solo = undefined;
    try s.init(.{ .max_batch_bytes = 1000, .max_outstanding_bytes = 1000, .when_full = .fail });
    defer s.deinit();
    const big: [2000]u8 = @splat('b');
    const alone = try s.publisher.publish(.{ .data = &big }, .{});
    defer alone.release();
    try testing.expect(s.publisher.stats().outstanding_bytes > 1000);
    // With it outstanding, even a small one has no room.
    try testing.expectError(error.PublisherFull, s.publishText("small"));
    try s.publisher.sendDue();
    const small = try s.publishText("small");
    defer small.release();
}

test "init and deinit: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn initDeinit(gpa: Allocator) !void {
            var fake: FakeTopic = .{ .gpa = testing.allocator, .io = testing.io };
            defer fake.deinit();
            var publisher: Publisher = try .init(gpa, testing.io, testOptions(fake.transport(), .{ .concurrency = 3 }));
            publisher.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.initDeinit, .{});
}

test "publish, send and resolve: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn wholePath(gpa: Allocator) !void {
            var clock: test_util.FakeClock = .{};
            // The fake server allocates from the backing allocator: only the
            // publisher's allocations fail.
            var fake: FakeTopic = .{ .gpa = testing.allocator, .io = clock.io() };
            defer fake.deinit();
            fake.script = &.{ .{ .status = .{ 503, "UNAVAILABLE" } }, .ok, .ok };
            var publisher: Publisher = try .init(gpa, clock.io(), testOptions(fake.transport(), .{ .max_batch_messages = 2 }));
            defer publisher.deinit();
            var receipts: [3]?Receipt = @splat(null);
            defer for (receipts) |r| if (r) |receipt| receipt.release();
            for (&receipts, 0..) |*r, i| {
                var buf: [16]u8 = undefined;
                r.* = try publisher.publish(.{
                    .data = try std.fmt.bufPrint(&buf, "message {d}", .{i}),
                    .attributes = &.{.{ .key = "k", .value = "v" }},
                }, .{});
            }
            publisher.stop();
            try publisher.sendDue();
            // A batch the publisher could not send for want of memory fails
            // with OutOfMemory, and that is what this reports.
            for (receipts) |r| _ = try r.?.wait();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.wholePath, .{});
}

/// A publisher running for real, with its own tasks, against the fake.
/// Every wait it does is bounded: a stuck publisher panics, naming the test,
/// where it would otherwise hang the suite silently until CI gives up.
const Live = struct {
    fake: FakeTopic,
    publisher: Publisher,
    running: ?std.Io.Future(Error!void),
    returned: std.atomic.Value(bool),

    fn init(l: *Live, options: TestOptions) !void {
        l.fake = .{ .gpa = testing.allocator, .io = testing.io };
        errdefer l.fake.deinit();
        l.publisher = try .init(testing.allocator, testing.io, testOptions(l.fake.transport(), options));
        l.running = null;
        l.returned = .init(false);
    }

    fn start(l: *Live) !void {
        l.returned.store(false, .monotonic);
        l.running = try testing.io.concurrent(runFlagged, .{l});
    }

    fn runFlagged(l: *Live) Error!void {
        defer l.returned.store(true, .release);
        return l.publisher.run();
    }

    fn hasReturned(l: *Live) bool {
        return l.returned.load(.acquire);
    }

    /// Stops the publisher and returns what `run` returns.
    fn finish(l: *Live) Error!void {
        l.publisher.stop();
        var running = l.running orelse return;
        l.running = null;
        if (!try waitUntil(10_000, l, hasReturned)) @panic("Publisher.run had not returned 10 s after stop");
        return running.await(testing.io);
    }

    /// Cancels `run` and returns what it returns.
    fn cancel(l: *Live) anyerror!void {
        var canceling = try testing.io.concurrent(cancelRun, .{l});
        if (!try waitUntil(10_000, l, hasReturned)) @panic("Publisher.run had not returned 10 s after its cancel");
        return canceling.await(testing.io);
    }

    fn cancelRun(l: *Live) Error!void {
        var running = l.running.?;
        l.running = null;
        return running.cancel(testing.io);
    }

    fn deinit(l: *Live) void {
        if (l.running) |*running| discardRun(running.cancel(testing.io));
        l.publisher.deinit();
        l.fake.deinit();
    }

    fn discardRun(result: Error!void) void {
        result catch {};
    }
};

/// `receipt.wait()`, bounded: a receipt still unresolved after 10 s means
/// the publisher is stuck, and the test says so rather than hang.
fn waitBounded(receipt: Receipt) Error![]const u8 {
    const Resolved = struct {
        fn check(r: Receipt) bool {
            return r.batch.resolved.isSet();
        }
    };
    if (!try waitUntil(10_000, receipt, Resolved.check)) @panic("a receipt was still unresolved after 10 s");
    return receipt.wait();
}

/// True once `predicate` held, checked every 5 ms up to `limit_ms`.
fn waitUntil(limit_ms: i64, context: anytype, predicate: fn (@TypeOf(context)) bool) !bool {
    const io = testing.io;
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + limit_ms;
    while (!predicate(context)) {
        if (std.Io.Clock.awake.now(io).toMilliseconds() > deadline) return false;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    return true;
}

test "run: several tasks publish, every message goes out once, in fewer requests than messages" {
    var l: Live = undefined;
    try l.init(.{ .concurrency = 3, .max_batch_messages = 20, .max_batch_delay_ms = 5 });
    defer l.deinit();
    try l.start();

    const per_task = 60;
    const Tasks = struct {
        fn publishMany(publisher: *Publisher, task: usize, ids: *[per_task][]const u8) anyerror!void {
            var receipts: [per_task]Receipt = undefined;
            var made: usize = 0;
            defer for (receipts[0..made]) |r| r.release();
            for (&receipts, 0..) |*r, i| {
                var buf: [24]u8 = undefined;
                r.* = try publisher.publish(.{ .data = try std.fmt.bufPrint(&buf, "task {d} message {d}", .{ task, i }) }, .{});
                made += 1;
            }
            for (receipts, ids) |r, *id| id.* = try testing.allocator.dupe(u8, try waitBounded(r));
        }
    };
    // Freeing "" is a no-op, so ids never filled in are safe to free.
    var ids: [4][per_task][]const u8 = @splat(@splat(""));
    defer for (ids) |task_ids| for (task_ids) |id| testing.allocator.free(id);
    var tasks: [4]std.Io.Future(anyerror!void) = undefined;
    var started: usize = 0;
    defer for (tasks[0..started]) |*task| task.cancel(testing.io) catch {};
    for (&tasks, 0..) |*task, t| {
        task.* = try testing.io.concurrent(Tasks.publishMany, .{ &l.publisher, t, &ids[t] });
        started += 1;
    }
    for (&tasks) |*task| try task.await(testing.io);
    try l.finish();

    // Every id is distinct: nothing was sent twice or answered twice.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(testing.allocator);
    for (ids) |task_ids| for (task_ids) |id| {
        try testing.expect(try seen.fetchPut(testing.allocator, id, {}) == null);
    };
    try testing.expectEqual(4 * per_task, seen.count());
    const counts = l.publisher.stats();
    try testing.expectEqual(4 * per_task, counts.succeeded);
    try testing.expect(counts.requests < 4 * per_task);
    try testing.expect(l.fake.max_in_flight <= 3);
}

test "run: stop sends what is buffered at once, without waiting out the delay, then run returns" {
    var l: Live = undefined;
    // A delay far longer than the test is willing to wait.
    try l.init(.{ .max_batch_delay_ms = 50_000, .publish_timeout_ms = 120_000 });
    defer l.deinit();
    try l.start();
    var receipts: [5]Receipt = undefined;
    for (&receipts) |*r| r.* = try l.publisher.publish(.{ .data = "buffered" }, .{});
    defer for (receipts) |r| r.release();
    try l.finish();
    for (receipts) |r| _ = try waitBounded(r);
    try testing.expectEqual(1, l.fake.requestCount());
}

test "run: the timer sends a batch once its delay runs out" {
    var l: Live = undefined;
    try l.init(.{ .max_batch_delay_ms = 30 });
    defer l.deinit();
    try l.start();
    const receipt = try l.publisher.publish(.{ .data = "on time" }, .{});
    defer receipt.release();
    // No stop: only the timer can send it.
    try testing.expectEqualStrings("1", try waitBounded(receipt));
    try l.finish();
}

test "run: messages published before run wait for it, even past stop" {
    var l: Live = undefined;
    try l.init(.{});
    defer l.deinit();
    const receipt = try l.publisher.publish(.{ .data = "early" }, .{});
    defer receipt.release();
    l.publisher.stop();
    try l.start();
    try l.finish();
    try testing.expectEqualStrings("1", try receipt.wait());
    // A publisher runs once.
    var diag: Diagnostics = .{};
    l.publisher.caller_diag = &diag;
    try testing.expectError(error.InvalidOptions, l.publisher.run());
    try testing.expect(std.mem.indexOf(u8, diag.message(), "runs once") != null);
}

test "run: an Io that cannot run tasks is refused, and what was published fails" {
    var clock: test_util.FakeClock = .{};
    var fake: FakeTopic = .{ .gpa = testing.allocator, .io = clock.io() };
    defer fake.deinit();
    var diag: Diagnostics = .{};
    var options = testOptions(fake.transport(), .{});
    options.client.diagnostics = &diag;
    var publisher: Publisher = try .init(testing.allocator, clock.io(), options);
    defer publisher.deinit();
    const receipt = try publisher.publish(.{ .data = "stranded" }, .{});
    defer receipt.release();
    try testing.expectError(error.InvalidOptions, publisher.run());
    try testing.expect(std.mem.indexOf(u8, diag.message(), "concurrent tasks") != null);
    try testing.expectError(error.PublisherStopped, receipt.wait());
}

test "run: while every sender is busy, messages pile into one batch" {
    var l: Live = undefined;
    try l.init(.{ .concurrency = 1, .max_batch_delay_ms = 1 });
    defer l.deinit();
    l.fake.script = &.{.hold};
    try l.start();
    const first = try l.publisher.publish(.{ .data = "first" }, .{});
    defer first.release();
    const Held = struct {
        fn one(fake: *FakeTopic) bool {
            return fake.heldCount() == 1;
        }
    };
    try testing.expect(try waitUntil(5_000, &l.fake, Held.one));
    var rest: [10]Receipt = undefined;
    for (&rest) |*r| r.* = try l.publisher.publish(.{ .data = "queued" }, .{});
    defer for (rest) |r| r.release();
    l.fake.release();
    for (rest) |r| _ = try waitBounded(r);
    try l.finish();
    var buf: [4]usize = undefined;
    try testing.expectEqualSlices(usize, &.{ 1, 10 }, l.fake.counts(&buf));
}

test "run: canceling run fails what is unsent with PublisherStopped, and leaks nothing" {
    var l: Live = undefined;
    try l.init(.{ .concurrency = 2, .max_batch_messages = 1, .max_batch_delay_ms = 1 });
    defer l.deinit();
    l.fake.script = &.{ .hold, .hold };
    try l.start();
    var receipts: [4]Receipt = undefined;
    for (&receipts) |*r| r.* = try l.publisher.publish(.{ .data = "abandoned" }, .{});
    defer for (receipts) |r| r.release();
    const Held = struct {
        fn two(fake: *FakeTopic) bool {
            return fake.heldCount() == 2;
        }
    };
    try testing.expect(try waitUntil(5_000, &l.fake, Held.two));
    try testing.expectError(error.Canceled, l.cancel());
    for (receipts) |r| try testing.expectError(error.PublisherStopped, r.wait());
    // In flight when canceled: the server may have them.
    try testing.expect(std.mem.indexOf(u8, receipts[0].diagnostics().message(), "may have stored") != null);
    try testing.expectEqual(4, l.publisher.stats().failed);
}

/// Waits until the fake holds `n` requests, or panics after 5 s.
fn untilHeld(fake: *FakeTopic, n: u32) !void {
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 5_000;
    while (fake.heldCount() < n) {
        if (std.Io.Clock.awake.now(testing.io).toMilliseconds() > deadline) @panic("the fake never held the requests expected");
        try testing.io.sleep(.fromMilliseconds(2), .awake);
    }
}

/// A `publish` on a task of its own, so a test can watch it wait.
const Publishing = struct {
    publisher: *Publisher,
    receipt: ?Receipt = null,
    done: std.atomic.Value(bool) = .init(false),

    fn go(p: *Publishing, text: []const u8) Error!void {
        defer p.done.store(true, .release);
        p.receipt = try p.publisher.publish(.{ .data = text }, .{});
    }

    fn isDone(p: *Publishing) bool {
        return p.done.load(.acquire);
    }
};

test "flow control: .block waits for room, and wakes when a batch resolves" {
    var l: Live = undefined;
    try l.init(.{ .max_batch_messages = 2, .max_outstanding = 2, .max_batch_delay_ms = 1 });
    defer l.deinit();
    l.fake.script = &.{.hold};
    try l.start();
    const one = try l.publisher.publish(.{ .data = "one" }, .{});
    defer one.release();
    const two = try l.publisher.publish(.{ .data = "two" }, .{});
    defer two.release();
    try untilHeld(&l.fake, 1);

    var third: Publishing = .{ .publisher = &l.publisher };
    defer if (third.receipt) |r| r.release();
    var task = try testing.io.concurrent(Publishing.go, .{ &third, "three" });
    // It waits: both slots are taken by the held batch.
    try testing.io.sleep(.fromMilliseconds(50), .awake);
    try testing.expect(!third.isDone());
    try testing.expectEqual(2, l.publisher.stats().published);

    l.fake.release();
    if (!try waitUntil(10_000, &third, Publishing.isDone)) @panic("publish never got room after the batch resolved");
    try task.await(testing.io);
    try testing.expectEqualStrings("3", try waitBounded(third.receipt.?));
    try l.finish();
}

test "flow control: a publish waiting for room can be canceled, and publishes nothing" {
    var l: Live = undefined;
    try l.init(.{ .max_batch_messages = 1, .max_outstanding = 1, .max_batch_delay_ms = 1 });
    defer l.deinit();
    l.fake.script = &.{.hold};
    try l.start();
    const held = try l.publisher.publish(.{ .data = "held" }, .{});
    defer held.release();
    try untilHeld(&l.fake, 1);

    var waiting: Publishing = .{ .publisher = &l.publisher };
    var task = try testing.io.concurrent(Publishing.go, .{ &waiting, "never" });
    try testing.io.sleep(.fromMilliseconds(20), .awake);
    try testing.expectError(error.Canceled, task.cancel(testing.io));
    try testing.expectEqual(null, waiting.receipt);
    try testing.expectEqual(1, l.publisher.stats().published);

    l.fake.release();
    try l.finish();
    try testing.expectEqual(1, l.fake.requestCount());
}

/// `flush` on a task of its own.
const Flushing = struct {
    publisher: *Publisher,
    done: std.atomic.Value(bool) = .init(false),

    fn go(f: *Flushing) std.Io.Cancelable!void {
        defer f.done.store(true, .release);
        return f.publisher.flush();
    }

    fn isDone(f: *Flushing) bool {
        return f.done.load(.acquire);
    }
};

test "flush: sends what is buffered without waiting out the delay, and returns once it has resolved" {
    var l: Live = undefined;
    // A delay far longer than the test is willing to wait.
    try l.init(.{ .max_batch_delay_ms = 50_000, .publish_timeout_ms = 120_000 });
    defer l.deinit();
    try l.start();
    var receipts: [3]Receipt = undefined;
    for (&receipts) |*r| r.* = try l.publisher.publish(.{ .data = "buffered" }, .{});
    defer for (receipts) |r| r.release();

    var flushing: Flushing = .{ .publisher = &l.publisher };
    var task = try testing.io.concurrent(Flushing.go, .{&flushing});
    if (!try waitUntil(10_000, &flushing, Flushing.isDone)) @panic("flush never returned");
    try task.await(testing.io);
    for (receipts) |r| try testing.expect(r.batch.resolved.isSet());
    try testing.expectEqual(1, l.fake.requestCount());
    try l.finish();
}

test "flush: waits for what was published before it, and nothing after" {
    var l: Live = undefined;
    try l.init(.{ .concurrency = 2, .max_batch_messages = 1, .max_batch_delay_ms = 1 });
    defer l.deinit();
    l.fake.script = &.{ .hold, .hold };
    try l.start();
    const early = try l.publisher.publish(.{ .data = "before flush" }, .{});
    defer early.release();
    try untilHeld(&l.fake, 1);

    var flushing: Flushing = .{ .publisher = &l.publisher };
    var task = try testing.io.concurrent(Flushing.go, .{&flushing});
    try testing.io.sleep(.fromMilliseconds(20), .awake);
    try testing.expect(!flushing.isDone());
    const late = try l.publisher.publish(.{ .data = "after flush" }, .{});
    defer late.release();
    try untilHeld(&l.fake, 2);

    // Only the earlier request answers; flush returns with the later one
    // still in flight.
    l.fake.releaseThrough(1);
    if (!try waitUntil(10_000, &flushing, Flushing.isDone)) @panic("flush never returned");
    try task.await(testing.io);
    try testing.expect(early.batch.resolved.isSet());
    try testing.expect(!late.batch.resolved.isSet());

    l.fake.release();
    try testing.expectEqualStrings("2", try waitBounded(late));
    try l.finish();
}
