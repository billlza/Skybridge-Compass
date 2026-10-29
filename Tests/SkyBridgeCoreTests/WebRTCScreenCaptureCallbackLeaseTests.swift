#if os(macOS)
import Foundation
import XCTest
@testable import SkyBridgeCore

final class WebRTCScreenCaptureCallbackLeaseTests: XCTestCase {
    func testRevocationWaitsForInFlightPublisherAndRejectsLateCallbacks() {
        let ownerToken = UUID()
        let replacementToken = UUID()
        let lease = WebRTCScreenCaptureCallbackLease(ownerToken: ownerToken)
        let replacementLease = WebRTCScreenCaptureCallbackLease(ownerToken: replacementToken)
        let publisherEntered = DispatchSemaphore(value: 0)
        let releasePublisher = DispatchSemaphore(value: 0)
        let revokerStarted = DispatchSemaphore(value: 0)
        let revocationFinished = DispatchSemaphore(value: 0)
        let state = LockedLeaseTestState()

        XCTAssertFalse(lease.revoke(token: replacementToken))
        XCTAssertTrue(lease.isActive(token: ownerToken))
        DispatchQueue.global(qos: .userInitiated).async {
            lease.withActiveOwner(token: ownerToken) {
                publisherEntered.signal()
                _ = releasePublisher.wait(timeout: .now() + 5)
                state.recordOldOwnerPublication()
            }
        }

        XCTAssertEqual(publisherEntered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global(qos: .userInitiated).async {
            revokerStarted.signal()
            state.recordRevocationResult(lease.revoke(token: ownerToken))
            revocationFinished.signal()
        }

        XCTAssertEqual(revokerStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(
            revocationFinished.wait(timeout: .now() + 0.1),
            .timedOut,
            "Revocation must linearize after an already-admitted synchronous publisher"
        )
        releasePublisher.signal()
        XCTAssertEqual(revocationFinished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(state.revocationSucceeded)
        XCTAssertEqual(state.oldOwnerPublicationCount, 1)

        let staleResult: Void? = lease.withActiveOwner(token: ownerToken) {
            state.recordOldOwnerPublication()
        }
        XCTAssertNil(staleResult)
        XCTAssertEqual(state.oldOwnerPublicationCount, 1)

        XCTAssertNil(replacementLease.withActiveOwner(token: ownerToken) { true })
        XCTAssertEqual(
            replacementLease.withActiveOwner(token: replacementToken) { true },
            true
        )
    }

    func testScreenCaptureCallbacksAndNativeAudioBridgeRequireExactOwners() throws {
        let managerSource = try source(
            relativePath: "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )
        let nativeFrameRegion = try sourceSlice(
            from: "func submitNativeFrame(",
            to: "// Native warmup owns ScreenCaptureKit for raw RTP only.",
            in: managerSource
        )
        let audioCallbackRegion = try sourceSlice(
            from: "captureStreamer.onCapturedPCM16AudioChunk = { chunk in",
            to: "captureStreamer.onCaptureTelemetry = { snapshot in",
            in: managerSource
        )
        let bridgeSource = try source(
            relativePath: "Sources/WebRTCAudioDeviceBridge/SBWebRTCSystemAudioDevice.m"
        )

        XCTAssertGreaterThanOrEqual(
            nativeFrameRegion.components(separatedBy: "captureCallbackLease.withActiveOwner(").count - 1,
            2
        )
        XCTAssertTrue(audioCallbackRegion.contains("captureCallbackLease.withActiveOwner("))
        XCTAssertTrue(audioCallbackRegion.contains("ownerToken: nativeAudioOwnerToken"))
        XCTAssertTrue(audioCallbackRegion.contains("realtimePCMSubmissionPipe.submit(chunk)"))
        XCTAssertTrue(audioCallbackRegion.contains("directAudioFallbackSender.submit(audioWire)"))

        XCTAssertTrue(bridgeSource.contains("recordedAudioOwnerToken"))
        XCTAssertTrue(bridgeSource.contains("[self.recordedAudioOwnerToken isEqual:ownerToken]"))
        XCTAssertTrue(bridgeSource.contains("strongSelf.delegate == delegate"))
        XCTAssertTrue(bridgeSource.contains("[strongSelf.recordedAudioOwnerToken isEqual:ownerToken]"))
        XCTAssertTrue(bridgeSource.contains("self.recordedAudioOwnerToken = nil"))
    }

    private func source(relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceSlice(from start: String, to end: String, in source: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}

private final class LockedLeaseTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var publicationCount = 0
    private var didRevoke = false

    var oldOwnerPublicationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return publicationCount
    }

    var revocationSucceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didRevoke
    }

    func recordOldOwnerPublication() {
        lock.lock()
        publicationCount += 1
        lock.unlock()
    }

    func recordRevocationResult(_ succeeded: Bool) {
        lock.lock()
        didRevoke = succeeded
        lock.unlock()
    }
}
#endif
