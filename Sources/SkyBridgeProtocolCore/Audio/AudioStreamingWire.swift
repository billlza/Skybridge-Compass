import Foundation

public enum AudioStreamingWireError: Error, Equatable, Sendable {
    case malformed, oversized, invalidIdentifier, invalidFormat, invalidRange, invalidDigest
    case unsupportedVersion(UInt8), unknownOpcode(UInt8), unknownEncoding(UInt8), unknownReason(UInt16)
}

public struct AudioStreamingPCMFormat: Equatable, Sendable {
    public enum Encoding: UInt8, Sendable, CaseIterable {
        case unsigned8 = 1, signed16, signed24, signed32, signed64, float32, float64
        public var containerBits: UInt8 {
            switch self {
            case .unsigned8: 8
            case .signed16: 16
            case .signed24: 24
            case .signed32, .float32: 32
            case .signed64, .float64: 64
            }
        }
        public var isFloatingPoint: Bool { self == .float32 || self == .float64 }
    }

    public let sampleRate: UInt32
    public let channels: UInt16
    public let encoding: Encoding
    public let declaredValidBits: UInt8
    public let waveChannelMask: UInt32?
    public var bytesPerFrame: UInt32 { UInt32(channels) * UInt32(encoding.containerBits / 8) }

    public init(sampleRate: UInt32, channels: UInt16, encoding: Encoding,
                declaredValidBits: UInt8, waveChannelMask: UInt32?) throws {
        let frameBytes = UInt64(channels) * UInt64(encoding.containerBits / 8)
        guard sampleRate > 0, channels > 0, declaredValidBits > 0,
              declaredValidBits <= encoding.containerBits,
              !encoding.isFloatingPoint || declaredValidBits == encoding.containerBits,
              frameBytes <= UInt16.max,
              UInt64(sampleRate) * frameBytes <= UInt32.max else {
            throw AudioStreamingWireError.invalidFormat
        }
        self.sampleRate = sampleRate; self.channels = channels; self.encoding = encoding
        self.declaredValidBits = declaredValidBits; self.waveChannelMask = waveChannelMask
    }
}

/// Explicit lossy Bluetooth profile; never an original PCM or hardware-format guarantee.
public struct AudioStreamingOpusFormat: Equatable, Sendable {
    public let channels: UInt8
    public let bitrate: UInt32
    public var sampleRate: UInt32 { 48_000 }
    public var packetFrames: UInt16 { 960 }
    public var packetBytes: UInt32 { bitrate / 400 }
    public init(channels: UInt8, bitrate: UInt32) throws {
        guard (1...2).contains(channels), [128_000, 192_000, 256_000].contains(bitrate) else {
            throw AudioStreamingWireError.invalidFormat
        }
        self.channels = channels; self.bitrate = bitrate
    }
}

/// Sender's source claim, not capture permission or original-format attestation.
public enum AudioStreamingOpusSource: UInt8, Sendable, CaseIterable { case originalFile = 1, systemCapture }

/// An authenticated offer selects the complete queue policy. The buffered file profile
/// trades initial latency for bounded refill margin; it is never inferred from a codec rate.
public enum AudioStreamingOpusBuffering: Equatable, Sendable {
    case legacy, bufferedFile
    public var windowPackets: UInt32 { self == .legacy ? 16 : 64 }
    public var minimumPrefillFrames: UInt64 { UInt64(self == .legacy ? 10 : 48) * 960 }
    public var capacityFrames: UInt64 { UInt64(windowPackets) * 960 }
}

public struct AudioStreamingOpusOfferParameters: Equatable, Sendable {
    public let source: AudioStreamingOpusSource
    public let format: AudioStreamingOpusFormat
    public let buffering: AudioStreamingOpusBuffering
}

public enum AudioStreamingStopReason: UInt16, Sendable, CaseIterable {
    case userStopped = 1, permissionRevoked, sourceFailed, unsupportedOutput, queueOverflow
    case outputLost, protocolViolation, accountRevoked, sessionReplaced, timedOut
    case contentMismatch, unsupportedSource, receiverDeclined
}

