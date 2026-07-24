import Foundation
import XCTest
@testable import SkyBridgeCore
@testable import SkyBridgeUI

final class LocalLanInteropHostApprovalSurfaceContractTests: XCTestCase {
    func testSignedSmokeHostPresentsReusableExplicitPIBApprovalSurface() throws {
        let mainSource = try readSource("Sources/LocalLanInteropHost/main.swift")
        let controllerSource = try readSource(
            "Sources/SkyBridgeUI/Security/PairingTrustApprovalWindowController.swift"
        )
        let remoteControlNoticeControllerSource = try readSource(
            "Sources/SkyBridgeUI/Security/RemoteControlSecurityNoticePanelController.swift"
        )
        let approvalViewSource = try readSource(
            "Sources/SkyBridgeUI/Security/PairingTrustApprovalView.swift"
        )
        let approvalServiceSource = try readSource(
            "Sources/SkyBridgeCore/Security/PairingTrustApprovalService.swift"
        )
        let remoteControlNoticeSource = try readSource(
            "Sources/SkyBridgeCore/RemoteControl/RemoteControlSecurityNotice.swift"
        )
        let packageSource = try readSource("Package.swift")

        XCTAssertTrue(packageSource.contains("\"SkyBridgeSmokeSupport\",\n                \"SkyBridgeUI\""))
        XCTAssertTrue(mainSource.contains("if application.activationPolicy() != .regular"))
        XCTAssertTrue(mainSource.contains("_ = application.setActivationPolicy(.regular)"))
        XCTAssertTrue(mainSource.contains("guard application.activationPolicy() == .regular else"))
        XCTAssertFalse(mainSource.contains("guard application.setActivationPolicy(.regular) else"))
        XCTAssertTrue(mainSource.contains("approvalWindowController.start()"))
        XCTAssertTrue(
            mainSource.contains(
                "LocalLanInteropHostLifetime.pairingTrustApprovalWindowController = approvalWindowController"
            ),
            "The helper must retain its approval presenter for the whole listener lifetime."
        )
        XCTAssertTrue(mainSource.contains("remoteControlSecurityNoticePanelController.start()"))
        XCTAssertTrue(
            mainSource.contains(
                "LocalLanInteropHostLifetime.remoteControlSecurityNoticePanelController =\n                remoteControlSecurityNoticePanelController"
            ),
            "The helper must retain its remote-control notice presenter for the whole listener lifetime."
        )
        XCTAssertTrue(
            remoteControlNoticeControllerSource.contains(
                "public final class RemoteControlSecurityNoticePanelController"
            )
        )
        XCTAssertTrue(remoteControlNoticeControllerSource.contains("public func start()"))
        XCTAssertTrue(remoteControlNoticeControllerSource.contains("public func stop()"))
        XCTAssertTrue(remoteControlNoticeControllerSource.contains("guard cancellable != nil else { return }"))
        XCTAssertTrue(remoteControlNoticeControllerSource.contains("lifecycleGeneration &+= 1"))
        XCTAssertTrue(remoteControlNoticeControllerSource.contains("self.lifecycleGeneration == subscribedGeneration"))
        XCTAssertTrue(
            remoteControlNoticeControllerSource.contains(
                "RemoteControlSecurityNoticeCenter.shared.currentNotice == notice"
            ),
            "Queued publisher deliveries must not render an older notice over a replacement request."
        )
        XCTAssertTrue(remoteControlNoticeControllerSource.contains("cancellable?.cancel()"))
        XCTAssertTrue(
            remoteControlNoticeControllerSource.contains(
                "RemoteControlSecurityNoticeCenter.shared.closeCurrentNoticeFailClosed()"
            ),
            "Stopping the helper presenter must reject pending approval or disconnect active control."
        )
        XCTAssertTrue(
            remoteControlNoticeControllerSource.contains("recordPanelPresentedEvidence("),
            "The host's reusable panel must emit the same presentation evidence as the packaged app."
        )
        XCTAssertTrue(
            remoteControlNoticeSource.contains("remoteControlNoticePanelPresented"),
            "A visible LocalLanInteropHost notice must remain observable in release artifacts."
        )
        XCTAssertTrue(mainSource.contains("LocalLanInteropHostLifetime.stopApprovalPresentation()"))
        XCTAssertTrue(mainSource.contains("remoteControlSecurityNoticePanelController?.stop()"))
        XCTAssertTrue(mainSource.contains("pairingTrustApprovalWindowController?.stop()"))
        XCTAssertTrue(
            remoteControlNoticeControllerSource.contains(
                "approveNoticeFromUserInteraction(id: notice.id)"
            ),
            "The visible panel must use the user-interaction-only approval entry point."
        )
        XCTAssertFalse(
            remoteControlNoticeControllerSource.contains("approveNotice(id: notice.id)"),
            "The panel must not bypass the HumanApproved evidence boundary."
        )
        XCTAssertTrue(remoteControlNoticeControllerSource.contains("rejectNotice(id: notice.id)"))
        XCTAssertTrue(remoteControlNoticeControllerSource.contains("closeNoticeFailClosed(id: notice.id)"))
        XCTAssertTrue(remoteControlNoticeControllerSource.contains("disconnectNotice(id: notice.id)"))

        XCTAssertTrue(controllerSource.contains("PairingTrustApprovalSheet("))
        XCTAssertTrue(controllerSource.contains("approvalService.resolve(request, decision: decision)"))
        XCTAssertTrue(controllerSource.contains("approvalService.userDismissedCurrentPrompt()"))
        XCTAssertTrue(controllerSource.contains("NSRunningApplication.current.activate"))
        XCTAssertTrue(controllerSource.contains("public func stop()"))
        XCTAssertFalse(controllerSource.localizedCaseInsensitiveContains("autoApprove"))
        XCTAssertFalse(controllerSource.contains("decision: .allowOnce)"))
        XCTAssertFalse(controllerSource.contains("decision: .alwaysAllow)"))

        XCTAssertTrue(approvalViewSource.contains("service.pendingVerificationCode"))
        XCTAssertTrue(approvalViewSource.contains("request.protocolIdentityAlgorithm"))
        XCTAssertTrue(approvalViewSource.contains("request.protocolIdentityFingerprint"))
        XCTAssertTrue(approvalViewSource.contains("请确认 Mac 与 iPhone/iPad 显示的 6 位验证码完全一致"))

        let pinCommitSource = try sourceSlice(
            from: "private func pinProtocolIdentityRequester(",
            to: "private func stableProtocolIdentityDeviceId(",
            in: approvalServiceSource
        )
        XCTAssertEqual(
            pinCommitSource.components(separatedBy: "guard !Task.isCancelled else { return false }").count - 1,
            1,
            "Cancellation is allowed before the first durable pin write, never between authority and bootstrap stores."
        )
        XCTAssertTrue(
            pinCommitSource.range(of: "recordAuthenticatedRemoteAuthority")!.lowerBound
                < pinCommitSource.range(of: "PeerProtocolIdentityBootstrapStore.shared.upsert")!.lowerBound
        )
    }

