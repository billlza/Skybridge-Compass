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

The release transaction is deliberately ordered and fail-closed:

1. `.github/workflows/macos-release-readiness.yml` builds, signs, notarizes, staples,
   and Gatekeeper-validates one candidate. It emits `macos-signed-release-candidate`
   with `macos-release-candidate.json`.
2. `.github/workflows/real-device-release-gate.yml` runs only on the protected physical
   runner and behind `release-real-device-evidence` approval. Every producer must consume
   that candidate and include the exact candidate manifest in its public artifact.
3. `.github/workflows/macos-release-publish.yml` downloads the original candidate and the
   four evidence archives, verifies exact candidate identity in all four, and publishes the
   original app/DMG bytes. It never rebuilds the candidate.

Both protected workflows first query their named GitHub environment and fail unless it
exists with at least one required reviewer, `prevent_self_review=true`, and administrator
bypass disabled. The environment must also enable exactly one protected-branch or custom
deployment-branch policy; an all-branches environment is not an approval boundary. The
physical runner must use GitHub Actions Runner 2.327.1 or newer (required by the pinned
Node 24 artifact actions) and carry the `skybridge-real-device-release` label. Until those
environments and that labeled runner are provisioned, the transaction remains intentionally
non-runnable rather than bypassing review.

SHA-256 in the candidate/file-set documents is used only to detect accidental cross-run
or archive mismatch. Apple code signing, notarization, and Gatekeeper are the security
boundaries.

Only four evidence artifacts are release contracts. Notice/panel proof belongs inside the
P2P and WebRTC product-session artifacts; local probes are diagnostic-only:

| Artifact dir | Produced by |
|---|---|
| `Artifacts/release-gate/connectivity` | `Scripts/run_formal_product_evidence_session.sh --kind connectivity` |
| `Artifacts/release-gate/p2p-remote` | `Scripts/run_formal_product_evidence_session.sh --kind p2p` |
| `Artifacts/release-gate/webrtc-remote` | `Scripts/run_formal_product_evidence_session.sh --kind webrtc` |
| `Artifacts/release-gate/file-transfer` | `Scripts/run_formal_product_evidence_session.sh --kind file-transfer` |

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
# 1. Dispatch macos-release-readiness with an approved release_build_id.
#    Download/extract macos-signed-release-candidate on the protected runner.
export SKYBRIDGE_RELEASE_CANDIDATE_MANIFEST="<candidate>/macos-release-candidate.json"
export SKYBRIDGE_RELEASE_CANDIDATE_APP_PATH="<candidate>/SkyBridge Compass Pro.app"
export SKYBRIDGE_RELEASE_CANDIDATE_DMG_PATH="<candidate>/SkyBridgeCompassPro-1.0.2.dmg"

# 2. iOS device lane (build + on-device tests)
"SkyBridge Compass iOS/Scripts/test_lane_ios_device.sh"
# 3. Run each ordinary-product evidence session with exact candidate/archive inputs.
#    See Docs/ops/apple-formal-product-evidence.md for the complete invocation.
#    First produce the one-time immutable identity lifecycle binding/proof.
Scripts/run_formal_ios_identity_lifecycle.sh ...
Scripts/run_formal_product_evidence_session.sh --kind connectivity ...
Scripts/run_formal_product_evidence_session.sh --kind p2p ...
Scripts/run_formal_product_evidence_session.sh --kind webrtc ...
Scripts/run_formal_product_evidence_session.sh --kind file-transfer ...
# 4. Readiness gate over the four canonical artifacts
Scripts/check_macos_release_readiness.sh \
  --connectivity-artifact-dir ... \
  --p2p-remote-artifact-dir ... \
  --webrtc-remote-artifact-dir ... \
  --file-transfer-artifact-dir ...
