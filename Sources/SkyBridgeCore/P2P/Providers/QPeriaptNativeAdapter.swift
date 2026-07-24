import Foundation
import SkyBridgeProtocolCore
import SkyBridgeQPeriaptRuntime

public typealias QPeriaptCryptoAdmissionError =
    SkyBridgeQPeriaptRuntime.QPeriaptCryptoAdmissionError

extension SecureBytes: QPeriaptSecretBuffer {}

/// SkyBridgeCore compatibility facade. Native execution operates directly on
/// `SecureBytes` through the shared secret-buffer protocol; this layer only
/// translates the target-owned typed errors into the established Core errors.
struct QPeriaptNativeAdapter: Sendable {
    private typealias SharedAdapter =
        SkyBridgeQPeriaptRuntime.QPeriaptNativeAdapter<SecureBytes>

    static var publicKeyLength: Int { SharedAdapter.publicKeyLength }
    static var privateKeyLength: Int { SharedAdapter.privateKeyLength }
    static var encapsulatedKeyLength: Int { SharedAdapter.encapsulatedKeyLength }
    static var sharedSecretLength: Int { SharedAdapter.sharedSecretLength }
    static var maximumApplicationContextLength: Int {
        SharedAdapter.maximumApplicationContextLength
    }

    private let adapter: SharedAdapter

    init(session: QPeriaptRuntimeSession) {
        adapter = SharedAdapter(session: session)
    }

    func generateKeyPair() async throws -> (publicKey: Data, privateKey: SecureBytes) {
        try await translateNativeErrors {
            try await adapter.generateKeyPair()
        }
    }

    func encapsulate(
        recipientPublicKey: Data,
        applicationContext: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        try await translateNativeErrors {
            try await adapter.encapsulate(
                recipientPublicKey: recipientPublicKey,
                applicationContext: applicationContext
            )
        }
    }

    func decapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes,
        applicationContext: Data
    ) async throws -> SecureBytes {
        try await translateNativeErrors {
            try await adapter.decapsulate(
                encapsulatedKey: encapsulatedKey,
                privateKey: privateKey,
                applicationContext: applicationContext
            )
        }
    }

    private func translateNativeErrors<Result: Sendable>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        do {
            return try await operation()
        } catch let error as QPeriaptNativeError {
            throw Self.coreError(for: error)
        }
    }

    private static func coreError(for error: QPeriaptNativeError) -> CryptoProviderError {
        switch error {
        case .runtimeContract(let contractError):
            return .operationFailed(contractError.localizedDescription)
        case .emptyApplicationContext:
            return .operationFailed("Q-Periapt ABI2 application context must not be empty")
        case .applicationContextTooLarge(let actual, let maximum):
            return .lengthExceeded("Q-Periapt application context", actual, maximum)
        case .invalidRecipientPublicKeyLength(let expected, let actual),
             .invalidPrivateKeyLength(let expected, let actual):
            return .invalidKeyLength(
                expected: expected,
                actual: actual,
                suite: "Q-Periapt-ABI2-PolicyBound",
                usage: .keyExchange
            )
        case .invalidCiphertextLength(let expected, let actual):
            return .operationFailed(
                "Invalid Q-Periapt ABI2 ciphertext length: expected \(expected), got \(actual)"
            )
        case .keyBlobAssemblyFailed:
            return .operationFailed("Q-Periapt ABI2 key blob assembly failed")
        case .keyGenerationFailed:
            return .keyGenerationFailed(error.localizedDescription)
        case .encapsulationFailed:
            return .encapsulationFailed(error.localizedDescription)
        case .decapsulationFailed:
            return .decapsulationFailed(error.localizedDescription)
        }
    }
}
