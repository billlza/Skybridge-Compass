# ADR 2026-07-01: Android P2P, WebRTC, and Q-Periapt stack

Status: accepted for Android implementation; updated 2026-07-05 after emulator-only scope change. Android remains Kotlin-first with no Rust core. Strict Q Android-to-Apple smoke must be reported by concrete peer direction and device class: emulator proof is valid emulator proof, not physical-device proof.

Scope: Android repo first. macOS/iOS are strictly read-only reference clients for this Android lane because Apple development proceeds concurrently outside this repository. Android work must not edit Apple source, project files, generated state, or fixtures in the Apple trees. The Android strict-Q interop path may consume Apple smoke harnesses as peers, but all compatibility fixes made by this lane belong in Android. Android should not add a Rust/UniFFI runtime just because Q-Periapt is experimental. Peer-family transport selection and same-platform fast paths are governed by `ADR-2026-07-23-PEER-FAMILY-PROTOCOL-LANES.md`.

## Context

The Android app must connect P2P over WebRTC with the existing macOS and iOS apps. The Apple implementations are already mature and do not use a SkyBridge Rust core. Android should therefore stay on a modern Kotlin/Android stack and reuse the existing Android module boundaries instead of adding a Rust/UniFFI crypto or protocol runtime.

Target platforms for the current product line:

- Android 16+ / API 36+
- macOS 26+
- iOS 26+

Older Android, macOS, and iOS fallback paths are not a design target for this ADR.
This target statement applies to Q-Periapt admission and current product support. It must not be implemented as a global PQC ban: existing X-Wing / ML-KEM technical paths may still operate on older Android runtimes when an explicit policy selects them.

## Decision

1. Keep Android as Kotlin-first.
   - Do not introduce a SkyBridge Rust core.
   - Do not introduce UniFFI or a parallel protocol runtime.
   - Continue using the existing Android `shared`, `core`, `device-discovery`, `file-transfer`, `remote-control`, and `app` boundaries.
   - Q-Periapt work must stay in the existing Android Kotlin/JNI PQC boundary and app-layer handshake model.

2. Use the latest Android/Kotlin stack that is resolvable and warning-clean in this repo on 2026-07-01.
   - Kotlin Gradle plugins: 2.4.0
   - KSP: 2.3.9
   - Android Gradle Plugin: 9.3.0-rc01
   - Gradle wrapper: 9.6.1
   - compileSdk / targetSdk: 37
   - minSdk: 36
   - Hilt: 2.60
   - Ktor: 3.5.1
   - JUnit Jupiter/Vintage: 6.1.1

3. Do not use AGP 9.4 alpha builds for the main Android lane.
   - Google Maven currently lists `9.4.0-alpha02` as latest/release metadata, but that is an alpha build and is not adopted here.
   - Android's AGP 9.3 documentation lists API 37 support, and Google Maven currently publishes `9.3.0-rc01`.
   - AGP 9.3.0-rc01 with Gradle 9.6.1 is the highest warning-clean combination validated in this repo.

4. Keep WebRTC as transport and keep app-layer security explicit.
   - WebRTC DataChannel remains the transport.
   - The app-layer P2P handshake is responsible for session keys.
   - App payloads remain invalid before app-layer session keys exist.
   - Signaling, TURN admission, and current-path auth failures fail closed.

5. Make native PQC the default Android P2P policy.
   - `P2PHandshakePolicy.DEFAULT` requires PQC.
   - Classic fallback is not part of the default policy.
   - Trusted classic bootstrap remains a separate explicit bootstrap mode and must not weaken Q-Periapt.

6. Treat Q-Periapt as an explicit local beta suite.
   - Q-Periapt remains parseable by wire ID.
   - Q-Periapt is not in `CryptoSuite.ALL_SUITES`.
   - Q-Periapt is listed only in `CryptoSuite.EXPLICIT_BETA_SUITES`.
   - Cloud settings cannot enable `qperiaptPQC`.
   - Android settings cannot select `qperiaptPQC` unless the local runtime is Android 16+ / API 36+.
   - When `qperiaptPQC` is explicitly requested, the handshake must either negotiate Q-Periapt or fail; it must not fall back to X-Wing, ML-KEM, hybrid, or classic.
   - Q-Periapt capability advertisement is limited to Q-Periapt suite and beta profile markers.
   - The Android Q-Periapt Android 16/API 36 gate applies only when `qperiaptPQC` is explicitly requested; it must not block X-Wing or ML-KEM negotiation.

