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

To fuzz, run `zig build test -Dfuzz-runner -Dtest-filter=fuzz --fuzz=100K`.

## Changes

- `main` is protected: open a pull request, and CI must pass before it
  merges.
- A bug fix comes with a test that fails without it. When the fuzzer finds
  a failing input, add that input to the property's corpus.
- User-visible changes go in `CHANGELOG.md`. Until 1.0, minor versions may
  break the API; say how in the changelog entry.
- Follow the existing code: `zig fmt`, doc comments on public declarations,
  camelCase functions, snake_case fields and variables, and TitleCase types.
