# OS 27 Cutover & Real-Device Validation Runbook

_Last updated: 2026-07-10. Companion to `Docs/os27-adaptation-plan-2026-06.md`._

This runbook covers (1) building/releasing under Xcode 27 / macOS 27 / iOS 27 while
keeping macOS 14 / iOS 17 support, (2) the real-device (iPad + Mac) validation the
release gate requires, (3) validating the newly-wired HDR Reference tier, and
(4) the remaining work to make remote-desktop control "live".

> **Old-device safety is non-negotiable.** Nothing in the OS 27 cutover lowers the
> deployment floors: `LSMinimumSystemVersion 14.0`, SwiftPM `.macOS(.v14)/.iOS(.v17)`,
> `IPHONEOS_DEPLOYMENT_TARGET 17.0`. These are enforced as hard, exact floors by
> `Scripts/package_build_policy.sh` regardless of which build toolchain line is selected.

---

## 1. Toolchain status (verified 2026-06-16)

| Item | Status |
|------|--------|
| Xcode 27 beta installed | ✅ `/Applications/Xcode-beta.app` = Xcode 27.0 (27A5194q), Swift 6.4 |
| macOS package vs **macOS 27.0 SDK** | ✅ `swift build` clean — 0 errors, 0 warnings |
| iOS app vs **iOS 27.0 simulator SDK** | ✅ `BUILD SUCCEEDED` — 0 errors, 0 warnings |
| Source `#available` gating | ✅ every check ends in `*`, so OS 27 is covered automatically |

**No source changes are required for OS 27 source compatibility.** The only OS-27 work
lives in the release tooling (below).

### Building / verifying against Xcode 27

```bash
# Compat build (source-level), already green:
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build

# Verify the toolchain for an OS 27 release (additive policy, major-tolerant):
SKYBRIDGE_XCODE_TOOLCHAIN_POLICY=os27-release \
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  Scripts/verify_xcode_toolchain.sh
```

### Release toolchain pinning — single knob

The stable release line stays pinned to Xcode **26.6** by exact literal (defense-in-depth,
enforced by `AppUpdateManifestTests`/`ApplePQCSDKGateSourceContractTests`). An **additive**
`os27-release` line was introduced:

- `Scripts/verify_xcode_toolchain.sh` — new `os27-release` policy: Xcode **major 27**,
  macOS SDK **major 27**, **major-tolerant** matching (27.x point releases and rotating
  beta build ids do not require re-pinning), beta developer dir allowed while 27 is beta.
- `Scripts/toolchain_release_pin.sh` (new) — single source of truth for the line constants
  + match helpers, consumed by `package_build_policy.sh`'s app-bundle metadata gate.
- `Scripts/package_build_policy.sh` — the `DTSDKName`/`DTXcode`/`DTXcodeBuild` app-bundle
  gate is line-aware: default (xcode26) requires exact `macosx26.5/2660/17F113`; selecting
  the xcode27 line accepts `macosx27.x` / `27xx` while still asserting the `LSMinimumSystemVersion 14.0` floor exactly.

To cut a **27 release** once Xcode 27 is GA (or to test the path now on the beta):

```bash
export SKYBRIDGE_RELEASE_TOOLCHAIN_LINE=xcode27   # selects the 27 plist gate
export SKYBRIDGE_XCODE_TOOLCHAIN_POLICY=os27-release
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer   # GA: point at the GA Xcode 27
# then run the normal package/DMG/readiness scripts.
```

> **Deferred on purpose:** the update-manifest publishing path
> (`Scripts/generate_macos_update_manifest.swift`, `Scripts/publish_macos_update_release.sh`)
> stays pinned to the Xcode 26.6 / macOS SDK 26.5 Apple-PQC-SDK attestation. Its source-contract tests intentionally
> require an explicit, reviewed migration before a 27 manifest can be published — migrate those
> literals deliberately when you flip the shipping line to 27 GA, not before.

---

## 2. Real-device validation (iPad + Mac) — operator-only

The signed-release gate (`.github/workflows/macos-release-readiness.yml` →
`Scripts/check_macos_release_readiness.sh`) **fails closed** without seven release-evidence
artifact directories: five production-identity/real-device sets and two local security-notice
sets. Producing the real-device sets requires physical hardware and operator interaction:

| Artifact dir | Produced by |
|---|---|
| `Artifacts/release-gate/connectivity` | `Scripts/run_real_device_*smoke.sh` (connectivity) |
| `Artifacts/release-gate/p2p-remote` | `Scripts/run_real_device_p2p_remote_smoke.sh` |
| `Artifacts/release-gate/webrtc-remote` | `Scripts/run_real_device_webrtc_smoke.sh` |
| `Artifacts/release-gate/file-transfer` | `Scripts/run_real_device_file_transfer_smoke.sh` |
| `Artifacts/release-gate/p2p-notice` | remote-control notice probe |
| `Artifacts/release-gate/webrtc-notice` | WebRTC notice probe |
| `Artifacts/release-gate/notice-panel` | notice-panel probe |

