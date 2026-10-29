import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@MainActor
final class RemoteControlManagerViewerIngressTests: XCTestCase {
    func testFinalReceiveDeliversAuthenticatedFrameThenStopsBeforeTheNextChunk() async throws {
        let manager = RemoteControlManager(controlledHostStreamTier: .background)
        manager.testingInstallViewerPeer(deviceId: "host", keys: keys(role: .initiator))
        defer { manager.stopControlling(deviceId: "host") }
        let transaction = RemoteDesktopStreamConfigurationTransaction()
        let access = try RemoteControlAccess(revision: 1, role: .controller, lease: UUID())
        manager.testingSetViewerStreamConfigurations(pending: configuration(transaction: transaction))
        let frame = try acknowledgementFrame(transaction: transaction, controlAccess: access)
        var length = UInt32(frame.count).bigEndian
        var wire = withUnsafeBytes(of: &length) { Data($0) }
        wire.append(frame)
        // The prefix is fragmented; the final receive includes body bytes and EOF.
        // A following chunk must never be processed after that EOF.
        do {
            try await manager.testingReceiveViewerChunks(
                [(Data(wire.prefix(2)), false), (Data(wire.dropFirst(2)), true), (Data([0xff]), false)],
                from: "host"
            )
            XCTFail("EOF must terminate the receive loop after processing its final bytes.")
        } catch let error as RemoteControlError {
            guard case .connectionClosed = error else { return XCTFail("Unexpected EOF error: \(error)") }
        }
        XCTAssertEqual(manager.testingAcknowledgedViewerStreamTransaction, transaction)
        XCTAssertEqual(manager.viewerInputAccess.access, access)
    }

    func testIncompleteFinalReceiveCannotCommitAnAuthenticatedFrame() async throws {
        let manager = RemoteControlManager(controlledHostStreamTier: .background)
        manager.testingInstallViewerPeer(deviceId: "host", keys: keys(role: .initiator))
        defer { manager.stopControlling(deviceId: "host") }
        let transaction = RemoteDesktopStreamConfigurationTransaction()
        manager.testingSetViewerStreamConfigurations(pending: configuration(transaction: transaction))
        let frame = try acknowledgementFrame(transaction: transaction)
        var length = UInt32(frame.count).bigEndian
        var wire = withUnsafeBytes(of: &length) { Data($0) }
        wire.append(frame.dropLast())
        do {
            try await manager.testingReceiveViewerChunks([(wire, true)], from: "host")
            XCTFail("Truncated EOF must terminate without accepting the incomplete frame.")
        } catch let error as RemoteControlError {
            guard case .connectionClosed = error else { return XCTFail("Unexpected EOF error: \(error)") }
        }
        XCTAssertNil(manager.testingAcknowledgedViewerStreamTransaction)
        XCTAssertFalse(manager.viewerInputAccess.hasAcknowledgement)
    }

    func testAuthenticatedInputAccessPushCannotBeOverwrittenByAnOlderRefreshReceipt() async throws {
        let manager = RemoteControlManager(controlledHostStreamTier: .background)
        manager.testingInstallViewerPeer(deviceId: "host", keys: keys(role: .initiator))
        defer { manager.stopControlling(deviceId: "host") }
        let original = RemoteDesktopStreamConfigurationTransaction()
        let initialAccess = try RemoteControlAccess(revision: 1, role: .controller, lease: UUID())
        manager.testingSetViewerStreamConfigurations(pending: configuration(transaction: original))
        try await manager.testingReceiveViewerFrame(
            acknowledgementFrame(transaction: original, controlAccess: initialAccess), from: "host"
        )
        XCTAssertTrue(manager.viewerInputAccess.canSendInput)
        let refresh = RemoteDesktopStreamConfigurationTransaction()
        manager.testingSetViewerStreamConfigurations(
            pending: configuration(transaction: refresh), committed: configuration(transaction: original)
        )
        let observer = try RemoteControlAccess(revision: 2, role: .observer, lease: nil)
        try await manager.testingReceiveViewerFrame(accessFrame(observer, counter: 2), from: "host")
        XCTAssertFalse(manager.viewerInputAccess.canSendInput)
        try await manager.testingReceiveViewerFrame(
            acknowledgementFrame(transaction: refresh, counter: 3, controlAccess: initialAccess), from: "host"
        )
        XCTAssertEqual(manager.testingAcknowledgedViewerStreamTransaction, refresh)
        XCTAssertEqual(manager.viewerInputAccess.access, observer)
        let next = try RemoteControlAccess(revision: 3, role: .controller, lease: UUID())
        try await manager.testingReceiveViewerFrame(accessFrame(next, counter: 4), from: "host")
        XCTAssertEqual(manager.viewerInputAccess.access, next)
        XCTAssertTrue(manager.viewerInputAccess.canSendInput)
    }

