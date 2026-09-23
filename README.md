# zig-gcp

Google Cloud clients for Zig, written against the REST APIs. The package is
`gcp`, with one module per service, and an application compiles only the
modules it imports.

| Module | Covers | Stability |
| --- | --- | --- |
| `pubsub` | Pub/Sub v1: publish, one call at a time or batched from many tasks, pull, a worker loop, acknowledge, and topic and subscription management | beta |
| `secret_manager` | Secret Manager v1: read a secret's bytes, add versions, and manage secrets and their versions, global or regional | experimental |
| `storage` | Cloud Storage JSON API: buckets, object metadata and listings, uploads from memory or any reader and downloads into any writer, streamed in constant memory, resumed after failures and checksummed both ways, preconditions, server-side copies, and signed URLs | experimental |
| `auth` | Credentials for the service modules: `findDefault` picks between the metadata server on Google Cloud, the login `gcloud auth application-default login` saves (impersonating a service account or not), and a file the environment names. They sign signed URLs too, on this machine or through IAM. | experimental |
| `core` | What the service modules share: the HTTP transport, retries, `Diagnostics`, the `TokenProvider` and `Signer` seams, and test fakes. Services re-export what their callers need. | beta |

- Zig **0.16.0** (`minimum_zig_version` enforces it). No dependencies.
- Tested with 749 unit, property and fuzz tests, Google's 29 V4 signing
  vectors among them; 28 Pub/Sub integration tests that pass against both
  the emulator and production, and 20 more through a proxy that drops,
  cuts and stalls the connection; 18 Cloud Storage tests against
  fake-gcs-server and 9 against a real bucket, where uploads and
  downloads cut off mid-body resume against Google itself; 12 Secret
  Manager tests against a real project, since it has no emulator; 10 auth
  tests against Google's token, STS and IAM Credentials endpoints; and a
  run on a Compute Engine VM, where the metadata server is the one that
  answers.
- Until 1.0, a minor release may break any module. `CHANGELOG.md` says how.

## Install

```
zig fetch --save git+https://github.com/kmoneil/zig-gcp#v0.15.0
```

```zig
// build.zig
const gcp = b.dependency("gcp", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("pubsub", gcp.module("pubsub"));
exe.root_module.addImport("auth", gcp.module("auth")); // for credentials
exe.root_module.addImport("secret_manager", gcp.module("secret_manager"));
exe.root_module.addImport("storage", gcp.module("storage"));
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

See `examples/publish.zig`, `examples/publisher.zig` and `examples/worker.zig`
for complete programs, and `examples/whoami.zig` for one that finds its own
credentials.

### A worker loop

Consuming a subscription for real means more than `pull` and `ack`: leases
must be extended while a handler runs, failures released for redelivery,
work bounded, and shutdown clean. `Subscriber` is that loop:

```zig
const Printer = struct {
    fn handler(self: *Printer) pubsub.Subscriber.Handler {
        return .{ .ptr = self, .vtable = &.{ .handle = handle } };
    }
    fn handle(ptr: *anyopaque, io: std.Io, message: pubsub.ReceivedMessage) anyerror!void {
        std.debug.print("{s}\n", .{message.data}); // return acks; an error releases
        _ = .{ ptr, io };
    }
};

var subscriber = try pubsub.Subscriber.init(gpa, io, .{
    .subscription_id = "orders-worker",
    .client = .{ .project_id = "my-project", .token_provider = creds.provider() },
    .concurrency = 4,
});
defer subscriber.deinit();
try subscriber.run(printer.handler()); // until subscriber.stop(), or a fatal error
```

`run` blocks and runs everything else on tasks of its own: one puller, one
janitor that batches acknowledgements, releases and lease extensions, and
`concurrency` handler tasks. A handler returning acknowledges its message;
an error releases it for redelivery, so delivery is at least once and a
handler must tolerate a duplicate. Leases are extended for as long as a
handler runs, up to `max_extension_s`, after which the handler is presumed
dead and the server redelivers elsewhere. `max_outstanding` bounds how many
unresolved messages are held at once, and pulling pauses at the cap.

Transient failures anywhere are retried forever, further and further
apart; an error retrying cannot fix, such as the subscription being
deleted, stops the loop and comes back from `run` with the diagnostics
filled. `stop` is safe to call from a handler or another task: pulling
stops, running handlers finish and their messages resolve, buffered ones
are released unhandled, and the last acknowledgements are flushed.
`stats()` is a consistent snapshot of the counters at any time.

### Publishing at volume

`Topic.publish` sends one request per call, and a client serves one task at
a time. An application that publishes a message at a time from many tasks
wants `Publisher`: any task hands it messages, it batches them into
requests, and it sends those on tasks of its own.

```zig
var publisher = try pubsub.Publisher.init(gpa, io, .{
    .topic_id = "orders",
    .client = .{ .project_id = "my-project", .token_provider = creds.provider() },
});
defer publisher.deinit();
var running = try io.concurrent(pubsub.Publisher.run, .{&publisher});
defer {
    publisher.stop(); // sends what is left; run returns when all of it has resolved
    running.await(io) catch {};
}

