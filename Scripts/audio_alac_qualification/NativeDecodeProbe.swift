import AudioToolbox
import Foundation

enum ProbeError: Error { case native(String, OSStatus), invalid(String) }
func requireOK(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw ProbeError.native(operation, status) }
}

// Isolated, immutable synthetic input. The product adapter must instead borrow the existing
// commitment-verified reader and recheck authorization/source identity around every native step.
final class Input {
    let bytes: Data
    var reads = 0
    init(_ bytes: Data) { self.bytes = bytes }
}

final class PacketInput {
    let bytes: UnsafeRawPointer
    let description: UnsafeMutablePointer<AudioStreamPacketDescription>
    let channels: UInt32
    var supplied = false
    init(bytes: UnsafeRawPointer, description: UnsafeMutablePointer<AudioStreamPacketDescription>, channels: UInt32) {
        self.bytes = bytes; self.description = description; self.channels = channels
    }
}

func packetDecode(file: AudioFileID, source: AudioStreamBasicDescription,
                  target: AudioStreamBasicDescription, frames: Int64) throws -> (Data, [UInt32]) {
    var packetCount: UInt64 = 0
    var size = UInt32(MemoryLayout<UInt64>.size)
    try requireOK(AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &size, &packetCount), "packet count")
    var capacity: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    try requireOK(AudioFileGetProperty(file, kAudioFilePropertyPacketSizeUpperBound, &size, &capacity), "packet capacity")
    guard packetCount > 0, packetCount < 4096, capacity > 0, capacity <= 2_097_120,
          source.mFramesPerPacket > 0, source.mFramesPerPacket <= 65536 else { throw ProbeError.invalid("packet bounds") }
    // This isolated fixture generator emits full 4096-frame packets and one optional tail.
    // AudioFileReadPacketData reports variableFrames=0 even for its shorter last packet.
    // Expected lengths therefore come from the known fixture, never the decoder's output.
    // A product adapter must use validated stts durations instead of this fixture-only rule.
    guard packetCount == UInt64((frames + Int64(source.mFramesPerPacket) - 1) / Int64(source.mFramesPerPacket)) else {
        throw ProbeError.invalid("fixture packet count differs")
    }
    var cookieSize: UInt32 = 0
    try requireOK(AudioFileGetPropertyInfo(file, kAudioFilePropertyMagicCookieData, &cookieSize, nil), "cookie size")
    guard cookieSize > 0, cookieSize <= 512 else { throw ProbeError.invalid("cookie bounds") }
    var cookie = Data(count: Int(cookieSize))
    try cookie.withUnsafeMutableBytes { raw in
        guard let address = raw.baseAddress else { throw ProbeError.invalid("cookie storage") }
        try requireOK(AudioFileGetProperty(file, kAudioFilePropertyMagicCookieData, &cookieSize, address), "cookie")
    }
    var inputFormat = source
    var outputFormat = target
    var converter: AudioConverterRef?
    try requireOK(AudioConverterNew(&inputFormat, &outputFormat, &converter), "new packet decoder")
    guard let converter else { throw ProbeError.invalid("missing packet decoder") }
    let inputCallback: AudioConverterComplexInputDataProc = { _, count, buffers, description, opaque in
        guard let opaque else { count.pointee = 0; return kAudio_ParamError }
        let input = Unmanaged<PacketInput>.fromOpaque(opaque).takeUnretainedValue()
        if input.supplied {
            count.pointee = 0
            buffers.pointee.mBuffers.mDataByteSize = 0
            buffers.pointee.mBuffers.mData = nil
            return noErr
        }
        guard count.pointee > 0, let description else { count.pointee = 0; return kAudio_ParamError }
        count.pointee = 1
        buffers.pointee.mNumberBuffers = 1
        buffers.pointee.mBuffers = AudioBuffer(mNumberChannels: input.channels,
            mDataByteSize: input.description.pointee.mDataByteSize, mData: UnsafeMutableRawPointer(mutating: input.bytes))
        description.pointee = input.description
        input.supplied = true
        return noErr
    }
    let result: Result<(Data, [UInt32]), any Error>
    do {
        try cookie.withUnsafeBytes { raw in
            guard let address = raw.baseAddress else { throw ProbeError.invalid("cookie storage") }
            try requireOK(AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie,
                                                    cookieSize, address), "configure packet decoder")
        }
        var pcm = Data()
        var counts: [UInt32] = []
        for index in 0..<packetCount {
            var compressed = Data(count: Int(capacity))
            var description = AudioStreamPacketDescription()
            var bytes = capacity
            var packets: UInt32 = 1
            try compressed.withUnsafeMutableBytes { raw in
                guard let address = raw.baseAddress else { throw ProbeError.invalid("packet storage") }
                try requireOK(AudioFileReadPacketData(file, false, &bytes, &description, Int64(index), &packets, address), "read packet")
            }
            guard packets == 1, bytes > 0, bytes <= capacity, description.mStartOffset == 0,
                  description.mDataByteSize == bytes else { throw ProbeError.invalid("packet description") }
            let expected = UInt32(min(Int64(source.mFramesPerPacket), frames - Int64(index) * Int64(source.mFramesPerPacket)))
            guard expected > 0, description.mVariableFramesInPacket == 0 || description.mVariableFramesInPacket == expected else {
                throw ProbeError.invalid("packet frames")
            }
            var produced = expected + 1 // Forces the converter to ask for EOF, not a next packet.
            var output = Data(count: Int(produced * target.mBytesPerFrame))
            try compressed.withUnsafeBytes { inputBytes in
                guard let address = inputBytes.baseAddress else { throw ProbeError.invalid("packet storage") }
                try withUnsafeMutablePointer(to: &description) { packet in
                    let input = PacketInput(bytes: address, description: packet, channels: source.mChannelsPerFrame)
                    let status = output.withUnsafeMutableBytes { raw in
                        var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                            mNumberChannels: target.mChannelsPerFrame, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                        return AudioConverterFillComplexBuffer(converter, inputCallback, Unmanaged.passUnretained(input).toOpaque(),
                                                               &produced, &buffers, nil)
                    }
                    // Release any borrowed packet storage before its pointer scopes end.
                    let reset = AudioConverterReset(converter)
                    withExtendedLifetime(input) {}
                    try requireOK(reset, "reset packet decoder")
                    try requireOK(status, "decode packet")
                }
            }
            guard produced == expected else {
                throw ProbeError.invalid("packet \(index): decoded=\(produced), expected=\(expected), variable=\(description.mVariableFramesInPacket), nominal=\(source.mFramesPerPacket)")
            }
            counts.append(produced)
            pcm.append(output.prefix(Int(produced * target.mBytesPerFrame)))
        }
        guard counts.reduce(Int64(0), { $0 + Int64($1) }) == frames else { throw ProbeError.invalid("decoded stream length differs") }
        result = .success((pcm, counts))
    } catch { result = .failure(error) }
    try requireOK(AudioConverterDispose(converter), "dispose packet decoder")
    return try result.get()
}

