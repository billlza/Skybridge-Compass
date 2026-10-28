#if os(macOS)
import AVFAudio
import Foundation
import os
import SkyBridgeProtocolCore
import XCTest
@testable import SkyBridgeCore

final class CoreAudioOpusOutputTests: XCTestCase {
    private enum Failure: Error { case revoked, schedule }
    private final class Driver: CoreAudioOpusDriver {
        private struct State: Sendable {
            var callbacks: [@Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void] = []
            var running = false, endpointCurrent = true, failClose = false, failSchedule = false
            var position: Int64? = 0
            var closes = 0, schedules = 0
        }
        private let value = OSAllocatedUnfairLock(initialState: State())
        var failClose: Bool { get { value.withLock { $0.failClose } } set { value.withLock { $0.failClose = newValue } } }
        var failSchedule: Bool { get { value.withLock { $0.failSchedule } } set { value.withLock { $0.failSchedule = newValue } } }
        var running: Bool { get { value.withLock { $0.running } } set { value.withLock { $0.running = newValue } } }
        var endpointCurrent: Bool { get { value.withLock { $0.endpointCurrent } } set { value.withLock { $0.endpointCurrent = newValue } } }
        var position: Int64? { get { value.withLock { $0.position } } set { value.withLock { $0.position = newValue } } }
        var closes: Int { value.withLock { $0.closes } }
        var schedules: Int { value.withLock { $0.schedules } }
        func schedule(_ pcm16LE: Data, completion: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void) throws {
            try value.withLock {
                if $0.failSchedule { throw Failure.schedule }
                $0.schedules += 1; $0.callbacks.append(completion)
            }
        }
        func start() { running = true }
        func status() -> CoreAudioOpusDriverStatus {
            value.withLock { .init(endpointCurrent: $0.endpointCurrent, engineRunning: $0.running,
                playerPlaying: $0.running, renderedSourceFrame: $0.position) }
        }
        func close() throws {
            let captured = value.withLock { state in
                state.closes += 1
                if !state.failClose { state.running = false }
                return (state.callbacks, state.failClose)
            }
            // Reproduce the observed native behavior: stop invokes all pending completion blocks.
            captured.0.forEach { $0(.dataPlayedBack) }
            if captured.1 { throw CoreAudioOpusOutputError.cleanupUnconfirmed }
        }
        func complete(_ index: Int, kind: AVAudioPlayerNodeCompletionCallbackType = .dataPlayedBack) {
            let callback = value.withLock { state in
                if kind == .dataPlayedBack { state.position = max(state.position ?? 0, Int64((index + 1) * 960)) }
                return state.callbacks[index]
            }
            callback(kind)
        }
    }
    private final class Fixture {
        let id = UUID(), driver = Driver()
        let current = OSAllocatedUnfairLock(initialState: true)
        let time = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let output: CoreAudioOpusOutput
        init(prepare: Bool = true, buffering: AudioStreamingOpusBuffering = .legacy) throws {
            let driver = driver, current = current, time = time
            output = try CoreAudioOpusOutput(ownerID: id, buffering: buffering, requireAuthorization: {
                guard current.withLock({ $0 }) else { throw Failure.revoked }
            }, makeDriver: { _, _ in driver }, automaticMonitoring: false, now: { time.withLock { $0 } })
            if prepare { try output.prepare(endpointUID: "fixture-device", channels: 2) }
        }
        func append(_ blocks: Int) throws {
            for _ in 0..<blocks {
                let first = output.snapshot().acceptedSourceFrames
                try output.enqueue(Data(count: 960 * 4), firstSourceFrame: first, ownerID: id)
            }
        }
        deinit {
            do { _ = try output.close(ownerID: id) }
            catch { XCTFail("Fixture cleanup failed: \(error)") }
        }
    }

