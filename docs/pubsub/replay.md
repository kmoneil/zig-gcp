[Docs](../README.md) › [Pub/Sub](README.md) › Replaying and purging

# Replaying and purging

A subscription normally only moves forward: a message is delivered,
acknowledged, and gone. Three calls change that. A **snapshot** keeps a
backlog as it stands. A **seek** moves a subscription back, to a
snapshot or to a time, or ahead, past a backlog nobody wants. A
**detach** cuts a subscription off its topic.

**On this page:** [Snapshots](#snapshots) · [Seeking](#seeking) ·
[What a running subscriber sees](#what-a-running-subscriber-sees) ·
[Detaching](#detaching) · [Permissions](#permissions) ·
[What the emulator and production do](#what-the-emulator-and-production-do)

## Snapshots

<!-- snippet: tests/docs_examples.zig#pubsub-snapshot -->
```zig
/// Before a risky deploy: keeps the backlog of `orders-worker` as it
/// stands.
fn keepBacklog(client: *pubsub.Client) !void {
    var kept = try client.snapshot("before-deploy").create(.{ .subscription = "orders-worker" });
    defer kept.deinit();
}

/// The deploy acknowledged what it should not have: back to the snapshot,
/// which stays until it is deleted or expires.
fn undoDeploy(client: *pubsub.Client) !void {
    try client.subscription("orders-worker").seek(.{ .snapshot = "before-deploy" });
}
```

A snapshot keeps the messages its subscription had not had acknowledged
when it was made, and every message published to the topic since.

- **It belongs to the topic.** Any subscription of that topic can seek
  to it, one created after it included, and as often as needed; another
  topic's subscription is refused, `error.FailedPrecondition`. It
  outlives the subscription it was made of, and the topic too, whose
  name `SnapshotInfo.topic` then gives as `_deleted-topic_`.
- **It lives at most 7 days**, less the age of the oldest message its
  subscription held: `SnapshotInfo.expire_time` says until when. One
  that would expire within the hour is refused,
  `error.FailedPrecondition`.
- **`client.snapshot(id)` is a handle**, as `client.topic` and
  `client.subscription` are, with `create`, `get`, `update`, `delete`
  and the five [IAM calls](topics-and-subscriptions.md#iam). `update`
  changes its labels and nothing else: Pub/Sub lets nothing else change.
  The subscription is an id in the client's project, or
  `projects/{project}/subscriptions/{id}` elsewhere.
- **Listing.** `Client.listSnapshots` pages through a project's
  snapshots, whole. `Topic.listSnapshots` and `Topic.listSubscriptions`
  page through what is attached to one topic, and answer full names
  alone, some of which may lie in other projects.
- **Limits.** 5,000 snapshots a project, and as many a topic.

## Seeking

To a snapshot, as above, or to a time:

<!-- snippet: tests/docs_examples.zig#pubsub-seek-time -->
```zig
/// Replays what was published since `since`, as far back as the
/// subscription or its topic retains messages.
fn replaySince(client: *pubsub.Client, since: std.Io.Timestamp) !void {
    try client.subscription("orders-worker").seek(.{ .time = since });
}

/// Drops a backlog nobody wants. A minute ahead of this machine's clock,
/// to be past the server's: what is published afterwards is delivered.
fn purge(client: *pubsub.Client, io: std.Io) !void {
    const now = std.Io.Clock.real.now(io);
    try client.subscription("orders-worker").seek(.{ .time = .{ .nanoseconds = now.nanoseconds + std.time.ns_per_min } });
}
```

A seek to a time acknowledges the messages the subscription holds that
were published before it, and makes those published after it
unacknowledged again.

- **Back, to replay.** It reaches only as far as messages are retained:
  by the subscription (`retain_acked_messages`, within its
  `message_retention`) or by its topic (`TopicConfig.message_retention`).
  With neither, nothing that was acknowledged comes back. With retention
  on the topic, a subscription can even replay what was published before
  it existed. `pubsub.parseTimestamp(message.publish_time)` gives the
  time of a message to go back to.
- **Ahead, to purge.** It acknowledges what the subscription holds when
  it runs. It is no filter on the future: a message published after the
  seek is delivered, even one published before the time the seek named.
- **With other settings.** With a filter, only matching messages come
  back. With a dead-letter policy, Google documents that delivery
  attempts start again at 0. An ordered subscription's messages came
  back in order when measured.
- **Retried as any call is**: a repeat leaves the subscription where the
  first attempt did.

## What a running subscriber sees

A seek does not show at once. Google says it may take a minute; when
measured on 2026-10-10, a seek back began to redeliver after 2 to 50
seconds. Until it has settled:

- messages the seek acknowledged can still arrive;
- an ack for a delivery made before a seek back is answered as taken,
  and then forgotten: the message comes again. That held with
  exactly-once delivery too, where Google's page says such an ack fails.

So around a seek a handler can see a message twice. Handlers that are
safe to run twice, which at-least-once delivery asks for anyway, need
nothing more. A [`Subscriber`](subscribing.md) needs no restart: what a
seek brings back arrives through the pulls it is already making, and its
stats count an ack the server took, whether or not the seek undid it.

## Detaching

<!-- snippet: tests/docs_examples.zig#pubsub-detach -->
```zig
/// A topic's owner cuts off a subscription for good. `consumers` is a
/// client for the project the subscription lives in.
fn cutOff(consumers: *pubsub.Client) !void {
    try consumers.subscription("stale-consumer").detach();
}
```

A detached subscription drops what it holds, receives nothing more, and
cannot be attached again. It stays until it is deleted, reads back with
`SubscriptionInfo.detached` set, and is gone from
`Topic.listSubscriptions`.

- **What it then refuses.** Within seconds, 7 when measured, `pull`,
  `ack`, `modifyAckDeadline`, `seek` and a snapshot of it are all
  `error.FailedPrecondition`, and a `Subscriber` running on it stops
  with that error. It can still be read, updated and deleted.
- **A lost answer.** A second detach is refused like the rest. When that
  refusal answers a retry, the client reads the subscription, and if it
  is detached the call succeeds: the earlier attempt landed, and only
  its answer was lost. A first attempt's refusal is returned as it is.
- **It is the topic owner's call.** The permission is checked on the
  topic, not on the subscription. To detach a subscription that lives in
  another project, use a client whose `project_id` is that project, with
  credentials that hold the permission on the topic.
- **One oddity.** The answer to an update of a detached subscription
  leaves `detached` out, so `update` returns `detached = false` for it.
  `get` says what is true.

## Permissions

| Call | Needs |
| --- | --- |
| `Snapshot.create` | `pubsub.snapshots.create` on the project, and `pubsub.subscriptions.consume` on the subscription |
| `Snapshot.get`, `Client.listSnapshots` | `pubsub.snapshots.get`, `pubsub.snapshots.list` |
| `Snapshot.update`, `Snapshot.delete` | `pubsub.snapshots.update`, `pubsub.snapshots.delete` |
| `Subscription.seek` | `pubsub.subscriptions.consume`, and `pubsub.snapshots.seek` on the snapshot |
| `Subscription.detach` | `pubsub.topics.detachSubscription` on the topic |

`roles/pubsub.subscriber` can seek, to a time or to a snapshot, and can
do nothing else here. `roles/pubsub.editor` can do all of it but read
and write IAM policies.

## What the emulator and production do

Measured on 2026-10-10, with emulator 0.8.36. The client's own checks
catch the one marked *checked*.

| Behavior | Emulator | Production |
| --- | --- | --- |
| A snapshot's labels | dropped, without a word (*checked*: a bad label is refused before sending) | kept |
| `Snapshot.update` | `error.Unimplemented` | labels change; any other field is "not mutable" |
| A snapshot's IAM calls | `error.InvalidArgument` | the policy |
| `Subscription.detach` | `error.Unimplemented` | done within seconds |
| A seek | shows at once | showed after 2 to 50 s |
| A seek to a time on an ordered subscription | unsupported, by its own page | works, in order |
| A snapshot whose topic was deleted | still names the topic | names `_deleted-topic_` |
| `Topic.listSnapshots` on a deleted topic | still lists them | `error.NotFound` |
