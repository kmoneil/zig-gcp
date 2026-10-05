[Docs](../README.md) › [Cloud Storage](README.md) › Access control lists

# Access control lists

A bucket without uniform bucket-level access decides who may read and
write through access control lists: the bucket's own, the default list
its new objects get, and each object's. Uniform access replaces all of
them with IAM, and Google recommends it; the lists are for buckets that
still need per-object grants.

**On this page:** [Reading a list](#reading-a-list) ·
[Changing a list](#changing-a-list) ·
[Canned lists](#canned-lists) ·
[What production does](#what-production-does) ·
[Refusals](#refusals)

## Reading a list

`Bucket.acl()`, `Bucket.defaultObjectAcl()` and `Object.acl()` hand out an
`AclList`, which sends nothing until called. `get` reads the whole list,
its owner, and the metageneration a guarded write takes; `entry` reads
one entry, `error.NotFound` when there is none. An object's list and
owner also come with its metadata when asked for:
`GetOptions.with_acl` and `ListOptions.with_acl`.

An entry is an `AclEntity` and an `AclRole`:

| `AclEntity` | Grants to |
| --- | --- |
| `.{ .user = email }` | A Google account or service account |
| `.{ .group = email }` | A Google group |
| `.{ .domain = domain }` | Every account of a Workspace or Cloud Identity domain |
| `.{ .project = .{ .team, .number } }` | A project's owners, editors or viewers, by the project's number |
| `.all_users`, `.all_authenticated_users` | Anyone, or anyone signed in to a Google account |
| `.{ .other = text }` | A form this library does not model, kept as the server sent it |

A bucket's list takes `.owner`, `.writer` and `.reader`; an object's and
a default object list take `.owner` and `.reader`. `storage.acl.parseEntity`,
`writeEntity` and `sameEntity` read, spell and compare entities as Cloud
Storage keeps them.

## Changing a list

<!-- snippet: tests/docs_examples.zig#storage-acl-grant -->
```zig
/// Lets a team's group read one report and takes a former colleague's
/// access away: each a read of the list, a change, and a write guarded by
/// what was read, run again when another change came in between.
fn shareReport(gcs: *storage.Client) !void {
    const acl = gcs.bucket("reports").object("2026/q3.pdf").acl();
    var shared = try acl.grant(.{ .group = "finance@example.com" }, .reader);
    defer shared.deinit();
    var revoked = try acl.revoke(.{ .user = "former@example.com" });
    defer revoked.deinit();
}
```

`grant` and `revoke` read the list, change it, and write it back whole
under the metageneration they read, and an object's under its generation
too, starting over when another change came in between, as
`addIamBinding` does. They are safe to retry. `set` replaces the whole
list, under an `AclGuard` when one is given; an empty list leaves the
owner alone.

Cloud Storage also has calls that change one entry at a time. This
library does not use them: as measured, they take no condition at all,
an idempotency token does not stop a repeat, and two at once on one
bucket answer 409. Nothing can make them safe to retry.

## Canned lists

Every write takes a `PredefinedAcl` in place of the bucket's default
object list: `upload`, `uploadFrom`, `uploadFile`, `uploadParallel`,
`copyTo`, `composeFrom` and `updateMetadata`. `Bucket.create` and
`Bucket.update` take a `PredefinedBucketAcl` and a default object list.
As measured, with W the account that wrote the object:

| `PredefinedAcl` | An object gets |
| --- | --- |
| `.private` | W OWNER |
| `.project_private` | W, project owners and editors OWNER; viewers READER |
| `.bucket_owner_full_control` | W and the project's owners OWNER |
| `.bucket_owner_read` | W OWNER, the project's owners READER |
| `.public_read` | W OWNER, `allUsers` READER |
| `.authenticated_read` | W OWNER, `allAuthenticatedUsers` READER |

A new bucket's list and default object list are `projectPrivate`. A copy,
a rewrite and a compose give the new object the bucket's default list
and the caller as owner, never the source's list.

## What production does

Measured on 2026-10-05, where it differs from what Google documents or
from what an emulator does:

- **The owner keeps OWNER.** Giving it less, or removing it, is 403
  "The owner of the resource is required to have OWNER access."; a whole
  list that leaves it out comes back with it. This library refuses both
  before sending, so a change that would never happen is not reported as
  done.
- **An empty list is ignored, not applied.** `set` with none sends the
  canned `private` instead.
- **Emails come back in lower case**, and a project named by ID is kept
  under its number, so `AclEntity.project` takes the number only.
- **Every single-entry write is an upsert**, a PATCH of an absent entity
  included, and moves the bucket's or object's metageneration.
- **A bucket takes about one change a second**, then answers 429.
  `grant`, `revoke` and a guarded `set` wait it out under the retry
  policy; an unguarded `set` is sent once.
- **A bucket's list shows in its IAM policy** as legacy bindings, and a
  change to it moves the policy's etag.
- **At most 100 entries**, judged before anything else in a list.
- fake-gcs-server keeps only `publicRead` as asked; every other list, or
  none, is an entity production never uses, `projectOwner-test-project`.

## Refusals

| Error | When |
| --- | --- |
| `error.UniformAccessEnabled` | Any list, or canned list, on a bucket with uniform bucket-level access: 400, in one of five wordings, each naming it |
| `error.PublicAccessPrevented` | A grant to `allUsers` or `allAuthenticatedUsers` under public access prevention, by list, canned list or IAM: 412, the reason a failed precondition has, told apart by its words |
| `error.Aborted` | A guarded `set` whose bucket or object changed since its list was read |
| `error.InvalidArgument` | Refused before sending: the owner given less than OWNER or removed, a role the list does not take, a project named by ID, an entity twice, more than 100 entries; or an unknown principal, in Cloud Storage's words |