public struct AudioStreamingMessage: Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        case fileOffer(transferID: UUID, length: UInt64, sha256: Data)
        case captureOffer(AudioStreamingPCMFormat)
        case accept(receiveWindowBytes: UInt32)
        case pcmData(byteOffset: UInt64, bytes: Data)
        case credit(retiredBytes: UInt64)
        case end(totalBytes: UInt64, sha256: Data)
        case contentVerified(totalBytes: UInt64, sha256: Data)
        case outputReady(AudioStreamingPCMFormat)
        case playbackComplete(sourceFrames: UInt64, trailingPaddingFrames: UInt32)
        /// Negotiated native output progress, never completion, flow credit or authorization.
        case fileOutputProgress(sourceFrames: UInt64)
        case stop(AudioStreamingStopReason)
        case opusOffer(source: AudioStreamingOpusSource, format: AudioStreamingOpusFormat)
        case opusConfiguration(preSkipFrames: UInt16)
        case opusData(sequence: UInt64, bytes: Data)
        case opusEnd(sourceFrames: UInt64, packetCount: UInt64, totalEncodedBytes: UInt64, sha256: Data)
        case opusOutputReady
        case bluetoothRoute(AudioBluetoothRoute)
        case usbFileRoute(port: UInt16)
        case bufferedOpusFileOffer(AudioStreamingOpusFormat)

        public var opusOfferParameters: AudioStreamingOpusOfferParameters? {
            switch self {
            case let .opusOffer(source, format): .init(source: source, format: format, buffering: .legacy)
            case let .bufferedOpusFileOffer(format): .init(source: .originalFile, format: format, buffering: .bufferedFile)
            default: nil
            }
        }

        fileprivate var opcode: UInt8 {
            switch self {
            case .fileOffer: 1
            case .captureOffer: 2
            case .accept: 3
            case .pcmData: 4
            case .credit: 5
            case .end: 6
            case .contentVerified: 7
            case .outputReady: 8
            case .playbackComplete: 9
            case .stop: 10
            case .opusOffer: 11
            case .opusConfiguration: 12
            case .opusData: 13
            case .opusEnd: 14
            case .opusOutputReady: 15
            case .bluetoothRoute: 16
            case .usbFileRoute: 17
            case .bufferedOpusFileOffer: 18
            case .fileOutputProgress: 19
            }
        }
    }

    public let streamID: UUID
    public let body: Body
    public init(streamID: UUID, body: Body) { self.streamID = streamID; self.body = body }
}

/// Structural codec only. Callers must authenticate and admit an exact stream owner
/// before applying a message. Successful decoding never grants playback or file access.
public enum AudioStreamingWire {
    public static let maximumMessageBytes = 12_288
    public static let maximumPCMDataBytes = maximumMessageBytes - 28 - 8
    public static let maximumReceiveWindowBytes: UInt32 = 1_048_576
    public static let maximumFileBytes: UInt64 = 16 * 1024 * 1024 * 1024
    public static let maximumCounter = UInt64(Int64.max)
    public static let fileReceiveCapability = "audio_file_receive_v1"
    // Requires finite native FLAC, full prevalidation and the bounded 180-second validation phase.
    // Senders still require fileReceiveCapability for the unchanged original-file transfer protocol.
    public static let flacFileReceiveCapability = "audio_flac_file_receive_v1"
    // Finite mono/stereo ALAC in a self-contained M4A: complete native prevalidation before output.
    // Requires fileReceiveCapability and the same bounded validation window as native FLAC.
    public static let alacFileReceiveCapability = "audio_alac_file_receive_v1"
    // Both installed roles are required; structural codec support does not advertise either role.
    public static let fileOutputProgressReportCapability = "audio_file_output_progress_report_v1"
    public static let fileOutputProgressReceiveCapability = "audio_file_output_progress_receive_v1"
    public static let captureReceiveCapability = "audio_capture_receive_v1"
    // Codec availability alone never permits advertising a receive role.
    public static let opusReceiveCapability = "audio_opus_bluetooth_receive_v1"
    public static let bluetoothAttachmentCapability = "audio_bluetooth_attachment_v1"
    // Requires the 64-packet receive window and bounded 960 ms native prefill, not just a parser.
    public static let bufferedOpusFileReceiveCapability = "audio_opus_buffered_file_receive_v1"
    public static let usbFileSendCapability = "audio_file_usb_return_send_v1"
    public static let usbFileReceiveCapability = "audio_file_usb_return_receive_v1"
    public static let usbStreamFileSendCapability = "audio_file_usb_stream_send_v1"
    public static let usbStreamFileReceiveCapability = "audio_file_usb_stream_receive_v1"
    public static let maximumOpusPacketBytes = 640
    public static let maximumOpusPreSkipFrames: UInt16 = 3840
    public static let maximumOpusPacketCount = maximumCounter / 960