7. Fail closed on Q-Periapt platform eligibility.
   - Android local runtime must be Android 16+ / API 36+.
   - Q-Periapt peer eligibility must be explicit: macOS 26+, iOS 26+, or Android 16+ / API 36+.
   - Ambiguous values such as `26` without a platform family are not accepted as peer proof.
   - Signed/encrypted handshake capabilities must include the `q-periapt-beta` auth profile and an eligible platform version before Q-Periapt is accepted.
   - WebRTC JOIN bootstrap must carry KEM public keys with explicit `platform` / `osVersion` metadata when Android advertises local KEM material.
   - Incoming WebRTC JOIN bootstrap may persist Q-Periapt peer keys only when the same metadata proves eligibility; missing or unsupported Q metadata clears stale Q peer state without discarding valid X-Wing / ML-KEM keys.
   - Pairing identity exchanges may persist Q-Periapt peer keys only when their `platform` / `osVersion` metadata proves eligibility.
   - Previously persisted Q-Periapt peer keys without the new eligibility marker are ignored; peers must re-advertise eligible metadata.

8. Redact Android-controlled smoke artifacts.
   - Android smoke scripts must not print connection codes to stdout.
   - Android smoke scripts must not pass connection codes as `adb shell am instrument -e` arguments.
   - Android smoke scripts must move transient connection codes through app-private files created with `run-as`, then delete those files after reading.
   - Android instrumentation logs must not print raw connection codes, device IDs, or protocol fingerprints.
   - Apple smoke-host status output is still an Apple-side artifact boundary and remains outside this Android-only change.

9. Keep public signaling endpoints on current-path admission.
   - Direct legacy register/lookup/redeem methods are allowed only for local/private diagnostic endpoints.
   - Public signaling base URLs must use current-path admission and fail before sending a request if a caller tries the legacy path.
   - Local compat signaling remains permitted for emulator smoke because it is a diagnostic endpoint, not production auth proof.

## Consequences

- Android remains aligned with the architecture style of the macOS and iOS clients.
- The repo avoids a second cross-platform crypto runtime and the long-term maintenance cost of Rust/Kotlin boundary ownership.
- Old Android 13-15 references in previous docs are superseded for this product line.
- Q-Periapt can be tested end-to-end without being presented as production-ready default cryptography or silently reused from stale peer-key state.
- Real runtime proof still requires Android 16+ hardware or emulator plus macOS 26/iOS 26 peers.
- Non-Q PQC remains independent from the Q-Periapt platform gate. This keeps existing X-Wing / ML-KEM behavior testable and avoids making an experimental suite a global admission dependency.
- The Android emulator can now be used as the active Android device when hardware is unavailable, but any result must explicitly say `emulator`.

## External source checks

- Kotlin 2.4.0 release: https://blog.jetbrains.com/kotlin/2026/06/kotlin-2-4-0-released/
- KSP 2.3.9 with Kotlin 2.4.0 docs: https://kotlinlang.org/docs/ksp-quickstart.html
- AGP 9.3 release notes: https://developer.android.com/build/releases/agp-9-3-0-release-notes
- Google Maven AGP metadata: https://dl.google.com/dl/android/maven2/com/android/tools/build/gradle/maven-metadata.xml
- Gradle 9.6.1 release notes: https://docs.gradle.org/9.6.1/release-notes.html
- Ktor 3.5.1 Maven Central artifact: https://central.sonatype.com/artifact/io.ktor/ktor-client-core
- Hilt 2.60 Maven Central artifact: https://central.sonatype.com/artifact/com.google.dagger/hilt-android
- JUnit 6.1.1 release notes: https://docs.junit.org/6.1.1/release-notes.html
- Android 16 local network permission: https://developer.android.com/privacy-and-security/local-network-permission

## 2026-07-05 validation delta

