import Foundation

public enum AudioAlacFileError: Error, Equatable, Sendable {
    case truncated, malformed, unsupportedContainer, unsupportedLayout, unsupportedEncoding
    case metadataLimit, invalidReadLength, oversized
}

/// Validated container declarations and ranges, not decoded audio or output admission.
public struct AudioAlacMetadata: Sendable {
    public let decodedFormat: AudioStreamingPCMFormat
    public let totalFrames: UInt64
    public let packetCount: UInt64
    /// Sum of indexed compressed packet sizes, distinct from the container's entire length.
    public let encodedAudioBytes: UInt64
    public let maximumFramesPerPacket: UInt32
    public let maximumPacketBytes: UInt32?
    public let configuration: Data
    fileprivate let index: AlacIndex

    public func makePacketCursor() -> AudioAlacPacketCursor { AudioAlacPacketCursor(index: index) }
}

public struct AudioAlacPacket: Equatable, Sendable {
    public let index: UInt64
    public let firstFrameIndex: UInt64
    public let frameCount: UInt32
    public let byteOffset: UInt64
    public let byteCount: Int
}

/// Sequential, paged traversal of the inspected packet/time/chunk tables. No compressed packet
/// is read here. The same immutable source must be lent for each call. nil means the declared
/// sequence ended with exact counts; read, cancellation and structural errors remain terminal.
public struct AudioAlacPacketCursor: Sendable {
    private let index: AlacIndex
    private var timing: AlacPage
    private var sizes: AlacPage?
    private var offsets: AlacPage
    private var runs: AlacPage
    private var packet: UInt64 = 0
    private var frames: UInt64 = 0
    private var timingRows: UInt64 = 0
    private var timingRemaining: UInt64 = 0
    private var packetFrames: UInt32 = 0
    private var chunks: UInt64 = 0
    private var chunkRemaining: UInt64 = 0
    private var nextByte: UInt64 = 0
    private var runIndex: UInt64 = 0
    private var currentRun: AlacChunkRun?
    private var nextRun: AlacChunkRun?
    private var failure: (any Error)?

    fileprivate init(index: AlacIndex) {
        self.index = index
        timing = AlacPage(index.timing); sizes = index.sizes.map(AlacPage.init)
        offsets = AlacPage(index.offsets); runs = AlacPage(index.runs)
    }

    public mutating func next(read: (UInt64, Int) throws -> Data,
        requireCurrent: () throws -> Void = { try Task.checkCancellation() }) throws -> AudioAlacPacket? {
        if let failure { throw failure }
        do {
            try Task.checkCancellation()
            try requireCurrent()
            if packet == index.packetCount {
                guard frames == index.frames, timingRemaining == 0, timingRows == index.timing.count,
                      chunkRemaining == 0, chunks == index.offsets.count,
                      runIndex + 1 == index.runs.count, nextRun == nil else { throw AudioAlacFileError.malformed }
                try requireCurrent()
                try Task.checkCancellation()
                return nil
            }
            if timingRemaining == 0 {
                guard timingRows < index.timing.count else { throw AudioAlacFileError.malformed }
                let count = try timing.u32(timingRows, 0, read, requireCurrent)
                let delta = try timing.u32(timingRows, 4, read, requireCurrent)
                guard count > 0, UInt64(count) <= index.packetCount - packet,
                      delta > 0, delta <= index.maximumFrames else { throw AudioAlacFileError.malformed }
                timingRows += 1; timingRemaining = UInt64(count); packetFrames = delta
            }
            if chunkRemaining == 0 {
                guard chunks < index.offsets.count else { throw AudioAlacFileError.malformed }
                let chunk = chunks + 1
                if currentRun == nil {
                    currentRun = try loadRun(0, after: 0, read: read, check: requireCurrent)
                    guard currentRun?.firstChunk == 1 else { throw AudioAlacFileError.malformed }
                    if index.runs.count > 1 { nextRun = try loadRun(1, after: 1, read: read, check: requireCurrent) }
                }
                if let following = nextRun, following.firstChunk == chunk {
                    runIndex += 1; currentRun = following
                    nextRun = runIndex + 1 < index.runs.count
                        ? try loadRun(runIndex + 1, after: following.firstChunk, read: read, check: requireCurrent) : nil
                }
                guard let run = currentRun, run.firstChunk <= chunk,
                      nextRun == nil || nextRun.map({ $0.firstChunk > chunk }) == true,
                      UInt64(run.packetsPerChunk) <= index.packetCount - packet else { throw AudioAlacFileError.malformed }
                nextByte = index.offsets.stride == 8
                    ? try offsets.u64(chunks, read, requireCurrent)
                    : UInt64(try offsets.u32(chunks, 0, read, requireCurrent))
                chunkRemaining = UInt64(run.packetsPerChunk); chunks += 1
            }
            let size: UInt32
            if let fixed = index.fixedBytes { size = fixed }
            else {
                guard var page = sizes else { throw AudioAlacFileError.malformed }
                size = try page.u32(packet, 0, read, requireCurrent)
                sizes = page
            }
            guard size > 0, size <= AudioAlacFile.maximumPacketBytes,
                  index.maximumBytes == nil || index.maximumBytes.map({ size <= $0 }) == true,
                  UInt64(packetFrames) <= index.frames - frames,
                  index.containsMedia(offset: nextByte, count: UInt64(size)) else { throw AudioAlacFileError.malformed }
            let result = AudioAlacPacket(index: packet, firstFrameIndex: frames, frameCount: packetFrames,
                                        byteOffset: nextByte, byteCount: Int(size))
            try requireCurrent()
            try Task.checkCancellation()
            packet += 1; frames += UInt64(packetFrames); timingRemaining -= 1
            chunkRemaining -= 1; nextByte += UInt64(size)
            return result
        } catch { failure = error; throw error }
    }

