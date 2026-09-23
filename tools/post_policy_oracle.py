#!/usr/bin/env python3
"""Writes tests/testdata/post_policy_oracle.json: V4 POST policies drawn at
random, each signed offline by Google's own Python library,
google-cloud-storage, at a fixed time. tests/storage_signing.zig signs the
same cases and must produce the same URL and the same policy document.

The draw stays clear of the four places where that library departs from
this one, each tested elsewhere:

  - it sorts the caller's fields, so the draw sorts them too;
  - it prints a sub-second expiry when the clock has one, so the clock here
    is on a whole second;
  - it drops a field named `x-ignore-*` without a word, where this library
    refuses one, so none is drawn;
  - it has no way to say "any name under this prefix": its `key` condition
    is always exact. Prefix keys are covered by the goldens and the
    properties in src/storage/post_policy.zig.

The signatures themselves do not matter, so a throwaway key signs, and
only the document and the URL are recorded.

Usage: pip install google-cloud-storage, then
    tools/post_policy_oracle.py [count] > tests/testdata/post_policy_oracle.json
"""

import base64
import datetime
import json
import random
import subprocess
import sys
import tempfile
from importlib.metadata import version

from google.cloud import storage
from google.cloud.storage import client as client_module
from google.oauth2 import service_account

SEED = 20260923
EMAIL = "oracle@test-project.iam.gserviceaccount.com"
# Names a form can carry, and that Cloud Storage does not set itself.
FIELD_NAMES = ["acl", "cache-control", "content-disposition", "content-encoding",
               "content-type", "success_action_redirect", "x-goog-custom-time",
               "x-goog-meta-a", "x-goog-meta-note", "x-goog-meta-reviewer"]
# Every printable ASCII character, space included, and some UTF-8 of each length.
TEXT_CHARS = [chr(c) for c in range(0x20, 0x7F)] + ["é", "ß", "中", "文", "\U0001F600", "​"]


def draw_text(r, lo, hi):
    return "".join(r.choice(TEXT_CHARS) for _ in range(r.randint(lo, hi)))


def draw_object(r):
    """An object name without CR, LF, a control character, or a `.` or `..` segment."""
    while True:
        name = "".join(r.choice(TEXT_CHARS + ["/"] * 8) for _ in range(r.randint(1, 30)))
        if not any(segment in (".", "..") for segment in name.split("/")):
            return name


def draw_fields(r):
    """Sorted by name, as the library emits them whatever order it is given."""
    fields = {}
    for _ in range(r.randint(0, 4)):
        name = r.choice(FIELD_NAMES)
        if name == "success_action_redirect":
            value = r.choice(["http://example.com/done", "https://example.org/ok?a=b"])
        else:
            value = draw_text(r, 0, 20)
        fields[name] = value
    return dict(sorted(fields.items()))


def draw_conditions(r):
    conditions = []
    for _ in range(r.randint(0, 3)):
        if r.random() < 0.4:
            lo = r.randint(0, 1 << 20)
            conditions.append(["content-length-range", lo, lo + r.randint(0, 1 << 30)])
        else:
            conditions.append(["starts-with", "$" + r.choice(FIELD_NAMES), draw_text(r, 0, 12)])
        # One content-length-range to a policy, as this library requires.
        if sum(1 for c in conditions if c[0] == "content-length-range") > 1:
            conditions.pop()
    return conditions


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 400
    r = random.Random(SEED)
    with tempfile.TemporaryDirectory() as tmp:
        key_path = f"{tmp}/key.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:1024", "-out", key_path],
                       check=True, capture_output=True)
        pem = open(key_path).read()
    credentials = service_account.Credentials.from_service_account_info({
        "type": "service_account", "client_email": EMAIL, "private_key": pem,
        "token_uri": "https://oauth2.googleapis.com/token",
    })
    client = storage.Client(project="test-project", credentials=credentials)

    cases = []
    while len(cases) < count:
        bucket = r.choice(["photos", "test-bucket", "b0", "my-project-assets"])
        obj = draw_object(r)
        style = r.choices(["path", "virtual", "bound"], [70, 15, 15])[0]
        bound_host = r.choice(["media.example.com", "cdn.example.org"])
        bound_scheme = r.choice(["https", "http"])
        expires = r.randint(1, 604800)
        signed_at = r.randint(946684800, 4102444799)  # 2000 to 2099
        at = datetime.datetime.fromtimestamp(signed_at, datetime.timezone.utc)
        fields = draw_fields(r)
        conditions = draw_conditions(r)

        # The library reads the clock twice: once for x-goog-date, once for
        # the expiry. Both are pinned here, on a whole second.
        stamp = at.strftime("%Y%m%dT%H%M%SZ")
        client_module.get_v4_now_dtstamps = lambda stamp=stamp: (stamp, stamp[:8])
        client_module._NOW = lambda tz=None, at=at: at.replace(tzinfo=tz)

        out = client.generate_signed_post_policy_v4(
            bucket, obj, expiration=expires,
            # Copies: the library appends to the list it is given.
            conditions=[list(c) for c in conditions], fields=dict(fields),
            virtual_hosted_style=(style == "virtual"),
            bucket_bound_hostname=(bound_host if style == "bound" else None),
            scheme=bound_scheme,
        )
        document = base64.b64decode(out["fields"]["policy"]).decode("utf-8")
        assert document.startswith('{"conditions":['), document[:40]
        case = {
            "bucket": bucket, "object": obj, "expires": expires, "signedAt": signed_at,
            "style": style, "fields": list(fields.items()), "conditions": conditions,
            "url": out["url"], "policy": out["fields"]["policy"],
        }
        if style == "bound":
            case["boundHost"] = bound_host
            case["boundScheme"] = bound_scheme
        cases.append(case)

    # One case a line, so a regenerated file diffs by case.
    out = sys.stdout
    out.write('{"generator":"tools/post_policy_oracle.py",')
    out.write(f'"library":"google-cloud-storage {version("google-cloud-storage")}",')
    out.write(f'"seed":{SEED},"email":"{EMAIL}","cases":[\n')
    for i, case in enumerate(cases):
        out.write(json.dumps(case, ensure_ascii=False, separators=(",", ":")))
        out.write(",\n" if i + 1 < len(cases) else "\n")
    out.write("]}\n")


if __name__ == "__main__":
    main()
