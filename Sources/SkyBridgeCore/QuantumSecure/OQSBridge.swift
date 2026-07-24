import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct OQSSignatureResult: Sendable, Equatable {
    public let signature: Data
    public let publicKey: Data

    public init(signature: Data, publicKey: Data) {
        self.signature = signature
        self.publicKey = publicKey
    }
}

#if canImport(liboqs)
import liboqs

public enum OQSAlgorithm: String, Sendable {
    case mldsa65
    case mldsa87
    case mlkem768
    case mlkem1024
}

public final class OQSBridge {
    private static func signingParameters(
        for algorithm: OQSAlgorithm
    ) throws -> (name: String, keyVariant: String) {
        switch algorithm {
        case .mldsa65:
            return ("ML-DSA-65", "65")
        case .mldsa87:
            return ("ML-DSA-87", "87")
        case .mlkem768, .mlkem1024:
            throw pqcError(code: -300, description: "签名操作收到非签名算法")
        }
    }

    private static func kemParameters(
        for algorithm: OQSAlgorithm
    ) throws -> (name: String, keyVariant: String) {
        switch algorithm {
        case .mlkem768:
            return ("ML-KEM-768", "768")
        case .mlkem1024:
            return ("ML-KEM-1024", "1024")
        case .mldsa65, .mldsa87:
            throw pqcError(code: -310, description: "KEM 操作收到非 KEM 算法")
        }
    }

    private static func pqcError(code: Int, description: String) -> NSError {
        NSError(
            domain: "PQC",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    private static func requireExactLength(
        _ data: Data,
        expected: Int,
        errorCode: Int,
        description: String
    ) throws {
        guard data.count == expected else {
            throw pqcError(
                code: errorCode,
                description: "\(description) (expected=\(expected), actual=\(data.count))"
            )
        }
    }

    private static func requirePositiveLengths(
        _ lengths: [Int],
        errorCode: Int,
        description: String
    ) throws {
        guard lengths.allSatisfy({ $0 > 0 }) else {
            throw pqcError(code: errorCode, description: description)
        }
    }

    private static func descriptor(
        peerId: String,
        algorithm: String,
        purpose: PQCKeyPairStorePurpose,
        authority: PQCKeyPairStoreAuthority,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) -> PQCKeyPairStoreDescriptor {
        PQCKeyPairStoreDescriptor(
            backend: .liboqs,
            purpose: purpose,
            algorithm: algorithm,
            identity: peerId,
            authority: authority,
            storageScope: PQCKeyPairStoreStorageScope(
                canonicalLocation: nil,
                keychainScopeSource: scopeSource,
                includeLegacyKeychain: true
            )
        )
    }

    private static func validateSignatureKeyPair(
        _ record: PQCKeyPairRecord,
        signatureAlgorithm: UnsafeMutablePointer<OQS_SIG>
    ) throws {
        let challenge = Data("SkyBridge/PQCKeyPair/v3/signature-validation".utf8)
        let signatureLength = Int(signatureAlgorithm.pointee.length_signature)
        let signature = UnsafeMutablePointer<UInt8>.allocate(capacity: signatureLength)
        defer { signature.deallocate() }
        var actualSignatureLength = 0
        let signStatus = challenge.withUnsafeBytes { messageRaw in
            record.privateKey.withUnsafeBytes { privateRaw in
                guard let message = messageRaw.bindMemory(to: UInt8.self).baseAddress,
                      let privateKey = privateRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return OQS_ERROR
                }
                return OQS_SIG_sign(
                    signatureAlgorithm,
                    signature,
                    &actualSignatureLength,
                    message,
                    challenge.count,
                    privateKey
                )
            }
        }
        guard signStatus == OQS_SUCCESS,
              actualSignatureLength == signatureLength else {
            throw pqcError(code: -306, description: "OQS signature key-pair validation failed")
        }
        let verifyStatus = challenge.withUnsafeBytes { messageRaw in
            record.publicKey.withUnsafeBytes { publicRaw in
                guard let message = messageRaw.bindMemory(to: UInt8.self).baseAddress,
                      let publicKey = publicRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return OQS_ERROR
                }
                return OQS_SIG_verify(
                    signatureAlgorithm,
                    message,
                    challenge.count,
                    signature,
                    actualSignatureLength,
                    publicKey
                )
            }
        }
        guard verifyStatus == OQS_SUCCESS else {
            throw pqcError(code: -306, description: "OQS signature public/private keys do not match")
        }
    }

