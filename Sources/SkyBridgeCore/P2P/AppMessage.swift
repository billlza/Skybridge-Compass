import Foundation
import CryptoKit

/// App-level encrypted message sent over an established P2P session (after handshake).
/// This is distinct from handshake frames.
@available(macOS 14.0, iOS 17.0, *)
public enum AppMessage: Codable, Sendable, Equatable {
    case clipboard(ClipboardPayload)
    case pairingIdentityExchange(PairingIdentityExchangePayload)
    case kemRefreshRequest(KEMRefreshRequestPayload)
    case signedKEMRefresh(SignedKEMRefreshPayload)
    case kemRefreshFailure(KEMRefreshFailurePayload)
    case protocolIdentityBindingRequest(ProtocolIdentityBindingRequestPayload)
    case signedProtocolIdentityBinding(SignedProtocolIdentityBindingPayload)
    case heartbeat(HeartbeatPayload)
    case peerDisconnecting(PeerDisconnectingPayload)
    /// Lightweight RTT probe (request).
    case ping(PingPayload)
    /// Lightweight RTT probe (response).
    case pong(PongPayload)

    public struct ClipboardPayload: Codable, Sendable, Equatable {
        public let mimeType: String
        public let dataBase64: String
        public let sentAt: Date

        public init(mimeType: String, dataBase64: String, sentAt: Date = Date()) {
            self.mimeType = mimeType
            self.dataBase64 = dataBase64
            self.sentAt = sentAt
        }

        public var decodedData: Data? {
            Data(base64Encoded: dataBase64)
        }
    }

    /// Minimal identity bundle used to bootstrap PQC handshake:
    /// - provides peer KEM identity public keys (suiteWireId -> publicKey)
    /// - provides stable deviceId for trust store indexing
    public struct PairingIdentityExchangePayload: Codable, Sendable, Equatable {
        public let deviceId: String
        public let kemPublicKeys: [KEMPublicKeyInfo]
        public let protocolIdentityPublicKeys: [ProtocolIdentityPublicKeyInfo]?
        /// Optional UI metadata (best-effort). Used to populate “Trusted Devices” UI and approval prompts.
        public let deviceName: String?
        public let modelName: String?
        public let platform: String?
        public let osVersion: String?
        public let chip: String?
        public let accountDisplayName: String?
        public let nebulaId: String?
        public let remoteVideoFormats: [String]?
        public let capabilities: [String]?
        public let fileTransferPort: UInt16?
        public let remoteControlPort: UInt16?
        public let sentAt: Date

        public init(
            deviceId: String,
            kemPublicKeys: [KEMPublicKeyInfo],
            protocolIdentityPublicKeys: [ProtocolIdentityPublicKeyInfo]? = nil,
            deviceName: String? = nil,
            modelName: String? = nil,
            platform: String? = nil,
            osVersion: String? = nil,
            chip: String? = nil,
            accountDisplayName: String? = nil,
            nebulaId: String? = nil,
            remoteVideoFormats: [String]? = nil,
            capabilities: [String]? = nil,
            fileTransferPort: UInt16? = nil,
            remoteControlPort: UInt16? = nil,
            sentAt: Date = Date()
        ) {
            self.deviceId = deviceId
            self.kemPublicKeys = kemPublicKeys
            self.protocolIdentityPublicKeys = ProtocolIdentityPublicKeyInfo.normalizedValidKeys(protocolIdentityPublicKeys)
            self.deviceName = deviceName
            self.modelName = modelName
            self.platform = platform
            self.osVersion = osVersion
            self.chip = chip
            self.accountDisplayName = accountDisplayName
            self.nebulaId = nebulaId
            self.remoteVideoFormats = remoteVideoFormats
            self.capabilities = capabilities
            self.fileTransferPort = fileTransferPort
            self.remoteControlPort = remoteControlPort
            self.sentAt = sentAt
        }

        public var normalizedBootstrapPayload: PairingIdentityExchangePayload? {
            let trimmedDeviceId = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDeviceId.isEmpty else { return nil }
            let validKEMKeys = KEMPublicKeyInfo.normalizedValidKeys(kemPublicKeys)
            guard !validKEMKeys.isEmpty else { return nil }
            return .init(
                deviceId: trimmedDeviceId,
                kemPublicKeys: validKEMKeys,
                protocolIdentityPublicKeys: ProtocolIdentityPublicKeyInfo.normalizedValidKeys(protocolIdentityPublicKeys),
                deviceName: deviceName,
                modelName: modelName,
                platform: platform,
                osVersion: osVersion,
                chip: chip,
                accountDisplayName: accountDisplayName,
                nebulaId: nebulaId,
                remoteVideoFormats: remoteVideoFormats,
                capabilities: capabilities,
                fileTransferPort: fileTransferPort,
                remoteControlPort: remoteControlPort,
                sentAt: sentAt
            )
        }
    }

    public struct ProtocolIdentityPublicKeyInfo: Codable, Sendable, Equatable {
        public let protocolSigningAlgorithm: String
        public let publicKey: Data

        public init(protocolSigningAlgorithm: String, publicKey: Data) {
            self.protocolSigningAlgorithm = protocolSigningAlgorithm
            self.publicKey = publicKey
        }

        public var normalizedAlgorithm: ProtocolSigningAlgorithm? {
            let raw = protocolSigningAlgorithm.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProtocolSigningAlgorithm(rawValue: raw)
        }

        public var authoritativeFingerprint: String? {
            guard let algorithm = normalizedAlgorithm, !publicKey.isEmpty else { return nil }
            return ProtocolIdentityPublicKeys(
                protocolPublicKey: publicKey,
                protocolAlgorithm: algorithm
            ).authoritativeFingerprint.lowercased()
        }

        public static func normalizedValidKeys(_ rawKeys: [ProtocolIdentityPublicKeyInfo]?) -> [ProtocolIdentityPublicKeyInfo]? {
            var byFingerprint: [String: ProtocolIdentityPublicKeyInfo] = [:]
            for key in rawKeys ?? [] {
                guard let algorithm = key.normalizedAlgorithm,
                      let fingerprint = key.authoritativeFingerprint,
                      !fingerprint.isEmpty else {
                    continue
                }
                byFingerprint[fingerprint] = ProtocolIdentityPublicKeyInfo(
                    protocolSigningAlgorithm: algorithm.rawValue,
                    publicKey: key.publicKey
                )
            }
            guard !byFingerprint.isEmpty else { return nil }
            return byFingerprint.keys.sorted().compactMap { byFingerprint[$0] }
        }
    }

    public enum KEMRefreshValidationError: Error, LocalizedError, Sendable, Equatable {
        case invalidVersion
        case invalidDeviceId
        case invalidProtocolIdentityPublicKey
        case invalidProtocolIdentityFingerprint
        case missingPinnedProtocolIdentity
        case pinnedProtocolIdentityMismatch(fingerprint: String)
        case invalidSignatureAlgorithm
        case invalidRequestNonce
        case missingKEMPublicKey
        case unknownSuite(wireId: UInt16)
        case classicSuiteRejected(wireId: UInt16)
        case invalidKEMPublicKeyLength(wireId: UInt16, expected: Int, actual: Int)
        case invalidKeyId
        case targetDeviceIdMismatch
        case expired
        case invalidValidityWindow
        case generationRollback(current: UInt64, incoming: UInt64)
        case policyMismatch
        case invalidRouteScope
        case missingRequestedSuite
        case requestExpired
        case requestFromFuture
        case missingSignature
        case requestNonceMismatch
        case requestHashMismatch
        case requestPolicyHashMismatch
        case responseSuiteNotRequested(wireId: UInt16)