### Prerequisites
1. **iPad**: connected over USB/tunnel, Developer Mode enabled, the app's provisioning
   profile installed. `run_real_device_p2p_remote_smoke.sh` discovers it via
   `xcrun devicectl list devices` and fails closed with "No connected real iPad found".
2. **Mac**: Developer ID cert, both provisioning profiles, and `notarytool` credentials present.
3. Keep the device **unlocked** and the screen on for the duration.
4. For OS 27 device runs, set `SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27` where the lane
   honors it (see `SkyBridge Compass iOS/Scripts/test_lane_ios_device.sh`).
5. **macOS Accessibility (TCC) permission** — REQUIRED for the `mac-online-ipad`
   sub-phase. That phase proves the Mac consumer UI lists the iPad as online and then
   performs a *real* Connect-button click via the Accessibility API
   (`AXIsProcessTrusted()` + `AXUIElementPerformAction`). The process that runs the
   smoke (your Terminal / the host app) must be enabled in **System Settings → Privacy
   & Security → Accessibility**. This cannot be granted programmatically (no SIP-off /
   MDM), so it is operator-only. Without it the phase fails with
   `Accessibility permission is required to press the SkyBridge online iPad Connect button`.
   Tip: run the smoke from a Terminal that already has Accessibility granted.

### Historical validation results — 2026-06-16 (superseded by PIB-1 v3)

The results below predate the two-sided PIB-1 v3 candidate/confirm/final-ack transaction.
They remain useful diagnostic history, but **are not release evidence for the current source**.
After any PIB/AppMessage change, rerun all current real-device lanes and archive a fresh
`release-acceptance.json`; never reuse this historical result.

Run via `skybridge smoke real-device-p2p --real-device-id <iPad UDID>` against
`api.nebula-technologies.net` (verified `/health` → 200). **Core capability PASSED:**
- Apple PQC SDK gate (macOS + iOS) = `symbol_probe` (real PQC, no fallback)
- P2P handshake + **X-Wing** suite; **PIB-1** protocol-identity binding; **SKR-1** signed KEM refresh
- LAN route validation (`lanMain=1`, no fallback); perf window **iOS 59.8 fps / Mac 60.1 fps**, audio flowing, upright
- `mac-online-ipad` UI (fresh-from-source client): iPad shown `status=online buttonEnabled=1` ✓

**Only blocker:** the `mac-online-ipad` synthetic Connect-click needs the Accessibility grant above.
Re-run after granting it (fresh online client, still production signaling):
```bash
SKYBRIDGE_SMOKE_MAC_ONLINE_ALLOW_DEBUG_BUILD=1 \
SKYBRIDGE_SMOKE_MAC_ONLINE_APP_BUNDLE=/tmp/skybridge-force-fresh-online-build.app \
  rust/target/debug/skybridge smoke real-device-p2p --real-device-id 00008132-0006452C1138801C
```
For a final production sign-off of that UI phase, run it against a freshly **packaged +
notarized** `dist/SkyBridge Compass Pro.app` (omit the two `MAC_ONLINE` overrides).

### Run order
```bash
# 1. iOS device lane (build + on-device tests)
"SkyBridge Compass iOS/Scripts/test_lane_ios_device.sh"
# 2. The three real-device smokes (produce the artifact dirs above)
Scripts/run_real_device_p2p_remote_smoke.sh
Scripts/run_real_device_file_transfer_smoke.sh
Scripts/run_real_device_webrtc_smoke.sh
# 3. Readiness gate over the produced artifacts (seven dirs, including WebRTC remote)
Scripts/check_macos_release_readiness.sh \
  --connectivity-artifact-dir ... \
  --p2p-remote-artifact-dir ... \
  --webrtc-remote-artifact-dir ... \
  --file-transfer-artifact-dir ... \
  --p2p-notice-artifact-dir ... \
  --webrtc-notice-artifact-dir ... \
  --notice-panel-artifact-dir ...
```

The P2P remote smoke defaults to the system Keychain and actual/user trust. Injected
KEM trust or an in-memory Keychain is permitted only with
`SKYBRIDGE_REAL_DEVICE_P2P_LAB_RUN=1`; that run exits as non-acceptance and its artifact
is rejected by release readiness. WebRTC acceptance likewise requires relay-only ICE,
audio, a successful relay UDP preflight, non-synthetic media, and at least a 10-second
passing soak. `SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN=1` permits diagnostic overrides but
cannot produce a release-eligible artifact.

