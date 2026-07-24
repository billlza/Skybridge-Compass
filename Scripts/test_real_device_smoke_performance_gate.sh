#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT_DIR}/Scripts/real_device_smoke_performance_gate.sh"
P2P_SCRIPT="${ROOT_DIR}/Scripts/run_real_device_p2p_remote_smoke.sh"
FILE_SCRIPT="${ROOT_DIR}/Scripts/run_real_device_file_transfer_smoke.sh"
WEBRTC_SCRIPT="${ROOT_DIR}/Scripts/run_real_device_webrtc_smoke.sh"
RELEASE_ACCEPTANCE_FINALIZER="${ROOT_DIR}/Scripts/finalize_release_acceptance_manifests.py"
RELEASE_ACCEPTANCE_VALIDATOR="${ROOT_DIR}/Scripts/validate_real_device_release_acceptance_artifact.py"
IOS_DISTRIBUTION_SIGNING_HELPERS="${ROOT_DIR}/Scripts/ios_distribution_signing_helpers.sh"
IOS_DISTRIBUTION_PRODUCT_VERIFIER="${ROOT_DIR}/Scripts/verify_ios_distribution_product.py"
RELEASE_READINESS_SCRIPT="${ROOT_DIR}/Scripts/check_macos_release_readiness.sh"
REAL_DEVICE_RELEASE_WORKFLOW="${ROOT_DIR}/.github/workflows/real-device-release-gate.yml"

fail() {
  echo "[test-real-device-smoke-performance-gate] $1" >&2
  exit 1
}

line_number() {
  local pattern="$1"
  local path="$2"
  grep -nF -- "$pattern" "$path" | head -n 1 | cut -d: -f1
}

require_literal() {
  local pattern="$1"
  local path="$2"
  grep -Fq -- "$pattern" "$path" || fail "missing required literal in ${path}: ${pattern}"
}

require_literal 'source "$ROOT_DIR/Scripts/real_device_smoke_performance_gate.sh"' "$P2P_SCRIPT"
require_literal 'source "$ROOT_DIR/Scripts/real_device_smoke_performance_gate.sh"' "$FILE_SCRIPT"
require_literal 'PUBLIC_ARTIFACT_DIR="${SKYBRIDGE_SMOKE_PUBLIC_ARTIFACT_DIR:-${ARTIFACT_DIR}-public-redacted}"' "$P2P_SCRIPT"
require_literal 'PUBLIC_ARTIFACT_DIR="${SKYBRIDGE_SMOKE_PUBLIC_ARTIFACT_DIR:-${ARTIFACT_DIR}-public-redacted}"' "$FILE_SCRIPT"
require_literal 'PUBLIC_ARTIFACT_DIR="${SKYBRIDGE_SMOKE_PUBLIC_ARTIFACT_DIR:-${ARTIFACT_DIR}-public-redacted}"' "$WEBRTC_SCRIPT"
for private_artifact_script in "$P2P_SCRIPT" "$FILE_SCRIPT" "$WEBRTC_SCRIPT"; do
  require_literal 'umask 077' "$private_artifact_script"
  require_literal 'chmod 0700 "$ARTIFACT_DIR"' "$private_artifact_script"
