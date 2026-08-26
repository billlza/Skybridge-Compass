#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIFECYCLE_PRODUCER="$ROOT_DIR/Scripts/run_formal_ios_identity_lifecycle.sh"
KIND_PRODUCER="$ROOT_DIR/Scripts/run_formal_product_evidence_session.sh"

usage() {
  cat <<'USAGE'
Produce all four formal Apple product evidence directories in one invocation.

Usage:
  run_all_formal_product_evidence.sh \
    --private-evidence-root <new local directory> \
    --public-evidence-root <new public result directory> \
    --candidate-manifest <macos-release-candidate.json> \
    --candidate-app <signed/notarized SkyBridge Compass Pro.app> \
    --candidate-dmg <same immutable candidate DMG> \
    --ios-archive-identity <sealed archive identity> \
    --ios-release-testing-ipa <sealed physical-testing IPA> \
    --ios-device-id <devicectl identifier> \
    --ios-device-udid <xcdevice physical UDID> \
    --expected-source-repository <owner/repository> \
    --expected-source-sha <40 lowercase hex> \
    [--timeout-seconds <30-1800>]

The lifecycle binding containing the stable private id1 reference exists only
inside a mode-0700 temporary directory for this process. It is reused by the
four sequential product runs, never copied into either result root, and is
removed on every exit. The public root appears only after all four kinds pass.
USAGE
}

PRIVATE_EVIDENCE_ROOT=""
PUBLIC_EVIDENCE_ROOT=""
CANDIDATE_MANIFEST=""
CANDIDATE_APP=""
CANDIDATE_DMG=""
IOS_ARCHIVE_IDENTITY=""
IOS_RELEASE_TESTING_IPA=""
IOS_DEVICE_ID=""
IOS_DEVICE_UDID=""
EXPECTED_SOURCE_REPOSITORY=""
EXPECTED_SOURCE_SHA=""
TIMEOUT_SECONDS=900

