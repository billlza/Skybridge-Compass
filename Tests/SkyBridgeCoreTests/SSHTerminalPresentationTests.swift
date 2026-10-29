import Foundation
import NIOCore
import XCTest
@testable import SkyBridgeCore

final class SSHTerminalPresentationTests: XCTestCase {
    func testUTF8DecoderRetainsScalarSplitAcrossNetworkBatches() throws {
        let buffer = SSHTerminalOutputBuffer()
        buffer.reset(generation: 1)

        XCTAssertTrue(buffer.enqueue([0xF0, 0x9F], generation: 1))
        XCTAssertNil(buffer.drain(generation: 1))
        XCTAssertTrue(buffer.enqueue([0x98, 0x80], generation: 1))
        XCTAssertEqual(buffer.drain(generation: 1), "😀")
    }

    func testUTF8DecoderReplacesCompleteInvalidBytesInsteadOfHoldingThemForever() throws {
        let buffer = SSHTerminalOutputBuffer()
        buffer.reset(generation: 2)

        XCTAssertTrue(buffer.enqueue([0xFF], generation: 2))
        XCTAssertEqual(buffer.drain(generation: 2), "�")
    }

    func testPendingByteTrimStartsAtUTF8ScalarBoundaryAndReportsTruncation() throws {
        let buffer = SSHTerminalOutputBuffer(
            maximumPendingBytes: 8,
            retainedPendingBytesAfterTrim: 5
        )
        buffer.reset(generation: 3)

        XCTAssertTrue(buffer.enqueue(Array("😀😀x".utf8), generation: 3))
        let output = try XCTUnwrap(buffer.drain(generation: 3))

        XCTAssertTrue(output.hasPrefix(SSHTerminalOutputBuffer.truncationMarker))
        XCTAssertTrue(output.hasSuffix("😀x"))
        XCTAssertFalse(output.contains("�"))
    }

    func testOversizedNIOBufferIsBoundedBeforeExtractionAndKeepsUTF8SafeSuffix() throws {
        let buffer = SSHTerminalOutputBuffer(
            maximumPendingBytes: 8,
            retainedPendingBytesAfterTrim: 4
        )
        buffer.reset(generation: 4)
        var nioBuffer = ByteBufferAllocator().buffer(capacity: 64)
        nioBuffer.writeString("untrusted-prefix-😀😀x")

        XCTAssertTrue(buffer.enqueue(nioBuffer, generation: 4))
        let output = try XCTUnwrap(buffer.drain(generation: 4))

        XCTAssertTrue(output.hasPrefix(SSHTerminalOutputBuffer.truncationMarker))
        XCTAssertTrue(output.hasSuffix("x"))
        XCTAssertFalse(output.contains("untrusted-prefix"))
        XCTAssertFalse(output.contains("�"))
    }

    func testAllContinuationSuffixIsDiscardedInOnePassWithoutLosingTruncationSignal() throws {
        let buffer = SSHTerminalOutputBuffer(
            maximumPendingBytes: 8,
            retainedPendingBytesAfterTrim: 4
        )
        buffer.reset(generation: 5)

        XCTAssertTrue(
            buffer.enqueue([UInt8](repeating: 0x80, count: 1_000_000), generation: 5)
        )
        XCTAssertNil(buffer.drain(generation: 5))
        XCTAssertTrue(buffer.enqueue("ok", generation: 5))
        XCTAssertEqual(
            buffer.drain(generation: 5),
            SSHTerminalOutputBuffer.truncationMarker + "ok"
        )
    }

    func testANSIStyleAndControlSequenceCanSpanBatches() {
        var parser = SSHTerminalANSIStreamParser()

        XCTAssertEqual(
            parser.consume("plain\u{001B}[3"),
            [.append(SSHTerminalStyledRun(text: "plain", style: SSHTerminalTextStyle()))]
        )
        XCTAssertEqual(
            parser.consume("1;1mred\u{001B}[22;39mnormal"),
            [
                .append(
                    SSHTerminalStyledRun(
                        text: "red",
                        style: SSHTerminalTextStyle(
                            foregroundColor: .red,
                            isBold: true,
                            isUnderlined: false
                        )
                    )
                ),
                .append(
                    SSHTerminalStyledRun(
                        text: "normal",
                        style: SSHTerminalTextStyle()
                    )
                )
            ]
        )
    }

