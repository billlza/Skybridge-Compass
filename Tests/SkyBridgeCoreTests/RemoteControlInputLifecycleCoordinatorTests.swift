#if os(macOS)
import CoreGraphics
import XCTest
@testable import SkyBridgeCore

@MainActor
final class RemoteControlInputLifecycleCoordinatorTests: XCTestCase {
    func testExplicitUpClearsTrackedStateBeforeTeardown() {
        let timeline = TimelineBox()
        let coordinator = makeCoordinator(timeline: timeline)
        let owner = makeOwner()

        XCTAssertEqual(
            coordinator.postMouseEvent(mouse(.leftMouseDown), owner: owner),
            .posted
        )
        XCTAssertEqual(
            coordinator.postMouseEvent(mouse(.leftMouseUp), owner: owner),
            .posted
        )

        let release = coordinator.releaseAll(for: owner)

        XCTAssertEqual(
            timeline.values,
            ["mouse:leftMouseDown:plain", "mouse:leftMouseUp:plain"]
        )
        XCTAssertFalse(release.hadTrackedInput)
        XCTAssertEqual(coordinator.releaseAll(for: owner), emptyReleaseResult)
    }

    func testTeardownReleasesControlsInReversePressOrderExactlyOnce() {
        let timeline = TimelineBox()
        let coordinator = makeCoordinator(
            timeline: timeline,
            currentPointerLocation: { CGPoint(x: 90, y: 91) }
        )
        let owner = makeOwner()

        XCTAssertEqual(coordinator.postKeyboardEvent(key(.keyDown, 56), owner: owner), .posted)
        XCTAssertEqual(coordinator.postKeyboardEvent(key(.keyDown, 0), owner: owner), .posted)
        XCTAssertEqual(coordinator.postKeyboardEvent(key(.keyDown, 0), owner: owner), .posted)
        XCTAssertEqual(coordinator.postMouseEvent(mouse(.rightMouseDown), owner: owner), .posted)

        let release = coordinator.releaseAll(for: owner)

        XCTAssertEqual(release.trackedMouseButtonCount, 1)
        XCTAssertEqual(release.trackedKeyCount, 2)
        XCTAssertEqual(release.releasedControlCount, 3)
        XCTAssertEqual(release.failedReleaseCount, 0)
        XCTAssertEqual(
            Array(timeline.values.suffix(3)),
            ["syntheticMouseUp:right:90.0:91.0", "syntheticKeyUp:0", "syntheticKeyUp:56"]
        )
        let countAfterFirstRelease = timeline.values.count
        XCTAssertEqual(coordinator.releaseAll(for: owner), emptyReleaseResult)
        XCTAssertEqual(timeline.values.count, countAfterFirstRelease)
    }

    func testSameSessionIdentifierReplacementCannotInjectOrReleaseAcrossGeneration() {
        let timeline = TimelineBox()
        let coordinator = makeCoordinator(timeline: timeline)
        let oldOwner = makeOwner(sessionID: "same")
        let replacementOwner = makeOwner(sessionID: "same")

        XCTAssertEqual(coordinator.postKeyboardEvent(key(.keyDown, 0), owner: oldOwner), .posted)
        XCTAssertEqual(
            coordinator.postKeyboardEvent(key(.keyDown, 1), owner: replacementOwner),
            .ownerConflict
        )
        XCTAssertEqual(coordinator.releaseAll(for: oldOwner).releasedControlCount, 1)
        XCTAssertEqual(coordinator.postKeyboardEvent(key(.keyDown, 1), owner: replacementOwner), .posted)

        XCTAssertEqual(coordinator.releaseAll(for: oldOwner), emptyReleaseResult)
        XCTAssertEqual(coordinator.releaseAll(for: replacementOwner).releasedControlCount, 1)
        XCTAssertEqual(Array(timeline.values.suffix(2)), ["key:keyDown:1", "syntheticKeyUp:1"])
    }

