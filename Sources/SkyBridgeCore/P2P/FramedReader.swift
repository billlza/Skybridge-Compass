import Foundation
import Network

public enum FramedReaderError: Error, Sendable, Equatable {
    case peerClosed
    case invalidLength(UInt32)
}

public struct FramedReader: Sendable {
    public typealias ReceiveChunk = @Sendable (_ maximumLength: Int) async throws -> (data: Data, isComplete: Bool)

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
            let remaining = length - buffer.count
            let (chunk, isComplete) = try await receiveChunk(min(chunkLimit, remaining))
            if !chunk.isEmpty {
                buffer.append(chunk)
                continue
            }
            if isComplete {
                throw FramedReaderError.peerClosed
            }
            throw FramedReaderError.peerClosed
        }
        return buffer
    }

    public func receiveFrame(maxFrameLength: UInt32 = 1_048_576) async throws -> Data {
        let lenData = try await receiveExactly(4)
        let totalLen = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard totalLen > 0, totalLen < maxFrameLength else {
            throw FramedReaderError.invalidLength(totalLen)
        }
        return try await receiveExactly(Int(totalLen))
    }

    public static func nwConnection(_ connection: NWConnection) -> FramedReader {
        FramedReader { maximumLength in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(data: Data, isComplete: Bool), Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: (data ?? Data(), isComplete))
                }
            }
        }
    }
}
