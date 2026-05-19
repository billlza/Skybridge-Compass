import Foundation

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    static func shouldAllowAuthenticatedAuthorityRebind(
        for conflict: TrustedDeviceStore.CurrentPathTrustConflict
    ) -> Bool {
        switch conflict {
        case .identityConflict, .deviceIdMigrationRequired:
            return false
        case .quarantinedIdentity, .revokedIdentity:
            return false
        }
    }

    static func shouldAllowAuthenticatedQRRebind(
        for conflict: TrustedDeviceStore.CurrentPathTrustConflict
    ) -> Bool {
        switch conflict {
        case .identityConflict, .deviceIdMigrationRequired:
            return true
        case .quarantinedIdentity, .revokedIdentity:
            return false
        }
    }

    static func shouldAllowVerifiedQRCodeRebind(
        for conflict: TrustedDeviceStore.CurrentPathTrustConflict,
        deviceId: String,
        protocolPublicKeyFingerprint: String
    ) -> Bool {
        if shouldAllowAuthenticatedQRRebind(for: conflict) {
            return true
        }

        switch conflict {
        case .quarantinedIdentity:
            if TrustedDeviceStore.shared.hasCurrentPathAuthorityFingerprint(
                protocolPublicKeyFingerprint,
                lifecycleStates: [.reverificationRequired, .quarantined]
            ) {
                return true
            }
            return TrustedDeviceStore.shared.hasCurrentPathAuthorityDevice(
                deviceId,
                lifecycleStates: [.reverificationRequired, .quarantined]
            )
        case .identityConflict, .deviceIdMigrationRequired, .revokedIdentity:
            return false
        }
    }

    static func shouldAllowAuthenticatedConnectionCodeRebind(
        for conflict: TrustedDeviceStore.CurrentPathTrustConflict
    ) -> Bool {
        switch conflict {
        case .identityConflict:
            return true
        case .deviceIdMigrationRequired, .quarantinedIdentity, .revokedIdentity:
            return false
        }
    }
}
