import XCTest
import CryptoKit
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class CrossNetworkWebRTCManagerDirectProbeTests: XCTestCase {
    func testDirectProbeDecryptsRawCiphertextPayload() throws {
        let keys = makeSessionKeys()
        let plaintext = Data("hello-direct-probe".utf8)
        let ciphertext = try encryptForInboundProbe(plaintext, keys: keys)

        let decrypted = CrossNetworkWebRTCManager.decryptDirectControlProbePayload(
            ciphertext,
            keys: keys
        )

        XCTAssertEqual(decrypted, plaintext)
    }

    func testDirectProbeReturnsNilForLengthPrefixedFrame() throws {
        let keys = makeSessionKeys()
        let plaintext = Data("hello-framed-payload".utf8)
        let ciphertext = try encryptForInboundProbe(plaintext, keys: keys)
        var framed = Data()
        var length = UInt32(ciphertext.count).bigEndian
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(ciphertext)

        let decrypted = CrossNetworkWebRTCManager.decryptDirectControlProbePayload(
            framed,
            keys: keys
        )

        XCTAssertNil(decrypted)
    }

    private func makeSessionKeys() -> SessionKeys {
        let keyBytes = Data(repeating: 0x42, count: 32)
        return SessionKeys(
            sendKey: keyBytes,
            receiveKey: keyBytes,
            negotiatedSuite: .mlKem768,
            transcriptHash: Data(repeating: 0x24, count: 32)
        )
    }

    private func encryptForInboundProbe(_ plaintext: Data, keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.receiveKey)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            XCTFail("Missing combined ciphertext")
            return Data()
        }
        return combined
    }
}
