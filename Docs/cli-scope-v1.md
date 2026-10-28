# SkyBridge CLI Scope v1

## 0.4.0-dev.1 development work

The current workspace adds app-owned nearby discovery/authentication and
receipt-gated file sending with terminal progress. See
[the development ledger](cli-v0.4.0-development.md) for source, runtime and
physical-device validation boundaries. Apple XCTest tooling under
`Tools/AppleDeviceOperator` is for development acceptance only; it is not a
production mobile operator or an end-user dependency.

## Windows public CLI 0.3.3 development adapter

The Windows public build adds `skybridge app` for explicit selection of the
running WinUI instance, local status, confirmed appearance settings and host
listener start/stop. Its PID-bound local IPC reuses the existing App owners.
It is separate from the Windows Core diagnostic CLI and from headless commands.
Native Windows acceptance remains incomplete after the actual candidate build
was rejected by Code Integrity. See [0.3.3 validation](cli-v0.3.3-windows-validation.md)
and ADR-0003; process discovery, unit tests and a valid ADR are not live App proof.


Current-source review: 2026-09-13. [ADR-0003](ADR-0003-Native-Runtimes-and-Operator-Contract.md)
owns runtime selection, public/diagnostic CLI identity and completion semantics.
Earlier disabled-state descriptions have been replaced by the current source
status below; installed-app capability negotiation and release evidence remain
separate from the presence of a CLI handler.

## Product Definition

SkyBridge CLI has two explicit operator surfaces:

- **Mac app control surface**: app-bound commands that call the running
  SkyBridge Compass Pro macOS app through `crossnet-control/1`. These commands
  may change the Mac GUI/WebRTC runtime only when the Mac app itself has a
  loaded auth session and tenant binding. iOS is not a Rust CLI control target;
  the iOS app has no terminal-hosted operator surface, so CLI work there is
  limited to shared protocol compatibility and regression coverage.
- **Native/headless surface**: scriptable commands backed by Rust `state_dir`
  and `skybridge-agent`. These commands are protocol-faithful, but they do not
  read, copy, or replace the Mac app Keychain/auth session.

The native/headless surface is for:

- device identity and enrollment
- connection establishment and session visibility
- file transfer
- diagnostics and automation

It is not a CLI skin over the GUI, and it is not a general-purpose SSH replacement.
When an operator action is expected to affect the Mac GUI runtime, the command
must be app-bound (`skybridge crossnet ...`) or fail closed. Native CLI auth is
not a fallback for Mac app auth.

## v1 In Scope

- `skybridge-agent` as the long-running headless peer/runtime
- `skybridge` as the operator-facing command line
- `skybridge crossnet ...` as the Mac app-bound cross-network control surface.
  The Rust client, wire contract, and Mac app `crossnet-control/1`
  socket server source exist. `crossnet preflight` is the explicit
  macOS-only readiness check for protocol/auth/tenant state. `crossnet status`
  can read one redacted Mac app status snapshot. `crossnet settings` can read
  one allowlisted, non-secret Mac app settings snapshot, and
  `crossnet settings set` can mutate the smaller typed allowlist with runtime
  read-back. Session mutation, navigation and status watch are implemented in
  current source, with auth/tenant and installed-app method checks. Their
  `pending_live_proof` status still requires signed-app live socket evidence
  before a release-ready end-to-end GUI control claim.
- reuse of the formal SkyBridge identity, signaling, current-path, session, and file-transfer contracts
- stable structured logs and doctor output for automation and regression

## v1 Out of Scope

- interactive shell / PTY
- SSH replacement semantics
- remote desktop viewer
- port forwarding
- plugin system
- custom script execution engine
- multi-session current-path signaling
- iOS runtime control through the Rust CLI

These are backlog items and must not slip into v1 under the label of “small extra.”

## Success Criteria

CLI v1 is release-worthy only if all are true:

