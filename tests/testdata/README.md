# Test data

Files the test suites read. None of them ships in the package, whose
`build.zig.zon` lists only `src` and the top-level files.

## From Google's conformance tests

`v4_signatures.json` is copied unchanged from
[googleapis/conformance-tests](https://github.com/googleapis/conformance-tests),
`storage/v1/v4_signatures.json`: git blob
`40aa21cba378e8cc6976c4e8b5154878335d7a42`, last changed in commit
`905d67f` (2024-03-05), read at commit `998891a`. It is Google's statement
of V4 signed URLs: 29 signing vectors and 11 POST policy vectors, each with
its inputs and exact expected output. `tests/storage_signing.zig` runs the
signing vectors, and embeds the private key they are signed with, from
`storage/v1/test_service_account.not-a-test.json` in the same repository:
a key made for these tests, which grants nothing anywhere.

Both are licensed under the Apache License 2.0, whose text is in
`LICENSE-conformance-tests`. To update, copy the new file over this one
unchanged and check its blob hash against the upstream tree.

## Generated here

`signed_url_oracle.json` holds cases drawn at random and signed offline by
Google's Python library, google-cloud-storage, with a fixed timestamp.
`tools/signed_url_oracle.py` writes it, and its header says which version
of the library did.