    @MainActor
    func testWindowBindsPendingRequestAndClosingItRejectsExactlyOnce() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let controller = PairingTrustApprovalWindowController(
            approvalService: service,
            applicationActivator: {}
        )
        controller.start()
        defer {
            controller.stop()
            service.userDismissedCurrentPrompt()
        }

        let requesterID = "id:\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "a", count: 64)
        let approvalTask = Task { @MainActor in
            await service.stageTestProtocolIdentityBindingRequesterApproval(
                peerEndpoint: "lan-window-binding-test",
                requesterDeviceIds: [requesterID],
                displayName: "Test iPad",
                platform: "iOS",
                verificationCode: "123456",
                requesterProtocolSigningAlgorithm: .mlDSA65,
                requesterProtocolIdentityFingerprint: fingerprint
            )
        }

        let request = try await waitForPendingRequest(service: service)
        try await waitForPresentedRequest(request.id, controller: controller)
        XCTAssertEqual(request.protocolIdentityAlgorithm, ProtocolSigningAlgorithm.mlDSA65.rawValue)
        XCTAssertEqual(request.protocolIdentityFingerprint, fingerprint)
        XCTAssertEqual(service.pendingVerificationCode, "123456")

        controller.closePresentedWindowForTesting()
        let decision = await approvalTask.value
        XCTAssertEqual(decision, .reject)
        XCTAssertNil(service.pendingRequest)
        XCTAssertNil(controller.presentedRequestIDForTesting)

