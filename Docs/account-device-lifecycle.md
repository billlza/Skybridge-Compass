# Account device lifecycle

This is the common account-device contract for macOS, iOS, Android, Windows and Linux.
Native clients adapt the same signaling API; platform code must not invent admission rules.

- A verified non-guest account logs in and registers its exact committed signing identity through `POST /api/devices/register-current`. An existing roster does not block another device. Frozen, revoked, conflicting and retired identities remain rejected.
- `GET /api/devices/list` returns the account's registered devices and exact-identity live presence. A roster is not pairing or connection approval. The `isCaller` marker must match the complete local identity.
- Every My Devices list provides a confirmed **Remove from account** action. It sends `POST /api/devices/remove` with the caller's existing identity/version fields and `target: {deviceId, protocolSigningAlgorithm, protocolPublicKeyFingerprint}`. Tenant and user authority come only from the verified session.
- The service requires a real active caller and atomically checks both owner and exact current target identity. A stale selection after key rotation fails with `target_identity_mismatch`; a foreign target is indistinguishable from a missing target.
- Success is exactly `{removed:true,target:{deviceId,protocolSigningAlgorithm,protocolPublicKeyFingerprint,status:"revoked"}}`. Clients validate all fields before updating the list. Failure is displayed explicitly; no optimistic success or automatic destructive retry.
- Removal retains a revoked registry tombstone and revokes the device's active/grace history. It removes account presence, denies later account registration/requests for that identity, and does not delete the user's local files or established local pairings.
- Removing the current caller ends its account-device synchronization and displays its revoked state. Foreground restoration and login cannot silently reverse an explicit removal. Another still-active device may repeat an already committed removal idempotently.
- Account changes and cancellation retire in-flight results. A refresh started before removal cannot put the removed device back into a current snapshot.

The removal migration and server route require production approval separately from client builds. Windows physical-device acceptance remains pending while the device is unavailable; host contract tests do not prove WinUI startup. Linux host builds do not prove a native Linux runtime.
