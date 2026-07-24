import CryptoKit
import Foundation
import SkyBridgeQPeriaptRuntime

/// Persistent local KEM identity keys (per CryptoSuite).
/// Responder needs the private key to `kemDecapsulate()` PQC keyShares from initiator.
@available(iOS 17.0, *)
public actor P2PKEMIdentityKeyStore {
    public static let shared = P2PKEMIdentityKeyStore()

    private let keychain = KeychainManager.shared

    private init() {}

    public func getOrCreateIdentityKey(
        for suite: CryptoSuite,
        provider: any CryptoProvider
    ) async throws -> (publicKey: Data, privateKey: SecureBytes) {
        let storageSuite = suite.canonicalKEMSuite
        if storageSuite == .qperiaptABI2PolicyBound {
            guard let configuration = try? ProtocolSigningIdentityPolicy.requiredConfiguration(),
                  configuration.algorithm == .mlDSA65 else {
                throw CryptoProviderError.unsupportedOperation(
                    "Q-Periapt ABI2 requires the active ML-DSA-65 protocol identity"
                )
            }
            guard let provider = provider as? any QPeriaptRuntimeBoundCryptoProvider else {
                throw CryptoProviderError.pqcNotAvailable
            }
            return try await getOrCreateQPeriaptIdentityKey(provider: provider)
        }

        let publicIdentifier = "p2p.kem.public.\(storageSuite.wireId)"
        let privateIdentifier = "p2p.kem.private.\(storageSuite.wireId)"
        if let stored = try loadStoredIdentityKey(
            publicIdentifier: publicIdentifier,
            privateIdentifier: privateIdentifier
        ) {
            return (
                publicKey: stored.publicKey,
                privateKey: SecureBytes(data: stored.privateKey)
            )
        }

        let pair = try await provider.generateKeyPair(for: .keyExchange)
        try keychain.savePublicKey(pair.publicKey.bytes, identifier: publicIdentifier)
        try keychain.savePrivateKey(pair.privateKey.bytes, identifier: privateIdentifier)
        return (
            publicKey: pair.publicKey.bytes,
            privateKey: SecureBytes(data: pair.privateKey.bytes)
        )
    }

    private func getOrCreateQPeriaptIdentityKey(
        provider: any QPeriaptRuntimeBoundCryptoProvider
    ) async throws -> (publicKey: Data, privateKey: SecureBytes) {
        let rootFingerprint = provider.qPeriaptTrustRootFingerprint
        if let stored = try loadQPeriaptEnvelope(rootFingerprint: rootFingerprint) {
            return stored
        }

        let pair = try await provider.generateKeyPair(for: .keyExchange)
        guard let privateKey = pair.privateKey.secureBytesReference else {
            throw KeychainError.incompleteKeyMaterial(
                "Q-Periapt provider returned non-secure private-key storage"
            )
        }
        var keepCandidate = false
        defer {
            if !keepCandidate {
                privateKey.zeroize()
            }
        }
        var encoded = try QPeriaptKEMIdentityEnvelope.encode(
            rootFingerprint: rootFingerprint,
            publicKey: pair.publicKey.bytes,
            privateKey: privateKey
        )
        defer { encoded.resetBytes(in: 0..<encoded.count) }
        switch try keychain.insertQPeriaptIdentityEnvelopeIfAbsent(
            encoded,
            rootFingerprint: rootFingerprint,
            suiteWireId: CryptoSuite.qperiaptABI2PolicyBound.wireId,
            formatVersion: QPeriaptKEMIdentityEnvelope.formatVersion
        ) {
        case .inserted:
            keepCandidate = true
            return (
                publicKey: pair.publicKey.bytes,
                privateKey: privateKey
            )
        case .alreadyExists:
            guard let winner = try loadQPeriaptEnvelope(rootFingerprint: rootFingerprint) else {
                throw KeychainError.incompleteKeyMaterial(
                    "Q-Periapt identity CAS lost but no winning envelope was readable"
                )
            }
            return winner
        }
    }

    private func loadQPeriaptEnvelope(
        rootFingerprint: Data
    ) throws -> (publicKey: Data, privateKey: SecureBytes)? {
        guard var encoded = try keychain.loadQPeriaptIdentityEnvelope(
            rootFingerprint: rootFingerprint,
            suiteWireId: CryptoSuite.qperiaptABI2PolicyBound.wireId,
            formatVersion: QPeriaptKEMIdentityEnvelope.formatVersion
        ) else {
            return nil
        }
        defer { encoded.resetBytes(in: 0..<encoded.count) }
        return try QPeriaptKEMIdentityEnvelope.decode(
            &encoded,
            expectedRootFingerprint: rootFingerprint
        )
    }

    private func loadStoredIdentityKey(
        publicIdentifier: String,
        privateIdentifier: String
    ) throws -> (publicKey: Data, privateKey: Data)? {
        let privateKey: Data?
        let publicKey: Data?

        do {
            privateKey = try keychain.loadPrivateKey(identifier: privateIdentifier)
        } catch KeychainError.itemNotFound {
            privateKey = nil
        }

        do {
            publicKey = try keychain.loadPublicKey(identifier: publicIdentifier)
        } catch KeychainError.itemNotFound {
            publicKey = nil
        }

        switch (publicKey, privateKey) {
        case (nil, nil):
            return nil
        case let (publicKey?, privateKey?):
            return (publicKey: publicKey, privateKey: privateKey)
        default:
            throw KeychainError.incompleteKeyMaterial("P2P KEM identity keypair is incomplete")
        }
    }

    public func getOrCreateBootstrapPublicKeys() async throws -> [KEMPublicKeyInfo] {
        var bySuiteWireId: [UInt16: Data] = [:]

        let provider = CryptoProviderFactory.make(policy: .requirePQC)
        let requiredConfiguration = try? ProtocolSigningIdentityPolicy.requiredConfiguration()
        for suite in provider.supportedSuites where suite.isPQCGroup && suite.isNegotiable {
            if suite == .qperiaptABI2PolicyBound,
               requiredConfiguration?.algorithm != .mlDSA65 {
                continue
            }
            let (publicKey, _) = try await getOrCreateIdentityKey(for: suite, provider: provider)
            bySuiteWireId[suite.wireId] = publicKey
        }

        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            var nativeProviders: [any CryptoProvider] = [ApplePQCCryptoProvider()]
            if AppleXWingCryptoProvider.quickRuntimeProbe() {
                nativeProviders.append(AppleXWingCryptoProvider())
            }
            for nativeProvider in nativeProviders {
                for suite in nativeProvider.supportedSuites where suite.isPQCGroup && suite.isNegotiable {
                    let (publicKey, _) = try await getOrCreateIdentityKey(for: suite, provider: nativeProvider)
                    bySuiteWireId[suite.wireId] = publicKey
                }
            }
        }
        #endif

        return bySuiteWireId
            .keys
            .sorted()
            .compactMap { suiteWireId in
                guard let publicKey = bySuiteWireId[suiteWireId] else { return nil }
                return KEMPublicKeyInfo(suiteWireId: suiteWireId, publicKey: publicKey)
            }
    }
}

