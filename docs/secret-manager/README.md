[Docs](../README.md) › Secret Manager

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

[`examples/secret.zig`](../../examples/secret.zig) is the whole of the
above as a program: `zig build example-secret -- db-password latest`.

**On this page:** [The bytes](#the-bytes) ·
[What it covers](#what-it-covers) · [Checksums](#checksums) ·
[Regional secrets](#regional-secrets) · [IAM](#iam)

**Guides:** [Changing a secret](updating.md): updates, preconditions,
aliases, expiry and delayed destruction ·
[Notifications and rotation](notifications.md) ·
[Customer-managed encryption keys](encryption.md)

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
> secret. [SECURITY.md](../../SECURITY.md#secret-bytes) lists what holds it
> to that, test by test.

## What it covers

| Call | What it does |
| --- | --- |
| `client.secret(id).access(ref)` | The bytes of a version: `.latest`, `.{ .number = 3 }` or `.{ .alias = "prod" }` |
| `.addVersion(bytes)` | Stores a new version, with a CRC-32C the server checks |
| `.create(config)`, `.get()`, `.delete()` | The secret itself: replication, labels, annotations, expiry, a destruction delay, topics, a rotation and a key, then metadata, then gone |
| `.update(changes)` | Labels, annotations, aliases, expiry, the destruction delay, topics, the rotation and the keys, each set or cleared: [Changing a secret](updating.md) |
| `.deleteIf(etag)` | Deletes only if nothing changed since the read: [Preconditions](updating.md#preconditions) |
| `client.listSecrets(options)` | One page of secrets, with `filter`, `page_size` and `page_token` |
| `.listVersions(options)` | One page of versions, newest first |
| `.version(ref).get()` | A version's state, times and etag |
| `.version(.{ .number = n }).enable()`, `.disable()`, `.destroy()` | Change what a version serves |
| `.enableIf(etag)`, `.disableIf(etag)`, `.destroyIf(etag)` | The same, only if the version is as read |
| `client.serviceAgent()` | The account that publishes a secret's events and uses its key: [Notifications and rotation](notifications.md), [keys](encryption.md) |
| `secret_manager.decodeEvent(gpa, message, .{})` | A message from a secret's topic, as a `SecretEvent` |
| `.iamPolicy()`, `.setIamPolicy(policy)`, `.addIamBinding(role, member)`, `.removeIamBinding(role, member)`, `.testIamPermissions(permissions)` | Who may read the secret's bytes, or manage it: [IAM](#iam) |

`enable`, `disable` and `destroy` take a version number and refuse
`.latest` and aliases with `error.ExplicitVersionRequired`: "whatever is
latest right now" is the wrong target for a change that lasts.
Production refuses `latest` and aliases for those three as well.
Enabling and disabling are idempotent; destroying is not, and a second
destroy answers `error.FailedPrecondition`, which means the first one
worked. **A version's state reaches `access` eventually**, as Google's
documentation says of everything but access by number to a version just
added: measured on 2026-10-02, a version disabled moments before was
still served, twice in one run, and refused a second later. Disable a
version only after nothing should need it.

Not in this version: typed secrets and their managed rotation (a
regional Preview), and Resource Manager tags, which a secret takes only
when it is created.

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

[IAM on every resource](../iam.md) has the calls, how members compare, and
what each service does differently.

