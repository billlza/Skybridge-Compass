import Foundation

@available(iOS 17.0, *)
enum CrossNetworkConnectPayloadCodec {
    nonisolated static func base64URLEncodedString(from data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func decodeBase64Payload(_ rawPayload: String) -> Data? {
        for candidate in strictBase64URLCandidates(from: rawPayload) {
            if let data = Data(base64Encoded: candidate) {
                return data
            }
        }
        return nil
    }

    nonisolated private static func strictBase64URLCandidates(from rawPayload: String) -> [String] {
        let rawCandidates = [rawPayload, rawPayload.removingPercentEncoding]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_+/=")
        var normalizedCandidates: [String] = []
        var seen = Set<String>()

        for rawCandidate in rawCandidates {
            let compactScalars = rawCandidate.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            guard !compactScalars.isEmpty else { continue }
            guard compactScalars.allSatisfy({ allowedCharacters.contains($0) }) else { continue }

            let normalized = String(String.UnicodeScalarView(compactScalars))
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let padded = normalized + String(repeating: "=", count: (4 - (normalized.count % 4)) % 4)
            if seen.insert(padded).inserted {
                normalizedCandidates.append(padded)
            }
        }

        return normalizedCandidates
    }
}

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    enum ConnectLinkError: LocalizedError {
        case invalidFormat
        case invalidBase64
        case expired
        case invalidSignature

        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "二维码格式无效"
            case .invalidBase64: return "二维码内容损坏"
            case .expired: return "二维码已过期"
            case .invalidSignature: return "二维码签名或绑定字段无效"
            }
        }
    }

    nonisolated static func isP2PKEMBootstrapCapability(_ capabilities: [String]) -> Bool {
        let normalized = Set(capabilities.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return normalized.contains("p2p-oob-kem") || normalized.contains("p2p-kem-bootstrap")
    }

    nonisolated static func shouldReuseRedeemedQRSessionArtifacts(
        canonicalQRSignalingOrigin: String,
        qrDeviceId: String,
        qrProtocolSigningAlgorithm: ProtocolSigningAlgorithm,
        qrProtocolPublicKeyFingerprint: String,
        qrProtocolPublicKeyBytes: Data,
        signalingToken: String?,
        turnAdmissionToken: String?,
        cachedSignalingOrigin: String?,
        cachedAuthority: CurrentPathRemoteAuthorityCompat?
    ) -> Bool {
        guard signalingToken != nil,
              turnAdmissionToken != nil,
              cachedSignalingOrigin == canonicalQRSignalingOrigin,
              let cachedAuthority else {
            return false
        }
        guard cachedAuthority.deviceId == qrDeviceId,
              cachedAuthority.protocolSigningAlgorithm == qrProtocolSigningAlgorithm,
              cachedAuthority.protocolPublicKeyFingerprint == qrProtocolPublicKeyFingerprint else {
            return false
        }
        if let cachedKeyBytes = cachedAuthority.protocolPublicKeyBytes,
           !qrProtocolPublicKeyBytes.isEmpty,
           !cachedKeyBytes.isEmpty,
           cachedKeyBytes != qrProtocolPublicKeyBytes {
            return false
        }
        return true
    }

    nonisolated static func decodeDynamicQRCodePayload(from jsonData: Data) throws -> DynamicQRCodeData {
        try JSONDecoder().decode(DynamicQRCodeData.self, from: jsonData)
    }

    /// 解码 macOS 侧 `generateDynamicQRCode` 发出的服务端背书邀请（version 8，无 PQC 公钥材料）。
    /// CodingKeys 与 macOS 的 `CompactServerBackedDynamicQRCodeInvite`(`{v,s,q,r,d,n,y,o,a,f,e}`) 逐字节一致。
    nonisolated static func decodeServerBackedQRCodeInvite(from jsonData: Data) throws -> ServerBackedDynamicQRCodeInvite {
        try JSONDecoder().decode(ServerBackedDynamicQRCodeInvite.self, from: jsonData)
    }

    nonisolated static func extractConnectPayloadString(from raw: String) -> String? {
        CrossNetworkConnectPayloadParserCompat.extractPayload(from: raw)
    }
}

/// 服务端背书动态二维码邀请（version >= 8）。镜像 macOS
/// `Sources/SkyBridgeCore/RemoteConnection/CrossNetworkQRCodePayload.swift` 的同名结构，
/// 不携带 PQC 公钥材料；redeem 流程后由握手/pinning 完成设备来源认证。
@available(iOS 17.0, *)
struct ServerBackedDynamicQRCodeInvite: Codable {
    let version: Int
    let sessionID: String
    let qrBootstrapToken: String
    let signalingServerOrigin: String
    let deviceID: String
    let deviceName: String
    let deviceType: String
    let osVersion: String
    let protocolSigningAlgorithm: ProtocolSigningAlgorithm
    let protocolPublicKeyFingerprint: String
    let expiresAt: Date

