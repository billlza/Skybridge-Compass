#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-${SMS_TEST_BASE_URL:-}}"
PHONE_NUMBER="${2:-${SMS_TEST_PHONE:-}}"
OTP_CODE="${3:-${SMS_TEST_OTP:-123456}}"
HOOK_SECRET="${SUPABASE_SEND_SMS_HOOK_SECRET:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ -z "$BASE_URL" ]]; then
    echo "[probe] FAIL: missing base URL. Pass arg #1 or set SMS_TEST_BASE_URL." >&2
    exit 1
fi

if [[ -z "$PHONE_NUMBER" ]]; then
    echo "[probe] FAIL: missing mainland phone number. Pass arg #2 or set SMS_TEST_PHONE." >&2
    exit 1
fi

if [[ -z "$HOOK_SECRET" ]]; then
    echo "[probe] FAIL: missing SUPABASE_SEND_SMS_HOOK_SECRET in environment." >&2
    exit 1
fi

if ! [[ "$PHONE_NUMBER" =~ ^(\+86)?1[3-9][0-9]{9}$ ]]; then
    echo "[probe] FAIL: phone number must be a mainland China mobile number." >&2
    exit 1
fi

if ! [[ "$OTP_CODE" =~ ^[0-9]{4,8}$ ]]; then
    echo "[probe] FAIL: OTP code must be 4-8 digits." >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

READY_FILE="$TMP_DIR/ready.json"
HOOK_HEADERS_FILE="$TMP_DIR/hook_headers.env"
HOOK_BODY_FILE="$TMP_DIR/hook_body.json"
HOOK_RESPONSE_FILE="$TMP_DIR/hook_response.json"

echo "[probe] checking readiness: $BASE_URL/readyz"
curl -fsS "$BASE_URL/readyz" -o "$READY_FILE"

node - "$READY_FILE" <<'NODE'
const fs = require('fs');
const path = process.argv[2];
const ready = JSON.parse(fs.readFileSync(path, 'utf8'));
if (ready.status !== 'ready') {
  console.error('[probe] FAIL: /readyz is not ready');
  console.error(JSON.stringify(ready, null, 2));
  process.exit(1);
}
if (!ready.smsReady) {
  console.error('[probe] FAIL: /readyz reports smsReady=false');
  console.error(JSON.stringify(ready, null, 2));
  process.exit(1);
}
if (ready.smsProvider !== 'pnvs') {
  console.error(`[probe] FAIL: expected smsProvider=pnvs, got ${ready.smsProvider}`);
  console.error(JSON.stringify(ready, null, 2));
  process.exit(1);
}
console.log('[probe] PASS: /readyz reports smsReady=true and smsProvider=pnvs');
NODE

export HOOK_SECRET OTP_CODE PHONE_NUMBER HOOK_HEADERS_FILE HOOK_BODY_FILE SERVER_DIR
node <<'NODE'
const fs = require('fs');
const crypto = require('crypto');
const path = require('path');
const { createRequire } = require('module');

const serverDir = process.env.SERVER_DIR;
const requireFromServer = createRequire(path.join(serverDir, 'package.json'));
const { Webhook } = requireFromServer('standardwebhooks');

const hookSecret = process.env.HOOK_SECRET;
const phoneNumber = process.env.PHONE_NUMBER;
const otpCode = process.env.OTP_CODE;
const headersPath = process.env.HOOK_HEADERS_FILE;
const bodyPath = process.env.HOOK_BODY_FILE;

const payload = JSON.stringify({
  user: { phone: phoneNumber },
  sms: { otp: otpCode }
});

const verifier = new Webhook(hookSecret);
const messageId = `probe_${crypto.randomUUID()}`;
const timestamp = new Date();
const signature = verifier.sign(messageId, timestamp, payload);

fs.writeFileSync(bodyPath, payload);
fs.writeFileSync(headersPath, [
  `WEBHOOK_ID=${messageId}`,
  `WEBHOOK_TIMESTAMP=${Math.floor(timestamp.getTime() / 1000)}`,
  `WEBHOOK_SIGNATURE=${signature}`
].join('\n'));
NODE

# shellcheck disable=SC1090
source "$HOOK_HEADERS_FILE"

MASKED_PHONE="${PHONE_NUMBER:0:3}****${PHONE_NUMBER: -4}"
echo "[probe] sending signed hook request for $MASKED_PHONE"
HOOK_STATUS="$(curl -sS -o "$HOOK_RESPONSE_FILE" -w '%{http_code}' \
    -X POST "$BASE_URL/api/hooks/supabase/send-sms" \
    -H 'Content-Type: application/json' \
    -H "webhook-id: $WEBHOOK_ID" \
    -H "webhook-timestamp: $WEBHOOK_TIMESTAMP" \
    -H "webhook-signature: $WEBHOOK_SIGNATURE" \
    --data-binary "@$HOOK_BODY_FILE")"

if [[ "$HOOK_STATUS" != "200" ]]; then
    echo "[probe] FAIL: hook returned status=$HOOK_STATUS" >&2
    cat "$HOOK_RESPONSE_FILE" >&2 || true
    exit 1
fi

echo "[probe] PASS: signed send_sms hook accepted"
echo "[probe] response body:"
cat "$HOOK_RESPONSE_FILE"
echo
echo "[probe] next step: confirm a successful record appears in PNVS sending history for $MASKED_PHONE"
