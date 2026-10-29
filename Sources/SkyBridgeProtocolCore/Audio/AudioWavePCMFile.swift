import Foundation

public enum AudioWavePCMFileError: Error, Equatable, Sendable {
    case oversized, truncated, malformed, unsupportedContainer, unsupportedEncoding
    case unsupportedLayout, undeclaredPrecision, chunkLimit, invalidReadLength
}

/// Declarations and byte ranges from one uncompressed RIFF/WAVE container. This is not a
/// decoder, an output-format admission, a content hash, or proof of the signal's effective precision.
public struct AudioWavePCMMetadata: Equatable, Sendable {
    public let format: AudioStreamingPCMFormat
    public let pcmByteOffset: UInt64
    public let pcmByteCount: UInt64
    public var frameCount: UInt64 { pcmByteCount / UInt64(format.bytesPerFrame) }
}

public enum AudioWavePCMFile {
    public static let maximumChunks = 4_096
    public static let maximumReadBytes = 40
    /// RIFF uses a DWORD payload size excluding its initial eight bytes. RF64 is not accepted.
    public static let maximumFileBytes = min(AudioStreamingWire.maximumFileBytes, UInt64(UInt32.max) + 8)

    /// Inspects a caller-owned, immutable/verified source. `fileSize` must describe that same source;
    /// `read` must return exactly the requested range. Use an already prepared file-read session
    /// when source identity/content guarantees are required. The parser owns no descriptor and
    /// never closes the caller's source. It neither reads nor changes PCM, padding, or metadata.
    ///
    /// Every request is at most 40 bytes; unknown payloads are skipped by checked offsets. All
    /// chunks are inspected before returning, including chunks after data. Callback errors are
    /// propagated unchanged. Cancellation is checked before and after every asynchronous read.
    public static func inspect(fileSize: UInt64,
        read: @Sendable (UInt64, Int) async throws -> Data) async throws -> AudioWavePCMMetadata {
        try Task.checkCancellation()
        guard fileSize <= maximumFileBytes else { throw AudioWavePCMFileError.oversized }
        guard fileSize >= 12 else { throw AudioWavePCMFileError.truncated }
        let header = try await readBytes(at: 0, count: 12, fileSize: fileSize, read: read)
        guard fourCC(header, 0) == "RIFF", fourCC(header, 8) == "WAVE" else {
            throw AudioWavePCMFileError.unsupportedContainer
        }
        let riffEnd = UInt64(u32(header, 4)) + 8
        guard riffEnd >= 12 else { throw AudioWavePCMFileError.malformed }
        guard riffEnd <= fileSize else { throw AudioWavePCMFileError.truncated }
        guard riffEnd == fileSize else { throw AudioWavePCMFileError.unsupportedLayout }
        var offset: UInt64 = 12
        var chunks = 0
        var format: AudioStreamingPCMFormat?
        var pcmRange: (offset: UInt64, count: UInt64)?
        while offset < riffEnd {
            try Task.checkCancellation()
            guard chunks < maximumChunks else { throw AudioWavePCMFileError.chunkLimit }
            chunks += 1
            guard riffEnd - offset >= 8 else { throw AudioWavePCMFileError.truncated }
            let chunk = try await readBytes(at: offset, count: 8, fileSize: fileSize, read: read)
            let length = UInt64(u32(chunk, 4))
            let start = offset + 8 // Checked above against riffEnd, which is at most UInt32.max + 8.
            let padding = length & 1
            guard length <= riffEnd - start, padding <= riffEnd - start - length else {
                throw AudioWavePCMFileError.truncated
            }
            switch fourCC(chunk, 0) {
            case "fmt ":
                guard format == nil else { throw AudioWavePCMFileError.unsupportedLayout }
                guard length >= 16 else { throw AudioWavePCMFileError.truncated }
                let bytes = try await readBytes(at: start, count: Int(min(length, 40)), fileSize: fileSize, read: read)
                format = try parseFormat(bytes, chunkSize: length)
            case "data":
                guard pcmRange == nil else { throw AudioWavePCMFileError.unsupportedLayout }
                pcmRange = (start, length)
            case "LIST":
                guard length >= 4 else { throw AudioWavePCMFileError.malformed }
                let type = try await readBytes(at: start, count: 4, fileSize: fileSize, read: read)
                guard fourCC(type, 0) != "wavl" else { throw AudioWavePCMFileError.unsupportedLayout }
            case "slnt": throw AudioWavePCMFileError.unsupportedLayout
            default: break
            }
            offset = start + length + padding
        }
        guard let format, let pcmRange else { throw AudioWavePCMFileError.malformed }
        guard pcmRange.count % UInt64(format.bytesPerFrame) == 0 else { throw AudioWavePCMFileError.malformed }
        try Task.checkCancellation()
        return .init(format: format, pcmByteOffset: pcmRange.offset, pcmByteCount: pcmRange.count)
    }

