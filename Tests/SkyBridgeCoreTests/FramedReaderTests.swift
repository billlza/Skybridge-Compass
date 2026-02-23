import XCTest
@testable import SkyBridgeCore

final class FramedReaderTests: XCTestCase {
    actor ChunkSource {
        private var chunks: [Data]
        private let closesWhenEmpty: Bool

        init(chunks: [Data], closesWhenEmpty: Bool = true) {
            self.chunks = chunks
            self.closesWhenEmpty = closesWhenEmpty
        }

        func next(maximumLength: Int) -> (data: Data, isComplete: Bool) {
            guard !chunks.isEmpty else {
                return (Data(), closesWhenEmpty)
            }
            let head = chunks.removeFirst()
            if head.count > maximumLength {
                let prefix = head.prefix(maximumLength)
                let tail = head.dropFirst(maximumLength)
                chunks.insert(Data(tail), at: 0)
                return (Data(prefix), false)
            }
            return (head, false)
        }
    }

    private func chunked(_ data: Data, seed: UInt64) -> [Data] {
        var state = seed
        var chunks: [Data] = []
        var cursor = 0
        while cursor < data.count {
            state = 2862933555777941757 &* state &+ 3037000493
            let length = Int((state % 23) + 1)
            let end = min(data.count, cursor + length)
            chunks.append(Data(data[cursor..<end]))
            cursor = end
        }
        return chunks
    }

    func testReceiveFrameHandlesShortReadsOverManyFragmentations() async throws {
        let payload = Data((0..<3072).map { UInt8($0 % 251) })
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(payload)

        for seed in 1...1000 {
            let source = ChunkSource(chunks: chunked(frame, seed: UInt64(seed)))
            let reader = FramedReader { maxLen in
                await source.next(maximumLength: maxLen)
            }
            let decoded = try await reader.receiveFrame()
            XCTAssertEqual(decoded, payload, "fragmentation seed \(seed) should round-trip")
        }
    }

    func testReceiveExactlyFailsClosedWhenPeerEndsEarly() async {
        let source = ChunkSource(chunks: [Data([0xAA, 0xBB])], closesWhenEmpty: true)
        let reader = FramedReader { maxLen in
            await source.next(maximumLength: maxLen)
        }

        do {
            _ = try await reader.receiveExactly(4)
            XCTFail("expected peerClosed")
        } catch let error as FramedReaderError {
            XCTAssertEqual(error, .peerClosed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
