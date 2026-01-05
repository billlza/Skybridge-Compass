import Foundation
import OSLog
#if canImport(liboqs)
import liboqs

public enum OQSAlgorithm: String {
    case mldsa65
    case mldsa87
    case mlkem768
    case mlkem1024
}

public final class OQSBridge {
    private static let logger = Logger(subsystem: "com.skybridge.quantum", category: "OQSBridge")

    private static func sigName(_ alg: OQSAlgorithm) -> String {
        switch alg {
        case .mldsa65: return "ML-DSA-65"
        case .mldsa87: return "ML-DSA-87"
        case .mlkem768: return "ML-KEM-768"
        case .mlkem1024: return "ML-KEM-1024"
        }
    }
    private static func kemName(_ alg: OQSAlgorithm) -> String {
        switch alg {
        case .mlkem768: return "ML-KEM-768"
        case .mlkem1024: return "ML-KEM-1024"
        case .mldsa65, .mldsa87: return ""
        }
    }

    public static func sign(_ data: Data, peerId: String, algorithm: OQSAlgorithm) async throws -> Data {
        let name = sigName(algorithm)
        guard let sig = OQS_SIG_new(name) else {
            throw NSError(domain: "PQC", code: -301, userInfo: [NSLocalizedDescriptionKey: "OQS_SIG_new 失败: \(name)"])
        }
        defer { OQS_SIG_free(sig) }

        let privService = PQCKeyTags.service("MLDSA", algorithm == .mldsa65 ? "65" : "87", "Priv")
        let pubService = PQCKeyTags.service("MLDSA", algorithm == .mldsa65 ? "65" : "87", "Pub")

        let privLen = Int(sig.pointee.length_secret_key)
        let pubLen = Int(sig.pointee.length_public_key)
        let sigLen = Int(sig.pointee.length_signature)

 // KeychainManager 方法是 nonisolated 的，可以同步调用
        var secretKey: Data? = KeychainManager.shared.exportKey(service: privService, account: peerId)
        if secretKey == nil {
            let pub = UnsafeMutablePointer<UInt8>.allocate(capacity: pubLen)
            let sec = UnsafeMutablePointer<UInt8>.allocate(capacity: privLen)
            defer { pub.deallocate(); sec.deallocate() }
            let status = OQS_SIG_keypair(sig, pub, sec)
            if status != OQS_SUCCESS {
                throw NSError(domain: "PQC", code: -302, userInfo: [NSLocalizedDescriptionKey: "OQS_SIG_keypair 失败: \(name)"])
            }
            let pubData = Data(bytes: pub, count: pubLen)
            let secData = Data(bytes: sec, count: privLen)
            _ = KeychainManager.shared.importKey(data: pubData, service: pubService, account: peerId)
            _ = KeychainManager.shared.importKey(data: secData, service: privService, account: peerId)
            secretKey = secData
        }

        guard let sk = secretKey else { throw NSError(domain: "PQC", code: -303, userInfo: [NSLocalizedDescriptionKey: "未找到私钥: \(privService) :: \(peerId)"]) }

        let sigBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: sigLen)
        defer { sigBuf.deallocate() }
        var outLen = Int(0)

