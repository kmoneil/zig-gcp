//! A condition variable for `std.Io` tasks: `std.Io.Condition` from Zig
//! 0.16.0, with one change.
//!
//! When std's `wait` is canceled, its futex wait returns `error.Canceled`,
//! and it then takes any signal still pending before it reports that. If a
//! signal is pending, it returns normally instead: the cancel is dropped.
//! That happens whenever another waiter on the same condition has not yet
//! claimed its share of a `broadcast`. std delivers a cancel once, so the
//! dropped one never comes back. The task's next wait cannot be canceled,
//! and whoever awaits the task waits forever.
//!
//! This `wait` returns `error.Canceled` whenever its futex wait did. It
//! still takes a pending signal, as std does, so none is left stranded, and
//! hands that signal to the next waiter in line, since it may have been
//! that waiter's.

const Condition = @This();

const std = @import("std");
const Io = std.Io;
const Mutex = Io.Mutex;
const assert = std.debug.assert;

state: std.atomic.Value(State),
/// Incremented whenever the condition is signaled.
epoch: std.atomic.Value(u32),

const State = packed struct(u32) {
    waiters: u16,
    signals: u16,
};

pub const init: Condition = .{
    .state = .init(.{ .waiters = 0, .signals = 0 }),
    .epoch = .init(0),
};

/// Unlocks `mutex`, waits for a signal, and locks `mutex` again, even when
/// canceled. Spurious wakeups are possible; wait in a loop.
pub fn wait(cond: *Condition, io: Io, mutex: *Mutex) Io.Cancelable!void {
    return waitInner(cond, io, mutex, false);
}

/// `wait`, without a cancelation point.
pub fn waitUncancelable(cond: *Condition, io: Io, mutex: *Mutex) void {
    waitInner(cond, io, mutex, true) catch |err| switch (err) {
        error.Canceled => unreachable,
    };
}

fn waitInner(cond: *Condition, io: Io, mutex: *Mutex, uncancelable: bool) Io.Cancelable!void {
    var epoch = cond.epoch.load(.acquire); // ordered before the state load
    {
        const prev = cond.state.fetchAdd(.{ .waiters = 1, .signals = 0 }, .monotonic);
        assert(prev.waiters < std.math.maxInt(u16)); // too many waiters
    }

    mutex.unlock(io);
    defer mutex.lockUncancelable(io);

    while (true) {
        const result = if (uncancelable)
            io.futexWaitUncancelable(u32, &cond.epoch.raw, epoch)
        else
            io.futexWait(u32, &cond.epoch.raw, epoch);
        epoch = cond.epoch.load(.acquire); // ordered before the state load

        // Take a pending signal whatever happened, as std does: left
        // alone, it could wait in the state for a waiter that never comes.
        const took_signal = took: {
            var prev = cond.state.load(.monotonic);
            while (prev.signals > 0) {
                prev = cond.state.cmpxchgWeak(prev, .{
                    .waiters = prev.waiters - 1,
                    .signals = prev.signals - 1,
                }, .acquire, .monotonic) orelse break :took true;
            }
            break :took false;
        };

        if (result) |_| {
            if (took_signal) return;
            // A spurious wakeup: wait again.
        } else |err| {
            if (took_signal) {
                // The one change from std, which returns normally here and
                // loses the cancel. The signal may have been another
                // waiter's: pass it on.
                cond.signal(io);
            } else {
                const prev = cond.state.fetchSub(.{ .waiters = 1, .signals = 0 }, .monotonic);
                assert(prev.waiters > 0);
            }
            return err;
        }
    }
}

/// Wakes one waiter, if there is one.
pub fn signal(cond: *Condition, io: Io) void {
    var prev = cond.state.load(.monotonic);
    while (prev.waiters > prev.signals) {
        prev = cond.state.cmpxchgWeak(prev, .{
            .waiters = prev.waiters,
            .signals = prev.signals + 1,
        }, .release, .monotonic) orelse {
            // Tell the waiters there are new signals for them.
            _ = cond.epoch.fetchAdd(1, .release); // ordered after the state update
            io.futexWake(u32, &cond.epoch.raw, 1);
            return;
        };
    }
}

/// Wakes every waiter.
pub fn broadcast(cond: *Condition, io: Io) void {
    var prev = cond.state.load(.monotonic);
    while (prev.waiters > prev.signals) {
        prev = cond.state.cmpxchgWeak(prev, .{
            .waiters = prev.waiters,
            .signals = prev.waiters,
        }, .release, .monotonic) orelse {
            _ = cond.epoch.fetchAdd(1, .release); // ordered after the state update
            io.futexWake(u32, &cond.epoch.raw, prev.waiters - prev.signals);
            return;
        };
    }
}

const testing = std.testing;