        public var errorDescription: String? {
            switch self {
            case .invalidVersion: return "SKR-1 version is invalid"
            case .invalidDeviceId: return "SKR-1 device id is missing or invalid"
            case .invalidProtocolIdentityPublicKey: return "SKR-1 protocol identity public key is missing or invalid"
            case .invalidProtocolIdentityFingerprint: return "SKR-1 protocol identity fingerprint is invalid"
            case .missingPinnedProtocolIdentity: return "SKR-1 requires an existing pinned protocol identity"
            case .pinnedProtocolIdentityMismatch(let fingerprint):
                return "SKR-1 protocol identity fingerprint does not match pinned identity: \(fingerprint)"
            case .invalidSignatureAlgorithm: return "SKR-1 signature algorithm is unsupported"
            case .invalidRequestNonce: return "SKR-1 request nonce is missing or too short"
            case .missingKEMPublicKey: return "SKR-1 response does not contain a KEM public key"
            case .unknownSuite(let wireId): return String(format: "SKR-1 rejected unknown suite wireId=0x%04X", wireId)
            case .classicSuiteRejected(let wireId): return String(format: "SKR-1 rejected classic suite wireId=0x%04X", wireId)
            case .invalidKEMPublicKeyLength(let wireId, let expected, let actual):
                return String(format: "SKR-1 KEM key length mismatch wireId=0x%04X expected=%d actual=%d", wireId, expected, actual)
            case .invalidKeyId: return "SKR-1 key id is missing"
            case .targetDeviceIdMismatch: return "SKR-1 response device id does not match request target"
            case .expired: return "SKR-1 signed KEM refresh is expired"
            case .invalidValidityWindow: return "SKR-1 validity window is invalid"
            case .generationRollback(let current, let incoming):
                return "SKR-1 generation rollback detected current=\(current) incoming=\(incoming)"
            case .policyMismatch: return "SKR-1 policy does not match strict PQC"
            case .invalidRouteScope: return "SKR-1 route scope is invalid"
            case .missingRequestedSuite: return "SKR-1 requested suite list is empty"
            case .requestExpired: return "SKR-1 request timestamp is expired"
            case .requestFromFuture: return "SKR-1 request timestamp is too far in the future"
            case .missingSignature: return "SKR-1 signature is missing"
            case .requestNonceMismatch: return "SKR-1 request nonce mismatch"
            case .requestHashMismatch: return "SKR-1 request hash mismatch"
            case .requestPolicyHashMismatch: return "SKR-1 request policy hash mismatch"
            case .responseSuiteNotRequested(let wireId):
                return String(format: "SKR-1 response suite was not requested wireId=0x%04X", wireId)
            }
        }
    }

    public struct KEMRefreshRequestPayload: Codable, Sendable, Equatable {
        public static let domainSeparator = "SkyBridge-SKR-1-Request"
        public static let currentVersion = 1
        public static let maximumAcceptedAge: TimeInterval = 120
        public static let maximumAcceptedFutureSkew: TimeInterval = 30

        public let version: Int
        public let requesterDeviceId: String
        public let targetDeviceId: String
        public let requesterProtocolIdentityFingerprint: String?
        public let targetProtocolIdentityFingerprint: String?
        public let requestedSuiteWireIds: [UInt16]
        public let policyRequirePQC: Bool
        public let policyAllowClassicFallback: Bool
        public let policyHashHex: String?
        public let routeScope: String
        public let bonjourEndpointDigest: String?
        public let nonce: Data
        public let sentAt: Date

        public init(
            version: Int = Self.currentVersion,
            requesterDeviceId: String,
            targetDeviceId: String,
            requesterProtocolIdentityFingerprint: String? = nil,
            targetProtocolIdentityFingerprint: String? = nil,
            requestedSuiteWireIds: [UInt16],
            policyRequirePQC: Bool = true,
            policyAllowClassicFallback: Bool = false,
            policyHashHex: String? = nil,
            routeScope: String = "lan",
            bonjourEndpointDigest: String? = nil,
            nonce: Data,
            sentAt: Date = Date()
        ) {
            self.version = version
            self.requesterDeviceId = requesterDeviceId
            self.targetDeviceId = targetDeviceId
            self.requesterProtocolIdentityFingerprint = requesterProtocolIdentityFingerprint
            self.targetProtocolIdentityFingerprint = targetProtocolIdentityFingerprint
            self.requestedSuiteWireIds = requestedSuiteWireIds
            self.policyRequirePQC = policyRequirePQC
            self.policyAllowClassicFallback = policyAllowClassicFallback
            self.policyHashHex = AppMessage.normalizedHex(policyHashHex, exactCount: 64)
                ?? AppMessage.skr1PolicyHashHex(
                    requirePQC: policyRequirePQC,
                    allowClassicFallback: policyAllowClassicFallback,
                    routeScope: routeScope
                )
            self.routeScope = routeScope
            self.bonjourEndpointDigest = bonjourEndpointDigest
            self.nonce = nonce
            self.sentAt = sentAt
        }

        public var expectedPolicyHashHex: String {
            AppMessage.skr1PolicyHashHex(
                requirePQC: policyRequirePQC,
                allowClassicFallback: policyAllowClassicFallback,
                routeScope: routeScope
            )
        }

        public var hasExpectedPolicyHash: Bool {
            AppMessage.normalizedHex(policyHashHex, exactCount: 64) == expectedPolicyHashHex
        }

        public var hasRequesterProtocolIdentityFingerprint: Bool {
            AppMessage.normalizedFingerprint(requesterProtocolIdentityFingerprint) != nil
        }

        public var canonicalRequestHashHex: String {
            AppMessage.sha256Hex(canonicalPreimage)
        }

        public func validatedStrictResponderSuites(
            now: Date = Date(),
            maximumAcceptedAge: TimeInterval = Self.maximumAcceptedAge,
            maximumAcceptedFutureSkew: TimeInterval = Self.maximumAcceptedFutureSkew
        ) throws -> [CryptoSuite] {
            guard version == Self.currentVersion else { throw KEMRefreshValidationError.invalidVersion }
            guard policyRequirePQC, !policyAllowClassicFallback else { throw KEMRefreshValidationError.policyMismatch }
            guard hasExpectedPolicyHash else { throw KEMRefreshValidationError.requestPolicyHashMismatch }
            guard routeScope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "lan" else {
                throw KEMRefreshValidationError.invalidRouteScope
            }
            guard nonce.count >= 16 else { throw KEMRefreshValidationError.invalidRequestNonce }
            guard sentAt.timeIntervalSince(now) <= maximumAcceptedFutureSkew else {
                throw KEMRefreshValidationError.requestFromFuture
            }
            guard now.timeIntervalSince(sentAt) <= maximumAcceptedAge else {
                throw KEMRefreshValidationError.requestExpired
            }
            guard !requestedSuiteWireIds.isEmpty else { throw KEMRefreshValidationError.missingRequestedSuite }

            let suites = requestedSuiteWireIds.map(CryptoSuite.init(wireId:))
            for suite in suites {
                guard suite.isKnown else { throw KEMRefreshValidationError.unknownSuite(wireId: suite.wireId) }
                guard suite.isPQCGroup else { throw KEMRefreshValidationError.classicSuiteRejected(wireId: suite.wireId) }
            }
            return suites
        }

