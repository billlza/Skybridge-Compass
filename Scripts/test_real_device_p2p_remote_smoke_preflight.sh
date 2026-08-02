#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE_SCRIPT="${SCRIPT_DIR}/run_real_device_p2p_remote_smoke.sh"
SIGNING_HELPERS="${SCRIPT_DIR}/signing_entitlements_helpers.sh"
IOS_DISTRIBUTION_SIGNING_HELPERS="${SCRIPT_DIR}/ios_distribution_signing_helpers.sh"
IOS_DISTRIBUTION_SIGNING_RESOLVER="${SCRIPT_DIR}/resolve_ios_distribution_signing.py"
IOS_DISTRIBUTION_PRODUCT_VERIFIER="${SCRIPT_DIR}/verify_ios_distribution_product.py"
AUTHENTICATED_ROUTE_EXTRACTOR="${SCRIPT_DIR}/extract_authenticated_p2p_route.py"
RELEASE_ACCEPTANCE_FINALIZER="${SCRIPT_DIR}/finalize_release_acceptance_manifests.py"
RELEASE_ACCEPTANCE_VALIDATOR="${SCRIPT_DIR}/validate_real_device_release_acceptance_artifact.py"
IOS_PROJECT_FILE="${SCRIPT_DIR}/../SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj/project.pbxproj"
IOS_PROJECT_YAML="${SCRIPT_DIR}/../SkyBridge Compass iOS/project.yml"
IOS_DEBUG_ENTITLEMENTS="${SCRIPT_DIR}/../SkyBridge Compass iOS/SkyBridgeCompass-iOSDebug.entitlements"
IOS_RELEASE_ENTITLEMENTS="${SCRIPT_DIR}/../SkyBridge Compass iOS/SkyBridgeCompass-iOSRelease.entitlements"
IOS_APP_INFO_PLIST="${SCRIPT_DIR}/../SkyBridge Compass iOS/SkyBridgeCompassiOS/Supporting Files/Info.plist"
SOURCE_INPUT_DIGEST_TOOL="${SCRIPT_DIR}/source_input_digest.py"

fail() {
  echo "[test-real-device-smoke-preflight] $1" >&2
  exit 1
}

contains_literal() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]]
}

script_has_literal() {
  local needle="$1"
  grep -Fq -- "$needle" "$SMOKE_SCRIPT"
}

detect_body="$(
  awk '
    /^detect_macos_loginwindow_occlusion\(\)/ { in_function = 1 }
    /^wait_for_ios_status_pattern\(\)/ { in_function = 0 }
    in_function { print }
  ' "$SMOKE_SCRIPT"
)"
direct_launch_body="$(
  awk '
    /^start_macos_smoke_host_directly\(\)/ { in_function = 1 }
    /^start_macos_smoke_host\(\)/ { in_function = 0 }
    in_function { print }
  ' "$SMOKE_SCRIPT"
)"
launch_evidence_body="$(
  awk '
    /^record_macos_smoke_host_launch_evidence\(\)/ { in_function = 1 }
    /^append_ios_status\(\)/ { in_function = 0 }
    in_function { print }
  ' "$SMOKE_SCRIPT"
)"
host_start_body="$(
  awk '
    /^start_macos_smoke_host\(\)/ { in_function = 1 }
    /^append_ios_status\(\)/ { in_function = 0 }
    in_function { print }
  ' "$SMOKE_SCRIPT"
)"
product_signing_body="$(
  awk '
    /^verify_macos_smoke_host_product_signing_context\(\)/ { in_function = 1 }
    /^prepare_macos_smoke_host_app_bundle\(\)/ { in_function = 0 }
    in_function { print }
  ' "$SMOKE_SCRIPT"
)"
minimal_entitlements_body="$(
  awk '
    /^derive_macos_smoke_host_minimal_entitlements\(\)/ { in_function = 1 }
    /^validate_macos_smoke_host_minimal_entitlements\(\)/ { in_function = 0 }
    in_function { print }
  ' "$SMOKE_SCRIPT"
)"
host_bundle_prepare_body="$(
  awk '
    /^prepare_macos_smoke_host_app_bundle\(\)/ { in_function = 1 }
    /^register_launch_services_app_bundle\(\)/ { in_function = 0 }
    in_function { print }
  ' "$SMOKE_SCRIPT"
)"
cleanup_body="$(
  awk '
    /^cleanup\(\)/ { in_function = 1 }
    /^trap cleanup EXIT/ { in_function = 0 }
    in_function { print }
  ' "$SMOKE_SCRIPT"
)"
artifact_sync_body="$(
  awk '
    /^sync_macos_smoke_host_artifacts\(\)/ { in_function = 1 }
    /^tracked_process_executable\(\)/ { in_function = 0 }
    in_function { print }
  ' "$SMOKE_SCRIPT"
)"
tracked_process_termination_body="$(
  awk '
    /^terminate_tracked_process\(\)/ { in_function = 1 }
    /^capture_ios_release_source_provenance\(\)/ { in_function = 0 }
    in_function { print }
  ' "$SMOKE_SCRIPT"
)"
mac_online_build_body="$(
  awk '
    /^build_macos_online_ipad_app\(\)/ { in_function = 1 }
    /^register_macos_online_ipad_app_bundle\(\)/ { in_function = 0 }
    in_function { print }
  ' "$SMOKE_SCRIPT"
)"
mac_online_packaged_body="$(
  awk '
    /^build_macos_online_ipad_app\(\)/ { in_function = 1 }
    in_function && /if \[\[ "\$MAC_ONLINE_ALLOW_DEBUG_BUILD"/ { in_function = 0 }
    in_function { print }
  ' "$SMOKE_SCRIPT"
)"
mac_online_debug_body="$(
  awk '
    /if \[\[ "\$MAC_ONLINE_ALLOW_DEBUG_BUILD"/ { in_branch = 1 }
    /^register_macos_online_ipad_app_bundle\(\)/ { in_branch = 0 }
    in_branch { print }
  ' "$SMOKE_SCRIPT"
)"
mac_online_signing_body="$(
  awk '
    /^sign_macos_online_ipad_debug_app\(\)/ { in_function = 1 }
    /^build_macos_online_ipad_app\(\)/ { in_function = 0 }
    in_function { print }
  ' "$SMOKE_SCRIPT"
)"
remote_control_notice_lifecycle_body="$(
  awk '
    /^wait_for_remote_control_notice_lifecycle\(\)/ { in_function = 1 }
    /^wait_for_remote_control_notice_disconnected\(\)/ { in_function = 0 }
    in_function { print }
  ' "$SMOKE_SCRIPT"
)"
approval_proof_body="$(
  awk '
    /^write_p2p_remote_control_approval_proof\(\)/ { in_function = 1 }
    /^wait_for_remote_control_notice_lifecycle\(\)/ { in_function = 0 }
    in_function { print }
  ' "$SMOKE_SCRIPT"
)"
source_provenance_body="$(
  awk '
    /^capture_ios_release_source_provenance\(\)/ { in_function = 1 }
    /^write_ios_p2p_product_proof\(\)/ { in_function = 0 }
    in_function { print }
  ' "$SMOKE_SCRIPT"
)"
ios_build_invocation_body="$(
  awk '
    /^IOS_XCODEBUILD_ARGS=\(/ { in_block = 1 }
    /^IOS_APP_PATH=/ { in_block = 0 }
    in_block { print }
  ' "$SMOKE_SCRIPT"
)"
for shared_ios_signing_file in \
  "$IOS_DISTRIBUTION_SIGNING_HELPERS" \
  "$IOS_DISTRIBUTION_SIGNING_RESOLVER" \
  "$IOS_DISTRIBUTION_PRODUCT_VERIFIER"; do
  [[ -f "$shared_ios_signing_file" && ! -L "$shared_ios_signing_file" ]] \
    || fail "shared iOS distribution signing source is missing or symlinked: $shared_ios_signing_file"
done
[[ -f "$SOURCE_INPUT_DIGEST_TOOL" && ! -L "$SOURCE_INPUT_DIGEST_TOOL" ]] \
  || fail "source-input digest tool is missing or symlinked"
distribution_profile_resolver_body="$(<"$IOS_DISTRIBUTION_SIGNING_RESOLVER")"
ios_product_proof_body="$(<"$IOS_DISTRIBUTION_SIGNING_HELPERS")"$'\n'"$(<"$IOS_DISTRIBUTION_PRODUCT_VERIFIER")"

[[ "$detect_body" == *"set +e"* ]] \
  || fail "loginwindow preflight must disable errexit before capturing Swift status"
contains_literal "$detect_body" "proof=\"\$(swift" \
  || fail "loginwindow preflight should capture Swift proof output"
contains_literal "$detect_body" "status=\$?" \
  || fail "loginwindow preflight should preserve Swift exit status"
[[ "$detect_body" == *"set -e"* ]] \
  || fail "loginwindow preflight must restore errexit after capturing Swift status"
[[ "$detect_body" == *"reason=screen-locked-loginwindow-occlusion"* ]] \
  || fail "loginwindow preflight must emit a structured locked-screen failure"

preflight_line="$(grep -n 'Checking macOS visible desktop preflight' "$SMOKE_SCRIPT" | head -n 1 | cut -d: -f1)"
source_provenance_line="$(grep -n '^capture_ios_release_source_provenance$' "$SMOKE_SCRIPT" | head -n 1 | cut -d: -f1)"
pqc_gate_line="$(grep -n 'Checking Apple PQC SDK gate for macOS host' "$SMOKE_SCRIPT" | head -n 1 | cut -d: -f1)"
build_line="$(grep -n 'Building macOS LAN host' "$SMOKE_SCRIPT" | head -n 1 | cut -d: -f1)"
verify_call_line="$(grep -n '^verify_mac_smoke_capture_source_visible$' "$SMOKE_SCRIPT" | head -n 1 | cut -d: -f1)"
performance_line="$(grep -n '^validate_remote_desktop_performance_window$' "$SMOKE_SCRIPT" | head -n 1 | cut -d: -f1)"
mac_online_line="$(grep -n '^[[:space:]]*run_mac_online_ipad_button_smoke$' "$SMOKE_SCRIPT" | head -n 1 | cut -d: -f1)"
host_final_line="$(grep -n 'append_host_status "smoke-final result=success' "$SMOKE_SCRIPT" | head -n 1 | cut -d: -f1)"
ios_final_line="$(grep -n 'append_ios_status "smoke-final result=success' "$SMOKE_SCRIPT" | head -n 1 | cut -d: -f1)"

[[ -n "$preflight_line" && -n "$source_provenance_line" && -n "$pqc_gate_line" && -n "$build_line" ]] \
  || fail "smoke script should contain desktop/source preflight, Apple PQC SDK gate, and build markers"
(( preflight_line < source_provenance_line && source_provenance_line < build_line )) \
  || fail "clean iOS source provenance must be proven after desktop preflight and before expensive builds"
(( preflight_line < pqc_gate_line && pqc_gate_line < build_line )) \
  || fail "Apple PQC SDK gate should run after desktop preflight and before the macOS host build"

script_has_literal 'source "$ROOT_DIR/Scripts/apple_pqc_sdk_probe.sh"' \
  || fail "real-device X-Wing smoke must source the Apple PQC SDK symbol probe"
script_has_literal "skybridge_configure_optional_apple_pqc_sdk_compile_gate macosx" \
  || fail "macOS host build must be guarded by the Apple PQC SDK symbol probe"
script_has_literal 'Apple PQC SDK symbol probe failed for the macOS host; refusing to build a real-device X-Wing smoke host without HAS_APPLE_PQC_SDK.' \
  || fail "missing Apple PQC SDK gate must fail closed before building the macOS host"
script_has_literal 'SKYBRIDGE_ENABLE_APPLE_PQC_SDK:-0' \
  || fail "real-device smoke must require the SwiftPM HAS_APPLE_PQC_SDK compile gate before X-Wing validation"
script_has_literal "skybridge_detect_apple_pqc_sdk iphoneos" \
  || fail "real-device X-Wing smoke must probe iPhoneOS Apple PQC SDK symbols before building the iOS app"
