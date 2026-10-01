[Docs](README.md) › Development

# Development

Building, testing, fuzzing and measuring coverage, and running the
integration suites against the emulators and Google. How changes are
made and reviewed is in [CONTRIBUTING.md](../CONTRIBUTING.md).

**On this page:** [Build steps](#build-steps) · [Fuzzing](#fuzzing) ·
[Coverage](#coverage) · [Continuous integration](#continuous-integration) ·
[Integration tests](#integration-tests)

## Build steps

```sh
zig build test                         # unit, property and fuzz-corpus tests
zig build test --seed 0x1234           # same, with different pseudo-random inputs
zig build test -Doptimize=ReleaseFast  # same, optimized; also ReleaseSafe
zig build test -Dfuzz-runner --fuzz    # coverage-guided fuzzing (see below)
zig build test-integration             # needs a server, see below
zig build test-integration-gcp         # against Google, see below
zig build coverage                     # line coverage; needs kcov (see below)
zig build bench-crc32c                 # how fast this machine computes CRC-32C
zig build example-publish -- orders 5
zig build example-worker -- orders orders-worker
zig build example-whoami               # which credentials, and the topics they see
zig build fmt                          # zig fmt --check
python3 tools/check_docs.py            # the docs' links, anchors and snippets
```

`zig build test` also compiles every example and the suites that run
against Google, so none of them can rot between runs.

## Fuzzing

Every fuzz property also runs in `zig build test`: on its seed corpus and
on a few hundred pseudo-random inputs. Zig 0.16.0's own test runner does
not compile in fuzz mode, and its default x86_64 backend emits no
coverage instrumentation. `-Dfuzz-runner` fixes both: it swaps in
`tools/test_runner.zig`, a copy with a one-line fix, and builds the tests
with LLVM. The fuzzer keeps its corpus in `.zig-cache/f`, so only one
fuzzing run per checkout at a time; `-Dtest-filter=fuzz` skips the unit
tests that are not fuzz targets. When it finds a failing input, it saves
it to `.zig-cache/f/crash`: a 4-byte little-endian length, then the
input. Add the input to that property's corpus, so the fix stays
covered.

## Coverage

`zig build coverage` runs the unit tests under
[kcov](https://github.com/SimonKagstrom/kcov) and writes the report to
`zig-out/coverage/index.html`. `tools/coverage_summary.py` prints it as
Markdown, including every line no test reached. kcov counts lines, not
branches, and sees only code the compiler kept.

## Continuous integration

CI runs the unit tests on Linux, macOS and Windows, and on Linux also in
ReleaseSafe and ReleaseFast, and core's on a baseline CPU, whose build
computes CRC-32C with tables rather than instructions; the docs check;
the integration tests and examples against the emulators; and coverage,
whose summary and report are attached to each run.

Every night it also fuzzes, one job per module, each starting from the
corpus that earlier nights built up for it, and jobs of their own for
the properties too slow to share one: auth's RSA signing
(`slow-auth`), pubsub's Publisher and Subscriber models (`slow-pubsub`,
`slow-subscriber`) and its heavy properties (`heavy-pubsub`), storage's
slow and heavy properties (`slow-storage`, `heavy-storage`), and its
fault properties, which drive whole transfers through injected faults
(`fault-storage`, `fault-gzip`). A test that fails while being fuzzed
fails its job, and the input is attached to the run as
`fuzz-failure-<job>`, such as `fuzz-failure-pubsub`.

## Integration tests

Integration tests skip unless a server is configured.

### Pub/Sub

```sh
gcloud beta emulators pubsub start --project=test --host-port=127.0.0.1:8085
PUBSUB_EMULATOR_HOST=127.0.0.1:8085 zig build test-integration
```

The emulator binds to IPv6 localhost unless given `--host-port`. The
same step runs `tests/fault_injection.zig`: the whole stack against the
emulator, through a proxy that drops, cuts, delays and rewrites
responses. Those tests need the emulator specifically and never target
production.

Or a real project. Every test creates `zigps-*` resources and deletes
them. With the project's number, the dead-letter test grants Pub/Sub's
service agent the roles it needs on its own topic and subscription;
without it, that test skips. The grants go with the resources.

```sh
PUBSUB_TEST_PROJECT=my-project PUBSUB_TEST_TOKEN=$(gcloud auth print-access-token) \
    PUBSUB_TEST_PROJECT_NUMBER=$(gcloud projects describe my-project --format='value(projectNumber)') \
    zig build test-integration
```

### auth

Against Google's token endpoint, with the file gcloud's login wrote, and
a read-only Pub/Sub call with the token it gets:

```sh
AUTH_TEST_CREDENTIALS=$HOME/.config/gcloud/application_default_credentials.json \
    PUBSUB_TEST_PROJECT=my-project zig build test-integration
```

### Secret Manager and bucket settings

Secret Manager has no emulator, so its tests need a real project. They
create `zigps-*` secrets labelled `zig-gcp-test` and delete them, and
sweep up anything a crashed run left behind. `GCP_TEST_LOCATION` adds the
regional tests. The same project runs the Cloud Storage bucket tests,
which make `zigps-settings-*` buckets with soft delete off and delete
them; they need Storage Admin there.

```sh
GCP_TEST_PROJECT=my-project GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
    zig build test-integration-gcp
```

### Cloud Storage on the emulator

Against fake-gcs-server, on its memory backend, the one that keeps
versions. Every test creates a `zigps-*` bucket and deletes it.

```sh
docker run -d -p 4443:4443 fsouza/fake-gcs-server:1.56.1 -backend memory -scheme http -port 4443
# Or without Docker: go install github.com/fsouza/fake-gcs-server@latest
fake-gcs-server -backend memory -scheme http -port 4443
STORAGE_EMULATOR_HOST=http://127.0.0.1:4443 zig build test-integration
```

The emulator serves the paths signed URLs use only for the host they
name, so those tests need `-public-host`, as CI passes it:

```sh
docker run -d -p 4443:4443 fsouza/fake-gcs-server:1.56.1 -backend memory -scheme http -port 4443 \
    -public-host 127.0.0.1:4443
```

### Notifications on both emulators

fake-gcs-server publishes a bucket's notifications only to the Pub/Sub
emulator its own environment names, so the two must reach each other,
as they do in CI:

```sh
docker network create emulators
docker run -d --name pubsub --network emulators -p 8085:8085 \
    gcr.io/google.com/cloudsdktool/google-cloud-cli:emulators \
    gcloud beta emulators pubsub start --project=test --host-port=0.0.0.0:8085
docker run -d --name fake-gcs --network emulators -p 4443:4443 \
    -e PUBSUB_EMULATOR_HOST=pubsub:8085 \
    fsouza/fake-gcs-server:1.56.1 -backend memory -scheme http -port 4443 -public-host 127.0.0.1:4443
PUBSUB_EMULATOR_HOST=127.0.0.1:8085 STORAGE_EMULATOR_HOST=http://127.0.0.1:4443 \
    zig build test-integration
```

Without Docker, start fake-gcs-server with
`PUBSUB_EMULATOR_HOST=127.0.0.1:8085` in its environment.

### Cloud Storage against a real bucket

For what an emulator cannot show: every precondition enforced, checksums
checked by the server, gzip transcoding, uploads and downloads cut
mid-body that resume against Google itself, and transfers a second
client carries on from a checkpoint. Objects live under `zig-gcp-test/`
and are deleted. The token needs Storage Object Admin on the bucket,
which must not have object versioning on. It moves about 5.7 GiB over
the wire, 1 GiB of it in one object at a time.

```sh
GCP_TEST_BUCKET=my-bucket GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
    zig build test-integration-gcp
```

### Signed URLs and POST policies

Against a real bucket, the only place a signature is ever checked, and
the only place Cloud Storage says what it makes of a policy's
conditions. Name a key file, an account the token may sign as through
IAM, or both: each test runs once per signer. That account needs Storage
Object Admin on the bucket, since a URL or a policy grants what its
signer may do.

```sh
GCP_TEST_BUCKET=my-bucket GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
    GCP_TEST_SIGNER_KEY=key.json GCP_TEST_SIGNER_EMAIL=signer@my-project.iam.gserviceaccount.com \
    zig build test-integration-gcp
```

### Requester pays

As someone other than the bucket's owners: a requester pays bucket, and
an account with Storage Object Admin on it that may bill
`GCP_TEST_PROJECT` (Service Usage Consumer there) and that the token may
sign as through IAM. Without them those tests skip; the owners' test
needs `GCP_TEST_PROJECT` alone.

```sh
GCP_TEST_PROJECT=my-project GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
    GCP_TEST_REQUESTER_BUCKET=their-bucket GCP_TEST_REQUESTER_EMAIL=requester@my-project.iam.gserviceaccount.com \
    GCP_TEST_REQUESTER_TOKEN=$(gcloud auth print-access-token --impersonate-service-account=requester@my-project.iam.gserviceaccount.com) \
    zig build test-integration-gcp -Dtest-filter="requester pays"
```

### Encryption keys

The customer-supplied key tests draw keys of their own and need
`GCP_TEST_PROJECT` alone; the Cloud KMS test also needs a key in
us-central1 that the project's Cloud Storage service agent may use.

```sh
GCP_TEST_PROJECT=my-project GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
    GCP_TEST_KMS_KEY=projects/my-project/locations/us-central1/keyRings/my-ring/cryptoKeys/my-key \
    zig build test-integration-gcp -Dtest-filter="keys:"
```

### Notifications against Google

A bucket in the project, and a token allowed to manage its notifications
and to create Pub/Sub topics and subscriptions and set their policies.
Each test makes a `zigps-ntf-*` topic and subscription, and a
configuration for objects under that name, and deletes them all, even
when it fails.

```sh
GCP_TEST_PROJECT=my-project GCP_TEST_BUCKET=my-bucket \
    GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
    zig build test-integration-gcp -Dtest-filter="notifications against Google"
```
