import AVFAudio
import Foundation
import SkyBridgeProtocolCore

public enum AudioCompatiblePCMConversionError: Error, Equatable, Sendable {
    case invalidFormat, invalidFrameCount, invalidState, invalidInputSize
    case nonFiniteSample, nonzeroPadding, sourceOverrun, incompleteSource
    case unavailableConverter, invalidNativeProgress, unexpectedNativeEnd, excessiveNativeTail
}

/// Counts in the explicit lossy 48 kHz PCM16 timebase, not original-format playback evidence.
public struct AudioCompatiblePCMCompletion: Equatable, Sendable {
    public let sourceFrames: UInt64
    public let convertedFrames: UInt64
    public let clippedSamples: UInt64
    public let resampled: Bool
    public let dithered: Bool
    public let algorithmReadback: AudioCompatiblePCMConverter.AlgorithmReadback
}

/// Serial, non-Sendable conversion owner for the explicitly selected compatible audio path.
/// The caller resolves source layout, verifies file EOF and owns the input resource. This type
/// never opens files, acquires authorization, downmixes, retries or changes the strict route.
/// Each append is bounded and each emitted block is consumed synchronously before more work.
public final class AudioCompatiblePCMConverter {
    public enum State: Equatable, Sendable { case converting, completed, cancelled, failed }
    public enum AlgorithmReadback: String, Codable, Sendable {
        case notResampled, reportedMastering, unavailable
    }
    public static let maximumInputFrames = 4096
    public static let maximumOutputFrames = 4096
    public let sourceFormat: AudioStreamingPCMFormat
    public let expectedSourceFrames: UInt64
    public let expectedOutputFrames: UInt64
    public let resampled: Bool
    public let dithered: Bool
    public let algorithmReadback: AlgorithmReadback
    public private(set) var state = State.converting
    public private(set) var acceptedSourceFrames: UInt64 = 0
    public private(set) var emittedFrames: UInt64 = 0
    public private(set) var clippedSamples: UInt64 = 0
    /// Synthetic filter input only; never included in acceptedSourceFrames or delivered duration.
    public private(set) var tailInputFrames: UInt64 = 0
    public var resourcesReleased: Bool {
        converter == nil && inputBuffer == nil && outputBuffer == nil && samples.isEmpty && !active
    }

    private var converter: AVAudioConverter?
    private var inputBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?
    private var samples: [Double]
    private var random: UInt64
    private var active = false
    private var releasePending = false
    private var failure: (any Error)?
    private var nativeOutputFrames: UInt64 = 0
    private let requireAuthorization: () throws -> Void

