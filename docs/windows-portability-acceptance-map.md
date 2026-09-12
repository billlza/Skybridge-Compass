# Windows Portability Acceptance Map

This map fixes the active Windows parity objective to auditable evidence. It is intentionally stricter than a plain build check: each requirement points to the script or artifact that must prove the claim, and local-only evidence remains opt-in when it requires a Mac, DNS-SD peer, WebRTC helper, GitHub write permission, or an interactive desktop.

| Requirement | Required evidence |
| --- | --- |
| `REQ-RESEARCH` mac/TDSC and ADR research is captured before Windows decisions | `docs/windows-architecture.md` records the current TDSC branch, current-path mac docs, ADR branch fallback, and source links. |
| `REQ-BEST-PRACTICE-RESEARCH` Windows stack, modularity, UI parity, Rust CLI, and Apple preservation decisions are tied to source-backed best-practice research | `docs/windows-research-agent-synthesis.md` records the best-practice research matrix with `checkedAtUtc`, `sourceUris`, `finding`, `decisionImpact`, and `staleRisk`; `Scripts/verify-windows-research-evidence.ps1` checks the matrix and source signals. |
| `REQ-SUBAGENT-SUMMARY` sub-agent collection and synthesis is documented before final parity claims | `docs/windows-research-agent-synthesis.md` records the three explorer reports, their agent IDs, scope, findings, and decision impacts; `Scripts/verify-windows-research-evidence.ps1` keeps the synthesis auditable. |
| `REQ-STACK` Windows stack is current and checked against primary sources | `Scripts/verify-windows-stack-freshness.ps1` checks project versions offline and supports `-CheckOnline -EvidencePath <json>` for .NET/NuGet/GitHub latest-version evidence. |
| `REQ-MODULARITY` Windows is modular around Core/service boundaries rather than page-local logic | `Scripts/verify-windows-ffi-client.ps1`, `Scripts/verify-windows-ui-parity.ps1`, `Scripts/verify-windows-native-runtime-profile.ps1`, and `Scripts/verify-windows-connection-launch.ps1` cover CoreBridge, dependency injection, runtime selectors, transport adapters, and fail-closed launch boundaries. |
| `REQ-UI` controllable UI parity matches mac positions and style contracts | Every local Windows validation round starts by building and launching the product app through `Scripts/verify-windows-ui-automation-smoke.ps1 -EvidenceDir <dir>` in an interactive desktop session. `docs/windows-ui-parity-matrix.md`, `Scripts/verify-windows-ui-action-order.ps1`, `Scripts/verify-windows-ui-parity-matrix.ps1`, `Scripts/verify-windows-ui-automation-smoke.ps1`, and `Scripts/verify-windows-ui-visual-evidence.ps1` cover button/function order, anchors, shared templates, runtime action bounds, the real WinClient window, File Transfer QR preview, and 16 screenshot artifacts. An SSH-only `dotnet build` is build preflight, not visual evidence. The visual evidence manifest must carry `repoBranch` and `repoHead`; acceptance/completion may use `-AllowStandaloneWinUiVisualEvidence` only when an interactive desktop task generated evidence for the same branch/head outside the non-interactive smoke process. Fonts, DPI, and platform pixel metrics remain out of scope. |
| `REQ-RUST-CLI` Rust CLI is reusable and keeps at least 90% line coverage | `Scripts/verify-rust-cli-coverage.ps1` runs `cargo fmt`, `cargo clippy`, `cargo test`, `cargo llvm-cov`, requires total and `cli.rs` line coverage at or above 90%, and records evidence JSON. The Windows `skybridge version [--json]` and `skybridge capabilities [--json]` reports must keep the `SkyBridge CLI` display name, stable `skybridge` binary name, operator parity status, `operator_gap_summary`, and transport-only `NotHandshakeProof` / `NotAppControlProof` / `NotMacProductAppProof` boundaries machine-readable. `operator_gap_summary` must enumerate the current Windows gaps for discovery, connect, PQC handshake, file transfer, and remote desktop without marking any of those live-proven. `skybridge pqc status [--json]` may report strict PQC suite-policy availability and missing handshake gates, while `skybridge pqc offer/select` may reuse the Core suite negotiation path; those commands are diagnostics only and must not verify peer identity, start a runtime, derive live session keys, create sessions, or establish SBWC. `skybridge evidence status --evidence <path> [--json]` and `skybridge remote-desktop status --product-control-evidence <path> [--json]` may read RuntimeSmoke current-path product-control evidence as a strict, read-only proof-boundary report; they must not start a runtime, register a request, echo the local evidence path, or treat AppControl evidence as file-transfer receipt, remote-desktop apply, Mac product-app observation, or persisted peer-trust proof. `device discover --nearby --state-dir <dir>` may read an agent-owned `runtime/nearby-discovery-snapshots.json` registry as a strict public, read-only snapshot projection; `device discover --nearby --scan --state-dir <dir>` only accepts a fresh `agent_owned_active_mdns_scan` snapshot and still reports `active_scan_started=false`. Discovery snapshot projection is not active DNS-SD browsing, connection authorization, PQC handshake proof, file-transfer proof, remote-desktop proof, Mac product-app observation, or peer-trust persistence, and stale/corrupt/missing registries fail closed without echoing state-directory paths or private locator material. `connect <code>` remains a Windows core CLI contract/fail-closed surface until a Windows agent or product runtime owns product sessions. `file send --state-dir <dir> <path> --to <peer> --session-id <id>` may register a request-only pending row only when an agent-owned session registry already contains an unexpired established product-control session with a verified remote device/protocol binding; `file history --state-dir <dir>` may read that request registry, but request registration/history is not agent observation, transfer start, transferred bytes, SHA-256 receipt proof, receive-policy proof, Mac product-app observation, or peer-trust persistence. `file receive` remains fail-closed until an agent-owned receive policy exists. `remote-desktop start|stop|set-* --state-dir <dir>` may register request-only pending rows only when an agent-owned session registry already contains an unexpired established product-control session; `remote-desktop status --state-dir <dir>` may read that request registry, but request registration is not live apply, agent observation, capture/input/video proof, performance proof, Mac product-app observation, or file-transfer receipt. Remote-desktop request-contract resolution IDs must match the Mac CLI bounded set `auto`, `1280x720`, `1920x1080`, `2056x1329`, and `2560x1440` without exposing `3840x2160` before sender-mode evidence; reports must not echo raw connection codes, local paths, state-directory paths, peer refs, session ids, SDP/ICE credentials, hashes, or key material. |
| `REQ-RUST-CLI-SESSION-INVENTORY` Rust CLI session inventory parity is read-only and redacted | `skybridge session ls --state-dir <dir> [--json]` and `skybridge session inspect --state-dir <dir> <id> [--json]` may project an agent-owned `runtime/sessions.json` registry as session inventory only. The commands must not acquire mutation locks, create sessions, disconnect sessions, start runtime work, authorize peers, or treat registry presence as live product-control proof. Reports must redact raw session ids and state-directory paths, expose `session_inventory_not_live_runtime_proof` and `raw_session_ids_redacted`, and fail closed for missing, stale, corrupt, unsafe, oversized, or unsupported registries with classified errors such as `session_registry_too_large`. |
| `REQ-RUST-CLI-SESSION-IMPORT` Rust CLI may import AppControl evidence into the core-owned session authority without claiming live file or remote proof | `skybridge session import-product-control --state-dir <dir> --evidence <path> (--session-id <id>\|--session-id-file <path>) --remote-device-id <id> [--target-runtime-id <id>] [--ttl-seconds <n>] [--json]` may upsert an established product-control session into `runtime/sessions.json` only after `RuntimeSmoke` evidence validates as `AppControlSbwcPingPong`, `SecureSessionState=Established`, `SessionIdSha256` matches the supplied raw session id or protected session-id file contents, `RemoteDeviceIdSha256` matches the supplied raw remote device id, and `RemoteProtocolPublicKeyFingerprint` is present and valid. The command must not echo raw ids, paths, hashes, fingerprints, SDP/ICE credentials, or key material; must reject transport-only evidence, missing fields, hash mismatches, stale TTLs, unsafe registries, ambiguous `--session-id` plus `--session-id-file` inputs, invalid secret files, and conflicting existing bindings fail-closed; and must report `session_id_file_used`, `target_runtime_id_provided`, `ttl_seconds`, `appcontrol_evidence_required`, `session_import_not_live_runtime_start`, `request_registered_not_live_transfer`, and `request_registered_not_live_remote_apply`. `Scripts/verify-windows-portability-smoke.ps1` records the redacted import report as `windows-current-path-product-control-session-import` or `windows-current-path-product-control-answerer-appcontrol-session-import` when the corresponding import switch is supplied; `Scripts/verify-windows-portability-acceptance-evidence.ps1 -RequireCurrentPathProductControlSessionImport` and `-RequireCurrentPathProductControlAnswererAppControlSessionImport` require those digest-checked reports. The raw session state directory is not an acceptance artifact. Downstream `file send` and `remote-desktop start|stop|set-*` remain request-only until agent observation and real-device transfer/remote gates pass. |
| `REQ-BASIC-SMOKE` CLI/basic operations and repository smoke paths are executable | `Scripts/verify-windows-portability-smoke.ps1` runs default static/service/CLI proof gates, including `Scripts/verify-windows-powershell-ast.ps1` for Windows PowerShell AST parsing of repository scripts. CI runs it with `-CiMode -CheckOnlineStackFreshness -IncludeRustCliCoverage`, and `Scripts/verify-windows-portability-acceptance-evidence.ps1` validates generated `gateResults`, evidence paths, artifact digests, branch/head metadata, optional 90% Rust CLI coverage evidence, online stack freshness evidence, WinUI visual evidence, native DNS-SD acceptance evidence, and real Mac interop evidence. |
| `REQ-PUBLIC-ARTIFACT-REDACTION` publishable Windows acceptance evidence must cite redacted public artifacts, not raw helper/session directories | `Scripts/verify-windows-public-artifact-redaction.ps1` scans only `.log`, `.json`, `.jsonl`, `.txt`, and `.csv` public artifacts, rejects denied raw paths such as connection-code/signaling/TURN/session-state files, rejects unsupported bundles such as dumps/pcaps/archives, rejects raw bearer/JWT/SDP/ICE/candidate/endpoints/local paths, and can write `windows-public-artifact-redaction` evidence JSON. `Scripts/verify-windows-portability-smoke.ps1 -RequirePublicArtifactRedaction -PublicArtifactPath <public-redacted-dir>` makes this a gate in the smoke package; `Scripts/verify-windows-portability-acceptance-evidence.ps1 -RequirePublicArtifactRedaction -PublicArtifactPath <public-redacted-dir>` re-scans before publishing. Raw current-path product-control, helper, and live-device directories remain private debugging artifacts unless this scanner passes on a redacted copy. |
| `REQ-APPLE-PRESERVATION` Windows interop must not break mac/iOS AppleNative behavior | `Scripts/verify-apple-native-preservation.ps1` proves Apple-to-Apple same-LAN/cross-NAT paths keep `AppleNative`, Windows-to-Apple uses WebRTC without Apple stream/datagram bindings, and Windows-to-Windows keeps MsQuic. |
| `REQ-NATIVE-DNS-SD` Windows native discovery must use the Win32 DNS-SD lifecycle without becoming the default before LAN proof | `Scripts/verify-windows-native-dns-sd-acceptance.ps1` exercises `NativeWindowsDnsSdBrowseClient` through browse, resolve, cancel, TXT parsing, record free, and instance free boundaries. `Scripts/audit-windows-portability-completion.ps1` requires this gate before reporting completion; `-RequirePeer` plus expected device identity remains the local-network proof before enabling the native provider by default. |
| `REQ-MAC-INTEROP` Windows-to-mac co-debugging is gated by direct LAN, pinned SSH host key, Mac Rust CLI smoke, DNS-SD, WebRTC proof, and launch smoke | `Scripts/prepare-mac-rust-cli-codbg.ps1`, `Scripts/verify-mac-rust-cli-codbg-wrapper.ps1`, and `Scripts/verify-windows-mac-webrtc-interop.ps1` define the local sequence. Real interop remains incomplete until direct LAN route, host-key pinning, helper proof, and expected identity evidence are available. |
| `REQ-CURRENT-PATH-APPCONTROL` Windows-to-mac product control must prove current-path admission, peer lookup, WebSocket bind, SDP/ICE bridge, PQC product handshake, installed session keys, and encrypted AppControl pong on the SBWC secure-envelope wire format | `Scripts/verify-windows-current-path-product-control-transport-live.ps1` is the transport-only gate and must still report `NotHandshakeProof=true`, `NotAppControlProof=true`, and `NotMacProductAppProof=true`. `Scripts/verify-windows-current-path-product-control-appcontrol-live.ps1` is the stronger trusted-KEM gate: it requires Windows current-path credentials, a Mac product connection code, expected Mac device id/fingerprint, and explicit out-of-band peer ML-KEM-768 public key material; then it records `AdmissionLookupBoundSdpIceProductControlHandshakeAppControlPong`, `NegotiatedSuiteWireId=0x0101`, verified responder identity/signature/Finished, `SecureSessionState=Established`, `PeerMlKem768PublicKeySource=operatorProvidedOutOfBand`, `PeerMlKem768PublicKeyServerAttested=false`, `AppControlPayloadFormat=SkybridgeSecureEnvelopeV1`, `AppControlCryptoFormat=SkybridgeSecureEnvelopeV1`, `AppControlSbwcEnvelope=true`, `AppControlSbwcCounterPresent=true`, `AppControlReplayProtection=sbwc-replay-window`, null legacy nonce/tag/AAD/layout fields, non-null `AppControlOutboundCounter`, `AppControlInboundCounter`, `AppControlSessionHash`, and `AppControlTranscriptPrefix`, `AuthenticatedAppControlPingPongProof=true`, `AppControlReceivedMessageKind=pong`, `RemoteProductAppObserved=false`, `PeerTrustPersistenceProof=false`, `NotMacProductAppProof=true`, and secret-redaction fields. When `-ImportProductControlSession -SessionImportStateDir <skybridge-current-path-product-control-session-state-*>` is explicitly supplied, the script asks RuntimeSmoke to write the raw session id only to a protected `--session-id-out` file, verifies `SessionIdSha256`, `RemoteDeviceIdSha256`, and `RemoteProtocolPublicKeyFingerprint`, calls Rust with `--session-id-file`, and records a redacted import report whose `session_id_file_used`, `session_import_not_live_runtime_start`, `request_registered_not_live_transfer`, and `request_registered_not_live_remote_apply` flags stay true. `Scripts/verify-windows-portability-smoke.ps1 -RequireCurrentPathProductControlAppControl` and `Scripts/verify-windows-portability-acceptance-evidence.ps1 -RequireCurrentPathProductControlAppControl` keep this proof separate from helper-only WebRTC, persisted peer-trust proof, product UI composition proof, SSH management-channel evidence, and the independent transport-only gate; the AppControl evidence's internal `ProductControlTransport` step does not mark `windows-current-path-product-control-transport` passed, and optional session import does not prove file-transfer bytes or remote-desktop apply. |
| `REQ-CURRENT-PATH-FILE-TRANSFER` Windows-to-mac product control may prove current-path encrypted FileTransfer receipt, but only in a separate offerer smoke package from AppControl because the remote connection code is one-time | `Scripts/verify-windows-current-path-product-control-file-transfer-live.ps1` requires Windows current-path credentials, a Mac product connection code, expected Mac device id/fingerprint, explicit out-of-band peer ML-KEM-768 public key material, and `FileTransferPayloadBytes` in the bounded 1..2048-byte range. The RuntimeSmoke profile is `current-path-product-control-file-transfer`; evidence must record `AdmissionLookupBoundSdpIceProductControlHandshakeFileTransferReceipt`, `fileTransferReceipt`, `NegotiatedSuiteWireId=0x0101`, `SecureSessionState=Established`, verified responder identity/signature/Finished, `FileTransferPacketType=FileTransfer`, `SbwcPacketType=FileTransfer`, `FileTransferSbwcEnvelope=true`, `FileTransferReplayProtection=sbwc-replay-window`, `AuthenticatedFileTransferReceiptProof=true`, `TransferRole=sender`, `ManifestFileCount=1`, positive matching `ManifestBytes` and `TransferredBytes`, `ChunkCount`, `ChunkAckCount`, `CompleteAckReceived=true`, lowercase SHA-256 `SentFileSha256`, `FileSha256Receipt`, `FileTransferSessionIdSha256`, and `FileTransferTransferIdSha256`, `ReceiptMatchesSentHash=true`, `ProductPayloadCountSource=runtime-smoke-filetransfer-exchange`, raw payload/path/signaling/SDP/ICE capture flags false, and `NotAppControlProof=true`. `Scripts/verify-windows-portability-smoke.ps1 -RequireCurrentPathProductControlFileTransfer -CurrentPathProductControlFileTransferEvidencePath <path>` and `Scripts/verify-windows-portability-acceptance-evidence.ps1 -RequireCurrentPathProductControlFileTransfer` validate this artifact. This is a current-path product data-plane receipt proof; it does not replace `windows-live-file-transfer`, request-history observation, Mac product-app observation, peer-trust persistence, or remote-desktop apply evidence. |
| `REQ-CURRENT-PATH-ANSWERER-TRANSPORT` mac/iOS-to-Windows product-control entry must prove Windows can register a current-path code, bind as the expected signaling role, answer remote SDP/ICE, and open the product-control DataChannel | `Scripts/verify-windows-current-path-product-control-answerer-transport-live.ps1` wraps the shared transport gate with `Role answer`. The RuntimeSmoke profile is `current-path-product-control-answerer-transport`, helper mode is `product-control-answer`, default `ExpectedBoundRole` is `responder`, and evidence must record `AdmissionRegisterBoundSdpIceProductControlAnswererTransportOpen`, `RegisterCode=true`, `RegisteredCodeLocalDeviceBound=true`, `RegisteredCodeRemoteInitiatorIdentityPresent=false`, `SignalingExchangeRole=answerer`, `HelperMode=product-control-answer`, `LocalSignalType=answer`, `RemoteSignalType=offer`, `RemoteSignalWaitType=offer`, `TransportOnlyDirection=answerer`, `ExpectedBoundRole`, `Role=answer`, `RemoteIdentitySource=operatorExpectedPeerNotServerAttested`, `NotRemoteIdentityProof=true`, `SecureSessionState=TransportOnly`, `ProductSendCount=0`, `ProductReceiveCount=0`, `NotHandshakeProof=true`, `NotAppControlProof=true`, and `NotMacProductAppProof=true`. RuntimeSmoke writes the registered code only when `--registered-code-out` is supplied, requires a fresh dedicated `skybridge-current-path-product-control-answerer-code-*` parent directory, creates the file with owner/Administrators/SYSTEM-only ACL on Windows, and prints the path, not the code, so terminal logs do not become code-bearing evidence. The wrappers also require `SignalingDir` to be a dedicated `skybridge-current-path-product-control-signaling-*` directory because SDP/ICE files can contain short-lived credentials. `Scripts/verify-windows-portability-smoke.ps1 -RequireCurrentPathProductControlAnswererTransport` writes `CurrentPathProductControlAnswererEvidencePath`, and `Scripts/verify-windows-portability-acceptance-evidence.ps1 -RequireCurrentPathProductControlAnswererTransport` keeps this transport-only proof separate from AppControl. |
| `REQ-CURRENT-PATH-ANSWERER-APPCONTROL` mac/iOS-to-Windows product-control must prove Windows can answer the current-path offer, verify the peer handshake, install responder session keys, receive encrypted SBWC AppControl ping, and return encrypted pong | `Scripts/verify-windows-current-path-product-control-answerer-appcontrol-live.ps1` is the stronger answerer gate above transport-only registration. It requires Windows current-path credentials, expected peer device id/fingerprint, local ML-KEM-768 decapsulation key material through `LocalMlKem768DecapsulationKeyBase64EnvVar`, matching out-of-band local ML-KEM-768 public key material through `LocalMlKem768EncapsulationKeyBase64EnvVar`, and a remote mac/iOS peer that sends a signed `MessageA` plus encrypted AppControl `ping` to the Windows registered code. The RuntimeSmoke profile is `current-path-product-control-answerer-appcontrol`; evidence must record `AdmissionRegisterBoundSdpIceProductControlAnswererHandshakeAppControlPong`, `HandshakeRole=responder`, `InitiatorIdentityFingerprintVerified=true`, `InitiatorSignatureVerified=true`, `ResponderFinishedSent=true`, `InitiatorFinishedVerified=true`, `SecureSessionState=Established`, `LocalMlKem768DecapsulationKeyInputPresent=true`, `LocalMlKem768EncapsulationKeySource=operatorProvidedOutOfBand`, `LocalMlKem768EncapsulationKeyServerPublished=false`, `AppControlPayloadFormat=SkybridgeSecureEnvelopeV1`, `AppControlCryptoFormat=SkybridgeSecureEnvelopeV1`, `AppControlSbwcEnvelope=true`, `AppControlSbwcCounterPresent=true`, `AppControlReplayProtection=sbwc-replay-window`, null legacy nonce/tag/AAD/layout fields, non-null `AppControlOutboundCounter`, `AppControlInboundCounter`, `AppControlSessionHash`, and `AppControlTranscriptPrefix`, `AuthenticatedAppControlPingPongProof=true`, `AppControlReceivedMessageKind=ping`, `AppControlResponseMessageKind=pong`, `RemoteIdentitySource=operatorExpectedPeerHandshakeVerifiedNotServerAttested`, `LocalMlKem768DecapsulationKeyCaptured=false`, `LocalMlKem768EncapsulationKeyCaptured=false`, `LocalMlKem768KeyPairVerified=true`, `RemoteProductAppObserved=false`, `PeerTrustPersistenceProof=false`, `NotMacProductAppProof=true`, `NotRemoteIdentityProof=false`, `NotHandshakeProof=false`, and `NotAppControlProof=false`. When `-ImportProductControlSession -SessionImportStateDir <skybridge-current-path-product-control-session-state-*>` is explicitly supplied, the script uses RuntimeSmoke `--session-id-out`, protected session-id file validation, Rust `--session-id-file`, and a redacted import report with `session_id_file_used=true` while preserving the same non-file/non-remote proof boundaries. `Scripts/verify-windows-portability-smoke.ps1 -RequireCurrentPathProductControlAnswererAppControl` and `Scripts/verify-windows-portability-acceptance-evidence.ps1 -RequireCurrentPathProductControlAnswererAppControl` keep this proof separate from answerer transport-only evidence, SSH relay evidence, product UI composition, and future peer-trust persistence; its internal `ProductControlTransport` step does not satisfy `REQ-CURRENT-PATH-ANSWERER-TRANSPORT`, and optional session import does not prove file-transfer bytes or remote-desktop apply. |
| `REQ-CURRENT-PATH-ANSWERER-FILE-TRANSFER` mac/iOS-to-Windows product-control must prove Windows can answer the current-path offer, verify the peer handshake, install responder session keys, receive encrypted SBWC FileTransfer payloads, and send an authenticated receipt | `Scripts/verify-windows-current-path-product-control-answerer-file-transfer-live.ps1` wraps the shared FileTransfer gate with `Role answer`. It requires Windows current-path credentials, expected peer device id/fingerprint, local ML-KEM-768 decapsulation key material through `LocalMlKem768DecapsulationKeyBase64EnvVar`, matching out-of-band local ML-KEM-768 public key material through `LocalMlKem768EncapsulationKeyBase64EnvVar`, `FileTransferPayloadBytes` as a max inbound payload bound, and a remote mac/iOS peer that sends signed current-path product-control handshake plus encrypted FileTransfer manifest/chunk/complete messages to the Windows registered code. The RuntimeSmoke profile is `current-path-product-control-answerer-file-transfer`; evidence must record `AdmissionRegisterBoundSdpIceProductControlAnswererHandshakeFileTransferReceipt`, `TransferRole=receiver`, `RemoteIdentitySource=operatorExpectedPeerHandshakeVerifiedNotServerAttested`, `CompleteAckSent=true`, positive matching `ManifestBytes`, `TransferredBytes`, and `ReceivedBytes`, `ReceivedFileSha256`, `ReceiptMatchesReceivedHash=true`, `AuthenticatedFileTransferReceiptProof=true`, `FileTransferSbwcEnvelope=true`, `FileTransferReplayProtection=sbwc-replay-window`, `ChunkAckCount` equal to `ChunkCount`, raw payload/path/signaling/SDP/ICE capture flags false, and local KEM key material captured=false. `Scripts/verify-windows-portability-smoke.ps1 -RequireCurrentPathProductControlAnswererFileTransfer -CurrentPathProductControlAnswererFileTransferEvidencePath <path>` and `Scripts/verify-windows-portability-acceptance-evidence.ps1 -RequireCurrentPathProductControlAnswererFileTransfer` validate this artifact. When multiple answerer gates run in one smoke package, each gate must use a distinct `CurrentPathProductControlAnswerer*ConnectionCodePath` because every registered code is one-time. This gate remains separate from `REQ-CURRENT-PATH-ANSWERER-APPCONTROL`, `windows-live-file-transfer`, Mac product-app observation, peer-trust persistence, and remote-desktop apply evidence. |
| `REQ-OPENSSH-PQ-KEX` Windows OpenSSH co-debug transport must prove actual PQ/hybrid KEX before it is treated as a hardened SSH channel | `docs/windows-openssh-pq-kex.md` defines the local-only evidence boundary. `Scripts/verify-openssh-pq-kex.ps1` requires a pinned host key, forces `mlkem768x25519-sha256` / `sntrup761x25519-sha512` only, parses `ssh -vvv` for the negotiated algorithm, and can write `artifacts\openssh-pq-kex.json`. This evidence is SSH management-channel proof only and does not satisfy WebRTC helper, WinClient runtime, Mac product AppControl, or peer-trust persistence gates. |
| `REQ-WINDOWS-REVERSE-SSH-RELAY` Windows reverse SSH relay must be pinned, least-privilege, and task-owned before it is treated as durable management-channel access | `docs/windows-reverse-ssh-relay-lifecycle.md` defines the local-only lifecycle boundary, and `docs/windows-stable-ssh-connection.md` defines the operator recovery sequence when the management channel is down. `Scripts/register-windows-reverse-ssh-relay-task.ps1` pins the relay host key, writes a gate-owned `known_hosts`, rejects broad private-key ACLs unless `-RepairPrivateKeyAcl` is explicit, installs the start script to `C:\ProgramData\SkyBridge\reverse-ssh-relay\bin`, keeps logs under a separate writable `logs` directory, and registers a least-privilege scheduled task. `Scripts/start-windows-reverse-ssh-relay.ps1` runs one fail-closed SSH process with `StrictHostKeyChecking=yes`, `UserKnownHostsFile=...`, `IdentitiesOnly=yes`, `IdentityAgent=none`, `UpdateHostKeys=no`, and `ExitOnForwardFailure=yes`. `Scripts/verify-windows-reverse-ssh-relay-lifecycle.ps1` records `taskActionExpected`, `taskActionFailClosed`, `taskPrincipalExpected`, `relayHostKeyPinned`, `identityFileAclOk`, `knownHostsAclOk`, `installedStartScriptAclOk`, `runtimeAclOk`, `startScriptInstalledAndCurrent`, `localSshEndpointReachable`, `sshProcessCount`, `sshProcessOwnerExpected`, and `accepted`. This follows the macOS-style source contract plus hash-verified runtime artifact pattern. This is not SkyBridge product transport evidence and does not satisfy WebRTC helper or Mac AppControl gates. |
| `REQ-WINDOWS-DIRECT-LAN-SSH` Mac-to-Windows management access on the same physical LAN must be independently pinned, source-bound, least-privilege, and live-proven before it is called direct-LAN SSH | `docs/windows-lan-ssh-lifecycle.md` defines a separate two-stage authority. Elevated Windows-local `Scripts/register-windows-lan-ssh-access.ps1 -VerifyOnly` is the single server-policy authority and can only emit private provisioning evidence with `accepted=false`; it checks the one built-in Microsoft-signed `sshd`, exact loopback plus numeric LAN listeners on port 22, source-bound LAN and relay accounts, public-key-only effective policy, no alternate key-command or user-CA source, exact key/config ACLs, a physical Private-profile interface, and an exact program/service/address/interface firewall rule with no broader active conflict. `Scripts/verify-windows-lan-ssh-lifecycle.ps1 -ServerAudit` binds that private registration audit to a fresh nonce and private artifact digest. The Mac live mode requires an independently supplied server-audit SHA-256, a pre-existing unique ED25519 durable host pin, an exact ED25519 client key, a numeric same-prefix route over the frozen physical `en*` interface with no gateway/tunnel/proxy/jump/fallback, `mlkem768x25519-sha256`, and an exact non-administrator account/SID plus `SSH_CONNECTION` tuple. Only the final composite may set `accepted=true`; registration, fixture evaluation, reverse relay, UU/proxy reachability, PQ KEX alone, and SkyBridge product-route evidence cannot. `Scripts/test-windows-lan-ssh-lifecycle.ps1` covers positive non-accepting fixtures, route/pin/key/admin/firewall/session negatives, public-evidence redaction, and the ban on host-key scanning or known-hosts writes. |
| `REQ-GITHUB-SSH` branch upload must avoid unstable GitHub HTTPS transport by default and provide a controlled fallback | `Scripts/ensure-github-ssh-remote.ps1`, `Scripts/verify-git-ssh-remote.ps1`, `Scripts/push-github-ssh.ps1`, `Scripts/push-github-gcm.ps1`, `.githooks/pre-push`, and `docs/github-ssh-transport.md` pin SSH remotes, known_hosts, fallback bundle creation, and an explicit Git Credential Manager HTTPS fallback with write-permission and fast-forward checks. |
| `REQ-GITHUB-UPLOAD` the dedicated GitHub branch must actually contain the accepted commit | `Scripts/audit-windows-portability-completion.ps1 -CheckRemoteBranch -AllowGitHubApiRemoteCheck` compares `billlza/Skybridge-Compass` branch `Bill/windows-portability` with the accepted local HEAD, using SSH `git ls-remote` first and the GitHub refs API when SSH authorization is unavailable; `-RequireComplete` fails until the remote branch, Mac SSH readiness, Windows-to-mac interop, current-path AppControl, current-path FileTransfer, current-path answerer transport, current-path answerer AppControl, current-path answerer FileTransfer, and both current-path session-import gates are complete. |

