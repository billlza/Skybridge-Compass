import AppKit
import XCTest
import SkyBridgeCore
@testable import SkyBridgeCompassApp

@MainActor
final class InteractiveRemoteViewTests: XCTestCase {
    private enum Input: Equatable {
        case key(UInt16, Bool)
        case mouse(NSEvent.EventType, CGFloat, CGFloat, Int)
    }

    func testLeftAndRightModifiersReleaseIndependently() throws {
        let view = makeView()
        var input: [Input] = []
        view.onKeyboardEvent = { input.append(.key($0, $1)) }

        view.flagsChanged(with: try keyEvent(.flagsChanged, code: 56, flags: .shift))
        view.flagsChanged(with: try keyEvent(.flagsChanged, code: 60, flags: .shift))
        view.flagsChanged(with: try keyEvent(.flagsChanged, code: 56, flags: .shift))
        view.flagsChanged(with: try keyEvent(.flagsChanged, code: 60))

        XCTAssertEqual(input, [.key(56, true), .key(60, true), .key(56, false), .key(60, false)])
        view.releasePressedInput()
        XCTAssertEqual(input.count, 4)
    }

    func testKeyFlagsRestoreModifierPressedBeforeRemoteViewReceivedFocus() throws {
        let view = makeView()
        var input: [Input] = []
        view.onKeyboardEvent = { input.append(.key($0, $1)) }
        view.keyDown(with: try keyEvent(.keyDown, code: 0, flags: .shift))
        view.keyUp(with: try keyEvent(.keyUp, code: 0, flags: .shift))
        view.keyDown(with: try keyEvent(.keyDown, code: 1))
        view.keyUp(with: try keyEvent(.keyUp, code: 1))
        view.releasePressedInput()
        XCTAssertEqual(input, [.key(56, true), .key(0, true), .key(0, false),
            .key(56, false), .key(1, true), .key(1, false)])
    }

    func testNavigationFunctionFlagDoesNotInventHeldFnModifier() throws {
        let view = makeView()
        var input: [Input] = []
        view.onKeyboardEvent = { input.append(.key($0, $1)) }
        view.keyDown(with: try keyEvent(.keyDown, code: 126, flags: [.function, .numericPad]))
        view.keyUp(with: try keyEvent(.keyUp, code: 126, flags: [.function, .numericPad]))
        view.releasePressedInput()
        XCTAssertEqual(input, [.key(126, true), .key(126, false)])
    }

    func testKeyFlagReconciliationPreservesKnownRightModifierAndReleasesOnFocusLoss() throws {
        let view = makeView()
        var input: [Input] = []
        view.onKeyboardEvent = { input.append(.key($0, $1)) }
        view.flagsChanged(with: try keyEvent(.flagsChanged, code: 60, flags: .shift))
        view.keyDown(with: try keyEvent(.keyDown, code: 0, flags: .shift))
        view.releasePressedInput()
        XCTAssertEqual(input, [.key(60, true), .key(0, true), .key(0, false), .key(60, false)])
    }

    func testRepeatedKeyDownHasOneSyntheticReleaseAndLatePhysicalUpIsIgnored() throws {
        let view = makeView()
        var input: [Input] = []
        view.onKeyboardEvent = { input.append(.key($0, $1)) }

        view.keyDown(with: try keyEvent(.keyDown, code: 0))
        view.keyDown(with: try keyEvent(.keyDown, code: 0, isRepeat: true))
        view.releasePressedInput()
        view.keyUp(with: try keyEvent(.keyUp, code: 0))
        view.releasePressedInput()

        XCTAssertEqual(input, [.key(0, true), .key(0, true), .key(0, false)])
    }

