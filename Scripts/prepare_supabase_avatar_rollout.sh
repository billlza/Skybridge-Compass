#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_REF_FILE="$ROOT_DIR/supabase/.temp/project-ref"
FUNCTION_NAME="avatar-finalize"
MIGRATION_GLOB="$ROOT_DIR/supabase/migrations/*_avatar_b2_nebula_frozen.sql"

info() {
  printf '[info] %s\n' "$1"
}

warn() {
  printf '[warn] %s\n' "$1" >&2
}

die() {
  printf '[error] %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_command supabase
require_command rg

[[ -f "$PROJECT_REF_FILE" ]] || die "missing linked project ref at $PROJECT_REF_FILE"

PROJECT_REF="$(tr -d '[:space:]' < "$PROJECT_REF_FILE")"
[[ -n "$PROJECT_REF" ]] || die "linked project ref is empty"

info "workspace: $ROOT_DIR"
info "supabase cli: $(supabase --version | head -n 1)"
info "linked project ref: $PROJECT_REF"

LOCAL_MIGRATIONS="$(find "$ROOT_DIR/supabase/migrations" -maxdepth 1 -type f -name '*.sql' | sort)"
[[ -n "$LOCAL_MIGRATIONS" ]] || die "no local migrations found under supabase/migrations"

info "local avatar migration:"
printf '%s\n' "$LOCAL_MIGRATIONS" | rg 'avatar_b2_nebula_frozen\.sql' || die "expected avatar migration is missing"

info "remote migration history:"
supabase migration list --linked || warn "unable to list remote migrations"

info "remote edge functions:"
FUNCTIONS_OUTPUT="$(supabase functions list || true)"
printf '%s\n' "$FUNCTIONS_OUTPUT"
if printf '%s\n' "$FUNCTIONS_OUTPUT" | rg -q "(^|[[:space:]])${FUNCTION_NAME}([[:space:]]|$)"; then
  info "remote function ${FUNCTION_NAME} already exists and will be updated"
else
  warn "remote function ${FUNCTION_NAME} does not exist yet and will be created on deploy"
fi

info "local function entrypoint:"
FUNCTION_ENTRY="$ROOT_DIR/supabase/functions/${FUNCTION_NAME}/index.ts"
[[ -f "$FUNCTION_ENTRY" ]] || die "missing function entrypoint: $FUNCTION_ENTRY"
printf '%s\n' "$FUNCTION_ENTRY"

info "dry-run database push (best effort, network dependent):"
if supabase db push --dry-run --linked --dns-resolver https; then
  info "dry-run database push succeeded"
else
  warn "dry-run database push failed. If this is a network timeout, keep VPN on and retry with --dns-resolver https."
fi

cat <<EOF

Next deploy commands:
  supabase db push --linked --dns-resolver https
  supabase functions deploy ${FUNCTION_NAME} --project-ref ${PROJECT_REF} --use-api

Post-deploy acceptance artifacts:
  Docs/ops/avatar-b-supabase-rollout.md
  supabase/verification/avatar_post_deploy_acceptance.sql

EOF
