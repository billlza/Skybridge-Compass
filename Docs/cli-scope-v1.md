# SkyBridge CLI Scope v1

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
  The Rust client, wire contract, and initial Mac app `crossnet-control/1`
  read-only socket server source exist. `crossnet preflight` is the explicit
  macOS-only readiness check for protocol/auth/tenant state. `crossnet status`
  can read one redacted Mac app status snapshot. `crossnet settings` can read
  one allowlisted, non-secret Mac app settings snapshot. Mutating commands,
  settings writes, and status watch still require signed-app live socket smoke
  before they are treated as end-to-end GUI control capabilities.
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
  - operator commands, doctor/logs/metrics, future login/connect/file commands

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

These are app-bound and use the Mac app's `crossnet-control/1` Unix socket at
`~/Library/Application Support/SkyBridge/crossnet-control.sock`. The Mac app
remains the source of truth for Keychain auth, tenant state,
`CrossNetworkConnectionManager`, and WebRTC/signaling lifecycle.

Current source-tree status: the Rust CLI client and `crossnet-control/1` wire
contract are present. The Mac app now has an initial `crossnet.hello` /
`crossnet.status` socket server source path. `crossnet preflight` reads that
Mac app hello state and reports whether protocol/auth/tenant preconditions are
ready. It must keep mutation availability separate: `preconditions_ready=true`
does not imply GUI mutation support, `mutation_methods_enabled=false` remains
visible until signed Mac app socket smoke proves the runtime path, and
`release_gate=signed_mac_app_socket_smoke_required` stays machine-readable.
`crossnet status` reads one redacted Mac app status snapshot: auth/tenant flags,
connection/readiness strings, signaling health, optional stable `failure_code` /
`failure_class`, suite, and non-secret `session_ref`; it does not log in,
generate codes, connect peers, change settings, watch streams, expose raw session
ids, raw failure reasons, or control iOS. `crossnet settings` reads an allowlisted, non-secret settings snapshot from
the running Mac app and reports every setting as read-only in this slice; it does
not write `UserDefaults`, mutate runtime state, expose paths/tokens/raw session
ids, or control iOS. `crossnet.host`, `crossnet.connect`, `crossnet.disconnect`,
and `crossnet.settings.set` still return explicit `method_not_enabled` after
their validation/auth gates where a method shape exists. Mutating commands and
`crossnet status --watch` must remain planned/app-bound until the signed Mac app
passes live socket smoke with explicit auth, tenant, status, local-binding,
stream lifecycle, mutation, and runtime-observation gates.

Native/headless commands:

- `skybridge login`
- `skybridge logout`
- `skybridge code create`
- `skybridge connect <code>`
- `skybridge session ls`
- `skybridge session inspect <id>`
- `skybridge disconnect <id>`

These use Rust `state_dir` and `skybridge-agent` runtime state. They are useful
for standalone/headless operation and tests, but they do not mutate the Mac GUI
runtime and must not be treated as a substitute GUI interop channel.

`skybridge capabilities --json` exposes this boundary with `runtime_target` and
`control_effect` for each capability. Top-level fields also keep
`ios_runtime_control_supported=false`, `mac_gui_control_protocol=crossnet-control/1`,
and `mac_gui_control_release_gate=signed_mac_app_socket_smoke_required` visible
to automation.
The v1 matrix has no `ios_app_runtime` target: iOS appears only as shared
protocol compatibility and regression coverage, never as a Rust CLI runtime
control plane.

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
- `skybridge logs tail`
- `skybridge metrics`
- `skybridge version`

As of this commit, the runnable subset is:

- `skybridge login`
- `skybridge logout`
- `skybridge agent run`
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
- `skybridge file history`
- `skybridge capabilities`
- `skybridge crossnet preflight`
- `skybridge crossnet status`
- `skybridge crossnet settings`
- `skybridge doctor`
- `skybridge logs tail`
- `skybridge metrics`
- `skybridge version`

Still intentionally gated:

- `skybridge file receive`
- `skybridge crossnet host`
- `skybridge crossnet connect <code>`
- `skybridge crossnet disconnect`
- `skybridge crossnet settings set <id> <value>`
- `skybridge crossnet status --watch`

The gated `crossnet` host/connect/disconnect commands have a runnable CLI parser
and Rust UDS client, and the Mac app source now exposes an initial read-only
`crossnet-control/1` server. They remain release-gated until a signed Mac app
live socket smoke proves the runtime path. `crossnet settings set` remains a
planned capability without a runnable parser until a typed allowlist and runtime
observation proof exist. The gated `file receive` command remains fail-closed
because inbound transfers are handled by the managed agent runtime, not a
synchronous operator command.

Current native `connect` establishes and validates the formal signaling/current-path control plane, then writes lifecycle state into the shared runtime session registry under `runtime/sessions.json`. `session ls` and `session inspect` read that native agent/runtime view instead of Mac GUI state. Use `skybridge crossnet preflight/status/settings` for read-only Mac GUI truth; use mutating `skybridge crossnet ...` commands for Mac GUI interop only after signed Mac app socket smoke exists. File transfer send/history are present as agent-owned request/evidence surfaces; release readiness still requires real-device transfer artifacts.

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
