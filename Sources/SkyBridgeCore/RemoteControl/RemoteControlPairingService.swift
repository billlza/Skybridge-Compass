import CryptoKit
import Foundation
import SkyBridgeProtocolCore

public enum RemoteControlPairingError: Error, LocalizedError, Sendable, Equatable {
    case invalidMaterial(String)
    case unsupportedLocalAlgorithm
    case missingCommittedKEM
    case missingCommittedQKEM
    case missingDeviceName
    case conflictingTrust
    case inactiveTrust
    case localIdentityImport

    public var errorDescription: String? {
        switch self {
        case .invalidMaterial(let field): return "Remote-control pairing material is invalid: \(field)"
        case .unsupportedLocalAlgorithm: return "Windows LAN pairing requires the active committed ML-DSA-65 identity"
        case .missingCommittedKEM: return "A supported KEM identity has not been committed on this device"
        case .missingCommittedQKEM: return "The requested Q-Periapt identity has not been committed on this device"
        case .missingDeviceName: return "The system did not provide a device name for pairing"
        case .conflictingTrust: return "The imported device conflicts with an existing trusted identity or KEM key"
        case .inactiveTrust: return "The imported device has revoked, quarantined or pending trust and cannot be reauthorized by import"
        case .localIdentityImport: return "The local identity cannot be imported as a remote device"
        }
    }
}

/// Public-only pairing contract shared with the Windows LAN host. The user
/// explicitly approves the material; protocol authentication follows on connect.
public struct RemoteControlPairingMaterial: Sendable, Equatable {
    public let deviceId: String
    public let name: String
    public let protocolPublicKey: Data
    public let protocolPublicKeyFingerprint: String
    public let kemPublicKey: Data
    public let qPeriaptPublicKey: Data