// From any task:
const receipt = try publisher.publish(.{ .data = "hello" }, .{});
defer receipt.release();
const id = try receipt.wait(); // the server's message id, or the error
```

A request with a hundred small messages takes about as long as one with a
single message (27 ms against 26, measured against production), and Google
bills every request as at least 1,000 bytes. From a laptop, the example
publishes 10,000 messages from 8 tasks in 102 requests and about a second.
A batch goes out when one of `concurrency` connections (4) is free and the
batch is full, at `max_batch_messages` (100) or `max_batch_bytes` of request
body as sent (1,000,000), or its first message has waited
`max_batch_delay_ms` (10); until a connection takes it, it keeps filling.
Release every receipt, whether or not anyone waits on it. A failure no one
waits for still counts in `stats()` and is logged.

What a publisher holds is capped at 1,000 messages and 10,000,000 bytes by
default (`max_outstanding`, `max_outstanding_bytes`), counting everything
accepted and not yet resolved. At a cap `publish` waits for room, or with
`when_full = .fail` returns `error.PublisherFull` at once, for a server that
would rather shed load. Each cap must hold a full batch, so raising
`max_batch_bytes` toward the 10,485,760-byte limit means raising
`max_outstanding_bytes` with it.

Transient failures are retried, with the statuses Google's own clients
retry for publishing, until `publish_timeout_ms` (60 s) after the message
was published. Each attempt is also bounded by the client's
`request_timeout_ms`, whose 3-minute default is sized for held pulls; a
publisher is better served by about 30 seconds. As with `Topic.publish`, a
retry after a lost response can store a message twice, with a new message
id. `flush` sends everything at once and waits for what was published
before it. `stop` sends what is left; canceling `run` gives up on it, and
those receipts report `error.PublisherStopped`.

Ordering keys need `enable_message_ordering`. Messages with the same key
reach an ordered subscription in publish order: no request mixes keys, and
a key has one request in flight at a time. When one of a key's batches
fails for good, the key pauses: the messages queued behind it fail with
`error.OrderingKeyPaused` without being sent, and `publish` refuses the key
until `resumePublish(key)`, so a message is never stored ahead of one that
failed. Google requires every message of a key to be published in one
region. A publisher outside Google Cloud, or spread across regions, should
use a locational endpoint, such as
`.endpoint = .{ .url = "https://us-east1-pubsub.googleapis.com" }`.

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
   login (`authorized_user`), a service account key (`service_account`),
   workload identity federation (`external_account`), or a login that acts
   as a service account (`impersonated_service_account`).
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
user login, `auth.ServiceAccount.initFromFile` for a key file,
`auth.ExternalAccount.initFromFile` for federation,
`auth.ImpersonatedServiceAccount.initFromFile` for impersonation, or
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

An `ExternalAccount` is workload identity federation: no stored Google key
at all. Each fetch reads the third-party subject token from the file's
credential source (a file, as GitHub Actions and Kubernetes write, or a
URL, as Azure's metadata service answers), trades it at Google's STS, and,
when the file names a service account to impersonate, trades once more at
the IAM Credentials API. Subject tokens rotate, so each fetch reads anew.
AWS credential sources (which need request signing) and executable sources
(which run a subprocess) are refused by name. Scopes fix on first use, as
for a service account.

An `ImpersonatedServiceAccount` is a login that acts as a service account,
which Google recommends over key files for running locally as one: nothing
of the service account is stored, only the right to act as it. It is the
file this writes, which `findDefault` then picks up like any other:

```
gcloud auth application-default login --impersonate-service-account=SA_EMAIL
```

Each fetch takes a token from the file's source credentials (a user login,
or a service account key) and trades it at the IAM Credentials API for one
that is the service account's. The source keeps its own cached token, so
most fetches cost one request. Only the account's email is read from the
file's URL: the request always goes to Google's endpoint, as Google's own
libraries do, so a crafted file cannot send your token anywhere else. The
login needs `roles/iam.serviceAccountTokenCreator` on the service account,
and a refusal says so. Scopes fix on first use, as for a service account.

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
(std reports a connection dropped mid-handshake as a TLS failure). A publish
is also retried on ABORTED, CANCELLED, and UNKNOWN answered with a 5xx, as
Google's own clients retry it. A retried publish can store messages twice; set `Client.Options.retry_publish = false`
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

## Secret Manager

A client for the Secret Manager v1 REST API. The call most applications
want is `access`: it fetches the bytes of a secret version, verifies the
CRC-32C stored beside them, and hands them over in memory that is wiped
when it is released.

```zig
const std = @import("std");
const auth = @import("auth");
const secret_manager = @import("secret_manager");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    var creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    defer creds.deinit();

    // There is no emulator and no unauthenticated mode: credentials are
    // a required option, not an optional one.
    var secrets = try secret_manager.Client.init(init.gpa, init.io, .{
        .project_id = "my-project",
        .token_provider = creds.provider(),
    });
    defer secrets.deinit();

    var password = try secrets.secret("db-password").access(.latest);
    defer password.deinit(); // wipes the bytes
    std.log.info("using {s}", .{password.version_name});

    try db.connect(.{ .user = "app", .password = password.bytes() });
}
```

Read secrets at startup, or on a timer, rather than on every request:
access calls are quota-limited and billed per call. The library never keeps
a secret after the call returns, so caching is the application's to decide.

`examples/secret.zig` is the whole of the above as a program:
`zig build example-secret -- db-password latest`.

### The bytes

`access` returns a `SecretValue`, not an `Owned(T)`, because the result
needs more care than other results do.

- Everything the call touched lives in one arena over
  `core.WipingAllocator`: the response body, which carries the secret in
  base64, the JSON parser's scratch space, the decoded bytes, and the
  bearer token the request was made with. `deinit` zeroes all of it.
- `value.bytes()` reads the secret. There is no `data` field on purpose:
  `{}` and `{any}` print a struct's fields whatever its `format` method
  says, so the bytes are held as a pointer and a length. Printing a
  `SecretValue` any way at all gives `[REDACTED]`.
- Nothing about a secret is logged: not the bytes, not their length, not
  their checksum. Sizes and timings are logged for other things; here the
  length of a password is information too.
- The bytes are never altered. A secret written with `echo` ends in a
  newline, and it is still there; trim it with `std.mem.trimRight` if you
  want it gone.
- Pass a `SecretValue` by pointer. A copy that is also `deinit`ed frees the
  same memory twice.

Wiping is not a guarantee against swap, a core dump or a debugger, and the
HTTP and TLS layers have buffers of their own that this library cannot
reach. It narrows the window in which a later bug can find the secret.

### What it covers

| Call | What it does |
| --- | --- |
| `client.secret(id).access(ref)` | The bytes of a version: `.latest`, `.{ .number = 3 }` or `.{ .alias = "prod" }` |
| `.addVersion(bytes)` | Stores a new version, with a CRC-32C the server checks |
| `.create(config)`, `.get()`, `.delete()` | The secret itself: replication and labels, then metadata, then gone |
| `client.listSecrets(options)` | One page of secrets, with `filter`, `page_size` and `page_token` |
| `.listVersions(options)` | One page of versions, newest first |
| `.version(ref).get()` | A version's state, times and etag |
| `.version(.{ .number = n }).enable()`, `.disable()`, `.destroy()` | Change what a version serves |

`enable`, `disable` and `destroy` take a version number and refuse
`.latest` and aliases with `error.ExplicitVersionRequired`: "whatever is
latest right now" is the wrong target for a change that lasts. Production
refuses `latest` for those three as well. Enabling and disabling are
idempotent; destroying is not, and a second destroy answers
`error.FailedPrecondition`, which means the first one worked.

Not in this version: `patch` (so no labels, aliases, expiry or rotation
after creation), IAM policy calls, notification topics, customer-managed
encryption keys, and etag preconditions.

### Checksums

Secret Manager stores a CRC-32C with every version. `addVersion` always
computes one over the raw bytes and sends it, so a payload that arrives
changed is refused with `INVALID_ARGUMENT` rather than stored. On the way
back, `Options.verify_checksum` decides:

| Mode | The server sent a checksum | It sent none |
| --- | --- | --- |
| `.required` | Verified; a mismatch is an error | `error.MissingChecksum` |
| `.if_present` (default) | Verified; a mismatch is an error | The bytes, with `checksum_verified = false` |
| `.off` | Ignored | The bytes, with `checksum_verified = false` |

A mismatch means the bytes changed between Google's storage and this
process. Since access is idempotent, the client wipes them and asks again
under the retry policy; if the last attempt still mismatches, it returns
`error.ChecksumMismatch` and the bytes are never handed over.

### Regional secrets

`Options.location` decides both the host and the resource names, so a
client is global or regional for its whole life:

```zig
var eu = try secret_manager.Client.init(gpa, io, .{
    .project_id = "my-project",
    .location = "europe-west3", // secretmanager.europe-west3.rep.googleapis.com
    .token_provider = creds.provider(),
});
```

The two are separate namespaces: a global client asking for a regional
secret gets `NotFound`, and the reverse. An application that needs both
makes two clients. A regional secret sends no `replication`, because its
location decides where the bytes live; a global one must name it, and it
cannot be changed afterwards. `location` is checked against a strict
pattern before it becomes part of a host name.

## Cloud Storage

A client for the Cloud Storage JSON API. Objects of any size stream both
ways in constant memory, pick up where they stopped after a dropped
connection, and are checked against the CRC-32C Cloud Storage keeps for
every object.

```zig
const std = @import("std");
const auth = @import("auth");
const storage = @import("storage");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    var creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    defer creds.deinit();

    var gcs = try storage.Client.init(init.gpa, init.io, .{
        .token_provider = creds.provider(),
    });
    defer gcs.deinit();
    const report = gcs.bucket("my-bucket").object("reports/2026/q3.txt");

    // Bytes in memory go up in one request whose metadata carries their
    // CRC-32C, so a body changed on the way is refused, never stored.
    var info = try report.upload("hello world\n", .{
        .content_type = "text/plain",
        .preconditions = .does_not_exist, // create-only, and safe to retry
    });
    defer info.deinit();

    // And come back verified, up to a cap.
    var copy = try report.downloadAlloc(1024 * 1024, .{});
    defer copy.deinit();
    std.log.info("generation {d}: {s}", .{ copy.value.result.generation, copy.value.data });
}
```

Against the `fake-gcs-server` emulator, pass
`.endpoint = storage.Endpoint.fromEnv(init.environ_map)`, which honors
`STORAGE_EMULATOR_HOST`, and no credentials: the emulator speaks plain
HTTP and never receives a token.

### Files of any size

`uploadFrom` reads from any `std.Io.Reader`, and `download` writes into any
`std.Io.Writer`:

```zig
const file = try std.Io.Dir.cwd().openFile(io, "backup.tar", .{});
defer file.close(io);
var buffer: [64 * 1024]u8 = undefined;
var reader = file.reader(io, &buffer);
const size = (try file.stat(io)).size;
var uploaded = try bucket.object("backups/backup.tar").uploadFrom(&reader.interface, .{ .size = size });
defer uploaded.deinit();
```

- An upload goes through the resumable protocol in `chunk_size` pieces,
  8 MiB by default and always a multiple of 256 KiB. One chunk stays in
  memory until the server confirms it, so a resume never needs the reader
  to go backwards; after a failure the client asks the server how much it
  kept and carries on from there. `upload` does the same above
  `single_request_limit` (8 MiB), slicing chunks from the caller's memory
  instead of copying them. When the session itself is lost, `upload`
  starts over from its bytes; `uploadFrom` cannot, since the reader has
  moved on, so it returns `error.UploadSessionLost` for the caller to
  reopen the source and try again.
- A download writes into the caller's writer as the bytes arrive, and
  never flushes it: the buffer is the caller's. A connection that drops
  mid-body resumes at the byte it stopped at, pinned to the generation the
  first response named, so an overwrite in between is `error.NotFound`
  rather than a file spliced from two objects. `range` reads part of an
  object.
- `examples/gcs_cp.zig` copies a file up or down, as
  `zig build example-gcs_cp -- backup.tar gs://my-bucket/backups/backup.tar`
  and back. Copying a 1 GiB file each way with it, the process peaked at
  15 MiB resident going up and 5.5 MiB coming down.

