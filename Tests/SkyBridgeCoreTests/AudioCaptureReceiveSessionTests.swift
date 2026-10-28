#if os(macOS)
import Combine
import CryptoKit
import Foundation
import Network
import os
import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore
@testable import SkyBridgeAppleTransport

@MainActor
final class AudioCaptureReceiveSessionTests: XCTestCase {
    func testRenewalWaitsForConsentAndClosesOutputBeforeJoiningLateRequest() async throws {
        let fixture = try ReceiverFixture(autoApprove: false, renewalDue: true)
        let gate = PlaybackRenewalGate()
        let expectedOwner = fixture.channel.ownerID, expectedLease = fixture.lease
        let session = fixture.session(renewMembership: { channel, lease in
            guard channel.ownerID == expectedOwner, lease === expectedLease else { throw TestFailure.timeout }
            await gate.waitForRelease()
            try Task.checkCancellation()
        })
        var returned = false
        let task = Task { defer { returned = true }; return try await session.run() }
        defer { gate.releaseIfWaiting(); task.cancel() }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.approvals.pendingRequest != nil }
        XCTAssertFalse(gate.started)
        let request = try XCTUnwrap(fixture.approvals.pendingRequest)
        XCTAssertTrue(fixture.approvals.resolve(request, allowOnce: true))
        try await wait { gate.started }
        await session.stop()
        try await wait { gate.cancelled.withLock { $0 } && fixture.output.state.withLock { $0.closes > 0 } }
        XCTAssertFalse(returned, "The cancelled account request must stay owned until its cleanup returns")
        XCTAssertTrue(fixture.lease.isCurrent, "Stopping the stream must not revoke its otherwise valid account evidence")
        gate.releaseIfWaiting()
        do { _ = try await task.value; XCTFail("Stopped playback reported success") }
        catch let failure as AudioPlaybackReceiveFailure { XCTAssertEqual(failure.reason, .userStopped) }
        XCTAssertTrue(returned)
        XCTAssertFalse(fixture.sent.withLock { $0.contains { if case .playbackComplete = $0.body { true } else { false } } })
    }

    func testActualChannelConsumerVerifiesExactBytesAndWaitsForNativeCompletion() async throws {
        let fixture = try ReceiverFixture()
        fixture.output.state.withLock { $0.allowCompletion = false }
        let received = fixture.sent
        let bytes = Data([1, 2, 0x80, 3, 4, 0x7f, 0xff, 0, 0, 1, 0, 0])
        fixture.respondOnReady = [fixture.data(bytes), fixture.end(bytes)]
        let session = fixture.session()
        let task = Task { try await session.run() }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.output.state.withLock { $0.finishes == 1 } }
        XCTAssertFalse(received.withLock { $0.contains { if case .playbackComplete = $0.body { true } else { false } } })
        fixture.output.state.withLock { $0.allowCompletion = true }
        let receipt = try await task.value
        XCTAssertEqual(receipt.sourceFrames, 2)
        XCTAssertEqual(receipt.sha256, Data(SHA256.hash(data: bytes)))
        XCTAssertEqual(receipt.trailingPaddingFrames, 2)
        XCTAssertEqual(fixture.output.state.withLock { $0.bytes }, bytes)
        let messages = received.withLock { $0 }
        let verified = try XCTUnwrap(messages.firstIndex { if case .contentVerified = $0.body { true } else { false } })
        let completed = try XCTUnwrap(messages.firstIndex { if case .playbackComplete = $0.body { true } else { false } })
        XCTAssertLessThan(verified, completed)
        XCTAssertEqual(fixture.output.state.withLock { $0.starts }, 0, "Short stream starts through finishInput")
        XCTAssertEqual(fixture.output.state.withLock { $0.closes }, 1)
    }

    func testContentMismatchTerminatesWithoutSuccessfulPlaybackReceipt() async throws {
        let fixture = try ReceiverFixture(), bytes = Data(repeating: 2, count: 6)
        fixture.respondOnReady = [fixture.data(bytes), .init(streamID: fixture.id,
            body: .end(totalBytes: 6, sha256: Data(repeating: 0, count: 32)))]
        let task = Task { try await fixture.session().run() }
        try fixture.mailbox.receive(fixture.offer)
        do { _ = try await task.value; XCTFail("Bad content completed") }
        catch let failure as AudioPlaybackReceiveFailure { XCTAssertEqual(failure.reason, .contentMismatch) }
        XCTAssertEqual(fixture.output.state.withLock { $0.finishes }, 0)
        XCTAssertTrue(fixture.sent.withLock { $0.contains { $0.body == .stop(.contentMismatch) } })
        XCTAssertFalse(fixture.sent.withLock { $0.contains { if case .playbackComplete = $0.body { true } else { false } } })
    }

    func testCompressedControlsCannotReuseAnApprovedStrictPcmStream() async throws {
        let bodies: [AudioStreamingMessage.Body] = [
            .opusOffer(source: .systemCapture, format: try .init(channels: 2, bitrate: 192000)),
            .opusConfiguration(preSkipFrames: 312), .opusData(sequence: 0, bytes: Data(repeating: 0, count: 480)),
            .opusEnd(sourceFrames: 1, packetCount: 1, totalEncodedBytes: 480, sha256: Data(repeating: 0, count: 32)),
            .opusOutputReady
        ]
        for body in bodies {
            let fixture = try ReceiverFixture()
            fixture.respondOnReady = [.init(streamID: fixture.id, body: body)]
            let task = Task { try await fixture.session().run() }
            try fixture.mailbox.receive(fixture.offer)
            do { _ = try await task.value; XCTFail("Compatible message reused strict PCM permission") }
            catch let failure as AudioPlaybackReceiveFailure { XCTAssertEqual(failure.reason, .protocolViolation) }
            XCTAssertTrue(fixture.output.state.withLock { $0.bytes.isEmpty })
            XCTAssertEqual(fixture.output.state.withLock { $0.finishes }, 0)
            XCTAssertFalse(fixture.sent.withLock { $0.contains { if case .playbackComplete = $0.body { true } else { false } } })
        }
    }

    func testPeerStopCancelsVisibleApprovalWithoutOpeningOutput() async throws {
        let fixture = try ReceiverFixture(autoApprove: false)
        let task = Task { try await fixture.session().run() }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.approvals.pendingRequest != nil }
        try fixture.mailbox.receive(.init(streamID: fixture.id, body: .stop(.userStopped)))
        do { _ = try await task.value; XCTFail("Stop was success") }
        catch let failure as AudioPlaybackReceiveFailure { XCTAssertEqual(failure.reason, .userStopped) }
        XCTAssertNil(fixture.approvals.pendingRequest)
        XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
    }

    func testUnavailableOutputReturnsExplicitStopForTheOfferedStream() async throws {
        let fixture = try ReceiverFixture()
        fixture.failOutputSelection = true
        let task = Task { try await fixture.session().run() }
        try fixture.mailbox.receive(fixture.offer)
        do { _ = try await task.value; XCTFail("Unavailable output accepted") }
        catch let failure as AudioPlaybackReceiveFailure {
            XCTAssertEqual(failure.reason, .unsupportedOutput)
            XCTAssertEqual(failure.sourceFormat, fixture.format)
            XCTAssertEqual(failure.outputIssue, .endpointUnavailable)
        }
        XCTAssertTrue(fixture.sent.withLock { $0.contains { $0.streamID == fixture.id && $0.body == .stop(.unsupportedOutput) } })
        XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
        XCTAssertNil(fixture.approvals.pendingRequest)
    }

    func testUnavailableAccountDoesNotReportAnOutputFailureOrOpenOutput() async throws {
        let fixture = try ReceiverFixture()
        fixture.failAccountLookup = true
        let task = Task { try await fixture.session().run() }
        try fixture.mailbox.receive(fixture.offer)
        do { _ = try await task.value; XCTFail("Unavailable account accepted") }
        catch let failure as AudioPlaybackReceiveFailure {
            XCTAssertEqual(failure.reason, .accountRevoked)
            XCTAssertNil(failure.sourceFormat)
            XCTAssertNil(failure.outputIssue)
        }
        XCTAssertTrue(fixture.sent.withLock { $0.contains { $0.body == .stop(.accountRevoked) } })
        XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
        XCTAssertNil(fixture.approvals.pendingRequest)
    }

    func testDataBeforeApprovalIsRejectedAndCannotReachNativeQueue() async throws {
        let fixture = try ReceiverFixture(autoApprove: false)
        let task = Task { try await fixture.session().run() }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.approvals.pendingRequest != nil }
        try fixture.mailbox.receive(fixture.data(Data(count: 6)))
        do { _ = try await task.value; XCTFail("Unapproved data accepted") }
        catch let failure as AudioPlaybackReceiveFailure { XCTAssertEqual(failure.reason, .protocolViolation) }
        XCTAssertTrue(fixture.output.state.withLock { $0.bytes.isEmpty })
        XCTAssertNil(fixture.approvals.pendingRequest)
    }

    func testCapturedFormatAndSpecificOutputIssueSurvivePreparationFailureWithoutReadiness() async throws {
        let cases: [(CoreAudioExactPcmError, AudioPlaybackOutputIssue)] = [
            (.formatMismatch, .formatMismatch), (.mixableVirtualFormat, .mixingRequired),
            (.unsupportedLayout, .unsupportedLayout), (.deviceBusy, .deviceBusy)
        ]
        for (native, issue) in cases {
            let fixture = try ReceiverFixture()
            fixture.output.state.withLock { $0.prepareFailure = native }
            let session = fixture.session(), task = Task { try await session.run() }
            try fixture.mailbox.receive(fixture.offer)
            do { _ = try await task.value; XCTFail("Rejected output completed playback") }
            catch let failure as AudioPlaybackReceiveFailure {
                XCTAssertEqual(failure.reason, .unsupportedOutput)
                XCTAssertEqual(failure.sourceFormat, fixture.format)
                XCTAssertEqual(failure.outputIssue, issue)
                XCTAssertEqual(failure.diagnostic, issue.rawValue)
                XCTAssertTrue(failure.cleanupFailures.isEmpty)
            }
            XCTAssertEqual(fixture.sent.withLock { $0.map(\.body) }, [.stop(.unsupportedOutput)])
            XCTAssertEqual(fixture.output.state.withLock { $0.starts + $0.finishes }, 0)
            XCTAssertTrue(fixture.output.state.withLock { $0.bytes.isEmpty })
            XCTAssertEqual(fixture.output.state.withLock { $0.closes }, 1)
        }
    }

    func testOutputIssueResetsForNewOwnerAndRejectedConcurrentRequestCannotOverwriteIt() async throws {
        let first = try ReceiverFixture(), second = try ReceiverFixture(controlTransport: .usb), third = try ReceiverFixture()
        first.output.state.withLock { $0.prepareFailure = .mixableVirtualFormat }
        second.output.state.withLock { $0.waitUntilRevoked = true }
        let service = first.service(additional: [second, third])
        addTeardownBlock { _ = await service.stop() }
        try service.start(); try first.deliver(first)
        try await wait { service.phase == .failed }
        XCTAssertEqual(service.outputIssue, .mixingRequired)
        XCTAssertEqual(service.controlTransport, .network)
        XCTAssertEqual(service.sourceFormat, first.format)
        try first.deliver(second)
        try await wait { second.output.state.withLock { $0.prepares == 1 } }
        XCTAssertNil(service.outputIssue)
        XCTAssertNil(service.failureReason)
        try first.deliver(third)
        try await wait { third.mailbox.isTerminal }
        XCTAssertEqual(service.currentPlaybackID, second.channel.ownerID)
        XCTAssertEqual(service.controlTransport, .usb, "A competing channel cannot overwrite the active playback carrier")
        XCTAssertEqual(service.sourceFormat, second.format)
        XCTAssertNil(service.outputIssue)
        XCTAssertNil(service.failureReason)
        let stopped = await service.stop(); XCTAssertTrue(stopped)
        XCTAssertEqual(service.failureReason, .userStopped)
        XCTAssertNil(service.outputIssue)
        XCTAssertEqual(service.sourceFormat, second.format)
        XCTAssertEqual(third.output.state.withLock { $0.prepares }, 0)
        XCTAssertEqual(service.controlTransport, .usb, "Keep the terminal playback carrier after cleanup")
    }

    func testNativeAcceptedCounterCannotDisagreeWithReceivedBytes() async throws {
        let fixture = try ReceiverFixture(), bytes = Data(count: 6)
        fixture.output.state.withLock { $0.inventAcceptedFrame = true }
        fixture.respondOnReady = [fixture.data(bytes)]
        let task = Task { try await fixture.session().run() }
        try fixture.mailbox.receive(fixture.offer)
        do { _ = try await task.value; XCTFail("Fabricated native progress accepted") }
        catch let failure as AudioPlaybackReceiveFailure { XCTAssertEqual(failure.reason, .protocolViolation) }
        XCTAssertEqual(fixture.output.state.withLock { $0.finishes }, 0)
    }

    func testEmptyCaptureCompletesOnlyAfterNativeEmptyFinalization() async throws {
        let fixture = try ReceiverFixture()
        fixture.respondOnReady = [fixture.end(Data())]
        let task = Task { try await fixture.session().run() }
        try fixture.mailbox.receive(fixture.offer)
        let receipt = try await task.value
        XCTAssertEqual(receipt.sourceFrames, 0)
        XCTAssertEqual(receipt.trailingPaddingFrames, 0)
        XCTAssertEqual(fixture.output.state.withLock { $0.finishes }, 1)
    }

    func testTransientNativeFinishBusyRetriesWithoutLosingVerifiedContent() async throws {
        let fixture = try ReceiverFixture(), bytes = Data(count: 6)
        fixture.output.state.withLock { $0.finishBusyCount = 1 }
        fixture.respondOnReady = [fixture.data(bytes), fixture.end(bytes)]
        let task = Task { try await fixture.session().run() }
        try fixture.mailbox.receive(fixture.offer)
        let receipt = try await task.value
        XCTAssertEqual(receipt.sourceFrames, 1)
        XCTAssertEqual(fixture.output.state.withLock { $0.finishes }, 1)
    }

    func testCancellingPrepareRevokesPermissionAndWaitsForOwnedCleanup() async throws {
        let fixture = try ReceiverFixture()
        fixture.output.state.withLock { $0.waitUntilRevoked = true }
        let task = Task { try await fixture.session().run() }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.output.state.withLock { $0.prepares == 1 } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled preparation succeeded") }
        catch let failure as AudioPlaybackReceiveFailure { XCTAssertEqual(failure.reason, .userStopped) }
        XCTAssertEqual(fixture.output.state.withLock { $0.closes }, 1)
        XCTAssertFalse(fixture.sent.withLock { $0.contains { if case .outputReady = $0.body { true } else { false } } })
    }

    func testPendingOutputRetainsExactOwnerBlocksReplacementAndNeedsExplicitBoundedRetries() async throws {
        let first = try ReceiverFixture(), second = try ReceiverFixture()
        first.output.state.withLock { $0.pendingCloseAttempts = 2 }
        first.respondOnReady = [.init(streamID: first.id, body: .stop(.userStopped))]
        let service = first.service(additional: [second])
        try service.start(); try first.deliver(first)
        try await wait { service.requiresOutputRecovery }
        XCTAssertEqual(service.phase, .failed); XCTAssertNil(service.currentPlaybackID)
        XCTAssertEqual(service.outputCleanupOutcome?.state, .pending)
        XCTAssertFalse(first.output.authorization.withLock { $0?() == true })
        try first.deliver(second)
        try await wait { second.mailbox.isTerminal }
        XCTAssertEqual(second.output.state.withLock { $0.prepares }, 0, "Pending owner cannot be replaced")
        let stopped = await service.stop()
        XCTAssertFalse(stopped); XCTAssertEqual(first.output.state.withLock { $0.closes }, 1, "stop is not an implicit retry")
        let retryOne = await service.retryOutputCleanup()
        XCTAssertFalse(retryOne); XCTAssertTrue(service.requiresOutputRecovery)
        XCTAssertEqual(first.output.state.withLock { $0.closes }, 2)
        let retryTwo = await service.retryOutputCleanup()
        XCTAssertTrue(retryTwo); XCTAssertFalse(service.requiresOutputRecovery)
        XCTAssertEqual(first.output.state.withLock { $0.closes }, 3)
        XCTAssertEqual(first.output.state.withLock { $0.closedOwners }, Array(repeating: first.channel.ownerID, count: 3))
        XCTAssertEqual(service.phase, .failed); XCTAssertNil(service.completedSourceFrames)
        XCTAssertFalse(first.sent.withLock { $0.contains { if case .playbackComplete = $0.body { true } else { false } } })
        let stoppedSafely = await service.stop(); XCTAssertTrue(stoppedSafely)
    }

    func testConcurrentRecoveryCallsShareOneCloseAttemptAndDoNotRestartOutput() async throws {
        let fixture = try ReceiverFixture()
        fixture.output.state.withLock { $0.pendingCloseAttempts = 1 }
        fixture.respondOnReady = [.init(streamID: fixture.id, body: .stop(.userStopped))]
        let service = fixture.service(); try service.start(); try fixture.deliver(fixture)
        try await wait { service.requiresOutputRecovery }
        let entered = expectation(description: "cleanup retry entered"), secondEntered = expectation(description: "second caller joined")
        let release = DispatchSemaphore(value: 0)
        fixture.output.closeGate.withLock { $0 = {
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
        } }
        let one = Task { await service.retryOutputCleanup() }
        await fulfillment(of: [entered], timeout: 2)
        let two = Task { secondEntered.fulfill(); return await service.retryOutputCleanup() }
        await fulfillment(of: [secondEntered], timeout: 2)
        release.signal()
        let firstResult = await one.value, secondResult = await two.value
        XCTAssertTrue(firstResult); XCTAssertTrue(secondResult)
        XCTAssertEqual(fixture.output.state.withLock { $0.closes }, 2)
        XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 1)
        XCTAssertEqual(fixture.output.state.withLock { $0.starts }, 0)
        XCTAssertEqual(service.phase, .failed)
        let stoppedSafely = await service.stop(); XCTAssertTrue(stoppedSafely)
    }

    func testReleasedDiagnosticsAndPreservedExternalSettingsDoNotRetainOutputOwner() async throws {
        let fixture = try ReceiverFixture()
        fixture.output.state.withLock {
            $0.releaseDiagnostics = ["historical native snapshot failure"]
            $0.preservedExternalChanges = ["nominalRate"]
        }
        fixture.respondOnReady = [.init(streamID: fixture.id, body: .stop(.userStopped))]
        let service = fixture.service(); try service.start(); try fixture.deliver(fixture)
        try await wait { service.phase == .failed }
        XCTAssertFalse(service.requiresOutputRecovery); XCTAssertTrue(service.outputCleanupPreservedExternalChanges)
        XCTAssertEqual(service.outputCleanupOutcome?.preservedExternalChanges, ["nominalRate"])
        XCTAssertTrue(service.cleanupFailures.contains("historical native snapshot failure"))
        let retry = await service.retryOutputCleanup()
        XCTAssertTrue(retry); XCTAssertEqual(fixture.output.state.withLock { $0.closes }, 1)
        let stoppedSafely = await service.stop(); XCTAssertTrue(stoppedSafely)
    }

    func testStopDeliveryFailureDoesNotMasqueradeAsOutputRecovery() async throws {
        let fixture = try ReceiverFixture()
        fixture.failStopDelivery.withLock { $0 = true }
        fixture.respondOnReady = [.init(streamID: fixture.id, body: .end(totalBytes: 0, sha256: Data(count: 32)))]
        let service = fixture.service(); try service.start(); try fixture.deliver(fixture)
        try await wait { service.phase == .failed }
        XCTAssertEqual(service.failureReason, .contentMismatch)
        XCTAssertFalse(service.requiresOutputRecovery); XCTAssertEqual(service.outputCleanupOutcome?.state, .released)
        XCTAssertFalse(service.cleanupFailures.isEmpty)
        let stoppedSafely = await service.stop(); XCTAssertTrue(stoppedSafely)
    }

    func testStaleStopActionCannotStopReplacementOwner() async throws {
        let first = try ReceiverFixture(), second = try ReceiverFixture()
        first.respondOnReady = [.init(streamID: first.id, body: .stop(.userStopped))]
        let service = first.service(additional: [second]); try service.start(); try first.deliver(first)
        try await wait { service.phase == .failed }
        try first.deliver(second)
        try await wait { service.phase == .buffering && service.currentPlaybackID == second.channel.ownerID }
        service.stopPlayback(ifOwnedBy: first.channel.ownerID)
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(service.currentPlaybackID, second.channel.ownerID)
        XCTAssertEqual(second.output.state.withLock { $0.closes }, 0)
        service.stopPlayback(ifOwnedBy: second.channel.ownerID)
        try await wait { service.phase == .failed }
        XCTAssertEqual(second.output.state.withLock { $0.closes }, 1)
        let stoppedSafely = await service.stop(); XCTAssertTrue(stoppedSafely)
    }


    func testOriginalFileWaitsForExactVerifiedArtifactThenPlaysRawSamples() async throws {
        let samples = Data([1, 2, 0x80, 3, 4, 0x7f, 0xff, 0, 0, 1, 0, 0])
        let file = wave(samples), fixture = try ReceiverFixture(file: file)
        let session = fixture.session(), task = Task { try await session.run() }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.acceptedFile }
        XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
        let ticket = try await fixture.claimFile()
        let directory = try privateAudioDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let owned = try await prepareArtifact(file, ticket: ticket, directory: directory)
        try await ticket.deliver(owned.artifact)
        await ticket.endReceive()
        let receipt = try await task.value
        XCTAssertEqual(receipt.sha256, Data(SHA256.hash(data: file)))
        XCTAssertEqual(receipt.sourceFrames, 2)
        XCTAssertEqual(receipt.format, fixture.format)
        XCTAssertEqual(fixture.output.state.withLock { $0.bytes }, samples)
        let messages = fixture.sent.withLock { $0 }
        XCTAssertEqual(messages.map(\.body), [.accept(receiveWindowBytes: 0), .outputReady(fixture.format),
            .playbackComplete(sourceFrames: 2, trailingPaddingFrames: 2)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.url.path))
        let count = await owned.io.activeTransferCount(); XCTAssertEqual(count, 0)
        do { _ = try await owned.reader.read(offset: 0, length: 1); XCTFail("Reader escaped cleanup") }
        catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .closed) }
    }

    func testFileOutputProgressDoesNotCompleteUndrainedNativeOutput() async throws {
        let file = wave(Data(count: 12))
        let fixture = try ReceiverFixture(file: file,
            peerCapabilities: [AudioStreamingWire.fileOutputProgressReceiveCapability])
        fixture.output.state.withLock { $0.allowCompletion = false }
        let session = fixture.session(reportFileOutputProgress: true), task = Task { try await session.run() }
        defer { task.cancel() }
        try fixture.mailbox.receive(fixture.offer); try await wait { fixture.acceptedFile }
        let ticket = try await fixture.claimFile(), directory = try privateAudioDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let owned = try await prepareArtifact(file, ticket: ticket, directory: directory)
        try await ticket.deliver(owned.artifact); await ticket.endReceive()
        try await wait { !fixture.outputProgressMessages.isEmpty }
        XCTAssertEqual(fixture.outputProgressMessages, [2])
        XCTAssertEqual(fixture.sent.withLock { $0.map(\.body) }, [.accept(receiveWindowBytes: 0),
            .outputReady(fixture.format), .fileOutputProgress(sourceFrames: 2)])
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(fixture.outputProgressMessages, [2], "Unchanged output is not a progress heartbeat")
        fixture.output.state.withLock { $0.allowCompletion = true }
        let receipt = try await task.value
        XCTAssertEqual(receipt.sourceFrames, 2); XCTAssertEqual(receipt.trailingPaddingFrames, 2)
        XCTAssertEqual(fixture.sent.withLock { $0.last?.body }, .playbackComplete(sourceFrames: 2, trailingPaddingFrames: 2))
    }

    func testFileOutputProgressRequiresBothInstalledRoles() async throws {
        for (reports, consumes) in [(false, true), (true, false)] {
            let file = wave(Data(count: 12))
            let fixture = try ReceiverFixture(file: file,
                peerCapabilities: consumes ? [AudioStreamingWire.fileOutputProgressReceiveCapability] : [])
            fixture.output.state.withLock { $0.allowCompletion = false }
            let session = fixture.session(reportFileOutputProgress: reports), task = Task { try await session.run() }
            defer { task.cancel() }
            try fixture.mailbox.receive(fixture.offer); try await wait { fixture.acceptedFile }
            let ticket = try await fixture.claimFile(), directory = try privateAudioDirectory()
            defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
            let owned = try await prepareArtifact(file, ticket: ticket, directory: directory)
            try await ticket.deliver(owned.artifact); await ticket.endReceive()
            try await wait { fixture.output.state.withLock { $0.finishes > 0 } }
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertTrue(fixture.outputProgressMessages.isEmpty)
            fixture.output.state.withLock { $0.allowCompletion = true }
            _ = try await task.value
        }
    }

    func testFileOutputProgressCoalescesNativeCountersWithoutDelayingCompletion() async throws {
        let file = wave(Data(count: 128 * 6))
        let fixture = try ReceiverFixture(file: file,
            peerCapabilities: [AudioStreamingWire.fileOutputProgressReceiveCapability])
        fixture.output.state.withLock { $0.maximumSubmittedFrames = 0 }
        let session = fixture.session(reportFileOutputProgress: true), task = Task { try await session.run() }
        defer { task.cancel() }
        try fixture.mailbox.receive(fixture.offer); try await wait { fixture.acceptedFile }
        let ticket = try await fixture.claimFile(), directory = try privateAudioDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let owned = try await prepareArtifact(file, ticket: ticket, directory: directory)
        try await ticket.deliver(owned.artifact); await ticket.endReceive()
        try await wait { fixture.output.state.withLock { $0.starts > 0 } }
        XCTAssertTrue(fixture.outputProgressMessages.isEmpty, "Queued prefill is not native output progress")
        fixture.output.state.withLock { $0.maximumSubmittedFrames = 8 }
        try await wait { fixture.outputProgressMessages.count == 1 }
        fixture.output.state.withLock { $0.maximumSubmittedFrames = 64 }
        try await wait { fixture.output.state.withLock { $0.bytes.count >= 64 * 6 } }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(fixture.outputProgressMessages, [8])
        try await wait { fixture.outputProgressMessages.count == 2 }
        XCTAssertEqual(fixture.outputProgressMessages, [8, 64])
        let sends = fixture.progressSends.withLock { $0 }
        XCTAssertGreaterThanOrEqual(sends[0].at.duration(to: sends[1].at), .seconds(1))
        fixture.output.state.withLock { $0.maximumSubmittedFrames = nil }
        let receipt = try await task.value
        XCTAssertEqual(receipt.sourceFrames, 128)
        XCTAssertEqual(fixture.sent.withLock { $0.last?.body }, .playbackComplete(sourceFrames: 128, trailingPaddingFrames: 0))
    }

    func testStopClosesNativeOutputBeforeBlockedProgressWriteSettles() async throws {
        let file = wave(Data(count: 12)), blockedWrite = PlaybackRenewalGate()
        let fixture = try ReceiverFixture(file: file,
            peerCapabilities: [AudioStreamingWire.fileOutputProgressReceiveCapability])
        fixture.output.state.withLock { $0.allowCompletion = false }
        fixture.beforeSend.withLock { $0 = { message in
            if case .fileOutputProgress = message.body { await blockedWrite.waitForRelease() }
        } }
        let session = fixture.session(reportFileOutputProgress: true), task = Task { try await session.run() }
        defer { blockedWrite.releaseIfWaiting(); task.cancel() }
        try fixture.mailbox.receive(fixture.offer); try await wait { fixture.acceptedFile }
        let ticket = try await fixture.claimFile(), directory = try privateAudioDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let owned = try await prepareArtifact(file, ticket: ticket, directory: directory)
        try await ticket.deliver(owned.artifact); await ticket.endReceive()
        try await wait { blockedWrite.started }
        await session.stop()
        let closedBeforeWriteSettled: Result<Void, Error>
        do {
            try await wait { fixture.output.state.withLock { $0.closes > 0 } }
            closedBeforeWriteSettled = .success(())
        } catch { closedBeforeWriteSettled = .failure(error) }
        blockedWrite.releaseIfWaiting()
        do { _ = try await task.value; XCTFail("Stopped output completed successfully") }
        catch { XCTAssertEqual((error as? AudioPlaybackReceiveFailure)?.reason, .userStopped) }
        try closedBeforeWriteSettled.get()
        XCTAssertTrue(fixture.outputProgressMessages.isEmpty, "A cancelled control write must not report progress")
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.url.path))
    }

    func testOriginalFileCannotBeClaimedBeforePlaybackApproval() async throws {
        let fixture = try ReceiverFixture(autoApprove: false, file: wave(Data(count: 12)))
        let task = Task { try await fixture.session().run() }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.approvals.pendingRequest != nil }
        let early = try await fixture.tryClaimFile()
        XCTAssertNil(early)
        XCTAssertFalse(fixture.acceptedFile)
        try fixture.mailbox.receive(.init(streamID: fixture.id, body: .stop(.userStopped)))
        do { _ = try await task.value; XCTFail("Unapproved file completed") }
        catch let error as AudioPlaybackReceiveFailure { XCTAssertEqual(error.reason, .userStopped) }
        XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
    }

    func testLogicalFileStreamIsNotAcquiredBeforePlaybackApproval() async throws {
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let fixture = try ReceiverFixture(controlTransport: .usb, autoApprove: false, file: wave(Data(count: 12)), logicalFileAcceptor: {
            opens.withLock { $0 += 1 }; throw P2PAudioTransportError.unavailable
        })
        let session = fixture.session(), task = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await task.result }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.approvals.pendingRequest != nil }
        XCTAssertEqual(opens.withLock { $0 }, 0)
        XCTAssertFalse(fixture.acceptedFile)
        try fixture.mailbox.receive(.init(streamID: fixture.id, body: .stop(.userStopped)))
        do { _ = try await task.value; XCTFail("Unapproved logical file completed") }
        catch let error as AudioPlaybackReceiveFailure { XCTAssertEqual(error.reason, .userStopped) }
        XCTAssertEqual(opens.withLock { $0 }, 0)
        XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
    }

    func testApprovedLogicalFileAcquisitionFailureStopsBeforeOutput() async throws {
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let fixture = try ReceiverFixture(controlTransport: .usb, file: wave(Data(count: 12)), logicalFileAcceptor: {
            opens.withLock { $0 += 1 }; throw P2PAudioTransportError.unavailable
        })
        let session = fixture.session(), task = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await task.result }
        try fixture.mailbox.receive(fixture.offer)
        do { _ = try await task.value; XCTFail("Missing logical stream produced playback") }
        catch let error as AudioPlaybackReceiveFailure { XCTAssertEqual(error.reason, .sessionReplaced) }
        XCTAssertEqual(opens.withLock { $0 }, 1)
        XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
    }

    func testOriginalFileRejectsMetadataAndForeignClassicAuthorityWithoutConsumingGrant() async throws {
        let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
        let session = fixture.session(), task = Task { try await session.run() }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.acceptedFile }
        for fault in ["length", "hash", "peer", "key"] {
            do { _ = try await fixture.tryClaimFile(fault: fault); XCTFail("Foreign \(fault) accepted") }
            catch { XCTAssertTrue(error is AudioOriginalFileTransferError || error is P2PAudioTransportError) }
        }
        let ticket = try await fixture.claimFile()
        do { _ = try await fixture.claimFile(); XCTFail("Second file consumer accepted") }
        catch { XCTAssertEqual(error as? AudioOriginalFileTransferError, .alreadyClaimed) }
        await ticket.endReceive()
        await session.stop()
        do { _ = try await task.value; XCTFail("Stop completed") }
        catch let error as AudioPlaybackReceiveFailure { XCTAssertEqual(error.reason, .userStopped) }
    }

    func testOriginalFileStopWaitsForProducerAndCleansAnUnfinishedArtifact() async throws {
        let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
        let session = fixture.session(), finished = OSAllocatedUnfairLock(initialState: false)
        let task = Task { defer { finished.withLock { $0 = true } }; return try await session.run() }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.acceptedFile }
        let ticket = try await fixture.claimFile(), directory = try privateAudioDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let io = InboundFileTransferIOActor(maxOpenTransfers: 1), url = directory.appendingPathComponent("receiving.partial")
        let handle = try await io.createTemporaryFile(at: url, declaredFileSize: Int64(file.count))
        let artifact = AudioOriginalFileArtifact(io: io, handle: handle)
        // Stop between create returning and retaining cleanup must still retain the new file.
        await session.stop()
        try await ticket.retainForCleanup(artifact)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(finished.withLock { $0 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        await ticket.endReceive()
        do { _ = try await task.value; XCTFail("Stop was success") }
        catch let error as AudioPlaybackReceiveFailure { XCTAssertEqual(error.reason, .userStopped) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let count = await io.activeTransferCount(); XCTAssertEqual(count, 0)
        XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
    }

    func testOriginalFileStopAfterReaderPreparationStillInstallsItForCleanup() async throws {
        let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
        let session = fixture.session(), task = Task { try await session.run() }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.acceptedFile }
        let ticket = try await fixture.claimFile(), directory = try privateAudioDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let io = InboundFileTransferIOActor(maxOpenTransfers: 1), url = directory.appendingPathComponent("receiving.partial")
        let handle = try await io.createTemporaryFile(at: url, declaredFileSize: Int64(file.count))
        let artifact = AudioOriginalFileArtifact(io: io, handle: handle)
        try await ticket.retainForCleanup(artifact)
        _ = try await io.write(file, atOffset: 0, using: handle)
        let digest = try await io.closeAndDigest(using: handle)
        let reader = try await io.prepareVerifiedReadSession(using: handle, expectedSHA256: digest,
            validateLifetime: { try ticket.requireAuthorization() })
        await session.stop()
        try await artifact.installReader(reader)
        do { try await ticket.deliver(artifact); XCTFail("Stopped artifact delivered") }
        catch { XCTAssertTrue(error is AudioPlaybackApprovalError || error is AudioOriginalFileTransferError) }
        await ticket.endReceive()
        do { _ = try await task.value; XCTFail("Stop was success") }
        catch let error as AudioPlaybackReceiveFailure { XCTAssertEqual(error.reason, .userStopped) }
        do { _ = try await reader.read(offset: 0, length: 1); XCTFail("Prepared reader leaked") }
        catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .closed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOriginalFileUnresponsiveProducerRetainsResourcesForBoundedCleanupRetry() async throws {
        let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
        let session = fixture.session(fileReceiveCleanupTimeout: .milliseconds(25))
        let task = Task { try await session.run() }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.acceptedFile }
        let ticket = try await fixture.claimFile(), directory = try privateAudioDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let owned = try await prepareArtifact(file, ticket: ticket, directory: directory)
        await session.stop()
        do { _ = try await task.value; XCTFail("Unfinished producer was success") }
        catch let error as AudioPlaybackReceiveFailure { XCTAssertEqual(error.reason, .userStopped) }
        let pending = await session.outputCleanupStatus()
        XCTAssertEqual(pending.state, .pending)
        XCTAssertTrue(pending.diagnostics.contains("file_receive_cancel_pending"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.url.path))
        let retained = await owned.io.activeTransferCount(); XCTAssertEqual(retained, 1)
        do { _ = try await fixture.tryClaimFile(); XCTFail("Pending owner was removed") }
        catch { XCTAssertTrue(error is AudioOriginalFileTransferError) }
        await ticket.endReceive()
        let released = try await session.retryOutputCleanup()
        XCTAssertEqual(released.state, .released)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.url.path))
        let removed = try await fixture.tryClaimFile(); XCTAssertNil(removed)
    }

    func testOriginalFileRejectsPCMControlsWithoutOpeningNativeOutput() async throws {
        let fixture = try ReceiverFixture(file: wave(Data(count: 12)))
        let task = Task { try await fixture.session().run() }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.acceptedFile }
        try fixture.mailbox.receive(fixture.data(Data(count: 6)))
        do { _ = try await task.value; XCTFail("File stream accepted PCM data") }
        catch let error as AudioPlaybackReceiveFailure { XCTAssertEqual(error.reason, .protocolViolation) }
        XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
        let removed = try await fixture.tryClaimFile(); XCTAssertNil(removed)
    }

    func testOriginalFileCleanupPreservesReplacementAndRetainsOwnerUntilRetry() async throws {
        let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
        let session = fixture.session(), task = Task { try await session.run() }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.acceptedFile }
        let ticket = try await fixture.claimFile(), directory = try privateAudioDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let owned = try await prepareArtifact(file, ticket: ticket, directory: directory)
        let held = directory.appendingPathComponent("original.held")
        try FileManager.default.moveItem(at: owned.url, to: held)
        let replacement = Data("preserve this replacement".utf8)
        try replacement.write(to: owned.url)
        try await ticket.deliver(owned.artifact); await ticket.endReceive()
        do { _ = try await task.value; XCTFail("Failed cleanup reported successful playback session") }
        catch let error as AudioPlaybackReceiveFailure { XCTAssertEqual(error.reason, .outputLost) }
        let pending = await session.outputCleanupStatus(); XCTAssertEqual(pending.state, .pending)
        XCTAssertFalse(fixture.sent.withLock { $0.contains { if case .playbackComplete = $0.body { true } else { false } } },
            "File resource cleanup failure must not publish a successful playback completion")
        XCTAssertEqual(try Data(contentsOf: owned.url), replacement)
        fixture.fileTransfers.remove(ownerID: UUID())
        do { _ = try await fixture.tryClaimFile(); XCTFail("Pending owner disappeared") }
        catch { XCTAssertTrue(error is AudioOriginalFileTransferError) }
        try FileManager.default.removeItem(at: owned.url)
        try FileManager.default.moveItem(at: held, to: owned.url)
        let released = try await session.retryOutputCleanup()
        XCTAssertEqual(released.state, .released); XCTAssertFalse(released.diagnostics.isEmpty)
        let removed = try await fixture.tryClaimFile(); XCTAssertNil(removed)
        let count = await owned.io.activeTransferCount(); XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.url.path))
    }

    func testOriginalFileRealSocketAuthenticatesAndPlaysExactPrivateArtifact() async throws {
        let samples = Data((0..<65_538).map { UInt8(truncatingIfNeeded: $0) })
        let file = wave(samples), fixture = try ReceiverFixture(file: file)
        let session = fixture.session(), playback = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await playback.result }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.acceptedFile }
        let socket = try await fileSocket(fixture, lowercaseTransferID: true, canonicalLookupID: true)
        XCTAssertEqual(socket.resolvedPeerID, "id:" + fixture.channel.remoteIdentity.deviceID)
        let metadata = try socket.metadata(file: file)
        try await socket.sendMetadata(metadata)
        try await socket.approval(for: metadata)
        XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0, "File approval is not output readiness")
        try await socket.sendChunks(file)
        let receipt = try await socket.receipt()
        XCTAssertTrue(receipt.success)
        XCTAssertEqual(receipt.receivedBytes, Int64(file.count))
        XCTAssertEqual(receipt.fileHash, metadata.fileHash)
        try await socket.result()
        let played = try await playback.value
        XCTAssertEqual(played.format, fixture.format)
        XCTAssertEqual(played.sourceFrames, UInt64(samples.count / 6))
        XCTAssertEqual(fixture.output.state.withLock { $0.bytes }, samples)
        try await assertSocketFilesReleased(socket)
        XCTAssertTrue(socket.manager.activeTransfers.isEmpty)
        XCTAssertTrue(socket.manager.transferHistory.isEmpty, "Private audio must not become a downloadable history artifact")
        XCTAssertFalse(socket.manager.hasActiveTransferWork)
        XCTAssertTrue(socket.lifetime.isActive, "File completion must not retire the shared MAIN authority")
        let handles = await socket.sessions.activeSessionHandles()
        XCTAssertEqual(handles.count, 1)
        XCTAssertEqual(fixture.sent.withLock { $0.last?.body }, .playbackComplete(sourceFrames: UInt64(samples.count / 6), trailingPaddingFrames: 1))
    }

    func testOriginalFileProductListenerNormalClosePreservesVerifiedArtifact() async throws {
        let samples = Data((0..<65_538).map { UInt8(truncatingIfNeeded: $0) })
        let file = wave(samples), fixture = try ReceiverFixture(file: file)
        let session = fixture.session(), playback = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await playback.result }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.acceptedFile }
        let socket = try await fileSocket(fixture, useProductListener: true)
        let metadata = try socket.metadata(file: file)
        try await socket.sendMetadata(metadata); try await socket.approval(for: metadata)
        try await socket.sendChunks(file)
        let receipt = try await socket.receipt()
        XCTAssertTrue(receipt.success)
        XCTAssertEqual(receipt.receivedBytes, Int64(file.count))
        XCTAssertEqual(receipt.fileHash, metadata.fileHash)
        try await socket.result()
        let played = try await playback.value
        XCTAssertEqual(played.sourceFrames, UInt64(samples.count / 6))
        XCTAssertEqual(fixture.output.state.withLock { $0.bytes }, samples)
        try await assertSocketFilesReleased(socket)
        XCTAssertFalse(socket.manager.hasActiveTransferWork)
        XCTAssertTrue(socket.manager.transferHistory.isEmpty)
        XCTAssertTrue(socket.lifetime.isActive)
    }

    func testOriginalFileProductListenerUnexpectedCloseAndStopDoNotDeliver() async throws {
        for stopListener in [false, true] {
            let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
            let session = fixture.session(), playback = Task { try await session.run() }
            addTeardownBlock { await session.stop(); _ = await playback.result }
            try fixture.mailbox.receive(fixture.offer)
            try await wait { fixture.acceptedFile }
            let socket = try await fileSocket(fixture, useProductListener: true)
            let metadata = try socket.metadata(file: file)
            try await socket.sendMetadata(metadata); try await socket.approval(for: metadata)
            if stopListener { try socket.stopProductListener() }
            else { try socket.cancelAcceptedConnection() }
            try await socket.result()
            do { _ = try await playback.value; XCTFail("Interrupted file was delivered") }
            catch let failure as AudioPlaybackReceiveFailure {
                XCTAssertTrue([.userStopped, .sourceFailed].contains(failure.reason))
            }
            XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
            try await assertSocketFilesReleased(socket)
            XCTAssertFalse(socket.manager.hasActiveTransferWork)
            XCTAssertTrue(socket.lifetime.isActive)
        }
    }

    func testVerifiedOriginalFileFormatRemainsVisibleWhenStrictOutputPreparationFails() async throws {
        let files = [wave(Data(count: 12)), try AudioFlacTestFixture.resource("three-valid-frames", extension: "flac")]
        for file in files {
            let fixture = try ReceiverFixture(file: file)
            fixture.output.state.withLock { $0.prepareFailure = .formatMismatch }
            let service = fixture.service()
            addTeardownBlock { _ = await service.stop() }
            try service.start(); try fixture.deliver(fixture)
            try await wait { fixture.acceptedFile }
            let socket = try await fileSocket(fixture)
            let metadata = try socket.metadata(file: file)
            try await socket.sendMetadata(metadata); try await socket.approval(for: metadata)
            try await socket.sendChunks(file)
            let receipt = try await socket.receipt()
            XCTAssertTrue(receipt.success)
            XCTAssertEqual(receipt.fileHash, metadata.fileHash)
            try await socket.result()
            try await wait { service.phase == .failed }
            XCTAssertEqual(service.failureReason, .unsupportedOutput)
            XCTAssertEqual(service.outputIssue, .formatMismatch)
            XCTAssertEqual(service.sourceFormat, fixture.format, "Output rejection must preserve the parsed source PCM format")
            XCTAssertNil(service.completedSourceFrames)
            XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 1)
            XCTAssertEqual(fixture.output.state.withLock { $0.starts + $0.finishes }, 0)
            XCTAssertTrue(fixture.output.state.withLock { $0.bytes.isEmpty })
            XCTAssertEqual(fixture.output.state.withLock { $0.closes }, 1)
            XCTAssertEqual(fixture.sent.withLock { $0.map(\.body) }, [.accept(receiveWindowBytes: 0), .stop(.unsupportedOutput)])
            try await assertSocketFilesReleased(socket)
            XCTAssertTrue(socket.lifetime.isActive)
            let stopped = await service.stop(); XCTAssertTrue(stopped)
        }
    }

    func testLosslessFilesRealSocketValidateThenPlayExactSamplesAndCleanPrivateFiles() async throws {
        let flac = try AudioFlacTestFixture.resource("three-valid-frames", extension: "flac")
        let flacSamples = try AudioFlacTestFixture.resource("three-valid-frames", extension: "pcm")
        let alac = try AudioAlacTestFixture.resource("44100-2-s24", extension: "m4a")
        let alacSamples = try AudioAlacTestFixture.resource("44100-2-s24", extension: "pcm")
        // The controlled output uses four-frame periods: 96 source frames need no padding;
        // the 4,427-frame ALAC reference needs one trailing output frame, never a source frame.
        for (file, samples, padding) in [(flac, flacSamples, UInt32(0)), (alac, alacSamples, UInt32(1))] {
            let frames = UInt64(samples.count / 6)
            let fixture = try ReceiverFixture(file: file)
            let session = fixture.session(), playback = Task { try await session.run() }
            addTeardownBlock { await session.stop(); _ = await playback.result }
            try fixture.mailbox.receive(fixture.offer)
            try await wait { fixture.acceptedFile }
            let socket = try await fileSocket(fixture)
            let metadata = try socket.metadata(file: file)
            try await socket.sendMetadata(metadata); try await socket.approval(for: metadata)
            XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
            try await socket.sendChunks(file)
            let transfer = try await socket.receipt(); XCTAssertTrue(transfer.success)
            try await socket.result()
            let receipt = try await playback.value
            XCTAssertEqual(receipt.format, fixture.format)
            XCTAssertEqual(receipt.sourceFrames, frames)
            XCTAssertEqual(receipt.trailingPaddingFrames, padding)
            XCTAssertEqual(fixture.output.state.withLock { $0.bytes }, samples)
            XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 1)
            XCTAssertEqual(fixture.phases.withLock { $0 }, ["authorizing", "awaitingApproval", "receivingFile",
                "validatingFile", "preparing", "playing", "finishing"])
            XCTAssertEqual(fixture.sent.withLock { $0.map(\.body) }, [.accept(receiveWindowBytes: 0),
                .outputReady(fixture.format), .playbackComplete(sourceFrames: frames, trailingPaddingFrames: padding)])
            try await assertSocketFilesReleased(socket)
            XCTAssertTrue(socket.manager.transferHistory.isEmpty)
            XCTAssertTrue(socket.lifetime.isActive)
        }
    }

    func testNativeLosslessContentFailuresNeverPrepareOutput() async throws {
        var cases = try ["frame-crc-mismatch", "missing-silent-middle-must-not-recover", "valid-crc-wrong-pcm-md5"].map {
            (name: $0, file: try AudioFlacTestFixture.resource($0, extension: "flac"))
        }
        cases.append((name: "ALAC-invalid-final-packet", file: try AudioAlacTestFixture.withInvalidFinalPacket("44100-2-s24")))
        for (name, file) in cases {
            let fixture = try ReceiverFixture(file: file)
            let session = fixture.session(), playback = Task { try await session.run() }
            addTeardownBlock { await session.stop(); _ = await playback.result }
            try fixture.mailbox.receive(fixture.offer)
            try await wait { fixture.acceptedFile }
            let socket = try await fileSocket(fixture)
            let metadata = try socket.metadata(file: file)
            try await socket.sendMetadata(metadata); try await socket.approval(for: metadata)
            try await socket.sendChunks(file)
            let transfer = try await socket.receipt(); XCTAssertTrue(transfer.success, "Transport hash is valid even for invalid audio")
            try await socket.result()
            do { _ = try await playback.value; XCTFail("Invalid lossless file played: \(name)") }
            catch let failure as AudioPlaybackReceiveFailure {
                XCTAssertEqual(failure.reason, .contentMismatch)
                XCTAssertNil(failure.sourceFormat, "Invalid lossless file cannot publish validated source metadata")
                XCTAssertNil(failure.outputIssue)
            }
            XCTAssertEqual(fixture.output.state.withLock { $0.prepares + $0.starts + $0.finishes }, 0)
            XCTAssertTrue(fixture.output.state.withLock { $0.bytes.isEmpty })
            XCTAssertEqual(fixture.sent.withLock { $0.map(\.body) }, [.accept(receiveWindowBytes: 0), .stop(.contentMismatch)])
            try await assertSocketFilesReleased(socket)
            XCTAssertTrue(socket.lifetime.isActive)
        }
    }

    func testOriginalFileRealSocketRejectsLookupAliasAsAuthenticatedSender() async throws {
        let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
        let session = fixture.session(), playback = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await playback.result }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.acceptedFile }
        let socket = try await fileSocket(fixture, canonicalLookupID: true)
        let metadata = try socket.metadata(file: file, senderDeviceID: socket.resolvedPeerID)
        try await socket.sendMetadata(metadata)
        do { try await socket.result(); XCTFail("A lookup alias replaced the authenticated protocol identity") }
        catch { XCTAssertEqual(error as? AudioOriginalFileTransferError, .metadataMismatch) }
        XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
        XCTAssertTrue(socket.manager.activeTransfers.isEmpty)
        try await assertSocketFilesReleased(socket)
        XCTAssertTrue(socket.lifetime.isActive)
    }

    func testOriginalFileRealSocketRejectsMetadataMACBeforeClaimOrStorage() async throws {
        let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
        let session = fixture.session(), playback = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await playback.result }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.acceptedFile }
        let socket = try await fileSocket(fixture)
        try await socket.sendMetadata(socket.metadata(file: file, invalidMAC: true))
        let receipt = try await socket.receipt()
        XCTAssertFalse(receipt.success)
        do { try await socket.result(); XCTFail("Invalid metadata MAC was accepted") }
        catch { guard case FileTransferError.secureSessionRequired = error else { return XCTFail("Unexpected error: \(error)") } }
        XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
        try await assertSocketFilesReleased(socket)
        // Authenticated retry on a fresh file socket can still claim the unchanged one-stream grant.
        let retry = try await fileSocket(fixture)
        let valid = try retry.metadata(file: file)
        try await retry.sendMetadata(valid); try await retry.approval(for: valid)
        try await retry.sendChunks(file)
        let completed = try await retry.receipt(); XCTAssertTrue(completed.success)
        try await retry.result()
        _ = try await playback.value
        try await assertSocketFilesReleased(retry)
    }

    func testOriginalFileRealSocketRejectsValidMACWithWrongOfferCommitment() async throws {
        let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
        let session = fixture.session(), playback = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await playback.result }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.acceptedFile }
        let socket = try await fileSocket(fixture)
        try await socket.sendMetadata(socket.metadata(file: file, offeredHash: String(repeating: "0", count: 64)))
        do { try await socket.result(); XCTFail("File offer commitment was bypassed") }
        catch { XCTAssertEqual(error as? AudioOriginalFileTransferError, .metadataMismatch) }
        XCTAssertTrue(socket.manager.activeTransfers.isEmpty)
        try await assertSocketFilesReleased(socket)
        XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
        await session.stop()
        do { _ = try await playback.value; XCTFail("Stopped file stream completed") }
        catch let failure as AudioPlaybackReceiveFailure { XCTAssertEqual(failure.reason, .userStopped) }
    }

    func testOriginalFileRealSocketRejectsCorruptCiphertextAndCleansPartial() async throws {
        let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
        let session = fixture.session(), playback = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await playback.result }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.acceptedFile }
        let socket = try await fileSocket(fixture), metadata = try socket.metadata(file: file)
        try await socket.sendMetadata(metadata); try await socket.approval(for: metadata)
        try await socket.sendChunks(file, corruptTag: true, sendEOF: false)
        do { try await socket.result(); XCTFail("Corrupt encrypted chunk was accepted") }
        catch { guard case FileTransferError.invalidHeader = error else { return XCTFail("Unexpected error: \(error)") } }
        do { _ = try await playback.value; XCTFail("Corrupt file reported successful playback") }
        catch let failure as AudioPlaybackReceiveFailure { XCTAssertEqual(failure.reason, .sourceFailed) }
        XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
        try await assertSocketFilesReleased(socket)
        XCTAssertFalse(socket.manager.hasActiveTransferWork)
        XCTAssertTrue(socket.lifetime.isActive)
        XCTAssertFalse(fixture.sent.withLock { $0.contains { if case .playbackComplete = $0.body { true } else { false } } })
    }

    func testOriginalFileRealSocketRechecksRetiredClassicAuthorityBeforeWritingChunk() async throws {
        let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
        let session = fixture.session(), playback = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await playback.result }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.acceptedFile }
        let socket = try await fileSocket(fixture), metadata = try socket.metadata(file: file)
        try await socket.sendMetadata(metadata); try await socket.approval(for: metadata)
        socket.lifetime.invalidate()
        try await socket.sendChunks(file, sendEOF: false)
        do { try await socket.result(); XCTFail("Retired classic authority wrote an audio file") }
        catch { guard case FileTransferError.secureSessionRequired = error else { return XCTFail("Unexpected error: \(error)") } }
        do { _ = try await playback.value; XCTFail("Retired authority completed playback") }
        catch let failure as AudioPlaybackReceiveFailure { XCTAssertEqual(failure.reason, .sourceFailed) }
        XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
        try await assertSocketFilesReleased(socket)
        XCTAssertFalse(socket.manager.hasActiveTransferWork)
    }

    func testOriginalFileAuthorizationReportsExactPermissionAndCancellationBoundaries() async throws {
        let fixture = try ReceiverFixture(file: wave(Data(count: 12)))
        try fixture.mailbox.receive(fixture.offer)
        let request = try AudioPlaybackApprovalRequest(ownerID: fixture.channel.ownerID,
            offer: fixture.offer, membership: fixture.lease.evidence, outputEndpointUID: "test-output")
        let permission = try await fixture.approvals.requestApproval(request, isCurrent: { fixture.lease.isCurrent })
        let transfer = try AudioOriginalFileTransfer(channel: fixture.channel, offer: fixture.offer,
            membership: fixture.lease, permission: permission, endpoint: "test-output")
        XCTAssertNoThrow(try transfer.requireAuthorization())
        permission.revoke() // Stop's synchronous effect, before its async cancel reaches this producer.
        XCTAssertThrowsError(try transfer.requireAuthorization()) { error in
            XCTAssertEqual(error as? AudioPlaybackApprovalError, .rejected)
        }
        XCTAssertTrue(fixture.lease.isCurrent)
        XCTAssertNoThrow(try fixture.channel.requireCurrent())
        await transfer.cancel()
        XCTAssertThrowsError(try transfer.requireAuthorization()) { error in
            XCTAssertEqual(error as? AudioOriginalFileTransferError, .cancelled)
        }
        let cleanup = await transfer.close()
        XCTAssertEqual(cleanup.state, .released)
        XCTAssertTrue(cleanup.diagnostics.isEmpty)
        fixture.channel.close()
    }

    func testOriginalFileRealSocketStopAfterApprovalPreservesMainAuthority() async throws {
        let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
        let session = fixture.session(), playback = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await playback.result }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.acceptedFile }
        let socket = try await fileSocket(fixture), metadata = try socket.metadata(file: file)
        try await socket.sendMetadata(metadata); try await socket.approval(for: metadata)
        await session.stop()
        do { _ = try await playback.value; XCTFail("Stopped file reported success") }
        catch let failure as AudioPlaybackReceiveFailure { XCTAssertEqual(failure.reason, .userStopped) }
        do { try await socket.result(); XCTFail("Cancelled socket receive reported success") }
        catch {
            // Client receipt of approval does not prove the server has armed its
            // chunk read. Stop revokes permission before asynchronous I/O cancel;
            // the exact grant failures below are valid in that ordering too.
            XCTAssertTrue(error is CancellationError || error is FileTransferError || error is NWError ||
                (error as? AudioPlaybackApprovalError) == .rejected ||
                (error as? AudioOriginalFileTransferError) == .cancelled,
                "Unexpected socket stop error: \(String(reflecting: type(of: error))) \(error)")
        }
        try await assertSocketFilesReleased(socket)
        XCTAssertFalse(socket.manager.hasActiveTransferWork)
        XCTAssertTrue(socket.lifetime.isActive)
        XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
        let cleanup = await session.outputCleanupStatus()
        XCTAssertEqual(cleanup.state, .released)
    }

    func testOriginalFileRealSocketRejectsPathBearingMetadataBeforeStorage() async throws {
        let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
        let session = fixture.session(), playback = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await playback.result }
        try fixture.mailbox.receive(fixture.offer)
        try await wait { fixture.acceptedFile }
        let socket = try await fileSocket(fixture)
        try await socket.sendMetadata(socket.metadata(file: file, fileName: "../../original.wav"))
        do { try await socket.result(); XCTFail("Path-bearing metadata was accepted") }
        catch { guard case FileTransferError.invalidHeader = error else { return XCTFail("Unexpected error: \(error)") } }
        try await assertSocketFilesReleased(socket)
        XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
        await session.stop()
        do { _ = try await playback.value; XCTFail("Stopped file stream completed") }
        catch let failure as AudioPlaybackReceiveFailure { XCTAssertEqual(failure.reason, .userStopped) }
    }

    func testDedicatedAudioFileSocketUsesExactGrantAndExistingFileProtocol() async throws {
        let file = wave(Data([0, 1, 2, 3, 4, 5])), fixture = try ReceiverFixture(file: file)
        let transfer = try await dedicatedFileGrant(fixture, register: true)
        let socket = try await dedicatedFileSocket(fixture, required: transfer)
        let metadata = try socket.metadata(file: file)
        try await socket.sendMetadata(metadata); try await socket.approval(for: metadata)
        try await socket.sendChunks(file)
        let receipt = try await socket.receipt()
        XCTAssertTrue(receipt.success); XCTAssertEqual(receipt.receivedBytes, Int64(file.count))
        try await socket.result()
        let artifact = try await transfer.waitForArtifact()
        let reader = try await artifact.verifiedReader()
        let received = try await reader.read(offset: 0, length: file.count)
        XCTAssertEqual(received, file)
        let cleanup = await transfer.close()
        XCTAssertEqual(cleanup.state, .released)
        try await assertSocketFilesReleased(socket)
        XCTAssertTrue(socket.manager.transferHistory.isEmpty)
        XCTAssertTrue(socket.lifetime.isActive)
    }

    func testUSBReturnReceiverUsesExactChannelAndClosesNativeFileStreamBeforeCompletion() async throws {
        let file = wave(Data(count: 18))
        let native = OSAllocatedUnfairLock<NWConnection?>(initialState: nil)
        let ports = OSAllocatedUnfairLock<[UInt16]>(initialState: [])
        let fixture = try ReceiverFixture(controlTransport: .usb, file: file, usbFileOpener: { port in
            ports.withLock { $0.append(port) }
            guard let connection = native.withLock({ $0 }) else { throw AudioOriginalFileUSBError.unavailable }
            return connection
        })
        let transfer = try await dedicatedFileGrant(fixture, register: true)
        let socket = try await dedicatedFileSocket(fixture, required: transfer, startReceiving: false)
        let server = try XCTUnwrap(socket.server)
        native.withLock { $0 = server }
        let manager = socket.manager
        let receiver = AudioOriginalFileUSBReceiver(channel: fixture.channel, transfer: transfer, port: 49_153,
            receive: { connection, context, required in
                try await manager.receiveOriginalAudioFile(from: connection, peerContext: context, requiring: required)
            })
        addTeardownBlock { let result = await receiver.close(); XCTAssertEqual(result.state, .released) }
        try await receiver.start()
        let metadata = try socket.metadata(file: file)
        try await socket.sendMetadata(metadata); try await socket.approval(for: metadata)
        try await socket.sendChunks(file)
        let receipt = try await socket.receipt(); XCTAssertTrue(receipt.success)
        socket.client?.cancel() // Real iOS sender closes only after authenticating this receipt.
        try await receiver.waitForCompletion()
        XCTAssertEqual(ports.withLock { $0 }, [49_153])
        if case .cancelled? = socket.server?.state {} else { XCTFail("Native file close was not observed") }
        let artifact = try await transfer.waitForArtifact(), reader = try await artifact.verifiedReader()
        let received = try await reader.read(offset: 0, length: file.count)
        XCTAssertEqual(received, file)
        let closed = await transfer.close(); XCTAssertEqual(closed.state, .released)
        try await assertSocketFilesReleased(socket)
        XCTAssertTrue(socket.lifetime.isActive)
    }

    func testUSBOriginalFileGrantCannotBeClaimedThroughGeneralNetworkFileListener() async throws {
        let file = wave(Data(count: 12))
        let fixture = try ReceiverFixture(controlTransport: .usb, file: file, usbFileOpener: { _ in
            XCTFail("Rejected network file must not initiate a USB dial")
            throw AudioOriginalFileUSBError.unavailable
        })
        let transfer = try await dedicatedFileGrant(fixture, register: true)
        let socket = try await fileSocket(fixture)
        try await socket.sendMetadata(socket.metadata(file: file))
        do { try await socket.result(); XCTFail("USB-selected file silently used the general network listener") }
        catch { XCTAssertEqual(error as? AudioOriginalFileTransferError, .metadataMismatch) }
        let claimed = await transfer.hasClaimedTransfer; XCTAssertFalse(claimed)
        try await assertSocketFilesReleased(socket)
    }

    func testDedicatedAudioFileSocketRejectsReplacementGrantWithSameOwnerAndTransferID() async throws {
        let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
        let expected = try await dedicatedFileGrant(fixture, register: false)
        let replacement = try await dedicatedFileGrant(fixture, register: true)
        XCTAssertEqual(expected.ownerID, replacement.ownerID)
        XCTAssertEqual(expected.transferID, replacement.transferID)
        let socket = try await dedicatedFileSocket(fixture, required: expected)
        try await socket.sendMetadata(socket.metadata(file: file))
        do { try await socket.result(); XCTFail("A replacement grant consumed an old return stream") }
        catch { XCTAssertEqual(error as? AudioOriginalFileTransferError, .unavailable) }
        let claimed = await replacement.hasClaimedTransfer
        XCTAssertFalse(claimed)
        try await assertSocketFilesReleased(socket)
        XCTAssertTrue(socket.lifetime.isActive)
    }

    func testDedicatedAudioFileSocketRejectsMissingGrantWithoutGeneralFileFallback() async throws {
        let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
        let transfer = try await dedicatedFileGrant(fixture, register: true)
        fixture.fileTransfers.remove(ownerID: transfer.ownerID)
        let socket = try await dedicatedFileSocket(fixture, required: transfer)
        try await socket.sendMetadata(socket.metadata(file: file))
        do { try await socket.result(); XCTFail("A missing playback grant entered general reception") }
        catch { XCTAssertEqual(error as? AudioOriginalFileTransferError, .unavailable) }
        let claimed = await transfer.hasClaimedTransfer
        XCTAssertFalse(claimed)
        XCTAssertTrue(socket.manager.activeTransfers.isEmpty)
        try await assertSocketFilesReleased(socket)
    }

    func testDedicatedAudioFileSocketRejectsDifferentAuthenticatedTransferID() async throws {
        let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
        let transfer = try await dedicatedFileGrant(fixture, register: true)
        let socket = try await dedicatedFileSocket(fixture, required: transfer, transferID: UUID().uuidString)
        try await socket.sendMetadata(socket.metadata(file: file))
        do { try await socket.result(); XCTFail("A different authenticated file replaced the audio offer") }
        catch { XCTAssertEqual(error as? AudioOriginalFileTransferError, .metadataMismatch) }
        let claimed = await transfer.hasClaimedTransfer
        XCTAssertFalse(claimed)
        try await assertSocketFilesReleased(socket)
    }

    func testDedicatedAudioFileSocketRequiresAuthenticatedFileApprovalProtocol() async throws {
        let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
        let transfer = try await dedicatedFileGrant(fixture, register: true)
        let socket = try await dedicatedFileSocket(fixture, required: transfer)
        try await socket.sendMetadata(socket.metadata(file: file, requiresApproval: false))
        do { try await socket.result(); XCTFail("The reverse stream omitted receiver authentication before chunks") }
        catch { guard case FileTransferError.secureSessionRequired = error else { return XCTFail("Unexpected error: \(error)") } }
        let claimed = await transfer.hasClaimedTransfer
        XCTAssertFalse(claimed)
        try await assertSocketFilesReleased(socket)
    }

    func testDedicatedAudioFileSocketRejectsAuthenticatedResumeBeforeResumeHandling() async throws {
        let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
        let transfer = try await dedicatedFileGrant(fixture, register: true)
        let socket = try await dedicatedFileSocket(fixture, required: transfer)
        try await socket.sendResumeRequest()
        do { try await socket.result(); XCTFail("A one-off audio return stream entered general resume handling") }
        catch { guard case FileTransferError.invalidTransferState = error else { return XCTFail("Unexpected error: \(error)") } }
        let claimed = await transfer.hasClaimedTransfer
        XCTAssertFalse(claimed)
        try await assertSocketFilesReleased(socket)
    }

    func testEpochV2OriginalFileRunsThroughNativeOwnersAndRetainsSiblingControl() async throws {
        let file = wave(Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 * 31) }))
        let configuration = USBHostMultiplexConnection.Configuration(linkProfile: .epochV2)
        let usb = try USBMultiplexFixture(configuration: configuration)
        addTeardownBlock { try await usb.close() }
        try await usb.start()
        let opening = Task { try await usb.b.openStream(priority: .bulk) }
        let hostStream = try await usb.a.acceptStream(priority: .bulk)
        let phoneStream = try await opening.value
        let sender = try USBClassicFileTransferByteChannel(connection: usb.b, stream: phoneStream,
            requireParentCurrent: {}, requireParentWriteAuthorization: {})
        let receiver = try USBClassicFileTransferByteChannel(connection: usb.a, stream: hostStream,
            requireParentCurrent: {}, requireParentWriteAuthorization: {})
        let fixture = try ReceiverFixture(controlTransport: .usb, file: file, logicalFileAcceptor: { receiver })
        let transfer = try await dedicatedFileGrant(fixture, register: true)
        let wire = try await dedicatedFileSocket(fixture, required: transfer, startReceiving: false, byteChannel: sender)
        let manager = wire.manager
        let receiveOwner = AudioOriginalFileUSBReceiver(channel: fixture.channel, transfer: transfer,
            receive: { bytes, context, required in
                try await manager.receiveOriginalAudioFile(from: bytes, peerContext: context, requiring: required)
            })
        addTeardownBlock { let cleanup = await receiveOwner.close(); XCTAssertEqual(cleanup.state, .released) }
        try await receiveOwner.start()
        let metadata = try wire.metadata(file: file)
        try await wire.sendMetadata(metadata); try await wire.approval(for: metadata)
        try await wire.sendChunks(file)
        let receipt = try await wire.receipt(); XCTAssertTrue(receipt.success)
        try await receiveOwner.waitForCompletion()
        let artifact = try await transfer.waitForArtifact(), reader = try await artifact.verifiedReader()
        let received = try await reader.read(offset: 0, length: file.count)
        XCTAssertEqual(received, file)
        try await usb.sibling()
        XCTAssertNil(usb.a.terminalFailure); XCTAssertNil(usb.b.terminalFailure)
        let cleanup = await transfer.close(); XCTAssertEqual(cleanup.state, .released)
        try await assertSocketFilesReleased(wire)
    }

    func testEpochV2ApprovedFileReceiverDeliversExactWaveFlacAndAlacSamplesThroughPlaybackConsumer() async throws {
        let samples = try AudioFlacTestFixture.resource("three-valid-frames", extension: "pcm")
        let flac = try AudioFlacTestFixture.resource("three-valid-frames", extension: "flac")
        let alac = try AudioAlacTestFixture.resource("44100-2-s24", extension: "m4a")
        let alacSamples = try AudioAlacTestFixture.resource("44100-2-s24", extension: "pcm")
        for (file, expected, padding) in [(wave(samples), samples, UInt32(0)), (flac, samples, UInt32(0)),
                                          (alac, alacSamples, UInt32(1))] {
            let frames = UInt64(expected.count / 6)
            let usb = try USBMultiplexFixture(configuration: .init(linkProfile: .epochV2))
            addTeardownBlock { try await usb.close() }
            try await usb.start()
            let opening = Task { try await usb.b.openStream(priority: .bulk) }
            let host = try await usb.a.acceptStream(priority: .bulk), peer = try await opening.value
            let sender = try USBClassicFileTransferByteChannel(connection: usb.b, stream: peer,
                requireParentCurrent: {}, requireParentWriteAuthorization: {})
            let receiver = try USBClassicFileTransferByteChannel(connection: usb.a, stream: host,
                requireParentCurrent: {}, requireParentWriteAuthorization: {})
            let fixture = try ReceiverFixture(controlTransport: .usb, file: file, logicalFileAcceptor: { receiver })
            let wire = try AudioFileSocketFixture(transferID: fixture.fileTransferID.uuidString,
                peerID: fixture.channel.remoteIdentity.deviceID, keys: fixture.fileKeys, audioFiles: fixture.fileTransfers)
            try await wire.useByteChannel(sender, keys: fixture.fileKeys)
            let manager = wire.manager
            let session = fixture.session(receiveOriginalFile: { bytes, context, required in
                try await manager.receiveOriginalAudioFile(from: bytes, peerContext: context, requiring: required)
            })
            let playback = Task { try await session.run() }
            addTeardownBlock { await session.stop(); _ = await playback.result; try await wire.shutdown() }
            try fixture.mailbox.receive(fixture.offer)
            try await wait { fixture.acceptedFile }
            let metadata = try wire.metadata(file: file)
            try await wire.sendMetadata(metadata); try await wire.approval(for: metadata)
            XCTAssertEqual(fixture.output.state.withLock { $0.prepares }, 0)
            try await wire.sendChunks(file)
            let receipt = try await wire.receipt(); XCTAssertTrue(receipt.success)
            let played = try await playback.value
            XCTAssertEqual(played.format, fixture.format); XCTAssertEqual(played.sourceFrames, frames)
            XCTAssertEqual(played.trailingPaddingFrames, padding)
            XCTAssertEqual(fixture.output.state.withLock { $0.bytes }, expected)
            XCTAssertEqual(fixture.sent.withLock { $0.map(\.body) }, [.accept(receiveWindowBytes: 0),
                .outputReady(fixture.format), .playbackComplete(sourceFrames: frames, trailingPaddingFrames: padding)])
            try await assertSocketFilesReleased(wire)
            try await usb.sibling()
        }
    }

    func testLogicalFileAdapterRejectsForeignCarrierAndRawProfile() async throws {
        for profile in [USBHostMultiplexConnection.LinkProfile.rawYamuxV1, .epochV2] {
            let configuration = USBHostMultiplexConnection.Configuration(linkProfile: profile)
            let usb = try USBMultiplexFixture(configuration: configuration)
            try await usb.start()
            let (left, right) = try await usb.open()
            if profile == .rawYamuxV1 {
                XCTAssertThrowsError(try USBClassicFileTransferByteChannel(connection: usb.a, stream: left,
                    requireParentCurrent: {}, requireParentWriteAuthorization: {})) {
                    XCTAssertEqual($0 as? ClassicFileTransferByteError, .invalidCarrier)
                }
            }
            XCTAssertThrowsError(try USBClassicFileTransferByteChannel(connection: usb.a, stream: right,
                requireParentCurrent: {}, requireParentWriteAuthorization: {})) {
                XCTAssertEqual($0 as? ClassicFileTransferByteError, .invalidCarrier)
            }
            XCTAssertFalse(left.isClosed); XCTAssertFalse(right.isClosed)
            try await left.closeAndAwait(); try await right.closeAndAwait(); try await usb.close()
        }
    }

    func testLogicalFileParentWriteGrantIsRecheckedBeforeNativePayload() async throws {
        let configuration = USBHostMultiplexConnection.Configuration(linkProfile: .epochV2)
        let usb = try USBMultiplexFixture(configuration: configuration)
        addTeardownBlock { try await usb.close() }
        try await usb.start()
        let (left, right) = try await usb.open()
        let sender = try USBClassicFileTransferByteChannel(connection: usb.a, stream: left,
            requireParentCurrent: {}, requireParentWriteAuthorization: { throw AudioMembershipLeaseFailure.revoked })
        do { try await sender.send(Data([1, 2, 3]), requireEffectAuthorization: {}); XCTFail("Expired grant submitted file bytes") }
        catch { XCTAssertEqual(error as? AudioMembershipLeaseFailure, .revoked) }
        do { _ = try await right.readBytes(maximumBytes: 3, timeout: .seconds(2)); XCTFail("Peer received unauthorized file bytes") }
        catch { XCTAssertEqual(error as? USBLogicalStreamError, .resetByPeer) }
        try await sender.closeAndAwait(timeout: .seconds(2)); try await right.closeAndAwait()
    }

    func testLogicalFileCompletionTimesOutWithoutPeerFin() async throws {
        try await assertLogicalCompletionFailure(.missingFin)
    }

    func testLogicalFileCompletionRejectsTrailingBytes() async throws {
        try await assertLogicalCompletionFailure(.trailingBytes)
    }

    func testLogicalFileCompletionCancellationReleasesOnlyFileStream() async throws {
        try await assertLogicalCompletionFailure(.cancelled)
    }

    private enum LogicalCompletionFailure: Equatable { case missingFin, trailingBytes, cancelled }

    private func assertLogicalCompletionFailure(_ mode: LogicalCompletionFailure) async throws {
        let usb = try USBMultiplexFixture(configuration: .init(linkProfile: .epochV2))
        addTeardownBlock { try await usb.close() }
        try await usb.start()
        let (left, right) = try await usb.open()
        let bytes = try USBClassicFileTransferByteChannel(connection: usb.a, stream: left,
            requireParentCurrent: {}, requireParentWriteAuthorization: {})
        if mode == .trailingBytes {
            try await right.writeBytes(Data([42]), timeout: .seconds(2), requireEffectAuthorization: {})
        }
        let timeout: Duration = mode == .missingFin ? .milliseconds(400) : .seconds(5)
        let completion = Task { try await bytes.completeAndClose(timeout: timeout) }
        addTeardownBlock { completion.cancel(); _ = await completion.result; try await bytes.closeAndAwait(timeout: .seconds(2)) }
        if mode != .trailingBytes {
            guard case .end = try await right.readBytes(maximumBytes: 1, timeout: .seconds(2)) else {
                return XCTFail("Completion sent unexpected application bytes")
            }
            if mode == .cancelled { completion.cancel() }
        }
        do { try await completion.value; XCTFail("Unsettled file stream completed") }
        catch {
            switch mode {
            case .missingFin: XCTAssertEqual(error as? USBHostMultiplexError, .timedOut)
            case .trailingBytes:
                if case FileTransferError.invalidHeader = error {} else { XCTFail("Unexpected trailing-byte failure: \(error)") }
            case .cancelled: XCTAssertTrue(error is CancellationError, "Unexpected cancellation failure: \(error)")
            }
        }
        try await bytes.closeAndAwait(timeout: .seconds(2)); try await right.closeAndAwait()
        try await usb.sibling()
        XCTAssertNil(usb.a.terminalFailure); XCTAssertNil(usb.b.terminalFailure)
    }

    func testNonIPOriginalFileUsesExistingCryptoAndPrivateArtifactFlow() async throws {
        let file = wave(Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0) }))
        let fixture = try ReceiverFixture(file: file)
        let transfer = try await dedicatedFileGrant(fixture, register: true)
        let socket = try await dedicatedFileSocket(fixture, required: transfer, startReceiving: false)
        let bytes = NonIPClassicByteFixture(try XCTUnwrap(socket.server))
        let receiving = Task {
            try await socket.manager.receiveOriginalAudioFile(from: bytes,
                peerContext: .init(declaredSenderDeviceId: fixture.channel.remoteIdentity.deviceID,
                    endpointHostOrIP: nil, peerLabel: nil, transferId: fixture.fileTransferID.uuidString), requiring: transfer)
        }
        addTeardownBlock { bytes.cancel(); receiving.cancel(); _ = await receiving.result }
        let metadata = try socket.metadata(file: file)
        try await socket.sendMetadata(metadata); try await socket.approval(for: metadata)
        try await socket.sendChunks(file)
        let receipt = try await socket.receipt(); XCTAssertTrue(receipt.success)
        try await receiving.value
        let artifact = try await transfer.waitForArtifact(), reader = try await artifact.verifiedReader()
        let received = try await reader.read(offset: 0, length: file.count)
        XCTAssertEqual(received, file)
        XCTAssertTrue(bytes.cleanupObserved.withLock { $0 })
        XCTAssertTrue(socket.manager.transferHistory.isEmpty)
        let cleanup = await transfer.close(); XCTAssertEqual(cleanup.state, .released)
        try await assertSocketFilesReleased(socket)
    }

    func testNonIPOriginalFileRejectsResumeWithoutClaimingGrant() async throws {
        let fixture = try ReceiverFixture(file: wave(Data(count: 12)))
        let transfer = try await dedicatedFileGrant(fixture, register: true)
        let socket = try await dedicatedFileSocket(fixture, required: transfer, startReceiving: false)
        let bytes = NonIPClassicByteFixture(try XCTUnwrap(socket.server))
        let receiving = Task {
            try await socket.manager.receiveOriginalAudioFile(from: bytes,
                peerContext: .init(declaredSenderDeviceId: fixture.channel.remoteIdentity.deviceID,
                    endpointHostOrIP: nil, peerLabel: nil, transferId: fixture.fileTransferID.uuidString), requiring: transfer)
        }
        addTeardownBlock { bytes.cancel(); receiving.cancel(); _ = await receiving.result }
        try await socket.sendResumeRequest()
        do { try await receiving.value; XCTFail("Non-IP audio entered general resume") }
        catch { guard case FileTransferError.invalidTransferState = error else { return XCTFail("Unexpected error: \(error)") } }
        let claimed = await transfer.hasClaimedTransfer; XCTAssertFalse(claimed)
        try await assertSocketFilesReleased(socket)
    }

    func testNonIPOriginalFileDoesNotDeliverArtifactBeforeConfirmedCleanup() async throws {
        let file = wave(Data(count: 18)), fixture = try ReceiverFixture(file: file)
        let transfer = try await dedicatedFileGrant(fixture, register: true)
        let socket = try await dedicatedFileSocket(fixture, required: transfer, startReceiving: false)
        let bytes = NonIPClassicByteFixture(try XCTUnwrap(socket.server))
        bytes.failCleanup.withLock { $0 = true }
        let receiving = Task {
            try await socket.manager.receiveOriginalAudioFile(from: bytes,
                peerContext: .init(declaredSenderDeviceId: fixture.channel.remoteIdentity.deviceID,
                    endpointHostOrIP: nil, peerLabel: nil, transferId: fixture.fileTransferID.uuidString), requiring: transfer)
        }
        addTeardownBlock { bytes.cancel(); receiving.cancel(); _ = await receiving.result }
        let metadata = try socket.metadata(file: file)
        try await socket.sendMetadata(metadata); try await socket.approval(for: metadata)
        try await socket.sendChunks(file)
        let receipt = try await socket.receipt(); XCTAssertTrue(receipt.success)
        do { try await receiving.value; XCTFail("Unconfirmed close reported successful reception") }
        catch { XCTAssertEqual(error as? ClassicFileTransferByteError, .cleanupUnconfirmed) }
        do { _ = try await transfer.waitForArtifact(); XCTFail("Unconfirmed carrier published artifact") }
        catch { XCTAssertEqual(error as? ClassicFileTransferByteError, .cleanupUnconfirmed) }
        XCTAssertFalse(bytes.cleanupObserved.withLock { $0 })
        bytes.failCleanup.withLock { $0 = false }
        try await bytes.closeAndAwait(timeout: .seconds(2))
        XCTAssertTrue(bytes.cleanupObserved.withLock { $0 })
        let cleanup = await transfer.close(); XCTAssertEqual(cleanup.state, .released)
        try await assertSocketFilesReleased(socket)
    }

    func testNonIPOriginalFileRechecksPlaybackGrantAtApprovalWrite() async throws {
        let file = wave(Data(count: 12)), fixture = try ReceiverFixture(file: file)
        let transfer = try await dedicatedFileGrant(fixture, register: true)
        let socket = try await dedicatedFileSocket(fixture, required: transfer, startReceiving: false)
        let lease = fixture.lease
        let bytes = NonIPClassicByteFixture(try XCTUnwrap(socket.server), beforeSend: { lease.revoke() })
        let receiving = Task {
            try await socket.manager.receiveOriginalAudioFile(from: bytes,
                peerContext: .init(declaredSenderDeviceId: fixture.channel.remoteIdentity.deviceID,
                    endpointHostOrIP: nil, peerLabel: nil, transferId: fixture.fileTransferID.uuidString), requiring: transfer)
        }
        addTeardownBlock { bytes.cancel(); receiving.cancel(); _ = await receiving.result }
        try await socket.sendMetadata(socket.metadata(file: file))
        do { try await receiving.value; XCTFail("Revoked playback grant sent file approval") }
        catch { XCTAssertEqual(error as? AudioMembershipLeaseFailure, .revoked) }
        let client = try XCTUnwrap(socket.client)
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(3)) }
            catch is CancellationError { return }
            catch { XCTFail("Unexpected watchdog error: \(error)"); return }
            timedOut.withLock { $0 = true }; client.cancel()
        }
        defer { watchdog.cancel() }
        let observed: Int = await withCheckedContinuation { continuation in
            client.receive(minimumIncompleteLength: 1, maximumLength: 8) { data, _, _, _ in
                continuation.resume(returning: data?.count ?? 0)
            }
        }
        XCTAssertEqual(observed, 0)
        XCTAssertFalse(timedOut.withLock { $0 })
        let cleanup = await transfer.close(); XCTAssertEqual(cleanup.state, .released)
        try await assertSocketFilesReleased(socket)
    }

    private func dedicatedFileGrant(_ fixture: ReceiverFixture, register: Bool) async throws -> AudioOriginalFileTransfer {
        let request = try AudioPlaybackApprovalRequest(ownerID: fixture.channel.ownerID, offer: fixture.offer,
            membership: fixture.lease.evidence, outputEndpointUID: "test-output")
        let lease = fixture.lease
        let permission = try await fixture.approvals.requestApproval(request, isCurrent: { lease.isCurrent })
        let transfer = try AudioOriginalFileTransfer(channel: fixture.channel, offer: fixture.offer,
            membership: lease, permission: permission, endpoint: "test-output")
        if register { try fixture.fileTransfers.register(transfer) }
        addTeardownBlock {
            let cleanup = await transfer.close()
            XCTAssertEqual(cleanup.state, .released)
            await MainActor.run { fixture.fileTransfers.remove(ownerID: transfer.ownerID) }
        }
        return transfer
    }

    private func dedicatedFileSocket(_ fixture: ReceiverFixture, required: AudioOriginalFileTransfer,
                                     transferID: String? = nil, startReceiving: Bool = true,
                                     byteChannel: (any ClassicFileTransferByteChannel)? = nil) async throws -> AudioFileSocketFixture {
        let socket = try AudioFileSocketFixture(transferID: transferID ?? fixture.fileTransferID.uuidString,
            peerID: fixture.channel.remoteIdentity.deviceID, keys: fixture.fileKeys, audioFiles: fixture.fileTransfers)
        addTeardownBlock {
            await socket.close()
            let cleanup = await required.close()
            guard cleanup.state == .released else {
                XCTFail("Private audio cleanup must precede removal of the fixture directory: \(cleanup.diagnostics)")
                return
            }
            try await socket.shutdown()
        }
        if let byteChannel { try await socket.useByteChannel(byteChannel, keys: fixture.fileKeys) }
        else { try await socket.open(keys: fixture.fileKeys, purpose: .originalAudio(required), startReceiving: startReceiving) }
        return socket
    }

    private func assertSocketFilesReleased(_ socket: AudioFileSocketFixture) async throws {
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: socket.directory.path).isEmpty)
        let activeIO = await InboundFileTransferIOActor.shared.activeTransferCount()
        XCTAssertEqual(activeIO, 0, "Deleting the path must also release the actual inbound IO owner")
    }

    private func fileSocket(_ fixture: ReceiverFixture, lowercaseTransferID: Bool = false,
                            canonicalLookupID: Bool = false,
                            useProductListener: Bool = false) async throws -> AudioFileSocketFixture {
        let raw = fixture.fileTransferID.uuidString
        let socket = try AudioFileSocketFixture(transferID: lowercaseTransferID ? raw.lowercased() : raw,
            peerID: fixture.channel.remoteIdentity.deviceID, keys: fixture.fileKeys, audioFiles: fixture.fileTransfers,
            canonicalLookupID: canonicalLookupID, useProductListener: useProductListener)
        addTeardownBlock { try await socket.shutdown() }
        try await socket.open(keys: fixture.fileKeys)
        return socket
    }

    private func privateAudioDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-receive-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func wave(_ samples: Data) -> Data {
        func u16(_ n: UInt16) -> Data { Data([UInt8(truncatingIfNeeded: n), UInt8(truncatingIfNeeded: n >> 8)]) }
        func u32(_ n: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) }
        var format = Data()
        for part in [u16(0xfffe), u16(2), u32(44_100), u32(264_600), u16(6), u16(24),
                     u16(22), u16(24), u32(3), u32(1)] { format.append(part) }
        format.append(contentsOf: [0,0,0x10,0,0x80,0,0,0xaa,0,0x38,0x9b,0x71])
        var chunks = Data("fmt ".utf8)
        for part in [u32(40), format, Data("data".utf8), u32(UInt32(samples.count)), samples] { chunks.append(part) }
        var result = Data("RIFF".utf8)
        for part in [u32(UInt32(chunks.count + 4)), Data("WAVE".utf8), chunks] { result.append(part) }
        return result
    }

    private func prepareArtifact(_ file: Data, ticket: AudioOriginalFileTransfer, directory: URL) async throws
        -> (artifact: AudioOriginalFileArtifact, reader: PreparedOutboundFileReadSession, io: InboundFileTransferIOActor, url: URL) {
        let io = InboundFileTransferIOActor(maxOpenTransfers: 1)
        let staging = directory.appendingPathComponent("receiving.partial")
        let handle = try await io.createTemporaryFile(at: staging, declaredFileSize: Int64(file.count))
        let artifact = AudioOriginalFileArtifact(io: io, handle: handle)
        try await ticket.retainForCleanup(artifact)
        _ = try await io.write(file, atOffset: 0, using: handle)
        let digest = try await io.closeAndDigest(using: handle)
        let reader = try await io.prepareVerifiedReadSession(using: handle, expectedSHA256: digest,
            validateLifetime: { try ticket.requireAuthorization() })
        try await artifact.installReader(reader)
        let url = try await io.commit(using: handle, destinationDirectory: directory, fileName: "music.verified")
        return (artifact, reader, io, url)
    }

    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Condition did not arrive"); throw TestFailure.timeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private enum TestFailure: Error { case timeout }

