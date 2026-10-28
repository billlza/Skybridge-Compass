#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation
import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

final class CoreAudioExactPcmOutputTests: XCTestCase {
    private final class Grant: @unchecked Sendable {
        private let lock = NSLock(); private var value = true
        func current() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
        func revoke() { lock.lock(); value = false; lock.unlock() }
    }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var value: TimeInterval = 0
        func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock(); private var value: Error?
        func store(_ error: Error) { lock.lock(); value = error; lock.unlock() }
        func read() -> Error? { lock.lock(); defer { lock.unlock() }; return value }
    }

    // All mutable backend/ring state is used on the output's serialized control gate. Tests inspect
    // it only before starting a concurrent operation or after joining that operation.
    private final class Ring: CoreAudioOutputRing {
        let frameBytes: Int, capacityFrames: UInt32, callbackFrames: UInt32
        var counters = CoreAudioOutputNativeSnapshot()
        var attached = false, started = false, destroyed = false
        var stopFails = false, destroyFails = false
        var snapshotFailsBeforeStop = false, snapshotFailsAfterStop = false
        var stopCalls = 0, destroyCalls = 0
        var received = Data()
        var retirements: [CoreAudioOutputRetirement] = []
        var afterEnqueue: (() -> Void)?
        var sealedFrames: UInt64?
        var paddingLimit: UInt32 = 0
        var cleanStops = 0
        var duringStop: (() -> Void)?
        init(format: AudioStreamingPCMFormat, capacityFrames: UInt32, callbackFrames: UInt32) {
            frameBytes = Int(format.bytesPerFrame); self.capacityFrames = capacityFrames; self.callbackFrames = callbackFrames
        }
        func attach(device: AudioDeviceID) throws { XCTAssertEqual(device, 71); attached = true }
        func watch(object: AudioObjectID, address: AudioObjectPropertyAddress) throws {}
        func enqueue(_ data: Data) throws {
            guard !data.isEmpty, data.count % frameBytes == 0,
                  counters.queued + UInt64(data.count / frameBytes) <= UInt64(capacityFrames) else {
                throw CoreAudioExactPcmOutputError.native(result: 7, status: nil)
            }
            received.append(data); counters.accepted += UInt64(data.count / frameBytes)
            counters.queued += UInt64(data.count / frameBytes); afterEnqueue?()
        }
        func start() throws {
            guard counters.queued > 0, sealedFrames != nil || counters.queued >= UInt64(callbackFrames) else {
                throw CoreAudioExactPcmOutputError.insufficientPrefill
            }
            started = true
        }
        func finishInput(expectedSourceFrames: UInt64, maximumPaddingFrames: UInt32) throws {
            guard expectedSourceFrames == counters.accepted else { throw CoreAudioExactPcmOutputError.sourceCountMismatch }
            sealedFrames = expectedSourceFrames; paddingLimit = maximumPaddingFrames
        }
        func retire(_ reason: CoreAudioOutputRetirement) throws { retirements.append(reason) }
        func snapshot() throws -> CoreAudioOutputNativeSnapshot {
            if snapshotFailsBeforeStop && stopCalls == 0 || snapshotFailsAfterStop && stopCalls > 0 {
                throw CoreAudioExactPcmOutputError.native(result: 5, status: -53)
            }
            return counters
        }
        func stop() throws {
            stopCalls += 1
            if stopFails { throw CoreAudioExactPcmOutputError.native(result: 13, status: -51) }
            started = false; duringStop?()
        }
        func stopAfterDrain() throws { cleanStops += 1; try stop() }
        func destroy() throws {
            destroyCalls += 1
            if destroyFails { throw CoreAudioExactPcmOutputError.native(result: 14, status: -52) }
            destroyed = true
        }
    }

    private final class Hardware: CoreAudioOutputHardware, @unchecked Sendable {
        var hogOwner: UUID?
        var acquired = 0, released = 0, resolves = 0, makeCalls = 0, verified = 0
        var values: [CoreAudioOutputProperty: CoreAudioOutputValue]
        var original: [CoreAudioOutputProperty: CoreAudioOutputValue]
        var writes: [CoreAudioOutputProperty] = []
        var failPlan = false, failListeners = false, ignoreWrites = false, releaseFails = false
        var callbackFrames: UInt32 = 2
        var ring: Ring?
        var afterWrite: (() -> Void)?
        var duringVerify: (@Sendable () -> Void)?
        var duringCurrentTime: (() -> Void)?
        var outputTiming = CoreAudioOutputTiming(deviceLatency: 3, streamLatency: 5, safetyOffset: 7, clockDomain: 0, clockSource: nil)
        var deviceTime = CoreAudioOutputDeviceTime(sampleTime: 0, hostTime: 1)
        var currentTimeFailure: Error?
        var currentTimeCalls = 0
        init() {
            let old = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
            values = [.nominalRate: .rate(48_000), .physicalFormat: .format(old), .virtualFormat: .format(old)]
            original = values
        }
        func resolve(uid: String) throws -> CoreAudioOutputEndpoint {
            resolves += 1; XCTAssertEqual(uid, "test-endpoint"); return .init(uid: uid, device: 71)
        }
        func acquireHog(_ endpoint: CoreAudioOutputEndpoint, owner: UUID) throws {
            guard hogOwner == nil else { throw CoreAudioExactPcmError.deviceBusy }
            hogOwner = owner; acquired += 1
        }
        func releaseHog(_ endpoint: CoreAudioOutputEndpoint, owner: UUID) throws {
            if releaseFails { throw CoreAudioExactPcmError.deviceBusy }
            guard hogOwner == owner else { return }; hogOwner = nil; released += 1
        }
        func plan(_ endpoint: CoreAudioOutputEndpoint, format: AudioStreamingPCMFormat) throws -> CoreAudioOutputPlan {
            if failPlan { throw CoreAudioExactPcmError.formatMismatch }
            let target = AudioStreamBasicDescription(mSampleRate: Double(format.sampleRate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonMixable,
                mBytesPerPacket: format.bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: format.bytesPerFrame,
                mChannelsPerFrame: UInt32(format.channels), mBitsPerChannel: UInt32(format.declaredValidBits), mReserved: 0)
            return .init(endpoint: endpoint, stream: 72, mutations: [
                .init(property: .nominalRate, original: try XCTUnwrap(original[.nominalRate]), applied: .rate(Double(format.sampleRate))),
                .init(property: .physicalFormat, original: try XCTUnwrap(original[.physicalFormat]), applied: .format(target)),
                .init(property: .virtualFormat, original: try XCTUnwrap(original[.virtualFormat]), applied: .format(target))
            ])
        }
        func read(_ property: CoreAudioOutputProperty, plan: CoreAudioOutputPlan) throws -> CoreAudioOutputValue {
            try XCTUnwrap(values[property])
        }
        func write(_ property: CoreAudioOutputProperty, value: CoreAudioOutputValue, plan: CoreAudioOutputPlan) throws {
            writes.append(property); if !ignoreWrites { values[property] = value }; afterWrite?()
        }
        func verify(_ plan: CoreAudioOutputPlan, format: AudioStreamingPCMFormat) throws -> UInt32 {
            verified += 1; duringVerify?()
            guard hogOwner != nil, plan.mutations.allSatisfy({ values[$0.property] == $0.applied }) else {
                throw CoreAudioExactPcmError.formatMismatch
            }
            return callbackFrames
        }
        func makeRing(owner: UUID, format: AudioStreamingPCMFormat, capacityFrames: UInt32, maximumCallbackFrames: UInt32) throws -> any CoreAudioOutputRing {
            makeCalls += 1
            let result = Ring(format: format, capacityFrames: capacityFrames, callbackFrames: maximumCallbackFrames)
            ring = result; return result
        }
        func installListeners(_ plan: CoreAudioOutputPlan, format: AudioStreamingPCMFormat, ring: any CoreAudioOutputRing) throws {
            if failListeners { throw CoreAudioExactPcmOutputError.native(result: 16, status: -71) }
        }
        func timing(_ plan: CoreAudioOutputPlan) throws -> CoreAudioOutputTiming { outputTiming }
        func currentTime(_ plan: CoreAudioOutputPlan) throws -> CoreAudioOutputDeviceTime {
            currentTimeCalls += 1; duringCurrentTime?()
            if let currentTimeFailure { throw currentTimeFailure }
            return deviceTime
        }
    }

    private func format() throws -> AudioStreamingPCMFormat {
        try .init(sampleRate: 44_100, channels: 2, encoding: .signed24, declaredValidBits: 24, waveChannelMask: 3)
    }
    private func output(_ hardware: Hardware, grant: Grant = Grant(), clock: Clock = Clock()) throws -> CoreAudioExactPcmOutput {
        try .init(ownerID: UUID(), isAuthorizationCurrent: { grant.current() }, hardware: hardware,
                  automaticMonitoring: false, now: { clock.now() }, sleep: { clock.advance($0) })
    }
    @discardableResult private func prepare(_ output: CoreAudioExactPcmOutput, capacity: Int = 48) throws -> CoreAudioExactPcmPreparedOutput {
        try output.prepare(endpointUID: "test-endpoint", format: format(), capacityBytes: capacity)
    }

    // These are deterministic HAL substitutes. They prove state/contract handling, not a physical
    // device clock, DAC output, driver latency accuracy or successful hardware restoration.
    private func submit(_ hardware: Hardware, sourceFrames: UInt64, end: Double, padding: UInt32 = 0) throws {
        let ring = try XCTUnwrap(hardware.ring)
        ring.counters.submitted = sourceFrames; ring.counters.queued = ring.counters.accepted - sourceFrames
        ring.counters.sourceTimelineValid = true; ring.counters.lastSourceEndSampleTime = end
        ring.counters.trailingPaddingFrames = padding
    }

    func testShortFiniteInputStartsAndCompletesOnlyAfterDeviceProgressAndCleanup() throws {
        let hardware = Hardware(), output = try output(hardware); try prepare(output)
        _ = try output.enqueue(Data([1, 2, 3, 4, 5, 6]), ownerID: output.ownerID)
        try output.finishInput(ownerID: output.ownerID, expectedSourceFrames: 1)
        XCTAssertEqual(output.snapshot().state, .draining); XCTAssertEqual(hardware.ring?.started, true)
        XCTAssertEqual(hardware.ring?.sealedFrames, 1); XCTAssertGreaterThan(try XCTUnwrap(hardware.ring?.paddingLimit), 2)
        try submit(hardware, sourceFrames: 1, end: 101, padding: 1)
        hardware.deviceTime = .init(sampleTime: 108, hostTime: 2); output.service()
        XCTAssertEqual(output.snapshot().drainStatus, .pending); XCTAssertEqual(hardware.released, 0)
        hardware.deviceTime = .init(sampleTime: 109, hostTime: 3); output.service()
        let complete = output.snapshot()
        XCTAssertEqual(complete.drainStatus, .completed); XCTAssertEqual(complete.state, .closed)
        XCTAssertEqual(complete.submittedFrames, 1); XCTAssertEqual(complete.trailingPaddingFrames, 1)
        XCTAssertEqual(complete.expectedSourceFrames, 1); XCTAssertTrue(complete.finalCountersVerified)
        XCTAssertEqual(hardware.ring?.cleanStops, 1); XCTAssertEqual(hardware.ring?.retirements, [])
        XCTAssertEqual(hardware.values, hardware.original); XCTAssertNil(hardware.hogOwner)
    }

    func testLateEOFUsesSavedLastSourceTimestampAndDoesNotAddSafetyOffsetTwice() throws {
        let hardware = Hardware(), output = try output(hardware); try prepare(output)
        _ = try output.enqueue(Data(repeating: 1, count: 12), ownerID: output.ownerID)
        try output.start(ownerID: output.ownerID)
        try submit(hardware, sourceFrames: 2, end: 102)
        hardware.deviceTime = .init(sampleTime: 110, hostTime: 10)
        try output.finishInput(ownerID: output.ownerID, expectedSourceFrames: 2)
        XCTAssertEqual(output.snapshot().drainStatus, .completed)
        XCTAssertEqual(output.snapshot().trailingPaddingFrames, 0)
    }

    func testEmptyFiniteInputNeverStartsOrClaimsClockEvidence() throws {
        let hardware = Hardware(), output = try output(hardware); try prepare(output)
        try output.finishInput(ownerID: output.ownerID, expectedSourceFrames: 0)
        XCTAssertEqual(output.snapshot().drainStatus, .emptyCompleted)
        XCTAssertEqual(output.snapshot().state, .closed); XCTAssertEqual(hardware.currentTimeCalls, 0)
        XCTAssertEqual(hardware.ring?.started, false); XCTAssertEqual(output.snapshot().submittedFrames, 0)
        XCTAssertEqual(output.snapshot().trailingPaddingFrames, 0); XCTAssertEqual(hardware.ring?.cleanStops, 1)
    }

    func testWrongOwnerAndWrongEndCountDoNotSealOrRetireActiveStream() throws {
        let hardware = Hardware(), output = try output(hardware); try prepare(output)
        _ = try output.enqueue(Data(repeating: 1, count: 6), ownerID: output.ownerID)
        XCTAssertThrowsError(try output.finishInput(ownerID: UUID(), expectedSourceFrames: 1)) {
            XCTAssertEqual($0 as? CoreAudioExactPcmOutputError, .wrongOwner)
        }
        XCTAssertThrowsError(try output.finishInput(ownerID: output.ownerID, expectedSourceFrames: UInt64.max)) {
            XCTAssertEqual($0 as? CoreAudioExactPcmOutputError, .sourceCountMismatch)
        }
        XCTAssertNil(hardware.ring?.sealedFrames); XCTAssertEqual(output.snapshot().state, .prepared)
        XCTAssertEqual(output.snapshot().drainStatus, .notRequested); XCTAssertNil(output.snapshot().failure)
        _ = try output.enqueue(Data(repeating: 2, count: 6), ownerID: output.ownerID)
        try output.close(ownerID: output.ownerID)
    }

    func testSealedSourceRejectsFurtherEnqueueWithoutChangingPendingDrain() throws {
        let hardware = Hardware(), output = try output(hardware); try prepare(output)
        _ = try output.enqueue(Data(repeating: 1, count: 6), ownerID: output.ownerID)
        try output.finishInput(ownerID: output.ownerID, expectedSourceFrames: 1)
        XCTAssertThrowsError(try output.enqueue(Data(repeating: 2, count: 6), ownerID: output.ownerID))
        XCTAssertEqual(output.snapshot().acceptedFrames, 1); XCTAssertEqual(output.snapshot().drainStatus, .pending)
        try output.close(ownerID: output.ownerID); XCTAssertEqual(output.snapshot().drainStatus, .failed)
    }

    func testSubmittedCountWithoutTimestampCannotComplete() throws {
        let hardware = Hardware(), output = try output(hardware); try prepare(output)
        _ = try output.enqueue(Data(repeating: 1, count: 6), ownerID: output.ownerID)
        try output.finishInput(ownerID: output.ownerID, expectedSourceFrames: 1)
        hardware.ring?.counters.submitted = 1; hardware.ring?.counters.queued = 0
        hardware.deviceTime = .init(sampleTime: 1_000, hostTime: 2); output.service()
        XCTAssertEqual(output.snapshot().drainStatus, .failed)
        XCTAssertEqual(output.snapshot().failure, "invalidTimeline"); XCTAssertEqual(hardware.ring?.cleanStops, 0)
    }

    func testStalledDeviceClockTimesOutInsteadOfCompletingByElapsedTime() throws {
        let clock = Clock(), hardware = Hardware(), output = try output(hardware, clock: clock); try prepare(output)
        _ = try output.enqueue(Data(repeating: 1, count: 6), ownerID: output.ownerID)
        try output.finishInput(ownerID: output.ownerID, expectedSourceFrames: 1)
        try submit(hardware, sourceFrames: 1, end: 100, padding: 9)
        clock.advance(3); output.service()
        XCTAssertEqual(output.snapshot().drainStatus, .failed); XCTAssertEqual(output.snapshot().failure, "drainTimedOut")
        XCTAssertEqual(output.snapshot().submittedFrames, 1); XCTAssertEqual(hardware.ring?.cleanStops, 0)
    }

    func testRegressingOrUnreadableDeviceClockFailsDrain() throws {
        for kind in 0..<3 {
            let hardware = Hardware(), output = try output(hardware); try prepare(output)
            _ = try output.enqueue(Data(repeating: 1, count: 6), ownerID: output.ownerID)
            hardware.deviceTime = .init(sampleTime: 50, hostTime: 50)
            try output.finishInput(ownerID: output.ownerID, expectedSourceFrames: 1)
            try submit(hardware, sourceFrames: 1, end: 100)
            if kind == 0 { hardware.deviceTime = .init(sampleTime: 49, hostTime: 51) }
            if kind == 1 { hardware.deviceTime = .init(sampleTime: 51, hostTime: 49) }
            if kind == 2 { hardware.currentTimeFailure = CoreAudioExactPcmOutputError.invalidTimeline }
            output.service(); XCTAssertEqual(output.snapshot().drainStatus, .failed)
            XCTAssertEqual(hardware.ring?.cleanStops, 0)
        }
    }

    func testLatencyChangeRevocationAndNativeFaultEachBlockDrain() throws {
        for kind in 0..<3 {
            let grant = Grant(), hardware = Hardware(), output = try output(hardware, grant: grant); try prepare(output)
            _ = try output.enqueue(Data(repeating: 1, count: 6), ownerID: output.ownerID)
            try output.finishInput(ownerID: output.ownerID, expectedSourceFrames: 1)
            try submit(hardware, sourceFrames: 1, end: 100)
            hardware.deviceTime = .init(sampleTime: 108, hostTime: 2)
            if kind == 0 { hardware.outputTiming = .init(deviceLatency: 4, streamLatency: 5, safetyOffset: 7, clockDomain: 0, clockSource: nil) }
            if kind == 1 { hardware.duringCurrentTime = { grant.revoke() } }
            if kind == 2 { hardware.ring?.counters.fault = 9 }
            output.service(); XCTAssertEqual(output.snapshot().drainStatus, .failed)
            XCTAssertEqual(hardware.ring?.cleanStops, 0)
        }
    }

    func testCleanupFailureCannotBecomeCompletionAfterRetry() throws {
        let hardware = Hardware(), output = try output(hardware); try prepare(output)
        _ = try output.enqueue(Data(repeating: 1, count: 6), ownerID: output.ownerID)
        try output.finishInput(ownerID: output.ownerID, expectedSourceFrames: 1)
        try submit(hardware, sourceFrames: 1, end: 100)
        hardware.deviceTime = .init(sampleTime: 108, hostTime: 2); hardware.ring?.stopFails = true
        output.service(); XCTAssertEqual(output.snapshot().state, .cleanupRequired)
        XCTAssertEqual(output.snapshot().drainStatus, .failed); XCTAssertEqual(hardware.ring?.destroyed, false)
        hardware.ring?.stopFails = false; try output.close(ownerID: output.ownerID)
        XCTAssertEqual(output.snapshot().state, .closed); XCTAssertEqual(output.snapshot().drainStatus, .failed)
    }

    func testDeviceFaultOrRevocationDuringCleanStopCannotPublishCompletion() throws {
        for revoke in [false, true] {
            let grant = Grant(), hardware = Hardware(), output = try output(hardware, grant: grant); try prepare(output)
            _ = try output.enqueue(Data(repeating: 1, count: 6), ownerID: output.ownerID)
            try output.finishInput(ownerID: output.ownerID, expectedSourceFrames: 1)
            try submit(hardware, sourceFrames: 1, end: 100)
            hardware.deviceTime = .init(sampleTime: 108, hostTime: 2)
            hardware.ring?.duringStop = { if revoke { grant.revoke() } else { hardware.ring?.counters.fault = 9 } }
            output.service(); XCTAssertEqual(output.snapshot().drainStatus, .failed)
            XCTAssertEqual(output.snapshot().state, .closed)
        }
    }

    func testFinalSnapshotFailureAndSkippedRestorationBlockCompletion() throws {
        for skipRestoration in [false, true] {
            let hardware = Hardware(), output = try output(hardware); try prepare(output)
            _ = try output.enqueue(Data(repeating: 1, count: 6), ownerID: output.ownerID)
            try output.finishInput(ownerID: output.ownerID, expectedSourceFrames: 1)
            try submit(hardware, sourceFrames: 1, end: 100)
            hardware.deviceTime = .init(sampleTime: 108, hostTime: 2)
            if skipRestoration {
                hardware.ring?.duringStop = { hardware.values[.nominalRate] = .rate(96_000) }
            } else { hardware.ring?.snapshotFailsAfterStop = true }
            output.service()
            XCTAssertEqual(output.snapshot().state, .closed); XCTAssertEqual(output.snapshot().drainStatus, .failed)
            XCTAssertNotNil(output.snapshot().failure)
            if skipRestoration {
                XCTAssertFalse(output.snapshot().skippedRestorations.isEmpty)
                XCTAssertEqual(hardware.values[.nominalRate], .rate(96_000))
            } else { XCTAssertFalse(output.snapshot().finalCountersVerified) }
        }
    }

    func testExactPreparePrefillStartAndConditionalRestoration() throws {
        let hardware = Hardware()
        let active = try self.output(hardware)
        let ready = try prepare(active, capacity: 19)
        XCTAssertEqual(ready.receiveCapacityBytes, 18); XCTAssertEqual(ready.minimumPrefillFrames, 2)
        XCTAssertEqual(active.snapshot().state, .prepared)
        let bytes = Data([1, 0, 0, 255, 255, 127, 0, 0, 128, 255, 255, 255])
        let submitted = try active.enqueue(bytes, ownerID: active.ownerID)
        XCTAssertEqual(submitted.acceptedFrames, 2); XCTAssertEqual(submitted.submittedFrames, 0)
        XCTAssertEqual(hardware.ring?.received, bytes)
        try active.start(ownerID: active.ownerID)
        hardware.ring?.counters.submitted = 2; hardware.ring?.counters.queued = 0; active.service()
        XCTAssertEqual(active.snapshot().submittedFrames, 2)
        try active.close(ownerID: active.ownerID)
        XCTAssertEqual(active.snapshot().state, .closed); XCTAssertEqual(hardware.values, hardware.original)
        XCTAssertEqual(Array(hardware.writes.suffix(3)), [.physicalFormat, .virtualFormat, .nominalRate])
        XCTAssertEqual(hardware.released, 1); XCTAssertEqual(hardware.ring?.destroyed, true)
        XCTAssertNil(active.snapshot().failure); XCTAssertTrue(active.snapshot().finalCountersVerified)
    }

    func testAuthorizationRequiredBeforeHardwareAndRecheckedAfterSetter() throws {
        let denied = Grant(); denied.revoke(); let untouched = Hardware(); let output = try output(untouched, grant: denied)
        XCTAssertThrowsError(try prepare(output)); XCTAssertEqual(untouched.resolves, 0)
        let grant = Grant(), hardware = Hardware(); hardware.afterWrite = { grant.revoke() }
        let revoked = try self.output(hardware, grant: grant)
        XCTAssertThrowsError(try prepare(revoked)) { XCTAssertEqual($0 as? CoreAudioExactPcmOutputError, .authorizationLost) }
        XCTAssertEqual(hardware.values, hardware.original); XCTAssertEqual(hardware.makeCalls, 0)
        XCTAssertEqual(hardware.released, 1); XCTAssertEqual(revoked.snapshot().state, .closed)
    }

    func testRevocationAfterEnqueueTerminatesWithoutPlaybackSuccess() throws {
        let grant = Grant(), hardware = Hardware(); let output = try output(hardware, grant: grant)
        try prepare(output); hardware.ring?.afterEnqueue = { grant.revoke() }
        XCTAssertThrowsError(try output.enqueue(Data(repeating: 1, count: 12), ownerID: output.ownerID))
        XCTAssertEqual(output.snapshot().state, .closed); XCTAssertEqual(output.snapshot().submittedFrames, 0)
        XCTAssertEqual(output.snapshot().acceptedFrames, 2); XCTAssertEqual(output.snapshot().queuedFrames, 0)
        XCTAssertEqual(hardware.ring?.destroyed, true); XCTAssertNotNil(output.snapshot().failure)
        XCTAssertEqual(hardware.ring?.retirements.first, .revoked)
    }

    func testStaleOwnerCannotStartWriteOrCloseCurrentOutput() throws {
        let hardware = Hardware(); let output = try output(hardware); try prepare(output)
        let stale = UUID()
        XCTAssertThrowsError(try output.start(ownerID: stale))
        XCTAssertThrowsError(try output.enqueue(Data(repeating: 0, count: 12), ownerID: stale))
        XCTAssertThrowsError(try output.close(ownerID: stale))
        XCTAssertEqual(output.snapshot().state, .prepared); XCTAssertEqual(hardware.released, 0)
        try output.close(ownerID: output.ownerID)
    }

    func testBusyInputIsRejectedWithoutQueueingOrTakingItsBytes() throws {
        let hardware = Hardware(); let output = try output(hardware); try prepare(output)
        _ = try output.enqueue(Data(repeating: 1, count: 12), ownerID: output.ownerID)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchGroup()
        let error = ErrorBox()
        hardware.duringVerify = { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        done.enter()
        DispatchQueue.global().async { defer { done.leave() }; do { try output.start(ownerID: output.ownerID) } catch let failure { error.store(failure) } }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        XCTAssertThrowsError(try output.enqueue(Data(repeating: 2, count: 12), ownerID: output.ownerID)) {
            XCTAssertEqual($0 as? CoreAudioExactPcmOutputError, .busy)
        }
        release.signal(); XCTAssertEqual(done.wait(timeout: .now() + 5), .success); XCTAssertNil(error.read())
        XCTAssertEqual(hardware.ring?.received.count, 12); hardware.duringVerify = nil
        try output.close(ownerID: output.ownerID)
    }

    func testStopFailureRetainsCallbackContextSettingsAndHogForRetry() throws {
        let hardware = Hardware(); let output = try output(hardware); try prepare(output)
        hardware.ring?.stopFails = true
        XCTAssertThrowsError(try output.close(ownerID: output.ownerID))
        XCTAssertEqual(output.snapshot().state, .cleanupRequired); XCTAssertFalse(output.snapshot().cleanupFailures.isEmpty)
        XCTAssertEqual(hardware.ring?.destroyCalls, 0); XCTAssertEqual(hardware.released, 0)
        XCTAssertNotEqual(hardware.values, hardware.original)
        hardware.ring?.stopFails = false; try output.close(ownerID: output.ownerID)
        XCTAssertEqual(output.snapshot().state, .closed); XCTAssertEqual(hardware.values, hardware.original)
        XCTAssertEqual(hardware.released, 1); XCTAssertNotNil(output.snapshot().failure)
    }

    func testDestroyAndHogReleaseFailuresRemainRetryable() throws {
        let hardware = Hardware(); let output = try output(hardware); try prepare(output)
        hardware.ring?.destroyFails = true
        XCTAssertThrowsError(try output.close(ownerID: output.ownerID)); XCTAssertEqual(hardware.released, 0)
        hardware.ring?.destroyFails = false; hardware.releaseFails = true
        XCTAssertThrowsError(try output.close(ownerID: output.ownerID)); XCTAssertEqual(hardware.ring?.destroyed, true)
        XCTAssertEqual(output.snapshot().state, .cleanupRequired)
        hardware.releaseFails = false; try output.close(ownerID: output.ownerID)
        XCTAssertEqual(output.snapshot().state, .closed); XCTAssertEqual(hardware.ring?.destroyCalls, 2)
    }

    func testPartialListenerInitializationIsCleanedBeforeAnyStart() throws {
        let hardware = Hardware(); hardware.failListeners = true; let output = try output(hardware)
        XCTAssertThrowsError(try prepare(output))
        XCTAssertEqual(hardware.ring?.attached, false); XCTAssertEqual(hardware.ring?.destroyed, true)
        XCTAssertEqual(hardware.released, 1); XCTAssertEqual(hardware.values, hardware.original)
    }

    func testNativeFaultAndAuthorizationExpiryAreServiced() throws {
        let hardware = Hardware(); let output = try output(hardware); try prepare(output)
        hardware.ring?.counters.fault = 9; output.service()
        XCTAssertEqual(output.snapshot().state, .closed); XCTAssertNotNil(output.snapshot().failure)
        XCTAssertEqual(hardware.ring?.stopCalls, 1)
        let grant = Grant(), otherHardware = Hardware(); let other = try self.output(otherHardware, grant: grant)
        try prepare(other); grant.revoke(); other.service()
        XCTAssertEqual(other.snapshot().state, .closed); XCTAssertEqual(otherHardware.released, 1)
    }

    func testPreparedDeadlineAndAutomaticCleanupRetriesAreBounded() throws {
        let clock = Clock(), hardware = Hardware(); let output = try output(hardware, clock: clock)
        try prepare(output); hardware.ring?.stopFails = true; clock.advance(11); output.service()
        XCTAssertEqual(output.snapshot().state, .cleanupRequired)
        for _ in 0..<10 { output.service() }
        XCTAssertEqual(hardware.ring?.stopCalls, 4) // First close plus three bounded automatic retries.
        XCTAssertEqual(hardware.ring?.destroyCalls, 0)
        hardware.ring?.stopFails = false; try output.close(ownerID: output.ownerID)
    }

    func testExternalPropertyChangeIsNotOverwrittenDuringCleanup() throws {
        let hardware = Hardware(); let output = try output(hardware); try prepare(output)
        let external = CoreAudioOutputValue.rate(88_200)
        hardware.values[.nominalRate] = external
        let beforeCleanup = hardware.values, writeCount = hardware.writes.count
        hardware.afterWrite = { XCTFail("A format setter could indirectly overwrite the external value") }
        XCTAssertThrowsError(try output.close(ownerID: output.ownerID)) {
            XCTAssertEqual($0 as? CoreAudioExactPcmOutputError, .restorationSkipped)
        }
        XCTAssertEqual(hardware.values, beforeCleanup); XCTAssertEqual(hardware.writes.count, writeCount)
        XCTAssertEqual(hardware.values[.nominalRate], external); XCTAssertEqual(hardware.released, 1)
        XCTAssertEqual(output.snapshot().state, .closed)
        XCTAssertEqual(output.snapshot().skippedRestorations, ["physicalFormat", "virtualFormat", "nominalRate"])
        XCTAssertThrowsError(try output.close(ownerID: output.ownerID)) // A repeat must not hide the residue.
    }

    func testSnapshotFailureStillStopsAndRetainsIndependentStopFailure() throws {
        let hardware = Hardware(); let output = try output(hardware); try prepare(output)
        let ring = try XCTUnwrap(hardware.ring)
        ring.snapshotFailsBeforeStop = true; ring.stopFails = true
        XCTAssertThrowsError(try output.close(ownerID: output.ownerID)) {
            XCTAssertEqual($0 as? CoreAudioExactPcmOutputError, .cleanupRequired)
        }
        XCTAssertEqual(ring.stopCalls, 1); XCTAssertEqual(ring.destroyCalls, 0); XCTAssertEqual(hardware.released, 0)
        XCTAssertEqual(output.snapshot().cleanupFailures.count, 2)
        XCTAssertTrue(output.snapshot().cleanupFailures.contains { $0.contains("snapshot before stop") })
        XCTAssertTrue(output.snapshot().cleanupFailures.contains { $0.contains("stop: ") })
        XCTAssertFalse(output.snapshot().finalCountersVerified)
        ring.snapshotFailsBeforeStop = false; ring.stopFails = false
        XCTAssertThrowsError(try output.close(ownerID: output.ownerID)) {
            XCTAssertEqual($0 as? CoreAudioExactPcmOutputError, .cleanupDiagnostics)
        }
        XCTAssertEqual(output.snapshot().state, .closed); XCTAssertTrue(output.snapshot().finalCountersVerified)
        XCTAssertEqual(ring.destroyCalls, 1); XCTAssertEqual(hardware.released, 1)
        XCTAssertEqual(output.snapshot().cleanupFailures.count, 2) // Retry does not erase either error.
    }

    func testFinalSnapshotFailureDoesNotPreventSafeDestroyOrInventFinalCounts() throws {
        let hardware = Hardware(); let output = try output(hardware); try prepare(output)
        let ring = try XCTUnwrap(hardware.ring)
        _ = try output.enqueue(Data(repeating: 1, count: 12), ownerID: output.ownerID)
        ring.snapshotFailsAfterStop = true
        XCTAssertThrowsError(try output.close(ownerID: output.ownerID)) {
            XCTAssertEqual($0 as? CoreAudioExactPcmOutputError, .cleanupDiagnostics)
        }
        XCTAssertEqual(ring.stopCalls, 1); XCTAssertEqual(ring.destroyCalls, 1); XCTAssertEqual(hardware.released, 1)
        XCTAssertEqual(output.snapshot().state, .closed); XCTAssertFalse(output.snapshot().finalCountersVerified)
        XCTAssertEqual(output.snapshot().acceptedFrames, 2); XCTAssertEqual(output.snapshot().queuedFrames, 0)
        XCTAssertTrue(output.snapshot().cleanupFailures.contains { $0.contains("snapshot after stop") })
    }

    func testLateRestorationSetterChangingEarlierPropertyRequiresAnotherVerifiedPass() throws {
        let hardware = Hardware(); let output = try output(hardware); try prepare(output)
        let appliedVirtual = try XCTUnwrap(hardware.values[.virtualFormat])
        var didCouple = false
        hardware.afterWrite = {
            if hardware.writes.last == .nominalRate, hardware.values[.nominalRate] == hardware.original[.nominalRate], !didCouple {
                hardware.values[.virtualFormat] = appliedVirtual; didCouple = true
            }
        }
        try output.close(ownerID: output.ownerID)
        XCTAssertTrue(didCouple); XCTAssertEqual(output.snapshot().state, .closed)
        XCTAssertEqual(hardware.values, hardware.original); XCTAssertEqual(hardware.released, 1)
        XCTAssertEqual(Array(hardware.writes.suffix(4)), [.physicalFormat, .virtualFormat, .nominalRate, .virtualFormat])
    }

    func testNonconvergingRestorationIsBoundedAndKeepsHogForExplicitRetry() throws {
        let hardware = Hardware(); let output = try output(hardware); try prepare(output)
        let appliedVirtual = try XCTUnwrap(hardware.values[.virtualFormat])
        let appliedPhysical = try XCTUnwrap(hardware.values[.physicalFormat])
        let beforeCleanup = hardware.writes.count
        hardware.afterWrite = {
            if hardware.writes.last == .physicalFormat { hardware.values[.virtualFormat] = appliedVirtual }
            if hardware.writes.last == .virtualFormat { hardware.values[.physicalFormat] = appliedPhysical }
        }
        XCTAssertThrowsError(try output.close(ownerID: output.ownerID)) {
            XCTAssertEqual($0 as? CoreAudioExactPcmOutputError, .cleanupRequired)
        }
        XCTAssertEqual(hardware.writes.count - beforeCleanup, 7) // Exactly three bounded passes.
        XCTAssertEqual(output.snapshot().state, .cleanupRequired); XCTAssertEqual(hardware.released, 0)
        XCTAssertEqual(hardware.ring?.destroyed, true); XCTAssertNotNil(hardware.hogOwner)
        XCTAssertTrue(output.snapshot().cleanupFailures.contains { $0.contains("restorationDidNotConverge") })
        hardware.afterWrite = nil; try output.close(ownerID: output.ownerID)
        XCTAssertEqual(hardware.values, hardware.original); XCTAssertEqual(hardware.released, 1)
        XCTAssertEqual(output.snapshot().state, .closed); XCTAssertNotNil(output.snapshot().failure)
    }

    func testThirdValueAfterRestorationBeginsIsNeverOverwrittenOrReportedRestored() throws {
        let hardware = Hardware(); let output = try output(hardware); try prepare(output)
        guard case .format(var foreignDescription) = try XCTUnwrap(hardware.values[.virtualFormat]) else {
            return XCTFail("Fixture must provide an ASBD for the virtual stream")
        }
        foreignDescription.mSampleRate = 88_200
        let foreign = CoreAudioOutputValue.format(foreignDescription)
        hardware.afterWrite = {
            if hardware.writes.last == .nominalRate { hardware.values[.virtualFormat] = foreign }
        }
        XCTAssertThrowsError(try output.close(ownerID: output.ownerID))
        XCTAssertEqual(output.snapshot().state, .cleanupRequired); XCTAssertEqual(hardware.released, 0)
        XCTAssertEqual(hardware.values[.virtualFormat], foreign)
        let writeCount = hardware.writes.count
        XCTAssertThrowsError(try output.close(ownerID: output.ownerID))
        XCTAssertEqual(hardware.writes.count, writeCount); XCTAssertEqual(hardware.values[.virtualFormat], foreign)
        hardware.afterWrite = nil; hardware.values[.virtualFormat] = hardware.original[.virtualFormat]
        try output.close(ownerID: output.ownerID)
        XCTAssertEqual(hardware.values, hardware.original); XCTAssertEqual(hardware.released, 1)
    }

    func testUnsupportedFormatAndNonsettlingSetterDoNotProducePreparedOutput() throws {
        let unsupported = Hardware(); unsupported.failPlan = true; let output = try output(unsupported)
        XCTAssertThrowsError(try prepare(output)); XCTAssertEqual(unsupported.makeCalls, 0); XCTAssertEqual(unsupported.released, 1)
        let clock = Clock(), stuck = Hardware(); stuck.ignoreWrites = true; let other = try self.output(stuck, clock: clock)
        XCTAssertThrowsError(try prepare(other)) { XCTAssertEqual($0 as? CoreAudioExactPcmOutputError, .formatDidNotSettle) }
        XCTAssertLessThanOrEqual(clock.now(), 0.51); XCTAssertEqual(stuck.makeCalls, 0); XCTAssertEqual(stuck.released, 1)
    }

    func testInsufficientPrefillRemainsPreparedAndBufferChangeFailsStart() throws {
        let hardware = Hardware(); let output = try output(hardware); try prepare(output)
        XCTAssertThrowsError(try output.start(ownerID: output.ownerID)) {
            XCTAssertEqual($0 as? CoreAudioExactPcmOutputError, .insufficientPrefill)
        }
        XCTAssertEqual(output.snapshot().state, .prepared)
        _ = try output.enqueue(Data(repeating: 1, count: 12), ownerID: output.ownerID)
        hardware.callbackFrames = 3
        XCTAssertThrowsError(try output.start(ownerID: output.ownerID))
        XCTAssertEqual(output.snapshot().state, .closed); XCTAssertEqual(hardware.ring?.started, false)
    }
}
#endif
