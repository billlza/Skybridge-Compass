import Foundation

public enum FramedReaderError: Error, Sendable, Equatable {
    case peerClosed
    case invalidLength(UInt32)
}

/// Platform-neutral reader for SkyBridge's canonical 4-byte length-prefixed
/// control frames. Apple transport adapters provide the receive closure; the
/// framing limits and partial-read semantics stay identical on macOS and iOS.
public struct FramedReader: Sendable {
    public typealias ReceiveChunk = @Sendable (
        _ maximumLength: Int
    ) async throws -> (data: Data, isComplete: Bool)

    private let receiveChunk: ReceiveChunk
    private let chunkLimit: Int

    public init(
        chunkLimit: Int = 65_536,
        receiveChunk: @escaping ReceiveChunk
    ) {
        self.chunkLimit = max(1, chunkLimit)
        self.receiveChunk = receiveChunk
    }

    public func receiveExactly(_ length: Int) async throws -> Data {
        guard length >= 0 else {
            throw FramedReaderError.invalidLength(0)
        }
        var buffer = Data()
        buffer.reserveCapacity(length)
        while buffer.count < length {
            try Task.checkCancellation()
            let remaining = length - buffer.count
            let (chunk, isComplete) = try await receiveChunk(
                min(chunkLimit, remaining)
            )
            if !chunk.isEmpty {
                buffer.append(chunk)
                if buffer.count >= length {
                    return buffer
                }
                if isComplete {
                    throw FramedReaderError.peerClosed
                }
                continue
            }
            if isComplete {
                throw FramedReaderError.peerClosed
            }
            throw FramedReaderError.peerClosed
        }
        return buffer
    }

    public func receiveFrame(
        maxFrameLength: UInt32 = UInt32(P2PControlFramePolicy.maximumBodyByteCount)
    ) async throws -> Data {
        let lenData = try await receiveExactly(
            P2PControlFramePolicy.lengthPrefixByteCount
        )
        let totalLen = lenData.withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).bigEndian
        }
        guard let bodyByteCount = try? P2PControlFramePolicy
            .inboundBodyByteCount(from: totalLen),
              totalLen <= maxFrameLength else {
            throw FramedReaderError.invalidLength(totalLen)
        }
        return try await receiveExactly(bodyByteCount)
    }
}
