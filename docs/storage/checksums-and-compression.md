[Docs](../README.md) › [Cloud Storage](README.md) › Checksums and compression

# Checksums and compression

**On this page:** [Checksums](#checksums) ·
[Objects stored gzip-compressed](#objects-stored-gzip-compressed) ·
[Compressing on upload](#compressing-on-upload)

## Checksums

Every object has a CRC-32C, and it is checked in both directions:

| Call | Checked by | On a mismatch |
| --- | --- | --- |
| `upload` | The server, against the checksum the request carries | `error.InvalidArgument` (HTTP 400); nothing is stored |
| `uploadFile` | The server, against the file's checksum, which the last request carries | Nothing is stored: stored bytes cannot be overwritten, so the session is cancelled and the file sent again, up to `retry.max_attempts` times, then `error.UploadSessionLost` |
| `uploadFrom` with `options.crc32c` | The server, once the last chunk is in | The same |
| `uploadFrom` without it | The client, which hashes the stream and compares it with the finished object | `error.ChecksumMismatch`; the object is deleted again, pinned to its generation |
| Any upload with `gzip` | The client, which decompresses the compressed bytes as they are made and holds them to the data; then the server, against the compressed bytes' checksum, which the last request carries | `error.ChecksumMismatch` before the last request, or the session started over as for `uploadFile`; nothing wrong is stored |
| `download`, `downloadAlloc` | The client, which hashes the bytes as they pass | `error.ChecksumMismatch`; the writer holds bytes to discard |

`checksum_verified = false` means there was nothing to check against: a
`range` read, whose bytes are only part of what the checksum covers. A
resumed download is still verified: Cloud Storage names no checksum on a
partial range, so the client holds it to the one its first response
named. An object stored gzip-compressed is verified too, as the next
section says. `Options.verify_checksums = false` turns all of this off.

Checking costs little. `core.crc32c` runs the CPU's CRC32C instructions
where the build's target CPU has them, aarch64's CRC extension or
x86_64's SSE4.2, three streams at once, and eight tables, eight bytes at
a time, everywhere else. The build chooses, at compile time:
`zig build` on a machine that has the instructions takes them, as does
any `-Dcpu` that names them, and a baseline cross-compile takes the
tables. Measured on an Apple M5 Max on 2026-09-25:

| CRC-32C | ReleaseFast | Debug |
| --- | ---: | ---: |
| The standard library's, one table, which this used through v0.20.0 | 562 MiB/s | 180 MiB/s |
| The tables | 3.0 GiB/s | 0.7 GiB/s |
| The instructions | 29 GiB/s | 2.6 GiB/s |

In use, with `gcs_cp` in ReleaseFast against a local emulator, a 1 GiB
download spent 0.12 s of CPU where it spent 1.83 s, and finished in
about 0.4 s where it took 2.2 s: the checksum had been most of the work.
A resume's re-read of 1 GiB, which rebuilds its checksum from the file,
took 88 ms where it took 1.9 s. `zig build bench-crc32c` measures the
machine at hand.

## Objects stored gzip-compressed

An object uploaded compressed with `Content-Encoding: gzip`, as
`gcloud storage cp -z` makes them, has a CRC-32C of its compressed
bytes. Cloud Storage decompresses it on the way for a client that does
not ask for gzip, and then there is nothing to check the bytes against,
and a dropped connection cannot resume, since it ignores a range while
it decompresses. So downloads ask for every object as stored:

- **Decompressed here.** The stored bytes are checked against the
  stored checksum and decompressed on their way to the caller's writer.
  Every gzip member is decompressed, as `gzip -d` does, and each
  member's own CRC-32 and length are checked too. `downloadAlloc`'s cap
  counts the decompressed bytes, so a small object that decompresses to
  gigabytes stops there.
- **Resumed like any object.** Past its first chunk (`chunk_size`,
  8 MiB) the rest comes in ranges of the stored bytes, pinned to the
  generation, so a dropped connection costs at most one range, and the
  decompressor never sees it.
- **Or kept as stored.** `DownloadOptions.decompress = false` writes the
  stored bytes as they are, verified the same way;
  `ParallelDownloadOptions.decompress = false` fetches them in ranges,
  several at once. `DownloadResult.stored_bytes` counts what came over
  the wire.
- **Refused.** A range of a gzip object is refused with
  `error.InvalidArgument` unless `decompress` is false: part of a gzip
  stream does not decompress. An object whose metadata says gzip and
  whose bytes are not fails with `error.DecompressionFailed`; Cloud
  Storage never checks that an object is what its encoding says.

```zig
var page: std.Io.Writer.Allocating = .init(gpa);
defer page.deinit();
const result = try bucket.object("site/index.html").download(&page.writer, .{});
// result.checksum_verified: the stored bytes met the stored checksum.
// result.stored_bytes: fewer than result.bytes_written.
```

<details>
<summary><b>📏 Measured against a real bucket on 2026-09-25</b></summary>

- A range asked for as stored comes as asked, 206 with
  `Content-Encoding: gzip` and no `x-goog-hash`. Asked for plainly, the
  object comes whole and decompressed, the range ignored, as Google
  documents.
- An object stored plain is never compressed on its way: 2 MiB of text,
  4 KiB of HTML and 64 KiB of noise all came as stored to a client that
  offered gzip.
- `Cache-Control: no-transform` serves the stored bytes even to a client
  that asked for them plainly; they are decompressed here all the same.
- An object that says gzip and is not makes Cloud Storage's own
  transcoding answer 400 Bad Request.
- A gzip object of two members is decompressed whole by Cloud Storage's
  transcoding, and here.

</details>

`examples/gcs_cp.zig --no-decompress` keeps a gzip object as stored.

## Compressing on upload

`UploadOptions.gzip` compresses the data on its way up and stores it
that way, with `Content-Encoding: gzip` and the content type the caller
gave, as `gcloud storage cp -z` does. `upload`, `uploadFrom` and
`uploadFile` take it. The object's `size` and `crc32c` are then the
compressed bytes', and a download decompresses it again, verified, as
the last section says.

```zig
var info = try bucket.object("logs/2026-09-26.log").uploadFile(file, .{
    .content_type = "text/plain",
    .gzip = .{}, // level 6; 1 is fastest, 9 smallest
});
defer info.deinit();
// info.value.size: the stored, compressed size.
```

- **Checked before the object exists.** The compressed bytes are
  decompressed again as they are made and must give back exactly the
  data: its length and CRC-32C, the gzip header, and a trailer that
  agrees. The last request carries the compressed bytes' CRC-32C, which
  Cloud Storage checks as for any upload. `options.crc32c` names the
  data before compression, and is checked here. The request itself
  never carries `Content-Encoding`: Cloud Storage would take that to
  mean the body was compressed only for the trip, and store it
  decompressed.
- **In memory, or a chunk at a time.** `upload` compresses data of at
  most `single_request_limit` whole and sends it in one request; larger
  data, and every stream and file, goes a chunk at a time, one
  `chunk_size` buffer and about 650 KiB of compressor beside it. A lost
  session compresses `upload`'s data or `uploadFile`'s file again from
  the start.
- **Resumed from a checkpoint.** `uploadFile` with `options.checkpoint`
  carries a compressed upload on in a later process: it compresses the
  file again from its first byte and passes over what the session holds,
  which costs CPU, about 9 seconds per GiB already sent at level 6, and
  no bandwidth. The same file at the same level gives the same bytes, on
  the same Zig; a checkpoint written at another level or by another Zig
  starts over.
- **Not in parallel.** A gzip stream's offsets are not known until it is
  made, so `uploadParallel` has no `gzip`. Compress into a file first
  and upload that in parallel with `content_encoding = "gzip"`, as
  gcloud does.
- **What to compress** is the caller's choice. Text, JSON, CSV and logs
  shrink to a fifth of their size or less; images, video, archives and
  anything already compressed grow by about 0.2%, as Google warns.
- **`Cache-Control`** is left as the caller gives it. Without
  `no-transform`, Cloud Storage decompresses the object for any client
  that does not ask for gzip, so any client can read it; with it, every
  client gets the stored bytes. gcloud sets `no-transform`, and so does
  `gcs_cp -z`.

The compressor is the standard library's, audited here: it gave correct
output on every one of about 506,000 fuzzed cases, and the same bytes
however its input was split, which a resume depends on. On 64 MiB of
text, measured on an Apple M5 Max:

| Level | ReleaseFast | Debug | Size |
| --- | ---: | ---: | ---: |
| 1 | 197 MiB/s | 21.8 MiB/s | 17% |
| 3 | 178 MiB/s | 20.1 MiB/s | 14% |
| 6 | 111 MiB/s | 13.0 MiB/s | 13% |
| 9 | 44 MiB/s | 5.3 MiB/s | 13% |

Checking by decompressing costs about an eighth more on text, and a
third more on data that does not compress.

<details>
<summary><b>📏 Measured against a real bucket on 2026-09-26</b></summary>

- Each call stored exactly the bytes the standard library makes of the
  data, and a request for plain bytes got the data back, decompressed by
  Cloud Storage, with the stored bytes' `x-goog-hash` beside it, which
  cannot check what was sent.
- A compressed `uploadFile` cut 300 KiB into its second 1 MiB chunk:
  Cloud Storage kept the first 1 MiB and none of the second. A second
  process compressed the file again, passed over that 1 MiB, sent the
  other 5,253,472 bytes, and the object verified.
- `gcloud storage cp -Z` compressed 2,294,729 bytes of access log to
  369,844 at level 9, with `Cache-Control: no-transform` and a content
  type guessed from the name; it downloads here decompressed and
  verified. The same file uploaded here at level 6 came to 400,094
  bytes, and `gcloud storage cp` reads it back to the original.
- A body sent with a request `Content-Encoding: gzip`, through a media
  upload, a multipart upload compressed whole, or one resumable chunk,
  was decompressed by Cloud Storage and stored plain, with no
  `contentEncoding`, which is why this library never sends one.

</details>

`examples/gcs_cp.zig -z log,txt` compresses a file whose name ends in
one of the extensions, and `-Z` any file.
