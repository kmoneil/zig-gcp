# zig-gcp

Google Cloud clients for Zig, written against the REST APIs. The package is
`gcp`, with one module per service, and an application compiles only the
modules it imports.

| Module | Covers | Stability |
| --- | --- | --- |
| `pubsub` | Pub/Sub v1: publish, pull, acknowledge, and topic and subscription management | beta |
| `auth` | Credentials for the service modules: `findDefault` picks between the metadata server on Google Cloud, the login `gcloud auth application-default login` saves, and a file the environment names. | experimental |
| `core` | What the service modules share: the HTTP transport, retries, `Diagnostics`, the `TokenProvider` seam, and test fakes. Services re-export what their callers need. | beta |

- Zig **0.16.0** (`minimum_zig_version` enforces it). No dependencies.
- Tested with 282 unit, property and fuzz tests; 20 Pub/Sub integration
  tests that pass against both the emulator and production; 3 auth tests
  against Google's token endpoint; and a run on a Compute Engine VM, where
  the metadata server is the one that answers.
- Until 1.0, a minor release may break any module. `CHANGELOG.md` says how.

## Install

```
zig fetch --save git+https://github.com/kmoneil/zig-gcp#v0.5.0
```

```zig
// build.zig
const gcp = b.dependency("gcp", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("pubsub", gcp.module("pubsub"));
exe.root_module.addImport("auth", gcp.module("auth")); // for credentials
```

## Pub/Sub

A small, synchronous client for the Pub/Sub v1 REST API. It works against
the local emulator with no credentials, and against production through a
token-provider seam.

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

See `examples/publish.zig` and `examples/worker.zig` for complete programs,
and `examples/whoami.zig` for one that finds its own credentials.

### Production credentials

Production needs a `TokenProvider`. `auth.findDefault` picks one the way
Google's own libraries do, so the same binary runs on a laptop and on Cloud
Run without a flag:

```zig
var arena: std.heap.ArenaAllocator = .init(gpa);
defer arena.deinit();
const lookup = try auth.Lookup.fromEnv(init.environ_map, arena.allocator());
var creds = try auth.findDefault(gpa, io, lookup, .{});
defer creds.deinit();
std.log.info("credentials from {t}", .{creds.source});

var client = try pubsub.Client.init(gpa, io, .{
    .project_id = "my-project",
    .token_provider = creds.provider(),
});
```

`creds.provider()` also carries the project to charge for quota, which
user credentials name: the client sends it as `x-goog-user-project`, and
`send_quota_project` turns that off. When a call comes back 401, the client
drops the cached token, fetches another and tries once more.
`creds.projectId(io, arena)` says which project the program runs in, when
the credentials know: the metadata server does, and a service account key
file names the project it belongs to; a user login does not. On Google
Cloud that means a program needs no configuration at all.

It looks in three places, in this order:

1. The credentials file `GOOGLE_APPLICATION_CREDENTIALS` names: a user
   login (`authorized_user`) or a service account key (`service_account`).
2. The file `gcloud auth application-default login` writes, under
   `$HOME/.config/gcloud` or `%APPDATA%\gcloud`.
3. The metadata server, on Cloud Run, GKE, GCE or Cloud Functions, which
   hands out tokens for the workload's service account with nothing stored
   on disk.

The first place that has something decides it. A credential that is there
but unusable is an error, never a reason to try the next place: running as
somebody else, quietly, would be worse. With nothing anywhere, the error is
`NoCredentialsFound` and `Diagnostics` lists what was tried.

To choose a source yourself, use `auth.AuthorizedUser.initFromFile` for a
user login, `auth.ServiceAccount.initFromFile` for a key file, or
`auth.MetadataServer` on Google Cloud, whose `probe` answers whether there
is a metadata server to ask (in half a second on a machine that has none)
and whose `projectId` says which project it runs in. None of them may move
while a client uses its provider; the `Credentials` that `findDefault`
returns may, because it keeps the provider on the heap.

A `ServiceAccount` signs a short-lived JWT with the key file's RSA key
(RS256, via `std.crypto`, checked against the key's own public half before
anything is sent) and trades it at the token endpoint. Its tokens are
minted for particular scopes, so the first `getToken` fixes them; use a
second provider for a second scope set.

A static token also works, for about an hour:

