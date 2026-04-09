# Failure Matrix and Recovery

## Purpose

The CLI must explain failures in stable categories that automation and humans can act on.

## Signaling Failures

### Authentication / bind rejection

- class
  - fatal
- symptoms
  - signaling failed after or before bind with authorization refusal
- user-facing outcome
  - if transport not established: connect fails
  - if transport established: session stays up but signaling becomes fenced
- recovery
  - refresh credentials, re-authenticate, retry with a new session

### Shard/session mismatch

- class
  - fatal
- symptoms
  - server indicates wrong shard or session
- user-facing outcome
  - current signaling handle is invalid
- recovery
  - recreate code/session and retry

### Token expired

- class
  - fatal
- symptoms
  - signaling token no longer valid
- recovery
  - renew token through the formal auth path

### Transient network or server churn

- class
  - recoverable
- symptoms
  - reconnecting signaling, websocket churn, temporary backend failures
- user-facing outcome
  - degrade signaling health, keep transport if healthy
- recovery
  - retry signaling without tearing down transport

## Transport Failures

### Remote leave

- class
  - terminal session close
- recovery
  - clear active session snapshot and surface explicit disconnect

### Data channel / peer connection failure

- class
  - terminal data-plane failure
- recovery
  - teardown transport, attempt full reconnect if policy allows
- runtime presentation
  - preserve the last established readiness in the session record so disconnect inspection reads as “disconnected after handshake_complete(...)” instead of collapsing to a bare `idle`

## Route Contract Failures

### Connected but route missing

- class
  - contract bug
- recovery
  - do not surface connected, emit structured error, block transfers

### Compatibility fallback invoked

- class
  - warning
- recovery
  - continue only with explicit warning and counter increment

## File Transfer Failures

### Route unavailable

- class
  - fail closed
- recovery
  - require route republish before retry

### Signaling degraded during transfer

- class
  - warning
- recovery
  - keep transfer alive while data plane remains healthy

### Integrity mismatch

- class
  - terminal transfer failure
- recovery
  - stop transfer, mark failed, require retry

### Secure session missing

- class
  - fail closed
- recovery
  - re-establish an authenticated peer session before starting transfer

### Resume state unavailable

- class
  - terminal transfer failure
- recovery
  - restart the transfer from the beginning

## Install and Runtime Failures

### Missing state directory

- class
  - actionable environment issue
- recovery
  - initialize with `skybridge agent run`

### Stale health snapshot

- class
  - warning
- recovery
  - restart agent or inspect logs

### Schema mismatch

- class
  - migration block
- recovery
  - run migration or rollback to a compatible version

## Required Doctor Output

Doctor must emit actionable checks for at least:

- state directory
- identity state presence + schema compatibility
- agent health freshness
- log file presence

## Release Gate

The release is blocked if:

- any fatal state is surfaced as a generic “something went wrong”
- any transport-preservation case still tears down the data plane due only to signaling loss
- any route-contract failure still appears as a successful connection