    func testMonitoredFailureRemainsTheCauseOfLaterOwnerOperations() throws {
        for expected in [CoreAudioOpusOutputError.underrun, .engineStopped, .endpointChanged, .timedOut] {
            let f = try Fixture(); try f.append(10); try f.output.start(ownerID: f.id)
            switch expected {
            case .underrun: f.driver.position = 9_728
            case .engineStopped: f.driver.running = false
            case .endpointChanged: f.driver.endpointCurrent = false
            case .timedOut: f.time.withLock { $0 = $0.advanced(by: .seconds(3)) }
            default: XCTFail("Unexpected fixture failure"); continue
            }
            // Same ordering observed on native output: monitor retires the driver,
            // then the next producer operation arrives with the correct owner.
            let failed = f.output.snapshot()
            XCTAssertEqual(failed.state, .failed)
            XCTAssertEqual(failed.failure, String(describing: expected))
            let schedules = f.driver.schedules, closes = f.driver.closes
            XCTAssertThrowsError(try f.output.enqueue(Data(count: 960 * 4), firstSourceFrame: 9_600, ownerID: f.id)) {
                XCTAssertEqual($0 as? CoreAudioOpusOutputError, expected)
            }
            XCTAssertThrowsError(try f.output.finishInput(ownerID: f.id, expectedSourceFrames: 9_600)) {
                XCTAssertEqual($0 as? CoreAudioOpusOutputError, expected)
            }
            XCTAssertThrowsError(try f.output.start(ownerID: f.id)) {
                XCTAssertEqual($0 as? CoreAudioOpusOutputError, expected)
            }
            XCTAssertThrowsError(try f.output.checkedSnapshot(ownerID: f.id)) {
                XCTAssertEqual($0 as? CoreAudioOpusOutputError, expected)
            }
            XCTAssertEqual(f.driver.schedules, schedules)
            XCTAssertEqual(f.driver.closes, closes)
            XCTAssertEqual(f.output.snapshot().playedSourceFrames, failed.playedSourceFrames)
        }
    }

    func testMonitoredAuthorizationFailureSurvivesCleanupAndKeepsOwnerCheckFirst() throws {
        let f = try Fixture(); try f.append(10); try f.output.start(ownerID: f.id)
        f.driver.failClose = true; f.current.withLock { $0 = false }
        XCTAssertEqual(f.output.snapshot().state, .failed)
        XCTAssertTrue(f.output.snapshot().cleanupPending)
        XCTAssertThrowsError(try f.output.enqueue(Data(count: 960 * 4), firstSourceFrame: 9_600, ownerID: UUID())) {
            XCTAssertEqual($0 as? CoreAudioOpusOutputError, .wrongOwner)
        }
        XCTAssertThrowsError(try f.output.checkedSnapshot(ownerID: UUID())) {
            XCTAssertEqual($0 as? CoreAudioOpusOutputError, .wrongOwner)
        }
        XCTAssertThrowsError(try f.output.enqueue(Data(count: 960 * 4), firstSourceFrame: 9_600, ownerID: f.id)) {
            guard case Failure.revoked = $0 else { return XCTFail("Lost original authority failure: \($0)") }
        }
        XCTAssertEqual(f.driver.schedules, 10)
        f.driver.failClose = false
        let cleanup = try f.output.close(ownerID: f.id)
        XCTAssertEqual(cleanup.state, .released)
        XCTAssertFalse(cleanup.diagnostics.isEmpty)
        XCTAssertThrowsError(try f.output.finishInput(ownerID: f.id, expectedSourceFrames: 9_600)) {
            guard case Failure.revoked = $0 else { return XCTFail("Cleanup replaced the original failure: \($0)") }
        }
        XCTAssertThrowsError(try f.output.checkedSnapshot(ownerID: f.id)) {
            guard case Failure.revoked = $0 else { return XCTFail("Cleanup replaced the polled failure: \($0)") }
        }
        XCTAssertEqual(f.output.snapshot().failure, String(describing: Failure.revoked))
        XCTAssertEqual(f.output.snapshot().playedSourceFrames, 0)
    }

