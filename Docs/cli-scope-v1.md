# SkyBridge CLI Scope v1

## Product Definition

SkyBridge CLI has two explicit operator surfaces:

- **Mac app control surface**: app-bound commands that call the running
  SkyBridge Compass Pro app through `crossnet-control/1`. These commands may
  change the GUI/WebRTC runtime only when the Mac app itself has a loaded auth
  session and tenant binding.
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
- `skybridge crossnet ...` as the Mac app-bound cross-network control surface
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

## Authority Boundaries

GUI-affecting commands:

- `skybridge crossnet host`
- `skybridge crossnet connect <code>`
- `skybridge crossnet disconnect`
- `skybridge crossnet status`

These are app-bound and use the Mac app's `crossnet-control/1` Unix socket. The
Mac app remains the source of truth for Keychain auth, tenant state,
`CrossNetworkConnectionManager`, and WebRTC/signaling lifecycle.

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
- `skybridge crossnet host`
- `skybridge crossnet connect <code>`
- `skybridge crossnet disconnect`
- `skybridge crossnet status`
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
- `skybridge doctor`
- `skybridge logs tail`
- `skybridge metrics`
- `skybridge version`

Still intentionally gated:

- `skybridge file send`
- `skybridge file receive`
- `skybridge file history`

Current native `connect` establishes and validates the formal signaling/current-path control plane, then writes lifecycle state into the shared runtime session registry under `runtime/sessions.json`. `session ls` and `session inspect` read that native agent/runtime view instead of Mac GUI state. Use `skybridge crossnet ...` for Mac GUI interop. Full data-plane/file-transfer work remains Phase 6.

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
