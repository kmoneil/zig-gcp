# Changelog

Until 1.0, minor versions may break the API; each entry says how. One
version covers the whole package, and each entry lists every module,
including the ones that did not change.

## 0.12.0 (unreleased)

- pubsub: `Topic.publish` now also retries ABORTED, CANCELLED and UNKNOWN,
  the statuses Google's own clients retry for Publish beyond the four it
  already did. UNKNOWN is retried only when the server answered with a 5xx:
  an HTTP status the library cannot place, such as a proxy's 405, reads as
  `error.Unknown` too, and it is permanent. `retry_publish = false` still
  turns every retry off.
- core: `rpc.Call.retryable` lets a call decide which failures are worth
  another attempt, given the error and the HTTP status. The default is
  `isRetryable`, as before.
- auth, secret_manager: unchanged.

## 0.11.1 (2026-09-21)

- pubsub: fixed: canceling `Subscriber.run` could hang it for good. `run`
  waits on a condition variable that every resolved message signals, and
  `std.Io.Condition` in Zig 0.16.0 drops a cancel that arrives while
  another waiter's signal is still pending. std delivers a cancel once, so
  the next wait could not be canceled and `run` never returned. A worker
  waiting in the message queue could lose its cancel the same way. `run`
  now waits on `core.Condition`, and closes the queue on every way out.
- core: `Condition` is `std.Io.Condition` with that flaw fixed: a canceled
  `wait` always returns `error.Canceled`, and any signal it took on the way
  goes to the next waiter.
- auth, secret_manager: unchanged.

## 0.11.0 (2026-09-21)

- auth: impersonated service accounts. `ImpersonatedServiceAccount`
  reads the `impersonated_service_account` file that
  `gcloud auth application-default login --impersonate-service-account`
  writes, takes a token from its source credentials (a user login or a
  service account key), and trades it at the IAM Credentials API for one
  that is the service account's. `findDefault` picks the file up wherever
  it picked up the other types; it used to refuse it. Only the account's
  email is read from the file's URL, and requests go to Google's endpoint,
  as Google's own libraries do, so a crafted file cannot send the source
  token anywhere else. A refusal names the role the login lacks,
  `roles/iam.serviceAccountTokenCreator`.
- core: when one `Diagnostics` is given to the credentials and to a client,
  as an application usually does, a failed token fetch now leaves the
  provider's own explanation, such as which role an impersonation lacks,
  where it used to be replaced by "the token provider failed".
- pubsub, secret_manager: no API changes; they report credential failures
  in the provider's words through core.

## 0.10.1 (2026-09-21)

- pubsub: fixed: `Subscriber.run` could hang for good after `stop()`.
  When the teardown's cancel reached the janitor while it was sending
  acknowledgements, the request noticed the cancel and the janitor then
  swallowed it, so it went on ticking and `run` waited for it forever.
  CI's integration suite met this about once in twenty runs. The
  acknowledgements that were in flight are now kept and sent by the
  final flush, so those messages are not redelivered either.
- core, auth, secret_manager: unchanged.

## 0.10.0 (2026-09-21)

- secret_manager: new module, stability `experimental`. A client for
  Secret Manager v1. `access` fetches a version's bytes, verifies the
  CRC-32C stored beside them and returns a `SecretValue` whose `deinit`
  wipes every buffer the call touched: the response body, the parser's
  scratch space, the decoded bytes and the bearer token. `addVersion`
  stores new bytes with a checksum the server verifies, from a request
  body built in wiped memory. `create`, `get`, `list` and `delete` cover
  secrets, and `get`, `list`, `enable`, `disable` and `destroy` cover
  their versions; the three that change a version's state take a number
  rather than `latest`. Secrets are global or regional, which decides both
  the host and the resource names. A `SecretValue` prints as `[REDACTED]`
  however it is formatted, and nothing about a secret reaches the log, not
  even its length. Read secrets at startup or on a timer: access calls are
  quota-limited and billed per call, and the library caches nothing.