    public static func encode(_ message: AudioStreamingMessage) throws -> Data {
        try validate(message)
        var body = Writer()
        switch message.body {
        case let .fileOffer(id, length, digest): body.uuid(id); body.u64(length); body.data(digest)
        case let .captureOffer(format), let .outputReady(format): body.format(format)
        case let .accept(window): body.u32(window)
        case let .pcmData(offset, bytes): body.u64(offset); body.data(bytes)
        case let .credit(retired): body.u64(retired)
        case let .end(total, digest), let .contentVerified(total, digest): body.u64(total); body.data(digest)
        case let .playbackComplete(frames, padding): body.u64(frames); body.u32(padding)
        case let .fileOutputProgress(frames): body.u64(frames)
        case let .stop(reason): body.u16(reason.rawValue); body.u16(0)
        case let .opusOffer(source, format):
            body.u8(1); body.u8(source.rawValue); body.u8(format.channels); body.u8(0)
            body.u32(format.sampleRate); body.u16(format.packetFrames); body.u16(0); body.u32(format.bitrate)
        case let .bufferedOpusFileOffer(format):
            body.u8(1); body.u8(AudioStreamingOpusSource.originalFile.rawValue); body.u8(format.channels); body.u8(0)
            body.u32(format.sampleRate); body.u16(format.packetFrames); body.u16(0); body.u32(format.bitrate)
        case let .opusConfiguration(skip): body.u16(skip); body.u16(0)
        case let .opusData(sequence, bytes): body.u64(sequence); body.data(bytes)
        case let .opusEnd(frames, count, total, digest): body.u64(frames); body.u64(count); body.u64(total); body.data(digest)
        case .opusOutputReady: break
        case let .bluetoothRoute(route):
            body.u16(route.psm); body.u16(0); body.uuid(route.serviceID); body.uuid(route.publicationID)
        case let .usbFileRoute(port): body.u16(port); body.u16(0)
        }
        guard body.bytes.count <= maximumMessageBytes - 28 else { throw AudioStreamingWireError.oversized }
        var wire = Writer()
        wire.u32(0x53424155); wire.u8(1); wire.u8(message.body.opcode); wire.u16(0)
        wire.uuid(message.streamID); wire.u32(UInt32(body.bytes.count)); wire.data(body.bytes)
        return wire.bytes
    }