    private static func validateKEMKeyPair(
        _ record: PQCKeyPairRecord,
        kem: UnsafeMutablePointer<OQS_KEM>
    ) throws {
        let ciphertextLength = Int(kem.pointee.length_ciphertext)
        let sharedSecretLength = Int(kem.pointee.length_shared_secret)
        let ciphertext = UnsafeMutablePointer<UInt8>.allocate(capacity: ciphertextLength)
        let encapsulatedSecret = UnsafeMutablePointer<UInt8>.allocate(capacity: sharedSecretLength)
        let decapsulatedSecret = UnsafeMutablePointer<UInt8>.allocate(capacity: sharedSecretLength)
        defer {
            ciphertext.deallocate()
            wipeAndDeallocate(encapsulatedSecret, count: sharedSecretLength)
            wipeAndDeallocate(decapsulatedSecret, count: sharedSecretLength)
        }
        let encapsulationStatus = record.publicKey.withUnsafeBytes { publicRaw in
            guard let publicKey = publicRaw.bindMemory(to: UInt8.self).baseAddress else {
                return OQS_ERROR
            }
            return OQS_KEM_encaps(kem, ciphertext, encapsulatedSecret, publicKey)
        }
        guard encapsulationStatus == OQS_SUCCESS else {
            throw pqcError(code: -316, description: "OQS KEM key-pair validation encapsulation failed")
        }
        let decapsulationStatus = record.privateKey.withUnsafeBytes { privateRaw in
            guard let privateKey = privateRaw.bindMemory(to: UInt8.self).baseAddress else {
                return OQS_ERROR
            }
            return OQS_KEM_decaps(kem, decapsulatedSecret, ciphertext, privateKey)
        }
        guard decapsulationStatus == OQS_SUCCESS,
              constantTimeEqual(
                  encapsulatedSecret,
                  decapsulatedSecret,
                  count: sharedSecretLength
              ) else {
            throw pqcError(code: -316, description: "OQS KEM public/private keys do not match")
        }
    }

