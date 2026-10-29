import Foundation
@preconcurrency import AVFoundation

enum RemotePCM16AudioChunkBuilder {
    static func makeChunk(
        from buffer: AVAudioPCMBuffer,
        sequenceNumber: UInt64,
        sentAt: TimeInterval = Date().timeIntervalSince1970
    ) -> RemoteDesktopAudioChunkPayload? {
        guard buffer.format.commonFormat == .pcmFormatInt16 else { return nil }
        let sampleRate = Int(buffer.format.sampleRate.rounded())
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard sampleRate > 0, channelCount > 0, frameCount > 0 else { return nil }
        guard let data = pcm16InterleavedData(from: buffer, channelCount: channelCount, frameCount: frameCount),
              !data.isEmpty else {
            return nil
        }
        return RemoteDesktopAudioChunkPayload(
            encoding: .pcmS16LE,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            sequenceNumber: sequenceNumber,
            sentAt: sentAt,
            data: data
        )
    }

    static func pcm16InterleavedData(
        from buffer: AVAudioPCMBuffer,
        channelCount: Int,
        frameCount: Int
    ) -> Data? {
        let bytesPerSample = MemoryLayout<Int16>.size
        let expectedInterleavedBytes = frameCount * channelCount * bytesPerSample
        guard expectedInterleavedBytes > 0 else { return nil }

        if buffer.format.isInterleaved {
            let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard let first = audioBuffers.first,
                  let baseAddress = first.mData,
                  Int(first.mDataByteSize) >= expectedInterleavedBytes else {
                return nil
            }
            return Data(bytes: baseAddress, count: expectedInterleavedBytes)
        }

        guard let channelData = buffer.int16ChannelData else { return nil }
        var output = Data(count: expectedInterleavedBytes)
        output.withUnsafeMutableBytes { rawOutput in
            guard let destination = rawOutput.bindMemory(to: Int16.self).baseAddress else { return }
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    destination[frame * channelCount + channel] = channelData[channel][frame]
                }
            }
        }
        return output
    }
}