    func testCompletionRequiresExactEndAndNativeDrainBeforeCleanup() throws {
        let f = try Fixture(); try f.append(10); try f.output.start(ownerID: f.id)
        for index in 0..<10 { f.driver.complete(index) }
        XCTAssertEqual(f.output.snapshot().state, .running)
        XCTAssertEqual(f.driver.closes, 0)
        try f.output.finishInput(ownerID: f.id, expectedSourceFrames: 9600)
        let ended = f.output.snapshot()
        XCTAssertEqual(ended.state, .completed)
        XCTAssertEqual(ended.acceptedSourceFrames, 9600)
        XCTAssertEqual(ended.playedSourceFrames, 9600)
        XCTAssertFalse(ended.cleanupPending)
        XCTAssertEqual(f.driver.closes, 1)
    }

    func testBufferedFileRequiresItsPrefillAndRetainsHardCapacity() throws {
        let f = try Fixture(buffering: .bufferedFile)
        try f.append(47)
        XCTAssertThrowsError(try f.output.start(ownerID: f.id)) {
            XCTAssertEqual($0 as? CoreAudioOpusOutputError, .insufficientPrefill)
        }
        XCTAssertFalse(f.driver.running)
        try f.append(1); try f.output.start(ownerID: f.id)
        XCTAssertTrue(f.driver.running)
        try f.append(16)
        XCTAssertThrowsError(try f.append(1)) {
            XCTAssertEqual($0 as? CoreAudioOpusOutputError, .busy)
        }
        XCTAssertEqual(f.driver.schedules, 64)
        XCTAssertEqual(f.output.snapshot().acceptedSourceFrames, 61_440)
        // A larger queue cannot turn local stop callbacks into playback evidence.
        _ = try f.output.close(ownerID: f.id)
        XCTAssertEqual(f.output.snapshot().playedSourceFrames, 0)
    }

    func testBufferedShortSealedFileCanStartButStillNeedsNativeDrain() throws {
        let f = try Fixture(buffering: .bufferedFile)
        try f.append(1)
        try f.output.finishInput(ownerID: f.id, expectedSourceFrames: 960)
        try f.output.start(ownerID: f.id)
        XCTAssertNotEqual(f.output.snapshot().state, .completed)
        f.driver.complete(0)
        XCTAssertEqual(f.output.snapshot().state, .completed)
        XCTAssertEqual(f.output.snapshot().playedSourceFrames, 960)
    }

    func testBufferedOutputStillStopsOnRevocationAndUnderrun() throws {
        for revoked in [true, false] {
            let f = try Fixture(buffering: .bufferedFile)
            try f.append(48); try f.output.start(ownerID: f.id)
            if revoked { f.current.withLock { $0 = false } }
            else { f.driver.position = 46_081 }
            let state = f.output.snapshot()
            XCTAssertEqual(state.state, .failed)
            // The output preserves the injected authority error rather than relabeling it.
            XCTAssertEqual(state.failure, revoked ? String(describing: Failure.revoked) : "underrun")
            XCTAssertEqual(state.playedSourceFrames, 0)
            XCTAssertFalse(f.driver.running)
        }
    }

    @MainActor func testPlaybackCannotMixLegacyAndBufferedOutputPolicies() throws {
        for bufferedOffer in [true, false] {
            let f = try Fixture(prepare: false, buffering: bufferedOffer ? .legacy : .bufferedFile)
            let format = try AudioStreamingOpusFormat(channels: 2, bitrate: 128_000)
            let offer = AudioStreamingMessage(streamID: UUID(), body: bufferedOffer
                ? .bufferedOpusFileOffer(format) : .opusOffer(source: .originalFile, format: format))
            XCTAssertThrowsError(try AudioOpusPlayback(offer: offer, endpointUID: "fixture-device", output: f.output,
                                                     requireAuthorization: {})) {
                XCTAssertEqual($0 as? AudioOpusReceiveError, .invalidConfiguration)
            }
            XCTAssertEqual(f.driver.schedules, 0)
            XCTAssertFalse(f.driver.running)
        }
    }