```zig
var token: pubsub.StaticToken = .{ .token = access_token }; // gcloud auth print-access-token
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
(`error.ConnectionRefused`, `error.TlsFailure`, ...), the token provider's
(`error.RefreshTokenInvalid`, `error.TokenUnavailable`, ...), and client-side
checks (`error.InvalidMessage`, `error.InvalidResourceId`). Errors carry no
payload; the details of the last failed call go to `Diagnostics`:

```zig
orders.create(.{}) catch |err| {
    std.debug.print("{t}: HTTP {d} {s}: {s}\n", .{ err, diag.http_status, diag.status(), diag.message() });
};
```

`error.ServerCancelled` is the server's CANCELLED status. `error.Canceled`
means this task's `std.Io` operation was canceled.

### Retries, time limits and cancellation

Transient failures are retried with full-jitter exponential backoff
(`RetryPolicy`: 5 attempts, 100 ms doubling to at most 10 s). Retried:
RESOURCE_EXHAUSTED, INTERNAL, UNAVAILABLE (and HTTP 502), DEADLINE_EXCEEDED,
connections that were refused, reset or timed out, and failed TLS handshakes
(std reports a connection dropped mid-handshake as a TLS failure). A retried
publish can store messages twice; set `Client.Options.retry_publish = false`
to opt out, and note that such a publish also fails, rather than retries, when
the server has closed an idle connection. Retried creates and deletes can report
`AlreadyExists` or `NotFound` for an attempt that succeeded but whose
response was lost.

`std.http.Client` has no per-request timeout in 0.16, so the library adds
one: every request is raced against a timer, and one that outlives
`Client.Options.request_timeout_ms` (3 minutes by default) is
`error.TimedOut` and is retried like any other transient failure. The
default is generous because an empty pull is held open by the server; lower
it for calls that should fail fast, or set 0 to remove the limit. A request
that times out takes its connection with it, and the client stays usable.
Where the runtime offers no second thread, there is no timer to race, and
the request runs unbounded as before.

That bounds one request, not a whole call: five attempts with backoff can
still take longer. A canceled call returns `error.Canceled` promptly, so to
bound everything, race the call itself against a timer (this exact code runs
in the integration tests):

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

The library logs through `std.log.scoped(.gcp_pubsub)`: each request at
`debug` (method, path, status, attempt, time) and each retry at `warn`. It
never logs tokens, message data or attribute values. Filter it in your root
file:

```zig
pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .gcp_pubsub, .level = .warn }},
};
```

### Testing code that uses this library

Implement `pubsub.transport.Transport` (one `send` function) and pass it as
`Client.Options.transport` to answer requests from your tests instead of a
server. The `core` module has ready-made fakes: `core.testing.FakeTransport`
answers from a script and records every request, and
`core.testing.FakeTokenProvider` stands in for credentials. Add
`gcp.module("core")` to your test build to use them.

### The emulator is not production

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
`src/core/transport.zig`:

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
- On Windows, std maps neither `0xC0000236` (connection refused) nor
  `0xC000013B` (the peer hung up), so both arrive as `error.Unexpected`.
  The transport reads that as a dropped connection and retries, which is
  right for those two and is also what any other unmapped Windows error
  gets: a retry it may not deserve. On other platforms `error.Unexpected`
  stays a permanent `NetworkFailure`.
- `zig build test --fuzz` does not compile; see `-Dfuzz-runner` below.

## Development

```
zig build test                         # unit, property and fuzz-corpus tests
zig build test --seed 0x1234           # same, with different pseudo-random inputs
zig build test -Doptimize=ReleaseFast  # same, optimized; also ReleaseSafe
zig build test -Dfuzz-runner --fuzz    # coverage-guided fuzzing (see below)
zig build test-integration             # needs a server, see below
zig build coverage                     # line coverage; needs kcov (see below)
zig build example-publish -- orders 5
zig build example-worker -- orders orders-worker
zig build example-whoami               # which credentials, and the topics they see
zig build fmt                          # zig fmt --check
```

Every fuzz property also runs in `zig build test`: on its seed corpus and on a
few hundred pseudo-random inputs. Zig 0.16.0's own test runner does not
compile in fuzz mode, and its default x86_64 backend emits no coverage
instrumentation. `-Dfuzz-runner` fixes both: it swaps in
`tools/test_runner.zig`, a copy with a one-line fix, and builds the tests
with LLVM. The fuzzer keeps its corpus in `.zig-cache/f`, so only one
fuzzing run per checkout at a time; `-Dtest-filter=fuzz` skips the unit
tests that are not fuzz targets. When it finds a failing input, it saves it
to `.zig-cache/f/crash`: a 4-byte little-endian length, then the input. Add
the input to that property's corpus, so the fix stays covered.

`zig build coverage` runs the unit tests under
[kcov](https://github.com/SimonKagstrom/kcov) and writes the report to
`zig-out/coverage/index.html`. `tools/coverage_summary.py` prints it as
Markdown, including every line no test reached. kcov counts lines, not
branches, and sees only code the compiler kept.

CI runs the unit tests on Linux, macOS and Windows, and on Linux also in
ReleaseSafe and ReleaseFast; the integration tests and examples against the
emulator; and coverage, whose summary and report are attached to each run. Every night it
also fuzzes, starting from the corpus that earlier nights built up. A failing
input is attached to the run as `fuzz-failure`.

Integration tests skip unless a server is configured:

```
gcloud beta emulators pubsub start --project=test --host-port=127.0.0.1:8085
PUBSUB_EMULATOR_HOST=127.0.0.1:8085 zig build test-integration

# Or a real project. Every test creates zigps-* resources and deletes them.
PUBSUB_TEST_PROJECT=my-project PUBSUB_TEST_TOKEN=$(gcloud auth print-access-token) \
    zig build test-integration

# auth against Google's token endpoint, with the file gcloud's login wrote,
# and a read-only Pub/Sub call with the token it gets.
AUTH_TEST_CREDENTIALS=$HOME/.config/gcloud/application_default_credentials.json \
    PUBSUB_TEST_PROJECT=my-project zig build test-integration
```

The emulator binds to IPv6 localhost unless given `--host-port`.

## License

MIT
