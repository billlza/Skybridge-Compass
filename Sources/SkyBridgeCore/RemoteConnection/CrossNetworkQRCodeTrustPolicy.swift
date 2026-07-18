import Foundation
import SkyBridgeProtocolCore

@available(macOS 14.0, iOS 17.0, *)
extension CrossNetworkConnectionManager {
    nonisolated static func buildCanonicalQRCodePayload(for qrData: DynamicQRCodeData) throws -> Data {
        guard qrData.version == 6 || qrData.version == 7,
              let wireVersion = UInt16(exactly: qrData.version) else {
            throw CrossNetworkConnectionError.invalidQRCode
        }
        var encoder = DeterministicEncoder()
        encoder.encode(wireVersion)
        encoder.encode(qrData.sessionID)
        encoder.encode(qrData.qrBootstrapToken)
        encoder.encode(try CrossNetworkQREpochMilliseconds.milliseconds(from: qrData.expiresAt))
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
        await verifyDynamicQRCode(qrData, trustService: .shared)
    }

    static func verifyDynamicQRCode(
        _ qrData: DynamicQRCodeData,
        trustService: TrustSyncService
    ) async -> (ok: Bool, reason: String?, source: QRCodeTrustSource) {
        guard qrData.version == 6 || qrData.version == 7 else {
            return (false, "二维码协议版本无效", .selfAsserted)
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
        let nowMs: Int64
        let expiresAtMs: Int64
        do {
            nowMs = try CrossNetworkQREpochMilliseconds.milliseconds(from: Date())
            expiresAtMs = try CrossNetworkQREpochMilliseconds.milliseconds(from: qrData.expiresAt)
        } catch {
            return (false, "二维码过期时间格式无效", .selfAsserted)
        }
        let skewMs: Int64 = 120_000
        let (latestSignatureTimestampMs, signatureBoundOverflow) = nowMs.addingReportingOverflow(skewMs)
        guard !signatureBoundOverflow,
              qrData.signatureTimestampMs <= latestSignatureTimestampMs else {
            return (false, "二维码签名时间过于超前", .selfAsserted)
        }
        let (oldestExpirationTimestampMs, expirationBoundOverflow) = nowMs.subtractingReportingOverflow(skewMs)
        guard !expirationBoundOverflow,
              expiresAtMs >= oldestExpirationTimestampMs else {
            return (false, "二维码已过期", .selfAsserted)
        }
        guard qrData.signatureTimestampMs <= expiresAtMs else {
            return (false, "二维码时间戳与过期时间矛盾", .selfAsserted)
        }
        let (validityDurationMs, validityDurationOverflow) = expiresAtMs.subtractingReportingOverflow(
            qrData.signatureTimestampMs
        )
        let maximumValidityDurationMs = Int64(P2PConstants.qrCodeExpirationSeconds * 1_000)
        guard !validityDurationOverflow,
              validityDurationMs <= maximumValidityDurationMs else {
            return (false, "二维码有效期超出协议上限", .selfAsserted)
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
            let canonical = try Self.buildCanonicalQRCodePayload(for: qrData)
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

        let trustAssessment: CurrentPathTrustAssessment
        do {
            trustAssessment = try await trustService.currentPathTrustAssessment(
                deviceId: qrData.deviceID,
                protocolPublicKeyFingerprint: qrData.protocolPublicKeyFingerprint
            )
        } catch is CancellationError {
            return (false, "二维码验证已取消", .selfAsserted)
        } catch {
            return (false, "本地信任存储不可用，无法安全验证二维码", .selfAsserted)
        }

        if case .conflict(let conflict) = trustAssessment {
            switch conflict {
            case .identityConflict:
                return (false, "二维码密钥与已 pinned authoritative key 冲突", .selfAsserted)
            case .deviceIdMigrationRequired:
                return (false, "二维码 deviceId 与已 pinned authoritative key 不匹配", .selfAsserted)
            case .quarantinedIdentity:
                return (false, "二维码身份处于隔离/待重新验证状态", .selfAsserted)
            case .revokedIdentity:
                return (false, "二维码身份已撤销", .selfAsserted)
            }
        }

        if trustAssessment == .trustedDevice {
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
