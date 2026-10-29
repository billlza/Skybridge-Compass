#!/usr/bin/env bash
set -euo pipefail

BINARY=""
VERSION=""
SOURCE_SHA=""
SUBMISSION_ID=""
SUBMISSION_STATUS=""
OUTPUT=""

usage() {
  cat <<'EOF'
Usage: write_darwin_signing_proof.sh \
  --binary <signed skybridge binary> --version <X.Y.Z> \
  --source-sha <40-hex> --submission-id <notarytool submission uuid> \
  --submission-status <notarytool status> --output <proof json path>

Records the verifiable identity of a signed and notarized darwin CLI binary:
the code-signature cdhash, signing authority, and team identifier read back
from the binary itself, bound to the notarization submission that accepted it.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) BINARY="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --source-sha) SOURCE_SHA="${2:-}"; shift 2 ;;
    --submission-id) SUBMISSION_ID="${2:-}"; shift 2 ;;
    --submission-status) SUBMISSION_STATUS="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

fail() {
  echo "[darwin-signing-proof] ERROR: $1" >&2
  exit 1
}

for required in BINARY VERSION SOURCE_SHA SUBMISSION_ID SUBMISSION_STATUS OUTPUT; do
  [[ -n "${!required}" ]] || fail "missing required argument: ${required}"
done
[[ -f "${BINARY}" && ! -L "${BINARY}" ]] || fail "signed binary not found: ${BINARY}"
[[ "${SOURCE_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail "source sha must be 40 hex characters"
[[ "${SUBMISSION_STATUS}" == "Accepted" ]] || fail "refusing to record a proof for status: ${SUBMISSION_STATUS}"
[[ ! -e "${OUTPUT}" && ! -L "${OUTPUT}" ]] || fail "refusing to replace an existing proof: ${OUTPUT}"

SIGNATURE_INFO="$(/usr/bin/codesign --display --verbose=4 "${BINARY}" 2>&1)"
CDHASH="$(printf '%s\n' "${SIGNATURE_INFO}" | sed -n 's/^CDHash=//p' | head -1)"
TEAM_ID="$(printf '%s\n' "${SIGNATURE_INFO}" | sed -n 's/^TeamIdentifier=//p' | head -1)"
AUTHORITY="$(printf '%s\n' "${SIGNATURE_INFO}" | sed -n 's/^Authority=//p' | head -1)"

[[ "${CDHASH}" =~ ^[0-9a-f]{40}$ ]] || fail "unable to read the code-signature cdhash"
[[ -n "${TEAM_ID}" && "${TEAM_ID}" != "not set" ]] || fail "unable to read the signing team identifier"
[[ "${AUTHORITY}" == "Developer ID Application:"* ]] || fail "signing authority is not a Developer ID Application certificate: ${AUTHORITY}"

PROOF_BINARY_SHA256="$(shasum -a 256 "${BINARY}" | awk '{print $1}')"
export PROOF_BINARY_SHA256
export PROOF_VERSION="${VERSION}"
export PROOF_SOURCE_SHA="${SOURCE_SHA}"
export PROOF_CDHASH="${CDHASH}"
export PROOF_TEAM_ID="${TEAM_ID}"
export PROOF_AUTHORITY="${AUTHORITY}"
export PROOF_SUBMISSION_ID="${SUBMISSION_ID}"
export PROOF_SUBMISSION_STATUS="${SUBMISSION_STATUS}"
export PROOF_OUTPUT="${OUTPUT}"

"${PYTHON_BIN:-python3}" - <<'PY'
import json
import os
import pathlib

proof = {
    "schema": "skybridge-cli-darwin-signing-proof/1",
    "version": os.environ["PROOF_VERSION"],
    "source_sha": os.environ["PROOF_SOURCE_SHA"],
    "target": "aarch64-apple-darwin",
    "binary_sha256": os.environ["PROOF_BINARY_SHA256"],
    "codesign_cdhash": os.environ["PROOF_CDHASH"],
    "codesign_team_id": os.environ["PROOF_TEAM_ID"],
    "codesign_authority": os.environ["PROOF_AUTHORITY"],
    "notarization_submission_id": os.environ["PROOF_SUBMISSION_ID"],
    "notarization_status": os.environ["PROOF_SUBMISSION_STATUS"],
}
path = pathlib.Path(os.environ["PROOF_OUTPUT"])
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("x", encoding="utf-8") as handle:
    json.dump(proof, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

echo "[darwin-signing-proof] recorded ${OUTPUT}"