Current-path product-control transport, handshake, AppControl, and FileTransfer evidence must record `LateRemoteIceCandidateRelayCount` as a non-negative transport fact. The value is not a success shortcut; it only records how many remote trickle ICE candidates the server-backed bridge relayed into the helper signal file before the helper reported its product-control IPC ready state.

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

Before publishing or attaching any Windows acceptance artifacts outside the
private debugging context, scan the public redacted artifact package:

```powershell
Scripts\verify-windows-portability-smoke.ps1 `
    -RequirePublicArtifactRedaction `
    -PublicArtifactPath artifacts\public-redacted `
    -PublicArtifactScanEvidencePath artifacts\windows-public-artifact-redaction.json `
    -AcceptanceEvidencePath artifacts\windows-portability-acceptance.json

Scripts\verify-windows-portability-acceptance-evidence.ps1 `
    -AcceptanceEvidencePath artifacts\windows-portability-acceptance.json `
    -RequirePublicArtifactRedaction `
    -PublicArtifactPath artifacts\public-redacted `
    -PublicArtifactScanEvidencePath artifacts\windows-public-artifact-redaction.json
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

Require current-path product AppControl only when a Mac product peer has generated a live connection code and the expected peer identity/KEM material is available:

```powershell
Scripts\verify-windows-portability-smoke.ps1 `
    -RequireCurrentPathProductControlAppControl `
    -ImportCurrentPathProductControlAppControlSession `
    -CurrentPathLocalDeviceId <windows-device-id> `
    -ExpectedDeviceId <mac-device-id> `
    -ExpectedFingerprint <mac-protocol-fingerprint-hex> `
    -CurrentPathProductControlEvidencePath artifacts\current-path-product-control-appcontrol.json `
    -CurrentPathProductControlAppControlSessionImportStateDir artifacts\skybridge-current-path-product-control-session-state-offerer `
    -CurrentPathProductControlAppControlSessionImportEvidencePath artifacts\current-path-product-control-session-import.json `
    -AcceptanceEvidencePath artifacts\windows-portability-acceptance.json

Scripts\verify-windows-portability-acceptance-evidence.ps1 `
    -AcceptanceEvidencePath artifacts\windows-portability-acceptance.json `
    -RequireCurrentPathProductControlAppControl `
    -RequireCurrentPathProductControlSessionImport `
    -CurrentPathProductControlEvidencePath artifacts\current-path-product-control-appcontrol.json `
    -CurrentPathProductControlAppControlSessionImportEvidencePath artifacts\current-path-product-control-session-import.json
