import Foundation
import SkyBridgeQPeriaptRuntime

/// Canonical pre-KEM application context for Q-Periapt ABI2 MessageA.
///
/// The full MessageA transcript cannot exist until its KEM ciphertext exists,
/// so this encoding commits every stable initiator field available before KEM
/// plus the exact recipient public key. Its field order and byte order match the
/// shared macOS handshake contract; transport-local metadata never participates.
enum QPeriaptHandshakeApplicationContext {
    private static let domain = Data("skybridge/qperiapt/abi2/message-a-kem/v1".utf8)

    static func messageA(
        version: UInt8,
        suite: CryptoSuite,
        clientNonce: Data,
        recipientPublicKey: Data,
        policy: HandshakePolicy,
        offeredSuites: [CryptoSuite],
        capabilities: CryptoCapabilities,
        identityPublicKey: Data,
        extensionsRaw: Data
    ) throws -> Data {
        guard suite == .qperiaptABI2PolicyBound else {
            throw CryptoProviderError.unsupportedOperation(
                "Q-Periapt application context requires suite 0x0012"
            )
        }
        guard clientNonce.count == HandshakeConstants.nonceSize else {
            throw CryptoProviderError.invalidKeySize(
                expected: HandshakeConstants.nonceSize,
                actual: clientNonce.count
            )
        }
        let publicKeyLength = QPeriaptNativeAdapter<SecureBytes>.publicKeyLength
        guard recipientPublicKey.count == publicKeyLength else {
            throw CryptoProviderError.invalidKeyLength(
                expected: publicKeyLength,
                actual: recipientPublicKey.count,
                suite: suite.rawValue,
                usage: .keyExchange
            )
        }
        guard !offeredSuites.isEmpty,
              offeredSuites.count <= Int(HandshakeConstants.maxSupportedSuites),
              offeredSuites.contains(.qperiaptABI2PolicyBound),
              Set(offeredSuites.map(\.wireId)).count == offeredSuites.count,
              offeredSuites.allSatisfy(\.isNegotiable) else {
            throw CryptoProviderError.unsupportedOperation(
                "Q-Periapt application context received a non-canonical suite offer"
            )
        }

        var suites = Data(capacity: offeredSuites.count * MemoryLayout<UInt16>.size)
        for offeredSuite in offeredSuites {
            appendUInt16BE(offeredSuite.wireId, to: &suites)
        }

        var context = Data()
        appendField(domain, to: &context)
        context.append(version)
        appendUInt16BE(suite.wireId, to: &context)
        appendField(clientNonce, to: &context)
        appendField(policy.deterministicEncode(), to: &context)
        appendField(suites, to: &context)
        appendField(try capabilities.deterministicEncode(), to: &context)
        appendField(identityPublicKey, to: &context)
        appendField(extensionsRaw, to: &context)
        appendField(recipientPublicKey, to: &context)

        let maximumLength = QPeriaptNativeAdapter<SecureBytes>.maximumApplicationContextLength
        guard !context.isEmpty, context.count <= maximumLength else {
            throw CryptoProviderError.invalidCiphertext(
                "Q-Periapt MessageA application context exceeds \(maximumLength) bytes"
            )
        }
        return context
    }

    private static func appendField(_ field: Data, to output: inout Data) {
        var length = UInt32(field.count).bigEndian
        withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
        output.append(field)
    }

    private static func appendUInt16BE(_ value: UInt16, to output: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { output.append(contentsOf: $0) }
    }
}