script_has_literal 'Apple PQC SDK symbol probe failed for the iOS app; refusing to build a real-device X-Wing smoke target without HAS_APPLE_PQC_SDK.' \
  || fail "missing iPhoneOS Apple PQC SDK symbols must fail closed before building the iOS app"
script_has_literal "SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK" \
  || fail "iOS real-device X-Wing smoke must pass the Xcode HAS_APPLE_PQC_SDK build setting"
script_has_literal 'IOS_BUILD_CONFIGURATION="${SKYBRIDGE_SMOKE_IOS_BUILD_CONFIGURATION:-Release}"' \
  || fail "formal P2P iOS builds must default to the Release configuration"
script_has_literal 'The iOS Debug product is diagnostic-only and requires SKYBRIDGE_REAL_DEVICE_P2P_LAB_RUN=1.' \
  || fail "Debug iOS products must be restricted to explicit lab diagnostics"
script_has_literal 'IOS_PROVISIONING_DEVICE_ID="$(validate_real_ipad_device_id)"' \
  || fail "CoreDevice selection must resolve the hardware UDID used by provisioning profiles"
script_has_literal '"$IOS_PROVISIONING_DEVICE_ID"' \
  || fail "distribution profile selection and product proof must consume the hardware UDID"
script_has_literal '-configuration "$IOS_BUILD_CONFIGURATION"' \
  || fail "the iOS build must consume the validated Release-or-lab-Debug configuration"
contains_literal "$ios_build_invocation_body" 'IOS_XCODEBUILD_ARGS=(' \
  || fail "the iOS build must start from a non-empty common argument array"
contains_literal "$ios_build_invocation_body" 'IOS_XCODEBUILD_ARGS+=(' \
  || fail "Release-only signing arguments must append to the common iOS build array"
contains_literal "$ios_build_invocation_body" 'skybridge_run_xcodebuild "${IOS_XCODEBUILD_ARGS[@]}"' \
  || fail "the iOS build must expand the always-non-empty common argument array"
! contains_literal "$ios_build_invocation_body" 'IOS_XCODE_SIGNING_SETTINGS' \
  || fail "the iOS build must not expand an empty Release-only array under Bash nounset"
script_has_literal 'Build/Products/${IOS_BUILD_CONFIGURATION}-iphoneos/SkyBridgeCompass-iOS.app' \
  || fail "iOS product selection must bind to the actual requested build configuration"
contains_literal "$source_provenance_body" 'git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all' \
  || fail "formal P2P acceptance must measure tracked and untracked Git provenance"
contains_literal "$source_provenance_body" 'Formal P2P acceptance requires a clean Git worktree' \
  || fail "dirty source provenance must fail closed outside lab mode"
contains_literal "$source_provenance_body" 'capture_source_input_binding' \
  || fail "source provenance must capture an exact build-input digest before any smoke build"
script_has_literal 'verify_source_input_binding_unchanged "mac-build"' \
  || fail "macOS smoke products must be followed by a source-input stability check"
script_has_literal 'verify_source_input_binding_unchanged "ios-build"' \
  || fail "iOS smoke products must be followed by a source-input stability check"
script_has_literal '"SKYBRIDGE_PACKAGING_SOURCE_INPUT_DIGEST=$IOS_SOURCE_INPUT_DIGEST"' \
  || fail "the iOS product must embed the exact measured source-input digest"
script_has_literal 'verify_ios_product_source_input_binding' \
  || fail "the signed iOS app executable and Info.plist must be bound to the source digest"
grep -Fq '<key>SkyBridgePackagingSourceInputDigest</key>' "$IOS_APP_INFO_PLIST" \
  || fail "the iOS Info.plist must expose the signed source-input digest marker"
grep -Fq 'SkyBridgePackagingSourceInputDigest: "$(SKYBRIDGE_PACKAGING_SOURCE_INPUT_DIGEST)"' "$IOS_PROJECT_YAML" \
  || fail "XcodeGen must preserve the source-input digest Info.plist expansion"
grep -Fq 'SKYBRIDGE_PACKAGING_SOURCE_INPUT_DIGEST: unbound' "$IOS_PROJECT_YAML" \
  || fail "ordinary iOS builds must remain explicitly unbound until a producer supplies a digest"
grep -Fq 'SKYBRIDGE_PACKAGING_SOURCE_INPUT_DIGEST = unbound;' "$IOS_PROJECT_FILE" \
  || fail "the generated Xcode project must preserve the source-input digest build setting"
script_has_literal 'write_ios_p2p_product_proof "$IOS_EMBEDDED_PROFILE" "$IOS_WIDGET_EMBEDDED_PROFILE"' \
  || fail "the built iOS app and Widget must emit measured signing/profile proof before installation"
script_has_literal 'source "$ROOT_DIR/Scripts/ios_distribution_signing_helpers.sh"' \
  || fail "P2P release proof must consume the shared iOS App + Widget signing implementation"
script_has_literal 'python3 "$ROOT_DIR/Scripts/resolve_ios_distribution_signing.py"' \
  || fail "P2P release profile selection must consume the shared fail-closed resolver"
script_has_literal 'skybridge_write_ios_distribution_product_proof' \
  || fail "P2P product proof wrapper must delegate to the shared App + Widget verifier"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :aps-environment' "$IOS_DEBUG_ENTITLEMENTS")" == "development" ]] \
  || fail "Debug aps-environment must remain development"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :aps-environment' "$IOS_RELEASE_ENTITLEMENTS")" == "production" ]] \
  || fail "Release aps-environment must be production"
grep -Fq 'CODE_SIGN_STYLE: Automatic' "$IOS_PROJECT_YAML" \
  || fail "XcodeGen Release configuration must use Xcode-managed (Automatic) signing"
grep -Fq 'PROVISIONING_PROFILE_SPECIFIER: "$(SKYBRIDGE_IOS_APP_DISTRIBUTION_PROFILE_SPECIFIER)"' "$IOS_PROJECT_YAML" \
  || fail "XcodeGen app Release configuration must retain the caller-resolved profile specifier indirection"
grep -Fq 'PROVISIONING_PROFILE_SPECIFIER: "$(SKYBRIDGE_IOS_WIDGET_DISTRIBUTION_PROFILE_SPECIFIER)"' "$IOS_PROJECT_YAML" \
  || fail "XcodeGen Widget Release configuration must retain the caller-resolved profile specifier indirection"
grep -Fq 'CODE_SIGN_STYLE = Automatic;' "$IOS_PROJECT_FILE" \
  || fail "generated Xcode Release configurations must use Xcode-managed (Automatic) signing"
grep -Fq 'PROVISIONING_PROFILE_SPECIFIER = "$(SKYBRIDGE_IOS_APP_DISTRIBUTION_PROFILE_SPECIFIER)";' "$IOS_PROJECT_FILE" \
  || fail "generated app Release configuration must retain the resolved profile specifier indirection"
grep -Fq 'PROVISIONING_PROFILE_SPECIFIER = "$(SKYBRIDGE_IOS_WIDGET_DISTRIBUTION_PROFILE_SPECIFIER)";' "$IOS_PROJECT_FILE" \
  || fail "generated Widget Release configuration must retain the resolved profile specifier indirection"
contains_literal "$distribution_profile_resolver_body" 'Library/MobileDevice/Provisioning Profiles' \
  || fail "Release signing must resolve only already-installed provisioning profiles"
contains_literal "$distribution_profile_resolver_body" 'Formal physical iOS acceptance requires exactly one installed matching' \
  || fail "missing or ambiguous app/Widget distribution profiles must fail closed"
contains_literal "$distribution_profile_resolver_body" 'entitlements.get("get-task-allow") is False' \
  || fail "installed distribution profiles must explicitly disable get-task-allow"
contains_literal "$distribution_profile_resolver_body" 'device_identifier in provisioned_devices' \
  || fail "both installed distribution profiles must bind the selected real device"
contains_literal "$distribution_profile_resolver_body" 'app_profile["certificateHashes"]' \
  || fail "app and Widget profiles must share a profile-bound distribution identity"
contains_literal "$distribution_profile_resolver_body" 'security", "find-identity", "-v", "-p", "codesigning"' \
  || fail "the profile-bound distribution certificate must have a local private-key identity"
script_has_literal '"CODE_SIGN_STYLE=Manual"' \
  || fail "the testing-surface device build must force Manual signing to bind the resolved distribution profile under the Automatic project default"
script_has_literal '"CODE_SIGN_IDENTITY=$IOS_DISTRIBUTION_IDENTITY_HASH"' \
  || fail "xcodebuild must use the uniquely profile-bound distribution identity"
script_has_literal '"SKYBRIDGE_IOS_APP_DISTRIBUTION_PROFILE_SPECIFIER=$IOS_APP_DISTRIBUTION_PROFILE_SPECIFIER"' \
  || fail "xcodebuild must receive the resolved app distribution profile"
script_has_literal '"SKYBRIDGE_IOS_WIDGET_DISTRIBUTION_PROFILE_SPECIFIER=$IOS_WIDGET_DISTRIBUTION_PROFILE_SPECIFIER"' \
  || fail "xcodebuild must receive the resolved Widget distribution profile"
contains_literal "$ios_product_proof_body" '/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"' \
  || fail "the iOS product proof must strictly verify the nested code signature"
contains_literal "$ios_product_proof_body" '/usr/bin/codesign --verify --strict --verbose=2 "$widget_path"' \
  || fail "the embedded iOS Widget must also pass strict signature verification"
contains_literal "$ios_product_proof_body" '--extract-certificates="$app_certificate_prefix"' \
  || fail "the iOS product proof must extract the app leaf signing certificate"
contains_literal "$ios_product_proof_body" '--extract-certificates="$widget_certificate_prefix"' \
  || fail "the iOS product proof must extract the Widget leaf signing certificate"
contains_literal "$ios_product_proof_body" 'skybridge_write_signed_entitlements "$app_path" "$app_signed_entitlements"' \
  || fail "the iOS product proof must inspect actual app signed entitlements"
contains_literal "$ios_product_proof_body" 'skybridge_write_signed_entitlements "$widget_path" "$widget_signed_entitlements"' \
  || fail "the iOS product proof must inspect actual Widget signed entitlements"
contains_literal "$ios_product_proof_body" 'skybridge_profile_supports_requested_profile_backed_entitlements' \
  || fail "the iOS product proof must reuse strict profile-backed entitlement coverage"
! contains_literal "$ios_product_proof_body" 'skybridge_validate_provisionprofile_app_identity' \
  || fail "the iOS product proof must not call the macOS-only profile identity helper"
contains_literal "$ios_product_proof_body" '"platformVerified": "iOS" in (profile.get("Platform") or [])' \
  || fail "the embedded provisioning profile must explicitly target iOS"
contains_literal "$ios_product_proof_body" 'profile.get("DeveloperCertificates", [])' \
  || fail "the leaf signing certificate must be bound to profile DeveloperCertificates"
contains_literal "$ios_product_proof_body" '"-checkend",' \
  || fail "the leaf signing certificate expiry must be checked"
contains_literal "$ios_product_proof_body" 'profile.get("ProvisionedDevices", [])' \
  || fail "the selected real device must be covered by the provisioning profile"
contains_literal "$ios_product_proof_body" 'signed_keychain_groups == expected_keychain_group_set' \
  || fail "the signed iOS product must carry exactly the configuration-specific Keychain groups"
contains_literal "$ios_product_proof_body" 'required_keychain_groups(' \
  || fail "the signed iOS product proof must derive App and Widget Keychain requirements from the requested configuration"
contains_literal "$ios_product_proof_body" 'not get_task_allow' \
  || fail "formal iOS product proof must reject get-task-allow"
contains_literal "$ios_product_proof_body" 'distribution_signing' \
  || fail "formal iOS product proof must require Apple distribution signing"
contains_literal "$ios_product_proof_body" '"nestedWidgetVerified": nested_widget_verified' \
  || fail "formal product proof must expose aggregate nested Widget verification"
contains_literal "$ios_product_proof_body" 'product_surface == "production"' \
  || fail "formal product proof must require the signed app to declare a production surface"
