[Docs](../README.md) › [Secret Manager](README.md) › Changing a secret

# Changing a secret

**On this page:** [Updates](#updates) · [Preconditions](#preconditions) ·
[Aliases](#aliases) ·
[Expiry and delayed destruction](#expiry-and-delayed-destruction)

## Updates

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
| Topics and rotation | [Notifications and rotation](notifications.md) |
| Keys | [Customer-managed encryption keys](encryption.md) |

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