    public static func decode(_ data: Data) throws -> AudioStreamingMessage {
        guard data.count <= maximumMessageBytes else { throw AudioStreamingWireError.oversized }
        guard data.count >= 28 else { throw AudioStreamingWireError.malformed }
        var reader = Reader(bytes: Array(data)) // One bounded copy also normalizes nonzero Data indices.
        guard try reader.u32() == 0x53424155 else { throw AudioStreamingWireError.malformed }
        let version = try reader.u8()
        guard version == 1 else { throw AudioStreamingWireError.unsupportedVersion(version) }
        let opcode = try reader.u8()
        guard try reader.u16() == 0 else { throw AudioStreamingWireError.malformed }
        let id = try reader.uuid()
        let bodyLength = try reader.u32()
        guard Int(bodyLength) == reader.remaining else { throw AudioStreamingWireError.malformed }
        let body: AudioStreamingMessage.Body
        switch opcode {
        case 1: body = .fileOffer(transferID: try reader.uuid(), length: try reader.u64(), sha256: try reader.data(32))
        case 2: body = .captureOffer(try reader.format())
        case 3: body = .accept(receiveWindowBytes: try reader.u32())
        case 4:
            let offset = try reader.u64()
            body = .pcmData(byteOffset: offset, bytes: try reader.data(reader.remaining))
        case 5: body = .credit(retiredBytes: try reader.u64())
        case 6: body = .end(totalBytes: try reader.u64(), sha256: try reader.data(32))
        case 7: body = .contentVerified(totalBytes: try reader.u64(), sha256: try reader.data(32))
        case 8: body = .outputReady(try reader.format())
        case 9: body = .playbackComplete(sourceFrames: try reader.u64(), trailingPaddingFrames: try reader.u32())
        case 19: body = .fileOutputProgress(sourceFrames: try reader.u64())
        case 10:
            let raw = try reader.u16()
            guard let reason = AudioStreamingStopReason(rawValue: raw) else { throw AudioStreamingWireError.unknownReason(raw) }
            guard try reader.u16() == 0 else { throw AudioStreamingWireError.malformed }
            body = .stop(reason)
        case 11, 18:
            guard try reader.u8() == 1, let source = AudioStreamingOpusSource(rawValue: try reader.u8()) else {
                throw AudioStreamingWireError.invalidFormat
            }
            let channels = try reader.u8()
            guard try reader.u8() == 0, try reader.u32() == 48_000,
                  try reader.u16() == 960, try reader.u16() == 0 else { throw AudioStreamingWireError.invalidFormat }
            let format = try AudioStreamingOpusFormat(channels: channels, bitrate: reader.u32())
            if opcode == 18 {
                guard source == .originalFile else { throw AudioStreamingWireError.invalidFormat }
                body = .bufferedOpusFileOffer(format)
            } else { body = .opusOffer(source: source, format: format) }
        case 12:
            let skip = try reader.u16()
            guard try reader.u16() == 0 else { throw AudioStreamingWireError.malformed }
            body = .opusConfiguration(preSkipFrames: skip)
        case 13:
            let sequence = try reader.u64()
            guard [320, 480, 640].contains(reader.remaining) else { throw AudioStreamingWireError.invalidRange }
            body = .opusData(sequence: sequence, bytes: try reader.data(reader.remaining))
        case 14:
            body = .opusEnd(sourceFrames: try reader.u64(), packetCount: try reader.u64(),
                            totalEncodedBytes: try reader.u64(), sha256: try reader.data(32))
        case 15: body = .opusOutputReady
        case 16:
            let psm = try reader.u16()
            guard try reader.u16() == 0 else { throw AudioStreamingWireError.malformed }
            body = .bluetoothRoute(try .init(serviceID: reader.uuid(), publicationID: reader.uuid(), psm: psm))
        case 17:
            let port = try reader.u16()
            guard try reader.u16() == 0 else { throw AudioStreamingWireError.malformed }
            body = .usbFileRoute(port: port)
        default: throw AudioStreamingWireError.unknownOpcode(opcode)
        }
        guard reader.remaining == 0 else { throw AudioStreamingWireError.malformed }
        let message = AudioStreamingMessage(streamID: id, body: body)
        try validate(message)
        return message
    }

    private static func validate(_ message: AudioStreamingMessage) throws {
        guard !isZero(message.streamID) else { throw AudioStreamingWireError.invalidIdentifier }
        switch message.body {
        case let .fileOffer(id, length, digest):
            guard !isZero(id) else { throw AudioStreamingWireError.invalidIdentifier }
            guard length > 0, length <= maximumFileBytes else { throw AudioStreamingWireError.invalidRange }
            try hash(digest)
        case .captureOffer, .outputReady, .stop, .opusOffer, .bufferedOpusFileOffer, .opusOutputReady, .bluetoothRoute: break // Validated immutable types.
        case .usbFileRoute(let port):
            guard port > 0 else { throw AudioStreamingWireError.invalidRange }
        case let .accept(window):
            guard window <= maximumReceiveWindowBytes else { throw AudioStreamingWireError.invalidRange }
        case let .pcmData(offset, bytes):
            guard !bytes.isEmpty, bytes.count <= maximumPCMDataBytes else { throw AudioStreamingWireError.invalidRange }
            guard offset <= maximumCounter, UInt64(bytes.count) <= maximumCounter - offset else {
                throw AudioStreamingWireError.invalidRange
            }
        case let .credit(retired): try counter(retired)
        case let .fileOutputProgress(frames): try counter(frames)
        case let .end(total, digest), let .contentVerified(total, digest): try counter(total); try hash(digest)
        case let .playbackComplete(frames, padding):
            guard frames <= maximumCounter, UInt64(padding) <= maximumCounter - frames else {
                throw AudioStreamingWireError.invalidRange
            }
        case let .opusConfiguration(skip):
            guard skip <= maximumOpusPreSkipFrames else { throw AudioStreamingWireError.invalidRange }
        case let .opusData(sequence, bytes):
            guard sequence < maximumOpusPacketCount, [320, 480, 640].contains(bytes.count) else {
                throw AudioStreamingWireError.invalidRange
            }
        case let .opusEnd(frames, count, total, digest):
            guard frames > 0, frames <= maximumCounter - UInt64(maximumOpusPreSkipFrames),
                  count > 0, count <= maximumOpusPacketCount, total > 0, total <= maximumCounter,
                  total % count == 0, [320, 480, 640].contains(total / count) else {
                throw AudioStreamingWireError.invalidRange
            }
            try hash(digest)
        }
    }

