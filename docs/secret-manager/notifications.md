[Docs](../README.md) › [Secret Manager](README.md) › Notifications and rotation

# Notifications and rotation

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
const member = try arena.print("serviceAccount:{s}", .{agent.value});
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

[`examples/secret_rotation.zig`](../../examples/secret_rotation.zig) sets a
secret's topic and rotation up, granting the agent, and answers each
`SECRET_ROTATE` with a new version that the alias `current` then points
at: `zig build example-secret_rotation -- setup my-project db-password
rotations`.

