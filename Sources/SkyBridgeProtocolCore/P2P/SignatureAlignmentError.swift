import Foundation

public enum SignatureAlignmentError: Error, LocalizedError, Sendable {
    case protocolKeyGenerationFailed(String)
    case protocolKeyNotFound
    case signatureAlgorithmMismatch(expected: SignatureAlgorithm, actual: SignatureAlgorithm)
    case suiteSignatureMismatch(selectedSuite: String, sigAAlgorithm: String)
    case legacySignatureRejected
    case migrationFailed(String)
    case providerAlgorithmMismatch(expected: ProtocolSigningAlgorithm, actual: ProtocolSigningAlgorithm)
    case wireAlgorithmMismatch(wireAlgorithm: SignatureAlgorithm, sigAAlgorithm: ProtocolSigningAlgorithm)
    case homogeneityViolation(sigAAlgorithm: ProtocolSigningAlgorithm, offeredSuites: [CryptoSuite])
    case emptyOfferedSuites
    case legacyFallbackNotAllowed(reason: String)
    case transcriptMismatch
    case invalidAlgorithmForProtocolSigning(algorithm: SignatureAlgorithm)
    case invalidProviderType(message: String)

    public var errorDescription: String? {
        switch self {
        case .protocolKeyGenerationFailed(let reason):
            return "Protocol signing key generation failed: \(reason)"
        case .protocolKeyNotFound:
            return "Protocol signing key not found"
        case .signatureAlgorithmMismatch(let expected, let actual):
            return "Signature algorithm mismatch: expected \(expected.rawValue), got \(actual.rawValue)"
        case .suiteSignatureMismatch(let selectedSuite, let sigAAlgorithm):
            return "Suite-signature mismatch: selectedSuite \(selectedSuite) incompatible with sigA algorithm \(sigAAlgorithm)"
        case .legacySignatureRejected:
            return "Legacy signature rejected (transition period ended)"
        case .migrationFailed(let reason):
            return "Key migration failed: \(reason)"
        case .providerAlgorithmMismatch(let expected, let actual):
            return "Provider algorithm mismatch: expected \(expected.rawValue), got \(actual.rawValue)"
        case .wireAlgorithmMismatch(let wireAlgorithm, let sigAAlgorithm):
            return "Wire algorithm \(wireAlgorithm.rawValue) does not match sigAAlgorithm \(sigAAlgorithm.rawValue)"
        case .homogeneityViolation(let sigAAlgorithm, let offeredSuites):
            return "Homogeneity violation: sigAAlgorithm=\(sigAAlgorithm.rawValue), offeredSuites count=\(offeredSuites.count)"
        case .emptyOfferedSuites:
            return "offeredSuites cannot be empty"
        case .legacyFallbackNotAllowed(let reason):
            return "Legacy fallback not allowed: \(reason)"
        case .transcriptMismatch:
            return "Transcript mismatch detected"
        case .invalidAlgorithmForProtocolSigning(let algorithm):
            return "Algorithm \(algorithm.rawValue) is not allowed for protocol signing (sigA/sigB)"
        case .invalidProviderType(let message):
            return "Invalid provider type: \(message)"
        }
    }
}
