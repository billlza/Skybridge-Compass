import Foundation
import SkyBridgeProtocolCore

@available(macOS 14.0, iOS 17.0, *)
extension CrossNetworkConnectionManager {
    nonisolated static func buildCanonicalQRCodePayload(for qrData: DynamicQRCodeData) -> Data {
        var encoder = DeterministicEncoder()
        encoder.encode(UInt16(max(0, qrData.version)))
        encoder.encode(qrData.sessionID)
        encoder.encode(qrData.qrBootstrapToken)
        encoder.encode(Int64(qrData.expiresAt.timeIntervalSince1970 * 1000))
        encoder.encode(qrData.canonicalSignalingServerOrigin)
        encoder.encode(qrData.deviceID)
        encoder.encode(qrData.deviceName)
        encoder.encode(qrData.deviceType)
        encoder.encode(qrData.osVersion)
        encoder.encode(qrData.normalizedCapabilities) { enc, capability in
            enc.encode(capability)
        }
        encoder.encode(qrData.protocolSigningAlgorithm.rawValue)
        encoder.encode(qrData.protocolPublicKeyBytes)
        encoder.encode(qrData.protocolPublicKeyFingerprint)
        encoder.encode(qrData.normalizedKEMPublicKeys) { enc, key in
            enc.encode(key.suiteWireId)
            enc.encode(key.publicKey)
        }
        encoder.encode(qrData.signatureTimestampMs)
        return encoder.finalize()
    }

    static func shouldAllowAuthenticatedQRRebind(
        for conflict: CurrentPathTrustConflict
    ) -> Bool {
        switch conflict {
        case .identityConflict, .deviceIdMigrationRequired:
            return false
        case .quarantinedIdentity, .revokedIdentity:
            return false
        }
    }

    static func shouldAllowAuthenticatedConnectionCodeRebind(
        for conflict: CurrentPathTrustConflict
    ) -> Bool {
        switch conflict {
        case .identityConflict:
            return true
        case .deviceIdMigrationRequired, .quarantinedIdentity, .revokedIdentity:
            return false
        }
    }

    func validateCurrentPathOrigin(_ rawOrigin: String) throws -> String {
        let configuredOrigin = try CurrentPathOriginPolicy.canonicalOrigin(SkyBridgeServerConfig.signalingServerURL)
        let claimedOrigin = try CurrentPathOriginPolicy.canonicalOrigin(rawOrigin)
        guard configuredOrigin == claimedOrigin else {
            throw CrossNetworkConnectionError.invalidQRCode
        }
        return claimedOrigin
    }

    static func verifyDynamicQRCode(_ qrData: DynamicQRCodeData) async -> (ok: Bool, reason: String?, source: QRCodeTrustSource) {
        guard qrData.version >= 6 else {
            return (false, "二维码协议版本过旧", .selfAsserted)
        }
        guard !qrData.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, "二维码缺少 sessionID", .selfAsserted)
        }
        guard !qrData.qrBootstrapToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, "二维码缺少 bootstrap token", .selfAsserted)
        }
        guard (try? ProtocolIdentityBinding.normalizedDeviceId(qrData.deviceID)) != nil else {
            return (false, "二维码 deviceId 格式无效", .selfAsserted)
        }
        guard (try? CurrentPathOriginPolicy.canonicalOrigin(qrData.signalingServerOrigin)) != nil else {
            return (false, "二维码 signaling origin 无效", .selfAsserted)
        }
        guard P2PDeviceType(rawValue: qrData.deviceType) != nil else {
            return (false, "二维码缺少 deviceType", .selfAsserted)
        }
        guard !qrData.osVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, "二维码缺少 osVersion", .selfAsserted)
        }
        guard !qrData.normalizedCapabilities.isEmpty else {
            return (false, "二维码缺少能力列表", .selfAsserted)
        }
        if qrData.version < 7 {
            guard qrData.normalizedKEMPublicKeys.isEmpty else {
                return (false, "二维码 KEM 公钥需要 v7 协议", .selfAsserted)
            }
        }
        if qrData.version >= 7 {
            guard !qrData.normalizedKEMPublicKeys.isEmpty else {
                return (false, "二维码缺少 PQC KEM 公钥", .selfAsserted)
            }
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let skewMs: Int64 = 120_000
        guard qrData.signatureTimestampMs <= nowMs + skewMs else {
            return (false, "二维码签名时间过于超前", .selfAsserted)
        }
        guard Int64(qrData.expiresAt.timeIntervalSince1970 * 1000) >= nowMs - skewMs else {
            return (false, "二维码已过期", .selfAsserted)
        }
        guard qrData.signatureTimestampMs <= Int64(qrData.expiresAt.timeIntervalSince1970 * 1000) else {
            return (false, "二维码时间戳与过期时间矛盾", .selfAsserted)
        }
        guard let signature = qrData.signature else {
            return (false, "二维码缺少签名", .selfAsserted)
        }
        do {
            try ProtocolIdentityBinding.validateKeyEncoding(
                bytes: qrData.protocolPublicKeyBytes,
                algorithm: qrData.protocolSigningAlgorithm
            )
        } catch {
            return (false, "二维码长期协议公钥编码无效", .selfAsserted)
        }
        let computedFingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: qrData.protocolSigningAlgorithm,
            publicKeyBytes: qrData.protocolPublicKeyBytes
        )
        guard computedFingerprint == qrData.protocolPublicKeyFingerprint else {
            return (false, "二维码长期协议公钥指纹不匹配", .selfAsserted)
        }

        do {
            let canonical = Self.buildCanonicalQRCodePayload(for: qrData)
            let provider = ProtocolSignatureProviderSelector.select(for: qrData.protocolSigningAlgorithm)
            guard try await Self.awaitVerifyQRCodeSignature(
                provider: provider,
                canonical: canonical,
                signature: signature,
                publicKey: qrData.protocolPublicKeyBytes
            ) else {
                return (false, "二维码签名验证失败", .selfAsserted)
            }
        } catch {
            return (false, "二维码签名格式无效：\(error.localizedDescription)", .selfAsserted)
        }

        if let conflict = TrustSyncService.shared.evaluateCurrentPathBinding(
            deviceId: qrData.deviceID,
            protocolPublicKeyFingerprint: qrData.protocolPublicKeyFingerprint
        ) {
            if shouldAllowAuthenticatedQRRebind(for: conflict) {
                return (true, nil, .selfAsserted)
            }
            switch conflict {
            case .identityConflict:
                return (false, "二维码 authoritative key 与现有 deviceId 绑定冲突", .selfAsserted)
            case .deviceIdMigrationRequired:
                return (false, "二维码 deviceId 与已 pinned authoritative key 不匹配", .selfAsserted)
            case .quarantinedIdentity:
                return (false, "二维码身份处于隔离/待重新验证状态", .selfAsserted)
            case .revokedIdentity:
                return (false, "二维码身份已撤销", .selfAsserted)
            }
        }

        if let _ = TrustSyncService.shared.getCurrentPathTrustRecord(
            fingerprint: qrData.protocolPublicKeyFingerprint,
            matchingDeviceId: qrData.deviceID
        ) {
            return (true, nil, .trustedDevice)
        }
        return (true, nil, .selfAsserted)
    }

    nonisolated private static func awaitVerifyQRCodeSignature(
        provider: any ProtocolSignatureProvider,
        canonical: Data,
        signature: Data,
        publicKey: Data
    ) async throws -> Bool {
        try await provider.verify(canonical, signature: signature, publicKey: publicKey)
    }
}
