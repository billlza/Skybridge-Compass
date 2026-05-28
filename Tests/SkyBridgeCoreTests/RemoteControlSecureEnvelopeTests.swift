import XCTest
@testable import SkyBridgeCore

final class RemoteControlSecureEnvelopeTests: XCTestCase {
    private func makeKeys(
        transcript: Data = Data(repeating: 0x31, count: 32),
        sessionId: String? = nil
    ) -> (initiator: SessionKeys, responder: SessionKeys) {
        let resolvedSessionId = sessionId ?? SessionKeys.deterministicSessionId(transcriptHash: transcript)
        let initiatorKeys = SessionKeys(
            sendKey: Data(repeating: 0x11, count: 32),
            receiveKey: Data(repeating: 0x22, count: 32),
            negotiatedSuite: .xwingMLDSA,
            role: .initiator,
            transcriptHash: transcript,
            sessionId: resolvedSessionId
        )
        let responderKeys = SessionKeys(
            sendKey: Data(repeating: 0x22, count: 32),
            receiveKey: Data(repeating: 0x11, count: 32),
            negotiatedSuite: .xwingMLDSA,
            role: .responder,
            transcriptHash: transcript,
            sessionId: resolvedSessionId
        )
        return (initiatorKeys, responderKeys)
    }

    func testEnvelopeBindsDirectionSessionTranscriptAndPacketType() throws {
        let transcript = Data(repeating: 0x31, count: 32)
        let (initiatorKeys, responderKeys) = makeKeys(transcript: transcript)
        let packet = try RemoteControlSecureEnvelope.seal(
            Data("control".utf8),
            keys: initiatorKeys,
            packetType: .control,
            counter: 1
        )

        let opened = try RemoteControlSecureEnvelope.open(
            packet,
            keys: responderKeys,
            allowedPacketTypes: [.control]
        )
        XCTAssertEqual(opened.packetType, RemoteControlSecurePacketType.control)
        XCTAssertEqual(opened.counter, 1)
        XCTAssertEqual(opened.payload, Data("control".utf8))

        XCTAssertThrowsError(
            try RemoteControlSecureEnvelope.open(packet, keys: responderKeys, allowedPacketTypes: [.screen])
        ) { error in
            guard case RemoteControlSecureEnvelopeError.packetTypeMismatch = error else {
                return XCTFail("expected packetTypeMismatch, got \(error)")
            }
        }

        let wrongSessionKeys = SessionKeys(
            sendKey: responderKeys.sendKey,
            receiveKey: responderKeys.receiveKey,
            negotiatedSuite: responderKeys.negotiatedSuite,
            role: responderKeys.role,
            transcriptHash: responderKeys.transcriptHash,
            sessionId: "hs-other-session"
        )
        XCTAssertThrowsError(
            try RemoteControlSecureEnvelope.open(packet, keys: wrongSessionKeys, allowedPacketTypes: [.control])
        ) { error in
            guard case RemoteControlSecureEnvelopeError.sessionMismatch = error else {
                return XCTFail("expected sessionMismatch, got \(error)")
            }
        }

        XCTAssertThrowsError(
            try RemoteControlSecureEnvelope.open(packet, keys: initiatorKeys, allowedPacketTypes: [.control])
        ) { error in
            guard case RemoteControlSecureEnvelopeError.directionMismatch = error else {
                return XCTFail("expected directionMismatch, got \(error)")
            }
        }

        let wrongTranscriptKeys = SessionKeys(
            sendKey: responderKeys.sendKey,
            receiveKey: responderKeys.receiveKey,
            negotiatedSuite: responderKeys.negotiatedSuite,
            role: responderKeys.role,
            transcriptHash: Data(repeating: 0x42, count: 32),
            sessionId: responderKeys.sessionId
        )
        XCTAssertThrowsError(
            try RemoteControlSecureEnvelope.open(packet, keys: wrongTranscriptKeys, allowedPacketTypes: [.control])
        ) { error in
            guard case RemoteControlSecureEnvelopeError.transcriptMismatch = error else {
                return XCTFail("expected transcriptMismatch, got \(error)")
            }
        }
    }