    private static func constantTimeEqual(
        _ lhs: UnsafePointer<UInt8>,
        _ rhs: UnsafePointer<UInt8>,
        count: Int
    ) -> Bool {
        var difference: UInt8 = 0
        for index in 0..<count {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    private static func wipeAndDeallocate(
        _ pointer: UnsafeMutablePointer<UInt8>,
        count: Int
    ) {
        #if canImport(Darwin)
        _ = memset_s(pointer, count, 0, count)
        #else
        UnsafeMutableRawPointer(pointer).initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: count
        )
        #endif
        pointer.deallocate()
    }

    public static func sign(
        _ data: Data,
        peerId: String,
        algorithm: OQSAlgorithm
    ) async throws -> Data {
        let result = try await sign(
            data,
            peerId: peerId,
            algorithm: algorithm,
            authority: .active,
            scopeSource: .requiredEntitlement
        )
        return result.signature
    }

    static func sign(
        _ data: Data,
        peerId: String,
        algorithm: OQSAlgorithm,
        authority: PQCKeyPairStoreAuthority,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) async throws -> OQSSignatureResult {
        let parameters = try signingParameters(for: algorithm)
        let name = parameters.name
        guard let sig = OQS_SIG_new(name) else {
            throw pqcError(code: -301, description: "OQS_SIG_new 失败: \(name)")
        }
        defer { OQS_SIG_free(sig) }

        let privService = PQCKeyTags.service("MLDSA", parameters.keyVariant, "Priv")
        let pubService = PQCKeyTags.service("MLDSA", parameters.keyVariant, "Pub")

        let privLen = Int(sig.pointee.length_secret_key)
        let pubLen = Int(sig.pointee.length_public_key)
        let sigLen = Int(sig.pointee.length_signature)
        try requirePositiveLengths(
            [privLen, pubLen, sigLen],
            errorCode: -301,
            description: "OQS 签名算法返回无效的固定长度"
        )

        let keyDescriptor = descriptor(
            peerId: peerId,
            algorithm: name,
            purpose: .signature,
            authority: authority,
            scopeSource: scopeSource
        )
        var keyPair = try PQCKeyPairStore.loadOrCreate(
            descriptor: keyDescriptor,
            publicKeyLength: pubLen,
            privateKeyLength: privLen,
            legacyPublicService: pubService,
            legacyPrivateService: privService,
            validatePair: { record in
                try validateSignatureKeyPair(record, signatureAlgorithm: sig)
            },
            generate: {
            let pub = UnsafeMutablePointer<UInt8>.allocate(capacity: pubLen)
            let sec = UnsafeMutablePointer<UInt8>.allocate(capacity: privLen)
            defer {
                pub.deallocate()
                wipeAndDeallocate(sec, count: privLen)
            }
            let status = OQS_SIG_keypair(sig, pub, sec)
            if status != OQS_SUCCESS {
                throw pqcError(code: -302, description: "OQS_SIG_keypair 失败: \(name)")
            }
            let pubData = Data(bytes: pub, count: pubLen)
            let secData = Data(bytes: sec, count: privLen)
            try requireExactLength(
                pubData,
                expected: pubLen,
                errorCode: -303,
                description: "OQS 签名生成公钥长度无效"
            )
            try requireExactLength(
                secData,
                expected: privLen,
                errorCode: -303,
                description: "OQS 签名生成私钥长度无效"
            )
            return PQCKeyPairRecord(
                algorithmIdentifier: keyDescriptor.algorithmIdentifier,
                publicKey: pubData,
                privateKey: secData
            )
        })
        defer { PQCKeyPairRecordCodec.wipe(&keyPair.privateKey) }

        let sigBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: sigLen)
        defer { sigBuf.deallocate() }
        var outLen = Int(0)
        let messageBacking = data.isEmpty ? Data([0]) : data

        let ok = messageBacking.withUnsafeBytes { (msgPtr: UnsafeRawBufferPointer) -> OQS_STATUS in
            guard let m = msgPtr.bindMemory(to: UInt8.self).baseAddress else {
                return OQS_ERROR
            }
            return keyPair.privateKey.withUnsafeBytes { skPtr in
                guard let s = skPtr.bindMemory(to: UInt8.self).baseAddress else {
                    return OQS_ERROR
                }
                return OQS_SIG_sign(sig, sigBuf, &outLen, m, data.count, s)
            }
        }
        if ok != OQS_SUCCESS {
            throw pqcError(code: -304, description: "OQS_SIG_sign 失败: \(name)")
        }
        guard outLen == sigLen else {
            throw pqcError(
                code: -305,
                description: "OQS_SIG_sign 返回签名长度无效 (expected=\(sigLen), actual=\(outLen))"
            )
        }
        let sigData = Data(bytes: sigBuf, count: outLen)
        return OQSSignatureResult(signature: sigData, publicKey: keyPair.publicKey)
    }

    /// Loads and validates an existing canonical signing identity without
    /// generating one. Identity-policy code uses this to prevent a software
    /// key from being silently replaced by a Secure Enclave key for the same
    /// protocol algorithm.
    static func existingSigningPublicKey(
        peerId: String,
        algorithm: OQSAlgorithm,
        authority: PQCKeyPairStoreAuthority,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) throws -> Data? {
        let parameters = try signingParameters(for: algorithm)
        guard let sig = OQS_SIG_new(parameters.name) else {
            throw pqcError(
                code: -301,
                description: "OQS_SIG_new failed: \(parameters.name)"
            )
        }
        defer { OQS_SIG_free(sig) }
        let privateKeyLength = Int(sig.pointee.length_secret_key)
        let publicKeyLength = Int(sig.pointee.length_public_key)
        let descriptor = descriptor(
            peerId: peerId,
            algorithm: parameters.name,
            purpose: .signature,
            authority: authority,
            scopeSource: scopeSource
        )
        guard var record = try PQCKeyPairStore.loadOrMigrateLegacy(
            descriptor: descriptor,
            publicKeyLength: publicKeyLength,
            privateKeyLength: privateKeyLength,
            legacyPublicService: PQCKeyTags.service(
                "MLDSA", parameters.keyVariant, "Pub"
            ),
            legacyPrivateService: PQCKeyTags.service(
                "MLDSA", parameters.keyVariant, "Priv"
            ),
            validatePair: { record in
                try validateSignatureKeyPair(record, signatureAlgorithm: sig)
            }
        ) else {
            return nil
        }
        defer { PQCKeyPairRecordCodec.wipe(&record.privateKey) }
        return record.publicKey
    }

