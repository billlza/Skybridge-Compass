#if os(macOS)
import AudioToolbox
import CoreAudio
import CSkyBridgeAudioOutput
import Foundation
import SkyBridgeProtocolCore

/// Process-wide lease serialization is required because HAL hog ownership is a PID, not a stream ID.
/// The registry retains uncertain acquisitions until the same owner can resolve/release them.
final class CoreAudioOutputNativeHardware: CoreAudioOutputHardware, @unchecked Sendable {
    static let shared = CoreAudioOutputNativeHardware()
    private typealias Access = CoreAudioExactPcmEndpointInspector
    private let leaseLock = NSLock()
    private var leases: [AudioDeviceID: (owner: UUID, uid: String)] = [:]
    private let processID = Int32(getpid())
    private init() {}

    func resolve(uid: String) throws -> CoreAudioOutputEndpoint {
        guard !uid.isEmpty, uid.utf8.count <= 4096 else { throw CoreAudioExactPcmError.invalidEndpoint }
        let endpoint = CoreAudioOutputEndpoint(uid: uid, device: try Access.resolve(uid))
        try requireIdentity(endpoint); return endpoint
    }

    func acquireHog(_ endpoint: CoreAudioOutputEndpoint, owner: UUID) throws {
        leaseLock.lock(); defer { leaseLock.unlock() }
        try requireIdentity(endpoint)
        guard leases[endpoint.device] == nil,
              try hogPID(endpoint) == -1 else { throw CoreAudioExactPcmError.deviceBusy }
        leases[endpoint.device] = (owner, endpoint.uid)
        // From this point a failure is an outstanding cleanup obligation, even if readback fails.
        try toggleHog(endpoint)
        guard try hogPID(endpoint) == processID else {
            leases.removeValue(forKey: endpoint.device)
            throw CoreAudioExactPcmError.deviceBusy
        }
    }

    func releaseHog(_ endpoint: CoreAudioOutputEndpoint, owner: UUID) throws {
        leaseLock.lock(); defer { leaseLock.unlock() }
        guard let lease = leases[endpoint.device], lease.owner == owner else { return }
        guard lease.uid == endpoint.uid else { throw CoreAudioExactPcmError.invalidEndpoint }
        try requireIdentity(endpoint)
        let pid = try hogPID(endpoint)
        if pid == processID {
            try toggleHog(endpoint)
            guard try hogPID(endpoint) == -1 else { throw CoreAudioExactPcmError.deviceBusy }
        } else if pid != -1 {
            // No longer our PID: never toggle another owner's device.
            leases.removeValue(forKey: endpoint.device)
            throw CoreAudioExactPcmError.deviceBusy
        }
        leases.removeValue(forKey: endpoint.device)
    }

