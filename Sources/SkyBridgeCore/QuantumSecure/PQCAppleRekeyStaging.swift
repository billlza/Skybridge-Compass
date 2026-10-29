import CryptoKit
import Foundation
import OQSRAII
import OSLog

/// Stages a new Apple CryptoKit ML-DSA identity beside an existing liboqs
/// identity without changing the active backend.
///
/// The operation is deliberately not described as a byte-for-byte conversion:
/// liboqs secret keys cannot be imported as CryptoKit integrity-checked
/// representations. Staging therefore creates a new identity that cannot
/// become active until a separate, explicit peer re-pinning transaction exists.
enum PQCAppleRekeyStaging {
    private static let logger = Logger(
        subsystem: "com.skybridge.quantum",
        category: "PQCAppleRekeyStaging"
    )

    enum StagingError: Error, Equatable, LocalizedError, Sendable {
        case unsupportedPlatform
        case invalidPeerId
        case unsupportedAlgorithm(String)
        case keyNotFound
        case incompleteSourceKeyPair
        case invalidSourceKeyPair
        case stagingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedPlatform:
                return "Apple CryptoKit PQC is unavailable on this platform"
            case .invalidPeerId:
                return "PQC re-key staging peer identity is empty"
            case .unsupportedAlgorithm(let algorithm):
                return "PQC re-key staging does not support algorithm: \(algorithm)"
            case .keyNotFound:
                return "No existing liboqs ML-DSA key pair was found"
            case .incompleteSourceKeyPair:
                return "The existing liboqs ML-DSA key pair is incomplete"
            case .invalidSourceKeyPair:
                return "The existing liboqs ML-DSA public and private keys do not form a valid pair"
            case .stagingFailed(let reason):
                return "Apple PQC re-key staging failed: \(reason)"
            }
        }
    }

    private enum SupportedAlgorithm: String, Sendable {
        case mlDSA65 = "ML-DSA-65"

        init(requestedValue: String) throws {
            let normalized = requestedValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard normalized == Self.mlDSA65.rawValue else {
                throw StagingError.unsupportedAlgorithm(requestedValue)
            }
            self = .mlDSA65
        }

        var keyVariant: String { "65" }
        var applePublicKeyLength: Int { 1_952 }
        var applePrivateKeyLength: Int { 64 }
    }

    private static let validationMessage = Data(
        "SkyBridge/PQCAppleRekeyStaging/v1/key-pair-validation".utf8
    )

    // MARK: - OQS to Apple staging

    @available(iOS 26.0, macOS 26.0, *)
    static func stageAppleRekey(
        peerId: String,
        algorithm: String
    ) async throws {
        try await stageAppleRekey(
            peerId: peerId,
            algorithm: algorithm,
            scopeSource: .requiredEntitlement
        )
    }

    @available(iOS 26.0, macOS 26.0, *)
    static func stageAppleRekey(
        peerId: String,
        algorithm: String,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) async throws {
        #if HAS_APPLE_PQC_SDK
        let normalizedPeerId = try normalizedPeerId(peerId)
        let supportedAlgorithm = try SupportedAlgorithm(requestedValue: algorithm)
        let diagnosticPeer = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(normalizedPeerId)

        let sourcePublicKey: Data
        do {
            sourcePublicKey = try validatedExistingOQSPublicKey(
                peerId: normalizedPeerId,
                algorithm: supportedAlgorithm,
                scopeSource: scopeSource
            )
        } catch let error as StagingError {
            throw error
        } catch {
            throw StagingError.stagingFailed(
                "liboqs source validation failed: \(error.localizedDescription)"
            )
        }
        do {
            // If this upgrade predates the authority record, elect from the
            // still-complete source material before an Apple staging record is
            // added. Otherwise the two backends would become ambiguous on the
            // next factory lookup even though this operation never promoted
            // the Apple identity.
            _ = try PQCBackendAuthorityStore.resolveActiveBackend(
                preferred: .liboqs,
                appleAvailable: true,
                liboqsAvailable: true,
                scopeSource: scopeSource
            )
        } catch {
            throw StagingError.stagingFailed(
                "active backend preservation failed: \(error.localizedDescription)"
            )
        }
        let descriptor = appleDescriptor(
            peerId: normalizedPeerId,
            algorithm: supportedAlgorithm,
            scopeSource: scopeSource
        )
        var candidate = try makeAppleCandidate(
            peerId: normalizedPeerId,
            algorithm: supportedAlgorithm,
            scopeSource: scopeSource
        )
        defer { PQCKeyPairRecordCodec.wipe(&candidate.privateKey) }

        do {
            var insertedWinner = try PQCKeyPairStore.insertIfAbsent(
                candidate,
                descriptor: descriptor,
                publicKeyLength: supportedAlgorithm.applePublicKeyLength,
                privateKeyLength: supportedAlgorithm.applePrivateKeyLength,
                validatePair: { record in
                    try validateAppleKeyPair(record, algorithm: supportedAlgorithm)
                }
            )
            defer { PQCKeyPairRecordCodec.wipe(&insertedWinner.privateKey) }

            // Reload from Keychain and repeat the cryptographic relationship
            // proof. The in-memory candidate is not accepted as persistence
            // evidence, and a concurrent creator may have won insertion.
            guard var persistedWinner = try PQCKeyPairStore.load(
                descriptor: descriptor,
                publicKeyLength: supportedAlgorithm.applePublicKeyLength,
                privateKeyLength: supportedAlgorithm.applePrivateKeyLength,
                validatePair: { record in
                    try validateAppleKeyPair(record, algorithm: supportedAlgorithm)
                }
            ) else {
                throw StagingError.stagingFailed(
                    "canonical Apple key-pair record was missing after insertion"
                )
            }
            defer { PQCKeyPairRecordCodec.wipe(&persistedWinner.privateKey) }

            NotificationCenter.default.post(
                name: .pqcAppleRekeyStaged,
                object: nil,
                userInfo: [
                    "peerId": normalizedPeerId,
                    "algorithm": supportedAlgorithm.rawValue,
                    "provider": "Apple CryptoKit",
                    "sourcePublicKeyFingerprint": fingerprint(sourcePublicKey),
                    "destinationPublicKeyFingerprint": fingerprint(persistedWinner.publicKey),
                    "requiresRePinning": true,
                    "destinationState": "staged",
                    "activeBackendChanged": false
                ]
            )
            logger.info(
                "Apple PQC staged re-key verified: peer=\(diagnosticPeer, privacy: .public) algorithm=\(supportedAlgorithm.rawValue, privacy: .public) requiresRePinning=true activeBackendChanged=false"
            )
        } catch let error as StagingError {
            throw error
        } catch {
            throw StagingError.stagingFailed(error.localizedDescription)
        }
        #else
        _ = peerId
        _ = algorithm
        _ = scopeSource
        throw StagingError.unsupportedPlatform
        #endif
    }

    // MARK: - Verification

    /// Reloads and cryptographically validates the canonical Apple record.
    /// This method never creates a missing key.
    @available(iOS 26.0, macOS 26.0, *)
    static func validateStagedAppleRekey(
        peerId: String,
        algorithm: String
    ) async throws {
        try await validateStagedAppleRekey(
            peerId: peerId,
            algorithm: algorithm,
            scopeSource: .requiredEntitlement
        )
    }

    @available(iOS 26.0, macOS 26.0, *)
    static func validateStagedAppleRekey(
        peerId: String,
        algorithm: String,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) async throws {
        #if HAS_APPLE_PQC_SDK
        let normalizedPeerId = try normalizedPeerId(peerId)
        let supportedAlgorithm = try SupportedAlgorithm(requestedValue: algorithm)
        do {
            guard var persistedRecord = try PQCKeyPairStore.load(
                descriptor: appleDescriptor(
                    peerId: normalizedPeerId,
                    algorithm: supportedAlgorithm,
                    scopeSource: scopeSource
                ),
                publicKeyLength: supportedAlgorithm.applePublicKeyLength,
                privateKeyLength: supportedAlgorithm.applePrivateKeyLength,
                validatePair: { record in
                    try validateAppleKeyPair(record, algorithm: supportedAlgorithm)
                }
            ) else {
                throw StagingError.keyNotFound
            }
            PQCKeyPairRecordCodec.wipe(&persistedRecord.privateKey)
        } catch let error as StagingError {
            throw error
        } catch {
            throw StagingError.stagingFailed(error.localizedDescription)
        }
        #else
        _ = peerId
        _ = algorithm
        _ = scopeSource
        throw StagingError.unsupportedPlatform
        #endif
    }

    // MARK: - Validation helpers

    private static func normalizedPeerId(_ peerId: String) throws -> String {
        do {
            return try PQCIdentityToken.validated(peerId)
        } catch {
            throw StagingError.invalidPeerId
        }
    }

    private static func oqsDescriptor(
        peerId: String,
        algorithm: SupportedAlgorithm,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) -> PQCKeyPairStoreDescriptor {
        PQCKeyPairStoreDescriptor(
            backend: .liboqs,
            purpose: .signature,
            algorithm: algorithm.rawValue,
            identity: peerId,
            authority: .active,
            storageScope: storageScope(scopeSource: scopeSource)
        )
    }

    private static func appleDescriptor(
        peerId: String,
        algorithm: SupportedAlgorithm,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) -> PQCKeyPairStoreDescriptor {
        PQCKeyPairStoreDescriptor(
            backend: .appleCryptoKit,
            purpose: .signature,
            algorithm: algorithm.rawValue,
            identity: peerId,
            authority: .staged,
            storageScope: storageScope(scopeSource: scopeSource)
        )
    }

    private static func storageScope(
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) -> PQCKeyPairStoreStorageScope {
        PQCKeyPairStoreStorageScope(
            canonicalLocation: nil,
            keychainScopeSource: scopeSource,
            includeLegacyKeychain: true
        )
    }

    private static func validatedExistingOQSPublicKey(
        peerId: String,
        algorithm: SupportedAlgorithm,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) throws -> Data {
        let publicKeyLength = Int(oqs_raii_mldsa65_public_key_length())
        let privateKeyLength = Int(oqs_raii_mldsa65_secret_key_length())
        guard publicKeyLength > 0, privateKeyLength > 0 else {
            throw StagingError.invalidSourceKeyPair
        }

        let descriptor = oqsDescriptor(
            peerId: peerId,
            algorithm: algorithm,
            scopeSource: scopeSource
        )
        let publicService = PQCKeyTags.service("MLDSA", algorithm.keyVariant, "Pub")
        let privateService = PQCKeyTags.service("MLDSA", algorithm.keyVariant, "Priv")
        do {
            guard var canonical = try PQCKeyPairStore.loadOrMigrateLegacy(
                descriptor: descriptor,
                publicKeyLength: publicKeyLength,
                privateKeyLength: privateKeyLength,
                legacyPublicService: publicService,
                legacyPrivateService: privateService,
                validatePair: validateOQSMLDSA65KeyPair
            ) else {
                throw StagingError.keyNotFound
            }
            defer { PQCKeyPairRecordCodec.wipe(&canonical.privateKey) }
            return canonical.publicKey
        } catch let error as StagingError {
            throw error
        } catch let error as PQCKeyPairStoreError {
            switch error {
            case .incompleteLegacyKeyPair:
                throw StagingError.incompleteSourceKeyPair
            case .conflictingLegacyKeyPair:
                throw StagingError.invalidSourceKeyPair
            case .invalidIdentity,
                 .invalidStorageLocation,
                 .stagedStorageRequiresManagedNamespace,
                 .conflictingLegacyStorageConfiguration,
                 .incompleteLegacyStorageConfiguration,
                 .canonicalRecordMissingDuringInspection,
                 .canonicalRecordMissingAfterInsert,
                 .conflictingBackendIdentity:
                throw StagingError.stagingFailed(error.localizedDescription)
            }
        }
    }

    private static func validateOQSMLDSA65KeyPair(_ record: PQCKeyPairRecord) throws {
        let publicKeyLength = Int(oqs_raii_mldsa65_public_key_length())
        let privateKeyLength = Int(oqs_raii_mldsa65_secret_key_length())
        let signatureLength = Int(oqs_raii_mldsa65_signature_length())
        guard publicKeyLength > 0,
              privateKeyLength > 0,
              signatureLength > 0,
              record.publicKey.count == publicKeyLength,
              record.privateKey.count == privateKeyLength else {
            throw StagingError.invalidSourceKeyPair
        }

        var message = [UInt8](validationMessage)
        var publicKey = [UInt8](record.publicKey)
        var privateKey = [UInt8](record.privateKey)
        var signature = [UInt8](repeating: 0, count: signatureLength)
        var actualSignatureLength = signatureLength
        defer {
            PQCKeyPairRecordCodec.wipe(&privateKey)
            PQCKeyPairRecordCodec.wipe(&signature)
        }

        let signStatus = oqs_raii_mldsa65_sign(
            &message,
            message.count,
            &privateKey,
            privateKey.count,
            &signature,
            &actualSignatureLength
        )
        guard signStatus == OQSRAII_SUCCESS,
              actualSignatureLength == signatureLength,
              oqs_raii_mldsa65_verify(
                  &message,
                  message.count,
                  &signature,
                  actualSignatureLength,
                  &publicKey,
                  publicKey.count
              ) else {
            throw StagingError.invalidSourceKeyPair
        }
    }

    #if HAS_APPLE_PQC_SDK
    @available(iOS 26.0, macOS 26.0, *)
    private static func makeAppleCandidate(
        peerId: String,
        algorithm: SupportedAlgorithm,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) throws -> PQCKeyPairRecord {
        let descriptor = appleDescriptor(
            peerId: peerId,
            algorithm: algorithm,
            scopeSource: scopeSource
        )
        do {
            let privateKey = try MLDSA65.PrivateKey()
            return PQCKeyPairRecord(
                algorithmIdentifier: descriptor.algorithmIdentifier,
                publicKey: privateKey.publicKey.rawRepresentation,
                privateKey: privateKey.integrityCheckedRepresentation
            )
        } catch {
            throw StagingError.stagingFailed(
                "Apple ML-DSA candidate generation failed: \(error.localizedDescription)"
            )
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func validateAppleKeyPair(
        _ record: PQCKeyPairRecord,
        algorithm: SupportedAlgorithm
    ) throws {
        guard record.publicKey.count == algorithm.applePublicKeyLength,
              record.privateKey.count == algorithm.applePrivateKeyLength else {
            throw StagingError.stagingFailed("Apple ML-DSA key length contract failed")
        }

        do {
            let privateKey = try MLDSA65.PrivateKey(
                integrityCheckedRepresentation: record.privateKey
            )
            let publicKey = try MLDSA65.PublicKey(rawRepresentation: record.publicKey)
            guard privateKey.publicKey.rawRepresentation == publicKey.rawRepresentation else {
                throw StagingError.stagingFailed(
                    "Apple ML-DSA public and private keys do not match"
                )
            }
            let signature = try privateKey.signature(for: validationMessage)
            guard publicKey.isValidSignature(signature, for: validationMessage) else {
                throw StagingError.stagingFailed("Apple ML-DSA self-verification failed")
            }
        } catch let error as StagingError {
            throw error
        } catch {
            throw StagingError.stagingFailed(
                "Apple ML-DSA key validation failed: \(error.localizedDescription)"
            )
        }
    }
    #endif

    private static func fingerprint(_ publicKey: Data) -> String {
        ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA65,
            publicKeyBytes: publicKey
        )
    }
}

extension Notification.Name {
    static let pqcAppleRekeyStaged = Notification.Name("PQCAppleRekeyStaged")
}
