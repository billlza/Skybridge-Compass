import Foundation
import XCTest
import SkyBridgeProtocolCore
import AppKit
@testable import SkyBridgeCore
@testable import SkyBridgeUI

final class RemoteControlAccessTests: XCTestCase {
    func testManagedAccessRequiresReceiptAndRejectsOldOrConflictingGrants() throws {
        var tracker = RemoteControlAccessTracker()
        XCTAssertFalse(tracker.canSendInput)
        let original = try RemoteControlAccess(revision: 1, role: .controller, lease: UUID())
        XCTAssertTrue(try tracker.accept(original))
        XCTAssertTrue(tracker.canSendInput)
        let observer = try RemoteControlAccess(revision: 2, role: .observer, lease: nil)
        XCTAssertTrue(try tracker.accept(observer))
        XCTAssertFalse(tracker.canSendInput)
        XCTAssertFalse(try tracker.accept(original))
        XCTAssertEqual(tracker.access, observer)
        XCTAssertFalse(try tracker.accept(observer))
        XCTAssertThrowsError(try tracker.accept(.init(revision: 2, role: .controller, lease: UUID())))
        XCTAssertThrowsError(try tracker.accept(nil))
        XCTAssertEqual(tracker.access, observer)
    }

    func testLegacyModeIsSelectedOnlyByFirstReceipt() throws {
        var tracker = RemoteControlAccessTracker()
        XCTAssertTrue(try tracker.accept(nil))
        XCTAssertTrue(tracker.canSendInput)
        XCTAssertNil(tracker.access)
        XCTAssertThrowsError(try tracker.accept(.init(revision: 1, role: .observer, lease: nil)))
        XCTAssertTrue(tracker.canSendInput)
    }

    func testDecodedGrantValidatesVersionRevisionAndRoleLeaseCombination() throws {
        let invalid = [
            #"{"version":2,"revision":1,"role":"observer"}"#,
            #"{"version":1,"revision":0,"role":"observer"}"#,
            #"{"version":1,"revision":9223372036854775808,"role":"observer"}"#,
            #"{"version":1,"revision":1,"role":"controller"}"#,
            #"{"version":1,"revision":1,"role":"observer","lease":"F47AC10B-58CC-4372-A567-0E02B2C3D479"}"#
        ]
        for payload in invalid {
            XCTAssertThrowsError(try JSONDecoder().decode(RemoteControlAccess.self, from: Data(payload.utf8)))
        }
        let value = try RemoteControlAccess(revision: 3, role: .controller, lease: UUID())
        XCTAssertEqual(try JSONDecoder().decode(RemoteControlAccess.self, from: JSONEncoder().encode(value)), value)
    }
}

@MainActor
final class RemoteControlHostAuthorizationTests: XCTestCase {
    func testTwoViewerHostPanelRendersObserverAndTransferControls() async throws {
        _ = NSApplication.shared
        let center = RemoteControlSecurityNoticeCenter.shared
        let panel = RemoteControlSecurityNoticePanelController.shared
        panel.stop()
        center.closeAllNoticesFailClosed()
        defer { panel.stop(); center.closeAllNoticesFailClosed() }
        let first = descriptor("Office iPad")
        let second = descriptor("iPhone")
        try await approve(first, center: center)
        try await approve(second, center: center)
        panel.start()
        center.selectNotice(id: second.id)
        await waitUntil { panel.renderedNoticeIDForTesting == second.id }
        let content = try XCTUnwrap(panel.contentViewForTesting)
        content.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        XCTAssertEqual(center.notices.count, 2)
        XCTAssertTrue(center.canTransferInputControl(to: second.id))
        if let directory = ProcessInfo.processInfo.environment["SKYBRIDGE_UI_TEST_ARTIFACT_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: url.appendingPathComponent("host-two-viewers.png"))
        }
    }