contains_literal "$ios_product_proof_body" 'not testing_compilation_condition' \
  || fail "formal product proof must reject DEBUG and SKYBRIDGE_TESTING compilation conditions"
contains_literal "$ios_product_proof_body" 'not binary_test_surface_detected' \
  || fail "formal product proof must reject binaries containing diagnostic smoke surfaces"
contains_literal "$ios_product_proof_body" 'source_repository_verified' \
  || fail "formal product proof must bind the signed app to an explicit source repository"
contains_literal "$ios_product_proof_body" 'source_revision_verified' \
  || fail "formal product proof must bind the signed app to a full source SHA"
contains_literal "$ios_product_proof_body" 'Print :SkyBridgePackagingSourceRepository' \
  || fail "formal product proof must measure source repository metadata from the signed app"
contains_literal "$ios_product_proof_body" '"$product_source_repository" == "$expected_source_repository"' \
  || fail "formal product proof must match signed repository metadata to the release environment"
script_has_literal '"SKYBRIDGE_PACKAGING_SOURCE_REPOSITORY=${GITHUB_REPOSITORY:-${SKYBRIDGE_SOURCE_REPOSITORY:-}}"' \
  || fail "the diagnostic P2P product must embed its source-repository provenance when available"
script_has_literal '"SKYBRIDGE_PACKAGING_PRODUCT_SURFACE=testing"' \
  || fail "the diagnostic P2P harness must truthfully label its signed iOS product as testing"
script_has_literal '"SKYBRIDGE_PACKAGING_SWIFT_ACTIVE_COMPILATION_CONDITIONS=HAS_APPLE_PQC_SDK,SKYBRIDGE_TESTING"' \
  || fail "the diagnostic P2P harness must embed its test compilation condition"
for provenance_key in \
  SkyBridgePackagingBuildConfiguration \
  SkyBridgePackagingGitDirtyState \
  SkyBridgePackagingGitCommit \
  SkyBridgePackagingSourceRepository \
  SkyBridgePackagingProductSurface \
  SkyBridgePackagingSwiftActiveCompilationConditions; do
  grep -Fq "<key>${provenance_key}</key>" "$IOS_APP_INFO_PLIST" \
    || fail "the explicit iOS Info.plist must contain signed provenance key ${provenance_key}"
done
script_has_literal '"OTHER_SWIFT_FLAGS=\$(inherited) -D SKYBRIDGE_TESTING"' \
  || fail "the P2P harness test surface must remain an explicit compile-time diagnostic condition"
grep -Fq 'REQUIRED_IDENTITY_ALGORITHM = "mldsa87"' "$RELEASE_ACCEPTANCE_VALIDATOR" \
  || fail "release acceptance must require the production ML-DSA-87 identity algorithm"
grep -Fq 'REQUIRED_IDENTITY_PROTECTION = "secureEnclaveRequired"' "$RELEASE_ACCEPTANCE_VALIDATOR" \
  || fail "release acceptance must require the Secure Enclave identity policy"
grep -Fq '"handshakePersistenceVerified"' "$RELEASE_ACCEPTANCE_VALIDATOR" \
  || fail "release acceptance must prove the production identity survives into handshake use"
grep -Fq '"currentPathAuthorityVerified"' "$RELEASE_ACCEPTANCE_VALIDATOR" \
  || fail "release acceptance must prove current-path authority on the production identity"

[[ -n "$verify_call_line" && -n "$performance_line" && -n "$mac_online_line" && -n "$host_final_line" && -n "$ios_final_line" ]] \
  || fail "smoke script should contain capture verification, performance validation, Mac online button smoke, and final sentinels"
(( verify_call_line < performance_line )) \
  || fail "capture verification must run before performance validation"
(( performance_line < mac_online_line )) \
  || fail "performance validation must run before the Mac online iPad button smoke"
(( mac_online_line < host_final_line && host_final_line < ios_final_line )) \
  || fail "smoke-final sentinels must be emitted only after the Mac online iPad button smoke succeeds"
script_has_literal 'has_current_packaged_mac_online = (' \
  || fail "release acceptance must distinguish the current packaged mac-online client from Debug diagnostics"
script_has_literal 'mac_online_source == "packaged" and mac_online_source_current == "1"' \
  || fail "release acceptance must require a current packaged mac-online source"
script_has_literal '"acceptanceEligible": False' \
  || fail "pre-cleanup P2P manifests must never be acceptance eligible"
script_has_literal '"diagnosticOnly": True' \
  || fail "pre-cleanup P2P manifests must remain diagnostic-only"
script_has_literal '"cleanupComplete": False' \
  || fail "pre-cleanup P2P manifests must explicitly record incomplete cleanup"
script_has_literal '"preCleanupCandidate": pre_cleanup_candidate' \
  || fail "pre-cleanup P2P manifests must preserve the fail-closed candidate decision"
script_has_literal 'and has_current_packaged_mac_online' \
  || fail "P2P acceptanceEligible must be bound to packaged-current mac-online proof"
script_has_literal 'finalize_release_acceptance_manifests_after_cleanup' \
  || fail "EXIT cleanup must own release-acceptance finalization"
script_has_literal "python3 \"\$ROOT_DIR/Scripts/finalize_release_acceptance_manifests.py\"" \
  || fail "P2P cleanup must use the shared release-acceptance finalizer"
grep -Fq 'final_payload["cleanupComplete"] = True' "$RELEASE_ACCEPTANCE_FINALIZER" \
  || fail "cleanup finalization must explicitly commit cleanupComplete=true"
grep -Fq 'final_payload["acceptanceEligible"] = candidate' "$RELEASE_ACCEPTANCE_FINALIZER" \
  || fail "cleanup finalization may only promote the preserved pre-cleanup candidate"
grep -Fq 'final_payload["diagnosticOnly"] = not candidate' "$RELEASE_ACCEPTANCE_FINALIZER" \
  || fail "cleanup finalization must keep ineligible candidates diagnostic-only"
grep -Fq 'final_payload["finalizationOrder"] = FINALIZATION_ORDER' "$RELEASE_ACCEPTANCE_FINALIZER" \
  || fail "cleanup finalization must stamp the private-first proof order"
grep -Fq 'FINALIZATION_ORDER = "private-then-public-v1"' "$RELEASE_ACCEPTANCE_VALIDATOR" \
  || fail "release-acceptance validator must pin the private-first finalization contract"
grep -Fq 'payload.get("finalizationOrder") != FINALIZATION_ORDER' "$RELEASE_ACCEPTANCE_VALIDATOR" \
  || fail "release-acceptance validator must reject missing or unknown finalization order"
python3 - "$RELEASE_ACCEPTANCE_FINALIZER" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
body = source.split("def finalize_release_acceptance_manifests(", 1)[1].split("def _parse_args", 1)[0]
markers = (
    "_atomic_replace(\n        private_path,",
    "_verify_final_manifest(private_path,",
    "_atomic_replace(\n        public_path,",
    "_verify_final_manifest(public_path,",
)
positions = [body.find(marker) for marker in markers]
if any(position < 0 for position in positions) or positions != sorted(positions):
    raise SystemExit("release-acceptance finalizer is not private-write/private-verify/public-write/public-verify")
if "original_private" in body or "original_public" in body or "rollback" in body.lower():
    raise SystemExit("release-acceptance finalizer must never roll back to an older proof state")
for required in (
    "metadata.st_uid != os.geteuid()",
    "metadata.st_nlink != 1",
    "stat.S_IMODE(metadata.st_mode) != MANIFEST_MODE",
    "metadata.st_size <= 0 or metadata.st_size > MAX_MANIFEST_BYTES",
    "os.fsync(descriptor)",
    "os.fsync(directory_descriptor)",
):
    if required not in source:
        raise SystemExit(f"release-acceptance finalizer is missing strict contract: {required}")
PY

script_has_literal "fail_if_forbidden_fallback_evidence \"\$IOS_STATUS_LOCAL\" \"\$label\"" \
  || fail "iOS wait loop must reject forbidden attemptedFallback/fallbackResult evidence"
script_has_literal "fail_if_forbidden_fallback_evidence \"\$HOST_STATUS\" \"\$label\"" \
  || fail "macOS host wait loop must reject forbidden attemptedFallback/fallbackResult evidence"
grep -q 'allowed = {' "$SMOKE_SCRIPT" \
  || fail "fallback evidence validator must define an explicit allow-list"
grep -q '"attemptedFallback": {"none"}' "$SMOKE_SCRIPT" \
  || fail "fallback evidence validator must allow only attemptedFallback=none"
grep -q '"fallbackResult": {"none", "not-attempted"}' "$SMOKE_SCRIPT" \
  || fail "fallback evidence validator must allow only non-activated fallback results"
! grep -q -- '-DSKYBRIDGE_UI_SMOKE_HARNESS' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must not compile a special production UI lifecycle branch"
! grep -q 'SKYBRIDGE_ONLINE_CONNECT_STATUS_FILE' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must not make the production coordinator write artifact diagnostics"
grep -q 'observe_mac_online_ipad_connected_row' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must prove the clicked row reaches connected state from external Accessibility"
grep -q 'run_stdin_command_with_hard_timeout 20 swift -' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad connected-row Accessibility probe must be bounded by a hard timeout"
grep -q 'subprocess.Popen(command, stdin=subprocess.PIPE)' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad Swift Accessibility probes must be supervised without shell job-termination noise"
grep -q 'start_macos_online_ipad_client' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must wait for the real SkyBridge app process before clicking"
grep -q 'ipad-control-port reachable=1 host=%s port=%s identityKey=%s targetDeviceId=%s source=pre-mac-online-probe probe=tcp-only listenerReady=1' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad TCP probe must only emit positive evidence when iOS listener readiness is proven"
grep -q 'bonjour_control_route_reachable' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad TCP probe must resolve the app-authored Bonjour service when its host IP is not populated yet"
grep -q 'bonjourServiceNameBase64' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad TCP probe must consume a lossless Bonjour service name instead of a whitespace-sanitized display value"
grep -q 'NWEndpoint.service' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad Bonjour pre-probe must exercise Network.framework service endpoint resolution"
script_has_literal 'parameters.requiredInterfaceType = .wifi' \
  || fail "Mac online iPad Bonjour pre-probe must not let an attached-device interface count as P2P reachability"
script_has_literal 'NWConnection timed out waiting for Bonjour control connection readiness' \
  || fail "Bonjour probe timeout evidence must describe connection readiness instead of misclassifying a TCP stall as DNS resolution"
[[ -f "$AUTHENTICATED_ROUTE_EXTRACTOR" ]] \
  || fail "Mac online iPad pre-probe must ship the authenticated forward-route evidence parser"
script_has_literal 'authenticated_forward_ipad_control_host' \
  || fail "Mac online iPad pre-probe must expose an explicit authenticated forward-peer route class"
script_has_literal 'routeKind=authenticated-forward-peer' \
  || fail "Authenticated forward-peer route observations must remain distinct from Bonjour evidence"
script_has_literal 'routeEvidence=operator-approved-xwing-forward-session' \
  || fail "Authenticated forward-peer liveness must be labeled with its operator-approved X-Wing evidence boundary"
script_has_literal 'bonjourReachable=0' \
  || fail "Using an authenticated forward-peer route must preserve the failed Bonjour observation"
grep -q 'remoteControlNoticeActive' "$AUTHENTICATED_ROUTE_EXTRACTOR" \
  || fail "Authenticated route extraction must require an active remote-control notice"
grep -q 'remoteControlNoticeDisconnected' "$AUTHENTICATED_ROUTE_EXTRACTOR" \
  || fail "Authenticated route extraction must reject a disconnected session"
grep -q 'remoteDeviceId' "$AUTHENTICATED_ROUTE_EXTRACTOR" \
  || fail "Authenticated route extraction must bind both notice and X-Wing establishment to the target device id"
grep -q 'X-Wing_PQC' "$AUTHENTICATED_ROUTE_EXTRACTOR" \
  || fail "Authenticated route extraction must require X-Wing PQC approval evidence"