    func testEnvelopeRejectsEpochAndAuthTamperingBeforeBusinessDecode() throws {
        let (initiatorKeys, responderKeys) = makeKeys()
        let packet = try RemoteControlSecureEnvelope.seal(
            Data("screen".utf8),
            keys: initiatorKeys,
            packetType: .screen,
            counter: 7
        )

        var epochTampered = packet
        epochTampered[epochTampered.startIndex + 27] = 1
        XCTAssertThrowsError(
            try RemoteControlSecureEnvelope.open(epochTampered, keys: responderKeys, allowedPacketTypes: [.screen])
        ) { error in
            guard case RemoteControlSecureEnvelopeError.epochMismatch = error else {
                return XCTFail("expected epochMismatch, got \(error)")
            }
        }

        var authTampered = packet
        authTampered[authTampered.startIndex + 52] ^= 0x01
        XCTAssertThrowsError(
            try RemoteControlSecureEnvelope.open(authTampered, keys: responderKeys, allowedPacketTypes: [.screen])
        ) { error in
            guard case RemoteControlSecureEnvelopeError.authenticationFailed = error else {
                return XCTFail("expected authenticationFailed, got \(error)")
            }
        }
    }

    func testEnvelopeOpenRejectsZeroCounterBeforeReplayWindow() throws {
        let (initiatorKeys, responderKeys) = makeKeys()
        let packet = try RemoteControlSecureEnvelope.seal(
            Data("control".utf8),
            keys: initiatorKeys,
            packetType: .control,
            counter: 1
        )
        let zeroCounterPacket = packet.replacingSecureEnvelopeCounter(with: 0)

        XCTAssertThrowsError(
            try RemoteControlSecureEnvelope.open(
                zeroCounterPacket,
                keys: responderKeys,
                allowedPacketTypes: [.control]
            )
        ) { error in
            XCTAssertEqual(error as? RemoteControlSecureEnvelopeError, .invalidCounter(0))
        }
    }

    func testReplayWindowRejectsRepeatedCountersPerPacketType() throws {
        let (initiatorKeys, responderKeys) = makeKeys()
        let screenPacket = try RemoteControlSecureEnvelope.seal(
            Data("screen".utf8),
            keys: initiatorKeys,
            packetType: .screen,
            counter: 1
        )
        let controlPacket = try RemoteControlSecureEnvelope.seal(
            Data("control".utf8),
            keys: initiatorKeys,
            packetType: .control,
            counter: 1
        )
        let audioPacket = try RemoteControlSecureEnvelope.seal(
            Data("audio".utf8),
            keys: initiatorKeys,
            packetType: .audio,
            counter: 1
        )
        var replayWindow = RemoteControlSecureReplayWindow()

        let openedScreen = try RemoteControlSecureEnvelope.open(
            screenPacket,
            keys: responderKeys,
            allowedPacketTypes: [.screen]
        )
        try replayWindow.validateAndRecord(openedScreen)

        let openedControl = try RemoteControlSecureEnvelope.open(
            controlPacket,
            keys: responderKeys,
            allowedPacketTypes: [.control]
        )
        try replayWindow.validateAndRecord(openedControl)

        let openedAudio = try RemoteControlSecureEnvelope.open(
            audioPacket,
            keys: responderKeys,
            allowedPacketTypes: [.audio]
        )
        try replayWindow.validateAndRecord(openedAudio)

        XCTAssertThrowsError(
            try replayWindow.validateAndRecord(openedScreen)
        ) { error in
            guard case RemoteControlSecureEnvelopeError.replayDetected = error else {
                return XCTFail("expected replayDetected, got \(error)")
            }
        }
    }

    func testReplayWindowAcceptsOutOfOrderCounterInsideWindowThenRejectsDuplicate() throws {
        let (initiatorKeys, responderKeys) = makeKeys()
        let highPacket = try RemoteControlSecureEnvelope.seal(
            Data("control-193".utf8),
            keys: initiatorKeys,
            packetType: .control,
            counter: 193
        )
        let latePacket = try RemoteControlSecureEnvelope.seal(
            Data("control-191".utf8),
            keys: initiatorKeys,
            packetType: .control,
            counter: 191
        )
        let openedHigh = try RemoteControlSecureEnvelope.open(
            highPacket,
            keys: responderKeys,
            allowedPacketTypes: [.control]
        )
        let openedLate = try RemoteControlSecureEnvelope.open(
            latePacket,
            keys: responderKeys,
            allowedPacketTypes: [.control]
        )
        var replayWindow = RemoteControlSecureReplayWindow()

        try replayWindow.validateAndRecord(openedHigh)
        XCTAssertNoThrow(try replayWindow.validateAndRecord(openedLate))
        XCTAssertThrowsError(try replayWindow.validateAndRecord(openedLate)) { error in
            XCTAssertEqual(
                error as? RemoteControlSecureEnvelopeError,
                .replayDetected(
                    packetType: .control,
                    counter: 191,
                    highestCounter: 193,
                    reason: .duplicateCounter
                )
            )
        }
    }

