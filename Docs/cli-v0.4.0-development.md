# CLI 0.4.0 development: native operations and Apple device automation

This is an unpublished development iteration. Existing dirty product work is
preserved. A command's presence, a unit test, and a physical-device result are
separate claims.

## Contract

- Keep `crossnet-control/1` as the authenticated, same-user Mac app interface.
  Nearby discovery/connection and file sending reuse the app's P2P and transfer
  services, identities, approval rules, and signed receipt validation.
- `crossnet nearby` returns app-observed peers; `connect-nearby` must verify an
  authenticated session, not merely an open TCP connection.
- `crossnet file send` reports preparation, bytes sent, waiting for receiver
  confirmation, and a terminal result. A full progress bar alone is not success.
  Success requires the exact transfer's verified receiver receipt and byte/hash
  match. Progress goes to stderr; JSON stdout remains one final result.
- The independent `file send` headless runtime remains explicitly separate.
  Its progress display must retain its existing verified-receipt completion gate.
- Apple development tooling uses `xcrun devicectl` for inventory/lifecycle and
  `xcodebuild`/XCUIAutomation for real UI interaction. It does not activate
  Device Hub or iPhone Mirroring. Xcode discovery does not prove UI automation.
  Fixture/reset UI tests cannot establish production transfer acceptance.
- Product use must not require Xcode, XCTest, Developer Mode, a test runner, or
  repeated UI Automation passcode prompts. XCTest is a development acceptance
  tool only. Production mobile actions should reuse the app's existing paired
  identity, authenticated transport, scoped permission decisions and native
  services; App Intents can expose supported local actions. This is not a grant
  to control other apps or bypass iOS background/lock-state restrictions.
- Remembered product authorization means a revocable, device-bound grant for
  specified actions, not an everlasting OS-level automation permission. The
  exact mobile action vocabulary, scope and lifecycle contract still need a
  reviewed implementation; this development helper does not implement them.
- Remote desktop interaction design remains under discussion. The proposed
  split is CLI session/control operations plus a native video viewer. A listener
  starting is not peer approval, a received frame, or working remote input.

## Validation ledger

Evidence is retained in `Artifacts/cli-040-development-20260926/`.

- Observed: Xcode 27.0 (27A266a), devicectl 642.16; physical iPhone and iPad
  discovered over local network with Developer Mode enabled.
- Existing Device Hub / iPhone Mirroring processes were already running when
  inspected. They were closed with the user's explicit permission. Both remained
  closed during the successful physical iPhone runs; this work did not reopen them.
- CLI: 351 unit tests, 11 JSON process tests and 34 Mac client tests passed.
  `cargo fmt --all -- --check` and strict Clippy (`--all-targets -- -D warnings`)
  passed. The candidate reports `0.4.0-dev.1` when invoked from `/tmp`.
- Swift: 66 focused operator tests passed, including receipt, stream binding,
  auth and socket contracts. SwiftPM also compiled the app. The existing duplicate
  rpath and pre-existing `.build/debug` symlink warnings remain recorded.
- Apple helper: eight contract tests passed. The signed physical runner completed
  one snapshot run and a separate nine-action navigation run after one device-side
  authorization. These are UI results, not file-delivery results.
- The native Mac build exposed an uninstalled Xcode 27 Metal Toolchain. After
  explicit user approval, Apple's component installer succeeded and
  `xcodebuild -showComponent MetalToolchain` reported build 27A266a installed.
- The native Xcode development app signed successfully, but its local entitlement
  set omitted the required shared Keychain group. The identity loader refused it;
  this did not prove stored identity corruption. It was stopped and retained as
  a rejected candidate. Its native resource layout also failed the release
  resource-bundle gate. No gate was weakened to accept it.
- The existing packaging workflow, with the existing Developer ID identity and
  matching product profiles, passed deep/strict signature, shared Keychain and
  resource checks. It restored the existing login without user re-entry. Live
  CLI preflight, settings read, file-page navigation and iPhone discovery passed.
