[Docs](../README.md) › [Firestore](README.md) › Transactions

# Transactions

`client.runTransaction(handler, options)` runs a handler in a
transaction: its reads join the transaction, and its writes are kept
and committed together when it returns, all or none. When another
transaction holds what this one needs, the server answers ABORTED, and
the handler runs again, from the start, in a new transaction.

**On this page:** [A handler](#a-handler) ·
[When it runs again](#when-it-runs-again) · [Read-only](#read-only) ·
[By hand](#by-hand) · [Limits](#limits)

## A handler

A `TransactionHandler` is a pointer and a function, as pubsub's
handlers are. The function reads through the `Transaction` it is
given, `get`, `batchGet`, `runQuery`, `runAggregationQuery`, and writes
through it, `set`, `update`, `delete`, `write`:

<!-- snippet: examples/firestore.zig#transfer -->
```zig
/// Moves `amount` of `field` from one document to another, as a
/// transaction's handler: run again from the start whenever the server
/// aborts the transaction, so it only reads and writes through `txn`.
const Transfer = struct {
    from: []const u8,
    to: []const u8,
    field: []const u8,
    amount: i64,
    /// What the documents held when last read.
    balance: i64 = 0,
    received: i64 = 0,

    fn handler(self: *Transfer) firestore.TransactionHandler {
        return .{ .ptr = self, .vtable = &.{ .run = run } };
    }

    fn run(ptr: *anyopaque, txn: *firestore.Transaction) anyerror!void {
        const self: *Transfer = @ptrCast(@alignCast(ptr));
        var both = try txn.batchGet(&.{ self.from, self.to }, .{});
        defer both.deinit();
        self.balance = number(both.value.documents[0], self.field);
        self.received = number(both.value.documents[1], self.field);
        if (self.balance < self.amount) return error.InsufficientFunds;
        try txn.set(self.from, &.{.{ .name = self.field, .value = .{ .integer = self.balance - self.amount } }}, .{});
        try txn.set(self.to, &.{.{ .name = self.field, .value = .{ .integer = self.received + self.amount } }}, .{});
    }

    /// The document's integer `field`, 0 when it or the field is missing.
    fn number(doc: ?firestore.Snapshot, field: []const u8) i64 {
        const d = doc orelse return 0;
        const v = d.get(field) orelse return 0;
        return if (v == .integer) v.integer else 0;
    }
};
```

`client.runTransaction(transfer.handler(), .{})` runs it;
[`examples/firestore.zig`](../../examples/firestore.zig) has it as
`zig build example-firestore -- transfer accounts/alice accounts/bob balance 25`.

- A write is checked when made, and copied: what it points to need not
  outlive the call. Returning from the handler commits them all.
- A read does not see the transaction's own writes, which are sent only
  at the end. Read first, then write.
- A transaction's reads lock what they read until it ends. Measured on
  the emulator, a conflicting commit waits about 2 s for the lock, then
  answers ABORTED "Transaction lock timeout.".
- A handler with no writes ends its transaction with a rollback.

## When it runs again

The handler runs again only when the server answers ABORTED, from the
commit or from a read the handler passes on, and at most
`options.max_attempts` times in all, 5 by default, as in Google's
clients:

- Each new transaction names the last as the one it retries, which
  keeps its place in line for locks.
- The client's retry policy spaces the runs, as it spaces any retry.
- Every failure rolls the transaction back, a failed commit included, so
  its locks go at once rather than when it expires. The failure's own
  diagnostics are what the caller reads.
- Any other error, the handler's own included, rolls back and is
  returned at once.

Since the handler can run more than once, whatever else it does must
bear repeating: keep its effects to reads and writes through `txn`, and
anything it keeps for after, as `Transfer` keeps balances, from its last
run.

A transaction's commit is sent once, never again after a lost answer: a
repeat of one that landed would answer ABORTED, which would run the
handler a second time and apply its writes twice. A commit that fails
that way says in its diagnostics that it may or may not have committed.

Three tasks incrementing one counter in transactions, against the
emulator and in production, end with every increment counted once; in
production, 9 increments took 14 to 15 runs.

## Read-only

`.read_only = true` begins a transaction that only reads, every read as
of one time: now, or `.read_time`. It takes no writes, refused when
made, and runs once.

## By hand

`client.beginTransaction(.read_write)` or
`client.beginTransaction(.{ .read_only = .{ .read_time = t } })` returns
a transaction's id, which `GetOptions`, `BatchGetOptions`,
`QueryOptions` and `CommitOptions` take as `.transaction`.
`client.rollback(id)` ends one without writing; a transaction left open
holds its locks until it expires.

Reads in a transaction travel in the request's body: measured, the
emulator hangs for a minute on a transaction id sent in the URL, and
the transaction expires.

## Limits

A transaction lasts at most 270 s, and expires after 60 s without a
request. One that is over answers ABORTED "The referenced transaction
has expired or is no longer valid."; a read-only one given writes,
`error.InvalidArgument`, "Cannot modify entities in a read-only
transaction.".