while (( $# > 0 )); do
  case "$1" in
    --private-evidence-root) PRIVATE_EVIDENCE_ROOT="${2:-}"; shift 2 ;;
    --public-evidence-root) PUBLIC_EVIDENCE_ROOT="${2:-}"; shift 2 ;;
    --candidate-manifest) CANDIDATE_MANIFEST="${2:-}"; shift 2 ;;
    --candidate-app) CANDIDATE_APP="${2:-}"; shift 2 ;;
    --candidate-dmg) CANDIDATE_DMG="${2:-}"; shift 2 ;;
    --ios-archive-identity) IOS_ARCHIVE_IDENTITY="${2:-}"; shift 2 ;;
    --ios-release-testing-ipa) IOS_RELEASE_TESTING_IPA="${2:-}"; shift 2 ;;
    --ios-device-id) IOS_DEVICE_ID="${2:-}"; shift 2 ;;
    --ios-device-udid) IOS_DEVICE_UDID="${2:-}"; shift 2 ;;
    --expected-source-repository) EXPECTED_SOURCE_REPOSITORY="${2:-}"; shift 2 ;;
    --expected-source-sha) EXPECTED_SOURCE_SHA="${2:-}"; shift 2 ;;
    --timeout-seconds) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for path in \
  "$PRIVATE_EVIDENCE_ROOT" "$PUBLIC_EVIDENCE_ROOT" "$CANDIDATE_MANIFEST" \
  "$CANDIDATE_APP" "$CANDIDATE_DMG" "$IOS_ARCHIVE_IDENTITY" \
  "$IOS_RELEASE_TESTING_IPA"; do
  [[ "$path" == /* ]] || { echo "all paths must be absolute" >&2; exit 2; }
done
for destination in "$PRIVATE_EVIDENCE_ROOT" "$PUBLIC_EVIDENCE_ROOT"; do
  [[ ! -e "$destination" && ! -L "$destination" ]] || {
    echo "evidence root must be new: $destination" >&2
    exit 1
  }
done
if [[ ! "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] \
  || (( TIMEOUT_SECONDS < 30 || TIMEOUT_SECONDS > 1800 )); then
  echo "--timeout-seconds must be an integer from 30 through 1800" >&2
  exit 2
fi

mkdir -m 0700 "$PRIVATE_EVIDENCE_ROOT"
PUBLIC_PARENT="$(dirname "$PUBLIC_EVIDENCE_ROOT")"
[[ -d "$PUBLIC_PARENT" && ! -L "$PUBLIC_PARENT" ]] || {
  echo "public evidence parent must be an existing real directory" >&2
  exit 1
}
PUBLIC_NAME="$(basename "$PUBLIC_EVIDENCE_ROOT")"
[[ -n "$PUBLIC_NAME" && "$PUBLIC_NAME" != "." && "$PUBLIC_NAME" != ".." ]] || {
  echo "public evidence root name is unsafe" >&2
  exit 2
}
PUBLIC_STAGING="$(mktemp -d "$PUBLIC_PARENT/.${PUBLIC_NAME}.tmp.XXXXXX")"
chmod 0700 "$PUBLIC_STAGING"
LIFECYCLE_RUNTIME="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-formal-all-identity.XXXXXX")"
chmod 0700 "$LIFECYCLE_RUNTIME"
LIFECYCLE_PRIVATE="$LIFECYCLE_RUNTIME/private"
LIFECYCLE_PUBLIC="$LIFECYCLE_RUNTIME/public"
ALL_COMPLETE=0

cleanup() {
  local status=$?
  # This exact temporary tree is the only location allowed to contain id1.
  /bin/rm -rf "$LIFECYCLE_RUNTIME"
  if [[ "$ALL_COMPLETE" != "1" ]]; then
    /bin/rm -rf "$PUBLIC_STAGING"
  fi
  return "$status"
}
trap cleanup EXIT

"$LIFECYCLE_PRODUCER" \
  --private-output-dir "$LIFECYCLE_PRIVATE" \
  --public-output-dir "$LIFECYCLE_PUBLIC" \
  --ios-archive-identity "$IOS_ARCHIVE_IDENTITY" \
  --ios-release-testing-ipa "$IOS_RELEASE_TESTING_IPA" \
  --ios-device-id "$IOS_DEVICE_ID" \
  --ios-device-udid "$IOS_DEVICE_UDID" \
  --timeout-seconds "$((TIMEOUT_SECONDS < 900 ? TIMEOUT_SECONDS : 900))"

LIFECYCLE_BINDING="$LIFECYCLE_PRIVATE/ios-production-identity-lifecycle-binding.json"
LIFECYCLE_PROOF="$LIFECYCLE_PUBLIC/ios-production-identity-lifecycle-proof.json"

kind_specs=(
  "connectivity|real-device-connectivity-matrix-public-redacted"
  "p2p|real-device-p2p-remote-smoke-public-redacted"
  "webrtc|real-device-webrtc-smoke-public-redacted"
  "file-transfer|real-device-file-transfer-smoke-public-redacted"
)
for spec in "${kind_specs[@]}"; do
  kind="${spec%%|*}"
  public_name="${spec#*|}"
  "$KIND_PRODUCER" \
    --kind "$kind" \
    --artifact-dir "$PRIVATE_EVIDENCE_ROOT/$public_name" \
    --public-artifact-dir "$PUBLIC_STAGING/$public_name" \
    --candidate-manifest "$CANDIDATE_MANIFEST" \
    --candidate-app "$CANDIDATE_APP" \
    --candidate-dmg "$CANDIDATE_DMG" \
    --ios-archive-identity "$IOS_ARCHIVE_IDENTITY" \
    --ios-release-testing-ipa "$IOS_RELEASE_TESTING_IPA" \
    --ios-device-id "$IOS_DEVICE_ID" \
    --ios-device-udid "$IOS_DEVICE_UDID" \
    --identity-lifecycle-binding "$LIFECYCLE_BINDING" \
    --identity-lifecycle-proof "$LIFECYCLE_PROOF" \
    --expected-source-repository "$EXPECTED_SOURCE_REPOSITORY" \
    --expected-source-sha "$EXPECTED_SOURCE_SHA" \
    --timeout-seconds "$TIMEOUT_SECONDS"
done

if rg -l --hidden --glob '*.json' --glob '*.log' \
  'id1:[0-9a-f]{32}' "$PRIVATE_EVIDENCE_ROOT" "$PUBLIC_STAGING" >/dev/null; then
  echo "stable production identity reference escaped its ephemeral binding" >&2
  exit 1
fi

directory_descriptor="$(python3 - "$PUBLIC_STAGING" <<'PY'
import os
import sys

descriptor = os.open(sys.argv[1], os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
print("synced")
PY
)"
[[ "$directory_descriptor" == "synced" ]] || exit 1
mv "$PUBLIC_STAGING" "$PUBLIC_EVIDENCE_ROOT"
ALL_COMPLETE=1

echo "all four formal product evidence directories finalized: $PUBLIC_EVIDENCE_ROOT"
