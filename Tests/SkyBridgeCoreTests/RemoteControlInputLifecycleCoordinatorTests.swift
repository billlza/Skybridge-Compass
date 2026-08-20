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

    func testMissingMappingRejectsMouseAndKeyboardBeforePermissionOrPosting() {
        let timeline = TimelineBox()
        var permissionPromptCount = 0
        let coordinator = makeCoordinator(
            timeline: timeline,
            ensureAccessibilityPermission: {
                permissionPromptCount += 1
                return true
            },
            resolveInjectionMapping: { _ in .missing }
        )
        let owner = makeOwner()

        XCTAssertEqual(
            coordinator.postMouseEvent(mouse(.leftMouseDown), owner: owner),
            .mappingUnavailable
        )
        XCTAssertEqual(
            coordinator.postKeyboardEvent(key(.keyDown, 0), owner: owner),
            .mappingUnavailable
        )
        XCTAssertEqual(permissionPromptCount, 0)
        XCTAssertTrue(timeline.values.isEmpty)
    }

    func testTrackedMouseUpDuringMappingGapPostsSyntheticReleaseAndClearsTracking() {
        let timeline = TimelineBox()
        var permissionPromptCount = 0
        var mappingAvailable = true
        let coordinator = makeCoordinator(
            timeline: timeline,
            ensureAccessibilityPermission: {
                permissionPromptCount += 1
                return true
            },
            resolveInjectionMapping: { _ in
                mappingAvailable
                    ? .available(
                        ResolvedRemoteControlInjectionMapping(
                            visibleSize: CGSize(width: 100, height: 100),
                            displayBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
                        )
                    )
                    : .missing
            }
        )
        let owner = makeOwner()

        XCTAssertEqual(coordinator.postMouseEvent(mouse(.leftMouseDown), owner: owner), .posted)
        // 采集重启窗口：旧流 stop() 已清映射、新映射尚未重新发布。
        mappingAvailable = false

        XCTAssertEqual(coordinator.postMouseEvent(mouse(.leftMouseUp), owner: owner), .posted)

        XCTAssertEqual(
            timeline.values,
            ["mouse:leftMouseDown:plain", "syntheticMouseUp:left:5.0:7.0"]
        )
        XCTAssertEqual(permissionPromptCount, 2)
        // 补发是一次性的：跟踪已清空，重复 up 按未跟踪释放拒绝。
        XCTAssertEqual(
            coordinator.postMouseEvent(mouse(.leftMouseUp), owner: owner),
            .untrackedRelease
        )
        // Down/位置事件在无映射时仍照常拒绝。
        XCTAssertEqual(
            coordinator.postMouseEvent(mouse(.leftMouseDown), owner: owner),
            .mappingUnavailable
        )
        XCTAssertEqual(
            coordinator.postMouseEvent(mouse(.mouseMoved), owner: owner),
            .mappingUnavailable
        )
        // 映射恢复后指针移动是普通移动而不是残留拖拽。
        mappingAvailable = true
        XCTAssertEqual(coordinator.postMouseEvent(mouse(.mouseMoved), owner: owner), .posted)
        XCTAssertEqual(timeline.values.last, "mouse:mouseMoved:plain")
        XCTAssertEqual(coordinator.releaseAll(for: owner), emptyReleaseResult)
    }

    func testTrackedReleaseDuringMappingGapUsesPressTimeGlobalInjectionPoint() {
        let timeline = TimelineBox()
        var mappingAvailable = true
        let coordinator = makeCoordinator(
            timeline: timeline,
            resolveInjectionMapping: { _ in
                mappingAvailable
                    ? .available(
                        ResolvedRemoteControlInjectionMapping(
                            visibleSize: CGSize(width: 100, height: 100),
                            displayBounds: CGRect(x: 100, y: 50, width: 50, height: 50)
                        )
                    )
                    : .missing
            }
        )
        let owner = makeOwner()

        XCTAssertEqual(coordinator.postMouseEvent(mouse(.rightMouseDown), owner: owner), .posted)
        mappingAvailable = false

        XCTAssertEqual(coordinator.postMouseEvent(mouse(.rightMouseUp), owner: owner), .posted)

        // 补发坐标 = 按下时已换算的全局注入点，而不是帧像素透传坐标。
        XCTAssertEqual(timeline.values.last, "syntheticMouseUp:right:102.5:53.5")
        XCTAssertEqual(coordinator.releaseAll(for: owner), emptyReleaseResult)
    }

    func testWrongMappingOwnerRejectsMouseAndKeyboardBeforePermissionOrPosting() {
        let timeline = TimelineBox()
        var permissionPromptCount = 0
        let coordinator = makeCoordinator(
            timeline: timeline,
            ensureAccessibilityPermission: {
                permissionPromptCount += 1
                return true
            },
            resolveInjectionMapping: { _ in .ownerConflict }
        )
        let owner = makeOwner()

        XCTAssertEqual(
            coordinator.postMouseEvent(mouse(.leftMouseDown), owner: owner),
            .ownerConflict
        )
        XCTAssertEqual(
            coordinator.postKeyboardEvent(key(.keyDown, 0), owner: owner),
            .ownerConflict
        )
        XCTAssertEqual(permissionPromptCount, 0)
        XCTAssertTrue(timeline.values.isEmpty)
    }

    func testInvalidDisplayRejectsMouseAndKeyboardBeforePermissionOrPosting() {
        let timeline = TimelineBox()
        var permissionPromptCount = 0
        let coordinator = makeCoordinator(
            timeline: timeline,
            ensureAccessibilityPermission: {
                permissionPromptCount += 1
                return true
            },
            resolveInjectionMapping: { _ in .invalidDisplay }
        )
        let owner = makeOwner()

        XCTAssertEqual(
            coordinator.postMouseEvent(mouse(.leftMouseDown), owner: owner),
            .invalidDisplay
        )
        XCTAssertEqual(
            coordinator.postKeyboardEvent(key(.keyDown, 0), owner: owner),
            .invalidDisplay
        )
        XCTAssertEqual(permissionPromptCount, 0)
        XCTAssertTrue(timeline.values.isEmpty)
    }

    func testOutOfFrameMouseCoordinatesRejectBeforePermissionOrPosting() {
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
        let outsideFrame = RemoteMouseEvent(
            type: .leftMouseDown,
            x: 101,
            y: 7,
            timestamp: 3
        )

        XCTAssertEqual(
            coordinator.postMouseEvent(outsideFrame, owner: owner),
            .invalidEvent
        )
        XCTAssertEqual(permissionPromptCount, 0)
        XCTAssertTrue(timeline.values.isEmpty)
    }

    func testStaleMappingLeaseCannotRemoveSameOwnerReplacement() {
        let owner = makeOwner(sessionID: "same")
        let wrongOwner = makeOwner(sessionID: "same")
        let staleMapping = RemoteControlInjectionMapping(
            displayID: 1,
            visibleSize: CGSize(width: 640, height: 480)
        )
        let replacementMapping = RemoteControlInjectionMapping(
            displayID: 2,
            visibleSize: CGSize(width: 1920, height: 1080)
        )
        let staleLease = RemoteControlInjectionMappingStore.publish(staleMapping, for: owner)
        let replacementLease = RemoteControlInjectionMappingStore.publish(
            replacementMapping,
            for: owner
        )
        defer { RemoteControlInjectionMappingStore.clear(replacementLease) }

        RemoteControlInjectionMappingStore.clear(staleLease)

        guard case .available(let retainedMapping) =
            RemoteControlInjectionMappingStore.snapshot(for: owner) else {
            return XCTFail("Stale capture lease removed the same-owner replacement mapping")
        }
        XCTAssertEqual(retainedMapping.displayID, replacementMapping.displayID)
        XCTAssertEqual(retainedMapping.visibleSize, replacementMapping.visibleSize)
        guard case .ownerConflict = RemoteControlInjectionMappingStore.snapshot(for: wrongOwner) else {
            return XCTFail("A different owner must not access the replacement mapping")
        }
    }

    func testJPEGFallbackPublishIfChangedReplacesOnlyOnRealChange() {
        let owner = makeOwner()
        let mapping = RemoteControlInjectionMapping(
            displayID: 7,
            visibleSize: CGSize(width: 3456, height: 2234)
        )

        guard let initialLease = RemoteControlInjectionMappingStore.publishIfChanged(
            mapping,
            for: owner
        ) else {
            return XCTFail("Empty store must accept the JPEG fallback mapping")
        }
        defer { RemoteControlInjectionMappingStore.clear(initialLease) }

        // 同 owner + 同映射：逐帧调用不产生新租约。
        XCTAssertNil(RemoteControlInjectionMappingStore.publishIfChanged(mapping, for: owner))
        guard case .available(let stored) =
            RemoteControlInjectionMappingStore.snapshot(for: owner) else {
            return XCTFail("Mapping must remain published for the same owner")
        }
        XCTAssertEqual(stored.displayID, mapping.displayID)
        XCTAssertEqual(stored.visibleSize, mapping.visibleSize)

        // 帧尺寸变化（显示器配置变更后的新输出）：原子替换并返回新租约。
        let resized = RemoteControlInjectionMapping(
            displayID: 7,
            visibleSize: CGSize(width: 1728, height: 1117)
        )
        guard let resizedLease = RemoteControlInjectionMappingStore.publishIfChanged(
            resized,
            for: owner
        ) else {
            return XCTFail("A changed frame size must republish the mapping")
        }
        defer { RemoteControlInjectionMappingStore.clear(resizedLease) }

        RemoteControlInjectionMappingStore.clear(initialLease)

        guard case .available(let retained) =
            RemoteControlInjectionMappingStore.snapshot(for: owner) else {
            return XCTFail("Stale JPEG lease must not remove the replacement mapping")
        }
        XCTAssertEqual(retained.visibleSize, resized.visibleSize)
    }

    func testJPEGFallbackRepublishesAfterSCKLeaseCleared() {
        let owner = makeOwner()
        let jpegMapping = RemoteControlInjectionMapping(
            displayID: 7,
            visibleSize: CGSize(width: 3456, height: 2234)
        )
        // SCK 硬编路径以同 owner、同内容发布（start()）时，JPEG 逐帧调用退化为 no-op。
        let sckLease = RemoteControlInjectionMappingStore.publish(jpegMapping, for: owner)
        XCTAssertNil(RemoteControlInjectionMappingStore.publishIfChanged(jpegMapping, for: owner))

        // 硬编→JPEG 回退切换：SCK stop() 清除映射后即使内容未变也必须重新发布，
        // 否则商店留空、观看端输入全部被 .mappingUnavailable 拒绝。
        RemoteControlInjectionMappingStore.clear(sckLease)
        guard let republished = RemoteControlInjectionMappingStore.publishIfChanged(
            jpegMapping,
            for: owner
        ) else {
            return XCTFail("JPEG fallback must republish after the SCK lease is cleared")
        }
        defer { RemoteControlInjectionMappingStore.clear(republished) }
        guard case .available = RemoteControlInjectionMappingStore.snapshot(for: owner) else {
            return XCTFail("Republished JPEG mapping must be visible to the owner")
        }
    }

    func testVisibleFrameCoordinatesUseHalfOpenPixelBoundsBeforePermission() {
        var permissionPromptCount = 0
        let coordinator = makeCoordinator(
            timeline: TimelineBox(),
            ensureAccessibilityPermission: {
                permissionPromptCount += 1
                return true
            }
        )
        let owner = makeOwner()

        XCTAssertEqual(
            coordinator.postMouseEvent(
                RemoteMouseEvent(type: .mouseMoved, x: 100, y: 99, timestamp: 3),
                owner: owner
            ),
            .invalidEvent
        )
        XCTAssertEqual(
            coordinator.postMouseEvent(
                RemoteMouseEvent(type: .mouseMoved, x: 99, y: 100, timestamp: 3),
                owner: owner
            ),
            .invalidEvent
        )
        XCTAssertEqual(permissionPromptCount, 0)
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
        resolveInjectionMapping: @escaping (RemoteControlInputOwner) -> RemoteControlInjectionMappingResolution = { _ in
            .available(
                ResolvedRemoteControlInjectionMapping(
                    visibleSize: CGSize(width: 100, height: 100),
                    displayBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
                )
            )
        },
        currentPointerLocation: @escaping () -> CGPoint? = { CGPoint(x: 20, y: 30) },
        postKeyboardEvent: ((RemoteKeyboardEvent) -> Bool)? = nil,
        postKeyboardRelease: ((Int) -> Bool)? = nil
    ) -> RemoteControlInputLifecycleCoordinator {
        let coordinator = RemoteControlInputLifecycleCoordinator(
            ensureAccessibilityPermission: ensureAccessibilityPermission,
            hasAccessibilityPermission: hasAccessibilityPermission,
            resolveInjectionMapping: resolveInjectionMapping,
            postMouseEvent: { event, _, draggingButton in
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
