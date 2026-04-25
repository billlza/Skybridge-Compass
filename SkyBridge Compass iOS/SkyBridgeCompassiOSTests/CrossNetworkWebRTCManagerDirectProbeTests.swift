import XCTest
import CryptoKit
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class CrossNetworkWebRTCManagerDirectProbeTests: XCTestCase {
    @MainActor
    func testDirectProbeDecryptsRawCiphertextPayload() throws {
        let keys = makeSessionKeys()
        let plaintext = Data("hello-direct-probe".utf8)
        let ciphertext = try encryptForInboundProbe(plaintext, keys: keys)

        let decrypted = CrossNetworkWebRTCManager.testOnlyDecryptDirectControlProbePayload(
            ciphertext,
            keys: keys
        )

        XCTAssertEqual(decrypted, plaintext)
    }

    @MainActor
    func testDirectProbeReturnsNilForLengthPrefixedFrame() throws {
        let keys = makeSessionKeys()
        let plaintext = Data("hello-framed-payload".utf8)
        let ciphertext = try encryptForInboundProbe(plaintext, keys: keys)
        var framed = Data()
        var length = UInt32(ciphertext.count).bigEndian
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(ciphertext)

        let decrypted = CrossNetworkWebRTCManager.testOnlyDecryptDirectControlProbePayload(
            framed,
            keys: keys
        )

        XCTAssertNil(decrypted)
    }

    func testHighThroughputRemoteDesktopScreenPayloadDecodesOffMainActor() async throws {
        let screen = ScreenData(
            width: 2,
            height: 2,
            imageData: Data([0x01, 0x02, 0x03]),
            timestamp: 1_700_000_000,
            format: "jpeg",
            isSyncFrame: true
        )
        let inner = try JSONEncoder().encode(screen)
        let message = RemoteMessage(type: .screenData, payload: inner)
        let plaintext = try JSONEncoder().encode(message)

        let kind = await Task.detached {
            CrossNetworkWebRTCManager.testOnlyDecodeHighThroughputRemoteDesktopPayloadKind(plaintext)
        }.value

        XCTAssertEqual(kind, "screen")
    }

    @MainActor
    func testViewerStreamConfigurationKeepsCrossNetworkFallbackOnDedicatedScreenChannel() {
        let payload = RemoteDesktopManager.instance.makeViewerStreamConfigurationPayload()

        XCTAssertEqual(payload.screenDataChannelEnabled, true)
    }

    private func makeSessionKeys() -> SessionKeys {
        let keyBytes = Data(repeating: 0x42, count: 32)
        return SessionKeys(
            sendKey: keyBytes,
            receiveKey: keyBytes,
            negotiatedSuite: .mlkem768,
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
