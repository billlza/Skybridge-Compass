import Foundation

enum RemoteDesktopScreenFrameWire {
    private static let magic: UInt32 = 0x53425246 // "SBRF"
    private static let versionV1: UInt8 = 1
    private static let versionV2: UInt8 = 2
    private static let headerSizeV1 = 28
    private static let headerSizeV2 = 36
    static let frameHeaderByteCountV2 = headerSizeV2
    static let screenChunkHeaderByteCount = 36
    private static let screenChunkMagic: UInt32 = 0x5342_4332 // "SBC2"
    private static let screenChunkVersion: UInt8 = 1

    struct ChunkEnvelope: Equatable {
        let frameId: UInt64
        let chunkIndex: Int
        let chunkCount: Int
        let totalBytes: Int
        let chunkOffset: Int
        let payload: Data
    }

    private enum CodecTag: UInt8 {
        case unknown = 0
        case jpeg = 1
        case h264 = 2
        case hevc = 3
        case bgra = 4

        init(format: String?) {
            switch (format ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "jpeg", "jpg":
                self = .jpeg
            case "h264":
                self = .h264
            case "hevc":
                self = .hevc
            case "bgra":
                self = .bgra
            default:
                self = .unknown
            }
        }

        var format: String? {
            switch self {
            case .unknown:
                return nil
            case .jpeg:
                return "jpeg"
            case .h264:
                return "h264"
            case .hevc:
                return "hevc"
            case .bgra:
                return "bgra"
            }
        }
    }

    struct Frame: Equatable {
        let width: Int
        let height: Int
        let imageData: Data
        let timestamp: TimeInterval
        let format: String?
        let isSyncFrame: Bool?
        let sequenceNumber: UInt64?
    }

    static func encode(
        width: Int,
        height: Int,
        imageData: Data,
        timestamp: TimeInterval,
        format: String?,
        isSyncFrame: Bool? = nil,
        sequenceNumber: UInt64? = nil
    ) -> Data {
        let codecTag = CodecTag(format: format)
        let timestampMicros = UInt64(max(timestamp, 0) * 1_000_000.0)
        let width = UInt32(clamping: width)
        let height = UInt32(clamping: height)
        let payloadLength = UInt32(clamping: imageData.count)
        let flags: UInt16 = containsSyncFrame(
            format: format,
            imageData: imageData,
            advertisedSyncFrame: isSyncFrame
        ) ? 0x0001 : 0
        let headerSize = sequenceNumber == nil ? headerSizeV1 : headerSizeV2

        var data = Data()
        data.reserveCapacity(headerSize + imageData.count)
        appendUInt32(magic, to: &data)
        data.append(sequenceNumber == nil ? versionV1 : versionV2)
        data.append(codecTag.rawValue)
        appendUInt16(flags, to: &data)
        appendUInt32(width, to: &data)
        appendUInt32(height, to: &data)
        appendUInt64(timestampMicros, to: &data)
        if let sequenceNumber {
            appendUInt64(sequenceNumber, to: &data)
        }
        appendUInt32(payloadLength, to: &data)
        data.append(imageData)
        return data
    }

    static func decodeIfPresent(_ data: Data) -> Frame? {
        guard data.count >= headerSizeV1 else { return nil }
        guard readUInt32(from: data, offset: 0) == magic else { return nil }
        let version = data[4]
        guard version == versionV1 || version == versionV2 else { return nil }
        let headerSize = version == versionV2 ? headerSizeV2 : headerSizeV1
        guard data.count >= headerSize else { return nil }
        guard let codecTag = CodecTag(rawValue: data[5]) else { return nil }

        let width = Int(readUInt32(from: data, offset: 8))
        let height = Int(readUInt32(from: data, offset: 12))
        let timestampMicros = readUInt64(from: data, offset: 16)
        let sequenceNumber: UInt64?
        let payloadLength: Int
        if version == versionV2 {
            sequenceNumber = readUInt64(from: data, offset: 24)
            payloadLength = Int(readUInt32(from: data, offset: 32))
        } else {
            sequenceNumber = nil
            payloadLength = Int(readUInt32(from: data, offset: 24))
        }
        let flags = readUInt16(from: data, offset: 6)
        guard payloadLength >= 0, data.count == headerSize + payloadLength else { return nil }

        return Frame(
            width: width,
            height: height,
            imageData: data.subdata(in: headerSize..<data.count),
            timestamp: TimeInterval(timestampMicros) / 1_000_000.0,
            format: codecTag.format,
            isSyncFrame: (flags & 0x0001) != 0,
            sequenceNumber: sequenceNumber
        )
    }

