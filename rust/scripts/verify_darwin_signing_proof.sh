#!/usr/bin/env bash
set -euo pipefail

ARCHIVE=""
PROOF=""
EXPECTED_VERSION=""
EXPECTED_SOURCE_SHA=""
EXPECTED_TEAM_ID=""
NOTARY_INFO_JSON=""

usage() {
  cat <<'EOF'
Usage: verify_darwin_signing_proof.sh \
  --archive <skybridge-aarch64-apple-darwin.tar.gz> \
  --proof <darwin-signing-proof.json> \
  --expected-version <X.Y.Z> --expected-source-sha <40-hex> \
  --expected-team-id <team id> \
  --notary-info-json <live notarytool info output>

Fails closed unless the released darwin archive contains exactly the signed
and notarized binary the proof describes: the live code signature verifies
strictly, the team identifier matches, the binary bytes and cdhash equal the
proof, and Apple's notary service confirms the recorded submission Accepted.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive) ARCHIVE="${2:-}"; shift 2 ;;
    --proof) PROOF="${2:-}"; shift 2 ;;
    --expected-version) EXPECTED_VERSION="${2:-}"; shift 2 ;;
    --expected-source-sha) EXPECTED_SOURCE_SHA="${2:-}"; shift 2 ;;
    --expected-team-id) EXPECTED_TEAM_ID="${2:-}"; shift 2 ;;
    --notary-info-json) NOTARY_INFO_JSON="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

fail() {
  echo "[darwin-signing-verify] ERROR: $1" >&2
  exit 1
}

for required in ARCHIVE PROOF EXPECTED_VERSION EXPECTED_SOURCE_SHA EXPECTED_TEAM_ID NOTARY_INFO_JSON; do
  [[ -n "${!required}" ]] || fail "missing required argument: ${required}"
done
[[ -f "${ARCHIVE}" && ! -L "${ARCHIVE}" ]] || fail "darwin archive not found: ${ARCHIVE}"
[[ -f "${PROOF}" && ! -L "${PROOF}" ]] || fail "signing proof not found: ${PROOF}"
[[ -f "${NOTARY_INFO_JSON}" && ! -L "${NOTARY_INFO_JSON}" ]] || fail "notary info output not found: ${NOTARY_INFO_JSON}"

PYTHON="${PYTHON_BIN:-python3}"

read_proof_field() {
  "${PYTHON}" - "$PROOF" "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    proof = json.load(handle)
value = proof.get(sys.argv[2])
if not isinstance(value, str) or not value:
    raise SystemExit(f"proof field missing or empty: {sys.argv[2]}")
print(value)
PY
}

PROOF_SCHEMA="$(read_proof_field schema)"
PROOF_VERSION="$(read_proof_field version)"
PROOF_SOURCE_SHA="$(read_proof_field source_sha)"
PROOF_TARGET="$(read_proof_field target)"
PROOF_BINARY_SHA256="$(read_proof_field binary_sha256)"
PROOF_CDHASH="$(read_proof_field codesign_cdhash)"
PROOF_TEAM_ID="$(read_proof_field codesign_team_id)"
PROOF_AUTHORITY="$(read_proof_field codesign_authority)"
PROOF_SUBMISSION_ID="$(read_proof_field notarization_submission_id)"
PROOF_STATUS="$(read_proof_field notarization_status)"

[[ "${PROOF_SCHEMA}" == "skybridge-cli-darwin-signing-proof/1" ]] || fail "unexpected proof schema: ${PROOF_SCHEMA}"
[[ "${PROOF_VERSION}" == "${EXPECTED_VERSION}" ]] || fail "proof version ${PROOF_VERSION} does not match expected ${EXPECTED_VERSION}"
[[ "${PROOF_SOURCE_SHA}" == "${EXPECTED_SOURCE_SHA}" ]] || fail "proof source sha does not match the release source"
[[ "${PROOF_TARGET}" == "aarch64-apple-darwin" ]] || fail "unexpected proof target: ${PROOF_TARGET}"
[[ "${PROOF_TEAM_ID}" == "${EXPECTED_TEAM_ID}" ]] || fail "proof team id ${PROOF_TEAM_ID} does not match expected ${EXPECTED_TEAM_ID}"
[[ "${PROOF_AUTHORITY}" == "Developer ID Application:"* ]] || fail "proof authority is not a Developer ID Application certificate"
[[ "${PROOF_STATUS}" == "Accepted" ]] || fail "proof records a non-accepted notarization status: ${PROOF_STATUS}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
tar -xzf "${ARCHIVE}" -C "${WORK_DIR}"
BINARY_PATH="${WORK_DIR}/skybridge"
[[ -f "${BINARY_PATH}" && ! -L "${BINARY_PATH}" ]] || fail "darwin archive does not contain the skybridge binary"

ACTUAL_SHA256="$(shasum -a 256 "${BINARY_PATH}" | awk '{print $1}')"
[[ "${ACTUAL_SHA256}" == "${PROOF_BINARY_SHA256}" ]] || fail "released binary bytes differ from the notarized binary the proof describes"

/usr/bin/codesign --verify --strict --verbose=2 "${BINARY_PATH}" \
  || fail "strict code-signature verification failed for the released binary"

SIGNATURE_INFO="$(/usr/bin/codesign --display --verbose=4 "${BINARY_PATH}" 2>&1)"
ACTUAL_CDHASH="$(printf '%s\n' "${SIGNATURE_INFO}" | sed -n 's/^CDHash=//p' | head -1)"
ACTUAL_TEAM_ID="$(printf '%s\n' "${SIGNATURE_INFO}" | sed -n 's/^TeamIdentifier=//p' | head -1)"
[[ "${ACTUAL_CDHASH}" == "${PROOF_CDHASH}" ]] || fail "released binary cdhash ${ACTUAL_CDHASH} does not match the proof cdhash ${PROOF_CDHASH}"
[[ "${ACTUAL_TEAM_ID}" == "${EXPECTED_TEAM_ID}" ]] || fail "released binary team id ${ACTUAL_TEAM_ID} does not match expected ${EXPECTED_TEAM_ID}"

"${PYTHON}" - "$NOTARY_INFO_JSON" "$PROOF_SUBMISSION_ID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    info = json.load(handle)
if info.get("id") != sys.argv[2]:
    raise SystemExit(
        f"live notary info id {info.get('id')!r} does not match the proof submission {sys.argv[2]!r}"
    )
if info.get("status") != "Accepted":
    raise SystemExit(f"live notary status is not Accepted: {info.get('status')!r}")
PY

echo "[darwin-signing-verify] verified signed + notarized darwin binary (cdhash ${ACTUAL_CDHASH}, submission ${PROOF_SUBMISSION_ID})"