The following Android-only checks passed after the emulator-scope security and smoke-harness changes:

```bash
bash -n scripts/run_android_apple_webrtc_smoke.sh scripts/run_android_ios_webrtc_offer_smoke.sh scripts/run_android_mac_lan_remote_smoke.sh

./gradlew --no-daemon --no-configuration-cache --max-workers=1 --warning-mode all -Pkotlin.compiler.execution.strategy=in-process -Pkotlin.incremental=false :app:testDebugUnitTest --tests 'com.skybridge.compass.android.remote.mac.MacRemotePeerIdentityHintTest' :core:testDebugUnitTest --tests 'com.skybridge.compass.core.webrtc.SignalServerClientContractTest'

./gradlew --no-daemon --no-configuration-cache --max-workers=1 --warning-mode all -Pkotlin.compiler.execution.strategy=in-process -Pkotlin.incremental=false :app:assembleDebugAndroidTest :core:assembleDebugAndroidTest
```

Result: all passed. This proves compilation and unit/contract coverage for private-file smoke code handoff, public-signaling fail-closed admission, and advertised-identity naming. It does not by itself prove Android-to-iOS runtime interop; that still requires running `scripts/run_android_ios_webrtc_offer_smoke.sh` against an Android API 36+ emulator and iOS simulator.

## Validation commands

These commands passed on 2026-07-01 after the Android JOIN bootstrap,
Q-Periapt eligibility, TURN current-path endpoint, and TOFU-hardening changes,
with `--warning-mode all`:

```bash
./gradlew --no-daemon --no-configuration-cache --max-workers=1 --warning-mode all -Pkotlin.compiler.execution.strategy=in-process -Pkotlin.incremental=false :core:testDebugUnitTest --tests 'com.skybridge.compass.core.webrtc.JoinBootstrapKemAdmissionTest' --tests 'com.skybridge.compass.core.webrtc.JoinBootstrapPayloadTest' :app:testDebugUnitTest --tests 'com.skybridge.compass.android.remote.mac.MacRemotePeerTrustPolicyTest' :shared:testDebugUnitTest --tests 'com.skybridge.compass.shared.p2p.P2PHandshakeCompatibilityTests.trustStorePersistsAndRejectsMismatch' --tests 'com.skybridge.compass.shared.p2p.P2PHandshakeCompatibilityTests.trustStoreCanRequirePrePinnedPeer' --tests 'com.skybridge.compass.shared.p2p.P2PQPeriaptKemTest'

./gradlew --no-daemon --no-configuration-cache --max-workers=1 --warning-mode all -Pkotlin.compiler.execution.strategy=in-process -Pkotlin.incremental=false :core:testDebugUnitTest --tests 'com.skybridge.compass.core.webrtc.TURNCredentialServiceTest' --tests 'com.skybridge.compass.core.webrtc.JoinBootstrapKemAdmissionTest' --tests 'com.skybridge.compass.core.webrtc.JoinBootstrapPayloadTest' --tests 'com.skybridge.compass.core.p2p.PeerKemKeyStoreRecordsTest'

./gradlew --no-daemon --no-configuration-cache --max-workers=1 --warning-mode all -Pkotlin.compiler.execution.strategy=in-process -Pkotlin.incremental=false :shared:testDebugUnitTest --tests 'com.skybridge.compass.shared.p2p.P2PQPeriaptKemTest' --tests 'com.skybridge.compass.shared.p2p.QPeriaptPlatformPolicyTest' --tests 'com.skybridge.compass.shared.p2p.P2PHandshakeCompatibilityTests'

./gradlew --no-daemon --no-configuration-cache --max-workers=1 --warning-mode all -Pkotlin.compiler.execution.strategy=in-process -Pkotlin.incremental=false :app:testDebugUnitTest --tests 'com.skybridge.compass.android.data.SecuritySettingsStoreTest'

./gradlew --no-daemon --no-configuration-cache --max-workers=1 --warning-mode all -Pkotlin.compiler.execution.strategy=in-process -Pkotlin.incremental=false :app:assembleDebugAndroidTest :core:assembleDebugAndroidTest

./gradlew --no-daemon --no-configuration-cache --max-workers=1 --warning-mode all -Pkotlin.compiler.execution.strategy=in-process -Pkotlin.incremental=false :app:lintDebug :core:lintDebug

if rg -n "Connection code: \$CONNECTION_CODE|starting code=\$code|success code=\$\{state\.code\}|fingerprint=\$\{localBinding|deviceId=\$\{localBinding|SB-ANDROID-APP-OFFER code=\$code" scripts/run_android_apple_webrtc_smoke.sh app/src/androidTest core/src/androidTest -S; then exit 1; fi

./gradlew --no-daemon --no-configuration-cache --max-workers=1 --warning-mode all -Pkotlin.compiler.execution.strategy=in-process -Pkotlin.incremental=false :shared:testDebugUnitTest :core:testDebugUnitTest :app:testDebugUnitTest :device-discovery:testDebugUnitTest :file-transfer:testDebugUnitTest :remote-control:testDebugUnitTest

./gradlew --no-daemon --no-configuration-cache --max-workers=1 --warning-mode all -Pkotlin.compiler.execution.strategy=in-process -Pkotlin.incremental=false :shared:lintDebug :core:lintDebug :app:lintDebug :device-discovery:lintDebug :file-transfer:lintDebug :remote-control:lintDebug :app:assembleDebug :app:assembleDebugAndroidTest

bash -n scripts/run_android_apple_webrtc_smoke.sh scripts/run_android_mac_lan_remote_smoke.sh scripts/lib/android_env.sh

bash scripts/check_android_packaged_placeholders.sh --mode diagnostic-debug
```

