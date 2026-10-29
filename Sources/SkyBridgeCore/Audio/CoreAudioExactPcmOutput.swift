#if os(macOS)
import CoreAudio
import Foundation
import SkyBridgeProtocolCore

public enum CoreAudioExactPcmOutputError: Error, Equatable, Sendable {
    case invalidOwner, wrongOwner, busy, invalidState, invalidCapacity, authorizationLost
    case insufficientPrefill, prepareExpired, formatDidNotSettle, deviceChanged
    case sourceCountMismatch, invalidTimeline, drainTimedOut, unsupportedDrainLatency
    case native(result: Int32, status: OSStatus?), nativeFault(UInt32)
    case cleanupRequired, restorationSkipped, cleanupDiagnostics, restorationConflict, restorationDidNotConverge
}

public struct CoreAudioExactPcmOutputSnapshot: Sendable, Equatable {
    public enum State: String, Sendable { case idle, preparing, prepared, running, draining, closing, cleanupRequired, closed }
    public enum DrainStatus: String, Sendable {
        case notRequested, pending, failed
        /// Same HAL device timeline passed the source endpoint plus reported device/stream latency,
        /// then native Stop and resource restoration succeeded. This is not physical DAC proof.
        case completed
        /// Zero source frames, never started; successful cleanup with no device-clock claim.
        case emptyCompleted
    }
    public let ownerID: UUID
    public let state: State
    public let acceptedFrames: UInt64
    public let submittedFrames: UInt64
    public let queuedFrames: UInt64
    /// Counters are last observed values; only this flag proves a successful snapshot after native Stop.
    public let finalCountersVerified: Bool
    public let failure: String?
    public let cleanupFailures: [String]
    public let skippedRestorations: [String]
    public let drainStatus: DrainStatus
    public let expectedSourceFrames: UInt64?
    public let trailingPaddingFrames: UInt32
}

public struct CoreAudioExactPcmPreparedOutput: Sendable, Equatable {
    public let endpointUID: String
    public let format: AudioStreamingPCMFormat
    public let receiveCapacityBytes: Int
    public let minimumPrefillFrames: UInt32
}

struct CoreAudioOutputEndpoint: Sendable, Equatable { let uid: String; let device: AudioDeviceID }
enum CoreAudioOutputProperty: String, CaseIterable, Hashable, Sendable { case nominalRate, physicalFormat, virtualFormat }
enum CoreAudioOutputValue: Equatable, Sendable {
    case rate(Double), format(AudioStreamBasicDescription)
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.rate(a), .rate(b)): return a == b
        case let (.format(a), .format(b)):
            return a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
                && a.mBytesPerPacket == b.mBytesPerPacket && a.mFramesPerPacket == b.mFramesPerPacket
                && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame
                && a.mBitsPerChannel == b.mBitsPerChannel && a.mReserved == b.mReserved
        default: return false
        }
    }
}
struct CoreAudioOutputMutation: Sendable {
    let property: CoreAudioOutputProperty
    let original: CoreAudioOutputValue
    let applied: CoreAudioOutputValue
}
struct CoreAudioOutputPlan: Sendable {
    let endpoint: CoreAudioOutputEndpoint
    let stream: AudioStreamID
    let mutations: [CoreAudioOutputMutation]
}
struct CoreAudioOutputNativeSnapshot: Sendable {
    var accepted: UInt64 = 0, submitted: UInt64 = 0, queued: UInt64 = 0
    var fault: UInt32 = 0
    var trailingPaddingFrames: UInt32 = 0
    var sourceTimelineValid = false
    var lastSourceEndSampleTime: Double = 0
}
struct CoreAudioOutputTiming: Equatable, Sendable {
    let deviceLatency: UInt32, streamLatency: UInt32, safetyOffset: UInt32, clockDomain: UInt32
    let clockSource: UInt32?
    var latencyFrames: UInt64 { UInt64(deviceLatency) + UInt64(streamLatency) }
}
struct CoreAudioOutputDeviceTime: Sendable {
    let sampleTime: Double
    let hostTime: UInt64
}
enum CoreAudioOutputRetirement: Equatable { case stopped, revoked, deviceChanged }

