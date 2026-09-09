#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1-http://127.0.0.1:8443}"
# An explicitly empty second argument keeps the deployment probes credential-free.
API_KEY="${2-${SKYBRIDGE_CLIENT_API_KEY:-}}"
EXPECTED_BUILD_FINGERPRINT="${3-${SKYBRIDGE_EXPECTED_SERVER_BUILD_FINGERPRINT:-}}"

for command_name in curl node mktemp; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "[smoke] FAIL: required command missing: $command_name" >&2
        exit 1
    fi
done

BASE_URL="$(node - "$BASE_URL" "$EXPECTED_BUILD_FINGERPRINT" <<'VALIDATE_INPUT'
const [base, expected] = process.argv.slice(2);
function fail(message) {
  console.error(`[smoke] FAIL: ${message}`);
  process.exit(1);
}
if (!expected || expected.length > 256 || /[\u0000-\u001f\u007f]/.test(expected)) {
  fail('an explicit expected server build fingerprint is required');
}
let url;
try { url = new URL(base); } catch { fail('invalid base URL'); }
if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
  fail('base URL must be HTTP(S) without credentials, query or fragment');
}
if (/[\u0000-\u0020\u007f]/.test(base)) fail('base URL contains whitespace or control characters');
url.pathname = url.pathname.replace(/\/+$/, '');
console.log(url.toString().replace(/\/$/, ''));
VALIDATE_INPUT
)"

PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-signaling-smoke.XXXXXX")"
cleanup() {
    rm -rf -- "$PROBE_DIR"
}
trap cleanup EXIT

probe() {
    local contract="$1"
    local method="$2"
    local path="$3"
    local status
    local curl_args=(--disable --silent --show-error --connect-timeout 5 --max-time 15
        --max-filesize 1048576 --proto '=http,https' --request "$method"
        --header 'Accept: application/json' --output "$PROBE_DIR/body.json" --write-out '%{http_code}')
    if [[ "$method" == "POST" ]]; then
        curl_args+=(--header 'Content-Type: application/json' --data '{}')
    fi
    if [[ "$contract" == "turn_authenticated" ]]; then
        curl_args+=(--header "X-API-Key: $API_KEY")
    fi
    if ! status="$(curl "${curl_args[@]}" "$BASE_URL$path")"; then
        echo "[smoke] FAIL: $method $path transport failure" >&2
        return 1
    fi
    node - "$PROBE_DIR/body.json" "$contract" "$method" "$path" "$status" "$EXPECTED_BUILD_FINGERPRINT" <<'VERIFY_RESPONSE'
const fs = require('node:fs');
const [bodyPath, contract, method, path, rawStatus, expected] = process.argv.slice(2);
const status = Number(rawStatus);
function fail(reason) {
  console.error(`[smoke] FAIL: ${method} ${path} status=${rawStatus} ${reason}`);
  process.exit(1);
}
let body;
try { body = JSON.parse(fs.readFileSync(bodyPath, 'utf8')); } catch { fail('response is not valid JSON'); }
if (!body || typeof body !== 'object' || Array.isArray(body)) fail('response must be a JSON object');
if (['root', 'health', 'ready'].includes(contract)) {
  if (status !== 200) fail('expected HTTP 200');
  if (body.serverBuildFingerprint !== expected) fail('server build fingerprint does not match the candidate');
}
switch (contract) {
  case 'root':
    if (body.ok !== true || body.service !== 'skybridge-signaling') fail('unexpected service identity');
    for (const endpoint of ['/api/turn/credentials', '/api/presence/register', '/api/devices/list']) {
      if (!Array.isArray(body.endpoints) || !body.endpoints.includes(endpoint)) fail(`missing advertised endpoint ${endpoint}`);
    }
    break;
  case 'health':
    if (!body.sms || typeof body.sms !== 'object' || Array.isArray(body.sms)) fail('missing SMS readiness block');
    break;
  case 'ready':
    if (body.status !== 'ready') fail('service did not report ready');
    break;
  case 'account_authentication':
    if (status !== 401 || body.error !== 'missing_bearer_token') fail('expected HTTP 401 missing_bearer_token');
    break;
  case 'turn':
    if (![200, 401, 503].includes(status)) fail('unexpected TURN status');
    break;
  case 'turn_authenticated':
    if (![200, 503].includes(status)) fail('unexpected authenticated TURN status');
    break;
  default:
    fail('unknown probe contract');
}
console.log(`[smoke] PASS: ${method} ${path} status=${status}`);
VERIFY_RESPONSE
}

echo "[smoke] Base URL: $BASE_URL"
probe root GET /
probe health GET /health
probe ready GET /readyz
probe account_authentication POST /api/presence/register
probe account_authentication GET /api/devices/list
probe turn GET /api/turn/credentials

if [[ -n "$API_KEY" ]]; then
    probe turn_authenticated GET /api/turn/credentials
fi

echo "[smoke] Verified candidate build: $EXPECTED_BUILD_FINGERPRINT"
echo "[smoke] Deployment contract checks passed"
