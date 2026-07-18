#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-update-publisher-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

# The publisher intentionally exposes its transaction functions when sourced so
# the remote state machine can be tested without making GitHub mutations.
cd "${ROOT_DIR}"
source Scripts/publish_macos_update_release.sh

assert_contains() {
  local expected="$1"
  local actual="$2"
  [[ "${actual}" == *"${expected}"* ]] || {
    echo "expected output to contain: ${expected}" >&2
    printf '%s\n' "${actual}" >&2
    exit 1
  }
}

write_release_provenance_fixture() {
  local output_path="$1"
  local repository="$2"
  local head_sha="$3"
  local artifact_count="$4"

  python3 - "$output_path" "$repository" "$head_sha" "$artifact_count" <<'PY'
import json
import sys
from pathlib import Path

output_path = Path(sys.argv[1])
repository = sys.argv[2]
head_sha = sys.argv[3]
artifact_count = int(sys.argv[4])
value = {
    "schema_version": 1,
    "repository": repository,
    "run_id": 123456,
    "run_attempt": 1,
    "workflow_path": ".github/workflows/release-evidence.yml",
    "event": "workflow_dispatch",
    "status": "completed",
    "conclusion": "success",
    "head_sha": head_sha,
    "head_branch": "main",
    "artifacts": [
        {
            "name": f"release-evidence-{index}",
            "size_in_bytes": 1024 + index,
            "digest": "sha256:" + (f"{index + 1:x}" * 64)[:64],
            "expired": False,
        }
        for index in range(artifact_count)
    ],
}
output_path.write_text(json.dumps(value) + "\n", encoding="utf-8")
PY
}

test_remote_sequence_must_increase() (
  local sequence_fixture="${TMP_DIR}/remote-sequence.json"
  local output=""
  local status=0

  printf '{"sequence": 42}\n' >"${sequence_fixture}"
  TAG_NAME="stable"
  REMOTE_SEQUENCE=""
  release_asset_exists() { return 0; }
  download_release_asset() {
    mkdir -p "$3"
    cp "${sequence_fixture}" "$3/$2"
  }

  if output="$( (require_remote_sequence_monotonic 42 "${TMP_DIR}/sequence-check") 2>&1)"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" -ne 0 ]] || {
    echo "equal remote sequence must be rejected" >&2
    exit 1
  }
  assert_contains "must be greater than remote stable sequence 42" "${output}"

  require_remote_sequence_monotonic 43 "${TMP_DIR}/sequence-check-success" >/dev/null
  [[ "${REMOTE_SEQUENCE}" == "42" ]] || {
    echo "remote sequence was not retained for recovery evidence" >&2
    exit 1
  }
)

test_release_asset_inspection_fails_closed() (
  local output=""
  local status=0

  REPOSITORY="owner/repository"
  gh() { return 7; }
  if output="$( (release_asset_exists stable macos-stable.json) 2>&1)"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" -ne 0 ]] || {
    echo "release asset inspection failure must not be treated as an absent asset" >&2
    exit 1
  }
  assert_contains "could not inspect release assets" "${output}"
)

test_concurrent_sequence_change_is_rejected() (
  local concurrent_fixture="${TMP_DIR}/concurrent-sequence.json"
  local output=""
  local status=0

  printf '{"sequence": 43}\n' >"${concurrent_fixture}"
  TAG_NAME="stable"
  release_asset_exists() { return 0; }
  download_release_asset() {
    mkdir -p "$3"
    cp "${concurrent_fixture}" "$3/$2"
  }
  if output="$(
    (require_remote_sequence_unchanged 42 "${TMP_DIR}/concurrent-sequence-check") 2>&1
  )"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" -ne 0 ]] || {
    echo "a concurrent stable sequence change must abort the channel switch" >&2
    exit 1
  }
  assert_contains "sequence changed concurrently from 42 to 43" "${output}"
)

test_stable_publish_requires_official_workflow_context() (
  local output=""
  local status=0

  unset GITHUB_ACTIONS GITHUB_EVENT_NAME GITHUB_WORKFLOW_REF GITHUB_REPOSITORY GITHUB_SHA
  if output="$( (validate_release_execution_context) 2>&1)"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" -ne 0 ]] || {
    echo "stable publication must reject a local/manual execution context" >&2
    exit 1
  }
  assert_contains "restricted to the official GitHub Actions release workflow" "${output}"
)

