[Docs](../README.md) › Pub/Sub

# 📨 Pub/Sub

A small, synchronous client for the Pub/Sub v1 REST API. It works
against the local emulator with no credentials, and against production
through a token-provider seam.

```zig
const std = @import("std");
const pubsub = @import("pubsub");

pub fn main(init: std.process.Init) !void {
    var diag: pubsub.Diagnostics = .{};
    var client = try pubsub.Client.init(init.gpa, init.io, .{
        .project_id = "test",
        // Honors PUBSUB_EMULATOR_HOST; null (production) when it is unset.
        .endpoint = pubsub.Endpoint.fromEnv(init.environ_map),
        .diagnostics = &diag,
    });
    defer client.deinit();

    const orders = client.topic("orders");
    var sent = try orders.publish(&.{
        .{ .data = "hello", .attributes = &.{.{ .key = "origin", .value = "zig" }} },
    }, .{});
    defer sent.deinit();

    const worker = client.subscription("orders-worker");
    var batch = try worker.pull(.{ .max_messages = 10 });
    defer batch.deinit();
    for (batch.value.messages) |m| {
        std.debug.print("{s}: {s}\n", .{ m.message_id, m.data });
        try worker.ack(&.{m.ack_id});
    }
}
```

Against production, pass a `.token_provider` as well:
[Credentials](../auth.md) says where one comes from.

| Guide | What's in it |
| --- | --- |
| [Subscribing](subscribing.md) | `Subscriber`, a worker loop that extends leases, bounds work and shuts down cleanly; exactly-once delivery |
| [Publishing](publishing.md) | `Publisher`, which batches messages from many tasks; ordering keys; compression |
| [Topics and subscriptions](topics-and-subscriptions.md) | Dead letters, retry policies, filters, retention, expiration and labels; updates; topic IAM |

**On this page:** [Handles and calls](#handles-and-calls) ·
[Pulling](#pulling) · [Retries](#retries) · [Limits](#limits) ·
[The emulator is not production](#the-emulator-is-not-production)

## Handles and calls

`Topic` and `Subscription` are cheap handles: a client pointer and a
short id such as `orders`. Creating one sends nothing. The operations:

| `Client` | `Topic` | `Subscription` |
| --- | --- | --- |
| `listTopics`, `listSubscriptions` | `create`, `get`, `update`, `delete`, `publish`, and `iamPolicy`, `setIamPolicy`, `addIamBinding` | `create`, `get`, `update`, `delete`, `pull`, `ack`, `modifyAckDeadline`, `nack`, and `ackWithResults`, `modifyAckDeadlineWithResults`, `nackWithResults` |

See [`examples/publish.zig`](../../examples/publish.zig),
[`examples/publisher.zig`](../../examples/publisher.zig) and
[`examples/worker.zig`](../../examples/worker.zig) for complete
programs, and [`examples/whoami.zig`](../../examples/whoami.zig) for one
that finds its own credentials.

## Pulling

An empty pull is held open by the server: about 20 seconds in production
and 90 on the emulator. `PullOptions.return_immediately` returns at once
instead; Google discourages it in production because it hurts delivery
throughput. That hold is why a Pub/Sub client's `request_timeout_ms` is
3 minutes by default.

A program that consumes a subscription for real wants more than `pull`
and `ack`: [`Subscriber`](subscribing.md) is that loop.

## Retries

Pub/Sub retries what every module retries, as
[Essentials](../essentials.md#retries-time-limits-and-cancellation)
says. A publish is also retried on ABORTED, CANCELLED, and UNKNOWN
answered with a 5xx, as Google's own clients retry it. A retried publish
can store messages twice; set `Client.Options.retry_publish = false` to
opt out, and note that such a publish also fails, rather than retries,
when the server has closed an idle connection. Retried creates and
deletes can report `AlreadyExists` or `NotFound` for an attempt that
succeeded but whose response was lost.

## Limits

The client checks these before sending and fails with
`error.InvalidMessage` or `error.InvalidArgument`, with the reason in
`Diagnostics`. Values were measured against production (September 2026);
several are stricter or more precise than the documentation.

| Limit | Value |
| --- | --- |
| Publish request | **10,485,760 bytes of encoded JSON body**, counted before any compression. Base64 grows data by a third, so one message holds at most 7,864,299 bytes of raw data over REST. `pubsub.limits.publishRequestBytes` computes the exact size. |
| Messages per publish | 1,000 |
| Attributes per message | 100; keys 1 to 256 bytes and not starting with `goog` in any case; values up to 1,024 bytes |
| Ordering key | 1,024 bytes |
| Ack or modifyAckDeadline request | 524,288 bytes; `ack` splits longer id lists into several requests |
| Ack deadline | 10 to 600 s on a subscription, 0 to 600 s in `modifyAckDeadline` |
| Topic and subscription ids | 3 to 255 characters from `[A-Za-z0-9-_.~+%]`, starting with a letter, not starting with `goog` in any case |

## The emulator is not production

These differences were measured with emulator 0.8.35, and the
exactly-once ones and the deleted topic with 0.8.36. The client's own
checks catch the ones marked *checked*, so code tested against the
emulator does not fail later in production.

| Behavior | Emulator | Production |
| --- | --- | --- |
| Publish size limit | none | 10,485,760-byte request body, counted decompressed (*checked*) |
| Empty or `goog...` attribute keys | accepted | rejected (*checked*) |
| Ids starting with `GOOG` | accepted | rejected (*checked*) |
| Ordering key over 1,024 bytes | accepted | rejected (*checked*) |
| Mixed ordering keys in one publish | accepted | FAILED_PRECONDITION (the API takes one key per call) |
| Empty pull hold | about 90 s | about 20 s |
| A literal `%25` in an id | decoded twice | decoded once |
| Exactly-once: a late ack's refusal | names no id | names each refused id |
| Exactly-once: a late lease extension | taken | refused |
| Exactly-once: a second ack of an acknowledged message | refused | taken |
| Publishing to a deleted topic | refused at once | taken for 0.7 to 14 s in nine runs, and once for over 90 s |

[Topics and subscriptions](topics-and-subscriptions.md#what-the-emulator-and-production-do)
lists how the two treat settings and updates.