done
require_literal 'skybridge_smoke_check_performance_gate "$ROOT_DIR" p2p-remote "$ARTIFACT_DIR"' "$P2P_SCRIPT"
require_literal 'skybridge_smoke_check_performance_gate "$ROOT_DIR" file-transfer "$ARTIFACT_DIR"' "$FILE_SCRIPT"
require_literal 'skybridge_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID"' "$P2P_SCRIPT"
require_literal 'skybridge_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID"' "$FILE_SCRIPT"
require_literal 'skybridge_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID" "$MAC_DEVICE_ID" "$IOS_LOGICAL_DEVICE_ID" "$MAC_PQC_DEVICE_ID"' "$WEBRTC_SCRIPT"
require_literal 'cargo run --quiet --manifest-path "${root_dir}/rust/Cargo.toml" -p skybridge -- "$@"' "$HELPER"
require_literal 'SKYBRIDGE_CLI_BIN is not executable' "$HELPER"
require_literal 'real-device smoke artifact directory does not exist' "$HELPER"
require_literal 'PQC_TRUST_MODE="${SKYBRIDGE_SMOKE_PQC_TRUST_MODE:-actual}"' "$P2P_SCRIPT"
require_literal 'KEYCHAIN_MODE="${SKYBRIDGE_SMOKE_KEYCHAIN_MODE:-system}"' "$P2P_SCRIPT"
require_literal 'SKYBRIDGE_REAL_DEVICE_P2P_LAB_RUN=1' "$P2P_SCRIPT"
require_literal '"$ARTIFACT_DIR/release-acceptance.json"' "$P2P_SCRIPT"
require_literal '"bidirectionalHandshake": has_reverse_crypto' "$P2P_SCRIPT"
require_literal '"reverseCryptoHandshakeComplete": has_reverse_crypto' "$P2P_SCRIPT"
require_literal '"humanApproval": human_approval' "$P2P_SCRIPT"
require_literal '"runtimeAutoApproval": runtime_auto_approval' "$P2P_SCRIPT"
require_literal 'and human_approval' "$P2P_SCRIPT"
require_literal 'and not runtime_auto_approval' "$P2P_SCRIPT"
require_literal 'and ios_product_ready' "$P2P_SCRIPT"
require_literal '"iosBuildConfiguration": ios_product_proof.get("configuration")' "$P2P_SCRIPT"
require_literal '"iosGetTaskAllow": ios_product_proof.get("getTaskAllow") is True' "$P2P_SCRIPT"
require_literal '"iosNestedWidgetVerified": ios_product_proof.get("nestedWidgetVerified") is True' "$P2P_SCRIPT"
require_literal 'write_ios_p2p_product_proof "$IOS_EMBEDDED_PROFILE" "$IOS_WIDGET_EMBEDDED_PROFILE"' "$P2P_SCRIPT"
require_literal '"acceptanceEligible": False' "$P2P_SCRIPT"
require_literal '"diagnosticOnly": True' "$P2P_SCRIPT"
require_literal '"cleanupComplete": False' "$P2P_SCRIPT"
require_literal '"preCleanupCandidate": pre_cleanup_candidate' "$P2P_SCRIPT"
require_literal "python3 \"\$ROOT_DIR/Scripts/finalize_release_acceptance_manifests.py\"" "$P2P_SCRIPT"
require_literal 'if (( original_status == 0 && cleanup_status == 0 )); then' "$P2P_SCRIPT"
require_literal '"macOnlineSource": mac_online_source' "$P2P_SCRIPT"
require_literal '"macOnlineSourceCurrent": mac_online_source_current == "1"' "$P2P_SCRIPT"
require_literal 'and has_current_packaged_mac_online' "$P2P_SCRIPT"
require_literal 'SMOKE_SOAK_SECONDS="${SKYBRIDGE_SMOKE_SOAK_SECONDS:-10}"' "$WEBRTC_SCRIPT"
require_literal 'validate_acceptance_profile' "$WEBRTC_SCRIPT"
require_literal 'SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN=1' "$WEBRTC_SCRIPT"
require_literal 'KEYCHAIN_MODE="${SKYBRIDGE_SMOKE_KEYCHAIN_MODE:-system}"' "$WEBRTC_SCRIPT"
require_literal 'MAC_HOST_MODE="${SKYBRIDGE_SMOKE_MAC_HOST_MODE:-product}"' "$WEBRTC_SCRIPT"
require_literal 'remoteControlNoticeHumanApproved session=${SESSION_REGEX}' "$WEBRTC_SCRIPT"
require_literal '"keychainMode": keychain_mode' "$WEBRTC_SCRIPT"
require_literal '"approvalSurface": "shared-product-panel"' "$WEBRTC_SCRIPT"
require_literal '"runtimeAutoApproval": False' "$WEBRTC_SCRIPT"
require_literal '"acceptanceEligible": False' "$WEBRTC_SCRIPT"
require_literal '"cleanupComplete": False' "$WEBRTC_SCRIPT"
require_literal '"preCleanupCandidate": (' "$WEBRTC_SCRIPT"
require_literal 'and product_path_proof.get("iosProductionProduct") is True' "$WEBRTC_SCRIPT"
require_literal 'and ios_production_identity_lifecycle_verified' "$WEBRTC_SCRIPT"
require_literal "python3 \"\$ROOT_DIR/Scripts/finalize_release_acceptance_manifests.py\"" "$WEBRTC_SCRIPT"
require_literal 'final_payload["cleanupComplete"] = True' "$RELEASE_ACCEPTANCE_FINALIZER"
require_literal 'final_payload["acceptanceEligible"] = candidate' "$RELEASE_ACCEPTANCE_FINALIZER"
require_literal 'final_payload["diagnosticOnly"] = not candidate' "$RELEASE_ACCEPTANCE_FINALIZER"
require_literal 'final_payload["finalizationOrder"] = FINALIZATION_ORDER' "$RELEASE_ACCEPTANCE_FINALIZER"
require_literal 'FINALIZATION_ORDER = "private-then-public-v1"' "$RELEASE_ACCEPTANCE_FINALIZER"
require_literal 'SKYBRIDGE_SMOKE_EXPECTED_AUTH_BINDING_SHA256=$AUTH_BINDING_DIGEST' "$WEBRTC_SCRIPT"
require_literal 'IOS_BUILD_CONFIGURATION="${SKYBRIDGE_IOS_BUILD_CONFIGURATION:-Release}"' "$WEBRTC_SCRIPT"
require_literal 'source "$ROOT_DIR/Scripts/ios_distribution_signing_helpers.sh"' "$WEBRTC_SCRIPT"
require_literal 'skybridge_write_ios_distribution_product_proof' "$WEBRTC_SCRIPT"
require_literal '"iosDistributionSigningVerified": ios_verification.get("distributionSigning") is True' "$WEBRTC_SCRIPT"
require_literal '"iosNestedWidgetVerified": ios_verification.get("nestedWidgetVerified") is True' "$WEBRTC_SCRIPT"
require_literal 'codesign --verify --deep --strict' "$IOS_DISTRIBUTION_SIGNING_HELPERS"
require_literal 'not get_task_allow' "$IOS_DISTRIBUTION_PRODUCT_VERIFIER"
require_literal '"nestedWidgetVerified": nested_widget_verified' "$IOS_DISTRIBUTION_PRODUCT_VERIFIER"
require_literal 'product_surface == "production"' "$IOS_DISTRIBUTION_PRODUCT_VERIFIER"
require_literal 'not testing_compilation_condition' "$IOS_DISTRIBUTION_PRODUCT_VERIFIER"
require_literal 'not binary_test_surface_detected' "$IOS_DISTRIBUTION_PRODUCT_VERIFIER"
require_literal '"productionProduct": production_product' "$IOS_DISTRIBUTION_PRODUCT_VERIFIER"
require_literal "'SKYBRIDGE_TESTING|SKYBRIDGE_SMOKE_" "$IOS_DISTRIBUTION_SIGNING_HELPERS"
require_literal 'Print :SkyBridgePackagingSourceRepository' "$IOS_DISTRIBUTION_SIGNING_HELPERS"
require_literal '"$product_source_repository" == "$expected_source_repository"' "$IOS_DISTRIBUTION_SIGNING_HELPERS"
require_literal '"INFOPLIST_KEY_SkyBridgePackagingSourceRepository=${GITHUB_REPOSITORY:-${SKYBRIDGE_SOURCE_REPOSITORY:-}}"' "$P2P_SCRIPT"
require_literal '"INFOPLIST_KEY_SkyBridgePackagingProductSurface=testing"' "$P2P_SCRIPT"
require_literal '"INFOPLIST_KEY_SkyBridgePackagingSwiftActiveCompilationConditions=HAS_APPLE_PQC_SDK,SKYBRIDGE_TESTING"' "$P2P_SCRIPT"
require_literal '"OTHER_SWIFT_FLAGS=\$(inherited) -D SKYBRIDGE_TESTING"' "$P2P_SCRIPT"
require_literal '"INFOPLIST_KEY_SkyBridgePackagingSourceRepository=${GITHUB_REPOSITORY:-${SKYBRIDGE_SOURCE_REPOSITORY:-}}"' "$WEBRTC_SCRIPT"
require_literal '"INFOPLIST_KEY_SkyBridgePackagingProductSurface=testing"' "$WEBRTC_SCRIPT"
require_literal '"INFOPLIST_KEY_SkyBridgePackagingSwiftActiveCompilationConditions=HAS_APPLE_PQC_SDK,SKYBRIDGE_TESTING"' "$WEBRTC_SCRIPT"
require_literal '"OTHER_SWIFT_FLAGS=\$(inherited) -D SKYBRIDGE_TESTING"' "$WEBRTC_SCRIPT"
require_literal 'REQUIRED_IDENTITY_ALGORITHM = "mldsa87"' "$RELEASE_ACCEPTANCE_VALIDATOR"
require_literal 'REQUIRED_IDENTITY_PROTECTION = "secureEnclaveRequired"' "$RELEASE_ACCEPTANCE_VALIDATOR"
require_literal '"handshakePersistenceVerified"' "$RELEASE_ACCEPTANCE_VALIDATOR"
require_literal '"currentPathAuthorityVerified"' "$RELEASE_ACCEPTANCE_VALIDATOR"
require_literal 'choices=("p2p", "webrtc", "production-identity")' "$RELEASE_ACCEPTANCE_VALIDATOR"
require_literal 'runs-on: [self-hosted, macOS, skybridge-real-device-release]' "$REAL_DEVICE_RELEASE_WORKFLOW"
require_literal 'SKYBRIDGE_RELEASE_EVIDENCE_EXPECTED_REPOSITORY: ${{ github.repository }}' "$REAL_DEVICE_RELEASE_WORKFLOW"
require_literal 'SKYBRIDGE_RELEASE_EVIDENCE_EXPECTED_SHA: ${{ github.sha }}' "$REAL_DEVICE_RELEASE_WORKFLOW"
require_literal '--kind production-identity' "$REAL_DEVICE_RELEASE_WORKFLOW"
require_literal 'relayCandidateObserved' "$WEBRTC_SCRIPT"
require_literal '"mutualHandshake": True' "$WEBRTC_SCRIPT"
require_literal '"macPQCRekeyComplete": True' "$WEBRTC_SCRIPT"
require_literal '"iosPQCRekeyComplete": True' "$WEBRTC_SCRIPT"
require_literal 'stamp_release_session_evidence "$SESSION_ID"' "$WEBRTC_SCRIPT"
require_literal '"sessionRef": session_ref' "$WEBRTC_SCRIPT"
require_literal '"mediaEvidenceWindowMillis": int(media_evidence_window_millis)' "$WEBRTC_SCRIPT"
require_literal '"$ARTIFACT_DIR/release-acceptance.json"' "$WEBRTC_SCRIPT"
require_literal 'validate_real_device_release_acceptance_artifact.py' "$RELEASE_READINESS_SCRIPT"
require_literal '--kind p2p' "$RELEASE_READINESS_SCRIPT"
require_literal '--kind webrtc' "$RELEASE_READINESS_SCRIPT"

