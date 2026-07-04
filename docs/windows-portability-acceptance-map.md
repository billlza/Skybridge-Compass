# Windows Portability Acceptance Map

This map fixes the active Windows parity objective to auditable evidence. It is intentionally stricter than a plain build check: each requirement points to the script or artifact that must prove the claim, and local-only evidence remains opt-in when it requires a Mac, DNS-SD peer, WebRTC helper, GitHub write permission, or an interactive desktop.

| Requirement | Required evidence |
| --- | --- |
| `REQ-RESEARCH` mac/TDSC and ADR research is captured before Windows decisions | `docs/windows-architecture.md` records the current TDSC branch, current-path mac docs, ADR branch fallback, and source links. |
| `REQ-BEST-PRACTICE-RESEARCH` Windows stack, modularity, UI parity, Rust CLI, and Apple preservation decisions are tied to source-backed best-practice research | `docs/windows-research-agent-synthesis.md` records the best-practice research matrix with `checkedAtUtc`, `sourceUris`, `finding`, `decisionImpact`, and `staleRisk`; `Scripts/verify-windows-research-evidence.ps1` checks the matrix and source signals. |
| `REQ-SUBAGENT-SUMMARY` sub-agent collection and synthesis is documented before final parity claims | `docs/windows-research-agent-synthesis.md` records the three explorer reports, their agent IDs, scope, findings, and decision impacts; `Scripts/verify-windows-research-evidence.ps1` keeps the synthesis auditable. |
| `REQ-STACK` Windows stack is current and checked against primary sources | `Scripts/verify-windows-stack-freshness.ps1` checks project versions offline and supports `-CheckOnline -EvidencePath <json>` for .NET/NuGet/GitHub latest-version evidence. |
| `REQ-MODULARITY` Windows is modular around Core/service boundaries rather than page-local logic | `Scripts/verify-windows-ffi-client.ps1`, `Scripts/verify-windows-ui-parity.ps1`, `Scripts/verify-windows-native-runtime-profile.ps1`, and `Scripts/verify-windows-connection-launch.ps1` cover CoreBridge, dependency injection, runtime selectors, transport adapters, and fail-closed launch boundaries. |
| `REQ-UI` controllable UI parity matches mac positions and style contracts | `docs/windows-ui-parity-matrix.md`, `Scripts/verify-windows-ui-action-order.ps1`, `Scripts/verify-windows-ui-parity-matrix.ps1`, `Scripts/verify-windows-ui-automation-smoke.ps1`, and `Scripts/verify-windows-ui-visual-evidence.ps1` cover button/function order, anchors, shared templates, runtime action bounds, and 16 screenshot artifacts. The visual evidence manifest must carry `repoBranch` and `repoHead`; acceptance/completion may use `-AllowStandaloneWinUiVisualEvidence` only when an interactive desktop task generated evidence for the same branch/head outside the non-interactive smoke process. Fonts, DPI, and platform pixel metrics remain out of scope. |
| `REQ-RUST-CLI` Rust CLI is reusable and keeps at least 90% line coverage | `Scripts/verify-rust-cli-coverage.ps1` runs `cargo fmt`, `cargo clippy`, `cargo test`, `cargo llvm-cov`, requires total and `cli.rs` line coverage at or above 90%, and records evidence JSON. |
| `REQ-BASIC-SMOKE` CLI/basic operations and repository smoke paths are executable | `Scripts/verify-windows-portability-smoke.ps1` runs default static/service/CLI proof gates, CI runs it with `-CiMode -CheckOnlineStackFreshness -IncludeRustCliCoverage`, and `Scripts/verify-windows-portability-acceptance-evidence.ps1` validates generated `gateResults`, evidence paths, branch/head metadata, optional 90% Rust CLI coverage evidence, online stack freshness evidence, WinUI visual evidence, native DNS-SD acceptance evidence, and real Mac interop evidence. |
| `REQ-APPLE-PRESERVATION` Windows interop must not break mac/iOS AppleNative behavior | `Scripts/verify-apple-native-preservation.ps1` proves Apple-to-Apple same-LAN/cross-NAT paths keep `AppleNative`, Windows-to-Apple uses WebRTC without Apple stream/datagram bindings, and Windows-to-Windows keeps MsQuic. |
| `REQ-NATIVE-DNS-SD` Windows native discovery must use the Win32 DNS-SD lifecycle without becoming the default before LAN proof | `Scripts/verify-windows-native-dns-sd-acceptance.ps1` exercises `NativeWindowsDnsSdBrowseClient` through browse, resolve, cancel, TXT parsing, record free, and instance free boundaries. `Scripts/audit-windows-portability-completion.ps1` requires this gate before reporting completion; `-RequirePeer` plus expected device identity remains the local-network proof before enabling the native provider by default. |
| `REQ-MAC-INTEROP` Windows-to-mac co-debugging is gated by direct LAN, pinned SSH host key, Mac Rust CLI smoke, DNS-SD, WebRTC proof, and launch smoke | `Scripts/prepare-mac-rust-cli-codbg.ps1`, `Scripts/verify-mac-rust-cli-codbg-wrapper.ps1`, and `Scripts/verify-windows-mac-webrtc-interop.ps1` define the local sequence. Real interop remains incomplete until direct LAN route, host-key pinning, helper proof, and expected identity evidence are available. |
| `REQ-OPENSSH-PQ-KEX` Windows OpenSSH co-debug transport must prove actual PQ/hybrid KEX before it is treated as a hardened SSH channel | `docs/windows-openssh-pq-kex.md` defines the local-only evidence boundary. `Scripts/verify-openssh-pq-kex.ps1` requires a pinned host key, forces `mlkem768x25519-sha256` / `sntrup761x25519-sha512` only, parses `ssh -vvv` for the negotiated algorithm, and can write `artifacts\openssh-pq-kex.json`. This evidence is SSH management-channel proof only and does not satisfy WebRTC helper, WinClient runtime, Mac product AppControl, or peer-trust persistence gates. |
| `REQ-WINDOWS-REVERSE-SSH-RELAY` Windows reverse SSH relay must be pinned, least-privilege, and task-owned before it is treated as durable management-channel access | `docs/windows-reverse-ssh-relay-lifecycle.md` defines the local-only lifecycle boundary. `Scripts/register-windows-reverse-ssh-relay-task.ps1` pins the relay host key, writes a gate-owned `known_hosts`, rejects broad private-key ACLs unless `-RepairPrivateKeyAcl` is explicit, installs the start script to `C:\ProgramData\SkyBridge\reverse-ssh-relay\bin`, keeps logs under a separate writable `logs` directory, and registers a least-privilege scheduled task. `Scripts/start-windows-reverse-ssh-relay.ps1` runs one fail-closed SSH process with `StrictHostKeyChecking=yes`, `UserKnownHostsFile=...`, `IdentitiesOnly=yes`, `IdentityAgent=none`, `UpdateHostKeys=no`, and `ExitOnForwardFailure=yes`. `Scripts/verify-windows-reverse-ssh-relay-lifecycle.ps1` records `taskActionExpected`, `taskActionFailClosed`, `taskPrincipalExpected`, `relayHostKeyPinned`, `identityFileAclOk`, `knownHostsAclOk`, `installedStartScriptAclOk`, `runtimeAclOk`, `startScriptInstalledAndCurrent`, `localSshEndpointReachable`, `sshProcessCount`, `sshProcessOwnerExpected`, and `accepted`. This follows the macOS-style source contract plus hash-verified runtime artifact pattern. This is not SkyBridge product transport evidence and does not satisfy WebRTC helper or Mac AppControl gates. |
| `REQ-GITHUB-SSH` branch upload must avoid unstable GitHub HTTPS transport by default and provide a controlled fallback | `Scripts/ensure-github-ssh-remote.ps1`, `Scripts/verify-git-ssh-remote.ps1`, `Scripts/push-github-ssh.ps1`, `Scripts/push-github-gcm.ps1`, `.githooks/pre-push`, and `docs/github-ssh-transport.md` pin SSH remotes, known_hosts, fallback bundle creation, and an explicit Git Credential Manager HTTPS fallback with write-permission and fast-forward checks. |
| `REQ-GITHUB-UPLOAD` the dedicated GitHub branch must actually contain the accepted commit | `Scripts/audit-windows-portability-completion.ps1 -CheckRemoteBranch -AllowGitHubApiRemoteCheck` compares `billlza/Skybridge-Compass` branch `Bill/windows-portability` with the accepted local HEAD, using SSH `git ls-remote` first and the GitHub refs API when SSH authorization is unavailable; `-RequireComplete` fails until the remote branch, Mac SSH readiness, and Windows-to-mac interop gates are complete. |