    func testP2PAndWebRTCOwnersCannotSharePressedState() {
        let timeline = TimelineBox()
        let coordinator = makeCoordinator(timeline: timeline)
        let p2pOwner = makeOwner(transport: .p2p)
        let webRTCOwner = makeOwner(transport: .webRTC)

        XCTAssertEqual(coordinator.postMouseEvent(mouse(.leftMouseDown), owner: p2pOwner), .posted)
        XCTAssertEqual(
            coordinator.postKeyboardEvent(key(.keyDown, 0), owner: webRTCOwner),
            .ownerConflict
        )
        XCTAssertEqual(coordinator.releaseAll(for: p2pOwner).releasedControlCount, 1)
        XCTAssertEqual(coordinator.postKeyboardEvent(key(.keyDown, 0), owner: webRTCOwner), .posted)
        XCTAssertEqual(coordinator.releaseAll(for: webRTCOwner).releasedControlCount, 1)
    }

    func testUntrackedReleaseFailsClosedWithoutPermissionPrompt() {
        let timeline = TimelineBox()
        var permissionPromptCount = 0
        let coordinator = makeCoordinator(
            timeline: timeline,
            ensureAccessibilityPermission: {
                permissionPromptCount += 1
                return true
            }
        )
        let owner = makeOwner()

        XCTAssertEqual(
            coordinator.postMouseEvent(mouse(.leftMouseUp), owner: owner),
            .untrackedRelease
        )
        XCTAssertEqual(
            coordinator.postKeyboardEvent(key(.keyUp, 0), owner: owner),
            .untrackedRelease
        )
        XCTAssertEqual(permissionPromptCount, 0)
        XCTAssertTrue(timeline.values.isEmpty)
    }

    func testMissingPermissionDoesNotTrackDownAndTeardownDoesNotPrompt() {
        let timeline = TimelineBox()
        var permissionPromptCount = 0
        var nonPromptPermissionCheckCount = 0
        let coordinator = makeCoordinator(
            timeline: timeline,
            ensureAccessibilityPermission: {
                permissionPromptCount += 1
                return false
            },
            hasAccessibilityPermission: {
                nonPromptPermissionCheckCount += 1
                return false
            }
        )
        let owner = makeOwner()

        XCTAssertEqual(
            coordinator.postMouseEvent(mouse(.leftMouseDown), owner: owner),
            .permissionDenied
        )
        XCTAssertEqual(coordinator.releaseAll(for: owner), emptyReleaseResult)
        XCTAssertEqual(permissionPromptCount, 1)
        XCTAssertEqual(nonPromptPermissionCheckCount, 0)
        XCTAssertTrue(timeline.values.isEmpty)
    }

    func testPermissionRevokedAfterDownReturnsObservableSkippedReleaseWithoutPrompt() {
        let timeline = TimelineBox()
        var permissionPromptCount = 0
        var nonPromptPermissionCheckCount = 0
        let coordinator = makeCoordinator(
            timeline: timeline,
            ensureAccessibilityPermission: {
                permissionPromptCount += 1
                return true
            },
            hasAccessibilityPermission: {
                nonPromptPermissionCheckCount += 1
                return false
            }
        )
        let owner = makeOwner()
        XCTAssertEqual(coordinator.postKeyboardEvent(key(.keyDown, 0), owner: owner), .posted)

        let release = coordinator.releaseAll(for: owner)

        XCTAssertEqual(permissionPromptCount, 1)
        XCTAssertEqual(nonPromptPermissionCheckCount, 1)
        XCTAssertTrue(release.skippedForMissingPermission)
        XCTAssertEqual(release.trackedKeyCount, 1)
        XCTAssertEqual(release.releasedControlCount, 0)
        XCTAssertEqual(timeline.values, ["key:keyDown:0"])
    }

