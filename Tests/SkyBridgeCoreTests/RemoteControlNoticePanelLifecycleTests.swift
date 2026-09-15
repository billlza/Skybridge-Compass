import AppKit
import XCTest
@_spi(RemoteControlSecurityNoticeUI) @testable import SkyBridgeCore
@testable import SkyBridgeUI

@MainActor
final class RemoteControlNoticePanelLifecycleTests: XCTestCase {
    func testRemovingBackgroundNoticeFinishesOnlyItsPresentation() async throws {
        let fixture = PanelFixture()
        defer { fixture.stop() }
        let controller = try await fixture.approve("controller")
        let observer = try await fixture.approve("observer")
        try await fixture.select(observer)
        let oldContent = try XCTUnwrap(fixture.panel.contentViewForTesting)
        fixture.onEvidence = { [weak fixture] line in
            guard controller.matches(line, event: "remoteControlNoticePanelHidden"), let fixture else { return }
            XCTAssertFalse(fixture.panel.contentViewForTesting === oldContent)
            XCTAssertEqual(fixture.panel.renderedNoticeIDForTesting, observer.descriptor.id)
        }

        fixture.center.disconnectNotice(id: controller.descriptor.id)
        try await fixture.waitForRetirement(controller)

        XCTAssertEqual(fixture.count("remoteControlNoticePanelHidden", for: observer), 0)
        XCTAssertEqual(fixture.center.notices.map(\.id), [observer.descriptor.id])
        XCTAssertEqual(fixture.center.controlAccess(for: observer.descriptor.id)?.role, .observer)
        XCTAssertNil(fixture.center.inputControllerNoticeID)
        XCTAssertFalse(fixture.center.permitsInput(noticeID: observer.descriptor.id, lease: nil))
        XCTAssertTrue(fixture.center.canTransferInputControl(to: observer.descriptor.id))
    }

    func testRemovingSelectedNoticeKeepsOtherControllerAndPanelAlive() async throws {
        let fixture = PanelFixture()
        defer { fixture.stop() }
        let controller = try await fixture.approve("controller")
        let observer = try await fixture.approve("observer")
        let originalAccess = try XCTUnwrap(fixture.center.controlAccess(for: controller.descriptor.id))
        try await fixture.select(observer)

        fixture.center.disconnectNotice(id: observer.descriptor.id)
        try await fixture.waitForRetirement(observer)

        XCTAssertEqual(fixture.panel.renderedNoticeIDForTesting, controller.descriptor.id)
        XCTAssertNotNil(fixture.panel.contentViewForTesting)
        XCTAssertEqual(fixture.count("remoteControlNoticePanelHidden", for: controller), 0)
        XCTAssertEqual(fixture.center.controlAccess(for: controller.descriptor.id), originalAccess)
        XCTAssertTrue(fixture.center.permitsInput(noticeID: controller.descriptor.id, lease: originalAccess.lease))
    }

    func testSelectingLiveNoticesDoesNotEndEitherPresentation() async throws {
        let fixture = PanelFixture()
        defer { fixture.stop() }
        let controller = try await fixture.approve("controller")
        let observer = try await fixture.approve("observer")
        for peer in [observer, controller, observer, controller] {
            try await fixture.select(peer)
        }
        for peer in [controller, observer] {
            XCTAssertEqual(fixture.count("remoteControlNoticePanelHidden", for: peer), 0)
            XCTAssertEqual(fixture.count("releaseSessionDisconnected", for: peer), 0)
            XCTAssertNotNil(fixture.center.controlAccess(for: peer.descriptor.id))
        }
        XCTAssertEqual(fixture.center.inputControllerNoticeID, controller.descriptor.id)
    }

    func testStopHidesEveryPresentedNoticeExactlyOnceAndRejectsQueuedRenders() async throws {
        let fixture = PanelFixture()
        defer { fixture.stop() }
        let first = try await fixture.approve("first")
        let second = try await fixture.approve("second")
        fixture.center.selectNotice(id: second.descriptor.id)

        fixture.panel.stop()
        fixture.panel.stop()
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(fixture.panel.hasPanelForTesting)
        XCTAssertFalse(fixture.panel.isStartedForTesting)
        XCTAssertTrue(fixture.center.notices.isEmpty)
        for peer in [first, second] {
            XCTAssertEqual(fixture.count("remoteControlNoticePanelHidden", for: peer), 1)
            XCTAssertEqual(fixture.count("releaseSessionDisconnected", for: peer), 1)
        }
    }

