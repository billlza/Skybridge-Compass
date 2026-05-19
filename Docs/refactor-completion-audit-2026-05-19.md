# Refactor Completion Audit - 2026-05-19

## Objective

Reduce code bulk and Rust CLI complexity through structured module extraction without regressing performance, stability, clarity, or maintainability.

The goal is not complete until automated gates and manual iPad + Mac P2P testing both support the result.

## Success Criteria

| Requirement | Evidence required | Current status |
| --- | --- | --- |
| Rust CLI complexity is controlled | Largest files are small enough to reason about; dispatch and control-plane doctor boundaries are separated; full Rust tests pass. | Covered |
| macOS large-file risk is reduced without touching hot paths unnecessarily | Extracted coordination logic compiles and targeted signaling/media tests pass. | Covered for this round |
| iOS large-file risk is reduced without touching Metal/decode hot paths unnecessarily | Device and endpoint resolution are outside `RemoteDesktopManager`; iOS regression tests pass. | Covered for this round |
| P2P 2056x1329 60 FPS target is preserved | Real iPad artifact shows HEVC, Metal renderer, 2056x1329, final-window FPS/RX FPS near 60, no fallback. | Covered by latest automated artifact |
| Manual iPad + Mac P2P behavior is validated | Human-run test matrix covers UI startup, remote desktop, input, audio, clipboard, file transfer, reconnect, lifecycle, network disturbance. | Pending |

## Artifact Checklist

| Item | Concrete artifact or command | Result |
| --- | --- | --- |
| macOS signaling lifecycle extraction | `Sources/SkyBridgeCore/RemoteConnection/WebRTC/CrossNetworkSignalingLifecycleCoordinator.swift` | Extracted coordinator present |
| macOS manager still wires coordinator | `Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift` uses `CrossNetworkSignalingLifecycleCoordinator` | Verified by source scan |
| iOS device resolution extraction | `SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopDeviceResolutionCoordinator.swift` | Extracted coordinator present |
| iOS manager uses resolver factory | `RemoteDesktopManager.swift` has `makeDeviceResolutionCoordinator()` | Verified by source scan |
| Rust control-plane doctor split | `control_plane_doctor/signaling.rs`, `control_plane_doctor/media_lease.rs` | Split present |
| Rust smoke dispatch split | `cli_dispatch/smoke.rs` | Split present |
| Manual artifact mode | `skybridge check performance --kind p2p-remote --manual-artifact` | Implemented and tested |
| Manual artifact wrapper | `Scripts/check_manual_p2p_remote_artifact.sh` | Present and executable |
| Manual artifact wrapper smoke test | `Scripts/test_check_manual_p2p_remote_artifact.sh` | Passed |
| Manual test plan | `Docs/manual-p2p-real-device-test-plan.md` | Present |

## Verification Evidence

Rust CLI:

```bash
cargo test -p skybridge
```

Latest result: `187 passed; 0 failed`.

Focused Rust checks:

```bash
cargo test -p skybridge p2p_remote
cargo test -p skybridge check_subcommands_parse_with_json_flags
cargo test -p skybridge p2p_remote_manual_artifact_accepts_remote_desktop_pass_without_smoke_final
cargo fmt --check -p skybridge
```

Latest result: all passed.

Latest strict/manual artifact command:

```bash
cargo run -p skybridge -- check performance \
  --kind p2p-remote \
  --artifact-dir ../Artifacts/real_device_p2p_remote_smoke_20260519_182438 \
  --min-fps 59 \
  --min-width 2056 \
  --min-height 1329 \
  --exact-video-size \
  --manual-artifact \
  --json
```

Latest result: all P2P remote checks passed, including route, X-Wing, signed KEM refresh, HEVC main path, exact resolution, iOS window FPS, macOS sender FPS, timing correlation, raw latency, Metal render queue, decode queue, audio continuity, and no fallback.

Latest iPad artifact:

`Artifacts/real_device_p2p_remote_smoke_20260519_182438`

Key evidence:

- `remote-desktop-pass ... windowFPS=59.8 windowRxFps=60.4 frame=2056x1329 pipeline=metalRenderer`
- `mac-sck-start targetFPS=60 codec=hevc requested=2056x1329 encoded=2056x1330 visible=2056x1329`
- `smoke-final result=success validated=1 route=lan-main fps=59 frame=2056x1329`

Whitespace/patch hygiene:

```bash
git diff --check
```

Latest result: clean.

Manual artifact wrapper:

```bash
Scripts/test_check_manual_p2p_remote_artifact.sh
shellcheck Scripts/check_manual_p2p_remote_artifact.sh Scripts/test_check_manual_p2p_remote_artifact.sh
```

Latest result: both passed.

## Remaining Risk

The objective is not complete because the manual iPad + Mac P2P pass has not been run yet.

Latest artifact scan:

- Time: `2026-05-19 18:53:45 CST`
- Latest P2P remote artifact found: `Artifacts/real_device_p2p_remote_smoke_20260519_182438`
- No newer manual iPad + Mac P2P artifact/log directory was present under `Artifacts`.

Required manual coverage before completion:

- Start remote desktop from the normal iPad UI.
- Exercise pointer, click, drag, keyboard, and modifier input.
- Verify audio continuity during active remote desktop use.
- Verify clipboard in both directions.
- Transfer small and large files before and after remote desktop.
- Disconnect and reconnect repeatedly.
- Background and foreground the iPad app during idle and active streaming.
- Disturb the network path enough to confirm clean recovery or explicit failure.
- Run the `--manual-artifact` performance check on the resulting log directory when available.

## Current Recommendation

Freeze broad structural refactors until the manual P2P pass completes. Any next code change should be driven by a concrete manual-test failure or a narrowly scoped source audit.