1. users can install it and complete device enrollment
2. users can connect with connection codes or the existing formal flow
3. file transfer is reliable and observable
4. session state is stable and explainable
5. the CLI is usable from automation and cross-platform smoke/regression tests
6. existing GUI success paths do not regress

## Architecture

The Rust workspace under `rust/` is the new headless surface:

- `skybridge-core`
  - shared contracts, state machines, route resolution, structured event schema
- `skybridge-agent`
  - state directory, health/runtime loop, structured logging, graceful shutdown
- `skybridge`
  - operator commands, login/connect/file flows, doctor/logs/metrics

The CLI must not read GUI view models or UI-only state.

SkyBridge CLI is the product display name. The installed command and binary name
remain `skybridge` so existing automation, release artifacts, Homebrew formulas,
and npm wrappers do not break during the branding cleanup.

## Authority Boundaries

GUI-affecting commands:

- `skybridge crossnet preflight`
- `skybridge crossnet host`
- `skybridge crossnet connect <code>`
- `skybridge crossnet disconnect`
- `skybridge crossnet status`
- `skybridge crossnet settings`
- `skybridge crossnet settings set <id> <value>`

These are app-bound and use the Mac app's `crossnet-control/1` Unix socket at
`~/Library/Application Support/SkyBridge/crossnet-control.sock`. The Mac app
remains the source of truth for Keychain auth, tenant state,
`CrossNetworkConnectionManager`, and WebRTC/signaling lifecycle.

Current source-tree status: the Rust CLI client and `crossnet-control/1` wire
contract are present, including the Mac app's hello, status and guarded mutation
handlers. `crossnet preflight` reads that
Mac app hello state and reports whether protocol/auth/tenant preconditions are
ready. It must keep mutation availability separate: `preconditions_ready=true`
does not imply that every GUI mutation is available. `mutation_methods_enabled`
reports whether at least one method is enabled, while
`enabled_mutation_methods` / `disabled_mutation_methods` carry the per-method
boundary. Different installed app versions may expose different method sets;
auth/tenant readiness does not override a missing or disabled method. The independent
`release_gate=signed_mac_app_socket_smoke_required` stays machine-readable until
the packaged runtime path has live evidence.
`crossnet status` reads one redacted Mac app status snapshot: auth/tenant flags,
connection/readiness strings, signaling health, optional stable `failure_code` /
`failure_class`, suite, and non-secret `session_ref`; it does not log in,
generate codes, connect peers, change settings, watch streams, expose raw session
ids, raw failure reasons, or control iOS. `crossnet settings` reads an
allowlisted, non-secret settings snapshot from the running Mac app. A strict
subset is mutable through `crossnet settings set`; the app requires auth and
tenant binding, applies the typed value, and re-reads runtime state before
reporting success. PQC identity settings remain immutable on this surface.
`crossnet.navigate` and `crossnet.status --watch` are implemented with the gates
described above. `crossnet.host`, `crossnet.connect`, and `crossnet.disconnect` are implemented
and enabled: the app calls `CrossNetworkConnectionManager` and the router
rejects any result its own read-back does not corroborate — a downgraded host
lease, a connect that claims `handshake_complete` while the app is not
connected, or a disconnect after which a session survives. They are serialized
against each other so a read-back always describes its own mutation, and they
stay `pending_live_proof` until a signed-app socket smoke is captured.
`crossnet host --lease` is session-affecting: requesting a lease that differs
from the active one tears the current session down before issuing the new code.
`crossnet settings set` additionally exposes `remote_desktop.target_fps` and
`remote_desktop.resolution`, which are read-back verified but carry an
`applies_at_next_capture_start` note because ScreenCaptureKit reads capture
parameters only when a stream starts. Sidebar navigation is part of
`crossnet-control/1` through the app-owned injected `OperatorNavigationCoordinator`
with typed destinations and UI-confirmed read-back; it is not emulated with
global notifications or direct view state writes. All release claims for the
mutating and streaming verbs remain gated on signed-app socket evidence
(`pending_live_proof`).

