import Foundation

@available(macOS 14.0, iOS 17.0, *)
public enum PeerBootstrapTrustMaterialCleanup {
    @MainActor
    public static func forgetTrustCompletely(deviceIds rawDeviceIds: [String]) async throws {
        let deviceIds = normalizedUniqueIds(rawDeviceIds)
        guard !deviceIds.isEmpty else { throw TrustSyncError.recordNotFound }
        var verifiedScopeDeviceIds = deviceIds
        var expectedTrustScope: TrustForgetScope?
        try await performFailClosedForget(
            loadVerifiedFingerprints: {
                let scope = try await TrustSyncService.shared.verifiedForgetScopeForForget(
                    exactDeviceIds: deviceIds
                )
                expectedTrustScope = scope
                verifiedScopeDeviceIds = scope.deviceIds
                return scope.autoConnectFingerprints
            },
            clearAutoConnect: { fingerprints in
                try TrustedAutoConnectStore.shared.clearAutoConnect(fingerprints: fingerprints)
            },
            clearPairingPolicies: {
                try PairingTrustApprovalService.shared.clearPolicies(for: verifiedScopeDeviceIds)
            },
            removeTrust: {
                guard let expectedTrustScope else {
                    throw TrustSyncError.forgetScopeChanged
                }
                try await TrustSyncService.shared.revokeOrRemoveUnverifiableTrust(
                    deviceIds: deviceIds,
                    expectedScope: expectedTrustScope
                )
            },
            clearBootstrap: {
                try await forgetDevicePersisting(deviceIds: verifiedScopeDeviceIds)
            }
        )
    }

    /// Cross-store forget cannot be one physical transaction. This ordering is
    /// monotonic: every partial failure leaves equal or less authorization,
    /// while denial evidence remains until all fallible preference/policy
    /// cleanup has succeeded.
    @MainActor
    static func performFailClosedForget(
        loadVerifiedFingerprints: @MainActor () async throws -> [String],
        clearAutoConnect: @MainActor ([String]) throws -> Void,
        clearPairingPolicies: @MainActor () throws -> Void,
        removeTrust: @MainActor () async throws -> Void,
        clearBootstrap: @MainActor () async throws -> Void
    ) async throws {
        let fingerprints = try await loadVerifiedFingerprints()
        try clearAutoConnect(fingerprints)
        try clearPairingPolicies()
        try await removeTrust()
        try await clearBootstrap()
    }

    /// Throwing variant used by complete forget so persistence failures cannot
    /// be mistaken for successful removal of bootstrap authorization material.
    static func forgetDevicePersisting(deviceIds rawDeviceIds: [String]) async throws {
        let deviceIds = normalizedUniqueIds(rawDeviceIds)
        guard !deviceIds.isEmpty else { return }

        try await PeerKEMBootstrapStore.shared.clearPersisting(deviceIds: deviceIds)
        try await PeerProtocolIdentityBootstrapStore.shared.clearPersisting(deviceIds: deviceIds)
    }

    public static func forgetDevice(deviceIds rawDeviceIds: [String]) async {
        let deviceIds = normalizedUniqueIds(rawDeviceIds)
        guard !deviceIds.isEmpty else { return }

        await PeerKEMBootstrapStore.shared.clear(deviceIds: deviceIds)
        await PeerProtocolIdentityBootstrapStore.shared.clear(deviceIds: deviceIds)
    }

    public static func repairP2PTrust(deviceIds rawDeviceIds: [String]) async {
        let deviceIds = normalizedUniqueIds(rawDeviceIds)
        guard !deviceIds.isEmpty else { return }

        await PeerKEMBootstrapStore.shared.clear(deviceIds: deviceIds)
    }

    private static func normalizedUniqueIds(_ rawIds: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for raw in rawIds {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }

        return result
    }
}
