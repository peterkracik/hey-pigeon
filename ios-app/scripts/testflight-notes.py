#!/usr/bin/env python3
"""Set a TestFlight build's "What to Test" text through the App Store Connect API.

publish-ios runs this after the upload, with the list of changes since the
previous build. The text can only be written once Apple has finished
processing the build, so this waits for that first.

Usage: testflight-notes.py <notes-file>
Environment: ASC_KEY_PATH (the .p8 file), ASC_KEY_ID, ASC_ISSUER_ID,
ASC_APP_ID, APP_VERSION (marketing version), BUILD_NUMBER.
Optional: WAIT_MINUTES (default 30).

Standard library plus the `openssl` command only, so it runs on a bare runner.
"""

import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
LIMIT = 4000  # App Store Connect's limit for whatsNew
FALLBACK_LOCALE = "en-US"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def raw_signature(der: bytes) -> bytes:
    """openssl writes an ECDSA signature as DER; a JWT wants r and s, 32 bytes each."""
    if der[0] != 0x30:
        raise ValueError("not a DER signature")
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    parts = []
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("not a DER signature")
        length = der[i + 1]
        value = der[i + 2 : i + 2 + length].lstrip(b"\x00")
        parts.append(value.rjust(32, b"\x00"))
        i += 2 + length
    return b"".join(parts)


def token() -> str:
    """A fresh token per request: they live 20 minutes at most and the wait is longer."""
    header = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
    now = int(time.time())
    claims = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    signing_input = b64url(json.dumps(header).encode()) + "." + b64url(json.dumps(claims).encode())
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", os.environ["ASC_KEY_PATH"]],
        input=signing_input.encode(),
        capture_output=True,
        check=True,
    ).stdout
    return signing_input + "." + b64url(raw_signature(der))


def call(method: str, path: str, body: dict | None = None) -> dict:
    request = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            text = response.read()
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"{method} {path.split('?')[0]}: HTTP {error.code} {error.read().decode(errors='replace')[:500]}")
    return json.loads(text) if text else {}


def find_build() -> dict | None:
    query = urllib.parse.urlencode(
        {
            "filter[app]": os.environ["ASC_APP_ID"],
            "filter[version]": os.environ["BUILD_NUMBER"],
            "filter[preReleaseVersion.version]": os.environ["APP_VERSION"],
            "filter[preReleaseVersion.platform]": "IOS",
            "limit": "1",
        }
    )
    builds = call("GET", "/builds?" + query).get("data", [])
    return builds[0] if builds else None


def wait_for_build() -> dict:
    label = f"{os.environ['APP_VERSION']} ({os.environ['BUILD_NUMBER']})"
    deadline = time.time() + 60 * int(os.environ.get("WAIT_MINUTES", "30"))
    while True:
        state = "not listed yet"
        try:
            build = find_build()
        except (RuntimeError, OSError) as error:  # a blip must not end the wait
            build, state = None, f"lookup failed: {error}"
        if build:
            state = build["attributes"].get("processingState", "")
            if state == "VALID":
                return build
            if state in ("FAILED", "INVALID"):
                raise RuntimeError(f"Apple marked build {label} as {state}")
        if time.time() >= deadline:
            raise RuntimeError(f"build {label} was not processed in time ({state})")
        print(f"Build {label}: {state}; waiting…", flush=True)
        time.sleep(30)


def main() -> None:
    with open(sys.argv[1], encoding="utf-8") as file:
        notes = file.read().strip()
    if not notes:
        print("No notes to set.")
        return
    if len(notes) > LIMIT:
        notes = notes[: LIMIT - 1].rsplit("\n", 1)[0] + "\n…"

    build = wait_for_build()
    build_id = build["id"]
    existing = call("GET", f"/builds/{build_id}/betaBuildLocalizations?limit=50").get("data", [])
    for localization in existing:
        call(
            "PATCH",
            f"/betaBuildLocalizations/{localization['id']}",
            {"data": {"type": "betaBuildLocalizations", "id": localization["id"], "attributes": {"whatsNew": notes}}},
        )
    if not existing:
        call(
            "POST",
            "/betaBuildLocalizations",
            {
                "data": {
                    "type": "betaBuildLocalizations",
                    "attributes": {"locale": FALLBACK_LOCALE, "whatsNew": notes},
                    "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
                }
            },
        )
    print(f"What to Test set on build {os.environ['APP_VERSION']} ({os.environ['BUILD_NUMBER']}).")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # the caller decides how loud a failure is
        print(f"testflight-notes: {error}", file=sys.stderr)
        sys.exit(1)