protocol CoreAudioOutputRing: AnyObject {
    func attach(device: AudioDeviceID) throws
    func watch(object: AudioObjectID, address: AudioObjectPropertyAddress) throws
    func enqueue(_ data: Data) throws
    func start() throws
    func finishInput(expectedSourceFrames: UInt64, maximumPaddingFrames: UInt32) throws
    func retire(_ reason: CoreAudioOutputRetirement) throws
    func snapshot() throws -> CoreAudioOutputNativeSnapshot
    func stop() throws
    func stopAfterDrain() throws
    func destroy() throws
}
protocol CoreAudioOutputHardware: AnyObject {
    func resolve(uid: String) throws -> CoreAudioOutputEndpoint
    func acquireHog(_ endpoint: CoreAudioOutputEndpoint, owner: UUID) throws
    func releaseHog(_ endpoint: CoreAudioOutputEndpoint, owner: UUID) throws
    func plan(_ endpoint: CoreAudioOutputEndpoint, format: AudioStreamingPCMFormat) throws -> CoreAudioOutputPlan
    func read(_ property: CoreAudioOutputProperty, plan: CoreAudioOutputPlan) throws -> CoreAudioOutputValue
    func write(_ property: CoreAudioOutputProperty, value: CoreAudioOutputValue, plan: CoreAudioOutputPlan) throws
    func verify(_ plan: CoreAudioOutputPlan, format: AudioStreamingPCMFormat) throws -> UInt32
    func makeRing(owner: UUID, format: AudioStreamingPCMFormat, capacityFrames: UInt32, maximumCallbackFrames: UInt32) throws -> any CoreAudioOutputRing
    func installListeners(_ plan: CoreAudioOutputPlan, format: AudioStreamingPCMFormat, ring: any CoreAudioOutputRing) throws
    func timing(_ plan: CoreAudioOutputPlan) throws -> CoreAudioOutputTiming
    func currentTime(_ plan: CoreAudioOutputPlan) throws -> CoreAudioOutputDeviceTime
}