        let ok = data.withUnsafeBytes { (msgPtr: UnsafeRawBufferPointer) -> OQS_STATUS in
            guard let m = msgPtr.bindMemory(to: UInt8.self).baseAddress else {
                return OQS_ERROR
            }
            return sk.withUnsafeBytes { skPtr in
                guard let s = skPtr.bindMemory(to: UInt8.self).baseAddress else {
                    return OQS_ERROR
                }
                return OQS_SIG_sign(sig, sigBuf, &outLen, m, data.count, s)
            }
        }
        if ok != OQS_SUCCESS { throw NSError(domain: "PQC", code: -304, userInfo: [NSLocalizedDescriptionKey: "OQS_SIG_sign 失败: \(name)"]) }
        let sigData = Data(bytes: sigBuf, count: outLen)
        return sigData
    }

    public static func verify(_ data: Data, signature: Data, peerId: String, algorithm: OQSAlgorithm) async -> Bool {
        let name = sigName(algorithm)
        guard let sig = OQS_SIG_new(name) else { return false }
        defer { OQS_SIG_free(sig) }
        let pubService = PQCKeyTags.service("MLDSA", algorithm == .mldsa65 ? "65" : "87", "Pub")
 // KeychainManager 方法是 nonisolated 的，可以同步调用
        guard let pub = KeychainManager.shared.exportKey(service: pubService, account: peerId) else { return false }
        let ok: OQS_STATUS = data.withUnsafeBytes { mPtr in
            signature.withUnsafeBytes { sPtr in
                pub.withUnsafeBytes { pPtr in
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

    public static func kemEncapsulate(peerId: String, algorithm: OQSAlgorithm) async throws -> (shared: Data, encapsulated: Data) {
        let name = kemName(algorithm)
        guard !name.isEmpty, let kem = OQS_KEM_new(name) else {
            throw NSError(domain: "PQC", code: -311, userInfo: [NSLocalizedDescriptionKey: "OQS_KEM_new 失败: \(name)"])
        }
        defer { OQS_KEM_free(kem) }
        let pubService = PQCKeyTags.service("MLKEM", algorithm == .mlkem768 ? "768" : "1024", "Pub")
        let privService = PQCKeyTags.service("MLKEM", algorithm == .mlkem768 ? "768" : "1024", "Priv")

        let pubLen = Int(kem.pointee.length_public_key)
        let privLen = Int(kem.pointee.length_secret_key)
 // KeychainManager 方法是 nonisolated 的，可以同步调用
        var pub = KeychainManager.shared.exportKey(service: pubService, account: peerId)
        if pub == nil {
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: pubLen)
            let s = UnsafeMutablePointer<UInt8>.allocate(capacity: privLen)
            defer { p.deallocate(); s.deallocate() }
            let status = OQS_KEM_keypair(kem, p, s)
            if status != OQS_SUCCESS {
                throw NSError(domain: "PQC", code: -312, userInfo: [NSLocalizedDescriptionKey: "OQS_KEM_keypair 失败: \(name)"])
            }
            let pd = Data(bytes: p, count: pubLen)
            let sd = Data(bytes: s, count: privLen)
            _ = KeychainManager.shared.importKey(data: pd, service: pubService, account: peerId)
            _ = KeychainManager.shared.importKey(data: sd, service: privService, account: peerId)
            pub = pd
        }
        guard let pubKey = pub else { throw NSError(domain: "PQC", code: -313, userInfo: [NSLocalizedDescriptionKey: "未找到公钥: \(pubService) :: \(peerId)"]) }

        let ctLen = Int(kem.pointee.length_ciphertext)
        let ssLen = Int(kem.pointee.length_shared_secret)
        let ct = UnsafeMutablePointer<UInt8>.allocate(capacity: ctLen)
        let ss = UnsafeMutablePointer<UInt8>.allocate(capacity: ssLen)
        defer { ct.deallocate(); ss.deallocate() }
        let status = pubKey.withUnsafeBytes { pPtr -> OQS_STATUS in
            guard let p = pPtr.bindMemory(to: UInt8.self).baseAddress else {
                return OQS_ERROR
            }
            return OQS_KEM_encaps(kem, ct, ss, p)
        }
        if status != OQS_SUCCESS { throw NSError(domain: "PQC", code: -314, userInfo: [NSLocalizedDescriptionKey: "OQS_KEM_encaps 失败: \(name)"]) }
        let ctData = Data(bytes: ct, count: ctLen)
        let ssData = Data(bytes: ss, count: ssLen)
        return (ssData, ctData)
    }

    public static func kemDecapsulate(_ encapsulated: Data, peerId: String, algorithm: OQSAlgorithm) async throws -> Data {
        let name = kemName(algorithm)
        guard !name.isEmpty, let kem = OQS_KEM_new(name) else {
            throw NSError(domain: "PQC", code: -321, userInfo: [NSLocalizedDescriptionKey: "OQS_KEM_new 失败: \(name)"])
        }
        defer { OQS_KEM_free(kem) }
        let privService = PQCKeyTags.service("MLKEM", algorithm == .mlkem768 ? "768" : "1024", "Priv")
 // KeychainManager 方法是 nonisolated 的，可以同步调用
        guard let sk = KeychainManager.shared.exportKey(service: privService, account: peerId) else {
            throw NSError(domain: "PQC", code: -322, userInfo: [NSLocalizedDescriptionKey: "未找到私钥: \(privService) :: \(peerId)"])
        }
        let ssLen = Int(kem.pointee.length_shared_secret)
        let ss = UnsafeMutablePointer<UInt8>.allocate(capacity: ssLen)
        defer { ss.deallocate() }
        let status = sk.withUnsafeBytes { sPtr in
            encapsulated.withUnsafeBytes { cPtr in
                guard let s = sPtr.bindMemory(to: UInt8.self).baseAddress,
                      let c = cPtr.bindMemory(to: UInt8.self).baseAddress else {
                    return OQS_ERROR
                }
                return OQS_KEM_decaps(kem, ss, c, s)
            }
        }
        if status != OQS_SUCCESS { throw NSError(domain: "PQC", code: -323, userInfo: [NSLocalizedDescriptionKey: "OQS_KEM_decaps 失败: \(name)"]) }
        return Data(bytes: ss, count: ssLen)
    }
}
#else
public enum OQSAlgorithm: String { case mldsa65, mldsa87, mlkem768, mlkem1024 }
public final class OQSBridge {
    private static let logger = Logger(subsystem: "com.skybridge.quantum", category: "OQSBridge")
    public static func sign(_ data: Data, peerId: String, algorithm: OQSAlgorithm) async throws -> Data {
        throw NSError(domain: "PQC", code: -201, userInfo: [NSLocalizedDescriptionKey: "liboqs 未接入"])
    }
    public static func verify(_ data: Data, signature: Data, peerId: String, algorithm: OQSAlgorithm) async -> Bool {
        return false
    }
    public static func kemEncapsulate(peerId: String, algorithm: OQSAlgorithm) async throws -> (shared: Data, encapsulated: Data) {
        throw NSError(domain: "PQC", code: -202, userInfo: [NSLocalizedDescriptionKey: "liboqs 未接入"])
    }
    public static func kemDecapsulate(_ encapsulated: Data, peerId: String, algorithm: OQSAlgorithm) async throws -> Data {
        throw NSError(domain: "PQC", code: -203, userInfo: [NSLocalizedDescriptionKey: "liboqs 未接入"])
    }
}
#endif
