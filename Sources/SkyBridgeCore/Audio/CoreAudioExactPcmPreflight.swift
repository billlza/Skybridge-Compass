#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation
import SkyBridgeProtocolCore

public enum CoreAudioExactPcmError: Error, Equatable, Sendable {
    case invalidEndpoint, endpointUnavailable, unsupportedTopology, unsupportedLayout
    case formatMismatch, mixableVirtualFormat, gainOrMuteActive, deviceBusy, variableBufferSize
    case malformedProperty(AudioObjectPropertySelector)
    case propertyFailure(AudioObjectPropertySelector, OSStatus)
}

/// Pure checks for a direct, single-buffer HAL path. No format conversion or channel mapping.
public enum CoreAudioExactPcmPolicy {
    /// Select the original PCM representation from HAL capabilities. Loading
    /// available formats remains lazy when the current format already qualifies.
    static func selectSupportedFormat(
        _ offered: AudioStreamingPCMFormat,
        current: AudioStreamBasicDescription,
        requireNonmixable: Bool,
        available: () throws -> [AudioStreamRangedDescription]
    ) throws -> AudioStreamBasicDescription {
        func accepts(_ description: AudioStreamBasicDescription) -> Bool {
            matches(offered, description: description)
                && (!requireNonmixable || description.mFormatFlags & kAudioFormatFlagIsNonMixable != 0)
        }
        if accepts(current) { return current }
        var hasExactRepresentation = matches(offered, description: current)
        for range in try available() {
            guard range.mSampleRateRange.mMinimum.isFinite, range.mSampleRateRange.mMaximum.isFinite,
                  range.mSampleRateRange.mMinimum <= Double(offered.sampleRate),
                  Double(offered.sampleRate) <= range.mSampleRateRange.mMaximum else { continue }
            var candidate = range.mFormat
            candidate.mSampleRate = Double(offered.sampleRate)
            if accepts(candidate) { return candidate }
            hasExactRepresentation = hasExactRepresentation || matches(offered, description: candidate)
        }
        if requireNonmixable && hasExactRepresentation {
            throw CoreAudioExactPcmError.mixableVirtualFormat
        }
        throw CoreAudioExactPcmError.formatMismatch
    }

    public static func validateFormat(
        _ offered: AudioStreamingPCMFormat,
        virtual: AudioStreamBasicDescription,
        physical: AudioStreamBasicDescription,
        nominalSampleRate: Double
    ) throws {
        guard nominalSampleRate == Double(offered.sampleRate),
              matches(offered, description: virtual), matches(offered, description: physical) else {
            throw CoreAudioExactPcmError.formatMismatch
        }
        // Hog ownership is process-wide. Also require the IOProc's actual format to be nonmixable.
        guard virtual.mFormatFlags & kAudioFormatFlagIsNonMixable != 0 else {
            throw CoreAudioExactPcmError.mixableVirtualFormat
        }
    }

    public static func validateBuffers(_ offered: AudioStreamingPCMFormat, channels: [UInt32]) throws {
        guard channels == [UInt32(offered.channels)] else { throw CoreAudioExactPcmError.unsupportedTopology }
    }

