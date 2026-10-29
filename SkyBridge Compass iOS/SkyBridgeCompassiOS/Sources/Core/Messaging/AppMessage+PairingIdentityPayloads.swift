import Foundation

@available(iOS 17.0, *)
public extension AppMessage {
    /// Minimal identity bundle used to bootstrap PQC handshake:
    /// - provides peer KEM identity public keys (suiteWireId -> publicKey)
    /// - provides stable deviceId for trust store indexing
    struct PairingIdentityExchangePayload: Codable, Sendable, Equatable {
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
            let validKEMKeys = KEMPublicKeyInfo.normalizedValidKeys(
                kemPublicKeys,
                platform: platform,
                osVersion: osVersion
            )
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

    struct ProtocolIdentityPublicKeyInfo: Codable, Sendable, Equatable {
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
            guard let algorithm = normalizedAlgorithm,
                  Self.hasValidPublicKeyLength(publicKey, algorithm: algorithm) else {
                return nil
            }
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

        private static func hasValidPublicKeyLength(
            _ publicKey: Data,
            algorithm: ProtocolSigningAlgorithm
        ) -> Bool {
            switch algorithm {
            case .ed25519:
                return publicKey.count == 32
            case .mlDSA65:
                return publicKey.count == 1_952
            case .mlDSA87:
                return publicKey.count == 2_592
            }
        }
    }
}