```

### Formal product entry and retained diagnostic lanes

The former P2P inbound receiver uses `LocalLanInteropHost`; the former WebRTC receiver
uses `LocalWebRTCSmokeHarness`, and the iOS launch path compiles `SKYBRIDGE_TESTING`.
Those paths remain useful diagnostics but cannot produce release evidence. The
formal front door is `run_formal_product_evidence_session.sh`; it starts the immutable Mac
candidate and sealed iOS Release product through ordinary entry points and requires the
following product evidence, with no hidden smoke environment variables:

| Required product observation | P2P | WebRTC |
|---|---|---|
| Normal UI/session start | External AX activates the normal device-row Connect/Accept action | External AX activates the normal cross-network Connect/Accept action |
| Exact session owner | Paired Mac/iOS owners for two opaque `session_ref` values and both roles | Paired Mac/iOS owners for one opaque `session_ref`, current generations, and selected relay path |
| Notice lifecycle | panel presented, explicit human approve/reject, active | panel presented, explicit human approve/reject, active |
| Protected data effect | authenticated secure frame presented by the product renderer | authenticated data/media frame presented by the product renderer |
| Input/product effect | privacy-safe input event applied and externally visible UI effect | privacy-safe input event applied and externally visible UI effect |
| Terminal state | same owner/session disconnected and notice hidden | same owner/session disconnected and notice hidden |
| Candidate binding | exact `macos-release-candidate.json` in artifact, verified against app/DMG | exact `macos-release-candidate.json` in artifact, verified against app/DMG |

The minimal product interface should be a small typed event sink at the existing session
coordinator/remote-control boundaries, with a production default that writes privacy-safe
unified logging. It must not start sessions, alter approval, expose a hidden test role, or
own networking. The producer observes normal UI via Accessibility and captures these
ordered fields from the product log subsystem:

```text
releaseSessionOwner transport=<p2p|webrtc> session_ref=ev1:<32hex> owner=SkyBridgeCompassApp generation=<positive> state=active routeClass=<wifi|awdl>|selectedTransport=<direct|relay>
remoteControlNoticeShown transport=<...> session_ref=<same> owner=SkyBridgeCompassApp generation=<same> phase=awaitingApproval result=presented
remoteControlNoticePanelPresented transport=<...> session_ref=<same> owner=SkyBridgeCompassApp generation=<same> phase=awaitingApproval buttons=approve,reject result=visible
remoteControlNoticeHumanApproved transport=<...> session_ref=<same> owner=SkyBridgeCompassApp generation=<same> phase=awaitingApproval decisionSource=user result=approved
remoteControlNoticeApproved transport=<...> session_ref=<same> owner=SkyBridgeCompassApp generation=<same> phase=awaitingApproval decisionSource=user result=approved
remoteControlNoticeActive transport=<...> session_ref=<same> owner=SkyBridgeCompassApp generation=<same> phase=active result=active
secureFrameAccepted transport=p2p session_ref=<same> owner=SkyBridgeCompassApp generation=<same> frame_seq=<positive> effect=presented proof=p2p-renderer-ack bytes=<positive> width=<positive> height=<positive>
secureFrameAccepted transport=webrtc session_ref=<same> owner=SkyBridgeCompassApp generation=<same> frame_seq=<positive> effect=presented proof=webrtc-renderer-receipt bytes=<positive> width=<positive> height=<positive>
localFramePresented transport=<p2p|webrtc> session_ref=<same> owner=SkyBridgeCompassApp generation=<same> local_frame_seq=<positive> effect=presented proof=local-renderer bytes=<positive> width=<positive> height=<positive>
remoteInputApplied transport=<...> session_ref=<same> owner=SkyBridgeCompassApp generation=<same> event_seq=<positive> effect=<pointer|keyboard|scroll> applied=1
remoteControlNoticeDisconnected transport=<...> session_ref=<same> owner=SkyBridgeCompassApp generation=<same> phase=terminal result=disconnected
remoteControlNoticePanelHidden transport=<...> session_ref=<same> owner=SkyBridgeCompassApp generation=<same> phase=terminal result=hidden
releaseSessionDisconnected transport=<...> session_ref=<same> owner=SkyBridgeCompassApp generation=<same> noticeHidden=1 reason=<user|peer|trust-invalidated|session-replaced|protocol-failure> result=disconnected
```

The production recorder caps each owner generation at 20 public evidence lines; the
collector and parser enforce the same bound. For formal WebRTC evidence the owner must
report `selectedTransport=relay`; for P2P it reports the measured `routeClass=wifi|awdl`.
Only `secureFrameAccepted` with the transport-matched peer-renderer acknowledgement satisfies
the formal protected-frame effect. `localFramePresented` is valid local renderer telemetry but
cannot substitute for peer-side P2P acknowledgement or WebRTC renderer receipt.
The out-of-process collector uses the exact candidate PID and this fixed predicate:

```text
subsystem == "com.skybridge.compass.release-evidence" AND category == "ProductSession"
```

Raw unified-log NDJSON stays private; only the strict lines above plus
`mac-product-session-capture.json` enter a public artifact. The capture manifest records
only the exact PID, public start-time token, executable name, and `ownershipVerified=true`;
the audit token remains inside the private mode-`0700` capture directory. The collector
calls the repository's `mac-capture` once and `mac-status` both before and after capture,
so a same-path PID replacement is rejected without adding another digest:

```bash
Scripts/collect_product_release_evidence_log.sh \
  --pid "$CANDIDATE_PID" \
  --candidate-manifest "$SKYBRIDGE_RELEASE_CANDIDATE_MANIFEST" \
  --candidate-app "$SKYBRIDGE_RELEASE_CANDIDATE_APP_PATH" \
  --candidate-dmg "$SKYBRIDGE_RELEASE_CANDIDATE_DMG_PATH" \
  --timeout-seconds 180 \
  --artifact-dir "$PRIVATE_EVIDENCE_DIR"
