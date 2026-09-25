# Changelog

Until 1.0, minor versions may break the API; each entry says how. One
version covers the whole package, and each entry lists every module,
including the ones that did not change.

## 0.22.0 (unreleased)

- storage: objects stored gzip-compressed (`Content-Encoding: gzip`) now
  download verified. Every download asked for plain bytes, so Cloud
  Storage decompressed such an object on the way: there was nothing to
  check the bytes against, since the stored checksum covers the
  compressed ones, and a dropped connection could not resume, since
  Cloud Storage ignores a range while it decompresses. Downloads now ask
  for bytes as stored. A plain object comes as before. A gzip object's
  stored bytes are held to the stored checksum and decompressed here;
  past the first chunk they come in ranges pinned to the generation, so
  a dropped connection costs at most one range. Every gzip member is
  decompressed, as `gzip -d` does, and each member's CRC-32 and length
  are checked, which std's decompressor reads and does not check.
  `downloadAlloc`'s cap counts decompressed bytes. `DownloadOptions` and
  `ParallelDownloadOptions` gain `decompress`, true by default; false
  keeps the stored bytes, verified, and `downloadParallel` then fetches
  them in ranges. `DownloadResult` gains `stored_bytes`. A plain object
  compressed on its way would be asked for again plainly; measured,
  Cloud Storage never does that. Measured too: an object that says gzip
  and is not makes Cloud Storage's own transcoding answer 400. Breaking,
  for an exhaustive `switch` over `storage.Error`: it gains
  `DecompressionFailed`, for such an object; for code that builds a
  `DownloadResult` itself, which must now give `stored_bytes`; and a
  range of a gzip object is now `error.InvalidArgument` unless
  `decompress` is false, where it was `error.InvalidResponse`.
- core: `transport.StreamRequest.AcceptEncoding` gains `gzip_as_sent`,
  which offers gzip and delivers the body as it arrived. Breaking, for an
  exhaustive `switch` over `AcceptEncoding`.
- examples: `gcs_cp --no-decompress` keeps a gzip object as stored.
- auth, pubsub, secret_manager: unchanged.

## 0.21.0 (2026-09-25)

- core: `crc32c` computes CRC-32C with the CPU's instructions where the
  build's target CPU has them, aarch64's `crc32cx` or x86_64's SSE4.2
  `crc32q`, three streams at once, and with eight tables, eight bytes at a
  time, everywhere else. It was the standard library's one table, a byte
  at a time. Measured on an Apple M5 Max: 29 GiB/s for the instructions
  and 3.0 GiB/s for the tables, against 562 MiB/s; in Debug, 2.6 GiB/s
  against 180 MiB/s. The build chooses, at compile time: a native build,
  or a `-Dcpu` that names the instructions, takes them, and a baseline
  build takes the tables. At comptime the tables run, as std's CRC could.
  `crc32c.implementation` says which a build runs, and
  `crc32c.hashSoftware` computes by the tables on any machine. Breaking,
  for code that reached into std's type: `crc32c.Hasher` is now core's
  own, with the same `init`, `update`, `final` and `hash` and the same
  answers, but none of std's fields.
- secret_manager, storage: every checksum they compute goes through
  `core.crc32c`, with no API change. With `gcs_cp` against a local
  emulator, a 1 GiB download spent 0.12 s of CPU where it spent 1.83 s,
  and a resume's re-read of 1 GiB took 88 ms where it took 1.9 s.
- tools: `zig build bench-crc32c` prints each path's speed on the machine
  at hand.
- auth, pubsub: unchanged.

## 0.20.0 (2026-09-25)

