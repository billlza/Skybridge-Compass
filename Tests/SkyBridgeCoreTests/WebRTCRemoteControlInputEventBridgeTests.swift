import XCTest
@testable import SkyBridgeCore

final class WebRTCRemoteControlInputEventBridgeTests: XCTestCase {
    func testMouseWireEventMapsToSharedRemoteControlInputEvent() {
        let wire = MouseEventWire(
            type: .rightMouseDown,
            x: 123.5,
            y: 456.25,
            timestamp: 789
        )

        let event = WebRTCRemoteControlInputEventBridge.remoteMouseEvent(from: wire)

        XCTAssertEqual(event?.type, .rightMouseDown)
        XCTAssertEqual(event?.x, 123.5)
        XCTAssertEqual(event?.y, 456.25)
        XCTAssertEqual(event?.timestamp, 789)
    }

    func testKeyboardWireEventMapsToSharedRemoteControlInputEvent() {
        let wire = KeyboardEventWire(
            type: .keyUp,
            keyCode: 36,
            timestamp: 111
        )

        let event = WebRTCRemoteControlInputEventBridge.remoteKeyboardEvent(from: wire)

        XCTAssertEqual(event?.type, .keyUp)
        XCTAssertEqual(event?.keyCode, 36)
        XCTAssertEqual(event?.timestamp, 111)
    }

    func testCrossNetworkManagerDoesNotOwnCGEventInjectionImplementation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"),
            encoding: .utf8
        )
        let bridgeSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCRemoteControlInputEventBridge.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(managerSource.contains("AXIsProcessTrusted"))
        XCTAssertFalse(managerSource.contains("cghidEventTap"))
        XCTAssertFalse(managerSource.contains("CGEvent(mouseEventSource:"))
        XCTAssertTrue(managerSource.contains("WebRTCRemoteControlInputEventBridge.handleMouseEvent("))
        XCTAssertTrue(managerSource.contains("WebRTCRemoteControlInputEventBridge.handleKeyboardEvent("))
        XCTAssertTrue(bridgeSource.contains("RemoteControlInputLifecycleCoordinator.shared.postMouseEvent("))
        XCTAssertTrue(bridgeSource.contains("RemoteControlInputLifecycleCoordinator.shared.postKeyboardEvent("))
        XCTAssertTrue(bridgeSource.contains("owner: RemoteControlInputOwner"))
    }

    func testSuccessfulRemoteInputPathsDoNotEmitPerEventLogs() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePaths = [
            "Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift",
            "Sources/SkyBridgeCompassApp/RemoteDisplayView.swift",
        ]
        let forbiddenLogMarkers = [
            "发送鼠标事件",
            "发送键盘事件",
            "处理远程鼠标事件",
            "处理远程键盘事件",
            "鼠标按下:",
            "鼠标释放:",
            "右键按下:",
            "右键释放:",
            "滚轮事件:",
            "按键按下:",
            "按键释放:",
            "修饰键变化:",
        ]

        for sourcePath in sourcePaths {
            let source = try String(
                contentsOf: root.appendingPathComponent(sourcePath),
                encoding: .utf8
            )
            for forbiddenMarker in forbiddenLogMarkers {
                XCTAssertFalse(
                    source.contains(forbiddenMarker),
                    "Remote input path logs each event via \(forbiddenMarker) in \(sourcePath)"
                )
            }
        }
    }

    func testP2PStopReleasesInputBeforeAcknowledgementCanSuspend() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift"
            ),
            encoding: .utf8
        )
        guard let applicationGeneration = source.range(
            of: "let applicationGeneration = peer.streamConfigurationApplicationGeneration"
        ), let release = source.range(
            of: "releaseRemoteInput(for: peer, reason: \"p2p_stream_stop\")",
            range: applicationGeneration.upperBound..<source.endIndex
        ), let acknowledgement = source.range(
            of: "guard try await sendStreamConfigurationAcknowledgement(",
            range: applicationGeneration.upperBound..<source.endIndex
        ) else {
            return XCTFail("P2P stop input-release ordering contract is missing")
        }

        XCTAssertLessThan(release.lowerBound, acknowledgement.lowerBound)
    }
}