grep -q '192.168.0.0/16' "$AUTHENTICATED_ROUTE_EXTRACTOR" \
  || fail "Authenticated route extraction must restrict IPv4 evidence to explicit infrastructure LAN ranges"
grep -q 'reason=listener-not-ready' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad TCP probe must fail closed when TCP is reachable but iOS listener readiness is missing"
script_has_literal 'validate_mac_online_product_p2p_path' \
  || fail "Mac online iPad smoke must validate app-authored product currentPath evidence"
script_has_literal 'p2p-connection-ready-path .*pathStatus=satisfied .*routeClass=(wifi|awdl) .*attached=0 .*linkLocal=0' \
  || fail "Mac online iPad smoke must require a Wi-Fi/AWDL non-attached, non-link-local product path"
script_has_literal 'target product P2P path used an attached or wired interface' \
  || fail "Mac online iPad path gate must reject attached and wired interfaces"
grep -q 'phase=app-local-network-privacy reason=local-network-permission-denied' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must fail fast when the packaged app is denied Local Network privacy"
grep -q 'bootstrap-control-waiting .*reason=local-network-permission-denied' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must consume app-side Local Network denial evidence instead of waiting for connected-row timeout"
grep -q 'mac-online-connect-result .*targetFamily=ipad .*result=success' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must verify that the synchronized artifact contains connected-row success before the CLI gate"
grep -q 'failed stage=mac-online-ipad phase=status-sync reason=status-sync-missing-success' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must fail closed when runtime success evidence was not synchronized to the artifact"
grep -q 'source_render_gap_budget_exceeded = int' "$SMOKE_SCRIPT" \
  || fail "Remote desktop performance gate must expose Mac source render-gap budget diagnostics"
grep -q 'macSourceRenderGapBudgetExceeded=' "$SMOKE_SCRIPT" \
  || fail "Remote desktop performance summary must retain Mac source render-gap budget diagnostics"
grep -q 'sck_source_frame_age_budget_exceeded = int' "$SMOKE_SCRIPT" \
  || fail "Remote desktop performance gate must expose SCK source-frame-age budget diagnostics"
grep -q 'macSourceFrameAgeBudgetExceeded=' "$SMOKE_SCRIPT" \
  || fail "Remote desktop performance summary must retain SCK source-frame-age budget diagnostics"
! grep -q 'Mac smoke source render gap exceeded live-source budget' "$SMOKE_SCRIPT" \
  || fail "Remote desktop performance gate must not hard-fail on smoke-source heartbeat jitter after end-to-end cadence passes"
grep -q 'ios_listener_ready_for_control_port' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad TCP probe must bind positive evidence to iOS listener-ready status"
grep -q 'IOS_LISTENER_STATUS_NAME=' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad listener readiness must use a per-run iOS listener status sidecar"
grep -q 'SKYBRIDGE_SMOKE_LISTENER_STATUS_BASENAME="$IOS_LISTENER_STATUS_NAME"' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad listener readiness must pass the sidecar basename to the iOS app"
grep -q '"SKYBRIDGE_SMOKE_LISTENER_STATUS_BASENAME"' "$SMOKE_SCRIPT" \
  || fail "iOS launch environment must preserve the listener sidecar basename"
grep -q 'copy_ios_app_cache_file "$IOS_LISTENER_STATUS_NAME" "$IOS_LISTENER_STATUS_LOCAL" "listener-status"' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad listener readiness must read the app-authored listener sidecar"
grep -q 'IOS_TRACE_NAME="${IOS_STATUS_NAME}.trace.log"' "$SMOKE_SCRIPT" \
  || fail "Real-device P2P smoke must name the app-authored detailed iOS trace sidecar"
grep -q 'IOS_TRACE_LOCAL="$ARTIFACT_DIR/${IOS_STATUS_NAME%.status.log}.trace.log"' "$SMOKE_SCRIPT" \
  || fail "Real-device P2P smoke must persist the detailed iOS trace inside the artifact directory"
grep -q 'copy_ios_app_cache_file "$IOS_TRACE_NAME" "$IOS_TRACE_LOCAL" "trace"' "$SMOKE_SCRIPT" \
  || fail "Real-device P2P cleanup must copy the detailed iOS trace instead of losing first-frame rejection evidence"
grep -q 'copy_ios_trace || true' "$SMOKE_SCRIPT" \
  || fail "Real-device P2P cleanup must best-effort preserve the iOS trace on failed runs"
! grep -q 'copy_ios_app_cache_file "$IOS_STATUS_NAME" "$IOS_STATUS_APP_CACHE_LOCAL" "status-listener"' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad listener readiness must not copy the high-volume iOS status log"
grep -q 'lifecycle_pattern = re.compile' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad listener readiness must parse the latest structured listener lifecycle status"
grep -Fq 'p2p-listener\s+ready' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad listener readiness must require the latest structured ready state"
! grep -q 'grep -Fq "监听器就绪，端口: ${port}" "$IOS_STATUS_LOCAL"' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad listener readiness must not accept stale legacy console ready lines"
if perl -0ne 'exit(/reason=listener-not-ready.*?\n\s*sleep 1\n\s*continue/s ? 0 : 1)' "$SMOKE_SCRIPT"; then
  fail "Mac online iPad listener-not-ready branch must still reach the timeout failure check"
fi
script_has_literal "RUN_MAC_ONLINE_IPAD_SMOKE=\"\${SKYBRIDGE_SMOKE_RUN_MAC_ONLINE_IPAD:-1}\"" \
  || fail "Mac online iPad smoke must be explicitly skippable for security-notice profiles"
grep -q 'profile-separated-from-active-remote-control-session' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad skip evidence must explain that active remote-control session coverage is separated"
contains_literal "$remote_control_notice_lifecycle_body" 'remoteControlNoticeShown .*transport=p2p' \
  || fail "P2P notice acceptance must first observe the shown lifecycle event"
contains_literal "$remote_control_notice_lifecycle_body" 'remoteControlNoticePanelPresented .*transport=p2p .*phase=awaitingApproval' \
  || fail "P2P notice acceptance must observe the visible awaiting-approval panel before operator approval"
contains_literal "$remote_control_notice_lifecycle_body" 'buttons=[^[:space:]]*(approve[^[:space:]]*reject|reject[^[:space:]]*approve)' \
  || fail "P2P notice acceptance must require both approve and reject actions on the pending panel"
contains_literal "$remote_control_notice_lifecycle_body" 'Waiting for the operator to approve the visible macOS P2P remote-control notice' \
  || fail "P2P notice acceptance must make the manual approval boundary explicit to the operator"
contains_literal "$remote_control_notice_lifecycle_body" 'remoteControlNoticeHumanApproved .*transport=p2p' \
  || fail "ordinary Approved evidence must not count without the user-interaction-only HumanApproved event"
shown_notice_line="$(grep -n 'remoteControlNoticeShown .*transport=p2p' <<<"$remote_control_notice_lifecycle_body" | head -n 1 | cut -d: -f1)"
pending_panel_line="$(grep -n 'remoteControlNoticePanelPresented .*transport=p2p .*phase=awaitingApproval' <<<"$remote_control_notice_lifecycle_body" | head -n 1 | cut -d: -f1)"
human_approved_notice_line="$(grep -n 'remoteControlNoticeHumanApproved .*transport=p2p' <<<"$remote_control_notice_lifecycle_body" | head -n 1 | cut -d: -f1)"
approved_notice_line="$(grep -n 'remoteControlNoticeApproved .*transport=p2p' <<<"$remote_control_notice_lifecycle_body" | head -n 1 | cut -d: -f1)"
active_notice_line="$(grep -n 'remoteControlNoticeActive .*transport=p2p' <<<"$remote_control_notice_lifecycle_body" | head -n 1 | cut -d: -f1)"
[[ -n "$shown_notice_line" && -n "$pending_panel_line" && -n "$human_approved_notice_line" && -n "$approved_notice_line" && -n "$active_notice_line" ]] \
  || fail "P2P notice acceptance lifecycle must include shown, pending panel, human-approved, approved, and active waits"
(( shown_notice_line < pending_panel_line && pending_panel_line < human_approved_notice_line && human_approved_notice_line < approved_notice_line && approved_notice_line < active_notice_line )) \
  || fail "P2P notice acceptance must wait in shown -> pending panel -> human approved -> approved -> active order"
contains_literal "$remote_control_notice_lifecycle_body" 'write_p2p_remote_control_approval_proof' \
  || fail "the lifecycle wait must materialize measured approval proof"
contains_literal "$approval_proof_body" 'expected_lifecycle = ["Shown", "PanelPresented", "HumanApproved", "Approved", "Active"]' \
  || fail "approval proof must bind all events to the strict human lifecycle"
contains_literal "$approval_proof_body" 'if lifecycle == expected_lifecycle and panel_contract_by_session.get(session) is True' \
  || fail "approval proof must enforce same-session order and visible panel actions"
contains_literal "$approval_proof_body" 'runtime_auto_approval = any' \
  || fail "runtime auto-approval must be measured from status evidence"
contains_literal "$approval_proof_body" '"humanApproval": human_approval' \
  || fail "humanApproval must be derived from measured lifecycle evidence"
grep -q 'MAC_ONLINE_STDERR=' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must keep app stderr separate from stdout"
grep -q 'MAC_ONLINE_OPEN_STDERR=' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must capture LaunchServices open stderr"
grep -q 'MAC_ONLINE_LAUNCH_STDERR=' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must route LaunchServices app stderr through a TCC-safe temp file"
grep -q 'MAC_ONLINE_LAUNCH_OPEN_STDERR=' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must route open stderr through a TCC-safe temp file"
script_has_literal "--stderr \"\$MAC_ONLINE_LAUNCH_STDERR\"" \
  || fail "Mac online iPad LaunchServices app stderr must not share stdout"
script_has_literal "2>>\"\$MAC_ONLINE_LAUNCH_OPEN_STDERR\"" \
  || fail "Mac online iPad smoke must capture open(1) diagnostics on failure"
grep -q 'terminate_stale_macos_online_ipad_clients' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must terminate stale copies of the same app bundle before LaunchServices open"
grep -q 'MAC_ONLINE_PACKAGED_APP_BUNDLE=' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must default to a packaged app bundle"
grep -q 'SKYBRIDGE_SMOKE_MAC_ONLINE_APP_BUNDLE' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must allow an explicit packaged app bundle path"
grep -q 'SKYBRIDGE_SMOKE_MAC_ONLINE_ALLOW_DEBUG_BUILD' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad Debug build must require an explicit diagnostic opt-in"
script_has_literal "xcrun stapler validate \"\$MAC_ONLINE_APP_BUNDLE\"" \
  || fail "Mac online iPad packaged app must have stapled notarization evidence"
script_has_literal "spctl --assess --type execute \"\$MAC_ONLINE_APP_BUNDLE\"" \
  || fail "Mac online iPad packaged app must pass Gatekeeper assessment"
contains_literal "$mac_online_build_body" "if [[ -d \"\$MAC_ONLINE_PACKAGED_APP_BUNDLE\" ]]" \
  || fail "Mac online iPad smoke should use the packaged app before considering Debug builds"
script_has_literal 'verify_macos_online_ipad_pib_v3_wire_freshness' \
  || fail "Mac online iPad smoke must reject packaged clients with stale PIB wire code"
script_has_literal '"SkyBridge-PIB-1-V3-Confirm"' \
  || fail "Mac online iPad smoke must require the PIB-1 v3 confirm binary marker"
script_has_literal '"SkyBridge-PIB-1-V3-SignedFinalAck"' \
  || fail "Mac online iPad smoke must require the PIB-1 v3 final-ack binary marker"
script_has_literal 'LC_ALL=C /usr/bin/grep -aFq -- "$marker" "$MAC_ONLINE_APP_BIN"' \
  || fail "Mac online iPad smoke must inspect the exact packaged executable for PIB-1 v3 markers"
script_has_literal '[[ "$wire_source" -nt "$MAC_ONLINE_APP_BIN" ]]' \
  || fail "Mac online iPad smoke must fail when the PIB wire source is newer than the packaged executable"