- storage: transfers that outlive the process. `Object.uploadFile(file,
  options)` is a resumable upload from a file, read at offsets a chunk at
  a time, whose last request carries the whole file's CRC32C, so Cloud
  Storage refuses an object whose bytes differ before it exists: no read
  back, and nothing to delete. A lost session starts over from the file.
  `UploadOptions`, `ParallelUploadOptions` and `ParallelDownloadOptions`
  gain `checkpoint`, a `storage.Checkpoint`: three functions, `load`,
  `save` and `clear`, over wherever the caller keeps state, with
  `storage.CheckpointFile` built in, which keeps it in one file replaced
  atomically and readable by its owner only. With one, `uploadFile`,
  `uploadParallel` from a file and `downloadParallel` into a file save
  what a later process needs, and the same call with the same checkpoint
  carries the transfer on: it asks the session how much it holds, lists
  the parts the server holds, or fetches only the ranges the file does
  not hold. What the earlier run moved is read again locally to rebuild
  the checksums, so a file changed between runs is caught, and a source
  whose size or modification time changed starts over. With a
  checkpoint, a failed or cancelled transfer keeps its session or its
  parts for a later run; a failure no later run could get past cleans up
  and clears it all the same. `Client.abandonTransfer(checkpoint)` drops
  what an unfinished transfer left on the server and clears the
  checkpoint. An upload's state holds its session URL, a credential, and
  is never logged. Measured against a real bucket, a cancelled session
  answers 499 to everything sent to it afterwards, where an expired one
  answers 404 or 410: 499 now means a session is gone too, so `upload`
  and `uploadFile` start over, and `uploadFrom` returns
  `error.UploadSessionLost` where it returned `error.ServerCancelled`,
  which left a checkpoint whose session had been cancelled failing every
  resume. Measured too: a create-only resumable upload whose name was
  taken meanwhile is refused with 412 at its last chunk. The XML reader
  refuses an element name that is no qualified name, such as `<:/>`,
  which it read as an element with no name; the nightly fuzzing found it.
  Breaking, for an exhaustive `switch` over `storage.Error`: it gains
  `CheckpointFailed`.
- examples: `gcs_cp --resume STATE` carries a copy on, either way, after
  a failure or a killed process, when the same command runs again.
  Uploads without `--parallel` go through `uploadFile`.
- auth, core, pubsub, secret_manager: unchanged.

## 0.19.0 (2026-09-24)

- storage: parallel downloads, and parallel uploads that can be
  create-only. `Object.downloadParallel(destination, options)` fetches
  one object in ranges, `concurrency` at a time (8 by default), each on a
  client and connection of its own, and writes each at its offset in a
  file or a caller's buffer: Google's sliced download, which gcloud does
  by default. One metadata read names the size, generation, CRC32C and
  content encoding, and every range is pinned to that generation, so an
  overwrite partway through is `error.NotFound`, never a file spliced
  from two objects. Each range is fetched with `download`, so it resumes
  where a dropped connection left it. The ranges' checksums combine into
  the whole object's, which must match the metadata's. A file is set to
  exactly the object's length first and held to it afterwards, which is
  how a file opened for appending shows: Linux puts its writes at its
  end, whatever the offset. An empty object is not read, and one stored
  gzip-compressed is fetched whole by one worker, as `download` fetches
  it, since Cloud Storage ignores a range while it decompresses.
  `DownloadResult` gains `crc32c`, the checksum of what a download wrote,
  on every download. `ParallelUploadOptions` gains `preconditions`: the
  object is read under them first, so a condition that already fails
  refuses the upload before a byte is sent; the upload finishes under a
  temporary name, `zig-gcp-tmp/` and random hex digits; and
  `objects.move` renames it into place only if they still hold. A refused
  move, or any failure after the finish, deletes the temporary object.
  Upload workers now record a cancel like any other failure: a
  `std.Io.Group` swallows the `Canceled` its task returns, and an `Io`
  that reported one without a cancel request would have let an upload go
  on to finish with a part missing. Breaking, for an exhaustive `switch`
  over `storage.Error`: it gains `InvalidParallelDownloadOptions`; and for
  code that builds a `DownloadResult` itself, which must now give a
  `crc32c`.
