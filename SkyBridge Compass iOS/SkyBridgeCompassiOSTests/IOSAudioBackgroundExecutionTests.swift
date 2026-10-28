import XCTest
@testable import SkyBridgeCompass_iOS

@MainActor
final class IOSAudioBackgroundExecutionTests: XCTestCase {
    func testLaunchAndSuccessfulSubmissionAreBothRequired() async throws {
        let scheduler = ControlledAudioBackgroundScheduler(); scheduler.holdSubmission = true
        let execution = try makeExecution(scheduler)
        var started = false
        let start = Task { try await execution.start {}; started = true }
        try await until { scheduler.submitting }
        let handle = scheduler.launch()
        XCTAssertFalse(started); XCTAssertEqual(execution.state, .requesting)
        scheduler.resolveSubmission()
        try await start.value
        XCTAssertTrue(started); XCTAssertEqual(execution.state, .active)
        XCTAssertTrue(execution.preservesBackgroundWork)
        execution.update(work(.awaitingPlayback, frames: 100))
        XCTAssertEqual(execution.progress.value.fractionCompleted, 0.75, accuracy: 0.0001)
        XCTAssertTrue(handle.completions.isEmpty)
        await execution.finish(success: true)
        XCTAssertEqual(execution.failure as? IOSAudioBackgroundError, .incompleteWork)
        XCTAssertEqual(handle.completions, [false])
        XCTAssertLessThan(execution.progress.value.fractionCompleted, 1)
    }

    func testFinalReceiptAndCleanupPermitExactlyOneSuccessfulCompletion() async throws {
        let scheduler = ControlledAudioBackgroundScheduler()
        let execution = try makeExecution(scheduler)
        let start = Task { try await execution.start {} }
        try await until { scheduler.submitting }
        let handle = scheduler.launch(); try await start.value
        execution.update(work(.awaitingPlayback, frames: 50))
        XCTAssertEqual(execution.progress.value.fractionCompleted, 0.625, accuracy: 0.0001)
        execution.update(work(.completed, frames: 100))
        XCTAssertTrue(handle.completions.isEmpty, "Final progress cannot finish before the session owner joins cleanup")
        await execution.finish(success: true)
        await execution.finish(success: true)
        execution.cancel()
        XCTAssertEqual(handle.completions, [true])
        XCTAssertEqual(execution.progress.value.fractionCompleted, 1)
        XCTAssertEqual(execution.state, .finished); XCTAssertNil(execution.failure)
        XCTAssertFalse(execution.preservesBackgroundWork)
    }

    func testExpirationStopsWorkButRetainsTaskUntilOwnedCleanupFinishes() async throws {
        let scheduler = ControlledAudioBackgroundScheduler()
        let execution = try makeExecution(scheduler)
        var stops = 0
        let start = Task { try await execution.start { stops += 1 } }
        try await until { scheduler.submitting }
        let handle = scheduler.launch(); try await start.value
        handle.expire()
        handle.expire(); execution.cancel()
        XCTAssertEqual(stops, 1); XCTAssertEqual(execution.failure as? IOSAudioBackgroundError, .expired)
        XCTAssertFalse(execution.preservesBackgroundWork)
        XCTAssertTrue(handle.completions.isEmpty, "System expiration is not an owned cleanup receipt")
        await execution.finish(success: false)
        XCTAssertEqual(handle.completions, [false]); XCTAssertEqual(execution.state, .failed)
    }

