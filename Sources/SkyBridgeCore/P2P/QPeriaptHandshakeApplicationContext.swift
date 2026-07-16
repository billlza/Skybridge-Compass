import Foundation
import SkyBridgeProtocolCore

/// Canonical pre-KEM application context for Q-Periapt ABI2 MessageA.
///
/// MessageA's full transcript cannot exist until its KEM ciphertext exists, so
/// the context commits every stable, security-relevant initiator field available
/// before key-share generation plus the exact recipient Q-Periapt public key.
/// Both roles call this encoder with the same values; no JSON/default encoder or
/// transport-local metadata participates.
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
            throw CryptoProviderError.unsupportedAlgorithm(suite.rawValue)
        }
        guard clientNonce.count == 32 else {
            throw CryptoProviderError.lengthMismatch(expected: 32, actual: clientNonce.count)
        }
        guard recipientPublicKey.count == QPeriaptNativeAdapter.publicKeyLength else {
            throw CryptoProviderError.invalidKeyLength(
                expected: QPeriaptNativeAdapter.publicKeyLength,
                actual: recipientPublicKey.count,
                suite: suite.rawValue,
                usage: .keyExchange
            )
        }
        guard !offeredSuites.isEmpty,
              offeredSuites.count <= Int(HandshakeConstants.maxSupportedSuites),
              offeredSuites.contains(.qperiaptABI2PolicyBound),
              Set(offeredSuites).count == offeredSuites.count,
              offeredSuites.allSatisfy(\.isNegotiable) else {
            throw CryptoProviderError.operationFailed(
                "Q-Periapt ABI2 application context received a non-canonical suite offer"
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

        guard !context.isEmpty,
              context.count <= QPeriaptNativeAdapter.maximumApplicationContextLength else {
            throw CryptoProviderError.lengthExceeded(
                "Q-Periapt MessageA application context",
                context.count,
                QPeriaptNativeAdapter.maximumApplicationContextLength
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