    func testCRLFNormalizationAndBackspaceAreStatefulAcrossBatches() {
        var parser = SSHTerminalANSIStreamParser()

        XCTAssertEqual(
            parser.consume("first\r"),
            [.append(SSHTerminalStyledRun(text: "first\n", style: SSHTerminalTextStyle()))]
        )
        XCTAssertEqual(
            parser.consume("\nAB\u{0008}"),
            [
                .append(SSHTerminalStyledRun(text: "AB", style: SSHTerminalTextStyle())),
                .erasePreviousCharacter
            ]
        )
        XCTAssertEqual(
            parser.consume("C"),
            [.append(SSHTerminalStyledRun(text: "C", style: SSHTerminalTextStyle()))]
        )
    }

    func testOversizedOSCRemainsDiscardedUntilExplicitTerminator() {
        var parser = SSHTerminalANSIStreamParser()

        XCTAssertTrue(parser.consume("\u{001B}]" + String(repeating: "x", count: 4_100)).isEmpty)
        XCTAssertTrue(parser.consume("must-not-render").isEmpty)
        XCTAssertEqual(
            parser.consume("\u{001B}\\visible"),
            [.append(SSHTerminalStyledRun(text: "visible", style: SSHTerminalTextStyle()))]
        )
    }

    func testUnsupportedCSIIsConsumedRatherThanRenderedAsSpoofableText() {
        var parser = SSHTerminalANSIStreamParser()

        XCTAssertEqual(
            parser.consume("before\u{001B}[2Jafter"),
            [
                .append(SSHTerminalStyledRun(text: "before", style: SSHTerminalTextStyle())),
                .append(SSHTerminalStyledRun(text: "after", style: SSHTerminalTextStyle()))
            ]
        )
    }

    func testUnsupportedC0C1AndBidirectionalFormattingControlsAreNotVisible() {
        var parser = SSHTerminalANSIStreamParser()

        XCTAssertEqual(
            parser.consume(
                "a\u{0000}\u{0007}\u{000B}\u{007F}\u{0085}b"
                    + "\u{061C}\u{200E}\u{200F}\u{202E}c\u{202C}\u{2066}d\u{2069}\u{206A}e\t"
            ),
            [.append(SSHTerminalStyledRun(text: "abcde\t", style: SSHTerminalTextStyle()))]
        )
    }

    func testCanonicalPresentationReplayNeverRestartsInsideTruncatedOSCOrCSI() throws {
        let generation: UInt64 = 17
        let pipeline = SSHTerminalPresentationPipeline()
        pipeline.reset(generation: generation)
        var history = SSHTerminalPresentationHistory(
            maximumEstimatedBytes: 16_384,
            retainedEstimatedBytesAfterTrim: 8_192,
            maximumBatchCount: 2
        )
        var sequence: UInt64 = 0

        func parse(_ text: String) throws -> SSHTerminalPresentationBatch? {
            sequence &+= 1
            let operations = try XCTUnwrap(
                pipeline.consume(text, generation: generation)
            )
            guard !operations.isEmpty else { return nil }
            return SSHTerminalPresentationBatch(
                generation: generation,
                sequence: sequence,
                operations: operations
            )
        }

        history.append(try XCTUnwrap(parse("old-visible")))
        XCTAssertNil(try parse("\u{001B}]0;private-camera-title"))
        XCTAssertNil(try parse("-must-stay-hidden"))
        history.append(try XCTUnwrap(parse("\u{0007}after-osc")))

        XCTAssertNil(try parse("\u{001B}[3"))
        history.append(try XCTUnwrap(parse("1mred-text")))

        let replay = history.replay
        let visibleText = replay.batches
            .flatMap(\.operations)
            .compactMap { operation -> String? in
                guard case .append(let run) = operation else { return nil }
                return run.text
            }
            .joined()

        XCTAssertTrue(replay.didTruncateEarlierOutput)
        XCTAssertEqual(replay.batches.count, 2)
        XCTAssertFalse(visibleText.contains("private-camera-title"))
        XCTAssertFalse(visibleText.contains("must-stay-hidden"))
        XCTAssertFalse(visibleText.contains("31m"))
        XCTAssertEqual(visibleText, "after-oscred-text")
        XCTAssertEqual(
            replay.batches.last?.operations,
            [
                .append(
                    SSHTerminalStyledRun(
                        text: "red-text",
                        style: SSHTerminalTextStyle(foregroundColor: .red)
                    )
                )
            ]
        )
    }

