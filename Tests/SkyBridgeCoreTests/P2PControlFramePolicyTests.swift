import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

final class P2PControlFramePolicyTests: XCTestCase {
    func testBodyBoundaryAcceptsOneByteAndCompatibilityMaximum() throws {
        XCTAssertEqual(try P2PControlFramePolicy.outboundLength(forBodyByteCount: 1), 1)
        XCTAssertEqual(
            try P2PControlFramePolicy.outboundLength(
                forBodyByteCount: P2PControlFramePolicy.maximumBodyByteCount
            ),
            UInt32(P2PControlFramePolicy.maximumBodyByteCount)
        )
        XCTAssertEqual(
            try P2PControlFramePolicy.inboundBodyByteCount(
                from: UInt32(P2PControlFramePolicy.maximumBodyByteCount)
            ),
            P2PControlFramePolicy.maximumBodyByteCount
        )
    }

    func testBodyBoundaryRejectsEmptyAndMaximumPlusOne() {
        XCTAssertThrowsError(try P2PControlFramePolicy.outboundLength(forBodyByteCount: 0)) { error in
            XCTAssertEqual(error as? P2PControlFramePolicyError, .invalidByteCount(0))
        }

        let oversized = P2PControlFramePolicy.maximumBodyByteCount + 1
        XCTAssertThrowsError(try P2PControlFramePolicy.outboundLength(forBodyByteCount: oversized)) { error in
            XCTAssertEqual(
                error as? P2PControlFramePolicyError,
                .bodyTooLarge(actual: oversized, maximum: P2PControlFramePolicy.maximumBodyByteCount)
            )
        }
    }

    func testFrameBuildsBigEndianPrefixAfterValidation() throws {
        let body = Data([0xaa, 0xbb, 0xcc])

        let frame = try P2PControlFramePolicy.frame(body: body)

        XCTAssertEqual(frame, Data([0x00, 0x00, 0x00, 0x03, 0xaa, 0xbb, 0xcc]))
    }

    func testFrameRejectsOversizedBodyBeforeConstructingOutput() {
        let oversized = Data(
            repeating: 0xff,
            count: P2PControlFramePolicy.maximumBodyByteCount + 1
        )

        XCTAssertThrowsError(try P2PControlFramePolicy.frame(body: oversized)) { error in
            XCTAssertEqual(
                error as? P2PControlFramePolicyError,
                .bodyTooLarge(
                    actual: oversized.count,
                    maximum: P2PControlFramePolicy.maximumBodyByteCount
                )
            )
        }
    }

    func testInlineClipboardBudgetHasExplicitBoundary() throws {
        try P2PControlFramePolicy.validateInlineClipboardByteCount(
            P2PControlFramePolicy.maximumInlineClipboardByteCount
        )

        let oversized = P2PControlFramePolicy.maximumInlineClipboardByteCount + 1
        XCTAssertThrowsError(try P2PControlFramePolicy.validateInlineClipboardByteCount(oversized)) { error in
            XCTAssertEqual(
                error as? P2PControlFramePolicyError,
                .inlineClipboardTooLarge(
                    actual: oversized,
                    maximum: P2PControlFramePolicy.maximumInlineClipboardByteCount
                )
            )
        }
    }

    func testClipboardJSONDoesNotDoubleWorstCaseBase64Slashes() throws {
        let data = Data(
            repeating: 0xff,
            count: P2PControlFramePolicy.maximumInlineClipboardByteCount
        )
        let message = AppMessage.clipboard(
            .init(
                mimeType: "application/x-skybridge-file-url",
                dataBase64: data.base64EncodedString(),
                sentAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        let encoded = try P2PControlJSONEncoder.encode(message)
        XCTAssertFalse(try XCTUnwrap(String(data: encoded, encoding: .utf8)).contains("\\/"))

        let aesGCMCombinedOverhead = 28
        let trafficPaddingHeader = 8
        XCTAssertLessThanOrEqual(
            encoded.count + aesGCMCombinedOverhead + trafficPaddingHeader,
            P2PControlFramePolicy.maximumBodyByteCount
        )
    }

    func testMacClipboardConfigurationCannotAdvertiseAnUnsendableInlineSize() {
        let configuration = ClipboardSyncConfiguration(
            maxContentSize: 25 * 1_024 * 1_024
        )

        XCTAssertEqual(
            configuration.maxContentSize,
            P2PControlFramePolicy.maximumInlineClipboardByteCount
        )
    }

    func testLegacyMacFileURLMIMECanonicalizesToURIList() {
        XCTAssertEqual(
            P2PClipboardMIMEPolicy.canonicalWireValue(
                for: P2PClipboardMIMEPolicy.legacySkyBridgeFileURL
            ),
            P2PClipboardMIMEPolicy.uriList
        )
    }
}