    private mutating func loadRun(_ row: UInt64, after previous: UInt64,
        read: (UInt64, Int) throws -> Data, check: () throws -> Void) throws -> AlacChunkRun {
        let first = UInt64(try runs.u32(row, 0, read, check))
        let count = try runs.u32(row, 4, read, check)
        let description = try runs.u32(row, 8, read, check)
        guard first > previous, first <= index.offsets.count, count > 0,
              UInt64(count) <= index.packetCount, description == 1 else { throw AudioAlacFileError.malformed }
        return AlacChunkRun(firstChunk: first, packetsPerChunk: count)
    }
}

/// Single-track self-contained ALAC M4A/MP4. Uses ALACSpecificConfig rather than the enclosing
/// AudioSampleEntry's legacy rate/depth placeholders. Matches the Android metadata profile.
/// Synchronous borrowing lets an existing held-reader actor keep the entire operation within
/// its verified-read scope. No source handle or callback is retained in the returned metadata.
public enum AudioAlacFile {
    public static let maximumFileBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
    public static let maximumMetadataBytes: UInt64 = 64 * 1_024 * 1_024
    public static let maximumReadBytes = 65_536
    public static let maximumBoxes = 4_096
    public static let maximumPackets: UInt64 = 4_194_304
    public static let maximumPacketBytes: UInt32 = 2_097_120

    public static func inspect(fileSize: UInt64, read: (UInt64, Int) throws -> Data,
        requireCurrent: () throws -> Void = { try Task.checkCancellation() }) throws -> AudioAlacMetadata {
        try Task.checkCancellation()
        try requireCurrent()
        guard fileSize <= maximumFileBytes else { throw AudioAlacFileError.oversized }
        return try withoutActuallyEscaping(read) { borrowedRead in
            try withoutActuallyEscaping(requireCurrent) { borrowedCheck in
                let source = AlacSource(size: fileSize, read: borrowedRead, check: borrowedCheck)
                let result = try inspect(source)
                try requireCurrent()
                try Task.checkCancellation()
                return result
            }
        }
    }

