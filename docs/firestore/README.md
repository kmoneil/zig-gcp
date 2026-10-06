[Docs](../README.md) › Firestore

# 🔥 Firestore

A client for Cloud Firestore's v1 REST API: documents read, written and
deleted under preconditions; several writes committed together, with
field transforms; queries and aggregations over collections and
collection groups; and transactions that run again when they meet
contention. It works against the `(default)` database or a named one,
and against the emulator.

```zig
const std = @import("std");
const auth = @import("auth");
const firestore = @import("firestore");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    // FIRESTORE_EMULATOR_HOST, when set, wins, and needs no credentials.
    const endpoint = firestore.Endpoint.fromEnv(init.environ_map);
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    if (endpoint == null) {
        const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    }
    var client = try firestore.Client.init(init.gpa, init.io, .{
        .project_id = "my-project",
        .endpoint = endpoint,
        .token_provider = if (creds) |c| c.provider() else null,
    });
    defer client.deinit();
    try cities(&client);
}
```

<!-- snippet: tests/docs_examples.zig#firestore-first -->
```zig
/// Writes a city, raises its population under the update time it was read
/// at, and lists the cities of over a million, largest first.
fn cities(client: *firestore.Client) !void {
    const la = client.collection("cities").doc("LA");
    _ = try la.set(&.{
        .{ .name = "name", .value = .{ .string = "Los Angeles" } },
        .{ .name = "population", .value = .{ .integer = 3_900_000 } },
    }, .{});

    var got = try la.get(.{});
    defer got.deinit();
    const population = got.value.get("population").?.integer;
    // error.FailedPrecondition if anyone wrote LA after this read.
    _ = try la.update(&.{
        .{ .name = "population", .value = .{ .integer = population + 100_000 } },
    }, .{ .precondition = .{ .update_time = got.value.update_time } });

    var big = try client.runQuery(.{
        .from = .{ .collection = "cities" },
        .where = &.{.{ .field = "population", .op = .greater_than, .value = .{ .integer = 1_000_000 } }},
        .order_by = &.{.{ .field = "population", .direction = .descending }},
    }, .{});
    defer big.deinit();
    for (big.value.documents) |city| std.log.info("{s}", .{city.id()});
}
```

[`examples/firestore.zig`](../../examples/firestore.zig) does all of
this from the command line, and more: `zig build example-firestore --
set cities/LA population=3900000`, then `get`, `update`, `incr`,
`query`, `count`, `getall`, `collections`, `transfer` and `rm`.