Current PIB-1 v3 acceptance is explicitly two-sided: the responder returns only a signed
candidate, both devices display the same SAS and require an operator decision for a new identity,
the requester sends a signed confirmation bound to the request/candidate/transcript, and neither
side installs the new pin until the responder's signed final acknowledgement has been verified.
Automatic approval of a new/unpinned identity, a v2 response, a missing/expired transaction, or a
one-sided pin is a hard failure. Compare the SAS on the Mac and iPad before accepting either prompt.

The real-device WebRTC lane transfers its access token, tenant, connection code, and peer KEM
material in a bounded one-time `0600` bootstrap file copied into the app data container. The app
reads it off the main actor, deletes it before use, validates run ID/expiry/JWT-tenant/code/key
bindings, and installs the session only in the in-memory Keychain. These values must never be
added back to `devicectl --environment-variables` or the launch-result JSON. Raw smoke evidence
directories are private (`0700`, files `0600`); only the separately materialized and scanned
`-public-redacted` directory is shareable.

---

## 3. HDR Reference tier — validation-gated

The HDR "Reference" tier was previously **inert**: the PQ/HLG → BT.2020→P3 → tone-map
shader never executed (`pullAndRender` was always called without a drawable) and the
output view is `bgra8Unorm`. This was wired in `ReferenceRenderer.pullAndRender`:

- The HDR shader now runs **offscreen** (rgba16Float, 3-slot pool) for frames whose decoded
  buffer reports a **PQ or HLG transfer function** — detected per-frame from the
  `kCVImageBufferTransferFunctionKey` attachment. **SDR content is byte-for-byte unchanged**
  (it never enters the HDR branch — this guarantees no regression for the common path).
- `edrHeadroom` is intentionally left at `1.0` so HDR is tone-mapped into the displayable
  range of the current **SDR presenter** (`Sources/SkyBridgeCompassApp/RemoteDisplayView.swift`,
  a shared `bgra8Unorm` MTKView).

### Remaining step (needs an HDR Mac to validate)
To present **true EDR** (values > 1.0) instead of tone-mapped-to-SDR, the presenting view
must be EDR-enabled. This was **not** done blind because the view is shared with the working
SDR path and the change alters SDR color handling. On an HDR-capable Mac (e.g. XDR / Pro
Display XDR), enable it and validate:

```swift
// In RemoteDisplayView.makeNSView, on an HDR-capable display:
view.colorPixelFormat = .rgba16Float
if let layer = view.layer as? CAMetalLayer {
    layer.wantsExtendedDynamicRangeContent = true
    layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
}
// And pass the real headroom into pullAndRender:
//   referenceRenderer.pullAndRender(edrHeadroom: Float(HardwareCapabilityProbe.currentEDRHeadroom()))
```
Validate that: (a) SDR remote sessions look identical to before, (b) genuine HDR (HEVC
Main10 PQ/HLG) content shows correct highlights without clipping, (c) no tearing under load.
For full 10-bit precision, also switch the HDR decode path to
`kCVPixelFormatType_64RGBAHalf` (see the comment in `ReferenceRenderer.ensureDecompressionSession`).

---

## 4. Remote-desktop "live control" — current status & remaining work

**What is already live:** *file transfer*. The agent runtime
(`rust/crates/skybridge-agent/src/runtime.rs` → `runtime/file_transfer.rs`) observes a
`file send` request and spawns a real transfer behind the existing gates.

**What is NOT live (by design):** *remote-desktop control* (`start/stop/set-resolution/set-fps`).
The CLI enqueues a bounded request; the agent **observes** it but logs
`"observed by agent but not live-applied"`. Making it live honestly requires a vertical slice
that spans three components and **must be validated on real devices** (the
`real_device_p2p_remote_gate` / `sender_observed_mode_change` gates exist for exactly this):

1. **Core model** — add an `Applied` / `ApplyFailed` state to `RemoteDesktopControlRequest`
   (`rust/crates/skybridge-core/src/session/remote_desktop.rs`); today it only has
   `PendingAgentObservation → AgentObserved → AgentRejected`.
2. **Transport** — a control-channel send for RD control envelopes. The native sender today
   exposes only `send_file_app_frame` (file-framed); a generic control send over the existing
   `CONTROL_CHANNEL_LABEL` data channel is needed.
3. **Sender apply** — the macOS sender (`RemoteControlManager.handleControlMessagePayload`)
   must reconfigure the live `SCStream` (resolution/fps) or start/stop capture on receipt,
   then report the observed mode change.

> This was deliberately **not faked**: the project's invariant (and the audit) require that
> the CLI never reports a capability as live/applied when it isn't. `mutation_supported`
> stays `false` until the slice above lands and passes real-device validation.

When implementing, keep every existing gate; the CLI's `live_control_status` should move
`planned → pending_agent_observation → applied` only when step 3 actually confirms the change.