### Checksums

Every object has a CRC-32C, and it is checked in both directions:

| Call | Checked by | On a mismatch |
| --- | --- | --- |
| `upload` | The server, against the checksum the request carries | `error.InvalidArgument` (HTTP 400); nothing is stored |
| `uploadFrom` with `options.crc32c` | The server, once the last chunk is in | The same |
| `uploadFrom` without it | The client, which hashes the stream and compares it with the finished object | `error.ChecksumMismatch`; the object is deleted again, pinned to its generation |
| `download`, `downloadAlloc` | The client, which hashes the bytes as they pass | `error.ChecksumMismatch`; the writer holds bytes to discard |

`checksum_verified = false` means there was nothing to check against: a
`range` read, whose bytes are only part of what the checksum covers, or an
object stored gzip-compressed, which Cloud Storage decompresses for a
client that did not ask for gzip, so the bytes that arrive are not the
ones the checksum covers. A resumed download is still verified: Cloud
Storage names no checksum on a partial range, so the client holds it to
the one its first response named. `Options.verify_checksums = false` turns
all of this off.

### Preconditions and retries

`Preconditions` compare against an object's generation, which changes with
every overwrite, or its metageneration, which changes with every metadata
update, on gets, downloads, deletes, uploads and copies.
`.does_not_exist` makes an upload create-only.

