import Foundation
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class WebRTCControlChannelSecureEnvelopeTests: XCTestCase {
    func testEnvelopeBindsDirectionSessionTranscriptAndPacketType() throws {
        let (sender, receiver) = makePairedSessionKeys()
        let plaintext = Data("webrtc-app-message".utf8)
        let packet = try WebRTCControlChannelCodec.encryptAppPayload(
            plaintext,
            with: sender,
            packetType: .appControl,
            counter: 1
        )

        let opened = try WebRTCControlChannelCodec.decryptAppPayload(
            packet,
            with: receiver,
            allowedPacketTypes: [.appControl]
        )
        XCTAssertEqual(opened.payload, plaintext)
        XCTAssertEqual(opened.packetType, .appControl)
        XCTAssertEqual(opened.counter, 1)

        XCTAssertThrowsError(
            try WebRTCControlChannelCodec.decryptAppPayload(packet, with: sender)
        ) { error in
            XCTAssertEqual(
                error as? WebRTCAppSecureEnvelopeError,
                .directionMismatch(expected: 2, actual: 1)
            )
        }

        var wrongSessionReceiver = receiver
        wrongSessionReceiver = SessionKeys(
            sendKey: wrongSessionReceiver.sendKey,
            receiveKey: wrongSessionReceiver.receiveKey,
            negotiatedSuite: wrongSessionReceiver.negotiatedSuite,
            role: wrongSessionReceiver.role,
            transcriptHash: wrongSessionReceiver.transcriptHash,
            sessionId: "different-session"
        )
        XCTAssertThrowsError(
            try WebRTCControlChannelCodec.decryptAppPayload(packet, with: wrongSessionReceiver)
        ) { error in
            guard case .sessionMismatch = error as? WebRTCAppSecureEnvelopeError else {
                return XCTFail("expected session mismatch, got \(error)")
            }
        }

        let wrongTranscriptReceiver = SessionKeys(
            sendKey: receiver.sendKey,
            receiveKey: receiver.receiveKey,
            negotiatedSuite: receiver.negotiatedSuite,
            role: receiver.role,
            transcriptHash: Data(repeating: 0x55, count: 32),
            sessionId: receiver.sessionId
        )
        XCTAssertThrowsError(
            try WebRTCControlChannelCodec.decryptAppPayload(packet, with: wrongTranscriptReceiver)
        ) { error in
            guard case .transcriptMismatch = error as? WebRTCAppSecureEnvelopeError else {
                return XCTFail("expected transcript mismatch, got \(error)")
            }
        }

        XCTAssertThrowsError(
            try WebRTCControlChannelCodec.decryptAppPayload(
                packet,
                with: receiver,
                allowedPacketTypes: [.fileTransfer]
            )
        ) { error in
            XCTAssertEqual(
                error as? WebRTCAppSecureEnvelopeError,
                .packetTypeMismatch(expected: [.fileTransfer], actual: .appControl)
            )
        }
    }

    func testSessionBindingDescriptorMatchesOpenedEnvelopeHeader() throws {
        let (sender, receiver) = makePairedSessionKeys()
        let packet = try WebRTCControlChannelCodec.encryptAppPayload(
            Data("descriptor".utf8),
            with: sender,
            packetType: .appControl,
            counter: 9
        )
        let opened = try WebRTCControlChannelCodec.decryptAppPayload(
            packet,
            with: receiver,
            allowedPacketTypes: [.appControl]
        )
        let descriptor = WebRTCControlChannelCodec.sessionBindingDescriptor(for: sender)
        XCTAssertEqual(descriptor.sessionHashHex, String(format: "%016llx", opened.sessionHash))
        XCTAssertEqual(descriptor.transcriptPrefixHex, String(format: "%016llx", opened.transcriptPrefix))
    }

    func testLocalAuthenticatedRouteBindingFactoryUsesRegisteredProductRoutes() throws {
        let routes = CrossNetworkWebRTCLocalAppMessageFactory.localAuthenticatedRouteBindingRoutes(
            endpointSnapshot: ServiceEndpointSnapshot(fileTransferPort: 9443, remoteControlPort: 5901),
            serviceName: "Desk Mac",
            hostName: "desk-mac.local."
        )
        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(routes[0].kind, "fileTransfer")
        XCTAssertEqual(routes[0].serviceType, BonjourInteropContract.fileTransferServiceType)
        XCTAssertEqual(routes[0].instanceName, "Desk Mac._skybridge-xfer._tcp.local")
        XCTAssertEqual(routes[0].hostName, "desk-mac.local")
        XCTAssertEqual(routes[0].port, 9443)
        XCTAssertEqual(routes[1].kind, "remoteDesktop")
        XCTAssertEqual(routes[1].serviceType, BonjourInteropContract.remoteControlServiceType)
        XCTAssertEqual(routes[1].instanceName, "Desk Mac._skybridge-rd._tcp.local")
        XCTAssertEqual(routes[1].hostName, "desk-mac.local")
        XCTAssertEqual(routes[1].port, 5901)

        let messages = try CrossNetworkWebRTCLocalAppMessageFactory.authenticatedRouteBindingMessages(
            routes: routes,
            localDeviceId: "mac-device",
            remoteDeviceId: "windows-device",
            localProtocolPublicKeyFingerprint: String(repeating: "a", count: 64),
            remoteProtocolPublicKeyFingerprint: String(repeating: "b", count: 64),
            sessionBinding: .init(
                sessionHashHex: "0123456789abcdef",
                transcriptPrefixHex: "fedcba9876543210"
            ),
            sentAt: Date(timeIntervalSinceReferenceDate: 42),
            ttl: 30
        )
        XCTAssertEqual(messages.count, 2)
        guard case .authenticatedRouteBinding(let filePayload) = messages[0],
              case .authenticatedRouteBinding(let remotePayload) = messages[1] else {
            return XCTFail("expected authenticatedRouteBinding messages")
        }
        XCTAssertEqual(filePayload.kind, "fileTransfer")
        XCTAssertEqual(filePayload.endpointProvenance, "resolved-dns-sd-endpoint")
        XCTAssertEqual(filePayload.localDeviceId, "mac-device")
        XCTAssertEqual(filePayload.remoteDeviceId, "windows-device")
        XCTAssertEqual(filePayload.routeAuthorityProtocolPublicKeyFingerprint, String(repeating: "a", count: 64))
        XCTAssertEqual(filePayload.remoteProtocolPublicKeyFingerprint, String(repeating: "b", count: 64))
        XCTAssertEqual(filePayload.sessionHashHex, "0123456789abcdef")
        XCTAssertEqual(filePayload.transcriptPrefixHex, "fedcba9876543210")
        XCTAssertEqual(filePayload.sentAt, Date(timeIntervalSinceReferenceDate: 42))
        XCTAssertEqual(filePayload.expiresAt, Date(timeIntervalSinceReferenceDate: 72))
        XCTAssertEqual(filePayload.nonce.count, 16)
        XCTAssertEqual(remotePayload.kind, "remoteDesktop")
        XCTAssertEqual(remotePayload.port, 5901)
    }

    func testAuthenticatedRouteBindingPolicyPublishesOnlyVerifiedFileTransferRoutes() throws {
        let payload = authenticatedRouteBindingPayload(
            kind: "fileTransfer",
            serviceType: BonjourInteropContract.fileTransferServiceType,
            port: 9443
        )

        let decision = WebRTCAuthenticatedRouteBindingPolicy.evaluate(
            payload,
            context: routeBindingContext(now: Date(timeIntervalSinceReferenceDate: 60))
        )

        XCTAssertEqual(
            decision,
            .fileTransfer(.init(
                peerId: "windows-device",
                deviceName: "Windows PC",
                displayAddress: "windows-pc.local",
                transferAddress: "windows-pc.local",
                transferPort: 9443
            ))
        )
    }

    func testAuthenticatedRouteBindingPolicyAcceptsLegacyFileServiceAsInputOnly() throws {
        let payload = authenticatedRouteBindingPayload(
            kind: "fileTransfer",
            serviceType: BonjourInteropContract.legacyFileTransferServiceType,
            port: 9443
        )

        guard case .fileTransfer(let route) = WebRTCAuthenticatedRouteBindingPolicy.evaluate(
            payload,
            context: routeBindingContext(now: Date(timeIntervalSinceReferenceDate: 60))
        ) else {
            return XCTFail("authenticated version-1 service input should remain readable")
        }
        XCTAssertEqual(route.transferPort, 9443)
    }

    func testAuthenticatedRouteBindingPolicyRejectsSessionBindingMismatch() throws {
        let payload = authenticatedRouteBindingPayload(
            kind: "fileTransfer",
            serviceType: BonjourInteropContract.fileTransferServiceType,
            port: 9443,
            sessionHashHex: "badbadbadbadbadb"
        )

        XCTAssertEqual(
            WebRTCAuthenticatedRouteBindingPolicy.evaluate(
                payload,
                context: routeBindingContext(now: Date(timeIntervalSinceReferenceDate: 60))
            ),
            .rejected(reason: "session_binding_mismatch")
        )
    }

    func testAuthenticatedRouteBindingPolicyDoesNotPublishRemoteDesktopAsFileRoute() throws {
        let payload = authenticatedRouteBindingPayload(
            kind: "remoteDesktop",
            serviceType: BonjourInteropContract.remoteControlServiceType,
            port: 5901
        )

        XCTAssertEqual(
            WebRTCAuthenticatedRouteBindingPolicy.evaluate(
                payload,
                context: routeBindingContext(now: Date(timeIntervalSinceReferenceDate: 60))
            ),
            .verifiedButUnsupported(kind: "remoteDesktop")
        )
    }

    func testLocalAuthenticatedRouteBindingFactoryFailsClosedForInvalidIdentityInputs() throws {
        XCTAssertThrowsError(
            try CrossNetworkWebRTCLocalAppMessageFactory.authenticatedRouteBindingMessages(
                routes: [.init(
                    kind: "fileTransfer",
                    serviceType: BonjourInteropContract.fileTransferServiceType,
                    instanceName: "Desk Mac._skybridge-xfer._tcp.local",
                    hostName: "desk-mac.local",
                    port: 9443
                )],
                localDeviceId: "",
                remoteDeviceId: "windows-device",
                localProtocolPublicKeyFingerprint: String(repeating: "a", count: 64),
                remoteProtocolPublicKeyFingerprint: String(repeating: "b", count: 64),
                sessionBinding: .init(
                    sessionHashHex: "0123456789abcdef",
                    transcriptPrefixHex: "fedcba9876543210"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? CrossNetworkWebRTCLocalAppMessageFactoryError,
                .missingRequiredToken("local route-binding device id")
            )
        }

        XCTAssertThrowsError(
            try CrossNetworkWebRTCLocalAppMessageFactory.authenticatedRouteBindingMessages(
                routes: [.init(
                    kind: "fileTransfer",
                    serviceType: BonjourInteropContract.fileTransferServiceType,
                    instanceName: "Desk Mac._skybridge-xfer._tcp.local",
                    hostName: "desk-mac.local",
                    port: 9443
                )],
                localDeviceId: "mac-device",
                remoteDeviceId: "windows-device",
                localProtocolPublicKeyFingerprint: String(repeating: "A", count: 64),
                remoteProtocolPublicKeyFingerprint: String(repeating: "b", count: 64),
                sessionBinding: .init(
                    sessionHashHex: "0123456789abcdef",
                    transcriptPrefixHex: "fedcba9876543210"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? CrossNetworkWebRTCLocalAppMessageFactoryError,
                .invalidProtocolFingerprint("local route-binding protocol fingerprint")
            )
        }
    }

    private func authenticatedRouteBindingPayload(
        kind: String,
        serviceType: String,
        port: UInt16,
        sessionHashHex: String = "0123456789abcdef"
    ) -> AppMessage.AuthenticatedRouteBindingPayload {
        AppMessage.AuthenticatedRouteBindingPayload(
            kind: kind,
            serviceType: serviceType,
            instanceName: "Windows PC.\(serviceType).local",
            hostName: "windows-pc.local.",
            port: port,
            endpointProvenance: CrossNetworkWebRTCLocalAppMessageFactory.routeBindingEndpointProvenance,
            localDeviceId: "windows-device",
            remoteDeviceId: "mac-device",
            routeAuthorityProtocolPublicKeyFingerprint: String(repeating: "a", count: 64),
            remoteProtocolPublicKeyFingerprint: String(repeating: "b", count: 64),
            sessionHashHex: sessionHashHex,
            transcriptPrefixHex: "fedcba9876543210",
            sentAt: Date(timeIntervalSinceReferenceDate: 42),
            expiresAt: Date(timeIntervalSinceReferenceDate: 72),
            nonce: Data(1...16)
        )
    }

    private func routeBindingContext(now: Date) -> WebRTCAuthenticatedRouteBindingPolicy.Context {
        .init(
            localDeviceId: "mac-device",
            localProtocolPublicKeyFingerprint: String(repeating: "b", count: 64),
            expectedRemoteAuthority: CurrentPathRemoteAuthority(
                deviceId: "windows-device",
                protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
                protocolPublicKeyBytes: nil,
                deviceName: "Windows PC"
            ),
            sessionBinding: .init(
                sessionHashHex: "0123456789abcdef",
                transcriptPrefixHex: "fedcba9876543210"
            ),
            now: now
        )
    }

    func testEnvelopeRejectsHeaderAndCiphertextTampering() throws {
        let (sender, receiver) = makePairedSessionKeys()
        let packet = try WebRTCControlChannelCodec.encryptAppPayload(
            Data("protected".utf8),
            with: sender,
            packetType: .remoteControl,
            counter: 7
        )

        var tamperedKind = packet
        tamperedKind[tamperedKind.startIndex + 6] = WebRTCAppSecurePacketType.fileTransfer.rawValue
        XCTAssertThrowsError(
            try WebRTCControlChannelCodec.decryptAppPayload(tamperedKind, with: receiver)
        ) { error in
            XCTAssertEqual(
                error as? WebRTCAppSecureEnvelopeError,
                .authenticationFailed(packetType: .fileTransfer, counter: 7)
            )
        }

        var tamperedCiphertext = packet
        tamperedCiphertext[tamperedCiphertext.index(tamperedCiphertext.endIndex, offsetBy: -17)] ^= 0x01
        XCTAssertThrowsError(
            try WebRTCControlChannelCodec.decryptAppPayload(tamperedCiphertext, with: receiver)
        ) { error in
            XCTAssertEqual(
                error as? WebRTCAppSecureEnvelopeError,
                .authenticationFailed(packetType: .remoteControl, counter: 7)
            )
        }
    }

    func testReplayWindowRejectsRepeatedCountersPerPacketType() throws {
        let (sender, receiver) = makePairedSessionKeys()
        let packet = try WebRTCControlChannelCodec.encryptAppPayload(
            Data("file-ack".utf8),
            with: sender,
            packetType: .fileTransfer,
            counter: 3
        )
        let opened = try WebRTCControlChannelCodec.decryptAppPayload(packet, with: receiver)

        var replayWindow = WebRTCAppSecureReplayWindow()
        try replayWindow.validateAndRecord(opened)
        XCTAssertThrowsError(try replayWindow.validateAndRecord(opened)) { error in
            XCTAssertEqual(
                error as? WebRTCAppSecureEnvelopeError,
                .replayDetected(
                    packetType: .fileTransfer,
                    counter: 3,
                    highestCounter: 3,
                    reason: .duplicateCounter
                )
            )
        }

        let appPacket = try WebRTCControlChannelCodec.encryptAppPayload(
            Data("heartbeat".utf8),
            with: sender,
            packetType: .appControl,
            counter: 3
        )
        let appOpened = try WebRTCControlChannelCodec.decryptAppPayload(appPacket, with: receiver)
        XCTAssertNoThrow(try replayWindow.validateAndRecord(appOpened))
    }

    func testReplayWindowAcceptsOutOfOrderCounterInsideWindowThenRejectsDuplicate() throws {
        let (sender, receiver) = makePairedSessionKeys()
        let highPacket = try WebRTCControlChannelCodec.encryptAppPayload(
            Data("desktop-193".utf8),
            with: sender,
            packetType: .remoteDesktop,
            counter: 193
        )
        let latePacket = try WebRTCControlChannelCodec.encryptAppPayload(
            Data("desktop-191".utf8),
            with: sender,
            packetType: .remoteDesktop,
            counter: 191
        )
        let openedHigh = try WebRTCControlChannelCodec.decryptAppPayload(
            highPacket,
            with: receiver,
            allowedPacketTypes: [.remoteDesktop]
        )
        let openedLate = try WebRTCControlChannelCodec.decryptAppPayload(
            latePacket,
            with: receiver,
            allowedPacketTypes: [.remoteDesktop]
        )
        var replayWindow = WebRTCAppSecureReplayWindow()

        try replayWindow.validateAndRecord(openedHigh)
        XCTAssertNoThrow(try replayWindow.validateAndRecord(openedLate))
        XCTAssertThrowsError(try replayWindow.validateAndRecord(openedLate)) { error in
            XCTAssertEqual(
                error as? WebRTCAppSecureEnvelopeError,
                .replayDetected(
                    packetType: .remoteDesktop,
                    counter: 191,
                    highestCounter: 193,
                    reason: .duplicateCounter
                )
            )
        }
    }

    func testReplayWindowRejectsCounterOutsideSlidingWindow() throws {
        let (sender, receiver) = makePairedSessionKeys()
        let highPacket = try WebRTCControlChannelCodec.encryptAppPayload(
            Data("desktop-2000".utf8),
            with: sender,
            packetType: .remoteDesktop,
            counter: 2_000
        )
        let oldestInWindowPacket = try WebRTCControlChannelCodec.encryptAppPayload(
            Data("desktop-977".utf8),
            with: sender,
            packetType: .remoteDesktop,
            counter: 977
        )
        let stalePacket = try WebRTCControlChannelCodec.encryptAppPayload(
            Data("desktop-976".utf8),
            with: sender,
            packetType: .remoteDesktop,
            counter: 976
        )
        let openedHigh = try WebRTCControlChannelCodec.decryptAppPayload(
            highPacket,
            with: receiver,
            allowedPacketTypes: [.remoteDesktop]
        )
        let openedOldestInWindow = try WebRTCControlChannelCodec.decryptAppPayload(
            oldestInWindowPacket,
            with: receiver,
            allowedPacketTypes: [.remoteDesktop]
        )
        let openedStale = try WebRTCControlChannelCodec.decryptAppPayload(
            stalePacket,
            with: receiver,
            allowedPacketTypes: [.remoteDesktop]
        )
        var replayWindow = WebRTCAppSecureReplayWindow()

        try replayWindow.validateAndRecord(openedHigh)
        XCTAssertNoThrow(try replayWindow.validateAndRecord(openedOldestInWindow))
        XCTAssertThrowsError(try replayWindow.validateAndRecord(openedStale)) { error in
            XCTAssertEqual(
                error as? WebRTCAppSecureEnvelopeError,
                .replayDetected(
                    packetType: .remoteDesktop,
                    counter: 976,
                    highestCounter: 2_000,
                    reason: .counterOutsideWindow
                )
            )
        }
    }

    func testReplayWindowSeparatesRemoteDesktopScreenAndFallbackAudioLanes() throws {
        let (sender, receiver) = makePairedSessionKeys()
        let audioPacket = try WebRTCControlChannelCodec.encryptAppPayload(
            Data("fallback-audio".utf8),
            with: sender,
            packetType: .remoteDesktopAudio,
            counter: 8
        )
        let screenPacket = try WebRTCControlChannelCodec.encryptAppPayload(
            Data("screen-frame".utf8),
            with: sender,
            packetType: .remoteDesktop,
            counter: 7
        )

        let audioOpened = try WebRTCControlChannelCodec.decryptAppPayload(audioPacket, with: receiver)
        let screenOpened = try WebRTCControlChannelCodec.decryptAppPayload(screenPacket, with: receiver)

        var replayWindow = WebRTCAppSecureReplayWindow()
        try replayWindow.validateAndRecord(audioOpened)
        XCTAssertNoThrow(
            try replayWindow.validateAndRecord(screenOpened),
            "Fallback audio travels on the control channel and must not advance the screen frame replay lane."
        )

        XCTAssertThrowsError(try replayWindow.validateAndRecord(audioOpened)) { error in
            XCTAssertEqual(
                error as? WebRTCAppSecureEnvelopeError,
                .replayDetected(
                    packetType: .remoteDesktopAudio,
                    counter: 8,
                    highestCounter: 8,
                    reason: .duplicateCounter
                )
            )
        }
    }

    @MainActor
    func testManagerSharedCounterDoesNotMergeScreenAndFallbackAudioReplayLanes() throws {
        let senderManager = CrossNetworkConnectionManager()
        let receiverManager = CrossNetworkConnectionManager()
        let (sender, receiver) = makePairedSessionKeys()
        let sessionId = sender.sessionId

        let screenPacket = try senderManager.sealWebRTCSecurePayload(
            Data("screen-frame".utf8),
            with: sender,
            sessionID: sessionId,
            packetType: .remoteDesktop
        )
        let audioPacket = try senderManager.sealWebRTCSecurePayload(
            Data("fallback-audio".utf8),
            with: sender,
            sessionID: sessionId,
            packetType: .remoteDesktopAudio
        )

        let audioOpened = try receiverManager.openWebRTCSecurePayload(
            audioPacket,
            with: receiver,
            sessionID: sessionId,
            allowedPacketTypes: [.remoteDesktopAudio]
        )
        XCTAssertEqual(audioOpened.counter, 2)

        let screenOpened = try receiverManager.openWebRTCSecurePayload(
            screenPacket,
            with: receiver,
            sessionID: sessionId,
            allowedPacketTypes: [.remoteDesktop]
        )
        XCTAssertEqual(screenOpened.counter, 1)
        XCTAssertEqual(screenOpened.payload, Data("screen-frame".utf8))
    }

    func testSealRejectsZeroCounter() {
        let (sender, _) = makePairedSessionKeys()
        XCTAssertThrowsError(
            try WebRTCControlChannelCodec.encryptAppPayload(
                Data(),
                with: sender,
                packetType: .appControl,
                counter: 0
            )
        ) { error in
            XCTAssertEqual(error as? WebRTCAppSecureEnvelopeError, .invalidCounter(0))
        }
    }

    private func makePairedSessionKeys() -> (sender: SessionKeys, receiver: SessionKeys) {
        let senderToReceiver = Data(repeating: 0xA1, count: 32)
        let receiverToSender = Data(repeating: 0xB2, count: 32)
        let transcript = Data(repeating: 0xC3, count: 32)
        let sessionId = SessionKeys.deterministicSessionId(transcriptHash: transcript)
        let sender = SessionKeys(
            sendKey: senderToReceiver,
            receiveKey: receiverToSender,
            negotiatedSuite: .mlkem768MLDSA65,
            role: .initiator,
            transcriptHash: transcript,
            sessionId: sessionId
        )
        let receiver = SessionKeys(
            sendKey: receiverToSender,
            receiveKey: senderToReceiver,
            negotiatedSuite: .mlkem768MLDSA65,
            role: .responder,
            transcriptHash: transcript,
            sessionId: sessionId
        )
        return (sender, receiver)
    }
}
