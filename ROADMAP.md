# SkyBridge Compass Pro — Roadmap & Real Status

> Updated: 2026-06-16. This is the **single source of truth for "what's done vs. planned."**
> `FEATURE_DESIGN_v2.md` is a *design proposal* (some items aspirational); this file
> records the ground truth verified against the code. When they disagree, trust the code +
> `Package.swift` + this file.

## Platform & compatibility baseline (current, verified)

- **Deployment floor: macOS 14 / iOS 17** (`Package.swift`, `Info.plist LSMinimumSystemVersion 14.0`). Held firm.
- **OS 27 support is additive**: all new-OS API is behind `#available(macOS 26/27, iOS 26/27, *)` guards (every guard ends in `*`). macOS 14–15 use liboqs PQC; macOS 26+ use Apple CryptoKit native PQC (HPKE X-Wing, ML-KEM, ML-DSA). No source change needed for OS 27; the floor never rises.
- **Toolchain**: Swift 6.3 / Xcode 26.5 stable; Xcode 27 beta only for manual OS27 validation.

## Feature status (verified 2026-06-16)

| Feature | Status | Notes |
|---|---|---|
| Clipboard sync | ✅ Implemented | `ClipboardRedirection` / `ClipboardRedirectionManager` (not the doc's `ClipboardSyncManager`). |
| Bandwidth throttling | ✅ Implemented | Rate-limit / bandwidth caps across transport + settings. |
| Offline message queue | ✅ Implemented | `OfflineMessageQueue`. |
| Multi-factor approval | ✅ Implemented | `ConnectionApprovalService` / approval types. |
| Network-aware scheduling | ✅ Implemented | `NWPathMonitor`-driven path/cost awareness. |
| Cloud sync/backup | 🟡 Partial | CloudKit sync present; a dedicated `CloudBackupManager` / CKSyncEngine path is not fully built. |
| Hardware performance monitor | 🟡 Partial | Metrics exist; the doc's `HardwarePerformanceMonitor` class does not. |
| ML anomaly detection | 🟡 Rules-only | Rule-engine `AnomalyDetectionService`; Foundation Models integration not done — and by policy must stay out of the handshake/crypto/media hot path (diagnostics only). |

## Remote desktop rendering (done)

Three-tier Stable → Fluid → Reference pipeline is implemented. HDR/Reference tier is offscreen-wired for PQ/HLG; **true EDR output remains validation-gated** (needs an HDR Mac). See the rendering pipeline tests.

---

## Near-term engineering (low-risk, high-value)

1. **Protocol-parity drift gate — ✅ DONE (2026-06-16).** `Scripts/check_protocol_parity.py` + `.github/workflows/protocol-parity.yml` guard the ~32 hand-copied iOS↔macOS wire/protocol files (normalized-hash baseline + DataChannel-label wire anchors). See `Docs/CoreLayering.md`.
2. **WebRTC Swift package 148→149+** — blocked by an *upstream* checksum bug on 149 (`Package.swift` line ~93). Bump when upstream fixes it; no code change expected.
3. **Move SwiftUI views out of `SkyBridgeCore` into `SkyBridgeUI`** — `SettingsView`, `DeviceManagementView`, `DiscoveryDiagnosticsView` violate the UI-layer boundary (`CoreLayering.md`). Small-step migration (cover with baseline test → move → delete).
4. **Verify vendored FreeRDP ≥ 3.26** — ✅ confirmed `3.26.0` (`Scripts/build_freerdp_xcframework.sh`). Keep tracking 3.27+ for TLS/crypto updates.
5. **Doc hygiene** — add implementation status + code anchors to contract docs (`signaling-lifecycle-contract.md`, `failure-matrix-and-recovery.md`).

## Cross-platform expansion (Windows / Android / Linux)

**Key asset:** the *entire* protocol stack already exists in portable Rust (`rust/crates/skybridge-core`: `pqc_handshake`, `classic_handshake`, `native_webrtc`, `signaling`, `route`, `session`, `control_plane`) with **zero `target_os` cfg**. What's Apple-locked is only the per-OS *shell*: screen capture, input injection, video encode, attestation — exactly what `PlatformAdapter` abstracts (Mac-only impl today).

**Highest-leverage move:** make `PlatformAdapter` a **Rust trait + FFI boundary** so every new platform reuses the portable transport/handshake and only implements native capture/inject.

- **Phase 0 (prereq):** Rust `PlatformAdapter` trait + macOS FFI bridge over the existing Swift adapter. *(Skeleton landed under `rust/crates/skybridge-core/src/platform/` — see that module for the contract.)*
- **Phase 1 (proof):** Ubuntu/Linux — X11 `XGetImage` capture + `XTest` injection (lowest-friction first non-Apple target). Wayland (PipeWire portal) follows.
- **Phase 2 (parallel):** Android — official libwebrtc AAR + JNI `MediaProjection` (capture) / `InputDispatcher` (inject).
- **Phase 3 (parallel):** Windows — `windows-rs` `Windows.Graphics.Capture` + `SendInput`; file-transfer first, screen/input second.
- **Validation:** golden cross-platform test vectors (known nonce / KEM ciphertext / signature / shared-secret tuples) locking wire-format parity, in CI.

Rough sizing: ~8 weeks parallel / ~12 weeks sequential for a first Linux + Android proof. **Do not start Phases 1–3 until Phase 0 is merged.**

## Tech-watch (no action now)

- **Media-over-QUIC (MoQ)** — IETF draft; *complements* WebRTC, likely Proposed Standard ~2027. Add experimental tier if/when it lands.
- **AV1 hardware encode** — adopt only when Apple Silicon gains a hardware encoder; software AV1 is 10–50× too slow for interactive use. H.266/VVC not viable on macOS in 2026.
- **X-Wing → CFRG RFC** — doc-only change when the hybrid finishes standardization (post-2026).
- **Rust signaling server** — optional consolidation if Node.js becomes a bottleneck (>~100k concurrent); not needed now.

## Explicitly out of scope / deferred

- Lowering the deployment floor below macOS 14 / iOS 17.
- Putting Foundation Models / ML on the handshake, crypto, or media hot path.
- Switching the frozen TDSC paper baseline to new PQC tiers without a full artifact refresh.
