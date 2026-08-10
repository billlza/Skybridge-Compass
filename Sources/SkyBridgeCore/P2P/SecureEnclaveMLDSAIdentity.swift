import CryptoKit
import Foundation
import SkyBridgeProtocolCore

/// Storage policy for the main-protocol ML-DSA signing key.
///
/// This is deliberately separate from the historical P-256 Secure Enclave
/// proof-of-possession key. Enabling `.secureEnclaveRequired` means that the
/// ML-DSA private key used for `sigA` / `sigB` must remain in Secure Enclave;
/// failures never fall back to a software key.
public enum ProtocolSigningKeyProtection: String, Codable, Sendable, CaseIterable {
    case softwareKeychain = "software-keychain"
    case secureEnclaveRequired = "secure-enclave-required"
}

struct SecureEnclaveMLDSAIdentityRecord: Codable, Equatable, Sendable {
    static let currentVersion: UInt8 = 1
    static let maximumEncodedSize = 96 * 1_024

    let version: UInt8
    let algorithm: ProtocolSigningAlgorithm
    let protection: ProtocolSigningKeyProtection
    let publicKey: Data
    var opaqueKeyRepresentation: Data

    init(
        version: UInt8 = currentVersion,
        algorithm: ProtocolSigningAlgorithm,
        publicKey: Data,
        opaqueKeyRepresentation: Data
    ) {
        self.version = version
        self.algorithm = algorithm
        self.protection = .secureEnclaveRequired
        self.publicKey = publicKey
        self.opaqueKeyRepresentation = opaqueKeyRepresentation
    }

    func validated(for expectedAlgorithm: ProtocolSigningAlgorithm) throws -> Self {
        let expectedPublicKeyLength: Int
        switch expectedAlgorithm {
        case .mlDSA65: expectedPublicKeyLength = 1_952
        case .mlDSA87: expectedPublicKeyLength = 2_592
        case .ed25519:
            throw SecureEnclaveMLDSAIdentityError.unsupportedAlgorithm(expectedAlgorithm)
        }
        guard version == Self.currentVersion,
              algorithm == expectedAlgorithm,
              protection == .secureEnclaveRequired,
              publicKey.count == expectedPublicKeyLength,
              !opaqueKeyRepresentation.isEmpty,
              opaqueKeyRepresentation.count <= 64 * 1_024 else {
            throw DeviceIdentityKeyError.corruptIdentityAuthority(
                "Secure Enclave \(expectedAlgorithm.rawValue) protocol identity record is invalid"
            )
        }
        return self
    }

    mutating func wipeOpaqueKeyRepresentation() {
        opaqueKeyRepresentation.secureErase()
    }
}

enum SecureEnclaveMLDSAIdentityError: Error, LocalizedError, Sendable {
    case unsupportedAlgorithm(ProtocolSigningAlgorithm)
    case unavailable
    case invalidPublicKey(algorithm: ProtocolSigningAlgorithm, actualLength: Int)
    case invalidSignature(algorithm: ProtocolSigningAlgorithm, actualLength: Int)
    case invalidOpaqueKeyRepresentation
    case publicKeyMismatch
    case selfTestFailed
    case sdkUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedAlgorithm(let algorithm):
            return "Secure Enclave protocol signing does not support \(algorithm.rawValue)"
        case .unavailable:
            return "Secure Enclave is unavailable on this device"
        case .invalidPublicKey(let algorithm, let actualLength):
            return "Secure Enclave \(algorithm.rawValue) public key has invalid length \(actualLength)"
        case .invalidSignature(let algorithm, let actualLength):
            return "Secure Enclave \(algorithm.rawValue) signature has invalid length \(actualLength)"
        case .invalidOpaqueKeyRepresentation:
            return "Secure Enclave protocol signing key reference is empty or unreasonably large"
        case .publicKeyMismatch:
            return "Secure Enclave key reference does not match the persisted protocol public key"
        case .selfTestFailed:
            return "Secure Enclave protocol signing self-test failed"
        case .sdkUnavailable:
            return "The Apple PQC Secure Enclave SDK is unavailable"
        }
    }
}

struct SecureEnclaveMLDSAIdentityMaterial: Sendable {
    let algorithm: ProtocolSigningAlgorithm
    let publicKey: Data
    let opaqueKeyRepresentation: Data
    let signingCallback: any SigningCallback
}

