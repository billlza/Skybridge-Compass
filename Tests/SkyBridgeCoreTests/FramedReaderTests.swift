import XCTest
@testable import SkyBridgeCore
import SkyBridgeProtocolCore

final class FramedReaderTests: XCTestCase {
    private final class CancellationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func markCancelled() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    actor ChunkSource {
        private var chunks: [Data]
        private let closesWhenEmpty: Bool
        private var requestCount = 0

        init(chunks: [Data], closesWhenEmpty: Bool = true) {
            self.chunks = chunks
            self.closesWhenEmpty = closesWhenEmpty
        }

        func next(maximumLength: Int) -> (data: Data, isComplete: Bool) {
            requestCount += 1
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

        func requestsMade() -> Int {
            requestCount
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

    func testReceiveFrameHandles8192ByteFrameWithStickyNextFrameAndShortReads() async throws {
        let firstPayload = Data((0..<8192).map { UInt8($0 % 251) })
        let secondPayload = Data([0x53, 0x4B, 0x59])

        func encodedFrame(_ payload: Data) -> Data {
            var frame = Data()
            var length = UInt32(payload.count).bigEndian
            frame.append(Data(bytes: &length, count: 4))
            frame.append(payload)
            return frame
        }

        var stickyFrames = Data()
        stickyFrames.append(encodedFrame(firstPayload))
        stickyFrames.append(encodedFrame(secondPayload))

        let source = ChunkSource(chunks: [stickyFrames])
        let reader = FramedReader(chunkLimit: 137) { maxLen in
            await source.next(maximumLength: maxLen)
        }

        let decodedFirst = try await reader.receiveFrame()
        let decodedSecond = try await reader.receiveFrame()

        XCTAssertEqual(decodedFirst, firstPayload)
        XCTAssertEqual(decodedSecond, secondPayload)
    }

    func testReceiveFrameHandlesHandshakeBoundarySizes() async throws {
        for size in [8191, 8192, 8193] {
            let payload = Data((0..<size).map { UInt8($0 % 251) })
            var frame = Data()
            var length = UInt32(payload.count).bigEndian
            frame.append(Data(bytes: &length, count: 4))
            frame.append(payload)

            let source = ChunkSource(chunks: chunked(frame, seed: UInt64(size)))
            let reader = FramedReader(chunkLimit: 127) { maxLen in
                await source.next(maximumLength: maxLen)
            }

            let decoded = try await reader.receiveFrame(maxFrameLength: 16_384)
            XCTAssertEqual(decoded, payload, "handshake boundary size \(size) should round-trip")
        }
    }

    func testReceiveFrameAcceptsExactMaximumLength() async throws {
        let payload = Data((0..<8192).map { UInt8($0 % 251) })
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(payload)

        let source = ChunkSource(chunks: chunked(frame, seed: 8192))
        let reader = FramedReader(chunkLimit: 127) { maxLen in
            await source.next(maximumLength: maxLen)
        }

        let decoded = try await reader.receiveFrame(maxFrameLength: 8192)
        XCTAssertEqual(decoded, payload)
    }

    func testReceiveFrameRejectsSharedMaximumPlusOneBeforeReadingBody() async {
        var encodedLength = UInt32(
            P2PControlFramePolicy.maximumBodyByteCount + 1
        ).bigEndian
        let header = Data(bytes: &encodedLength, count: 4)
        let source = ChunkSource(chunks: [header])
        let reader = FramedReader { maximumLength in
            await source.next(maximumLength: maximumLength)
        }

        do {
            _ = try await reader.receiveFrame()
            XCTFail("expected invalidLength")
        } catch let error as FramedReaderError {
            XCTAssertEqual(
                error,
                .invalidLength(UInt32(P2PControlFramePolicy.maximumBodyByteCount + 1))
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let requestCount = await source.requestsMade()
        XCTAssertEqual(requestCount, 1)
    }

    func testReceiveFrameHandlesSplitLengthPrefixes() async throws {
        let payload = Data((0..<512).map { UInt8($0 % 251) })
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(payload)

        for prefixSplit in [1, 2, 3] {
            let source = ChunkSource(chunks: [
                Data(frame.prefix(prefixSplit)),
                Data(frame.dropFirst(prefixSplit).prefix(4 - prefixSplit)),
                Data(frame.dropFirst(4))
            ])
            let reader = FramedReader(chunkLimit: 64) { maxLen in
                await source.next(maximumLength: maxLen)
            }

            let decoded = try await reader.receiveFrame()
            XCTAssertEqual(decoded, payload, "length prefix split \(prefixSplit)+\(4 - prefixSplit) should round-trip")
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

    func testReceiveExactlyRejectsPartialDataDeliveredWithTerminalFIN() async {
        let reader = FramedReader { _ in
            (Data([0xAA, 0xBB]), true)
        }

        do {
            _ = try await reader.receiveExactly(4)
            XCTFail("terminal partial data must not be treated as a complete frame")
        } catch let error as FramedReaderError {
            XCTAssertEqual(error, .peerClosed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testBootstrapReceiveTimeoutCancelsUnderlyingReceiveBeforeReturning() async {
        let probe = CancellationProbe()
        let startedAt = ContinuousClock.now

        do {
            _ = try await P2PDiscoveryService.raceBootstrapReceive(
                timeoutSeconds: 0.02,
                cancelReceive: { probe.markCancelled() },
                receive: {
                    try await Task.sleep(for: .seconds(60))
                    return Data()
                }
            )
            XCTFail("expected timeout")
        } catch let error as P2PDiscoveryError {
            guard case .timeout = error else {
                return XCTFail("unexpected P2P error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertTrue(probe.wasCancelled)
        XCTAssertLessThan(startedAt.duration(to: .now), .seconds(1))
    }
}