- examples: `gcs_cp --parallel N` works in both directions, and with
  `--no-clobber` for uploads.
- auth, core, pubsub, secret_manager: unchanged.

## 0.18.0 (2026-09-24)

- storage: parallel uploads, and copies that change what they carry: the
  two follow-ups the metadata spec named.
  `Object.uploadParallel(source, options)` sends one object in parts,
  `concurrency` at a time (8 by default), each on a client and connection
  of its own, through the XML API's multipart upload, and has Cloud
  Storage join them. That is Google's own advice over parallel composite
  uploads: the parts are never objects, so there is nothing to list,
  delete or leave behind. The source is bytes in memory or a file, read at
  each part's offset. Every part is checked against the CRC32C Cloud
  Storage stored for it. The parts' checksums combine into the whole
  object's, which is held to `options.crc32c` before anything is joined,
  and to the finished object afterwards. Every failure aborts the upload,
  so no part is left to be billed, and a cancel stops the workers and
  aborts too. It takes no preconditions, since the multipart upload has
  none. Against an emulator, which has no multipart uploads, the object
  goes up as one ordinary upload. From this sandbox, 100 MiB in 8 MiB
  parts, 8 at a time, went up 3.5 times as fast as one stream.
  `copyTo` can now change what the copy carries: the fixed fields, a
  `MetadataEdit`, and `storage_class`. Cloud Storage takes any metadata a
  copy sends as the whole of the copy's: measured, a rewrite naming only a
  storage class, the body Google's own samples send, came back with an
  empty content type and no custom metadata. So a changed copy reads its
  source first and sends everything back with the change applied, pinned
  to the generation and metageneration it read. Copying an object onto
  itself with a new class is how a class changes on demand.
  `Client.sibling` makes a client with the same settings for another
  task. `UploadOptions` gains `content_disposition` and
  `content_language`. Breaking, for an exhaustive `switch` over
  `storage.Error`: it gains `InvalidParallelUploadOptions`.
- core: `crc32c.combine` gives the CRC32C of two runs of bytes joined,
  from the CRC32C of each. zlib's version of it is wrong for CRC32C from
  512 MiB on, since CRC32C's table wraps at 31 and zlib's at 32. Held to
  std's own hashing of real zero runs up to 5 GiB. `rpc` gains
  `executeStreamBody`, a body streamed once and never replayed, and
  `StreamCall` gains `timeout_ms` and `decode_error`.
  `testing.FakeClock` keeps a cancel protection state.
- auth, pubsub, secret_manager: unchanged.

## 0.17.0 (2026-09-23)

- storage: metadata updates and compose, the next two items of the storage
  spec's list. `Object.updateMetadata(options)` patches what an object says
  about itself and leaves its bytes and its generation alone: the fixed
  fields, and `edit` for the custom metadata, which is `.keep`, `.change`
  (set the entries with a value, remove the entries with none, leave every
  key it does not name) or `.clear`. Those three are what Cloud Storage
  reads, and a JSON object has one `metadata` value, so `MetadataEdit` is a
  union rather than a set of fields that could ask for two at once.
  `MetadataChange.value` is optional, because the null that means "remove"
  has nowhere to live in `Metadata`. Nothing could change an object's
  metadata before this: `copyTo` sends `{}` as the destination resource,
  which is how a rewrite says "inherit", so even a copy carried the
  source's metadata exactly. `Object.composeFrom(sources, options)` writes
  an object from 1 to 32 others in the same bucket, server-side, with no
  bytes moving; the destination may be one of its own sources, so an append
  is a compose, and a larger join is repeated composes. `ObjectInfo` gains
  `cache_control`, `content_disposition`, `content_encoding` and
  `content_language`, which v1 could set on upload and never read back, and
  `component_count`, which only a composite carries. `Preconditions` gains
  `makesMetadataWriteSafe`: a patch never moves the generation, so
  `if_generation_match` says nothing about repeating one, while a patch
  that lost its answer has already moved the metageneration. A repeated
  custom metadata key is now refused on `upload` too, where it used to make
  a body carrying two entries of one name. Breaking, for an exhaustive
  `switch` over `storage.Error`: it gains `InvalidMetadataUpdate` and
  `InvalidComposeSources`. Held to Google's own answers against a real
  bucket, including three things no documentation states: a key a patch
  does not name survives it, `.clear` removes the lot, and a composite's
  component-derived CRC32C is the CRC32C of the whole, so a download
  verifies one through the path it already had.
