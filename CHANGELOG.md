# Changelog

Until 1.0, minor versions may break the API; each entry says how. One
version covers the whole package, and each entry lists every module,
including the ones that did not change.

## 0.4.0 (unreleased)

- core: new module, holding what the service modules share: the HTTP
  transport, `RetryPolicy`, Google API errors and `Diagnostics`, `Owned`,
  the `TokenProvider` seam with `StaticToken`, and test fakes in
  `core.testing`. pubsub re-exports what its callers use, so most code
  never imports core.
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
