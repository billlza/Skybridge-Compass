import Foundation

enum RemoteDesktopScreenFrameWire {
    private static let magic: UInt32 = 0x53425246 // "SBRF"
    private static let version: UInt8 = 1
    private static let headerSize = 28

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
    }

    static func encode(
        width: Int,
        height: Int,
        imageData: Data,
        timestamp: TimeInterval,
        format: String?,
        isSyncFrame: Bool? = nil
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

        var data = Data()
        data.reserveCapacity(headerSize + imageData.count)
        appendUInt32(magic, to: &data)
        data.append(version)
        data.append(codecTag.rawValue)
        appendUInt16(flags, to: &data)
        appendUInt32(width, to: &data)
        appendUInt32(height, to: &data)
        appendUInt64(timestampMicros, to: &data)
        appendUInt32(payloadLength, to: &data)
        data.append(imageData)
        return data
    }

    static func decodeIfPresent(_ data: Data) -> Frame? {
        guard data.count >= headerSize else { return nil }
        guard readUInt32(from: data, offset: 0) == magic else { return nil }
        guard data[4] == version else { return nil }
        guard let codecTag = CodecTag(rawValue: data[5]) else { return nil }

        let width = Int(readUInt32(from: data, offset: 8))
        let height = Int(readUInt32(from: data, offset: 12))
        let timestampMicros = readUInt64(from: data, offset: 16)
        let payloadLength = Int(readUInt32(from: data, offset: 24))
        let flags = readUInt16(from: data, offset: 6)
        guard payloadLength >= 0, data.count == headerSize + payloadLength else { return nil }

        return Frame(
            width: width,
            height: height,
            imageData: data.subdata(in: headerSize..<data.count),
            timestamp: TimeInterval(timestampMicros) / 1_000_000.0,
            format: codecTag.format,
            isSyncFrame: (flags & 0x0001) != 0
        )
    }

    static func containsSyncFrame(
        format: String?,
        imageData: Data,
        advertisedSyncFrame: Bool?
    ) -> Bool {
        if advertisedSyncFrame == true {
            return true
        }

        switch CodecTag(format: format) {
        case .jpeg, .bgra, .unknown:
            return true
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
