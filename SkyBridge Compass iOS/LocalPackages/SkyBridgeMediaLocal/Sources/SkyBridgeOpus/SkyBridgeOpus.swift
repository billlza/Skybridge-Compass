import Foundation
import CSkyBridgeOpusShim

public enum SkyBridgeOpusError: Error, Equatable, Sendable {
    case invalidSampleRate(Int)
    case invalidChannelCount(Int)
    case invalidPCMByteCount(Int)
    case encoderCreateFailed(Int32)
    case decoderCreateFailed(Int32)
    case opusCallFailed(operation: String, code: Int32)
}

public enum SkyBridgeOpusSignal: Sendable {
    case voice
    case music

    var opusValue: Int32 {
        switch self {
        case .voice:
            return Int32(OPUS_SIGNAL_VOICE)
        case .music:
            return Int32(OPUS_SIGNAL_MUSIC)
        }
    }
}

public enum SkyBridgeOpusApplication: Sendable {
    case audio
    case lowDelay
    case voip

    var opusValue: Int32 {
        switch self {
        case .audio:
            return Int32(OPUS_APPLICATION_AUDIO)
        case .lowDelay:
            return Int32(OPUS_APPLICATION_RESTRICTED_LOWDELAY)
        case .voip:
            return Int32(OPUS_APPLICATION_VOIP)
        }
    }
}

public struct SkyBridgeOpusConfiguration: Equatable, Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let frameDurationMs: Int
    public let bitrate: Int
    public let complexity: Int
    public let expectedPacketLossPercent: Int
    public let inBandFECEnabled: Bool
    public let dtxEnabled: Bool
    public let application: SkyBridgeOpusApplication
    public let signal: SkyBridgeOpusSignal

    public init(
        sampleRate: Int = 48_000,
        channels: Int = 2,
        frameDurationMs: Int = 20,
        bitrate: Int,
        complexity: Int,
        expectedPacketLossPercent: Int,
        inBandFECEnabled: Bool,
        dtxEnabled: Bool = false,
        application: SkyBridgeOpusApplication = .audio,
        signal: SkyBridgeOpusSignal = .music
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.frameDurationMs = frameDurationMs
        self.bitrate = bitrate
        self.complexity = complexity
        self.expectedPacketLossPercent = expectedPacketLossPercent
        self.inBandFECEnabled = inBandFECEnabled
        self.dtxEnabled = dtxEnabled
        self.application = application
        self.signal = signal
    }

    public var samplesPerChannel: Int {
        sampleRate * frameDurationMs / 1_000
    }

    public var interleavedSampleCount: Int {
        samplesPerChannel * channels
    }

    public static let lowLatency = SkyBridgeOpusConfiguration(
        bitrate: 96_000,
        complexity: 5,
        expectedPacketLossPercent: 3,
        inBandFECEnabled: true,
        application: .lowDelay,
        signal: .music
    )

    public static let highFidelity = SkyBridgeOpusConfiguration(
        bitrate: 160_000,
        complexity: 8,
        expectedPacketLossPercent: 2,
        inBandFECEnabled: true,
        application: .audio,
        signal: .music
    )
}

public final class SkyBridgeOpusEncoder {
    private var encoder: OpaquePointer?
    public private(set) var configuration: SkyBridgeOpusConfiguration

    public init(configuration: SkyBridgeOpusConfiguration) throws {
        try Self.validate(configuration)
        var error: Int32 = 0
        encoder = opus_encoder_create(
            Int32(configuration.sampleRate),
            Int32(configuration.channels),
            configuration.application.opusValue,
            &error
        )
        guard error == OPUS_OK, encoder != nil else {
            throw SkyBridgeOpusError.encoderCreateFailed(error)
        }
        self.configuration = configuration
        try apply(configuration)
    }

    deinit {
        if let encoder {
            opus_encoder_destroy(encoder)
        }
    }

    public func reconfigure(_ configuration: SkyBridgeOpusConfiguration) throws {
        try Self.validate(configuration)
        guard configuration.sampleRate == self.configuration.sampleRate,
              configuration.channels == self.configuration.channels,
              configuration.frameDurationMs == self.configuration.frameDurationMs else {
            throw SkyBridgeOpusError.opusCallFailed(operation: "reconfigure-static-format", code: OPUS_BAD_ARG)
        }
        try apply(configuration)
        self.configuration = configuration
    }

    public func encode(pcm16Interleaved: Data, maxPacketBytes: Int = 4_096) throws -> Data {
        guard pcm16Interleaved.count % MemoryLayout<Int16>.size == 0 else {
            throw SkyBridgeOpusError.invalidPCMByteCount(pcm16Interleaved.count)
        }
        let sampleCount = pcm16Interleaved.count / MemoryLayout<Int16>.size
        guard sampleCount == configuration.interleavedSampleCount else {
            throw SkyBridgeOpusError.invalidPCMByteCount(pcm16Interleaved.count)
        }
        return try pcm16Interleaved.withUnsafeBytes { rawBuffer in
            guard let pcm = rawBuffer.bindMemory(to: opus_int16.self).baseAddress else {
                throw SkyBridgeOpusError.invalidPCMByteCount(pcm16Interleaved.count)
            }
            return try encode(pcm: pcm, maxPacketBytes: maxPacketBytes)
        }
    }