Retries follow what is safe to repeat. Reads always retry, and resumable
chunks always resume from what the server confirmed. A write is retried
only when repeating it cannot do harm: an upload or copy carrying
`if_generation_match`, or a delete naming a `generation`, whose repeat
fails cleanly if the first attempt landed, instead of overwriting or
deleting whatever is there by then. `Options.retry_unconditional_writes`
opts every write in. A 412 on a write that may have been retried says so
in `Diagnostics`: the first attempt may have succeeded, so `get` the object
and compare checksums. An `if_generation_not_match` or
`if_metageneration_not_match` met by the current object is
`error.NotModified`, an answer rather than a failure.

### Signed URLs

A signed URL lets someone with no credentials make one request on one
object until it expires: a browser downloading a private file, or
uploading straight into a bucket without the bytes passing through the
application.

```zig
var creds = try auth.findDefault(gpa, io, lookup, .{});
defer creds.deinit();
const signer = creds.signer() orelse return error.CannotSign;

var url = try gcs.bucket("photos").object("cats/tom.jpg").signedUrl(signer, .{
    .expires_in_s = 15 * 60,
    .query = &.{.{ .name = "response-content-disposition", .value = "attachment; filename=\"tom.jpg\"" }},
});
defer url.deinit();
```

An upload URL can pin what the holder may send:

