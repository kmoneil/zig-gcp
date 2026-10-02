[Docs](README.md) › Secret Manager

# 🔑 Secret Manager

A client for the Secret Manager v1 REST API. The call most applications
want is `access`: it fetches the bytes of a secret version, verifies the
CRC-32C stored beside them, and hands them over in memory that is wiped
when it is released.

```zig
const std = @import("std");
const auth = @import("auth");
const secret_manager = @import("secret_manager");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    var creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    defer creds.deinit();

    // There is no emulator and no unauthenticated mode: credentials are
    // a required option, not an optional one.
    var secrets = try secret_manager.Client.init(init.gpa, init.io, .{
        .project_id = "my-project",
        .token_provider = creds.provider(),
    });
    defer secrets.deinit();

    var password = try secrets.secret("db-password").access(.latest);
    defer password.deinit(); // wipes the bytes
    std.log.info("using {s}", .{password.version_name});

    try db.connect(.{ .user = "app", .password = password.bytes() });
}
```

> [!TIP]
> Read secrets at startup, or on a timer, rather than on every request:
> access calls are quota-limited and billed per call. The library never
> keeps a secret after the call returns, so caching is the application's
> to decide.

[`examples/secret.zig`](../examples/secret.zig) is the whole of the
above as a program: `zig build example-secret -- db-password latest`.

