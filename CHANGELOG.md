# Changelog

Until 1.0, minor versions may break the API; each entry says how. One
version covers the whole package, and each entry lists every module,
including the ones that did not change.

## 0.5.0 (unreleased)

- core: every request now carries a deadline. `Request.timeout_ms` bounds
  one request, and one that outlives it is the new `error.TimedOut`, which
  the retry policy treats as transient. std.http has no timeout of its own,
  so before this a server that accepted a connection and then said nothing
  stalled the caller until its `std.Io` task was canceled. A timed-out
  request takes its connection with it, and the transport stays usable.
  Where the runtime offers no second thread there is no timer to race, and
  the request runs unbounded as before.
- core: breaking, for exhaustive switches: `transport.Error` gains
  `TimedOut`, so `pubsub.Error` does too.
- pubsub: `Client.Options.request_timeout_ms`, 3 minutes by default,
  because an empty pull is held open by the server. 0 removes the limit.
- auth: `request_timeout_ms` on `AuthorizedUser`, `MetadataServer` and
  `findDefault`: 30 seconds for a token endpoint on the internet, 10 for
  the metadata server on this machine's own network.

## 0.4.0 (2026-09-20)

- core: new module, holding what the service modules share: the HTTP
  transport, which can send JSON or form bodies and carry extra request
  headers, and hands back the response's, `RetryPolicy`, Google API
  errors and `Diagnostics`, `Owned`, the `TokenProvider` seam with
  `StaticToken`, `WipingAllocator` for memory that held a secret, the
  logging helper the modules share, and test helpers in `core.testing`: a
  fake transport, token provider and clock, a scripted HTTP server, and an
  allocator that checks memory was wiped. pubsub re-exports what its callers
  use, so most code never imports core.
- auth: new module, experimental. `findDefault` picks credentials the way
  Google's own libraries do: the file `GOOGLE_APPLICATION_CREDENTIALS`
  names, then the one gcloud's login writes, then the metadata server, with
  `Lookup.fromEnv` reading the variables and per-OS paths. A credential that
  is there but unusable stops the search rather than falling through.
  `MetadataServer` fetches tokens for the service account attached to a
  workload on Google Cloud, reads its project id, and tells you whether
  there is a metadata server at all.
  `Credentials.projectId` says which project a workload runs in, when the
  credentials know. `AuthorizedUser` reads the credentials file that
  `gcloud auth application-default login` writes, and trades its refresh
  token for access tokens at Google's token endpoint. `Cache`, which both
  build on, refreshes a token before it expires, runs one fetch at a time,
  keeps using a still-valid token when an early refresh fails, and wipes
  every copy it frees. `StaticToken` is also available here.
- pubsub: sends `x-goog-user-project` when the credentials name a project
  to charge for quota, which user credentials do. `send_quota_project` in
  `Client.Options` turns it off. A 401 now drops the cached token, fetches
  another and retries once, even for a publish with retries off: the server
  refused the request before storing anything. `examples/whoami.zig` prints
  which credentials the machine offers and lists the project's topics with
  them.
- pubsub: breaking: `retry_publish` moved from `RetryPolicy` to
  `Client.Options`. Write `.retry_publish = false` instead of
  `.retry = .{ .retry_publish = false }`.
- pubsub: breaking: logs under the scope `.gcp_pubsub`, not `.pubsub`, so
  it cannot collide with another library's scope. Rename it in
  `std_options.log_scope_levels`.
- pubsub: breaking, for custom token providers: `TokenProvider.getToken`
  takes an arena and returns the token copied into it, and a provider also
  implements `invalidate` and `quotaProject`. `TokenProvider.Error` names
  the token failures a caller can act on, such as `RefreshTokenInvalid`,
  and `pubsub.Error` gains them. `StaticToken` works as before.
- pubsub: breaking, for exhaustive switches: `pubsub.Error` gains the token
  errors above and `InvalidRequestHeader`, which a request carrying a header
  HTTP cannot express returns before it connects.
- pubsub: fixed: on Windows, a refused or dropped connection is retried.
  Zig 0.16 reports both as an unexpected error there, which the client took
  for a permanent `NetworkFailure`.
- pubsub: fixed: running out of memory while reading an error response is
  reported as `error.OutOfMemory`. Before, the error was mapped from the
  HTTP status alone, which could name the wrong error, and the call went
  on.

## 0.3.0 (2026-09-19)

- Breaking: the repository is now `zig-gcp` and the package is `gcp`, with
  one module per Google Cloud service. Depend on `gcp` instead of `pubsub`;
  the module keeps its name, so imports do not change.
- pubsub: no API changes. The default `User-Agent` is now
  `zig-gcp-pubsub/0.3`, after the repository.

## 0.2.0 (2026-09-19)

- Breaking: `error.Cancelled` is now `error.ServerCancelled`, so the
  server's CANCELLED status no longer sits one letter away from
  `error.Canceled`, which means the calling task was canceled through
  `std.Io`. Rename it wherever you handle it.

## 0.1.0 (2026-09-19)

First version, for Zig 0.16.0.

- Topics: create, get, list, delete, publish.
- Subscriptions: create, get, list, delete, pull, acknowledge, modify ack
  deadline, nack.
- Emulator mode, and production through the `TokenProvider` seam.
- Retries with full-jitter exponential backoff; `Diagnostics` for failed calls.
- Client-side checks of the API's fixed limits, measured against production.