        public var canonicalPreimage: Data {
            let fields: [(String, String)] = [
                ("domain", Self.domainSeparator),
                ("version", String(version)),
                ("requesterDeviceId", AppMessage.normalizedToken(requesterDeviceId)),
                ("targetDeviceId", AppMessage.normalizedToken(targetDeviceId)),
                ("requesterProtocolIdentityFingerprint", AppMessage.normalizedFingerprint(requesterProtocolIdentityFingerprint) ?? ""),
                ("targetProtocolIdentityFingerprint", AppMessage.normalizedFingerprint(targetProtocolIdentityFingerprint) ?? ""),
                ("requestedSuiteWireIds", requestedSuiteWireIds.sorted().map { String(format: "0x%04X", $0) }.joined(separator: ",")),
                ("policyRequirePQC", policyRequirePQC ? "1" : "0"),
                ("policyAllowClassicFallback", policyAllowClassicFallback ? "1" : "0"),
                ("policyHashHex", AppMessage.normalizedHex(policyHashHex, exactCount: 64) ?? ""),
                ("routeScope", routeScope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
                ("bonjourEndpointDigest", AppMessage.normalizedToken(bonjourEndpointDigest ?? "")),
                ("nonce", nonce.base64EncodedString()),
                ("sentAtMs", String(AppMessage.millisecondsSinceEpoch(sentAt)))
            ]
            return AppMessage.canonicalLineEncoding(fields)
        }
    }

    /// Diagnostic-only negative response for SKR-1. It is intentionally not a
    /// trust-bearing message: clients may use it to surface a fail-fast stage,
    /// but must never import KEM material or continue the handshake from it.
    public struct KEMRefreshFailurePayload: Codable, Sendable, Equatable {
        public static let currentVersion = 1

        public let version: Int
        public let requesterDeviceId: String
        public let targetDeviceId: String
        public let stage: String
        public let reasonCode: String
        public let reason: String
        public let requestHashHex: String?
        public let sentAt: Date

        public init(
            version: Int = Self.currentVersion,
            requesterDeviceId: String,
            targetDeviceId: String,
            stage: String,
            reasonCode: String,
            reason: String,
            requestHashHex: String? = nil,
            sentAt: Date = Date()
        ) {
            self.version = version
            self.requesterDeviceId = requesterDeviceId
            self.targetDeviceId = targetDeviceId
            self.stage = stage
            self.reasonCode = reasonCode
            self.reason = reason
            self.requestHashHex = requestHashHex
            self.sentAt = sentAt
        }
    }

    public enum ProtocolIdentityBindingValidationError: Error, LocalizedError, Sendable, Equatable {
        case invalidVersion
        case invalidDeviceId
        case missingRequesterProtocolIdentity
        case invalidRequesterProtocolIdentity
        case invalidProtocolIdentityPublicKey
        case invalidProtocolIdentityFingerprint
        case invalidSignatureAlgorithm
        case invalidRequestNonce
        case missingRequesterSignature
        case expired
        case invalidValidityWindow
        case policyMismatch
        case invalidRouteScope
        case targetDeviceIdMismatch
        case missingSignature
        case requestNonceMismatch
        case requestHashMismatch

        public var errorDescription: String? {
            switch self {
            case .invalidVersion: return "PIB-1 version is invalid"
            case .invalidDeviceId: return "PIB-1 device id is missing or invalid"
            case .missingRequesterProtocolIdentity: return "PIB-1 requester protocol identity is missing"
            case .invalidRequesterProtocolIdentity: return "PIB-1 requester protocol identity is invalid"
            case .invalidProtocolIdentityPublicKey: return "PIB-1 protocol identity public key is missing or invalid"
            case .invalidProtocolIdentityFingerprint: return "PIB-1 protocol identity fingerprint is invalid"
            case .invalidSignatureAlgorithm: return "PIB-1 signature algorithm is unsupported"
            case .invalidRequestNonce: return "PIB-1 request nonce is missing or too short"
            case .missingRequesterSignature: return "PIB-1 requester signature is missing"
            case .expired: return "PIB-1 signed protocol identity binding is expired"
            case .invalidValidityWindow: return "PIB-1 validity window is invalid"
            case .policyMismatch: return "PIB-1 policy does not match strict PQC"
            case .invalidRouteScope: return "PIB-1 route scope is invalid"
            case .targetDeviceIdMismatch: return "PIB-1 response device id does not match request target"
            case .missingSignature: return "PIB-1 signature is missing"
            case .requestNonceMismatch: return "PIB-1 request nonce mismatch"
            case .requestHashMismatch: return "PIB-1 request hash mismatch"
            }
        }
    }

    /// PIB-1 asks a LAN peer to prove possession of its current protocol
    /// identity key. The response is intentionally identity-only: KEM material is
    /// still imported exclusively through SKR-1 after the user accepts the SAS.
    public struct ProtocolIdentityBindingRequestPayload: Codable, Sendable, Equatable {
        public static let domainSeparator = "SkyBridge-PIB-1-Request"
        public static let currentVersion = 2

        public let version: Int
        public let requesterDeviceId: String
        public let targetDeviceId: String
        public let requestedProtocolSigningAlgorithms: [String]
        public let requesterProtocolSigningAlgorithm: String?
        public let requesterProtocolIdentityPublicKey: Data?
        public let requesterProtocolIdentityFingerprint: String?
        public let requesterSignature: Data?
        public let policyRequirePQC: Bool
        public let policyAllowClassicFallback: Bool
        public let routeScope: String
        public let bonjourEndpointDigest: String?
        public let nonce: Data
        public let sentAt: Date

        public init(
            version: Int = Self.currentVersion,
            requesterDeviceId: String,
            targetDeviceId: String,
            requestedProtocolSigningAlgorithms: [String],
            requesterProtocolSigningAlgorithm: String? = nil,
            requesterProtocolIdentityPublicKey: Data? = nil,
            requesterProtocolIdentityFingerprint: String? = nil,
            requesterSignature: Data? = nil,
            policyRequirePQC: Bool = true,
            policyAllowClassicFallback: Bool = false,
            routeScope: String = "lan",
            bonjourEndpointDigest: String? = nil,
            nonce: Data,
            sentAt: Date = Date()
        ) {
            self.version = version
            self.requesterDeviceId = requesterDeviceId
            self.targetDeviceId = targetDeviceId
            self.requestedProtocolSigningAlgorithms = requestedProtocolSigningAlgorithms
            self.requesterProtocolSigningAlgorithm = requesterProtocolSigningAlgorithm
            self.requesterProtocolIdentityPublicKey = requesterProtocolIdentityPublicKey
            self.requesterProtocolIdentityFingerprint = requesterProtocolIdentityFingerprint
            self.requesterSignature = requesterSignature
            self.policyRequirePQC = policyRequirePQC
            self.policyAllowClassicFallback = policyAllowClassicFallback
            self.routeScope = routeScope
            self.bonjourEndpointDigest = bonjourEndpointDigest
            self.nonce = nonce
            self.sentAt = sentAt
        }

        public var canonicalRequestHashHex: String {
            AppMessage.sha256Hex(canonicalPreimage)
        }

