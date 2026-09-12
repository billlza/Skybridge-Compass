# Windows, Mac, and iOS Parity Gap Audit

Date: 2026-08-11

This audit compares the current Windows worktree against the current Mac/iOS
worktree for device discovery, handshake and session authority, PQ/PQC security,
file transfer, remote desktop/control, account and settings truth, and CLI or
launch command consistency.

The conclusion is intentionally strict: Windows is directionally aligned with
the Apple architecture, and the transport/current-path/product-control work has
good fail-closed gates. Account/session/settings persistence now has a typed
non-device contract gate, and RuntimeSmoke AppControl evidence can now be
imported into the core-owned Windows operator session registry through the Rust
CLI, including the AppControl live scripts' protected `--session-id-out` to
`--session-id-file` path. Windows is still not product-runtime parity with
Mac/iOS until the live product authority and real-device gates pass.

## Repos Audited

- Windows: `/Users/bill/Desktop/SkyBridge Compass-win64/Skybridge-Compass`
- Apple: `/Users/bill/Desktop/SkyBridge Compass Pro release`

Both worktrees were dirty during the audit, so this document records the current
workspace state rather than a clean release baseline.

## Overall Verdict

Windows currently has:

- Rust core protocol diagnostics and a Windows `skybridge` CLI capability report.
- WinUI shell workspaces that preserve fail-closed preview and intent boundaries.
- Core transport planning, channel mapping, SBP2/SBF1 framing, and suite policy.
- Current-path signaling, header-auth WebSocket binding, WebRTC helper transport
  gates, product-control handshake code, and AppControl runtime smoke gates.
- A Rust core `runtime/sessions.json` import path that accepts only validated
  AppControl ping/pong evidence with matching session and remote-device hashes,
  plus offerer/answerer AppControl live-script opt-in wiring that exports the
  raw session id only through a protected short-lived file before calling Rust
  with `--session-id-file`; the repository smoke and acceptance verifier can
  digest-check the redacted import reports without publishing the raw session
  state directory. File-transfer and remote-desktop request registration can
  consume the same redacted session authority.
- Explicit evidence-state language that separates management SSH, helper echo,
  transport-only proof, handshake proof, and AppControl proof.

Windows does not yet have:

- A single live Windows agent/session authority equivalent to the Apple Rust
  CLI/native agent surface; the current session registry import is a strict
  non-device bridge from AppControl evidence and a protected script handoff,
  not a live `code create`/`connect` lifecycle owner.
- Product UI composition that registers or looks up a live code, performs the
  product handshake, persists peer trust, and exposes the result as user-visible
  runtime state.
- Live product file transfer proof with bytes, ACKs, SHA-256 receipt evidence,
  and failure-phase artifacts.
- Live product remote desktop/control proof with capture, video, input,
  notice lifecycle, and performance artifacts.
- Real Windows-environment proof for the account/session/settings fail-closed
  contract, including DPAPI and live Supabase rejection/revocation behavior.

Dependency freshness is no longer one of the identified gaps in this checkout.
The 2026-08-11 online gate verifies every direct product NuGet and Rust dependency,
the .NET and Rust toolchains, cargo-llvm-cov, and the CI actions against official
latest-stable metadata. This removes version drift as a confounding variable; it
does not promote any static, helper, transport, or handshake result to live
product parity.

## Proof State Boundaries

These states must stay separate in docs, scripts, UI text, and release evidence:

| State | What it proves | What it must not prove |
| --- | --- | --- |
| `OpenSshPqKex` | SSH management channel negotiated a PQ KEX | WebRTC, product handshake, AppControl, peer trust |
| `HelperDataChannel` | Helper opened a WebRTC DataChannel and passed helper frames | Product app control, product session keys |
| `TransportOnly` | A bound transport/control plane exists | Handshake, SBWC session keys, AppControl |
| `HandshakeEstablished` | MessageA/B/FIN1 completed and keys were installed | AppControl, persisted trust, UI composition |
| `AppControlReady` | Encrypted app-control ping/pong or equivalent app message passed | Persisted peer KEM trust, fresh-code product UX parity |
| `ProductRuntimeReady` | UI/agent/auth/settings/session state are composed into a live product flow | Lower proof states alone cannot imply this |

No lower state should be promoted to a higher state by wording, fallback, UI
labels, or acceptance scripts.

## Parity Matrix