    func testFocusLossReleasesButtonsBeforeTheirHeldModifiersInReversePressOrder() throws {
        let view = makeView()
        let window = attachToWindow(view)
        defer { window.contentView = nil; window.close() }
        var input: [Input] = []
        view.onKeyboardEvent = { input.append(.key($0, $1)) }
        view.onMouseEvent = { input.append(.mouse($1, $0.x, $0.y, $2)) }

        view.flagsChanged(with: try keyEvent(.flagsChanged, code: 56, flags: .shift))
        view.keyDown(with: try keyEvent(.keyDown, code: 0, flags: .shift))
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 10, y: 10), in: window))
        view.rightMouseDown(with: try mouseEvent(.rightMouseDown, at: CGPoint(x: 11, y: 11), in: window))
        view.mouseMoved(with: try mouseEvent(.mouseMoved, at: CGPoint(x: 30, y: 30), in: window))
        view.releasePressedInput()

        XCTAssertEqual(Array(input.suffix(4)), [
            .mouse(.rightMouseUp, 30, 30, 1), .mouse(.leftMouseUp, 30, 30, 0),
            .key(0, false), .key(56, false)
        ])
        let releasedCount = input.count
        view.releasePressedInput()
        XCTAssertEqual(input.count, releasedCount)
    }

    func testFeedChangeReleasesThroughOldCallbacksBeforeNewBinding() throws {
        let view = makeView()
        let oldFeed = RemoteTextureFeed()
        let newFeed = RemoteTextureFeed()
        var oldInput: [Input] = []
        var newInput: [Input] = []
        view.prepareInputBinding(feed: oldFeed, hasKeyboardInput: true, hasMouseInput: true)
        view.onKeyboardEvent = { oldInput.append(.key($0, $1)) }
        view.keyDown(with: try keyEvent(.keyDown, code: 0))

        view.prepareInputBinding(feed: newFeed, hasKeyboardInput: true, hasMouseInput: true)
        view.onKeyboardEvent = { newInput.append(.key($0, $1)) }
        view.keyUp(with: try keyEvent(.keyUp, code: 0))
        view.keyDown(with: try keyEvent(.keyDown, code: 1))
        view.releasePressedInput()

        XCTAssertEqual(oldInput, [.key(0, true), .key(0, false)])
        XCTAssertEqual(newInput, [.key(1, true), .key(1, false)])
    }

    func testSameFeedRefreshPreservesHeldInputUntilItsExplicitUp() throws {
        let view = makeView()
        let feed = RemoteTextureFeed()
        var input: [Input] = []
        view.prepareInputBinding(feed: feed, hasKeyboardInput: true, hasMouseInput: true)
        view.onKeyboardEvent = { input.append(.key($0, $1)) }
        view.keyDown(with: try keyEvent(.keyDown, code: 0))

        view.prepareInputBinding(feed: feed, hasKeyboardInput: true, hasMouseInput: true)
        XCTAssertEqual(input, [.key(0, true)])
        view.keyUp(with: try keyEvent(.keyUp, code: 0))
        view.releasePressedInput()
        XCTAssertEqual(input, [.key(0, true), .key(0, false)])
    }

    func testRemovingCallbacksReleasesPressedInputThroughTheExistingBinding() throws {
        let view = makeView()
        let feed = RemoteTextureFeed()
        var input: [Input] = []
        view.prepareInputBinding(feed: feed, hasKeyboardInput: true, hasMouseInput: true)
        view.onKeyboardEvent = { input.append(.key($0, $1)) }
        view.keyDown(with: try keyEvent(.keyDown, code: 0))

        view.prepareInputBinding(feed: feed, hasKeyboardInput: false, hasMouseInput: false)
        view.onKeyboardEvent = nil
        view.releasePressedInput()

        XCTAssertEqual(input, [.key(0, true), .key(0, false)])
        XCTAssertFalse(view.acceptsFirstResponder)
    }

    func testTrackedMouseUpUsesLastPositionDuringAFrameMappingGap() throws {
        let view = makeView()
        let window = attachToWindow(view)
        defer { window.contentView = nil; window.close() }
        view.mapsPointerToRemoteFrame = true
        view.remoteFrameSize = CGSize(width: 1_600, height: 900)
        var input: [Input] = []
        view.onMouseEvent = { input.append(.mouse($1, $0.x, $0.y, $2)) }
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 80, y: 45), in: window))

        view.remoteFrameSize = .zero
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 100, y: 50), in: window))
        XCTAssertEqual(input, [.mouse(.leftMouseDown, 400, 675, 0), .mouse(.leftMouseUp, 400, 675, 0)])
        view.releasePressedInput()
        XCTAssertEqual(input.count, 2, "A mapping gap must not leave local or remote pressed state")
    }

    func testPointerMappingUsesRemotePixelsTopLeftOriginAndHalfOpenBounds() throws {
        let view = makeView()
        let window = attachToWindow(view)
        defer { window.contentView = nil; window.close() }
        view.mapsPointerToRemoteFrame = true
        view.remoteFrameSize = CGSize(width: 1_600, height: 900)
        var input: [Input] = []
        view.onMouseEvent = { input.append(.mouse($1, $0.x, $0.y, $2)) }

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 80, y: 45), in: window))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: -10, y: 200), in: window))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 400, y: -10), in: window))

        XCTAssertEqual(input, [
            .mouse(.leftMouseDown, 400, 675, 0), .mouse(.leftMouseDragged, 0, 0, 0),
            .mouse(.leftMouseUp, 1_599, 899, 0)
        ])
    }

    func testMissingFrameMappingCannotCreateAPressedButton() throws {
        let view = makeView()
        let window = attachToWindow(view)
        defer { window.contentView = nil; window.close() }
        view.mapsPointerToRemoteFrame = true
        var input: [Input] = []
        view.onMouseEvent = { input.append(.mouse($1, $0.x, $0.y, $2)) }
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 80, y: 45), in: window))
        view.remoteFrameSize = CGSize(width: 1_600, height: 900)
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 80, y: 45), in: window))
        view.releasePressedInput()

        XCTAssertTrue(input.isEmpty)
    }

    func testLegacyPointerBindingKeepsUnscaledViewCoordinates() throws {
        let view = makeView()
        let window = attachToWindow(view)
        defer { window.contentView = nil; window.close() }
        view.remoteFrameSize = CGSize(width: 1_600, height: 900)
        var input: [Input] = []
        view.onMouseEvent = { input.append(.mouse($1, $0.x, $0.y, $2)) }
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 20, y: 30), in: window))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 20, y: 30), in: window))

        XCTAssertEqual(input, [.mouse(.leftMouseDown, 20, 30, 0), .mouse(.leftMouseUp, 20, 30, 0)])
    }

    func testWindowFocusNotificationReleasesOnlyTheOwningWindow() throws {
        let firstView = makeView()
        let firstWindow = attachToWindow(firstView)
        let secondView = makeView()
        let secondWindow = attachToWindow(secondView)
        defer {
            firstWindow.contentView = nil
            secondWindow.contentView = nil
            firstWindow.close()
            secondWindow.close()
        }
        var firstInput: [Input] = []
        var secondInput: [Input] = []
        firstView.onKeyboardEvent = { firstInput.append(.key($0, $1)) }
        secondView.onKeyboardEvent = { secondInput.append(.key($0, $1)) }
        firstView.keyDown(with: try keyEvent(.keyDown, code: 0))
        secondView.keyDown(with: try keyEvent(.keyDown, code: 1))

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: firstWindow)

        XCTAssertEqual(firstInput, [.key(0, true), .key(0, false)])
        XCTAssertEqual(secondInput, [.key(1, true)])
    }

    func testRemovingViewFromWindowReleasesPressedInput() throws {
        let view = makeView()
        let window = attachToWindow(view)
        defer { window.close() }
        var input: [Input] = []
        view.onKeyboardEvent = { input.append(.key($0, $1)) }
        view.keyDown(with: try keyEvent(.keyDown, code: 0))

        window.contentView = nil

        XCTAssertEqual(input, [.key(0, true), .key(0, false)])
    }

    func testChangingFirstResponderReleasesPressedInput() throws {
        let view = makeView()
        let window = attachToWindow(view)
        defer { window.contentView = nil; window.close() }
        var input: [Input] = []
        view.onKeyboardEvent = { input.append(.key($0, $1)) }
        XCTAssertTrue(window.makeFirstResponder(view))
        view.keyDown(with: try keyEvent(.keyDown, code: 0))

        XCTAssertTrue(window.makeFirstResponder(nil))

        XCTAssertEqual(input, [.key(0, true), .key(0, false)])
    }

    func testRepresentableDismantleReleasesInput() throws {
        let view = makeView()
        var input: [Input] = []
        view.onKeyboardEvent = { input.append(.key($0, $1)) }
        view.keyDown(with: try keyEvent(.keyDown, code: 0))
        let representable = RemoteDisplayView(textureFeed: RemoteTextureFeed())

        RemoteDisplayView.dismantleNSView(view, coordinator: representable.makeCoordinator())

        XCTAssertEqual(input, [.key(0, true), .key(0, false)])
    }

    private func makeView() -> InteractiveRemoteView {
        _ = NSApplication.shared
        return InteractiveRemoteView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), device: nil)
    }

    private func attachToWindow(_ view: InteractiveRemoteView) -> NSWindow {
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    private func keyEvent(
        _ type: NSEvent.EventType,
        code: UInt16,
        flags: NSEvent.ModifierFlags = [],
        isRepeat: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 1,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: isRepeat, keyCode: code
        ))
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
    }
}
