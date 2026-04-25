#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_REF_FILE="$ROOT_DIR/supabase/.temp/project-ref"
FIX_MIGRATION="$ROOT_DIR/supabase/migrations/20260424190000_decouple_login_from_registration_guard.sql"
SCOPE_MIGRATION="$ROOT_DIR/supabase/migrations/20260424173000_scope_auth_risk_by_attempt_type.sql"
DNS_RESOLVER="${SUPABASE_DNS_RESOLVER:-native}"

info() {
  printf '[auth-login-guard-fix] %s\n' "$1"
}

die() {
  printf '[auth-login-guard-fix] ERROR: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" && "$line" != \#* && "$line" == *=* ]] || continue

    local key="${line%%=*}"
    local value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"

    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ -z "${!key:-}" ]]; then
      export "$key=$value"
    fi
  done < "$file"
}

rpc_login_probe() {
  python3 - "$1" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request
import uuid

mode = sys.argv[1]
url = os.environ.get("SUPABASE_URL", "").rstrip("/")
anon_key = os.environ.get("SUPABASE_ANON_KEY", "")
if not url or not anon_key:
    print("missing SUPABASE_URL or SUPABASE_ANON_KEY")
    sys.exit(2)

payload = {
    "identifier_hash": "0" * 64,
    "identifier_type": "email",
    "raw_identifier": f"login-guard-probe-{uuid.uuid4().hex}@example.invalid",
    "device_fingerprint": f"probe-{uuid.uuid4().hex}",
    "config_name": "login",
    "attempt_type": "login",
}
req = urllib.request.Request(
    f"{url}/rest/v1/rpc/guard_registration_attempt_v1",
    data=json.dumps(payload).encode(),
    method="POST",
    headers={
        "apikey": anon_key,
        "Authorization": f"Bearer {anon_key}",
        "Content-Type": "application/json",
    },
)

try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read().decode()
        status = resp.status
except urllib.error.HTTPError as exc:
    body = exc.read().decode()
    status = exc.code

print(f"rpc_status={status}")
print(body[:1200])

if mode == "expect-fixed":
    if status != 200:
        sys.exit(10)
    parsed = json.loads(body)
    row = parsed[0] if isinstance(parsed, list) else parsed
    if row.get("allowed") is not True:
        sys.exit(11)
    if row.get("requires_captcha") not in (False, None):
        sys.exit(12)
    if row.get("retry_after") is not None:
        sys.exit(13)
    if row.get("audit_ticket") is not None:
        sys.exit(14)
PY
}

require_command supabase
require_command python3

[[ -f "$PROJECT_REF_FILE" ]] || die "missing linked project ref at $PROJECT_REF_FILE"
[[ -f "$SCOPE_MIGRATION" ]] || die "missing prerequisite migration: $SCOPE_MIGRATION"
[[ -f "$FIX_MIGRATION" ]] || die "missing fix migration: $FIX_MIGRATION"

load_env_file "$ROOT_DIR/.env"
load_env_file "$ROOT_DIR/supabase_config.env"

PROJECT_REF="$(tr -d '[:space:]' < "$PROJECT_REF_FILE")"
[[ -n "$PROJECT_REF" ]] || die "linked project ref is empty"

info "workspace: $ROOT_DIR"
info "supabase cli: $(supabase --version 2>/dev/null | head -n 1)"
info "linked project ref: $PROJECT_REF"
info "dns resolver: $DNS_RESOLVER"
info "preflight REST probe; PGRST202 here means the remote is still on the old guard"
rpc_login_probe "preflight" || true

if [[ -z "${SUPABASE_DB_PASSWORD:-}" && -n "${PGPASSWORD:-}" ]]; then
  export SUPABASE_DB_PASSWORD="$PGPASSWORD"
fi

info "remote migration history before push"
supabase migration list --linked

info "dry-run database push"
supabase db push --dry-run --linked --dns-resolver "$DNS_RESOLVER"

info "applying pending migrations"
supabase db push --linked --dns-resolver "$DNS_RESOLVER"

info "post-deploy REST acceptance"
rpc_login_probe "expect-fixed"

info "done"
