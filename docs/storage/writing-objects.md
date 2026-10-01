[Docs](../README.md) › [Cloud Storage](README.md) › Writing objects

# Writing objects

**On this page:** [Preconditions and retries](#preconditions-and-retries) ·
[Metadata, after the upload](#metadata-after-the-upload) ·
[Compose](#compose) ·
[Copies that change what they carry](#copies-that-change-what-they-carry)

## Preconditions and retries

`Preconditions` compare against an object's generation, which changes
with every overwrite, or its metageneration, which changes with every
metadata update, on gets, downloads, deletes, uploads and copies.
`.does_not_exist` makes an upload create-only.

Retries follow what is safe to repeat. Reads always retry, and resumable
chunks always resume from what the server confirmed. A write is retried
when repeating it cannot do harm: an upload or copy carrying
`if_generation_match`, a metadata update carrying
`if_metageneration_match`, or a delete naming a `generation`, whose
repeat fails cleanly if the first attempt landed, instead of overwriting
or deleting whatever is there by then.

Every JSON API write also carries `X-Goog-Gcs-Idempotency-Token`, one
value per call and the same on each of its retries. Cloud Storage
answers a repeated upload of one request, metadata update, move or
delete with its first result and does not act again, so these retry
without a condition too, for 60 seconds after their first attempt:
Google's "within a minute". A conditional one whose first answer was
lost gets its own result back, not a failed condition. Compose, copy,
restore and bucket calls act again on a repeat, token or not, and retry
as before. `Options.idempotency_tokens = false` sends none and keeps
only the conditions' retries. `Options.retry_unconditional_writes`
retries every write, past the window too.

A 412 on a write that may have been retried says so in `Diagnostics`:
the first attempt may have succeeded, so `get` the object and compare
checksums. An `if_generation_not_match` or `if_metageneration_not_match`
met by the current object is `error.NotModified`, an answer rather than
a failure.

<details>
<summary><b>📏 Measured against Cloud Storage on 2026-09-30</b></summary>

A repeat with the token was recognised 115 seconds after the first
attempt and not after 130: an upload repeated after another writer
replaced the object left that writer's object, a delete repeated after
the name was created again left the new object, and a patch repeated
after another writer's kept that writer's value. A failed attempt is
not replayed: a repeat after its cause is gone succeeds.

</details>

## Metadata, after the upload

Nothing about an object's bytes has to move to change what it says
about itself. `updateMetadata` patches: fields left null keep the values
they had, and the bytes and the generation stand still.

```zig
var patched = try object.updateMetadata(.{
    .content_type = "text/markdown",
    .cache_control = "public, max-age=60",
    .edit = .{ .change = &.{
        .{ .key = "reviewer", .value = "sam" },
        .{ .key = "draft", .value = null },   // null removes the key
    } },
});
defer patched.deinit();
```

`edit` is the whole of what happens to custom metadata, and Cloud
Storage reads three different requests there, which cannot be combined
because a JSON object has one `metadata` value:

| `edit` | What it does |
| --- | --- |
| `.keep` (the default) | Every entry keeps its value |
| `.change` | Sets the entries with a value, removes the entries with none, and leaves every key it does not name |
| `.clear` | Removes every entry |

A patch moves the metageneration and not the generation, so
`if_metageneration_match` is what makes one safe to repeat; a generation
condition says nothing about it. `generation` patches one named
generation, which needs a versioned bucket to reach a noncurrent one.

Measured against a real bucket on 2026-09-23: a key the patch does not
name survives it, `.clear` really does remove the lot, a stale
`if_metageneration_match` is 412 and leaves the object alone, and the
content stays byte for byte what it was.

## Compose

`composeFrom` writes an object from up to 32 others in the same bucket,
server-side, with no bytes moving:

```zig
var joined = try bucket.object("whole.bin").composeFrom(&.{
    .{ .name = "part-1" },
    .{ .name = "part-2" },
}, .{ .content_type = "application/octet-stream" });
defer joined.deinit();
```

The destination may be one of its own sources, so an append is a
compose whose first source is the destination, and a larger join is
repeated composes. Sources share a bucket and a storage class, may each
pin a `generation` or carry an `if_generation_match`, and
`delete_sources` hard-deletes them once the composite exists, which is
what Google advises for parallel composite uploads and wrong wherever
soft delete, versioning, a retention policy or a hold is in play.

Nothing is inherited: the composite's metadata is what the call sends.
It has no MD5, which no composite has, and a CRC32C that Cloud Storage
derives from its components', so `download` verifies one exactly as it
verifies anything else. `component_count` says how many objects it is
made of.

Two rules here are this library's rather than Cloud Storage's: a source
named twice at the same generation is refused, since concatenating one
object twice is far more often a loop bug than a request, and a compose
that deletes its sources is never retried without a precondition,
because the second attempt would find them gone.

## Copies that change what they carry

`copyTo` copies server-side, and can change the copy's metadata on the
way: the same fields `updateMetadata` takes, and a storage class.

```zig
// Onto itself with a new class: how an object's class changes on demand,
// without its bytes going anywhere near this machine.
var archived = try object.copyTo(object, .{ .storage_class = "COLDLINE" });
defer archived.deinit();

var renamed = try object.copyTo(bucket.object("public/report.csv"), .{
    .content_type = "text/csv",
    .cache_control = "public, max-age=300",
});
defer renamed.deinit();
```

With no change the copy carries the source's metadata as it is. With
any change, a storage class included, the copy first reads the source's
metadata and sends it back with the change applied. That is because
Cloud Storage takes whatever metadata a copy sends as the whole of the
copy's. Measured against a real bucket on 2026-09-24:

- A rewrite naming only a content type came back with no cache control,
  no language, no custom metadata and no custom time.
- One naming only a storage class, which is exactly what Google's own
  samples send to change a class, came back with an empty content type
  and no custom metadata.

The copy is pinned to what it read. `sourceGeneration` fixes the bytes
and `ifSourceMetagenerationMatch` the metadata, so a source that changes
in between fails the copy with a 412 rather than mixing two versions. A
copy with no `storage_class` takes the destination bucket's default:
measured, a NEARLINE object copied, changed or not, into a STANDARD
bucket came out STANDARD. ACLs, holds and retention are never copied.