script_has_literal '  verify_macos_online_ipad_pib_v3_wire_freshness' \
  || fail "Mac online iPad app verification must enforce PIB-v3 source and binary freshness"
contains_literal "$mac_online_build_body" "if [[ \"\$MAC_ONLINE_ALLOW_DEBUG_BUILD\" != \"1\" ]]" \
  || fail "Mac online iPad Debug build should be gated behind an explicit opt-in"
! grep -q 'SKYBRIDGE_SMOKE_MAC_ONLINE_SIGN_IDENTITY' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad Debug app must not bypass canonical profile-bound signing with an arbitrary identity override"
! grep -q 'select_macos_online_ipad_debug_signing_identity' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad Debug app must not select the first Apple Development identity"
! grep -q 'macos_online_ipad_debug_entitlements_for' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad Debug app must not reuse Debug xcent entitlements that lack the product Keychain groups"
grep -q 'sign_macos_online_ipad_debug_app' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad Debug app must use certificate signing before LaunchServices open"
grep -q 'remove_macos_online_ipad_debug_signature_before_binary_mutation' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad Debug app must remove the Xcode signature before install_name_tool mutates rpaths"
remove_signature_line="$(grep -n 'remove_macos_online_ipad_debug_signature_before_binary_mutation' <<<"$mac_online_signing_body" | tail -n 1 | cut -d: -f1)"
normalize_rpath_line="$(grep -n 'normalize_macos_online_ipad_debug_rpaths' <<<"$mac_online_signing_body" | tail -n 1 | cut -d: -f1)"
[[ -n "$remove_signature_line" && -n "$normalize_rpath_line" ]] \
  || fail "Mac online iPad Debug signing function must call signature removal and rpath normalization"
(( remove_signature_line < normalize_rpath_line )) \
  || fail "Mac online iPad Debug executable signature must be removed before install_name_tool mutates rpaths"
grep -q 'normalize_macos_online_ipad_debug_rpaths' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad Debug app must remove external PackageFrameworks rpaths before signing"
grep -q 'normalize_macos_online_ipad_debug_frameworks' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad Debug app must normalize embedded framework layouts before signing"
grep -q 'skybridge_assert_no_nested_framework_versions_payload "$webrtc_framework"' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad app verification must reject nested versioned framework payloads"
script_has_literal '/usr/bin/file -b "$binary" | grep -Fq '\''Mach-O'\''' \
  || fail "Mac online iPad Debug app must sign Mach-O framework payloads instead of every executable resource"
script_has_literal 'MAC_HOST_PRODUCT_WIDGET_PROFILE="$MAC_HOST_PRODUCT_WIDGET_BUNDLE/Contents/embedded.provisionprofile"' \
  || fail "Mac online iPad Debug Widget must use the canonical dist Widget profile"
script_has_literal 'MAC_HOST_PRODUCT_WIDGET_ENTITLEMENTS="$MAC_HOST_SIGNING_DIR/product-widget-entitlements.plist"' \
  || fail "Mac online iPad Debug Widget must use the canonical dist signed entitlements"
script_has_literal 'compare_macos_online_ipad_entitlements_exact' \
  || fail "Mac online iPad Debug app and Widget must compare post-sign entitlements exactly"
script_has_literal '--options runtime' \
  || fail "Mac online iPad Debug nested code must retain hardened runtime signing"
contains_literal "$mac_online_build_body" "MAC_ONLINE_APP_BUNDLE=\"\$MAC_ONLINE_PACKAGED_APP_BUNDLE\"" \
  || fail "Mac online iPad packaged app must launch from the stable signed app bundle for TCC-stable Local Network proof"
! contains_literal "$mac_online_build_body" "ditto \"\$MAC_ONLINE_PACKAGED_APP_BUNDLE\" \"\$MAC_ONLINE_RUNTIME_APP_BUNDLE\"" \
  || fail "Mac online iPad packaged app must not be copied to a fresh temporary bundle before Local Network proof"
contains_literal "$mac_online_build_body" "ditto \"\$debug_app_bundle\" \"\$MAC_ONLINE_RUNTIME_APP_BUNDLE\"" \
  || fail "Mac online iPad Debug app must launch from a TCC-safe runtime app copy"
contains_literal "$mac_online_build_body" "sign_macos_online_ipad_debug_app" \
  || fail "Mac online iPad Debug app must not use ad-hoc signing for LaunchServices open"
! contains_literal "$mac_online_build_body" "/usr/bin/codesign --force --deep --sign - \"\$MAC_ONLINE_APP_BUNDLE\"" \
  || fail "Mac online iPad Debug app must not use ad-hoc signing for LaunchServices open"
grep -q 'mac-online-app-signing source=debug identityKind=developer-id identitySource=canonical-dist appProfile=exact widgetProfile=exact entitlements=app-widget-exact nested=verified keychainAccess=product preMutationSignature=removed' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad Debug app signing must record exact product identity proof without leaking certificate names"
contains_literal "$mac_online_signing_body" '--sign "$MAC_HOST_PRODUCT_SIGN_IDENTITY_HASH"' \
  || fail "Mac online iPad Debug app and Widget must use the unique canonical profile-bound identity hash"
contains_literal "$mac_online_signing_body" '--entitlements "$MAC_HOST_PRODUCT_WIDGET_ENTITLEMENTS"' \
  || fail "Mac online iPad Debug Widget must be signed with exact canonical Widget entitlements"
contains_literal "$mac_online_signing_body" '--entitlements "$MAC_HOST_PRODUCT_ENTITLEMENTS"' \
  || fail "Mac online iPad Debug app must be signed with exact canonical app entitlements"
script_has_literal 'cp "$MAC_HOST_PRODUCT_PROFILE" "$MAC_ONLINE_APP_BUNDLE/Contents/embedded.provisionprofile"' \
  || fail "Mac online iPad Debug app must embed the exact canonical app profile"
script_has_literal 'cp "$MAC_HOST_PRODUCT_WIDGET_PROFILE" "$widget_bundle/Contents/embedded.provisionprofile"' \
  || fail "Mac online iPad Debug Widget must embed the exact canonical Widget profile"
script_has_literal '/usr/bin/codesign --verify --deep --strict --verbose=2 "$MAC_ONLINE_APP_BUNDLE"' \
  || fail "Mac online iPad Debug app must pass deep strict nested signature verification"
grep -q 'mac-online-app source=%s %s bundle=%s executable=%s' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad app verification must emit source plus trust status evidence"
grep -q 'stapler=valid spctl=accepted' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad packaged app status must include notarization and Gatekeeper proof"
grep -q 'mac_online_app_reports_connected_after_ax_click' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad connected proof must accept app-authored connected status only after AX click evidence"
grep -q 'mac-online-connect-app action=button .*targetFamily=ipad .*result=success' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad connected proof must require app-authored button success"
grep -q 'observer=app-status-after-ax-click' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad connected proof must label app-status success after AX click without pretending it is AX text"
! contains_literal "$mac_online_packaged_body" "xattr" \
  || fail "packaged macOS product must remain read-only; its extended attributes cannot be mutated"
! contains_literal "$mac_online_packaged_body" "ditto" \
  || fail "packaged macOS product branch must not copy or rewrite the signed product"
! contains_literal "$mac_online_packaged_body" "codesign" \
  || fail "packaged macOS product branch must not re-sign the signed product"
contains_literal "$mac_online_debug_body" 'clear_runtime_bundle_quarantine_if_present "$MAC_ONLINE_APP_BUNDLE" "macOS online iPad Debug app"' \
  || fail "runtime-only Debug app quarantine must be conditionally cleared with explicit error handling"
[[ "$mac_online_build_body" == *'ENABLE_DEBUG_DYLIB=NO'* ]] \
  || fail "Mac online iPad Debug app must disable debug dylib stubs for reliable LaunchServices launch"
grep -q 'find_macos_online_ipad_client_pid' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must track the app PID, not the open wrapper PID"
grep -q 'launch method=open-app-bundle pid=%s role=mac-online-ipad-client' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must emit LaunchServices app PID evidence"
grep -q 'launch requested role=mac-online-ipad-client' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must distinguish shell launch requests from real app boot evidence"
! grep -q 'boot role=mac-online-ipad-client process=SkyBridgeCompassApp uiRole=external-accessibility' "$SMOKE_SCRIPT" \
  || fail "shell harness must not prewrite dashboard boot evidence"
! grep -q '/usr/bin/open -n -W' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must not use open -W as the app process handle"
script_has_literal "SKYBRIDGE_TARGET_IPAD_IDENTITY=\"\$IOS_PQC_DEVICE_ID\"" \
  || fail "Accessibility click evidence must be identity-bound to the real iPad PQC report"
grep -q 'No connected real iPad found' "$SMOKE_SCRIPT" \
  || fail "real-device P2P smoke must fail closed instead of silently selecting a non-iPad device"
grep -q 'validate_real_ipad_device_id' "$SMOKE_SCRIPT" \
  || fail "explicit real-device target UDID must be validated as a connected iPad"
grep -q 'Selected real-device target is not a connected iPad according to devicectl JSON' "$SMOKE_SCRIPT" \
  || fail "explicit real-device target validation must fail closed for non-iPad devices"
grep -q 'is_physical_devicectl_device' "$SMOKE_SCRIPT" \
  || fail "real-device P2P smoke must reject CoreSimulator devices when selecting an iPad"
grep -q 'visibility_class != "simulators"' "$SMOKE_SCRIPT" \
  || fail "real-device P2P smoke must not select devices from the simulator visibility class"
grep -q 'com.apple.CoreSimulator.SimulatorCoreDevicePlugin' "$SMOKE_SCRIPT" \
  || fail "real-device P2P smoke must reject CoreSimulator provider records"
grep -q 'has_install_application_capability' "$SMOKE_SCRIPT" \
  || fail "real-device P2P smoke must only select iPads that support app installation"
! grep -q 'SKYBRIDGE_SMOKE_ALLOW_NON_IPAD_DEVICE' "$SMOKE_SCRIPT" \
  || fail "real-device P2P remote smoke must not provide a non-iPad opt-in for iPad verification"
script_has_literal "MAC_HOST_LAUNCH_MODE=\"\${SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE:-packaged}\"" \
  || fail "real-device acceptance must default the macOS host to packaged-product identity launch"
script_has_literal 'acceptance_violations+=("SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE=packaged")' \
  || fail "acceptance mode must reject the diagnostic direct host path"
script_has_literal 'packaged|packaged-lab|direct) ;;' \
  || fail "macOS host launch policy must enumerate packaged-lab as an explicit third mode"
script_has_literal 'if [[ "$MAC_HOST_LAUNCH_MODE" == "packaged-lab" && "$LAB_RUN" != "1" ]]; then' \
  || fail "packaged-lab must fail before work unless the explicit lab profile is active"
script_has_literal 'IDENTITY_AUDIT_ONLY="${SKYBRIDGE_SMOKE_IDENTITY_AUDIT_ONLY:-0}"' \
  || fail "the read-only identity audit must be an explicit default-off mode"
script_has_literal 'IDENTITY_AUDIT_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_IDENTITY_AUDIT_TIMEOUT_SECONDS:-120}"' \
  || fail "the read-only identity audit must have an explicit bounded default timeout"
script_has_literal 'IDENTITY_AUDIT_TIMEOUT_SECONDS < 30 || IDENTITY_AUDIT_TIMEOUT_SECONDS > 300' \
  || fail "identity audit timeout overrides must stay within the reviewed bounded range"
contains_literal "$host_start_body" 'audit_started_at >= IDENTITY_AUDIT_TIMEOUT_SECONDS' \
  || fail "identity audit launch must use the validated bounded timeout"
script_has_literal 'if [[ "$LAB_RUN" != "1" || "$MAC_HOST_LAUNCH_MODE" != "packaged-lab" ]]; then' \
  || fail "identity audit must require the signed packaged-lab profile"
script_has_literal '--env "SKYBRIDGE_SMOKE_IDENTITY_AUDIT_ONLY=$IDENTITY_AUDIT_ONLY"' \
  || fail "LaunchServices must forward only the fixed identity-audit boolean"