    public init(deviceId: String, name: String, protocolPublicKey: Data, kemPublicKey: Data, qPeriaptPublicKey: Data = Data()) throws {
        guard let canonical = PeerTrustLookup.persistentDeviceId(from: deviceId), canonical.count <= 131 else {
            throw RemoteControlPairingError.invalidMaterial("stable deviceId")
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 128,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RemoteControlPairingError.invalidMaterial("device name")
        }
        guard protocolPublicKey.count == 1_952,
              kemPublicKey.isEmpty || kemPublicKey.count == 1_184,
              qPeriaptPublicKey.isEmpty || qPeriaptPublicKey.count == 1_216,
              !kemPublicKey.isEmpty || !qPeriaptPublicKey.isEmpty else {
            throw RemoteControlPairingError.invalidMaterial("ML-DSA-65, ML-KEM-768 or Q-Periapt key length")
        }
        self.deviceId = canonical
        self.name = name
        self.protocolPublicKey = protocolPublicKey
        self.protocolPublicKeyFingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA65, publicKeyBytes: protocolPublicKey
        )
        self.kemPublicKey = kemPublicKey
        self.qPeriaptPublicKey = qPeriaptPublicKey
    }

    public static func decode(_ data: Data) throws -> Self {
        let expectedFields: Set<String> = ["schemaVersion", "deviceId", "name", "protocolSigningAlgorithm",
                                          "protocolPublicKey", "protocolPublicKeyFingerprint", "kemPublicKeys"]
        let fields = try StrictJSONSingleDiscriminatorWireValidator.validatedRootFields(
            in: data, allowedFields: expectedFields, maximumByteCount: 32_768
        )
        guard fields == expectedFields else { throw RemoteControlPairingError.invalidMaterial("missing fields") }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard wire.schemaVersion == 1, wire.protocolSigningAlgorithm == "ML-DSA-65",
              (1...2).contains(wire.kemPublicKeys.count),
              Set(wire.kemPublicKeys.map(\.suiteWireId)).count == wire.kemPublicKeys.count else {
            throw RemoteControlPairingError.invalidMaterial("schema, signing algorithm or duplicate KEM suite")
        }
        for key in wire.kemPublicKeys {
            switch key.suiteWireId {
            case CryptoSuite.mlkem768MLDSA65.wireId:
                guard key.publicKey.count == 1_184 else { throw RemoteControlPairingError.invalidMaterial("ML-KEM-768 key length") }
            case CryptoSuite.qperiaptABI2PolicyBound.wireId:
                guard key.publicKey.count == 1_216 else { throw RemoteControlPairingError.invalidMaterial("Q-Periapt key length") }
            default:
                throw RemoteControlPairingError.invalidMaterial("unsupported KEM suite")
            }
        }
        let material = try Self(deviceId: wire.deviceId, name: wire.name,
            protocolPublicKey: wire.protocolPublicKey,
            kemPublicKey: wire.kemPublicKeys.first { $0.suiteWireId == CryptoSuite.mlkem768MLDSA65.wireId }?.publicKey ?? Data(),
            qPeriaptPublicKey: wire.kemPublicKeys.first { $0.suiteWireId == CryptoSuite.qperiaptABI2PolicyBound.wireId }?.publicKey ?? Data())
        guard material.protocolPublicKeyFingerprint == wire.protocolPublicKeyFingerprint else {
            throw RemoteControlPairingError.invalidMaterial("protocol fingerprint")
        }
        return material
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Wire(schemaVersion: 1, deviceId: deviceId, name: name,
            protocolSigningAlgorithm: "ML-DSA-65", protocolPublicKey: protocolPublicKey,
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprint,
            kemPublicKeys: publicKEMKeys.map { Wire.KEMKey(suiteWireId: $0.suiteWireId, publicKey: $0.publicKey) }))
    }

    private struct Wire: Codable {
        let schemaVersion: Int
        let deviceId: String
        let name: String
        let protocolSigningAlgorithm: String
        let protocolPublicKey: Data
        let protocolPublicKeyFingerprint: String
        let kemPublicKeys: [KEMKey]

        struct KEMKey: Codable {
            let suiteWireId: UInt16
            let publicKey: Data

            init(suiteWireId: UInt16, publicKey: Data) {
                self.suiteWireId = suiteWireId
                self.publicKey = publicKey
            }

            init(from decoder: any Decoder) throws {
                let keys = try decoder.container(keyedBy: Field.self)
                guard Set(keys.allKeys.map(\.stringValue)) == ["suiteWireId", "publicKey"] else {
                    throw RemoteControlPairingError.invalidMaterial("KEM fields")
                }
                suiteWireId = try keys.decode(UInt16.self, forKey: Field("suiteWireId"))
                publicKey = try keys.decode(Data.self, forKey: Field("publicKey"))
            }

            private struct Field: CodingKey {
                let stringValue: String
                var intValue: Int? { nil }
                init(_ value: String) { stringValue = value }
                init?(stringValue: String) { self.stringValue = stringValue }
                init?(intValue: Int) { return nil }
            }
        }
    }

    func trustRecord(approvedAt: Date) -> TrustRecord {
        TrustRecord(deviceId: deviceId,
            pubKeyFP: SHA256.hash(data: protocolPublicKey).map { String(format: "%02x", $0) }.joined(),
            publicKey: protocolPublicKey,
            protocolPublicKey: protocolPublicKey,
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprint,
            protocolIdentityBindingsV2: [ProtocolIdentityBindingV2(algorithm: .mlDSA65,
                publicKey: protocolPublicKey, fingerprint: protocolPublicKeyFingerprint,
                source: .manualPairingImport, approvedAt: approvedAt, generation: 1)],
            signatureAlgorithm: .mlDSA65,
            kemPublicKeys: publicKEMKeys,
            createdAt: approvedAt, updatedAt: approvedAt, signature: Data(), deviceName: name,
            currentDeviceId: deviceId, knownDeviceIds: [deviceId], lifecycleState: .active)
    }

    private var publicKEMKeys: [KEMPublicKeyInfo] {
        var keys: [KEMPublicKeyInfo] = []
        if !qPeriaptPublicKey.isEmpty {
            keys.append(KEMPublicKeyInfo(suiteWireId: CryptoSuite.qperiaptABI2PolicyBound.wireId, publicKey: qPeriaptPublicKey))
        }
        if !kemPublicKey.isEmpty {
            keys.append(KEMPublicKeyInfo(suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId, publicKey: kemPublicKey))
        }
        return keys
    }

    /// Runs inside TrustSyncService's mutation gate, including denied/tombstoned records.
    func requiresImport(in records: [TrustRecord]) throws -> Bool {
        try recordForImport(in: records, approvedAt: Date()) != nil
    }

    /// An explicit import may add a new KEM suite to the same pinned identity.
    /// It must not replace a key, remove an existing suite or reset trust metadata.
    func recordForImport(in records: [TrustRecord], approvedAt: Date) throws -> TrustRecord? {
        var matches: [TrustRecord] = []
        var existingKeys: [UInt16: Data] = [:]
        for record in records {
            let sameId = PeerTrustLookup.recordLookupCandidates(record).contains {
                PeerTrustLookup.persistentDeviceId(from: $0) == deviceId
            }
            let sameFingerprint = record.currentPathAuthorityFingerprints.contains(protocolPublicKeyFingerprint)
            guard sameId || sameFingerprint else { continue }
            guard record.isAuthenticationEligible else { throw RemoteControlPairingError.inactiveTrust }
            guard sameId,
                  PeerTrustLookup.persistentDeviceId(from: record.currentDeviceId) == deviceId,
                  let binding = record.authenticatedProtocolIdentityBinding(for: .mlDSA65),
                  binding.publicKey == protocolPublicKey,
                  binding.fingerprint == protocolPublicKeyFingerprint else {
                throw RemoteControlPairingError.conflictingTrust
            }
            for key in record.kemPublicKeys ?? [] {
                if let known = existingKeys[key.suiteWireId], known != key.publicKey {
                    throw RemoteControlPairingError.conflictingTrust
                }
                existingKeys[key.suiteWireId] = key.publicKey
            }
            matches.append(record)
        }
        guard !matches.isEmpty else { return trustRecord(approvedAt: approvedAt) }
        var additions: [KEMPublicKeyInfo] = []
        for key in publicKEMKeys {
            if let known = existingKeys[key.suiteWireId] {
                guard known == key.publicKey else { throw RemoteControlPairingError.conflictingTrust }
            } else {
                additions.append(key)
            }
        }
        guard !additions.isEmpty else { return nil }
        // Updating ambiguous alias records requires explicit reconciliation, not
        // selecting an arbitrary authority and overwriting its metadata.
        guard matches.count == 1, let existing = matches.first else {
            throw RemoteControlPairingError.conflictingTrust
        }
        let mergedKeys = (existing.kemPublicKeys ?? []) + additions
        return TrustRecord(
            deviceId: existing.deviceId, pubKeyFP: existing.pubKeyFP, publicKey: existing.publicKey,
            secureEnclavePublicKey: existing.secureEnclavePublicKey,
            protocolPublicKey: existing.protocolPublicKey, protocolSigningAlgorithm: existing.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: existing.protocolPublicKeyFingerprint,
            protocolIdentityPins: existing.protocolIdentityPins, protocolIdentityBindingsV2: existing.protocolIdentityBindingsV2,
            legacyP256PublicKey: existing.legacyP256PublicKey, signatureAlgorithm: existing.signatureAlgorithm,
            kemPublicKeys: mergedKeys, attestationLevel: existing.attestationLevel, attestationData: existing.attestationData,
            capabilities: existing.capabilities, createdAt: existing.createdAt, updatedAt: approvedAt,
            version: existing.version, signaturePayloadVersion: existing.signaturePayloadVersion, signature: Data(),
            recordType: existing.recordType, revokedAt: existing.revokedAt, deviceName: existing.deviceName,
            currentDeviceId: existing.currentDeviceIdMetadata, knownDeviceIds: existing.knownDeviceIdsMetadata,
            lifecycleState: existing.lifecycleStateMetadata)
    }

}