        public var normalizedRequesterProtocolIdentity: ProtocolIdentityPublicKeyInfo? {
            guard let rawAlgorithm = requesterProtocolSigningAlgorithm?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let publicKey = requesterProtocolIdentityPublicKey,
                  !rawAlgorithm.isEmpty,
                  !publicKey.isEmpty,
                  let claimedFingerprint = AppMessage.normalizedFingerprint(requesterProtocolIdentityFingerprint),
                  let algorithm = ProtocolSigningAlgorithm(rawValue: rawAlgorithm) else {
                return nil
            }
            guard AppMessage.protocolIdentityFingerprint(
                algorithm: algorithm,
                publicKey: publicKey
            ) == claimedFingerprint else {
                return nil
            }
            return ProtocolIdentityPublicKeyInfo(
                protocolSigningAlgorithm: algorithm.rawValue,
                publicKey: publicKey
            )
        }

        public func validatedRequesterProtocolIdentity() throws -> ProtocolIdentityPublicKeyInfo {
            guard requesterProtocolSigningAlgorithm != nil
                    || requesterProtocolIdentityPublicKey != nil
                    || requesterProtocolIdentityFingerprint != nil else {
                throw ProtocolIdentityBindingValidationError.missingRequesterProtocolIdentity
            }
            guard let identity = normalizedRequesterProtocolIdentity,
                  identity.authoritativeFingerprint != nil else {
                throw ProtocolIdentityBindingValidationError.invalidRequesterProtocolIdentity
            }
            guard let signature = requesterSignature, !signature.isEmpty else {
                throw ProtocolIdentityBindingValidationError.missingRequesterSignature
            }
            return identity
        }

        public var canonicalPreimage: Data {
            let algorithms = requestedProtocolSigningAlgorithms
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted()
                .joined(separator: ",")
            let requesterAlgorithm = requesterProtocolSigningAlgorithm?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let requesterKeyHash = requesterProtocolIdentityPublicKey.map(AppMessage.sha256Hex) ?? ""
            let requesterFingerprint = AppMessage.normalizedFingerprint(requesterProtocolIdentityFingerprint) ?? ""
            let fields: [(String, String)] = [
                ("domain", Self.domainSeparator),
                ("version", String(version)),
                ("requesterDeviceId", AppMessage.normalizedToken(requesterDeviceId)),
                ("targetDeviceId", AppMessage.normalizedToken(targetDeviceId)),
                ("requestedProtocolSigningAlgorithms", algorithms),
                ("requesterProtocolSigningAlgorithm", requesterAlgorithm),
                ("requesterProtocolIdentityPublicKeyHash", requesterKeyHash),
                ("requesterProtocolIdentityFingerprint", requesterFingerprint),
                ("policyRequirePQC", policyRequirePQC ? "1" : "0"),
                ("policyAllowClassicFallback", policyAllowClassicFallback ? "1" : "0"),
                ("routeScope", routeScope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
                ("bonjourEndpointDigest", AppMessage.normalizedToken(bonjourEndpointDigest ?? "")),
                ("nonce", nonce.base64EncodedString()),
                ("sentAtMs", String(AppMessage.millisecondsSinceEpoch(sentAt)))
            ]
            return AppMessage.canonicalLineEncoding(fields)
        }
    }

    public struct SignedProtocolIdentityBindingPayload: Codable, Sendable, Equatable {
        public static let domainSeparator = "SkyBridge-PIB-1-SignedProtocolIdentityBinding"
        public static let currentVersion = 1

        public let version: Int
        public let deviceId: String
        public let aliases: [String]
        public let protocolSigningAlgorithm: String
        public let protocolIdentityPublicKey: Data
        public let protocolIdentityFingerprint: String
        public let deviceName: String?
        public let sentAt: Date
        public let expiresAt: Date
        public let requestNonce: Data
        public let requestHashHex: String?
        public let policyRequirePQC: Bool
        public let policyAllowClassicFallback: Bool
        public let routeScope: String
        public let bonjourEndpointDigest: String?
        public let signature: Data

        public init(
            version: Int = Self.currentVersion,
            deviceId: String,
            aliases: [String] = [],
            protocolSigningAlgorithm: String,
            protocolIdentityPublicKey: Data,
            protocolIdentityFingerprint: String,
            deviceName: String? = nil,
            sentAt: Date = Date(),
            expiresAt: Date,
            requestNonce: Data,
            requestHashHex: String? = nil,
            policyRequirePQC: Bool = true,
            policyAllowClassicFallback: Bool = false,
            routeScope: String = "lan",
            bonjourEndpointDigest: String? = nil,
            signature: Data
        ) {
            self.version = version
            self.deviceId = deviceId
            self.aliases = aliases
            self.protocolSigningAlgorithm = protocolSigningAlgorithm
            self.protocolIdentityPublicKey = protocolIdentityPublicKey
            self.protocolIdentityFingerprint = protocolIdentityFingerprint
            self.deviceName = deviceName
            self.sentAt = sentAt
            self.expiresAt = expiresAt
            self.requestNonce = requestNonce
            self.requestHashHex = requestHashHex
            self.policyRequirePQC = policyRequirePQC
            self.policyAllowClassicFallback = policyAllowClassicFallback
            self.routeScope = routeScope
            self.bonjourEndpointDigest = bonjourEndpointDigest
            self.signature = signature
        }

        public var normalizedForSignature: SignedProtocolIdentityBindingPayload? {
            let deviceId = AppMessage.normalizedToken(deviceId)
            let rawAlgorithm = protocolSigningAlgorithm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !deviceId.isEmpty,
                  let fingerprint = AppMessage.normalizedFingerprint(protocolIdentityFingerprint),
                  let algorithm = ProtocolSigningAlgorithm(rawValue: rawAlgorithm),
                  !protocolIdentityPublicKey.isEmpty,
                  AppMessage.protocolIdentityFingerprint(
                    algorithm: algorithm,
                    publicKey: protocolIdentityPublicKey
                  ) == fingerprint else {
                return nil
            }
            return .init(
                version: version,
                deviceId: deviceId,
                aliases: AppMessage.normalizedUniqueTokens(aliases),
                protocolSigningAlgorithm: rawAlgorithm,
                protocolIdentityPublicKey: protocolIdentityPublicKey,
                protocolIdentityFingerprint: fingerprint,
                deviceName: deviceName,
                sentAt: sentAt,
                expiresAt: expiresAt,
                requestNonce: requestNonce,
                requestHashHex: AppMessage.normalizedHex(requestHashHex),
                policyRequirePQC: policyRequirePQC,
                policyAllowClassicFallback: policyAllowClassicFallback,
                routeScope: routeScope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                bonjourEndpointDigest: AppMessage.normalizedToken(bonjourEndpointDigest ?? ""),
                signature: signature
            )
        }