        // Re-closing the already retired window cannot resolve any later request.
        controller.closePresentedWindowForTesting()
        XCTAssertNil(service.pendingRequest)
    }

    @MainActor
    func testMalformedRequesterSASAndFingerprintFailWithoutPresentingWindow() async {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let controller = PairingTrustApprovalWindowController(
            approvalService: service,
            applicationActivator: {}
        )
        controller.start()
        defer { controller.stop() }

        let invalidSASDecision = await service.stageTestProtocolIdentityBindingRequesterApproval(
            peerEndpoint: "lan-invalid-sas-test",
            requesterDeviceIds: ["id:\(UUID().uuidString.lowercased())"],
            displayName: "Test iPad",
            platform: "iOS",
            verificationCode: "12 456",
            requesterProtocolSigningAlgorithm: .mlDSA65,
            requesterProtocolIdentityFingerprint: String(repeating: "b", count: 64)
        )
        XCTAssertEqual(invalidSASDecision, .reject)
        XCTAssertNil(service.pendingRequest)
        XCTAssertNil(controller.presentedRequestIDForTesting)

        let invalidFingerprintDecision = await service.stageTestProtocolIdentityBindingRequesterApproval(
            peerEndpoint: "lan-invalid-fingerprint-test",
            requesterDeviceIds: ["id:\(UUID().uuidString.lowercased())"],
            displayName: "Test iPad",
            platform: "iOS",
            verificationCode: "654321",
            requesterProtocolSigningAlgorithm: .mlDSA65,
            requesterProtocolIdentityFingerprint: String(repeating: "g", count: 64)
        )
        XCTAssertEqual(invalidFingerprintDecision, .reject)
        XCTAssertNil(service.pendingRequest)
        XCTAssertNil(controller.presentedRequestIDForTesting)
    }

    @MainActor
    func testAcceptedDecisionCannotBeRewrittenByWindowCloseWhilePinCommits() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let pinOperation = ControlledPinOperation()
        let completionRecorder = DecisionCompletionRecorder()
        service.setProtocolIdentityPinOperationForTesting { _, _, _ in
            await pinOperation.run()
        }
        let controller = PairingTrustApprovalWindowController(
            approvalService: service,
            applicationActivator: {}
        )
        controller.start()
        defer {
            service.setProtocolIdentityPinOperationForTesting(nil)
            controller.stop()
            service.userDismissedCurrentPrompt()
        }

        let requesterID = "id:\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "d", count: 64)
        let transactionId = UUID()
        let requestHash = String(repeating: "1", count: 64)
        let candidateHash = String(repeating: "2", count: 64)
        let sasHash = String(repeating: "3", count: 64)
        let approvalTask = Task { @MainActor in
            let decision = await service.stageTestProtocolIdentityBindingRequesterApproval(
                peerEndpoint: "lan-commit-race-test",
                requesterDeviceIds: [requesterID],
                displayName: "Test iPad",
                platform: "iOS",
                verificationCode: "246810",
                requesterProtocolSigningAlgorithm: .mlDSA65,
                requesterProtocolIdentityFingerprint: fingerprint,
                transactionId: transactionId,
                requestHashHex: requestHash,
                candidateHashHex: candidateHash,
                sasTranscriptHashHex: sasHash
            )
            await completionRecorder.record(decision)
            return decision
        }

        let request = try await waitForPendingRequest(service: service)
        try await waitForPresentedRequest(request.id, controller: controller)
        service.resolve(request, decision: .allowOnce)
        let decision = await approvalTask.value
        let commitTask = Task { @MainActor in
            await service.commitProtocolIdentityBindingRequesterApproval(
                decision: decision,
                transactionId: transactionId,
                requesterDeviceIds: [requesterID],
                requesterProtocolSigningAlgorithm: .mlDSA65,
                requesterProtocolIdentityFingerprint: fingerprint,
                requestHashHex: requestHash,
                candidateHashHex: candidateHash,
                sasTranscriptHashHex: sasHash
            )
        }
        try await waitForPinOperationToStart(pinOperation)
        XCTAssertTrue(service.isPendingResolutionInFlight)

        controller.closePresentedWindowForTesting()
        XCTAssertEqual(controller.presentedRequestIDForTesting, request.id)
        XCTAssertEqual(service.pendingRequest?.id, request.id)
        XCTAssertTrue(service.isPendingResolutionInFlight)

        await pinOperation.complete(with: true)
        let committedDecision = await commitTask.value
        let completionSnapshot = await completionRecorder.snapshot()
        XCTAssertEqual(decision, .allowOnce)
        XCTAssertEqual(committedDecision, .allowOnce)
        XCTAssertEqual(completionSnapshot.count, 1)
        XCTAssertEqual(completionSnapshot.decision, .allowOnce)
        XCTAssertFalse(service.isPendingResolutionInFlight)
        XCTAssertEqual(service.pendingDecision, .allowOnce)
    }

    @MainActor
    private func waitForPendingRequest(
        service: PairingTrustApprovalService,
        timeout: Duration = .seconds(2)
    ) async throws -> PairingTrustApprovalService.Request {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let request = service.pendingRequest { return request }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ApprovalSurfaceTestError.timedOutWaitingForPendingRequest
    }

    @MainActor
    private func waitForPresentedRequest(
        _ requestID: UUID,
        controller: PairingTrustApprovalWindowController,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if controller.presentedRequestIDForTesting == requestID { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ApprovalSurfaceTestError.timedOutWaitingForApprovalWindow
    }

    @MainActor
    private func waitForPinOperationToStart(
        _ operation: ControlledPinOperation,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await operation.hasStarted { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ApprovalSurfaceTestError.timedOutWaitingForPinOperation
    }

    private func readSource(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func sourceSlice(from start: String, to end: String, in source: String) throws -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            throw ApprovalSurfaceTestError.sourceBoundaryMissing
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}

private enum ApprovalSurfaceTestError: Error {
    case timedOutWaitingForPendingRequest
    case timedOutWaitingForApprovalWindow
    case timedOutWaitingForPinOperation
    case sourceBoundaryMissing
}

private actor ControlledPinOperation {
    private(set) var hasStarted = false
    private var completion: Bool?
    private var completionContinuations: [CheckedContinuation<Bool, Never>] = []

    func run() async -> Bool {
        hasStarted = true
        if let completion { return completion }
        return await withCheckedContinuation { continuation in
            completionContinuations.append(continuation)
        }
    }

    func complete(with result: Bool) {
        guard completion == nil else { return }
        completion = result
        let continuations = completionContinuations
        completionContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: result)
        }
    }
}

private actor DecisionCompletionRecorder {
    private var decisions: [PairingTrustApprovalService.Decision] = []

    func record(_ decision: PairingTrustApprovalService.Decision) {
        decisions.append(decision)
    }

    func snapshot() -> (count: Int, decision: PairingTrustApprovalService.Decision?) {
        (decisions.count, decisions.last)
    }
}