    func testInputAccessPushRequiresManagedNegotiationAndAuthenticEnvelope() async throws {
        let manager = RemoteControlManager(controlledHostStreamTier: .background)
        manager.testingInstallViewerPeer(deviceId: "host", keys: keys(role: .initiator))
        defer { manager.stopControlling(deviceId: "host") }
        let observer = try RemoteControlAccess(revision: 1, role: .observer, lease: nil)
        do {
            try await manager.testingReceiveViewerFrame(accessFrame(observer, counter: 1), from: "host")
            XCTFail("Unsolicited input grants must not select the session contract")
        } catch let error as RemoteControlAccess.ValidationError {
            XCTAssertEqual(error, .negotiationChanged)
        }
        XCTAssertFalse(manager.viewerInputAccess.hasAcknowledgement)
        let transaction = RemoteDesktopStreamConfigurationTransaction()
        manager.testingSetViewerStreamConfigurations(pending: configuration(transaction: transaction))
        try await manager.testingReceiveViewerFrame(
            acknowledgementFrame(transaction: transaction, counter: 2, controlAccess: observer), from: "host"
        )
        var tampered = try accessFrame(.init(revision: 2, role: .controller, lease: UUID()), counter: 3)
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        do {
            try await manager.testingReceiveViewerFrame(tampered, from: "host")
            XCTFail("Tampered grants must fail authentication")
        } catch let error as RemoteControlSecureEnvelopeError {
            guard case .authenticationFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(manager.viewerInputAccess.access, observer)
    }

    private func accessFrame(_ access: RemoteControlAccess, counter: UInt64) throws -> Data {
        let message = RemoteMessage(type: .controlAccess, payload: try JSONEncoder().encode(access))
        return try RemoteControlSecureEnvelope.seal(
            JSONEncoder().encode(message), keys: keys(role: .responder), packetType: .control, counter: counter
        )
    }
    func testAuthenticatedRejectionSurvivesSocketTeardownAndFailsExactWaiter() async throws {
        let manager = RemoteControlManager(controlledHostStreamTier: .background)
        manager.testingInstallViewerPeer(deviceId: "host", keys: keys(role: .initiator))
        let transaction = RemoteDesktopStreamConfigurationTransaction()
        manager.testingSetViewerStreamConfigurations(pending: configuration(transaction: transaction))
        let waiter = try manager.testingBeginWaitingForViewerStreamConfiguration(deviceId: "host")
        defer { waiter.cancel(); manager.stopControlling(deviceId: "host") }
        let expected = ControlledHostSessionError.streamConfigurationRejected(
            code: "audio-device-unavailable", message: "No playback device is available. Disable audio and reconnect.")
        do {
            try await manager.testingReceiveViewerFrame(rejectionFrame(transaction: transaction), from: "host")
            XCTFail("Authenticated rejection must fail the session without committing an ACK.")
        } catch let error as ControlledHostSessionError { XCTAssertEqual(error, expected) }
        manager.stopControlling(deviceId: "host")
        do { try await waiter.value; XCTFail("A following EOF must not replace the authenticated rejection.") }
        catch let error as ControlledHostSessionError { XCTAssertEqual(error, expected) }
        XCTAssertNil(manager.testingAcknowledgedViewerStreamTransaction)
    }

    func testRejectionForDifferentTransactionCannotFailCurrentOperation() async throws {
        let manager = RemoteControlManager(controlledHostStreamTier: .background)
        manager.testingInstallViewerPeer(deviceId: "host", keys: keys(role: .initiator))
        defer { manager.stopControlling(deviceId: "host") }
        let transaction = RemoteDesktopStreamConfigurationTransaction()
        manager.testingSetViewerStreamConfigurations(pending: configuration(transaction: transaction))
        do {
            try await manager.testingReceiveViewerFrame(rejectionFrame(transaction: .init()), from: "host")
            XCTFail("A stale rejection must not be accepted as the current transaction's failure.")
        } catch let error as ControlledHostSessionError { XCTAssertEqual(error, .invalidStreamConfigurationRejection) }
        XCTAssertNil(manager.testingAcknowledgedViewerStreamTransaction)
        try await manager.testingReceiveViewerFrame(acknowledgementFrame(transaction: transaction, counter: 2), from: "host")
        XCTAssertEqual(manager.testingAcknowledgedViewerStreamTransaction, transaction)
    }

    func testRejectionWireRejectsOversizedOrInvalidUserFacingFields() throws {
        let transaction = RemoteDesktopStreamConfigurationTransaction()
        XCTAssertThrowsError(try RemoteDesktopStreamConfigurationRejection(transaction: transaction, code: "BAD-CODE", message: "Error"))
        XCTAssertThrowsError(try RemoteDesktopStreamConfigurationRejection(transaction: transaction, code: "audio-device-unavailable", message: String(repeating: "a", count: 513)))
        XCTAssertThrowsError(try RemoteDesktopStreamConfigurationRejection(transaction: transaction, code: "audio-device-unavailable", message: "Error\nstack trace"))
        let raw = "{\"transaction\":{\"id\":\"\(transaction.id.uuidString)\"},\"code\":\"bad code\",\"message\":\"Error\"}"
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteDesktopStreamConfigurationRejection.self, from: Data(raw.utf8)))
    }

    private func rejectionFrame(transaction: RemoteDesktopStreamConfigurationTransaction) throws -> Data {
        let rejection = try RemoteDesktopStreamConfigurationRejection(transaction: transaction,
            code: "audio-device-unavailable", message: "No playback device is available. Disable audio and reconnect.")
        let message = RemoteMessage(type: .streamConfigurationRejected, payload: try JSONEncoder().encode(rejection))
        return try RemoteControlSecureEnvelope.seal(JSONEncoder().encode(message), keys: keys(role: .responder), packetType: .control, counter: 1)
    }

    func testEncryptedControlAcknowledgementCommitsOnlyThePendingViewerTransaction() async throws {
        let manager = RemoteControlManager(controlledHostStreamTier: .background)
        manager.testingInstallViewerPeer(deviceId: "host", keys: keys(role: .initiator))
        defer { manager.stopControlling(deviceId: "host") }
        let transaction = RemoteDesktopStreamConfigurationTransaction()
        manager.testingSetViewerStreamConfigurations(pending: configuration(transaction: transaction))

        let frame = try acknowledgementFrame(transaction: transaction)
        try await manager.testingReceiveViewerFrame(frame, from: "host")
        XCTAssertEqual(manager.testingAcknowledgedViewerStreamTransaction, transaction)

        try await manager.testingReceiveViewerFrame(frame, from: "host")
        XCTAssertEqual(manager.testingAcknowledgedViewerStreamTransaction, transaction)
    }

    func testTamperedAcknowledgementCannotCommitViewerConfiguration() async throws {
        let manager = RemoteControlManager(controlledHostStreamTier: .background)
        manager.testingInstallViewerPeer(deviceId: "host", keys: keys(role: .initiator))
        defer { manager.stopControlling(deviceId: "host") }
        let transaction = RemoteDesktopStreamConfigurationTransaction()
        manager.testingSetViewerStreamConfigurations(pending: configuration(transaction: transaction))
        var frame = try acknowledgementFrame(transaction: transaction)
        frame[frame.index(before: frame.endIndex)] ^= 1

        do {
            try await manager.testingReceiveViewerFrame(frame, from: "host")
            XCTFail("Tampered control envelopes must fail authentication.")
        } catch let error as RemoteControlSecureEnvelopeError {
            guard case .authenticationFailed = error else {
                return XCTFail("Unexpected envelope rejection: \(error)")
            }
        }
        XCTAssertNil(manager.testingAcknowledgedViewerStreamTransaction)
    }

    func testAuthenticatedHostCannotInjectInputOrClipboardThroughViewerControlLane() async throws {
        let manager = RemoteControlManager(controlledHostStreamTier: .background)
        manager.testingInstallViewerPeer(deviceId: "host", keys: keys(role: .initiator))
        defer { manager.stopControlling(deviceId: "host") }
        let types: [RemoteMessage.MessageType] = [.keyboardEvent, .mouseEvent, .clipboard, .streamConfiguration]
        for (index, type) in types.enumerated() {
            let message = RemoteMessage(type: type, payload: Data())
            let frame = try RemoteControlSecureEnvelope.seal(
                JSONEncoder().encode(message),
                keys: keys(role: .responder),
                packetType: .control,
                counter: UInt64(index + 1)
            )
            do {
                try await manager.testingReceiveViewerFrame(frame, from: "host")
                XCTFail("Viewer accepted a host-to-controller \(type) message.")
            } catch let error as RemoteControlError {
                guard case .handshakeInitializationFailed = error else {
                    return XCTFail("Unexpected viewer rejection: \(error)")
                }
            }
        }
    }

    func testOutboundCompletionReusesOnlyTheExactAlreadyInstalledHandshakeAuthority() async throws {
        let manager = RemoteControlManager(controlledHostStreamTier: .background)
        let installedKeys = keys(role: .initiator)
        let authority = AuthenticatedRemoteAuthority(
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: "test-peer-fingerprint"
        )
        manager.testingInstallViewerPeer(deviceId: "host", keys: installedKeys, authority: authority)
        defer { manager.stopControlling(deviceId: "host") }

        let completedAuthority = try await manager.testingCompletedOutboundHandshakeAuthority(
            deviceId: "host",
            keys: installedKeys
        )
        XCTAssertEqual(completedAuthority, authority)

        do {
            _ = try await manager.testingCompletedOutboundHandshakeAuthority(
                deviceId: "host",
                keys: keys(role: .initiator, transcriptByte: 0x44)
            )
            XCTFail("A different completed handshake must not reuse the installed authority.")
        } catch let error as RemoteControlError {
            guard case .handshakeInitializationFailed = error else {
                return XCTFail("Unexpected handshake rejection: \(error)")
            }
        }
    }

    func testInstalledKeysWithoutAuthenticatedAuthorityCannotCompleteStartup() async throws {
        let manager = RemoteControlManager(controlledHostStreamTier: .background)
        let installedKeys = keys(role: .initiator)
        manager.testingInstallViewerPeer(deviceId: "host", keys: installedKeys)
        defer { manager.stopControlling(deviceId: "host") }

        do {
            _ = try await manager.testingCompletedOutboundHandshakeAuthority(deviceId: "host", keys: installedKeys)
            XCTFail("Session keys alone cannot replace authenticated peer authority.")
        } catch let error as RemoteControlError {
            guard case .handshakeInitializationFailed = error else {
                return XCTFail("Unexpected handshake rejection: \(error)")
            }
        }
    }

    func testLateHandshakeDriverCannotInstallIntoAReplacementWithTheSameHostKey() async throws {
        let manager = RemoteControlManager(controlledHostStreamTier: .background)
        manager.testingInstallViewerPeer(deviceId: "host", keys: nil)
        let originalIdentity = try XCTUnwrap(manager.testingViewerPeerIdentity(deviceId: "host"))
        manager.stopControlling(deviceId: "host")
        manager.testingInstallViewerPeer(deviceId: "host", keys: nil)
        defer { manager.stopControlling(deviceId: "host") }
        let replacementIdentity = try XCTUnwrap(manager.testingViewerPeerIdentity(deviceId: "host"))
        let transport = MockDiscoveryTransport()
        let driver = try HandshakeDriver(
            transport: transport,
            cryptoProvider: ClassicCryptoProvider(),
            protocolSignatureProvider: ClassicSignatureProvider(),
            protocolSigningKeyHandle: .softwareKey(Data(repeating: 0x42, count: 32)),
            sigAAlgorithm: .ed25519,
            identityPublicKey: encodeIdentityPublicKey(Data(repeating: 0x01, count: 32)),
            offeredSuites: [.x25519Ed25519]
        )

        XCTAssertFalse(
            manager.testingInstallOutboundHandshakeDriver(
                driver,
                deviceId: "host",
                expectedPeerIdentity: originalIdentity
            )
        )
        XCTAssertTrue(
            manager.testingInstallOutboundHandshakeDriver(
                driver,
                deviceId: "host",
                expectedPeerIdentity: replacementIdentity
            )
        )
        let sentMessageCount = await transport.getSentMessageCount()
        XCTAssertEqual(sentMessageCount, 0)
    }

    private func keys(role: HandshakeRole, transcriptByte: UInt8 = 0x31) -> SessionKeys {
        SessionKeys(
            sendKey: Data(repeating: role == .initiator ? 0x11 : 0x22, count: 32),
            receiveKey: Data(repeating: role == .initiator ? 0x22 : 0x11, count: 32),
            negotiatedSuite: .xwingMLDSA,
            role: role,
            transcriptHash: Data(repeating: transcriptByte, count: 32)
        )
    }

    private func configuration(
        transaction: RemoteDesktopStreamConfigurationTransaction
    ) -> RemoteDesktopStreamConfiguration {
        RemoteDesktopStreamConfiguration(
            targetFrameRate: 2,
            keyFrameInterval: 10,
            lowLatencyMode: false,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: false,
            screenFrameTransport: "sbrf-v1",
            streamConfigurationTransaction: transaction
        )
    }

    private func acknowledgementFrame(
        transaction: RemoteDesktopStreamConfigurationTransaction,
        counter: UInt64 = 1,
        controlAccess: RemoteControlAccess? = nil
    ) throws -> Data {
        let acknowledgement = RemoteDesktopStreamConfigurationAcknowledgement(
            acceptedAt: 1,
            transaction: transaction,
            streamRefreshToken: nil,
            audioEndpointPresent: false,
            screenFrameTransport: "sbrf-v1",
            controlAccess: controlAccess
        )
        let message = RemoteMessage(
            type: .streamConfigurationAck,
            payload: try JSONEncoder().encode(acknowledgement)
        )
        return try RemoteControlSecureEnvelope.seal(
            JSONEncoder().encode(message),
            keys: keys(role: .responder),
            packetType: .control,
            counter: counter
        )
    }
}