    /// DIRECTOUT explicitly uses channel indices. Unknown layout is not DIRECTOUT. The first
    /// semantic-layout implementation handles front L/R stereo and front-center mono only;
    /// other WAVE speaker masks fail explicitly until an audited ordered mapping is implemented.
    public static func validateLayout(_ offered: AudioStreamingPCMFormat, channelLabels: [UInt32]?) throws {
        guard let mask = offered.waveChannelMask else { throw CoreAudioExactPcmError.unsupportedLayout }
        if mask == 0 { return }
        let expected: [UInt32]
        switch (mask, offered.channels) {
        case (3, 2): expected = [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
        case (4, 1): expected = [kAudioChannelLabel_Center]
        default: throw CoreAudioExactPcmError.unsupportedLayout
        }
        guard channelLabels == expected else { throw CoreAudioExactPcmError.unsupportedLayout }
    }

    static func matches(_ offered: AudioStreamingPCMFormat, description: AudioStreamBasicDescription) -> Bool {
        var flags: AudioFormatFlags = 0
        if offered.encoding.isFloatingPoint { flags |= kAudioFormatFlagIsFloat }
        else if offered.encoding != .unsigned8 { flags |= kAudioFormatFlagIsSignedInteger }
        flags |= offered.declaredValidBits == offered.encoding.containerBits
            ? kAudioFormatFlagIsPacked : kAudioFormatFlagIsAlignedHigh
        return description.mSampleRate == Double(offered.sampleRate)
            && description.mFormatID == kAudioFormatLinearPCM
            && description.mFormatFlags & ~kAudioFormatFlagIsNonMixable == flags
            && description.mBytesPerPacket == offered.bytesPerFrame
            && description.mFramesPerPacket == 1
            && description.mBytesPerFrame == offered.bytesPerFrame
            && description.mChannelsPerFrame == UInt32(offered.channels)
            && description.mBitsPerChannel == UInt32(offered.declaredValidBits)
            && description.mReserved == 0
    }
}

/// Read-only inspection, not an opened output or an authority to start one. Device properties can
/// change immediately after inspection. The control owner must acquire its own hog lease,
/// revalidate, install change listeners, attach the native bridge, and service faults before it can
/// report outputReady. This object never changes sample rate, volume, mute or hog ownership.
public struct CoreAudioExactPcmEndpointInspection: Sendable, Equatable {
    public let deviceUID: String
    public let deviceID: AudioDeviceID
    public let streamID: AudioStreamID
    public let format: AudioStreamingPCMFormat
    public let bufferFrames: UInt32
    public let hogOwnerPID: Int32
}

public enum CoreAudioExactPcmEndpointInspector {
    /// Selects this exact local endpoint UID; never substitutes the default output device.
    public static func inspect(deviceUID: String, format: AudioStreamingPCMFormat,
                               expectedHogOwnerPID: Int32 = -1) throws -> CoreAudioExactPcmEndpointInspection {
        guard !deviceUID.isEmpty, deviceUID.utf8.count <= 4096 else { throw CoreAudioExactPcmError.invalidEndpoint }
        guard format.channels <= 64 else { throw CoreAudioExactPcmError.unsupportedTopology }
        let device = try resolve(deviceUID)
        guard try string(device, kAudioDevicePropertyDeviceUID) == deviceUID,
              try scalar(device, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) == 1 else {
            throw CoreAudioExactPcmError.endpointUnavailable
        }
        let streams = try identifiers(device, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        guard streams.count == 1, let stream = streams.first,
              try scalar(stream, kAudioStreamPropertyDirection, initial: UInt32(1)) == 0,
              try scalar(stream, kAudioStreamPropertyStartingChannel, initial: UInt32(0)) == 1 else {
            throw CoreAudioExactPcmError.unsupportedTopology
        }
        let virtual = try scalar(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
        let physical = try scalar(stream, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription())
        let rate = try scalar(device, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
        try CoreAudioExactPcmPolicy.validateFormat(format, virtual: virtual, physical: physical, nominalSampleRate: rate)
        try CoreAudioExactPcmPolicy.validateBuffers(format, channels: bufferChannels(device))
        let labels: [UInt32]?
        if format.waveChannelMask == 0 { labels = nil }
        else { labels = try channelLabels(device) }
        try CoreAudioExactPcmPolicy.validateLayout(format, channelLabels: labels)
        guard try scalar(device, kAudioDevicePropertyUsesVariableBufferFrameSizes, initial: UInt32(0)) == 0 else {
            throw CoreAudioExactPcmError.variableBufferSize
        }
        let bufferFrames = try scalar(device, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0))
        guard bufferFrames > 0, UInt64(bufferFrames) * UInt64(format.bytesPerFrame) <= 1_048_576 else {
            throw CoreAudioExactPcmError.unsupportedTopology
        }
        let hogOwner = try scalar(device, kAudioDevicePropertyHogMode, initial: Int32(-1))
        // The native controller supplies its PID only after obtaining its exact local lease.
        guard hogOwner == expectedHogOwnerPID else { throw CoreAudioExactPcmError.deviceBusy }
        guard try scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyMixStereoToMono, initial: UInt32(0)) == 0 else {
            throw CoreAudioExactPcmError.gainOrMuteActive
        }
        try checkControls(device, channels: UInt32(format.channels))
        return .init(deviceUID: deviceUID, deviceID: device, streamID: stream, format: format,
                     bufferFrames: bufferFrames, hogOwnerPID: hogOwner)
    }

    static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: element)
    }