- Nearby connection did not reach an authenticated state. During the attempts,
  the product recorded ML-DSA-65 authority-claim conflicts against active records.
  Trust records were not cleared or re-pinned to bypass this rejection. A local
  trust mirror was read only for metadata shape; it dated from May and is not
  treated as an authoritative snapshot of the current Keychain state.
- That failure exposed an operator error-mapping bug: a thrown nearby runtime
  error fell into the response-encoding error boundary. A regression failed on
  the old behavior and passed after mapping known runtime rejections to closed,
  non-secret reason codes. The transport and identity checks remain unchanged.
- The rebuilt, signed candidate `20260926161255` was launched and rechecked. It
  restored the existing app login, rediscovered the iPhone, and returned the
  actual `nearby_trust_preflight_failed` refusal instead of an encoding error.
- A live file command was rejected with `nearby_peer_not_authenticated` before
  creating a transfer. Positive receipt completion and terminal progress on a
  real transfer remain unverified. Earlier failures are retained in the evidence
  directory; this is not a completed file-transfer acceptance result.
- No release, publication, installed-product replacement, or security-policy
  change is implied by this development iteration.

The preceding candidate and selected source/binary identities are recorded in
`Artifacts/cli-040-development-20260926/validation-summary.json`. The signed Mac
development bundle is under `mac-packaged-candidate-r3/`; the CLI is under `bin/`.
Rejected earlier candidates remain evidence, not alternate accepted builds.
`Tools/skills/skybridge-operator/SKILL.md` is a validated repository-local skill
draft; it was not installed into the user's global skills directory.

### Follow-up: native trust loading and physical identity rejection

After the user reported no iPhone reinstall, identity reset or re-pairing, a
native Keychain regression established a separate product defect: the trust
loader combined password data retrieval with `kSecMatchLimitAll`, received
`errSecParam`, and treated that failure as no records. Two actual isolated
file-Keychain fixtures were successfully inserted, but the old reader returned
zero. The replacement enumerates metadata and persistent references, then reads
each exact item using the existing backend-bound reference policy. Both payloads
now round-trip, and an invalid query leaves the trust store unavailable instead
of empty and available. The test deletes only its own uniquely named fixtures.

The focused run passed 43 tests, and a separate trust/security run passed 39.
The new Developer ID candidate, build `20260926164053`, passed strict signature,
shared Keychain entitlement, profile and resource checks. Its binary SHA-256 is
`c1405b7056e9d55c2e7be6e0fa86fd4402e6440a83df3ef6ca1a5bab83a87e74`.
It restored the existing app login and discovered the physical iPhone. Evidence
is in `Artifacts/cli-040-identity-diagnosis-20260926/`, with the bundle under
`mac-candidate-r1/` and the source manifest in `source-identity-r2.json`.

The Keychain fix did **not** make the connection pass. The current candidate
verified the peer's PIB-1 candidate and reached local authority commit after
final-ACK verification, where active identity claims conflicted. The Mac already
has exact algorithm/fingerprint-bound `alwaysAllow` decisions for this iPhone;
this is not missing XCTest consent. Two Keychain additions were also rejected
for invalid local signatures; those logs alone cannot distinguish a legitimate
cross-device record from a damaged record.

No existing trust record, remembered approval, key or iPad association was reset
or replaced. The old mirror is a historical clue, not a complete live Keychain
snapshot. An approved current fingerprint does not prove continuity from a
different old key, and does not authorize automatic replacement of it. Real
file-receipt completion and live transfer progress remain blocked on authenticated
connection. See [the diagnosis and recovery constraints](iphone-trust-diagnosis-20260926.md).

## Commands in this candidate

```sh
skybridge version --json
skybridge capabilities --json
skybridge crossnet preflight --json
skybridge crossnet nearby --scan-seconds 3 --json
skybridge crossnet connect-nearby DEVICE_REF --json
skybridge crossnet file send /absolute/path/file.bin --to DEVICE_REF
skybridge crossnet file approval authorize --to DEVICE_REF
skybridge crossnet file send /absolute/path/file.bin --to DEVICE_REF --approval allow --json
```