Native/headless commands:

- `skybridge login`
- `skybridge logout`
- `skybridge agent run`
- `skybridge device discover --nearby [--scan]`
- `skybridge code create`
- `skybridge connect <code>`
- `skybridge session ls`
- `skybridge session inspect <id>`
- `skybridge disconnect <id>`
- `skybridge file send <path> --to <peer> --session-id <id>`

These use Rust `state_dir` and `skybridge-agent` runtime state. They are useful
for standalone/headless operation and tests, but they do not mutate the Mac GUI
runtime and must not be treated as a substitute GUI interop channel. Hosting,
connecting, and transferring files require one healthy lock-owning
`skybridge agent run` process for the same state directory; no Desktop app is
required. `device discover --nearby --scan` is a bounded foreground mDNS scan
and can run without the agent. Addresses are hidden by default and, when
explicitly requested, are labelled short-lived and unauthenticated.

`skybridge capabilities --json` exposes this boundary with `runtime_target` and
`control_effect` for each capability. Top-level fields also keep
`ios_runtime_control_supported=false`, `mac_gui_control_protocol=crossnet-control/1`,
and `mac_gui_control_release_gate=signed_mac_app_socket_smoke_required` visible
to automation.
The v1 matrix has no `ios_app_runtime` target: iOS appears only as shared
protocol compatibility and regression coverage, never as a Rust CLI runtime
control plane.

In CLI 0.3.2, `crossnet preflight` succeeds only when the installed app reports
at least one mutation method supported by this CLI. Auth/tenant readiness alone
is not mutation readiness. An absent/null method list is `app_unreported`, with
null enabled/disabled lists; an explicit empty list means no methods are enabled.
Neither is replaced with compile-time expectations. Each mutation additionally
requires its exact advertised method before the mutation request is sent.
Failed preflight writes its structured report to stderr and returns nonzero.

The v1 settings snapshot's `mutable:false` is a legacy read-only-projection
marker, not a declaration that the setting can never be written. The separate
typed mutation allowlist permits the UI/logging settings and capture FPS/resolution,
while protocol-identity settings remain immutable. After a successful mutation
response, 0.3.2 independently reads `crossnet.settings.snapshot`, verifies the
actual value/type, and includes its effect-timing note. Capture changes are
`applies_at_next_capture_start`; they do not prove the current stream changed FPS
or resolution. A missing/conflicting read-back fails without blindly retrying
the already-issued mutation.

`skybridge version --json` and `skybridge capabilities --json` also expose the
same `operator_profile` from ADR-0003. This identifies the public `rust/` CLI
separately from the Windows core diagnostic binary, even when both are called
`skybridge`. Mac-only capabilities are omitted on non-macOS hosts. A profile
describes the compiled command contract, not live authentication or acceptance.

Desktop `skybridge android devices|status|doctor|lan|code` is development tooling.
The app queries require an Android debug app implementing `adb-bridge/1`; the
inspected Android source tree does not currently contain that server. Presence
of the desktop client or its pure protocol tests does not establish Android app
control. Formal mobile automation should use app-owned actions, not require
ADB/Xcode in the novice user's workflow.

`skybridge metrics` accepts data only from the same lock-owning agent and the
same schema/state-directory/freshness evaluator used by managed mutations; a
stale `health.json` cannot report a current healthy runtime. Transfer and
fallback counters remain `null` with an explicit `unobserved` marker until the
agent owns authoritative process-wide counters—zero is never used as a stand-in
for missing observation. Plain `skybridge doctor` includes `overall_ok` and
returns a non-zero status whenever any required check fails.