**On this page:** [Values and documents](#values-and-documents) ·
[Paths and handles](#paths-and-handles) · [What it covers](#what-it-covers) ·
[Errors and retries](#errors-and-retries) · [Limits](#limits)

**Guides:** [Writing documents](writing.md): masks, preconditions,
transforms and commits · [Queries and aggregations](queries.md) ·
[Transactions](transactions.md) · [The emulator](emulator.md)

## Values and documents

A field's value is a `Value`, a union of Firestore's eleven kinds:
`.null`, `.boolean`, `.integer`, `.double`, `.timestamp`, `.string`,
`.bytes`, `.reference`, `.geo_point`, `.array` and `.map`. A document,
and a map, is a slice of `Field`, a name and a value, in the order the
server sent them; `snapshot.get(name)` and `value.get(name)` find one.

- Integers are exactly `i64` both ways. Nothing turns one into a double,
  and a double never comes back as an integer.
- Doubles carry NaN and both infinities, which JSON has no numbers for.
  -0.0 is stored as 0.0: production and the emulator both drop the sign.
- Timestamps are `std.Io.Timestamp`. The server keeps microseconds and
  drops finer digits; years 1 to 9999 only.
- A reference is a full document name,
  `projects/P/databases/D/documents/PATH`, which
  `client.documentName(allocator, path)` builds.
- No sentinels hide in the data. A server timestamp or an increment is a
  transform, listed beside the fields, not a magic value among them; see
  [Transforms](writing.md#transforms).

A read returns an `Owned(Snapshot)`: `name`, `fields`, `create_time`,
`update_time`, and `id()` and `path()`. Everything in it lives in the
result's arena until `deinit`.

## Paths and handles

A path is relative to the database's documents, and alternates
collection and document ids: `cities` is a collection, `cities/LA` a
document, `cities/LA/landmarks` a subcollection. Handles cost nothing
and send nothing:

- `client.collection(path)` and `client.doc(path)` take a whole path.
- `collection.doc(id)` and `document.collection(id)` add one segment.

A handle borrows the strings it was built from and joins them when a
call sends it, so it allocates nothing. It holds at most eight of them,
the first path and seven more segments; one derived past that says so
on its first call, `error.InvalidResourceId`, and `client.doc` then
takes the whole path at once. Ids are any UTF-8 but
`/`, `.`, `..` and the reserved `__x__` names, at most 1,500 bytes, and
travel percent-encoded: `a b%c+d` and `été` are ids like any other.

A field name that is not an identifier, such as `a-b` or `c.d`, is
quoted in backticks wherever it becomes a field path. Masks and orders
take field paths: `address.city`, or `` `a-b`.c ``.
`firestore.field_path.ofName(allocator, name)` quotes a name for one.

## What it covers

| Call | What it does | Guide |
| --- | --- | --- |
| `document.get(options)` | One document, all of it or through a read mask, now, at a past time, or in a transaction | |
| `document.set(fields, options)`, `.update(fields, options)`, `.delete(options)` | Writes it whole, changes the fields a mask names, deletes it; each under a precondition when asked | [Writing](writing.md) |
| `collection.create(fields, options)` | A new document, under an id of yours or a random one | [Writing](writing.md#creating-documents) |
| `client.commit(writes, options)` | Several writes, atomic and in order, with field transforms, and what each did | [Commits](writing.md#several-writes-at-once) |
| `client.batchGet(paths, options)` | Many documents in one request, in the order asked, `null` for a missing one | |
| `collection.list(options)` | One page of a collection's documents | |
| `client.listCollectionIds(options)`, `document.listCollectionIds(options)` | The collections at the root, or below a document | |
| `client.runQuery(query, options)` | Filters, orders, cursors, offset, limit and select, over a collection or a collection group | [Queries](queries.md) |
| `client.runQueryEach(query, options, handler)`, `client.batchGetEach(paths, options, handler)` | The same reads, each document handed over as it arrives, in the memory of one | [Large answers](queries.md#large-answers-as-they-arrive) |
| `client.runAggregationQuery(query, aggregations, options)` | Count, sum and average, on the server | [Aggregations](queries.md#aggregations) |
| `client.runTransaction(handler, options)` | Reads and writes together, run again on contention | [Transactions](transactions.md) |
| `client.beginTransaction(options)`, `client.rollback(id)` | A transaction driven by hand | [Transactions](transactions.md#by-hand) |

Not covered: listening for changes (production serves it over gRPC and
WebChannel only, not REST), `batchWrite`, partitioned queries,
pipelines, and creating databases and indexes, which is `gcloud`'s job.

## Errors and retries

Calls return `firestore.Error`, and `Diagnostics` hold the server's
words. Reading a missing document is `error.NotFound`, as in every
module here; `batchGet` answers missing documents with `null` instead,
so checking whether documents exist needs no error handling.

Reads and queries are retried after transient failures, as core's retry
policy says. Writes are retried when sending them twice cannot apply
them twice: a write without transforms always, one with transforms only
under a precondition a repeat fails. [Retries](writing.md#retries) has
the rule, and `Client.Options.retry_unconditional_writes` to retry
regardless, as Google's own clients do. A transaction's commit is never
sent twice; see [Transactions](transactions.md).

## Limits

Checked before anything is sent, as production enforces them:

| What | Limit |
| --- | --- |
| A collection or document id | 1,500 bytes, no `/`, not `.` or `..`, no `__x__` |
| A path | 100 segments; a full name, `projects/.../documents/...`, 6 KiB |
| A field name | 1,500 bytes, not empty, no `__x__` |
| A field path | 1,499 bytes: production refuses 1,500, though Google documents it as the limit |
| A string or bytes value | 1,048,487 bytes |
| Maps and arrays in one value | 20 deep; no array directly in an array |
| Transforms on one document in one commit | 500 |
| `in` and `array_contains_any` | 1 to 30 values; `not_in` 1 to 10 |
| Aggregations in one query | 5 |
| A document | 1,048,576 bytes, counted as Firestore counts them (below) |
| A request | 11,534,336 bytes (11 MiB), though Google documents 10 MiB |

A document's size is counted as production counts it, checked to the byte
for every kind of value against the size production reports when it
refuses one (2026-10-05). Its path, each collection and document id as a
string, plus 16; each field, its name as a string and its value; plus 32.
A string is its UTF-8 bytes plus one, bytes their length, a boolean or
null 1, a number or timestamp 8, a geo point 16, a reference its
document's path, an array its values, a map its names and values, and an
empty array or map 1 (Google documents 0). `firestore.limits.documentSize`
gives it. A write through a mask can only be checked for what it sends:
growing a stored document past the limit is the server's refusal,
`error.InvalidArgument` with its words.

Index entries, at most 40,000 per document, are left to the server too:
how many a document makes depends on the database's index settings.