The default human-mode progress view uses stderr when attached to a terminal.
`--progress always` gives line-oriented progress when redirected; `never` turns
it off. Explicit progress and JSON modes are mutually exclusive, so a JSON
consumer receives one final result or the existing structured stderr failure.
The headless `file send` command gains the same view while retaining its own
agent/session/receipt contract. It never selects the Mac app implicitly.

For the app transfer, a terminal success includes `success:true`,
`status:completed`, `runtime_target:mac_app_runtime`, exact operation/transfer
and peer references, byte counts, SHA-256 and `receipt_verified:true`. A stream
ending without that result is unconfirmed. The app cancels the owned transfer
on stream termination/deadline; that does not prove remote rollback. There is
no automatic resend. This first candidate has no reconnectable durable CLI job
handle and does not expose every application button.

## Physical Apple CLI observations

On 2026-09-26, `devicectl` launched the existing iPhone SkyBridge app and captured
its screen without opening Device Hub or iPhone Mirroring. Initial XCTest
attempts failed before test execution: an IDE channel disconnected, then UI
automation mode timed out. A captured screen established the concrete remaining
gate: iOS requested the device passcode to enable XCTest UI Automation.

The user completed the system authorization on the iPhone. A physical USB run
then obtained 142 real UI elements. A second independent XCTest session completed
nine requested operations: devices/files/remote/home tab taps, matching screen
assertions and a final snapshot. Both visual device tools remained closed. The
application process in the trace was the already-running production app; no
UITEST_RESET_STATE, guest fixture or mock transfer scenario was requested.

This demonstrates authorization reuse during the observed sessions, not permanent
authorization after a reboot, re-pairing, upgrade or OS policy change. The user
explicitly rejected XCTest as the normal product interaction path. The helper
therefore remains developer tooling, and its success is not a product transfer
or remote-desktop result.

One workflow defect was reproduced after closing Device Hub: inventory reported
`disconnected` even though a direct lock-state request succeeded. The helper now
performs a bounded live probe rather than treating a cached tunnel state as
device unavailability. A failed live probe still fails; it never falls back to
cached success.

## Production mobile authorization proposal

The desired user experience is a remembered, revocable pairing grant, with
separate scopes for device actions, receiving files, sending from user-selected
locations, and remote viewing/control. Existing pairing identity trust is not
blanket authorization for all these actions. Reuse the native app's verified
transport and current business services, with explicit operation results and
the same transfer receipt semantics. Do not introduce a second mobile Rust
runtime, copy device credentials, or use a test-mode bypass.

App Intents can expose supported local app actions to system clients; it does
not itself supply a Mac-to-iPhone authenticated transport or perpetual background
execution. The mobile production operation contract and its permission/lifecycle
checks are not implemented by this candidate.

Proposed interaction, for review rather than an implemented feature:

1. The user selects the two devices and confirms a pairing using the existing
   device identities and authenticated transport.
2. The receiving app presents the requested action scopes. Remember the accepted
   scopes against that peer identity in protected storage, with a visible revoke
   action. A trusted device is not implicitly approved for every operation.
3. Later CLI requests reuse that grant. Check the current peer identity, scope,
   request lifetime and operation state before calling the same native service
   that implements the app's UI action. Return the observed outcome, not a tap
   count or an echoed request.
4. Revocation, an unrecognized replacement identity or an expanded scope requires
   a new decision. OS-required consent and lock/background restrictions remain
   separate. In particular, this proposal does not grant arbitrary control of
   other iOS apps or silent system-wide screen/input access.

The desired promise is "remember the approved pairing and scopes while valid",
not "the operating system will never request consent again". A development
runner's reused UI Automation grant is not the credential for this product path.

