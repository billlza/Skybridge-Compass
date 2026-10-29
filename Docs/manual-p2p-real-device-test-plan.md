# Manual P2P Real-Device Test Plan

## Purpose

This checklist is the manual acceptance layer after large macOS, iOS, and Rust CLI refactors. Automated smoke gates prove that the main media path can still hit the target, but they do not replace hands-on iPad + Mac testing for real UI behavior, repeated operations, and recovery paths.

Do not resume broad structural splitting until this manual pass is complete or a specific failure gives us a concrete fix target.

## Current Automated Baseline

Latest verified artifact:

`Artifacts/real_device_p2p_remote_smoke_20260519_182438`

Key evidence from that run:

- iPad viewer: `remote-desktop-pass ... windowFPS=59.8 windowRxFps=60.4 frame=2056x1329 pipeline=metalRenderer`
- Mac host: `mac-sck-start targetFPS=60 codec=hevc requested=2056x1329 encoded=2056x1330 visible=2056x1329`
- Final result: `smoke-final result=success validated=1 route=lan-main fps=59 frame=2056x1329`
- Audio remained clean in the pass window: `audioRxRejected=0`, `audioRxPlaybackDrop=0`, `audioRxReplayRejected=0`, `audioRxUnderflow=0`, `audioRxRebuffer=0`

This is a release-readiness baseline, not a substitute for manual interaction.

## Machine Gate for Artifact Folders

When a manual run is captured in the same artifact layout as the real-device P2P remote run, validate it with the existing strict CLI gate:

```bash
Scripts/check_manual_p2p_remote_artifact.sh Artifacts/<artifact-folder>
```

The wrapper above calls the underlying Rust gate:

```bash
cd rust
cargo run -p skybridge -- check performance \
  --kind p2p-remote \
  --artifact-dir ../Artifacts/<artifact-folder> \
  --min-fps 59 \
  --min-width 2056 \
  --min-height 1329 \
  --exact-video-size \
  --min-pass-window-seconds 10 \
  --manual-artifact \
  --json
```

The latest baseline artifact passes this command. The gate covers:

- source completeness
- hidden failure markers
- LAN route selection
- X-Wing and signed KEM refresh evidence
- HEVC main path
- exact visible resolution
- iOS final-window FPS and RX FPS
- macOS sender FPS and backpressure
- timing correlation
- iOS raw latency
- Metal render queue health
- decode queue health
- audio continuity
- no fallback path

`--manual-artifact` only relaxes the formal `smoke-final` sentinel. It still requires remote desktop pass-window evidence and all media, route, security, render, audio, and no-fallback checks to pass.

## Preconditions

- Use the current working tree build for both macOS and iPad.
- Keep the Mac and iPad on the intended P2P/LAN network path.
- Start from a clean app launch on both sides.
- Confirm the iPad sees the Mac through the normal UI, not only through a direct smoke harness.
- Keep macOS and iPad logs available for post-test triage.

## Manual Pass Criteria

The session is acceptable only if all of these hold during normal use:

- Remote desktop opens from the iPad UI without requiring a retry loop.
- Visible stream stays at `2056x1329` and uses the Metal renderer.
- Perceived motion remains 60 FPS class during desktop movement, window movement, scrolling, and typing.
- No sustained visible stalls, black frames, wrong orientation, frame tearing, or stale-frame jumps.
- Input events stay responsive: pointer movement, click, drag, keyboard, modifier keys.
- Clipboard sync still works after remote desktop has started.
- Audio starts, remains continuous, and does not accumulate underflow or rebuffer counters.
- File transfer still works before and after a remote desktop session.
- Disconnect, reconnect, and app foreground/background transitions do not leave a stuck session.
- Logs do not show a silent fallback path, stale generation restart, or route confusion.

## Test Matrix

| Area | Steps | Pass evidence |
| --- | --- | --- |
| Discovery and trust | Fresh-launch both apps, find Mac from iPad, connect through the UI. | Stable device identity, no ambiguous trust or alias-only endpoint. |
| Remote desktop startup | Start remote desktop from iPad. | First frame appears quickly; logs show `2056x1329`, `hevc`, `metalRenderer`. |
| 60 FPS feel | Move windows, scroll, type, and move pointer for at least 2 minutes. | No visible stutter; status logs stay near 60 FPS and no queue drop/backlog buildup. |
| Input control | Click, drag, text input, modifier shortcuts, and focus changes. | Actions land once, in order, without lag spikes or duplicate input. |
| Audio | Play continuous audio on Mac while viewing from iPad. | Audio continues; counters stay at zero for rejected/drop/underflow/rebuffer. |
| Clipboard | Copy text on one side, paste on the other, then repeat after reconnect. | Clipboard works in both directions without restarting either app. |
| File transfer | Send a small file and a larger file before and after remote desktop. | Transfer completes with the intended route and no integrity failure. |
| Reconnect | Stop remote desktop, reconnect, then repeat twice. | Old session is torn down; new session starts without stale callbacks. |
| App lifecycle | Background and foreground iPad app during idle and active stream. | UI recovers or fails explicitly; no hidden half-connected state. |
| Network disturbance | Brief Wi-Fi fluctuation or router roam if available. | Either recovers cleanly or fails with a clear error; no indefinite spinner. |

## Log Checks

After a manual pass, scan logs for these positive signals:

```text
mac-stream-config ... codec=hevc fps=60 ... fallback=fail-fast
mac-sck-start targetFPS=60 codec=hevc requested=2056x1329 encoded=2056x1330 visible=2056x1329
remote-desktop status ... windowFPS=... windowRxFps=... frame=2056x1329 pipeline=metalRenderer
screenDelivery=immediate-decode-metal-feed-direct
queueDrop=0
audioRxRejected=0
audioRxPlaybackDrop=0
audioRxUnderflow=0
audioRxRebuffer=0
```

Treat any of these as a stop-and-fix signal:

```text
pipeline=fallback
ciFallback=1
queueDrop>0 during steady state
realtimeReplacementBeforeDraw>0 during steady state
fallback render evidence
unknown suite
alias-only remote-control endpoint
stale generation
untrustedPeer
```

## Result Record

Record each manual run with:

- Date and build identifiers for Mac and iPad.
- iPad model and iPadOS version.
- Mac model and macOS version.
- Network path.
- Duration.
- Pass/fail result for every row in the matrix.
- Artifact/log folder path.
- Any visible performance issue, even if logs pass.