- core: `transport.Method` gains `PATCH`.
- auth, pubsub, secret_manager: unchanged.

## 0.16.0 (2026-09-23)

- storage: POST policy documents, for uploads from a plain HTML form.
  `Object.postPolicy(signer, options)` and `Bucket.postPolicy` sign what a
  form may upload, stated in advance: the object name exactly, or any name
  under a prefix the browser completes through Google's `${filename}`;
  fields the form must send with these values, such as a `content-type`;
  `starts_with` conditions for fields whose value the browser chooses; and
  a `content_length_range` that bounds the body, which is the one
  condition a signed URL cannot express for a form. The result is where
  the form posts and the hidden inputs it carries; the caller adds `file`,
  last, holding bytes this library never sees. Path-style, virtual-hosted
  and bucket-bound-hostname URLs, on the client's endpoint, as for signed
  URLs, and signed through the same `core.Signer`, so a key file, IAM,
  impersonation and the metadata server all work with no new setup. Held
  byte for byte to Google's 11 POST policy conformance vectors, signatures
  included, and to 400 cases Google's Python library signed. Stricter than
  that library, which sorts the caller's fields, mutates the condition
  list it is given, and can print a sub-second expiry: this keeps the
  caller's order, takes `const` options, and truncates to the second. It
  refuses with `error.InvalidPostPolicyOptions` what that library would
  sign into a policy no form can satisfy: a field the policy sets itself,
  a field Cloud Storage never compares (`file`, `policy`,
  `x-goog-signature`) or ignores (`x-ignore-*`), a repeated field, two
  size ranges, a `success_action_status` other than 200, 201 or 204, and a
  control character anywhere, which a hidden input cannot carry. Breaking,
  for an exhaustive `switch` over `storage.Error`: it gains
  `InvalidPostPolicyOptions`. `examples/gcs_sign.zig --post-policy` prints
  a ready `<form>`. Against a real bucket, both ways of signing were held
  to what Google answers: a failed condition is 400 `InvalidPolicyDocument`
  whose `Details` quotes the condition, a body outside the size range is
  400 `EntityTooLarge` or `EntityTooSmall`, an expired policy is 400
  `InvalidPolicyDocument` where an expired URL is `ExpiredToken`, and a
  changed signature is 403 `SignatureDoesNotMatch` whose body carries the
  policy document Google read, which matched ours.
- auth, core, pubsub, secret_manager: unchanged.

## 0.15.0 (2026-09-22)

- storage: signed URLs. `Object.signedUrl(signer, options)` and
  `Bucket.signedUrl` make V4 signed URLs (`GOOG4-RSA-SHA256`): whoever
  holds one can make the one request it describes until it expires, with
  no credentials of their own, as a browser downloading a private object
  or uploading straight into a bucket does. GET, HEAD, PUT, DELETE, and a
  POST that starts a resumable upload. Signed headers pin what the holder
  must send, such as a content type, `x-goog-content-length-range` or
  `x-goog-if-generation-match: 0`; signed query parameters such as
  `response-content-disposition` too. Path-style, virtual-hosted and
  bucket-bound-hostname URLs, on the client's endpoint, so a client on the
  emulator makes URLs for it. Held byte for byte to Google's 29
  conformance vectors, signatures included, and to 400 cases Google's
  Python library signed. Stricter than Google's libraries, which merge,
  drop or sign what this refuses with `error.InvalidSignedUrlOptions`: an
  expiry outside 1 second to 7 days, a repeated header, a query parameter
  named like the signature's own, a newline in a header value, and an
  object name with a `.` or `..` segment, which browsers rewrite before
  sending. Breaking, for an exhaustive `switch` over `storage.Error`: it
  gains `InvalidSignedUrlOptions`, `SigningRejected` and `SigningFailed`.
  `examples/gcs_sign.zig` prints a URL and the `curl` line that uses it.
  Against a real bucket, both ways of signing were held to what Google
  answers: an expired URL is 400 `ExpiredToken`, one dated more than 15
  minutes ahead is 403 `AccessDenied`, a changed signature is 403
  `SignatureDoesNotMatch` whose body carries Google's own canonical
  request, and a signed `x-goog-content-sha256` must be sent as signed but
  is never checked against the body.
