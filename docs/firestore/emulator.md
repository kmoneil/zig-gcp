[Docs](../README.md) › [Firestore](README.md) › The emulator

# The emulator

Google's Firestore emulator serves the same v1 REST API as production.
Start it, and point the client at it with `FIRESTORE_EMULATOR_HOST`:

```sh
gcloud emulators firestore start --host-port=127.0.0.1:8087
export FIRESTORE_EMULATOR_HOST=127.0.0.1:8087
```

`firestore.Endpoint.fromEnv(environ)` reads the variable, `host:port`
with no scheme, and a client on it speaks plain HTTP and needs no token
provider. It never sends the caller's credentials there: it sends
`Authorization: Bearer owner`, the emulator's administrator, without
which listing collection ids answers 403 "Metadata operations require
admin authentication.". Any project id works, and every project starts
empty; `DELETE /emulator/v1/projects/P/databases/(default)/documents`
empties one.

**On this page:** [Where it differs](#where-it-differs) ·
[How this library is tested against it](#how-this-library-is-tested-against-it)

## Where it differs

Measured side by side with production, 2026-10-04 to 10-05:

| | Emulator | Production |
| --- | --- | --- |
| A timestamp as a query parameter, such as `currentDocument.updateTime` or `readTime` | Read as 0: a precondition that the document must not exist, or "Only timestamps past epoch are supported." | Read as sent |
| A transaction id as a query parameter | Hangs for a minute, and the transaction expires | Not measured |
| Ordering by `__name__` descending alone | Refused: "Firestore does not support descending key scans" | Needs a composite index |
| A query's error | `{"error": ...}` | `[{"error": ...}]`, inside the answer's stream |
| A query past its deadline | Not measured | The documents found, then `{"error": ...}` `DEADLINE_EXCEEDED`, all in a 200 |
| `batchGet`'s order | In no particular order | By name, the missing last |
| A request's size | Not measured | 11 MiB (11,534,336 bytes), not the documented 10: "Request payload size exceeds the limit: 11534336 bytes." |
| An offset | No `skippedResults` | `skippedResults` in a message of its own |
| `listCollectionIds` below a document id holding `:` | Refused | Answered |
| 501 transforms on one document | Taken | Refused, 500 at most |
| A transform on `__name__`, or an array among an array transform's values | Taken | Not measured; the client refuses both |
| Error messages | Its own words, such as "no entity to update: ..." | Google's documented words |

Everything else measured the same in both: a string or bytes value of at
most 1,048,487 bytes, the field path limit of 1,499 bytes, -0.0 losing its sign, timestamps kept to the microsecond,
equality with null or NaN matching nothing, a sum narrowing its query's
count, and the order of values.

The client works the same way against both. Writes go through `commit`
and read times through request bodies, which both take, and the client
checks the limits that one of them leaves to the other.

## How this library is tested against it

- **The emulator suite**, `tests/firestore_integration.zig`, runs every
  call end to end, each test in a project of its own.
- **The fake**: the unit tests run against `FakeFirestore`, written from
  what the emulator was measured to do, with its own JSON and field path
  parsing. A differential test, `src/firestore/emulator_diff.zig`, writes
  the same documents to both and runs 400 random queries and
  aggregations per seed against each, which must answer or refuse alike;
  its first runs found eleven rules of the emulator's that the fake now
  follows. CI runs five seeds; `FIRESTORE_DIFF_SEED` replays one.
- **Production**: `tests/firestore_gcp_integration.zig` runs against a
  real project, in a named database made for the run, and records what
  production does where it may differ.

[Development](../development.md#firestore) says how to run each.