        public var signaturePreimage: Data {
            let payload = normalizedForSignature ?? self
            let protocolKeyHash = AppMessage.sha256Hex(payload.protocolIdentityPublicKey)
            let fields: [(String, String)] = [
                ("domain", Self.domainSeparator),
                ("version", String(payload.version)),
                ("deviceId", AppMessage.normalizedToken(payload.deviceId)),
                ("aliases", AppMessage.normalizedUniqueTokens(payload.aliases).joined(separator: ",")),
                ("protocolSigningAlgorithm", payload.protocolSigningAlgorithm.trimmingCharacters(in: .whitespacesAndNewlines)),
                ("protocolIdentityPublicKeyHash", protocolKeyHash),
                ("protocolIdentityFingerprint", AppMessage.normalizedFingerprint(payload.protocolIdentityFingerprint) ?? ""),
                ("deviceName", AppMessage.normalizedToken(payload.deviceName ?? "")),
                ("sentAtMs", String(AppMessage.millisecondsSinceEpoch(payload.sentAt))),
                ("expiresAtMs", String(AppMessage.millisecondsSinceEpoch(payload.expiresAt))),
                ("requestNonce", payload.requestNonce.base64EncodedString()),
                ("requestHashHex", AppMessage.normalizedHex(payload.requestHashHex) ?? ""),
                ("policyRequirePQC", payload.policyRequirePQC ? "1" : "0"),
                ("policyAllowClassicFallback", payload.policyAllowClassicFallback ? "1" : "0"),
                ("routeScope", payload.routeScope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
                ("bonjourEndpointDigest", AppMessage.normalizedToken(payload.bonjourEndpointDigest ?? ""))
            ]
            return AppMessage.canonicalLineEncoding(fields)
        }

        public func validatedForOOBBinding(
            request: ProtocolIdentityBindingRequestPayload,
            now: Date = Date()
        ) throws -> SignedProtocolIdentityBindingPayload {
            guard version == Self.currentVersion else { throw ProtocolIdentityBindingValidationError.invalidVersion }
            let rawAlgorithm = protocolSigningAlgorithm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let algorithm = ProtocolSigningAlgorithm(rawValue: rawAlgorithm) else {
                throw ProtocolIdentityBindingValidationError.invalidSignatureAlgorithm
            }
            guard !protocolIdentityPublicKey.isEmpty else {
                throw ProtocolIdentityBindingValidationError.invalidProtocolIdentityPublicKey
            }
            guard let claimedFingerprint = AppMessage.normalizedFingerprint(protocolIdentityFingerprint) else {
                throw ProtocolIdentityBindingValidationError.invalidProtocolIdentityFingerprint
            }
            guard AppMessage.protocolIdentityFingerprint(
                algorithm: algorithm,
                publicKey: protocolIdentityPublicKey
            ) == claimedFingerprint else {
                throw ProtocolIdentityBindingValidationError.invalidProtocolIdentityFingerprint
            }
            guard let payload = normalizedForSignature else {
                throw ProtocolIdentityBindingValidationError.invalidDeviceId
            }
            guard payload.policyRequirePQC, !payload.policyAllowClassicFallback else {
                throw ProtocolIdentityBindingValidationError.policyMismatch
            }
            guard payload.routeScope == "lan" else { throw ProtocolIdentityBindingValidationError.invalidRouteScope }
            guard payload.requestNonce.count >= 16 else { throw ProtocolIdentityBindingValidationError.invalidRequestNonce }
            guard !payload.signature.isEmpty else { throw ProtocolIdentityBindingValidationError.missingSignature }
            guard payload.expiresAt > payload.sentAt else { throw ProtocolIdentityBindingValidationError.invalidValidityWindow }
            guard payload.expiresAt > now else { throw ProtocolIdentityBindingValidationError.expired }
            guard payload.requestNonce == request.nonce else {
                throw ProtocolIdentityBindingValidationError.requestNonceMismatch
            }
            guard payload.requestHashHex?.lowercased() == request.canonicalRequestHashHex else {
                throw ProtocolIdentityBindingValidationError.requestHashMismatch
            }
            let targetDeviceId = AppMessage.normalizedToken(request.targetDeviceId)
            let responseDeviceIds = Set(
                AppMessage.normalizedUniqueTokens([payload.deviceId] + payload.aliases)
            )
            guard !targetDeviceId.isEmpty, responseDeviceIds.contains(targetDeviceId) else {
                throw ProtocolIdentityBindingValidationError.targetDeviceIdMismatch
            }
            return payload
        }

        public func shortAuthenticationCode(
            request: ProtocolIdentityBindingRequestPayload
        ) -> String {
            var material = Data("SkyBridge-PIB-1-SAS\n".utf8)
            material.append(request.canonicalPreimage)
            material.append(request.requesterSignature ?? Data())
            material.append(signaturePreimage)
            material.append(signature)
            let digest = SHA256.hash(data: material)
            let raw = digest.withUnsafeBytes { ptr -> UInt32 in
                ptr.loadUnaligned(as: UInt32.self).bigEndian
            }
            return String(format: "%06d", Int(raw % 1_000_000))
        }
    }

    public struct SignedKEMRefreshPayload: Codable, Sendable, Equatable {
        public static let domainSeparator = "SkyBridge-SKR-1-SignedKEMRefresh"
        public static let currentVersion = 1

        public let version: Int
        public let deviceId: String
        public let aliases: [String]
        public let protocolSigningAlgorithm: String
        public let protocolIdentityPublicKey: Data
        public let protocolIdentityFingerprint: String
        public let kemPublicKeys: [KEMPublicKeyInfo]
        public let keyId: String
        public let generation: UInt64
        public let sentAt: Date
        public let expiresAt: Date
        public let requestNonce: Data
        public let requestHashHex: String?
        public let policyRequirePQC: Bool
        public let policyAllowClassicFallback: Bool
        public let routeScope: String
        public let bonjourEndpointDigest: String?
        public let signature: Data

        public init(
            version: Int = Self.currentVersion,
            deviceId: String,
            aliases: [String] = [],
            protocolSigningAlgorithm: String,
            protocolIdentityPublicKey: Data,
            protocolIdentityFingerprint: String,
            kemPublicKeys: [KEMPublicKeyInfo],
            keyId: String,
            generation: UInt64,
            sentAt: Date = Date(),
            expiresAt: Date,
            requestNonce: Data,
            requestHashHex: String? = nil,
            policyRequirePQC: Bool = true,
            policyAllowClassicFallback: Bool = false,
            routeScope: String = "lan",
            bonjourEndpointDigest: String? = nil,
            signature: Data
        ) {
            self.version = version
            self.deviceId = deviceId
            self.aliases = aliases
            self.protocolSigningAlgorithm = protocolSigningAlgorithm
            self.protocolIdentityPublicKey = protocolIdentityPublicKey
            self.protocolIdentityFingerprint = protocolIdentityFingerprint
            self.kemPublicKeys = kemPublicKeys
            self.keyId = keyId
            self.generation = generation
            self.sentAt = sentAt
            self.expiresAt = expiresAt
            self.requestNonce = requestNonce
            self.requestHashHex = requestHashHex
            self.policyRequirePQC = policyRequirePQC
            self.policyAllowClassicFallback = policyAllowClassicFallback
            self.routeScope = routeScope
            self.bonjourEndpointDigest = bonjourEndpointDigest
            self.signature = signature
        }

        public var normalizedForSignature: SignedKEMRefreshPayload? {
            let deviceId = AppMessage.normalizedToken(deviceId)
            let rawAlgorithm = protocolSigningAlgorithm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !deviceId.isEmpty,
                  let fingerprint = AppMessage.normalizedFingerprint(protocolIdentityFingerprint),
                  let algorithm = ProtocolSigningAlgorithm(rawValue: rawAlgorithm),
                  !protocolIdentityPublicKey.isEmpty,
                  AppMessage.protocolIdentityFingerprint(
                    algorithm: algorithm,
                    publicKey: protocolIdentityPublicKey
                  ) == fingerprint else {
                return nil
            }
            let keys = AppMessage.normalizedKEMPublicKeysForSignature(kemPublicKeys)
            return .init(
                version: version,
                deviceId: deviceId,
                aliases: AppMessage.normalizedUniqueTokens(aliases),
                protocolSigningAlgorithm: rawAlgorithm,
                protocolIdentityPublicKey: protocolIdentityPublicKey,
                protocolIdentityFingerprint: fingerprint,
                kemPublicKeys: keys,
                keyId: AppMessage.normalizedToken(keyId),
                generation: generation,
                sentAt: sentAt,
                expiresAt: expiresAt,
                requestNonce: requestNonce,
                requestHashHex: AppMessage.normalizedHex(requestHashHex),
                policyRequirePQC: policyRequirePQC,
                policyAllowClassicFallback: policyAllowClassicFallback,
                routeScope: routeScope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                bonjourEndpointDigest: AppMessage.normalizedToken(bonjourEndpointDigest ?? ""),
                signature: signature
            )
        }

