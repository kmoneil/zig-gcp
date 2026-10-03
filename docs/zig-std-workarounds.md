[Docs](README.md) › Zig 0.17 workarounds

# Zig 0.17 standard library issues handled here

Each of these is worked around here, and covered by a regression test in
`src/core/transport.zig` unless it says otherwise. Each was checked
against Zig 0.17.0's source when the library moved to it.

- A chunk size near 2^64 overflows `std.http`'s chunked decoder (a
  panic in a safe build), so the transport decodes chunked bodies
  itself.
- A body that ends before its `Content-Length` is reported as complete;
  the transport checks, and reports a dropped connection.
- The gzip decoder stops before the last chunk, which kept connections
  from being reused and made complete bodies look truncated.
- `[::1]` is not a host name to std's HTTP client, so
  `PUBSUB_EMULATOR_HOST=[::1]:8085` failed; the transport connects to
  an IPv6 literal itself.
- The TLS certificate clock is read once per client; the transport
  reloads it hourly and after a TLS failure.
- Streaming a body larger than the connection's read buffer into a
  writer with no buffer of its own trips an assertion in std's readers,
  which need somewhere writable; the transport passes bodies through a
  small buffer of its own.
- On Windows, std does not map `0xC000013B` (the peer hung up), so it
  arrives as `error.Unexpected`. The transport reads that as a dropped
  connection and retries, which is right for it and is also what any
  other unmapped Windows error gets: a retry it may not deserve. On
  other platforms `error.Unexpected` stays a permanent `NetworkFailure`.
  Zig 0.16 also left `0xC0000236` (connection refused) unmapped; Zig
  0.17 maps it to `error.ConnectionRefused`.
- `std.compress.flate.Decompress` reads each gzip member's trailer, its
  CRC-32 and length, and checks neither, so a corrupted member
  decompresses to wrong bytes without complaint. `storage`'s downloads
  check both themselves, in `src/storage/gzip_download.zig`, where a
  test also holds std to what it does.
- `std.Io.Writer.Hashing.init` passes an argument to its hasher's
  `init`, which a CRC hasher's does not take, so it does not compile for
  one; the code calls `initHasher` instead. There is nothing to test: the
  other call would not compile.

Two more are handled in this repository's tests:

- `std.testing.allocator`, a `std.heap.SafeAllocator`, records a stack
  trace for every allocation. On macOS, capturing one locks the debug
  info's mutex with a cancelable lock, and when the lock is contended
  its wait takes the calling task's pending cancel, which the unwinder
  then swallows. A cancel arrives once, so the task's next wait can no
  longer be canceled, and whoever cancels it waits forever: `pubsub`'s
  Subscriber tests hung that way, a different test each run. Every test
  build uses `tools/test_runner.zig`, std's test runner with `std.debug`
  waiting uncancelably; the Subscriber tests are its regression tests.
  This one can reach your program too: on macOS, any allocator that
  records stack traces, as `SafeAllocator` does in a Debug build, can
  lose a task's cancel the same way, a Subscriber's or Publisher's
  among them. Declaring `std_options_debug_io` in your root file, as
  `tools/test_runner.zig` does, prevents it.
- The same allocator grows a block in place only while nothing was
  handed out after it, which depends on what earlier runs did, so the
  same code made a different number of allocations from one run to the
  next, and `std.testing.checkAllAllocationFailures` failed with
  `NondeterministicMemoryUsage`. Every sweep backs onto
  `core.testing.no_grow_allocator`, which refuses to grow a block in
  place, tested in `src/core/testing.zig`.

## Fixed in Zig 0.17

These had workarounds here until the library moved to Zig 0.17, and
their tests now hold std to the fix:

- `std.Io.Condition.wait` dropped a cancel that landed while another
  waiter's signal was pending, and the task could then never be
  canceled; `core.Condition` was std's with that fixed. It is gone, and
  the Subscriber's and Publisher's tests that cancel them under load
  guard std's.
- `std.compress.flate.Decompress` panicked on input that ends partway
  through a code, such as a gzip body cut short; the nightly fuzzing
  found it with 19 bytes. `core.flate.Decompress` was std's with that
  fixed, and is std's own again; `src/core/flate.zig` tests it.
- `zig build test --fuzz` did not compile, and a fuzz test got no
  `std.testing.io`. Zig 0.17's test runner fixes both.