test_release_provenance_binds_main_commit_and_six_artifacts() (
  local provenance_path="${TMP_DIR}/release-artifact-run-provenance.json"
  local source_commit=""
  local output=""
  local status=0

  source_commit="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
  REPOSITORY="owner/repository"
  RELEASE_PROVENANCE_PATH="${provenance_path}"
  GITHUB_ACTIONS="true"
  GITHUB_EVENT_NAME="workflow_dispatch"
  GITHUB_REF="refs/heads/main"
  GITHUB_WORKFLOW_REF="owner/repository/.github/workflows/macos-release-readiness.yml@refs/heads/main"
  GITHUB_REPOSITORY="${REPOSITORY}"
  GITHUB_SHA="${source_commit}"
  export GITHUB_ACTIONS GITHUB_EVENT_NAME GITHUB_REF GITHUB_WORKFLOW_REF GITHUB_REPOSITORY GITHUB_SHA

  write_release_provenance_fixture "${provenance_path}" "${REPOSITORY}" "${source_commit}" 6
  validate_release_execution_context

  write_release_provenance_fixture \
    "${provenance_path}" \
    "${REPOSITORY}" \
    "2222222222222222222222222222222222222222" \
    6
  if output="$( (validate_release_execution_context) 2>&1)"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" -ne 0 ]] || {
    echo "mismatched release evidence SHA must be rejected" >&2
    exit 1
  }
  assert_contains "head_sha does not match the publish commit" "${output}"

  write_release_provenance_fixture "${provenance_path}" "${REPOSITORY}" "${source_commit}" 5
  if output="$( (validate_release_execution_context) 2>&1)"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" -ne 0 ]] || {
    echo "incomplete release evidence must be rejected" >&2
    exit 1
  }
  assert_contains "exactly six validated release artifacts are required" "${output}"
)

test_immutable_dmg_refuses_different_bytes() (
  local local_dmg="${TMP_DIR}/local.dmg"
  local remote_dmg="${TMP_DIR}/remote.dmg"
  local output=""
  local status=0

  printf 'local release bytes\n' >"${local_dmg}"
  printf 'different remote bytes\n' >"${remote_dmg}"
  ARTIFACT_TAG_NAME="macos-v1.0.1-build-43"
  DMG_ASSET_NAME="SkyBridgeCompassPro-1.0.1.dmg"
  DMG_PATH="${local_dmg}"
  release_asset_exists() { return 0; }
  download_release_asset() {
    mkdir -p "$3"
    cp "${remote_dmg}" "$3/$2"
  }

  if output="$(
    (ensure_unique_dmg_uploaded "${TMP_DIR}/immutable-check" "$(sha256_file "${local_dmg}")") 2>&1
  )"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" -ne 0 ]] || {
    echo "different bytes under an existing immutable asset name must be rejected" >&2
    exit 1
  }
  assert_contains "refusing to overwrite immutable version asset" "${output}"
)

test_artifact_tag_must_match_source_commit() (
  local output=""
  local status=0

  PROJECT_ROOT="${ROOT_DIR}"
  REPOSITORY="owner/repository"
  ARTIFACT_TAG_NAME="macos-v1.0.1-build-43"
  git() {
    if [[ "$*" == *"rev-parse HEAD"* ]]; then
      printf '%s\n' '1111111111111111111111111111111111111111'
      return 0
    fi
    return 1
  }
  gh() {
    if [[ "${1:-} ${2:-}" == "release view" ]]; then
      return 0
    fi
    if [[ "${1:-}" == "api" ]]; then
      printf '%s\n' '2222222222222222222222222222222222222222'
      return 0
    fi
    return 1
  }

  if output="$( (ensure_artifact_release) 2>&1)"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" -ne 0 ]] || {
    echo "artifact tag commit mismatch must be rejected" >&2
    exit 1
  }
  assert_contains "points to 2222222222222222222222222222222222222222" "${output}"
)

test_previous_manifest_backup_is_read_back() (
  local previous_manifest="${TMP_DIR}/previous-macos-stable.json"
  local remote_dir="${TMP_DIR}/backup-remote"
  local verification_dir="${TMP_DIR}/backup-verification"
  local expected_asset="previous-macos-stable-sequence-42.json"

  printf '{"sequence": 42, "signature": "preserved"}\n' >"${previous_manifest}"
  mkdir -p "${remote_dir}"
  REPOSITORY="owner/repository"
  ARTIFACT_TAG_NAME="macos-v1.0.1-build-43"
  release_asset_exists() {
    [[ -f "${remote_dir}/$2" ]]
  }
  gh() {
    [[ "${1:-} ${2:-}" == "release upload" ]] || return 1
    cp "$4" "${remote_dir}/$(basename "$4")"
  }
  download_release_asset() {
    mkdir -p "$3"
    cp "${remote_dir}/$2" "$3/$2"
  }

  preserve_previous_manifest "${previous_manifest}" 42 "${verification_dir}"
  cmp -s "${previous_manifest}" "${remote_dir}/${expected_asset}" || {
    echo "previous manifest backup was not preserved byte-for-byte" >&2
    exit 1
  }
)

