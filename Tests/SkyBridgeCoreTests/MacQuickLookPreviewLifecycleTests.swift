import XCTest

final class MacQuickLookPreviewLifecycleTests: XCTestCase {
    func testQuickLookWindowCloseDoesNotManuallyClosePreviewView() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SkyBridgeCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let sourceURL = root.appendingPathComponent("Sources/SkyBridgeUI/FileTransfer/MediaPreviewView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        guard let closeHandlerRange = source.range(of: "func windowWillClose(_ notification: Notification)"),
              let closingBraceRange = source[closeHandlerRange.upperBound...].range(of: "\n    }") else {
            XCTFail("Mac Quick Look window close handler was not found")
            return
        }

        let closeHandler = source[closeHandlerRange.lowerBound..<closingBraceRange.upperBound]
        XCTAssertFalse(
            closeHandler.contains(".close()"),
            "QLPreviewView shouldCloseWithWindow owns teardown; manually closing it from windowWillClose can double-deactivate Quick Look."
        )
        XCTAssertFalse(
            closeHandler.contains("onClose(fileKey)"),
            "Quick Look window controllers must not be synchronously released from windowWillClose while Quick Look is closing its view."
        )
        XCTAssertTrue(
            closeHandler.contains("DispatchQueue.main.async"),
            "Quick Look presenter cleanup should run after the current AppKit/Quick Look close callback returns."
        )
        XCTAssertTrue(
            closeHandler.contains("guard !didScheduleClose else { return }"),
            "Quick Look close cleanup should only be scheduled once per window close lifecycle."
        )

        XCTAssertTrue(
            source.contains("self?.controllers[closedKey] === closedController"),
            "Delayed Quick Look cleanup must not remove a newer preview controller for the same file path."
        )
    }
}
