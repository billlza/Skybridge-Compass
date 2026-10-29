import CryptoKit
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class HandshakeDriverOfferedSuitesRegressionTests: XCTestCase {
    func testInitiatorMessageAUsesOfferedSuitesWithoutAppendingClassicFallback() async throws {
        let transport = CapturingDiscoveryTransport()
        let cryptoProvider = MockMLKEM768CryptoProvider()
        let signatureProvider = MockMLDSA65SignatureProvider()

        let signingKey = Data(repeating: 0x11, count: 64)
        let keyHandle = SigningKeyHandle.softwareKey(signingKey)
        let identityPublicKey = signingKey

        let offeredSuites: [CryptoSuite] = [.mlkem768MLDSA65]
        let peerId = PeerIdentifier(deviceId: "test-peer")

        let peerKEMPublicKey = Data(repeating: 0xAA, count: 1184) // ML-KEM-768 public key length
        let trustProvider = StaticTrustProviderWithKEM(
            deviceId: peerId.deviceId,
            kemPublicKeys: [.mlkem768MLDSA65: peerKEMPublicKey]
        )

        let driver = try HandshakeDriver(
            transport: transport,
            cryptoProvider: cryptoProvider,
            protocolSignatureProvider: signatureProvider,
            protocolSigningKeyHandle: keyHandle,
            sigAAlgorithm: .mlDSA65,
            identityPublicKey: identityPublicKey,
            offeredSuites: offeredSuites,
            timeout: .seconds(5),
            trustProvider: trustProvider
        )

        do {
            _ = try await driver.initiateHandshake(with: peerId)
            XCTFail("Expected initiateHandshake to fail due to transport error")
        } catch {
            // Expected (CapturingDiscoveryTransport throws after capturing MessageA).
        }

        guard let captured = await transport.capturedData else {
            XCTFail("Expected transport to capture MessageA")
            return
        }

        // HandshakeDriver applies SBP1 handshake padding by default; unwrap before decoding.
        let unwrapped = HandshakePadding.unwrapIfNeeded(captured, label: "test/MessageA")
        let messageA = try HandshakeMessageA.decode(from: unwrapped)
        XCTAssertEqual(messageA.supportedSuites, offeredSuites)
        XCTAssertTrue(messageA.supportedSuites.allSatisfy { $0.isPQCGroup })
    }
}

@available(macOS 14.0, iOS 17.0, *)
private actor CapturingDiscoveryTransport: DiscoveryTransport {
    private(set) var capturedData: Data?

    func send(to peer: PeerIdentifier, data: Data) async throws {
        capturedData = data
        throw NSError(domain: "CapturingDiscoveryTransport", code: 1, userInfo: nil)
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct StaticTrustProviderWithKEM: HandshakeTrustProvider, Sendable {
    let deviceId: String
    let kemPublicKeys: [CryptoSuite: Data]

    func trustedFingerprint(for deviceId: String) async -> String? {
        nil
    }

    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        guard deviceId == self.deviceId else { return [:] }
        return kemPublicKeys
    }

    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
        nil
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct MockMLKEM768CryptoProvider: CryptoProvider, Sendable {
    let providerName: String = "MockMLKEM768"
    let tier: CryptoTier = .liboqsPQC
    let activeSuite: CryptoSuite = .mlkem768MLDSA65

    func hpkeSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox {
        throw CryptoProviderError.notImplemented("Mock provider")
    }

    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws -> Data {
        throw CryptoProviderError.notImplemented("Mock provider")
    }

    func kemEncapsulate(recipientPublicKey: Data) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        let encapsulatedKey = Data(repeating: 0xA5, count: 1088) // ML-KEM-768 ciphertext length (wire keyShare)
        let sharedSecret = SecureBytes(data: Data(repeating: 0x5A, count: 32))
        return (encapsulatedKey: encapsulatedKey, sharedSecret: sharedSecret)
    }

    func kemDecapsulate(encapsulatedKey: Data, privateKey: SecureBytes) async throws -> SecureBytes {
        SecureBytes(data: Data(repeating: 0x5A, count: 32))
    }

    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        throw CryptoProviderError.notImplemented("Mock provider")
    }

    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        throw CryptoProviderError.notImplemented("Mock provider")
    }

    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        throw CryptoProviderError.notImplemented("Mock provider")
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct MockMLDSA65SignatureProvider: ProtocolSignatureProvider, Sendable {
    let signatureAlgorithm: ProtocolSigningAlgorithm = .mlDSA65

    func sign(_ data: Data, key: SigningKeyHandle) async throws -> Data {
        guard case .softwareKey(let keyData) = key else {
            throw SignatureProviderError.unsupportedKeyHandle(String(describing: key))
        }
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: keyData))
        return Data(mac)
    }

    func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: publicKey))
        return Data(mac) == signature
    }
}