References: [Apple AppIntent](https://developer.apple.com/documentation/appintents/appintent),
[intent authentication policies](https://developer.apple.com/documentation/appintents/intentauthenticationpolicy),
and [XCUIAutomation](https://developer.apple.com/documentation/xcuiautomation).

## Remote desktop discussion

Prefer a shared authenticated session with two clients: CLI commands for connect,
status, permission decisions and disconnect, plus a native viewer for video and
human input. An agent-oriented mode could request a bounded frame snapshot and
send scoped input against the same session. Listener readiness, peer admission,
first decoded/presented frame, and accepted input remain different states.
Terminal video is not required for this design. The viewer versus agent mode
priority remains a user decision; this iteration does not implement a new remote
desktop control path.


## USB development follow-up: 0.4.0-dev.2

The default nearby connection now tries an available physical USB route first.
OS multiplexer inventory excludes Wi-Fi entries even when they share a UDID.
A hardware-family match is only a routing hint: the stable peer ID, the selected
full fingerprint, signed PIB/SKR messages, current grants and strict PQC handshake
must still pass. An unavailable USB application port may select the ordinary
network route before authentication begins; a trust/protocol failure never retries
on Wi-Fi to bypass rejection. Explicit `usb connect` has no network fallback.

The native `/var/run/usbmuxd` client uses bounded plist frames, verifies response
version/type/tag and result, refreshes the ephemeral device ID on every dial,
and turns the accepted Connect socket into the existing protocol byte stream.
No Xcode runner, Device Hub, iPhone Mirroring, external proxy, or new global
software dependency is involved in the product USB path. The iPhone app must be
running and the operating system must allow the host/accessory connection.

File transfer has a separate data socket. Its USB route now uses the file port
advertised inside the authenticated encrypted control session, plus the key
material of that exact USB connection. Bonjour and a guessed file port are not
used for USB data. While a USB control session exists, the file route waits for
its service hint or fails; it does not silently send the file on a parallel LAN
session. CLI JSON returns `transport`, and the human progress view displays it.
Existing receiver receipt, exact bytes/hash and no-automatic-resend rules remain.

```sh
skybridge crossnet usb devices --json
skybridge crossnet usb connect UDID --peer-id PEER_UUID --expected-fingerprint FULL_FINGERPRINT --json
skybridge crossnet trust preview --peer-id PEER_UUID --expected-fingerprint FULL_FINGERPRINT --json
# Only for the separately approved, snapshot-bound stale mirror recovery:
skybridge crossnet trust recover UDID --peer-id PEER_UUID --expected-fingerprint FULL_FINGERPRINT --snapshot-sha256 PREVIEW_SHA256 --recovery-id FRESH_UUID --approve-mirror-retirement --json
```

The USB page now offers a paired-device picker and a real Connect action using
the same core as the CLI. It does not infer trust from the USB product name.
Recovery preserves an already-correct Keychain authority; it is not key rotation.
Fresh signed peer proof precedes archival and retirement of exact stale mirror
records. The immutable archive retains the original mirror bytes. Changed
snapshots, revocation, a newer mirror or an unrelated device claim refuse the
transaction. A partial recovery is returned as partial, with no connected-session
claim. A recovery ID is not an automatic-retry token.

Evidence: `Artifacts/cli-040-usb-recovery-20260926/`. Observed USB inventory and
opening the iPhone application port succeeded through both the OS protocol and
the production Swift transport. The old installed iPhone app closed the stream
before PIB; native Mac logs identify `FramedReaderError.peerClosed`. The matching
iOS source unconditionally discarded loopback inbound sockets. The development
fix admits these sockets to the existing bounded unauthenticated path and adds
an explicit signed requester self-identity rejection. This remains a causal
candidate until the updated physical app is tested.

The iPhone development candidate is 1.0.2 (14), Release configuration with a
development profile, stable application/keychain identity, verified Apple PQC SDK
symbols and unchanged build-input digest. It is not a clean-source release,
App Store submission or completed physical acceptance. At this checkpoint its
installation is awaiting user approval. Native Mac/Swift focused tests passed
22 cases after UI integration (the earlier transport/recovery/file suite passed
73); Rust passed 353 CLI tests, 11 process contracts and 39 client tests. Strict
Clippy and formatting passed. Real USB handshake, no-LAN operation and a live
file receipt/progress result remain open pending physical execution.


### Signed candidate checkpoint

Mac build `20260926184443` is running from `mac-candidate-r2/`. Its SHA-256 is
`7abe5e9df21af0141a25804c18507c1eb5200a64d36e81eb00f139d132e43fcd`;
strict/deep signing passed and its complete entitlements match the previous
accepted development candidate. The build-input digest did not change. The CLI
in `Artifacts/cli-040-usb-recovery-20260926/bin/skybridge` reports `0.4.0-dev.2`
from outside the repository. Live preflight reports all new methods, USB inventory
returns the physical iPhone, and CLI navigation presents USB management. Native
UI inspection confirmed the paired iPhone selection and enabled Connect button;
the button was not used to claim a connection.

The new native preview returns `cross_device_claim`, `writes_performed:false`,
and the exact same snapshot digest as before. The two directly targeted mirror
rows include a shared historical Bonjour association with another stable ID.
No trust recovery was executed, and the pairing policy digest remains unchanged.
The iPhone (14) candidate is ready but not installed; its original (13) app remains.
Both visual device tools remain closed. See `validation-checkpoint-r2.json` for
the complete machine-readable state and outstanding real-device gates.


### Physical USB admission repair verified

After explicit user approval, the signed iPhone 1.0.2 (14) candidate was installed
in place. `devicectl` read back build 14 at the new bundle URL and launched PID
32183 without resetting its container. The USB connect attempt at 17:53:01 UTC
now verified the PIB peer signature and sent confirmation before the unchanged
Mac authority-conflict refusal. This distinguishes the repaired inbound-loopback
admission defect from the remaining local trust conflict. The selected peer ID
and full protocol fingerprint were unchanged. No XCTest session was used.

The historical peer's two separate mirror records were then inspected read-only
and both local signatures verified. A narrower recovery proposal keeps these
records intact while retiring only the two directly targeted stale mirror rows.
`trust preview` / `trust recover` gain an explicit `--preserve-shared-peer-id`
scope. It cannot remove that peer's own authority, hide a revocation, or assert
that two stable IDs represent the same device. The resulting archive and return
value bind and verify preservation. Default recovery continues to reject shared
claims without the explicit scope. See `shared-alias-recovery-review.zh.md` and
its JSON counterpart for the reviewable live record hashes. Actual retirement
still requires confirmation of this shared-alias scope.

### Approved recovery and explicit suite failure (current checkpoint)

The user confirmed the exact shared-alias scope. Recovery
`37D946EE-ECC5-4D01-AEB2-8C5FAF3DE323` completed through the native operator,
retiring exactly the two reviewed mirror rows after fresh USB PIB proof and
snapshot revalidation. Independent archive/current-store comparison confirmed
all remaining rows, the historical peer and iPad were preserved. The existing
ML-DSA-65 fingerprint and pairing-policy digest were unchanged. See
`approved-recovery-execution-r1.json` and
`approved-recovery-independent-readback.json`; earlier pending checkpoints are
historical, not the current authorization or installation state.

The next USB attempt reached verified PIB/final ACK and then a signed KEM refresh
refusal: `missing_requested_pqc_kem`. Mac requests only Q-Periapt ABI2, while the
installed iPhone selects X-Wing. No suite preference or strict-PQC policy has been
changed to conceal this mismatch. CLI 0.4.0-dev.4 maps this specific wire refusal
through a typed native/client error to `peer_pqc_suite_unavailable`, with a fixed
message rather than arbitrary remote error text. It remains non-retryable on a
different transport. Unknown failures remain redacted.

Focused Swift tests passed 13 cases; Rust passed 354 CLI tests, 11 process
contracts and 41 client tests. Strict Clippy and formatting passed. These counts
overlap earlier suites and must not be added into a claimed aggregate. Candidate
Mac build `20260926204621` passed deep/strict signature, full entitlement equality
against r3, and unchanged selected source-input digests. Its binary SHA-256 is
`d679237d49775ff5e617e2c0b44821d4627ce5a6a291510ee8db48df649eafd9`.

A new XCTest read-only snapshot attempt timed out enabling automation and showed
the device passcode authorization sheet before any test action. Further XCTest
attempts were stopped. In contrast, official Xcode LLDB attached to the installed
development-signed iPhone build 14, read the two live preference booleans, and
detached normally without using XCTest. A Swift application-service expression
could not resolve `PQCCryptoManager`; therefore general app-method invocation is
not demonstrated. This debug workflow requires a debuggable signature and is
not a consumer release capability or permanent authorization.

Full USB PQC session, default USB preference with LAN present, operation without
a shared LAN, receiver-confirmed transfer and live terminal progress remain open.
The running signed r4 app and dev.4 CLI now returned this exact closed failure
from a real USB attempt (exit 1, `retryable:false`); stdout/stderr and command
metadata are retained in `usb-connect-live-closed-error-r4*`. This is live failure
propagation evidence, not a successful session. Suite alignment awaits the user's
explicit choice. Wi-Fi changes have separate
pending authorization. The prepared 97-byte and 16-MiB fixtures have not been sent.

### USB Q-Periapt and receiver receipt observed

The user approved testing X-Wing and Q-Periapt, ending with Q-Periapt on both
devices. Fresh inventory initially showed only the iPad on USB. No iPad operation
was performed; the user subsequently reconnected the iPhone. The first X-Wing
attempt stopped because the requested physical USB device was absent and is not
a failed cryptographic handshake. CLI 0.4.0-dev.5 adds the closed
`usb_device_unavailable` error across the native router and Rust boundary.
Unknown server text is still redacted. The added behavior passed 11 focused Swift
tests and 355 CLI, 11 process-contract and 42 client tests; strict Clippy and
formatting passed. Mac r5 packaging remains a separate gate.

With the exact build-14 binary UUID verified, LLDB successfully invoked the
iPhone's normal `PQCCryptoManager.applyProviderPreference(.qPeriaptBeta)` method
on the main actor. This uses production preparation, provider validation and
rollback, rather than editing raw defaults. The asynchronous operation's cache
result was independently retrieved with `devicectl` and reported completed,
`active_suite:qperiaptABI2PolicyBound`, `active_tier:qperiaptPQC`. The debugger
detached normally. Providing the matching Swift module directory resolved the
earlier public-service symbol lookup failure. An internal file-approval singleton
was optimized out; no claim of arbitrary method/button control follows.

At 2026-09-26 22:46:55 UTC, the native product USB connect returned
`authenticated:true`, `transport:usb`, `pqc:true`,
`negotiated_suite:Q-Periapt-ABI2-PolicyBound`, and the unchanged complete iPhone
fingerprint. No XCTest, Device Hub or iPhone Mirroring was used. The 97-byte
`usb-receipt-proof-20260926.txt` then completed with a verified receiver receipt,
exact bytes and SHA-256. An independent copy from the iPhone's Documents/Downloads
matched the original, and a device screenshot showed the completion notification.
See `usb-qperiapt-functional-checkpoint-r1.json`.

The 16-MiB progress test visibly showed byte count, percent, rate, ETA and USB,
then failed after 393216 bytes (2%). No success receipt or final receiver file was
observed. During follow-up the installed app URL changed from bundle directory
`1DD1FCFC-FB4F-4B9D-A038-E0C6173EEE21` to
`3B3B7ED5-9D46-40F9-AD71-B193F038906A`, and PID 32183 was replaced by 32344 while
the reported version remained 1.0.2 (14). This turn issued no install command.
That source/process change prevents attributing the failure to a transport defect
without further evidence. No automatic resend or phone overwrite was attempted.
Host CoreDeviceService logs subsequently identified the replacement as the TIFS
`normal-app-service-results/2026-09-26-v1/ios-sign1` candidate. Installation began
at 22:49:18.505 UTC, about 11 seconds after the 22:49:07.562 transfer failure.
It therefore explains the later process change, not the initial timeout. The
failed transfer remains an unresolved counterexample; the later receiver state
cannot establish the old process's approval/cleanup behavior. Further phone
mutations are deferred while concurrent device use is being clarified.

X-Wing, complete large-file progress, automatic USB preference and no-shared-LAN
acceptance remain open; the latter still has separate pending Wi-Fi authorization.

The signed r5 app's live absent-device negative test did not return the new USB
code despite unit passes: identity preflight wrapped the transport exception as
a trust failure before the router saw it. `P2PDiscoveryError.preflightFailure`
now preserves typed USB errors at that actual boundary; ordinary protocol
failures retain the trust-preflight classification. This fixes error propagation,
not authentication or routing policy. The failed r5 result is retained in
`usb-missing-device-live-r5-red.json`. Signed r6 build `20260927001142` passed the
same live negative test and returned `usb_device_unavailable`, exit 1 and
`retryable:false`; `usb-missing-device-live-r6.json` records the result. The absent
UDID is an explicitly synthetic fixture, not an actual device operation. Twelve
focused Swift tests passed. Source digests were stable through packaging and
deep/strict signing plus complete entitlement equality against r5 passed. The
Mac binary SHA-256 is
`bac88b85bce5fd8f0f10630513dd7f94577b9bc6765b95d0ba3872a6e591dbee`.

The installed TIFS artifact identified by the host log has executable SHA-256
`0a71b509c916e0ab7dc244c64a923bd5e6ebc08b3526a9bac966a15b48d26692`, UUID
`D7370217-339D-3DC6-A9FE-0548FCDC22CD`, and `get-task-allow:false`. These are
read-only local artifact facts; the new remote process was not attached. Unlike
the earlier debuggable build-14 candidate, it cannot use the tested LLDB mutation
workflow. The user has been asked to apply X-Wing through the ordinary iPhone
settings screen. Until that action is observed, stored preferences remain
Q-Periapt on both devices and the X-Wing matrix stays open.


## 0.4.0-dev.6 — native handshake configuration

`skybridge tui` now provides `/handshake`; scripted callers use `crossnet handshake list/status/set/revoke`. The native Mac/iOS management endpoint supports explicit local/both scope, USB identity targets, per-peer consent, revision checks, provider read-back and optional verified reconnect. See [the command and authorization contract](cli-handshake-management.md). Classic remains disabled by strict PQC. Candidate identities and the installation/real-device acceptance gates are separate, under `Artifacts/handshake-cli-20260927/`.


## 0.4.0-dev.7 — file approval in the terminal

`/send` now reads the receiver's actual pending request and offers allow/reject before data is released. `/approvals` lists and handles pending requests. File approval delegation is separate from handshake-configuration permission; one-time native consent can grant ten minutes or persistent permission to this exact paired identity. Each file still requires a decision. Status, authorize, decide and revoke are available under `crossnet file approval`.

The default `--approval prompt` requires an interactive terminal. Scripts must explicitly select `--approval allow`, `--approval deny`, or `--approval device`; JSON mode does not guess a decision. A CLI choice requires the receiver's acknowledgement, and transfer completion still requires a separately verified SHA-256 receipt. Current receiver support and the session/metadata binding are documented in [the file approval contract](cli-file-approval-contract.md).

Build, physical-device and receipt evidence are recorded separately in `Artifacts/cli-file-approval-20260927/`. Candidate source/identity records remain in `Artifacts/handshake-cli-20260927/`.

## Guided terminal menus: 0.4.0-dev.8

`skybridge tui` now has `/setting` (eight native UI categories), keyword search,
`/device`, `/usb` and `/file`, with numbered choices, breadcrumbs and preserved
target selection. Settings show current values and confirm a proposed change
before native apply/readback. Eight settings are writable; identity preferences
remain read-only. This is an operator coverage menu, not complete GUI parity.

The new `crossnet usb connect-device UDID --to DEVICE_REF --json` uses a selected
app device reference and an explicit USB-only route. The native owner continues
to validate peer identity, current trust, PQC and post-handshake readiness.
No long protocol identity fields need to be entered in the guided USB menu.

See `Docs/cli-menu-guide-20260927.md` and
`Artifacts/cli-menu-20260927/verification-final.json` for exact candidate identities,
settings cancellation/persistence/restoration, physical USB and transfer evidence.
