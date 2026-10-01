[Docs](README.md) › Zig 0.16 workarounds

# Zig 0.16 standard library issues handled here

Each of these is worked around here, and covered by a regression test in
`src/core/transport.zig` unless it says otherwise:

- A chunk size near 2^64 panics `std.http`'s chunked decoder (integer
  overflow), so the transport decodes chunked bodies itself.
- A body that ends before its `Content-Length` is reported as complete;
  the transport checks, and reports a dropped connection.
- The gzip decoder stops before the last chunk, which kept connections
  from being reused and made complete bodies look truncated.
- `[::1]` is looked up as a host name, so
  `PUBSUB_EMULATOR_HOST=[::1]:8085` failed.
- The TLS certificate clock is read once per client; the transport
  reloads it hourly and after a TLS failure.
- Streaming a body larger than the connection's read buffer into a
  writer with no buffer of its own trips an assertion in std's readers,
  which need somewhere writable; the transport passes bodies through a
  small buffer of its own.
- On Windows, std maps neither `0xC0000236` (connection refused) nor
  `0xC000013B` (the peer hung up), so both arrive as `error.Unexpected`.
  The transport reads that as a dropped connection and retries, which is
  right for those two and is also what any other unmapped Windows error
  gets: a retry it may not deserve. On other platforms
  `error.Unexpected` stays a permanent `NetworkFailure`.
- `zig build test --fuzz` does not compile; see
  [Fuzzing](development.md#fuzzing) for `-Dfuzz-runner`.
- `std.compress.flate.Decompress` reads each gzip member's trailer, its
  CRC-32 and length, and checks neither, so a corrupted member
  decompresses to wrong bytes without complaint. `storage`'s downloads
  check both themselves, in `src/storage/gzip_download.zig`, where a
  test also holds std to what it does.
- The same decompressor panics on input that ends partway through a
  code, such as a gzip body cut short or a truncated object: its
  `tossBitsShort` counts consumed bits as bits still to read. The
  nightly fuzzing found it with 19 bytes. `core.flate.Decompress`
  (`src/core/flate/`) is std's, with that fixed, and both the transport
  and `storage`'s gzip downloads decompress with it.