    func plan(_ endpoint: CoreAudioOutputEndpoint, format: AudioStreamingPCMFormat) throws -> CoreAudioOutputPlan {
        try requireLease(endpoint)
        guard format.channels <= 64, format.waveChannelMask != nil else { throw CoreAudioExactPcmError.unsupportedLayout }
        let streams = try Access.identifiers(endpoint.device, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        guard streams.count == 1, let stream = streams.first else { throw CoreAudioExactPcmError.unsupportedTopology }
        let oldRate = try Access.scalar(endpoint.device, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
        guard oldRate.isFinite, oldRate > 0 else { throw CoreAudioExactPcmError.formatMismatch }
        let oldPhysical = try Access.scalar(stream, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription())
        let oldVirtual = try Access.scalar(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
        let desiredRate = Double(format.sampleRate)
        if oldRate != desiredRate {
            let ranges: [AudioValueRange] = try values(endpoint.device, kAudioDevicePropertyAvailableNominalSampleRates)
            guard ranges.contains(where: { $0.mMinimum.isFinite && $0.mMaximum.isFinite && $0.mMinimum <= desiredRate && desiredRate <= $0.mMaximum }) else {
                throw CoreAudioExactPcmError.formatMismatch
            }
        }
        let targetPhysical = try supportedFormat(stream, selector: kAudioStreamPropertyAvailablePhysicalFormats,
                                                 current: oldPhysical, offered: format, requireNonmixable: false)
        let targetVirtual = try supportedFormat(stream, selector: kAudioStreamPropertyAvailableVirtualFormats,
                                                current: oldVirtual, offered: format, requireNonmixable: true)
        return .init(endpoint: endpoint, stream: stream, mutations: [
            .init(property: .nominalRate, original: .rate(oldRate), applied: .rate(desiredRate)),
            .init(property: .physicalFormat, original: .format(oldPhysical), applied: .format(targetPhysical)),
            .init(property: .virtualFormat, original: .format(oldVirtual), applied: .format(targetVirtual))
        ])
    }

    func read(_ property: CoreAudioOutputProperty, plan: CoreAudioOutputPlan) throws -> CoreAudioOutputValue {
        try requireIdentity(plan.endpoint)
        switch property {
        case .nominalRate: return .rate(try Access.scalar(plan.endpoint.device, kAudioDevicePropertyNominalSampleRate, initial: Double(0)))
        case .physicalFormat: return .format(try Access.scalar(plan.stream, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription()))
        case .virtualFormat: return .format(try Access.scalar(plan.stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()))
        }
    }

    func write(_ property: CoreAudioOutputProperty, value: CoreAudioOutputValue, plan: CoreAudioOutputPlan) throws {
        try requireLease(plan.endpoint)
        switch (property, value) {
        case let (.nominalRate, .rate(rate)): try set(plan.endpoint.device, kAudioDevicePropertyNominalSampleRate, value: rate)
        case let (.physicalFormat, .format(format)): try set(plan.stream, kAudioStreamPropertyPhysicalFormat, value: format)
        case let (.virtualFormat, .format(format)): try set(plan.stream, kAudioStreamPropertyVirtualFormat, value: format)
        default: throw CoreAudioExactPcmOutputError.invalidState
        }
    }

    func verify(_ plan: CoreAudioOutputPlan, format: AudioStreamingPCMFormat) throws -> UInt32 {
        try requireLease(plan.endpoint)
        let snapshot = try Access.inspect(deviceUID: plan.endpoint.uid, format: format, expectedHogOwnerPID: processID)
        guard snapshot.deviceID == plan.endpoint.device, snapshot.streamID == plan.stream else { throw CoreAudioExactPcmOutputError.deviceChanged }
        return snapshot.bufferFrames
    }

    func makeRing(owner: UUID, format: AudioStreamingPCMFormat, capacityFrames: UInt32, maximumCallbackFrames: UInt32) throws -> any CoreAudioOutputRing {
        try CoreAudioOutputNativeRing(owner: owner, format: format, capacityFrames: capacityFrames, maximumCallbackFrames: maximumCallbackFrames)
    }

    func installListeners(_ plan: CoreAudioOutputPlan, format: AudioStreamingPCMFormat, ring: any CoreAudioOutputRing) throws {
        let device = plan.endpoint.device
        let global: [AudioObjectPropertySelector] = [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyDeviceUID,
            kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyHogMode, kAudioDevicePropertyBufferFrameSize,
            kAudioDevicePropertyUsesVariableBufferFrameSizes, kAudioDevicePropertyClockDomain]
        for selector in global { try ring.watch(object: device, address: Access.address(selector)) }
        for selector in [kAudioDevicePropertyLatency, kAudioDevicePropertySafetyOffset] {
            try ring.watch(object: device, address: Access.address(selector, scope: kAudioDevicePropertyScopeOutput))
        }
        var clockSource = Access.address(kAudioDevicePropertyClockSource, scope: kAudioDevicePropertyScopeOutput)
        if AudioObjectHasProperty(device, &clockSource) { try ring.watch(object: device, address: clockSource) }
        for selector in [kAudioDevicePropertyStreams, kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyPreferredChannelLayout] {
            var address = Access.address(selector, scope: kAudioDevicePropertyScopeOutput)
            if AudioObjectHasProperty(device, &address) { try ring.watch(object: device, address: address) }
        }
        for selector in [kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat, kAudioStreamPropertyStartingChannel,
                         kAudioStreamPropertyDirection, kAudioStreamPropertyLatency] {
            try ring.watch(object: plan.stream, address: Access.address(selector))
        }
        try ring.watch(object: AudioObjectID(kAudioObjectSystemObject), address: Access.address(kAudioHardwarePropertyMixStereoToMono))
        for channel in 0...UInt32(format.channels) {
            for selector in [kAudioDevicePropertyVolumeDecibels, kAudioDevicePropertyVolumeScalar,
                             kAudioDevicePropertyMute, kAudioDevicePropertyPhaseInvert, kAudioDevicePropertyStereoPan] {
                var address = Access.address(selector, scope: kAudioDevicePropertyScopeOutput, element: channel)
                if AudioObjectHasProperty(device, &address) { try ring.watch(object: device, address: address) }
            }
        }
    }

    func timing(_ plan: CoreAudioOutputPlan) throws -> CoreAudioOutputTiming {
        try requireLease(plan.endpoint)
        let device = plan.endpoint.device
        var address = Access.address(kAudioDevicePropertyClockSource, scope: kAudioDevicePropertyScopeOutput)
        let clockSource: UInt32? = AudioObjectHasProperty(device, &address)
            ? try Access.scalar(device, kAudioDevicePropertyClockSource, scope: kAudioDevicePropertyScopeOutput, initial: UInt32(0)) : nil
        return .init(
            deviceLatency: try Access.scalar(device, kAudioDevicePropertyLatency, scope: kAudioDevicePropertyScopeOutput, initial: UInt32(0)),
            streamLatency: try Access.scalar(plan.stream, kAudioStreamPropertyLatency, initial: UInt32(0)),
            safetyOffset: try Access.scalar(device, kAudioDevicePropertySafetyOffset, scope: kAudioDevicePropertyScopeOutput, initial: UInt32(0)),
            clockDomain: try Access.scalar(device, kAudioDevicePropertyClockDomain, initial: UInt32(0)), clockSource: clockSource)
    }

    func currentTime(_ plan: CoreAudioOutputPlan) throws -> CoreAudioOutputDeviceTime {
        try requireLease(plan.endpoint)
        var timestamp = AudioTimeStamp()
        let required: AudioTimeStampFlags = [.sampleTimeValid, .hostTimeValid]
        timestamp.mFlags = required
        let status = AudioDeviceGetCurrentTime(plan.endpoint.device, &timestamp)
        guard status == noErr else { throw CoreAudioExactPcmOutputError.native(result: -1, status: status) }
        // AudioDeviceGetCurrentTime may return fewer representations than requested.
        guard timestamp.mFlags.contains(required), timestamp.mSampleTime.isFinite else {
            throw CoreAudioExactPcmOutputError.invalidTimeline
        }
        return .init(sampleTime: timestamp.mSampleTime, hostTime: timestamp.mHostTime)
    }

    private func requireIdentity(_ endpoint: CoreAudioOutputEndpoint) throws {
        guard try Access.string(endpoint.device, kAudioDevicePropertyDeviceUID) == endpoint.uid,
              try Access.scalar(endpoint.device, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) == 1 else {
            throw CoreAudioExactPcmError.endpointUnavailable
        }
    }
    private func requireLease(_ endpoint: CoreAudioOutputEndpoint) throws {
        try requireIdentity(endpoint)
        guard try hogPID(endpoint) == processID else { throw CoreAudioExactPcmError.deviceBusy }
    }
    private func hogPID(_ endpoint: CoreAudioOutputEndpoint) throws -> Int32 {
        try Access.scalar(endpoint.device, kAudioDevicePropertyHogMode, initial: Int32(-1))
    }
    private func toggleHog(_ endpoint: CoreAudioOutputEndpoint) throws {
        // HAL ignores the incoming PID and toggles. Calls are serialized by leaseLock.
        try set(endpoint.device, kAudioDevicePropertyHogMode, value: processID)
    }
    private func set<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, value: T) throws {
        var address = Access.address(selector)
        var settable = DarwinBoolean(false)
        let query = AudioObjectIsPropertySettable(object, &address, &settable)
        guard query == noErr else { throw CoreAudioExactPcmError.propertyFailure(selector, query) }
        guard settable.boolValue else { throw CoreAudioExactPcmError.malformedProperty(selector) }
        var value = value
        let result = withUnsafeBytes(of: &value) { (raw: UnsafeRawBufferPointer) -> OSStatus in
            guard let base = raw.baseAddress else { return kAudioHardwareBadPropertySizeError }
            return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(raw.count), base)
        }
        guard result == noErr else { throw CoreAudioExactPcmError.propertyFailure(selector, result) }
    }
    private func values<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [T] {
        let data = try Access.bytes(object, selector, scope: kAudioObjectPropertyScopeGlobal)
        guard data.count % MemoryLayout<T>.stride == 0 else { throw CoreAudioExactPcmError.malformedProperty(selector) }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [T] in
            stride(from: 0, to: raw.count, by: MemoryLayout<T>.stride).map { raw.loadUnaligned(fromByteOffset: $0, as: T.self) }
        }
    }
    private func supportedFormat(_ stream: AudioStreamID, selector: AudioObjectPropertySelector,
                                 current: AudioStreamBasicDescription, offered: AudioStreamingPCMFormat,
                                 requireNonmixable: Bool) throws -> AudioStreamBasicDescription {
        try CoreAudioExactPcmPolicy.selectSupportedFormat(offered, current: current,
            requireNonmixable: requireNonmixable) {
            try values(stream, selector)
        }
    }
}