    func testTwoApprovedViewersKeepOneControllerAndTransferOnlyAfterReleaseReceipt() async throws {
        let center = RemoteControlSecurityNoticeCenter()
        let receipt = ReceiptGate()
        var timeline: [String] = []
        let first = descriptor("first")
        let second = descriptor("second")
        try await approve(first, center: center, release: { timeline.append("release-first") }, publish: { access in
            timeline.append("first-\(access.role.rawValue)")
            await receipt.wait()
        })
        try await approve(second, center: center, release: { timeline.append("release-second") }, publish: { access in
            timeline.append("second-\(access.role.rawValue)")
        })
        let oldLease = try XCTUnwrap(center.controlAccess(for: first.id)?.lease)
        XCTAssertEqual(center.notices.count, 2)
        XCTAssertEqual(center.inputControllerNoticeID, first.id)
        XCTAssertFalse(center.permitsInput(noticeID: second.id, lease: oldLease))
        let transfer = Task { await center.transferInputControl(to: second.id) }
        await waitUntil { receipt.isWaiting }
        XCTAssertEqual(timeline, ["release-first", "first-observer"])
        XCTAssertNil(center.inputControllerNoticeID)
        XCTAssertFalse(center.permitsInput(noticeID: first.id, lease: oldLease))
        XCTAssertFalse(center.permitsInput(noticeID: second.id, lease: nil))
        receipt.open()
        await transfer.value
        XCTAssertEqual(center.inputControllerNoticeID, second.id)
        let newLease = try XCTUnwrap(center.controlAccess(for: second.id)?.lease)
        XCTAssertTrue(center.permitsInput(noticeID: second.id, lease: newLease))
        XCTAssertEqual(timeline.last, "second-controller")
        await center.transferInputControl(to: first.id)
        let renewedLease = try XCTUnwrap(center.controlAccess(for: first.id)?.lease)
        XCTAssertNotEqual(renewedLease, oldLease)
        XCTAssertFalse(center.permitsInput(noticeID: first.id, lease: oldLease))
        center.closeAllNoticesFailClosed()
    }

    func testFailedReleaseDoesNotGrantTargetAndSurfacesFailure() async throws {
        let center = RemoteControlSecurityNoticeCenter()
        let first = descriptor("first")
        let second = descriptor("second")
        try await approve(first, center: center, release: { throw ControlledHostSessionError.inputReleaseFailed })
        var targetGrants = 0
        try await approve(second, center: center, publish: { access in
            if access.role == .controller { targetGrants += 1 }
        })
        await center.transferInputControl(to: second.id)
        XCTAssertEqual(targetGrants, 0)
        XCTAssertNil(center.inputControllerNoticeID)
        XCTAssertNotNil(center.controlHandoffError)
        XCTAssertEqual(center.notices.map(\.id), [second.id])
        XCTAssertEqual(center.controlAccess(for: second.id)?.role, .observer)
        center.closeAllNoticesFailClosed()
    }

    func testRemovedHandoffTargetCannotBeResurrectedByDelayedReceipt() async throws {
        let center = RemoteControlSecurityNoticeCenter()
        let receipt = ReceiptGate()
        let first = descriptor("first")
        let second = descriptor("second")
        try await approve(first, center: center, publish: { _ in await receipt.wait() })
        try await approve(second, center: center)
        let transfer = Task { await center.transferInputControl(to: second.id) }
        await waitUntil { receipt.isWaiting }
        center.endNotice(id: second.id)
        receipt.open()
        await transfer.value
        XCTAssertNil(center.inputControllerNoticeID)
        XCTAssertNil(center.controlAccess(for: second.id))
        XCTAssertFalse(center.notices.contains { $0.id == second.id })
    }

