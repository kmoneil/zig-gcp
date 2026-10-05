[Docs](README.md) › Essentials

# Essentials

What every module shares: clients and their handles, endpoints and
emulators, what a call returns and who frees it, how failures are
reported and retried, what is logged, and how to test code that uses
this library.

**On this page:** [Clients and handles](#clients-and-handles) ·
[Endpoints and emulators](#endpoints-and-emulators) ·
[Results and memory](#results-and-memory) ·
[Errors and diagnostics](#errors-and-diagnostics) ·
[Retries, time limits and cancellation](#retries-time-limits-and-cancellation) ·
[Logging](#logging) ·
[Testing code that uses this library](#testing-code-that-uses-this-library)

## Clients and handles

Each service module has a `Client`, made with `init(gpa, io, options)`
and freed with `deinit`. Its handles, such as `pubsub.Topic`,
`storage.Object` and `secret_manager.Secret`, are cheap: a client
pointer and a name. Creating one sends nothing. Handles borrow their
client and name, so they must not outlive them.

A client must not be used from two tasks at once, and its built-in
transport is not safe to share: give each task a client of its own.
`storage.Client.sibling` makes one with the same settings, and
`pubsub.Publisher` and `pubsub.Subscriber` run tasks of their own, each
with its own client.

## Endpoints and emulators

Production is the default. Pub/Sub and Cloud Storage have local
emulators, and each of those modules' `Endpoint.fromEnv` reads the
variable Google's own libraries read for one, and returns null, which
means production, when it is unset:

| Module | Variable | Emulator |
| --- | --- | --- |
| `pubsub` | `PUBSUB_EMULATOR_HOST` | `gcloud beta emulators pubsub start` |
| `storage` | `STORAGE_EMULATOR_HOST` | [fake-gcs-server](https://github.com/fsouza/fake-gcs-server) |
| `firestore` | `FIRESTORE_EMULATOR_HOST` | `gcloud emulators firestore start`; see [the emulator](firestore/emulator.md) |

Secret Manager has no emulator, so its client always needs credentials.

Emulator endpoints never receive a token, even when a provider is set,
and any other endpoint must use `https`. The emulators take much that
production refuses. Where they do, the client checks before sending, so
code tested against an emulator does not fail later in production; each
module's guide lists what was measured:
[Pub/Sub](pubsub/README.md#the-emulator-is-not-production) and
[Cloud Storage](storage/emulator.md).

## Results and memory

A call that returns data from the server returns an `Owned(T)`: the
value plus the arena holding all of its memory. One `deinit` frees it.
Copy out anything (an `ack_id`, say) needed after that. Inputs are
borrowed only for the duration of a call.

Three kinds of result are not `Owned(T)`, and their guides say how they
are freed: a download's `storage.DownloadResult`, which reports on bytes
already written into the caller's writer and holds no memory; a
`pubsub.Publisher` receipt, which is released with `release`; and Secret
Manager's `SecretValue`, which [wipes its memory](secret-manager/README.md#the-bytes)
when it is released.

## Errors and diagnostics

Every call returns its module's error set: `pubsub.Error`,
`storage.Error`, `secret_manager.Error` or `firestore.Error`. Each is closed: one error per
API status (`error.NotFound`, `error.AlreadyExists`, ...), the
transport's errors (`error.ConnectionRefused`, `error.TlsFailure`, ...),
the token provider's (`error.RefreshTokenInvalid`,
`error.TokenUnavailable`, ...), and the module's own checks
(`error.InvalidMessage`, `error.InvalidObjectName`, ...). Errors carry
no payload; the details of the last failed call go to `Diagnostics`:

```zig
var diag: pubsub.Diagnostics = .{};
var client = try pubsub.Client.init(gpa, io, .{
    .project_id = "my-project",
    .token_provider = creds.provider(),
    .diagnostics = &diag,
});
defer client.deinit();

client.topic("orders").create(.{}) catch |err| {
    std.debug.print("{t}: HTTP {d} {s}: {s}\n", .{ err, diag.http_status, diag.status(), diag.message() });
};
```

`error.ServerCancelled` is the server's CANCELLED status.
`error.Canceled` means this task's `std.Io` operation was canceled.

Cloud Storage's error bodies carry no canonical status, so there the
HTTP code decides the error, and `Diagnostics.status()` keeps the
server's `reason`, such as `notFound`. A few refusals are told apart by
Cloud Storage's words as well: an object kept by retention or a hold is
`error.ObjectRetained`, and a notification topic Cloud Storage cannot
publish to is `error.TopicNotPublishable`, rather than the
`error.PermissionDenied` or `error.InvalidArgument` their statuses alone
would make them.

## Retries, time limits and cancellation

Transient failures are retried with full-jitter exponential backoff
(`RetryPolicy`: 5 attempts, 100 ms doubling to at most 10 s, set per
client as `Options.retry`). Retried: RESOURCE_EXHAUSTED, INTERNAL,
UNAVAILABLE (and HTTP 502), DEADLINE_EXCEEDED, connections that were
refused, reset or timed out, and failed TLS handshakes (std reports a
connection dropped mid-handshake as a TLS failure). A call refused as
unauthenticated, HTTP 401, gets a fresh token and one more try.

What else is safe to repeat depends on the call, and each module says:

- **Pub/Sub** also retries a publish on ABORTED, CANCELLED, and UNKNOWN
  answered with a 5xx, as Google's own clients do, and a retried publish
  can store a message twice: see [Retries](pubsub/README.md#retries).
- **Cloud Storage** retries a write only when its preconditions or an
  idempotency token make a repeat harmless: see
  [Preconditions and retries](storage/writing-objects.md#preconditions-and-retries).
- **Secret Manager** fetches a secret again when its bytes fail their
  checksum, see [Checksums](secret-manager/README.md#checksums), and retries
  `addVersion`, which can store the same bytes twice, unless
  `Options.retry_add_version` is false.
- **IAM policy writes**, on every resource, are retried only under an
  etag, and a concurrent change is `error.Aborted`: see
  [IAM on every resource](iam.md#errors-and-retries).

`std.http.Client` has no per-request timeout (Zig 0.17), so the library
adds one: every request is raced against a timer, and one that outlives
`Client.Options.request_timeout_ms` is `error.TimedOut` and is retried
like any other transient failure. The default is 3 minutes for Pub/Sub,
since the server holds an empty pull open, and 30 seconds for Cloud
Storage and Secret Manager. Lower it for calls that should fail fast, or
set 0 to remove the limit. A request that times out takes its
connection with it, and the client stays usable. Where the runtime
offers no second thread, there is no timer to race, and the request runs
unbounded.

That bounds one request, not a whole call: five attempts with backoff
can still take longer. A canceled call returns `error.Canceled`
promptly, so to bound everything, race the call itself against a timer
(the integration tests run this pattern):

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

## Logging

Each module logs through `std.log` under a scope of its own:
`.gcp_pubsub`, `.gcp_storage`, `.gcp_secret_manager`, `.gcp_firestore`
and `.gcp_auth`.
Each request goes to `debug` (method, path, status, attempt, time) and
each retry to `warn`. Nothing sensitive is logged: no token, no message
data or attribute value, no secret or even its length, no signed URL or
upload session URL, and no encryption key. Filter it in your root file:

```zig
pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_pubsub, .level = .warn },
        .{ .scope = .gcp_storage, .level = .warn },
    },
};
```

## Testing code that uses this library

Every client takes `Options.transport`. Implement `transport.Transport`
(a `send` function, and `sendStream` for Cloud Storage's streamed
uploads and downloads) to answer requests from your tests instead of a
server. The `core` module has ready-made fakes:
`core.testing.FakeTransport` answers from a script and records every
request, and `core.testing.FakeTokenProvider` stands in for credentials.
Add `gcp.module("core")` to your test build to use them:

<!-- snippet: tests/docs_examples.zig#testing-with-fakes -->
```zig
const std = @import("std");
const core = @import("core");
const pubsub = @import("pubsub");

test "a publish, answered by a fake" {
    var fake: core.testing.FakeTransport = .init(std.testing.allocator, &.{
        .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
    });
    defer fake.deinit();
    var tokens: core.testing.FakeTokenProvider = .{};
    var client = try pubsub.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = tokens.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    var sent = try client.topic("orders").publish(&.{.{ .data = "hello" }}, .{});
    defer sent.deinit();
    try std.testing.expectEqualStrings("1", sent.value.message_ids[0]);

    const request = try fake.request(0);
    try std.testing.expectEqualStrings(
        "https://pubsub.googleapis.com/v1/projects/my-project/topics/orders:publish",
        request.url,
    );
}
```

The emulators make a fuller check, as this library's own integration
suites do: see [Integration tests](development.md#integration-tests).
