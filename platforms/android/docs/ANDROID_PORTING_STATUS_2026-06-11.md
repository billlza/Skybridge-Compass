# Android Porting Status - 2026-06-11

> Partially superseded by `docs/ADR-2026-07-01-ANDROID-P2P-QPERIAPT-STACK.md`
> for the current P2P/WebRTC/Q-Periapt stack. The current product contract is
> Android 16+ / API 36+, macOS 26+, and iOS 26+.

This note records the current Android bring-up state for SkyBridge Compass Android. It is intentionally scoped to the Android repo; the macOS and iOS source trees are read-only reference inputs for this work.

## Runtime Baseline

- App package: `com.skybridge.compass.debug`
- APK: `app/build/outputs/apk/debug/app-debug.apk`
- APK SDK contract: `minSdk=36`, `targetSdk=37`, `compileSdk=37`
- Required runtime for current app: Android 16 / API 36 or newer
- Current physical device: Meitu M6 / MP1503, Android 6.0 / API 23
- Meitu install result: `INSTALL_FAILED_OLDER_SDK`, which is expected for the current app contract

Do not lower `minSdk` to make the Meitu M6 install. The current app depends on Android 16+ permission, security, and cross-platform protocol assumptions. A lower-minSdk branch would require a separate product and security review.

## Historical API 35 Emulator Evidence

This section is historical evidence from the pre-Android-16 contract and is superseded for current validation. The current app uses `minSdk=36`, so API 35 is no longer a valid install/start or interop target.

The existing `Medium_Phone_API_36.1` Play Store AVD and the API 35 Google APIs AVD both exited early when started with HVF acceleration on this host. At the time, the API 35 Google APIs AVD booted reliably enough for APK install and launch smoke when started without acceleration:

```bash
/Users/bill/Library/Android/sdk/emulator/emulator \
  -avd SkyBridge_API_35 \
  -no-window \
  -gpu swiftshader_indirect \
  -no-accel \
  -no-snapshot-load \
  -no-snapshot-save \
  -no-boot-anim \
  -no-audio
```

Smoke evidence from this host:

- `system-images;android-35;google_apis;arm64-v8a` installed successfully
- `SkyBridge_API_35` AVD created successfully
- Emulator reached `sys.boot_completed=1`
- Historical API 35 install/start proof is not accepted for the current `minSdk=36` product line.

Known host limitation:

- The no-accel emulator is slow and has short-lived stability on the previously tested no-acceleration emulator.
- Treat emulator proof as install/start smoke, not as a durable end-to-end interop target until the host emulator runtime is stabilized.

## Apple / tdsc ADR Porting Rules

The Android WebRTC path should mirror the mature Apple architecture instead of adding Android-only protocol branches:

- Signaling uses the shared envelope shape: `sessionId`, `from`, optional `to`, `type`, `payload`, `sentAt`, plus auth where required.
- WebRTC DataChannel is a transport only; application protocol is carried over a 4-byte big-endian length-prefixed byte stream.
- App data is encrypted after P2P app-layer session keys exist.
- Handshake and rekey frames are the only frames allowed before app-layer session keys.
- Signaling, TURN admission, and current-path auth failures must fail closed.
- Secure session material must not fall back to plaintext storage.

Implemented in this Android repo on 2026-06-11:

- Removed duplicate app-layer signaling/framing sources from `app`.
- Centralized signaling in `core`.
- Made WebRTC frame parsing strict; malformed/truncated/trailing bytes fail.
- Rejected app payload sends before WebRTC app-layer session keys.
- Removed plaintext auth/session storage fallbacks.
- Made TURN admission-token credential fetch fail closed and validate server credential payloads.

## Google I/O 2026 Implications

Official Android updates reviewed on 2026-06-11:

- [17 Things to know for Android developers at Google I/O](https://android-developers.googleblog.com/2026/05/17-things-android-developers-google-io.html)
- [Android Studio I/O Edition: What's new in Android Developer tools](https://android-developers.googleblog.com/2026/05/whats-new-android-developer-tools.html)
- [The Android Show I/O Edition 2026](https://www.android.com/new-features-on-android/io-2026/)
- [The Fourth Beta of Android 17](https://android-developers.googleblog.com/2026/04/the-fourth-beta-of-android-17.html)
- [Android 17 release notes](https://developer.android.com/about/versions/17/release-notes)

Practical actions for SkyBridge Android:

- Keep the UI path Compose-first and avoid rebuilding controls in a parallel Android-only style.
- Continue targeting the modern Android runtime line; current `targetSdk=37` is the active Android 17 compatibility target.
- Add Android 17 compatibility runs when an API 37/Android 17 emulator is stable locally.
- Prioritize adaptive layouts and multi-window/external-display behavior for remote control and file transfer screens.
- Treat AI Studio / agentic tooling as productivity tooling, not as a runtime architecture dependency for SkyBridge.
- Do not add Android XR, Auto, Wear, or App Functions surfaces until core phone/tablet interop is stable.

## Meitu M6 Flashing Decision

Local device facts:

- Model: `MP1503`
- Android SDK: `23`
- Platform: MediaTek MT6755
- Treble: not enabled; `/vendor` is under `/system/vendor`
- Current app APK cannot install because `minSdk=36`

Web research found stock/repair firmware references for Meitu M6, but they are Android 6.0 stock ROM packages or third-party ROM indexes, not a verified current Android 16+ package:

- [Needrom Meitu M6 stock ROM page](https://www.needrom.com/download/meitu-m6/) describes an Android 6.0 MT6755 stock package.
- [AndroidMTK Meitu stock ROM index](https://androidmtk.com/download-meitu-stock-rom) indexes stock flash files, not Android 16+ ports.
- [LineageOS device downloads](https://download.lineageos.org/) list Mi CC9 Meitu Edition (`vela`) but not Meitu M6 / MP1503.

Decision:

- Do not flash the Meitu M6 with an unverified "latest" package for SkyBridge Android development.
- The device can remain useful as negative evidence for API 23 install failure and legacy-device documentation.
- For current app development and interop validation, use an API 36+ emulator or a real API 36+ phone.
- If the Meitu must be reflashed for recovery, only use a verified stock MP1503 scatter package and treat it as device rescue, not as a way to run current SkyBridge Android.

## Verification Commands

```bash
./gradlew :shared:testDebugUnitTest :core:testDebugUnitTest :app:compileDebugKotlin :app:testDebugUnitTest :app:lintDebug :app:assembleDebug \
  --no-daemon \
  --no-configuration-cache \
  --max-workers=1 \
  -Pkotlin.compiler.execution.strategy=in-process \
  -Pkotlin.incremental=false \
  --stacktrace
```

Result on 2026-06-11:

- Gradle build/test/lint/assemble command exited `0`
- `:shared:testDebugUnitTest`, `:core:testDebugUnitTest`, `:app:testDebugUnitTest` passed
- `:app:lintDebug` passed with `0` lint errors and `105` lint warnings
- `:app:assembleDebug` produced a debug APK

Warnings are not clean. The warning debt is tracked as remaining quality work, not as completed cleanup.
