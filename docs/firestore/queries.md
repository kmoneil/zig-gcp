[Docs](../README.md) › [Firestore](README.md) › Queries and aggregations

# Queries and aggregations

`client.runQuery(query, options)` runs a `firestore.Query` and returns
every result in one answer. Each rule below that says what matches or
how results are ordered was measured, on the emulator and in
production, and the fake this library tests against reproduces them: a
test holds it to the emulator over hundreds of random queries.

**On this page:** [A query](#a-query) · [Conditions](#conditions) ·
[Null and NaN](#null-and-nan) · [Order](#order) · [Cursors](#cursors) ·
[Collection groups](#collection-groups) · [Aggregations](#aggregations) ·
[What the server refuses](#what-the-server-refuses)

## A query

| Field | Means |
| --- | --- |
| `from` | `.{ .collection = "cities" }`, or `.{ .group = "landmarks" }` for every collection of that id |
| `parent` | The document below which to look, such as `cities/LA`; empty for the whole database |
| `where` | Conditions that must all hold |
| `filter` | A tree of `.all` and `.any` instead, for OR; not with `where` |
| `order_by` | Fields to order by, each `.ascending` or `.descending` |
| `select` | Field paths to return; empty for names only |
| `start_at`, `end_at` | Where the results begin and end, as [cursors](#cursors) |
| `offset`, `limit` | Results to skip, and the most to return |

`options.read_time` reads as of a past time, and `options.transaction`
in a transaction. The result is `documents`, the `read_time`, and
`skipped_results`, which production reports for an offset.

## Conditions

A condition is `.{ .field, .op, .value }`. The operators:

| `op` | Matches |
| --- | --- |
| `.equal`, `.not_equal` | Equal or not; numbers equal across integer and double, `1 == 1.0` |
| `.less_than` and the other three | Values of the operand's kind only: `> 1` matches numbers, never strings |
| `.array_contains` | Arrays holding the value |
| `.in`, `.array_contains_any` | Any of 1 to 30 values; for the second, arrays holding any |
| `.not_in` | None of 1 to 10 values |
| `.is_null`, `.is_nan`, `.is_not_null`, `.is_not_nan` | What they say; they take no value |

A document without the field never matches, whatever the operator, and
`not_equal` and `not_in` also leave out documents whose field is null.
`__name__` tests a document's name, compared with references:
`client.documentName(allocator, path)` builds one.

## Null and NaN

As a plain field filter, equality with null or NaN matches nothing, in
production as on the emulator, not even a field that is null. Google's
clients send it as the server's own test instead, and so does this one:

| Written | Sent |
| --- | --- |
| `.equal` null, `.equal` NaN | `IS_NULL`, `IS_NAN` |
| `.not_equal` null, `.not_equal` NaN | `IS_NOT_NULL`, `IS_NOT_NAN`; the latter also leaves out null |

A range or `array_contains` against null or NaN matches nothing either,
and is refused before sending; so is testing `__name__` for null, NaN or
array contents, which the server refuses. A null among `in`'s values
matches nothing, and among `not_in`'s, nothing at all.

## Order

Values order by kind, then within it: null, booleans, numbers (NaN
first), timestamps, strings (by their UTF-8 bytes), bytes, references
(segment by segment), geo points, arrays, maps. After the orders given,
the server orders by the field of every inequality not ordered by
already, then by name, in the last order's direction, which also breaks
ties. A document without a field ordered by is left out.

The order around `__name__` has rules of its own:

- Nothing may follow the name: "order by clause cannot contain more
  fields after the key", an inequality's implicit field included.
- Ordering by name descending alone needs a composite index in
  production ("The query requires an index. You can create it here:
  ..."), and the emulator refuses it outright.

## Cursors

A cursor is a position in the query's order: one value per entry of
`order_by`, at most as many. `start_at` with `.inclusive = false` starts
after the position, and `end_at` with it ends before. A `__name__`
position is a reference.

There is no cursor made from a document. To page through results, order
by the fields of the page's position, then `__name__`, so equal values
never repeat or vanish between pages, and start each page after the
last document of the one before:

<!-- snippet: tests/docs_examples.zig#firestore-pages -->
```zig
/// Reads every city by population, 100 at a time. Each page starts after
/// the last document of the one before, by its population and then its
/// name, which breaks ties between equal populations.
fn everyCity(client: *firestore.Client, gpa: std.mem.Allocator) !usize {
    var seen: usize = 0;
    var after: ?[2]firestore.Value = null;
    var name_buf: std.ArrayList(u8) = .empty;
    defer name_buf.deinit(gpa);
    while (true) {
        var page = try client.runQuery(.{
            .from = .{ .collection = "cities" },
            .order_by = &.{ .{ .field = "population" }, .{ .field = "__name__" } },
            .start_at = if (after) |*a| .{ .values = a, .inclusive = false } else null,
            .limit = 100,
        }, .{});
        defer page.deinit();
        const docs = page.value.documents;
        seen += docs.len;
        if (docs.len < 100) return seen;
        // The cursor outlives the page, so it keeps a copy of the name.
        const last = docs[docs.len - 1];
        name_buf.clearRetainingCapacity();
        try name_buf.appendSlice(gpa, last.name);
        after = .{ last.get("population").?, .{ .reference = name_buf.items } };
    }
}
```

That is the rule Google's clients follow when they build a cursor from a
document. `limit_to_last`, a client-side trick in those libraries, is
not here; reverse the order instead.

## Collection groups

`.from = .{ .group = "landmarks" }` reads every collection named
`landmarks`, at any depth, below `parent`, or anywhere when `parent` is
empty. A collection query reads only the collection directly below
`parent`.

## Aggregations

`client.runAggregationQuery(query, aggregations, options)` counts, sums
and averages on the server, without reading the documents: 1 to 5 at a
time, answered in the order given.

```zig
var stats = try client.runAggregationQuery(.{ .from = .{ .collection = "cities" } }, &.{
    .{ .count = .{} },
    .{ .sum = "population" },
    .{ .avg = "population" },
}, .{});
defer stats.deinit();
const count = stats.value.values[0].integer;
```

- `count` may stop at `up_to`.
- `sum` is an integer while every number is one and the sum fits, a
  double otherwise; values that are no number are left out.
- `avg` is a double, null when there is nothing to average.
- The query's limit, offset and cursors apply first. Its `select` is not
  sent: it means nothing here, and the emulator refuses one beside a sum.

> [!IMPORTANT]
> With a `sum` or an `avg` among them, every aggregation of the query,
> `count` included, sees only the documents that hold each field summed
> or averaged, whatever its value. In production as on the emulator, a
> `count` beside `sum("x")` counts the documents with an `x`. Count in a
> query of its own to count them all.

## What the server refuses

These stay the server's to check, and come back in `Diagnostics` in its
words. Production sends a query's error inside the stream its answer
would have taken, `[{"error": ...}]`, and core reads it there.

An error can also come after documents, inside a 200 response: a query
that runs past its deadline answers the documents it found and then
`DEADLINE_EXCEEDED`. The call fails with that error, never answering the
documents before it as the whole result, and is not retried.

- One `not_equal`, `not_in`, `is_not_nan` or `is_not_null` per query.
- `not_in` beside `in`, `array_contains_any` or OR.
- One `array_contains` or `array_contains_any` per term of the query's
  OR; each branch may hold one.
- Equality on `__name__` beside an inequality on another field, unless
  the name has one too.
- A field ordered by twice.
- A query that needs a composite index: `error.FailedPrecondition`, with
  a link to create it.