private final class CoreAudioOutputNativeRing: CoreAudioOutputRing {
    private var context: OpaquePointer?
    private let owner: SBAudioOutputOwner
    init(owner ownerID: UUID, format: AudioStreamingPCMFormat, capacityFrames: UInt32, maximumCallbackFrames: UInt32) throws {
        var uuid = ownerID.uuid
        let bytes = withUnsafeBytes(of: &uuid) { Array($0) }
        var high: UInt64 = 0, low: UInt64 = 0
        for byte in bytes.prefix(8) { high = high << 8 | UInt64(byte) }
        for byte in bytes.suffix(8) { low = low << 8 | UInt64(byte) }
        owner = .init(high: high, low: low)
        let configuration = SBAudioOutputConfiguration(owner: owner, bytesPerFrame: format.bytesPerFrame,
            channels: UInt32(format.channels), capacityFrames: capacityFrames, maximumCallbackFrames: maximumCallbackFrames)
        try check(SBAudioOutputCreate(configuration, &context))
    }
    func attach(device: AudioDeviceID) throws { try check(SBAudioOutputAttach(context, owner, device)) }
    func watch(object: AudioObjectID, address: AudioObjectPropertyAddress) throws { try check(SBAudioOutputWatchProperty(context, owner, object, address)) }
    func enqueue(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> Void in
            try check(SBAudioOutputEnqueue(context, owner, raw.baseAddress, raw.count))
        }
    }
    func start() throws {
        let result = SBAudioOutputStart(context, owner)
        if result == SBAudioOutputInsufficientPrefill { throw CoreAudioExactPcmOutputError.insufficientPrefill }
        try check(result)
    }
    func finishInput(expectedSourceFrames: UInt64, maximumPaddingFrames: UInt32) throws {
        try check(SBAudioOutputFinishInput(context, owner, expectedSourceFrames, maximumPaddingFrames))
    }
    func retire(_ reason: CoreAudioOutputRetirement) throws {
        let fault: SBAudioOutputFault
        switch reason { case .stopped: fault = SBAudioOutputFaultStopped
        case .revoked: fault = SBAudioOutputFaultOwnerRevoked
        case .deviceChanged: fault = SBAudioOutputFaultDeviceChanged }
        try check(SBAudioOutputRetire(context, owner, fault))
    }
    func snapshot() throws -> CoreAudioOutputNativeSnapshot {
        var value = SBAudioOutputSnapshot()
        try check(SBAudioOutputGetSnapshot(context, owner, &value))
        return .init(accepted: value.acceptedFrames, submitted: value.submittedFrames,
                     queued: value.queuedFrames, fault: UInt32(value.fault.rawValue),
                     trailingPaddingFrames: value.trailingPaddingFrames, sourceTimelineValid: value.sourceTimelineValid,
                     lastSourceEndSampleTime: value.lastSourceEndSampleTime)
    }
    func stop() throws { try check(SBAudioOutputStop(context, owner)) }
    func stopAfterDrain() throws { try check(SBAudioOutputStopAfterDrain(context, owner)) }
    func destroy() throws { try check(SBAudioOutputDestroy(&context, owner)) }
    private func check(_ result: SBAudioOutputResult) throws {
        guard result != SBAudioOutputOK else { return }
        var value = SBAudioOutputSnapshot()
        let read = SBAudioOutputGetSnapshot(context, owner, &value)
        throw CoreAudioExactPcmOutputError.native(result: Int32(result.rawValue), status: read == SBAudioOutputOK ? value.lastHALStatus : nil)
    }
}
#endif