    public static func verify(
        _ data: Data,
        signature: Data,
        publicKey: Data,
        algorithm: OQSAlgorithm
    ) async -> Bool {
        guard let parameters = try? signingParameters(for: algorithm) else { return false }
        let name = parameters.name
        guard let sig = OQS_SIG_new(name) else { return false }
        defer { OQS_SIG_free(sig) }
        let publicKeyLength = Int(sig.pointee.length_public_key)
        let signatureLength = Int(sig.pointee.length_signature)
        guard publicKeyLength > 0,
              signatureLength > 0,
              publicKey.count == publicKeyLength,
              signature.count == signatureLength else {
            return false
        }
        let messageBacking = data.isEmpty ? Data([0]) : data
        let ok: OQS_STATUS = messageBacking.withUnsafeBytes { mPtr in
            signature.withUnsafeBytes { sPtr in
                publicKey.withUnsafeBytes { pPtr in
                    guard let m = mPtr.bindMemory(to: UInt8.self).baseAddress,
                          let s = sPtr.bindMemory(to: UInt8.self).baseAddress,
                          let p = pPtr.bindMemory(to: UInt8.self).baseAddress else {
                        return OQS_ERROR
                    }
                    return OQS_SIG_verify(sig, m, data.count, s, signature.count, p)
                }
            }
        }
        return ok == OQS_SUCCESS
    }

    /// Legacy peer-id-only verification is retained solely as a fail-closed
    /// source-compatibility shim. Remote trust requires the explicit-public-key
    /// overload above.
    public static func verify(
        _ data: Data,
        signature: Data,
        peerId: String,
        algorithm: OQSAlgorithm
    ) async -> Bool {
        false
    }

    public static func kemEncapsulate(peerId: String, algorithm: OQSAlgorithm) async throws -> (shared: Data, encapsulated: Data) {
        try await kemEncapsulate(
            peerId: peerId,
            algorithm: algorithm,
            authority: .active,
            scopeSource: .requiredEntitlement
        )
    }

    static func kemEncapsulate(
        peerId: String,
        algorithm: OQSAlgorithm,
        authority: PQCKeyPairStoreAuthority,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) async throws -> (shared: Data, encapsulated: Data) {
        let parameters = try kemParameters(for: algorithm)
        let name = parameters.name
        guard let kem = OQS_KEM_new(name) else {
            throw pqcError(code: -311, description: "OQS_KEM_new 失败: \(name)")
        }
        defer { OQS_KEM_free(kem) }
        let pubService = PQCKeyTags.service("MLKEM", parameters.keyVariant, "Pub")
        let privService = PQCKeyTags.service("MLKEM", parameters.keyVariant, "Priv")

        let pubLen = Int(kem.pointee.length_public_key)
        let privLen = Int(kem.pointee.length_secret_key)
        let ctLen = Int(kem.pointee.length_ciphertext)
        let ssLen = Int(kem.pointee.length_shared_secret)
        try requirePositiveLengths(
            [pubLen, privLen, ctLen, ssLen],
            errorCode: -311,
            description: "OQS KEM 算法返回无效的固定长度"
        )
        let keyDescriptor = descriptor(
            peerId: peerId,
            algorithm: name,
            purpose: .kem,
            authority: authority,
            scopeSource: scopeSource
        )
        var keyPair = try PQCKeyPairStore.loadOrCreate(
            descriptor: keyDescriptor,
            publicKeyLength: pubLen,
            privateKeyLength: privLen,
            legacyPublicService: pubService,
            legacyPrivateService: privService,
            validatePair: { record in
                try validateKEMKeyPair(record, kem: kem)
            },
            generate: {
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: pubLen)
            let s = UnsafeMutablePointer<UInt8>.allocate(capacity: privLen)
            defer {
                p.deallocate()
                wipeAndDeallocate(s, count: privLen)
            }
            let status = OQS_KEM_keypair(kem, p, s)
            if status != OQS_SUCCESS {
                throw pqcError(code: -312, description: "OQS_KEM_keypair 失败: \(name)")
            }
            let pd = Data(bytes: p, count: pubLen)
            let sd = Data(bytes: s, count: privLen)
            try requireExactLength(
                pd,
                expected: pubLen,
                errorCode: -313,
                description: "OQS KEM 生成公钥长度无效"
            )
            try requireExactLength(
                sd,
                expected: privLen,
                errorCode: -313,
                description: "OQS KEM 生成私钥长度无效"
            )
            return PQCKeyPairRecord(
                algorithmIdentifier: keyDescriptor.algorithmIdentifier,
                publicKey: pd,
                privateKey: sd
            )
        })
        defer { PQCKeyPairRecordCodec.wipe(&keyPair.privateKey) }