/// A typed main-protocol signing callback backed by CryptoKit's ML-DSA Secure
/// Enclave keys. Only the device-bound opaque representation is retained; a
/// software private-key representation is never exposed to the handshake.
@available(macOS 26.0, iOS 26.0, *)
actor SecureEnclaveMLDSASigningCallback: SigningCallback {
    private let algorithm: ProtocolSigningAlgorithm
    private let opaqueKeyRepresentation: Data

    init(
        algorithm: ProtocolSigningAlgorithm,
        opaqueKeyRepresentation: Data,
        expectedPublicKey: Data
    ) throws {
        self.algorithm = algorithm
        self.opaqueKeyRepresentation = opaqueKeyRepresentation
        let restoredPublicKey = try Self.restoredPublicKey(
            algorithm: algorithm,
            opaqueKeyRepresentation: opaqueKeyRepresentation
        )
        guard restoredPublicKey == expectedPublicKey else {
            throw SecureEnclaveMLDSAIdentityError.publicKeyMismatch
        }
    }

    func sign(data: Data) async throws -> Data {
        #if HAS_APPLE_PQC_SDK
        let signature: Data
        switch algorithm {
        case .mlDSA65:
            let key = try SecureEnclave.MLDSA65.PrivateKey(
                dataRepresentation: opaqueKeyRepresentation
            )
            signature = try key.signature(for: data)
        case .mlDSA87:
            let key = try SecureEnclave.MLDSA87.PrivateKey(
                dataRepresentation: opaqueKeyRepresentation
            )
            signature = try key.signature(for: data)
        case .ed25519:
            throw SecureEnclaveMLDSAIdentityError.unsupportedAlgorithm(algorithm)
        }
        let expectedLength = try Self.signatureLength(for: algorithm)
        guard signature.count == expectedLength else {
            throw SecureEnclaveMLDSAIdentityError.invalidSignature(
                algorithm: algorithm,
                actualLength: signature.count
            )
        }
        return signature
        #else
        throw SecureEnclaveMLDSAIdentityError.sdkUnavailable
        #endif
    }

    private static func restoredPublicKey(
        algorithm: ProtocolSigningAlgorithm,
        opaqueKeyRepresentation: Data
    ) throws -> Data {
        #if HAS_APPLE_PQC_SDK
        let publicKey: Data
        switch algorithm {
        case .mlDSA65:
            publicKey = try SecureEnclave.MLDSA65.PrivateKey(
                dataRepresentation: opaqueKeyRepresentation
            ).publicKey.rawRepresentation
        case .mlDSA87:
            publicKey = try SecureEnclave.MLDSA87.PrivateKey(
                dataRepresentation: opaqueKeyRepresentation
            ).publicKey.rawRepresentation
        case .ed25519:
            throw SecureEnclaveMLDSAIdentityError.unsupportedAlgorithm(algorithm)
        }
        let expectedLength = try publicKeyLength(for: algorithm)
        guard publicKey.count == expectedLength else {
            throw SecureEnclaveMLDSAIdentityError.invalidPublicKey(
                algorithm: algorithm,
                actualLength: publicKey.count
            )
        }
        return publicKey
        #else
        throw SecureEnclaveMLDSAIdentityError.sdkUnavailable
        #endif
    }

    fileprivate static func publicKeyLength(
        for algorithm: ProtocolSigningAlgorithm
    ) throws -> Int {
        switch algorithm {
        case .mlDSA65: return 1_952
        case .mlDSA87: return 2_592
        case .ed25519:
            throw SecureEnclaveMLDSAIdentityError.unsupportedAlgorithm(algorithm)
        }
    }

    fileprivate static func signatureLength(
        for algorithm: ProtocolSigningAlgorithm
    ) throws -> Int {
        switch algorithm {
        case .mlDSA65: return 3_309
        case .mlDSA87: return 4_627
        case .ed25519:
            throw SecureEnclaveMLDSAIdentityError.unsupportedAlgorithm(algorithm)
        }
    }
}

enum SecureEnclaveMLDSAIdentityFactory {
    private static let validationMessage = Data(
        "SkyBridge/SecureEnclaveMLDSA/protocol-identity/v1".utf8
    )