Result: all passed with no remaining Gradle, Kotlin compiler, manifest merger, lint, or packaging-audit warnings.

Additional validation after the Apple JOIN export and Android server-gate fixes:

```bash
swift test --filter 'PairingIdentitySuiteAdvertisementTests|WebRTCSignalingCurrentPathTests|QPeriaptRoundTripTests|ApplePQCSDKGateSourceContractTests'

xcodebuild -project "SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj" -scheme "SkyBridgeCompass-iOS" -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' CODE_SIGNING_ALLOWED=NO build

./gradlew --no-daemon --no-configuration-cache --max-workers=1 --warning-mode all -Pkotlin.compiler.execution.strategy=in-process -Pkotlin.incremental=false :shared:testDebugUnitTest --tests 'com.skybridge.compass.shared.p2p.P2PHandshakeCompatibilityTests' --tests 'com.skybridge.compass.shared.p2p.QPeriaptPlatformPolicyTest' --tests 'com.skybridge.compass.shared.p2p.P2PQPeriaptKemTest'

./gradlew --no-daemon --no-configuration-cache --max-workers=1 --warning-mode all -Pkotlin.compiler.execution.strategy=in-process -Pkotlin.incremental=false :core:testDebugUnitTest --tests 'com.skybridge.compass.core.webrtc.SignalServerClientContractTest' --tests 'com.skybridge.compass.core.webrtc.JoinBootstrapKemAdmissionTest' --tests 'com.skybridge.compass.core.webrtc.JoinBootstrapPayloadTest' --tests 'com.skybridge.compass.core.webrtc.TURNCredentialServiceTest' --tests 'com.skybridge.compass.core.webrtc.CurrentPathSecurityTest'

./gradlew --no-daemon --no-configuration-cache --max-workers=1 --warning-mode all -Pkotlin.compiler.execution.strategy=in-process -Pkotlin.incremental=false :shared:lintDebug :core:lintDebug

./gradlew --no-daemon --no-configuration-cache --max-workers=1 --warning-mode all -Pkotlin.compiler.execution.strategy=in-process -Pkotlin.incremental=false :app:assembleDebug

bash scripts/check_android_packaged_placeholders.sh --mode diagnostic-debug

./gradlew --no-daemon --no-configuration-cache --max-workers=1 --warning-mode all -Pkotlin.compiler.execution.strategy=in-process -Pkotlin.incremental=false :shared:testDebugUnitTest :core:testDebugUnitTest
```