        public var signaturePreimage: Data {
            let payload = normalizedForSignature ?? self
            let kemHash = AppMessage.kemPublicKeyHashHex(payload.kemPublicKeys)
            let protocolKeyHash = AppMessage.sha256Hex(payload.protocolIdentityPublicKey)
            let suiteNames = payload.kemPublicKeys
                .map { CryptoSuite(wireId: $0.suiteWireId).rawValue }
                .sorted()
                .joined(separator: ",")
            let fields: [(String, String)] = [
                ("domain", Self.domainSeparator),
                ("version", String(payload.version)),
                ("deviceId", AppMessage.normalizedToken(payload.deviceId)),
                ("aliases", AppMessage.normalizedUniqueTokens(payload.aliases).joined(separator: ",")),
                ("protocolSigningAlgorithm", payload.protocolSigningAlgorithm.trimmingCharacters(in: .whitespacesAndNewlines)),
                ("protocolIdentityPublicKeyHash", protocolKeyHash),
                ("protocolIdentityFingerprint", AppMessage.normalizedFingerprint(payload.protocolIdentityFingerprint) ?? ""),
                ("suiteNames", suiteNames),
                ("suiteWireIds", payload.kemPublicKeys.map { String(format: "0x%04X", $0.suiteWireId) }.sorted().joined(separator: ",")),
                ("kemPublicKeyHash", kemHash),
                ("keyId", AppMessage.normalizedToken(payload.keyId)),
                ("generation", String(payload.generation)),
                ("sentAtMs", String(AppMessage.millisecondsSinceEpoch(payload.sentAt))),
                ("expiresAtMs", String(AppMessage.millisecondsSinceEpoch(payload.expiresAt))),
                ("requestNonce", payload.requestNonce.base64EncodedString()),
                ("requestHashHex", AppMessage.normalizedHex(payload.requestHashHex) ?? ""),
                ("policyRequirePQC", payload.policyRequirePQC ? "1" : "0"),
                ("policyAllowClassicFallback", payload.policyAllowClassicFallback ? "1" : "0"),
                ("routeScope", payload.routeScope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
                ("bonjourEndpointDigest", AppMessage.normalizedToken(payload.bonjourEndpointDigest ?? ""))
            ]
            return AppMessage.canonicalLineEncoding(fields)
        }

        public func validatedForStrictPQCImport(
            now: Date = Date(),
            pinnedProtocolFingerprints: Set<String>,
            minimumGeneration: UInt64? = nil
        ) throws -> SignedKEMRefreshPayload {
            guard version == Self.currentVersion else { throw KEMRefreshValidationError.invalidVersion }
            let rawAlgorithm = protocolSigningAlgorithm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let algorithm = ProtocolSigningAlgorithm(rawValue: rawAlgorithm) else {
                throw KEMRefreshValidationError.invalidSignatureAlgorithm
            }
            guard !protocolIdentityPublicKey.isEmpty else {
                throw KEMRefreshValidationError.invalidProtocolIdentityPublicKey
            }
            guard let claimedFingerprint = AppMessage.normalizedFingerprint(protocolIdentityFingerprint) else {
                throw KEMRefreshValidationError.invalidProtocolIdentityFingerprint
            }
            guard AppMessage.protocolIdentityFingerprint(
                algorithm: algorithm,
                publicKey: protocolIdentityPublicKey
            ) == claimedFingerprint else {
                throw KEMRefreshValidationError.invalidProtocolIdentityFingerprint
            }
            guard !kemPublicKeys.isEmpty else { throw KEMRefreshValidationError.missingKEMPublicKey }
            guard let payload = normalizedForSignature else { throw KEMRefreshValidationError.invalidDeviceId }
            guard payload.policyRequirePQC, !payload.policyAllowClassicFallback else {
                throw KEMRefreshValidationError.policyMismatch
            }
            guard payload.routeScope == "lan" else { throw KEMRefreshValidationError.invalidRouteScope }
            guard !payload.keyId.isEmpty else { throw KEMRefreshValidationError.invalidKeyId }
            guard payload.requestNonce.count >= 16 else { throw KEMRefreshValidationError.invalidRequestNonce }
            guard !payload.signature.isEmpty else { throw KEMRefreshValidationError.missingSignature }
            guard payload.expiresAt > payload.sentAt else { throw KEMRefreshValidationError.invalidValidityWindow }
            guard payload.expiresAt > now else { throw KEMRefreshValidationError.expired }

            let normalizedPinned = Set(pinnedProtocolFingerprints.compactMap(AppMessage.normalizedFingerprint))
            guard !normalizedPinned.isEmpty else { throw KEMRefreshValidationError.missingPinnedProtocolIdentity }
            let fingerprint = claimedFingerprint
            guard normalizedPinned.contains(fingerprint) else {
                throw KEMRefreshValidationError.pinnedProtocolIdentityMismatch(fingerprint: fingerprint)
            }
            if let minimumGeneration, payload.generation < minimumGeneration {
                throw KEMRefreshValidationError.generationRollback(current: minimumGeneration, incoming: payload.generation)
            }

            guard !payload.kemPublicKeys.isEmpty else { throw KEMRefreshValidationError.missingKEMPublicKey }
            for key in payload.kemPublicKeys {
                let suite = CryptoSuite(wireId: key.suiteWireId)
                guard suite.isKnown else { throw KEMRefreshValidationError.unknownSuite(wireId: key.suiteWireId) }
                guard suite.isPQCGroup else { throw KEMRefreshValidationError.classicSuiteRejected(wireId: key.suiteWireId) }
                let expected = AppMessage.expectedKEMPublicKeyLength(for: suite)
                guard expected == 0 || key.publicKey.count == expected else {
                    throw KEMRefreshValidationError.invalidKEMPublicKeyLength(
                        wireId: key.suiteWireId,
                        expected: expected,
                        actual: key.publicKey.count
                    )
                }
            }

            return payload
        }

        public func validatedForStrictPQCImport(
            request: KEMRefreshRequestPayload,
            now: Date = Date(),
            pinnedProtocolFingerprints: Set<String>,
            minimumGeneration: UInt64? = nil
        ) throws -> SignedKEMRefreshPayload {
            guard request.hasExpectedPolicyHash else {
                throw KEMRefreshValidationError.requestPolicyHashMismatch
            }
            let requestedWireIds = Set(try request.validatedStrictResponderSuites(now: now).map(\.wireId))
            let payload = try validatedForStrictPQCImport(
                now: now,
                pinnedProtocolFingerprints: pinnedProtocolFingerprints,
                minimumGeneration: minimumGeneration
            )
            for key in payload.kemPublicKeys {
                guard requestedWireIds.contains(key.suiteWireId) else {
                    throw KEMRefreshValidationError.responseSuiteNotRequested(wireId: key.suiteWireId)
                }
            }
            guard payload.requestNonce == request.nonce else {
                throw KEMRefreshValidationError.requestNonceMismatch
            }
            guard AppMessage.normalizedHex(payload.requestHashHex, exactCount: 64) == request.canonicalRequestHashHex else {
                throw KEMRefreshValidationError.requestHashMismatch
            }
            let targetDeviceId = AppMessage.normalizedToken(request.targetDeviceId)
            let responseDeviceIds = Set(
                AppMessage.normalizedUniqueTokens([payload.deviceId] + payload.aliases)
            )
            guard !targetDeviceId.isEmpty, responseDeviceIds.contains(targetDeviceId) else {
                throw KEMRefreshValidationError.targetDeviceIdMismatch
            }
            return payload
        }
    }

