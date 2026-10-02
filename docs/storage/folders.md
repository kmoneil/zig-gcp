[Docs](../README.md) › [Cloud Storage](README.md) › Folders

# Folders and managed folders

A bucket created with `hierarchical_namespace` makes folders real: they
exist while empty, carry metagenerations, and a whole tree renames in one
atomic metadata change, objects included. Managed folders are a different
thing on any uniform-access bucket: prefixes that carry IAM policies of
their own, so one team reads `teams/data/` and no more. Everything on this
page was measured against Cloud Storage on 2026-10-02; where its
documentation says otherwise, what it *does* is noted.

## Hierarchical buckets

```zig
var made = try gcs.bucket("my-tree").create(.{ .hierarchical_namespace = true });
defer made.deinit();
```

The setting is create-time only. It needs uniform bucket-level access,
which the client sends along unless you said `false`, and it excludes
versioning, retention policies and object retention: each combination is
refused before sending, in the server's own words, because the server
itself refuses them. Nothing can turn it on later: a bucket update naming
it is answered 200 with the field silently dropped, so this library's
`BucketUpdate` cannot carry it at all.

`Bucket.storageLayout()` answers whether any bucket is hierarchical, with
only `storage.objects.list` permission:

```zig
var layout = try gcs.bucket("some-bucket").storageLayout();
defer layout.deinit();
if (layout.value.hierarchical_namespace) { ... }
```

## Folders

```zig
const b = gcs.bucket("my-tree");
var reports = try b.folder("reports/2026/").create(.{ .recursive = true });
defer reports.deinit();
try b.folder("reports/2026/").delete(.{ .if_metageneration_match = reports.value.metageneration });
```

- **Uploads create their parents.** Writing `reports/2026/q3.txt` creates
  `reports/` and `reports/2026/` if they are missing; compose and copies
  do the same. The folders stay when the object goes: nothing removes a
  folder but an explicit delete, and a delete needs it empty
  (`error.FolderNotEmpty` otherwise).
- **Names are paths with a trailing slash.** A missing slash is
  normalized, as the server itself normalizes. The whole path holds 512
  bytes, slashes included, and 50 levels. Cloud Storage accepts `./`,
  `../` and `/` as folder names verbatim, whatever its documentation says;
  this library refuses dot and empty segments before sending
  (`error.InvalidFolderName`), because nothing can address what they
  leave behind safely.
- **Every folder conflict is one 409.** The library reads the message and
  tells them apart: `error.AlreadyExists`, `error.ParentFolderMissing`,
  `error.FolderNotEmpty`, and `error.HierarchicalNamespaceRequired` for
  any folder call on a flat bucket.
- **Creates are not deduplicated.** The idempotency token other writes
  ride does nothing for folders, as measured, so a create whose answer
  was lost is read back rather than sent again; a repeated delete answers
  `error.NotFound`.
- **Listing** pages with `page_size` and `page_token`, filters under a
  `prefix` (which must end with `/`), bounds with `start_offset` and
  `end_offset`, and keeps to the prefix and one level below in
  `directory_mode`. `ListOptions.include_folders_as_prefixes` lists
  folders beside objects in `prefixes`, empty ones included, with the `/`
  delimiter Cloud Storage requires for it.

## Renames

```zig
var renamed = try b.folder("reports/").renameTo("archive/", .{
    .if_source_metageneration_match = reports.value.metageneration,
});
defer renamed.deinit();
```

A rename moves the folder, its child folders, its objects and its managed
folders in one atomic metadata change. `renameTo` starts the operation and
waits it out under the client's backoff: a small tree is done in the very
first answer, and 300 folders took under a second when measured.
`startRenameTo` returns the `OperationInfo` instead, for
`Bucket.operation(id)` to follow; a finished rename carries the
destination folder, which keeps its create time and metageneration.

- **While a rename runs**, writes under the source and the destination
  answer a retryable 429 whose message says to retry; this library's own
  retries wait it out, so an upload racing a rename simply lands after it.
- **The one precondition is `if_source_metageneration_match`.** Cloud
  Storage's reference page names `ifMetagenerationMatch` instead, and
  silently ignores it while the rename runs: this library never sends the
  ignored spelling.
- **A rename is never sent twice** (a repeat of one that landed is a 404
  for the gone source) **and cannot be canceled**; one that outlives the
  wait is `error.DeadlineExceeded`, with the operation id in
  `Diagnostics`. A destination folder that exists refuses at once; an
  object of the destination's name is no conflict, since objects and
  folders share names freely.

## Managed folders

```zig
const managed = gcs.bucket("any-uniform-bucket").managedFolder("teams/data/");
var made = try managed.create();
defer made.deinit();
var policy = try managed.addIamBinding("roles/storage.objectViewer", "user:ada@example.com");
defer policy.deinit();
```

A grant on a managed folder applies to every object under its prefix,
additively with the bucket's policy and every enclosing managed folder's:
what one grants, no inner one takes away. The five IAM calls are the ones
buckets have, with the same semantics: a concurrent change is
`error.Aborted` and a grant starts over on it.

- A bucket without uniform bucket-level access refuses every managed
  folder call with the same 412 a stale precondition gets, told apart only
  by its message, which `Diagnostics` keeps.
- A fresh policy has **no bindings at all** (nothing legacy), at etag
  `CAA=`; the etag is the policy's own and does not move with the bucket,
  unlike a bucket's, whose etag is its metageneration.
- Paths follow the folder rules plus Cloud Storage's own: 1,024 bytes, 15
  levels, no carriage return or line feed, and nothing under
  `.well-known/acme-challenge/`. A child may be created before its
  parents.
- Deleting one needs it empty of objects and child managed folders, or
  `allow_non_empty`, which needs the setIamPolicy permission. In a
  hierarchical bucket, creating a managed folder creates its folders too,
  and deleting it leaves them standing.
- `testIamPermissions` takes at most 84 permissions, none twice; a bucket
  permission is refused (production answers a bare "Invalid argument.").

The example ties it together:
`zig build example-gcs_folders -- grant my-bucket teams/data/ roles/storage.objectViewer user:ada@example.com`.

## The emulator has none of this

fake-gcs-server (1.56.1) serves only `storageLayout`, answering
`hierarchical_namespace == false` for every bucket, however it was
created; the folders and managed folders routes are plain 404s. The unit
tests run against this library's own fake instead, which models the
measured semantics; the integration suite pins what the emulator does.
