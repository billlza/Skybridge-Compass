import Foundation

public struct QuantumSecurityStatus: Sendable {
    public let pqcEnabled: Bool
    public let tlsHybridEnabled: Bool
    public let secureEnclaveSigning: Bool
    public let secureEnclaveKEM: Bool
    public let algorithm: PQCAlgorithm

    public init(pqcEnabled: Bool, tlsHybridEnabled: Bool, secureEnclaveSigning: Bool, secureEnclaveKEM: Bool, algorithm: PQCAlgorithm) {
        self.pqcEnabled = pqcEnabled
        self.tlsHybridEnabled = tlsHybridEnabled
        self.secureEnclaveSigning = secureEnclaveSigning
        self.secureEnclaveKEM = secureEnclaveKEM
        self.algorithm = algorithm
    }
}

public enum PQCAlgorithm: String, CaseIterable, Sendable {
    case mldsa = "ML-DSA"
    case falcon = "Falcon"
    case dilithium = "Dilithium"
}

public extension QuantumSecurityStatus {
    static let `default` = QuantumSecurityStatus(
        pqcEnabled: true,
        tlsHybridEnabled: true,
        secureEnclaveSigning: true,
        secureEnclaveKEM: false,
        algorithm: .mldsa
    )
}