    init(
        version: Int,
        sessionID: String,
        qrBootstrapToken: String,
        signalingServerOrigin: String,
        deviceID: String,
        deviceName: String,
        deviceType: String,
        osVersion: String,
        protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        protocolPublicKeyFingerprint: String,
        expiresAt: Date
    ) {
        self.version = version
        self.sessionID = sessionID
        self.qrBootstrapToken = qrBootstrapToken
        self.signalingServerOrigin = (try? CurrentPathSecurityCompat.canonicalOrigin(signalingServerOrigin)) ?? signalingServerOrigin
        self.deviceID = deviceID
        self.deviceName = deviceName.precomposedStringWithCanonicalMapping
        self.deviceType = deviceType.precomposedStringWithCanonicalMapping
        self.osVersion = osVersion.precomposedStringWithCanonicalMapping
        self.protocolSigningAlgorithm = protocolSigningAlgorithm
        self.protocolPublicKeyFingerprint = protocolPublicKeyFingerprint.lowercased()
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let compact = try CompactServerBackedDynamicQRCodeInvite(from: decoder)
        self = try compact.expanded()
    }

    func encode(to encoder: Encoder) throws {
        try CompactServerBackedDynamicQRCodeInvite(from: self).encode(to: encoder)
    }
}

/// 紧凑线缆形态：键名 `{v,s,q,r,d,n,y,o,a,f,e}` 与 macOS
/// `CompactServerBackedDynamicQRCodeInvite` 完全一致，保证解码同一份 JSON。
@available(iOS 17.0, *)
struct CompactServerBackedDynamicQRCodeInvite: Codable {
    let v: Int
    let s: String
    let q: String
    let r: String
    let d: String
    let n: String
    let y: String
    let o: String
    let a: String
    let f: String
    let e: Int64

    init(from invite: ServerBackedDynamicQRCodeInvite) {
        self.v = invite.version
        self.s = invite.sessionID
        self.q = invite.qrBootstrapToken
        self.r = invite.signalingServerOrigin
        self.d = invite.deviceID
        self.n = invite.deviceName.precomposedStringWithCanonicalMapping
        self.y = invite.deviceType.precomposedStringWithCanonicalMapping
        self.o = invite.osVersion.precomposedStringWithCanonicalMapping
        self.a = invite.protocolSigningAlgorithm.rawValue
        self.f = invite.protocolPublicKeyFingerprint.lowercased()
        self.e = Int64(invite.expiresAt.timeIntervalSince1970 * 1000)
    }

    func expanded() throws -> ServerBackedDynamicQRCodeInvite {
        guard v >= 8 else {
            throw NSError(domain: "CrossNetworkWebRTCManager", code: 26, userInfo: [NSLocalizedDescriptionKey: "server-backed QR invite requires v8"])
        }
        guard let algorithm = ProtocolSigningAlgorithm(rawValue: a) else {
            throw NSError(domain: "CrossNetworkWebRTCManager", code: 10, userInfo: [NSLocalizedDescriptionKey: "unknown protocol signing algorithm"])
        }
        return ServerBackedDynamicQRCodeInvite(
            version: v,
            sessionID: s,
            qrBootstrapToken: q,
            signalingServerOrigin: r,
            deviceID: d,
            deviceName: n,
            deviceType: y,
            osVersion: o,
            protocolSigningAlgorithm: algorithm,
            protocolPublicKeyFingerprint: f,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(e) / 1000.0)
        )
    }
}

@available(iOS 17.0, *)
struct DynamicQRCodeData: Codable {
    let version: Int
    let sessionID: String
    let qrBootstrapToken: String
    let signalingServerOrigin: String
    let deviceID: String
    let deviceName: String
    let deviceType: String
    let osVersion: String
    let capabilities: [String]
    let protocolSigningAlgorithm: ProtocolSigningAlgorithm
    let protocolPublicKeyBytes: Data
    let protocolPublicKeyFingerprint: String
    let kemPublicKeys: [KEMPublicKeyInfo]
    let signature: Data?
    let signatureTimestampMs: Int64
    let expiresAt: Date

    init(
        version: Int,
        sessionID: String,
        qrBootstrapToken: String,
        signalingServerOrigin: String,
        deviceID: String,
        deviceName: String,
        deviceType: String,
        osVersion: String,
        capabilities: [String],
        protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        protocolPublicKeyBytes: Data,
        protocolPublicKeyFingerprint: String,
        kemPublicKeys: [KEMPublicKeyInfo] = [],
        signature: Data?,
        signatureTimestampMs: Int64,
        expiresAt: Date
    ) {
        self.version = version
        self.sessionID = sessionID
        self.qrBootstrapToken = qrBootstrapToken
        self.signalingServerOrigin = signalingServerOrigin
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.osVersion = osVersion
        self.capabilities = capabilities
        self.protocolSigningAlgorithm = protocolSigningAlgorithm
        self.protocolPublicKeyBytes = protocolPublicKeyBytes
        self.protocolPublicKeyFingerprint = protocolPublicKeyFingerprint.lowercased()
        self.kemPublicKeys = KEMPublicKeyInfo.normalizedValidKeys(kemPublicKeys)
        self.signature = signature
        self.signatureTimestampMs = signatureTimestampMs
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let compact = try CompactDynamicQRCodeData(from: decoder)
        self = try compact.expanded()
    }