/// Codec for one canonical, add-only Q-Periapt identity record. Decoding moves
/// private bytes directly from the caller-owned, wipeable encoded buffer into
/// `SecureBytes`; no long-lived value-semantic private-key copy is created.
enum QPeriaptKEMIdentityEnvelope {
    static let formatVersion: UInt8 = 1
    static var publicKeyLength: Int { QPeriaptNativeAdapter<SecureBytes>.publicKeyLength }
    static var privateKeyLength: Int { QPeriaptNativeAdapter<SecureBytes>.privateKeyLength }
    private static let magic: [UInt8] = [0x53, 0x42, 0x51, 0x4B] // "SBQK"
    private static let checksumLength = SHA256.byteCount
    private static let headerLength = magic.count + 1 + 2 + SHA256.byteCount + 4 + 4

    private static func validate(
        rootFingerprint: Data,
        publicKey: Data,
        privateKey: SecureBytes
    ) throws {
        guard rootFingerprint.count == SHA256.byteCount else {
            throw KeychainError.incompleteKeyMaterial(
                "Q-Periapt root-key fingerprint must be 32 bytes"
            )
        }
        guard publicKey.count == QPeriaptNativeAdapter<SecureBytes>.publicKeyLength,
              privateKey.byteCount == QPeriaptNativeAdapter<SecureBytes>.privateKeyLength else {
            throw KeychainError.incompleteKeyMaterial(
                "Q-Periapt identity envelope has invalid key lengths"
            )
        }
        var difference: UInt8 = 0
        privateKey.withUnsafeBytes { privateRaw in
            publicKey.withUnsafeBytes { publicRaw in
                let privateBytes = privateRaw.bindMemory(to: UInt8.self)
                let publicBytes = publicRaw.bindMemory(to: UInt8.self)
                let suffixOffset = privateBytes.count - publicBytes.count
                for index in publicBytes.indices {
                    difference |= privateBytes[suffixOffset + index] ^ publicBytes[index]
                }
            }
        }
        guard difference == 0 else {
            throw KeychainError.incompleteKeyMaterial(
                "Q-Periapt private key does not embed its public key"
            )
        }
    }

