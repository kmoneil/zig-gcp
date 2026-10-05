[Docs](../README.md) › [Cloud Storage](README.md) › HMAC keys

# HMAC keys

An HMAC key is a service account's second kind of credential: an access
ID and a secret. S3-style tools authenticate with one against Cloud
Storage's XML API, and this library signs URLs and POST policies with
one where no RSA key or IAM signing is at hand.

**On this page:** [Making and managing keys](#making-and-managing-keys) ·
[Signing with a key](#signing-with-a-key) ·
[Retries](#retries) · [What production does](#what-production-does)

## Making and managing keys

<!-- snippet: tests/docs_examples.zig#storage-hmac -->
```zig
/// Makes an HMAC key for a service account, signs a download URL with it,
/// and returns the URL in `gpa`'s memory. The secret is shown this once: a
/// real program stores it, as a credential, before `deinit` zeroes it.
fn signWithNewKey(gcs: *storage.Client, gpa: std.mem.Allocator, account: []const u8) ![]u8 {
    var key = try gcs.createHmacKey(account, .{});
    defer key.deinit();
    const signer: storage.UrlSigner = .{ .hmac = .{
        .access_id = key.value.info.access_id,
        .secret = key.value.secret,
    } };
    var url = try gcs.bucket("photos").object("cats/tom.jpg").signedUrl(signer, .{ .expires_in_s = 15 * 60 });
    defer url.deinit();
    return gpa.dupe(u8, url.value);
}

/// Retires a key: deactivated, then deleted. URLs it signed stop working
/// within minutes.
fn retireKey(gcs: *storage.Client, access_id: []const u8) !void {
    try gcs.hmacKey(access_id).deactivateAndDelete();
}
```

- `Client.createHmacKey(account, options)` makes a key for a service
  account of the project, `options.project` or `Options.project_id`. Its
  answer holds the secret, which Cloud Storage never shows again.
- `Client.listHmacKeys(options)` lists the project's keys, or one
  account's, a page at a time; `show_deleted` includes the deleted ones,
  listed for a while after.
- `Client.hmacKey(access_id)` hands out an `HmacKey`: `get`,
  `setState(.active or .inactive, options)`, `delete`, and
  `deactivateAndDelete`.

A key is active when made. Only an inactive key can be deleted. An
account holds at most 10 keys that are not deleted, inactive ones
included; the eleventh is `error.InvalidArgument`, "Service account HMAC
key limit reached".

> [!CAUTION]
> The secret is a credential that does not expire. It lives in memory
> that `deinit` zeroes, the response it came in included, and this
> library never logs it or puts it in `Diagnostics`. Keep it as you keep
> a service account key, and deactivate a key you no longer need.

## Signing with a key

`signedUrl` and `postPolicy` take a `UrlSigner`: `.{ .rsa = signer }` for
a service account's RSA key, or an HMAC key:

```zig
const signer: storage.UrlSigner = .{ .hmac = .{ .access_id = key.value.info.access_id, .secret = key.value.secret } };
var url = try gcs.bucket("photos").object("cats/tom.jpg").signedUrl(signer, .{ .expires_in_s = 15 * 60 });
defer url.deinit();
```

The URL names the access ID and signs with `GOOG4-HMAC-SHA256`;
everything else is as [Signed URLs](signed-urls.md) says. An HMAC signer
needs no I/O, and its URLs last until they expire, up to seven days, or
until the key is deactivated or deleted, which refuses them within
minutes (401 `KeyInactive`, `KeyDeleted`). A key signs from the moment it
exists.

Google publishes no conformance vectors for HMAC signing, so the tests
sign Google's RSA vectors again with an HMAC key
([`tools/hmac_vectors.py`](../../tools/hmac_vectors.py), Python's standard
library alone), and production checks a fresh key's URLs and POST
policy.

## Retries

| Call | Retried |
| --- | --- |
| `createHmacKey` | Never: a repeat makes a second key, idempotency token or not. A failure that may have made one says so in `Diagnostics`, and `listHmacKeys` finds it to delete |
| `get`, `listHmacKeys` | Yes |
| `setState` | Under `options.etag` |
| `delete` | Yes |

What a repeat meets is answered as done. A change to the state a key
already has ("Update must modify the credential.") answers the key as
read; so does a stale etag once a read finds the key in the state asked,
since Cloud Storage checks the etag first and a repeat of a change that
landed meets the etag its own change moved. A delete of a deleted key
("Key is already deleted.") is done.

## What production does

Measured on 2026-10-05:

- An access ID is 61 characters, `GOOG1E` and upper-case letters and
  digits; a secret 40 characters of base64, used as its text, never
  decoded.
- Cloud Storage's service agent cannot have keys (403 "is not in the
  project"); an account that does not exist is `error.NotFound`.
- A deleted key reads as `.deleted` until Cloud Storage forgets it.
- `userProject` is checked, not ignored as Google's libraries say, so
  this library never sends it here.
- A wrong signature and an unknown access ID are refused alike, 403
  `SignatureDoesNotMatch`.