    public struct HeartbeatPayload: Codable, Sendable, Equatable {
        public let sentAt: Date
        /// Optional identity metadata (best-effort). Backwards compatible: older builds ignore new fields.
        public let deviceId: String?
        public let deviceName: String?
        public let modelName: String?
        public let platform: String?
        public let osVersion: String?
        public let chip: String?
        public let accountDisplayName: String?
        public let nebulaId: String?
        public let remoteVideoFormats: [String]?
        public let capabilities: [String]?
        public let fileTransferPort: UInt16?
        public let remoteControlPort: UInt16?
        public let webrtcMedia: WebRTCMediaHeartbeatDiagnostics?

        public init(
            sentAt: Date = Date(),
            deviceId: String? = nil,
            deviceName: String? = nil,
            modelName: String? = nil,
            platform: String? = nil,
            osVersion: String? = nil,
            chip: String? = nil,
            accountDisplayName: String? = nil,
            nebulaId: String? = nil,
            remoteVideoFormats: [String]? = nil,
            capabilities: [String]? = nil,
            fileTransferPort: UInt16? = nil,
            remoteControlPort: UInt16? = nil,
            webrtcMedia: WebRTCMediaHeartbeatDiagnostics? = nil
        ) {
            self.sentAt = sentAt
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.modelName = modelName
            self.platform = platform
            self.osVersion = osVersion
            self.chip = chip
            self.accountDisplayName = accountDisplayName
            self.nebulaId = nebulaId
            self.remoteVideoFormats = remoteVideoFormats
            self.capabilities = capabilities
            self.fileTransferPort = fileTransferPort
            self.remoteControlPort = remoteControlPort
            self.webrtcMedia = webrtcMedia
        }
    }

    public struct WebRTCMediaHeartbeatDiagnostics: Codable, Sendable, Equatable {
        public let nativeVideoRendered: Bool
        public let nativeVideoWidth: Int?
        public let nativeVideoHeight: Int?
        public let audioRxDatagrams: UInt64?
        public let audioRxRecv: UInt64?
        public let audioRxDecoded: UInt64?
        public let audioRxPlayed: UInt64?
        public let audioRxRejected: UInt64?
        public let audioRxAuthRejected: UInt64?
        public let audioRxSessionHashRejected: UInt64?
        public let audioRxReplayRejected: UInt64?
        public let audioRxJitterEvicted: UInt64?
        public let audioRxPlaybackDropped: UInt64?
        public let audioRenderedFrames: UInt64?
        public let audioUnderflow: UInt64?
        public let audioRebuffer: UInt64?
        public let audioStartupSilenceFrames: UInt64?
        public let audioEngineRunning: Bool?

        public init(
            nativeVideoRendered: Bool,
            nativeVideoWidth: Int? = nil,
            nativeVideoHeight: Int? = nil,
            audioRxDatagrams: UInt64? = nil,
            audioRxRecv: UInt64? = nil,
            audioRxDecoded: UInt64? = nil,
            audioRxPlayed: UInt64? = nil,
            audioRxRejected: UInt64? = nil,
            audioRxAuthRejected: UInt64? = nil,
            audioRxSessionHashRejected: UInt64? = nil,
            audioRxReplayRejected: UInt64? = nil,
            audioRxJitterEvicted: UInt64? = nil,
            audioRxPlaybackDropped: UInt64? = nil,
            audioRenderedFrames: UInt64? = nil,
            audioUnderflow: UInt64? = nil,
            audioRebuffer: UInt64? = nil,
            audioStartupSilenceFrames: UInt64? = nil,
            audioEngineRunning: Bool? = nil
        ) {
            self.nativeVideoRendered = nativeVideoRendered
            self.nativeVideoWidth = nativeVideoWidth
            self.nativeVideoHeight = nativeVideoHeight
            self.audioRxDatagrams = audioRxDatagrams
            self.audioRxRecv = audioRxRecv
            self.audioRxDecoded = audioRxDecoded
            self.audioRxPlayed = audioRxPlayed
            self.audioRxRejected = audioRxRejected
            self.audioRxAuthRejected = audioRxAuthRejected
            self.audioRxSessionHashRejected = audioRxSessionHashRejected
            self.audioRxReplayRejected = audioRxReplayRejected
            self.audioRxJitterEvicted = audioRxJitterEvicted
            self.audioRxPlaybackDropped = audioRxPlaybackDropped
            self.audioRenderedFrames = audioRenderedFrames
            self.audioUnderflow = audioUnderflow
            self.audioRebuffer = audioRebuffer
            self.audioStartupSilenceFrames = audioStartupSilenceFrames
            self.audioEngineRunning = audioEngineRunning
        }
    }

    public struct PeerDisconnectingPayload: Codable, Sendable, Equatable {
        public let deviceId: String?
        public let deviceName: String?
        public let sentAt: Date

        public init(
            deviceId: String? = nil,
            deviceName: String? = nil,
            sentAt: Date = Date()
        ) {
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.sentAt = sentAt
        }
    }

    /// Ping request payload. Receiver should respond with `pong(id:)` as fast as possible.
    public struct PingPayload: Codable, Sendable, Equatable {
        public let id: UInt64

        public init(id: UInt64) {
            self.id = id
        }
    }

    /// Pong response payload (echoes `PingPayload.id`).
    public struct PongPayload: Codable, Sendable, Equatable {
        public let id: UInt64

        public init(id: UInt64) {
            self.id = id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case clipboard
        case pairingIdentityExchange
        case kemRefreshRequest
        case signedKEMRefresh
        case kemRefreshFailure
        case protocolIdentityBindingRequest
        case signedProtocolIdentityBinding
        case heartbeat
        case peerDisconnecting
        case ping
        case pong
    }

