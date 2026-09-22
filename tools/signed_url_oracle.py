#!/usr/bin/env python3
"""Writes tests/testdata/signed_url_oracle.json: V4 signed URL cases drawn
at random, each signed offline by Google's own Python library,
google-cloud-storage, with a fixed timestamp. tests/storage_signing.zig
signs the same cases and must produce the same URL and string to sign.

The draw stays clear of the three places where that library departs from
Google's conformance vectors or from this one, each tested elsewhere: a
query name that is a prefix of another (it sorts whole `name=value`
strings), an endpoint with a port (it signs the port), and a header value
outside printable ASCII (it raises).

The signatures themselves do not matter, so a throwaway key signs.

Usage: pip install google-cloud-storage, then
    tools/signed_url_oracle.py [count] > tests/testdata/signed_url_oracle.json
"""

import datetime
import json
import random
import subprocess
import sys
import tempfile
from importlib.metadata import version
from urllib.parse import quote

from google.cloud.storage import _signing
from google.oauth2 import service_account

SEED = 20260922
EMAIL = "oracle@test-project.iam.gserviceaccount.com"
RESERVED = {"x-goog-algorithm", "x-goog-credential", "x-goog-date", "x-goog-expires",
            "x-goog-signedheaders", "x-goog-signature"}
# Every printable ASCII character, space included, and some UTF-8 of each length.
NAME_CHARS = [chr(c) for c in range(0x20, 0x7F)] + ["\u00e9", "\u00df", "\u4e2d", "\u6587", "\U0001F600", "\u200b"]
HEADER_NAMES = ["content-type", "cache-control", "content-disposition", "x-goog-if-generation-match",
                "x-goog-content-length-range", "x-goog-meta-reviewer", "x-goog-meta-a", "x-goog-resumable"]
TOKEN_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!#$%&'*+^`|~/"


def draw_object(r):
    """An object name without CR, LF, or a `.` or `..` segment."""
    while True:
        name = "".join(r.choice(NAME_CHARS + ["/"] * 8) for _ in range(r.randint(1, 30)))
        if not any(segment in (".", "..") for segment in name.split("/")):
            return name


def draw_value(r):
    """Printable ASCII with runs of spaces and tabs anywhere."""
    out = []
    for _ in range(r.randint(0, 20)):
        out.append(r.choice([" ", "\t", "  ", " \t "]) if r.random() < 0.25 else chr(r.randint(0x21, 0x7E)))
    return "".join(out)


def draw_headers(r):
    headers = {}
    for _ in range(r.randint(0, 4)):
        name = r.choice(HEADER_NAMES) if r.random() < 0.6 else "".join(r.choice(TOKEN_CHARS) for _ in range(r.randint(1, 12)))
        name = "".join(c.upper() if r.random() < 0.3 else c for c in name)
        if name.lower() == "host" or any(k.lower() == name.lower() for k in headers):
            continue
        headers[name] = draw_value(r)
    return headers


def draw_query(r):
    query = {}
    for _ in range(r.randint(0, 4)):
        name = "".join(r.choice(NAME_CHARS + ["/", "&", "="]) for _ in range(r.randint(1, 10)))
        encoded = quote(name, safe="~")
        taken = [quote(k, safe="~") for k in query]
        if (name.lower() in RESERVED or name.lower().startswith("x-goog-")
                or any(encoded.startswith(t) or t.startswith(encoded) for t in taken)):
            continue
        query[name] = "".join(r.choice(NAME_CHARS + ["/", "&", "="]) for _ in range(r.randint(0, 12)))
    return query


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
    captured = []
    original = service_account.Credentials.sign_bytes

    def spy(self, message):
        captured.append(message.decode())
        return original(self, message)

    service_account.Credentials.sign_bytes = spy

    cases = []
    while len(cases) < count:
        bucket = r.choice(["photos", "test-bucket", "b0", "my-project-assets"])
        obj = None if r.random() < 0.1 else draw_object(r)
        style = r.choices(["path", "virtual", "bound"], [70, 15, 15])[0]
        bound_host = r.choice(["media.example.com", "cdn.example.org"])
        bound_scheme = r.choice(["https", "http"])
        method = r.choice(["GET", "HEAD", "PUT", "POST", "DELETE"])
        expires = r.randint(1, 604800)
        signed_at = r.randint(946684800, 4102444799)  # 2000 to 2099
        stamp = datetime.datetime.fromtimestamp(signed_at, datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        headers = draw_headers(r)
        query = draw_query(r)

        encoded = quote(obj, safe="/~") if obj is not None else None
        if style == "path":
            endpoint = "https://storage.googleapis.com"
            resource = f"/{bucket}" + (f"/{encoded}" if encoded is not None else "")
        elif style == "virtual":
            endpoint = f"https://{bucket}.storage.googleapis.com"
            resource = "/" + (encoded or "")
        else:
            endpoint = f"{bound_scheme}://{bound_host}"
            resource = "/" + (encoded or "")

        captured.clear()
        # Copies: the library adds a Host entry to the headers dict it is given.
        url = _signing.generate_signed_url_v4(
            credentials, resource, expiration=expires, api_access_endpoint=endpoint, method=method,
            headers=dict(headers) or None, query_parameters=dict(query) or None, _request_timestamp=stamp,
        )
        string_to_sign = captured[0].split("\n")
        assert string_to_sign[:3] == ["GOOG4-RSA-SHA256", stamp, stamp[:8] + "/auto/storage/goog4_request"]
        case = {
            "bucket": bucket, "object": obj, "method": method, "expires": expires, "signedAt": signed_at,
            "style": style, "headers": list(headers.items()), "query": list(query.items()),
            "url": url.split("&X-Goog-Signature=")[0], "hash": string_to_sign[3],
        }
        if style == "bound":
            case["boundHost"] = bound_host
            case["boundScheme"] = bound_scheme
        cases.append(case)

    # One case a line, so a regenerated file diffs by case.
    out = sys.stdout
    out.write('{"generator":"tools/signed_url_oracle.py",')
    out.write(f'"library":"google-cloud-storage {version("google-cloud-storage")}",')
    out.write(f'"seed":{SEED},"email":"{EMAIL}","cases":[\n')
    for i, case in enumerate(cases):
        out.write(json.dumps(case, ensure_ascii=False, separators=(",", ":")))
        out.write(",\n" if i + 1 < len(cases) else "\n")
    out.write("]}\n")


if __name__ == "__main__":
    main()
