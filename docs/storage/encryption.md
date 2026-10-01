[Docs](../README.md) › [Cloud Storage](README.md) › Encryption keys

# Encryption keys

Cloud Storage encrypts every object, with Google's own key unless a
write names another: a customer-supplied key, which the caller holds and
Cloud Storage never keeps, or a Cloud KMS key, which Cloud KMS holds.

**On this page:** [Customer-supplied keys](#customer-supplied-keys) ·
[Cloud KMS keys](#cloud-kms-keys)

## Customer-supplied keys

A customer-supplied key is 32 random bytes, usually kept as 44
characters of base64:

```zig
var key = try storage.EncryptionKey.fromBase64(key_text);
defer key.wipe();
const ledger = gcs.bucket("my-bucket").object("ledger.csv").withEncryptionKey(&key);
var stored = try ledger.upload(data, .{ .preconditions = .does_not_exist });
defer stored.deinit();
var back = try ledger.downloadAlloc(64 << 20, .{});
defer back.deinit();
```

> [!WARNING]
> Cloud Storage keeps only the key's SHA-256, which
> `ObjectInfo.encryption_key_sha256` reports and `EncryptionKey.sha256`
> computes, so an object whose key is lost cannot be read by anyone.

The handle borrows the key, and carries it on each request that reads
or writes the object's data:

- a download, each range and resume of it, and `downloadParallel`;
- `upload`, and the start of a resumable upload, the one request whose
  key counts: its chunks carry none, since Cloud Storage ignores a key
  there, even a wrong one;
- the start, every part and the finish of `uploadParallel`;
- `get` and `updateMetadata`, whose answers otherwise leave out `crc32c`
  and `md5`;
- `copyTo`: the source handle's key for the source, the destination
  handle's for the copy. A key is rotated by copying an object onto
  itself under the new one;
- `composeFrom`, where the destination's key must decrypt every source;
- a signed URL, which signs the key's three headers in, so whoever holds
  the URL must send them.

`exists`, `delete`, `restore` and listings carry none, since none needs
it. A listing reports no checksum for an object under a key of either
kind. A POST policy on a keyed handle is refused with
`error.InvalidPostPolicyOptions`, since a form cannot send the headers.

A read without the key, or with another, is `error.InvalidArgument`,
and so is a key sent for an object stored without one. Without a key,
`Diagnostics` says to give one with `withEncryptionKey`. The key never
reaches a log, `Diagnostics` or a checkpoint, which records only its
SHA-256, and the headers built from it live on the call's stack and are
wiped when it returns. One copy stays where this library cannot reach
it: as with the bearer token, std's HTTP client writes the request head
into the connection's buffer, where it stays until the next request
overwrites it. A checkpointed upload resumed under another key, or none,
starts over, since Cloud Storage encrypts with the key the upload began
under.

## Cloud KMS keys

A Cloud KMS key is named per write, with `kms_key_name` on
`UploadOptions`, `ParallelUploadOptions`, `CopyOptions` and
`ComposeOptions`, or for a whole bucket, with
`BucketConfig.default_kms_key_name` or `Bucket.update`:

```zig
var agent = try gcs.serviceAgent();
defer agent.deinit();
// Grant agent.value roles/cloudkms.cryptoKeyEncrypterDecrypter on the key, once.
var info = try gcs.bucket("my-bucket").object("report.pdf").upload(pdf, .{
    .kms_key_name = "projects/my-project/locations/us-central1/keyRings/my-ring/cryptoKeys/my-key",
});
defer info.deinit();
```

The key must be in the bucket's location, and the project's Cloud
Storage service agent, which `Client.serviceAgent` names, must hold
`roles/cloudkms.cryptoKeyEncrypterDecrypter` on it.
`ObjectInfo.kms_key_name` names the key's version, and a write may be
given that back as it is: the version goes before sending, since Cloud
Storage refuses one. A name that is not a key's, and a customer key and
a KMS key on one write, are refused before sending with
`error.InvalidArgument`.

`examples/gcs_cp.zig --encryption-key-file ledger.key` copies either way
under a customer-supplied key, read from a file of its 44 characters of
base64 and never from the command line, where shell history and the
process list would keep it; `--kms-key NAME` uploads under a Cloud KMS
key.

<details>
<summary><b>📏 Measured against Cloud Storage on 2026-09-30, with throwaway buckets and a software key</b></summary>

- Without the grant, or with a key that does not exist, a write is
  `error.PermissionDenied`, and `Diagnostics` says what to grant to
  whom.
- A copy that names no key gets the destination bucket's default key,
  else Google's own: never the source's.
- A bucket's new default key reached new uploads within seconds, after
  4.4 s in one run and 0.3 s in another; clearing it acted at once.
- A signed URL for an object under a customer-supplied key, used without
  the key's headers, is refused with 400 `MalformedSecurityHeader`.
- A parallel upload's finish names no checksum under a key of either
  kind, and a create-only one's move names none under a customer key, so
  both are held to what was sent by reading the object back.
- `restore` and `objects.move` need no key, and ignore one.

</details>
