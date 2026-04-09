# File Transfer Route Source

## Rule

File transfer must consume the shared route contract instead of inventing local routing heuristics.

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

## Recovery Rules

- if signaling degrades after the data plane is healthy, the file transfer continues unless the data plane actually fails
- if the route contract changes from compatibility to primary mid-session, new transfers use the primary route
- if route metadata disappears, new transfers fail closed until a valid route is republished

## Test Gates

- primary route beats compatibility route when both exist
- fallback increments observability counters
- missing route fails closed
- signaling loss alone does not cancel an established transfer
