# Real Device Interop Runbook

This runbook is the operational checklist for Android <-> macOS / iOS interop validation after the protocol and app-path fixes in this repo.

It focuses on the paths that are currently treated as production-ready in Android:

- Apple LAN discovery via Bonjour
- Android <-> macOS remote desktop over LAN
- Android <-> Apple WebRTC code-based session establishment
- Android app-layer trust establishment with PQC enabled by default
- Android app build + instrumentation smoke evidence collection
- Android AAB formal audit for the exact store upload artifact
- Android APK packaging audit to prove legacy placeholder classes are not shipped

## Paths

Run every command from the canonical Android project inside a Git release worktree. Derive paths;
do not copy a source tree or bind evidence to a workstation-specific directory:

```bash
RELEASE_REPO_ROOT="$(cd "$(git rev-parse --show-toplevel)" && pwd -P)"
ANDROID_ROOT="$RELEASE_REPO_ROOT/platforms/android"
MAC_RELEASE_ROOT="${SKYBRIDGE_MAC_RELEASE_ROOT:-$RELEASE_REPO_ROOT}"
MAC_RELEASE_ROOT="$(cd "$MAC_RELEASE_ROOT" && pwd -P)"
IOS_PROJECT="$MAC_RELEASE_ROOT/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj"
INTEROP_ROOT="$ANDROID_ROOT/build/interop"

test "$(cd "$ANDROID_ROOT" && pwd -P)" = "$RELEASE_REPO_ROOT/platforms/android"
test "$(git -C "$MAC_RELEASE_ROOT" rev-parse --show-toplevel)" = "$MAC_RELEASE_ROOT"
test -f "$RELEASE_REPO_ROOT/platforms/android/settings.gradle.kts"
test -f "$MAC_RELEASE_ROOT/Package.swift"
test -d "$IOS_PROJECT"
git -C "$RELEASE_REPO_ROOT" rev-parse --verify HEAD
git -C "$MAC_RELEASE_ROOT" rev-parse --verify HEAD
# Required when the run is being retained as release evidence:
test -z "$(git -C "$RELEASE_REPO_ROOT" status --porcelain --untracked-files=all)"
test -z "$(git -C "$MAC_RELEASE_ROOT" status --porcelain --untracked-files=all)"
cd "$ANDROID_ROOT"
```

`SKYBRIDGE_MAC_RELEASE_ROOT` is needed only when Apple validation intentionally uses a separate
registered Git worktree. Before release evidence, both selected worktrees must be clean; record each
Git `HEAD`, branch, and `git status --porcelain` in the run artifact. A host-provided LAN inbox path
is runtime output from `LocalLanInteropHost`, not a fixed path in this runbook.

## Procedure 0A: Android AAB Formal Audit

Purpose:

- Prove the existing signed release AAB, matching R8 mapping, generated AAB audit metadata, and
  packaged source binding all refer to the explicitly selected clean Git commit
- Validate the bundle with the pinned official bundletool CLI, generate an audit-only universal
  APK, and inspect package/version, modules, manifest, DEX classes, native libraries, licenses, and
  the public viewer/client-only boundary
- Prove the AAB upload signer against an independently approved upload-certificate fingerprint

Prerequisite tool:

- Download the executable `bundletool-all-1.18.3.jar` from the official
  [google/bundletool 1.18.3 release](https://github.com/google/bundletool/releases/tag/1.18.3)
  and provide its absolute path. The gate never downloads a floating tool. The AGP dependency cache
  may contain a non-executable bundletool library JAR; it is not an accepted substitute.
- A bundletool upgrade is a deliberate maintenance transaction: review the official release, update
  the script's pinned version, update this runbook, and rerun the AAB regression/generation checks.

### Command

```bash
RELEASE_AAB="$ANDROID_ROOT/app/build/outputs/bundle/release/app-release.aab"
EXPECTED_SOURCE_COMMIT="$(git -C "$RELEASE_REPO_ROOT" rev-parse HEAD)"
BUNDLETOOL_JAR="/absolute/path/to/bundletool-all-1.18.3.jar"

bash scripts/check_android_release_aab.sh \
  --aab "$RELEASE_AAB" \
  --mapping "$ANDROID_ROOT/app/build/outputs/mapping/release/mapping.txt" \
  --audit-metadata "$ANDROID_ROOT/app/build/outputs/release-audit/release/aab-metadata.properties" \
  --bundletool "$BUNDLETOOL_JAR" \
  --expected-upload-cert-sha256 "$EXPECTED_ANDROID_UPLOAD_CERT_SHA256" \
  --expected-commit "$EXPECTED_SOURCE_COMMIT"
```

`EXPECTED_ANDROID_UPLOAD_CERT_SHA256` must come from the approved release/Play-Console identity
channel, never from the AAB being inspected. The gate rejects a dirty canonical worktree, malformed
or unsafe ZIP entries, duplicate modules/entries, incomplete metadata, a mismatched AAB/mapping,
unsigned payload entries, the wrong upload certificate, or viewer-host surfaces. The SHA-256 fields
in the audit metadata are Level 1 accidental-artifact identity checks; they are not a new signing or
authentication scheme.

The universal APK is generated into the audit directory with an isolated one-day audit key solely
because bundletool requires APK signing. Its certificate is not a release identity. With Play App
Signing, the AAB upload certificate proves who may upload; Google Play's app-signing/distribution
certificate signs the APKs installed by users. Final Play identity therefore remains an independent
Play Console or downloaded test-track APK gate and cannot be proven from the local AAB.

### Acceptance criteria

- `scripts/check_android_release_aab.sh` exits `0` for the existing formal artifact
- official bundletool 1.18.3 validates the AAB and generates exactly one audit-only universal APK
- the bundle contains exactly the `base` module; no host feature module is shipped
- bundle config reports only `PAGE_ALIGNMENT_16K`, and the generated universal APK passes
  Build Tools 37.0.0 `zipalign -c -P 16 -v 4`
- NDK 30.0.14904198 `llvm-objdump -p` reports every `PT_LOAD` segment in every `arm64-v8a` and
  `x86_64` shared library with `p_align >= 0x4000`; 32-bit ABI alignments are recorded but do not
  create a false failure outside the current official 64-bit requirement
- `com.skybridge.compass`, `versionName=1.0.2`, and `versionCode=2` match
- host/Accessibility/MediaProjection classes, permissions, services, and manifest surfaces are absent
- WebRTC native ABI content, WebRTC license notice, and source-binding asset are present
- AAB audit metadata binds the AAB and exact R8 mapping to `EXPECTED_SOURCE_COMMIT`
- AAB JAR signature covers every non-`META-INF` payload and matches the approved upload certificate
- Play app-signing/distribution identity is still recorded as not proven by this gate
- installation, launch, native loading, and product behavior on a real 16KB-kernel emulator/device
  remain an independent runtime gate; the current Samsung device's 4KB `getconf PAGESIZE` is not
  accepted as that evidence

Regression tests:

```bash
bash scripts/tests/test_android_release_aab_gate.sh
bash scripts/tests/test_release_artifact_preflight.sh
```

## Procedure 0B: Android APK Packaging Audit

Purpose:

- Prove the exact signed release APK has the expected identity/signing, native ABI, third-party
  notice, viewer/client-only surface, permissions, and required current-path classes
- Bind the inspected artifact to the canonical Git source selected above

### Command

```bash
RELEASE_APK="$ANDROID_ROOT/app/build/outputs/apk/release/app-release.apk"
EXPECTED_SOURCE_COMMIT="$(git -C "$RELEASE_REPO_ROOT" rev-parse HEAD)"
bash scripts/check_android_packaged_placeholders.sh \
  --mode formal \
  --apk "$RELEASE_APK" \
  --mapping "$ANDROID_ROOT/app/build/outputs/mapping/release/mapping.txt" \
  --audit-metadata "$ANDROID_ROOT/app/build/outputs/release-audit/release/metadata.properties" \
  --expected-cert-sha256 "$EXPECTED_ANDROID_SIGNING_CERT_SHA256" \
  --expected-commit "$EXPECTED_SOURCE_COMMIT"
```

Optional custom output directory:

```bash
bash scripts/check_android_packaged_placeholders.sh \
  --mode formal \
  --apk "$RELEASE_APK" \
  --mapping "$ANDROID_ROOT/app/build/outputs/mapping/release/mapping.txt" \
  --audit-metadata "$ANDROID_ROOT/app/build/outputs/release-audit/release/metadata.properties" \
  --expected-cert-sha256 "$EXPECTED_ANDROID_SIGNING_CERT_SHA256" \
  --expected-commit "$EXPECTED_SOURCE_COMMIT" \
  --run-dir "$INTEROP_ROOT/android-packaging-audit/manual-run"
```

`EXPECTED_ANDROID_SIGNING_CERT_SHA256` must come from the approved release-key channel; never copy
it from the APK being inspected. Formal mode also requires the canonical release worktree to remain
clean at audit time and verifies the packaged source-binding asset against `EXPECTED_SOURCE_COMMIT`.

For a local development diagnostic only (never release evidence):

```bash
bash scripts/check_android_packaged_placeholders.sh --mode diagnostic-debug
```

### Logs and artifacts

The script writes one timestamped directory under:

`build/interop/android-packaging-audit/<timestamp>/`

Files:

- `environment.txt`
- `source-provenance.txt`
- `apk-dex-classes.txt`
- `apk-permissions.txt`
- `apk-badging.txt`
- `apk-signing.txt`
- `apk-contents.txt`
- `summary.txt`

### Acceptance criteria

- Script exits `0`
- formal mode inspects an existing APK and never silently rebuilds debug
- `apksigner` verifies a modern APK signature and `aapt` reports
  `com.skybridge.compass`, `versionName=1.0.2`, `versionCode=2`
- `summary.txt` reports all forbidden legacy classes as `OK absent`
- host/Accessibility/MediaProjection classes and permission are absent
- WebRTC native ABI content and packaged WebRTC license notice are present
- APK source-binding asset equals the explicitly expected clean Git commit
- matching release R8 mapping is used to resolve original host classes without adding keep rules
- release audit metadata binds that mapping to the inspected APK (Level 1 accidental-artifact
  mismatch detection, not a new security/authentication mechanism)
- signing certificate equals the independently configured production certificate fingerprint

This APK gate is physical-device/same-source evidence. It is not AAB validation and cannot replace
Procedure 0A for a Play upload artifact.

## Procedure 1: Android Instrumentation Smoke vs macOS WebRTC Smoke Host

Purpose:

- Validate Android debug app + instrumentation path
- Validate server-issued connection code join flow
- Validate app-layer session keys are established
- Validate PQC smoke can be run without silently forcing `classicOnly`

### Required parameters

- `--device <adb-serial>`
- `--ws-url <wss://host:port/ws>` or `ws://.../ws`

Preflight:

- `adb` is installed and the target Android device appears in `adb devices`
- `swift` is installed
- the source-bound macOS release worktree builds `LocalWebRTCSmokeHost`
- Android and Apple peers can both reach the same signaling WebSocket endpoint
- Android security settings for the test run are known:
  - PQC run: `PQC enabled = true`, `Allow Classic Fallback = false`
  - compatibility run only when explicitly requested

Optional parameters:

- `--mac-package-path <path>`: defaults to the Git worktree that contains `platforms/android`; pass
  `"$MAC_RELEASE_ROOT"` when validating against a separate Apple release worktree
- `--pqc true|false`: defaults to `true`
- `--pqc-minimum-tier nativePQC|liboqsPQC|qperiaptPQC|classic`: defaults to `nativePQC`
- `--expect-qperiapt true|false`: defaults to `true` when `--pqc-minimum-tier qperiaptPQC`, otherwise `false`
- `--expected-negotiated-suite <suite-name-or-wire-id>`: defaults to `Q_PERIAPT_CONTEXT_BOUND` in Q-Periapt mode
- `--require-direct-route true|false`: defaults to `false`. When `true`, the exact
  secure operation owner must still have a selected ICE route classified as
  `DIRECT` at terminal success; `RELAY` and `UNKNOWN` fail closed. This proves a
  non-TURN selected pair, not that both peers used a particular Wi-Fi access point.
- `--android-timeout-seconds <n>`: defaults to `120`
- `--mac-timeout-seconds <n>`: defaults to `120`
- `--mac-hold-after-success-seconds <n>`: defaults to `3`

### Command

```bash
bash scripts/run_android_apple_webrtc_smoke.sh \
  --device <adb-serial> \
  --ws-url <wss://host:port/ws> \
  --pqc true
```

For an explicit direct-P2P diagnostic, keep the product's normal TURN-capable
configuration but make this single smoke fail closed unless the selected pair is
direct:

```bash
bash scripts/run_android_apple_webrtc_smoke.sh \
  --device <adb-serial> \
  --ws-url <wss://host:port/ws> \
  --pqc true \
  --require-direct-route true
```

Q-Periapt beta validation must request and assert the exact suite:

```bash
bash scripts/run_android_apple_webrtc_smoke.sh \
  --device <adb-serial> \
  --ws-url <wss://host:port/ws> \
  --pqc true \
  --pqc-minimum-tier qperiaptPQC \
  --expect-qperiapt true \
  --expected-negotiated-suite Q_PERIAPT_CONTEXT_BOUND
```

### Logs and artifacts

The script writes one timestamped directory under:

`build/interop/android-apple-webrtc-smoke/<timestamp>/`

Files:

- `environment.txt`: tool + device environment snapshot
- `command.txt`: exact parameters used for the run
- `connection-code.txt`: server-issued code generated by the macOS smoke host
- `mac-host.stdout.log`: stdout/stderr from `LocalWebRTCSmokeHost`
- `mac-host.status.log`: structured host-side status timeline
- `android-instrumentation.log`: raw `am instrument` output
- `android-logcat.txt`: post-run logcat dump
- `android-handshake.log`: filtered `SB-HANDSHAKE` / smoke log lines
- `android-install.log`: APK install log
- `summary.txt`: acceptance-oriented summary

### Acceptance criteria

- Script exits `0`
- `android-instrumentation.log` contains `OK (1 test)`
- `android-instrumentation.log` contains `SB-ANDROID-APP-SMOKE success` or `SB-ANDROID-SMOKE success`
- `mac-host.status.log` contains `success session=`
- Android side reaches app-layer session keys; this is asserted by the instrumentation test itself
- `android-handshake.log` contains `SB-HANDSHAKE` evidence when logcat is available
- When `--pqc true`, host-side success must be reached without forcing `classicOnly`
- Q-Periapt smoke is accepted only when `summary.txt` contains `expected_qperiapt=true`, `android_qperiapt_asserted=true`, `android_bootstrap_qperiapt=true`, `android_negotiated_suite=Q_PERIAPT_CONTEXT_BOUND/0x0011`, `mac_negotiated_suite=Q-Periapt-ContextBound`, and `qperiapt_assertion_ok=true`
- A successful X-Wing or ML-KEM run is not Q-Periapt proof, even though it is valid PQC proof
- The smoke must use generated device identity keys. `--allow-static-ed25519-fallback` was removed and the scripts reject it explicitly.

## Procedure 2: macOS LAN Host for Android Manual Remote Desktop Validation

Purpose:

- Validate Bonjour discovery from Android
- Validate Android remote desktop viewer against the real macOS `RemoteControlServer`
- Validate mouse / text / navigation input against the actual host app
- Validate whether LAN remote control reaches an authenticated encrypted session or is blocked by policy

### Command

```bash
bash scripts/run_mac_lan_interop_host.sh
```

This wraps:

```bash
swift run --package-path "$MAC_RELEASE_ROOT" LocalLanInteropHost
```

### Logs

The wrapper writes to:

`build/interop/mac-lan-host/<timestamp>/local-lan-host.log`

Additional files:

- `environment.txt`
- `readme.txt`

The mac host itself prints:

- Bonjour/discovery service
- file listener port
- remote desktop port `5901`
- inbound directory path

### Automated smoke

```bash
bash scripts/run_android_mac_lan_remote_smoke.sh \
  --device <adb-serial> \
  --start-mac-host true \
  --require-secure true \
  --allow-plaintext-fallback false \
  --allow-tofu false
```

Artifacts:

- `build/interop/android-mac-lan-smoke/<timestamp>/environment.txt`
- `build/interop/android-mac-lan-smoke/<timestamp>/command.txt`
- `build/interop/android-mac-lan-smoke/<timestamp>/android-status.log`
- `build/interop/android-mac-lan-smoke/<timestamp>/android-logcat.txt`
- `build/interop/android-mac-lan-smoke/<timestamp>/mac-host.log`
- `build/interop/android-mac-lan-smoke/<timestamp>/summary.txt`

Automated smoke acceptance:

- Android discovers a `_skybridge-remote._tcp` peer
- Android reaches `success reason=secure_frame_received`
- If policy requires PQC but peer KEM bootstrap is missing, the run must fail explicitly instead of silently falling back
- `android-status.log` contains `security secure` before success
- Strict automated smoke requires expected device id and fingerprint. Use `--allow-tofu true` only for explicit first-pairing diagnostics, not release evidence.
- This automated smoke proves discovery, secure session state, and at least one received frame. It does not prove mouse, keyboard, text, or clipboard input closure.

### Android side manual checklist

1. Connect Android and Mac to the same LAN.
2. Start the mac LAN host wrapper above.
3. Open Android `设备发现 / Device Discovery`.
4. Confirm the Mac appears via Bonjour and is shown as directly connectable.
5. Open Android `远程控制 / Remote Control`, choose `LAN (5901)`.
6. Connect to the discovered Mac service.
7. Confirm screen frames render.
8. Confirm tap, drag, scroll, text entry, arrows, Tab, Enter, and common clipboard shortcuts behave as expected.
9. Treat this procedure primarily as LAN media/input compatibility validation.
10. If strict PQC is required on LAN, first complete Procedure 1 or Procedure 4 once so Android has the peer's KEM bootstrap material.
11. Use Procedure 1 or Procedure 4 as the hard current-path / PQC acceptance path when LAN peer bootstrap is unavailable.

### Acceptance criteria

- Mac is discovered from Android without enabling hidden/legacy protocols
- Android LAN remote viewer reaches connected state
- Screen frames are visible
- Pointer and keyboard input reach the Mac
- No old Android `ScreenCaptureService` path is needed
- Automated smoke artifacts alone satisfy only the discovery/session/frame subset. Pointer, keyboard, text, and clipboard acceptance requires manual or UI-automation artifacts that record the input action and observed host-side effect.

## Procedure 2A: Windows Peer Proof Boundary

Android <-> Windows interop is not accepted by Procedure 1 or Procedure 2. Gradle tests, Android packaging audit, Apple WebRTC smoke, and Android <-> macOS LAN smoke do not prove Windows discovery, file transfer, or remote desktop behavior.

Windows acceptance requires a separate artifact set with all of the following facts:

- Windows native DNS-SD discovers the Android or Apple peer and records the expected device id plus 64-hex fingerprint.
- File transfer evidence records non-zero transferred bytes, chunk/complete ACKs, final SHA-256 receipt, session id, peer digest, and any failure stage.
- Remote desktop evidence records notice lifecycle, encrypted session state, screen frame dimensions/bytes, FPS or latency, input path for mouse/keyboard/text/clipboard, and disconnect state.
- The evidence must distinguish transport-only/WebRTC helper proof from app-control or product-control proof.

Until those artifacts exist for the target Windows build, Android <-> Windows support remains a proof gap rather than a completed compatibility claim.

## Procedure 3: iOS Peer Smoke

Purpose:

- Validate the iOS app project still builds and its smoke bundle passes
- Keep the iOS peer healthy before running manual Android <-> iOS checks

### Full smoke

```bash
bash scripts/run_ios_peer_smoke.sh
```

### UI-only smoke

```bash
bash scripts/run_ios_peer_smoke.sh --only-ui true
```

### Logs

The wrapper writes to:

`build/interop/ios-peer-smoke/<timestamp>/`

Files:

- `environment.txt`
- `command.txt`
- `xcodebuild.log`
- `SkyBridgeCompass-iOS.xcresult`
- `summary.txt`

### Acceptance criteria

- `xcodebuild` exits `0`
- `xcodebuild.log` contains no failed test summary
- `SkyBridgeCompass-iOS.xcresult` exists

## Procedure 4: Manual Android <-> iOS Peer Validation

Purpose:

- Validate real peer behavior, not only build/test smoke

### LAN discovery / remote desktop

1. Build and launch the iOS app.
2. Keep Android and iPhone/iPad on the same Wi-Fi.
3. From Android `设备发现 / Device Discovery`, look for the iOS peer.
4. Confirm the peer is discovered through Bonjour.
5. If the iOS peer exposes a remote desktop viewer/host flow for the target build, connect from Android and confirm the trust/handshake path completes.

### Code-based WebRTC session

1. Configure the same signaling endpoint on Android and iOS.
2. Start the iOS side connection-code flow.
3. Join from Android using the generated code.
4. Confirm both peers reach connected state.
5. Confirm Android log / state shows app-layer session keys established.
6. If the peer build supports file transfer in that session, transfer a small file and verify integrity at the receiver.
7. If the peer build supports remote desktop/viewer in that session, confirm frames render and remote input is usable.

### Acceptance criteria

- Android and iOS complete session establishment on the same signaling server
- Session keys are established with PQC enabled unless an explicit compatibility run is being tested
- File transfer, when exercised, completes without checksum mismatch
- Remote desktop/viewer path, when exercised, receives frames and usable input

## Suggested result folders per run

- Packaging audit: `build/interop/android-packaging-audit/<timestamp>/`
- Android/mac WebRTC smoke: `build/interop/android-apple-webrtc-smoke/<timestamp>/`
- Android/mac LAN smoke: `build/interop/android-mac-lan-smoke/<timestamp>/`
- mac LAN host: `build/interop/mac-lan-host/<timestamp>/`
- iOS smoke: `build/interop/ios-peer-smoke/<timestamp>/`

## Notes on current scope

- Android production defaults now intentionally prefer the Apple-compatible Bonjour discovery path instead of exposing unfinished direct-connect protocols by default.
- Android public app release is viewer/client only for remote desktop. Procedure 0 must fail if
  the APK contains Android host services, Accessibility service registration, MediaProjection
  foreground service, overlay permission, camera permission, or audio-recording permission.
- Android PQC smoke defaults to enabled. Fallback must now be requested explicitly.
- Legacy/experimental modules can still exist in the source tree, but the shipping APK should now be validated with Procedure 0 rather than by scanning source text alone.
- Historical smoke runs are routing context only; release acceptance requires artifacts bound to the
  clean Git revisions selected by the path preflight above.