| Area | Apple/Mac/iOS state | Windows state | Gap | Required Windows proof |
| --- | --- | --- | --- | --- |
| Device discovery | Apple has Bonjour/NWBrowser runtime paths and real-device projection. | Windows queries both control services, canonical `_skybridge-xfer._tcp` / `_skybridge-rd._tcp`, then legacy input aliases, and normalizes resolved product routes to canonical service/instance names. It has a native DNS-SD adapter, but default WinUI remains pending/read-only and the CLI projects snapshots. | Windows lacks default live discovery authority and acceptance-proven peer discovery. | Agent-owned fresh DNS-SD snapshot, identity dedupe, `-RequirePeer` evidence, and no connection authorization from discovery alone. |
| Discovery contract | Apple accepts several TXT aliases for identity fields. | Windows parser requires exact `deviceId` and `pubKeyFP` while defaulting other fields. | Shared contract drift can reject valid Apple advertisements or hide missing fields. | Shared schema tests and a contract decision on aliases versus strict names. |
| Handshake/session | Apple CLI/native docs describe state-dir sessions; Mac app uses `crossnet-control/1` for GUI truth. | Windows product-control handshake code is strong; `skybridge session import-product-control` can import validated RuntimeSmoke AppControl evidence into core-owned `runtime/sessions.json`, but CLI `connect` is still fail-closed and runtime proof remains script-gated. | The registry import starts one authority boundary, but no single live Windows agent owns the whole code/connect/session lifecycle. | `code create`, `connect`, session registry, peer identity binding, key install, and UI/CLI status from the same live authority, with AppControl import remaining a non-device bridge only. |
| PQ/PQC security | Apple has provider selection and strict PQC gates; fallback policy is explicit. | Windows product PQC provider requires PQC and disables classic fallback by default, but Rust CLI `pqc status` is diagnostic, and some core identity validation remains placeholder-level. | PQC diagnostics and transport smoke can be mistaken for product PQC proof. | Product handshake evidence with suite id, transcript binding, peer fingerprint, provider policy, and no silent downgrade. |
| File transfer | Apple/iOS WebRTC file-transfer paths require connected sessions, chunk ACKs, byte progress, and final SHA-256 completion ACK. | Windows CLI registers send requests only against a core-owned established product-control session registry; WinUI prepares file/share intents and QR preview without reading files or starting transport. | Windows file transfer is request/intent-only. | Live transfer worker, receiver policy, transferred bytes, ACKs, SHA-256 receipt, and failure artifacts. |
| Remote desktop/control | Apple remote-control stack has real connections, session keys, capture/input/video paths, notices, and performance gates. | Windows CLI registers requests only against a core-owned established product-control session registry; WinUI disables live start/fullscreen/disconnect and stores overlay/quality changes in memory. | Windows remote desktop is preview/request-only. | Live capture/input adapters, encrypted control/video channels, user notice lifecycle, performance evidence, and disconnect truth. |
| Account/auth | Apple auth and Keychain surfaces expose typed errors and strict load behavior. | Windows `SupabaseAuthClient`, `SessionStore`, and account coordination now return typed results for auth/network/server/storage failures, clear rejected persisted sessions, and block optimistic UI sign-in when live verification or persistence fails. | Real Windows DPAPI and live Supabase revocation behavior still need device/environment proof. | Run the contract tests plus Windows-hosted DPAPI, server-reject, revoked-session, and UI-hydration gates. |
| Settings/runtime truth | Apple settings feed runtime consumers and CLI snapshot allowlists. | Windows `SettingsStore`/`SettingsService` now distinguish trusted first-run defaults from corrupt/schema/invalid/import/save/reset failures, expose runtime truth, and avoid applying startup effects from untrusted settings. | Real Windows filesystem/permission proof and broader runtime consumer proof remain open. | Contract tests for missing/corrupt/schema/import/save/reset plus Windows-hosted permission and runtime-effect evidence. |
| CLI command surface | Apple CLI is a separate Clap crate with macOS-only `crossnet`; Mac app launch is separate. | Windows `skybridge` is a Rust core diagnostic/request CLI and explicitly reports `crossnet` unsupported on Windows. | Names overlap, but capabilities and authority boundaries differ. | Keep shared command names only where contracts match; expose unsupported/request-only/read-only status in `capabilities --json`. |
| Launch commands | Mac GUI launches through `run_app.sh` or `launch_with_env.sh`, not through the CLI. | Windows CLI binary can be `skybridge.exe`, but that does not launch the WinUI product runtime. | "Same command" is only true for CLI binary naming, not GUI/product launch. | Document `skybridge` as CLI name and keep GUI launch/package commands platform-specific. |