@MainActor
private final class PlaybackRenewalGate {
    private var continuation: CheckedContinuation<Void, Never>?
    let cancelled = OSAllocatedUnfairLock(initialState: false)
    private(set) var started = false
    func waitForRelease() async {
        let cancelled = cancelled
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0; started = true }
        } onCancel: { cancelled.withLock { $0 = true } }
    }
    func releaseIfWaiting() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class ReceiverFixture {
    let id = UUID()
    let format: AudioStreamingPCMFormat
    let mailbox = P2PAudioMailbox()
    let sent = OSAllocatedUnfairLock<[AudioStreamingMessage]>(initialState: [])
    let progressSends = OSAllocatedUnfairLock<[(frames: UInt64, at: ContinuousClock.Instant)]>(initialState: [])
    let beforeSend = OSAllocatedUnfairLock<(@Sendable (AudioStreamingMessage) async throws -> Void)?>(initialState: nil)
    let responses = OSAllocatedUnfairLock<[AudioStreamingMessage]>(initialState: [])
    let phases = OSAllocatedUnfairLock<[String]>(initialState: [])
    let failStopDelivery = OSAllocatedUnfairLock(initialState: false)
    let output: ReceiverOutput
    let approvals: AudioPlaybackApprovalService
    let lease: AudioMembershipLease
    let channel: P2PAudioChannel
    let fileTransfers = AudioOriginalFileTransferRegistry()
    let fileTransferID: UUID
    let fileData: Data?
    let fileKeys: SessionKeys
    private var subscription: AnyCancellable?
    private var incoming: (@Sendable (P2PAudioChannel) -> Void)?
    var failOutputSelection = false
    var failAccountLookup = false
    var offer: AudioStreamingMessage {
        if let fileData { return .init(streamID: id, body: .fileOffer(transferID: fileTransferID,
            length: UInt64(fileData.count), sha256: Data(SHA256.hash(data: fileData)))) }
        return .init(streamID: id, body: .captureOffer(format))
    }
    var acceptedFile: Bool { sent.withLock { $0.contains { $0.body == .accept(receiveWindowBytes: 0) } } }
    var outputProgressMessages: [UInt64] { progressSends.withLock { $0.map(\.frames) } }
    var respondOnReady: [AudioStreamingMessage] {
        get { responses.withLock { $0 } }
        set { responses.withLock { $0 = newValue } }
    }
    init(controlTransport: P2PConnection.ControlTransport = .network,
         autoApprove: Bool = true, file: Data? = nil, renewalDue: Bool = false,
         usbFileOpener: (@Sendable (UInt16) async throws -> NWConnection)? = nil,
         logicalFileAcceptor: (@Sendable () async throws -> any ClassicFileTransferByteChannel)? = nil,
         transferID: UUID = UUID(), outputCapacityBytes: Int = 96, peerCapabilities: Set<String> = []) throws {
        fileTransferID = transferID
        output = ReceiverOutput(capacityBytes: outputCapacityBytes)
        fileData = file
        fileKeys = SessionKeys(sendKey: Data(repeating: 3, count: 32), receiveKey: Data(repeating: 4, count: 32),
            negotiatedSuite: .x25519Ed25519, role: .responder, transcriptHash: Data(repeating: 5, count: 32))
        format = try .init(sampleRate: 44_100, channels: 2, encoding: .signed24, declaredValidBits: 24, waveChannelMask: 3)
        approvals = try AudioPlaybackApprovalService()
        let binding = try ProtocolIdentityBinding(deviceId: "capture-receiver-local-0001", protocolSigningAlgorithm: .ed25519,
                                                  protocolPublicKeyBytes: Data(repeating: 1, count: 32))
        let local = try AudioProtocolIdentity(binding)
        let peer = try AudioProtocolIdentity(deviceID: "capture-sender-peer-0002", algorithm: .ed25519, fingerprint: String(repeating: "a", count: 64))
        let account = try AudioAccountIdentity(authority: "https://account.invalid", tenantID: "tenant", userID: "user")
        func row(_ identity: AudioProtocolIdentity, caller: Bool) -> AccountDeviceRecord {
            .init(deviceId: identity.deviceID, deviceName: nil, status: "active", protocolSigningAlgorithm: identity.algorithm.rawValue,
                protocolPublicKeyFingerprint: identity.fingerprint, platformRawValue: nil, deviceModel: nil, osVersion: nil,
                appVersion: nil, lanAddresses: [], publicAddress: nil, capabilities: [], registeredAtEpochMilliseconds: nil,
                lastSeenAtEpochMilliseconds: nil, presenceUpdatedAtEpochMilliseconds: nil, online: false, isCaller: caller)
        }
        let time: Int64 = renewalDue ? Int64(Date().timeIntervalSince1970 * 1_000) : 100_000
        let mono = ContinuousClock.now
        let evidence = try AudioAccountMembership.verifyFreshResponse(.init(generatedAtEpochMilliseconds: time,
            callerDeviceId: local.deviceID, truncated: false, devices: [row(local, caller: true), row(peer, caller: false)],
            accountScope: account.serverScope), account: account, local: local, peer: peer,
            requestStartedMilliseconds: time, receivedMilliseconds: time, requestStartedMonotonic: mono, receivedMonotonic: mono,
            lifetimeMilliseconds: renewalDue ? 60_000 : 3_600_000)
        let mailbox = self.mailbox, sent = self.sent, responses = self.responses, failStopDelivery = self.failStopDelivery
        let beforeSend = self.beforeSend, progressSends = self.progressSends
        let fileKeys = self.fileKeys
        channel = P2PAudioChannel(mailbox: mailbox, remoteIdentity: peer, localIdentityBinding: binding, controlTransport: controlTransport,
            peerCapabilities: peerCapabilities,
            validateOwner: {}, validateClassicFileTransfer: { transferID, material in
                guard ClassicTransferKeyMaterial(sessionKeys: fileKeys, transferId: transferID).matches(material) else {
                    throw P2PAudioTransportError.fileTransferMismatch
                }
            }, openUSBFileStream: usbFileOpener, acceptLogicalFileStream: logicalFileAcceptor, send: { message, effect in
                try effect?()
                if let hook = beforeSend.withLock({ $0 }) { try await hook(message); try effect?() }
                if case .stop = message.body, failStopDelivery.withLock({ $0 }) { throw URLError(.networkConnectionLost) }
                if case .fileOutputProgress(let frames) = message.body { progressSends.withLock { $0.append((frames, .now)) } }
                sent.withLock { $0.append(message) }
                if case .outputReady = message.body {
                    for response in responses.withLock({ $0 }) { try mailbox.receive(response) }
                }
            }, close: { mailbox.finish(.closed) })
        lease = try AudioMembershipLease(evidence: evidence, ownerID: channel.ownerID, account: account,
            local: local, peer: peer, wallMilliseconds: { time }, isAccountCurrent: { true }, isPeerCurrent: { true })
        if autoApprove {
            let approvals = self.approvals
            subscription = approvals.$pendingRequest.compactMap { $0 }.sink { request in
                _ = approvals.resolve(request, allowOnce: true)
            }
        }
    }
    func data(_ bytes: Data) -> AudioStreamingMessage { .init(streamID: id, body: .pcmData(byteOffset: 0, bytes: bytes)) }
    func end(_ bytes: Data) -> AudioStreamingMessage {
        .init(streamID: id, body: .end(totalBytes: UInt64(bytes.count), sha256: Data(SHA256.hash(data: bytes))))
    }
    func session(fileReceiveCleanupTimeout: Duration = .seconds(5),
                 receiveOriginalFile: @escaping AudioOriginalFileUSBReceiver.Receive = AudioOriginalFileUSBReceiver.receiveUsingFileManager,
                 renewMembership: AudioPlaybackReceiveSession.MembershipRenewal? = nil,
                 reportFileOutputProgress: Bool = false) -> AudioPlaybackReceiveSession {
        let lease = lease, output = output, failOutputSelection = failOutputSelection, failAccountLookup = failAccountLookup, phases = phases
        return AudioPlaybackReceiveSession(channel: channel, selectOutput: {
                if failOutputSelection { throw CoreAudioExactPcmError.endpointUnavailable }; return "test-output"
            }, authorize: { _ in
                if failAccountLookup { throw URLError(.notConnectedToInternet) }
                return lease
            }, approvals: approvals,
            outputFactory: { _, authorization in output.authorization.withLock { $0 = authorization }; return output },
            fileTransfers: fileData == nil ? nil : fileTransfers,
            reportFileOutputProgress: reportFileOutputProgress,
            fileReceiveCleanupTimeout: fileReceiveCleanupTimeout, receiveOriginalFile: receiveOriginalFile,
            renewMembership: renewMembership, onPhase: { phase in
                phases.withLock { $0.append(String(describing: phase)) }
            })
    }

    func claimFile() async throws -> AudioOriginalFileTransfer {
        guard let result = try await tryClaimFile() else { throw TestFailure.timeout }
        return result
    }

    func tryClaimFile(fault: String? = nil) async throws -> AudioOriginalFileTransfer? {
        guard let fileData else { throw TestFailure.timeout }
        return try await fileTransfers.claimIfOffered(rawTransferID: fileTransferID.uuidString,
            length: Int64(fileData.count) + (fault == "length" ? 1 : 0),
            sha256: fault == "hash" ? String(repeating: "0", count: 64) : Data(SHA256.hash(data: fileData)).map { String(format: "%02x", $0) }.joined(),
            peerID: fault == "peer" ? "wrong-device" : channel.remoteIdentity.deviceID,
            material: ClassicTransferKeyMaterial(sessionKeys: fileKeys,
                transferId: fault == "key" ? UUID().uuidString : fileTransferID.uuidString), cancelReceive: {})
    }

    func service(additional: [ReceiverFixture] = []) -> AudioPlaybackReceiverService {
        let fixtures = [self] + additional
        let leases = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.channel.ownerID, $0.lease) })
        let outputs = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.channel.ownerID, $0.output) })
        return AudioPlaybackReceiverService(approvals: approvals, selectOutput: { .init(uid: "test-output", name: "Fake HAL") },
            dependencies: .init(installHandler: { [weak self] handler in
                guard let self else { throw TestFailure.timeout }; self.incoming = handler; return UUID()
            }, removeHandler: { [weak self] _ in self?.incoming = nil }, authorize: { channel in
                guard let lease = leases[channel.ownerID] else { throw TestFailure.timeout }; return lease
            }, renewMembership: nil, makeOutput: { owner, authorization in
                guard let output = outputs[owner] else { throw TestFailure.timeout }
                output.authorization.withLock { $0 = authorization }; return output
            }, fileTransfers: fileData == nil ? nil : fileTransfers))
    }

    func deliver(_ fixture: ReceiverFixture) throws {
        guard let incoming else { throw TestFailure.timeout }
        incoming(fixture.channel)
        try fixture.mailbox.receive(fixture.offer)
    }
}

