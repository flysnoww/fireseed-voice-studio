#!/usr/bin/env python3
"""Wait for a specific App Store Connect upload to become a processed build."""

from __future__ import annotations

import argparse
import base64
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


API = "https://api.appstoreconnect.apple.com/v1"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def jwt_token(key_id: str, issuer_id: str, key_path: pathlib.Path) -> str:
    now = int(time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    claims = b64url(json.dumps({"iss": issuer_id, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}, separators=(",", ":")).encode())
    message = f"{header}.{claims}".encode()
    der_signature = subprocess.check_output(["openssl", "dgst", "-sha256", "-sign", str(key_path)], input=message)
    der = memoryview(der_signature)
    if len(der) < 8 or der[0] != 0x30:
        raise RuntimeError("OpenSSL returned an invalid ECDSA signature")
    offset = 2
    if der[1] & 0x80:
        offset = 2 + (der[1] & 0x7F)
    if der[offset] != 0x02:
        raise RuntimeError("OpenSSL returned an invalid ECDSA r component")
    r_len = der[offset + 1]
    r = bytes(der[offset + 2 : offset + 2 + r_len]).lstrip(b"\0")
    offset += 2 + r_len
    if der[offset] != 0x02:
        raise RuntimeError("OpenSSL returned an invalid ECDSA s component")
    s_len = der[offset + 1]
    s = bytes(der[offset + 2 : offset + 2 + s_len]).lstrip(b"\0")
    if len(r) > 32 or len(s) > 32:
        raise RuntimeError("OpenSSL returned an oversized ECDSA component")
    raw_signature = r.rjust(32, bytes([0])) + s.rjust(32, bytes([0]))
    return f"{header}.{claims}.{b64url(raw_signature)}"


def get_json(path: str, token: str) -> dict:
    request = urllib.request.Request(
        f"{API}{path}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"App Store Connect API returned HTTP {error.code}: {body}") from error


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer-id", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--timeout-minutes", type=int, default=150)
    args = parser.parse_args()

    encoded_key = os.environ.get("API_PRIVATE_KEY_BASE64")
    if not encoded_key:
        raise SystemExit("API_PRIVATE_KEY_BASE64 environment variable is required")
    key_path = pathlib.Path(os.environ.get("RUNNER_TEMP", ".")) / "voice-studio-asc-ingestion-key.p8"
    key_path.write_bytes(base64.b64decode(encoded_key, validate=True))
    os.chmod(key_path, 0o600)
    try:
        token = jwt_token(args.key_id, args.issuer_id, key_path)
        app_query = urllib.parse.urlencode({"filter[bundleId]": args.bundle_id})
        apps = get_json(f"/apps?{app_query}", token).get("data", [])
        app = next((item for item in apps if item.get("attributes", {}).get("bundleId") == args.bundle_id), None)
        if app is None:
            raise RuntimeError(f"No App Store Connect app found for bundle ID {args.bundle_id}")
        app_id = app["id"]
        print(f"App Store Connect app matched bundle ID {args.bundle_id}; app ID {app_id}")

        upload_query = urllib.parse.urlencode(
            {
                "filter[cfBundleShortVersionString]": args.version,
                "filter[cfBundleVersion]": args.build_number,
                "filter[platform]": "IOS",
                "fields[buildUploads]": "cfBundleShortVersionString,cfBundleVersion,state,platform,uploadedDate,createdDate,build",
                "include": "build",
            }
        )
        builds_query = urllib.parse.urlencode(
            {
                "filter[app]": app_id,
                "filter[preReleaseVersion.version]": args.version,
                "filter[preReleaseVersion.platform]": "IOS",
                "fields[builds]": "version,processingState,uploadedDate,minOsVersion,preReleaseVersion,buildUpload",
                "include": "preReleaseVersion,buildUpload",
                "limit": "200",
            }
        )
        deadline = time.monotonic() + args.timeout_minutes * 60
        while True:
            uploads_response = get_json(f"/apps/{app_id}/buildUploads?{upload_query}", token)
            uploads = [
                item for item in uploads_response.get("data", [])
                if item.get("attributes", {}).get("cfBundleShortVersionString") == args.version
                and item.get("attributes", {}).get("cfBundleVersion") == args.build_number
                and item.get("attributes", {}).get("platform") == "IOS"
            ]
            upload = max(uploads, key=lambda item: item.get("attributes", {}).get("createdDate", ""), default=None)
            if upload:
                upload_attrs = upload.get("attributes", {})
                print(f"Build upload {args.version} ({args.build_number}) state={upload_attrs.get('state')} uploadedDate={upload_attrs.get('uploadedDate')}")
                if upload_attrs.get("state") == "FAILED":
                    raise RuntimeError(f"App Store Connect build upload failed: {json.dumps(upload, sort_keys=True)}")

            builds_response = get_json(f"/builds?{builds_query}", token)
            build = next(
                (item for item in builds_response.get("data", []) if item.get("attributes", {}).get("version") == args.build_number),
                None,
            )
            if build:
                state = build.get("attributes", {}).get("processingState")
                print(f"App Store Connect build {args.version} ({args.build_number}) processingState={state}; build ID {build.get('id')}")
                if state == "VALID":
                    print("INGESTION VERIFIED: processed build is VALID")
                    return 0
                if state in {"INVALID", "FAILED"}:
                    raise RuntimeError(f"App Store Connect rejected build {args.version} ({args.build_number}): {json.dumps(build, sort_keys=True)}")
            elif upload and upload.get("attributes", {}).get("state") == "COMPLETE":
                print("Upload is COMPLETE; waiting for processed build resource")
            else:
                print("Waiting for matching App Store Connect upload and processed build")

            if time.monotonic() >= deadline:
                raise RuntimeError(f"App Store Connect did not expose build {args.version} ({args.build_number}) as VALID within {args.timeout_minutes} minutes")
            time.sleep(60)
    finally:
        key_path.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"App Store Connect ingestion verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