contains_literal "$host_start_body" 'validate_identity_audit_output' \
  || fail "identity audit completion must pass the bounded JSON validator"
script_has_literal '"stableAcrossReads"' \
  || fail "identity audit evidence must prove a stable double-read snapshot"
script_has_literal 'Identity audit output must contain exactly one JSON record' \
  || fail "identity audit stdout must reject appended or ambiguous records"
script_has_literal 'Signed read-only identity audit completed; this diagnostic is never release-acceptance evidence.' \
  || fail "identity audit must remain explicitly outside release acceptance"
script_has_literal 'mac_host_uses_signed_app_bundle()' \
  || fail "product-identity host modes must share one closed signed-app routing policy"
grep -Fq 'payload.get("macHostLaunchMode") != "packaged"' "$RELEASE_ACCEPTANCE_FINALIZER" \
  || fail "manifest finalization must independently reject packaged-lab host evidence"
grep -Fq 'payload.get("macHostLaunchMode") != "packaged"' "$RELEASE_ACCEPTANCE_VALIDATOR" \
  || fail "release validation must independently require the formal packaged host mode"
grep -Fq 'identitySourceStaplerValid' "$RELEASE_ACCEPTANCE_VALIDATOR" \
  || fail "release validation must require stapler proof for the host identity source"
grep -Fq 'identitySourceGatekeeperAccepted' "$RELEASE_ACCEPTANCE_VALIDATOR" \
  || fail "release validation must require Gatekeeper proof for the host identity source"
script_has_literal 'MAC_HOST_PRODUCT_APP_BUNDLE="$ROOT_DIR/dist/SkyBridge Compass Pro.app"' \
  || fail "acceptance host signing must use the canonical dist product app as its read-only identity source"
script_has_literal 'MAC_HOST_PRODUCT_BUNDLE_ID="com.skybridge.compass.pro"' \
  || fail "macOS host helper must bind to the production bundle identifier for product Keychain access"
script_has_literal 'MAC_HOST_PRODUCT_PROFILE="$MAC_HOST_PRODUCT_APP_BUNDLE/Contents/embedded.provisionprofile"' \
  || fail "macOS host signing must require the packaged product embedded provisioning profile"
script_has_literal 'MAC_APP_BUNDLE="$MAC_ONLINE_RUNTIME_DIR/LocalLanInteropHost.app"' \
  || fail "signed helper and its embedded profile must stay outside publishable smoke artifacts"
script_has_literal 'MAC_HOST_SIGNING_DIR="$MAC_ONLINE_RUNTIME_DIR/mac-host-signing"' \
  || fail "extracted product entitlements must remain in the private runtime directory"
! script_has_literal 'MAC_APP_BUNDLE="$ARTIFACT_DIR/LocalLanInteropHost.app"' \
  || fail "publishable artifacts must not contain the signed helper app or embedded provisioning profile"
contains_literal "$product_signing_body" '/usr/bin/codesign --verify --deep --strict --verbose=2 "$MAC_HOST_PRODUCT_APP_BUNDLE"' \
  || fail "packaged product identity input must pass strict code-sign verification"
contains_literal "$product_signing_body" '/usr/bin/xcrun stapler validate "$MAC_HOST_PRODUCT_APP_BUNDLE"' \
  || fail "packaged product identity input must have a valid stapled notarization ticket"
contains_literal "$product_signing_body" '/usr/sbin/spctl --assess --type execute "$MAC_HOST_PRODUCT_APP_BUNDLE"' \
  || fail "packaged product identity input must pass Gatekeeper assessment"
contains_literal "$product_signing_body" 'if [[ "$MAC_HOST_LAUNCH_MODE" == "packaged" ]]; then' \
  || fail "distribution trust checks may be omitted only outside the exact formal packaged mode"
contains_literal "$product_signing_body" 'MAC_HOST_IDENTITY_SOURCE_STAPLER_VALID=0' \
  || fail "packaged-lab must explicitly record missing stapler proof"
contains_literal "$product_signing_body" 'MAC_HOST_IDENTITY_SOURCE_GATEKEEPER_ACCEPTED=0' \
  || fail "packaged-lab must explicitly record missing Gatekeeper proof"
contains_literal "$product_signing_body" 'verify_macos_smoke_host_identity_source_unchanged()' \
  || fail "signed host preparation must bind the product identity source against TOCTOU changes"
contains_literal "$product_signing_body" 'product_profile_sha256' \
  || fail "product identity freshness must bind the app provisioning profile hash"
contains_literal "$product_signing_body" 'product_widget_profile_sha256' \
  || fail "product identity freshness must bind the Widget provisioning profile hash"
contains_literal "$product_signing_body" 'product_cdhash' \
  || fail "product identity freshness must bind the app code directory hash"
contains_literal "$product_signing_body" 'widget_cdhash' \
  || fail "product identity freshness must bind the Widget code directory hash"
contains_literal "$product_signing_body" 'skybridge_write_signed_entitlements "$MAC_HOST_PRODUCT_APP_BUNDLE" "$MAC_HOST_PRODUCT_ENTITLEMENTS"' \
  || fail "macOS host helper must use the packaged product signed entitlements"
contains_literal "$product_signing_body" 'skybridge_validate_provisionprofile_app_identity' \
  || fail "packaged product profile must match its signed bundle and team identity"
contains_literal "$product_signing_body" 'skybridge_profile_supports_requested_profile_backed_entitlements' \
  || fail "packaged product profile must cover all signed profile-backed entitlements"
contains_literal "$product_signing_body" 'skybridge_resolve_profile_bound_codesign_identity_hash' \
  || fail "macOS host signing must resolve a unique profile-bound existing identity without exporting it"
grep -Fq 'skybridge_validate_developer_id_distribution_profile_certificate()' "$SIGNING_HELPERS" \
  || fail "shared signing helpers must validate Developer ID distribution profile/certificate binding"
grep -Fq 'skybridge_select_unique_profile_bound_codesign_identity_hash()' "$SIGNING_HELPERS" \
  || fail "same-authority local identities must be intersected with profile DeveloperCertificates"
grep -Fq 'authority/profile certificate intersection is not unique' "$SIGNING_HELPERS" \
  || fail "missing or ambiguous profile-bound identity intersections must fail closed"
grep -Fq '"ProvisionedDevices" in profile' "$SIGNING_HELPERS" \
  || fail "Developer ID profile validation must reject device allow-lists"
grep -Fq '"get-task-allow" in entitlements' "$SIGNING_HELPERS" \
  || fail "Developer ID profile validation must reject get-task-allow"
contains_literal "$product_signing_body" 'derive_macos_smoke_host_minimal_entitlements' \
  || fail "helper entitlements must be derived as a least-privilege subset of product entitlements"
contains_literal "$product_signing_body" 'validate_macos_smoke_host_minimal_entitlements' \
  || fail "derived and signed helper entitlements must pass an explicit allow-list"
contains_literal "$minimal_entitlements_body" 'required_groups = {expected_application_identifier, expected_shared_group}' \
  || fail "helper must inherit exactly the product and shared Keychain groups, not future extra groups"
contains_literal "$minimal_entitlements_body" '"com.apple.security.network.client": True' \
  || fail "least-privilege helper entitlements must retain network client capability"
contains_literal "$minimal_entitlements_body" '"com.apple.security.network.server": True' \
  || fail "least-privilege helper entitlements must retain network server capability"
! grep -Eiq 'icloud|ubiquity|application-groups|personal-information\.location|get-task-allow' <<<"$minimal_entitlements_body" \
  || fail "least-privilege helper policy must not inherit cloud, app-group, location, or debug entitlements"
script_has_literal 'SMOKE_BUILD_DIR="${SKYBRIDGE_P2P_SMOKE_BUILD_DIR:-$ROOT_DIR/.build/real-device-p2p-smoke}"' \
  || fail "real-device remote smoke should isolate Apple-PQC SwiftPM products from the default build directory"
script_has_literal 'swift build --scratch-path "$SMOKE_BUILD_DIR" --product LocalLanInteropHost' \
  || fail "real-device remote smoke should build the LAN host in its dedicated SwiftPM scratch path"
script_has_literal 'MAC_DIRECT_BIN="$SMOKE_BUILD_DIR/debug/LocalLanInteropHost"' \
  || fail "explicit diagnostic direct macOS host launch should use the isolated SwiftPM build product"
script_has_literal 'MAC_SOURCE_DIRECT_BIN="$SMOKE_BUILD_DIR/debug/LocalLanSmokeSourceHost"' \
  || fail "real-device remote smoke should launch the isolated macOS smoke source helper"
script_has_literal 'swift build --scratch-path "$SMOKE_BUILD_DIR" --product LocalLanSmokeSourceHost' \
  || fail "real-device remote smoke should build the independent macOS smoke source helper"
! grep -Fq '$ROOT_DIR/.build/debug/' "$SMOKE_SCRIPT" \
  || fail "Apple-PQC smoke products must never be read from the default SwiftPM build directory"
grep -q 'start_macos_smoke_source_host' "$SMOKE_SCRIPT" \
  || fail "real-device remote smoke should start the source helper separately from the LAN host"
grep -q 'SKYBRIDGE_SMOKE_ROLE=mac-smoke-source' "$SMOKE_SCRIPT" \
  || fail "source helper launch must expose a distinct smoke role"
grep -q 'fail_if_smoke_source_exited' "$SMOKE_SCRIPT" \
  || fail "wait loops must fail fast if the source helper exits"
! grep -q 'SKYBRIDGE_SMOKE_REMOTE_ANIMATION=1' "$SMOKE_SCRIPT" \
  || fail "LAN host must not own the smoke animation source"
grep -q 'Unsupported SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE' "$SMOKE_SCRIPT" \
  || fail "macOS host launch mode should be validated before smoke execution"
contains_literal "$host_start_body" 'case "$MAC_HOST_LAUNCH_MODE" in' \
  || fail "macOS host start must use an explicit closed launch-mode switch"
contains_literal "$host_start_body" 'direct)' \
  || fail "macOS host start should route direct mode to the direct app binary"
contains_literal "$direct_launch_body" 'if [[ "$LAB_RUN" != "1" ]]' \
  || fail "direct SwiftPM host launch must enforce diagnostic lab mode at the execution boundary"
contains_literal "$direct_launch_body" " \"\$MAC_DIRECT_BIN\" >\"\$HOST_STDOUT\" 2>&1 &" \
  || fail "direct macOS host launch should execute the SwiftPM build product, not the app bundle copy"
! contains_literal "$direct_launch_body" 'launch method=direct-app-binary pid=$HOST_PID mode=direct' \
  || fail "direct host startup must not write launch evidence before the app resets its status file"
contains_literal "$launch_evidence_body" 'launch method=direct-app-binary pid=$HOST_PID mode=direct binary=swiftpm-build-product' \
  || fail "post-ready direct macOS host launch evidence should identify the SwiftPM product"
[[ "$direct_launch_body" != *"fallbackFrom=open-app-bundle"* ]] \
  || fail "direct macOS host launch evidence must not include open-app-bundle fallback wording"
! contains_literal "$host_start_body" 'fallback=direct-app-binary' \
  || fail "packaged-product acceptance launch must never fall back to a direct SwiftPM binary"
contains_literal "$host_start_body" 'failed stage=mac-host phase=launch reason=packaged-product-open-failed' \
  || fail "packaged-product LaunchServices failure must be explicit and fail closed"
contains_literal "$host_start_body" 'failed stage=mac-host phase=launch reason=packaged-product-app-pid-not-found' \
  || fail "packaged-product app PID timeout must fail closed without fallback"
[[ "$(grep -Fc 'if mac_host_uses_signed_app_bundle; then' "$SMOKE_SCRIPT")" -ge 3 ]] \
  || fail "both product-identity modes must share verification, helper preparation, and localization proof"
contains_literal "$host_start_body" 'packaged-lab)' \
  || fail "macOS host launch must explicitly route packaged-lab without a generic non-direct fallback"
