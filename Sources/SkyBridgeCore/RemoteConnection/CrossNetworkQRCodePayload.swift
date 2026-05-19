import Foundation
import SkyBridgeProtocolCore

@available(macOS 14.0, iOS 17.0, *)
enum CrossNetworkConnectPayloadCodec {
    nonisolated static func base64URLEncodedString(from data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func decodeBase64Payload(_ raw: String) -> Data? {
        for candidate in strictBase64URLCandidates(from: raw) {
            if let data = Data(base64Encoded: candidate) {
                return data
            }
        }
        return nil
    }

    nonisolated private static func strictBase64URLCandidates(from raw: String) -> [String] {
        let rawCandidates = [raw, raw.removingPercentEncoding]
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

@available(macOS 14.0, iOS 17.0, *)
extension CrossNetworkConnectionManager {
    nonisolated static func base64URLEncodedString(from data: Data) -> String {
        CrossNetworkConnectPayloadCodec.base64URLEncodedString(from: data)
    }

    nonisolated static func decodeBase64Payload(_ raw: String) -> Data? {
        CrossNetworkConnectPayloadCodec.decodeBase64Payload(raw)
    }

    nonisolated static func encodeQRCodeConnectLink(_ qrData: DynamicQRCodeData) throws -> Data {
        let compactPayload = CompactDynamicQRCodeData(from: qrData)
        let jsonData = try JSONEncoder().encode(compactPayload)
        let base64String = Self.base64URLEncodedString(from: jsonData)
        guard let data = "skybridge://connect/\(base64String)".data(using: .utf8) else {
            throw CrossNetworkConnectionError.invalidQRCode
        }
        return data
    }

    nonisolated static func isP2PKEMBootstrapCapability(_ capabilities: [String]) -> Bool {
        let normalized = Set(capabilities.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return normalized.contains("p2p-oob-kem") || normalized.contains("p2p-kem-bootstrap")
    }

    static func decodeDynamicQRCodePayload(from jsonData: Data) throws -> DynamicQRCodeData {
        try JSONDecoder().decode(DynamicQRCodeData.self, from: jsonData)
    }
}

/// 动态二维码数据结构
@available(macOS 14.0, iOS 17.0, *)
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
        (try? CurrentPathOriginPolicy.canonicalOrigin(signalingServerOrigin)) ?? signalingServerOrigin
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

    func withSignature(_ signature: Data) -> DynamicQRCodeData {
        DynamicQRCodeData(
            version: version,
            sessionID: sessionID,
            qrBootstrapToken: qrBootstrapToken,
            signalingServerOrigin: canonicalSignalingServerOrigin,
            deviceID: deviceID,
            deviceName: deviceName.precomposedStringWithCanonicalMapping,
            deviceType: deviceType.precomposedStringWithCanonicalMapping,
            osVersion: osVersion.precomposedStringWithCanonicalMapping,
            capabilities: normalizedCapabilities,
            protocolSigningAlgorithm: protocolSigningAlgorithm,
            protocolPublicKeyBytes: protocolPublicKeyBytes,
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprint,
            kemPublicKeys: kemPublicKeys,
            signature: signature,
            signatureTimestampMs: signatureTimestampMs,
            expiresAt: expiresAt
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
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
                throw CurrentPathSecurityError.invalidBootstrap("invalid KEM public key encoding")
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
            throw CurrentPathSecurityError.invalidBootstrap("unknown protocol signing algorithm")
        }
        guard let keyData = CrossNetworkConnectPayloadCodec.decodeBase64Payload(k) else {
            throw CurrentPathSecurityError.invalidBootstrap("invalid protocol public key encoding")
        }
        let signatureData: Data?
        if let g {
            guard let decodedSignature = CrossNetworkConnectPayloadCodec.decodeBase64Payload(g) else {
                throw CurrentPathSecurityError.invalidBootstrap("invalid signature encoding")
            }
            signatureData = decodedSignature
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
