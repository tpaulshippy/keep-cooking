#!/usr/bin/env python3
"""Minimal App Store Connect API helper (JWT via .p8, no secrets in repo).

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
Usage: asc.py apps | create-app | create-bundle-id [identifier] [name] | get /v1/path

Smidgen bundle IDs (upload set — app + widgets + share ONLY):
  org.smidgen.app          (Smidgen app)
  org.smidgen.app.widgets  (SmidgenWidgets extension)
  org.smidgen.app.share    (SmidgenShare extension)
NOTE: org.smidgen.app.watch (SmidgenWatch) is a standalone watchOS app and
is intentionally OUT of the upload set (pair at distribution time).

Requires: pip install PyJWT (ES256 JWT signing)
"""
import json
import os
import sys
import time
import urllib.request

import jwt

KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER_ID = os.environ["ASC_ISSUER_ID"]
KEY_PATH = os.environ["ASC_KEY_PATH"]
BASE = "https://api.appstoreconnect.apple.com"

APP_BUNDLE_ID = "org.smidgen.app"
EXTENSION_BUNDLE_IDS = ("org.smidgen.app.widgets", "org.smidgen.app.share")
# Out of the upload set — see NOTE above.
WATCH_BUNDLE_ID = "org.smidgen.app.watch"


def token():
    with open(KEY_PATH) as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BASE + path,
        data=data,
        method=method,
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: asc.py apps | create-app | create-bundle-id [id] [name] | get /v1/path")
    cmd = sys.argv[1]
    if cmd == "get":
        # Generic read helper, e.g.:
        #   asc.py get /v1/ciProducts?filter[productType]=APP
        #   asc.py get /v1/ciProducts/<productId>/workflows
        status, out = call("GET", sys.argv[2])
        print(json.dumps({"status": status, "result": out}, indent=1)[:4000])
    elif cmd == "apps":
        status, out = call("GET", f"/v1/apps?filter[bundleId]={APP_BUNDLE_ID}&limit=1")
        print(json.dumps({"status": status, "apps": out.get("data", [])}, indent=1))
    elif cmd == "create-app":
        status, out = call(
            "POST",
            "/v1/apps",
            {"data": {"type": "apps", "attributes": {
                "bundleId": APP_BUNDLE_ID,
                "name": "Smidgen",
                "primaryLocale": "en-US",
                "sku": "smidgen",
            }}},
        )
        print(json.dumps({"status": status, "result": out}, indent=1)[:2000])
    elif cmd == "create-bundle-id":
        identifier = sys.argv[2] if len(sys.argv) > 2 else EXTENSION_BUNDLE_IDS[0]
        name = sys.argv[3] if len(sys.argv) > 3 else identifier
        status, out = call(
            "POST",
            "/v1/bundleIds",
            {"data": {"type": "bundleIds", "attributes": {
                "identifier": identifier,
                "name": name,
                "platform": "IOS",
            }}},
        )
        print(json.dumps({"status": status, "result": out}, indent=1)[:2000])
    elif cmd == "create-cert":
        csr = open(sys.argv[2]).read()
        status, out = call(
            "POST",
            "/v1/certificates",
            {"data": {"type": "certificates", "attributes": {
                "certificateType": "DISTRIBUTION",
                "csrContent": csr,
            }}},
        )
        print(json.dumps({"status": status, "result": out}, indent=1)[:3000])
    elif cmd == "create-profile":
        bundle_id, cert_id = sys.argv[2], sys.argv[3]
        status, out = call(
            "POST",
            "/v1/profiles",
            {"data": {"type": "profiles", "attributes": {
                "name": "Smidgen AppStore",
                "profileType": "IOS_APP_STORE",
            }, "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
                "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
            }}},
        )
        print(json.dumps({"status": status, "result": out}, indent=1)[:3000])
    else:
        sys.exit(f"unknown command: {cmd}")


if __name__ == "__main__":
    main()
