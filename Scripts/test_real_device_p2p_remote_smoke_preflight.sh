#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE_SCRIPT="${SCRIPT_DIR}/run_real_device_p2p_remote_smoke.sh"

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
host_start_body="$(
  awk '
    /^start_macos_smoke_host\(\)/ { in_function = 1 }
    /^append_ios_status\(\)/ { in_function = 0 }
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
pqc_gate_line="$(grep -n 'Checking Apple PQC SDK gate for macOS host' "$SMOKE_SCRIPT" | head -n 1 | cut -d: -f1)"
build_line="$(grep -n 'Building macOS LAN host' "$SMOKE_SCRIPT" | head -n 1 | cut -d: -f1)"
verify_call_line="$(grep -n '^verify_mac_smoke_capture_source_visible$' "$SMOKE_SCRIPT" | head -n 1 | cut -d: -f1)"
performance_line="$(grep -n '^validate_remote_desktop_performance_window$' "$SMOKE_SCRIPT" | head -n 1 | cut -d: -f1)"
mac_online_line="$(grep -n '^[[:space:]]*run_mac_online_ipad_button_smoke$' "$SMOKE_SCRIPT" | head -n 1 | cut -d: -f1)"
host_final_line="$(grep -n 'append_host_status "smoke-final result=success' "$SMOKE_SCRIPT" | head -n 1 | cut -d: -f1)"
ios_final_line="$(grep -n 'append_ios_status "smoke-final result=success' "$SMOKE_SCRIPT" | head -n 1 | cut -d: -f1)"

[[ -n "$preflight_line" && -n "$pqc_gate_line" && -n "$build_line" ]] \
  || fail "smoke script should contain preflight, Apple PQC SDK gate, and build markers"
(( preflight_line < build_line )) \
  || fail "visible desktop preflight should run before the expensive macOS host build"
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

[[ -n "$verify_call_line" && -n "$performance_line" && -n "$mac_online_line" && -n "$host_final_line" && -n "$ios_final_line" ]] \
  || fail "smoke script should contain capture verification, performance validation, Mac online button smoke, and final sentinels"
(( verify_call_line < performance_line )) \
  || fail "capture verification must run before performance validation"
(( performance_line < mac_online_line )) \
  || fail "performance validation must run before the Mac online iPad button smoke"
(( mac_online_line < host_final_line && host_final_line < ios_final_line )) \
  || fail "smoke-final sentinels must be emitted only after the Mac online iPad button smoke succeeds"

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
grep -q 'reason=listener-not-ready' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad TCP probe must fail closed when TCP is reachable but iOS listener readiness is missing"
grep -q 'phase=app-local-network-privacy reason=local-network-permission-denied' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must fail fast when the packaged app is denied Local Network privacy"
grep -q 'bootstrap-control-waiting .*reason=local-network-permission-denied' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad smoke must consume app-side Local Network denial evidence instead of waiting for connected-row timeout"
grep -q 'ios_listener_ready_for_control_port' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad TCP probe must bind positive evidence to iOS listener-ready status"
grep -q 'copy_ios_app_cache_file "$IOS_STATUS_NAME" "$IOS_STATUS_APP_CACHE_LOCAL" "status-listener"' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad listener readiness must read the app-authored iOS cache status"
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
contains_literal "$mac_online_build_body" "if [[ \"\$MAC_ONLINE_ALLOW_DEBUG_BUILD\" != \"1\" ]]" \
  || fail "Mac online iPad Debug build should be gated behind an explicit opt-in"
grep -q 'SKYBRIDGE_SMOKE_MAC_ONLINE_SIGN_IDENTITY' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad Debug app signing identity must be explicitly overridable"
grep -q 'select_macos_online_ipad_debug_signing_identity' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad Debug app must select a certificate signing identity"
grep -q 'sign_macos_online_ipad_debug_app' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad Debug app must use certificate signing before LaunchServices open"
grep -q 'normalize_macos_online_ipad_debug_rpaths' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad Debug app must remove external PackageFrameworks rpaths before signing"
grep -q 'normalize_macos_online_ipad_debug_frameworks' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad Debug app must normalize embedded framework layouts before signing"
grep -q 'skybridge_assert_no_nested_framework_versions_payload "$webrtc_framework"' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad app verification must reject nested versioned framework payloads"
grep -q -- '-perm -111' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad Debug app must sign executable files inside embedded frameworks"
contains_literal "$mac_online_build_body" "ditto \"\$debug_app_bundle\" \"\$MAC_ONLINE_RUNTIME_APP_BUNDLE\"" \
  || fail "Mac online iPad Debug app must launch from a TCC-safe runtime app copy"