p2p_gate_line="$(line_number 'skybridge_smoke_check_performance_gate "$ROOT_DIR" p2p-remote "$ARTIFACT_DIR"' "$P2P_SCRIPT")"
p2p_public_gate_line="$(line_number 'skybridge_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID"' "$P2P_SCRIPT")"
p2p_success_line="$(line_number 'Real-device P2P remote desktop smoke succeeded' "$P2P_SCRIPT")"
p2p_final_line="$(line_number 'append_ios_status "smoke-final result=success' "$P2P_SCRIPT")"
[[ -n "$p2p_gate_line" && -n "$p2p_public_gate_line" && -n "$p2p_success_line" && -n "$p2p_final_line" ]] \
  || fail "P2P script must contain final sentinels, Rust performance gate, and success output"
(( p2p_final_line < p2p_gate_line && p2p_gate_line < p2p_public_gate_line && p2p_public_gate_line < p2p_success_line )) \
  || fail "P2P Rust performance and public artifact gates must run after final sentinels and before success output"

file_gate_line="$(line_number 'skybridge_smoke_check_performance_gate "$ROOT_DIR" file-transfer "$ARTIFACT_DIR"' "$FILE_SCRIPT")"
file_public_gate_line="$(line_number 'skybridge_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID"' "$FILE_SCRIPT")"
file_success_line="$(line_number 'Real-device bidirectional file transfer smoke succeeded' "$FILE_SCRIPT")"
file_marker_line="$(line_number 'Waiting for smoke success markers' "$FILE_SCRIPT")"
[[ -n "$file_gate_line" && -n "$file_public_gate_line" && -n "$file_success_line" && -n "$file_marker_line" ]] \
  || fail "file-transfer script must contain success markers, Rust performance gate, and success output"