    private struct LegacyAssociatedValueBox<Value: Decodable>: Decodable {
        let _0: Value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let payload = try? container.decode(ClipboardPayload.self, forKey: .clipboard) {
            self = .clipboard(payload)
            return
        }
        if let payload = try? container.decode(PairingIdentityExchangePayload.self, forKey: .pairingIdentityExchange) {
            self = .pairingIdentityExchange(payload)
            return
        }
        if let payload = try? container.decode(KEMRefreshRequestPayload.self, forKey: .kemRefreshRequest) {
            self = .kemRefreshRequest(payload)
            return
        }
        if let payload = try? container.decode(SignedKEMRefreshPayload.self, forKey: .signedKEMRefresh) {
            self = .signedKEMRefresh(payload)
            return
        }
        if let payload = try? container.decode(KEMRefreshFailurePayload.self, forKey: .kemRefreshFailure) {
            self = .kemRefreshFailure(payload)
            return
        }
        if let payload = try? container.decode(ProtocolIdentityBindingRequestPayload.self, forKey: .protocolIdentityBindingRequest) {
            self = .protocolIdentityBindingRequest(payload)
            return
        }
        if let payload = try? container.decode(SignedProtocolIdentityBindingPayload.self, forKey: .signedProtocolIdentityBinding) {
            self = .signedProtocolIdentityBinding(payload)
            return
        }
        if let payload = try? container.decode(HeartbeatPayload.self, forKey: .heartbeat) {
            self = .heartbeat(payload)
            return
        }
        if let payload = try? container.decode(PeerDisconnectingPayload.self, forKey: .peerDisconnecting) {
            self = .peerDisconnecting(payload)
            return
        }
        if let payload = try? container.decode(PingPayload.self, forKey: .ping) {
            self = .ping(payload)
            return
        }
        if let payload = try? container.decode(PongPayload.self, forKey: .pong) {
            self = .pong(payload)
            return
        }

        if let payload = (try? container.decode(LegacyAssociatedValueBox<ClipboardPayload>.self, forKey: .clipboard))?._0 {
            self = .clipboard(payload)
            return
        }
        if let payload = (try? container.decode(LegacyAssociatedValueBox<PairingIdentityExchangePayload>.self, forKey: .pairingIdentityExchange))?._0 {
            self = .pairingIdentityExchange(payload)
            return
        }
        if let payload = (try? container.decode(LegacyAssociatedValueBox<KEMRefreshRequestPayload>.self, forKey: .kemRefreshRequest))?._0 {
            self = .kemRefreshRequest(payload)
            return
        }
        if let payload = (try? container.decode(LegacyAssociatedValueBox<SignedKEMRefreshPayload>.self, forKey: .signedKEMRefresh))?._0 {
            self = .signedKEMRefresh(payload)
            return
        }
        if let payload = (try? container.decode(LegacyAssociatedValueBox<KEMRefreshFailurePayload>.self, forKey: .kemRefreshFailure))?._0 {
            self = .kemRefreshFailure(payload)
            return
        }
        if let payload = (try? container.decode(LegacyAssociatedValueBox<ProtocolIdentityBindingRequestPayload>.self, forKey: .protocolIdentityBindingRequest))?._0 {
            self = .protocolIdentityBindingRequest(payload)
            return
        }
        if let payload = (try? container.decode(LegacyAssociatedValueBox<SignedProtocolIdentityBindingPayload>.self, forKey: .signedProtocolIdentityBinding))?._0 {
            self = .signedProtocolIdentityBinding(payload)
            return
        }
        if let payload = (try? container.decode(LegacyAssociatedValueBox<HeartbeatPayload>.self, forKey: .heartbeat))?._0 {
            self = .heartbeat(payload)
            return
        }
        if let payload = (try? container.decode(LegacyAssociatedValueBox<PeerDisconnectingPayload>.self, forKey: .peerDisconnecting))?._0 {
            self = .peerDisconnecting(payload)
            return
        }
        if let payload = (try? container.decode(LegacyAssociatedValueBox<PingPayload>.self, forKey: .ping))?._0 {
            self = .ping(payload)
            return
        }
        if let payload = (try? container.decode(LegacyAssociatedValueBox<PongPayload>.self, forKey: .pong))?._0 {
            self = .pong(payload)
            return
        }

        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported AppMessage payload"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .clipboard(let payload):
            try container.encode(payload, forKey: .clipboard)
        case .pairingIdentityExchange(let payload):
            try container.encode(payload, forKey: .pairingIdentityExchange)
        case .kemRefreshRequest(let payload):
            try container.encode(payload, forKey: .kemRefreshRequest)
        case .signedKEMRefresh(let payload):
            try container.encode(payload, forKey: .signedKEMRefresh)
        case .kemRefreshFailure(let payload):
            try container.encode(payload, forKey: .kemRefreshFailure)
        case .protocolIdentityBindingRequest(let payload):
            try container.encode(payload, forKey: .protocolIdentityBindingRequest)
        case .signedProtocolIdentityBinding(let payload):
            try container.encode(payload, forKey: .signedProtocolIdentityBinding)
        case .heartbeat(let payload):
            try container.encode(payload, forKey: .heartbeat)
        case .peerDisconnecting(let payload):
            try container.encode(payload, forKey: .peerDisconnecting)
        case .ping(let payload):
            try container.encode(payload, forKey: .ping)
        case .pong(let payload):
            try container.encode(payload, forKey: .pong)
        }
    }

    private static func canonicalLineEncoding(_ fields: [(String, String)]) -> Data {
        Data(fields.map { "\($0.0)=\($0.1)" }.joined(separator: "\n").utf8)
    }

    private static func millisecondsSinceEpoch(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000.0).rounded(.down))
    }

    private static func normalizedToken(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "=" }) else {
            return ""
        }
        return value
    }

    private static func normalizedUniqueTokens(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in raw.map(normalizedToken).filter({ !$0.isEmpty }).sorted()
            where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private static func normalizedFingerprint(_ raw: String?) -> String? {
        normalizedHex(raw, exactCount: 64)
    }

    private static func normalizedHex(_ raw: String?, exactCount: Int? = nil) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.allSatisfy(\.isHexDigit) else { return nil }
        if let exactCount, value.count != exactCount { return nil }
        return value
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func skr1PolicyHashHex(
        requirePQC: Bool,
        allowClassicFallback: Bool,
        routeScope: String
    ) -> String {
        let fields: [(String, String)] = [
            ("domain", "SkyBridge-SKR-1-Policy"),
            ("version", String(KEMRefreshRequestPayload.currentVersion)),
            ("policyRequirePQC", requirePQC ? "1" : "0"),
            ("policyAllowClassicFallback", allowClassicFallback ? "1" : "0"),
            ("routeScope", routeScope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        ]
        return sha256Hex(canonicalLineEncoding(fields))
    }

    private static func protocolIdentityFingerprint(
        algorithm: ProtocolSigningAlgorithm,
        publicKey: Data
    ) -> String {
        ProtocolIdentityPublicKeys(
            protocolPublicKey: publicKey,
            protocolAlgorithm: algorithm
        ).authoritativeFingerprint.lowercased()
    }

    private static func kemPublicKeyHashHex(_ keys: [KEMPublicKeyInfo]) -> String {
        var material = Data("SkyBridge-SKR-1-KEMPublicKeys\n".utf8)
        for key in normalizedKEMPublicKeysForSignature(keys) {
            var wireId = key.suiteWireId.littleEndian
            var length = UInt32(key.publicKey.count).littleEndian
            material.append(Data(bytes: &wireId, count: MemoryLayout<UInt16>.size))
            material.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
            material.append(key.publicKey)
        }
        return sha256Hex(material)
    }

    private static func normalizedKEMPublicKeysForSignature(_ keys: [KEMPublicKeyInfo]) -> [KEMPublicKeyInfo] {
        var bySuite: [UInt16: KEMPublicKeyInfo] = [:]
        for key in keys where !key.publicKey.isEmpty {
            bySuite[key.suiteWireId] = key
        }
        return bySuite.keys.sorted().compactMap { bySuite[$0] }
    }

    private static func expectedKEMPublicKeyLength(for suite: CryptoSuite) -> Int {
        switch suite.canonicalKEMSuite.wireId {
        case 0x0001: return 1216
        case 0x0101, 0x0102: return 1184
        default: return 0
        }
    }
}