Native control-plane and signaling origins are TLS-only by default: control-plane
requests require `https://` and the corresponding WebSocket request uses `wss://`.
Plaintext is a local-development exception only. It requires either
`SKYBRIDGE_ALLOW_INSECURE_LOOPBACK_TRANSPORT=true` for environment-configured
clients or `--allow-insecure-loopback` together with an explicit doctor
`--base-url`; even then, only strict `localhost`, IPv4 loopback, or IPv6 loopback
origins are accepted. LAN and public plaintext origins always fail closed.

The native WebSocket session token is never placed in `?st=`. The handshake uses
the server contract's sensitive `X-SkyBridge-Session-Id` and
`X-SkyBridge-Session` headers while `shard` remains a non-authorizing routing
hint. Credential-bearing query parameters are rejected case-insensitively, and
there is no query-token compatibility fallback. External HTTP response bodies
are bounded; rejected-response diagnostics expose only status, an allowlisted
error code, and truncation state. Debug output redacts OAuth, PKCE, session,
TURN, and private-key material.

## Source of Truth

- device identity
  - protected local state store with schema version
- session state
  - shared session/runtime state machine
- file transfer routing
  - shared route contract
- user-visible status
  - shared presentation contract
- audit output
  - structured event stream

## Initial Command Surface

The parser is intentionally shaped around the release surface:

- `skybridge login`
- `skybridge logout`
- `skybridge device status`
- `skybridge device enroll`
- `skybridge device approve <request-id>`
- `skybridge code create`
- `skybridge connect <code>`
- `skybridge crossnet preflight`
- `skybridge crossnet host`
- `skybridge crossnet connect <code>`
- `skybridge crossnet disconnect`
- `skybridge crossnet status`
- `skybridge crossnet settings`
- `skybridge session ls`
- `skybridge session inspect <id>`
- `skybridge disconnect <id>`
- `skybridge file send <path> --to <target>`
- `skybridge file receive`
- `skybridge file history`
- `skybridge doctor`
- `skybridge doctor signaling [--base-url <https-origin>] [--allow-insecure-loopback]`
- `skybridge logs tail`
- `skybridge metrics`
- `skybridge version`

Current command entry points (availability and proof state come from capabilities):

- `skybridge login`
- `skybridge logout`
- `skybridge agent run`
- `skybridge device discover --nearby [--scan] [--show-addresses]`
- `skybridge device status`
- `skybridge device enroll --invite-token <token>`
- `skybridge device approve <pending-device-id> --pending-fingerprint <fp>`
- `skybridge code create`
- `skybridge connect <code>`
- `skybridge session ls`
- `skybridge session inspect <id>`
- `skybridge disconnect <id>`
- `skybridge remote-desktop contract`
- `skybridge remote-desktop status`
- `skybridge remote-desktop resolutions`
- `skybridge remote-desktop start`
- `skybridge remote-desktop stop`
- `skybridge remote-desktop set-resolution`
- `skybridge remote-desktop set-fps`
- `skybridge file send <path> --to <peer> --session-id <id>`
- `skybridge file receive --list`
- `skybridge file receive --session-id <id> --accept <transfer-uuid>`
- `skybridge file receive --session-id <id> --reject <transfer-uuid>`
- `skybridge file history`
- `skybridge capabilities`
- `skybridge crossnet preflight`
- `skybridge crossnet status`
- `skybridge crossnet settings`
- `skybridge crossnet settings set <id> <value>`
- `skybridge crossnet host [--lease short|long]`
- `skybridge crossnet connect <code>`
- `skybridge crossnet disconnect`
- `skybridge crossnet status --watch`
- `skybridge crossnet navigate <destination>`
- `skybridge crossnet devices`
- `skybridge crossnet connect-device <device-ref>`
- `skybridge android devices|status|doctor|lan|code`
- `skybridge doctor`
- `skybridge logs tail`
- `skybridge metrics`
- `skybridge version`

The current crossnet handlers are implemented, but each call still requires
the applicable installed-app capability, authority and runtime checks. Source
implementation does not remove signed-app or real-peer evidence requirements.