Result: all passed. The SwiftPM run executed 42 XCTest cases plus 17 Swift Testing cases, and the iOS simulator Debug build succeeded with signing disabled. The Android runs passed shared/core tests, lint, debug APK assembly, and packaging audit with no project warning/error output. Gradle printed its normal single-use daemon informational line under `--no-daemon`.

Runtime status on 2026-07-01:

- `Medium_Phone_API_36.1` booted and reported Android release `16`, SDK `36`.
- macOS host reported `27.0`, which satisfies the macOS 26+ Q-Periapt gate.
- Android Apple WebRTC/Q-Periapt local compat smoke `20260701-140306` reached WebRTC transport readiness: mac status showed inbound Android JOIN, answer, ICE candidates, and `transportReady`; Android logcat showed `dataChannel state=OPEN`.
- The same smoke failed correctly at strict Q suite selection: `handshake start failed: No compatible suite for policy(minimum=qperiaptPQC, requirePqc=true, allowClassicFallback=false)`.
- Apple source/unit validation now covers Q-Periapt JOIN KEM export, KEM public-key length admission, platform/osVersion metadata, local runtime self-test gating, and WebRTC JOIN payload encoding.
- The local compat server result is connectivity/protocol-flow evidence only. It is not production auth evidence because the compat server can skip Supabase and JWT signature validation by design.
- A new strict Q Android/Apple smoke run has not yet been executed after the Apple source patch. Until that smoke passes, the status is source/unit/build proven, not end-to-end Q interop proven.

## 2026-07-XX dependency version increments (appended; Decision 2 unchanged)

This section is an append-only version-increment log required by the
`cross-platform-parity-audit` spec (Requirement 1.10). It records every
dependency whose post-upgrade version, as finalized in
`gradle/libs.versions.toml` and `dependency-inventory.md` section 6
(spec tasks 1.2–1.4), differs from the version recorded in Decision 2
above. It does not modify, remove, or reinterpret any existing Decision 2
entry; Decision 2 remains the record of the stack as accepted on
2026-07-01. Where a Decision 2 entry and this log disagree, this log is
the newer state and Decision 2 is the historical baseline.

Only dependencies that Decision 2 actually documents are recorded as
increments below. Upgrades performed this round on coordinates that
Decision 2 does not mention are listed separately as "no ADR
counterpart" for traceability and are not version-increment records
against Decision 2.

### Version-increment records (coordinate documented by Decision 2)

| Coordinate / plugin id | Decision 2 recorded version | Upgraded version | Upstream release notes |
| --- | --- | --- | --- |
| `com.android.application` / `com.android.library` / `com.android.test` (Android Gradle Plugin) | 9.3.0-rc01 | 9.3.1 | https://developer.android.com/build/releases/agp-9-3-0-release-notes |
| `org.jetbrains.kotlin.plugin.serialization` / `org.jetbrains.kotlin.plugin.compose` / `org.jetbrains.kotlin.plugin.parcelize` (Kotlin Gradle plugins) | 2.4.0 | 2.4.10 | https://github.com/JetBrains/kotlin/releases/tag/v2.4.10 |
| `com.google.devtools.ksp` (KSP) | 2.3.9 | 2.3.10 | https://github.com/google/ksp/releases/tag/2.3.10 |
| `org.junit.jupiter:junit-jupiter-api` / `org.junit.jupiter:junit-jupiter-engine` / `org.junit.vintage:junit-vintage-engine` (JUnit Jupiter/Vintage) | 6.1.1 | 6.1.2 | https://docs.junit.org/6.1.2/release-notes.html |

Notes:

- AGP moved from the `9.3.0-rc01` prerelease recorded in Decision 2 to the
  stable `9.3.1`; it stays on the 9.3 line and does not adopt any 9.4
  alpha, consistent with Decision 3.
- The Kotlin plugin line, KSP, and Gradle wrapper relationship is
  preserved: Kotlin 2.4.10 with KSP 2.3.10 keeps KSP aligned to the Kotlin
  line as Decision 2 intended. The Gradle wrapper stays at 9.6.1
  (unchanged from Decision 2, so it is not an increment).
- Ktor (3.5.1), `compileSdk`/`targetSdk` (37), and `minSdk` (36) are
  unchanged from Decision 2 and therefore have no increment record.