(( file_marker_line < file_gate_line && file_gate_line < file_public_gate_line && file_public_gate_line < file_success_line )) \
  || fail "file-transfer Rust performance and public artifact gates must run after success markers and before success output"

require_literal 'run_webrtc_media_doctor "$SESSION_ID"' "$WEBRTC_SCRIPT"
require_literal 'skybridge_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID" "$MAC_DEVICE_ID" "$IOS_LOGICAL_DEVICE_ID" "$MAC_PQC_DEVICE_ID"' "$WEBRTC_SCRIPT"
python3 - "$WEBRTC_SCRIPT" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
cleanup = source.split("cleanup() {", 1)[1].split("\n}\ntrap cleanup EXIT", 1)[0]
success = "Real-device WebRTC smoke succeeded after verified Mac/iOS process cleanup"
finalize = "finalize_release_acceptance_manifests_after_cleanup"
if source.count(success) != 1 or success not in cleanup:
    raise SystemExit("WebRTC success output must exist exactly once inside cleanup")
if cleanup.index(finalize) >= cleanup.index(success):
    raise SystemExit("WebRTC success output must follow cleanup manifest finalization")
if "original_status == 0 && cleanup_status == 0 && ACCEPTANCE_CANDIDATE_READY == 1" not in cleanup:
    raise SystemExit("WebRTC cleanup success must be gated by a verified acceptance candidate")