    func testCancelledSubmissionRemainsOwnedAndLateFailureIsRetained() async throws {
        let scheduler = ControlledAudioBackgroundScheduler(); scheduler.holdSubmission = true
        let execution = try makeExecution(scheduler)
        var stopped = false
        let start = Task { try await execution.start { stopped = true } }
        try await until { scheduler.submitting }
        let handle = scheduler.launch()
        execution.cancel()
        do { try await start.value; XCTFail("Cancelled request started") }
        catch { XCTAssertEqual(error as? IOSAudioBackgroundError, .cancelled) }
        XCTAssertTrue(stopped)
        var finished = false, finishingEntered = false
        let finishing = Task { finishingEntered = true; await execution.finish(success: false); finished = true }
        try await until { finishingEntered }
        XCTAssertFalse(finished); XCTAssertTrue(handle.completions.isEmpty)
        scheduler.resolveSubmission(.registrationRejected)
        await finishing.value
        XCTAssertEqual(execution.submissionFailure as? IOSAudioBackgroundError, .registrationRejected)
        XCTAssertEqual(execution.failure as? IOSAudioBackgroundError, .cancelled)
        XCTAssertEqual(handle.completions, [false])
        let stale = scheduler.launch()
        XCTAssertEqual(stale.completions, [false]); XCTAssertEqual(handle.completions, [false])
    }

    func testTimeoutAndLateLaunchCannotRestartPlayback() async throws {
        let scheduler = ControlledAudioBackgroundScheduler()
        let execution = try makeExecution(scheduler, timeout: .milliseconds(10))
        var stops = 0
        do { try await execution.start { stops += 1 }; XCTFail("Missing system launch was accepted") }
        catch { XCTAssertEqual(error as? IOSAudioBackgroundError, .launchTimedOut) }
        XCTAssertEqual(stops, 1)
        await execution.finish(success: false)
        let late = scheduler.launch()
        XCTAssertEqual(late.completions, [false]); XCTAssertFalse(execution.preservesBackgroundWork)
        XCTAssertTrue(scheduler.cancelled.contains(execution.identifier))
    }

    func testRejectedRequestNeverStartsWork() async throws {
        let scheduler = ControlledAudioBackgroundScheduler(); scheduler.submissionError = .registrationRejected
        let execution = try makeExecution(scheduler)
        do { try await execution.start {}; XCTFail("Rejected request started") }
        catch { XCTAssertEqual(error as? IOSAudioBackgroundError, .registrationRejected) }
        await execution.finish(success: false)
        XCTAssertEqual(execution.submissionFailure as? IOSAudioBackgroundError, .registrationRejected)
        XCTAssertFalse(execution.preservesBackgroundWork)
    }

    func testWrongTaskCannotBorrowAnotherJobsLifetime() async throws {
        let scheduler = ControlledAudioBackgroundScheduler()
        let execution = try makeExecution(scheduler)
        let start = Task { try await execution.start {} }
        try await until { scheduler.submitting }
        let foreign = scheduler.launch(identifier: "different.job")
        do { try await start.value; XCTFail("Foreign task was attached") }
        catch { XCTAssertEqual(error as? IOSAudioBackgroundError, .unexpectedTask) }
        await execution.finish(success: false)
        XCTAssertEqual(foreign.completions, [false])
    }

    func testInvalidProgressStopsWithoutPublishingPartialObservation() async throws {
        for invalid in [work(.awaitingPlayback, frames: 101), work(.awaitingPlayback, frames: 49),
                        work(.awaitingPlayback, frames: UInt64(Int64.max) + 1)] {
            let scheduler = ControlledAudioBackgroundScheduler()
            let execution = try makeExecution(scheduler)
            var stopped = false
            let start = Task { try await execution.start { stopped = true } }
            try await until { scheduler.submitting }
            let handle = scheduler.launch(); try await start.value
            execution.update(work(.awaitingPlayback, frames: 50))
            let before = execution.progress.value.fractionCompleted
            execution.update(invalid)
            XCTAssertTrue(stopped)
            XCTAssertEqual(execution.progress.value.fractionCompleted, before)
            XCTAssertEqual(execution.failure as? IOSAudioBackgroundError, .invalidProgress)
            await execution.finish(success: false); XCTAssertEqual(handle.completions, [false])
        }
    }

    func testUserCancellationBeforeStartDoesNotSubmitAnything() async throws {
        let scheduler = ControlledAudioBackgroundScheduler()
        let execution = try makeExecution(scheduler)
        execution.cancel()
        do { try await execution.start {}; XCTFail("Pre-cancelled request was submitted") }
        catch { XCTAssertEqual(error as? IOSAudioBackgroundError, .cancelled) }
        await execution.finish(success: false)
        XCTAssertFalse(scheduler.submitting)
    }

