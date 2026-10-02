[Docs](../README.md) › [Pub/Sub](README.md) › Topics and subscriptions

# Topics and subscriptions

**On this page:** [Subscription settings](#subscription-settings) ·
[Updates](#updates) · [Topic settings](#topic-settings) ·
[What the emulator and production do](#what-the-emulator-and-production-do) ·
[IAM](#iam)

## Subscription settings

```zig
var created = try client.subscription("orders-worker").create(.{
    .topic_id = "orders",
    .dead_letter_policy = .{ .topic = "orders-dead", .max_delivery_attempts = 10 },
    .retry_policy = .{ .minimum = .fromSeconds(5), .maximum = .fromSeconds(300) },
    .filter = "attributes.region = \"eu\"",
    .message_retention = .fromSeconds(3 * 24 * 60 * 60),
    .labels = &.{.{ .key = "team", .value = "payments" }},
});
defer created.deinit();
```

- **`dead_letter_policy`**: after `max_delivery_attempts` deliveries (5
  to 100), a message goes to the dead-letter topic, a topic id here or
  `projects/{project}/topics/{id}` elsewhere, marked with
  `CloudPubSubDeadLetterSource...` attributes that say where it came
  from. Pub/Sub's service agent,
  `service-{project number}@gcp-sa-pubsub.iam.gserviceaccount.com`,
  needs `roles/pubsub.publisher` on the dead-letter topic and
  `roles/pubsub.subscriber` on this subscription, or nothing is
  forwarded: without them, production went on delivering a message past
  its last attempt, and the dead-letter topic got nothing; with them, it
  forwarded the message about 3 s after its fifth delivery was released.
  `ReceivedMessage.delivery_attempt` counts deliveries only on a
  subscription with a dead-letter policy.
- **`retry_policy`**: how long Pub/Sub waits before delivering a message
  again after a release or a lapsed deadline, each bound 0 to 600 s (the
  type is `pubsub.Backoff`: `pubsub.RetryPolicy` is this client's own
  retries). Null delivers again at once.
- **`filter`**: only messages whose attributes match are delivered; the
  rest are acknowledged unseen. At most 256 bytes, and fixed once
  created.
- **`message_retention`**: how long unacknowledged messages are kept, 10
  minutes to 31 days, 7 by default. `retain_acked_messages` keeps
  acknowledged ones as long.
- **`expiration`**: `.default` deletes a subscription nobody uses after
  31 days, `.never` never does, and `.after` sets the time, at least a
  day.
- **`labels`**: up to 64.

Every rule is checked before anything is sent. The emulator takes
several settings production refuses, such as ack deadlines of 1 to 9 s,
labels with capitals and expirations under a day, so code tested
against it would otherwise fail later.

## Updates

`update` changes the settings it names and leaves the rest alone:

```zig
var updated = try client.subscription("orders-worker").update(.{
    .ack_deadline_seconds = 60,
    .dead_letter_policy = .clear,
    .labels = &.{},
});
defer updated.deinit();
```

A setting that can be taken away is a `pubsub.Change(T)`: `.keep`, the
default, leaves it; `.{ .set = ... }` replaces it whole; `.clear`
removes it, or restores Pub/Sub's default where it has one (retention
goes back to 7 days). `labels` replaces every label, and `&.{}` removes
them all. The topic, the ordering and the filter cannot be changed.

## Topic settings

Topics take `labels`, `message_retention` (the topic keeps every
message, acknowledged or not, so subscriptions can replay them),
`kms_key_name` and `message_storage_policy` (the regions messages may be
stored in), and `Topic.update` changes them the same way.

## What the emulator and production do

The emulator cannot update a subscription's labels, filter or
expiration, or a topic's labels, KMS key or storage policy. It answers a
cleared topic retention with 31 days, and forwards a message to its
dead-letter topic only when the source subscription is pulled again.

Production, measured on 2026-09-28, refuses every rule above with a
message that names it, refuses to change the filter, the ordering or the
topic ("not mutable"), and answers each update as described here: a
cleared expiration goes back to 31 days, `.never` to none, a cleared
retention to 7 days, and a cleared topic retention to none.

## IAM

A topic's or a subscription's IAM policy says who may do what with it,
such as publish to the topic or consume from the subscription. Both take
the same five calls:

| Call | What it does |
| --- | --- |
| `iamPolicy()` | The policy, asked for as version 3. A fresh one is empty, with the etag `ACAB`. |
| `setIamPolicy(policy)` | Writes the whole policy, and answers it as stored |
| `addIamBinding(role, member)` | Grants one member one role, unless the member already holds it |
| `removeIamBinding(role, member)` | Takes the member out of the role, unless it is not there |
| `testIamPermissions(permissions)` | The permissions the caller holds, of those asked |

```zig
var policy = try client.topic("uploads").addIamBinding(
    "roles/pubsub.publisher",
    "serviceAccount:service-123456789@gs-project-accounts.iam.gserviceaccount.com",
);
defer policy.deinit();
```

`addIamBinding` and `removeIamBinding` read the policy, change the
role's binding that has no condition, and write the policy back under
the read's etag. When another change came in between, the write fails
with `error.Aborted`, and they start over after a jittered wait, up to
the retry policy's attempts; when the policy already says what they
would make it say, nothing is written. Members compare as Pub/Sub
stores them: the address of a `user:`, `serviceAccount:`, `group:` or
`domain:` member is lowercased, so granting `user:Alice@example.com` to
a policy that holds `user:alice@example.com` writes nothing. Bindings
with conditions are kept as read and written back as they came.

`setIamPolicy` takes a policy `iamPolicy` read, changed, as a
`pubsub.iam.Policy`, with helpers such as `pubsub.iam.withMember`: its
etag makes the write fail with `error.Aborted` if the policy changed
since, rather than undo that change. A write that carries an etag is
retried after a transient failure, and one whose first answer was lost
then reports `error.Aborted` although it landed: read the policy again.
A write without an etag is sent once.

Refused before sending, with `error.InvalidArgument` and the reason in
`Diagnostics`: a conditional binding, which Pub/Sub refuses ("Can't set
conditional policy on this resource"); a role that is not
`roles/NAME`, `projects/P/roles/NAME` or `organizations/O/roles/NAME`; a
member whose prefix is not one Pub/Sub takes, cased as it requires
(`ServiceAccount:` is refused); a `deleted:` member granted (one may be
revoked); and permissions to test that are none, over 100, named twice
or a wildcard.

<details>
<summary><b>📏 Measured against Pub/Sub on 2026-10-01</b></summary>

- Every write moves the etag, one that changes nothing included. A write
  under an older etag is 409 `ABORTED`, "There were concurrent policy
  changes. Please retry the whole read-modify-write with exponential
  backoff.".
- A principal that does not exist is refused ("User X does not exist.",
  and likewise for service accounts, groups and domains); a workforce
  principal of a pool that does not exist fails with 500 on every try.
- A binding with no members is dropped, a member named twice is stored
  once, and two bindings of one role without a condition are merged.
- Topics and subscriptions take Pub/Sub's own roles and the basic roles
  (`roles/viewer`, `roles/editor`); a subscription refuses the topic-only
  `roles/pubsub.publisher`.
- `testIamPermissions` takes at most 100 permissions, all Pub/Sub's own,
  and echoes one named twice; on a topic or subscription that does not
  exist it is 404, not the empty set Google's documentation promises.
- Two clients granting on one topic at once both landed, each starting
  over when the other came in between.

</details>

The calls need `pubsub.topics.getIamPolicy` and `setIamPolicy`, or the
same on `pubsub.subscriptions`; `testIamPermissions` needs nothing. The
emulator answers every IAM call 501, `error.Unimplemented`.

Cloud Storage publishes a bucket's [notifications](../storage/notifications.md)
only to a topic its service agent holds `roles/pubsub.publisher` on, and
a dead-letter policy forwards only once Pub/Sub's own service agent
holds `roles/pubsub.publisher` on the dead-letter topic and
`roles/pubsub.subscriber` on the subscription: `addIamBinding` grants
each.