        let ct = UnsafeMutablePointer<UInt8>.allocate(capacity: ctLen)
        let ss = UnsafeMutablePointer<UInt8>.allocate(capacity: ssLen)
        defer {
            ct.deallocate()
            wipeAndDeallocate(ss, count: ssLen)
        }
        let status = keyPair.publicKey.withUnsafeBytes { pPtr -> OQS_STATUS in
            guard let p = pPtr.bindMemory(to: UInt8.self).baseAddress else {
                return OQS_ERROR
            }
            return OQS_KEM_encaps(kem, ct, ss, p)
        }
        if status != OQS_SUCCESS {
            throw pqcError(code: -314, description: "OQS_KEM_encaps 失败: \(name)")
        }
        let ctData = Data(bytes: ct, count: ctLen)
        let ssData = Data(bytes: ss, count: ssLen)
        try requireExactLength(
            ctData,
            expected: ctLen,
            errorCode: -315,
            description: "OQS KEM 封装密文长度无效"
        )
        try requireExactLength(
            ssData,
            expected: ssLen,
            errorCode: -315,
            description: "OQS KEM 共享密钥长度无效"
        )
        return (ssData, ctData)
    }

    public static func kemDecapsulate(_ encapsulated: Data, peerId: String, algorithm: OQSAlgorithm) async throws -> Data {
        try await kemDecapsulate(
            encapsulated,
            peerId: peerId,
            algorithm: algorithm,
            authority: .active,
            scopeSource: .requiredEntitlement
        )
    }

    static func kemDecapsulate(
        _ encapsulated: Data,
        peerId: String,
        algorithm: OQSAlgorithm,
        authority: PQCKeyPairStoreAuthority,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) async throws -> Data {
        let parameters = try kemParameters(for: algorithm)
        let name = parameters.name
        guard let kem = OQS_KEM_new(name) else {
            throw pqcError(code: -321, description: "OQS_KEM_new 失败: \(name)")
        }
        defer { OQS_KEM_free(kem) }
        let pubService = PQCKeyTags.service("MLKEM", parameters.keyVariant, "Pub")
        let privService = PQCKeyTags.service("MLKEM", parameters.keyVariant, "Priv")
        let publicKeyLength = Int(kem.pointee.length_public_key)
        let privateKeyLength = Int(kem.pointee.length_secret_key)
        let ciphertextLength = Int(kem.pointee.length_ciphertext)
        let ssLen = Int(kem.pointee.length_shared_secret)
        try requirePositiveLengths(
            [publicKeyLength, privateKeyLength, ciphertextLength, ssLen],
            errorCode: -321,
            description: "OQS KEM 算法返回无效的固定长度"
        )
        guard encapsulated.count == ciphertextLength else {
            throw pqcError(
                code: -322,
                description: "OQS KEM 封装密文长度无效 (expected=\(ciphertextLength), actual=\(encapsulated.count))"
            )
        }
        let keyDescriptor = descriptor(
            peerId: peerId,
            algorithm: name,
            purpose: .kem,
            authority: authority,
            scopeSource: scopeSource
        )
        guard var keyPair = try PQCKeyPairStore.loadOrMigrateLegacy(
            descriptor: keyDescriptor,
            publicKeyLength: publicKeyLength,
            privateKeyLength: privateKeyLength,
            legacyPublicService: pubService,
            legacyPrivateService: privService,
            validatePair: { record in
                try validateKEMKeyPair(record, kem: kem)
            }
        ) else {
            throw pqcError(code: -322, description: "未找到 OQS KEM 密钥对")
        }
        defer { PQCKeyPairRecordCodec.wipe(&keyPair.privateKey) }
        let ss = UnsafeMutablePointer<UInt8>.allocate(capacity: ssLen)
        defer { wipeAndDeallocate(ss, count: ssLen) }
        let status = keyPair.privateKey.withUnsafeBytes { sPtr in
            encapsulated.withUnsafeBytes { cPtr in
                guard let s = sPtr.bindMemory(to: UInt8.self).baseAddress,
                      let c = cPtr.bindMemory(to: UInt8.self).baseAddress else {
                    return OQS_ERROR
                }
                return OQS_KEM_decaps(kem, ss, c, s)
            }
        }
        if status != OQS_SUCCESS {
            throw pqcError(code: -323, description: "OQS_KEM_decaps 失败: \(name)")
        }
        let sharedSecret = Data(bytes: ss, count: ssLen)
        try requireExactLength(
            sharedSecret,
            expected: ssLen,
            errorCode: -324,
            description: "OQS KEM 解封装共享密钥长度无效"
        )
        return sharedSecret
    }
}
#else
public enum OQSAlgorithm: String, Sendable { case mldsa65, mldsa87, mlkem768, mlkem1024 }
public final class OQSBridge {
    public static func sign(
        _ data: Data,
        peerId: String,
        algorithm: OQSAlgorithm
    ) async throws -> Data {
        throw NSError(domain: "PQC", code: -201, userInfo: [NSLocalizedDescriptionKey: "liboqs 未接入"])
    }
    static func sign(
        _ data: Data,
        peerId: String,
        algorithm: OQSAlgorithm,
        authority: PQCKeyPairStoreAuthority,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) async throws -> OQSSignatureResult {
        _ = authority
        _ = scopeSource
        throw NSError(
            domain: "PQC",
            code: -201,
            userInfo: [NSLocalizedDescriptionKey: "liboqs 未接入"]
        )
    }
    static func existingSigningPublicKey(
        peerId: String,
        algorithm: OQSAlgorithm,
        authority: PQCKeyPairStoreAuthority,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) throws -> Data? {
        _ = peerId
        _ = algorithm
        _ = authority
        _ = scopeSource
        return nil
    }
    public static func verify(
        _ data: Data,
        signature: Data,
        publicKey: Data,
        algorithm: OQSAlgorithm
    ) async -> Bool {
        false
    }
    /// Legacy peer-id-only verification remains fail-closed when liboqs is not
    /// linked as well.
    public static func verify(
        _ data: Data,
        signature: Data,
        peerId: String,
        algorithm: OQSAlgorithm
    ) async -> Bool {
        false
    }
    public static func kemEncapsulate(peerId: String, algorithm: OQSAlgorithm) async throws -> (shared: Data, encapsulated: Data) {
        throw NSError(domain: "PQC", code: -202, userInfo: [NSLocalizedDescriptionKey: "liboqs 未接入"])
    }
    static func kemEncapsulate(
        peerId: String,
        algorithm: OQSAlgorithm,
        authority: PQCKeyPairStoreAuthority,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) async throws -> (shared: Data, encapsulated: Data) {
        _ = authority
        _ = scopeSource
        return try await kemEncapsulate(peerId: peerId, algorithm: algorithm)
    }
    public static func kemDecapsulate(_ encapsulated: Data, peerId: String, algorithm: OQSAlgorithm) async throws -> Data {
        throw NSError(domain: "PQC", code: -203, userInfo: [NSLocalizedDescriptionKey: "liboqs 未接入"])
    }
    static func kemDecapsulate(
        _ encapsulated: Data,
        peerId: String,
        algorithm: OQSAlgorithm,
        authority: PQCKeyPairStoreAuthority,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) async throws -> Data {
        _ = authority
        _ = scopeSource
        return try await kemDecapsulate(encapsulated, peerId: peerId, algorithm: algorithm)
    }
}
#endif
