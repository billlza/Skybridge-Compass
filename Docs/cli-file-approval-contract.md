# CLI file approval integration

Status: the native Mac CLI → iPhone approval path is implemented and physically verified on development candidates. See [the candidate-bound validation record](cli-file-approval-validation-20260927.md). Initial receiver delegation still requires device confirmation; subsequent per-file allow/reject choices run in the terminal.

The receiver remains authoritative. A CLI decision may resolve a pending request only after the receiver has explicitly granted this paired identity permission to manage file approvals. Existing handshake-only grants do not gain this capability. Native grant storage is bound to the full protocol identity and has a separate scope.

The terminal shows the actual pending file name, byte count, receiver, and expiry, with Allow / Reject. No file bytes are released merely because a user chose Send. Decisions are bound to the current authenticated session, transfer UUID, receiver-issued pending-request UUID/nonce, and authenticated metadata digest. The receiver checks current trust, grant, expiry and unchanged request ownership before completing the existing approval continuation; the transfer's existing session revalidation and verified terminal receipt remain in force. A read-only list does not grant permission or approve a file. Disconnect, expiry, explicit rejection and outcome uncertainty are visible states.

Implemented interfaces:

- `crossnet file approval status --to DEVICE_REF --json`: inspect the separate grant and current pending request.
- `crossnet file approval authorize --to DEVICE_REF`: request explicit native file-management delegation once.
- `crossnet file approval decide --to DEVICE_REF --approval-id ID --decision allow|deny`: answer one receiver-owned pending request.
- `crossnet file approval revoke --to DEVICE_REF`: revoke that capability.
- Interactive `/send` displays the pending request and choice inside the same progress flow. JSON/noninteractive invocations require `--approval allow`, `--approval deny`, or `--approval device`; the default `prompt` requires a real terminal. Explicit decisions apply only to the pending transfer created by that invocation.

The native Mac operator service brokers signed paired-device management over the existing USB-first bounded transport, sharing the established identity/fingerprint validation and replay controls. There is no debugger or UI-automation fallback. Successful completion continues to require receiver acceptance and the file digest receipt; 100% sender progress is insufficient.

The authenticated approval-wait changes already present from the TIFS work are preserved. The iOS integration adds a narrow hook after metadata-MAC verification and uses the exact current connection generation, authenticated protocol fingerprint and file key. The diagnostic `sessionReference` is only a correlation field; it never substitutes for current private key/owner validation.

Current receiver scope: iOS native Classic file transport (including USB and LAN). The Mac sends and controls it through its native operator socket. Mac receiver and WebRTC prompts are not wired to this new remote-delegation registry: they return `file_approval_unavailable` rather than advertising a usable remote approval capability. Their existing local UI approval remains available. This limit must remain visible until those receiver owners have equivalent authority binding.

First grant choices: a ten-minute in-memory delegation or persistent Keychain delegation, plus reject. They do not accept files by themselves. Revocation from the device settings clears both the temporary and persistent grant. Restart clears temporary grants and pending request tickets; persistent grants remain bound to the full paired identity.