    public func encode(pcm16Interleaved: [Int16], maxPacketBytes: Int = 4_096) throws -> Data {
        guard pcm16Interleaved.count == configuration.interleavedSampleCount else {
            throw SkyBridgeOpusError.invalidPCMByteCount(pcm16Interleaved.count * MemoryLayout<Int16>.size)
        }
        return try pcm16Interleaved.withUnsafeBufferPointer { buffer in
            guard let pcm = buffer.baseAddress else {
                throw SkyBridgeOpusError.invalidPCMByteCount(0)
            }
            return try encode(pcm: pcm, maxPacketBytes: maxPacketBytes)
        }
    }

    private func encode(pcm: UnsafePointer<opus_int16>, maxPacketBytes: Int) throws -> Data {
        guard let encoder else {
            throw SkyBridgeOpusError.opusCallFailed(operation: "encode-after-destroy", code: OPUS_INVALID_STATE)
        }
        var output = [UInt8](repeating: 0, count: max(1, maxPacketBytes))
        let written = output.withUnsafeMutableBufferPointer { outputBuffer in
            guard let outputBaseAddress = outputBuffer.baseAddress else {
                return Int32(OPUS_BAD_ARG)
            }
            return opus_encode(
                encoder,
                pcm,
                Int32(configuration.samplesPerChannel),
                outputBaseAddress,
                Int32(outputBuffer.count)
            )
        }
        guard written >= 0 else {
            throw SkyBridgeOpusError.opusCallFailed(operation: "encode", code: written)
        }
        return Data(output.prefix(Int(written)))
    }

    private func apply(_ configuration: SkyBridgeOpusConfiguration) throws {
        guard let encoder else {
            throw SkyBridgeOpusError.opusCallFailed(operation: "configure-after-destroy", code: OPUS_INVALID_STATE)
        }
        try check(skybridge_opus_encoder_set_bitrate(encoder, Int32(configuration.bitrate)), operation: "set-bitrate")
        try check(skybridge_opus_encoder_set_complexity(encoder, Int32(configuration.complexity)), operation: "set-complexity")
        try check(skybridge_opus_encoder_set_inband_fec(encoder, configuration.inBandFECEnabled ? 1 : 0), operation: "set-fec")
        try check(skybridge_opus_encoder_set_packet_loss_perc(encoder, Int32(configuration.expectedPacketLossPercent)), operation: "set-loss")
        try check(skybridge_opus_encoder_set_dtx(encoder, configuration.dtxEnabled ? 1 : 0), operation: "set-dtx")
        try check(skybridge_opus_encoder_set_signal(encoder, configuration.signal.opusValue), operation: "set-signal")
    }

    private static func validate(_ configuration: SkyBridgeOpusConfiguration) throws {
        guard [8_000, 12_000, 16_000, 24_000, 48_000].contains(configuration.sampleRate) else {
            throw SkyBridgeOpusError.invalidSampleRate(configuration.sampleRate)
        }
        guard configuration.channels == 1 || configuration.channels == 2 else {
            throw SkyBridgeOpusError.invalidChannelCount(configuration.channels)
        }
    }

    private func check(_ code: Int32, operation: String) throws {
        guard code == OPUS_OK else {
            throw SkyBridgeOpusError.opusCallFailed(operation: operation, code: code)
        }
    }
}

public final class SkyBridgeOpusDecoder {
    private var decoder: OpaquePointer?
    public let sampleRate: Int
    public let channels: Int
    public let defaultFrameSamplesPerChannel: Int

    public init(sampleRate: Int = 48_000, channels: Int = 2, frameDurationMs: Int = 20) throws {
        guard [8_000, 12_000, 16_000, 24_000, 48_000].contains(sampleRate) else {
            throw SkyBridgeOpusError.invalidSampleRate(sampleRate)
        }
        guard channels == 1 || channels == 2 else {
            throw SkyBridgeOpusError.invalidChannelCount(channels)
        }
        var error: Int32 = 0
        decoder = opus_decoder_create(Int32(sampleRate), Int32(channels), &error)
        guard error == OPUS_OK, decoder != nil else {
            throw SkyBridgeOpusError.decoderCreateFailed(error)
        }
        self.sampleRate = sampleRate
        self.channels = channels
        self.defaultFrameSamplesPerChannel = sampleRate * frameDurationMs / 1_000
    }

    deinit {
        if let decoder {
            opus_decoder_destroy(decoder)
        }
    }

    public func decode(packet: Data?, frameSamplesPerChannel: Int? = nil, useFEC: Bool = false) throws -> [Int16] {
        guard let decoder else {
            throw SkyBridgeOpusError.opusCallFailed(operation: "decode-after-destroy", code: OPUS_INVALID_STATE)
        }
        let frameSamples = frameSamplesPerChannel ?? defaultFrameSamplesPerChannel
        var pcm = [opus_int16](repeating: 0, count: frameSamples * channels)
        let decodedSamples: Int32
        if let packet, !packet.isEmpty {
            decodedSamples = packet.withUnsafeBytes { rawBuffer in
                opus_decode(
                    decoder,
                    rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                    Int32(packet.count),
                    &pcm,
                    Int32(frameSamples),
                    useFEC ? 1 : 0
                )
            }
        } else {
            decodedSamples = opus_decode(
                decoder,
                nil,
                0,
                &pcm,
                Int32(frameSamples),
                0
            )
        }
        guard decodedSamples >= 0 else {
            throw SkyBridgeOpusError.opusCallFailed(operation: "decode", code: decodedSamples)
        }
        let decodedCount = Int(decodedSamples) * channels
        return Array(pcm[0..<decodedCount]).map { Int16($0) }
    }
}