test_remote_transaction_order() (
  local event_log="${TMP_DIR}/transaction-events.log"
  local expected_log="${TMP_DIR}/transaction-events.expected"

  : >"${event_log}"
  REPOSITORY="owner/repository"
  TAG_NAME="stable"
  ARTIFACT_TAG_NAME="macos-v1.0.1-build-43"
  SEQUENCE="43"
  VERIFY_DIR="${TMP_DIR}/transaction"
  EXPECTED_DMG_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  DMG_ASSET_NAME="SkyBridgeCompassPro-1.0.1.dmg"
  MANIFEST_PATH="${TMP_DIR}/macos-stable.json"
  APP_PATH="${TMP_DIR}/SkyBridge Compass Pro.app"
  PROOF_SUMMARY_PATH="${TMP_DIR}/publish-proof.json"
  mkdir -p "${VERIFY_DIR}/previous"
  printf '{"sequence": 42}\n' >"${VERIFY_DIR}/previous/macos-stable.json"

  gh() {
    if [[ "${1:-} ${2:-}" == "auth status" ]]; then
      return 0
    fi
    if [[ "${1:-} ${2:-} ${3:-}" == "release view stable" ]]; then
      return 0
    fi
    if [[ "${1:-} ${2:-} ${3:-}" == "release upload stable" ]]; then
      printf '%s\n' 'stable-manifest-switch' >>"${event_log}"
      return 0
    fi
    return 1
  }
  validate_release_execution_context() { printf '%s\n' 'release-context' >>"${event_log}"; }
  require_remote_sequence_monotonic() {
    printf '%s\n' 'sequence-check' >>"${event_log}"
    REMOTE_SEQUENCE="42"
  }
  ensure_artifact_release() { printf '%s\n' 'artifact-release' >>"${event_log}"; }
  preserve_previous_manifest() { printf '%s\n' 'previous-manifest-backup' >>"${event_log}"; }
  ensure_unique_dmg_uploaded() { printf '%s\n' 'dmg-upload-readback' >>"${event_log}"; }
  promote_artifact_release_if_needed() { printf '%s\n' 'artifact-promotion' >>"${event_log}"; }
  require_remote_sequence_unchanged() { printf '%s\n' 'sequence-recheck' >>"${event_log}"; }
  verify_uploaded_release_assets() { printf '%s\n' 'final-dual-tag-readback' >>"${event_log}"; }
  write_publish_proof_summary() { printf '%s\n' 'publish-proof' >>"${event_log}"; }

  publish_release_assets >/dev/null
  cat >"${expected_log}" <<'EOF'
release-context
sequence-check
artifact-release
previous-manifest-backup
dmg-upload-readback
artifact-promotion
sequence-recheck
stable-manifest-switch
final-dual-tag-readback
publish-proof
EOF
  diff -u "${expected_log}" "${event_log}"
)

test_final_verification_downloads_from_both_tags() (
  local local_dmg="${TMP_DIR}/dual-tag-local.dmg"
  local local_manifest="${TMP_DIR}/dual-tag-local.json"
  local event_log="${TMP_DIR}/dual-tag-downloads.log"
  local dmg_sha=""

  printf 'verified release bytes\n' >"${local_dmg}"
  dmg_sha="$(sha256_file "${local_dmg}")"
  python3 - "${local_manifest}" "${dmg_sha}" <<'PY'
import json
import sys
from pathlib import Path

manifest = {
    "sha256": sys.argv[2],
    "apple_pqc_sdk_build": {
        "compiled_with_has_apple_pqc_sdk": True,
        "compile_marker": "skybridge.apple-pqc-sdk.compile-fact.v1.has-apple-pqc-sdk",
        "probe_mode": "symbol_probe",
        "sdk_name": "macosx",
        "sdk_version": "26.5",
        "swift_target": "arm64-apple-macosx26.0",
        "secure_enclave_symbols_included": True,
        "symbol_set": "cryptokit-pqc-v1",
        "signature": {},
    },
}
Path(sys.argv[1]).write_text(json.dumps(manifest) + "\n", encoding="utf-8")
PY

  TAG_NAME="stable"
  ARTIFACT_TAG_NAME="macos-v1.0.1-build-43"
  : >"${event_log}"
  download_release_asset() {
    printf '%s|%s\n' "$1" "$2" >>"${event_log}"
    mkdir -p "$3"
    if [[ "$1" == "${ARTIFACT_TAG_NAME}" ]]; then
      cp "${local_dmg}" "$3/$2"
    else
      cp "${local_manifest}" "$3/$2"
    fi
  }
  bash() { return 0; }

  verify_uploaded_release_assets \
    "${TMP_DIR}/dual-tag-verification" \
    "SkyBridgeCompassPro-1.0.1.dmg" \
    "${dmg_sha}" \
    "${local_manifest}" \
    "${TMP_DIR}/unused.app"

  grep -Fqx "${ARTIFACT_TAG_NAME}|SkyBridgeCompassPro-1.0.1.dmg" "${event_log}"
  grep -Fqx "stable|macos-stable.json" "${event_log}"
)

test_remote_sequence_must_increase
test_release_asset_inspection_fails_closed
test_concurrent_sequence_change_is_rejected
test_stable_publish_requires_official_workflow_context
test_release_provenance_binds_main_commit_and_six_artifacts
test_immutable_dmg_refuses_different_bytes
test_artifact_tag_must_match_source_commit
test_previous_manifest_backup_is_read_back
test_remote_transaction_order
test_final_verification_downloads_from_both_tags

echo "[test-publish-macos-update-release] passed"