Run the acceptance-map static gate:

```powershell
Scripts\verify-windows-portability-acceptance-map.ps1
Scripts\verify-windows-research-evidence.ps1
```

Run the repository smoke with evidence paths when producing a release/PR acceptance package:

```powershell
Scripts\verify-windows-portability-smoke.ps1 `
    -CheckOnlineStackFreshness `
    -IncludeRustCliCoverage `
    -StackFreshnessEvidencePath artifacts\windows-stack-freshness.json `
    -RustCliCoverageEvidencePath artifacts\rust-cli-coverage.json `
    -AcceptanceEvidencePath artifacts\windows-portability-acceptance.json
```

Validate the generated acceptance package before publishing it:

```powershell
Scripts\verify-windows-portability-acceptance-evidence.ps1 `
    -AcceptanceEvidencePath artifacts\windows-portability-acceptance.json `
    -RequireRustCliCoverage `
    -RequireOnlineStackFreshness
```

Require the Windows reverse SSH relay lifecycle only when the Windows machine owns the scheduled task and the relay host key is pinned:

```powershell
Scripts\verify-windows-portability-smoke.ps1 `
    -RequireWindowsReverseSshRelayLifecycle `
    -WindowsReverseSshRelayExpectedHostKeyFingerprint SHA256:<relay-host-key> `
    -WindowsReverseSshRelayEvidencePath artifacts\windows-reverse-ssh-relay-lifecycle.json `
    -AcceptanceEvidencePath artifacts\windows-portability-acceptance.json

Scripts\verify-windows-portability-acceptance-evidence.ps1 `
    -AcceptanceEvidencePath artifacts\windows-portability-acceptance.json `
    -RequireWindowsReverseSshRelayLifecycle `
    -WindowsReverseSshRelayEvidencePath artifacts\windows-reverse-ssh-relay-lifecycle.json
```

When WinUI automation ran from an interactive scheduled task instead of the non-interactive portability smoke process, validate that evidence explicitly:

```powershell
Scripts\verify-windows-portability-acceptance-evidence.ps1 `
    -AcceptanceEvidencePath artifacts\windows-portability-acceptance.json `
    -RequireRustCliCoverage `
    -RequireOnlineStackFreshness `
    -RequireWinUiVisualEvidence `
    -AllowStandaloneWinUiVisualEvidence `
    -WinUiEvidenceDir <interactive-winui-evidence-dir>
```

Run the completion audit before claiming the full objective is done:

```powershell
Scripts\audit-windows-portability-completion.ps1 `
    -AcceptanceEvidencePath artifacts\windows-portability-acceptance.json `
    -WinUiEvidenceDir <interactive-winui-evidence-dir> `
    -AllowStandaloneWinUiVisualEvidence `
    -CheckRemoteBranch `
    -RequireComplete
```