```

Require current-path answerer transport only when a mac/iOS product peer can send a live offer to the Windows registered code:

```powershell
Scripts\verify-windows-portability-smoke.ps1 `
    -RequireCurrentPathProductControlAnswererTransport `
    -CurrentPathLocalDeviceId <windows-device-id> `
    -ExpectedDeviceId <mac-or-ios-device-id> `
    -ExpectedFingerprint <mac-or-ios-protocol-fingerprint-hex> `
    -CurrentPathProductControlAnswererTransportConnectionCodePath "$env:TEMP\skybridge-current-path-product-control-answerer-code-transport-$([guid]::NewGuid().ToString('N'))\connection-code.txt" `
    -CurrentPathProductControlAnswererEvidencePath artifacts\current-path-product-control-answerer-transport.json `
    -AcceptanceEvidencePath artifacts\windows-portability-acceptance.json

Scripts\verify-windows-portability-acceptance-evidence.ps1 `
    -AcceptanceEvidencePath artifacts\windows-portability-acceptance.json `
    -RequireCurrentPathProductControlAnswererTransport `
    -CurrentPathProductControlAnswererEvidencePath artifacts\current-path-product-control-answerer-transport.json
```

Require current-path answerer AppControl only when a mac/iOS product peer can send a signed product-control handshake and encrypted AppControl ping to the Windows registered code:

```powershell
Scripts\verify-windows-portability-smoke.ps1 `
    -RequireCurrentPathProductControlAnswererAppControl `
    -ImportCurrentPathProductControlAnswererAppControlSession `
    -CurrentPathLocalDeviceId <windows-device-id> `
    -ExpectedDeviceId <mac-or-ios-device-id> `
    -ExpectedFingerprint <mac-or-ios-protocol-fingerprint-hex> `
    -CurrentPathLocalMlKem768DecapsulationKeyBase64EnvVar SKYBRIDGE_CURRENT_PATH_LOCAL_MLKEM768_DECAPSULATION_KEY_BASE64 `
    -CurrentPathLocalMlKem768EncapsulationKeyBase64EnvVar SKYBRIDGE_CURRENT_PATH_LOCAL_MLKEM768_PUBLIC_KEY_BASE64 `
    -CurrentPathProductControlAnswererAppControlConnectionCodePath "$env:TEMP\skybridge-current-path-product-control-answerer-code-appcontrol-$([guid]::NewGuid().ToString('N'))\connection-code.txt" `
    -CurrentPathProductControlAnswererAppControlEvidencePath artifacts\current-path-product-control-answerer-appcontrol.json `
    -CurrentPathProductControlAnswererAppControlSessionImportStateDir artifacts\skybridge-current-path-product-control-session-state-answerer `
    -CurrentPathProductControlAnswererAppControlSessionImportEvidencePath artifacts\current-path-product-control-answerer-appcontrol-session-import.json `
    -AcceptanceEvidencePath artifacts\windows-portability-acceptance.json

