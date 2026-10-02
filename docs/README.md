[zig-gcp](../README.md) › Docs

# zig-gcp documentation

Start with [Essentials](essentials.md), which every module shares, and
[Credentials](auth.md), which every production program needs; then the
guide for the service at hand. Each guide says what was measured against
Google, not only what Google documents, and where the emulators differ.

## 🧭 Every module

| Guide | What's in it |
| --- | --- |
| [Essentials](essentials.md) | Clients and handles, endpoints and emulators, results and memory, errors and `Diagnostics`, retries, time limits and cancellation, logging, and testing code that uses this library |
| [Credentials](auth.md) | `findDefault` and where it looks, user logins, service account keys, workload identity federation, impersonation, static tokens, and signing |
| [IAM on every resource](iam.md) | Reading, granting, revoking and testing permissions on buckets, topics, subscriptions and secrets, and where the services differ |

## 📨 Pub/Sub

| Guide | What's in it |
| --- | --- |
| [Overview](pubsub/README.md) | A first program, the calls, pulling, retries, limits, and where the emulator differs |
| [Subscribing](pubsub/subscribing.md) | `Subscriber`, a worker loop that extends leases and shuts down cleanly; exactly-once delivery |
| [Publishing](pubsub/publishing.md) | `Publisher`, which batches from many tasks; caps, ordering keys and compression |
| [Topics and subscriptions](pubsub/topics-and-subscriptions.md) | Dead letters, retry policies, filters, retention, expiration, labels, updates, and IAM |

## 🪣 Cloud Storage

| Guide | What's in it |
| --- | --- |
| [Overview](storage/README.md) | A first program, and every call with the guide that covers it |
| [Transfers](storage/transfers.md) | Files and streams of any size, parallel uploads and downloads, and checkpoints that carry a transfer on in a later process |
| [Checksums and compression](storage/checksums-and-compression.md) | CRC-32C in both directions and at the CPU's speed, objects stored gzip-compressed, and compressing on upload |
| [Writing objects](storage/writing-objects.md) | Preconditions, retries and idempotency tokens, metadata after the upload, compose, and copies that change what they carry |
| [Signed URLs and POST policies](storage/signed-urls.md) | Requests and browser uploads without credentials, and who can sign them |
| [Buckets](storage/buckets.md) | Settings and lifecycle rules, versions and soft delete, retention and holds, requester pays, IAM |
| [Encryption keys](storage/encryption.md) | Customer-supplied keys and Cloud KMS keys |
| [Notifications](storage/notifications.md) | A Pub/Sub message for every change to a bucket's objects, and what each change publishes |
| [The emulator](storage/emulator.md) | What fake-gcs-server does differently, and how the tests make up for it |

## 🔑 Secret Manager

| Guide | What's in it |
| --- | --- |
| [Secret Manager](secret-manager.md) | Reading a secret's bytes, verified and wiped; versions; checksums; regional secrets; IAM |

## 🛠️ Working on zig-gcp

| Guide | What's in it |
| --- | --- |
| [Development](development.md) | Build steps, fuzzing, coverage, CI, and every integration suite with what it needs |
| [Zig 0.16 workarounds](zig-std-workarounds.md) | Standard library issues this library works around, each with its regression test |
| [Contributing](../CONTRIBUTING.md) | How changes are proposed, tested and merged |
| [Security](../SECURITY.md) | The threat model, and the test that holds each claim |
| [Changelog](../CHANGELOG.md) | Every release, and what each one breaks |
