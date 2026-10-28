import Foundation

public enum AudioFlacMetadataError: Error, Equatable, Sendable {
    case truncated, malformed, unsupportedContainer, metadataLimit, invalidReadLength, oversized
}

/// Source declarations only, not validated frames, decoded PCM, or hardware-output admission.
public struct AudioFlacMetadata: Equatable, Sendable {
    public let decodedFormat: AudioStreamingPCMFormat
    public let totalFrames: UInt64?
    public let pcmMD5Hex: String?
    public let firstFrameByteOffset: UInt64
    public let minimumBlockFrames: UInt16
    public let maximumBlockFrames: UInt16
    public let minimumFrameBytes: UInt32?
    public let maximumFrameBytes: UInt32?
    public let hasExplicitChannelMask: Bool
}

/// RFC 9639 metadata from one caller-owned immutable source. Does not open or close files, fetch
/// artwork, decode audio or validate frame checksums. A decoder must recheck every audio frame.
/// Read errors propagate unchanged and cancellation is checked around every asynchronous read.
///
/// FLAC declares signed precision, not a PCM container byte width. decodedFormat specifies the
/// reversible canonical representation: little endian, interleaved, high-aligned valid bits in the
/// smallest 8/16/24/32-bit container, with 8-bit offset binary. Explicit masks, even zero or partial
/// assignments, remain explicit; independent output admission must reject unsupported mappings.
public enum AudioFlacFile {
    public static let maximumFileBytes = AudioStreamingWire.maximumFileBytes
    public static let maximumMetadataBytes: UInt64 = 64 * 1_024 * 1_024
    public static let maximumBlocks = 4_096
    public static let maximumCommentBytes = 1_048_576
    public static let maximumCommentFields = 4_096
    public static let maximumReadBytes = 65_536
    private static let maskField = "waveformatextensible_channel_mask"
    private static let defaultMasks: [UInt32] = [4, 3, 7, 0x33, 0x37, 0x3f, 0x70f, 0x63f]

    public static func inspect(fileSize: UInt64,
        read: @Sendable (UInt64, Int) async throws -> Data) async throws -> AudioFlacMetadata {
        try Task.checkCancellation()
        guard fileSize <= maximumFileBytes else { throw AudioFlacMetadataError.oversized }
        let signature = try await bytes(at: 0, count: 4, fileSize: fileSize, read: read)
        guard signature == [0x66, 0x4c, 0x61, 0x43] else { throw AudioFlacMetadataError.unsupportedContainer }
        var offset: UInt64 = 4
        var streamInfo: [UInt8]?
        var explicitMask: UInt32?
        var commentsSeen = false
        var blockCount = 0
        while true {
            blockCount += 1
            guard blockCount <= maximumBlocks, offset <= maximumMetadataBytes - 4 else {
                throw AudioFlacMetadataError.metadataLimit
            }
            let header = try await bytes(at: offset, count: 4, fileSize: fileSize, read: read)
            let type = header[0] & 0x7f
            let last = header[0] & 0x80 != 0
            let length = Int(be(header, 1, 3))
            let start = offset + 4
            guard UInt64(length) <= fileSize - start else { throw AudioFlacMetadataError.truncated }
            guard UInt64(length) <= maximumMetadataBytes - start else { throw AudioFlacMetadataError.metadataLimit }
            guard type != 127, blockCount != 1 || type == 0 else { throw AudioFlacMetadataError.malformed }
            switch type {
            case 0:
                guard streamInfo == nil, length == 34 else { throw AudioFlacMetadataError.malformed }
                streamInfo = try await bytes(at: start, count: length, fileSize: fileSize, read: read)
            case 4:
                guard !commentsSeen else { throw AudioFlacMetadataError.malformed }
                commentsSeen = true
                guard length <= maximumCommentBytes else { throw AudioFlacMetadataError.metadataLimit }
                var comment: [UInt8] = []
                comment.reserveCapacity(length)
                while comment.count < length {
                    let part = try await bytes(at: start + UInt64(comment.count),
                        count: min(length - comment.count, maximumReadBytes), fileSize: fileSize, read: read)
                    comment.append(contentsOf: part)
                }
                explicitMask = try channelMask(comment)
            default: break // Ignorable payloads are skipped without loading artwork or application data.
            }
            offset = start + UInt64(length)
            if last { break }
        }
        guard offset < fileSize else { throw AudioFlacMetadataError.truncated }
        guard let info = streamInfo else { throw AudioFlacMetadataError.malformed }
        let minimumBlock = UInt16(be(info, 0, 2))
        let maximumBlock = UInt16(be(info, 2, 2))
        let minimumFrame = UInt32(be(info, 4, 3))
        let maximumFrame = UInt32(be(info, 7, 3))
        let rate = UInt32(be(info, 10, 3) >> 4)
        let channels = UInt16((info[12] >> 1) & 7) + 1
        let bits = ((info[12] & 1) << 4 | info[13] >> 4) + 1
        let frames = UInt64(info[13] & 15) << 32 | be(info, 14, 4)
        guard minimumBlock >= 16, maximumBlock >= minimumBlock, rate != 0, (4...32).contains(bits),
              minimumFrame == 0 || maximumFrame == 0 || minimumFrame <= maximumFrame else {
            throw AudioFlacMetadataError.malformed
        }
        let encoding: AudioStreamingPCMFormat.Encoding
        switch bits {
        case 4...8: encoding = .unsigned8
        case 9...16: encoding = .signed16
        case 17...24: encoding = .signed24
        default: encoding = .signed32
        }
        let format = try AudioStreamingPCMFormat(sampleRate: rate, channels: channels, encoding: encoding,
            declaredValidBits: bits, waveChannelMask: explicitMask ?? defaultMasks[Int(channels) - 1])
        let digest = Array(info[18..<34])
        let hex = digest.allSatisfy { $0 == 0 } ? nil : digest.map { String(format: "%02x", $0) }.joined()
        try Task.checkCancellation()
        return .init(decodedFormat: format, totalFrames: frames == 0 ? nil : frames, pcmMD5Hex: hex,
            firstFrameByteOffset: offset, minimumBlockFrames: minimumBlock, maximumBlockFrames: maximumBlock,
            minimumFrameBytes: minimumFrame == 0 ? nil : minimumFrame,
            maximumFrameBytes: maximumFrame == 0 ? nil : maximumFrame, hasExplicitChannelMask: explicitMask != nil)
    }

