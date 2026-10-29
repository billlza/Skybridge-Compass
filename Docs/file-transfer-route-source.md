# File Transfer Route Source

## Rule

File transfer must consume the shared route contract instead of inventing local routing heuristics.

`file_transfer` capability is not a LAN endpoint. It can make transfer UI available, but it must not synthesize `_skybridge-xfer._tcp` or a guessed host/port route.

## Route Resolution Order

Primary source:

1. published `PresenceRouteDescriptor`

Fallback source:

2. compatibility route derived from active presence data

If neither exists:

- the transfer must fail closed
- the CLI must not report a pseudo-successful connected path

## Primary Route Requirements

The primary route is valid only when:

- `transfer_address` is non-empty
- `transfer_port` is present
- `route_source` is explicit

## Compatibility Fallback Requirements

Compatibility fallback is allowed only when:

- there is an active peer connection
- no primary route is available
- the transfer is still bound to an authenticated secure session
- no trust state is synthesized from self-reported file metadata
- a warning event is emitted
- fallback usage is counted for diagnostics

Fallback must never be silently promoted to “normal.”

## Observability

Every transfer attempt must record:

- `session_id`
- `device_id`
- `route_source`
- `transfer_address`
- `transfer_port`
- `fallback_invocation_count`
- ordered LAN endpoint candidate index/count
- per-candidate connect waiting / timeout / failure reason

## Recovery Rules

- if signaling degrades after the data plane is healthy, the file transfer continues unless the data plane actually fails
- if the route contract changes from compatibility to primary mid-session, new transfers use the primary route
- if route metadata disappears, new transfers fail closed until a valid route is republished
- a single stale Bonjour service or unusable address must not block the transfer indefinitely; the sender must either connect to the next equivalent candidate or fail visibly within the per-candidate timeout

## Test Gates

- primary route beats compatibility route when both exist
- fallback increments observability counters
- missing route fails closed
- signaling loss alone does not cancel an established transfer
- iOS -> macOS and macOS -> iOS file transfer both complete on the same trusted account/device pair
- a stale first LAN endpoint candidate produces a timeout/failure log and then tries the next candidate