```

Never log raw account IDs, Nebula IDs,
device identifiers, addresses, coordinates, keystrokes, tokens, SAS values, or candidate
paths/digests. Candidate identity remains an out-of-process manifest comparison.

The formal file-transfer session uses the ordinary Send/Accept UI and exposes only
`fileTransferStarted` and `fileTransferCompleted` with an opaque transfer reference,
direction, final result, and a visible completion effect. It must not log file names,
paths, contents, byte/chunk counts, devices, or
accounts. The connectivity session captures both shipping candidates and the fixed
`connectivityAttemptStarted`, `connectivityAttemptAuthenticated`,
`connectivityEndpoint`, and `connectivityPolicyRejected` OSLog events from the exact Mac and
iOS candidate processes. `mac-product-session.log` remains bound by
`mac-product-session-capture.json`; connectivity alone additionally requires
`ios-product-session.log` and `ios-product-session-capture.json`, whose fixed manifest binds
the `SkyBridgeCompass-iOS` executable, bundle `com.skybridge.compass.ios`, physical iOS
platform, while event ownership remains `SkyBridgeCompassiOS`, and the
exact sealed release-testing archive binding. External `connectivityCase`, `connectivity-case`,
status labels, helpers, simulator processes, debug builds, and synthetic events are not formal
product evidence.

For the three successful profile pairs (`xwing/xwing`, `xwing/pqc`, and `pqc/xwing`), the
validator joins one Mac and one iOS endpoint by identical `attempt_ref` and `session_ref`.
Both endpoints must report the same negotiated suite and `attemptProfile`, complementary roles,
locally consistent generations, and a suite family actually present in each endpoint's
`offeredProfiles`. A mixed profile pair is not assigned one hard-coded suite: either X-Wing or
a negotiable pure-PQC suite is accepted when both actual signed offers contain that family.
The two classic edges are expected strict-policy rejections, not successful fallback sessions:
one shipping Mac responder and one shipping iOS responder must each emit exactly
`started -> policyRejected`, with `peerOfferSignature=verified`, no authenticated session, and
no endpoint. Every local attempt still has the 20-event hard limit.

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

Diagnostic WebRTC bootstrap material remains private and must never be added to release
evidence. The formal product session uses the ordinary signed-in product session,
system Keychain, and normal UI; it does not inject access tokens, tenant IDs, connection codes,
peer KEM material, or `SKYBRIDGE_TESTING` through `devicectl`. Raw diagnostic directories remain
private (`0700`, files `0600`); only separately materialized and scanned candidate-bound
`-public-redacted` directories are shareable.

The complete operator contract, exact iOS unified-log collection boundary, fixed product-only
file contract, and private-first cleanup finalization order are documented in
`Docs/ops/apple-formal-product-evidence.md`.

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