    func testLocalStopCallbacksCannotTurnUnplayedBuffersIntoCompletion() throws {
        let f = try Fixture(); try f.append(16); try f.output.start(ownerID: f.id)
        XCTAssertEqual(try f.output.close(ownerID: f.id).state, .released)
        let stopped = f.output.snapshot()
        XCTAssertEqual(stopped.state, .closed)
        XCTAssertEqual(stopped.playedSourceFrames, 0)
        XCTAssertEqual(stopped.acceptedSourceFrames, 15360)
        f.driver.complete(0)
        XCTAssertEqual(f.output.snapshot().playedSourceFrames, 0)
    }

    func testSystemEngineStopAndEndpointChangeFailBeforeReportingProgress() throws {
        for changedEndpoint in [false, true] {
            let f = try Fixture(); try f.append(10); try f.output.start(ownerID: f.id)
            if changedEndpoint { f.driver.endpointCurrent = false } else { f.driver.running = false }
            let value = f.output.snapshot()
            XCTAssertEqual(value.state, .failed)
            XCTAssertEqual(value.playedSourceFrames, 0)
            XCTAssertFalse(value.cleanupPending)
            XCTAssertEqual(value.failure, changedEndpoint ? "endpointChanged" : "engineStopped")
        }
    }

    func testCapacityRejectsWithoutCommittingAnotherBuffer() throws {
        let f = try Fixture(); try f.append(16)
        XCTAssertThrowsError(try f.output.enqueue(Data(count: 960 * 4), firstSourceFrame: 15360, ownerID: f.id)) {
            XCTAssertEqual($0 as? CoreAudioOpusOutputError, .busy)
        }
        XCTAssertEqual(f.output.snapshot().state, .prepared)
        XCTAssertEqual(f.output.snapshot().acceptedSourceFrames, 15360)
        XCTAssertEqual(f.driver.schedules, 16)
    }

    func testOrderedCompletionDoesNotSkipMissingBufferAndRejectsDuplicates() throws {
        let f = try Fixture(); try f.append(10); try f.output.start(ownerID: f.id)
        f.driver.complete(1)
        XCTAssertEqual(f.output.snapshot().playedSourceFrames, 0)
        f.driver.complete(0)
        XCTAssertEqual(f.output.snapshot().playedSourceFrames, 1920)
        f.driver.complete(0)
        XCTAssertEqual(f.output.snapshot().state, .failed)
        XCTAssertEqual(f.output.snapshot().failure, "invalidCallback")
    }

    func testConsumedCallbackAndAuthorizationLossNeverProduceSuccess() throws {
        let consumed = try Fixture(); try consumed.append(10); try consumed.output.start(ownerID: consumed.id)
        consumed.driver.complete(0, kind: .dataConsumed)
        XCTAssertEqual(consumed.output.snapshot().failure, "invalidCallback")
        let revoked = try Fixture(); try revoked.append(10); try revoked.output.start(ownerID: revoked.id)
        revoked.current.withLock { $0 = false }
        XCTAssertEqual(revoked.output.snapshot().state, .failed)
        XCTAssertEqual(revoked.output.snapshot().playedSourceFrames, 0)
        XCTAssertFalse(revoked.driver.running)
    }

    func testNativeScheduleFailureDoesNotCommitReservedSourceFrames() throws {
        let f = try Fixture(); f.driver.failSchedule = true
        XCTAssertThrowsError(try f.append(1))
        XCTAssertEqual(f.output.snapshot().state, .failed)
        XCTAssertEqual(f.output.snapshot().acceptedSourceFrames, 0)
        XCTAssertEqual(f.output.snapshot().playedSourceFrames, 0)
        XCTAssertEqual(f.driver.schedules, 0)
    }

