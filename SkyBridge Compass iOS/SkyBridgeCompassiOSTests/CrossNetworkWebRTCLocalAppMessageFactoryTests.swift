import XCTest
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class CrossNetworkWebRTCLocalAppMessageFactoryTests: XCTestCase {
    func testFileTransferRouteBindingUsesSessionDescriptorAndPublishedRoute() throws {
        let keys = makeSessionKeys()
        let sentAt = Date(timeIntervalSinceReferenceDate: 123)
        let messages = try CrossNetworkWebRTCLocalAppMessageFactory.authenticatedFileTransferRouteBindingMessages(
            keys: keys,
            localDeviceId: "ios-device",
            remoteAuthority: remoteAuthority(),
            localRouteAuthorityProtocolPublicKeyFingerprint: String(repeating: "b", count: 64),
            sentAt: sentAt
        )

        XCTAssertEqual(messages.count, 1)
        guard case .authenticatedRouteBinding(let payload) = messages[0] else {
            return XCTFail("expected authenticatedRouteBinding")
        }

        let descriptor = CrossNetworkWebRTCControlChannelCodec.sessionBindingDescriptor(for: keys)
        XCTAssertEqual(payload.kind, "fileTransfer")
        XCTAssertEqual(payload.serviceType, DiscoveredDevice.fileTransferServiceType)
        XCTAssertTrue(
            payload.instanceName.hasSuffix(".\(DiscoveredDevice.fileTransferServiceType).local")
        )
        XCTAssertEqual(payload.port, FileTransferConstants.defaultPort)
        XCTAssertEqual(payload.endpointProvenance, "resolved-dns-sd-endpoint")
        XCTAssertEqual(payload.localDeviceId, "ios-device")
        XCTAssertEqual(payload.remoteDeviceId, "windows-device")
        XCTAssertEqual(payload.routeAuthorityProtocolPublicKeyFingerprint, String(repeating: "b", count: 64))
        XCTAssertEqual(payload.remoteProtocolPublicKeyFingerprint, String(repeating: "a", count: 64))
        XCTAssertEqual(payload.sessionHashHex, descriptor.sessionHashHex)
        XCTAssertEqual(payload.transcriptPrefixHex, descriptor.transcriptPrefixHex)
        XCTAssertEqual(payload.sentAt, sentAt)
        XCTAssertEqual(payload.expiresAt.timeIntervalSince(sentAt), 120, accuracy: 0.001)
        XCTAssertEqual(payload.nonce.count, 16)
    }

    func testFileTransferRouteBindingRejectsInvalidIdentityInputs() throws {
        XCTAssertThrowsError(
            try CrossNetworkWebRTCLocalAppMessageFactory.authenticatedFileTransferRouteBindingMessages(
                keys: makeSessionKeys(),
                localDeviceId: "ios-device",
                remoteAuthority: remoteAuthority(fingerprint: String(repeating: "A", count: 64)),
                localRouteAuthorityProtocolPublicKeyFingerprint: String(repeating: "b", count: 64)
            )
        ) { error in
            XCTAssertEqual(
                error as? CrossNetworkWebRTCLocalAppMessageFactoryError,
                .invalidRemoteProtocolFingerprint
            )
        }

        XCTAssertThrowsError(
            try CrossNetworkWebRTCLocalAppMessageFactory.authenticatedFileTransferRouteBindingMessages(
                keys: makeSessionKeys(),
                localDeviceId: " ",
                remoteAuthority: remoteAuthority(),
                localRouteAuthorityProtocolPublicKeyFingerprint: String(repeating: "b", count: 64)
            )
        ) { error in
            XCTAssertEqual(error as? CrossNetworkWebRTCLocalAppMessageFactoryError, .invalidLocalDeviceId)
        }
    }

    private func makeSessionKeys() -> SessionKeys {
        let keyBytes = Data(repeating: 0x42, count: 32)
        return SessionKeys(
            sendKey: keyBytes,
            receiveKey: keyBytes,
            negotiatedSuite: .mlkem768,
            transcriptHash: Data(repeating: 0x24, count: 32),
            sessionId: "route-binding-session"
        )
    }

    private func remoteAuthority(
        fingerprint: String = String(repeating: "a", count: 64)
    ) -> CurrentPathRemoteAuthorityCompat {
        CurrentPathRemoteAuthorityCompat(
            deviceId: "windows-device",
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: fingerprint,
            protocolPublicKeyBytes: nil,
            deviceName: "Windows"
        )
    }
}
