# CLI 0.4.0-dev.7 file approval validation

The native Mac CLI → iPhone file-approval workflow is physically verified on the development candidates below. This is not a general UI automation or public-release acceptance claim. Raw commands, failures, signatures, source digests and receipts remain in `Artifacts/cli-file-approval-20260927/verification-final.json` and its referenced records.

## Exact candidates

| Component | Version | Executable SHA-256 |
| --- | --- | --- |
| Mac r10 | 1.0.2 (20260927110251) | `1d760e78a23aa2937f482b27931f532d3cca57d77c26c9296334aeed1b3c1dfa` |
| iPhone r9 | 1.0.2 (21) | `062e5a7bef78fa42adb8e93edeb0b365eb83b4e4ec20a9ccded908f063a393b2` |
| CLI | 0.4.0-dev.7, debug development build | `9efc682079d4be059f46b3f50de15f580e38567fd57dcd4ddf4551f87969f325` |

Both native packages passed deep/strict signature verification and retained the previous candidate's entitlements. The iPhone distribution app has `get-task-allow=false` and was updated in place. Build input digests remained stable. The Mac runs from `Artifacts/handshake-cli-20260927/mac-candidate-r10/`; the CLI is at `Artifacts/cli-file-approval-20260927/bin/skybridge` and is not installed globally.

## Implemented workflow

- `/send` presents the receiver-owned file name, size, SHA-256 and allow/reject choice. `/approvals` lists the current grant and pending files.
- `crossnet file approval status|authorize|decide|revoke` provides structured control; noninteractive sends require an explicit `--approval allow|deny|device` choice.
- File-management delegation is separate from the prior handshake grant. Ten-minute and persistent native consent are available. This iteration still requires receiver confirmation for the first delegation; it does not implement a unified first-pairing permission flow.
- The receiver binds each decision to the authenticated sender identity, exact current session owner/key, transfer ID, metadata digest, nonce, native continuation and expiry.
- File completion remains a separately verified receiver digest receipt. Unknown grant state on failure is not reported as denied permission.

## Final physical results

The iPhone was launched normally, without console environment overrides, XCTest, a debugger, Device Hub or iPhone Mirroring. The final runtime inventory found only the intended Mac candidate among those app processes.

| Scenario | Observed result | Evidence |
| --- | --- | --- |
| Consecutive X-Wing → ML-KEM → Q-Periapt changes, each immediately followed by a CLI-approved transfer | All three negotiated the requested suite over USB and returned verified receiver receipts; independent file readbacks matched SHA-256 | `build21-pair-matrix.json`, `build21-matrix-readback-proof.json` |
| TUI `/devices`, `/send`, allow | 16,777,216 bytes, visible progress, distinct waiting-for-receipt state, explicit completed notification; independent readback SHA-256 matched | `tui-final21-file-progress.terminal`, `final21-large-and-denial-proof.json` |
| CLI reject | `file_approval_denied`, zero payload bytes, no receiver file | `final21-denied.json`, `receiver-files-final21.json` |
| Replay completed approval | `file_approval_no_longer_pending`; grant state remains unknown (`null`) rather than falsely reporting revocation | `final21-replay-completed.json` |
| Normal iPhone app restart | PID 32894 → 32896; a fresh USB handshake and signed status returned file delegation authorized without another device prompt | `iphone-restart-21-normal.json`, `final21-restart-connect.json`, `final21-restart-file-grant.json` |
| Final state | Both configured Q-Periapt; actual authenticated session Q-Periapt/USB; both grants retained | `final21-handshake-status.json` |

The large file's source, receiver receipt and independent readback digest are `bffa1102b847f838193f6e76eff16de56026f15ed324a75d6752a8c343b8a15f`. Its transfer ID is `C84B806D-CAEC-43BE-9BE2-CAF000EAF362`. App restart reuse does not establish persistence across an iPhone OS reboot.

## Root causes and retained earlier observations

`Artifacts/cli-file-approval-20260927/` contains the machine-readable records and terminal transcripts.

