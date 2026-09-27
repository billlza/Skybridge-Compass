#if os(macOS)
import CoreGraphics
import XCTest
@testable import SkyBridgeCore

final class RemoteControlInjectionMappingOwnershipTests: XCTestCase {
    func testIndependentViewerCaptureGeometrySurvivesOtherCaptureReplacementAndStop() throws {
        let first = owner("first", transport: .p2p)
        let second = owner("second", transport: .webRTC)
        let firstMapping = RemoteControlInjectionMapping(displayID: 1, visibleSize: CGSize(width: 800, height: 600))
        let secondMapping = RemoteControlInjectionMapping(displayID: 2, visibleSize: CGSize(width: 1920, height: 1080))
        let firstLease = RemoteControlInjectionMappingStore.publish(firstMapping, for: first)
        let secondLease = RemoteControlInjectionMappingStore.publish(secondMapping, for: second)
        defer {
            RemoteControlInjectionMappingStore.clear(firstLease)
            RemoteControlInjectionMappingStore.clear(secondLease)
        }
        assertMapping(first, displayID: 1, size: firstMapping.visibleSize)
        assertMapping(second, displayID: 2, size: secondMapping.visibleSize)

        let replacement = RemoteControlInjectionMapping(displayID: 3, visibleSize: CGSize(width: 1280, height: 720))
        let replacementLease = try XCTUnwrap(RemoteControlInjectionMappingStore.publishIfChanged(replacement, for: first))
        defer { RemoteControlInjectionMappingStore.clear(replacementLease) }
        RemoteControlInjectionMappingStore.clear(firstLease)
        assertMapping(first, displayID: 3, size: replacement.visibleSize)
        assertMapping(second, displayID: 2, size: secondMapping.visibleSize)
        XCTAssertNil(RemoteControlInjectionMappingStore.publishIfChanged(secondMapping, for: second))

        RemoteControlInjectionMappingStore.clear(secondLease)
        assertMapping(first, displayID: 3, size: replacement.visibleSize)
    }

    func testSameHostReplacementGenerationCannotReadOrErasePreviousGeometry() {
        let previous = owner("same", transport: .p2p)
        let replacement = owner("same", transport: .p2p)
        let mapping = RemoteControlInjectionMapping(displayID: 4, visibleSize: CGSize(width: 640, height: 480))
        let lease = RemoteControlInjectionMappingStore.publish(mapping, for: previous)
        defer { RemoteControlInjectionMappingStore.clear(lease) }
        guard case .missing = RemoteControlInjectionMappingStore.snapshot(for: replacement) else {
            return XCTFail("An unknown generation must not inherit another generation's geometry")
        }
        assertMapping(previous, displayID: 4, size: mapping.visibleSize)
    }

    @MainActor
    func testControllerCaptureGapStillReleasesHeldInputWhileObserverMappingExists() {
        let controller = owner("controller", transport: .p2p)
        let observer = owner("observer", transport: .p2p)
        let mapping = RemoteControlInjectionMapping(displayID: 1, visibleSize: CGSize(width: 800, height: 600))
        let controllerLease = RemoteControlInjectionMappingStore.publish(mapping, for: controller)
        let observerLease = RemoteControlInjectionMappingStore.publish(mapping, for: observer)
        defer {
            RemoteControlInjectionMappingStore.clear(controllerLease)
            RemoteControlInjectionMappingStore.clear(observerLease)
        }
        var releasedKeys: [Int] = []
        var releasedButtons: [RemoteControlMouseButton] = []
        let coordinator = RemoteControlInputLifecycleCoordinator(
            ensureAccessibilityPermission: { true },
            hasAccessibilityPermission: { true },
            resolveInjectionMapping: { owner in
                switch RemoteControlInjectionMappingStore.snapshot(for: owner) {
                case .available(let mapping):
                    .available(ResolvedRemoteControlInjectionMapping(
                        visibleSize: mapping.visibleSize,
                        displayBounds: CGRect(origin: .zero, size: mapping.visibleSize)
                    ))
                case .missing:
                    .missing
                }
            },
            postMouseEvent: { _, _, _ in true },
            postKeyboardEvent: { _ in true },
            currentPointerLocation: { CGPoint(x: 10, y: 10) },
            postMouseButtonRelease: { button, _, _ in releasedButtons.append(button); return true },
            postKeyboardRelease: { code in releasedKeys.append(code); return true }
        )
        XCTAssertEqual(coordinator.postKeyboardEvent(.init(type: .keyDown, keyCode: 12, timestamp: 1), owner: controller), .posted)
        XCTAssertEqual(coordinator.postMouseEvent(.init(type: .leftMouseDown, x: 10, y: 10, timestamp: 1), owner: controller), .posted)
        RemoteControlInjectionMappingStore.clear(controllerLease)
        XCTAssertEqual(coordinator.postKeyboardEvent(.init(type: .keyUp, keyCode: 12, timestamp: 2), owner: controller), .posted)
        XCTAssertEqual(coordinator.postMouseEvent(.init(type: .leftMouseUp, x: 10, y: 10, timestamp: 2), owner: controller), .posted)
        XCTAssertEqual(releasedKeys, [12])
        XCTAssertEqual(releasedButtons, [.left])
        XCTAssertFalse(coordinator.releaseAll(for: controller).hadTrackedInput)
        assertMapping(observer, displayID: 1, size: mapping.visibleSize)
    }

    private func owner(_ sessionID: String, transport: RemoteControlInputOwner.Transport) -> RemoteControlInputOwner {
        RemoteControlInputOwner(transport: transport, sessionID: sessionID, generation: UUID())
    }

    private func assertMapping(
        _ owner: RemoteControlInputOwner,
        displayID: CGDirectDisplayID,
        size: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .available(let mapping) = RemoteControlInjectionMappingStore.snapshot(for: owner) else {
            return XCTFail("Expected the exact owner's mapping", file: file, line: line)
        }
        XCTAssertEqual(mapping.displayID, displayID, file: file, line: line)
        XCTAssertEqual(mapping.visibleSize, size, file: file, line: line)
    }
}
#endif