func decode(_ inputURL: URL, output: URL, rate: UInt32, channels: UInt32, bits: UInt32, frames: Int64, packetMode: Bool) throws -> [String: Any] {
    let readCallback: AudioFile_ReadProc = { context, position, count, buffer, actual in
        let input = Unmanaged<Input>.fromOpaque(context).takeUnretainedValue()
        actual.pointee = 0
        guard position >= 0, position <= input.bytes.count else { return kAudioFilePositionError }
        let length = min(Int(count), input.bytes.count - Int(position))
        if length > 0 {
            input.bytes.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self),
                                  from: Int(position)..<(Int(position) + length))
        }
        actual.pointee = UInt32(length)
        input.reads += 1
        return noErr
    }
    let sizeCallback: AudioFile_GetSizeProc = { context in
        return Int64(Unmanaged<Input>.fromOpaque(context).takeUnretainedValue().bytes.count)
    }

    let input = Input(try Data(contentsOf: inputURL))
    defer { withExtendedLifetime(input) {} }
    var file: AudioFileID?
    try requireOK(AudioFileOpenWithCallbacks(Unmanaged.passUnretained(input).toOpaque(), readCallback,
                                            nil, sizeCallback, nil, kAudioFileM4AType, &file), "open")
    guard let file else { throw ProbeError.invalid("missing native file") }
    var closeStatus: OSStatus = noErr
    var disposeStatus: OSStatus = noErr
    var bodyResult: Result<[String: Any], any Error>
    do {
        var source = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try requireOK(AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &source), "source format")
        guard size == MemoryLayout<AudioStreamBasicDescription>.size,
              source.mFormatID == kAudioFormatAppleLossless, source.mSampleRate == Double(rate),
              source.mChannelsPerFrame == channels, source.mFormatFlags == [16:1, 20:2, 24:3, 32:4][bits] else {
            throw ProbeError.invalid("source declaration differs")
        }
        var extended: ExtAudioFileRef?
        try requireOK(ExtAudioFileWrapAudioFileID(file, false, &extended), "wrap")
        guard let extended else { throw ProbeError.invalid("missing decoder") }
        do {
            let containerBytes = (bits + 7) / 8
            let flags = kAudioFormatFlagIsSignedInteger |
                (bits == containerBytes * 8 ? kAudioFormatFlagIsPacked : kAudioFormatFlagIsAlignedHigh)
            var target = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: flags, mBytesPerPacket: channels * containerBytes, mFramesPerPacket: 1,
                mBytesPerFrame: channels * containerBytes, mChannelsPerFrame: channels,
                mBitsPerChannel: bits, mReserved: 0)
            try requireOK(ExtAudioFileSetProperty(extended, kExtAudioFileProperty_ClientDataFormat,
                                                 UInt32(MemoryLayout.size(ofValue: target)), &target), "set exact PCM")
            var actual = AudioStreamBasicDescription()
            size = UInt32(MemoryLayout.size(ofValue: actual))
            try requireOK(ExtAudioFileGetProperty(extended, kExtAudioFileProperty_ClientDataFormat, &size, &actual), "get exact PCM")
            guard actual.mSampleRate == target.mSampleRate, actual.mFormatID == target.mFormatID,
                  actual.mFormatFlags == target.mFormatFlags, actual.mBytesPerPacket == target.mBytesPerPacket,
                  actual.mFramesPerPacket == target.mFramesPerPacket, actual.mBytesPerFrame == target.mBytesPerFrame,
                  actual.mChannelsPerFrame == target.mChannelsPerFrame, actual.mBitsPerChannel == target.mBitsPerChannel else {
                throw ProbeError.invalid("client format changed")
            }
            var declaredFrames: Int64 = 0
            size = UInt32(MemoryLayout<Int64>.size)
            try requireOK(ExtAudioFileGetProperty(extended, kExtAudioFileProperty_FileLengthFrames, &size, &declaredFrames), "length")
            guard declaredFrames == frames else { throw ProbeError.invalid("frame declaration differs") }
            var result = Data()
            var decoded: Int64 = 0
            var packetFrames: [UInt32] = []
            if packetMode {
                (result, packetFrames) = try packetDecode(file: file, source: source, target: target, frames: frames)
                decoded = packetFrames.reduce(0) { $0 + Int64($1) }
            } else { while true {
                var count: UInt32 = 1021 // Intentionally cross native packet boundaries.
                var block = Data(count: Int(count * target.mBytesPerFrame))
                let status = block.withUnsafeMutableBytes { raw -> OSStatus in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: channels, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                    return ExtAudioFileRead(extended, &count, &list)
                }
                try requireOK(status, "decode")
                guard count <= 1021 else { throw ProbeError.invalid("excess output") }
                if count == 0 { break }
                decoded += Int64(count)
                guard decoded <= frames else { throw ProbeError.invalid("excess frames") }
                result.append(block.prefix(Int(count * target.mBytesPerFrame)))
            } }
            guard decoded == frames else { throw ProbeError.invalid("early EOF") }
            try result.write(to: output, options: .withoutOverwriting)
            bodyResult = .success(["frames": decoded, "sourceFlags": source.mFormatFlags,
                "validBits": actual.mBitsPerChannel, "bytesPerFrame": actual.mBytesPerFrame,
                "rate": actual.mSampleRate, "channels": actual.mChannelsPerFrame, "reads": input.reads,
                "packetMode": packetMode, "packetFrames": packetFrames])
        } catch { bodyResult = .failure(error) }
        disposeStatus = ExtAudioFileDispose(extended)
    } catch { bodyResult = .failure(error) }
    closeStatus = AudioFileClose(file)
    try requireOK(disposeStatus, "dispose")
    try requireOK(closeStatus, "close")
    return try bodyResult.get()
}

do {
    let args = CommandLine.arguments
    guard args.count == 7 || (args.count == 8 && args[7] == "packet"), let rate = UInt32(args[3]), let channels = UInt32(args[4]),
          let bits = UInt32(args[5]), let frames = Int64(args[6]), frames > 0 else { throw ProbeError.invalid("arguments") }
    let result = try decode(URL(fileURLWithPath: args[1]), output: URL(fileURLWithPath: args[2]),
                            rate: rate, channels: channels, bits: bits, frames: frames, packetMode: args.count == 8)
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