## Root Cause

The main gap is architectural, not cosmetic. Windows has transport and proof
building blocks, but it does not yet have a single product authority that joins
auth, settings, discovery, current-path admission, WebRTC transport, product
handshake, session registry, file transfer, and remote desktop state.

Secondary causes:

- Shared wire and operator contracts are split across Rust core, WinClient C#,
  runtime smoke programs, scripts, and docs.
- Some Windows product-layer code still uses null/default/best-effort error
  semantics where Apple uses typed errors or strict failure.
- Preview UI language can be read as stronger evidence than the code provides.

## 2026-08-11 Source Recheck: Prioritized Gaps

### P0: Default product composition is not live

- `WindowsNativeRuntimeDependencyFactory` defaults to
  `PendingWindowsTransportAdapterClient`; native DNS-SD is opt-in, and the
  current-path connector is composed in RuntimeSmoke rather than in the default
  WinUI product graph.
- Generate Code and Connect therefore remain snapshot/intent surfaces. They do
  not yet share the Apple implementation's live authority for admission,
  register/lookup, handshake ownership, key installation, route binding, and
  session lifecycle.
- The next implementation step is one product authority consumed by both WinUI
  and CLI. RuntimeSmoke remains an evidence harness, not the product owner.

### P0: File transfer and remote desktop stop at the action boundary

- `FileTransferWorkspaceClient` still uses in-memory selection/share intents;
  it neither reads nor sends the selected bytes.
- `RemoteDesktopWorkspaceClient` explicitly reports that capture, input
  forwarding, transport launch, live telemetry, full-screen lifecycle, and
  disconnect were not started.
- Apple currently has live WebRTC file messages with chunk/final receipt checks,
  plus approved remote-control input application and capture/video paths. The
  Windows acceptance target must prove the same effects and receipts, not just
  request registration or a connected control channel.

### P1: Ownership and module boundaries need consolidation

- `SessionViewModel` and `MainWindow.xaml` remain large composition surfaces,
  while account, settings, top-bar, discovery, and session state have more than
  one construction path. Typed auth results exist, but some UI integration paths
  still discard the richer result and retain only projected state.
- ContractTests compile linked production source files instead of referencing a
  separately buildable runtime/domain assembly. This catches many regressions,
  but it does not prove the exact product assembly graph.
- `WebRtcProductControlEngineClient.Dispose` synchronously waits for asynchronous
  cleanup. This should converge on explicit async ownership to avoid UI-thread
  blocking and shutdown deadlock risk.
- The Apple `CrossNetworkConnectionManager` is itself very large, so parity work
  should copy its contracts and proven state transitions, not reproduce its
  monolithic structure on Windows.
- The validated desktop layout now treats 1200/1280/1366 as logical dimensions
  and scales them to the current monitor DPI, but the fixed expanded navigation
  pane and two-column Dashboard can still clip below roughly 1060 logical pixels
  of window width. A future narrow-window contract should either enforce a
  minimum supported width or add coordinated navigation/Dashboard reflow; test
  scroll percentages must not substitute for that product decision.

## Architecture-Correct Implementation Order

1. Tighten account/session/settings truth first. Completed for the local
   non-device contract boundary in this worktree; still requires Windows-hosted
   DPAPI/Supabase/WinUI proof before release parity.
   - Replace null/no-throw and default-on-corruption persistence boundaries with
     typed results.
   - Preserve first-run default creation only for true missing-state cases.
   - Make corrupt files, DPAPI failure, permission failure, schema mismatch,
     save failure, reset failure, network reject, and revoked session observable.

2. Introduce one Windows agent/session authority.
   - Started for the non-device bridge: RuntimeSmoke AppControl evidence can be
     imported into the Rust core `runtime/sessions.json` authority through
     `--session-id-file`, the AppControl live scripts can create the protected
     short-lived session-id file when explicitly requested, and
     file-transfer/remote-desktop requests consume that same registry.
   - Own state-dir layout, auth/session snapshots, discovery snapshots, code
     snapshots, session registry, file-transfer requests, and remote-desktop
     requests.
   - Make CLI and WinUI consume the same authority rather than parallel state.

