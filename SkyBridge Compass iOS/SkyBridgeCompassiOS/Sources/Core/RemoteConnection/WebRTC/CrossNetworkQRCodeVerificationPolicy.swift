import Foundation

@available(iOS 17.0, *)
struct CrossNetworkQRCodeVerificationResult: Equatable, Sendable {
    let ok: Bool
    let reason: String?

    static let accepted = CrossNetworkQRCodeVerificationResult(ok: true, reason: nil)

    static func rejected(_ reason: String) -> CrossNetworkQRCodeVerificationResult {
        CrossNetworkQRCodeVerificationResult(ok: false, reason: reason)
    }
}

@available(iOS 17.0, *)
enum CrossNetworkQRCodeVerificationPolicy {
    private static let acceptedClockSkewMs: Int64 = 120_000

    static func verify(
        _ qrData: DynamicQRCodeData,
        now: Date = Date()
    ) async throws -> CrossNetworkQRCodeVerificationResult {
        guard qrData.version >= 6 else {
            return .rejected("二维码协议版本过旧")
        }
        guard !qrData.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected("二维码缺少 sessionID")
        }
        guard !qrData.qrBootstrapToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected("二维码缺少 bootstrap token")
        }
        guard (try? CurrentPathSecurityCompat.normalizeDeviceId(qrData.deviceID)) != nil else {
            return .rejected("二维码 deviceId 格式无效")
        }
        guard (try? CurrentPathSecurityCompat.canonicalOrigin(qrData.signalingServerOrigin)) != nil else {
            return .rejected("二维码 signaling origin 无效")
        }
        guard !qrData.deviceType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected("二维码缺少 deviceType")
        }
        guard !qrData.osVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected("二维码缺少 osVersion")
        }
        guard !qrData.normalizedCapabilities.isEmpty else {
            return .rejected("二维码缺少能力列表")
        }
        if qrData.version < 7 {
            guard qrData.normalizedKEMPublicKeys.isEmpty else {
                return .rejected("二维码 KEM 公钥需要 v7 协议")
            }
        }
        if qrData.version >= 7 {
            guard !qrData.normalizedKEMPublicKeys.isEmpty else {
                return .rejected("二维码缺少 PQC KEM 公钥")
            }
        }
        guard let signature = qrData.signature else {
            return .rejected("二维码缺少签名")
        }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        guard qrData.signatureTimestampMs <= nowMs + acceptedClockSkewMs else {
            return .rejected("二维码签名时间过于超前")
        }
        guard Int64(qrData.expiresAt.timeIntervalSince1970 * 1000) >= nowMs - acceptedClockSkewMs else {
            return .rejected("二维码已过期")
        }
        guard qrData.signatureTimestampMs <= Int64(qrData.expiresAt.timeIntervalSince1970 * 1000) else {
            return .rejected("二维码时间戳与过期时间矛盾")
        }
        do {
            try CurrentPathSecurityCompat.validateKeyEncoding(
                bytes: qrData.protocolPublicKeyBytes,
                algorithm: qrData.protocolSigningAlgorithm
            )
        } catch {
            return .rejected(error.localizedDescription)
        }
        let computedFingerprint = CurrentPathSecurityCompat.computeFingerprint(
            algorithm: qrData.protocolSigningAlgorithm,
            publicKeyBytes: qrData.protocolPublicKeyBytes
        )
        guard computedFingerprint == qrData.protocolPublicKeyFingerprint else {
            return .rejected("二维码长期协议公钥指纹不匹配")
        }
        let provider = ProtocolSignatureProviderSelector.select(for: qrData.protocolSigningAlgorithm)
        let isValid = try await provider.verify(
            qrData.canonicalSignaturePayload,
            signature: signature,
            publicKey: qrData.protocolPublicKeyBytes
        )
        return isValid ? .accepted : .rejected("二维码签名验证失败")
    }
}