- Persistent file delegation survived iPhone process restart without another prompt (`persistent-file-grant-proof.json`).
- A real terminal rejection prevented receiver file creation. The initial run exposed an omitted authenticated approval capability; the repaired run sent zero payload bytes (`deny-wait-gap.json`, `receiver-after-delayed-deny.json`).
- Holding a terminal prompt exposed progress-reader backpressure. With a latest-value reader, a 50-second command finished with the correct zero-byte rejection instead of losing its final event (`progress-wait-gap.json`, `delayed-deny-fixed.json`).
- On Mac r5 / iPhone build 18, normal TUI operation transferred 16 MiB over Q-Periapt/USB. Independent device-container readback matched SHA-256 (`normal-large-transfer-proof.json`). A normal JSON send returned completed/success/receipt_verified and the digest (`current-json-transfer.json`).
- First connection after app restart worked, while some subsequent profile changes left file metadata unavailable. `current-owner-root-cause.json` records the iOS cleanup path that removed the active handshake owner and restored only part of it. The repair preserves the current owner and removes partial restoration. Build 19 profile transfers/readbacks and the final build 21 matrix passed.
- Repeated status reads allocated new mutation challenges until the eight-per-identity limit was reached. Status now reuses an unconsumed challenge only for the exact identity, target fingerprint and configuration revision. Expiry, single-use consumption, CAS and capacity limits remain. The old implementation failed the regression; the new one passed. Build 20 also served 24 consecutive physical signed status reads (`status-burst20-readback.json`).
- Immediate management requests could arrive during a second pairing-identity commit. The receiver correctly hid uncommitted trust, but management incorrectly interpreted this as `peer_untrusted` and closed the channel. Build 20 logs captured `authorityReadable=false` immediately before the commit completed. Management now waits at most eight seconds for the existing live mutation owner, then performs a strict current-state trust read. It does not recover an abandoned journal, reuse cached trust, resend a mutation or bypass revocation (`management-trust-read-root-cause.json`). The identical immediate-operation pattern passed on build 21.
- Mac connect/reconnect completion now waits for the exact current session's accepted pairing identity, with unchanged connection/key checks and an eight-second deadline. A connected transport alone is not reported as ready for file use.

## Checks run

- `SKYBRIDGE_PACKAGE_CONTEXT=app swift test --jobs 4 --filter 'ClassicTransferApprovalOwnerTests|ClassicTransferApprovalTests|ClassicTransferApprovalVectorTests|ClassicTransferCapabilityEvidenceTests|HandshakeConfigurationTests|HandshakeTransferBusyTests|OperatorNearbyFileTests|RemoteFileApprovalRegistryTests|RemoteFileApprovalServiceTests'`: 59 passed (`swift-final-contracts.log`).
- Rust CLI, process-JSON and client suites: 359 + 12 + 48 passed; strict Clippy passed (`rust-tests-peer-ready.log`, `rust-clippy-peer-ready.log`).
- Client crate compilation passed for Windows x86_64 MSVC and Linux x86_64 GNU. This is not whole-CLI or remote-device runtime validation.
- A retained host harness compiled the exact production mutation-barrier code with Swift 6 warnings as errors, checking fresh-state reads, timeout, cancellation and propagated read failure. Its permit/journal stand-ins do not establish persistence correctness; physical validation is recorded separately (`authority-wait-host-check.json`).
- Signed native build commands, source manifests and results are retained under `Artifacts/handshake-cli-20260927/`. Scoped `git diff --check` passed. The pre-existing `.build/debug` symlink warning remains recorded; no new build warning was suppressed.

## Scope and remaining checks

The remote approval receiver currently covers iOS native Classic file transport, including USB. Mac receiver and WebRTC remote approval explicitly remain unavailable. No Wi-Fi-disabled physical comparison has been performed. Remote desktop and a unified first-pairing permission flow remain separate product work.

No global CLI installation, iPad modification, commit, push, public release or notarization was performed. Candidate validation is complete only for the stated native iPhone approval scope. Remaining product scope is not hidden by the passing matrix.