    private static func parseFormat(_ bytes: [UInt8], chunkSize: UInt64) throws -> AudioStreamingPCMFormat {
        let tag = u16(bytes, 0)
        let channels = u16(bytes, 2)
        let rate = u32(bytes, 4)
        let byteRate = u32(bytes, 8)
        let blockAlign = u16(bytes, 12)
        let containerBits = u16(bytes, 14)
        var validBits = containerBits
        var mask: UInt32?
        let encodingTag: UInt32
        switch tag {
        case 1, 3:
            // Legacy 16-byte PCM/float descriptors are accepted as on Android. Do not read a
            // missing cbSize or treat ignored PCM extension bytes as allocation instructions.
            encodingTag = UInt32(tag)
        case 0xfffe:
            guard chunkSize >= 40 else { throw AudioWavePCMFileError.truncated }
            let extra = u16(bytes, 16)
            guard extra >= 22, UInt64(extra) + 18 <= chunkSize else { throw AudioWavePCMFileError.malformed }
            validBits = u16(bytes, 18)
            guard validBits != 0 else { throw AudioWavePCMFileError.undeclaredPrecision }
            mask = u32(bytes, 20)
            // DEFINE_WAVEFORMATEX_GUID: tag-0000-0010-8000-00aa00389b71. The first three GUID
            // fields use little-endian storage; compare all remaining bytes, not only the tag.
            let tail: [UInt8] = [0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71]
            guard Array(bytes[28..<40]) == tail else { throw AudioWavePCMFileError.unsupportedEncoding }
            encodingTag = u32(bytes, 24)
        default: throw AudioWavePCMFileError.unsupportedEncoding
        }
        let encoding: AudioStreamingPCMFormat.Encoding
        switch (encodingTag, containerBits) {
        case (1, 8): encoding = .unsigned8
        case (1, 16): encoding = .signed16
        case (1, 24): encoding = .signed24
        case (1, 32): encoding = .signed32
        case (1, 64): encoding = .signed64
        case (3, 32): encoding = .float32
        case (3, 64): encoding = .float64
        default: throw AudioWavePCMFileError.unsupportedEncoding
        }
        guard validBits > 0, validBits <= containerBits else { throw AudioWavePCMFileError.malformed }
        let format: AudioStreamingPCMFormat
        do {
            // Preserve every declared mask, including zero DIRECTOUT and masks whose channel
            // mapping an output cannot realize. Unknown legacy layout stays nil. Admission to a
            // physical endpoint must independently reject unsupported/ambiguous mappings.
            format = try .init(sampleRate: rate, channels: channels, encoding: encoding,
                               declaredValidBits: UInt8(validBits), waveChannelMask: mask)
        } catch AudioStreamingWireError.invalidFormat { throw AudioWavePCMFileError.malformed }
        guard UInt32(blockAlign) == format.bytesPerFrame,
              UInt64(byteRate) == UInt64(rate) * UInt64(format.bytesPerFrame) else {
            throw AudioWavePCMFileError.malformed
        }
        return format
    }

    private static func readBytes(at offset: UInt64, count: Int, fileSize: UInt64,
        read: @Sendable (UInt64, Int) async throws -> Data) async throws -> [UInt8] {
        try Task.checkCancellation()
        guard count > 0, count <= maximumReadBytes, offset <= fileSize,
              UInt64(count) <= fileSize - offset else { throw AudioWavePCMFileError.truncated }
        let bytes = try await read(offset, count)
        try Task.checkCancellation()
        guard bytes.count >= count else { throw AudioWavePCMFileError.truncated }
        guard bytes.count == count else { throw AudioWavePCMFileError.invalidReadLength }
        return Array(bytes) // Normalizes Data slice indices with a constant-size bounded copy.
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
            UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
    private static func fourCC(_ bytes: [UInt8], _ offset: Int) -> String {
        String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }
}