contains_literal "$launch_evidence_body" 'launch method=signed-lab-app-bundle' \
  || fail "packaged-lab launch evidence must be distinguishable from formal packaged evidence"
contains_literal "$launch_evidence_body" 'stapler=skipped spctl=skipped diagnosticOnly=1' \
  || fail "packaged-lab launch evidence must explicitly remain diagnostic-only"
contains_literal "$host_bundle_prepare_body" '-c "Add :CFBundleIdentifier string $MAC_HOST_PRODUCT_BUNDLE_ID"' \
  || fail "product-identity helper must use the exact packaged product bundle identifier"
contains_literal "$host_bundle_prepare_body" 'cp "$MAC_HOST_PRODUCT_PROFILE" "$embedded_profile"' \
  || fail "product-identity helper must embed the exact packaged product provisioning profile"
contains_literal "$host_bundle_prepare_body" 'local source_core_resource_bundle="$SMOKE_BUILD_DIR/debug/SkyBridgeCompassApp_SkyBridgeCore.bundle"' \
  || fail "product-identity helper must source the exact SkyBridgeCore resource bundle from its dedicated SwiftPM scratch"
contains_literal "$host_bundle_prepare_body" 'local embedded_core_resource_bundle="$resources_dir/SkyBridgeCompassApp_SkyBridgeCore.bundle"' \
  || fail "product-identity helper must embed the exact SkyBridgeCore resource bundle under Contents/Resources"
contains_literal "$host_bundle_prepare_body" '[[ ! -d "$SMOKE_BUILD_DIR" || ! -d "$SMOKE_BUILD_DIR/debug" ]]' \
  || fail "product-identity helper must require a populated dedicated SwiftPM scratch"
contains_literal "$host_bundle_prepare_body" '[[ ! -d "$source_core_resource_bundle" || -L "$source_core_resource_bundle" ]]' \
  || fail "product-identity helper must reject a missing or symlinked SkyBridgeCore resource bundle"
contains_literal "$host_bundle_prepare_body" 'scratch_root_dir="$(cd "$SMOKE_BUILD_DIR" && pwd -P)"' \
  || fail "product-identity helper must canonicalize its dedicated SwiftPM scratch"
contains_literal "$host_bundle_prepare_body" 'scratch_debug_dir="$(cd "$SMOKE_BUILD_DIR/debug" && pwd -P)"' \
  || fail "product-identity helper must canonicalize the SwiftPM platform debug product link"
contains_literal "$host_bundle_prepare_body" '[[ "$scratch_debug_dir" != "$scratch_root_dir/"* ]]' \
  || fail "product-identity helper must reject a debug product directory outside its dedicated scratch"
contains_literal "$host_bundle_prepare_body" '[[ "$source_resource_dir" != "$scratch_debug_dir/SkyBridgeCompassApp_SkyBridgeCore.bundle" ]]' \
  || fail "product-identity helper must require the exact Core bundle as a direct canonical debug product"
contains_literal "$host_bundle_prepare_body" '/usr/bin/find -P "$source_core_resource_bundle" -type l -print -quit' \
  || fail "product-identity helper must reject symlinks inside the SkyBridgeCore resource bundle"
contains_literal "$host_bundle_prepare_body" '/usr/bin/ditto --norsrc --noextattr --noqtn --noacl' \
  || fail "product-identity helper must explicitly copy the exact resource bundle without source metadata"
contains_literal "$host_bundle_prepare_body" 'local embedded_core_resource_root="$embedded_core_resource_contents/Resources"' \
  || fail "product-identity helper must normalize the flat SwiftPM bundle into a standard Contents/Resources layout"
contains_literal "$host_bundle_prepare_body" 'mv "$embedded_core_resource_root/Info.plist" "$embedded_core_resource_contents/Info.plist"' \
  || fail "product-identity helper must place the copied bundle Info.plist under its normalized Contents directory"
contains_literal "$host_bundle_prepare_body" 'cmp -s "$source_core_resource_bundle/Info.plist" "$embedded_core_resource_contents/Info.plist"' \
  || fail "product-identity helper must verify the normalized bundle Info.plist byte-for-byte"
contains_literal "$host_bundle_prepare_body" '/usr/bin/diff -qr -x Info.plist "$source_core_resource_bundle" "$embedded_core_resource_root"' \
  || fail "product-identity helper must verify the copied resource bundle before code signing seals it"
contains_literal "$host_bundle_prepare_body" '"$embedded_core_resource_root" \
    "pre-sign"' \
  || fail "product-identity helper must validate all security-notice localizations before signing"
contains_literal "$host_bundle_prepare_body" '"$embedded_core_resource_root" \
    "post-sign"' \
  || fail "product-identity helper must revalidate all security-notice localizations after strict signature verification"
[[ "$host_bundle_prepare_body" == *'/usr/bin/ditto --norsrc --noextattr --noqtn --noacl'*'/usr/bin/codesign --force --timestamp=none --options runtime --sign'* ]] \
  || fail "product-identity helper must embed the resource bundle before signing the app bundle"
contains_literal "$host_bundle_prepare_body" 'resourceBundleLayout=normalized-contents-resources resourceBundleSource=dedicated-swiftpm-scratch resourceBundleSealed=1' \
  || fail "product-identity helper status must record the signed dedicated resource-bundle provenance"
script_has_literal '--env "SKYBRIDGE_SMOKE_REQUIRE_EMBEDDED_CORE_RESOURCES=1"' \
  || fail "packaged-product helper launch must require the embedded signed localization bundle"
script_has_literal 'remote-control-localization requiredKeys=20 embeddedRawKeys=0 managerRawKeys=0 source=embedded-signed-core' \
  || fail "packaged-product acceptance must wait for the runtime 20-key embedded localization probe"
! contains_literal "$host_bundle_prepare_body" 'debug/*.bundle' \
  || fail "product-identity helper must never copy an open-ended set of SwiftPM resource bundles"
contains_literal "$host_bundle_prepare_body" '--sign "$MAC_HOST_PRODUCT_SIGN_IDENTITY_HASH"' \
  || fail "product-identity helper must be signed with the profile-bound Developer ID certificate hash"
contains_literal "$host_bundle_prepare_body" '--entitlements "$MAC_HOST_HELPER_ENTITLEMENTS"' \
  || fail "product-identity helper must be signed with derived least-privilege entitlements"
contains_literal "$host_bundle_prepare_body" 'cmp -s "$MAC_HOST_PRODUCT_PROFILE" "$embedded_profile"' \
  || fail "signed helper must retain the exact packaged product profile bytes"
contains_literal "$host_bundle_prepare_body" 'embedded_profile_sha256' \
  || fail "signed helper must retain the originally verified product profile hash"
contains_literal "$host_bundle_prepare_body" 'verify_macos_smoke_host_identity_source_unchanged' \
  || fail "signed helper must recheck product identity freshness after signing"
contains_literal "$host_bundle_prepare_body" 'skybridge_write_signed_entitlements "$MAC_APP_BUNDLE" "$MAC_HOST_SIGNED_ENTITLEMENTS"' \
  || fail "signed helper entitlements must be re-extracted for post-sign verification"
! contains_literal "$host_bundle_prepare_body" 'codesign --force --deep --sign -' \
  || fail "acceptance helper must never use ad-hoc signing"
! contains_literal "$host_bundle_prepare_body" 'LocalLanInteropHostSmoke.${RUN_ID}' \
  || fail "acceptance helper must not create a random bundle identity that loses product Keychain access"
script_has_literal 'skybridge_smoke_require_safe_run_id "$RUN_ID" "SKYBRIDGE_SMOKE_P2P_REMOTE_RUN_ID"' \
  || fail "P2P smoke runtime path must reject unsafe run identifiers before any recursive cleanup"
script_has_literal '/bin/mkdir -m 700 "$MAC_ONLINE_RUNTIME_DIR"' \
  || fail "P2P smoke runtime directory must be private to the current user"
script_has_literal 'HOST_STATUS="$MAC_ONLINE_RUNTIME_DIR/mac.status.log"' \
  || fail "LaunchServices host status must stay in the TCC-safe private runtime directory"
script_has_literal 'HOST_PQC_REPORT="$MAC_ONLINE_RUNTIME_DIR/mac.pqc.json"' \
  || fail "LaunchServices host PQC output must stay in the TCC-safe private runtime directory"
script_has_literal 'HOST_STDOUT="$MAC_ONLINE_RUNTIME_DIR/mac.stdout.log"' \
  || fail "LaunchServices stdout/stderr must stay outside the protected Desktop artifact path"
script_has_literal 'sync_macos_smoke_host_artifacts' \
  || fail "private runtime host evidence must be persisted to the release artifact directory"
contains_literal "$artifact_sync_body" 'if [[ "$MAC_HOST_STARTED" == "1" ]]; then' \
  || fail "artifact sync must distinguish a launched host from a pre-launch cleanup"
contains_literal "$artifact_sync_body" '[[ ! -s "$HOST_STATUS" ]] || [[ ! -s "$HOST_PQC_REPORT" ]] || [[ ! -f "$HOST_STDOUT" ]]' \
  || fail "artifact sync must fail closed when launched-host evidence is missing"
script_has_literal 'failed stage=cleanup phase=artifact-sync reason=mac-host-runtime-artifact-copy-failed' \
  || fail "runtime evidence persistence failure must affect an otherwise successful acceptance run"
contains_literal "$cleanup_body" 'terminate_tracked_process "$HOST_PID" "macOS smoke host" "$expected_host_executable"' \
  || fail "cleanup must terminate the host only through the executable-bound process helper"
contains_literal "$cleanup_body" 'terminate_tracked_process "$MAC_SOURCE_PID" "macOS smoke source" "$MAC_SOURCE_DIRECT_BIN"' \
  || fail "cleanup must terminate the source helper only through the executable-bound process helper"
contains_literal "$cleanup_body" 'terminate_tracked_process "$MAC_ONLINE_PID" "macOS online iPad client" "$MAC_ONLINE_APP_BIN"' \
  || fail "cleanup must terminate the online client only through the executable-bound process helper"
contains_literal "$tracked_process_termination_body" 'actual_canonical="$(python3 -c' \
  || fail "tracked-process cleanup must canonicalize the executable identity before signaling"
contains_literal "$tracked_process_termination_body" 'if [[ "$actual_canonical" != "$expected_canonical" ]]; then' \
  || fail "tracked-process cleanup must reject PID reuse or executable mismatch"
contains_literal "$tracked_process_termination_body" 'kill -TERM "$pid"' \
  || fail "tracked-process cleanup must attempt bounded graceful termination"
contains_literal "$tracked_process_termination_body" 'kill -KILL "$pid"' \
  || fail "tracked-process cleanup must have a bounded, identity-revalidated force-termination path"
! contains_literal "$cleanup_body" 'kill -TERM "$HOST_PID"' \
  || fail "cleanup must not signal the host PID without executable identity validation"
script_has_literal 'unregister_launch_services_app_bundle "$MAC_APP_BUNDLE"' \
  || fail "cleanup must unregister the temporary same-bundle-id helper"
script_has_literal 'MAC_ONLINE_APP_REGISTERED=0' \
  || fail "cleanup must independently track the runtime mac-online app registration"
script_has_literal 'cleanup_macos_online_ipad_launch_services_registration' \
  || fail "cleanup must unregister the exact runtime mac-online app"
script_has_literal 'verify_launch_services_runtime_paths_absent "$runtime_app"' \
  || fail "cleanup must prove stale runtime app and Widget paths are absent from LaunchServices"
script_has_literal 'restore_canonical_macos_launch_services_registration_last' \
  || fail "cleanup must restore the canonical packaged product as its final registration operation"
script_has_literal 'verify_launch_services_paths_state \
    present \
    "$MAC_HOST_PRODUCT_APP_BUNDLE"' \
  || fail "cleanup must prove the canonical parent app path exists after final registration"
script_has_literal 'verify_launch_services_paths_state \
    absent \
    "$MAC_ONLINE_RUNTIME_APP_BUNDLE" \
    "$runtime_online_widget" \
    "$MAC_APP_BUNDLE" \
    "$runtime_helper_widget"' \
  || fail "cleanup must prove every runtime app and Widget exact path is absent after canonical restoration"