private final class ReceiverOutput: AudioCaptureOutput {
    private let capacityBytes: Int
    init(capacityBytes: Int = 96) { self.capacityBytes = capacityBytes }
    struct State: Sendable {
        var bytes = Data()
        var prepares = 0, starts = 0, finishes = 0, closes = 0
        var finishBusyCount = 0
        var pendingCloseAttempts = 0
        var prepareFailure: CoreAudioExactPcmError?
        var closedOwners: [UUID] = []
        var releaseDiagnostics: [String] = []
        var preservedExternalChanges: [String] = []
        var allowCompletion = true, waitUntilRevoked = false, inventAcceptedFrame = false
        var maximumSubmittedFrames: UInt64?
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    let authorization = OSAllocatedUnfairLock<(@Sendable () -> Bool)?>(initialState: nil)
    let closeGate = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    func prepare(endpointUID: String, format: AudioStreamingPCMFormat) throws -> CoreAudioExactPcmPreparedOutput {
        let waits = state.withLock { $0.prepares += 1; return $0.waitUntilRevoked }
        if let failure = state.withLock({ $0.prepareFailure }) { throw failure }
        if waits {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while authorization.withLock({ $0?() == true }) {
                guard ContinuousClock.now < deadline else { throw TestFailure.timeout }
                Thread.sleep(forTimeInterval: 0.002)
            }
            throw CoreAudioExactPcmOutputError.authorizationLost
        }
        return .init(endpointUID: endpointUID, format: format, receiveCapacityBytes: capacityBytes, minimumPrefillFrames: 4)
    }
    func enqueue(_ bytes: Data, ownerID: UUID) throws { state.withLock { $0.bytes.append(bytes) } }
    func start(ownerID: UUID) throws { state.withLock { $0.starts += 1 } }
    func finishInput(ownerID: UUID, expectedSourceFrames: UInt64) throws {
        try state.withLock {
            if $0.finishBusyCount > 0 { $0.finishBusyCount -= 1; throw CoreAudioExactPcmOutputError.busy }
            guard UInt64($0.bytes.count / 6) == expectedSourceFrames else { throw TestFailure.timeout }
            $0.finishes += 1
        }
    }
    func observe() throws -> AudioCaptureOutputObservation {
        state.withLock {
            let frames = UInt64($0.bytes.count / 6)
            let submitted = $0.finishes > 0 || $0.starts > 0 ? min(frames, $0.maximumSubmittedFrames ?? frames) : 0
            return .init(state: $0.finishes > 0 ? ($0.allowCompletion && submitted == frames ? .completed : .draining) : ($0.starts > 0 ? .running : .prepared),
                         acceptedSourceFrames: frames + ($0.inventAcceptedFrame && frames > 0 ? 1 : 0),
                         submittedSourceFrames: submitted, trailingPaddingFrames: $0.finishes > 0 ? UInt32((4 - frames % 4) % 4) : 0)
        }
    }
    func close(ownerID: UUID) -> AudioOutputCleanupOutcome {
        let outcome = state.withLock { value -> AudioOutputCleanupOutcome in
            value.closes += 1; value.closedOwners.append(ownerID)
            if value.pendingCloseAttempts > 0 {
                value.pendingCloseAttempts -= 1
                return .init(state: .pending, diagnostics: ["native stop still pending"], preservedExternalChanges: [])
            }
            return .init(state: .released, diagnostics: value.releaseDiagnostics,
                         preservedExternalChanges: value.preservedExternalChanges)
        }
        let gate = closeGate.withLock { value in let result = value; value = nil; return result }
        gate?()
        return outcome
    }
}
/// Byte-route admission fixture over a real loopback socket. This deliberately has no network
/// projection at the receiver; it is not native AOA acquisition or MAIN/account authentication.
private final class NonIPClassicByteFixture: ClassicFileTransferByteChannel {
    private let underlying: NetworkClassicFileTransferByteChannel
    private let beforeSend: @Sendable () -> Void
    let failCleanup = OSAllocatedUnfairLock(initialState: false)
    let cleanupObserved = OSAllocatedUnfairLock(initialState: false)
    init(_ connection: NWConnection, beforeSend: @escaping @Sendable () -> Void = {}) {
        underlying = NetworkClassicFileTransferByteChannel(connection); self.beforeSend = beforeSend
    }
    var identity: ObjectIdentifier { underlying.identity }
    var networkConnection: NWConnection? { nil }
    func send(_ data: Data, requireEffectAuthorization: @escaping @Sendable () throws -> Void) async throws {
        beforeSend()
        try await underlying.send(data, requireEffectAuthorization: requireEffectAuthorization)
    }
    func receive(length: Int, timeout: TimeInterval?, zeroByteDisconnectError: FileTransferError?) async throws -> Data {
        try await underlying.receive(length: length, timeout: timeout, zeroByteDisconnectError: zeroByteDisconnectError)
    }
    func cancel() { underlying.cancel() }
    func completeAndClose(timeout: Duration) async throws { try await closeAndAwait(timeout: timeout) }
    func closeAndAwait(timeout: Duration) async throws {
        if failCleanup.withLock({ $0 }) { throw ClassicFileTransferByteError.cleanupUnconfirmed }
        try await underlying.closeAndAwait(timeout: timeout)
        cleanupObserved.withLock { $0 = true }
    }
}

#if SKYBRIDGE_USB_FILE_INTEROP
/// Explicit opt-in process peer. Regular test builds do not compile or skip this entry.
/// MAIN/account grants and the output device are fixtures; file crypto and both native byte owners are real.
@MainActor
final class USBOriginalFileInteropPeerTests: XCTestCase {
    private struct Configuration: Decodable {
        let mode, filePath, pcmPath, outputDirectory: String
        let transferID: UUID
    }
    private enum Failure: Error { case invalidConfiguration, timeout, parentRetired, malformedReceipt }
    private func event(_ name: String, _ value: [String: Any], in directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
    }
    func testRunPeer() async throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["SKYBRIDGE_USB_FILE_PEER_CONFIG"])
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard ["success", "offer-mismatch", "receipt-corrupt"].contains(configuration.mode) else { throw Failure.invalidConfiguration }
        let directory = URL(fileURLWithPath: configuration.outputDirectory)
        let file = try Data(contentsOf: URL(fileURLWithPath: configuration.filePath))
        let pcm = try Data(contentsOf: URL(fileURLWithPath: configuration.pcmPath))
        guard !file.isEmpty, file.count <= 1_048_576, !pcm.isEmpty, pcm.count % 6 == 0 else { throw Failure.invalidConfiguration }
        let fd = try USBLoopbackSocketFixture.accept { port in
            try event("listening", ["port": port, "linkProfile": "epoch-v2"], in: directory)
        }
        let carrier = USBHostByteTransport(deviceRegistryID: 1, driver: try USBLoopbackSocketDriver(fd: fd), requireAttachmentCurrent: {})
        let native = try USBHostMultiplexConnection(carrier: carrier, role: .client, configuration: .init(linkProfile: .epochV2))
        addTeardownBlock { try await native.closeAndAwait() }
        try await native.start()
        let stream = try await native.acceptStream(timeout: .seconds(10))
        let control = try USBHostControlFrameTransport(stream: stream, readTimeout: .seconds(20))
        addTeardownBlock { try await control.closeAndAwait() }
        let live = OSAllocatedUnfairLock(initialState: true)
        let corruptReceipt = configuration.mode == "receipt-corrupt"
        let fault = OSAllocatedUnfairLock(initialState: false)
        let fixture = try ReceiverFixture(controlTransport: .usb, file: file, logicalFileAcceptor: {
            guard live.withLock({ $0 }), control.isReady else { throw Failure.parentRetired }
            let stream = try await native.acceptStream(timeout: .seconds(10), priority: .bulk)
            let bytes = try USBClassicFileTransferByteChannel(connection: native, stream: stream,
                requireParentCurrent: { guard live.withLock({ $0 }), control.isReady else { throw Failure.parentRetired } },
                requireParentWriteAuthorization: { guard live.withLock({ $0 }) else { throw Failure.parentRetired } })
            return USBReceiptFaultChannel(underlying: bytes, enabled: corruptReceipt, fault: fault)
        }, transferID: configuration.transferID, outputCapacityBytes: 6_144)
        let wire = try AudioFileSocketFixture(transferID: configuration.transferID.uuidString,
            peerID: fixture.channel.remoteIdentity.deviceID, keys: fixture.fileKeys, audioFiles: fixture.fileTransfers)
        // Register the fixture MAIN authority without creating another network/file channel.
        try await wire.registerSession(keys: fixture.fileKeys, endpoint: nil)
        let wireClosed = OSAllocatedUnfairLock(initialState: false)
        addTeardownBlock { if !wireClosed.withLock({ $0 }) { try await wire.shutdown() } }
        let manager = wire.manager
        let metadataMismatchObserved = OSAllocatedUnfairLock(initialState: false)
        let session = fixture.session(receiveOriginalFile: { bytes, context, required in
            do { try await manager.receiveOriginalAudioFile(from: bytes, peerContext: context, requiring: required) }
            catch {
                metadataMismatchObserved.withLock { $0 = error as? AudioOriginalFileTransferError == .metadataMismatch }
                throw error
            }
        })
        let playback = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await playback.result }
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(35)) }
            catch is CancellationError { return }
            catch { XCTFail("Unexpected interop watchdog error: \(error)"); return }
            timedOut.withLock { $0 = true }; live.withLock { $0 = false }
            native.close(); fixture.mailbox.finish(.closed)
        }
        defer { watchdog.cancel() }
        if configuration.mode == "offer-mismatch" {
            try fixture.mailbox.receive(.init(streamID: fixture.id, body: .fileOffer(transferID: fixture.fileTransferID,
                length: UInt64(file.count), sha256: Data(repeating: 0, count: 32))))
        } else { try fixture.mailbox.receive(fixture.offer) }
        let acceptedUntil = ContinuousClock.now.advanced(by: .seconds(5))
        while !fixture.acceptedFile {
            guard ContinuousClock.now < acceptedUntil else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(2))
        }
        try event("ready", ["acceptedOriginalFile": true, "testAuthority": true, "hardwareOutput": false], in: directory)
        let result = await playback.result
        XCTAssertFalse(timedOut.withLock { $0 })
        let output = fixture.output.state.withLock { $0 }
        var sourceFrames: UInt64 = 0
        if configuration.mode == "success" {
            let receipt = try result.get()
            XCTAssertEqual(receipt.format, fixture.format)
            XCTAssertEqual(receipt.sourceFrames, UInt64(pcm.count / 6))
            XCTAssertEqual(output.bytes, pcm)
            sourceFrames = receipt.sourceFrames
        } else {
            if case .success = result { XCTFail("Rejected file became successful playback") }
            XCTAssertEqual(output.prepares, 0); XCTAssertTrue(output.bytes.isEmpty)
            XCTAssertEqual(fault.withLock { $0 }, corruptReceipt)
            XCTAssertEqual(metadataMismatchObserved.withLock { $0 }, configuration.mode == "offer-mismatch")
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: wire.directory.path).isEmpty)
        let activeIO = await InboundFileTransferIOActor.shared.activeTransferCount(); XCTAssertEqual(activeIO, 0)
        let echo = try await control.receiveFrame(maximumBytes: 64)
        XCTAssertEqual(echo, Data("after-file".utf8))
        try await control.sendFrame(Data("after-file".utf8), requireEffectAuthorization: {})
        try await stream.finishSending()
        switch try await stream.readBytes(maximumBytes: 1, timeout: .seconds(5)) {
        case .end: break
        case .bytes: XCTFail("Trailing control data")
        }
        try await control.closeAndAwait()
        live.withLock { $0 = false }
        try await wire.shutdown(); wireClosed.withLock { $0 = true }
        try await native.closeAndAwait()
        let cleanup = native.shutdownState
        XCTAssertTrue(cleanup.nativeWorkersExited && cleanup.referencesReleased && cleanup.pumpsJoined && cleanup.logicalOwnersReleased)
        try event("result", ["mode": configuration.mode, "sourceFrames": sourceFrames,
            "sourceLength": file.count, "sourceSHA256": Data(SHA256.hash(data: file)).map { String(format: "%02x", $0) }.joined(),
            "decodedSHA256": Data(SHA256.hash(data: output.bytes)).map { String(format: "%02x", $0) }.joined(),
            "sampleRate": fixture.format.sampleRate, "validBits": fixture.format.declaredValidBits,
            "channels": fixture.format.channels, "outputPrepares": output.prepares, "siblingControlWorked": true,
            "nativeCleanupConfirmed": cleanup.nativeWorkersExited && cleanup.referencesReleased && cleanup.pumpsJoined && cleanup.logicalOwnersReleased,
            "activeFileIO": activeIO, "receiptFaultInjected": fault.withLock { $0 },
            "metadataMismatchObserved": metadataMismatchObserved.withLock { $0 }], in: directory)
    }
}