    func encode(to encoder: Encoder) throws {
        try CompactDynamicQRCodeData(from: self).encode(to: encoder)
    }

    var normalizedCapabilities: [String] {
        Array(Set(
            capabilities
                .map { $0.precomposedStringWithCanonicalMapping.lowercased() }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        ))
        .sorted { lhs, rhs in
            Data(lhs.utf8).lexicographicallyPrecedes(Data(rhs.utf8))
        }
    }

    var canonicalSignalingServerOrigin: String {
        (try? CurrentPathSecurityCompat.canonicalOrigin(signalingServerOrigin)) ?? signalingServerOrigin
    }

    var normalizedKEMPublicKeys: [KEMPublicKeyInfo] {
        KEMPublicKeyInfo.normalizedValidKeys(kemPublicKeys)
            .sorted { lhs, rhs in
                if lhs.suiteWireId != rhs.suiteWireId {
                    return lhs.suiteWireId < rhs.suiteWireId
                }
                return lhs.publicKey.lexicographicallyPrecedes(rhs.publicKey)
            }
    }
}

@available(iOS 17.0, *)
struct CompactDynamicQRCodeData: Codable {
    struct CompactKEMPublicKey: Codable {
        let w: UInt16
        let p: String

        init(_ key: KEMPublicKeyInfo) {
            self.w = key.suiteWireId
            self.p = CrossNetworkConnectPayloadCodec.base64URLEncodedString(from: key.publicKey)
        }

        func expanded() throws -> KEMPublicKeyInfo {
            guard let publicKey = CrossNetworkConnectPayloadCodec.decodeBase64Payload(p),
                  !publicKey.isEmpty else {
                throw NSError(domain: "CrossNetworkWebRTCManager", code: 16, userInfo: [NSLocalizedDescriptionKey: "invalid KEM public key encoding"])
            }
            return KEMPublicKeyInfo(suiteWireId: w, publicKey: publicKey)
        }
    }

    let v: Int
    let s: String
    let q: String
    let r: String
    let d: String
    let n: String
    let y: String
    let o: String
    let c: [String]
    let a: String
    let k: String
    let f: String
    let m: [CompactKEMPublicKey]?
    let g: String?
    let t: Int64
    let e: Int64

    init(from qrData: DynamicQRCodeData) {
        self.v = qrData.version
        self.s = qrData.sessionID
        self.q = qrData.qrBootstrapToken
        self.r = qrData.canonicalSignalingServerOrigin
        self.d = qrData.deviceID
        self.n = qrData.deviceName.precomposedStringWithCanonicalMapping
        self.y = qrData.deviceType
        self.o = qrData.osVersion.precomposedStringWithCanonicalMapping
        self.c = qrData.normalizedCapabilities
        self.a = qrData.protocolSigningAlgorithm.rawValue
        self.k = CrossNetworkConnectPayloadCodec.base64URLEncodedString(from: qrData.protocolPublicKeyBytes)
        self.f = qrData.protocolPublicKeyFingerprint.lowercased()
        let compactKEM = qrData.normalizedKEMPublicKeys.map(CompactKEMPublicKey.init)
        self.m = compactKEM.isEmpty ? nil : compactKEM
        self.g = qrData.signature.map { CrossNetworkConnectPayloadCodec.base64URLEncodedString(from: $0) }
        self.t = qrData.signatureTimestampMs
        self.e = Int64(qrData.expiresAt.timeIntervalSince1970 * 1000)
    }

    func expanded() throws -> DynamicQRCodeData {
        guard let algorithm = ProtocolSigningAlgorithm(rawValue: a) else {
            throw NSError(domain: "CrossNetworkWebRTCManager", code: 10, userInfo: [NSLocalizedDescriptionKey: "invalid signing algorithm"])
        }
        guard let keyData = CrossNetworkConnectPayloadCodec.decodeBase64Payload(k) else {
            throw NSError(domain: "CrossNetworkWebRTCManager", code: 11, userInfo: [NSLocalizedDescriptionKey: "invalid public key encoding"])
        }
        let signatureData: Data?
        if let g {
            guard let decoded = CrossNetworkConnectPayloadCodec.decodeBase64Payload(g) else {
                throw NSError(domain: "CrossNetworkWebRTCManager", code: 12, userInfo: [NSLocalizedDescriptionKey: "invalid signature encoding"])
            }
            signatureData = decoded
        } else {
            signatureData = nil
        }
        let kemKeys = try (m ?? []).map { try $0.expanded() }
        return DynamicQRCodeData(
            version: v,
            sessionID: s,
            qrBootstrapToken: q,
            signalingServerOrigin: r,
            deviceID: d,
            deviceName: n,
            deviceType: y,
            osVersion: o,
            capabilities: c,
            protocolSigningAlgorithm: algorithm,
            protocolPublicKeyBytes: keyData,
            protocolPublicKeyFingerprint: f,
            kemPublicKeys: kemKeys,
            signature: signatureData,
            signatureTimestampMs: t,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(e) / 1000.0)
        )
    }
}
