#if os(macOS)
import Foundation
import XCTest
@testable import SkyBridgeCore

final class MacWebRTCScreenFrameWorkerTests: XCTestCase {
    func testWorkerKeepsOnlyLatestPendingRequest() throws {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let thirdProcessed = DispatchSemaphore(value: 0)
        let processedIDs = LockedIDs()
        let worker = MacWebRTCScreenFrameWorker { request in
            processedIDs.append(request.id)
            if request.id == 1 {
                firstStarted.signal()
                _ = releaseFirst.wait(timeout: .now() + 5)
            } else if request.id == 3 {
                thirdProcessed.signal()
            }
            return .noDamage(captureMilliseconds: Int(request.id))
        }

        worker.submit(makeRequest(id: 1))
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 2), .success)

        worker.submit(makeRequest(id: 2))
        worker.submit(makeRequest(id: 3))
        releaseFirst.signal()

        XCTAssertEqual(thirdProcessed.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(waitUntil { worker.snapshot().processed == 2 })
        XCTAssertEqual(processedIDs.values, [1, 3])
        let snapshot = worker.snapshot()
        XCTAssertEqual(snapshot.submitted, 3)
        XCTAssertEqual(snapshot.processed, 2)
        XCTAssertEqual(snapshot.droppedPending, 1)
        XCTAssertFalse(snapshot.hasPending)
    }

    func testNoDamageResultCannotEraseUnconsumedChangedFrame() throws {
        let firstProcessed = DispatchSemaphore(value: 0)
        let secondProcessed = DispatchSemaphore(value: 0)
        let worker = MacWebRTCScreenFrameWorker { request in
            if request.id == 1 {
                defer { firstProcessed.signal() }
                return .prepared(Self.preparedFrame(requestID: request.id))
            }
            defer { secondProcessed.signal() }
            return .noDamage(captureMilliseconds: 1)
        }

        worker.submit(makeRequest(id: 1))
        XCTAssertEqual(firstProcessed.wait(timeout: .now() + 2), .success)
        worker.submit(makeRequest(id: 2))
        XCTAssertEqual(secondProcessed.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(waitUntil { worker.snapshot().processed == 2 })

        guard case .prepared(let prepared)? = worker.takeLatestResult() else {
            return XCTFail("The changed frame must remain ready until consumed")
        }
        XCTAssertEqual(prepared.requestID, 1)
    }

    func testStopClearsPendingAndRejectsNewWork() {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let worker = MacWebRTCScreenFrameWorker { request in
            if request.id == 1 {
                firstStarted.signal()
                _ = releaseFirst.wait(timeout: .now() + 5)
            }
            return .noDamage(captureMilliseconds: 0)
        }

        worker.submit(makeRequest(id: 1))
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 2), .success)
        worker.submit(makeRequest(id: 2))
        worker.stop()
        worker.submit(makeRequest(id: 3))
        releaseFirst.signal()

        let snapshot = worker.snapshot()
        XCTAssertTrue(snapshot.isStopped)
        XCTAssertFalse(snapshot.hasPending)
        XCTAssertFalse(snapshot.hasReadyResult)
        XCTAssertEqual(snapshot.submitted, 2)
        XCTAssertEqual(snapshot.droppedPending, 1)
    }

    func testPreencodedHardwareFrameIsClassifiedWiredAndSealedByWorker() throws {
        let transcript = Data(repeating: 0x44, count: 32)
        let initiatorKeys = SessionKeys(
            sendKey: Data(repeating: 0x11, count: 32),
            receiveKey: Data(repeating: 0x22, count: 32),
            negotiatedSuite: .xwingMLDSA,
            role: .initiator,
            transcriptHash: transcript
        )
        let responderKeys = SessionKeys(
            sendKey: initiatorKeys.receiveKey,
            receiveKey: initiatorKeys.sendKey,
            negotiatedSuite: .xwingMLDSA,
            role: .responder,
            transcriptHash: transcript,
            sessionId: initiatorKeys.sessionId
        )
        let h264IDR = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84])
        let sourceFrame = ScreenDataWire(
            width: 1920,
            height: 1080,
            imageData: h264IDR,
            timestamp: 10,
            format: "h264",
            isSyncFrame: nil,
            sequenceNumber: 7
        )
        let worker = MacWebRTCScreenFrameWorker()
        worker.submit(
            MacWebRTCScreenFrameWorker.Request(
                id: 7,
                sequenceNumber: 7,
                sourceFrame: sourceFrame,
                damageTrackingEnabled: false,
                resetDamageTracker: false,
                degradedJPEGProfile: nil,
                jpegQuality: 0.55,
                keys: initiatorKeys,
                secureCounter: 1,
                secureStateFingerprint: "hardware-key"
            )
        )

        let result = waitForResult(from: worker)
        guard case .prepared(let prepared)? = result else {
            return XCTFail("Expected a prepared hardware frame")
        }
        XCTAssertTrue(prepared.isIndependentFrame)
        let opened = try WebRTCControlChannelCodec.decryptAppPayload(
            prepared.encryptedPayload,
            with: responderKeys,
            allowedPacketTypes: [.remoteDesktop]
        )
        let decoded = try XCTUnwrap(
            RemoteDesktopScreenFrameWire.decodeIfPresent(opened.payload)
        )
        XCTAssertEqual(decoded.width, sourceFrame.width)
        XCTAssertEqual(decoded.height, sourceFrame.height)
        XCTAssertEqual(decoded.imageData, h264IDR)
        XCTAssertEqual(decoded.sequenceNumber, sourceFrame.sequenceNumber)
        worker.stop()
    }

    func testManagerFallbackPipelineUsesBoundedWorkerOffMainActor() throws {
        let managerSource = try source(
            relativePath: "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )
        let fallbackBody = try sourceSlice(
            from: "let sourceFrameToPrepare = capturedFrame",
            to: "guard let sd = capturedFrame else {",
            in: managerSource
        )
        let workerSource = try source(
            relativePath: "Sources/SkyBridgeCore/RemoteConnection/WebRTC/MacWebRTCScreenFrameWorker.swift"
        )

        XCTAssertTrue(fallbackBody.contains("cgDisplayFrameWorker.submit("))
        XCTAssertTrue(fallbackBody.contains("reserveWebRTCSecurePayloadCounter("))
        XCTAssertFalse(fallbackBody.contains("CGDisplayCreateImage"))
        XCTAssertFalse(fallbackBody.contains("damageTracker.analyze"))
        XCTAssertFalse(fallbackBody.contains("jpegData(from:"))
        XCTAssertTrue(workerSource.contains("private var pendingRequest: Request?"))
        XCTAssertTrue(workerSource.contains("droppedPending &+= 1"))
        XCTAssertTrue(workerSource.contains("CGDisplayCreateImage(CGMainDisplayID())"))
        XCTAssertTrue(workerSource.contains("damageTracker.analyze(image: image)"))
        XCTAssertTrue(workerSource.contains("RemoteDesktopScreenFrameWire.encode("))
        XCTAssertTrue(workerSource.contains("RemoteDesktopScreenFrameWire.containsSyncFrame("))
        XCTAssertTrue(workerSource.contains("WebRTCControlChannelCodec.encryptAppPayload("))
        XCTAssertFalse(workerSource.contains("Task.detached"))
    }

    func testWebRTCStartupAwaitsCannotDriveReplacementSessions() throws {
        let managerSource = try source(
            relativePath: "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )
        let startupRegions = [
            try sourceSlice(
                from: "source: \"connection-code-answerer\"",
                to: "// 主动加入会话并在短时间内心跳重发",
                in: managerSource
            ),
            try sourceSlice(
                from: "source: \"connection-code-offerer\"",
                to: "private func establishWebRTCConnection(",
                in: managerSource
            ),
            try sourceSlice(
                from: "source: \"qr-answerer\"",
                to: "// 主动发送 join",
                in: managerSource
            )
        ]

        for region in startupRegions {
            XCTAssertTrue(region.contains("try await session.startAsync()"))
            XCTAssertTrue(region.contains("try Task.checkCancellation()"))
            XCTAssertTrue(region.contains("webrtcSessionsBySessionId[sessionID] === session"))
        }

        let callbackRegions = [
            try sourceSlice(
                from: "let session = WebRTCSession(sessionId: sessionID, localDeviceId: localDeviceId, role: .answerer, ice: ice)",
                to: "beginWebRTCTerminalNotificationTracking(sessionID: sessionID)",
                in: managerSource
            ),
            try sourceSlice(
                from: "let session = WebRTCSession(sessionId: sessionID, localDeviceId: localDeviceId, role: .offerer, ice: ice)",
                to: "beginWebRTCTerminalNotificationTracking(sessionID: sessionID)",
                in: managerSource
            ),
            try sourceSlice(
                from: "let session = WebRTCSession(sessionId: sessionID, localDeviceId: localDeviceId, role: .answerer, ice: ice)",
                to: "beginWebRTCTerminalNotificationTracking(sessionID: sessionID)",
                in: String(managerSource.dropFirst(
                    managerSource.distance(
                        from: managerSource.startIndex,
                        to: try XCTUnwrap(
                            managerSource.range(of: "private func establishWebRTCConnection(")?.lowerBound
                        )
                    )
                ))
            )
        ]
        for region in callbackRegions {
            let exactIdentityGuardCount = region.components(
                separatedBy: "webrtcSessionsBySessionId[sessionID] === session"
            ).count - 1
            XCTAssertGreaterThanOrEqual(exactIdentityGuardCount, 4)
        }

        let sendSignalBody = try sourceSlice(
            from: "private func sendSignal(_ env: WebRTCSignalingEnvelope",
            to: "private func handleSignalingServerFrame(",
            in: managerSource
        )
        XCTAssertTrue(sendSignalBody.contains("try Task.checkCancellation()"))
        XCTAssertTrue(sendSignalBody.contains("error is CancellationError || Task.isCancelled"))
        XCTAssertFalse(sendSignalBody.contains("try? await Task.sleep(for: .milliseconds(350))"))
    }

    private func makeRequest(id: UInt64) -> MacWebRTCScreenFrameWorker.Request {
        MacWebRTCScreenFrameWorker.Request(
            id: id,
            sequenceNumber: id,
            sourceFrame: nil,
            damageTrackingEnabled: true,
            resetDamageTracker: false,
            degradedJPEGProfile: nil,
            jpegQuality: 0.55,
            keys: SessionKeys(
                sendKey: Data(repeating: 0x11, count: 32),
                receiveKey: Data(repeating: 0x22, count: 32),
                negotiatedSuite: .xwingMLDSA,
                role: .initiator,
                transcriptHash: Data(repeating: 0x33, count: 32)
            ),
            secureCounter: id,
            secureStateFingerprint: "test-key"
        )
    }

    private static func preparedFrame(
        requestID: UInt64
    ) -> MacWebRTCScreenFrameWorker.PreparedFrame {
        MacWebRTCScreenFrameWorker.PreparedFrame(
            requestID: requestID,
            frame: ScreenDataWire(
                width: 1,
                height: 1,
                imageData: Data([0x01]),
                timestamp: 1,
                format: "jpeg",
                isSyncFrame: true,
                sequenceNumber: requestID
            ),
            encryptedPayload: Data([0x02]),
            damageReport: nil,
            captureMilliseconds: 1,
            jpegEncodeMilliseconds: 1,
            jpegQuality: 0.55,
            usedDegradedJPEGProfile: false,
            isIndependentFrame: true,
            secureStateFingerprint: "test-key"
        )
    }

    private func source(relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    private func waitForResult(
        from worker: MacWebRTCScreenFrameWorker,
        timeout: TimeInterval = 2
    ) -> MacWebRTCScreenFrameWorker.ProcessingResult? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = worker.takeLatestResult() {
                return result
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return worker.takeLatestResult()
    }

    private func sourceSlice(from startMarker: String, to endMarker: String, in source: String) throws -> String {
        guard let start = source.range(of: startMarker)?.lowerBound,
              let end = source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound else {
            XCTFail("source markers not found: \(startMarker) -> \(endMarker)")
            return source
        }
        return String(source[start..<end])
    }
}

private final class LockedIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt64] = []

    var values: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: UInt64) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
#endif