    func testImmediateBackgroundSwitchKeepsThePlannedRequestAndDelayedStartExpires() async throws {
        let scheduler = ControlledAudioBackgroundScheduler()
        let execution = try makeExecution(scheduler, timeout: .milliseconds(10))
        XCTAssertTrue(execution.preservesBackgroundWork)
        XCTAssertEqual(execution.state, .requesting)
        try await Task.sleep(for: .milliseconds(25))
        do { try await execution.start {}; XCTFail("Suspended request started late") }
        catch { XCTAssertEqual(error as? IOSAudioBackgroundError, .launchTimedOut) }
        await execution.finish(success: false)
        XCTAssertFalse(scheduler.submitting)
    }

    func testObservedNativeExpiryWinsOverAQueuedActorCallbackAtCompletion() async throws {
        let scheduler = ControlledAudioBackgroundScheduler()
        let execution = try makeExecution(scheduler)
        let start = Task { try await execution.start {} }
        try await until { scheduler.submitting }; let handle = scheduler.launch(); try await start.value
        execution.update(work(.completed, frames: 100))
        handle.isExpired = true // Callback observed by SDK; actor notification has not run yet.
        await execution.finish(success: true)
        XCTAssertEqual(handle.completions, [false])
        XCTAssertEqual(execution.failure as? IOSAudioBackgroundError, .expired)
        XCTAssertLessThan(execution.progress.value.fractionCompleted, 1)
    }

    func testBluetoothPacketProgressCannotReplaceFinalReceiptAndCleanup() async throws {
        let scheduler = ControlledAudioBackgroundScheduler()
        let execution = try makeExecution(scheduler)
        let start = Task { try await execution.start {} }
        try await until { scheduler.submitting }; let handle = scheduler.launch(); try await start.value
        execution.update(IOSOpusFileSendSession.WorkProgress(phase: .awaitingPlayback,
            preparationCompleted: true, totalPackets: 51, sentPackets: 51, retiredPackets: 51))
        XCTAssertEqual(execution.progress.value.fractionCompleted, 0.75, accuracy: 0.0001)
        XCTAssertEqual(handle.statuses.last, .bluetoothFile(.awaitingPlayback))
        await execution.finish(success: true)
        XCTAssertEqual(execution.failure as? IOSAudioBackgroundError, .incompleteWork)
        XCTAssertEqual(handle.completions, [false])
    }

    func testBluetoothProgressRejectsRegressionUnknownExtentAndChangedJobKind() throws {
        let good = IOSOpusFileSendSession.WorkProgress(phase: .streaming,
            preparationCompleted: true, totalPackets: 8, sentPackets: 4, retiredPackets: 2)
        let invalid: [IOSOpusFileSendSession.WorkProgress] = [
            .init(phase: .streaming, preparationCompleted: true, totalPackets: 8, sentPackets: 9, retiredPackets: 2),
            .init(phase: .streaming, preparationCompleted: true, totalPackets: 8, sentPackets: 3, retiredPackets: 2),
            .init(phase: .streaming, preparationCompleted: true, totalPackets: 8, sentPackets: 4, retiredPackets: 1),
            .init(phase: .streaming, preparationCompleted: false, totalPackets: 8, sentPackets: 4, retiredPackets: 2),
            .init(phase: .streaming, preparationCompleted: true, totalPackets: nil, sentPackets: 4, retiredPackets: 2),
            .init(phase: .streaming, preparationCompleted: true, totalPackets: 9, sentPackets: 4, retiredPackets: 2),
            .init(phase: .streaming, preparationCompleted: true, totalPackets: 0, sentPackets: 0, retiredPackets: 0),
            .init(phase: .streaming, preparationCompleted: true, totalPackets: UInt64(Int64.max) + 1,
                  sentPackets: 4, retiredPackets: 2)
        ]
        for observation in invalid {
            let progress = IOSAudioTaskProgress(); try progress.update(good)
            let previous = progress.value.fractionCompleted
            XCTAssertThrowsError(try progress.update(observation)) {
                XCTAssertEqual($0 as? IOSAudioBackgroundError, .invalidProgress)
            }
            XCTAssertEqual(progress.value.fractionCompleted, previous)
            XCTAssertEqual(progress.status, .bluetoothFile(.streaming))
        }
        let progress = IOSAudioTaskProgress(); try progress.update(good)
        XCTAssertThrowsError(try progress.update(work(.completed, frames: 100))) {
            XCTAssertEqual($0 as? IOSAudioBackgroundError, .invalidProgress)
        }
        let unknown = IOSAudioTaskProgress()
        try unknown.update(IOSOpusFileSendSession.WorkProgress(phase: .completed,
            preparationCompleted: true, totalPackets: nil, sentPackets: 0, retiredPackets: 0))
        XCTAssertThrowsError(try unknown.finishSuccessfully()) {
            XCTAssertEqual($0 as? IOSAudioBackgroundError, .incompleteWork)
        }
    }