```zig
var put = try object.signedUrl(signer, .{
    .method = .PUT,
    .expires_in_s = 10 * 60,
    .headers = &.{
        .{ .name = "content-type", .value = "image/png" },
        .{ .name = "x-goog-content-length-range", .value = "0,5242880" },
        .{ .name = "x-goog-if-generation-match", .value = "0" },
    },
});
```

The holder must send every signed header with the same value, and cannot
add a query parameter of their own: Cloud Storage refuses the request
otherwise. They must also send no `Authorization` header, even an empty
one, which would turn the request into an ordinary authenticated one.

Who can sign, as `Credentials.signer()` decides:

| Credentials | Signs | What it needs |
| --- | --- | --- |
| A service account key file | on this machine | nothing else |
| A login impersonating a service account | through IAM, as the target | the Token Creator role impersonation already needs |
| A workload on Google Cloud | through IAM, as its attached account | Token Creator on itself, and the `cloud-platform` access scope |
| A user's own login, or workload identity federation | nothing: `signer()` is null | name an account through `auth.IamSigner` |

Google rotates the key IAM signs with and promises each for 12 hours, so
a URL signed through IAM may last no longer, and `signedUrl` refuses a
longer one before asking IAM. A key file's URL may last the seven days
Cloud Storage allows.