### Upgrades this round with no Decision 2 counterpart (not recorded against Decision 2)

Decision 2 does not enumerate these coordinates, so per Requirement 1.10
they are not version-increment records against it. They are listed here
only so the increment log is complete against `dependency-inventory.md`
section 6.

| Coordinate / plugin id | Previous version | Upgraded version | Upstream release notes |
| --- | --- | --- | --- |
| `com.github.ben-manes.versions` | 0.53.0 | 0.57.0 | https://github.com/ben-manes/gradle-versions-plugin/releases/tag/v0.57.0 |
| `androidx.browser:browser` | 1.9.0 | 1.10.0 | https://developer.android.com/jetpack/androidx/releases/browser |
| `org.bouncycastle:bcprov-jdk18on` | 1.84 | 1.85 | https://www.bouncycastle.org/download/bouncy-castle-java/ |
| `io.kotest:kotest-runner-junit5` / `io.kotest:kotest-assertions-core` / `io.kotest:kotest-property` | 6.2.1 | 6.2.3 | https://github.com/kotest/kotest/releases/tag/v6.2.3 |
| `androidx.test.uiautomator:uiautomator` | 2.3.0 | 2.4.0 | https://developer.android.com/jetpack/androidx/releases/test-uiautomator |
| `com.infobip:google-webrtc` → `io.github.webrtc-sdk:android` | 1.0.45036 | 144.7559.09 | https://central.sonatype.com/artifact/io.github.webrtc-sdk/android/versions |

The coordinate change is intentional. The newer Infobip artifacts inspected for this
release reference generated JNI bridge classes that are absent from their AAR, while
the retained 1.0.45036 artifact causes a stale-version release warning. The maintained
`webrtc-sdk/android` artifact owns the complete Java/JNI surface, including
`org.webrtc.Environment`, and is admitted by a build-time four-ABI and unresolved-JNI
check. Compilation is not runtime evidence; the release gate still requires the native
factory smoke and real-device WebRTC session on the packaged candidate.

### Observation: Hilt (documented by Decision 2, not upgraded this round)

Decision 2 records Hilt `2.60`. The current version catalog and
`dependency-inventory.md` section 6 carry Hilt `2.60.1` with a
"keep / no higher stable" decision, i.e. Hilt was not upgraded in this
round. The `2.60` vs `2.60.1` difference is a pre-existing catalog state
rather than an increment produced by this round's upgrade work; it is
noted here for completeness and is not claimed as a change performed by
this task.

## 2026-08-13 dependency version increments

The zero-warning release gate resolved fresh upstream metadata on its
Ubuntu runner and identified stable dependency updates. A subsequent clean
lint pass exposed the KSP build-plugin update as the only remaining issue.
The version catalog remains the single source of truth; no compatibility
layer or lint suppression was introduced.

| Coordinate | Previous version | Upgraded version | Upstream release notes |
| --- | --- | --- | --- |
| `androidx.appcompat:appcompat` | 1.7.1 | 1.8.0 | https://developer.android.com/jetpack/androidx/releases/appcompat#1.8.0 |
| `androidx.compose:compose-bom` | 2026.06.01 | 2026.08.00 | https://developer.android.com/develop/ui/compose/bom/bom-mapping |
| `androidx.fragment:fragment-ktx` | 1.8.9 | 1.9.0 | https://developer.android.com/jetpack/androidx/releases/fragment#1.9.0 |
| `io.github.webrtc-sdk:android` | 144.7559.09 | 144.7559.12 | https://github.com/webrtc-sdk/android/releases/tag/v144.7559.12 |
| `com.google.devtools.ksp` | 2.3.10 | 2.3.11 | https://github.com/google/ksp/releases/tag/2.3.11 |

The WebRTC coordinate remains strictly pinned and continues through the
existing Java/JNI closure, four-ABI, manifest, and payload validation. These
build checks detect packaging incompatibility; they do not replace the
source-bound Samsung 4 KiB/API 37 16 KiB native runtime gate or the physical
Android/Apple selected-ICE and bidirectional durable-transfer receipt.
