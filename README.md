# pubsub

A small, synchronous Zig client for the Google Cloud Pub/Sub v1 REST API:
publish, pull, acknowledge, and topic and subscription management.

- Zig **0.16.0** (`minimum_zig_version` enforces it). No dependencies.
- Works against the local emulator with no credentials, and against
  production through a token-provider seam.
- Tested with 139 unit, property and fuzz tests, and 20 integration tests
  that pass against both the emulator and production.

## Install

```
zig fetch --save git+https://github.com/kmoneil/zig-gcp-pubsub#v0.1.0
```

```zig
// build.zig
const pubsub = b.dependency("pubsub", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("pubsub", pubsub.module("pubsub"));
```

## Use

```zig
const std = @import("std");
const pubsub = @import("pubsub");

pub fn main(init: std.process.Init) !void {
    var diag: pubsub.Diagnostics = .{};
    var client = try pubsub.Client.init(init.gpa, init.io, .{
        .project_id = "test",
        // Honors PUBSUB_EMULATOR_HOST; null (production) when it is unset.
        .endpoint = pubsub.Endpoint.fromEnv(init.environ_map),
        .diagnostics = &diag,
    });
    defer client.deinit();

    const orders = client.topic("orders");
    var sent = try orders.publish(&.{
        .{ .data = "hello", .attributes = &.{.{ .key = "origin", .value = "zig" }} },
    }, .{});
    defer sent.deinit();

    const worker = client.subscription("orders-worker");
    var batch = try worker.pull(.{ .max_messages = 10 });
    defer batch.deinit();
    for (batch.value.messages) |m| {
        std.debug.print("{s}: {s}\n", .{ m.message_id, m.data });
        try worker.ack(&.{m.ack_id});
    }
}
```

`Topic` and `Subscription` are cheap handles: a client pointer and a short id
such as `orders`. Creating one sends nothing. The operations:

| `Client` | `Topic` | `Subscription` |
| --- | --- | --- |
| `listTopics`, `listSubscriptions` | `create`, `get`, `delete`, `publish` | `create`, `get`, `delete`, `pull`, `ack`, `modifyAckDeadline`, `nack` |

See `examples/publish.zig` and `examples/worker.zig` for complete programs.

### Production credentials

Production needs a `TokenProvider`. Loading credentials from a metadata
server or key file is the job of a separate auth package; until then, a
static token works for about an hour:

```zig
var token: pubsub.StaticToken = .{ .token = access_token }; // gcloud auth print-access-token
var client = try pubsub.Client.init(gpa, io, .{
    .project_id = "my-project",
    .token_provider = token.provider(),
});
```

Emulator endpoints never receive a token, even when a provider is set, and
any other endpoint must use `https`.

### Results and memory

Every call that returns data returns an `Owned(T)`: the value plus the arena
holding all of its memory. One `deinit` frees it. Copy out anything (an
`ack_id`, say) needed after that. Inputs are borrowed only for the duration
of a call. Handles borrow their client and id, so they must not outlive them.

### Errors and diagnostics

Every call returns `pubsub.Error`, a closed error set: one error per API
status (`error.NotFound`, `error.AlreadyExists`, ...), the transport's errors
(`error.ConnectionRefused`, `error.TlsFailure`, ...), and client-side checks
(`error.InvalidMessage`, `error.InvalidResourceId`). Errors carry no payload;
the details of the last failed call go to `Diagnostics`:

```zig
orders.create(.{}) catch |err| {
    std.debug.print("{t}: HTTP {d} {s}: {s}\n", .{ err, diag.http_status, diag.status(), diag.message() });
};
```

`error.Cancelled` is the server's CANCELLED status. `error.Canceled` means
this task's `std.Io` operation was canceled.

### Retries, time limits and cancellation

Transient failures are retried with full-jitter exponential backoff
(`RetryPolicy`: 5 attempts, 100 ms doubling to at most 10 s). Retried:
RESOURCE_EXHAUSTED, INTERNAL, UNAVAILABLE (and HTTP 502), DEADLINE_EXCEEDED,
connections that were refused, reset or timed out, and failed TLS handshakes
(std reports a connection dropped mid-handshake as a TLS failure). A retried
publish can store messages twice; set `retry_publish = false` to opt out, and
note that such a publish also fails, rather than retries, when the server has
closed an idle connection. Retried creates and deletes can report
`AlreadyExists` or `NotFound` for an attempt that succeeded but whose
response was lost.

`std.http.Client` has no per-request timeout in 0.16, and the library adds
none: bounding a call is up to the caller's `std.Io`. A canceled call returns
`error.Canceled` promptly and the client stays usable. To race a call against
a timer (this exact code runs in the integration tests):

```zig
const Race = union(enum) {
    pulled: pubsub.Error!pubsub.Owned(pubsub.PullResult),
    timed_out: std.Io.Cancelable!void,
};
var buffer: [2]Race = undefined;
var select: std.Io.Select(Race) = .init(io, &buffer);
try select.concurrent(.pulled, pubsub.Subscription.pull, .{ worker, .{} });
try select.concurrent(.timed_out, std.Io.sleep, .{ io, .fromSeconds(5), .awake });
const first = try select.await();
// Cancel the loser. It may have finished first, so free what it returned.
while (select.cancel()) |other| switch (other) {
    .pulled => |result| if (result) |owned| {
        var batch = owned;
        batch.deinit();
    } else |_| {},
    .timed_out => {},
};
```