    func testCleanupFailureRetainsOwnerAndOnlyExplicitRetryReleasesIt() throws {
        let f = try Fixture(); try f.append(10); try f.output.start(ownerID: f.id)
        f.driver.failClose = true
        XCTAssertEqual(try f.output.close(ownerID: f.id).state, .pending)
        XCTAssertEqual(f.output.snapshot().state, .closing)
        XCTAssertEqual(f.driver.closes, 1)
        XCTAssertEqual(f.output.snapshot().playedSourceFrames, 0)
        f.driver.failClose = false
        let cleaned = try f.output.close(ownerID: f.id)
        XCTAssertEqual(cleaned.state, .released)
        XCTAssertFalse(cleaned.diagnostics.isEmpty)
        XCTAssertEqual(f.driver.closes, 2)
        XCTAssertEqual(f.output.snapshot().state, .closed)
    }

    func testWrongOwnerDoesNotStopCurrentOutputAndShortSealedInputCanStart() throws {
        let f = try Fixture(); try f.append(1)
        XCTAssertThrowsError(try f.output.start(ownerID: f.id)) {
            XCTAssertEqual($0 as? CoreAudioOpusOutputError, .insufficientPrefill)
        }
        XCTAssertThrowsError(try f.output.close(ownerID: UUID())) {
            XCTAssertEqual($0 as? CoreAudioOpusOutputError, .wrongOwner)
        }
        XCTAssertEqual(f.output.snapshot().state, .prepared)
        try f.output.finishInput(ownerID: f.id, expectedSourceFrames: 960)
        try f.output.start(ownerID: f.id)
        f.driver.complete(0)
        XCTAssertEqual(f.output.snapshot().state, .completed)
    }

    func testTimelineUnderrunAndExpiredPreparationRemainFailures() throws {
        let running = try Fixture(); try running.append(10); try running.output.start(ownerID: running.id)
        running.driver.position = 9601
        XCTAssertEqual(running.output.snapshot().failure, "underrun")
        let expired = try Fixture()
        expired.time.withLock { $0 = $0.advanced(by: .seconds(31)) }
        XCTAssertEqual(expired.output.snapshot().failure, "timedOut")
        XCTAssertFalse(expired.output.snapshot().cleanupPending)
    }

    func testNegativeStartupTimelineWaitsWithoutInventingProgressOrExtendingDeadline() throws {
        let f = try Fixture(); try f.append(10); f.driver.position = -1024
        try f.output.start(ownerID: f.id)
        XCTAssertEqual(f.output.snapshot().state, .running)
        XCTAssertEqual(f.output.snapshot().playedSourceFrames, 0)
        f.driver.position = -512
        XCTAssertEqual(f.output.snapshot().state, .running)
        f.driver.position = 0
        XCTAssertEqual(f.output.snapshot().state, .running)
        f.driver.position = -1
        XCTAssertEqual(f.output.snapshot().failure, "invalidTimeline")

        let stalled = try Fixture(); try stalled.append(10); stalled.driver.position = -1024
        try stalled.output.start(ownerID: stalled.id)
        stalled.time.withLock { $0 = $0.advanced(by: .seconds(3)) }
        stalled.driver.position = -512
        XCTAssertEqual(stalled.output.snapshot().failure, "timedOut")
        XCTAssertEqual(stalled.output.snapshot().playedSourceFrames, 0)
    }

    func testAllCallbacksStillRequireCurrentTimelineToPassSourceEnd() throws {
        let f = try Fixture(); try f.append(10); try f.output.start(ownerID: f.id)
        try f.output.finishInput(ownerID: f.id, expectedSourceFrames: 9600)
        for index in 0..<10 { f.driver.complete(index) }
        f.driver.position = 9599
        XCTAssertEqual(f.output.snapshot().state, .draining)
        XCTAssertEqual(f.driver.closes, 0)
        f.driver.position = nil
        XCTAssertEqual(f.output.snapshot().state, .draining)
        f.driver.position = 9600
        XCTAssertEqual(f.output.snapshot().state, .completed)
        XCTAssertEqual(f.driver.closes, 1)
    }