    /// ditherSeed controls only audio noise, never cryptographic or account state. The normal
    /// caller leaves it nil; explicit seeds make conversion/reference comparisons reproducible.
    public init(sourceFormat: AudioStreamingPCMFormat, sourceFrames: UInt64,
                ditherSeed: UInt64? = nil, requireAuthorization: @escaping () throws -> Void) throws {
        let mask: UInt32 = sourceFormat.channels == 1 ? 4 : 3
        guard (1...2).contains(sourceFormat.channels), (8_000...384_000).contains(sourceFormat.sampleRate),
              sourceFormat.waveChannelMask == mask else { throw AudioCompatiblePCMConversionError.invalidFormat }
        guard sourceFrames > 0, sourceFrames <= UInt64(sourceFormat.sampleRate) * 14_400 else {
            throw AudioCompatiblePCMConversionError.invalidFrameCount
        }
        self.sourceFormat = sourceFormat
        expectedSourceFrames = sourceFrames
        expectedOutputFrames = (sourceFrames * 48_000 + UInt64(sourceFormat.sampleRate) - 1) / UInt64(sourceFormat.sampleRate)
        resampled = sourceFormat.sampleRate != 48_000
        dithered = resampled || sourceFormat.encoding.isFloatingPoint || sourceFormat.declaredValidBits > 16
        self.requireAuthorization = requireAuthorization
        random = ditherSeed ?? UInt64.random(in: UInt64.min...UInt64.max)
        samples = [Double](repeating: 0, count: Self.maximumInputFrames * Int(sourceFormat.channels))
        try Task.checkCancellation(); try requireAuthorization()
        if resampled {
            guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                    sampleRate: Double(sourceFormat.sampleRate), channels: AVAudioChannelCount(sourceFormat.channels), interleaved: true),
                  let destination = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                    sampleRate: 48_000, channels: AVAudioChannelCount(sourceFormat.channels), interleaved: true),
                  let native = AVAudioConverter(from: source, to: destination),
                  let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(Self.maximumInputFrames)),
                  let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: AVAudioFrameCount(Self.maximumOutputFrames)),
                  input.floatChannelData != nil, output.floatChannelData != nil else {
                throw AudioCompatiblePCMConversionError.unavailableConverter
            }
            native.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            native.sampleRateConverterQuality = Int(AVAudioQuality.max.rawValue)
            native.primeMethod = .normal
            // This nullable Apple property is not readable on every platform. On the qualified
            // iPad, the C property getter also returns kAudioConverterErr_PropertyNotSupported
            // while the setter succeeds. Preserve that unknown state; never label it confirmed
            // Mastering, and still reject a reported conflicting algorithm or quality/priming.
            if let reported = native.sampleRateConverterAlgorithm {
                guard reported == AVSampleRateConverterAlgorithm_Mastering else {
                    throw AudioCompatiblePCMConversionError.unavailableConverter
                }
                algorithmReadback = .reportedMastering
            } else { algorithmReadback = .unavailable }
            guard native.sampleRateConverterQuality == Int(AVAudioQuality.max.rawValue), native.primeMethod == .normal else {
                throw AudioCompatiblePCMConversionError.unavailableConverter
            }
            converter = native; inputBuffer = input; outputBuffer = output
        } else { algorithmReadback = .notResampled }
        try Task.checkCancellation(); try requireAuthorization()
    }

    public func append(_ pcm: Data, emit: ([Int16]) throws -> Void) throws {
        try perform {
            let frameBytes = Int(sourceFormat.bytesPerFrame)
            guard !pcm.isEmpty, pcm.count % frameBytes == 0,
                  pcm.count / frameBytes <= Self.maximumInputFrames else {
                throw AudioCompatiblePCMConversionError.invalidInputSize
            }
            let frames = pcm.count / frameBytes
            guard UInt64(frames) <= expectedSourceFrames - acceptedSourceFrames else {
                throw AudioCompatiblePCMConversionError.sourceOverrun
            }
            // Validate the entire incoming block before any of it is emitted or passed to AVFAudio.
            try normalize(pcm)
            acceptedSourceFrames += UInt64(frames)
            if resampled { try convert(frames: frames, isTail: false, emit: emit) }
            else { try emitSamples(frames: frames, sample: { self.samples[$0] }, emit: emit) }
        }
    }

    /// Call only after the enclosing source has verified EOF. Explicit zero extension releases
    /// delayed filter output until ceil(source * 48000 / rate) frames are delivered. It never
    /// extends public audio duration. iPad finite endOfStream returned early in independent
    /// native probes, so native EOF/primeInfo is not used as proof that the tail was emitted.
    /// A one-second source-time resource budget bounds padding; exhausting it is a failure.
    public func finish(emit: ([Int16]) throws -> Void) throws -> AudioCompatiblePCMCompletion {
        try perform {
            guard acceptedSourceFrames == expectedSourceFrames else { throw AudioCompatiblePCMConversionError.incompleteSource }
            if resampled {
                for index in samples.indices { samples[index] = 0 }
                while emittedFrames < expectedOutputFrames {
                    try requireCurrent()
                    guard tailInputFrames < UInt64(sourceFormat.sampleRate) else {
                        throw AudioCompatiblePCMConversionError.excessiveNativeTail
                    }
                    let count = Int(min(UInt64(Self.maximumInputFrames), UInt64(sourceFormat.sampleRate) - tailInputFrames))
                    try convert(frames: count, isTail: true, emit: emit)
                }
                // The last native block can straddle the endpoint. Nothing beyond that endpoint
                // is quantized or emitted, and conversion stops immediately after this block.
                guard nativeOutputFrames >= expectedOutputFrames,
                      nativeOutputFrames - expectedOutputFrames < UInt64(Self.maximumOutputFrames) else {
                    throw AudioCompatiblePCMConversionError.invalidNativeProgress
                }
            }
            guard emittedFrames == expectedOutputFrames else { throw AudioCompatiblePCMConversionError.incompleteSource }
            try requireCurrent()
            let receipt = AudioCompatiblePCMCompletion(sourceFrames: acceptedSourceFrames,
                convertedFrames: emittedFrames, clippedSamples: clippedSamples, resampled: resampled,
                dithered: dithered, algorithmReadback: algorithmReadback)
            state = .completed; releasePending = true
            return receipt
        }
    }

    public func cancel() {
        guard state == .converting else { return }
        state = .cancelled; releasePending = true
        if !active { releaseResources() }
    }

    private func convert(frames: Int, isTail: Bool, emit: ([Int16]) throws -> Void) throws {
        guard let converter, let inputBuffer, let outputBuffer,
              let input = inputBuffer.floatChannelData?[0], let output = outputBuffer.floatChannelData?[0] else {
            throw AudioCompatiblePCMConversionError.invalidState
        }
        let channels = Int(sourceFormat.channels)
        var offset = 0
        // At the largest admitted ratio one append yields <= 6 * 4096 output frames. This
        // bound also allows partial native progress and a final inputRanDry/endOfStream call.
        for _ in 0..<16 {
            try requireCurrent()
            let before = offset
            var callbackFailure: (any Error)?
            var nativeError: NSError?
            outputBuffer.frameLength = 0
            let status = converter.convert(to: outputBuffer, error: &nativeError) { requested, inputStatus in
                do {
                    try self.requireCurrent()
                    guard requested > 0 else { throw AudioCompatiblePCMConversionError.invalidNativeProgress }
                    if offset == frames {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    let count = min(Int(requested), frames - offset)
                    for index in 0..<(count * channels) { input[index] = Float(self.samples[offset * channels + index]) }
                    inputBuffer.frameLength = AVAudioFrameCount(count); offset += count
                    if isTail { self.tailInputFrames += UInt64(count) }
                    inputStatus.pointee = .haveData
                    return inputBuffer
                } catch {
                    callbackFailure = error; inputStatus.pointee = .noDataNow; return nil
                }
            }
            if let callbackFailure { throw callbackFailure }
            if let nativeError { throw nativeError }
            try requireCurrent()
            guard status != .error else { throw AudioCompatiblePCMConversionError.invalidNativeProgress }
            let count = Int(outputBuffer.frameLength)
            guard count <= Self.maximumOutputFrames else { throw AudioCompatiblePCMConversionError.invalidNativeProgress }
            for index in 0..<(count * channels) {
                guard output[index].isFinite else { throw AudioCompatiblePCMConversionError.nonFiniteSample }
            }
            nativeOutputFrames += UInt64(count)
            if !isTail, nativeOutputFrames > expectedOutputFrames { throw AudioCompatiblePCMConversionError.invalidNativeProgress }
            let admitted = min(count, Int(expectedOutputFrames - emittedFrames))
            if admitted > 0 { try emitSamples(frames: admitted, sample: { Double(output[$0]) }, emit: emit) }
            if isTail, emittedFrames == expectedOutputFrames { return }
            switch status {
            case .endOfStream:
                throw AudioCompatiblePCMConversionError.unexpectedNativeEnd
            case .inputRanDry:
                guard offset == frames else { throw AudioCompatiblePCMConversionError.invalidNativeProgress }
                return
            case .haveData:
                guard count > 0 || offset > before else { throw AudioCompatiblePCMConversionError.invalidNativeProgress }
            case .error: throw AudioCompatiblePCMConversionError.invalidNativeProgress
            @unknown default: throw AudioCompatiblePCMConversionError.invalidNativeProgress
            }
        }
        throw AudioCompatiblePCMConversionError.invalidNativeProgress
    }

    private func normalize(_ bytes: Data) throws {
        let width = Int(sourceFormat.encoding.containerBits / 8)
        let padding = Int(sourceFormat.encoding.containerBits - sourceFormat.declaredValidBits)
        try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for index in 0..<(bytes.count / width) {
                var bits: UInt64 = 0
                for byte in 0..<width { bits |= UInt64(raw[index * width + byte]) << (8 * byte) }
                let value: Double
                if sourceFormat.encoding == .float32 { value = Double(Float(bitPattern: UInt32(bits))) }
                else if sourceFormat.encoding == .float64 { value = Double(bitPattern: bits) }
                else {
                    if padding > 0, bits & ((UInt64(1) << padding) - 1) != 0 {
                        throw AudioCompatiblePCMConversionError.nonzeroPadding
                    }
                    if sourceFormat.encoding == .unsigned8 { value = Double(Int(bits) - 128) / 128 }
                    else {
                        let shift = 64 - width * 8
                        let signed = Int64(bitPattern: bits << shift) >> shift
                        value = Double(signed) / Double(UInt64(1) << (width * 8 - 1))
                    }
                }
                guard value.isFinite, Float(value).isFinite else { throw AudioCompatiblePCMConversionError.nonFiniteSample }
                samples[index] = value
            }
        }
    }

    private func emitSamples(frames: Int, sample: (Int) -> Double, emit: ([Int16]) throws -> Void) throws {
        try requireCurrent()
        var pcm = [Int16](); pcm.reserveCapacity(frames * Int(sourceFormat.channels))
        for index in 0..<(frames * Int(sourceFormat.channels)) {
            let value = sample(index)
            guard value.isFinite else { throw AudioCompatiblePCMConversionError.nonFiniteSample }
            let noise: Double
            if dithered { let first = uniform(); let second = uniform(); noise = first - second }
            else { noise = 0 }
            // Values outside this range must saturate even with TPDF; bound the multiplication.
            let rounded = value > 2 ? 65_536 : value < -2 ? -65_536 : floor(value * 32768 + noise + 0.5)
            let result: Int16
            if rounded < -32768 { clippedSamples += 1; result = -32768 }
            else if rounded > 32767 { clippedSamples += 1; result = 32767 }
            else { result = Int16(rounded) }
            pcm.append(result)
        }
        try requireCurrent(); try emit(pcm); try requireCurrent()
        emittedFrames += UInt64(frames)
    }

    /// SplitMix64 supplies reproducible audio noise, not cryptographic entropy. Two uniform
    /// draws form TPDF with one output LSB peak amplitude in either direction.
    private func uniform() -> Double {
        random &+= 0x9e3779b97f4a7c15
        var value = random
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return Double((value ^ (value >> 31)) >> 11) * (1.0 / 9007199254740992.0)
    }

    private func requireCurrent() throws {
        if let failure { throw failure }
        guard state == .converting else { throw AudioCompatiblePCMConversionError.invalidState }
        try Task.checkCancellation(); try requireAuthorization()
        if let failure { throw failure }
        guard state == .converting else { throw AudioCompatiblePCMConversionError.invalidState }
        try Task.checkCancellation()
    }

    private func perform<T>(_ operation: () throws -> T) throws -> T {
        guard !active else {
            if state == .converting { failure = AudioCompatiblePCMConversionError.invalidState; state = .failed; releasePending = true }
            throw failure ?? AudioCompatiblePCMConversionError.invalidState
        }
        active = true
        defer { active = false; if releasePending { releaseResources() } }
        do { try requireCurrent(); return try operation() }
        catch {
            if state == .converting { failure = error; state = .failed; releasePending = true }
            throw failure ?? error
        }
    }

    private func releaseResources() {
        converter = nil; inputBuffer = nil; outputBuffer = nil; samples.removeAll(keepingCapacity: false)
    }
}