! grep -Fq '    "$canonical_widget"; then' "$SMOKE_SCRIPT" \
  || fail "canonical parent registration must not require an independent Widget LaunchServices record"
online_cleanup_line="$(grep -n 'cleanup_macos_online_ipad_launch_services_registration' <<<"$cleanup_body" | tail -n 1 | cut -d: -f1)"
helper_cleanup_line="$(grep -n 'cleanup_macos_smoke_host_launch_services_registration' <<<"$cleanup_body" | tail -n 1 | cut -d: -f1)"
canonical_restore_line="$(grep -n 'restore_canonical_macos_launch_services_registration_last' <<<"$cleanup_body" | tail -n 1 | cut -d: -f1)"
[[ -n "$online_cleanup_line" && -n "$helper_cleanup_line" && -n "$canonical_restore_line" ]] \
  || fail "cleanup must contain online unregister, helper unregister, and canonical restore phases"
(( online_cleanup_line < helper_cleanup_line && helper_cleanup_line < canonical_restore_line )) \
  || fail "cleanup order must be runtime app unregister -> helper unregister -> canonical register last"
script_has_literal 'terminate_macos_smoke_host_bundle_processes' \
  || fail "cleanup must terminate helper processes by the exact runtime executable path"
script_has_literal 'failed stage=cleanup phase=launch-services-restore reason=canonical-app-or-runtime-absence-proof-missing runtime=preserved-private' \
  || fail "LaunchServices restoration failure must preserve the private runtime and affect a successful run"
script_has_literal 'if (( original_status == 0 && cleanup_status == 0 )); then' \
  || fail "release-acceptance manifests may only finalize after a successful run and successful cleanup"
script_has_literal 'failed stage=cleanup phase=release-acceptance reason=manifest-finalization-failed' \
  || fail "acceptance manifest finalization failure must turn an otherwise green run red"
script_has_literal "verify_mac_control_port_reachable \"\$MAC_CONTROL_HOST\" \"\$MAC_CONTROL_PORT\"" \
  || fail "real-device smoke should verify the dynamic control listener before launching iOS"
script_has_literal "mac-control-port reachable=1 host=\$host port=\$port source=local-self-probe" \
  || fail "macOS control port probe must identify itself as a local-only reachability diagnostic"
script_has_literal 'verify_host_pid_owns_listener_port "$MAC_CONTROL_PORT" "control"' \
  || fail "real-device smoke must bind the dynamic control port to the tracked host PID"
script_has_literal 'record_macos_smoke_host_launch_evidence' \
  || fail "host launch evidence must be appended only after the host resets and publishes its status file"
! grep -q 'SKYBRIDGE_SMOKE_TARGET_HOST\|SKYBRIDGE_SMOKE_TARGET_CONTROL_PORT\|SKYBRIDGE_SMOKE_TARGET_REMOTE_PORT' "$SMOKE_SCRIPT" \
  || fail "iOS smoke must not replace provenance-bound Bonjour routes with independently injected host/port fields"
grep -q 'failed stage=mac-host phase=control-port-probe reason=tcp-unreachable' "$SMOKE_SCRIPT" \
  || fail "macOS control port probe should fail fast with a structured startup failure"
grep -q 'verify_ipad_control_port_reachable_from_mac' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must actively probe the iPad control TCP port before clicking Connect"
grep -q 'ipad-control-port reachable=1 host=%s port=%s identityKey=%s targetDeviceId=%s source=pre-mac-online-probe probe=tcp-only listenerReady=1' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad control-port probe should emit positive TCP-only reachability evidence only after listener readiness"
grep -q 'failed stage=mac-online-ipad phase=ipad-control-port-probe reason=tcp-unreachable' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad control-port probe should fail fast before UI click"
grep -q 'failed stage=mac-online-ipad phase=ipad-control-port-probe reason=listener-not-ready' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad control-port probe should fail fast when listener readiness is missing"
grep -q 'failed stage=mac-online-ipad phase=app-local-network-privacy reason=local-network-permission-denied' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad control flow should distinguish packaged-app Local Network denial from connected-row timeout"
grep -q 'latest_mac_online_ipad_control_route' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad probe must derive host-or-Bonjour route evidence from the app-authored OnlineDeviceCard row"
grep -q 'minimum_source_samples' "$SMOKE_SCRIPT" \
  || fail "remote performance validation should require source helper heartbeats inside the final window"
! grep -q 'Mac smoke source aggregate renderFPS below live-source budget' "$SMOKE_SCRIPT" \
  || fail "remote performance validation must not fail solely on source helper aggregate render cadence"
grep -q 'source_frame_delta = source_frame_end - source_frame_start' "$SMOKE_SCRIPT" \
  || fail "remote performance validation should still prove source helper frame liveness inside the final window"
grep -q 'macSourceRenderProgressFPS=' "$SMOKE_SCRIPT" \
  || fail "remote performance validation should report diagnostic aggregate source render cadence evidence"
grep -q 'writerClockStrict' "$SMOKE_SCRIPT" \
  || fail "remote performance validation should require strict DispatchSource timer evidence"
grep -q 'mac-remote-realtime-activity active=1' "$SMOKE_SCRIPT" \
  || fail "remote performance validation should require realtime activity/App Nap protection evidence"
grep -q 'failed stage=mac-host' "$SMOKE_SCRIPT" \
  || fail "host failure matcher should surface mac-host startup failures before a generic process-exited report"
grep -q 'failed stage=mac-smoke-source' "$SMOKE_SCRIPT" \
  || fail "host failure matcher should surface smoke source helper failures"
grep -q 'already_connected' "$SMOKE_SCRIPT" \
  || fail "smoke failure matcher should surface SOA already_connected rejections instead of treating success sentinels as enough"
script_has_literal 'source "$ROOT_DIR/Scripts/real_device_ios_process_ownership.sh"' \
  || fail "P2P remote smoke must use the shared exact iOS console-handle ownership boundary"
script_has_literal 'skybridge_ios_require_fresh_app_launch' \
  || fail "P2P remote smoke must prove the app is absent before launching"
script_has_literal 'skybridge_ios_capture_console_handle' \
  || fail "P2P remote smoke must capture the exact local devicectl handle before proceeding"
script_has_literal 'skybridge_ios_signal_console_handle' \
  || fail "P2P remote smoke cleanup must signal the exact audit-token-bound console handle"
script_has_literal 'skybridge_ios_capture_exited_console_identity' \
  || fail "P2P remote smoke cleanup must validate the exited remote launch identity"
script_has_literal 'skybridge_ios_require_app_absent_after_handle_exit' \
  || fail "P2P remote smoke cleanup must prove remote app absence"
script_has_literal 'IOS_PROCESS_CLEANUP_RECEIPT="$ARTIFACT_DIR/ios-process-cleanup.json"' \
  || fail "P2P remote smoke must emit an explicit process-cleanup receipt"
script_has_literal 'python3 "$ROOT_DIR/Scripts/check_p2p_notice_disconnect.py"' \
  || fail "P2P remote smoke must bind Disconnected evidence to the approved notice session"
script_has_literal 'P2P_NOTICE_SESSION="$approved_session"' \
  || fail "P2P approval proof must retain the exact session only for same-session lifecycle validation"
! script_has_literal '--terminate-existing' \
  || fail "P2P remote smoke must never terminate a pre-existing app instance"
! script_has_literal 'device process terminate' \
  || fail "P2P remote smoke must never authorize iOS termination from a reusable remote PID"
! grep -Fq 'kill "$IOS_CONSOLE_PID"' "$SMOKE_SCRIPT" \
  || fail "P2P remote smoke must never signal the local console process by PID alone"
ios_exact_cleanup_line="$(grep -n '^  terminate_ios_remote_smoke_app_exact "remote-control-notice-disconnect-proof"' "$SMOKE_SCRIPT" | head -n 1 | cut -d: -f1)"
performance_gate_line="$(grep -n '^skybridge_smoke_check_performance_gate .*p2p-remote' "$SMOKE_SCRIPT" | head -n 1 | cut -d: -f1)"
[[ -n "$ios_exact_cleanup_line" && -n "$performance_gate_line" ]] \
  || fail "P2P remote smoke must contain exact iOS cleanup and performance gate phases"
(( ios_exact_cleanup_line < performance_gate_line )) \
  || fail "exact iOS app exit and absence proof must precede performance/public artifact acceptance"
PYTHONDONTWRITEBYTECODE=1 python3 "$SCRIPT_DIR/test_check_p2p_notice_disconnect.py" >/dev/null \
  || fail "same-session P2P notice disconnect behavior tests failed"

mode_guard_root="$(mktemp -d)"
mode_guard_artifact="$mode_guard_root/must-not-be-created"
set +e
mode_guard_output="$({
  SKYBRIDGE_REAL_DEVICE_P2P_LAB_RUN=0 \
  SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE=packaged-lab \
  SKYBRIDGE_SMOKE_ARTIFACT_DIR="$mode_guard_artifact" \
    bash "$SMOKE_SCRIPT"
} 2>&1)"
mode_guard_status=$?
set -e
[[ "$mode_guard_status" -eq 2 ]] \
  || fail "packaged-lab without LAB_RUN=1 must exit 2 before execution"
[[ "$mode_guard_output" == *"packaged-lab requires SKYBRIDGE_REAL_DEVICE_P2P_LAB_RUN=1"* ]] \
  || fail "packaged-lab rejection must explain the exact required diagnostic profile"
[[ ! -e "$mode_guard_artifact" ]] \
  || fail "packaged-lab rejection must happen before artifact or runtime side effects"
/bin/rm -r "$mode_guard_root"

audit_guard_root="$(mktemp -d)"
audit_guard_artifact="$audit_guard_root/must-not-be-created"
set +e
audit_guard_output="$({
  SKYBRIDGE_REAL_DEVICE_P2P_LAB_RUN=1 \
  SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE=packaged \
  SKYBRIDGE_SMOKE_IDENTITY_AUDIT_ONLY=1 \
  SKYBRIDGE_SMOKE_ARTIFACT_DIR="$audit_guard_artifact" \
    bash "$SMOKE_SCRIPT"
} 2>&1)"
audit_guard_status=$?
set -e
[[ "$audit_guard_status" -eq 2 ]] \
  || fail "identity audit outside packaged-lab must exit 2 before execution"
[[ "$audit_guard_output" == *"identity audit is diagnostic-only"* ]] \
  || fail "identity audit rejection must explain the exact signed lab boundary"
[[ ! -e "$audit_guard_artifact" ]] \
  || fail "identity audit rejection must happen before artifact or runtime side effects"
/bin/rm -r "$audit_guard_root"

audit_timeout_guard_root="$(mktemp -d)"
audit_timeout_guard_artifact="$audit_timeout_guard_root/must-not-be-created"
set +e
audit_timeout_guard_output="$({
  SKYBRIDGE_REAL_DEVICE_P2P_LAB_RUN=1 \
  SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE=packaged-lab \
  SKYBRIDGE_SMOKE_IDENTITY_AUDIT_ONLY=1 \
  SKYBRIDGE_SMOKE_IDENTITY_AUDIT_TIMEOUT_SECONDS=0 \
  SKYBRIDGE_SMOKE_ARTIFACT_DIR="$audit_timeout_guard_artifact" \
    bash "$SMOKE_SCRIPT"
} 2>&1)"
audit_timeout_guard_status=$?
set -e
[[ "$audit_timeout_guard_status" -eq 2 ]] \
  || fail "invalid identity audit timeout must exit 2 before execution"
[[ "$audit_timeout_guard_output" == *"must be an integer from 30 through 300"* ]] \
  || fail "invalid identity audit timeout must explain the bounded contract"
[[ ! -e "$audit_timeout_guard_artifact" ]] \
  || fail "invalid identity audit timeout must be rejected before artifact side effects"
/bin/rm -r "$audit_timeout_guard_root"

echo "[test-real-device-smoke-preflight] all checks passed"