3. Promote discovery from read-only preview to agent-owned live discovery.
   - Wire `NativeWindowsDnsSdBrowseClient` behind the authority.
   - Require freshness, peer identity binding, duplicate handling, and explicit
     local-network acceptance evidence.

4. Promote `code create` and `connect`.
   - Route through current-path admission/register/lookup and verified peer
     identity.
   - Install session keys only after explicit suite policy and transcript
     binding.
   - Keep fresh-code classic authority bootstrap separate from trusted-KEM PQC.

5. Promote file transfer.
   - Move from intent/request registration to an agent-observed live worker.
   - Require manifest, receiver policy, transferred bytes, chunk ACKs, final
     SHA-256 receipt, cancellation/error artifacts, and history sourced from the
     live worker.

6. Promote remote desktop/control.
   - Add Windows capture/input/video adapters behind notice and permission gates.
   - Record live control state, FPS/latency, disconnect truth, and failure
     phases.

7. Extract shared contracts.
   - Keep protocol/wire/security contracts in shared core or generated schema,
     not duplicated in WinClient-only C# and CLI-only Rust paths.
   - Keep platform adapters below the product authority.

## Current Local Validation Notes

The 2026-08-11 dependency and parity pass produced the following local
evidence:

- The strict offline and online stack-freshness gates passed. The pinned stack
  matches the current stable upstream metadata: .NET runtime `10.0.10`, .NET
  SDK `10.0.302`, Windows App SDK `2.3.1`, Windows SDK BuildTools
  `10.0.28000.2526`, SIPSorcery `10.0.13`, Rust `1.97.1`, and
  cargo-llvm-cov `0.8.7`. QRCoder `1.8.0`, the Vortice rendering family
  `3.8.3`, directly consumed Vortice.Mathematics `2.1.1`, MsQuic `2.5.9`,
  and libdatachannel `0.24.5` remain current.
- All 55 repository PowerShell files passed AST parsing. The Windows workflow,
  command-gate, native-runtime-profile, startup-state, UI action-order, UI
  parity, acceptance-map, and FFI-client static gates passed.
- Rust `fmt`, all-target/all-feature `check`, and Clippy with `-D warnings`
  passed. The full suite passed 138 unit, 65 CLI, 15 FFI, and 3 state-machine
  tests (221 total). The clean coverage gate passed with no LLVM mismatch
  warning: `cli.rs` is 90.79% and the repository total is 91.89%.
- The production Rust dynamic library exports all 28 expected `skybridge_*`
  C ABI symbols; the unit-test harness exports none of those stable symbols.
  `cargo audit` found zero known vulnerabilities in 93 resolved packages.
- ContractTests built with warnings as errors and ran 73 passing cases.
  RuntimeSmoke and WebRtcHelper also built with warnings as errors. These
  macOS-hosted Windows-targeting builds reported zero warnings and zero errors,
  but they are not a substitute for the Windows-native WinUI build and launch
  lane recorded separately below.
- On the Windows 11 ARM64 validation VM, the x64 MSVC Rust lane passed `fmt`,
  all-target/all-feature `check`, Clippy with `-D warnings`, and 219 tests with
  zero compiler or linker warnings. ContractTests ran all 73 cases; RuntimeSmoke
  and the unpackaged WinClient built in Release with warnings as errors. The
  command-gates, native-runtime-profile, and connection-launch executable
  harnesses restored, built, and ran successfully with zero warnings and zero
  errors.
- Windows-native NuGet queries for WinClient, ContractTests, RuntimeSmoke, and
  WebRtcHelper all returned valid JSON with empty direct-outdated and
  vulnerable findings. Transitive-outdated output remains only inside the
  coordinated Windows App SDK, QRCoder, SIPSorcery, and Makaretu dependency
  graphs; those packages are not promoted to direct references because doing so
  would invoke NuGet direct-dependency-wins and make this project own unproven
  major-version combinations. The sole production-consumed transitive,
  Vortice.Mathematics, is now an explicit direct `2.1.1` dependency.
- The native Windows DNS-SD acceptance harness executed all six service queries
  and passed its adapter/lifecycle boundary with `peers=0`. This proves the
  native browse path can run, but not `-RequirePeer`, live Mac/iOS discovery, or
  product authorization.