    private static func channelMask(_ bytes: [UInt8]) throws -> UInt32? {
        var cursor = 0
        func length() throws -> Int {
            guard bytes.count - cursor >= 4 else { throw AudioFlacMetadataError.malformed }
            let value = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[cursor + $1]) << ($1 * 8) }
            cursor += 4
            guard value <= Int32.max else { throw AudioFlacMetadataError.malformed }
            return Int(value)
        }
        func text(_ count: Int) throws -> String {
            guard count <= bytes.count - cursor else { throw AudioFlacMetadataError.malformed }
            guard let value = String(bytes: bytes[cursor..<(cursor + count)], encoding: .utf8) else {
                throw AudioFlacMetadataError.malformed
            }
            cursor += count
            return value
        }
        _ = try text(length())
        let fields = try length()
        guard fields <= maximumCommentFields else { throw AudioFlacMetadataError.metadataLimit }
        var mask: UInt32?
        for _ in 0..<fields {
            try Task.checkCancellation()
            let field = Array(try text(length()).utf8)
            guard let separator = field.firstIndex(of: 0x3d), separator > 0,
                  field[..<separator].allSatisfy({ (0x20...0x7e).contains($0) }) else {
                throw AudioFlacMetadataError.malformed
            }
            let name = String(decoding: field[..<separator], as: UTF8.self).lowercased()
            if name == maskField {
                guard mask == nil else { throw AudioFlacMetadataError.malformed }
                let value = Array(field[(separator + 1)...])
                guard value.count >= 3, value[0] == 0x30, value[1] == 0x78 || value[1] == 0x58 else {
                    throw AudioFlacMetadataError.malformed
                }
                var parsed: UInt32 = 0
                for character in value.dropFirst(2) {
                    let digit: UInt32
                    switch character {
                    case 0x30...0x39: digit = UInt32(character - 0x30)
                    case 0x41...0x46: digit = UInt32(character - 0x41 + 10)
                    case 0x61...0x66: digit = UInt32(character - 0x61 + 10)
                    default: throw AudioFlacMetadataError.malformed
                    }
                    guard parsed <= (UInt32.max - digit) / 16 else { throw AudioFlacMetadataError.malformed }
                    parsed = parsed * 16 + digit
                }
                mask = parsed
            }
        }
        guard cursor == bytes.count else { throw AudioFlacMetadataError.malformed }
        return mask
    }

    private static func bytes(at offset: UInt64, count: Int, fileSize: UInt64,
        read: @Sendable (UInt64, Int) async throws -> Data) async throws -> [UInt8] {
        try Task.checkCancellation()
        guard (1...maximumReadBytes).contains(count), offset <= fileSize, UInt64(count) <= fileSize - offset else {
            throw AudioFlacMetadataError.truncated
        }
        let value = try await read(offset, count)
        try Task.checkCancellation()
        guard value.count >= count else { throw AudioFlacMetadataError.truncated }
        guard value.count == count else { throw AudioFlacMetadataError.invalidReadLength }
        return Array(value)
    }

    private static func be(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
        (0..<count).reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[offset + $1]) }
    }
}