    func testMalformedInputAndInjectionFailureNeverBecomeTrackedState() {
        let timeline = TimelineBox()
        var permissionPromptCount = 0
        let coordinator = makeCoordinator(
            timeline: timeline,
            ensureAccessibilityPermission: {
                permissionPromptCount += 1
                return true
            },
            postKeyboardEvent: { event in
                timeline.values.append("failedKey:\(event.keyCode)")
                return false
            }
        )
        let owner = makeOwner()

        XCTAssertEqual(
            coordinator.postMouseEvent(
                RemoteMouseEvent(
                    type: .leftMouseDown,
                    x: .nan,
                    y: 2,
                    timestamp: 3
                ),
                owner: owner
            ),
            .invalidEvent
        )
        XCTAssertEqual(coordinator.postKeyboardEvent(key(.keyDown, -1), owner: owner), .invalidEvent)
        XCTAssertEqual(coordinator.postKeyboardEvent(key(.keyDown, 65_536), owner: owner), .invalidEvent)
        XCTAssertEqual(coordinator.postKeyboardEvent(key(.keyDown, 0), owner: owner), .injectionFailed)
        XCTAssertEqual(permissionPromptCount, 1)
        XCTAssertEqual(coordinator.releaseAll(for: owner), emptyReleaseResult)
        XCTAssertEqual(timeline.values, ["failedKey:0"])
    }

    func testSyntheticMouseReleaseFallsBackToLastSuccessfulInjectionPoint() {
        let timeline = TimelineBox()
        let coordinator = makeCoordinator(
            timeline: timeline,
            currentPointerLocation: { nil }
        )
        let owner = makeOwner()

        XCTAssertEqual(
            coordinator.postMouseEvent(
                RemoteMouseEvent(
                    type: .leftMouseDown,
                    x: 5,
                    y: 7,
                    timestamp: 3,
                    clickCount: 2
                ),
                owner: owner
            ),
            .posted
        )
        XCTAssertEqual(coordinator.releaseAll(for: owner).releasedControlCount, 1)
        XCTAssertEqual(timeline.values.last, "syntheticMouseUp:left:5.0:7.0")
    }

    func testSyntheticReleaseFailureIsObservableAndStillIdempotent() {
        let timeline = TimelineBox()
        let coordinator = makeCoordinator(
            timeline: timeline,
            postKeyboardRelease: { keyCode in
                timeline.values.append("failedSyntheticKeyUp:\(keyCode)")
                return false
            }
        )
        let owner = makeOwner()
        XCTAssertEqual(coordinator.postKeyboardEvent(key(.keyDown, 0), owner: owner), .posted)

        let release = coordinator.releaseAll(for: owner)

        XCTAssertEqual(release.failedReleaseCount, 1)
        XCTAssertEqual(release.releasedControlCount, 0)
        XCTAssertEqual(coordinator.releaseAll(for: owner), emptyReleaseResult)
        XCTAssertEqual(timeline.values.last, "failedSyntheticKeyUp:0")
    }

    func testPointerMotionUsesNativeDragTypeForMostRecentlyPressedButton() {
        let timeline = TimelineBox()
        let coordinator = makeCoordinator(timeline: timeline)
        let owner = makeOwner()

        XCTAssertEqual(coordinator.postMouseEvent(mouse(.mouseMoved), owner: owner), .posted)
        XCTAssertEqual(coordinator.postMouseEvent(mouse(.leftMouseDown), owner: owner), .posted)
        XCTAssertEqual(coordinator.postMouseEvent(mouse(.mouseMoved), owner: owner), .posted)
        XCTAssertEqual(coordinator.postMouseEvent(mouse(.rightMouseDown), owner: owner), .posted)
        XCTAssertEqual(coordinator.postMouseEvent(mouse(.mouseMoved), owner: owner), .posted)
        XCTAssertEqual(coordinator.postMouseEvent(mouse(.rightMouseUp), owner: owner), .posted)
        XCTAssertEqual(coordinator.postMouseEvent(mouse(.mouseMoved), owner: owner), .posted)

        XCTAssertEqual(
            timeline.values,
            [
                "mouse:mouseMoved:plain",
                "mouse:leftMouseDown:plain",
                "mouse:mouseMoved:drag-left",
                "mouse:rightMouseDown:plain",
                "mouse:mouseMoved:drag-right",
                "mouse:rightMouseUp:plain",
                "mouse:mouseMoved:drag-left",
            ]
        )
        XCTAssertEqual(coordinator.releaseAll(for: owner).releasedControlCount, 1)
    }