    @MainActor func testPlaybackPollPreservesTheMonitoredOutputCauseWithoutAnotherPacket() async throws {
        for revoked in [false, true] {
            let f = try Fixture(prepare: false), stream = UUID()
            let offer = AudioStreamingMessage(streamID: stream, body: .opusOffer(source: .originalFile,
                format: try .init(channels: 2, bitrate: 192_000)))
            let player = try AudioOpusPlayback(offer: offer, endpointUID: "fixture-device", output: f.output, requireAuthorization: {})
            _ = try await player.prepare()
            if revoked { f.current.withLock { $0 = false } }
            else { f.time.withLock { $0 = $0.advanced(by: .seconds(31)) } }
            XCTAssertEqual(f.output.snapshot().state, .failed)
            do { _ = try await player.poll(); XCTFail("Monitored failure became healthy progress") }
            catch let failure as AudioOpusPlaybackFailure {
                if revoked {
                    guard case Failure.revoked = failure.primary else { return XCTFail("Poll lost the authority failure: \(failure.primary)") }
                } else { XCTAssertEqual(failure.primary as? CoreAudioOpusOutputError, .timedOut) }
                XCTAssertEqual(failure.cleanup?.state, .released)
            }
            XCTAssertEqual(f.driver.schedules, 0)
            XCTAssertEqual(f.output.snapshot().playedSourceFrames, 0)
        }
    }

    @MainActor func testPlaybackConsumerRejectsStrictPCMBeforeEnqueueAndCannotBeReused() async throws {
        let f = try Fixture(prepare: false), stream = UUID()
        let offer = AudioStreamingMessage(streamID: stream, body: .opusOffer(source: .systemCapture,
            format: try .init(channels: 2, bitrate: 192_000)))
        let player = try AudioOpusPlayback(offer: offer, endpointUID: "fixture-device", output: f.output, requireAuthorization: {})
        let prepared = try await player.prepare()
        XCTAssertEqual(prepared.map(\.body), [.accept(receiveWindowBytes: 7680), .opusOutputReady])
        do { _ = try await player.receive(.init(streamID: stream, body: .pcmData(byteOffset: 0, bytes: Data(count: 3840)))); XCTFail("Strict PCM entered Opus output") }
        catch let failure as AudioOpusPlaybackFailure {
            XCTAssertEqual(failure.primary as? AudioOpusReceiveError, .invalidState)
            XCTAssertEqual(failure.cleanup?.state, .released)
        }
        XCTAssertEqual(f.driver.schedules, 0)
        XCTAssertEqual(f.output.snapshot().state, .closed)
        do { _ = try await player.poll(); XCTFail("Failed playback was reused") }
        catch let failure as AudioOpusReceiveError { XCTAssertEqual(failure, .invalidState) }
    }

    @MainActor func testPlaybackConsumerRetainsFailedCleanupForExplicitRetry() async throws {
        let f = try Fixture(prepare: false), stream = UUID()
        let offer = AudioStreamingMessage(streamID: stream, body: .opusOffer(source: .originalFile,
            format: try .init(channels: 2, bitrate: 192_000)))
        let player = try AudioOpusPlayback(offer: offer, endpointUID: "fixture-device", output: f.output, requireAuthorization: {})
        _ = try await player.prepare(); f.driver.failClose = true
        do { _ = try await player.receive(.init(streamID: stream, body: .opusOutputReady)); XCTFail("Wrong-direction control accepted") }
        catch let failure as AudioOpusPlaybackFailure {
            XCTAssertEqual(failure.cleanup?.state, .pending)
        }
        XCTAssertEqual(f.driver.closes, 1)
        XCTAssertEqual(f.output.snapshot().state, .closing)
        do { _ = try await player.poll(); XCTFail("Failed playback was reused") }
        catch let failure as AudioOpusReceiveError { XCTAssertEqual(failure, .invalidState) }
        XCTAssertEqual(f.driver.closes, 1)
        f.driver.failClose = false
        let cleanup = try await player.close()
        XCTAssertEqual(cleanup.state, .released)
        XCTAssertEqual(f.output.snapshot().state, .closed)
    }
}
#endif