    func testReplayWindowRejectsCounterOutsideSlidingWindow() throws {
        let (initiatorKeys, responderKeys) = makeKeys()
        let highPacket = try RemoteControlSecureEnvelope.seal(
            Data("control-2000".utf8),
            keys: initiatorKeys,
            packetType: .control,
            counter: 2_000
        )
        let oldestInWindowPacket = try RemoteControlSecureEnvelope.seal(
            Data("control-977".utf8),
            keys: initiatorKeys,
            packetType: .control,
            counter: 977
        )
        let stalePacket = try RemoteControlSecureEnvelope.seal(
            Data("control-976".utf8),
            keys: initiatorKeys,
            packetType: .control,
            counter: 976
        )
        let openedHigh = try RemoteControlSecureEnvelope.open(
            highPacket,
            keys: responderKeys,
            allowedPacketTypes: [.control]
        )
        let openedOldestInWindow = try RemoteControlSecureEnvelope.open(
            oldestInWindowPacket,
            keys: responderKeys,
            allowedPacketTypes: [.control]
        )
        let openedStale = try RemoteControlSecureEnvelope.open(
            stalePacket,
            keys: responderKeys,
            allowedPacketTypes: [.control]
        )
        var replayWindow = RemoteControlSecureReplayWindow()

        try replayWindow.validateAndRecord(openedHigh)
        XCTAssertNoThrow(try replayWindow.validateAndRecord(openedOldestInWindow))
        XCTAssertThrowsError(try replayWindow.validateAndRecord(openedStale)) { error in
            XCTAssertEqual(
                error as? RemoteControlSecureEnvelopeError,
                .replayDetected(
                    packetType: .control,
                    counter: 976,
                    highestCounter: 2_000,
                    reason: .counterOutsideWindow
                )
            )
        }
    }

    func testReplayWindowScopesCountersBySessionAndTranscript() throws {
        let firstSession = makeKeys(
            transcript: Data(repeating: 0x41, count: 32),
            sessionId: "hs-first-session"
        )
        let secondSession = makeKeys(
            transcript: Data(repeating: 0x42, count: 32),
            sessionId: "hs-second-session"
        )
        let firstPacket = try RemoteControlSecureEnvelope.seal(
            Data("first".utf8),
            keys: firstSession.initiator,
            packetType: .control,
            counter: 1
        )
        let secondPacket = try RemoteControlSecureEnvelope.seal(
            Data("second".utf8),
            keys: secondSession.initiator,
            packetType: .control,
            counter: 1
        )
        var replayWindow = RemoteControlSecureReplayWindow()

        try replayWindow.validateAndRecord(
            RemoteControlSecureEnvelope.open(
                firstPacket,
                keys: firstSession.responder,
                allowedPacketTypes: [.control]
            )
        )
        XCTAssertNoThrow(
            try replayWindow.validateAndRecord(
                RemoteControlSecureEnvelope.open(
                    secondPacket,
                    keys: secondSession.responder,
                    allowedPacketTypes: [.control]
                )
            )
        )
    }

    func testSendSequencerSharesMonotonicCounterAcrossCallersForSession() throws {
        let (initiatorKeys, _) = makeKeys(sessionId: "hs-shared-counter")
        let sequencer = RemoteControlSecureEnvelopeSendSequencer()

        XCTAssertEqual(try sequencer.nextCounter(for: initiatorKeys), 1)
        XCTAssertEqual(try sequencer.nextCounter(for: initiatorKeys), 2)

        sequencer.resetIfSessionChanged(sessionId: initiatorKeys.sessionId)
        XCTAssertEqual(try sequencer.nextCounter(for: initiatorKeys), 3)

        let (newSessionKeys, _) = makeKeys(sessionId: "hs-new-counter-session")
        XCTAssertEqual(try sequencer.nextCounter(for: newSessionKeys), 1)
    }

    func testMacRemoteControlSecureEnvelopeHasSingleSendCounterOwner() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift"),
            encoding: .utf8
        )
        let pumpSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/RemoteControlOutboundFramePump.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(managerSource.contains("secureEnvelopeSendCounter"))
        XCTAssertFalse(pumpSource.contains("private var secureEnvelopeSendCounter"))
        XCTAssertTrue(managerSource.contains("let secureEnvelopeSendSequencer"))
        XCTAssertTrue(pumpSource.contains("secureEnvelopeSendSequencer.nextCounter(for: sessionKeys)"))
    }
}

private extension Data {
    func replacingSecureEnvelopeCounter(with counter: UInt64) -> Data {
        var packet = self
        let counterOffset = 28
        for byteOffset in 0..<8 {
            let shift = UInt64((7 - byteOffset) * 8)
            packet[packet.startIndex + counterOffset + byteOffset] = UInt8((counter >> shift) & 0xff)
        }
        return packet
    }
}