    private func makeExecution(_ scheduler: ControlledAudioBackgroundScheduler,
                               timeout: Duration = .seconds(2)) throws -> IOSAudioBackgroundExecution {
        try IOSAudioBackgroundExecution(identifier: "com.skybridge.compass.ios.audio-file." + UUID().uuidString,
            title: "Audio fixture", scheduler: scheduler, launchTimeout: timeout)
    }
    private func work(_ phase: IOSOriginalFileSendSession.Phase, frames: UInt64) -> IOSOriginalFileSendSession.WorkProgress {
        .init(phase: phase, hashedBytes: 4096, hashTotal: 4096, transferredBytes: 4096, fileBytes: 4096,
              outputFrames: frames, sourceFrames: 100)
    }
    private func until(_ condition: @escaping @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < end else { throw IOSAudioBackgroundError.launchTimedOut }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

@MainActor
final class ControlledAudioBackgroundScheduler: IOSContinuedAudioScheduler {
    var holdSubmission = false
    var submissionError: IOSAudioBackgroundError?
    private(set) var submitting = false
    private(set) var cancelled: [String] = []
    private var identifier: String?
    private var launchHandler: (@MainActor (Result<any IOSContinuedAudioTask, any Error>) -> Void)?
    private var submission: CheckedContinuation<Void, Error>?
    func submit(identifier: String, title: String,
                launch: @escaping @MainActor (Result<any IOSContinuedAudioTask, any Error>) -> Void) async throws {
        self.identifier = identifier; launchHandler = launch; submitting = true
        if holdSubmission { try await withCheckedThrowingContinuation { submission = $0 } }
        if let submissionError { throw submissionError }
    }
    func cancel(identifier: String) { cancelled.append(identifier) }
    func resolveSubmission(_ failure: IOSAudioBackgroundError? = nil) {
        guard let continuation = submission else { XCTFail("No pending system submission"); return }
        submission = nil
        if let failure { continuation.resume(throwing: failure) } else { continuation.resume() }
    }
    @discardableResult func launch(identifier: String? = nil) -> ControlledAudioBackgroundTask {
        guard let actual = identifier ?? self.identifier, let launchHandler else {
            preconditionFailure("No registered test job")
        }
        let task = ControlledAudioBackgroundTask(identifier: actual)
        launchHandler(.success(task)); return task
    }
}

@MainActor
final class ControlledAudioBackgroundTask: IOSContinuedAudioTask {
    let identifier: String
    var isExpired = false
    private(set) var completions: [Bool] = []
    private(set) var progress: Progress?
    private(set) var statuses: [IOSAudioTaskStatus] = []
    private var expiration: (@MainActor () -> Void)?
    init(identifier: String) { self.identifier = identifier }
    func attachProgress(_ progress: Progress) { self.progress = progress }
    func updateStatus(_ status: IOSAudioTaskStatus) { statuses.append(status) }
    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void) { expiration = handler }
    @discardableResult func complete(success: Bool) -> Bool {
        let accepted = success && !isExpired; completions.append(accepted); return accepted
    }
    func expire() { isExpired = true; expiration?() }
}
