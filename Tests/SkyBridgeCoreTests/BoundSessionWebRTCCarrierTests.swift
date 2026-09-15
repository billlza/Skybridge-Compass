import Foundation
import SkyBridgeProtocolCore
import XCTest

@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class BoundSessionWebRTCCarrierTests: XCTestCase {
    func testAllFiveExactMaximaRoundTripAndOneOverRejectsBeforePayloadRead() throws {
        let (sender, receiver) = makePairedSessionKeys()

        for (index, kind) in BoundSessionWebRTCRecordKindV1.allCases.enumerated() {
            let record = makeRecordEnvelope(
                kind: kind,
                byteCount: kind.maximumRecordByteCount
            )
            let carrier = try WebRTCControlChannelCodec.encryptBoundSessionRecord(
                record,
                recordKind: kind,
                with: sender,
                counter: UInt64(index + 1)
            )
            XCTAssertEqual(carrier.count, kind.maximumCarrierPayloadByteCount)

            let route = try classify(carrier)
            guard case .boundSession(let header) = route else {
                return XCTFail("expected BSC1 route for kind \(kind)")
            }
            let opened = try WebRTCControlChannelCodec.decryptBoundSessionCarrier(
                carrier,
                admittedHeader: header,
                with: receiver
            )
            XCTAssertEqual(opened.packetType, .boundSession)
            XCTAssertEqual(opened.payload, record)

            let oneOver = kind.maximumRecordByteCount + 1
            let prefix = makeCarrierPrefix(kindRaw: kind.rawValue, recordByteCount: oneOver)
            XCTAssertThrowsError(
                try BoundSessionWebRTCCarrierPolicyV1.classifyStagedPrefix(
                    declaredPayloadByteCount:
                        BoundSessionWebRTCCarrierPolicyV1
                        .carrierAndSecureEnvelopeOverheadByteCount + oneOver,
                    stagedPrefix: prefix
                )
            ) { error in
                XCTAssertEqual(
                    error as? BoundSessionWebRTCCarrierErrorV1,
                    .recordTooLarge(
                        kind: kind,
                        maximum: kind.maximumRecordByteCount,
                        actual: oneOver
                    )
                )
            }
        }
    }

    func testReaderAcceptsEveryPrefixFragmentBoundaryAndSingleByteFragmentation() async throws {
        let (sender, _) = makePairedSessionKeys()
        let record = makeRecordEnvelope(kind: .finished)
        let carrier = try WebRTCControlChannelCodec.encryptBoundSessionRecord(
            record,
            recordKind: .finished,
            with: sender,
            counter: 1
        )
        let framed = frame(carrier)
        let completeAdmissionPrefixByteCount =
            4
            + BoundSessionWebRTCCarrierPolicyV1.stagedPrefixByteCount

        for boundary in 1...completeAdmissionPrefixByteCount {
            let chunks = [
                Data(framed.prefix(boundary)),
                Data(framed.dropFirst(boundary)),
            ].filter { !$0.isEmpty }
            let source = TestChunkSource(chunks: chunks)
            let reader = WebRTCStagedFramedPayloadReader { maximumByteCount in
                try await source.next(maximumByteCount: maximumByteCount)
            }
            let admitted = try await reader.next()
            XCTAssertEqual(admitted.payload, carrier, "boundary=\(boundary)")
            XCTAssertEqual(
                admitted.route,
                .boundSession(.init(recordKind: .finished, recordByteCount: record.count)),
                "boundary=\(boundary)"
            )
        }

        let oneByteChunks = framed.map { Data([$0]) }
        let source = TestChunkSource(chunks: oneByteChunks)
        let reader = WebRTCStagedFramedPayloadReader { maximumByteCount in
            try await source.next(maximumByteCount: maximumByteCount)
        }
        let admitted = try await reader.next()
        XCTAssertEqual(admitted.payload, carrier)
        XCTAssertEqual(
            admitted.route,
            .boundSession(.init(recordKind: .finished, recordByteCount: record.count))
        )
    }

    func testReaderPreservesMultipleFramesFromOneTransportChunk() async throws {
        let (sender, _) = makePairedSessionKeys()
        let record = makeRecordEnvelope(kind: .grantReady)
        let carrier = try WebRTCControlChannelCodec.encryptBoundSessionRecord(
            record,
            recordKind: .grantReady,
            with: sender,
            counter: 1
        )
        let legacy = Data("legacy-control-frame".utf8)
        var combined = frame(carrier)
        combined.append(frame(legacy))

        let source = TestChunkSource(chunks: [combined])
        let reader = WebRTCStagedFramedPayloadReader { maximumByteCount in
            try await source.next(maximumByteCount: maximumByteCount)
        }
        let first = try await reader.next()
        let second = try await reader.next()

        XCTAssertEqual(first.payload, carrier)
        XCTAssertEqual(
            first.route,
            .boundSession(.init(recordKind: .grantReady, recordByteCount: record.count))
        )
        XCTAssertEqual(second, WebRTCStagedFramedPayload(payload: legacy, route: .legacy))
    }

    func testLegacyFramesShorterThanNineteenBytesRemainCompatible() async throws {
        for byteCount in 1..<BoundSessionWebRTCCarrierPolicyV1.stagedPrefixByteCount {
            let legacy = Data(repeating: UInt8(byteCount), count: byteCount)
            let source = TestChunkSource(chunks: [frame(legacy)])
            let reader = WebRTCStagedFramedPayloadReader { maximumByteCount in
                try await source.next(maximumByteCount: maximumByteCount)
            }
            let admitted = try await reader.next()
            XCTAssertEqual(
                admitted,
                WebRTCStagedFramedPayload(payload: legacy, route: .legacy),
                "legacy byteCount=\(byteCount)"
            )
        }
    }

    func testMalformedCarrierHeaderAndLengthFormsFailClosed() throws {
        let valid = makeCarrierPrefix(kindRaw: 0x0007, recordByteCount: 100)

        assertCarrierError(
            prefix: mutate(valid, offset: 4, value: 2),
            declaredPayloadByteCount: 180,
            expected: .unsupportedCarrierVersion(2)
        )
        assertCarrierError(
            prefix: mutate(valid, offset: 5, value: 1),
            declaredPayloadByteCount: 180,
            expected: .nonzeroCarrierReservedByte(1)
        )
        var unknownKind = valid
        writeUInt16(0x0006, to: &unknownKind, at: 6)
        assertCarrierError(
            prefix: unknownKind,
            declaredPayloadByteCount: 180,
            expected: .unknownRecordKind(0x0006)
        )
        let zeroLength = makeCarrierPrefix(kindRaw: 0x0007, recordByteCount: 0)
        assertCarrierError(
            prefix: zeroLength,
            declaredPayloadByteCount: 80,
            expected: .zeroRecordByteCount
        )
        assertCarrierError(
            prefix: valid,
            declaredPayloadByteCount: 181,
            expected: .outerPayloadLengthMismatch(expected: 180, actual: 181)
        )
        assertCarrierError(
            prefix: mutate(valid, offset: 12, value: 0),
            declaredPayloadByteCount: 180,
            expected: .invalidInnerSecureEnvelopeMagic
        )
        assertCarrierError(
            prefix: mutate(valid, offset: 16, value: 2),
            declaredPayloadByteCount: 180,
            expected: .unsupportedInnerSecureEnvelopeVersion(2)
        )
        assertCarrierError(
            prefix: mutate(valid, offset: 17, value: 51),
            declaredPayloadByteCount: 180,
            expected: .invalidInnerSecureEnvelopeHeaderByteCount(51)
        )
        assertCarrierError(
            prefix: mutate(valid, offset: 18, value: 1),
            declaredPayloadByteCount: 180,
            expected: .invalidInnerSecureEnvelopePacketType(1)
        )

        let truncatedCarrier = Data([0x42, 0x53, 0x43, 0x31, 1])
        assertCarrierError(
            prefix: truncatedCarrier,
            declaredPayloadByteCount: truncatedCarrier.count,
            expected: .truncatedCarrierPrefix
        )
    }

    func testZeroOverflowDirectAndSBP2Type6RejectDuringStagedAdmission() async throws {
        XCTAssertThrowsError(
            try BoundSessionWebRTCCarrierPolicyV1.classifyStagedPrefix(
                declaredPayloadByteCount: 0,
                stagedPrefix: Data()
            )
        ) { error in
            XCTAssertEqual(
                error as? BoundSessionWebRTCCarrierErrorV1,
                .invalidOuterPayloadByteCount(0)
            )
        }
        for invalidLength in [
            WebRTCFramedPayloadPolicy.maximumPayloadByteCount + 1,
            Int.max,
        ] {
            XCTAssertThrowsError(
                try BoundSessionWebRTCCarrierPolicyV1.classifyStagedPrefix(
                    declaredPayloadByteCount: invalidLength,
                    stagedPrefix: Data(repeating: 0, count: 19)
                )
            ) { error in
                XCTAssertEqual(
                    error as? BoundSessionWebRTCCarrierErrorV1,
                    .invalidOuterPayloadByteCount(invalidLength)
                )
            }
        }

        var direct = Data([0x53, 0x42, 0x57, 0x43, 1, 52, 6])
        direct.append(Data(repeating: 0, count: 12))
        assertCarrierError(
            prefix: direct,
            declaredPayloadByteCount: 100,
            expected: .directSecureEnvelopePacketType6
        )

        var padded = Data([0x53, 0x42, 0x50, 0x32])
        appendUInt32(7, to: &padded)
        padded.append(contentsOf: [0x53, 0x42, 0x57, 0x43, 1, 52, 6])
        padded.append(Data(repeating: 0, count: 4))
        assertCarrierError(
            prefix: padded,
            declaredPayloadByteCount: 19,
            expected: .paddedSecureEnvelopePacketType6
        )

        let overLimitRecordByteCount =
            BoundSessionWebRTCRecordKindV1.finished.maximumRecordByteCount + 1
        let rejectedPayloadByteCount =
            BoundSessionWebRTCCarrierPolicyV1.carrierAndSecureEnvelopeOverheadByteCount
            + overLimitRecordByteCount
        let rejectedPrefix = makeCarrierPrefix(
            kindRaw: BoundSessionWebRTCRecordKindV1.finished.rawValue,
            recordByteCount: overLimitRecordByteCount
        )
        var rejectedFraming = Data()
        appendUInt32(UInt32(rejectedPayloadByteCount), to: &rejectedFraming)
        rejectedFraming.append(rejectedPrefix)
        let source = TestChunkSource(chunks: [rejectedFraming])
        let reader = WebRTCStagedFramedPayloadReader { maximumByteCount in
            try await source.next(maximumByteCount: maximumByteCount)
        }
        do {
            _ = try await reader.next()
            XCTFail("one-over carrier must fail before requesting its remaining payload")
        } catch let error as BoundSessionWebRTCCarrierErrorV1 {
            XCTAssertEqual(
                error,
                .recordTooLarge(
                    kind: .finished,
                    maximum: BoundSessionWebRTCRecordKindV1.finished.maximumRecordByteCount,
                    actual: overLimitRecordByteCount
                )
            )
        }
        let requestedMaximumByteCounts = await source.requestedMaximumByteCounts()
        XCTAssertEqual(requestedMaximumByteCounts, [4, 19])
    }

    func testAuthenticationInnerLengthAndDecodedKindMismatchesReject() throws {
        let (sender, receiver) = makePairedSessionKeys()
        let record = makeRecordEnvelope(kind: .messageB)
        let carrier = try WebRTCControlChannelCodec.encryptBoundSessionRecord(
            record,
            recordKind: .messageB,
            with: sender,
            counter: 1
        )
        guard case .boundSession(let header) = try classify(carrier) else {
            return XCTFail("expected bound-session carrier")
        }

        XCTAssertThrowsError(
            try BoundSessionWebRTCCarrierPolicyV1.validateAuthenticatedRecord(
                record,
                header: .init(
                    recordKind: .messageB,
                    recordByteCount: record.count + 1
                ),
                expectedRecordKind: .messageB
            )
        ) { error in
            XCTAssertEqual(
                error as? BoundSessionWebRTCCarrierErrorV1,
                .authenticatedRecordLengthMismatch(
                    expected: record.count + 1,
                    actual: record.count
                )
            )
        }

        var authenticationFailure = carrier
        authenticationFailure[authenticationFailure.index(before: authenticationFailure.endIndex)] ^= 0x01
        XCTAssertThrowsError(
            try WebRTCControlChannelCodec.decryptBoundSessionCarrier(
                authenticationFailure,
                admittedHeader: header,
                with: receiver
            )
        ) { error in
            guard
                case .authenticationFailed(packetType: .boundSession, counter: 1) =
                    error as? WebRTCAppSecureEnvelopeError
            else {
                return XCTFail("unexpected auth error: \(error)")
            }
        }

        var innerLengthMismatch = carrier
        let innerPayloadLengthOffset =
            BoundSessionWebRTCCarrierPolicyV1.carrierHeaderByteCount + 36
        innerLengthMismatch[innerLengthMismatch.startIndex + innerPayloadLengthOffset + 3] ^= 0x01
        XCTAssertThrowsError(
            try WebRTCControlChannelCodec.decryptBoundSessionCarrier(
                innerLengthMismatch,
                admittedHeader: header,
                with: receiver
            )
        ) { error in
            XCTAssertEqual(error as? WebRTCAppSecureEnvelopeError, .malformed)
        }

        var decodedKindMismatch = carrier
        writeUInt16(
            BoundSessionWebRTCRecordKindV1.messageA.rawValue,
            to: &decodedKindMismatch,
            at: 6
        )
        guard case .boundSession(let mismatchedHeader) = try classify(decodedKindMismatch) else {
            return XCTFail("expected mutated BSC1 route")
        }
        XCTAssertThrowsError(
            try WebRTCControlChannelCodec.decryptBoundSessionCarrier(
                decodedKindMismatch,
                admittedHeader: mismatchedHeader,
                with: receiver
            )
        ) { error in
            XCTAssertEqual(
                error as? BoundSessionWebRTCCarrierErrorV1,
                .canonicalRecordKindMismatch(
                    expected: BoundSessionWebRTCRecordKindV1.messageA.rawValue,
                    actual: BoundSessionWebRTCRecordKindV1.messageB.rawValue
                )
            )
        }
    }

    func testGenericSecureAPIsCannotSendOrExplicitlyOpenPacketType6() throws {
        let (sender, receiver) = makePairedSessionKeys()
        let record = makeRecordEnvelope(kind: .finished)

        XCTAssertThrowsError(
            try WebRTCControlChannelCodec.encryptAppPayload(
                record,
                with: sender,
                packetType: .boundSession,
                counter: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? WebRTCAppSecureEnvelopeError,
                .boundSessionRequiresCarrier
            )
        }

        let directType6 = try WebRTCAppSecureEnvelope.seal(
            record,
            keys: sender,
            packetType: .boundSession,
            counter: 1
        )
        XCTAssertThrowsError(
            try WebRTCControlChannelCodec.decryptAppPayload(directType6, with: receiver)
        ) { error in
            XCTAssertEqual(
                error as? WebRTCAppSecureEnvelopeError,
                .packetTypeMismatch(
                    expected: Array(WebRTCAppSecurePacketType.genericApplicationTypes)
                        .sorted { $0.rawValue < $1.rawValue },
                    actual: .boundSession
                )
            )
        }
        XCTAssertThrowsError(
            try WebRTCControlChannelCodec.decryptAppPayload(
                directType6,
                with: receiver,
                allowedPacketTypes: [.boundSession]
            )
        ) { error in
            XCTAssertEqual(
                error as? WebRTCAppSecureEnvelopeError,
                .boundSessionRequiresCarrier
            )
        }
    }

    func testManagerCarrierBranchIsConsumeOnlyAndOutboundNeverUsesSBP2() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(
                    "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
                ),
            encoding: .utf8
        )
        guard
            let inboundStart = source.range(
                of: "if case .boundSession(let carrierHeader) = admittedFrame.route {"
            )?.lowerBound,
            let legacyStart = source.range(
                of: "let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: \"rx/webrtc\")",
                range: inboundStart..<source.endIndex
            )?.lowerBound
        else {
            return XCTFail("BoundSession consume-only branch markers are missing")
        }
        let carrierBranch = String(source[inboundStart..<legacyStart])
        XCTAssertTrue(carrierBranch.contains("consumeWebRTCBoundSessionRecord"))
        XCTAssertTrue(carrierBranch.contains("continue"))
        XCTAssertFalse(carrierBranch.contains("decodeCompatibilityAppMessage"))
        XCTAssertFalse(carrierBranch.contains("inboundFileTransferReceiver"))
        XCTAssertFalse(carrierBranch.contains("RemoteMessageWire"))

        guard
            let outboundStart = source.range(
                of: "func sendWebRTCBoundSessionRecord("
            )?.lowerBound,
            let outboundEnd = source.range(
                of: "private func requireCurrentWebRTCBoundSessionOperationOwner(",
                range: outboundStart..<source.endIndex
            )?.lowerBound
        else {
            return XCTFail("BoundSession outbound method markers are missing")
        }
        let outboundBody = String(source[outboundStart..<outboundEnd])
        XCTAssertTrue(outboundBody.contains("encryptBoundSessionRecord"))
        XCTAssertTrue(outboundBody.contains("sendFramedPayloadAsync"))
        XCTAssertFalse(outboundBody.contains("TrafficPadding"))
        XCTAssertFalse(outboundBody.contains("wrapIfEnabled"))
    }

    func testBoundSessionReplayUsesDedicatedPacketLane() throws {
        let (sender, receiver) = makePairedSessionKeys()
        let record = makeRecordEnvelope(kind: .effectReceipt)
        let carrier = try WebRTCControlChannelCodec.encryptBoundSessionRecord(
            record,
            recordKind: .effectReceipt,
            with: sender,
            counter: 9
        )
        guard case .boundSession(let header) = try classify(carrier) else {
            return XCTFail("expected bound-session carrier")
        }
        let first = try WebRTCControlChannelCodec.decryptBoundSessionCarrier(
            carrier,
            admittedHeader: header,
            with: receiver
        )
        let duplicate = try WebRTCControlChannelCodec.decryptBoundSessionCarrier(
            carrier,
            admittedHeader: header,
            with: receiver
        )
        var replayWindow = WebRTCAppSecureReplayWindow()
        try replayWindow.validateAndRecord(first)
        XCTAssertThrowsError(try replayWindow.validateAndRecord(duplicate)) { error in
            XCTAssertEqual(
                error as? WebRTCAppSecureEnvelopeError,
                .replayDetected(
                    packetType: .boundSession,
                    counter: 9,
                    highestCounter: 9,
                    reason: .duplicateCounter
                )
            )
        }
    }

    @MainActor
    func testSecureEnvelopeStateResetsForAChangedKeyIncarnation() throws {
        let senderManager = CrossNetworkConnectionManager()
        let receiverManager = CrossNetworkConnectionManager()
        let (firstSender, firstReceiver) = makePairedSessionKeys()
        let secondSender = SessionKeys(
            sendKey: Data(repeating: 0xD4, count: 32),
            receiveKey: Data(repeating: 0xE5, count: 32),
            negotiatedSuite: firstSender.negotiatedSuite,
            role: firstSender.role,
            transcriptHash: firstSender.transcriptHash,
            sessionId: firstSender.sessionId
        )
        let secondReceiver = SessionKeys(
            sendKey: secondSender.receiveKey,
            receiveKey: secondSender.sendKey,
            negotiatedSuite: firstReceiver.negotiatedSuite,
            role: firstReceiver.role,
            transcriptHash: firstReceiver.transcriptHash,
            sessionId: firstReceiver.sessionId
        )

        let firstPacket = try senderManager.sealWebRTCSecurePayload(
            Data("first-incarnation".utf8),
            with: firstSender,
            sessionID: firstSender.sessionId,
            packetType: .appControl
        )
        XCTAssertEqual(
            try receiverManager.openWebRTCSecurePayload(
                firstPacket,
                with: firstReceiver,
                sessionID: firstReceiver.sessionId
            ).counter,
            1
        )

        let secondPacket = try senderManager.sealWebRTCSecurePayload(
            Data("second-incarnation".utf8),
            with: secondSender,
            sessionID: secondSender.sessionId,
            packetType: .appControl
        )
        let secondOpened = try receiverManager.openWebRTCSecurePayload(
            secondPacket,
            with: secondReceiver,
            sessionID: secondReceiver.sessionId
        )
        XCTAssertEqual(secondOpened.counter, 1)
        XCTAssertEqual(secondOpened.payload, Data("second-incarnation".utf8))
    }

    @MainActor
    func testConsumeOnlyGateRejectsWrongTypestateCrossOwnerDoubleAndLateCallbacks() async throws {
        let objectA = NSObject()
        let objectB = NSObject()
        let ownerA = makeOwnerIdentity(object: objectA, marker: 0xA1)
        let ownerB = makeOwnerIdentity(object: objectB, marker: 0xB2)
        var dedicatedInvocationCount = 0
        var genericInvocationCount = 0
        var gate = WebRTCBoundSessionConsumerGate()

        try gate.arm(
            ownerIdentity: ownerA,
            expectedRecordKind: .messageA
        ) { kind, record in
            XCTAssertEqual(kind, .messageA)
            XCTAssertFalse(record.isEmpty)
            dedicatedInvocationCount += 1
        }
        XCTAssertThrowsError(
            try gate.arm(
                ownerIdentity: ownerA,
                expectedRecordKind: .messageA
            ) { _, _ in }
        ) { error in
            XCTAssertEqual(
                error as? WebRTCBoundSessionCarrierIntegrationError,
                .consumerAlreadyArmed
            )
        }
        XCTAssertThrowsError(
            try gate.takeConsumer(ownerIdentity: ownerB, recordKind: .messageA)
        ) { error in
            XCTAssertEqual(
                error as? WebRTCBoundSessionCarrierIntegrationError,
                .ownerMismatch
            )
        }
        XCTAssertThrowsError(
            try gate.takeConsumer(ownerIdentity: ownerA, recordKind: .messageB)
        ) { error in
            XCTAssertEqual(
                error as? WebRTCBoundSessionCarrierIntegrationError,
                .unexpectedRecordKind(expected: .messageA, actual: .messageB)
            )
        }

        let dedicatedConsumer = try gate.takeConsumer(
            ownerIdentity: ownerA,
            recordKind: .messageA
        )
        try await dedicatedConsumer(.messageA, makeRecordEnvelope(kind: .messageA))
        XCTAssertEqual(dedicatedInvocationCount, 1)
        XCTAssertEqual(genericInvocationCount, 0)
        XCTAssertThrowsError(
            try gate.takeConsumer(ownerIdentity: ownerA, recordKind: .messageA)
        ) { error in
            XCTAssertEqual(
                error as? WebRTCBoundSessionCarrierIntegrationError,
                .consumerNotArmed
            )
        }

        try gate.arm(
            ownerIdentity: ownerA,
            expectedRecordKind: .finished
        ) { _, _ in
            genericInvocationCount += 1
        }
        let rekeyedOwnerA = WebRTCBoundSessionSecureOwnerIdentity(
            sessionID: ownerA.sessionID,
            sessionObjectIdentifier: ownerA.sessionObjectIdentifier,
            controlTaskToken: ownerA.controlTaskToken,
            keyIncarnationDigest: Data(repeating: 0xC3, count: 32)
        )
        // A verified current key incarnation may displace a stale registration;
        // the pre-rekey owner's late callback still cannot take it.
        try gate.arm(
            ownerIdentity: rekeyedOwnerA,
            expectedRecordKind: .finished
        ) { _, _ in
            dedicatedInvocationCount += 1
        }
        XCTAssertThrowsError(
            try gate.takeConsumer(ownerIdentity: ownerA, recordKind: .finished)
        ) { error in
            XCTAssertEqual(
                error as? WebRTCBoundSessionCarrierIntegrationError,
                .ownerMismatch
            )
        }
        // A verified current replacement transport owner may likewise displace
        // the now-stale key-incarnation registration.
        try gate.arm(
            ownerIdentity: ownerB,
            expectedRecordKind: .finished
        ) { _, _ in
            dedicatedInvocationCount += 1
        }
        XCTAssertThrowsError(
            try gate.takeConsumer(ownerIdentity: ownerA, recordKind: .finished)
        ) { error in
            XCTAssertEqual(
                error as? WebRTCBoundSessionCarrierIntegrationError,
                .ownerMismatch
            )
        }
        gate.invalidate()
        XCTAssertThrowsError(
            try gate.takeConsumer(ownerIdentity: ownerB, recordKind: .finished)
        ) { error in
            XCTAssertEqual(
                error as? WebRTCBoundSessionCarrierIntegrationError,
                .consumerNotArmed
            )
        }
        XCTAssertEqual(dedicatedInvocationCount, 1)
        XCTAssertEqual(genericInvocationCount, 0)
    }

    private func classify(_ carrier: Data) throws -> BoundSessionWebRTCFrameRouteV1 {
        try BoundSessionWebRTCCarrierPolicyV1.classifyStagedPrefix(
            declaredPayloadByteCount: carrier.count,
            stagedPrefix: Data(
                carrier.prefix(BoundSessionWebRTCCarrierPolicyV1.stagedPrefixByteCount)
            )
        )
    }

    private func assertCarrierError(
        prefix: Data,
        declaredPayloadByteCount: Int,
        expected: BoundSessionWebRTCCarrierErrorV1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try BoundSessionWebRTCCarrierPolicyV1.classifyStagedPrefix(
                declaredPayloadByteCount: declaredPayloadByteCount,
                stagedPrefix: prefix
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? BoundSessionWebRTCCarrierErrorV1,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func makeRecordEnvelope(
        kind: BoundSessionWebRTCRecordKindV1,
        byteCount: Int? = nil
    ) -> Data {
        let authenticatorByteCount: Int =
            switch kind {
            case .messageA, .messageB:
                3_309
            case .finished, .grantReady, .effectReceipt:
                32
            }
        let completeByteCount = byteCount ?? (12 + authenticatorByteCount)
        let bodyByteCount = completeByteCount - 12 - authenticatorByteCount
        precondition(bodyByteCount >= 0)

        var record = Data([0x42, 0x53, 0x56, 0x31, 0, 1])
        appendUInt16(kind.rawValue, to: &record)
        appendUInt32(UInt32(bodyByteCount), to: &record)
        record.append(Data(repeating: 0xA5, count: bodyByteCount))
        record.append(Data(repeating: 0x5A, count: authenticatorByteCount))
        return record
    }

    private func makeCarrierPrefix(kindRaw: UInt16, recordByteCount: Int) -> Data {
        var prefix = Data([0x42, 0x53, 0x43, 0x31, 1, 0])
        appendUInt16(kindRaw, to: &prefix)
        appendUInt32(UInt32(recordByteCount), to: &prefix)
        prefix.append(contentsOf: [0x53, 0x42, 0x57, 0x43, 1, 52, 6])
        return prefix
    }

    private func frame(_ payload: Data) -> Data {
        var framed = Data()
        appendUInt32(UInt32(payload.count), to: &framed)
        framed.append(payload)
        return framed
    }

    private func mutate(_ data: Data, offset: Int, value: UInt8) -> Data {
        var mutated = data
        mutated[mutated.startIndex + offset] = value
        return mutated
    }

    private func makeOwnerIdentity(
        object: NSObject,
        marker: UInt8
    ) -> WebRTCBoundSessionSecureOwnerIdentity {
        WebRTCBoundSessionSecureOwnerIdentity(
            sessionID: "bound-session-owner",
            sessionObjectIdentifier: ObjectIdentifier(object),
            controlTaskToken: UUID(),
            keyIncarnationDigest: Data(repeating: marker, count: 32)
        )
    }

    private func makePairedSessionKeys() -> (sender: SessionKeys, receiver: SessionKeys) {
        let senderToReceiver = Data(repeating: 0xA1, count: 32)
        let receiverToSender = Data(repeating: 0xB2, count: 32)
        let transcript = Data(repeating: 0xC3, count: 32)
        let sessionID = SessionKeys.deterministicSessionId(transcriptHash: transcript)
        return (
            SessionKeys(
                sendKey: senderToReceiver,
                receiveKey: receiverToSender,
                negotiatedSuite: .mlkem768MLDSA65,
                role: .initiator,
                transcriptHash: transcript,
                sessionId: sessionID
            ),
            SessionKeys(
                sendKey: receiverToSender,
                receiveKey: senderToReceiver,
                negotiatedSuite: .mlkem768MLDSA65,
                role: .responder,
                transcriptHash: transcript,
                sessionId: sessionID
            )
        )
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private func writeUInt16(_ value: UInt16, to data: inout Data, at offset: Int) {
        data[data.startIndex + offset] = UInt8((value >> 8) & 0xff)
        data[data.startIndex + offset + 1] = UInt8(value & 0xff)
    }
}

private actor TestChunkSource {
    enum SourceError: Error {
        case exhausted
        case invalidMaximumByteCount
    }

    private var chunks: [Data]
    private var requestedMaximums: [Int] = []

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func next(maximumByteCount: Int) throws -> Data {
        guard maximumByteCount > 0 else {
            throw SourceError.invalidMaximumByteCount
        }
        requestedMaximums.append(maximumByteCount)
        guard !chunks.isEmpty else {
            throw SourceError.exhausted
        }
        let first = chunks.removeFirst()
        guard first.count > maximumByteCount else {
            return first
        }
        let head = Data(first.prefix(maximumByteCount))
        let tail = Data(first.dropFirst(maximumByteCount))
        chunks.insert(tail, at: 0)
        return head
    }

    func requestedMaximumByteCounts() -> [Int] {
        requestedMaximums
    }
}
