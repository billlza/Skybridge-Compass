#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:8788}"
CLIENT_ID="${CLIENT_ID:-skybridge_compass_pro}"
REDIRECT_URI="${REDIRECT_URI:-skybridge://auth/nebula}"
USERNAME="${NEBULA_DEMO_USERNAME:-demo}"
PASSWORD="${NEBULA_DEMO_PASSWORD:-demo-pass}"

json_get() {
  python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"
}

VERIFIER="$(python3 - <<'PY'
import os, base64
print(base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip('='))
PY
)"

CHALLENGE="$(python3 - <<'PY' "$VERIFIER"
import sys, hashlib, base64
verifier = sys.argv[1].encode()
digest = hashlib.sha256(verifier).digest()
print(base64.urlsafe_b64encode(digest).decode().rstrip('='))
PY
)"

STATE="smoke-state"

echo "[smoke] base_url=$BASE_URL"
curl -fsS "$BASE_URL/health" >/dev/null
curl -fsS "$BASE_URL/.well-known/openid-configuration" >/dev/null

REQUEST_BODY="$(python3 - <<'PY' "$CLIENT_ID" "$REDIRECT_URI" "$CHALLENGE" "$STATE" "$USERNAME" "$PASSWORD"
import json, sys
client_id, redirect_uri, challenge, state, username, password = sys.argv[1:]
print(json.dumps({
    "response_type": "code",
    "client_id": client_id,
    "redirect_uri": redirect_uri,
    "scope": "openid profile email offline_access",
    "state": state,
    "code_challenge": challenge,
    "code_challenge_method": "S256",
    "username": username,
    "password": password
}))
PY
)"

AUTH_RESPONSE="$(curl -fsS "$BASE_URL/dev/authorize" \
  -H 'content-type: application/json' \
  -d "$REQUEST_BODY")"

CODE="$(printf '%s' "$AUTH_RESPONSE" | json_get code)"
RETURNED_STATE="$(printf '%s' "$AUTH_RESPONSE" | json_get state)"
if [ "$RETURNED_STATE" != "$STATE" ]; then
  echo "[smoke] FAIL: state mismatch" >&2
  exit 1
fi

TOKEN_RESPONSE="$(curl -fsS "$BASE_URL/oauth/token" \
  -H 'content-type: application/x-www-form-urlencoded' \
  --data-urlencode grant_type=authorization_code \
  --data-urlencode client_id="$CLIENT_ID" \
  --data-urlencode redirect_uri="$REDIRECT_URI" \
  --data-urlencode code="$CODE" \
  --data-urlencode code_verifier="$VERIFIER")"

ACCESS_TOKEN="$(printf '%s' "$TOKEN_RESPONSE" | json_get access_token)"
REFRESH_TOKEN="$(printf '%s' "$TOKEN_RESPONSE" | json_get refresh_token)"

USERINFO="$(curl -fsS "$BASE_URL/oauth/userinfo" -H "authorization: Bearer $ACCESS_TOKEN")"
SUBJECT="$(printf '%s' "$USERINFO" | json_get sub)"

REFRESH_RESPONSE="$(curl -fsS "$BASE_URL/oauth/token" \
  -H 'content-type: application/x-www-form-urlencoded' \
  --data-urlencode grant_type=refresh_token \
  --data-urlencode client_id="$CLIENT_ID" \
  --data-urlencode refresh_token="$REFRESH_TOKEN")"

NEW_ACCESS_TOKEN="$(printf '%s' "$REFRESH_RESPONSE" | json_get access_token)"

if [ -z "$ACCESS_TOKEN" ] || [ -z "$NEW_ACCESS_TOKEN" ] || [ -z "$SUBJECT" ]; then
  echo "[smoke] FAIL: empty token or subject" >&2
  exit 1
fi

echo "[smoke] PASS: PKCE authorize, token exchange, userinfo, and refresh all succeeded"