An empty pull is held open by the server: about 20 seconds in production and
90 on the emulator. `PullOptions.return_immediately` returns at once instead;
Google discourages it in production because it hurts delivery throughput.

### Limits

The client checks these before sending and fails with `error.InvalidMessage`
or `error.InvalidArgument`, with the reason in `Diagnostics`. Values were
measured against production (September 2026); several are stricter or more
precise than the documentation.

| Limit | Value |
| --- | --- |
| Publish request | **10,485,760 bytes of encoded JSON body.** Base64 grows data by a third, so one message holds at most 7,864,299 bytes of raw data over REST. `pubsub.limits.publishRequestBytes` computes the exact size. |
| Messages per publish | 1,000 |
| Attributes per message | 100; keys 1 to 256 bytes and not starting with `goog` in any case; values up to 1,024 bytes |
| Ordering key | 1,024 bytes |
| Ack or modifyAckDeadline request | 524,288 bytes; `ack` splits longer id lists into several requests |
| Ack deadline | 10 to 600 s on a subscription, 0 to 600 s in `modifyAckDeadline` |
| Topic and subscription ids | 3 to 255 characters from `[A-Za-z0-9-_.~+%]`, starting with a letter, not starting with `goog` in any case |

### Logging

The library logs through `std.log.scoped(.pubsub)`: each request at `debug`
(method, path, status, attempt, time) and each retry at `warn`. It never logs
tokens, message data or attribute values. Filter it in your root file:

```zig
pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .pubsub, .level = .warn }},
};
```

### Testing code that uses this library

Implement `pubsub.transport.Transport` (one `send` function) and pass it as
`Client.Options.transport` to answer requests from your tests instead of a
server.

## The emulator is not production

These differences were measured with emulator 0.8.35. The client's own checks
catch the ones marked *checked*, so code tested against the emulator does not
fail later in production.

| Behavior | Emulator | Production |
| --- | --- | --- |
| Publish size limit | none | 10,485,760-byte request body (*checked*) |
| Empty or `goog...` attribute keys | accepted | rejected (*checked*) |
| Ids starting with `GOOG` | accepted | rejected (*checked*) |
| Ordering key over 1,024 bytes | accepted | rejected (*checked*) |
| Mixed ordering keys in one publish | accepted | FAILED_PRECONDITION (the API takes one key per call) |
| Empty pull hold | about 90 s | about 20 s |
| A literal `%25` in an id | decoded twice | decoded once |

## Zig 0.16 standard library issues handled here

The HTTP transport works around these, each covered by a regression test in
`src/transport.zig`:

- A chunk size near 2^64 panics `std.http`'s chunked decoder (integer
  overflow), so the transport decodes chunked bodies itself.
- A body that ends before its `Content-Length` is reported as complete; the
  transport checks, and reports a dropped connection.
- The gzip decoder stops before the last chunk, which kept connections from
  being reused and made complete bodies look truncated.
- `[::1]` is looked up as a host name, so `PUBSUB_EMULATOR_HOST=[::1]:8085`
  failed.
- The TLS certificate clock is read once per client; the transport reloads it
  hourly and after a TLS failure.
- `zig build test --fuzz` does not compile; see `-Dfuzz-runner` below.

## Development

```
zig build test                         # unit, property and fuzz-corpus tests
zig build test --seed 0x1234           # same, with different pseudo-random inputs
zig build test -Dfuzz-runner --fuzz    # coverage-guided fuzzing (see below)
zig build test-integration             # needs a server, see below
zig build example-publish -- orders 5
zig build example-worker -- orders orders-worker
zig build fmt                          # zig fmt --check
```

Every fuzz property also runs in `zig build test`: on its seed corpus and on a
few hundred pseudo-random inputs. When the fuzzer finds a failing input, add
it to that property's corpus so it stays covered. Zig 0.16.0's own test
runner does not compile in fuzz mode, and its default x86_64 backend emits
no coverage instrumentation. `-Dfuzz-runner` fixes both: it swaps in
`tools/test_runner.zig`, a copy with a one-line fix, and builds the tests
with LLVM. The fuzzer keeps its
corpus in `.zig-cache/f`, so only one fuzzing run per checkout at a time;
`-Dtest-filter=fuzz` skips the unit tests that are not fuzz targets.

Integration tests skip unless a server is configured:

```
gcloud beta emulators pubsub start --project=test --host-port=127.0.0.1:8085
PUBSUB_EMULATOR_HOST=127.0.0.1:8085 zig build test-integration

# Or a real project. Every test creates zigps-* resources and deletes them.
PUBSUB_TEST_PROJECT=my-project PUBSUB_TEST_TOKEN=$(gcloud auth print-access-token) \
    zig build test-integration
```

The emulator binds to IPv6 localhost unless given `--host-port`.

## License

MIT