PY

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-smoke-performance-gate-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT
ARTIFACT_DIR="${TMP_DIR}/artifact"
FAKE_CLI="${TMP_DIR}/skybridge"
ARGS_FILE="${TMP_DIR}/args.txt"
mkdir -p "$ARTIFACT_DIR"
cat >"$FAKE_CLI" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${SKYBRIDGE_FAKE_CLI_ARGS_FILE:?missing args file}"
SH
chmod +x "$FAKE_CLI"

source "${ROOT_DIR}/Scripts/real_device_smoke_performance_gate.sh"

SKYBRIDGE_CLI_BIN="$FAKE_CLI" \
SKYBRIDGE_FAKE_CLI_ARGS_FILE="$ARGS_FILE" \
  skybridge_smoke_check_performance_gate "$ROOT_DIR" p2p-remote "$ARTIFACT_DIR" --min-fps 59 --exact-video-size

expected_args="${TMP_DIR}/expected-args.txt"
cat >"$expected_args" <<EOF
check
performance
--kind
p2p-remote
--artifact-dir
$ARTIFACT_DIR
--min-fps
59
--exact-video-size
EOF
cmp "$expected_args" "$ARGS_FILE" \
  || fail "helper should invoke the selected SkyBridge CLI with canonical performance arguments"

if SKYBRIDGE_CLI_BIN="${TMP_DIR}/missing-cli" skybridge_smoke_check_performance_gate "$ROOT_DIR" file-transfer "$ARTIFACT_DIR" >/dev/null 2>&1; then
  fail "helper must fail when SKYBRIDGE_CLI_BIN is not executable"
fi

if SKYBRIDGE_CLI_BIN="$FAKE_CLI" skybridge_smoke_check_performance_gate "$ROOT_DIR" file-transfer "${TMP_DIR}/missing-artifact" >/dev/null 2>&1; then
  fail "helper must fail when artifact directory is missing"
fi

echo "real-device smoke performance gate contract passed"