**On this page:** [The bytes](#the-bytes) ·
[What it covers](#what-it-covers) ·
[Changing a secret](#changing-a-secret) ·
[Preconditions](#preconditions) · [Aliases](#aliases) ·
[Expiry and delayed destruction](#expiry-and-delayed-destruction) ·
[Notifications and rotation](#notifications-and-rotation) ·
[Checksums](#checksums) · [Regional secrets](#regional-secrets) ·
[IAM](#iam)

## The bytes

`access` returns a `SecretValue`, not an `Owned(T)`, because the result
needs more care than other results do.

- Everything the call touched lives in one arena over
  `core.WipingAllocator`: the response body, which carries the secret in
  base64, the JSON parser's scratch space, the decoded bytes, and the
  bearer token the request was made with. `deinit` zeroes all of it.
- `value.bytes()` reads the secret. There is no `data` field on purpose:
  `{}` and `{any}` print a struct's fields whatever its `format` method
  says, so the bytes are held as a pointer and a length. Printing a
  `SecretValue` any way at all gives `[REDACTED]`.
- Nothing about a secret is logged: not the bytes, not their length, not
  their checksum. Sizes and timings are logged for other things; here
  the length of a password is information too.
- The bytes are never altered. A secret written with `echo` ends in a
  newline, and it is still there; trim it with `std.mem.trimRight` if
  you want it gone.
- Pass a `SecretValue` by pointer. A copy that is also `deinit`ed frees
  the same memory twice.

> [!NOTE]
> Wiping is not a guarantee against swap, a core dump or a debugger, and
> the HTTP and TLS layers have buffers of their own that this library
> cannot reach. It narrows the window in which a later bug can find the
> secret. [SECURITY.md](../SECURITY.md#secret-bytes) lists what holds it
> to that, test by test.

## What it covers

| Call | What it does |
| --- | --- |
| `client.secret(id).access(ref)` | The bytes of a version: `.latest`, `.{ .number = 3 }` or `.{ .alias = "prod" }` |
| `.addVersion(bytes)` | Stores a new version, with a CRC-32C the server checks |
| `.create(config)`, `.get()`, `.delete()` | The secret itself: replication, labels, annotations, expiry, a destruction delay, topics and a rotation, then metadata, then gone |
| `.update(changes)` | Labels, annotations, aliases, expiry, the destruction delay, topics and the rotation, each set or cleared: [Changing a secret](#changing-a-secret) |
| `.deleteIf(etag)` | Deletes only if nothing changed since the read: [Preconditions](#preconditions) |
| `client.listSecrets(options)` | One page of secrets, with `filter`, `page_size` and `page_token` |
| `.listVersions(options)` | One page of versions, newest first |
| `.version(ref).get()` | A version's state, times and etag |
| `.version(.{ .number = n }).enable()`, `.disable()`, `.destroy()` | Change what a version serves |
| `.enableIf(etag)`, `.disableIf(etag)`, `.destroyIf(etag)` | The same, only if the version is as read |
| `client.serviceAgent()` | The account that publishes a secret's events: [Notifications and rotation](#notifications-and-rotation) |
| `secret_manager.decodeEvent(gpa, message, .{})` | A message from a secret's topic, as a `SecretEvent` |
| `.iamPolicy()`, `.setIamPolicy(policy)`, `.addIamBinding(role, member)`, `.removeIamBinding(role, member)`, `.testIamPermissions(permissions)` | Who may read the secret's bytes, or manage it: [IAM](#iam) |

`enable`, `disable` and `destroy` take a version number and refuse
`.latest` and aliases with `error.ExplicitVersionRequired`: "whatever is
latest right now" is the wrong target for a change that lasts.
Production refuses `latest` and aliases for those three as well.
Enabling and disabling are idempotent; destroying is not, and a second
destroy answers `error.FailedPrecondition`, which means the first one
worked.

Not in this version: customer-managed encryption keys.

## Changing a secret

`update` changes any of a secret's settings and answers the secret as it
then is. Every field of `SecretUpdate` defaults to `.keep`; each one
named is `.set` to a value or `.clear`ed:

```zig
var info = try secrets.secret("db-password").update(.{
    .annotations = .{ .set = &.{.{ .key = "owner", .value = "payments" }} },
    .aliases = .{ .set = &.{.{ .name = "prod", .version = 7 }} },
    .expiry = .clear,
});
defer info.deinit();
```

**A list is replaced whole.** Secret Manager keeps nothing of the old
labels, annotations or aliases, and refuses a change to just one of
them (an update mask such as `labels.team`), so changing one means
reading the secret, changing the list, and setting it. Do that under
the etag the read returned, so a change made in between is not lost:

<!-- snippet: tests/docs_examples.zig#secret-set-label -->
```zig
/// Sets one label and keeps the others. The update replaces every label,
/// so it goes under the etag the read returned: another change made in
/// between is error.Aborted rather than lost, and the loop reads again.
fn setLabel(gpa: std.mem.Allocator, secret: secret_manager.Secret, key: []const u8, value: []const u8) !void {
    while (true) {
        var read = try secret.get();
        defer read.deinit();
        var labels: std.ArrayList(secret_manager.Label) = .empty;
        defer labels.deinit(gpa);
        for (read.value.labels) |l| {
            if (!std.mem.eql(u8, l.key, key)) try labels.append(gpa, l);
        }
        try labels.append(gpa, .{ .key = key, .value = value });

        var updated = secret.update(.{
            .labels = .{ .set = labels.items },
            .etag = read.value.etag,
        }) catch |err| switch (err) {
            error.Aborted => continue, // changed since the read
            else => return err,
        };
        updated.deinit();
        return;
    }
}
```

An update that changes nothing is refused before sending: production
would answer it, still move the etag, and tell any notification topic
that the secret changed. So are values production would refuse, as
`error.InvalidArgument`, with the rule in `Diagnostics`:

| Setting | The rules, as production enforced them on 2026-10-02 |
| --- | --- |
| Labels | At most 64. Keys 1 to 63 characters, a lowercase letter first (international letters too), then lowercase letters, digits, `_` and `-`; values the same, 0 to 63 characters; each at most 128 bytes |
| Annotations | Keys 1 to 64 ASCII letters and digits, with `.`, `_` and `-` between them (the docs and production's own message say "less than 64", but 64 is taken); values anything; **16,384 bytes in all, keys and values, counted in bytes** |
| Aliases | At most 50. Names 1 to 63 characters, a letter first, then letters, digits, `-` and `_`; `latest` and `NEW` are refused exactly, so `Latest` and `new` are taken; each names a version the secret has |
| Expiry | 60 seconds to 100 years ahead: `.after_s` seconds, or `.at` an RFC 3339 time |
| Destruction delay | 86,400 to 86,400,000 seconds (1 to 1,000 days) |

Everything read back is on `SecretInfo`: `annotations` and
`annotation(key)`, `aliases` and `alias(name)`, `expire_time` (always a
time, however the expiry was set) and `version_destroy_delay_s`.

## Preconditions

Every secret and version carries an etag, and every change moves it,
even one that changes nothing. Pass the etag a read returned, and the
change happens only if nothing else changed first:

| Call | Changes only if |
| --- | --- |
| `.update(.{ ..., .etag = e })` | the secret's etag is still `e` |
| `.deleteIf(e)` | the same |
| `.version(.{ .number = n }).enableIf(e)`, `.disableIf(e)`, `.destroyIf(e)` | the version's etag is still `e` |

A stale etag is `error.Aborted`, as a stale IAM policy is on every
resource, and nothing changes. Secret Manager answers it with HTTP 400
`FAILED_PRECONDITION`, the status a disabled version also gets, so the
library tells them apart by production's message: any other
`FAILED_PRECONDITION` stays `error.FailedPrecondition`.

- **A secret's etag and its versions' are separate.** Adding a version,
  enabling, disabling or destroying one, and changing the IAM policy
  leave the secret's etag where it was.
- **A retried conditional call** whose first attempt landed reports
  `error.Aborted` too, since that attempt moved the etag: read again
  before deciding it failed. Without an etag, `update` is safe to
  retry.
- An empty etag is refused before sending: production would take it as
  no condition at all.

## Aliases

An alias names a version: `access(.{ .alias = "prod" })` reads whatever
`prod` points at. Set them with `update`, all at once:

- **Case matters**: `prod` and `Prod` are two aliases.
- **Moving one** was seen by the very next access when measured, 0.43
  seconds later. Google's documentation calls aliases eventually
  consistent, so a reader may see the old version briefly.
- An alias may point at a disabled or destroyed version; reading through
  it is `error.FailedPrecondition`, as reading that version by number
  is. Destroying a version keeps the aliases that name it.
- An alias that does not exist is `error.NotFound`. `enable`, `disable`
  and `destroy` take numbers, never aliases.

## Expiry and delayed destruction

**Expiry** deletes the secret and every version at the time it names,
for good, with no warning beyond Secret Manager's own logs. Measured, a
secret was gone 20 seconds after its `expire_time`. `.clear` removes it.

**A destruction delay** (`version_destroy_delay_s`) makes `destroy` wait:
the version is `.disabled` until its `scheduled_destroy_time`, and only
then are the bytes gone. During the delay:

- a second `destroy` is `error.FailedPrecondition`, "SecretVersion is
  already scheduled for DESTRUCTION.";
- `enable` or `disable` cancels the destruction, and the version keeps
  its bytes;
- clearing the delay leaves versions already scheduled as they are, and
  makes later destroys immediate.

Google's documentation says deleting the secret, or its expiry,
destroys every version at once, delay or not.

## Notifications and rotation

A secret can name up to 10 Pub/Sub topics. Secret Manager publishes a
message to each for every change to the secret or its versions, and,
on the secret's rotation schedule, one saying it is time to rotate.

**Its service agent publishes, so it needs the publisher role on each
topic first**, and nothing creates that agent but asking for it:
measured, a project that had used Secret Manager for days had none.
`client.serviceAgent()` asks Service Usage, which creates it if needed
and answers its address at once:

```zig
var agent = try secrets.serviceAgent();
defer agent.deinit();
const member = try std.fmt.allocPrint(arena, "serviceAccount:{s}", .{agent.value});
var policy = try ps.topic("rotations").addIamBinding("roles/pubsub.publisher", member);
policy.deinit();

var info = try secrets.secret("db-password").update(.{
    .topics = .{ .set = &.{"projects/my-project/topics/rotations"} },
    .rotation = .{ .set = .{ .next_time = "2027-01-01T00:00:00Z", .period_s = 30 * 86_400 } },
});
defer info.deinit();
```

- **Topics are checked when they are set**, on create and on an update
  that names them, by publishing to each before anything else: a topic
  the agent may not publish to, one that does not exist, or one whose
  storage policy is enforced in transit is
  `error.TopicNotPublishable`, with production's words in
  `Diagnostics`. A grant took effect within a second when measured; a
  topic deleted moments before was still taken for a few minutes, from
  Pub/Sub's cache. Revoke the grant later and the secret's other writes
  still succeed; their messages were delivered once the grant came
  back.
- **A rotation needs topics**: a time 5 minutes to 100 years ahead, and
  an optional period of at least an hour. Without a period it happens
  once and is then gone from the secret. **Secret Manager changes
  nothing at rotation time**: it publishes `SECRET_ROTATE`, and a
  subscriber adds the new version. Measured, the message came 19 seconds
  after the time, the secret it carried already showed the next time,
  and the rotation moved the secret's etag. Google bills each rotation
  after the first three a month (Secret Manager's pricing page).

`secret_manager.decodeEvent` reads a message a `pubsub.Subscriber`
receives into a `SecretEvent`: its `kind`, the secret's full name and
location, the version for version events, the time, why a secret was
deleted, and the secret or version as the change left it.

| `kind` | Sent for |
| --- | --- |
| `.secret_create`, `.secret_update`, `.secret_delete` | create; every update, one that changes nothing included; delete, or expiry (`delete_type` `.expiration`) |
| `.version_add`, `.version_enable`, `.version_disable`, `.version_destroy`, `.version_destroy_scheduled` | the version calls; the last for a destroy under a destruction delay |
| `.secret_rotate` | the rotation schedule |
| `.topic_configured` | every time topics are set, to each, even for a create then refused: a check, naming no secret |
| `.unknown` | anything Secret Manager adds later |

Nothing is sent for IAM changes, reads, lists or access. As measured:

- **A global secret's events arrive late and out of order**: 18 seconds
  to nearly 3 minutes after the change, a delete before the updates it
  followed. A regional secret's came within a fifth of a second, in
  order. Order events by `time`, which Secret Manager writes in Pacific
  time with an offset, not by arrival.
- Pub/Sub delivers at least once, a repeat under a new message ID:
  `SecretEvent.key` tells a repeat from a new change.

[`examples/secret_rotation.zig`](../examples/secret_rotation.zig) sets a
secret's topic and rotation up, granting the agent, and answers each
`SECRET_ROTATE` with a new version that the alias `current` then points
at: `zig build example-secret_rotation -- setup my-project db-password
rotations`.

## Checksums

Secret Manager stores a CRC-32C with every version. `addVersion` always
computes one over the raw bytes and sends it, so a payload that arrives
changed is refused with `INVALID_ARGUMENT` rather than stored. On the
way back, `Options.verify_checksum` decides:

| Mode | The server sent a checksum | It sent none |
| --- | --- | --- |
| `.required` | Verified; a mismatch is an error | `error.MissingChecksum` |
| `.if_present` (default) | Verified; a mismatch is an error | The bytes, with `checksum_verified = false` |
| `.off` | Ignored | The bytes, with `checksum_verified = false` |

A mismatch means the bytes changed between Google's storage and this
process. Since access is idempotent, the client wipes them and asks
again under the retry policy; if the last attempt still mismatches, it
returns `error.ChecksumMismatch` and the bytes are never handed over.

## Regional secrets

`Options.location` decides both the host and the resource names, so a
client is global or regional for its whole life:

```zig
var eu = try secret_manager.Client.init(gpa, io, .{
    .project_id = "my-project",
    .location = "europe-west3", // secretmanager.europe-west3.rep.googleapis.com
    .token_provider = creds.provider(),
});
```

The two are separate namespaces: a global client asking for a regional
secret gets `NotFound`, and the reverse. An application that needs both
makes two clients. A regional secret sends no `replication`, because its
location decides where the bytes live; a global one must name it, and it
cannot be changed afterwards. `location` is checked against a strict
pattern before it becomes part of a host name.

## IAM

A secret's IAM policy says who may read its versions' bytes,
`roles/secretmanager.secretAccessor`, and who may manage it. Its
versions' permissions follow it. The five calls are the ones every
resource takes, global and regional alike:

```zig
var policy = try secrets.secret("db-password").addIamBinding(
    "roles/secretmanager.secretAccessor",
    "serviceAccount:app@my-project.iam.gserviceaccount.com",
);
defer policy.deinit();
```

A secret takes conditional bindings, written as version 3 by
themselves, and the basic roles. No `updateMask` is ever sent, so a
secret's audit configuration, which `core.iam.Policy` does not hold,
stays as it is: measured, a write that left `auditConfigs` out kept
them. `testIamPermissions` on a secret that does not exist answers that
none is held, where a missing topic or bucket is `error.NotFound`.

[IAM on every resource](iam.md) has the calls, how members compare, and
what each service does differently.

