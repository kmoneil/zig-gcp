[Docs](../README.md) › Cloud Storage

# 🪣 Cloud Storage

A client for the Cloud Storage JSON API. Objects of any size stream both
ways in constant memory, pick up where they stopped after a dropped
connection, or with a checkpoint after the process itself ended, and are
checked against the CRC-32C Cloud Storage keeps for every object.

```zig
const std = @import("std");
const auth = @import("auth");
const storage = @import("storage");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    var creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    defer creds.deinit();

    var gcs = try storage.Client.init(init.gpa, init.io, .{
        .token_provider = creds.provider(),
    });
    defer gcs.deinit();
    const report = gcs.bucket("my-bucket").object("reports/2026/q3.txt");

    // Bytes in memory go up in one request whose metadata carries their
    // CRC-32C, so a body changed on the way is refused, never stored.
    var info = try report.upload("hello world\n", .{
        .content_type = "text/plain",
        .preconditions = .does_not_exist, // create-only, and safe to retry
    });
    defer info.deinit();

    // And come back verified, up to a cap.
    var copy = try report.downloadAlloc(1024 * 1024, .{});
    defer copy.deinit();
    std.log.info("generation {d}: {s}", .{ copy.value.result.generation, copy.value.data });
}
```

Against the `fake-gcs-server` emulator, pass
`.endpoint = storage.Endpoint.fromEnv(init.environ_map)`, which honors
`STORAGE_EMULATOR_HOST`, and no credentials: the emulator speaks plain
HTTP and never receives a token. [The emulator](emulator.md) lists where
it differs from Cloud Storage.

| Guide | What's in it |
| --- | --- |
| [Transfers](transfers.md) | Files and streams of any size, parallel uploads and downloads, and transfers that outlive the process |
| [Checksums and compression](checksums-and-compression.md) | CRC-32C in both directions, objects stored gzip-compressed, and compressing on upload |
| [Writing objects](writing-objects.md) | Preconditions and retries, metadata after the upload, compose, and copies that change what they carry |
| [Signed URLs and POST policies](signed-urls.md) | One request, or one kind of browser upload, without credentials |
| [Buckets](buckets.md) | Settings and lifecycle rules, versions and soft delete, retention and holds, requester pays, IAM |
| [Encryption keys](encryption.md) | Customer-supplied keys and Cloud KMS keys |
| [Notifications](notifications.md) | A Pub/Sub message for every change to a bucket's objects, decoded |
| [The emulator](emulator.md) | What fake-gcs-server does differently, and how the tests cover it |

## What it covers