    func testDroppedRawPrefixFailsClosedInsteadOfRenderingUnknownControlPayload() throws {
        let generation: UInt64 = 18
        let pipeline = SSHTerminalPresentationPipeline()
        pipeline.reset(generation: generation)

        let invalidation = try XCTUnwrap(
            pipeline.consume(
                "private-osc-payload-without-prefix",
                generation: generation,
                inputPrefixWasDropped: true
            )
        )
        XCTAssertEqual(
            invalidation,
            [
                .append(
                    SSHTerminalStyledRun(
                        text: SSHTerminalPresentationPipeline.desynchronizationMarker,
                        style: SSHTerminalTextStyle(foregroundColor: .brightYellow)
                    )
                )
            ]
        )
        XCTAssertFalse(
            invalidation.description.contains("private-osc-payload-without-prefix")
        )
        XCTAssertEqual(
            pipeline.consume("still-untrusted", generation: generation),
            []
        )

        pipeline.reset(generation: generation + 1)
        XCTAssertEqual(
            pipeline.consume("safe-after-reconnect", generation: generation + 1),
            [
                .append(
                    SSHTerminalStyledRun(
                        text: "safe-after-reconnect",
                        style: SSHTerminalTextStyle()
                    )
                )
            ]
        )
    }

    func testAdversarialStyleAndBackspaceAlternationHasHardOperationLimit() {
        var parser = SSHTerminalANSIStreamParser()
        var attack = ""
        attack.reserveCapacity(100_000)
        for _ in 0..<5_000 {
            attack.append("a\u{001B}[31mb\u{001B}[32m\u{0008}")
        }

        let operations = parser.consume(attack)

        XCTAssertEqual(
            operations.count,
            SSHTerminalANSIStreamParser.maximumRenderOperationsPerBatch
        )
        XCTAssertEqual(
            operations.last,
            .append(
                SSHTerminalStyledRun(
                    text: SSHTerminalANSIStreamParser.renderOperationTruncationMarker,
                    style: SSHTerminalTextStyle(
                        foregroundColor: .brightYellow,
                        isBold: false,
                        isUnderlined: false
                    )
                )
            )
        )
        XCTAssertEqual(
            parser.consume("tail"),
            [
                .append(
                    SSHTerminalStyledRun(
                        text: "tail",
                        style: SSHTerminalTextStyle(foregroundColor: .green)
                    )
                )
            ]
        )
    }

    func testHistoryIndexTrimsAtUnicodeSafeByteBoundary() {
        let policy = SSHTerminalHistoryRetentionPolicy(
            maximumUTF8Bytes: 8,
            retainedUTF8BytesAfterTrim: 4,
            maximumLineCount: 20,
            retainedLineCountAfterTrim: 10,
            byteBoundaryGranularity: 1
        )
        var index = SSHTerminalHistoryIndex(policy: policy)

        XCTAssertFalse(index.append("😀abcd").didTruncate)
        let mutation = index.append("e")

        XCTAssertEqual(mutation.prefixUTF16UnitsToRemove, 3)
        XCTAssertTrue(mutation.didTruncate)
        XCTAssertEqual(index.retainedUTF8ByteCount, 4)
        XCTAssertEqual(index.retainedUTF16UnitCount, 4)
    }

