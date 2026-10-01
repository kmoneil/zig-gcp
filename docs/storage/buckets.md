[Docs](../README.md) › [Cloud Storage](README.md) › Buckets

# Buckets

**On this page:** [Bucket settings](#bucket-settings) ·
[Versions and soft delete](#versions-and-soft-delete) ·
[Retention and holds](#retention-and-holds) ·
[Requester pays](#requester-pays)

## Bucket settings

`create` takes a bucket's settings, and `update` changes them later,
sending only what it names:

```zig
const archive = gcs.bucket("my-archive");
var created = try archive.create(.{
    .location = "europe-west3",
    .versioning = true,
    .soft_delete_retention_s = 0, // off; see below
    .labels = &.{.{ .key = "team", .value = "data" }},
    .lifecycle = &.{
        .{ .action = .{ .set_storage_class = "COLDLINE" }, .condition = .{ .age_days = 90 } },
        .{ .action = .delete, .condition = .{ .is_live = false, .num_newer_versions = 3 } },
    },
    .uniform_bucket_level_access = true,
    .public_access_prevention = .enforced,
});
defer created.deinit();

var changed = try archive.update(.{
    .labels = .{ .change = &.{
        .{ .key = "team", .value = "platform" },
        .{ .key = "draft", .value = null }, // null removes the label
    } },
    // Safe to retry: a repeat of an update that landed fails instead.
    .if_metageneration_match = created.value.metageneration,
});
defer changed.deinit();
```

| Setting | What it does | In an update |
| --- | --- | --- |
| `versioning` | Keeps every version an overwrite or a delete replaces | On or off |
| `soft_delete_retention_s` | How long a deleted object stays restorable: 0 (off), or 604,800 to 7,776,000 s (7 to 90 days) | The same |
| `requester_pays` | Bills requests to the requester's project | On or off |
| `default_kms_key_name` | The Cloud KMS key for objects written without one | `.set` or `.clear` |
| `labels` | At most 64 | `.change` merges, `.clear` removes every label |
| `lifecycle` | Rules Cloud Storage applies about once a day | Replaces every rule; `&.{}` removes them all |
| `uniform_bucket_level_access` | IAM alone decides access, never object ACLs | Off again only within its first 90 days |
| `public_access_prevention` | `.enforced` refuses grants to `allUsers` | `.inherited` or `.enforced` |
| `storage_class` | The class of objects written without one | The same |

A setting an update leaves out keeps its value, and one it names is
replaced alone: changing public access prevention leaves uniform access
as it was. Every value Cloud Storage refuses is refused before sending,
with `error.InvalidBucketSettings` and the reason in `Diagnostics`, as
is an update that changes nothing, since the emulator checks none of
them. Only the server judges two things: how many labels a bucket holds
after an edit, and letters beyond ASCII in labels, which it takes unless
they are uppercase. A bucket takes about one update a second.

> [!NOTE]
> Every new bucket has soft delete on unless its settings say otherwise:
> deleted objects stay restorable, and billed as stored, for 7 days, or
> what the organization's default says.

<details>
<summary><b>📏 Measured against Cloud Storage on 2026-09-29</b></summary>

- A bucket that ever had soft delete on is soft-deleted itself when it
  is deleted, and kept, empty and unbilled, for the longest retention it
  ever had: turning soft delete off first does not shorten that. A
  bucket created with a retention of 0 is deleted outright.
- Some libraries turn soft delete off with `"softDeletePolicy": null`,
  which puts the 7-day default back instead. This one sends a retention
  of 0.
- `"labels": {}` removes every label, as `.clear` does, so an empty
  `.change` sends no labels at all.
- The documented limit of 100 lifecycle rules is not enforced: 2,000
  were taken. The 1,000 prefixes and suffixes across the rules are.
- A stale `if_metageneration_match` is `error.FailedPrecondition`, and
  an `if_metageneration_not_match` equal to the bucket's metageneration
  is `error.NotModified`: the update changes nothing. An `If-Match` etag
  is ignored.
- Lifecycle dates before 1677-09-21 or after 2262-04-11 are kept as
  those dates.

</details>

A lifecycle rule read from a bucket that carries an action or a
condition this library does not know, such as the early-access
`matchesPattern`, comes back with `unrecognized` set, and an update that
sends it back is refused: without the part this library could not read,
the rule would act on objects it now leaves alone. Leave it out of the
list, which removes it, or change the rules with gcloud.

## Versions and soft delete

A bucket with `versioning` keeps every generation an overwrite or a
delete replaces, as a noncurrent version. One with soft delete keeps
what is deleted restorable, and billed, for its retention, and so do the
buckets themselves.

```zig
// Every version; the noncurrent ones carry the time they stopped being live.
var versions = try bucket.listObjects(.{ .versions = true, .prefix = "reports/" });
defer versions.deinit();

// An older version back as the live one: a copy onto its own name.
const q3 = bucket.object("reports/q3.csv");
var back = try q3.copyTo(q3, .{ .source_generation = older_generation });
defer back.deinit();

// What soft delete keeps, and one of them restored.
var deleted = try bucket.listObjects(.{ .soft_deleted = true, .match_glob = "reports/**" });
defer deleted.deinit();
var restored = try q3.restore(.{
    .generation = deleted.value.objects[0].generation,
    .preconditions = .does_not_exist, // where nothing live has the name; safe to retry
});
defer restored.deinit();
```

`bulkRestore` restores the newest soft-deleted generation of every name
that matches, as a long-running operation that `operation`,
`cancelOperation` and `listOperations` follow. `listSoftDeletedBuckets`
lists deleted buckets with the generation `Bucket.restore` takes.

<details>
<summary><b>📏 Measured against Cloud Storage on 2026-09-29</b></summary>

- A restore makes a new generation, with the soft-deleted one's
  metadata, custom time and storage class, and leaves the soft-deleted
  one where it is. Each restore of it makes another copy, and the copy
  it replaces goes into soft delete. The idempotency token Google
  recommends does not stop a repeat, so `restore` is retried only under
  `if_generation_match`, as `.does_not_exist` is.
- Under `.does_not_exist`, a restore over a live object is
  `error.FailedPrecondition`. A live generation, or one never
  soft-deleted, is `error.NotFound`. A bucket without soft delete
  refuses restores and soft-deleted listings with
  `error.InvalidArgument`.
- A soft-deleted object's metadata reads only by its generation, and its
  bytes not at all.
- A bulk restore took three minutes to restore three objects, and
  reported counts but never a percentage. A bucket runs one at a time:
  another start meanwhile is `error.ResourceExhausted`, and the bucket
  cannot be deleted until it ends. A start repeated with the same token
  gets the same operation, so `bulkRestore` retries with one token per
  call. A cancel ends one with `failure.code` 1, and a finished one
  cannot be cancelled.
- A restored bucket comes back with its settings and none of its
  objects, which stay soft-deleted and restorable. While another bucket
  has the name, the restore is `error.AlreadyExists`, and a repeat of
  one that landed is `error.NotFound`.
- `versions` and `soft_deleted` cannot be listed together. A listing of
  versions with a delimiter still groups a folder whose every object is
  noncurrent.

</details>

## Retention and holds

Cloud Storage can refuse to let an object go. A bucket's retention
policy keeps every object for a period after its creation; a hold keeps
one object until it is released; and an object's own retention, in a
bucket created to allow it, keeps it until a time. A write that would
delete, replace or move a kept object is `error.ObjectRetained`, with
Cloud Storage's words, and the time where there is one, in
`Diagnostics`. Its metadata stays editable.

```zig
// A bucket that keeps every object a day, and holds new ones until released.
var ledger = try gcs.bucket("my-ledger").create(.{
    .retention_period_s = 86_400,
    .default_event_based_hold = true,
});
defer ledger.deinit();

// Held as it is written; released when the event happens, and the day starts then.
const entry = gcs.bucket("my-ledger").object("2026/09/30.csv");
var stored = try entry.upload(data, .{ .temporary_hold = true });
defer stored.deinit();
var released = try entry.updateMetadata(.{ .temporary_hold = false, .event_based_hold = false });
defer released.deinit();

// Permanent: the policy may grow, never shrink or go.
var locked = try gcs.bucket("my-ledger").lockRetentionPolicy(ledger.value.metageneration);
defer locked.deinit();
```

> [!WARNING]
> **Locking is permanent**, and so is a bucket created with
> `object_retention`. Cloud Storage places a lien on the project, which
> keeps it from being deleted until an owner removes the lien; deleting
> the bucket did not remove it when measured. A locked policy may be
> lengthened; shortening or removing it is `error.PermissionDenied`.

- **An object's own retention** (`UploadOptions.retention`, and on
  compose, copy and `updateMetadata`) extends freely. Shortening,
  removing or locking an unlocked one takes
  `MetadataUpdate.override_unlocked_retention`; a locked one only
  extends. Otherwise the change is `error.PermissionDenied`. It cannot
  go beside an event-based hold.
- **Copies** never carry their source's holds or retention: a copy names
  its own, which makes it a changed copy.
- **A resumable upload over a kept object** sends every byte before its
  last request is refused. Nothing is checked first, which would cost a
  read per upload.
- **Parallel uploads with conditions** into a bucket that keeps every
  new object, by a policy or a default hold, go up as one ordinary
  upload, and the log says so: there, the temporary object they finish
  under could never be moved or deleted. Telling takes
  `storage.buckets.get`; without it the upload goes up in parts, and its
  temporary object can be stranded, and billed, for the whole period, as
  `Diagnostics` then says.
- **The cleanup of a failed upload**, a checksum mismatch or a truncated
  object, cannot delete a kept object, and `Diagnostics` says it stays.

<details>
<summary><b>📏 Measured against Cloud Storage on 2026-09-30</b></summary>

- A retained object's refusals are 403 `retentionPolicyNotMet`. A held
  one's are 403 `forbidden`, the reason a missing permission has, told
  apart only by the message: never the documented
  `objectUnderActiveHold`. The XML API names both, at the finish of a
  multipart upload whose parts it took.
- A condition is checked before retention: 412 comes first.
- A policy's period runs from 1 to 3,155,760,000 seconds, and covers the
  objects already there. Its removal took over three seconds to stop
  refusing once. With versioning on, a retained live object can still
  be made noncurrent, and a noncurrent one cannot be deleted.
- Releasing an event-based hold starts the policy's period over; its
  `retention_expiration_time` is absent while held.
- A lock repeated after a lost answer is refused 400, as if there were
  no policy, so `lockRetentionPolicy` reads the bucket back and answers
  a locked one as locked. A 60-second locked policy is enforced.
- Object retention can only be turned on at create: a later patch is
  taken and ignored.

</details>

## Requester pays

A bucket with `requester_pays` on bills each request to the project the
request names. Its owners may name none, and their requests bill the
bucket's project as before; anyone else who names none is refused.
`withBillingProject` gives a handle whose every request names one:

```zig
const dataset = gcs.bucket("their-dataset").withBillingProject("my-project");
var page = try dataset.listObjects(.{ .prefix = "2026/" });
defer page.deinit();
var got = try dataset.object("2026/01.csv").downloadAlloc(64 << 20, .{});
defer got.deinit();
```

`examples/gcs_cp.zig --billing-project my-project` does the same for a
copy either way.

The principal needs `serviceusage.services.use` on the project it bills,
which Service Usage Consumer grants. The project goes into every request
a call makes:

- on the JSON API, the `userProject` parameter and the
  `x-goog-user-project` header, one value in both;
- the header on every request of a parallel upload through the XML API;
- each call of a copy;
- the start of a resumable upload, whose session URL carries it on;
- a signed URL's signed query.

An object handle from a billed bucket handle is billed too. `copyTo`
bills the source handle's project, or the destination's when the source
names none. A checkpoint of a parallel upload records the project, so
`abandonTransfer` bills it as well. `create` bills nothing, since there
is no bucket yet. A POST policy on a billed handle is refused with
`error.InvalidPostPolicyOptions`, since no form can name a project.

<details>
<summary><b>📏 Measured against Cloud Storage on 2026-09-29, with a throwaway account on a throwaway bucket</b></summary>

- Anyone but the owners who names no project gets
  `error.InvalidArgument`, and `Diagnostics` says to name one with
  `withBillingProject`. A project the principal may not bill is
  `error.PermissionDenied`. A project that does not exist is
  `error.InvalidArgument`, even for an owner.
- Where the parameter and the header name different projects, the
  parameter counts. This library always sends one project in both.
- A signed URL is used as its signer, so the signer's account must be
  allowed to bill the project. A URL that names none is refused when
  used, 400 `UserProjectMissing`, and so is one naming a project that
  does not exist, 400 `UserProjectInvalid`.
- A form cannot name a project. A policy with an `x-goog-user-project`
  field is refused, and a query on the form's URL makes the POST a
  bucket create, which is refused too.

</details>