    static func startsWithChunkMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return readUInt32(from: data, offset: 0) == screenChunkMagic
    }

    static func decodeChunkEnvelopeIfPresent(_ data: Data) -> ChunkEnvelope? {
        guard data.count >= screenChunkHeaderByteCount,
              readUInt32(from: data, offset: 0) == screenChunkMagic,
              data[4] == screenChunkVersion,
              Int(readUInt16(from: data, offset: 6)) == screenChunkHeaderByteCount else {
            return nil
        }

        let flags = data[5]
        let chunkIndex = Int(readUInt32(from: data, offset: 16))
        let chunkCount = Int(readUInt32(from: data, offset: 20))
        let totalBytes = Int(readUInt32(from: data, offset: 24))
        let chunkOffset = Int(readUInt32(from: data, offset: 28))
        let chunkBytes = Int(readUInt32(from: data, offset: 32))
        let payloadStart = screenChunkHeaderByteCount

        guard chunkCount > 0,
              chunkIndex >= 0,
              chunkIndex < chunkCount,
              totalBytes > 0,
              chunkOffset >= 0,
              chunkBytes >= 0,
              data.count == payloadStart + chunkBytes,
              (flags & ~0x03) == 0,
              ((flags & 0x01) != 0) == (chunkIndex == 0),
              ((flags & 0x02) != 0) == (chunkIndex == chunkCount - 1) else {
            return nil
        }

        let payload = data.subdata(in: payloadStart..<data.count)
        guard chunkOffset + payload.count <= totalBytes else { return nil }
        return ChunkEnvelope(
            frameId: readUInt64(from: data, offset: 8),
            chunkIndex: chunkIndex,
            chunkCount: chunkCount,
            totalBytes: totalBytes,
            chunkOffset: chunkOffset,
            payload: payload
        )
    }

    static func encodeChunkEnvelope(
        frameId: UInt64,
        chunkIndex: Int,
        chunkCount: Int,
        totalBytes: Int,
        chunkOffset: Int,
        payload: Data
    ) throws -> Data {
        guard chunkIndex >= 0,
              chunkCount > 0,
              chunkIndex < chunkCount,
              totalBytes > 0,
              chunkOffset >= 0,
              chunkOffset + payload.count <= totalBytes,
              chunkCount <= Int(UInt32.max),
              chunkIndex <= Int(UInt32.max),
              totalBytes <= Int(UInt32.max),
              chunkOffset <= Int(UInt32.max),
              payload.count <= Int(UInt32.max) else {
            throw RemoteControlError.invalidMessageLength(totalBytes)
        }

        var data = Data()
        data.reserveCapacity(screenChunkHeaderByteCount + payload.count)
        appendUInt32(screenChunkMagic, to: &data)
        data.append(screenChunkVersion)
        var flags: UInt8 = 0
        if chunkIndex == 0 { flags |= 0x01 }
        if chunkIndex == chunkCount - 1 { flags |= 0x02 }
        data.append(flags)
        appendUInt16(UInt16(screenChunkHeaderByteCount), to: &data)
        appendUInt64(frameId, to: &data)
        appendUInt32(UInt32(chunkIndex), to: &data)
        appendUInt32(UInt32(chunkCount), to: &data)
        appendUInt32(UInt32(totalBytes), to: &data)
        appendUInt32(UInt32(chunkOffset), to: &data)
        appendUInt32(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    static func containsSyncFrame(
        format: String?,
        imageData: Data,
        advertisedSyncFrame: Bool?
    ) -> Bool {
        switch CodecTag(format: format) {
        case .jpeg, .bgra, .unknown:
            return advertisedSyncFrame ?? true
        case .h264:
            return parseNALUnits(from: imageData).contains { nalu in
                guard let first = nalu.first else { return false }
                return Int(first & 0x1F) == 5
            }
        case .hevc:
            return parseNALUnits(from: imageData).contains { nalu in
                guard let first = nalu.first else { return false }
                let type = Int((first >> 1) & 0x3F)
                return (16...21).contains(type)
            }
        }
    }

    private static func parseNALUnits(from data: Data) -> [Data] {
        if data.count >= 4,
           data.starts(with: [0x00, 0x00, 0x00, 0x01]) || data.starts(with: [0x00, 0x00, 0x01]) {
            return parseAnnexBNALUnits(from: data)
        }
        return parseLengthPrefixedNALUnits(from: data)
    }

    private static func parseLengthPrefixedNALUnits(from data: Data) -> [Data] {
        var nalus: [Data] = []
        var offset = 0
        while offset + 4 <= data.count {
            let length = data.withUnsafeBytes { raw -> Int in
                let value = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                return Int(UInt32(bigEndian: value))
            }
            offset += 4
            guard length > 0, offset + length <= data.count else { break }
            nalus.append(data.subdata(in: offset..<(offset + length)))
            offset += length
        }
        return nalus
    }

    private static func parseAnnexBNALUnits(from data: Data) -> [Data] {
        func startCodeLength(at index: Int) -> Int? {
            guard index + 3 <= data.count else { return nil }
            if index + 4 <= data.count,
               data[index] == 0x00, data[index + 1] == 0x00, data[index + 2] == 0x00, data[index + 3] == 0x01 {
                return 4
            }
            if data[index] == 0x00, data[index + 1] == 0x00, data[index + 2] == 0x01 {
                return 3
            }
            return nil
        }

        var nalus: [Data] = []
        var currentStart: Int?
        var currentSkip = 0
        var index = 0

        while index < data.count {
            if let skip = startCodeLength(at: index) {
                if let start = currentStart {
                    let naluStart = start + currentSkip
                    if naluStart < index {
                        nalus.append(data.subdata(in: naluStart..<index))
                    }
                }
                currentStart = index
                currentSkip = skip
                index += skip
            } else {
                index += 1
            }
        }

        if let start = currentStart {
            let naluStart = start + currentSkip
            if naluStart < data.count {
                nalus.append(data.subdata(in: naluStart..<data.count))
            }
        }
        return nalus
    }

    private static func readUInt16(from data: Data, offset: Int) -> UInt16 {
        data.withUnsafeBytes { rawBuffer in
            UInt16(
                bigEndian: rawBuffer.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt16.self
                )
            )
        }
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { rawBuffer in
            data.append(contentsOf: rawBuffer)
        }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { rawBuffer in
            data.append(contentsOf: rawBuffer)
        }
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { rawBuffer in
            data.append(contentsOf: rawBuffer)
        }
    }

    private static func readUInt32(from data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { rawBuffer in
            UInt32(
                bigEndian: rawBuffer.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt32.self
                )
            )
        }
    }

    private static func readUInt64(from data: Data, offset: Int) -> UInt64 {
        data.withUnsafeBytes { rawBuffer in
            UInt64(
                bigEndian: rawBuffer.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt64.self
                )
            )
        }
    }
}
