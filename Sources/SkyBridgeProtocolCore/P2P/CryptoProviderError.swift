import Foundation

public enum KeyUsage: String, Sendable {
    case keyExchange = "keyExchange"
    case signing = "signing"
}

public enum CryptoProviderError: Error, LocalizedError, Sendable {
    case unsupportedAlgorithm(String)
    case keyGenerationFailed(String)
    case encapsulationFailed(String)
    case decapsulationFailed(String)
    case signatureFailed(String)
    case verificationFailed(String)
    case invalidKeyFormat
    case providerNotAvailable(CryptoProviderType)
    case notImplemented(String)

    case invalidSealedBox(String)
    case invalidMagic
    case unsupportedVersion(UInt8)
    case lengthExceeded(String, Int, Int)
    case invalidNonceLength(Int)
    case invalidTagLength(Int)
    case lengthOverflow
    case lengthMismatch(expected: Int, actual: Int)

    case invalidKeyLength(expected: Int, actual: Int, suite: String, usage: KeyUsage)
    case keyUsageMismatch(expected: KeyUsage, actual: KeyUsage)

    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedAlgorithm(let alg):
            return "Unsupported algorithm: \(alg)"
        case .keyGenerationFailed(let reason):
            return "Key generation failed: \(reason)"
        case .encapsulationFailed(let reason):
            return "Encapsulation failed: \(reason)"
        case .decapsulationFailed(let reason):
            return "Decapsulation failed: \(reason)"
        case .signatureFailed(let reason):
            return "Signature failed: \(reason)"
        case .verificationFailed(let reason):
            return "Verification failed: \(reason)"
        case .invalidKeyFormat:
            return "Invalid key format"
        case .providerNotAvailable(let type):
            return "Crypto provider not available: \(type.rawValue)"
        case .notImplemented(let msg):
            return "Not implemented: \(msg)"
        case .invalidSealedBox(let reason):
            return "Invalid sealed box: \(reason)"
        case .invalidMagic:
            return "Invalid HPKE magic bytes"
        case .unsupportedVersion(let v):
            return "Unsupported HPKE version: \(v)"
        case .lengthExceeded(let field, let actual, let max):
            return "Length exceeded for \(field): \(actual) > \(max)"
        case .invalidNonceLength(let len):
            return "Invalid nonce length: \(len) (expected 12)"
        case .invalidTagLength(let len):
            return "Invalid tag length: \(len) (expected 16)"
        case .lengthOverflow:
            return "Length field overflow detected"
        case .lengthMismatch(let expected, let actual):
            return "Length mismatch: expected \(expected), got \(actual)"
        case .invalidKeyLength(let expected, let actual, let suite, let usage):
            return "Invalid key length for \(suite)/\(usage.rawValue): expected \(expected), got \(actual)"
        case .keyUsageMismatch(let expected, let actual):
            return "Key usage mismatch: expected \(expected.rawValue), got \(actual.rawValue)"
        case .operationFailed(let reason):
            return "Crypto operation failed: \(reason)"
        }
    }
}