    @available(macOS 26.0, iOS 26.0, *)
    static func create(
        algorithm: ProtocolSigningAlgorithm
    ) async throws -> SecureEnclaveMLDSAIdentityMaterial {
        #if HAS_APPLE_PQC_SDK
        guard SecureEnclave.isAvailable else {
            throw SecureEnclaveMLDSAIdentityError.unavailable
        }

        let publicKey: Data
        let opaqueKeyRepresentation: Data
        switch algorithm {
        case .mlDSA65:
            let key = try SecureEnclave.MLDSA65.PrivateKey()
            publicKey = key.publicKey.rawRepresentation
            opaqueKeyRepresentation = key.dataRepresentation
        case .mlDSA87:
            let key = try SecureEnclave.MLDSA87.PrivateKey()
            publicKey = key.publicKey.rawRepresentation
            opaqueKeyRepresentation = key.dataRepresentation
        case .ed25519:
            throw SecureEnclaveMLDSAIdentityError.unsupportedAlgorithm(algorithm)
        }
        return try await restore(
            algorithm: algorithm,
            publicKey: publicKey,
            opaqueKeyRepresentation: opaqueKeyRepresentation
        )
        #else
        throw SecureEnclaveMLDSAIdentityError.sdkUnavailable
        #endif
    }

    @available(macOS 26.0, iOS 26.0, *)
    static func restore(
        algorithm: ProtocolSigningAlgorithm,
        publicKey: Data,
        opaqueKeyRepresentation: Data
    ) async throws -> SecureEnclaveMLDSAIdentityMaterial {
        guard SecureEnclave.isAvailable else {
            throw SecureEnclaveMLDSAIdentityError.unavailable
        }
        let expectedPublicKeyLength = try SecureEnclaveMLDSASigningCallback
            .publicKeyLength(for: algorithm)
        guard publicKey.count == expectedPublicKeyLength else {
            throw SecureEnclaveMLDSAIdentityError.invalidPublicKey(
                algorithm: algorithm,
                actualLength: publicKey.count
            )
        }
        guard !opaqueKeyRepresentation.isEmpty,
              opaqueKeyRepresentation.count <= 64 * 1_024 else {
            throw SecureEnclaveMLDSAIdentityError.invalidOpaqueKeyRepresentation
        }

        let callback = try SecureEnclaveMLDSASigningCallback(
            algorithm: algorithm,
            opaqueKeyRepresentation: opaqueKeyRepresentation,
            expectedPublicKey: publicKey
        )
        let signature = try await callback.sign(data: validationMessage)
        #if HAS_APPLE_PQC_SDK
        let verified: Bool
        switch algorithm {
        case .mlDSA65:
            verified = try MLDSA65.PublicKey(rawRepresentation: publicKey)
                .isValidSignature(signature, for: validationMessage)
        case .mlDSA87:
            verified = try MLDSA87.PublicKey(rawRepresentation: publicKey)
                .isValidSignature(signature, for: validationMessage)
        case .ed25519:
            throw SecureEnclaveMLDSAIdentityError.unsupportedAlgorithm(algorithm)
        }
        guard verified else {
            throw SecureEnclaveMLDSAIdentityError.selfTestFailed
        }
        return SecureEnclaveMLDSAIdentityMaterial(
            algorithm: algorithm,
            publicKey: publicKey,
            opaqueKeyRepresentation: opaqueKeyRepresentation,
            signingCallback: callback
        )
        #else
        throw SecureEnclaveMLDSAIdentityError.sdkUnavailable
        #endif
    }
}

