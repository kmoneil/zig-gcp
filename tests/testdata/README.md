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
its inputs and exact expected output. `tests/storage_signing.zig` runs both
sets, and embeds the private key they are signed with, from
`storage/v1/test_service_account.not-a-test.json` in the same repository:
a key made for these tests, which grants nothing anywhere.

One trap in the POST policy half: `policyOutput.expectedDecodedPolicy` is
not the bytes that were signed. This file is JSON, so it cannot hold the
`\uXXXX` escapes the real document carries, and the two disagree for the
two vectors with a `é` in them. The base64 `policy` field is the truth.

Both are licensed under the Apache License 2.0, whose text is in
`LICENSE-conformance-tests`. To update, copy the new file over this one
unchanged and check its blob hash against the upstream tree.

## Generated here

`signed_url_oracle.json` and `post_policy_oracle.json` hold cases drawn at
random and signed offline by Google's Python library,
google-cloud-storage, with a fixed timestamp. `tools/signed_url_oracle.py`
and `tools/post_policy_oracle.py` write them, and each file's header says
which version of the library and which seed.

Both are reproducible: the same script, seed and library version write the
same bytes, and a larger count extends the file without changing the cases
already in it. That is how the signed URL file went from 400 cases to 800
on 2026-09-23 with the first 400 untouched. Regenerate with

    tools/signed_url_oracle.py 800 > tests/testdata/signed_url_oracle.json
    tools/post_policy_oracle.py 400 > tests/testdata/post_policy_oracle.json

and read each script's header for what the draw stays clear of, and why.
