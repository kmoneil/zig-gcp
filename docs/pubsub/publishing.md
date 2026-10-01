[Docs](../README.md) › [Pub/Sub](README.md) › Publishing

# Publishing

**On this page:** [Publishing at volume](#publishing-at-volume) ·
[Batches](#batches) · [Caps](#caps) ·
[Retries, flushing and stopping](#retries-flushing-and-stopping) ·
[Ordering keys](#ordering-keys) ·
[Compressed publishing](#compressed-publishing)

## Publishing at volume

`Topic.publish` sends one request per call, and a client serves one
task at a time. An application that publishes a message at a time from
many tasks wants `Publisher`: any task hands it messages, it batches
them into requests, and it sends those on tasks of its own.

```zig
var publisher = try pubsub.Publisher.init(gpa, io, .{
    .topic_id = "orders",
    .client = .{ .project_id = "my-project", .token_provider = creds.provider() },
});
defer publisher.deinit();
var running = try io.concurrent(pubsub.Publisher.run, .{&publisher});
defer {
    publisher.stop(); // sends what is left; run returns when all of it has resolved
    running.await(io) catch {};
}

// From any task:
const receipt = try publisher.publish(.{ .data = "hello" }, .{});
defer receipt.release();
const id = try receipt.wait(); // the server's message id, or the error
```

[`examples/publisher.zig`](../../examples/publisher.zig) publishes from
several tasks and says how few requests it took:
`zig build example-publisher -- orders 1000 4`.

### Batches

A request with a hundred small messages takes about as long as one with
a single message (27 ms against 26, measured against production), and
Google bills every request as at least 1,000 bytes. From a laptop, the
example publishes 10,000 messages from 8 tasks in 102 requests and about
a second. A batch goes out when one of `concurrency` connections (4) is
free and the batch is full, at `max_batch_messages` (100) or
`max_batch_bytes` of request body as sent (1,000,000), or its first
message has waited `max_batch_delay_ms` (10); until a connection takes
it, it keeps filling.

> [!IMPORTANT]
> Release every receipt, whether or not anyone waits on it. A failure no
> one waits for still counts in `stats()` and is logged.

### Caps

What a publisher holds is capped at 1,000 messages and 10,000,000 bytes
by default (`max_outstanding`, `max_outstanding_bytes`), counting
everything accepted and not yet resolved. At a cap `publish` waits for
room, or with `when_full = .fail` returns `error.PublisherFull` at once,
for a server that would rather shed load. Each cap must hold a full
batch, so raising `max_batch_bytes` toward the 10,485,760-byte limit
means raising `max_outstanding_bytes` with it.

### Retries, flushing and stopping

Transient failures are retried, with the statuses Google's own clients
retry for publishing, until `publish_timeout_ms` (60 s) after the
message was published. Each attempt is also bounded by the client's
`request_timeout_ms`, whose 3-minute default is sized for held pulls; a
publisher is better served by about 30 seconds. As with
`Topic.publish`, a retry after a lost response can store a message
twice, with a new message id. `flush` sends everything at once and waits
for what was published before it. `stop` sends what is left; canceling
`run` gives up on it, and those receipts report
`error.PublisherStopped`.

### Ordering keys

Ordering keys need `enable_message_ordering`. Messages with the same key
reach an ordered subscription in publish order: no request mixes keys,
and a key has one request in flight at a time. When one of a key's
batches fails for good, the key pauses: the messages queued behind it
fail with `error.OrderingKeyPaused` without being sent, and `publish`
refuses the key until `resumePublish(key)`, so a message is never stored
ahead of one that failed. Google requires every message of a key to be
published in one region. A publisher outside Google Cloud, or spread
across regions, should use a locational endpoint, such as
`.endpoint = .{ .url = "https://us-east1-pubsub.googleapis.com" }`.

## Compressed publishing

`compression` gzips a publish request's body and sends it with
`Content-Encoding: gzip`, as Google's Java, Go, C++, .NET, Ruby and PHP
libraries can. It is off by default, there as here. Set it on a
publisher for every batch, or on a single call:

```zig
var publisher = try pubsub.Publisher.init(gpa, io, .{
    .topic_id = "orders",
    .client = .{ .project_id = "my-project", .token_provider = creds.provider() },
    .compression = .{}, // level 6, for request bodies of 240 bytes or more
});

var sent = try topic.publish(&messages, .{ .compression = .{ .level = 1 } });
```

- **What it saves** is bandwidth between the publisher and Google, and
  egress charges where the publisher pays them, such as outside Google
  Cloud. Pub/Sub bills messages uncompressed, so its own charges do not
  change.
- **What it costs** is CPU and memory. At level 6, compressing and
  checking takes about 10 ms per MB of JSON body in ReleaseFast, and
  about twice that for data that does not compress. Compressing a body
  holds about 350 KiB of compressor state and windows until it is done,
  for each batch being compressed at once, and none of it while the
  request is out.
- **What is compressed** is a body of at least `min_bytes` (240) at
  `level` 1 (fastest) to 9 (smallest). Google's libraries compress from
  240 bytes of messages; this counts the request body, which base64
  makes a third bigger.
- **Sizes stay uncompressed.** `max_batch_bytes`, the caps and the
  10,485,760-byte check count the request before compression, as every
  Google library counts them, so compressing never lets a bigger batch
  through.
- **It is checked.** A body is compressed once, so every retry sends the
  same bytes, and decompressed again, to give back exactly the request.
  One that does not, which would be a bug in the compressor, goes
  uncompressed, with a warning in the log.

Measured on an Apple M5 Max in ReleaseFast, at level 6, the check
included:

| Batch | Body | Compressed | Time |
| --- | ---: | ---: | ---: |
| 100 JSON events of about 220 bytes, with two attributes each | 38,234 B | 5,357 B (14%) | 0.34 ms |
| 1,000 of them | 382,486 B | 46,093 B (12%) | 3.8 ms |
| 100 messages of 250 random bytes, with the same attributes | 42,014 B | 26,113 B (62%) | 0.79 ms |
| 1,000 of them | 420,014 B | 260,627 B (62%) | 8.9 ms |

Level 1 made the JSON a fifth bigger than level 6 in four fifths of the
time, and level 9 made it 3% smaller in a quarter more. Even random
bytes shrink by more than a third, to within 5% of the data itself:
base64 writes 6 bits of data in each 8-bit character, and gzip takes
that back, along with the repeated attributes.

Production takes compressed publishes, and holds the 10,485,760-byte
limit to the body decompressed: 10.8 MB of JSON, sent as 10,566 bytes of
gzip, was refused. The emulator takes them too. Pull answers already
come back compressed: the transport accepts gzip, and production gzips
them.