    func testPointerMotionEventTypeMatchesCoreGraphicsDragSemantics() {
        XCTAssertEqual(
            RemoteControlInputEventInjector.pointerMotionEventType(draggingButton: nil),
            .mouseMoved
        )
        XCTAssertEqual(
            RemoteControlInputEventInjector.pointerMotionEventType(draggingButton: .left),
            .leftMouseDragged
        )
        XCTAssertEqual(
            RemoteControlInputEventInjector.pointerMotionEventType(draggingButton: .right),
            .rightMouseDragged
        )
    }

    private var emptyReleaseResult: RemoteControlInputReleaseResult {
        RemoteControlInputReleaseResult(
            trackedMouseButtonCount: 0,
            trackedKeyCount: 0,
            releasedControlCount: 0,
            failedReleaseCount: 0,
            skippedForMissingPermission: false
        )
    }

    private func makeOwner(
        transport: RemoteControlInputOwner.Transport = .p2p,
        sessionID: String = "session"
    ) -> RemoteControlInputOwner {
        RemoteControlInputOwner(
            transport: transport,
            sessionID: sessionID,
            generation: UUID()
        )
    }

    private func mouse(_ type: MouseEventType) -> RemoteMouseEvent {
        RemoteMouseEvent(type: type, x: 5, y: 7, timestamp: 3)
    }

    private func key(_ type: KeyboardEventType, _ keyCode: Int) -> RemoteKeyboardEvent {
        RemoteKeyboardEvent(type: type, keyCode: keyCode, timestamp: 3)
    }

    private func makeCoordinator(
        timeline: TimelineBox,
        ensureAccessibilityPermission: @escaping () -> Bool = { true },
        hasAccessibilityPermission: @escaping () -> Bool = { true },
        currentPointerLocation: @escaping () -> CGPoint? = { CGPoint(x: 20, y: 30) },
        postKeyboardEvent: ((RemoteKeyboardEvent) -> Bool)? = nil,
        postKeyboardRelease: ((Int) -> Bool)? = nil
    ) -> RemoteControlInputLifecycleCoordinator {
        let coordinator = RemoteControlInputLifecycleCoordinator(
            ensureAccessibilityPermission: ensureAccessibilityPermission,
            hasAccessibilityPermission: hasAccessibilityPermission,
            mouseInjectionPoint: { CGPoint(x: $0.x, y: $0.y) },
            postMouseEvent: { event, draggingButton in
                let dragDescription: String
                switch draggingButton {
                case .left:
                    dragDescription = "drag-left"
                case .right:
                    dragDescription = "drag-right"
                case nil:
                    dragDescription = "plain"
                }
                timeline.values.append("mouse:\(event.type.rawValue):\(dragDescription)")
                return true
            },
            postKeyboardEvent: postKeyboardEvent ?? { event in
                timeline.values.append("key:\(event.type.rawValue):\(event.keyCode)")
                return true
            },
            currentPointerLocation: currentPointerLocation,
            postMouseButtonRelease: { button, point, _ in
                timeline.values.append(
                    "syntheticMouseUp:\(button == .left ? "left" : "right"):\(point.x):\(point.y)"
                )
                return true
            },
            postKeyboardRelease: postKeyboardRelease ?? { keyCode in
                timeline.values.append("syntheticKeyUp:\(keyCode)")
                return true
            }
        )
        return coordinator
    }
}

private final class TimelineBox {
    var values: [String]

    init(_ values: [String] = []) {
        self.values = values
    }
}
#endif