    private static func inspect(_ source: AlacSource) throws -> AudioAlacMetadata {
        let top = try source.boxes(0, source.size)
        guard !top.contains(where: { $0.type == "moof" }) else { throw AudioAlacFileError.unsupportedLayout }
        let ftyp = try single(top, "ftyp", error: .unsupportedContainer)
        guard ftyp.length >= 8, ftyp.length % 4 == 0 else { throw AudioAlacFileError.malformed }
        let moov = try single(top, "moov")
        guard moov.length <= maximumMetadataBytes else { throw AudioAlacFileError.metadataLimit }
        let movie = try source.children(moov)
        guard !movie.contains(where: { $0.type == "mvex" }) else { throw AudioAlacFileError.unsupportedLayout }
        let track = try source.children(single(movie, "trak", error: .unsupportedLayout))
        guard !track.contains(where: { $0.type == "edts" }) else { throw AudioAlacFileError.unsupportedLayout }
        let flags = try be32(source.prefix(single(track, "tkhd"), 4), 0)
        guard flags >> 24 <= 1, flags & 1 != 0 else { throw AudioAlacFileError.unsupportedLayout }
        let media = try source.children(single(track, "mdia"))
        let handler = try source.prefix(single(media, "hdlr"), 12)
        guard be32(handler, 0) == 0, fourCC(handler, 8) == "soun" else { throw AudioAlacFileError.unsupportedLayout }
        let time = try single(media, "mdhd")
        let version = try be32(source.prefix(time, 4), 0)
        guard version == 0 || version == 0x0100_0000 else { throw AudioAlacFileError.unsupportedLayout }
        let timeBytes = try source.prefix(time, version == 0 ? 24 : 36)
        let timescale = be32(timeBytes, version == 0 ? 12 : 20)
        let duration = version == 0 ? UInt64(be32(timeBytes, 16)) : try be64(timeBytes, 24)
        let info = try source.children(single(media, "minf"))
        let references = try source.children(single(info, "dinf"))
        let dref = try single(references, "dref"), drefHeader = try source.prefix(dref, 8)
        guard be32(drefHeader, 0) == 0, be32(drefHeader, 4) == 1 else { throw AudioAlacFileError.unsupportedLayout }
        let urls = try source.boxes(dref.start + 8, dref.end)
        let url = try single(urls, "url ", error: .unsupportedLayout)
        guard urls.count == 1, url.length == 4, try be32(source.prefix(url, 4), 0) == 1 else {
            throw AudioAlacFileError.unsupportedLayout
        }
        let table = try source.children(single(info, "stbl"))
        let unsupported: Set<String> = ["ctts", "cslg", "stz2", "senc", "saiz", "saio", "sbgp", "sgpd"]
        guard !table.contains(where: { unsupported.contains($0.type) }) else { throw AudioAlacFileError.unsupportedLayout }
        let stsd = try single(table, "stsd"), description = try source.prefix(stsd, 8)
        guard be32(description, 0) == 0, be32(description, 4) == 1 else { throw AudioAlacFileError.unsupportedLayout }
        let entries = try source.boxes(stsd.start + 8, stsd.end)
        let entry = try single(entries, "alac", error: .unsupportedEncoding)
        guard entries.count == 1 else { throw AudioAlacFileError.unsupportedLayout }
        let audio = try source.prefix(entry, 28)
        guard audio.prefix(6).allSatisfy({ $0 == 0 }), be16(audio, 6) == 1, be16(audio, 8) == 0 else {
            throw AudioAlacFileError.unsupportedLayout
        }
        let extensions = try source.boxes(entry.start + 28, entry.end)
        guard !extensions.contains(where: { $0.type == "sinf" }) else { throw AudioAlacFileError.unsupportedEncoding }
        let config = try single(extensions, "alac")
        guard config.length == 28 || config.length == 52 else { throw AudioAlacFileError.unsupportedEncoding }
        let cookie = try source.prefix(config, Int(config.length))
        guard be32(cookie, 0) == 0, cookie[8] == 0 else { throw AudioAlacFileError.unsupportedEncoding }
        let maximumFrames = be32(cookie, 4), bits = cookie[9], channels = cookie[13]
        let maximumBytes = be32(cookie, 16), rate = be32(cookie, 24)
        guard (1...65_536).contains(maximumFrames), maximumBytes <= maximumPacketBytes else { throw AudioAlacFileError.metadataLimit }
        guard [16, 20, 24, 32].contains(bits) else { throw AudioAlacFileError.unsupportedEncoding }
        guard (1...2).contains(channels) else { throw AudioAlacFileError.unsupportedLayout }
        guard rate > 0, timescale == rate, duration > 0 else { throw AudioAlacFileError.malformed }
        guard duration <= UInt64(rate) * 14_400 else { throw AudioAlacFileError.metadataLimit }
        let channelBoxes = extensions.filter { $0.type == "chan" }
        guard channelBoxes.count <= 1, config.length != 52 || channelBoxes.isEmpty else { throw AudioAlacFileError.unsupportedLayout }
        if config.length == 52 {
            guard be32(cookie, 28) == 24, fourCC(cookie, 32) == "chan" else { throw AudioAlacFileError.malformed }
            try layout(Array(cookie[36..<52]), channels: channels)
        }
        if let channel = channelBoxes.first {
            guard channel.length == 16 else { throw AudioAlacFileError.unsupportedLayout }
            try layout(source.prefix(channel, 16), channels: channels)
        }
        let timing = try source.table(single(table, "stts"), stride: 8)
        let stsz = try single(table, "stsz"), sizeHead = try source.prefix(stsz, 12)
        let fixed = be32(sizeHead, 4), packets = UInt64(be32(sizeHead, 8))
        guard be32(sizeHead, 0) == 0, (1...maximumPackets).contains(packets), fixed <= maximumPacketBytes,
              stsz.length == 12 + (fixed == 0 ? packets * 4 : 0) else { throw AudioAlacFileError.malformed }
        let sizes = fixed == 0 ? AlacTable(start: stsz.start + 12, count: packets, stride: 4) : nil
        let offsetBoxes = table.filter { $0.type == "stco" || $0.type == "co64" }
        guard offsetBoxes.count == 1, let offsetBox = offsetBoxes.first else { throw AudioAlacFileError.unsupportedLayout }
        let offsets = try source.table(offsetBox, stride: offsetBox.type == "co64" ? 8 : 4)
        let runs = try source.table(single(table, "stsc"), stride: 12)
        guard offsets.count <= packets, runs.count <= offsets.count else { throw AudioAlacFileError.malformed }
        let mediaData = top.filter { $0.type == "mdat" && $0.length > 0 }
        guard !mediaData.isEmpty else { throw AudioAlacFileError.malformed }
        let format: AudioStreamingPCMFormat
        do {
            format = try .init(sampleRate: rate, channels: UInt16(channels),
                encoding: bits == 16 ? .signed16 : (bits == 32 ? .signed32 : .signed24),
                declaredValidBits: bits, waveChannelMask: channels == 1 ? 4 : 3)
        } catch AudioStreamingWireError.invalidFormat { throw AudioAlacFileError.malformed }
        let index = AlacIndex(frames: duration, packetCount: packets, maximumFrames: maximumFrames,
            maximumBytes: maximumBytes == 0 ? nil : maximumBytes, fixedBytes: fixed == 0 ? nil : fixed,
            timing: timing, sizes: sizes, offsets: offsets, runs: runs, media: mediaData)
        var cursor = AudioAlacPacketCursor(index: index)
        var encodedBytes: UInt64 = 0
        while let packet = try cursor.next(read: source.bytes, requireCurrent: source.check) {
            encodedBytes += UInt64(packet.byteCount) // Packet count and size limits bound this sum.
        }
        return AudioAlacMetadata(decodedFormat: format, totalFrames: duration, packetCount: packets,
            encodedAudioBytes: encodedBytes,
            maximumFramesPerPacket: maximumFrames, maximumPacketBytes: index.maximumBytes,
            configuration: Data(cookie[4..<28]), index: index)
    }