/// An `Io` whose futex waits report a cancel at once, as a task canceled
/// while it waits sees it, and whose wakes do nothing.
const CanceledWaits = struct {
    const vtable: Io.VTable = v: {
        var v = Io.failing.vtable.*;
        v.futexWait = futexWait;
        break :v v;
    };

    fn io() Io {
        return .{ .userdata = null, .vtable = &vtable };
    }

    fn futexWait(_: ?*anyopaque, _: *const u32, _: u32, _: Io.Timeout) Io.Cancelable!void {
        return error.Canceled;
    }
};

test "wait: a cancel is reported even while another waiter's signal is pending" {
    // The state a broadcast leaves: one other waiter, and a signal for it
    // not yet claimed. Then this task waits, and its wait is canceled.
    const io = CanceledWaits.io();

    // std's Condition takes that waiter's signal and returns normally: the
    // cancel is gone. When this starts failing, a newer Zig has fixed it,
    // and this file can go.
    var std_cond: Io.Condition = .init;
    std_cond.state.store(.{ .waiters = 1, .signals = 1 }, .monotonic);
    var mutex: Mutex = .init;
    mutex.lockUncancelable(io);
    try std_cond.wait(io, &mutex);
    mutex.unlock(io);

    // This one reports the cancel, and the signal is still there for the
    // other waiter.
    var cond: Condition = .init;
    cond.state.store(.{ .waiters = 1, .signals = 1 }, .monotonic);
    mutex.lockUncancelable(io);
    try testing.expectError(error.Canceled, cond.wait(io, &mutex));
    mutex.unlock(io);
    const state = cond.state.load(.monotonic);
    try testing.expectEqual(1, state.waiters);
    try testing.expectEqual(1, state.signals);
}

test "wait: a cancel with no signal pending leaves no waiter counted" {
    const io = CanceledWaits.io();
    var cond: Condition = .init;
    var mutex: Mutex = .init;
    mutex.lockUncancelable(io);
    try testing.expectError(error.Canceled, cond.wait(io, &mutex));
    // The mutex is held again, as after any wait.
    try testing.expect(!mutex.tryLock());
    mutex.unlock(io);
    const state = cond.state.load(.monotonic);
    try testing.expectEqual(0, state.waiters);
    try testing.expectEqual(0, state.signals);
}

test "signal and broadcast wake real waiters" {
    const io = testing.io;
    const Shared = struct {
        mutex: Mutex = .init,
        cond: Condition = .init,
        ready: usize = 0,
        go: bool = false,
        woke: usize = 0,

        fn waiter(s: *@This()) Io.Cancelable!void {
            try s.mutex.lock(io);
            defer s.mutex.unlock(io);
            s.ready += 1;
            while (!s.go) try s.cond.wait(io, &s.mutex);
            s.woke += 1;
        }

        fn readyCount(s: *@This()) usize {
            s.mutex.lockUncancelable(io);
            defer s.mutex.unlock(io);
            return s.ready;
        }
    };
    var shared: Shared = .{};
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..4) |_| try group.concurrent(io, Shared.waiter, .{&shared});
    while (shared.readyCount() < 4) try io.sleep(.fromMilliseconds(1), .awake);
    {
        shared.mutex.lockUncancelable(io);
        defer shared.mutex.unlock(io);
        shared.go = true;
        shared.cond.broadcast(io);
    }
    try group.await(io);
    try testing.expectEqual(4, shared.woke);
}

/// Rounds of the race std's Condition loses, over condition type `C`: each
/// cancels several waiters just as a broadcast wakes them.
fn Broadcasts(comptime C: type) type {
    return struct {
        mutex: Mutex = .init,
        cond: C = .init,

        const io = testing.io;

        fn waiter(s: *@This()) Io.Cancelable!void {
            try s.mutex.lock(io);
            defer s.mutex.unlock(io);
            while (true) try s.cond.wait(io, &s.mutex);
        }

        fn cancelDuring(rounds: usize, done: *std.atomic.Value(bool)) Io.ConcurrentError!void {
            defer done.store(true, .release);
            for (0..rounds) |_| {
                var shared: @This() = .{};
                var group: Io.Group = .init;
                for (0..3) |_| try group.concurrent(io, waiter, .{&shared});
                io.sleep(.fromMicroseconds(50), .awake) catch {};
                shared.mutex.lockUncancelable(io);
                shared.cond.broadcast(io);
                shared.mutex.unlock(io);
                group.cancel(io);
            }
        }
    };
}

test "canceling tasks that wait while a broadcast is in flight never hangs" {
    // With std's Condition in its place, some round hangs in Group.cancel
    // within a few hundred. Rather than hang the suite too, this gives up
    // after 30 s and says why.
    const io = testing.io;
    var done: std.atomic.Value(bool) = .init(false);
    var rounds = try io.concurrent(Broadcasts(Condition).cancelDuring, .{ 300, &done });
    const deadline = Io.Clock.awake.now(io).toMilliseconds() + 30_000;
    while (!done.load(.acquire)) {
        if (Io.Clock.awake.now(io).toMilliseconds() > deadline) {
            @panic("a canceled Condition.wait never returned: its cancel was lost");
        }
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try rounds.await(io);
}