`crossnet status --watch` is real server push: the Mac app streams coalesced,
deduplicated status snapshots over the same connection after the initial
response, each frame re-reads auth flags, the per-client send is
timeout-bounded, and a build with no wired push source still fails closed with
`watch_not_supported`.

`crossnet navigate <destination>` drives an app-owned injected navigation
coordinator with typed destinations. The dashboard view applies the request
through its own selection state and confirms what it actually presented — user
clicks confirm through the same path — and the router refuses any result the
UI did not confirm (`navigation_apply_failed`).

`crossnet` host/connect/disconnect reach the live runtime. They remain
`pending_live_proof` rather than `available` until a signed Mac app live socket
smoke proves the packaged runtime path. Because the CLI ships separately from
the app, `crossnet preflight` reports the method list the *installed app* says
it serves (`mutation_methods_source: app_reported`). If the app does not report
one, availability remains unknown and mutations are refused. `crossnet settings set` is
implemented with a typed allowlist and runtime read-back but remains
`pending_live_proof` until a signed-app socket smoke proves the packaged runtime
path.
`file receive --list` reads the persistent inbound approval registry. Accept
and reject require a health-fresh active agent and a current session/runtime,
transfer UUID, authenticated peer device-id, and protocol-fingerprint binding.
The CLI records a decision request with `applied=false`; only the managed agent
owns the live native sender and can apply the decision. The receiver allocates
no staging or storage before approval. This path remains
`pending_live_proof` until a real-device cross-platform inbound transfer gate
is captured.

Current native `connect` submits one managed responder session to the active
agent and returns success only after the agent persists an identity-bound
`HandshakeComplete` receipt with the negotiated suite. The CLI does not create
a second short-lived WebRTC runtime. Peer name comes from the connection-code
lookup; selected ICE IP and authenticated feature negotiation are reported as
unobserved until those runtime receipts exist. `file send` waits by default for
a matching SHA-256 receiver receipt; `--detach` means only that the request was
registered for the active agent. `session ls` and `session inspect` read the
native agent/runtime view instead of Mac GUI state. Release readiness still
requires real-device connection and file-transfer artifacts.
The default Ed25519 path requires a real classic initiator/responder handshake.
PQC initiation additionally requires explicit peer KEM key material and a
primary ML-DSA protocol identity whose fingerprint matches admission state.
An independent PQC bridge identity is not a release path until a signed
control-plane-to-handshake identity binding exists;
`SKYBRIDGE_PQC_BRIDGE_IDENTITY=true` currently fails before handshake setup
instead of generating or advertising an unbound identity.

## Doctor exit contract (0.3.2)

`doctor signaling`, `doctor media-lease` and `doctor webrtc-media` return nonzero
when their existing required checks or fault-stage validation fails. Under
`--json`, failure produces one document on stderr with `success:false`,
`error.code=doctor_checks_failed` and the complete diagnostic `report`; it does
not also emit a success-shaped report on stdout. Success keeps the existing
report on stdout. Scripts must check exit status before treating a report as
acceptance. `diagnose webrtc-media` remains a report-producing inspection command;
use `doctor` for a pass/fail gate. Neither command fabricates live media evidence.

## Iteration Template

Every phase must produce:

- goal
- explicit non-goals
- source of truth
- state machine
- failure semantics
- structured logs
- tests
- compatibility boundary
- rollback switch

Every phase review must answer:

1. which new states were introduced
2. which states can race
3. which states can be overwritten by stale events
4. which failure could be misclassified as fatal
5. which fallback could hide a real bug
6. which log field is still unstable
7. what the next phase is most likely to break

## Repository Layout

- Swift protocol and transport reference implementation remains under `Sources/`
- Rust headless workspace lives under `rust/`
- release-control docs live under `Docs/`

This split is deliberate: protocol semantics stay shared, but the operator surface now has a dedicated headless implementation path.
