# Signaling Lifecycle Contract

## Purpose

The CLI and agent must reuse one signaling lifecycle contract.
There is no separate “CLI fast path.”

## Lifecycle Semantics

- `idle`
  - no active signaling handle
- `connecting`
  - a signaling attempt exists, but the transport is not open yet
- `socket_open`
  - the websocket transport is open
  - this is not “connected”
- `bound`
  - the server accepted the shard/session bind
  - this is the only signaling-plane gate that unlocks business sends
- `reconnecting`
  - signaling is being re-established without implying transport teardown
- `closing`
  - signaling is intentionally shutting down
- `closed`
  - signaling transport is closed
- `failed`
  - signaling failed and must be classified

## Readiness Contract

Transport readiness is separate from signaling readiness:

- `transport_ready`
  - data plane exists, handshake not fully complete yet
- `handshake_complete`
  - transport is established and the negotiated suite is known

The CLI must not display “connected” from `socket_open`.
The CLI may display connected only from `transport_ready` or `handshake_complete`, using the shared presentation contract.
When a session later disconnects or fails, the live readiness may return to `idle`, but the runtime record must retain `last_established_readiness` so `session inspect` can still explain whether the session had previously reached `transport_ready` or `handshake_complete`.

## Health Contract

- `healthy`
  - signaling is operating normally
- `degraded_recoverable`
  - signaling is impaired, but a healthy data plane may remain alive
- `degraded_fatal`
  - signaling must be fenced for the current shard/session

## Failure Classification

- fatal classes
  - `auth_bind_rejected`
  - `invalid_shard_or_session_mismatch`
  - `token_expired`
  - `protocol_violation`
- recoverable classes
  - `transient_network`
  - `transient_server`

Rule:

- if transport is not established, a failed signaling handle may tear down readiness
- if transport is already established, failed signaling must degrade health without auto-killing the data plane

## Generation Guard

Every signaling event carries:

- `session_id`
- `backend`
- `generation`

Rules:

- older generations are ignored
- only the current generation may update the active signaling handle
- a stale `socket_open` or `bound` event must never roll back a newer handle

## Single Active Handle Boundary

Only one active signaling handle may own a session shard at a time.
The active handle is selected by:

- `session_id`
- `generation`
- the most recent current-generation lifecycle event

## CLI/Agent Obligations

- never equate websocket open with session connected
- never let signaling failure auto-kill transport unless the transport itself failed or the peer explicitly left
- always surface degraded state as structured fields, not vague prose

## Required Structured Fields

- `session_id`
- `backend`
- `generation`
- `lifecycle_phase`
- `signaling_health`
- `negotiated_suite`
- `reconnect_attempt_count`

## State Machine

```mermaid
stateDiagram-v2
    [*] --> "idle"
    "idle" --> "connecting"
    "connecting" --> "socket_open"
    "socket_open" --> "bound"
    "bound" --> "reconnecting"
    "reconnecting" --> "bound"
    "bound" --> "failed"
    "reconnecting" --> "failed"
    "bound" --> "closing"
    "closing" --> "closed"
```

## Test Gates

- stale generation events cannot override the current handle
- fatal signaling failure after handshake keeps readiness but marks degraded fatal
- recoverable signaling failure after transport does not kill transport
- `bound` is the only signaling-plane gate for business sends