- The Windows-native Release WinUI lane built with zero warnings and zero errors,
  launched the real unpackaged app, passed the runtime UI Automation bounds and
  order checks, and produced 16 verified screenshots plus its evidence manifest.
  Window sizing now converts requested logical dimensions through the live
  per-window DPI, fails before capture when the monitor work area cannot contain
  the requested evidence size, and verifies the actual physical bounds. On the
  200% validation desktop, the retained final process opened at 2400x1600
  physical pixels, exactly 1200x800 logical pixels, and remained responsive.
- The main WinClient restored successfully on macOS. Its XAML compiler cannot
  execute on macOS, so the Windows-native build, direct-package outdated audit,
  transitive-vulnerability audit, and desktop launch remain the authoritative
  WinUI evidence.
- Targeted tests against the read-only Apple source passed 23 cases: file
  progress truth, exact final bytes/hash acknowledgement, retry/cancel/owner
  enforcement, and approved remote-input application. These establish the
  mature Apple contract used by this audit; they do not prove Windows parity or
  physical iOS interoperability.
- Apple `python3 Scripts/check_protocol_parity.py` still fails on the current
  dirty Apple checkout because tracked protocol files have drifted from its
  recorded baseline. That checkout is therefore useful as live source evidence,
  but not as a clean protocol-parity certification baseline.

## Command Consistency Answer

`skybridge` is the stable CLI binary name on both sides, but the command
authority is not identical.

- Mac/Apple CLI: `skybridge` is a Rust CLI with native/headless state-dir
  commands, plus macOS-only `crossnet` commands that talk to the running Mac app
  over `crossnet-control/1`.
- Windows CLI: `skybridge` is currently a Windows protocol diagnostic and
  request-registration surface. It explicitly reports `crossnet` as unsupported
  on Windows and keeps many shared operator commands read-only, request-only, or
  planned fail-closed.
- Mac GUI launch: `run_app.sh` and `launch_with_env.sh` launch
  `SkyBridgeCompassApp`; they are separate from the CLI.

Therefore, CLI binary naming is consistent, but command implementation and
runtime authority are not yet consistent. A command name should be treated as
equivalent only when both sides expose the same authority boundary, mutation
semantics, proof state, and verification gate in their capability reports.

## Validation Lanes

Safe static Windows checks:

```powershell
pwsh -NoProfile -File Scripts/verify-windows-portability-acceptance-map.ps1
pwsh -NoProfile -File Scripts/verify-windows-powershell-ast.ps1
pwsh -NoProfile -File Scripts/verify-windows-ci-workflow.ps1
pwsh -NoProfile -File Scripts/verify-windows-portability-smoke.ps1 -AcceptanceEvidencePath artifacts/windows-portability-acceptance.json
pwsh -NoProfile -File Scripts/verify-windows-portability-acceptance-evidence.ps1 -AcceptanceEvidencePath artifacts/windows-portability-acceptance.json
pwsh -NoProfile -File Scripts/verify-rust-cli-coverage.ps1 -EvidencePath artifacts/rust-cli-coverage.json
```

Live Windows gates, only with prepared peers and credentials:

```powershell
pwsh -File Scripts/verify-windows-native-dns-sd-acceptance.ps1 -RequirePeer -ExpectedDeviceId <id> -ExpectedFingerprint <64hex> -EvidencePath artifacts/windows-native-dns-sd.json
pwsh -File Scripts/verify-windows-current-path-product-control-transport-live.ps1 ...
pwsh -File Scripts/verify-windows-current-path-product-control-appcontrol-live.ps1 ...
pwsh -File Scripts/verify-windows-current-path-product-control-answerer-appcontrol-live.ps1 ...
```

Apple comparison gates:

```bash
python3 Scripts/check_protocol_parity.py
swift test --filter SkyBridgeCoreTests.WebRTCOutboundFileTransferSupportTests
swift test --filter SkyBridgeCoreTests.FileTransferProgressTruthSourceContractTests
swift test --filter SkyBridgeCoreTests.SettingsRuntimeTruthSourceContractTests
bash Scripts/run_real_device_file_transfer_smoke.sh
bash Scripts/run_real_device_p2p_remote_smoke.sh
```

Passing Windows static checks alone is not product parity. Passing helper or
transport-only gates alone is not product parity. A parity claim needs matching
live Windows product evidence and Apple/Mac/iOS artifact evidence from the same
acceptance window.