@available(macOS 14.0, iOS 17.0, *)
@MainActor
public enum RemoteControlPairingService {
    public static func exportLocalMaterial() async throws -> RemoteControlPairingMaterial {
        let manager = DeviceIdentityKeyManager.shared
        let qRequested = try QPeriaptPlatformPolicy.requireRequestedRuntimeAdmission()
        let qProvider = qRequested ? QPeriaptPlatformPolicy.makeCryptoProvider() : nil
        if qRequested, qProvider == nil { throw CryptoProviderError.providerNotAvailable(.qPeriapt) }
        let identity = try await CommittedLocalProtocolIdentitySnapshot.loadActive(keyManager: manager)
        guard identity.algorithm == .mlDSA65 else { throw RemoteControlPairingError.unsupportedLocalAlgorithm }
        let deviceId = try await SelfIdentityProvider.shared.existingProtocolIdentityDeviceIdReadOnly()
        let baseProvider = CryptoProviderFactory.make(policy: .requirePQC)
        let kemKey = try await manager.existingKEMPublicKey(for: .mlkem768MLDSA65, baseProvider: baseProvider)
        let qKey: Data?
        if let qProvider {
            guard let committed = try await manager.existingKEMPublicKey(
                for: .qperiaptABI2PolicyBound, baseProvider: baseProvider, qPeriaptProvider: qProvider
            ) else { throw RemoteControlPairingError.missingCommittedQKEM }
            qKey = committed
        } else { qKey = nil }
        guard kemKey != nil || qKey != nil else { throw RemoteControlPairingError.missingCommittedKEM }
        let currentIdentity = try await CommittedLocalProtocolIdentitySnapshot.loadActive(keyManager: manager)
        guard QPeriaptPlatformPolicy.isRequested() == qRequested,
              !qRequested || QPeriaptPlatformPolicy.makeCryptoProvider()?.qPeriaptProviderIdentity == qProvider?.qPeriaptProviderIdentity,
              currentIdentity.algorithm == identity.algorithm, currentIdentity.protection == identity.protection,
              currentIdentity.publicKey == identity.publicKey,
              try await SelfIdentityProvider.shared.existingProtocolIdentityDeviceIdReadOnly() == deviceId else {
            throw CommittedLocalProtocolIdentitySnapshotError.configurationChanged
        }
        guard let name = LocalHostName.localizedName else { throw RemoteControlPairingError.missingDeviceName }
        return try RemoteControlPairingMaterial(deviceId: deviceId, name: name,
                                               protocolPublicKey: identity.publicKey, kemPublicKey: kemKey ?? Data(), qPeriaptPublicKey: qKey ?? Data())
    }

    /// The UI must call this only after the user explicitly imports the public pairing material.
    @discardableResult
    public static func importMaterial(_ material: RemoteControlPairingMaterial) async throws -> Bool {
        let localDeviceId = try await SelfIdentityProvider.shared.existingProtocolIdentityDeviceIdReadOnly()
        let localIdentity = try await CommittedLocalProtocolIdentitySnapshot.loadActive()
        guard material.deviceId != PeerTrustLookup.persistentDeviceId(from: localDeviceId),
              material.protocolPublicKeyFingerprint != localIdentity.authoritativeFingerprint else {
            throw RemoteControlPairingError.localIdentityImport
        }
        let approvedAt = Date()
        return try await TrustSyncService.shared.addTrustRecordIfNeeded { records in
            try material.recordForImport(in: records, approvedAt: approvedAt)
        }
    }
}
