import Foundation
import XCTest
@testable import SkyBridgeCameraKit

final class ClientLifecycleTests: XCTestCase {
    func testFrameGateRejectsPFramesUntilIDR() async throws {
        let client = try makeClient(frameBufferCapacity: 1)
        let stream = await client.frames()

        let acceptedPredictiveFrame = await client.publish(
            accessUnit(sequence: 0, keyFrame: false)
        )
        let acceptedKeyFrame = await client.publish(accessUnit(sequence: 1, keyFrame: true))
        XCTAssertFalse(acceptedPredictiveFrame)
        XCTAssertTrue(acceptedKeyFrame)

        var iterator = stream.makeAsyncIterator()
        let delivered = try await iterator.next()
        XCTAssertEqual(delivered?.frameSequenceNumber, 1)
        try await client.stop()
    }

    func testOverflowClearsGOPAndRequiresANewIDR() async throws {
        let client = try makeClient(frameBufferCapacity: 1)
        let stream = await client.frames()
        let acceptedInitialKeyFrame = await client.publish(
            accessUnit(sequence: 0, keyFrame: true)
        )
        XCTAssertTrue(acceptedInitialKeyFrame)

        // The full queue is cleared. The overflowing predictive frame and all
        // subsequent predictive frames are rejected until a fresh IDR arrives.
        let acceptedOverflow = await client.publish(accessUnit(sequence: 1, keyFrame: false))
        let acceptedAfterOverflow = await client.publish(
            accessUnit(sequence: 2, keyFrame: false)
        )
        let acceptedRecovery = await client.publish(accessUnit(sequence: 3, keyFrame: true))
        XCTAssertFalse(acceptedOverflow)
        XCTAssertFalse(acceptedAfterOverflow)
        XCTAssertTrue(acceptedRecovery)

        var iterator = stream.makeAsyncIterator()
        let delivered = try await iterator.next()
        XCTAssertEqual(delivered?.frameSequenceNumber, 3)
        try await client.stop()
    }