- auth: signers, for signed URLs. `ServiceAccount.signer()` signs with a
  key file's private key, on this machine. `IamSigner` signs through the
  IAM Credentials API's `signBlob` as any service account whose Token
  Creator role the token's principal holds, with delegates, retries, and
  one fresh token after a 401; Google rotates the keys it signs with and
  promises each for 12 hours, so a URL signed through IAM is refused
  beyond that. `ImpersonatedServiceAccount.signer()` signs as the target
  with the source credentials, as Google's Python, Node.js and Java
  libraries do, and `MetadataServer.signer()` as the attached account,
  whose email the new `MetadataServer.email()` reads. `Credentials.signer()`
  picks the right one for what `findDefault` found, or null for a user's
  own login or a workload identity federation file.
- core: `Signer`, the seam signing goes through, beside `TokenProvider`,
  and `testing.FakeSigner`.
- pubsub, secret_manager: unchanged.

## 0.14.1 (2026-09-22)

- pubsub: fixed: a `Subscriber` could keep a pulled batch's memory
  forever when handlers on different tasks finished messages of the same
  batch at the same moment. The count of messages still using a batch was
  a plain integer, decremented outside any lock, and a lost decrement
  meant the batch was never freed; it is atomic now. Also fixed: a
  `Subscriber` stopped just as it handed a batch to its workers could
  release one message twice and free the batch while earlier messages
  still pointed into it. Both date from the Subscriber's first release,
  0.7.0. The nightly fuzzing found the first once it could run the
  Subscriber at all, and tracing it found the second.
- core, auth, secret_manager, storage: unchanged.

## 0.14.0 (2026-09-22)

- storage: new module, stability `experimental`. A client for the Cloud
  Storage JSON API: buckets create, get, list and delete; objects get,
  exists, delete, and listing with prefixes, delimiters and paging;
  `upload` for bytes in memory and `downloadAlloc` for whole objects,
  checksummed both ways. An upload goes out as one `multipart/related`
  request whose metadata part carries the data's CRC-32C, so the server
  refuses a corrupted body before the object exists, and the data
  travels as a segment, never copied into the framing. A download
  streams into memory up to the caller's `max_bytes`, anything larger
  failing with `error.ObjectTooLarge` without being held, and the bytes
  are checked against `x-goog-hash`; an object decompressed in transit
  has nothing to check against and reports `checksum_verified = false`.
  Object names travel strictly percent-encoded, so names with slashes,
  spaces, `%` or non-ASCII address exactly the object they name, and the
  codec reads the API's quirks: `size` and generations as string
  integers (numbers too, for emulators), checksums in big-endian base64,
  `md5Hash` missing for composite objects. Against `fake-gcs-server` no
  credentials are needed: `Endpoint.fromEnv` honors
  `STORAGE_EMULATOR_HOST` in the three forms community tools write it.
  Uploads without a precondition, like deletes without a `generation`,
  are not retried unless `retry_unconditional_writes` opts in, because a
  blind repeat could overwrite or remove someone else's newer object.
  `download` streams an object, or
  a `range` of it, into any `std.Io.Writer`: the bytes are hashed as
  they pass and checked against `x-goog-hash` at the end, and a
  transient failure mid-body resumes where the bytes stopped, pinned to
  the generation the first response named, so an overwrite in between
  fails cleanly instead of splicing two objects; the attempt counter
  resets whenever a request delivers bytes. A resumed download is held
  to the checksum its first response named, because Cloud Storage names
  none on a range short of the whole object. A range read, and an object
  decompressed in transit, report `checksum_verified = false`, the
  latter because the stored checksum covers bytes that did not arrive,
  and it cannot resume either. A range past the end is
  `error.OutOfRange`, except at offset 0 on an empty object, which is
  simply zero bytes. `downloadAlloc` is the same download into the
  library's own capped buffer, resumes included.
