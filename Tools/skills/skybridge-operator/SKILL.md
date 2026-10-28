---
name: skybridge-operator
description: Operate SkyBridge through its CLI, distinguish app and headless runtimes, and verify device connections and file-delivery results.
---

Use the existing SkyBridge CLI. Resolve the executable from PATH or an explicitly
identified development candidate; do not choose a candidate by modification time.
Start with `skybridge version --json` and `skybridge capabilities --json`.

For operations on the running Mac app, use `crossnet` and first run
`skybridge crossnet preflight --json`. Check the reported app version, protocol,
auth/tenant readiness and enabled method. The separate headless `agent`, `session`
and `file` commands do not operate the Mac app or inherit its credentials.

Select nearby peers from a fresh app discovery snapshot:

```sh
skybridge crossnet nearby --scan-seconds 3 --json
skybridge crossnet connect-nearby DEVICE_REF --json
skybridge crossnet file send /absolute/path/file.bin --to DEVICE_REF
```

`DEVICE_REF` comes from `nearby`, not account-device listings or Xcode UDIDs.
Discovery is not authentication. Do not send until the selected peer's connection
result confirms authentication. Retain identity/trust rejections for diagnosis;
clearing pins, forgetting devices or switching cryptographic policy is not an
ordinary connection retry.

For a physical Apple USB cable, read `crossnet usb devices --json`; OS network
entries are excluded. `crossnet usb connect UDID --peer-id PEER_UUID
--expected-fingerprint FULL_FINGERPRINT --json` requires the device's existing
paired protocol identity. A USB serial/name is not that identity. Check the
returned `transport:usb`, `pqc:true`, suite and exact fingerprint. Use the returned
`device_ref` for file sends. Default nearby connections prefer an available USB
route; explicit USB connections never fall back to Wi-Fi. The file data socket
must use that authenticated USB session's advertised port and keys. Report the
actual transfer `transport`; do not infer it from a cable being attached.

`peer_pqc_suite_unavailable` means the peer could not supply the specifically
requested PQC KEM. Inspect both selected suites before proposing a policy change;
it does not authorize classic fallback, trust recovery, or a retry over Wi-Fi.
Do not replace this closed error code with arbitrary remote error text.

`usb_device_unavailable` means the specific physical cable target is absent.
Refresh `usb devices` and match its exact UDID. Do not substitute a different
iPhone/iPad or its network twin. Recheck installed app path/build and process
identity around physical tests; an install or process change invalidates any
assumption that a later failure came from the previously verified candidate.

`crossnet trust preview` reads real Keychain/mirror evidence without writes.
`crossnet trust recover` is a separate mutation requiring explicit user approval,
an exact preview digest, a fresh recovery UUID, the approved peer fingerprint,
and `--approve-mirror-retirement`. It verifies fresh peer proof, archives original
mirror bytes, and retires only approved stale mirror aliases while preserving
an existing Keychain authority. Stop on changed state, revocation or another
device's claim. Retain partial results and the archive; do not automatically
retry or treat a recovery result as an authenticated connection. Ordinary
connection failures do not authorize this recovery command.

In human mode, file progress is on stderr. Use `--progress always` for a redirected
progress log, or `--json` for one final machine-readable result; these explicit
modes are mutually exclusive. A full progress bar means bytes were sent. Claim
delivery only with `status:completed`, `success:true`, `receipt_verified:true`,
matching operation/peer/transfer references, exact byte counts and a SHA-256.
On timeout or a lost stream, retain the operation reference and report an
unconfirmed outcome. Do not automatically resend an uncertain write; this
development interface has no durable reconnectable CLI job handle.

Use `crossnet navigate` and `crossnet settings` only for their advertised
destinations and settings. Method availability and UI navigation do not prove a
working remote desktop, presented video frames, or accepted remote input.

The repository's `Tools/AppleDeviceOperator` is separate developer tooling using
`devicectl` and XCTest. Use it when physical UI testing is requested. It activates
the installed app and must preserve its data. An owner-approved UI Automation
grant may be reused, but is not a permanent product permission or an unrestricted
iOS shell. Normal product actions should use paired, scoped native services.

For development details and current acceptance gaps, inspect
`Docs/cli-v0.4.0-development.md` in the selected SkyBridge repository. Bind reported
results to the actual executable/app candidate and retained command output.

For a shared historical alias, do not infer that two stable IDs belong to the
same device. A read-only preview may use `--preserve-shared-peer-id UUID` to show
a narrower proposal. Executing that scope requires explicit approval of the
exact rows and the preserved peer. The native planner must keep its own records
unchanged and return `shared_peer_records_preserved:true` before a scoped recovery
can claim completion. Revocation and direct cross-identity claims still refuse.


### Native receiver approval (0.4.0-dev.7)

Interactive `/send` and `crossnet file send` show the actual receiver request. Scripts must set `--approval allow|deny|device`; JSON mode never invents a decision. `crossnet file approval status|authorize|decide|revoke --to DEVICE_REF` exposes the separate receiver-owned delegation. `decide` also requires `--approval-id ID --decision allow|deny`. Initial delegation needs explicit native consent, separate from the handshake grant; do not upgrade that grant silently. Only the iOS native file receiver currently implements remote approval; unavailable receivers must fail explicitly. A successful approval is not delivery: retain the terminal receiver receipt and digest check.

### Guided menus (0.4.0-dev.8)

For human operation, `skybridge tui` offers `/setting`, `/device`, `/usb` and `/file`. `/setting QUERY` searches categories and concrete functions. Numbered selection, `/back`, `/home` and `/refresh` retain the chosen device and make local-setting scope explicit. Settings writes require a chosen value and confirmation, then native runtime readback; identity settings remain read-only here. This menu only exposes the implemented operator scope, not every GUI setting.

For scripts, `crossnet usb connect-device UDID --to DEVICE_REF --json` resolves the app-owned discovery reference in the native runtime and uses only the selected physical USB route. Read `crossnet preflight --json` for `crossnet.usb.connect_device` support before invoking it. Do not infer trust from USB inventory or substitute another cable target on failure. Existing explicit peer-ID/fingerprint USB commands remain available when a discovery reference is unavailable. See `Docs/cli-menu-guide-20260927.md` for the candidate's menu and validation boundaries.