    private static func single(_ boxes: [AlacBox], _ type: String,
        error: AudioAlacFileError = .malformed) throws -> AlacBox {
        let result = boxes.filter { $0.type == type }
        guard result.count == 1, let box = result.first else { throw error }
        return box
    }

    private static func layout(_ bytes: [UInt8], channels: UInt8) throws {
        guard be32(bytes, 0) == 0, be32(bytes, 4) == ((99 + UInt32(channels)) << 16) + UInt32(channels),
              be32(bytes, 8) == 0, be32(bytes, 12) == 0 else { throw AudioAlacFileError.unsupportedLayout }
    }
}

fileprivate struct AlacBox: Sendable {
    let type: String
    let start: UInt64
    let end: UInt64
    var length: UInt64 { end - start }
}

fileprivate struct AlacTable: Sendable { let start: UInt64; let count: UInt64; let stride: Int }
fileprivate struct AlacChunkRun: Sendable { let firstChunk: UInt64; let packetsPerChunk: UInt32 }
fileprivate struct AlacIndex: Sendable {
    let frames, packetCount: UInt64
    let maximumFrames: UInt32
    let maximumBytes, fixedBytes: UInt32?
    let timing: AlacTable
    let sizes: AlacTable?
    let offsets, runs: AlacTable
    let media: [AlacBox]

    func containsMedia(offset: UInt64, count: UInt64) -> Bool {
        var lower = 0, upper = media.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if media[middle].start <= offset { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return false }
        let range = media[lower - 1]
        return offset <= range.end && count <= range.end - offset
    }
}

private final class AlacSource {
    let size: UInt64
    let read: (UInt64, Int) throws -> Data
    let check: () throws -> Void
    private var boxesRead = 0
    private var metadataRead: UInt64 = 0