- storage: `uploadFrom` streams an object of any size from a
  `std.Io.Reader` through the resumable protocol, holding one
  `chunk_size` buffer: the current chunk stays in memory until the
  server confirms it, so a resume never needs the reader to go
  backwards. `upload` above `single_request_limit` takes the same
  protocol with chunks sliced straight from the data and no buffer at
  all, and a lost session there simply starts over from the same bytes;
  for a reader the earlier bytes are gone, so a lost session is
  `error.UploadSessionLost` and the caller reopens the source. A 308's
  `Range` header is believed, not assumed: sending resumes at what the
  server kept, a failed chunk leads to a status query first, and the
  attempt counter resets whenever bytes land. The final answer is
  checked too: a server that calls the upload finished short of every
  byte, or before the stream has ended, has finished a truncated object,
  so the upload fails with `error.InvalidResponse` and the object is
  deleted again, pinned to its generation. With `options.crc32c` the
  server verifies the upload; without it `uploadFrom` hashes the stream
  and compares with the finished object, deleting it again, pinned to
  the generation just created, on a mismatch. A declared `options.size`
  polices the reader in both directions. The session URI is treated as
  the credential it is: never logged, never in `Diagnostics`, and
  requests to it carry no Authorization header.
- storage: `Preconditions` on gets, downloads, deletes, uploads and
  copies: generation and metageneration conditions, with
  `.does_not_exist` named because it is the most useful one, making an
  upload create-only and safe to retry. Retries follow the calls'
  idempotency: a write carrying `if_generation_match` is retried,
  because a repeat of one that already landed fails cleanly with 412
  instead of overwriting whatever is there by now, and a 412 on such a
  call says in the diagnostics that an earlier attempt may have
  succeeded. An `if...NotMatch` condition met by the current object is
  `error.NotModified`, an answer rather than a failure, never retried.
  `copyTo` copies server-side, looping over rewrite calls until done;
  the caller never sees a rewrite token, and only the tokenless first
  call needs a destination condition to be retried.
- storage: `examples/gcs_cp.zig` copies a file into Cloud Storage or an
  object out of it, streaming both ways and checksummed end to end, a
  download landing in `<file>.part` until its bytes have verified:
  `zig build example-gcs_cp -- backup.tar gs://my-bucket/backup.tar`. A
  1 GiB file each way stays under 16 MiB resident.
- core: `error.NotModified`, mapped from HTTP 304, for conditional
  reads whose condition was met: there is nothing new to return.
  Breaking for code that switches exhaustively over `pubsub.Error` or
  `secret_manager.Error`, which include core's API errors: add a prong
  for it. Neither module returns it.
- core: `testing.FaultTransport`, new: it wraps any `Transport` and
  breaks the requests a plan names the way a failing network does,
  cutting a request body or a streamed response body partway, or losing
  a response after the server acted on it, and it can record every
  exchange. Each fault reaches the caller as
  `error.ConnectionResetByPeer`. Around `HttpTransport` the connection
  really closes with the body unfinished, so a test proves recovery
  against a real server. A hook runs between the fault and the retry,
  where a test can change the world under a transfer that will resume.
