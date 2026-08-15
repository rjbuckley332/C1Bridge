#!/usr/bin/env python3
"""Minimal App Store Connect API helper for C1Bridge.

Reads creds from ~/.appstoreconnect (asc.env + private_keys/AuthKey_<KID>.p8).
Usage:
  asc.py get    /v1/apps?filter[bundleId]=ai.reachhigher.C1Bridge
  asc.py post   /v1/appStoreVersions '{"data":{...}}'
  asc.py patch  /v1/appStoreVersionLocalizations/<id> '{"data":{...}}'
Prints the JSON response body. No secrets are hardcoded here.
"""
import json, os, sys, time, uuid
import jwt, urllib.request, urllib.error

HOME = os.path.expanduser("~")
env = {}
for line in open(f"{HOME}/.appstoreconnect/asc.env"):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        env[k] = v.replace("$HOME", HOME)

KEY_ID, ISSUER_ID = env["ASC_KEY_ID"], env["ASC_ISSUER_ID"]
KEY_PATH = env.get("ASC_KEY_PATH", f"{HOME}/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")
with open(KEY_PATH) as f:
    PRIVATE_KEY = f.read()

def token():
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        PRIVATE_KEY, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"},
    )

def call(method, path, body=None):
    url = "https://api.appstoreconnect.apple.com" + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method.upper())
    req.add_header("Authorization", "Bearer " + token())
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read().decode()
            return r.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try: payload = json.loads(raw)
        except Exception: payload = raw
        return e.code, payload

if __name__ == "__main__":
    method, path = sys.argv[1], sys.argv[2]
    body = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    status, payload = call(method, path, body)
    print(f"HTTP {status}")
    print(json.dumps(payload, indent=2) if isinstance(payload, (dict, list)) else payload)
    sys.exit(0 if status < 400 else 1)