    init(size: UInt64, read: @escaping (UInt64, Int) throws -> Data, check: @escaping () throws -> Void) {
        self.size = size; self.read = read; self.check = check
    }
    func bytes(_ offset: UInt64, _ count: Int) throws -> Data {
        try Task.checkCancellation()
        try check()
        guard (1...AudioAlacFile.maximumReadBytes).contains(count), offset <= size, UInt64(count) <= size - offset else {
            throw AudioAlacFileError.truncated
        }
        guard UInt64(count) <= AudioAlacFile.maximumMetadataBytes - metadataRead else { throw AudioAlacFileError.metadataLimit }
        metadataRead += UInt64(count)
        let value = try read(offset, count)
        try check()
        try Task.checkCancellation()
        guard value.count >= count else { throw AudioAlacFileError.truncated }
        guard value.count == count else { throw AudioAlacFileError.invalidReadLength }
        return value
    }
    func prefix(_ box: AlacBox, _ count: Int) throws -> [UInt8] {
        guard UInt64(count) <= box.length else { throw AudioAlacFileError.truncated }
        return Array(try bytes(box.start, count))
    }
    func children(_ box: AlacBox) throws -> [AlacBox] { try boxes(box.start, box.end) }
    func boxes(_ start: UInt64, _ end: UInt64) throws -> [AlacBox] {
        var result: [AlacBox] = [], offset = start
        while offset < end {
            boxesRead += 1
            guard boxesRead <= AudioAlacFile.maximumBoxes else { throw AudioAlacFileError.metadataLimit }
            guard end - offset >= 8 else { throw AudioAlacFileError.truncated }
            let header = Array(try bytes(offset, 8))
            var length = UInt64(be32(header, 0)), headerLength: UInt64 = 8
            if length == 1 {
                guard end - offset >= 16 else { throw AudioAlacFileError.truncated }
                length = try be64(Array(bytes(offset + 8, 8)), 0); headerLength = 16
            } else if length == 0 { length = end - offset }
            guard length >= headerLength else { throw AudioAlacFileError.malformed }
            guard length <= end - offset else { throw AudioAlacFileError.truncated }
            result.append(AlacBox(type: fourCC(header, 4), start: offset + headerLength, end: offset + length))
            offset += length
        }
        return result
    }
    func table(_ box: AlacBox, stride: Int) throws -> AlacTable {
        let header = try prefix(box, 8), count = UInt64(be32(header, 4))
        guard be32(header, 0) == 0, (1...AudioAlacFile.maximumPackets).contains(count),
              box.length == 8 + count * UInt64(stride) else { throw AudioAlacFileError.malformed }
        return AlacTable(start: box.start + 8, count: count, stride: stride)
    }
}

fileprivate struct AlacPage: Sendable {
    let table: AlacTable
    private var first: UInt64?
    private var cached: [UInt8] = []
    init(_ table: AlacTable) { self.table = table }

    private mutating func field(_ index: UInt64, _ offset: Int, width: Int,
        read: (UInt64, Int) throws -> Data, check: () throws -> Void) throws -> Int {
        try check()
        guard index < table.count, offset >= 0, width > 0, offset <= table.stride - width else {
            throw AudioAlacFileError.malformed
        }
        let perPage = UInt64(AudioAlacFile.maximumReadBytes / table.stride)
        let block = index / perPage * perPage
        if first != block {
            let count = Int(min(perPage, table.count - block)) * table.stride
            let data = try read(table.start + block * UInt64(table.stride), count)
            try check()
            guard data.count >= count else { throw AudioAlacFileError.truncated }
            guard data.count == count else { throw AudioAlacFileError.invalidReadLength }
            cached = Array(data); first = block
        }
        return Int(index - block) * table.stride + offset
    }
    mutating func u32(_ index: UInt64, _ offset: Int, _ read: (UInt64, Int) throws -> Data,
                     _ check: () throws -> Void) throws -> UInt32 {
        let at = try field(index, offset, width: 4, read: read, check: check)
        return be32(cached, at)
    }
    mutating func u64(_ index: UInt64, _ read: (UInt64, Int) throws -> Data,
                     _ check: () throws -> Void) throws -> UInt64 {
        let at = try field(index, 0, width: 8, read: read, check: check)
        return try be64(cached, at)
    }
}

private func be16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1]) }
private func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 { UInt32(be16(bytes, at)) << 16 | UInt32(be16(bytes, at + 2)) }
private func be64(_ bytes: [UInt8], _ at: Int) throws -> UInt64 {
    let high = be32(bytes, at)
    guard high <= Int32.max else { throw AudioAlacFileError.oversized }
    return UInt64(high) << 32 | UInt64(be32(bytes, at + 4))
}
private func fourCC(_ bytes: [UInt8], _ at: Int) -> String { String(decoding: bytes[at..<(at + 4)], as: UTF8.self) }