    static func resolve(_ uid: String) throws -> AudioDeviceID {
        var property = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var count = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property,
                UInt32(MemoryLayout<CFString>.size), qualifierPointer, &count, &device)
        }
        try checked(status, selector: property.mSelector)
        guard count == UInt32(MemoryLayout<AudioDeviceID>.size), device != kAudioObjectUnknown else {
            throw CoreAudioExactPcmError.endpointUnavailable
        }
        return device
    }

    /// Only fixed-size imported C value types are used here; no object or variable-sized property.
    static func scalar<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                  element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                                  initial: T) throws -> T {
        var property = address(selector, scope: scope, element: element)
        var result = initial
        var count = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &result) { (raw: UnsafeMutableRawBufferPointer) -> OSStatus in
            guard let base = raw.baseAddress else { return kAudioHardwareBadPropertySizeError }
            return AudioObjectGetPropertyData(object, &property, 0, nil, &count, base)
        }
        try checked(status, selector: selector)
        guard count == UInt32(MemoryLayout<T>.size) else { throw CoreAudioExactPcmError.malformedProperty(selector) }
        return result
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var property = address(selector)
        var result: Unmanaged<CFString>?
        var count = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &property, 0, nil, &count, &result)
        // The HAL property explicitly transfers a retained CFString. Balance it even on failure.
        let value = result?.takeRetainedValue()
        try checked(status, selector: selector)
        guard count == UInt32(MemoryLayout<Unmanaged<CFString>?>.size), let value else {
            throw CoreAudioExactPcmError.malformedProperty(selector)
        }
        return value as String
    }

    static func bytes(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope) throws -> Data {
        var property = address(selector, scope: scope)
        var count: UInt32 = 0
        try checked(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &count), selector: selector)
        guard count > 0, count <= 65_536 else { throw CoreAudioExactPcmError.malformedProperty(selector) }
        let expected = count
        var result = Data(count: Int(count))
        let status = result.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> OSStatus in
            guard let base = raw.baseAddress else { return kAudioHardwareBadPropertySizeError }
            return AudioObjectGetPropertyData(object, &property, 0, nil, &count, base)
        }
        try checked(status, selector: selector)
        guard count == expected else { throw CoreAudioExactPcmError.malformedProperty(selector) }
        return result
    }

    static func identifiers(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope) throws -> [AudioObjectID] {
        let data = try bytes(object, selector, scope: scope)
        guard data.count % MemoryLayout<AudioObjectID>.stride == 0 else {
            throw CoreAudioExactPcmError.malformedProperty(selector)
        }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [AudioObjectID] in
            stride(from: 0, to: raw.count, by: MemoryLayout<AudioObjectID>.stride).map {
                raw.loadUnaligned(fromByteOffset: $0, as: AudioObjectID.self)
            }
        }
    }

    private static func bufferChannels(_ device: AudioDeviceID) throws -> [UInt32] {
        let selector = kAudioDevicePropertyStreamConfiguration
        let data = try bytes(device, selector, scope: kAudioDevicePropertyScopeOutput)
        guard let start = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers), data.count >= start else {
            throw CoreAudioExactPcmError.malformedProperty(selector)
        }
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> [UInt32] in
            let count = raw.loadUnaligned(as: UInt32.self)
            guard count == 1, data.count == start + MemoryLayout<AudioBuffer>.stride else {
                throw CoreAudioExactPcmError.unsupportedTopology
            }
            return [raw.loadUnaligned(fromByteOffset: start, as: AudioBuffer.self).mNumberChannels]
        }
    }

    private static func channelLabels(_ device: AudioDeviceID) throws -> [UInt32] {
        let selector = kAudioDevicePropertyPreferredChannelLayout
        let data = try bytes(device, selector, scope: kAudioDevicePropertyScopeOutput)
        return try channelLabels(propertyData: data)
    }

    static func channelLabels(propertyData data: Data) throws -> [UInt32] {
        let selector = kAudioDevicePropertyPreferredChannelLayout
        guard let start = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions), data.count >= start else {
            throw CoreAudioExactPcmError.malformedProperty(selector)
        }
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> [UInt32] in
            let tag = raw.loadUnaligned(as: UInt32.self)
            let bitmap = AudioChannelBitmap(rawValue: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            let count = raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            if tag == kAudioChannelLayoutTag_Stereo, bitmap.isEmpty, count == 0 {
                return [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
            }
            if tag == kAudioChannelLayoutTag_Mono, bitmap.isEmpty, count == 0 { return [kAudioChannelLabel_Center] }
            if tag == kAudioChannelLayoutTag_UseChannelBitmap, count == 0 {
                if bitmap == AudioChannelBitmap.bit_Left.union(.bit_Right) {
                    return [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
                }
                if bitmap == .bit_Center { return [kAudioChannelLabel_Center] }
            }
            guard tag == kAudioChannelLayoutTag_UseChannelDescriptions, bitmap.isEmpty, count == 1 || count == 2,
                  data.count >= start + Int(count) * MemoryLayout<AudioChannelDescription>.stride else {
                throw CoreAudioExactPcmError.unsupportedLayout
            }
            return try (0..<Int(count)).map { index in
                let description = raw.loadUnaligned(fromByteOffset: start + index * MemoryLayout<AudioChannelDescription>.stride,
                                                     as: AudioChannelDescription.self)
                guard description.mChannelFlags.isEmpty else { throw CoreAudioExactPcmError.unsupportedLayout }
                return description.mChannelLabel
            }
        }
    }

    private static func checkControls(_ device: AudioDeviceID, channels: UInt32) throws {
        for element in 0...channels {
            var pan = address(kAudioDevicePropertyStereoPan, scope: kAudioDevicePropertyScopeOutput, element: element)
            if AudioObjectHasProperty(device, &pan) {
                // No audited gain-neutral pan law is part of this first direct-output path.
                throw CoreAudioExactPcmError.gainOrMuteActive
            }
            for selector in [kAudioDevicePropertyMute, kAudioDevicePropertyPhaseInvert] {
                var property = address(selector, scope: kAudioDevicePropertyScopeOutput, element: element)
                if AudioObjectHasProperty(device, &property),
                   try scalar(device, selector, scope: property.mScope, element: element, initial: UInt32(0)) != 0 {
                    throw CoreAudioExactPcmError.gainOrMuteActive
                }
            }
            var decibels = address(kAudioDevicePropertyVolumeDecibels, scope: kAudioDevicePropertyScopeOutput, element: element)
            var scalarVolume = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            if AudioObjectHasProperty(device, &decibels) {
                guard try scalar(device, decibels.mSelector, scope: decibels.mScope, element: element, initial: Float(0)) == 0 else {
                    throw CoreAudioExactPcmError.gainOrMuteActive
                }
            } else if AudioObjectHasProperty(device, &scalarVolume) {
                // A normalized maximum is not independently a 0 dB declaration.
                throw CoreAudioExactPcmError.gainOrMuteActive
            }
        }
    }

    private static func checked(_ status: OSStatus, selector: AudioObjectPropertySelector) throws {
        guard status == noErr else { throw CoreAudioExactPcmError.propertyFailure(selector, status) }
    }
}
#endif
