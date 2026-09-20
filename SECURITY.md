# Security

This package holds credentials for somebody's Google Cloud account: bearer
tokens, and in `auth`, the refresh token that mints them. `pubsub` also
carries their messages. Two things follow from that, and this document is
about both: no credential may leak, and nothing a server or network peer
sends may crash the client or pass a partial response off as a whole one.

## Reporting a vulnerability

Email **kevin@oneil.xyz**, or use GitHub's
[private vulnerability reporting](https://github.com/kmoneil/zig-gcp/security/advisories/new).
Please do not open a public issue for a vulnerability.

You will get an acknowledgement within 3 working days. Fixed issues are
disclosed publicly within **90 days** of the report, sooner if a fix ships
earlier, later only by agreement with the reporter.

Include the version, the call, and if you can, the response that triggers it.

## Supported versions

Pre-1.0. Until the v1.0 tag, only the latest release receives fixes.

## Threat model

**Assumed hostile: everything a server sends.** Production is reached over
TLS, but the emulator speaks plain HTTP, and a proxy or a compromised peer can
say anything. A response is parsed, never trusted.

**Assumed trusted: the caller.** Arguments and options are the application's
own instructions. A mistake in them is still an error, never a crash or a
malformed request.

**Out of scope:** an attacker who already has a token or can read the
credentials file, a compromised machine, and the behavior of the emulator
itself.

Every claim below names the test that holds it. The tests live next to the
code in `src/`.

## Credentials

- **The emulator never receives a token,** even when a token provider is set,
  because it speaks plain HTTP. `credentials: production gets the bearer
  token, the emulator never does`.
- **No other endpoint receives one over plain HTTP either:** `Client.init`
  refuses a non-emulator endpoint that is not `https`. `credentials never go
  to a plain-http endpoint`.
- **A token that could break the Authorization header is refused before
  anything is sent,** whatever bytes a token provider returns.
  `credentials: an unusable token fails before sending`, `isValidToken
  rejects what would break the header`, `fuzz isValidToken: accepts exactly
  non-empty visible ASCII`, `fuzz: a provider's token reaches the request
  intact or not at all`.
- **Secrets are wiped before their memory is freed:** cached tokens, the
  refresh token and client secret, the credentials file as read, and
  everything a token fetch allocated. `Cache: every block the cache frees is
  wiped first`, `AuthorizedUser: every block it frees is wiped first`,
  `MetadataServer: every block it frees is wiped first`,
  `WipingAllocator: freed memory is zeroed before the child gets it back`,
  `WipingAllocator: an arena on top wipes every chunk when it is freed`,
  `fuzz WipingAllocator: nothing written survives a free`. Not covered:
  std.http's own connection buffers, which hold the latest request and
  response until the connection closes.
- **The refresh token goes only to the token endpoint,** over https, or
  plain http only to this machine, for tests. A redirect is refused, not
  followed. `AuthorizedUser: the token URL must use https, or http to this
  machine`, `AuthorizedUser: against a token endpoint on loopback`.
- **The metadata server has to prove itself.** It speaks plain HTTP by
  design, on an address that never leaves the host, so a header stands in
  for TLS: every request carries `Metadata-Flavor: Google`, which nothing
  can be tricked into sending by accident, and an answer without it is
  refused, whatever it contains. A redirect is refused too, and its
  answers are read to at most 64 KiB.
  `MetadataServer: the token request carries Metadata-Flavor and no token
  of its own`, `MetadataServer: an answer without Metadata-Flavor is not
  the metadata server's`, `MetadataServer: a wrong Metadata-Flavor value is
  refused, any case is accepted`, `MetadataServer: a redirect is refused,
  not followed`, `MetadataServer: its own transport reads at most 64 KiB
  from the answer`.
- **A header cannot smuggle a second request:** every name and value is
  checked against RFC 9110 before the transport connects.
  `HttpTransport refuses a header that would end the line, before it
  connects`, `fuzz headers: nothing accepted can break the request`.
- **Credential files are only read,** never written, and one over 64 KiB
  is refused. `AuthorizedUser: initFromFile reads the file, and reports a
  missing or oversized one`.
- **Redirects are never followed,** so a server cannot send the request, and
  its Authorization header, to another host. `HttpTransport does not follow
  redirects`.
- **Nothing sensitive reaches the log:** no tokens, message data, attribute
  keys or values, ordering keys or page tokens. Tokens stay out of
  `Diagnostics` too. `log hygiene: no token, payload or attribute value ever
  reaches the log`, `log hygiene: page tokens stay out of the log`, `fuzz: a
  provider's token reaches the request intact or not at all`, `Cache: a
  failed early refresh returns the cached token, warns, and retries 10 s
  later`, `AuthorizedUser: secrets reach neither the log nor Diagnostics`,
  `MetadataServer: the token reaches neither the log nor Diagnostics`.

## Talking to a server

- **Any response yields a value or an error, never a crash or a leak.**
  `fuzz: any server response yields a value or an error, never a crash or
  leak`, `fuzz decoders: arbitrary bodies never crash`, `fuzz
  decodeErrorBody: arbitrary bodies never crash`.
- **A body cut short is a dropped connection, never a short success,** whether
  it was framed by length or by chunks, compressed or not. `HttpTransport
  reports a truncated body as a dropped connection`, `HttpTransport reports a
  truncated chunked body as a dropped connection`, `HttpTransport: a gzip body
  cut short is a dropped connection; a corrupt one is not`.
- **Chunked bodies are decoded here, not by std.http,** whose decoder panics
  on a chunk size near 2^64. `Dechunker: a chunk size near 2^64 is an error,
  not a panic`, `fuzz Dechunker: arbitrary input never crashes`.
- **A response body is capped at 32 MiB.** `HttpTransport enforces the
  response size limit`.
- **Running out of memory is reported, never swallowed, and leaks
  nothing,** on every call path and at every allocation. `every public
  call: every allocation failure is OutOfMemory without leaks`,
  `credentials: every allocation failure on the token path is OutOfMemory
  without leaks`, `decodeErrorBody reports running out of memory, not an
  unreadable body`.
- **Certificates are checked against a clock read within the hour,** so a
  long-running client neither rejects rotated certificates nor keeps
  accepting expired ones. `HttpTransport: a TLS clock older than an hour is
  reloaded`, `HttpTransport: a failed TLS handshake forgets the TLS clock`.

## Caller input

- **An id cannot leave its path segment.** Ids are validated, and every byte a
  path segment does not allow is percent-encoded. `fuzz percent-encoding
  round-trips and emits only safe bytes`.
- **An endpoint that could inject into the request line, or trip assertions
  in std's resolver, is refused when the client is created.** `baseUrl:
  rejects what cannot be a base URL`, `fuzz baseUrl: never crashes; results
  are stable and printable`.
- **A string is never altered to make it sendable.** Invalid UTF-8 in an
  attribute, an ordering key or an ack id is refused, not replaced.
  `publish rules: empty messages, duplicate keys, UTF-8`, `ack ids and
  deadlines`.

## Supply chain

- **No dependencies** beyond the Zig standard library.
- **CI runs with a read-only token** and pins its actions to full commit
  SHAs, which Dependabot keeps current. The coverage job's container image
  is pinned by digest. CodeQL scans the workflows.

## What a hostile server can still do

Stated plainly, because a threat model that only lists wins is not one.

It can lie about the data: wrong messages, wrong ids, a list that leaves
topics out. It can withhold messages, redeliver them, or answer slowly; a
slow answer is bounded only by the caller's own cancellation, because
std.http has no request timeout. It can send a body just under the 32 MiB
cap. And on the plain-HTTP path to the emulator, anyone in between can read
and change everything, which is why no token ever goes there. A service
answering on the metadata address is in the same position: it receives no
credential, because that request carries none, and the most it can do is
hand out a token that does not work, or nothing at all. A token
endpoint can hand out a token that does not work; the cache keeps it for at
most 12 hours (`max_lifetime_s`), or until the provider's `invalidate` is
called.

What it cannot do is get a credential sent anywhere else, crash the client,
or get a truncated body accepted as complete.

## Keeping this current

Update this file in the same change that alters how a credential is
handled, what reaches the log, how responses are read, or the disclosure
process. Every claim above names the test that holds it, so if you move or
rename one, this document is part of the change.