- core: a streaming request can ask for the response head as soon as it
  arrives, through `head_out`, so a download that fails mid-body still
  knows the generation it was reading and can resume against it.
- core: fixed: streaming a response body larger than the connection's
  read buffer into an unbuffered caller writer tripped an assertion in
  std, because the readers in the chain need a writable destination.
  The transport now forwards the body through a small buffer of its
  own, so any writer works, and the request body writer gained the same
  protection for reader-backed uploads.
- examples: every example writes its standard output as a stream. Zig
  0.16's `File.writer` writes at an offset of its own, starting from 0,
  when standard output is a regular file, so output redirected into a
  file that something else also writes to landed on top of what came
  before it; `File.writerStreaming` writes where the file is, as a shell
  expects.
- auth, pubsub, secret_manager: unchanged, apart from `error.NotModified`
  joining their error sets through core.

## 0.13.1 (2026-09-21)

Version 0.13.0 was skipped: its tag landed one commit early, before the
release preparation, and v* tags are immutable here, so the same release
carries the next number. Do not fetch the v0.13.0 tag.

- core: the transport can stream, groundwork for the coming Cloud Storage
  module. `Transport` has a second, optional vtable entry, `sendStream`:
  a `StreamRequest` sends its body from back-to-back segments or from a
  `std.Io.Reader` with an exact Content-Length, and its 2xx response body
  either buffered as before or streamed into a `std.Io.Writer`, unbounded,
  with error bodies always buffered. Response headers, chunked framing,
  gzip and deflate, and the truncation checks all work as they do for
  `send`, which is now the same code path with the body as one segment.
  `accept_encoding` picks between plain bytes, for downloads that must
  match a checksum, and compressed JSON. Redirects are still never
  followed, so a resumable upload's 308 comes back untouched. Existing
  `Transport` implementations keep working: the new entry defaults to
  null, and only streaming callers need it.
- core: `crc32c.toBase64` and `crc32c.fromBase64`, the big-endian base64
  form Cloud Storage uses for checksums. `query.writeStrictSegment`
  percent-encodes a path segment with only unreserved bytes literal, the
  form an object name needs. `CountingWriter` counts bytes on their way
  to another writer. `errors.decodeErrorBody` now also reads the older
  error-body shape, taking the first error's `reason` as the status when
  there is no `status` string, and HTTP 412 and 416 map to
  `error.FailedPrecondition` and `error.OutOfRange`.
- core: `testing.FakeTransport` scripts streaming requests too: it
  records each body's prefix, length and CRC-32C however it was sent,
  writes canned success bodies into a sink writer, and can cut a
  streamed body short to play a dropped connection.
- pubsub, auth, secret_manager: unchanged in behavior; every request now
  goes through the streaming code path.

## 0.12.0 (2026-09-21)

- pubsub: `Publisher`, new: publishing from many tasks without a round
  trip per message. It takes messages from any task, batches them into
  publish requests, and sends those on tasks of its own over `concurrency`
  connections. A batch goes out when it is full, by message count or by
  bytes of request body as sent, or when its first message has waited
  `max_batch_delay_ms`, and until a connection is free it keeps filling.
  Each message gets a `Receipt` to wait on for its id. Transient failures
  are retried until `publish_timeout_ms` after the message was published.
  What it holds is capped, at 1,000 messages and 10,000,000 bytes by
  default; at a cap `publish` waits for room, or refuses with
  `error.PublisherFull` under `when_full = .fail`. `flush` sends
  everything at once and waits for what came before it. `run` sends until
  `stop`, which sends what is left first. With `enable_message_ordering`,
  a message may carry an ordering key: no request mixes keys, a key has
  one request in flight at a time, and a key whose batch fails for good
  pauses, failing what was queued behind it, until `resumePublish`. The
  new `examples/publisher.zig` shows it at work: from a laptop, 10,000
  messages from 8 tasks went to production in 102 requests and about a
  second.
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
