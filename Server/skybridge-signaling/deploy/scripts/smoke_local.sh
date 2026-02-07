#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:8443}"
API_KEY="${2:-${SKYBRIDGE_CLIENT_API_KEY:-skybridge-client-v1}}"

check_status() {
    local url="$1"
    local status
    status="$(curl -sS -o /tmp/skybridge-smoke-body.$$ -w '%{http_code}' "$url" || true)"
    if [[ -f /tmp/skybridge-smoke-body.$$ ]]; then
        cat /tmp/skybridge-smoke-body.$$ >/tmp/skybridge-smoke-last.$$ || true
    else
        : > /tmp/skybridge-smoke-last.$$
    fi
    rm -f /tmp/skybridge-smoke-body.$$
    echo "$status"
}

cleanup() {
    rm -f /tmp/skybridge-smoke-last.$$ || true
}
trap cleanup EXIT

echo "[smoke] Base URL: $BASE_URL"

root_status="$(check_status "$BASE_URL/")"
if [[ "$root_status" != "200" ]]; then
    echo "[smoke] FAIL: GET / status=$root_status" >&2
    cat /tmp/skybridge-smoke-last.$$ >&2
    exit 1
fi
if ! grep -q 'api/turn/credentials' /tmp/skybridge-smoke-last.$$; then
    echo "[smoke] FAIL: GET / does not advertise /api/turn/credentials" >&2
    cat /tmp/skybridge-smoke-last.$$ >&2
    exit 1
fi

echo "[smoke] PASS: GET /"

health_status="$(check_status "$BASE_URL/health")"
if [[ "$health_status" != "200" ]]; then
    echo "[smoke] FAIL: GET /health status=$health_status" >&2
    cat /tmp/skybridge-smoke-last.$$ >&2
    exit 1
fi

echo "[smoke] PASS: GET /health"

turn_no_key_status="$(curl -sS -o /tmp/skybridge-smoke-last.$$ -w '%{http_code}' "$BASE_URL/api/turn/credentials" || true)"
if [[ "$turn_no_key_status" == "404" ]]; then
    echo "[smoke] FAIL: GET /api/turn/credentials returned 404 (route not deployed)" >&2
    cat /tmp/skybridge-smoke-last.$$ >&2
    exit 1
fi
if [[ "$turn_no_key_status" != "200" && "$turn_no_key_status" != "401" && "$turn_no_key_status" != "503" ]]; then
    echo "[smoke] FAIL: GET /api/turn/credentials unexpected status=$turn_no_key_status" >&2
    cat /tmp/skybridge-smoke-last.$$ >&2
    exit 1
fi

echo "[smoke] PASS: GET /api/turn/credentials without key status=$turn_no_key_status"

turn_with_key_status="$(curl -sS -H "X-API-Key: $API_KEY" -o /tmp/skybridge-smoke-last.$$ -w '%{http_code}' "$BASE_URL/api/turn/credentials" || true)"
if [[ "$turn_with_key_status" == "404" || "$turn_with_key_status" == "401" ]]; then
    echo "[smoke] FAIL: GET /api/turn/credentials with key status=$turn_with_key_status" >&2
    cat /tmp/skybridge-smoke-last.$$ >&2
    exit 1
fi
if [[ "$turn_with_key_status" != "200" && "$turn_with_key_status" != "503" ]]; then
    echo "[smoke] FAIL: GET /api/turn/credentials with key unexpected status=$turn_with_key_status" >&2
    cat /tmp/skybridge-smoke-last.$$ >&2
    exit 1
fi

echo "[smoke] PASS: GET /api/turn/credentials with key status=$turn_with_key_status"
echo "[smoke] All checks passed"