    func testStopFinishesStreamExactlyOnceAndSecondConsumerFails() async throws {
        let client = try makeClient(frameBufferCapacity: 1)
        let first = await client.frames()
        let second = await client.frames()
        var secondIterator = second.makeAsyncIterator()
        do {
            _ = try await secondIterator.next()
            XCTFail("a second consumer must fail")
        } catch let error as SkyBridgeCameraError {
            guard case .invalidState = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        try await client.stop()
        var firstIterator = first.makeAsyncIterator()
        let completed = try await firstIterator.next()
        XCTAssertNil(completed)
        try await client.stop()
    }

    func testConcurrentOwnerStopsAndConsumerCancellationShareOneClose() async throws {
        let barrier = StopBarrier()
        let endpoint = try RTSPEndpoint("rtsp://192.168.1.20/live")
        let configuration = try RTSPClientConfiguration(
            endpoint: endpoint,
            frameBufferCapacity: 1
        )
        let client = RTSPInterleavedClient(
            configuration: configuration,
            stopBarrier: { await barrier.suspendStop() }
        )
        let stream = await client.frames()
        let consumer = Task { () -> (any Error)? in
            var iterator = stream.makeAsyncIterator()
            do {
                _ = try await iterator.next()
                return nil
            } catch {
                return error
            }
        }

        let firstOwnerStop = Task { try await client.stop() }
        await barrier.waitUntilStopStarted()

        consumer.cancel()
        let secondOwnerStop = Task { try await client.stop() }
        let consumerError = await consumer.value
        switch consumerError {
        case nil:
            // AsyncThrowingStream may observe task cancellation before its
            // unfolding closure installs the client's waiter and report clean
            // exhaustion. That is a valid linearization of the concurrent
            // cancellation; teardown ownership is asserted below.
            break
        case .some(let cameraError as SkyBridgeCameraError):
            XCTAssertEqual(cameraError, .cancelled)
        case .some(let unexpectedError):
            XCTFail("unexpected consumer termination: \(unexpectedError)")
        }

        await barrier.releaseStop()
        try await firstOwnerStop.value
        try await secondOwnerStop.value
        try await client.stop()

        let executionCount = await barrier.executionCount
        XCTAssertEqual(executionCount, 1)
    }

    func testSessionTimeoutProducesHalfTimeoutBoundedKeepalive() async throws {
        let client = try makeClient(frameBufferCapacity: 1)
        let response = RTSPResponse(
            version: "RTSP/1.0",
            statusCode: 200,
            reasonPhrase: "OK",
            headers: ["session": ["abc123;timeout=30"]],
            body: Data()
        )
        let parsed = try await client.parseSessionIdentifier(response)
        XCTAssertEqual(parsed.identifier, "abc123")
        XCTAssertEqual(parsed.keepaliveInterval, .seconds(15))

        let shortResponse = RTSPResponse(
            version: "RTSP/1.0",
            statusCode: 200,
            reasonPhrase: "OK",
            headers: ["session": ["abc123;timeout=1"]],
            body: Data()
        )
        let short = try await client.parseSessionIdentifier(shortResponse)
        XCTAssertEqual(short.keepaliveInterval, .milliseconds(500))
    }

    func testKeepaliveMediaProgressRefreshesOnlyTheMediaDeadline() throws {
        let clock = ContinuousClock()
        let origin = clock.now
        let policy = RTSPKeepaliveDeadlinePolicy(
            responseDeadline: origin.advanced(by: .seconds(20))
        )
        let originalMediaDeadline = origin.advanced(by: .seconds(10))

        let initialWait = try policy.nextWait(
            now: origin,
            mediaDeadline: originalMediaDeadline,
            hasReceivedAccessUnit: false
        )
        XCTAssertEqual(initialWait.deadline, originalMediaDeadline)
        XCTAssertEqual(initialWait.limitingTimeout, .firstAccessUnit)

        // A valid access unit arrives immediately before the old media deadline.
        // An OPTIONS response arriving after that old deadline must remain valid,
        // while the response deadline itself remains fixed at the request timeout.
        let refreshedMediaDeadline = origin.advanced(by: .seconds(19))
        let responseArrival = origin.advanced(by: .seconds(12))
        let refreshedWait = try policy.nextWait(
            now: responseArrival,
            mediaDeadline: refreshedMediaDeadline,
            hasReceivedAccessUnit: true
        )
        XCTAssertEqual(refreshedWait.deadline, refreshedMediaDeadline)
        XCTAssertEqual(refreshedWait.limitingTimeout, .subsequentAccessUnit)
        XCTAssertGreaterThan(refreshedWait.deadline, originalMediaDeadline)
        XCTAssertLessThan(refreshedWait.deadline, policy.responseDeadline)
    }

    func testKeepaliveDeadlinePolicyDistinguishesMediaAndResponseTimeouts() throws {
        let clock = ContinuousClock()
        let origin = clock.now
        let responseDeadline = origin.advanced(by: .seconds(20))
        let policy = RTSPKeepaliveDeadlinePolicy(responseDeadline: responseDeadline)

        XCTAssertThrowsError(
            try policy.nextWait(
                now: origin.advanced(by: .seconds(10)),
                mediaDeadline: origin.advanced(by: .seconds(10)),
                hasReceivedAccessUnit: false
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeCameraError,
                .timedOut("waiting for the first H.264 access unit")
            )
        }

        XCTAssertThrowsError(
            try policy.nextWait(
                now: origin.advanced(by: .seconds(15)),
                mediaDeadline: origin.advanced(by: .seconds(15)),
                hasReceivedAccessUnit: true
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeCameraError,
                .timedOut("waiting for a subsequent H.264 access unit")
            )
        }

        XCTAssertThrowsError(
            try policy.nextWait(
                now: responseDeadline,
                mediaDeadline: origin.advanced(by: .seconds(29)),
                hasReceivedAccessUnit: true
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeCameraError,
                .timedOut("completing the session keepalive request")
            )
        }
    }

    func testAuthenticationRetryStateEstablishesContextAndRejectsASecond401() throws {
        let credentials = try RTSPCredentials(username: "viewer", password: "secret")
        let initialChallenge = RTSPResponse(
            version: "RTSP/1.0",
            statusCode: 401,
            reasonPhrase: "Unauthorized",
            headers: [
                "cseq": ["1"],
                "www-authenticate": [
                    "Digest realm=\"camera\", nonce=\"initial\", algorithm=SHA-256, qop=\"auth\"",
                ],
            ],
            body: Data()
        )
        var context: RTSPAuthenticationContext?
        var retryState = RTSPAuthenticationRetryState()

        try retryState.prepareRetry(
            for: initialChallenge,
            credentials: credentials,
            secureTransport: false,
            authenticationContext: &context
        )
        XCTAssertTrue(retryState.hasRetried)
        var installedContext = try XCTUnwrap(context)
        let authorization = try installedContext.authorizationHeader(
            method: "SETUP",
            uri: "rtsp://192.168.1.20/live",
            cnonce: "abc123"
        )
        XCTAssertTrue(authorization.contains("nonce=\"initial\""))

        let secondChallenge = RTSPResponse(
            version: "RTSP/1.0",
            statusCode: 401,
            reasonPhrase: "Unauthorized",
            headers: [
                "cseq": ["2"],
                "www-authenticate": [
                    "Digest realm=\"camera\", nonce=\"second\", algorithm=SHA-256, "
                        + "qop=\"auth\", stale=true",
                ],
            ],
            body: Data()
        )
        XCTAssertThrowsError(try retryState.prepareRetry(
            for: secondChallenge,
            credentials: credentials,
            secureTransport: false,
            authenticationContext: &context
        )) { error in
            XCTAssertEqual(error as? SkyBridgeCameraError, .authenticationRejected)
        }
    }

    func testRequestBuilderAdvancesCSeqAcrossAuthenticationAttempts() async throws {
        let client = try makeClient(frameBufferCapacity: 1)
        let endpoint = try RTSPEndpoint("rtsp://192.168.1.20/live")

        let first = try await client.buildRequest(
            method: "SETUP",
            url: endpoint.url,
            headers: [],
            includeAuthentication: true
        )
        let second = try await client.buildRequest(
            method: "SETUP",
            url: endpoint.url,
            headers: [],
            includeAuthentication: true
        )
        let firstText = String(decoding: first, as: UTF8.self)
        let secondText = String(decoding: second, as: UTF8.self)
        XCTAssertTrue(firstText.contains("\r\nCSeq: 1\r\n"))
        XCTAssertTrue(secondText.contains("\r\nCSeq: 2\r\n"))
    }

    func testDroppedVCLAccessUnitsRefreshMediaActivityWithoutBreakingGOPQueue() async throws {
        let client = try makeClient(frameBufferCapacity: 1)
        let stream = await client.frames()
        let origin = ContinuousClock().now

        let acceptedInitialKeyFrame = await client.processDepacketizedAccessUnit(
            accessUnit(sequence: 0, keyFrame: true),
            receivedAt: origin
        )
        XCTAssertTrue(acceptedInitialKeyFrame)
        let droppedAt = origin.advanced(by: .seconds(1))
        let acceptedOverflow = await client.processDepacketizedAccessUnit(
            accessUnit(sequence: 1, keyFrame: false),
            receivedAt: droppedAt
        )
        XCTAssertFalse(acceptedOverflow)
        let lastActivityAfterDrop = await client.lastAccessUnitAt
        XCTAssertEqual(lastActivityAfterDrop, droppedAt)

        let parameterSetAt = origin.advanced(by: .seconds(2))
        let acceptedParameterSet = await client.processDepacketizedAccessUnit(
            accessUnit(
                sequence: 2,
                keyFrame: false,
                containsVideoCodingLayer: false
            ),
            receivedAt: parameterSetAt
        )
        XCTAssertFalse(acceptedParameterSet)
        let lastActivityAfterParameterSet = await client.lastAccessUnitAt
        XCTAssertEqual(lastActivityAfterParameterSet, droppedAt)

        let acceptedRecovery = await client.processDepacketizedAccessUnit(
            accessUnit(sequence: 3, keyFrame: true),
            receivedAt: origin.advanced(by: .seconds(3))
        )
        XCTAssertTrue(acceptedRecovery)
        var iterator = stream.makeAsyncIterator()
        let delivered = try await iterator.next()
        XCTAssertEqual(delivered?.frameSequenceNumber, 3)
        try await client.stop()
    }

    func testParameterSetOnlyAccessUnitsNeverEnterOrEvictTheFrameQueue() async throws {
        let client = try makeClient(frameBufferCapacity: 2)
        let stream = await client.frames()
        let origin = ContinuousClock().now

        let acceptedKeyFrame = await client.processDepacketizedAccessUnit(
            accessUnit(sequence: 0, keyFrame: true),
            receivedAt: origin
        )
        XCTAssertTrue(acceptedKeyFrame)
        let acceptedParameterSet = await client.processDepacketizedAccessUnit(
            accessUnit(
                sequence: 1,
                keyFrame: false,
                containsVideoCodingLayer: false
            ),
            receivedAt: origin.advanced(by: .seconds(1))
        )
        XCTAssertFalse(acceptedParameterSet)
        let activityAfterParameterSet = await client.lastAccessUnitAt
        XCTAssertEqual(activityAfterParameterSet, origin)

        let acceptedDirectParameterSet = await client.publish(
            accessUnit(
                sequence: 2,
                keyFrame: false,
                containsVideoCodingLayer: false
            )
        )
        XCTAssertFalse(acceptedDirectParameterSet)

        let acceptedPredictiveFrame = await client.processDepacketizedAccessUnit(
            accessUnit(sequence: 3, keyFrame: false),
            receivedAt: origin.advanced(by: .seconds(3))
        )
        guard acceptedPredictiveFrame else {
            try await client.stop()
            return XCTFail("a parameter-set-only AU must not consume queue capacity or reset the GOP")
        }

        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()
        XCTAssertEqual(first?.frameSequenceNumber, 0)
        XCTAssertEqual(second?.frameSequenceNumber, 3)
        try await client.stop()
    }

    func testDepacketizerMetadataDoesNotCreateAVisibleFrameSequenceGap() async throws {
        let activeSPS = Data([0x67, 0x42, 0x01])
        let activePPS = Data([0x68, 0xCE, 0x01])
        var depacketizer = H264RTPDepacketizer(
            payloadType: 96,
            packetizationMode: 1,
            sequenceParameterSets: [activeSPS],
            pictureParameterSets: [activePPS]
        )
        let client = try makeClient(frameBufferCapacity: 4)
        let stream = await client.frames()
        let origin = ContinuousClock().now

        let idr = try XCTUnwrap(depacketizer.consume(rtpPacket(
            payload: Data([0x65, 0xAA]),
            sequence: 10,
            timestamp: 10
        )))
        let repeatedSPS = try XCTUnwrap(depacketizer.consume(rtpPacket(
            payload: activeSPS,
            sequence: 11,
            timestamp: 11
        )))
        let repeatedPPS = try XCTUnwrap(depacketizer.consume(rtpPacket(
            payload: activePPS,
            sequence: 12,
            timestamp: 12
        )))
        let predictive = try XCTUnwrap(depacketizer.consume(rtpPacket(
            payload: Data([0x61, 0xBB]),
            sequence: 13,
            timestamp: 13
        )))

        let acceptedIDR = await client.processDepacketizedAccessUnit(
            idr,
            receivedAt: origin
        )
        let acceptedSPS = await client.processDepacketizedAccessUnit(
            repeatedSPS,
            receivedAt: origin.advanced(by: .seconds(1))
        )
        let acceptedPPS = await client.processDepacketizedAccessUnit(
            repeatedPPS,
            receivedAt: origin.advanced(by: .seconds(2))
        )
        let acceptedPredictive = await client.processDepacketizedAccessUnit(
            predictive,
            receivedAt: origin.advanced(by: .seconds(3))
        )
        XCTAssertTrue(acceptedIDR)
        XCTAssertFalse(acceptedSPS)
        XCTAssertFalse(acceptedPPS)
        XCTAssertTrue(acceptedPredictive)

        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()
        XCTAssertEqual(first?.frameSequenceNumber, 0)
        XCTAssertEqual(second?.frameSequenceNumber, 1)
        try await client.stop()
    }

    func testFrameBufferCapacityHasReleaseMemoryBound() throws {
        let endpoint = try RTSPEndpoint("rtsp://192.168.1.20/live")
        XCTAssertNoThrow(try RTSPClientConfiguration(
            endpoint: endpoint,
            frameBufferCapacity: 4
        ))
        XCTAssertThrowsError(try RTSPClientConfiguration(
            endpoint: endpoint,
            frameBufferCapacity: 5
        ))
    }

    private func makeClient(frameBufferCapacity: Int) throws -> RTSPInterleavedClient {
        let endpoint = try RTSPEndpoint("rtsp://192.168.1.20/live")
        let configuration = try RTSPClientConfiguration(
            endpoint: endpoint,
            frameBufferCapacity: frameBufferCapacity
        )
        return RTSPInterleavedClient(configuration: configuration)
    }

    private func accessUnit(
        sequence: UInt64,
        keyFrame: Bool,
        containsVideoCodingLayer: Bool = true
    ) -> H264AccessUnit {
        H264AccessUnit(
            data: Data([0, 0, 0, 1, keyFrame ? 0x65 : 0x61, UInt8(sequence)]),
            rtpTimestamp: UInt32(sequence),
            firstSequenceNumber: UInt16(sequence),
            lastSequenceNumber: UInt16(sequence),
            frameSequenceNumber: sequence,
            isKeyFrame: keyFrame,
            containsVideoCodingLayer: containsVideoCodingLayer
        )
    }

    private func rtpPacket(
        payload: Data,
        sequence: UInt16,
        timestamp: UInt32
    ) -> RTPPacket {
        RTPPacket(
            marker: true,
            payloadType: 96,
            sequenceNumber: sequence,
            timestamp: timestamp,
            sourceIdentifier: 1,
            payload: payload
        )
    }
}

private actor StopBarrier {
    private(set) var executionCount = 0
    private var stopStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendStop() async {
        executionCount += 1
        stopStarted = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStopStarted() async {
        if stopStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseStop() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }
}
