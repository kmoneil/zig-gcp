[Docs](../README.md) › [Cloud Storage](README.md) › Signed URLs and POST policies

# Signed URLs and POST policies

**On this page:** [Signed URLs](#signed-urls) ·
[Who can sign](#who-can-sign) ·
[POST policies: uploads from a plain HTML form](#post-policies-uploads-from-a-plain-html-form)

## Signed URLs

A signed URL lets someone with no credentials make one request on one
object until it expires: a browser downloading a private file, or
uploading straight into a bucket without the bytes passing through the
application.

```zig
var creds = try auth.findDefault(gpa, io, lookup, .{});
defer creds.deinit();
const signer = creds.signer() orelse return error.CannotSign;

var url = try gcs.bucket("photos").object("cats/tom.jpg").signedUrl(.{ .rsa = signer }, .{
    .expires_in_s = 15 * 60,
    .query = &.{.{ .name = "response-content-disposition", .value = "attachment; filename=\"tom.jpg\"" }},
});
defer url.deinit();
```

An upload URL can pin what the holder may send:

```zig
var put = try object.signedUrl(.{ .rsa = signer }, .{
    .method = .PUT,
    .expires_in_s = 10 * 60,
    .headers = &.{
        .{ .name = "content-type", .value = "image/png" },
        .{ .name = "x-goog-content-length-range", .value = "0,5242880" },
        .{ .name = "x-goog-if-generation-match", .value = "0" },
    },
});
```

The holder must send every signed header with the same value, and
cannot add a query parameter of their own: Cloud Storage refuses the
request otherwise. They must also send no `Authorization` header, even
an empty one, which would turn the request into an ordinary
authenticated one.

The URL points at the client's endpoint, so a client on the emulator
makes emulator URLs. `.style` chooses `.path` (the default),
`.virtual_hosted` for `bucket.storage.googleapis.com`, or a
`.bucket_bound` domain that serves one bucket.

> [!CAUTION]
> Treat the URL as a password: it is a bearer credential until it
> expires. The library never logs it or puts it in `Diagnostics`, and
> wipes the memory its signature passed through.

[`examples/gcs_sign.zig`](../../examples/gcs_sign.zig) prints one, with
the `curl` line that uses it:

```sh
zig build example-gcs_sign -- gs://my-bucket/reports/q3.txt
```

<details>
<summary><b>📏 Measured against a real bucket on 2026-09-22</b></summary>

| The request | The answer |
| --- | --- |
| A URL past its expiry | 400 `ExpiredToken` |
| A URL dated more than 15 minutes ahead | 403 `AccessDenied` |
| A changed signature, header or parameter | 403 `SignatureDoesNotMatch`, carrying the canonical request Google computed |
| A signed DELETE | 204 |
| A signed POST with `x-goog-resumable: start` | 201, and a session URI that takes the bytes with no signature |
| A body that does not match a signed `x-goog-content-sha256` | stored: the header is signed, but the body is not hashed against it |

</details>

## Who can sign

Who can sign, as `Credentials.signer()` decides:

| Credentials | Signs | What it needs |
| --- | --- | --- |
| A service account key file | on this machine | nothing else |
| A login impersonating a service account | through IAM, as the target | the Token Creator role impersonation already needs |
| A workload on Google Cloud | through IAM, as its attached account | Token Creator on itself, and the `cloud-platform` access scope |
| A user's own login, or workload identity federation | nothing: `signer()` is null | name an account through `auth.IamSigner` |

Google rotates the key IAM signs with and promises each for 12 hours, so
a URL signed through IAM may last no longer, and `signedUrl` refuses a
longer one before asking IAM. A key file's URL may last the seven days
Cloud Storage allows.

Each of those signs as `.{ .rsa = signer }`. An [HMAC key](hmac.md) signs
too, as `.{ .hmac = .{ .access_id, .secret } }`: with
`GOOG4-HMAC-SHA256`, on this machine, with no credentials at all, for up
to seven days or until the key is deactivated or deleted.

## POST policies: uploads from a plain HTML form

A signed URL allows one request. A POST policy allows one kind of
request, which is what a browser form needs: a form cannot send the
headers a signed PUT pins, and the person at the browser picks the file,
so its name is not known when the policy is signed.

```zig
var policy = try gcs.bucket("photos").postPolicy(.{ .rsa = signer }, .{
    .expires_in_s = 15 * 60,
    // Any name under the prefix: the browser chooses the rest.
    .key = .{ .starts_with = "avatars/" },
    .fields = &.{.{ .name = "content-type", .value = "image/png" }},
    .conditions = &.{.{ .content_length_range = .{ .min = 1, .max = 5 << 20 } }},
});
defer policy.deinit();
```

`policy.value.url` is where the form posts, and `policy.value.fields`
are its hidden inputs. Write them into a `<form method="post"
enctype="multipart/form-data">` and add `<input type="file" name="file">`
last: Cloud Storage reads the fields before the bytes. With a prefix key
the `key` field ends in Google's `${filename}`, which Cloud Storage
replaces with the name of the file the browser sent.

`Object.postPolicy` names one object exactly instead, and takes no
`key`.

A policy is a whitelist. Every field the form sends must be in it, with
the value it states, or as a `.starts_with` condition for one the
browser chooses. `content_length_range` bounds the body, which is the
one condition a signed URL cannot express for a form. Signing is the
same as for a URL, so [Who can sign](#who-can-sign) applies unchanged: a
key file signs here, IAM signs for the rest, and the 12-hour limit is
the same.

The fields are a bearer credential together, so the library never logs
the document or the signature. `examples/gcs_sign.zig` prints a ready
form; end the target with `/` to allow a prefix:

```sh
zig build example-gcs_sign -- gs://my-bucket/uploads/ --post-policy --put image/png
```

<details>
<summary><b>📏 Measured against a real bucket on 2026-09-23</b></summary>

| The form | The answer |
| --- | --- |
| Everything the policy allows | 204, or `success_action_status`'s 200 or 201, whose body names the bucket, key, location and etag |
| With `success_action_redirect` | 303 to that URL, with what was stored in its query |
| A field whose value contradicts its condition | 400 `InvalidPolicyDocument`, whose `Details` quotes the condition that failed |
| A field the policy never mentions | 400 `InvalidPolicyDocument` |
| A key outside a `starts_with` prefix | 400 `InvalidPolicyDocument` |
| A body over or under `content_length_range` | 400 `EntityTooLarge` or `EntityTooSmall` |
| A policy past its expiry | 400 `InvalidPolicyDocument`, where an expired URL is `ExpiredToken` |
| A changed signature | 403 `SignatureDoesNotMatch`, carrying the policy document Google read |

</details>