    static func decode(
        _ encoded: inout Data,
        expectedRootFingerprint: Data
    ) throws -> (publicKey: Data, privateKey: SecureBytes) {
        guard expectedRootFingerprint.count == SHA256.byteCount else {
            throw KeychainError.incompleteKeyMaterial(
                "Q-Periapt expected root-key fingerprint must be 32 bytes"
            )
        }
        guard encoded.count >= Self.headerLength + Self.checksumLength else {
            throw KeychainError.incompleteKeyMaterial("Q-Periapt identity envelope is truncated")
        }
        let payloadEnd = encoded.count - Self.checksumLength
        let computedChecksum = SHA256.hash(data: encoded.prefix(payloadEnd))
        var checksumDifference: UInt8 = 0
        computedChecksum.withUnsafeBytes { checksumRawBuffer in
            let checksumBytes = checksumRawBuffer.bindMemory(to: UInt8.self)
            for index in 0..<Self.checksumLength {
                checksumDifference |= checksumBytes[index] ^ encoded[payloadEnd + index]
            }
        }
        guard checksumDifference == 0 else {
            throw KeychainError.incompleteKeyMaterial(
                "Q-Periapt identity envelope checksum mismatch"
            )
        }

        return try encoded.withUnsafeBytes { rawBuffer in
            guard rawBuffer.baseAddress != nil else {
                throw KeychainError.incompleteKeyMaterial(
                    "Q-Periapt identity envelope has no readable storage"
                )
            }
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard bytes.count == encoded.count,
                  Self.magic.indices.allSatisfy({ bytes[$0] == Self.magic[$0] }) else {
                throw KeychainError.incompleteKeyMaterial(
                    "Q-Periapt identity envelope magic mismatch"
                )
            }

            var offset = Self.magic.count
            guard bytes[offset] == Self.formatVersion else {
                throw KeychainError.incompleteKeyMaterial(
                    "Unsupported Q-Periapt identity envelope version"
                )
            }
            offset += 1

            let suiteWireId = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            guard suiteWireId == CryptoSuite.qperiaptABI2PolicyBound.wireId else {
                throw KeychainError.incompleteKeyMaterial(
                    "Q-Periapt identity envelope suite mismatch"
                )
            }
            offset += 2

            let rootFingerprint = Data(bytes[offset..<(offset + SHA256.byteCount)])
            guard rootFingerprint == expectedRootFingerprint else {
                throw KeychainError.incompleteKeyMaterial(
                    "Q-Periapt identity envelope belongs to a different root key"
                )
            }
            offset += SHA256.byteCount

            let publicKeyLength = Self.readUInt32BE(bytes, at: offset)
            offset += MemoryLayout<UInt32>.size
            let privateKeyLength = Self.readUInt32BE(bytes, at: offset)
            offset += MemoryLayout<UInt32>.size
            guard publicKeyLength == QPeriaptNativeAdapter<SecureBytes>.publicKeyLength,
                  privateKeyLength == QPeriaptNativeAdapter<SecureBytes>.privateKeyLength,
                  offset == Self.headerLength,
                  offset + publicKeyLength + privateKeyLength == payloadEnd else {
                throw KeychainError.incompleteKeyMaterial(
                    "Q-Periapt identity envelope declares invalid key lengths"
                )
            }

            let publicKeyRange = offset..<(offset + publicKeyLength)
            let privateKeyOffset = publicKeyRange.upperBound
            let embeddedPublicKeyOffset = privateKeyOffset + privateKeyLength - publicKeyLength
            var keyDifference: UInt8 = 0
            for index in 0..<publicKeyLength {
                keyDifference |= bytes[publicKeyRange.lowerBound + index]
                    ^ bytes[embeddedPublicKeyOffset + index]
            }
            guard keyDifference == 0 else {
                throw KeychainError.incompleteKeyMaterial(
                    "Q-Periapt private key does not embed its public key"
                )
            }

            let publicKey = Data(bytes[publicKeyRange])
            let privateKey = SecureBytes(count: privateKeyLength)
            privateKey.withUnsafeMutableBytes { destination in
                destination.copyBytes(
                    from: UnsafeRawBufferPointer(
                        start: rawBuffer.baseAddress?.advanced(by: privateKeyOffset),
                        count: privateKeyLength
                    )
                )
            }
            return (publicKey: publicKey, privateKey: privateKey)
        }
    }

    static func encode(
        rootFingerprint: Data,
        publicKey: Data,
        privateKey: SecureBytes
    ) throws -> Data {
        try validate(
            rootFingerprint: rootFingerprint,
            publicKey: publicKey,
            privateKey: privateKey
        )
        let encodedLength = Self.headerLength
            + publicKey.count
            + privateKey.byteCount
            + Self.checksumLength
        var encoded = Data()
        encoded.reserveCapacity(encodedLength)
        encoded.append(contentsOf: Self.magic)
        encoded.append(Self.formatVersion)
        Self.appendUInt16BE(CryptoSuite.qperiaptABI2PolicyBound.wireId, to: &encoded)
        encoded.append(rootFingerprint)
        Self.appendUInt32BE(UInt32(publicKey.count), to: &encoded)
        Self.appendUInt32BE(UInt32(privateKey.byteCount), to: &encoded)
        encoded.append(publicKey)
        privateKey.withUnsafeBytes { privateRaw in
            encoded.append(contentsOf: privateRaw)
        }
        let checksum = SHA256.hash(data: encoded)
        encoded.append(contentsOf: checksum)
        precondition(encoded.count == encodedLength)
        return encoded
    }

    private static func appendUInt16BE(_ value: UInt16, to data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func readUInt32BE(
        _ bytes: UnsafeBufferPointer<UInt8>,
        at offset: Int
    ) -> Int {
        Int(bytes[offset]) << 24
            | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8
            | Int(bytes[offset + 3])
    }
}
