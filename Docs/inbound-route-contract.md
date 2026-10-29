# Inbound Route Contract

## Problem Statement

“Connected but route unknown” is a contract bug, not a tolerable degraded UX.

Inbound P2P may not be published as connected unless the transfer route metadata is complete.

## Route Descriptor

The canonical inbound route descriptor must include:

- `peer_id`
- `device_name`
- `display_address`
- `transfer_address`
- `transfer_port`
- `route_source`
- `connected_at`

If any required field is missing, the route descriptor is incomplete and must not be published.

## Atomic Publication Rule

Inbound publication is atomic:

1. validate route completeness
2. publish route descriptor
3. publish active connection snapshot

If validation fails:

- do not publish the route
- do not publish the active connection
- emit a contract violation event

## Source Priority

Preferred sources for inbound route resolution:

1. discovered device match via stable device id
2. unified device record via stable device id
3. endpoint label fallback such as `peer:10.0.0.42`

Fallback may recover operability, but it must remain observable.

## Observable Route Sources

- `presence:inbound`
- `presence:outbound`
- `presence:presence`
- `presence:webrtc`
- `presence:compatibility`

Compatibility is fallback, never the primary route when a complete descriptor exists.

## Failure Semantics

- inbound transport up, route missing
  - classify as contract bug
  - do not surface connected
- inbound transport up, endpoint label only
  - allow compatibility fallback
  - emit warning log
- route published from fallback while primary metadata later arrives
  - replace fallback route with the primary descriptor atomically

## Required Structured Fields

- `session_id`
- `route_source`
- `transfer_address`
- `transfer_port`
- `fallback_invocation_count`

## Release Gate

v1 does not ship if any inbound P2P path can produce:

- connected state without route metadata
- silent fallback with no warning
- non-atomic publication of connection and route