| Call | What it does | Guide |
| --- | --- | --- |
| `client.bucket(name).create(config)`, `.get()`, `.update(changes)`, `.delete()` | A bucket and its settings, in the project `Options.project_id` names | [Buckets](buckets.md#bucket-settings) |
| `client.listBuckets(page)` | One page of the project's buckets | |
| `bucket.listObjects(options)` | One page of objects, with `prefix`, a `delimiter` for folders, a `match_glob`, and paging: live ones, every version, or the soft-deleted ones | [Versions](buckets.md#versions-and-soft-delete) |
| `bucket.object(name).get(options)`, `.exists()`, `.delete(options)` | An object's metadata, whether it exists, and deleting it or one generation of it | |
| `.upload(data, options)`, `.uploadFrom(reader, options)` | Bytes in memory, or any reader | [Transfers](transfers.md#files-of-any-size) |
| `.uploadFile(file, options)` | A file, read at offsets, resumable in a later process with `options.checkpoint` | [Transfers](transfers.md#transfers-that-outlive-the-process) |
| `.uploadParallel(source, options)`, `.downloadParallel(destination, options)` | One object in parts or ranges, several at once | [Parallel uploads](transfers.md#parallel-uploads), [downloads](transfers.md#parallel-downloads) |
| `client.abandonTransfer(checkpoint)` | Drops what a checkpoint's unfinished transfer left on the server | [Transfers](transfers.md#transfers-that-outlive-the-process) |
| `.download(writer, options)`, `.downloadAlloc(max_bytes, options)` | Into any writer, or into memory up to a cap | [Checksums](checksums-and-compression.md#checksums) |
| `.copyTo(dest, options)` | A server-side copy, across buckets too | [Copies](writing-objects.md#copies-that-change-what-they-carry) |
| `.updateMetadata(options)` | Changes what an object says about itself, leaving its bytes alone | [Metadata](writing-objects.md#metadata-after-the-upload) |
| `.restore(options)` | Brings back a soft-deleted generation as the live one | [Soft delete](buckets.md#versions-and-soft-delete) |
| `bucket.bulkRestore(options)`, `.operation(id)`, `.cancelOperation(id)`, `.listOperations(page)` | Restores many soft-deleted objects at once, and follows the operation doing it | [Soft delete](buckets.md#versions-and-soft-delete) |
| `client.listSoftDeletedBuckets(page)`, `bucket.restore(generation)` | Deleted buckets, and one brought back | [Soft delete](buckets.md#versions-and-soft-delete) |
| `.composeFrom(sources, options)` | Writes this object from up to 32 others in the bucket, server-side | [Compose](writing-objects.md#compose) |
| `bucket.lockRetentionPolicy(metageneration)` | Makes a bucket's retention policy permanent | [Retention](buckets.md#retention-and-holds) |
| `.signedUrl(signer, options)`, `bucket.signedUrl(signer, options)` | A V4 signed URL, which lets whoever holds it make one request without credentials until it expires | [Signed URLs](signed-urls.md#signed-urls) |
| `.postPolicy(signer, options)`, `bucket.postPolicy(signer, options)` | A V4 POST policy, which lets a plain HTML form upload what the policy allows, without credentials, until it expires | [POST policies](signed-urls.md#post-policies-uploads-from-a-plain-html-form) |
| `.withBillingProject(project)`, `bucket.withBillingProject(project)` | A handle whose every request bills `project`, as a requester pays bucket needs | [Requester pays](buckets.md#requester-pays) |
| `.withEncryptionKey(&key)` | A handle for an object under a customer-supplied key | [Encryption keys](encryption.md) |
| `bucket.createNotification(config)`, `.getNotification(id)`, `.listNotifications()`, `.deleteNotification(id)` | Pub/Sub messages for every change to the bucket's objects | [Notifications](notifications.md) |
| `storage.decodeEvent(gpa, message, options)` | One of those messages, as a `pubsub.Subscriber` receives it, read into an `ObjectEvent` | [Notifications](notifications.md) |
| `client.serviceAgent()` | The account a Cloud KMS key, or a notification's topic, must be granted to | [Encryption keys](encryption.md#cloud-kms-keys) |
| `bucket.iamPolicy()`, `.setIamPolicy(policy)`, `.addIamBinding(role, member)`, `.removeIamBinding(role, member)`, `.testIamPermissions(permissions)` | Who may do what with the bucket and its objects | [IAM](buckets.md#iam) |

The default OAuth scope is `devstorage.read_write`; `Options.scope`
picks `.read_only`, `.full_control` (which a bucket's IAM policy needs)
or `.cloud_platform` instead. Not in this version:
the JSON API's PUT, which replaces a whole resource (`updateMetadata`
and `Bucket.update` patch, which merges), parallel composite uploads,
and gRPC.

The examples put it to work:
[`examples/gcs_cp.zig`](../../examples/gcs_cp.zig) copies files up and
down, in parallel, resumably, compressed and under keys;
[`examples/gcs_sign.zig`](../../examples/gcs_sign.zig) signs URLs and
POST policy forms; and
[`examples/gcs_notify.zig`](../../examples/gcs_notify.zig) sets up a
bucket's notifications and watches them arrive.