    func testHistoryIndexTrimsCompletedLinesAndMirrorsBackspaceDeletion() {
        let policy = SSHTerminalHistoryRetentionPolicy(
            maximumUTF8Bytes: 128,
            retainedUTF8BytesAfterTrim: 96,
            maximumLineCount: 4,
            retainedLineCountAfterTrim: 2,
            byteBoundaryGranularity: 8
        )
        var index = SSHTerminalHistoryIndex(policy: policy)

        let mutation = index.append("a\nb\nc\nd\n")
        XCTAssertEqual(mutation.prefixUTF16UnitsToRemove, 6)
        XCTAssertEqual(index.retainedLineCount, 2)
        XCTAssertEqual(index.retainedUTF8ByteCount, 2)

        XCTAssertFalse(index.append("😀").didTruncate)
        index.removeSuffix("😀")
        XCTAssertEqual(index.retainedUTF8ByteCount, 2)
        XCTAssertEqual(index.retainedUTF16UnitCount, 2)
    }

    func testHistoryIndexRemoves511BackspacesFromFullLineIndexByOrderedTailDeletion() throws {
        let policy = SSHTerminalHistoryRetentionPolicy(
            maximumUTF8Bytes: 1_048_576,
            retainedUTF8BytesAfterTrim: 786_432,
            maximumLineCount: 2_100,
            retainedLineCountAfterTrim: 2_000,
            byteBoundaryGranularity: 1
        )
        var index = SSHTerminalHistoryIndex(policy: policy)
        let completedLines = String(repeating: "x\n", count: 2_000)
        let removableSuffix = String(repeating: "z", count: 511)

        XCTAssertFalse(index.append(completedLines + removableSuffix).didTruncate)
        for _ in 0..<511 {
            index.removeSuffix("z")
        }

        XCTAssertEqual(index.retainedLineCount, 2_001)
        XCTAssertEqual(index.retainedUTF8ByteCount, completedLines.utf8.count)
        XCTAssertEqual(index.retainedUTF16UnitCount, completedLines.utf16.count)

        let source = try terminalPresentationSource()
        XCTAssertTrue(source.contains("while let last = lineBreakEnds.last"))
        XCTAssertTrue(source.contains("while let last = byteTrimBoundaries.last"))
        XCTAssertFalse(source.contains("lineBreakEnds.removeAll(where:"))
        XCTAssertFalse(source.contains("byteTrimBoundaries.removeAll(where:"))
    }

    func testMacTerminalViewUsesIncrementalTextStorageContract() throws {
        let source = try macTerminalViewSource()

        XCTAssertTrue(source.contains("NSTextStorage"))
        XCTAssertTrue(source.contains("session.$terminalPresentationBatch"))
        XCTAssertTrue(source.contains("session.terminalPresentationReplay"))
        XCTAssertTrue(source.contains("SSHTerminalHistoryIndex"))
        XCTAssertTrue(source.contains("rangeOfComposedCharacterSequence"))
        XCTAssertTrue(source.contains("for operation in batch.operations"))
        XCTAssertFalse(source.contains("SSHTerminalANSIStreamParser"))
        XCTAssertFalse(source.contains("session.$terminalOutputBatch"))
        XCTAssertFalse(source.contains("Text(formatANSI("))
        XCTAssertFalse(source.contains("session?.outputText"))
        XCTAssertFalse(source.contains("split(separator: \"\\n\""))
        XCTAssertFalse(source.contains("AttributedString(bufferedOutput"))

        let clearStart = try XCTUnwrap(source.range(of: "func clear() {"))
        let clearEnd = try XCTUnwrap(
            source.range(
                of: "private func resetForNewSession()",
                range: clearStart.upperBound..<source.endIndex
            )
        )
        let clearBody = String(source[clearStart.lowerBound..<clearEnd.lowerBound])
        let surfaceClear = try XCTUnwrap(
            clearBody.range(of: "textStorage.setAttributedString(NSAttributedString())")
        )
        let sessionClear = try XCTUnwrap(
            clearBody.range(of: "observedSession?.clearTerminalOutputHistory()")
        )
        XCTAssertLessThan(
            surfaceClear.lowerBound,
            sessionClear.lowerBound,
            "The surface must clear before the session republishes a persistent desync warning"
        )
    }

    private func macTerminalViewSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources/SkyBridgeCompassApp/Views/SSHTerminalView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func terminalPresentationSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/SSHTerminalPresentation.swift"
            )
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