/// A synchronous, serialized native owner. Prepare/close may wait for bounded HAL format settling;
/// call them off the UI thread. Enqueue never queues a task or waits for the control lock: .busy
/// leaves ownership of the unaccepted bytes with the caller. The authorization predicate must be
/// synchronous, thread-safe and non-reentrant; it has no permissive default.
///
/// The coalescing timer retains this owner while native cleanup is outstanding. After three automatic
/// cleanup retries it parks the obligation as cleanupRequired for explicit close() retry; it never
/// frees a live callback context or releases a device whose stream may still be running.
/// Submitted counts source copied to HAL, never played. finishInput requests a bounded drain using
/// the same HAL device's sample timeline and reported latency, followed by successful cleanup.
public final class CoreAudioExactPcmOutput: @unchecked Sendable {
    public let ownerID: UUID
    private let lock = NSLock()
    private let hardware: any CoreAudioOutputHardware
    private let isAuthorizationCurrent: @Sendable () -> Bool
    private let now: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) -> Void
    private let automaticMonitoring: Bool
    private let timerQueue = DispatchQueue(label: "com.skybridge.audio.exact-output-control", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var state: CoreAudioExactPcmOutputSnapshot.State = .idle
    private var endpoint: CoreAudioOutputEndpoint?
    private var plan: CoreAudioOutputPlan?
    private var pendingRestorations: [CoreAudioOutputMutation] = []
    private var restorationStarted = false
    private var hogReleaseRequired = false
    private var ring: (any CoreAudioOutputRing)?
    private var format: AudioStreamingPCMFormat?
    private var native = CoreAudioOutputNativeSnapshot()
    private var failure: String?
    private var cleanupFailures: [String] = []
    private var recordedCleanupStages: Set<String> = []
    private var cleanupDiagnosticOccurred = false
    private var finalCountersVerified = false
    private var skippedRestorations: [String] = []
    private var preparedDeadline: TimeInterval = 0
    private var maximumCallbackFrames: UInt32 = 0
    private var automaticCleanupAttempts = 0
    private var timing: CoreAudioOutputTiming?
    private var expectedSourceFrames: UInt64?
    private var drainStatus: CoreAudioExactPcmOutputSnapshot.DrainStatus = .notRequested
    private var drainDeadline: TimeInterval = 0
    private var lastDeviceTime: CoreAudioOutputDeviceTime?

    public convenience init(ownerID: UUID, isAuthorizationCurrent: @escaping @Sendable () -> Bool) throws {
        try self.init(ownerID: ownerID, isAuthorizationCurrent: isAuthorizationCurrent,
            hardware: CoreAudioOutputNativeHardware.shared, automaticMonitoring: true,
            now: { ProcessInfo.processInfo.systemUptime }, sleep: { Thread.sleep(forTimeInterval: $0) })
    }

    init(ownerID: UUID, isAuthorizationCurrent: @escaping @Sendable () -> Bool,
         hardware: any CoreAudioOutputHardware, automaticMonitoring: Bool,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
        guard ownerID != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) else { throw CoreAudioExactPcmOutputError.invalidOwner }
        self.ownerID = ownerID; self.hardware = hardware; self.isAuthorizationCurrent = isAuthorizationCurrent
        self.automaticMonitoring = automaticMonitoring; self.now = now; self.sleep = sleep
    }

    public func prepare(endpointUID: String, format: AudioStreamingPCMFormat, capacityBytes: Int = 1_048_576) throws -> CoreAudioExactPcmPreparedOutput {
        lock.lock(); defer { lock.unlock() }
        guard state == .idle else { throw CoreAudioExactPcmOutputError.invalidState }
        guard capacityBytes > 0, capacityBytes <= 1_048_576,
              capacityBytes / Int(format.bytesPerFrame) > 0 else { throw CoreAudioExactPcmOutputError.invalidCapacity }
        state = .preparing; self.format = format; startMonitorLocked()
        do {
            try authorized()
            let endpoint = try hardware.resolve(uid: endpointUID); self.endpoint = endpoint
            try authorized()
            hogReleaseRequired = true // Includes a setter that succeeded before its readback failed.
            try hardware.acquireHog(endpoint, owner: ownerID)
            try authorized()
            let plan = try hardware.plan(endpoint, format: format); self.plan = plan
            // Track all target properties before the first setter: setting one can change the others.
            // Restore the physical stream first: its rate change may itself restore the nominal
            // rate/virtual format. Their later equality checks then avoid redundant setters.
            pendingRestorations = plan.mutations.sorted {
                func order(_ property: CoreAudioOutputProperty) -> Int {
                    switch property { case .nominalRate: 0; case .virtualFormat: 1; case .physicalFormat: 2 }
                }
                return order($0.property) < order($1.property)
            }
            for mutation in plan.mutations {
                try authorized()
                if try hardware.read(mutation.property, plan: plan) != mutation.applied {
                    try authorized()
                    try hardware.write(mutation.property, value: mutation.applied, plan: plan)
                    try settle(mutation.property, value: mutation.applied, plan: plan, requiresAuthorization: true)
                }
            }
            try authorized()
            let callbackFrames = try hardware.verify(plan, format: format)
            maximumCallbackFrames = callbackFrames
            try authorized()
            let capacityFrames = UInt32(capacityBytes / Int(format.bytesPerFrame))
            guard callbackFrames > 0, capacityFrames >= callbackFrames else { throw CoreAudioExactPcmOutputError.invalidCapacity }
            let nativeRing = try hardware.makeRing(owner: ownerID, format: format,
                capacityFrames: capacityFrames, maximumCallbackFrames: callbackFrames)
            ring = nativeRing
            try authorized()
            let timing = try hardware.timing(plan)
            try hardware.installListeners(plan, format: format, ring: nativeRing)
            try authorized()
            guard try hardware.verify(plan, format: format) == callbackFrames else { throw CoreAudioExactPcmOutputError.deviceChanged }
            guard try hardware.timing(plan) == timing else { throw CoreAudioExactPcmOutputError.deviceChanged }
            self.timing = timing
            try authorized()
            try nativeRing.attach(device: endpoint.device)
            try authorized()
            native = try nativeRing.snapshot()
            guard native.fault == 0 else { throw CoreAudioExactPcmOutputError.nativeFault(native.fault) }
            state = .prepared; preparedDeadline = now() + 10
            return .init(endpointUID: endpointUID, format: format,
                         receiveCapacityBytes: Int(capacityFrames) * Int(format.bytesPerFrame),
                         minimumPrefillFrames: callbackFrames)
        } catch {
            terminateLocked(error, retirement: .stopped)
            throw error
        }
    }

    public func enqueue(_ bytes: Data, ownerID: UUID) throws -> CoreAudioExactPcmOutputSnapshot {
        guard ownerID == self.ownerID else { throw CoreAudioExactPcmOutputError.wrongOwner }
        guard lock.try() else { throw CoreAudioExactPcmOutputError.busy }
        defer { lock.unlock() }
        guard state == .prepared || state == .running, let ring else { throw CoreAudioExactPcmOutputError.invalidState }
        do {
            try authorized()
            try ring.enqueue(bytes)
            try authorized()
            native = try ring.snapshot()
            guard native.fault == 0 else { throw CoreAudioExactPcmOutputError.nativeFault(native.fault) }
            return snapshotLocked()
        } catch {
            terminateLocked(error, retirement: isAuthorizationCurrent() ? .stopped : .revoked)
            throw error
        }
    }

    public func start(ownerID: UUID) throws {
        guard ownerID == self.ownerID else { throw CoreAudioExactPcmOutputError.wrongOwner }
        lock.lock(); defer { lock.unlock() }
        guard state == .prepared, let ring, let plan, let format else { throw CoreAudioExactPcmOutputError.invalidState }
        do {
            try authorized()
            guard try hardware.verify(plan, format: format) == maximumCallbackFrames else { throw CoreAudioExactPcmOutputError.deviceChanged }
            try authorized()
            try ring.start()
            try authorized()
            native = try ring.snapshot()
            guard native.fault == 0 else { throw CoreAudioExactPcmOutputError.nativeFault(native.fault) }
            state = .running
        } catch CoreAudioExactPcmOutputError.insufficientPrefill {
            throw CoreAudioExactPcmOutputError.insufficientPrefill
        } catch {
            terminateLocked(error, retirement: isAuthorizationCurrent() ? .stopped : .revoked)
            throw error
        }
    }

    public func close(ownerID: UUID) throws {
        guard ownerID == self.ownerID else { throw CoreAudioExactPcmOutputError.wrongOwner }
        lock.lock(); defer { lock.unlock() }
        if state == .idle { state = .closed; return }
        if state != .closed {
            if drainStatus == .pending { drainStatus = .failed; if failure == nil { failure = "Drain cancelled" } }
            closeLocked(retirement: .stopped)
        }
        if state == .cleanupRequired { throw CoreAudioExactPcmOutputError.cleanupRequired }
        if !skippedRestorations.isEmpty { throw CoreAudioExactPcmOutputError.restorationSkipped }
        if cleanupDiagnosticOccurred { throw CoreAudioExactPcmOutputError.cleanupDiagnostics }
    }

    public func snapshot() -> CoreAudioExactPcmOutputSnapshot {
        lock.lock(); defer { lock.unlock() }; return snapshotLocked()
    }

    /// Seal an authenticated finite source after its end/count/hash checks. A wrong owner/count
    /// leaves the active stream untouched. This never waits for playback: the monitor advances the
    /// drain. An unstarted short stream is started here; a zero-frame stream is only cleaned up.
    public func finishInput(ownerID: UUID, expectedSourceFrames: UInt64) throws {
        guard ownerID == self.ownerID else { throw CoreAudioExactPcmOutputError.wrongOwner }
        guard lock.try() else { throw CoreAudioExactPcmOutputError.busy }
        defer { lock.unlock() }
        guard state == .prepared || state == .running, let ring, let plan, let format, let timing else {
            throw CoreAudioExactPcmOutputError.invalidState
        }
        // accepted is producer-owned and updated before every successful enqueue returns. Do not
        // touch native state on a caller's mismatched end count.
        guard expectedSourceFrames == native.accepted else { throw CoreAudioExactPcmOutputError.sourceCountMismatch }
        self.expectedSourceFrames = expectedSourceFrames; drainStatus = .pending
        do {
            try authorized()
            guard try hardware.verify(plan, format: format) == maximumCallbackFrames,
                  try hardware.timing(plan) == timing else { throw CoreAudioExactPcmOutputError.deviceChanged }
            native = try ring.snapshot()
            guard native.fault == 0 else { throw CoreAudioExactPcmOutputError.nativeFault(native.fault) }
            // The 180-second hard ceiling bounds unusual driver latency and a stalled control
            // executor. Wall time only triggers failure; it never supplies playback evidence.
            let seconds = expectedSourceFrames == 0 ? 2 : Double(native.queued + timing.latencyFrames) / Double(format.sampleRate) + 2
            guard seconds.isFinite, seconds <= 180 else { throw CoreAudioExactPcmOutputError.unsupportedDrainLatency }
            let paddingBudget = ceil(seconds * Double(format.sampleRate)) + Double(maximumCallbackFrames)
            guard paddingBudget <= Double(UInt32.max) else { throw CoreAudioExactPcmOutputError.unsupportedDrainLatency }
            drainDeadline = now() + seconds
            try ring.finishInput(expectedSourceFrames: expectedSourceFrames, maximumPaddingFrames: UInt32(paddingBudget))
            try authorized()
            if expectedSourceFrames == 0 {
                completeDrainLocked(empty: true)
                return
            }
            if state == .prepared { try ring.start() }
            try authorized()
            state = .draining
            try advanceDrainLocked()
        } catch {
            terminateLocked(error, retirement: isAuthorizationCurrent() ? .stopped : .revoked)
            throw error
        }
    }

    // Internal for deterministic substitute-backend tests. Timer uses the same single control gate.
    func service() {
        guard lock.try() else { return }; defer { lock.unlock() }
        if state == .cleanupRequired {
            guard automaticCleanupAttempts < 3 else { return }
            automaticCleanupAttempts += 1; closeLocked(retirement: .stopped)
            if automaticCleanupAttempts == 3, state == .cleanupRequired { timer?.schedule(deadline: .distantFuture) }
            return
        }
        guard state == .prepared || state == .running || state == .draining, let ring else { return }
        do {
            try authorized()
            if state == .prepared, now() >= preparedDeadline { throw CoreAudioExactPcmOutputError.prepareExpired }
            native = try ring.snapshot()
            if native.fault != 0 {
                // Native listener has already disarmed output. Re-read for a precise failure;
                // even a transient change terminates this strict-continuity generation.
                if let plan, let format { _ = try hardware.verify(plan, format: format) }
                throw CoreAudioExactPcmOutputError.nativeFault(native.fault)
            }
            if state == .draining { try advanceDrainLocked() }
        } catch {
            terminateLocked(error, retirement: isAuthorizationCurrent() ? .deviceChanged : .revoked)
        }
    }

    private func advanceDrainLocked() throws {
        guard let ring, let plan, let timing, let expectedSourceFrames else { throw CoreAudioExactPcmOutputError.invalidState }
        try authorized()
        guard now() < drainDeadline else { throw CoreAudioExactPcmOutputError.drainTimedOut }
        guard try hardware.timing(plan) == timing else { throw CoreAudioExactPcmOutputError.deviceChanged }
        native = try ring.snapshot()
        guard native.fault == 0 else { throw CoreAudioExactPcmOutputError.nativeFault(native.fault) }
        let deviceTime = try hardware.currentTime(plan)
        guard deviceTime.sampleTime.isFinite, abs(deviceTime.sampleTime) <= 9_007_199_254_740_991 else {
            throw CoreAudioExactPcmOutputError.invalidTimeline
        }
        if let previous = lastDeviceTime {
            guard deviceTime.sampleTime >= previous.sampleTime, deviceTime.hostTime >= previous.hostTime else {
                throw CoreAudioExactPcmOutputError.invalidTimeline
            }
        }
        lastDeviceTime = deviceTime
        try authorized()
        guard native.submitted == expectedSourceFrames else { return }
        guard native.sourceTimelineValid, native.lastSourceEndSampleTime.isFinite,
              abs(native.lastSourceEndSampleTime) <= 9_007_199_254_740_991 - Double(timing.latencyFrames) else {
            throw CoreAudioExactPcmOutputError.invalidTimeline
        }
        // IOProc inOutputTime already identifies the first frame's hardware handoff. Do not add
        // buffer frames or safety offset again; Apple's total device latency is device + stream.
        if deviceTime.sampleTime >= native.lastSourceEndSampleTime + Double(timing.latencyFrames) {
            completeDrainLocked(empty: false)
        }
    }

    private func completeDrainLocked(empty: Bool) {
        closeLocked(retirement: .stopped, afterDrain: true)
        if now() >= drainDeadline, failure == nil { failure = "drainTimedOut" }
        guard state == .closed, finalCountersVerified, failure == nil, cleanupFailures.isEmpty,
              skippedRestorations.isEmpty, native.fault == 0, native.submitted == expectedSourceFrames,
              isAuthorizationCurrent() else {
            drainStatus = .failed
            if failure == nil { failure = isAuthorizationCurrent() ? "Drain cleanup was not verified" : "authorizationLost" }
            return
        }
        drainStatus = empty ? .emptyCompleted : .completed
    }

    private func authorized() throws {
        guard isAuthorizationCurrent() else { throw CoreAudioExactPcmOutputError.authorizationLost }
    }

    private func settle(_ property: CoreAudioOutputProperty, value: CoreAudioOutputValue,
                        plan: CoreAudioOutputPlan, requiresAuthorization: Bool) throws {
        let deadline = now() + 0.5
        for _ in 0..<51 {
            if requiresAuthorization { try authorized() }
            if try hardware.read(property, plan: plan) == value { return }
            guard now() < deadline else { break }
            sleep(0.01)
        }
        throw CoreAudioExactPcmOutputError.formatDidNotSettle
    }

    private func terminateLocked(_ error: Error, retirement: CoreAudioOutputRetirement) {
        if drainStatus == .pending { drainStatus = .failed }
        if failure == nil { failure = String(describing: error) }
        closeLocked(retirement: retirement)
    }

    private func closeLocked(retirement: CoreAudioOutputRetirement, afterDrain: Bool = false) {
        state = .closing
        if let ring {
            // A diagnostic read cannot veto the independent exact-owner Stop operation. Retire
            // failures are also retained while Stop gets a chance to quiesce the native context.
            do { if !afterDrain { try ring.retire(retirement) } }
            catch { recordCleanupFailure("retire", error: error); cleanupDiagnosticOccurred = true }
            do { native = try ring.snapshot() }
            catch { recordCleanupFailure("snapshot before stop", error: error); cleanupDiagnosticOccurred = true }
            do { if afterDrain { try ring.stopAfterDrain() } else { try ring.stop() } }
            catch { recordCleanupFailure("stop", error: error); state = .cleanupRequired; return }
            do { native = try ring.snapshot(); finalCountersVerified = true }
            catch { recordCleanupFailure("snapshot after stop", error: error); cleanupDiagnosticOccurred = true }
            do { try ring.destroy() }
            catch { recordCleanupFailure("destroy", error: error); state = .cleanupRequired; return }
            self.ring = nil
            native.queued = 0 // The destroyed ring contains no queued bytes, even if its counters were unreadable.
        }
        if let plan, !pendingRestorations.isEmpty {
            do { try restorePropertiesLocked(plan) }
            catch { recordCleanupFailure("restore format group", error: error); state = .cleanupRequired; return }
        }
        if hogReleaseRequired, let endpoint {
            do { try hardware.releaseHog(endpoint, owner: ownerID); hogReleaseRequired = false }
            catch { recordCleanupFailure("hog release", error: error); state = .cleanupRequired; return }
        }
        state = .closed
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
    }

    /// Nominal/physical/virtual setters may change each other. Keep the entire journal until a
    /// final group read proves restoration, and bound convergence to three passes per close.
    private func restorePropertiesLocked(_ plan: CoreAudioOutputPlan) throws {
        let mutations = pendingRestorations.reversed()
        var values = try restorationValues(plan)
        if !restorationStarted, hasForeignRestorationValue(values) {
            // Restoring a different property could indirectly overwrite this external value.
            // Skip the coupled group, release only our quiesced resources, and report residue.
            skippedRestorations = mutations.filter { values[$0.property] != $0.original }.map { $0.property.rawValue }
            if failure == nil { failure = "Restoration skipped after external change: " + skippedRestorations.joined(separator: ", ") }
            pendingRestorations.removeAll()
            return
        }
        for _ in 0..<3 {
            values = try restorationValues(plan)
            if pendingRestorations.allSatisfy({ values[$0.property] == $0.original }) {
                pendingRestorations.removeAll(); return
            }
            guard !hasForeignRestorationValue(values) else { throw CoreAudioExactPcmOutputError.restorationConflict }
            for mutation in mutations {
                // Re-read the whole group before every setter: an earlier setter or another
                // owner may have changed a different property since the previous observation.
                values = try restorationValues(plan)
                guard !hasForeignRestorationValue(values) else { throw CoreAudioExactPcmOutputError.restorationConflict }
                if values[mutation.property] != mutation.original {
                    restorationStarted = true
                    try hardware.write(mutation.property, value: mutation.original, plan: plan)
                    try settle(mutation.property, value: mutation.original, plan: plan, requiresAuthorization: false)
                }
            }
        }
        values = try restorationValues(plan)
        guard pendingRestorations.allSatisfy({ values[$0.property] == $0.original }) else {
            throw hasForeignRestorationValue(values)
                ? CoreAudioExactPcmOutputError.restorationConflict : CoreAudioExactPcmOutputError.restorationDidNotConverge
        }
        pendingRestorations.removeAll()
    }

    private func restorationValues(_ plan: CoreAudioOutputPlan) throws -> [CoreAudioOutputProperty: CoreAudioOutputValue] {
        var values: [CoreAudioOutputProperty: CoreAudioOutputValue] = [:]
        for mutation in pendingRestorations { values[mutation.property] = try hardware.read(mutation.property, plan: plan) }
        return values
    }

    private func hasForeignRestorationValue(_ values: [CoreAudioOutputProperty: CoreAudioOutputValue]) -> Bool {
        pendingRestorations.contains { values[$0.property] != $0.original && values[$0.property] != $0.applied }
    }

    private func recordCleanupFailure(_ stage: String, error: Error) {
        // Stage names come only from the seven fixed call sites above. Preserve the first error
        // per stage across retries without accumulating unbounded diagnostic strings.
        let description = "\(stage): \(error)"
        if recordedCleanupStages.insert(stage).inserted { cleanupFailures.append(description) }
        if failure == nil { failure = description }
    }

    private func startMonitorLocked() {
        guard automaticMonitoring, timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: timerQueue)
        source.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(5))
        source.setEventHandler { self.service() } // Deliberate resource ownership until safe close.
        timer = source; source.resume()
    }

    private func snapshotLocked() -> CoreAudioExactPcmOutputSnapshot {
        .init(ownerID: ownerID, state: state, acceptedFrames: native.accepted, submittedFrames: native.submitted,
              queuedFrames: native.queued, finalCountersVerified: finalCountersVerified, failure: failure, cleanupFailures: cleanupFailures,
              skippedRestorations: skippedRestorations, drainStatus: drainStatus,
              expectedSourceFrames: expectedSourceFrames, trailingPaddingFrames: native.trailingPaddingFrames)
    }
}
#endif
