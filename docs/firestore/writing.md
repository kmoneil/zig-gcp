[Docs](../README.md) › [Firestore](README.md) › Writing documents

# Writing documents

Every write here travels through Firestore's `commit`, as Google's own
clients send them, `set`, `update` and `delete` included: the emulator
misreads a precondition's time sent any other way.

**On this page:** [Set, update, delete](#set-update-delete) ·
[Masks](#masks) · [Preconditions](#preconditions) ·
[Creating documents](#creating-documents) · [Transforms](#transforms) ·
[Several writes at once](#several-writes-at-once) · [Retries](#retries)

## Set, update, delete

- `document.set(fields, options)` writes the document whole: the fields
  given replace every field it had, and a missing document is created.
- `document.update(fields, options)` changes only the fields its mask
  names, by default the top-level names of `fields`, and by default the
  document must exist: `error.NotFound` otherwise, as Google's clients
  have it. `.precondition = null` writes it either way.
- `document.delete(options)` deletes the document. Deleting a missing
  one succeeds unless a precondition says it must exist, and the
  document's subcollections stay: Firestore deletes nothing but the one
  document.

`set` and `update` return a `WriteResult`, the document's new update
time.

## Masks

An update's mask is a list of field paths:

- A path with a value in `fields` writes that value.
- A path with no value deletes that field.
- A path inside a map, such as `address.city`, changes only that field
  of it; `address` alone replaces the whole map.

```zig
// city changes, zip stays, nickname goes.
_ = try la.update(&.{
    .{ .name = "address", .value = .{ .map = &.{.{ .name = "city", .value = .{ .string = "Los Angeles" } }} } },
}, .{ .mask = &.{ "address.city", "nickname" } });
```

Two refusals come before sending, though the server would take both:

- **A value outside the mask.** The server ignores it silently, so a
  forgotten mask path would lose a write without a word. The diagnostics
  name the field.
- **Overlapping paths**, such as `a` and `a.b`. The emulator applies both
  in order and production takes them too; Google's clients refuse them,
  and so does this one.

An update that would change nothing, no field, no mask path and no
transform, is refused as well.

## Preconditions

A write may hold the document to a condition:

| Precondition | Fails with |
| --- | --- |
| `.{ .exists = true }` | `error.NotFound`, "No document to update: ..." |
| `.{ .exists = false }` | `error.AlreadyExists`, "Document already exists: ..." |
| `.{ .update_time = t }` | `error.FailedPrecondition`, "the stored version (N) does not match the required base version (M)" |

`update_time` takes the time a read or a write returned, to the
microsecond. A write under it fails if anyone wrote the document in
between, which is how to change a document from what was read without a
transaction.

## Creating documents

`collection.create(fields, .{ .document_id = id })` creates a document
and returns it as stored; an existing id is `error.AlreadyExists`.
Without `document_id`, this picks a random id of 20 letters and digits
before sending, as Google's clients do, rather than leave it to the
server: a create whose answer was lost is sent again under the same id,
meets its own document, and reads it back instead of making a second
one.

## Transforms

A transform changes a field from its current value, on the server, after
the write's fields are written, so concurrent writers never lose one
another's changes:

| `op` | Does |
| --- | --- |
| `.server_time` | The time the server took the write, to the millisecond; the same for every such field of one commit |
| `.increment = n` | Adds `n`; integers saturate at the ends of `i64`, a double on either side makes a double, a missing or non-numeric field takes `n` |
| `.maximum = n`, `.minimum = n` | Keeps the larger or smaller; `3` and `3.0` count as equal and leave the field as it was; NaN wins |
| `.append_missing = values` | Appends each value the array lacks, in order |
| `.remove_all = values` | Removes every element equal to any value |

The array transforms compare numbers across integer and double, NaN to
NaN, and maps field by field; a field that is missing or no array
becomes one. All of this was measured on the emulator, and the fake the
unit tests run against reproduces it.

<!-- snippet: tests/docs_examples.zig#firestore-counter -->
```zig
/// Counts a visit on the server: concurrent visits never lose one, and the
/// document need not exist yet.
fn countVisit(client: *firestore.Client, page: []const u8) !void {
    _ = try client.doc(page).update(&.{}, .{
        .transforms = &.{
            .{ .field_path = "visits", .op = .{ .increment = .{ .integer = 1 } } },
            .{ .field_path = "last_visit", .op = .server_time },
        },
        // Created when missing, rather than error.NotFound.
        .precondition = null,
    });
}
```

`set` and `update` take `transforms`; `client.commit` returns their
results, the new value of each, null for the array transforms. Two
transforms may name one field, applied in turn, but not a field and one
inside it ("Cannot transform property m and its nested property at the
same time."). At most 500 per document per commit.

## Several writes at once

`client.commit(writes, options)` applies a list of `firestore.Write`
atomically and in order: every one or none. A write is
`.{ .update = .{ .path, .fields, .mask, .transforms, .precondition } }`,
where a null mask writes the document whole and an empty one with
transforms changes only what they change; or
`.{ .delete = .{ .path, .precondition } }`.

```zig
var result = try client.commit(&.{
    .{ .update = .{ .path = "orders/1001", .fields = &.{.{ .name = "status", .value = .{ .string = "paid" } }}, .mask = &.{"status"}, .precondition = .{ .exists = true } } },
    .{ .update = .{ .path = "stats/orders", .mask = &.{}, .transforms = &.{.{ .field_path = "paid", .op = .{ .increment = .{ .integer = 1 } } }} } },
    .{ .delete = .{ .path = "carts/1001" } },
}, .{});
defer result.deinit();
```

A document may be written more than once in one commit, each write
seeing the one before, and a precondition sees the commit's earlier
writes: a delete and then a create of the same document, under
`exists == false`, succeeds. In a commit of several writes, a refusal
before sending names the write by its index.

## Retries

A write whose answer was lost may have landed. Sending it again is safe
when a repeat cannot apply it twice:

- **A write without transforms** is retried: writing the same fields
  again leaves what a reader sees as it was.
- **A write with transforms** is retried only under a precondition a
  repeat fails, an update time or `exists == false`, since an increment
  sent twice counts twice. `update`'s default `exists == true` is no
  such precondition.
- **A commit** is retried only when every write in it may be.

A write that is not retried says in its diagnostics that it may or may
not have landed. Where a retried write meets its own landed attempt, as
`exists == false` meeting `AlreadyExists` or an update time meeting
`FailedPrecondition`, the diagnostics say that too.

`Client.Options.retry_unconditional_writes` retries every write,
transforms or not, as Google's clients do by default.
