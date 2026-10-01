[Docs](../README.md) › [Cloud Storage](README.md) › The emulator

# The emulator is not production

The integration suite runs against
[`fake-gcs-server`](https://github.com/fsouza/fake-gcs-server), and a
second suite against a real bucket covers what the emulator cannot be
trusted on. The differences it found:

- It serves the XML API's paths, which signed URLs use, only when
  started with `-public-host` naming the host those URLs carry, and it
  never checks a signature. Its signed DELETE answers 200 where Cloud
  Storage answers 204, and its resumable start drops the object name
  from the path.
- The emulator enforces preconditions on uploads, but not on deletes,
  and never answers 304.
- It takes a resumable upload's status query for the final request, and
  finishes a truncated object. The client refuses that answer with
  `error.InvalidResponse` and deletes the object, so an interrupted
  upload, carried on in the same process or a later one, can only be
  tested against Google.
- It checks a declared CRC-32C on multipart uploads, not on resumable
  ones.
- It names the object's checksum on every range read; Cloud Storage
  names it only for a range that spans the whole object.
- It fills in whatever a copy's metadata leaves out from the source,
  where Cloud Storage leaves it out, and it ignores a copy's storage
  class. `copyTo` sends everything it means the copy to carry, so both
  agree on every field but the class.
- It has no multipart uploads at all, and no `objects.move`: it takes a
  move for an update of an object named
  `{source}/moveTo/o/{destination}`, and answers 404. So
  `uploadParallel` sends an ordinary upload to an emulator, with any
  conditions, and ignores a checkpoint, with a warning. The library's
  own tests run the multipart upload and the move against an in-memory
  fake and a loopback server that speak them.
- It does serve ranges pinned to a generation, and decompresses a
  gzip-stored object ignoring a range, as Cloud Storage does, so
  `downloadParallel` runs against it for real. To a client that takes
  gzip it serves a gzip object as stored, ranges and all, as Cloud
  Storage does, so gzip objects download verified against it too.
- It takes every bucket setting, checks none, and keeps none but
  versioning, which its filesystem backend refuses; a bucket update that
  leaves versioning out turns it off. So bucket settings are tested
  against an in-memory fake that holds Cloud Storage's rules as
  measured, and against Cloud Storage itself.
- Its memory backend keeps versions, which CI runs, pinned to 1.56.1,
  but a listing of versions in pages smaller than one name's versions
  repeats a page forever. It has no soft delete at all:
  `softDeleted=true` lists live objects, a restore is taken for an
  update of an object named `{name}/restore`, and bulk and bucket
  restores do not exist.
- It checks neither requester pays nor keys. It takes `userProject` and
  the `x-goog-user-project` header from anyone and bills no one. It
  takes a customer-supplied key, even a malformed one, stores the object
  without it, serves it back with no key or another, reports its
  checksums to every read, and never says it was keyed; it drops a
  Cloud KMS key's name. So both are tested against an in-memory fake
  that holds Cloud Storage's rules as measured, and against Cloud
  Storage itself.
- It keeps notification configurations and publishes their messages,
  but only to the Pub/Sub emulator named by `PUBSUB_EMULATOR_HOST` in
  its own environment. It checks no topic, grant or limit, answers a
  create with 201, and keeps no etag. Its messages carry no
  `notificationConfig`, a time to the second in its own zone, and a
  payload without a metageneration, and a compose over an existing
  object sends no event for the generation it replaced. `decodeEvent`
  reads them; production's own messages are what its unit tests hold it
  to.

[Integration tests](../development.md#integration-tests) says how to run
the emulator, and both suites.