/// liboqs protocol signing callback used by the ML-DSA-87 software identity.
/// The callback reopens the one canonical key-pair authority on every call and
/// verifies that its public key is still the identity that was admitted by the
/// handshake. A storage split or replacement therefore fails closed.
actor OQSProtocolMLDSASigningCallback: SigningCallback {
    private let algorithm: ProtocolSigningAlgorithm
    private let identity: String
    private let expectedPublicKey: Data
    private let scopeSource: SkyBridgeSharedIdentityScopeSource
    private let existingOnly: Bool

    init(
        algorithm: ProtocolSigningAlgorithm,
        identity: String,
        expectedPublicKey: Data,
        scopeSource: SkyBridgeSharedIdentityScopeSource,
        existingOnly: Bool = false
    ) {
        self.algorithm = algorithm
        self.identity = identity
        self.expectedPublicKey = expectedPublicKey
        self.scopeSource = scopeSource
        self.existingOnly = existingOnly
    }

    func sign(data: Data) async throws -> Data {
        let result: OQSSignatureResult
        if existingOnly {
            result = try await OQSBridge.signExistingOnly(
                data,
                peerId: identity,
                algorithm: try Self.oqsAlgorithm(for: algorithm),
                authority: .active,
                scopeSource: scopeSource
            )
        } else {
            result = try await OQSBridge.sign(
                data,
                peerId: identity,
                algorithm: try Self.oqsAlgorithm(for: algorithm),
                authority: .active,
                scopeSource: scopeSource
            )
        }
        guard result.publicKey == expectedPublicKey else {
            throw DeviceIdentityKeyError.authorityConflict(
                "liboqs \(algorithm.rawValue) protocol identity changed during signing"
            )
        }
        return result.signature
    }

    static func resolve(
        algorithm: ProtocolSigningAlgorithm,
        identity: String,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) async throws -> (publicKey: Data, keyHandle: SigningKeyHandle) {
        try await resolve(
            algorithm: algorithm,
            identity: identity,
            scopeSource: scopeSource,
            existingOnly: false
        )
    }

    static func resolveExistingOnly(
        algorithm: ProtocolSigningAlgorithm,
        identity: String,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) async throws -> (publicKey: Data, keyHandle: SigningKeyHandle) {
        try await resolve(
            algorithm: algorithm,
            identity: identity,
            scopeSource: scopeSource,
            existingOnly: true
        )
    }

    private static func resolve(
        algorithm: ProtocolSigningAlgorithm,
        identity: String,
        scopeSource: SkyBridgeSharedIdentityScopeSource,
        existingOnly: Bool
    ) async throws -> (publicKey: Data, keyHandle: SigningKeyHandle) {
        let challenge = Data("SkyBridge/OQS/protocol-identity/v1".utf8)
        let result: OQSSignatureResult
        if existingOnly {
            result = try await OQSBridge.signExistingOnly(
                challenge,
                peerId: identity,
                algorithm: try oqsAlgorithm(for: algorithm),
                authority: .active,
                scopeSource: scopeSource
            )
        } else {
            result = try await OQSBridge.sign(
                challenge,
                peerId: identity,
                algorithm: try oqsAlgorithm(for: algorithm),
                authority: .active,
                scopeSource: scopeSource
            )
        }
        let expectedPublicKeyLength: Int
        let expectedSignatureLength: Int
        switch algorithm {
        case .mlDSA65:
            expectedPublicKeyLength = 1_952
            expectedSignatureLength = 3_309
        case .mlDSA87:
            expectedPublicKeyLength = 2_592
            expectedSignatureLength = 4_627
        case .ed25519:
            throw SecureEnclaveMLDSAIdentityError.unsupportedAlgorithm(algorithm)
        }
        guard result.publicKey.count == expectedPublicKeyLength,
              result.signature.count == expectedSignatureLength,
              await OQSBridge.verify(
                challenge,
                signature: result.signature,
                publicKey: result.publicKey,
                algorithm: try oqsAlgorithm(for: algorithm)
              ) else {
            throw DeviceIdentityKeyError.incompleteKeyMaterial(
                "liboqs \(algorithm.rawValue) protocol identity failed its validation challenge"
            )
        }
        let callback = OQSProtocolMLDSASigningCallback(
            algorithm: algorithm,
            identity: identity,
            expectedPublicKey: result.publicKey,
            scopeSource: scopeSource,
            existingOnly: existingOnly
        )
        return (result.publicKey, .callback(callback))
    }

    private static func oqsAlgorithm(
        for algorithm: ProtocolSigningAlgorithm
    ) throws -> OQSAlgorithm {
        switch algorithm {
        case .mlDSA65: return .mldsa65
        case .mlDSA87: return .mldsa87
        case .ed25519:
            throw SecureEnclaveMLDSAIdentityError.unsupportedAlgorithm(algorithm)
        }
    }
}
