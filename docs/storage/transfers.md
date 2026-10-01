[Docs](../README.md) › [Cloud Storage](README.md) › Transfers

# Transfers

Objects of any size, streamed in constant memory, in parallel parts and
ranges, and carried on after a dropped connection or a process that
ended partway.

**On this page:** [Files of any size](#files-of-any-size) ·
[Parallel uploads](#parallel-uploads) ·
[Parallel downloads](#parallel-downloads) ·
[Transfers that outlive the process](#transfers-that-outlive-the-process)

## Files of any size

`uploadFile` sends a file, `uploadFrom` reads from any `std.Io.Reader`,
and `download` writes into any `std.Io.Writer`:

```zig
const file = try std.Io.Dir.cwd().openFile(io, "backup.tar", .{});
defer file.close(io);
var uploaded = try bucket.object("backups/backup.tar").uploadFile(file, .{
    .content_type = "application/x-tar",
});
defer uploaded.deinit();
```

- An upload goes through the resumable protocol in `chunk_size` pieces,
  8 MiB by default and always a multiple of 256 KiB; after a failure the
  client asks the server how much it kept and carries on from there.
  `uploadFile` reads the file at offsets, a chunk at a time, and its last
  request carries the whole file's CRC32C, so Cloud Storage refuses an
  object whose bytes differ before it exists: no read back, and nothing
  to delete. `uploadFrom` keeps one chunk in memory until the server
  confirms it, so a resume never needs the reader to go backwards.
  `upload` does the same above `single_request_limit` (8 MiB), slicing
  chunks from the caller's memory instead of copying them.
- When the session itself is lost, expired or cancelled, `upload` and
  `uploadFile` start over from their bytes; `uploadFrom` cannot, since
  the reader has moved on, so it returns `error.UploadSessionLost` for
  the caller to reopen the source and try again.
- A download writes into the caller's writer as the bytes arrive, and
  never flushes it: the buffer is the caller's. A connection that drops
  mid-body resumes at the byte it stopped at, pinned to the generation
  the first response named, so an overwrite in between is
  `error.NotFound` rather than a file spliced from two objects. `range`
  reads part of an object.
- [`examples/gcs_cp.zig`](../../examples/gcs_cp.zig) copies a file up or
  down, as
  `zig build example-gcs_cp -- backup.tar gs://my-bucket/backups/backup.tar`
  and back. Copying a 1 GiB file each way with it on macOS, the process
  peaked at 13.4 MiB resident going up and 5.0 MiB coming down.

Every transfer is checked against the object's CRC-32C:
[Checksums and compression](checksums-and-compression.md) says how.

## Parallel uploads

`uploadParallel` sends one object in parts, several at once, each on a
connection of its own, and has Cloud Storage join them: the XML API's
multipart upload. It is for large objects on fast links, where one
connection is the limit.

```zig
const file = try std.Io.Dir.cwd().openFile(io, "backup.tar", .{});
defer file.close(io);
var uploaded = try bucket.object("backups/backup.tar").uploadParallel(.{ .file = file }, .{
    .content_type = "application/x-tar",
    .part_size = 32 * 1024 * 1024, // the default
    .concurrency = 8,              // the default
});
defer uploaded.deinit();
```

- **Sources.** Bytes in memory are sliced, never copied; a file is read
  at each part's offset, so any number of workers read it at once.
- **Workers.** Each is a task with a client of its own
  (`Client.sibling`) and `part_timeout_ms` as its timeout, since one
  large part takes far longer than a small request.
- **Checksums.** Every part is checked against the CRC32C Cloud Storage
  stored for it. The parts' checksums combine into the whole object's
  with no second pass over the data. That is held to `options.crc32c`
  before anything is joined, so a file that changed under the upload
  writes nothing, and to the finished object afterwards.
- **Failures.** Without a checkpoint, every failure aborts the upload,
  so no part is left to be billed, and a cancel stops the workers and
  aborts too; with one, the parts stay for a later run, as
  [Transfers that outlive the process](#transfers-that-outlive-the-process)
  says. No retry writes twice: a part sent again replaces itself, and a
  finish repeated after a lost answer names the same generation as the
  one that landed.
- **Emulators.** Against an emulator, which has no multipart uploads,
  the object goes up as one ordinary upload, with any conditions.

Custom metadata travels as `x-goog-meta-` headers, so keys must be
lowercase, which is also what Cloud Storage makes of them: measured,
`x-goog-meta-Reviewer` comes back as `reviewer`.

### Conditions

The multipart upload takes no preconditions, and a precondition header
on it is not refused, only ignored: measured,
`x-goog-if-generation-match: 0` on a finish replaced an existing object.
So `options.preconditions` holds another way:

```zig
var created = try bucket.object("backups/db.tar").uploadParallel(.{ .file = file }, .{
    .preconditions = .does_not_exist, // create-only
});
defer created.deinit();
```

1. The object is read under the conditions first, so one that already
   fails, such as a create-only upload over an existing object, costs
   one request and refuses with `error.FailedPrecondition` before a byte
   is sent.
2. The parts go up and are joined under a temporary name in the same
   bucket, `zig-gcp-tmp/` and 32 random hex digits.
3. `objects.move` renames it into place only if the conditions still
   hold. The move is atomic and pinned to the temporary object's
   generation, charges no early deletion fee, and skips soft delete. Its
   answer is the finished object.

A refused move, and any failure after the finish, deletes the temporary
object again. A move whose answer is lost is settled by reading: if the
temporary object is gone, the move happened. The temporary object also
means three things to plan for:

- The move needs `storage.objects.move`, or `get` and `delete`, on the
  temporary object. Storage Object User and Admin grant them; Storage
  Object Creator does not, and with it the move fails with 403 once
  every byte is up, and the temporary object stays.
- Pub/Sub notifications and event triggers on the bucket see the
  temporary object come and go.
- A bucket with a retention policy or default event-based holds keeps
  objects from being deleted, and may refuse the move; this is
  unmeasured.

Without conditions, the upload replaces whatever has the name, and the
result is read back with one metadata request, which needs
`storage.objects.get`, a permission Storage Object Creator does not
grant.

### Cleaning up

> [!WARNING]
> A process that dies mid-upload leaves its parts, and Cloud Storage
> bills them until the upload is aborted: unfinished uploads never
> expire.

With a checkpoint, a later run carries the upload on, or
`abandonTransfer` aborts it. One that dies between the finish and the
move leaves an object under `zig-gcp-tmp/`. Lifecycle rules clean up
both:

```zig
var bucket = try gcs.bucket("my-bucket").update(.{ .lifecycle = &.{
    .{ .action = .abort_incomplete_multipart_upload, .condition = .{ .age_days = 7 } },
    .{ .action = .delete, .condition = .{ .age_days = 1, .matches_prefix = &.{"zig-gcp-tmp/"} } },
} });
defer bucket.deinit();
```

An update replaces every rule the bucket has, so to keep the ones it
has, `get` the bucket first and send its `lifecycle` with these added.

<details>
<summary><b>📏 Measured against a real bucket on 2026-09-24</b></summary>

Measured from this sandbox, 100 MiB in 8 MiB parts, 8 at a time, went up
in 10.0 s (10 MiB/s), where one stream took 34.9 s (2.9 MiB/s). A 1 GiB
file in 103 parts took 67.6 s eight at a time and 327.2 s one at a time,
4.84 times as fast; its finish took 143 ms, far from the "several
minutes" Google warns of. Smaller objects gain less: gcloud starts using
parallel uploads only at `150M`.

</details>

[`examples/gcs_cp.zig`](../../examples/gcs_cp.zig) takes `--parallel N`,
and `--no-clobber` with it.

## Parallel downloads

`downloadParallel` fetches one object in ranges, several at once, each
on a connection of its own, and writes each range at its offset in a
file or a buffer: Google's sliced download, which gcloud does by
default. It is for large objects on fast links, where one connection is
the limit.

```zig
const cwd = std.Io.Dir.cwd();
const file = try cwd.createFile(io, "backup.tar.part", .{});
defer file.close(io);
const result = try bucket.object("backups/backup.tar").downloadParallel(.{ .file = file }, .{
    .part_size = 32 * 1024 * 1024, // the default
    .concurrency = 8,              // the default
});
// result.checksum_verified: the ranges' checksums, combined, matched the
// object's. False with checking turned off.
try std.Io.Dir.rename(cwd, "backup.tar.part", cwd, "backup.tar", io);
```

- **One metadata read first** names the size, the generation, the
  CRC32C and the content encoding, with any `preconditions` applied.
  Every range is pinned to that generation, so an overwrite partway
  through is `error.NotFound`, never a file spliced from two objects.
- **Ranges.** Each is fetched with `download`, so it resumes at the byte
  where a dropped connection or a timeout left it. The workers are tasks
  with clients of their own and `part_timeout_ms` as their timeout.
- **Checksums.** A range carries no checksum of its own: Cloud Storage
  names none on a range short of the whole object, and the emulator
  names the whole object's. So each range is hashed as it arrives, and
  the hashes combine into the whole object's, which must match the
  metadata's. `DownloadResult.crc32c` is the checksum of what a download
  wrote, on every download.
- **Files** are set to exactly the object's length first and held to it
  afterwards. On Linux a file opened for appending takes every write at
  its end, whatever the offset; its length is what shows it, since the
  checksum covers the bytes as they arrived, not where they landed. A
  file that cannot be sized, such as a pipe, is refused. A **buffer**
  must hold the whole object, or the call is `error.ObjectTooLarge`
  before any range is read.
- **Two kinds of object are not split.** An empty object is not read at
  all. An object stored gzip-compressed is fetched by one worker, as
  `download` fetches it: as stored, verified, and decompressed in order,
  which no set of ranges written at their offsets could be. With
  `decompress = false` its stored bytes come in ranges like any
  object's.

> [!TIP]
> On any failure the destination holds whatever arrived, so write to a
> temporary name and rename it on success, as
> `examples/gcs_cp.zig --parallel N` does. With a checkpoint, a later run
> fetches only the ranges the file does not hold yet.

<details>
<summary><b>📏 Measured against a real bucket on 2026-09-24</b></summary>

Measured from this sandbox, 1 GiB in 32 MiB ranges came down in 64.8 s
eight at a time and 333.0 s one at a time, 5.14 times as fast.

</details>

## Transfers that outlive the process

A dropped connection is ridden out within a call. A process that ends
partway, crashed, killed or restarted, loses its place, unless the
transfer has a checkpoint: somewhere to keep what a later process needs
to carry it on. `uploadFile` takes one, and so do `uploadParallel` and
`downloadParallel` with a file.

```zig
var saved: storage.CheckpointFile = .init(io, state_dir, "db.tar.upload");
var info = try bucket.object("backups/db.tar").uploadFile(file, .{
    .content_type = "application/x-tar",
    .checkpoint = saved.checkpoint(),
});
defer info.deinit();
```

After a failure, the same call with the same checkpoint, in this process
or another, carries the transfer on:

| Call | Saves | A later run |
| --- | --- | --- |
| `uploadFile` | The session URL, once, when it opens | Asks the session how much it holds, and sends the rest |
| `uploadParallel` | The upload id, once, when it starts | Lists the parts the server holds, and sends the others |
| `downloadParallel` | After every range it writes | Fetches only the ranges the file does not hold |

- **Nothing about the data is taken on trust.** A later run re-reads
  locally what the earlier one moved, the prefix, the parts or the
  ranges, to rebuild the checksum that verifies the whole. A source file
  whose size or modification time changed starts the transfer over. One
  changed with its time put back is still caught: measured, the server
  refused the resumed upload's last request with 400, and the file went
  up again whole.
- **What a failure leaves.** With a checkpoint, a failed or cancelled
  transfer keeps its session or its parts for a later run, where one
  without cleans up. A failure no later run could get past cleans up and
  clears the checkpoint all the same: a checksum mismatch, a response
  the library cannot use, a failed precondition, a source that could not
  be read. A session that expired or was cancelled, and an upload that
  is gone, start over by themselves.
- **The state** is compact JSON with a version, readable for debugging
  but not an API. A checkpoint of another transfer, another object or
  kind, is refused with `error.CheckpointFailed` before anything is
  sent, rather than orphan that transfer's session; so is a save that
  fails, since the caller asked for a transfer that can resume.
- **Abandoning.** `client.abandonTransfer(checkpoint)` drops what a
  transfer left on the server, cancelling its session or aborting its
  parts, and then clears the checkpoint. Left alone, a session expires
  in a week, and parts stay billed until a lifecycle rule aborts them.
- **A store of your own** is three functions on `storage.Checkpoint`:
  `load`, `save` and `clear`. `CheckpointFile` keeps the state in one
  file, replaced atomically, readable and writable by its owner only.

> [!CAUTION]
> An upload's state holds its session URL, and the URL is a credential:
> anyone who has it can write the object for up to a week. The library
> never logs it or puts it in `Diagnostics`; keep a custom store's copy
> as you keep credentials.

`examples/gcs_cp.zig --resume STATE` keeps a `CheckpointFile`: kill a
copy partway, run the same command again, and it carries on.

<details>
<summary><b>📏 Measured against a real bucket on 2026-09-25</b></summary>

- A 64 MiB upload cut 3 MiB into its fifth 8 MiB chunk had 2.75 MiB of
  that chunk stored, in 256 KiB steps; a second client sent exactly the
  other 29.25 MiB, and its last request carried the file's CRC32C.
- A cancelled session answers 499 to the cancel, and to every status
  query or cancel after it. Google documents 404 and 410 for a session
  that expired; the library takes all three for a session that is gone.
- A create-only upload whose name another writer took while its session
  was open is refused with 412 at its last chunk: the condition is held
  again when the object would come into being, which Google's
  documentation does not say.
- ListParts pages with `max-parts`, and says `IsTruncated`, with a
  `NextPartNumberMarker` that is 0 on the last page. A part carries its
  number, time, ETag and size, and no checksum.

</details>

### A plain download, carried on by hand

A plain `download` takes no checkpoint, but can be carried on by hand:
fetch the rest as a range, pinned to the generation the first run read,
and join the checksums, since a range has none of its own to meet.
`core.crc32c` does the joining.

```zig
/// Carries on a download an earlier run left partway in `file`, from the
/// generation it was reading, and holds the whole to the object's CRC32C.
fn finishDownload(io: std.Io, object: storage.Object, file: std.Io.File, generation: u64) !void {
    var info = try object.get(.{ .generation = generation });
    defer info.deinit();
    const have = try file.length(io);
    var buffer: [64 * 1024]u8 = undefined;

    // The rest, pinned to the generation: an overwrite since the first
    // run is error.NotFound, never a file spliced from two objects.
    var rest_crc: u32 = 0;
    var rest_len: u64 = 0;
    if (have < info.value.size) {
        var writer = file.writer(io, &buffer);
        try writer.seekTo(have);
        const rest = try object.download(&writer.interface, .{
            .generation = generation,
            .range = .{ .offset = have },
        });
        try writer.interface.flush();
        rest_crc = rest.crc32c;
        rest_len = rest.bytes_written;
    }

    // A range has no checksum of its own to meet, so join its CRC32C to
    // that of the bytes the file already held, and compare the whole.
    var hasher: core.crc32c.Hasher = .init();
    var reader = file.reader(io, &buffer);
    var left = have;
    while (left > 0) {
        const chunk = try reader.interface.peekGreedy(1);
        const n: usize = @intCast(@min(chunk.len, left));
        hasher.update(chunk[0..n]);
        reader.interface.toss(n);
        left -= n;
    }
    const whole = core.crc32c.combine(hasher.final(), rest_crc, rest_len);
    if (info.value.crc32c != whole) return error.ChecksumMismatch;
}
```