- core: gains what the new module needed, all of it useful to later
  services. `rpc` is the request loop that lived in pubsub: credentials,
  the quota-project header, retries with jittered backoff, the 401
  re-authentication, error mapping and diagnostics, bound to each module's
  log scope. A call can now be marked as carrying secrets, and then its
  scratch memory is wiped and a failed attempt's response freed at once
  rather than kept for the next attempt. `crc32c` is CRC-32C, with the
  RFC 3720 vectors pinned. `query` holds percent-encoding and a
  query-string builder. `base64` and `endpoint` moved out of pubsub, and
  `names.isProjectId` replaces the copy pubsub and auth each had.
- auth, pubsub: no API changes. What they lost to core they now import
  from it, and their own tests are unchanged.

## 0.9.0 (2026-09-20)

- auth: fixed: `MetadataServer` accepted a host whose colon was followed
  by something other than a port, such as `metadata:host`, and the
  mistake then surfaced as a URL parse failure on the first request
  instead of the init-time "invalid metadata host" diagnostic. CI's
  coverage-guided fuzzing found it; the input is pinned in the corpus.
- core, pubsub: unchanged.

## 0.8.0 (2026-09-20)

- auth: workload identity federation. `ExternalAccount` reads an
  `external_account` file, fetches the third-party subject token from its
  credential source (a file or a URL, text or a JSON field), trades it at
  Google's STS with an RFC 8693 token exchange, and impersonates a
  service account through the IAM Credentials API when the file asks.
  `findDefault` and the gcloud file path accept such files wherever the
  other types worked. Subject tokens rotate, so each fetch reads anew;
  everything is cached, retried and wiped like the other providers. AWS
  credential sources (which need request signing), executable sources
  (which run a subprocess) and workforce pools are refused by name.
- auth: the scope-fixing that `ServiceAccount` introduced is shared as
  `Cache.ScopeSet`, and `ExternalAccount` uses it too.
- core: gains `timestamp` (RFC 3339), moved from pubsub, which auth needs
  for impersonated tokens' expiry. `pubsub.parseTimestamp` is unchanged.
- pubsub: unchanged.

## 0.7.0 (2026-09-20)

- pubsub: `Subscriber`, the worker loop consuming a subscription used to
  mean writing by hand: it pulls, hands each message to a handler on one
  of `concurrency` tasks, extends leases for as long as a handler runs
  (up to `max_extension_s`), acknowledges successes, releases failures
  for redelivery, and bounds unresolved messages with `max_outstanding`.
  Transient failures are retried forever with backoff; a fatal one, such
  as the subscription being deleted, stops the loop and comes back from
  `run` with diagnostics. `stop` drains cleanly from any task, `stats`
  snapshots the counters, and `examples/worker.zig` is now four lines of
  handler around it. Proven by unit tests against an in-memory server,
  integration tests against the emulator (a 15-second handler outliving
  a 10-second ack deadline included), and a fault-injection run.
- core, auth: unchanged.

## 0.6.0 (2026-09-20)

- auth: service account keys. `ServiceAccount` reads a `service_account`
  key file, signs a short-lived RS256 JWT with its RSA key, and trades it
  at the token endpoint for an access token, cached and wiped like every
  other secret. `findDefault` and the gcloud file path accept such files
  wherever an `authorized_user` one worked. The RSA is `std.crypto`'s
  constant-time modular exponentiation; the key is parsed from PKCS#8 or
  PKCS#1 PEM without allocating, and every signature is verified against
  the key's own public half before it leaves the process. A service
  account token is minted for particular scopes, so a provider's first
  `getToken` fixes its scopes, and a call asking for different ones fails
  with a diagnostic instead of silently changing what the token can do.
- auth: `Credentials.projectId` also answers from a service account key
  file, which names the project it belongs to.
- core, pubsub: unchanged.

## 0.5.0 (2026-09-20)

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
- tests: a fault-injection suite (`zig build test-integration`) drives the
  whole stack against the emulator through a proxy that drops connections
  mid-response, truncates and trickles bytes, stalls past the deadline and
  rewrites frames. It pins down what each misdelivery costs: a retry, an
  exact error, or a duplicated publish. No API change.

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