    private static func counter(_ value: UInt64) throws {
        guard value <= maximumCounter else { throw AudioStreamingWireError.invalidRange }
    }
    private static func hash(_ digest: Data) throws {
        guard digest.count == 32 else { throw AudioStreamingWireError.invalidDigest }
    }
    private static func isZero(_ id: UUID) -> Bool {
        var value = id.uuid
        return withUnsafeBytes(of: &value) { $0.allSatisfy { $0 == 0 } }
    }

    private struct Writer {
        var bytes = Data()
        mutating func u8(_ value: UInt8) { bytes.append(value) }
        mutating func u16(_ value: UInt16) { u8(UInt8(value >> 8)); u8(UInt8(truncatingIfNeeded: value)) }
        mutating func u32(_ value: UInt32) { u16(UInt16(value >> 16)); u16(UInt16(truncatingIfNeeded: value)) }
        mutating func u64(_ value: UInt64) { u32(UInt32(value >> 32)); u32(UInt32(truncatingIfNeeded: value)) }
        mutating func data(_ value: Data) { bytes.append(value) }
        mutating func uuid(_ id: UUID) {
            var value = id.uuid
            withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        }
        mutating func format(_ value: AudioStreamingPCMFormat) {
            u32(value.sampleRate); u16(value.channels); u8(value.encoding.rawValue); u8(value.declaredValidBits)
            u8(value.waveChannelMask == nil ? 0 : 1); u8(0); u16(0); u32(value.waveChannelMask ?? 0)
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        var remaining: Int { bytes.count - offset }
        mutating func u8() throws -> UInt8 {
            guard remaining > 0 else { throw AudioStreamingWireError.malformed }
            defer { offset += 1 }; return bytes[offset]
        }
        mutating func u16() throws -> UInt16 { (UInt16(try u8()) << 8) | UInt16(try u8()) }
        mutating func u32() throws -> UInt32 { (UInt32(try u16()) << 16) | UInt32(try u16()) }
        mutating func u64() throws -> UInt64 { (UInt64(try u32()) << 32) | UInt64(try u32()) }
        mutating func data(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else { throw AudioStreamingWireError.malformed }
            defer { offset += count }; return Data(bytes[offset..<(offset + count)])
        }
        mutating func uuid() throws -> UUID {
            let b = Array(try data(16))
            return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
        }
        mutating func format() throws -> AudioStreamingPCMFormat {
            let rate = try u32(); let channels = try u16(); let raw = try u8(); let bits = try u8()
            guard let encoding = AudioStreamingPCMFormat.Encoding(rawValue: raw) else { throw AudioStreamingWireError.unknownEncoding(raw) }
            let present = try u8()
            guard present <= 1, try u8() == 0, try u16() == 0 else { throw AudioStreamingWireError.invalidFormat }
            let mask = try u32()
            guard present == 1 || mask == 0 else { throw AudioStreamingWireError.invalidFormat }
            return try .init(sampleRate: rate, channels: channels, encoding: encoding,
                             declaredValidBits: bits, waveChannelMask: present == 1 ? mask : nil)
        }
    }
}
