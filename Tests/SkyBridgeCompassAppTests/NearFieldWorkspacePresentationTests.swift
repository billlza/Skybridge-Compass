import AppKit
import Combine
import Network
import SwiftUI
import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore
@testable import SkyBridgeCompassApp

@MainActor
final class NearFieldWorkspacePresentationTests: XCTestCase {
    private struct RebuildingParent: View {
        let revision: Int
        let makeModel: @MainActor () -> NearFieldWorkspaceViewModel

        var body: some View {
            VStack {
                Text("Revision \(revision)")
                NearFieldMirrorView(model: makeModel())
            }
        }
    }

    func testParentRepaintRetainsOneDiscoveryModelForTheWindow() async throws {
        _ = NSApplication.shared
        var models: [NearFieldWorkspaceViewModel] = []
        let workspace = ControlledHostWorkspace(concurrentHostLimit: 2) { PresentationEngine() }
        let makeModel: @MainActor () -> NearFieldWorkspaceViewModel = {
            let discovery = DeviceDiscoveryManagerOptimized()
            discovery.enableBonjourDiscovery = false
            let model = NearFieldWorkspaceViewModel(discoveryManager: discovery, workspace: workspace)
            models.append(model)
            return model
        }
        defer { models.forEach { $0.close() } }
        let host = NSHostingView(rootView: RebuildingParent(revision: 0, makeModel: makeModel))
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(models.count, 1)

        for revision in 1...3 {
            host.rootView = RebuildingParent(revision: revision, makeModel: makeModel)
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            XCTAssertEqual(models.count, 1, "A parent repaint must not construct an unused discovery manager or observe a different model")
        }
    }

    private final class PresentationEngine: ControlledHostSessionEngine {
        let manager = RemoteControlManager(controlledHostStreamTier: .background)
        var remoteControlManager: RemoteControlManager? { manager }
        let errors = CurrentValueSubject<String?, Never>(nil)
        var failurePublisher: AnyPublisher<String?, Never> { errors.eraseToAnyPublisher() }
        let inputAccess = CurrentValueSubject<RemoteControlAccessTracker, Never>(RemoteControlAccessTracker())
        var viewerInputAccess: RemoteControlAccessTracker { inputAccess.value }
        var inputAccessPublisher: AnyPublisher<RemoteControlAccessTracker, Never> { inputAccess.eraseToAnyPublisher() }
        var sentKeys: [Int] = []
        var stopCount = 0
        func startControlledHostSession(device: DiscoveredDevice, connection: NWConnection) async throws -> String {
            var access = inputAccess.value
            try access.accept(nil)
            inputAccess.send(access)
            return RemoteControlManager.controlPeerIdentifier(for: device)
        }
        func setControlledHostStreamTier(_ tier: ControlledHostSessionPolicy.StreamTier, deviceId: String) async throws {}
        func sendMouseEvent(_ event: RemoteMouseEvent, to deviceId: String, inputControlLease: UUID?) async throws {}
        func sendKeyboardEvent(_ event: RemoteKeyboardEvent, to deviceId: String, inputControlLease: UUID?) async throws {
            sentKeys.append(event.keyCode)
        }
        func stopControlling(deviceId: String) { stopCount += 1 }
    }

    func testLateCanvasReleasesDoNotTargetNewHostOrSurfaceAFalseFailure() async throws {
        let first = PresentationEngine()
        let second = PresentationEngine()
        var engines = [first, second]
        let workspace = ControlledHostWorkspace(concurrentHostLimit: 2) { engines.removeFirst() }
        let model = NearFieldWorkspaceViewModel(workspace: workspace)
        defer { workspace.stopAll() }
        try await connect("a", named: "办公 Mac", to: workspace)
        try await connect("b", named: "测试 Mac", to: workspace)

        model.submitKeyboardEvent(RemoteKeyboardEvent(type: .keyUp, keyCode: 56, timestamp: 1), to: "a")
        model.submitMouseEvent(RemoteMouseEvent(type: .leftMouseUp, x: 10, y: 10, timestamp: 1), to: "a")
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(second.sentKeys.isEmpty)

        model.submitKeyboardEvent(RemoteKeyboardEvent(type: .keyDown, keyCode: 0, timestamp: 2), to: "a")
        XCTAssertNotNil(model.errorMessage, "An actual background input request must still be rejected visibly")
        XCTAssertTrue(first.sentKeys.isEmpty)
        XCTAssertTrue(second.sentKeys.isEmpty)
    }

    func testClosingWindowRetiresEveryWorkspaceSession() async throws {
        let first = PresentationEngine()
        let second = PresentationEngine()
        var engines = [first, second]
        let workspace = ControlledHostWorkspace(concurrentHostLimit: 2) { engines.removeFirst() }
        let model = NearFieldWorkspaceViewModel(workspace: workspace)
        try await connect("a", named: "办公 Mac", to: workspace)
        try await connect("b", named: "测试 Mac", to: workspace)
        model.showsDevicePicker = false

        model.close()

        XCTAssertTrue(workspace.sessions.isEmpty)
        XCTAssertNil(workspace.focusedSessionId)
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(second.stopCount, 1)
        XCTAssertTrue(model.showsDevicePicker)
    }

    func testTwoSessionPickerRendersAtMinimumAndDefaultWindowSizes() async throws {
        _ = NSApplication.shared
        let first = PresentationEngine()
        let second = PresentationEngine()
        var engines = [first, second]
        let workspace = ControlledHostWorkspace(concurrentHostLimit: 2) { engines.removeFirst() }
        defer { workspace.stopAll() }
        try await connect("a", named: "办公 Mac · MacBook Pro", to: workspace)
        try await connect("b", named: "测试 Mac · Mac mini", to: workspace)
        let model = NearFieldWorkspaceViewModel(workspace: workspace)

        for size in [CGSize(width: 800, height: 600), CGSize(width: 1000, height: 700)] {
            let content = NearFieldMirrorContent(model: model).workspaceContent
                .environment(\.colorScheme, .dark)
                .frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: content)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
            XCTAssertEqual(host.bounds.size, size)
            XCTAssertEqual(workspace.sessions.count, 2, "Rendering the picker must retain both connections")
            if let directory = ProcessInfo.processInfo.environment["SKYBRIDGE_UI_TEST_ARTIFACT_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: url.appendingPathComponent("multihost-picker-\(Int(size.width)).png"))
            }
        }
    }

    private func connect(_ id: String, named name: String, to workspace: ControlledHostWorkspace) async throws {
        let device = DiscoveredDevice(
            id: UUID(), name: name, ipv4: nil, ipv6: nil, services: [], portMap: [:], deviceId: id
        )
        try await workspace.connect(to: device) {
            let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
            return ControlledHostConnection(connection: connection, onAbandon: { connection.cancel() })
        }
    }
}
