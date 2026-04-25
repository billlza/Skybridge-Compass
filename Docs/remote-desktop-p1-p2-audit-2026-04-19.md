# Remote Desktop P1/P2 Audit

Date: 2026-04-19
Scope: P2P/WebRTC remote desktop path only. This document is an optimization audit, not an implementation change list.

## P1

- `QualityGovernor` needs a verified hot-path hook into live session adaptation.
  The current codebase contains `QualityGovernor`, but the effective WebRTC stream policy is still selected in `WebRTCRemoteDesktopVideoPolicySelector` and applied via `CrossNetworkConnectionManager`. We should make `QualityGovernor` the authoritative source for runtime bitrate, FPS, codec, and frame-size downgrades, or remove the duplicate policy layer. Until that happens, adaptive quality decisions risk being observational instead of controlling.

- Relay and unknown transport paths should stop defaulting so early to `BGRA`.
  The current relay/unknown path policy is conservative to the point of being expensive on bandwidth and decoder stability. For remote desktop, the safer default is usually conservative `H.264` first, then `HEVC` where decoder health and hardware support are proven. `BGRA` should be a last-resort fallback for diagnostic or compatibility modes, not the normal relay fallback.

- `RendererHealthMonitor` should drive degradation, not just report it.
  Today the monitor and `RenderingModeController` can observe health, but there is still a gap between “we detected decoder/render stress” and “we immediately adjusted encoder/session policy.” We should bind sustained health regressions directly to codec fallback, frame pacing, sync-frame requests, and queue-depth caps so the system closes the loop automatically.

- Remote desktop codec governance should be unified with viewer preset governance.
  The repo already has viewer presets and codec governance logic on iOS, but the selection and recovery path are still split across multiple components. We should have one source of truth for preset intent, decoder health, and transport constraints so the same session does not oscillate between incompatible policies.

## P2

- TURN credential fallback needs explicit UI and telemetry visibility.
  When dynamic TURN credentials fail and the stack falls back to STUN-only or static TURN, that downgrade is too implicit. We should surface a user-visible session status and emit structured telemetry describing which ICE path was chosen and why.

- Cross-network file-transfer and remote-desktop ack/phase telemetry should use the same stage vocabulary.
  The remote desktop stack already has retry and ack helpers, but phase-level diagnostics are inconsistent with the LAN file-transfer work. We should standardize on a common `sessionId + transferId/streamId + op + phase` log contract so future regressions are diagnosable across transports.

- Session readiness and first-frame confirmation should be consolidated.
  The code already contains native-ready announcements, viewer bootstrap guards, and frame confirmation helpers. Those mechanisms should be collapsed into one readiness model so we do not keep separate timers and “first usable frame” heuristics in multiple layers.

- Viewer policy should expose relay-awareness to the UI layer.
  The transport layer knows when a session is LAN, relay, or degraded, but the UI does not clearly communicate the resulting preset/codec choice. A small status indicator would make “why did this session switch to compatibility mode?” much easier to explain and support.

## Recommended Order

1. Make `QualityGovernor` authoritative over live adaptation.
2. Change relay/unknown default policy from early `BGRA` fallback to conservative `H.264` preference.
3. Wire `RendererHealthMonitor` outputs into codec/frame-rate downgrade actions.
4. Add TURN fallback telemetry and session-status UI.