The URL points at the client's endpoint, so a client on the emulator
makes emulator URLs. `.style` chooses `.path` (the default),
`.virtual_hosted` for `bucket.storage.googleapis.com`, or a
`.bucket_bound` domain that serves one bucket.

Treat the URL as a password: it is a bearer credential until it expires.
The library never logs it or puts it in `Diagnostics`, and wipes the
memory its signature passed through. `examples/gcs_sign.zig` prints one,
with the `curl` line that uses it:

```
zig build example-gcs_sign -- gs://my-bucket/reports/q3.txt
```

What Cloud Storage answers, measured against a real bucket on 2026-09-22:

| The request | The answer |
| --- | --- |
| A URL past its expiry | 400 `ExpiredToken` |
| A URL dated more than 15 minutes ahead | 403 `AccessDenied` |
| A changed signature, header or parameter | 403 `SignatureDoesNotMatch`, carrying the canonical request Google computed |
| A signed DELETE | 204 |
| A signed POST with `x-goog-resumable: start` | 201, and a session URI that takes the bytes with no signature |
| A body that does not match a signed `x-goog-content-sha256` | stored: the header is signed, but the body is not hashed against it |

### POST policies: uploads from a plain HTML form

A signed URL allows one request. A POST policy allows one kind of
request, which is what a browser form needs: a form cannot send the
headers a signed PUT pins, and the person at the browser picks the file,
so its name is not known when the policy is signed.

```zig
var policy = try gcs.bucket("photos").postPolicy(signer, .{
    .expires_in_s = 15 * 60,
    // Any name under the prefix: the browser chooses the rest.
    .key = .{ .starts_with = "avatars/" },
    .fields = &.{.{ .name = "content-type", .value = "image/png" }},
    .conditions = &.{.{ .content_length_range = .{ .min = 1, .max = 5 << 20 } }},
});
defer policy.deinit();
```

`policy.value.url` is where the form posts, and `policy.value.fields` are
its hidden inputs. Write them into a `<form method="post"
enctype="multipart/form-data">` and add `<input type="file" name="file">`
last: Cloud Storage reads the fields before the bytes. With a prefix key
the `key` field ends in Google's `${filename}`, which Cloud Storage
replaces with the name of the file the browser sent.

`Object.postPolicy` names one object exactly instead, and takes no `key`.

A policy is a whitelist. Every field the form sends must be in it, with
the value it states, or as a `.starts_with` condition for one the browser
chooses. `content_length_range` bounds the body, which is the one
condition a signed URL cannot express for a form. Signing is the same as
for a URL, so the table above applies unchanged: a key file signs here,
IAM signs for the rest, and the 12-hour limit is the same.

The fields are a bearer credential together, so the library never logs
the document or the signature. `examples/gcs_sign.zig` prints a ready
form; end the target with `/` to allow a prefix:

```
zig build example-gcs_sign -- gs://my-bucket/uploads/ --post-policy --put image/png
```

What Cloud Storage answers, measured against a real bucket on 2026-09-23:

| The form | The answer |
| --- | --- |
| Everything the policy allows | 204, or `success_action_status`'s 200 or 201, whose body names the bucket, key, location and etag |
| With `success_action_redirect` | 303 to that URL, with what was stored in its query |
| A field whose value contradicts its condition | 400 `InvalidPolicyDocument`, whose `Details` quotes the condition that failed |
| A field the policy never mentions | 400 `InvalidPolicyDocument` |
| A key outside a `starts_with` prefix | 400 `InvalidPolicyDocument` |
| A body over or under `content_length_range` | 400 `EntityTooLarge` or `EntityTooSmall` |
| A policy past its expiry | 400 `InvalidPolicyDocument`, where an expired URL is `ExpiredToken` |
| A changed signature | 403 `SignatureDoesNotMatch`, carrying the policy document Google read |

### What it covers