private final class USBReceiptFaultChannel: ClassicFileTransferByteChannel {
    let underlying: any ClassicFileTransferByteChannel
    let enabled: Bool
    let fault: OSAllocatedUnfairLock<Bool>
    init(underlying: any ClassicFileTransferByteChannel, enabled: Bool, fault: OSAllocatedUnfairLock<Bool>) {
        self.underlying = underlying; self.enabled = enabled; self.fault = fault
    }
    var identity: ObjectIdentifier { underlying.identity }
    var networkConnection: NWConnection? { underlying.networkConnection }
    func send(_ data: Data, requireEffectAuthorization: @escaping @Sendable () throws -> Void) async throws {
        var outgoing = data
        if enabled, data.count > 8,
           data.prefix(4).reduce(UInt32(0), { ($0 << 8) | UInt32($1) }) == FileTransferWireMessageType.receipt.rawValue {
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(data.dropFirst(8))) as? [String: Any])
            var modified = payload
            modified["authTag"] = Data(repeating: 0, count: 32).base64EncodedString()
            let body = try JSONSerialization.data(withJSONObject: modified, options: [.sortedKeys])
            outgoing = Data(data.prefix(4)); var length = UInt32(body.count).bigEndian
            withUnsafeBytes(of: &length) { outgoing.append(contentsOf: $0) }; outgoing.append(body)
            fault.withLock { $0 = true }
        }
        try await underlying.send(outgoing, requireEffectAuthorization: requireEffectAuthorization)
    }
    func receive(length: Int, timeout: TimeInterval?, zeroByteDisconnectError: FileTransferError?) async throws -> Data {
        try await underlying.receive(length: length, timeout: timeout, zeroByteDisconnectError: zeroByteDisconnectError)
    }
    func cancel() { underlying.cancel() }
    func completeAndClose(timeout: Duration) async throws { try await underlying.completeAndClose(timeout: timeout) }
    func closeAndAwait(timeout: Duration) async throws { try await underlying.closeAndAwait(timeout: timeout) }
}
#endif
#endif