contains_literal "$mac_online_build_body" "sign_macos_online_ipad_debug_app" \
  || fail "Mac online iPad Debug app must not use ad-hoc signing for LaunchServices open"
! contains_literal "$mac_online_build_body" "/usr/bin/codesign --force --deep --sign - \"\$MAC_ONLINE_APP_BUNDLE\"" \
  || fail "Mac online iPad Debug app must not use ad-hoc signing for LaunchServices open"
grep -q 'mac-online-app-signing source=debug identityKind=' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad Debug app signing must emit status evidence without leaking certificate names"
grep -q 'mac-online-app source=%s %s bundle=%s executable=%s' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad app verification must emit source plus trust status evidence"
grep -q 'stapler=valid spctl=accepted' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad packaged app status must include notarization and Gatekeeper proof"
contains_literal "$mac_online_build_body" "xattr -dr com.apple.quarantine \"\$MAC_ONLINE_APP_BUNDLE\"" \
  || fail "Mac online iPad Debug app quarantine attributes must be cleared before LaunchServices open"
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
script_has_literal "MAC_HOST_LAUNCH_MODE=\"\${SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE:-direct}\"" \
  || fail "real-device smoke should default the macOS host to direct binary launch"
script_has_literal "MAC_DIRECT_BIN=\"\$ROOT_DIR/.build/debug/LocalLanInteropHost\"" \
  || fail "default direct macOS host launch should use the SwiftPM build product"
script_has_literal "MAC_SOURCE_DIRECT_BIN=\"\$ROOT_DIR/.build/debug/LocalLanSmokeSourceHost\"" \
  || fail "real-device remote smoke should launch the independent macOS smoke source helper"
grep -q 'swift build --product LocalLanSmokeSourceHost' "$SMOKE_SCRIPT" \
  || fail "real-device remote smoke should build the independent macOS smoke source helper"
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
script_has_literal "if [[ \"\$MAC_HOST_LAUNCH_MODE\" == \"direct\" ]]" \
  || fail "macOS host start should route direct mode to the direct app binary"
contains_literal "$direct_launch_body" " \"\$MAC_DIRECT_BIN\" >\"\$HOST_STDOUT\" 2>&1 &" \
  || fail "direct macOS host launch should execute the SwiftPM build product, not the app bundle copy"
[[ "$direct_launch_body" == *"launch method=direct-app-binary pid=\$HOST_PID mode=direct binary=swiftpm-build-product"* ]] \
  || fail "direct macOS host launch evidence should not claim LaunchServices fallback"
[[ "$direct_launch_body" != *"fallbackFrom=open-app-bundle"* ]] \
  || fail "direct macOS host launch evidence must not include open-app-bundle fallback wording"
[[ "$host_start_body" == *'fallback=direct-app-binary'* && "$host_start_body" == *'return 0'* ]] \
  || fail "opt-in LaunchServices fallback should start the direct binary and leave the open pid loop immediately"
script_has_literal "if [[ \"\$MAC_HOST_LAUNCH_MODE\" == \"open\" ]]; then" \
  || fail "temporary macOS app bundle should only be prepared for opt-in LaunchServices mode"
script_has_literal "verify_mac_control_port_reachable \"\$MAC_CONTROL_HOST\" \"\$MAC_CONTROL_PORT\"" \
  || fail "real-device smoke should verify the dynamic control listener before launching iOS"
script_has_literal "mac-control-port reachable=1 host=\$host port=\$port source=pre-ios-probe" \
  || fail "macOS control port probe should emit positive TCP reachability evidence"
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
grep -q 'latest_mac_online_ipad_control_endpoint' "$SMOKE_SCRIPT" \
  || fail "Mac online iPad probe must derive host/port from the app-authored OnlineDeviceCard row"
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

echo "[test-real-device-smoke-preflight] all checks passed"