| Call | What it does |
| --- | --- |
| `client.bucket(name).create(config)`, `.get()`, `.delete()` | A bucket, in the project `Options.project_id` names |
| `client.listBuckets(page)` | One page of the project's buckets |
| `bucket.listObjects(options)` | One page of objects, with `prefix`, a `delimiter` for folders, and paging |
| `bucket.object(name).get(options)`, `.exists()`, `.delete(options)` | An object's metadata, whether it exists, and deleting it or one generation of it |
| `.upload(data, options)`, `.uploadFrom(reader, options)` | Bytes in memory, or any reader |
| `.download(writer, options)`, `.downloadAlloc(max_bytes, options)` | Into any writer, or into memory up to a cap |
| `.copyTo(dest, options)` | A server-side copy, across buckets too |
| `.signedUrl(signer, options)`, `bucket.signedUrl(signer, options)` | A V4 signed URL, which lets whoever holds it make one request without credentials until it expires |
| `.postPolicy(signer, options)`, `bucket.postPolicy(signer, options)` | A V4 POST policy, which lets a plain HTML form upload what the policy allows, without credentials, until it expires |

The default OAuth scope is `devstorage.read_write`; `Options.scope` picks
`.read_only` or `.cloud_platform` instead. Not in this version: metadata
updates after upload (`patch`), compose, resumable sessions that outlive
the process, parallel downloads, requester pays, customer-supplied
encryption keys, listing old versions or soft-deleted objects, and gRPC.

### The emulator is not production

The integration suite runs against `fake-gcs-server`, and a second suite
against a real bucket covers what the emulator cannot be trusted on. The
differences it found:

- It serves the XML API's paths, which signed URLs use, only when started
  with `-public-host` naming the host those URLs carry, and it never checks
  a signature. Its signed DELETE answers 200 where Cloud Storage answers
  204, and its resumable start drops the object name from the path.
- The emulator enforces preconditions on uploads, but not on deletes, and
  never answers 304.
- It takes a resumable upload's status query for the final request, and
  finishes a truncated object. The client refuses that answer with
  `error.InvalidResponse` and deletes the object, so an interrupted upload
  can only be tested against Google.
- It checks a declared CRC-32C on multipart uploads, not on resumable
  ones.
- It names the object's checksum on every range read; Cloud Storage names
  it only for a range that spans the whole object.

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
- Streaming a body larger than the connection's read buffer into a writer
  with no buffer of its own trips an assertion in std's readers, which
  need somewhere writable; the transport passes bodies through a small
  buffer of its own.
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
also fuzzes, one job per module, each starting from the corpus that earlier
nights built up for it, and one job for each property too slow to share
one: auth's RSA signing, and pubsub's Publisher and Subscriber models. A
test that fails while being fuzzed fails its job, and the input is
attached to the run as `fuzz-failure-<job>`, such as
`fuzz-failure-pubsub`.

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

# Secret Manager has no emulator, so its tests need a real project. They
# create zigps-* secrets labelled zig-gcp-test and delete them, and sweep
# up anything a crashed run left behind. GCP_TEST_LOCATION adds the
# regional tests.
GCP_TEST_PROJECT=my-project GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
    zig build test-integration-gcp

# Cloud Storage against fake-gcs-server. Every test creates a zigps-*
# bucket and deletes it.
docker run -d -p 4443:4443 fsouza/fake-gcs-server -scheme http -port 4443
STORAGE_EMULATOR_HOST=http://127.0.0.1:4443 zig build test-integration

# And against a real bucket, for what an emulator cannot show: every
# precondition enforced, checksums checked by the server, gzip transcoding,
# and uploads and downloads cut mid-body that resume against Google itself.
# Objects live under zig-gcp-test/ and are deleted. The token needs Storage
# Object Admin on the bucket, which must not have object versioning on. It
# moves about 230 MiB over the wire, 100 MiB of it in one object each way.
GCP_TEST_BUCKET=my-bucket GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
    zig build test-integration-gcp

# Signed URLs and POST policies against a real bucket, the only place a
# signature is ever checked, and the only place Cloud Storage says what it
# makes of a policy's conditions. Name a key file, an account the token may
# sign as through IAM, or both: each test runs once per signer. That
# account needs Storage Object Admin on the bucket, since a URL or a policy
# grants what its signer may do.
GCP_TEST_BUCKET=my-bucket GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
    GCP_TEST_SIGNER_KEY=key.json GCP_TEST_SIGNER_EMAIL=signer@my-project.iam.gserviceaccount.com \
    zig build test-integration-gcp

# The emulator serves the paths signed URLs use only for the host they
# name, so those tests need -public-host, as CI passes it.
docker run -d -p 4443:4443 fsouza/fake-gcs-server -scheme http -port 4443 \
    -public-host 127.0.0.1:4443
```

The emulator binds to IPv6 localhost unless given `--host-port`.

## License

MIT