Scripts\verify-windows-portability-acceptance-evidence.ps1 `
    -AcceptanceEvidencePath artifacts\windows-portability-acceptance.json `
    -RequireCurrentPathProductControlAnswererAppControl `
    -RequireCurrentPathProductControlAnswererAppControlSessionImport `
    -CurrentPathProductControlAnswererAppControlEvidencePath artifacts\current-path-product-control-answerer-appcontrol.json `
    -CurrentPathProductControlAnswererAppControlSessionImportEvidencePath artifacts\current-path-product-control-answerer-appcontrol-session-import.json
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

For a manual local Windows validation round, run the app gate directly before the broader smoke package:

```powershell
Scripts\verify-windows-ui-automation-smoke.ps1 `
    -RepoRoot . `
    -Configuration Debug `
    -EvidenceDir artifacts\winui-smoke

Scripts\verify-windows-portability-smoke.ps1 `
    -RepoRoot . `
    -IncludeWinUiAutomationSmoke `
    -WinUiEvidenceDir artifacts\winui-smoke `
    -AcceptanceEvidencePath artifacts\windows-portability-acceptance.json

Scripts\verify-windows-portability-acceptance-evidence.ps1 `
    -AcceptanceEvidencePath artifacts\windows-portability-acceptance.json `
    -RequireWinUiVisualEvidence `
    -WinUiEvidenceDir artifacts\winui-smoke
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