    func testOldOwnerFailureCannotCleanUpALaterSuccessfulHandoff() async throws {
        let center = RemoteControlSecurityNoticeCenter()
        let receipt = ReceiptGate()
        let first = descriptor("first")
        let second = descriptor("second")
        var secondDisconnects = 0
        try await approve(first, center: center, publish: { _ in
            await receipt.wait()
            throw ControlledHostSessionError.inputControlDeliveryTimedOut
        })
        try await approve(second, center: center)
        center.setDisconnectHandler(for: second.id) { secondDisconnects += 1 }
        let interruptedTransfer = Task { await center.transferInputControl(to: second.id) }
        await waitUntil { receipt.isWaiting }
        center.endNotice(id: first.id)
        XCTAssertTrue(center.isTransferringControl)
        XCTAssertFalse(center.canTransferInputControl(to: second.id))
        await center.transferInputControl(to: second.id)
        XCTAssertNil(center.inputControllerNoticeID)
        receipt.open()
        await interruptedTransfer.value
        XCTAssertEqual(secondDisconnects, 0)
        XCTAssertEqual(center.controlAccess(for: second.id)?.role, .observer)
        XCTAssertTrue(center.canTransferInputControl(to: second.id))
        await center.transferInputControl(to: second.id)
        XCTAssertEqual(center.inputControllerNoticeID, second.id)
        XCTAssertEqual(secondDisconnects, 0)
        XCTAssertNil(center.controlHandoffError)
        center.closeAllNoticesFailClosed()
    }

    func testLegacyRequestCannotEvictPendingApprovalOrJoinManagedViewer() async throws {
        let center = RemoteControlSecurityNoticeCenter()
        let pending = descriptor("pending")
        let request = Task { await center.requestApproval(pending) }
        await waitUntil { center.currentNotice?.id == pending.id }
        let competing = await center.requestApproval(descriptor("competing"))
        XCTAssertEqual(competing, .rejected)
        XCTAssertEqual(center.currentNotice?.id, pending.id)
        center.rejectNotice(id: pending.id)
        let result = await request.value
        XCTAssertEqual(result, .rejected)
        try await approve(descriptor("managed"), center: center)
        let legacy = await center.requestApproval(descriptor("legacy"))
        XCTAssertEqual(legacy, .rejected)
        XCTAssertEqual(center.notices.count, 1)
        center.closeAllNoticesFailClosed()
    }

    func testOldIncarnationCannotReuseApprovalOrEndReplacement() async throws {
        let center = RemoteControlSecurityNoticeCenter()
        let first = descriptor("same")
        try await approve(first, center: center)
        let replacement = descriptor("same")
        let competing = await center.requestApproval(replacement)
        XCTAssertEqual(competing, .rejected)
        XCTAssertEqual(center.inputControllerNoticeID, first.id)
        center.endNotice(id: first.id)
        try await approve(replacement, center: center)
        center.endNotice(id: first.id)
        XCTAssertEqual(center.inputControllerNoticeID, replacement.id)
        center.closeAllNoticesFailClosed()
    }

    private func approve(
        _ descriptor: RemoteControlSecurityDescriptor,
        center: RemoteControlSecurityNoticeCenter,
        release: @escaping @MainActor () throws -> Void = {},
        publish: @escaping @MainActor (RemoteControlAccess) async throws -> Void = { _ in }
    ) async throws {
        try center.registerSharedControl(for: descriptor.id, releaseInput: release, publishAccess: publish)
        let request = Task { await center.requestApproval(descriptor) }
        await waitUntil { center.notices.contains { $0.id == descriptor.id } }
        center.approveNotice(id: descriptor.id)
        let result = await request.value
        XCTAssertEqual(result, .approved)
        center.markControlReady(for: descriptor.id)
    }

    private func descriptor(_ id: String) -> RemoteControlSecurityDescriptor {
        RemoteControlSecurityDescriptor(
            sessionId: id,
            sessionEvidenceReference: P2PEvidenceReference.sessionIncarnation(
                sessionID: UUID().uuidString, transcriptHash: Data(repeating: 1, count: 32)
            ),
            transportKind: .p2p,
            remoteIPAddress: "192.0.2.10", remoteDeviceId: id, remoteDeviceName: id,
            remoteAccountDisplayName: "viewer@example.com", remoteNebulaId: "viewer",
            localAccountDisplayName: "host@example.com", localNebulaId: "host", cryptoSuite: "X-Wing PQC"
        )
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    @MainActor
    private final class ReceiptGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false
        var isWaiting: Bool { continuation != nil }
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }
}
