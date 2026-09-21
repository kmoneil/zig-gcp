# Contributing

Bug reports, fixes and improvements are welcome. For anything larger than a
small fix, open an issue first so the approach can be agreed on.

## Setup

You need Zig 0.16.0. The README's Development section lists every build
step; these are the ones to know:

```
zig build test          # unit, property and fuzz-corpus tests
zig build fmt           # zig fmt --check
zig build test-integration
```

Integration tests skip unless a server is configured. Start the Pub/Sub
emulator and point `PUBSUB_EMULATOR_HOST` at it:

```
gcloud beta emulators pubsub start --project=test --host-port=127.0.0.1:8085
PUBSUB_EMULATOR_HOST=127.0.0.1:8085 zig build test-integration
```

The step also runs `tests/fault_injection.zig`: the whole stack against the
emulator, through a proxy that drops, cuts, delays and rewrites responses.
Those tests need the emulator specifically and never target production.

The auth integration tests run against Google when `AUTH_TEST_CREDENTIALS`
names a credentials file, of type `authorized_user` or `service_account`;
each test runs when the file is the type it exercises. The README shows how.

The metadata server can only be checked where there is one. One test skips
unless a probe answers, and `examples/whoami.zig` shows the same path by
hand. To run it on a VM, with everything named `zigps-` so the cleanup is
obvious:

```
zig build-exe -target x86_64-linux-musl -O ReleaseSafe \
    --dep pubsub --dep auth -Mroot=examples/whoami.zig \
    --dep core -Mpubsub=src/pubsub/root.zig \
    --dep core -Mauth=src/auth/root.zig \
    -Mcore=src/core/root.zig -femit-bin=whoami
gcloud storage cp whoami gs://zigps-oncloud-$USER/whoami
gcloud compute instances create zigps-oncloud-$USER --zone=us-central1-a \
    --machine-type=e2-micro --image-family=debian-12 \
    --image-project=debian-cloud \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --metadata-from-file=startup-script=run.sh   # downloads and runs whoami
gcloud compute instances get-serial-port-output zigps-oncloud-$USER \
    --zone=us-central1-a
gcloud compute instances delete zigps-oncloud-$USER \
    --zone=us-central1-a --quiet
gcloud storage rm -r gs://zigps-oncloud-$USER
```

The instance needs the `cloud-platform` scope: the default scopes leave out
Pub/Sub, so the token comes back fine and the API call fails. Delete the
instance and the bucket as soon as the output is in hand.

To fuzz, run `zig build test -Dfuzz-runner -Dtest-filter=fuzz --fuzz=100K`.
For line coverage, install [kcov](https://github.com/SimonKagstrom/kcov) and
run `zig build coverage`; the report is `zig-out/coverage/index.html`.

## Changes

- `main` is protected: open a pull request, and CI must pass before it
  merges. Six checks are required by name: `test`, `release (ReleaseSafe)`,
  `release (ReleaseFast)`, `platforms (macos-latest)`,
  `platforms (windows-latest)` and `coverage`. Renaming one of those jobs,
  or changing a matrix value that appears in its name, leaves every pull
  request waiting for a check that will never report; change the rule for
  `main` in the same breath. The nightly `fuzz` jobs, one per module, are
  not required, because they do not run on pull requests.
- A bug fix comes with a test that fails without it. When the fuzzer finds
  a failing input, add that input to the property's corpus. The fuzzer
  saves it as `.zig-cache/f/crash`, and the nightly CI run attaches it as
  the `fuzz-failure-<module>` artifact: a 4-byte little-endian length, then
  the input. `zig build test -Dfuzz-runner -Dmodule=<module> --fuzz` fuzzes
  one module the way that job does.
- User-visible changes go in `CHANGELOG.md`. Until 1.0, minor versions may
  break the API; say how in the changelog entry.
- Follow the existing code: `zig fmt`, doc comments on public declarations,
  camelCase functions, snake_case fields and variables, and TitleCase types.
