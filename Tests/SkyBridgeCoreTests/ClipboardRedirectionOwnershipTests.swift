#if os(macOS)
import AppKit
import XCTest
@testable import SkyBridgeCore

@MainActor
final class ClipboardRedirectionOwnershipTests: XCTestCase {
    func testOldOwnerCannotWriteOrStopReplacementClipboardSession() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let manager = ClipboardRedirectionManager(pasteboard: pasteboard)
        let old = UUID()
        let current = UUID()
        manager.enable(for: old) { _, _ in }
        try manager.setRemoteClipboard(data: Data("old".utf8), mimeType: "text/plain", for: old)
        manager.enable(for: current) { _, _ in }
        defer { manager.disable(for: current) }
        try manager.setRemoteClipboard(data: Data("current".utf8), mimeType: "text/plain", for: current)

        XCTAssertFalse(manager.disable(for: old))
        XCTAssertThrowsError(try manager.setRemoteClipboard(
            data: Data("stale".utf8), mimeType: "text/plain", for: old
        )) { XCTAssertEqual($0 as? ClipboardRedirectionError, .ownerMismatch) }
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(pasteboard.string(forType: .string), "current")
        XCTAssertTrue(manager.disable(for: current))
        XCTAssertFalse(manager.disable(for: current))
        XCTAssertThrowsError(try manager.setRemoteClipboard(data: Data(), mimeType: "text/plain", for: current)) {
            XCTAssertEqual($0 as? ClipboardRedirectionError, .inactiveSession)
        }
    }

    func testInvalidRemotePayloadNeverClearsExistingPasteboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let manager = ClipboardRedirectionManager(pasteboard: pasteboard)
        let owner = UUID()
        manager.enable(for: owner) { _, _ in }
        defer { manager.disable(for: owner) }
        try manager.setRemoteClipboard(data: Data("keep".utf8), mimeType: "text/plain", for: owner)
        let invalid: [(Data, String, ClipboardRedirectionError)] = [
            (Data([0xFF]), "text/plain", .invalidPayload),
            (Data("not an image".utf8), "image/png", .invalidPayload),
            (Data(), "application/octet-stream", .unsupportedMIMEType),
            (Data(repeating: 0, count: 8 * 1_024 * 1_024 + 1), "text/plain", .payloadTooLarge)
        ]
        for (data, mimeType, expected) in invalid {
            XCTAssertThrowsError(try manager.setRemoteClipboard(data: data, mimeType: mimeType, for: owner)) {
                XCTAssertEqual($0 as? ClipboardRedirectionError, expected)
            }
            XCTAssertEqual(pasteboard.string(forType: .string), "keep")
        }
    }

    func testDelayedOldPollCannotDeliverNewOwnerClipboardAndRemoteWritesDoNotEcho() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let manager = ClipboardRedirectionManager(pasteboard: pasteboard)
        let old = UUID()
        let current = UUID()
        var oldPayloads: [Data] = []
        var currentPayloads: [Data] = []
        manager.enable(for: old) { data, _ in oldPayloads.append(data) }
        manager.enable(for: current) { data, _ in currentPayloads.append(data) }
        defer { manager.disable(for: current) }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("local", forType: .string))
        manager.pollLocalClipboard(for: old)
        XCTAssertTrue(oldPayloads.isEmpty)
        XCTAssertTrue(currentPayloads.isEmpty)
        manager.pollLocalClipboard(for: current)
        XCTAssertEqual(currentPayloads, [Data("local".utf8)])
        try manager.setRemoteClipboard(data: Data("remote".utf8), mimeType: "text/plain", for: current)
        XCTAssertEqual(pasteboard.string(forType: .string), "remote", "Writes must complete before ownership can change")
        manager.pollLocalClipboard(for: current)
        XCTAssertEqual(currentPayloads, [Data("local".utf8)])
    }

    func testDeduplicationDoesNotCarryAcrossOwnersOrHideEmptyText() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let manager = ClipboardRedirectionManager(pasteboard: pasteboard)
        let old = UUID()
        let current = UUID()
        manager.enable(for: old) { _, _ in }
        try manager.setRemoteClipboard(data: Data("same".utf8), mimeType: "text/plain", for: old)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("changed locally", forType: .string))
        manager.enable(for: current) { _, _ in }
        defer { manager.disable(for: current) }
        try manager.setRemoteClipboard(data: Data("same".utf8), mimeType: "text/plain", for: current)
        XCTAssertEqual(pasteboard.string(forType: .string), "same")
        try manager.setRemoteClipboard(data: Data(), mimeType: "text/plain", for: current)
        XCTAssertEqual(pasteboard.string(forType: .string), "")
    }
}
#endif