    func testRepeatedObserverRetirementDoesNotExhaustEvidenceCapacity() async throws {
        let fixture = PanelFixture()
        defer { fixture.stop() }
        let controller = try await fixture.approve("controller")
        let grant = fixture.center.controlAccess(for: controller.descriptor.id)
        for index in 0...ProductReleaseEvidenceRecorder.maximumRetainedSessionCount {
            let observer = try await fixture.approve("observer-\(index)")
            fixture.center.disconnectNotice(id: observer.descriptor.id)
            try await fixture.waitForRetirement(observer)
            XCTAssertEqual(fixture.count("remoteControlNoticePanelHidden", for: observer), 1)
            XCTAssertEqual(fixture.center.controlAccess(for: controller.descriptor.id), grant)
        }
        XCTAssertEqual(fixture.count("remoteControlNoticePanelHidden", for: controller), 0)
        XCTAssertEqual(fixture.center.notices.map(\.id), [controller.descriptor.id])
    }

    private struct Peer {
        let descriptor: RemoteControlSecurityDescriptor
        let owner: ProductReleaseEvidenceSessionOwner

        func matches(_ line: String, event: String) -> Bool {
            line.hasPrefix(event + " ")
                && line.contains("session_ref=\(owner.sessionReference) ")
                && line.contains("generation=\(owner.generation) ")
        }
    }

    @MainActor
    private final class PanelFixture {
        private var lines: [String] = []
        var onEvidence: ((String) -> Void)?
        private lazy var recorder = ProductReleaseEvidenceRecorder { [weak self] line in
            self?.lines.append(line)
            self?.onEvidence?(line)
        }
        lazy var center = RemoteControlSecurityNoticeCenter(productEvidenceRecorder: recorder)
        lazy var panel = RemoteControlSecurityNoticePanelController(center: center)

        init() {
            _ = NSApplication.shared
            panel.start()
        }

        func stop() {
            onEvidence = nil
            panel.stop()
        }

        func approve(_ name: String) async throws -> Peer {
            let sessionID = UUID().uuidString
            let reference = "ev1:" + sessionID.replacingOccurrences(of: "-", with: "").lowercased()
            let owner = try XCTUnwrap(recorder.beginSession(
                product: .macOSApp, transport: .p2p,
                sessionReference: reference, routeClass: .wifi
            ))
            let descriptor = RemoteControlSecurityDescriptor(
                sessionId: sessionID, sessionEvidenceReference: reference, transportKind: .p2p,
                remoteIPAddress: "192.0.2.20", remoteDeviceId: name, remoteDeviceName: name,
                remoteAccountDisplayName: "viewer@example.com", remoteNebulaId: "viewer",
                localAccountDisplayName: "host@example.com", localNebulaId: "host", cryptoSuite: "X-Wing PQC"
            )
            let peer = Peer(descriptor: descriptor, owner: owner)
            try center.registerSharedControl(for: descriptor.id, releaseInput: {}, publishAccess: { _ in })
            center.setDisconnectHandler(for: descriptor.id) { [recorder] in
                XCTAssertTrue(recorder.endSession(owner: owner, reason: .user))
            }
            let approval = Task { await center.requestApproval(descriptor) }
            try await waitUntil { self.count("remoteControlNoticePanelPresented", for: peer) == 1 }
            let pendingContent = try XCTUnwrap(panel.contentViewForTesting)
            center.approveNoticeFromUserInteraction(id: descriptor.id)
            let decision = await approval.value
            XCTAssertEqual(decision, .approved)
            center.markControlReady(for: descriptor.id)
            try await waitUntil { self.panel.contentViewForTesting !== pendingContent }
            return peer
        }

        func select(_ peer: Peer) async throws {
            center.selectNotice(id: peer.descriptor.id)
            try await waitUntil { self.panel.renderedNoticeIDForTesting == peer.descriptor.id }
        }

        func waitForRetirement(_ peer: Peer) async throws {
            try await waitUntil { self.count("releaseSessionDisconnected", for: peer) == 1 }
        }

        func count(_ event: String, for peer: Peer) -> Int {
            lines.filter { peer.matches($0, event: event) }.count
        }

        private func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(condition(), "The real panel did not complete the expected presentation transition.")
            guard condition() else { throw PanelWaitFailure.transitionTimedOut }
        }
    }

    private enum PanelWaitFailure: Error { case transitionTimedOut }
}
