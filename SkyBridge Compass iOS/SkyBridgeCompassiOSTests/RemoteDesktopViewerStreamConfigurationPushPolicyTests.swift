import XCTest
import SkyBridgeProtocolCore

@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class RemoteDesktopViewerStreamConfigurationPushPolicyTests: XCTestCase {
    func testLANPendingRejectionRetainsOriginalOwnerWhileAudioBecomesReady() throws {
        var lane = RemoteDesktopViewerStreamConfigurationPushPolicy.LANSendLane<UUID>()
        let owner = UUID()
        let first = try XCTUnwrap(lane.request(owner: owner, intent: .init(force: true, refreshStream: false)))
        let transaction = RemoteDesktopStreamConfigurationTransaction()
        XCTAssertTrue(lane.bind(transaction, work: first))
        XCTAssertNil(lane.request(owner: owner, intent: .init(force: false, refreshStream: false)))
        XCTAssertNil(lane.finishSending(first))
        XCTAssertTrue(lane.awaits(transaction, owner: owner))
        XCTAssertTrue(lane.cancel(first), "Exact rejection retires the first request and its queued update")
        XCTAssertNil(lane.queuedIntent)
        XCTAssertNil(lane.acknowledge(transaction, owner: owner))
    }

    func testLANACKBeforeSendCompletionDoesNotStartNextConfiguration() throws {
        var lane = RemoteDesktopViewerStreamConfigurationPushPolicy.LANSendLane<Int>()
        let first = try XCTUnwrap(lane.request(owner: 1, intent: .init(force: true, refreshStream: false)))
        let transaction = RemoteDesktopStreamConfigurationTransaction()
        XCTAssertTrue(lane.bind(transaction, work: first))
        XCTAssertNil(lane.request(owner: 1, intent: .init(force: false, refreshStream: true)))
        XCTAssertNil(lane.acknowledge(transaction, owner: 1))
        XCTAssertTrue(lane.isCurrent(first))
        let next = try XCTUnwrap(lane.finishSending(first))
        XCTAssertTrue(lane.isCurrent(next))
        XCTAssertTrue(next.intent.refreshStream)
        XCTAssertFalse(lane.bind(.init(), work: first), "Late send callback cannot bind a replacement's transaction")
        XCTAssertFalse(lane.awaits(transaction, owner: 1), "Duplicate old ACK cannot cancel the new deadline")
    }

    func testLANSendCompletionBeforeACKStartsQueuedIntentOnlyAfterACK() throws {
        var lane = RemoteDesktopViewerStreamConfigurationPushPolicy.LANSendLane<Int>()
        let first = try XCTUnwrap(lane.request(owner: 1, intent: .init(force: true, refreshStream: false)))
        let transaction = RemoteDesktopStreamConfigurationTransaction()
        XCTAssertTrue(lane.bind(transaction, work: first))
        XCTAssertNil(lane.finishSending(first))
        XCTAssertNil(lane.request(owner: 1, intent: .init(force: true, refreshStream: false)))
        XCTAssertNil(lane.acknowledge(.init(), owner: 1))
        XCTAssertNil(lane.acknowledge(transaction, owner: 2))
        XCTAssertTrue(lane.awaits(transaction, owner: 1))
        let next = try XCTUnwrap(lane.acknowledge(transaction, owner: 1))
        XCTAssertNotEqual(first.id, next.id)
        XCTAssertTrue(lane.isCurrent(next))
    }

    func testLANIntentQueueIsBoundedAndPreservesRequiredRefresh() throws {
        var lane = RemoteDesktopViewerStreamConfigurationPushPolicy.LANSendLane<Int>()
        let first = try XCTUnwrap(lane.request(owner: 1, intent: .init(force: false, refreshStream: false)))
        for index in 0..<100 {
            XCTAssertNil(lane.request(owner: 1, intent: .init(force: index == 1, refreshStream: index == 50)))
        }
        XCTAssertEqual(lane.queuedIntent, .init(force: true, refreshStream: true))
        let next = try XCTUnwrap(lane.finishSending(first)) // unchanged payload: no wire transaction
        XCTAssertNil(lane.queuedIntent)
        XCTAssertTrue(lane.isCurrent(next))
    }

    func testLANReplacementRejectsOldACKBindCancelAndCompletion() throws {
        var lane = RemoteDesktopViewerStreamConfigurationPushPolicy.LANSendLane<Int>()
        let old = try XCTUnwrap(lane.request(owner: 1, intent: .init(force: false, refreshStream: false)))
        let oldTransaction = RemoteDesktopStreamConfigurationTransaction()
        XCTAssertTrue(lane.bind(oldTransaction, work: old))
        let replacement = try XCTUnwrap(lane.request(owner: 2, intent: .init(force: true, refreshStream: false)))
        XCTAssertFalse(lane.cancel(old))
        XCTAssertFalse(lane.bind(.init(), work: old))
        XCTAssertNil(lane.finishSending(old))
        XCTAssertNil(lane.acknowledge(oldTransaction, owner: 1))
        XCTAssertTrue(lane.isCurrent(replacement))
        XCTAssertTrue(lane.isAwaitingResponse(replacement))
    }

    func testLANResetRejectsOldCompletionEvenOnSameTransportOwner() throws {
        var lane = RemoteDesktopViewerStreamConfigurationPushPolicy.LANSendLane<Int>()
        let old = try XCTUnwrap(lane.request(owner: 1, intent: .init(force: true, refreshStream: true)))
        lane.reset() // explicit stop, permission loss or owner retirement
        let replacement = try XCTUnwrap(lane.request(owner: 1, intent: .init(force: false, refreshStream: false)))
        XCTAssertFalse(lane.cancel(old))
        XCTAssertFalse(lane.bind(.init(), work: old))
        XCTAssertNil(lane.finishSending(old))
        XCTAssertTrue(lane.isCurrent(replacement))
    }

    func testLANApprovalBudgetIsNotAReconfigurationDeadline() {
        XCTAssertEqual(RemoteDesktopViewerStreamConfigurationPushPolicy.configurationResponseTimeout(hasApprovedSession: false), .seconds(57))
        XCTAssertEqual(RemoteDesktopViewerStreamConfigurationPushPolicy.configurationResponseTimeout(hasApprovedSession: true), .seconds(10))
    }

    func testLANUnsupportedFeaturesHaveFixedLocalizedReasons() {
        let policy = RemoteDesktopViewerStreamConfigurationPushPolicy.self
        XCTAssertEqual(policy.rejectionLocalizationKey(code: "audio-unsupported"), "remote.error.audioUnsupported")
        XCTAssertEqual(policy.rejectionLocalizationKey(code: "clipboard-unsupported"), "remote.error.clipboardUnsupported")
        XCTAssertEqual(policy.rejectionLocalizationKey(code: "audio-and-clipboard-unsupported"), "remote.error.audioAndClipboardUnsupported")
        XCTAssertEqual(policy.rejectionLocalizationKey(code: "configuration-unsupported"), "remote.error.configurationUnsupported")
        XCTAssertEqual(policy.rejectionLocalizationKey(code: "unrecognized-code"), "remote.error.configurationRejected")
    }

    func testStartupWatchdogsWaitForAcknowledgementAndDoNotRestartOnDuplicateACKs() {
        var admission = RemoteDesktopViewerStreamConfigurationPushPolicy.StartupWatchdogAdmission<UUID>()
        let video = admission.acknowledge(audioOwner: nil)
        XCTAssertTrue(video.startVideo)
        XCTAssertFalse(video.startAudio)
        let audio = UUID()
        let audioACK = admission.acknowledge(audioOwner: audio)
        XCTAssertFalse(audioACK.startVideo)
        XCTAssertTrue(audioACK.startAudio)
        let repeated = admission.acknowledge(audioOwner: audio)
        XCTAssertFalse(repeated.startVideo)
        XCTAssertFalse(repeated.startAudio)
    }

    func testReplacementAudioReceiverGetsItsOwnWatchdogWithoutExtendingVideoDeadline() {
        var admission = RemoteDesktopViewerStreamConfigurationPushPolicy.StartupWatchdogAdmission<UUID>()
        let first = admission.acknowledge(audioOwner: UUID())
        XCTAssertTrue(first.startVideo && first.startAudio)
        let replacement = admission.acknowledge(audioOwner: UUID())
        XCTAssertFalse(replacement.startVideo)
        XCTAssertTrue(replacement.startAudio)
    }

    func testRetiredAudioWaitsForItsNextACKAndNewSessionStartsFresh() {
        var admission = RemoteDesktopViewerStreamConfigurationPushPolicy.StartupWatchdogAdmission<UUID>()
        let audio = UUID()
        _ = admission.acknowledge(audioOwner: audio)
        admission.retireAudio()
        XCTAssertFalse(admission.acknowledge(audioOwner: nil).startAudio)
        XCTAssertTrue(admission.acknowledge(audioOwner: audio).startAudio)
        admission = .init()
        let nextSession = admission.acknowledge(audioOwner: audio)
        XCTAssertTrue(nextSession.startVideo && nextSession.startAudio)
    }

    @MainActor
    func testWorkspaceWaiterPreservesTerminalTransportFailure() async throws {
        let waiter = RemoteDesktopConfigurationWaiter()
        let started = expectation(description: "waiting for host configuration acknowledgement")
        let waiting = Task {
            started.fulfill()
            try await waiter.wait(for: .init(), timeout: .seconds(1))
        }
        await fulfillment(of: [started], timeout: 1)
        waiter.fail(RemoteDesktopError.streamingFailed("exact transport retired"))
        do {
            try await waiting.value
            XCTFail("Transport retirement must fail the pending workspace operation")
        } catch RemoteDesktopError.streamingFailed(let reason) {
            XCTAssertEqual(reason, "exact transport retired")
        }
    }

    func testRuntimeArmsMediaWatchdogsOnlyAfterAnExactConfigurationACK() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try readRepositorySourceForSourceShapeTests(at: root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
        ))
        let start = try XCTUnwrap(source.range(of: "public func startStreaming() async throws"))
        let startEnd = try XCTUnwrap(source.range(of: "private func scheduleFirstFrameWatchdog", range: start.upperBound..<source.endIndex))
        XCTAssertFalse(source[start.lowerBound..<startEnd.lowerBound].contains("scheduleFirstFrameWatchdog(for:"))
        let prepare = try XCTUnwrap(source.range(of: "private func prepareRealtimeMediaAudioReceiverIfNeeded"))
        let prepareEnd = try XCTUnwrap(source.range(of: "private func scheduleRealtimeMediaAudioStartupDiagnostic", range: prepare.upperBound..<source.endIndex))
        let preparation = source[prepare.lowerBound..<prepareEnd.lowerBound]
        XCTAssertFalse(preparation.contains("scheduleRealtimeMediaAudioNoTrafficRecovery("))
        XCTAssertFalse(preparation.contains("rx startup stalled"))
        let ack = try XCTUnwrap(source.range(of: "public func handleStreamConfigurationAck("))
        let match = try XCTUnwrap(source.range(of: "acknowledgementMatches(", range: ack.upperBound..<source.endIndex))
        let accepted = try XCTUnwrap(source.range(of: "acknowledgedStreamConfigurationTransaction = owner.transaction", range: match.upperBound..<source.endIndex))
        let arm = try XCTUnwrap(source.range(of: "scheduleAcknowledgedMediaStartupWatchdogs(for: owner)", range: accepted.upperBound..<source.endIndex))
        XCTAssertLessThan(match.lowerBound, accepted.lowerBound)
        XCTAssertLessThan(accepted.lowerBound, arm.lowerBound)
        XCTAssertTrue(source.contains("workspaceConfigurationWaiter.fail(isNormalHostEnd ? RemoteDesktopError.disconnected : RemoteDesktopError.streamingFailed(errorMessage))"))
        XCTAssertTrue(source.contains("realtimeMediaAudioStartupDiagnosticTask?.cancel()"))
    }

    @MainActor
    func testVideoConfigurationRemainsAwaitableWhenAudioInstallsBeforeReplacement() async throws {
        let operationGate = RemoteDesktopManager.RemoteDesktopStreamConfigurationOperationGate()
        let transaction = operationGate.begin()
        let requirement = try RemoteDesktopViewerStreamConfigurationPushPolicy
            .AudioBindingRequirement<UUID>(audioEndpointPresent: false, installedOwner: nil)
        let waiter = RemoteDesktopConfigurationWaiter()
        let started = expectation(description: "waiting for the video transaction")
        let waiting = Task {
            started.fulfill()
            try await waiter.wait(for: transaction, timeout: .seconds(1))
        }
        await fulfillment(of: [started], timeout: 1)
        let installedAudio = UUID()
        XCTAssertTrue(operationGate.isCurrent(transaction))
        XCTAssertTrue(requirement.isSatisfied(by: installedAudio))
        XCTAssertFalse(requirement.requiresAudioBinding, "A video ACK cannot admit newly installed audio")
        waiter.acknowledge(transaction)
        try await waiting.value
    }

    func testAudioConfigurationRequiresTheExactPublishedReceiver() throws {
        let published = UUID()
        let replacement = UUID()
        let requirement = try RemoteDesktopViewerStreamConfigurationPushPolicy
            .AudioBindingRequirement(audioEndpointPresent: true, installedOwner: published)
        XCTAssertTrue(requirement.requiresAudioBinding)
        XCTAssertTrue(requirement.isSatisfied(by: published))
        XCTAssertFalse(requirement.isSatisfied(by: replacement))
        XCTAssertFalse(requirement.isSatisfied(by: nil))
    }

    func testAudioConfigurationRejectsMissingReceiver() {
        XCTAssertThrowsError(try RemoteDesktopViewerStreamConfigurationPushPolicy
            .AudioBindingRequirement<UUID>(audioEndpointPresent: true, installedOwner: nil)) { error in
            guard case RemoteDesktopViewerStreamConfigurationPushPolicy
                .AudioBindingRequirement<UUID>.Failure.missingAudioBinding = error else {
                return XCTFail("Unexpected failure: \(error)")
            }
        }
    }

    func testStopConfigurationDoesNotCaptureAnExistingAudioReceiver() throws {
        let installed = UUID()
        let requirement = try RemoteDesktopViewerStreamConfigurationPushPolicy
            .AudioBindingRequirement(audioEndpointPresent: false, installedOwner: installed)
        XCTAssertFalse(requirement.requiresAudioBinding)
        XCTAssertTrue(requirement.isSatisfied(by: installed))
        XCTAssertTrue(requirement.isSatisfied(by: UUID()))
        XCTAssertTrue(requirement.isSatisfied(by: nil))
    }

    func testAudioAdmissionCloseWaitsForInFlightPublisherAndRejectsLateEffects() {
        let gate = IOSRealtimeMediaAudioAdmissionGate(open: true)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let closeStarted = DispatchSemaphore(value: 0)
        let closeFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = gate.withOpen {
                entered.signal()
                release.wait()
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            closeStarted.signal()
            gate.setOpen(false)
            closeFinished.signal()
        }
        XCTAssertEqual(closeStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertNil(gate.withOpen { 1 })

        gate.setOpen(true)
        XCTAssertEqual(gate.withOpen { 2 }, 2)
    }

    func testMediaAdmissionRequiresExactConfigurationAcknowledgement() throws {
        let first = RemoteDesktopStreamConfigurationTransaction(
            id: try XCTUnwrap(UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        )
        let replacement = RemoteDesktopStreamConfigurationTransaction(
            id: try XCTUnwrap(UUID(uuidString: "550e8400-e29b-41d4-a716-446655440001"))
        )

        XCTAssertFalse(
            RemoteDesktopViewerStreamConfigurationPushPolicy.allowsMediaAdmission(
                isReadOnlyCameraSession: false,
                activeTransaction: first,
                acknowledgedTransaction: nil
            )
        )
        XCTAssertFalse(
            RemoteDesktopViewerStreamConfigurationPushPolicy.allowsMediaAdmission(
                isReadOnlyCameraSession: false,
                activeTransaction: replacement,
                acknowledgedTransaction: first
            )
        )
        XCTAssertTrue(
            RemoteDesktopViewerStreamConfigurationPushPolicy.allowsMediaAdmission(
                isReadOnlyCameraSession: false,
                activeTransaction: first,
                acknowledgedTransaction: first
            )
        )
        XCTAssertTrue(
            RemoteDesktopViewerStreamConfigurationPushPolicy.allowsMediaAdmission(
                isReadOnlyCameraSession: true,
                activeTransaction: nil,
                acknowledgedTransaction: nil
            )
        )
    }

    func testStreamConfigurationOperationGateRejectsOutOfOrderCompletion() {
        let gate = RemoteDesktopManager.RemoteDesktopStreamConfigurationOperationGate()
        let first = gate.begin()
        let replacement = gate.begin()

        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.isCurrent(replacement))
        gate.invalidate(first)
        XCTAssertTrue(gate.isCurrent(replacement))
        gate.invalidate(replacement)
        XCTAssertFalse(gate.isCurrent(replacement))
    }

    func testAcknowledgementMustMatchExactLogicalConfiguration() {
        let first = RemoteDesktopStreamConfigurationTransaction(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )
        let replacement = RemoteDesktopStreamConfigurationTransaction(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        )
        let expectation = RemoteDesktopViewerStreamConfigurationPushPolicy
            .AcknowledgementExpectation(
                transaction: replacement,
                streamRefreshToken: 7,
                audioEndpointPresent: true,
                screenFrameTransport: "webrtc-native-main",
                framePresentationAckVersion:
                    RemoteDesktopFramePresentationAcknowledgement.currentVersion
            )

        XCTAssertFalse(
            RemoteDesktopViewerStreamConfigurationPushPolicy.acknowledgementMatches(
                .init(
                    acceptedAt: 1,
                    transaction: first,
                    streamRefreshToken: 7,
                    audioEndpointPresent: true,
                    screenFrameTransport: "webrtc-native-main",
                    framePresentationAckVersion:
                        RemoteDesktopFramePresentationAcknowledgement.currentVersion
                ),
                expectation: expectation
            )
        )
        XCTAssertTrue(
            RemoteDesktopViewerStreamConfigurationPushPolicy.acknowledgementMatches(
                .init(
                    acceptedAt: 2,
                    transaction: replacement,
                    streamRefreshToken: 7,
                    audioEndpointPresent: true,
                    screenFrameTransport: "webrtc-native-main",
                    framePresentationAckVersion:
                        RemoteDesktopFramePresentationAcknowledgement.currentVersion
                ),
                expectation: expectation
            )
        )
        XCTAssertTrue(
            RemoteDesktopViewerStreamConfigurationPushPolicy.acknowledgementMatches(
                .init(
                    acceptedAt: 3,
                    transaction: replacement,
                    streamRefreshToken: 7,
                    audioEndpointPresent: true,
                    screenFrameTransport: "webrtc-native-main",
                    framePresentationAckVersion: nil
                ),
                expectation: expectation
            ),
            "A legacy host must keep streaming when it omits the optional capability receipt"
        )
        XCTAssertFalse(
            RemoteDesktopViewerStreamConfigurationPushPolicy.acknowledgementMatches(
                .init(
                    acceptedAt: 4,
                    transaction: replacement,
                    streamRefreshToken: 7,
                    audioEndpointPresent: true,
                    screenFrameTransport: "webrtc-native-main",
                    framePresentationAckVersion: 2
                ),
                expectation: expectation
            )
        )
    }

    func testFramePresentationAcknowledgementGateRejectsDuplicateAndStaleRelease() {
        let first = RemoteDesktopFramePresentationContext(
            sequenceNumber: 1,
            streamTransaction: RemoteDesktopStreamConfigurationTransaction(),
            streamEpoch: 7
        )
        let replacement = RemoteDesktopFramePresentationContext(
            sequenceNumber: 2,
            streamTransaction: RemoteDesktopStreamConfigurationTransaction(),
            streamEpoch: 8
        )
        var gate = RemoteDesktopManager.FramePresentationAcknowledgementGate()

        XCTAssertTrue(gate.reserve(first))
        XCTAssertFalse(gate.reserve(first))
        gate.release(replacement)
        XCTAssertTrue(gate.isCurrent(first))
        gate.release(first)
        XCTAssertTrue(gate.reserve(replacement))
        gate.reset()
        XCTAssertFalse(gate.isCurrent(replacement))
    }
    func testPendingAudioBindingIsNotUsableBeforeExactTransportIsReady() {
        XCTAssertFalse(
            RemoteDesktopManager.RealtimeMediaAudioBindingAvailabilityPolicy.isUsable(
                transportMode: .crossNetwork,
                hasRenderer: true,
                hasLANReceiver: false,
                hasRelayTransport: false,
                installedMode: .lowLatency,
                expectedMode: .lowLatency
            )
        )
        XCTAssertTrue(
            RemoteDesktopManager.RealtimeMediaAudioBindingAvailabilityPolicy.isUsable(
                transportMode: .crossNetwork,
                hasRenderer: true,
                hasLANReceiver: false,
                hasRelayTransport: true,
                installedMode: .lowLatency,
                expectedMode: .lowLatency
            )
        )
    }

    func testAudioModeChangeInvalidatesExistingBinding() {
        XCTAssertFalse(
            RemoteDesktopManager.RealtimeMediaAudioBindingAvailabilityPolicy.isUsable(
                transportMode: .lan,
                hasRenderer: true,
                hasLANReceiver: true,
                hasRelayTransport: false,
                installedMode: .highFidelity,
                expectedMode: .lowLatency
            )
        )
    }

    func testSessionMutationGateInvalidatesAttemptsAndSerializesTeardown() throws {
        let gate = RemoteDesktopManager.RemoteDesktopSessionMutationGate()
        let attempt = try XCTUnwrap(gate.beginConnectionAttempt())
        let witness = try XCTUnwrap(gate.captureOperationWitness())
        XCTAssertTrue(gate.isCurrent(attempt))
        XCTAssertTrue(gate.isCurrent(witness))
        XCTAssertNil(gate.beginConnectionAttempt())

        let teardown = try XCTUnwrap(gate.beginExclusiveMutation())
        XCTAssertFalse(gate.isCurrent(attempt))
        XCTAssertFalse(gate.isCurrent(witness))
        XCTAssertTrue(gate.hasActiveExclusiveMutation)
        XCTAssertNil(gate.beginConnectionAttempt())
        XCTAssertFalse(gate.canCommit(teardown, ownerIsCurrent: false))
        XCTAssertTrue(gate.canCommit(teardown, ownerIsCurrent: true))

        gate.finish(teardown)
        XCTAssertFalse(gate.hasActiveExclusiveMutation)
        let replacement = try XCTUnwrap(gate.beginConnectionAttempt())
        gate.finish(attempt)
        XCTAssertTrue(gate.isCurrent(replacement))
        gate.finish(replacement)
        XCTAssertNil(gate.beginExclusiveMutation(ifCurrent: false))
    }

    func testNoTransportCannotSendButStillPlansAudioIntent() {
        let plan = RemoteDesktopViewerStreamConfigurationPushPolicy.prepare(
            activeTransportMode: .none,
            hasCurrentConnection: false,
            hasLANConnection: false,
            audioRedirectionEnabled: true,
            hasUsableMediaAudioBinding: false,
            refreshStream: false,
            lastSentMediaAudioEndpointPresent: false,
            lastAcknowledgedMediaAudioEndpointPresent: false
        )

        XCTAssertFalse(plan.canSend)
        XCTAssertFalse(plan.canSendOverWebRTC)
        XCTAssertFalse(plan.canSendOverLAN)
        XCTAssertTrue(plan.shouldStartRealtimeMediaAudioReceiver)
        XCTAssertFalse(plan.shouldStopRealtimeMediaAudioReceiver)
    }

    func testStrictAudioValidationSendsExplicitVideoOnlyWhileEndpointPrepares() {
        let plan = RemoteDesktopViewerStreamConfigurationPushPolicy.prepare(
            activeTransportMode: .crossNetwork,
            hasCurrentConnection: true,
            hasLANConnection: false,
            audioRedirectionEnabled: true,
            hasUsableMediaAudioBinding: false,
            refreshStream: false,
            lastSentMediaAudioEndpointPresent: false,
            lastAcknowledgedMediaAudioEndpointPresent: false
        )

        XCTAssertTrue(plan.canSend)
        XCTAssertTrue(plan.shouldStartRealtimeMediaAudioReceiver)
        XCTAssertFalse(plan.includeAudioEndpointInStreamConfig)
    }

    func testCrossNetworkRefreshDoesNotRepeatExistingAudioEndpoint() {
        let plan = RemoteDesktopViewerStreamConfigurationPushPolicy.prepare(
            activeTransportMode: .crossNetwork,
            hasCurrentConnection: true,
            hasLANConnection: false,
            audioRedirectionEnabled: true,
            hasUsableMediaAudioBinding: true,
            refreshStream: true,
            lastSentMediaAudioEndpointPresent: true,
            lastAcknowledgedMediaAudioEndpointPresent: true
        )

        XCTAssertFalse(plan.includeAudioEndpointInStreamConfig)
    }

    func testCrossNetworkRefreshRepeatsAudioEndpointUntilHostAcknowledgesIt() {
        let plan = RemoteDesktopViewerStreamConfigurationPushPolicy.prepare(
            activeTransportMode: .crossNetwork,
            hasCurrentConnection: true,
            hasLANConnection: false,
            audioRedirectionEnabled: true,
            hasUsableMediaAudioBinding: true,
            refreshStream: true,
            lastSentMediaAudioEndpointPresent: true,
            lastAcknowledgedMediaAudioEndpointPresent: false
        )

        XCTAssertTrue(plan.includeAudioEndpointInStreamConfig)
    }

    func testCrossNetworkFirstAudioConfigIncludesEndpoint() {
        let plan = RemoteDesktopViewerStreamConfigurationPushPolicy.prepare(
            activeTransportMode: .crossNetwork,
            hasCurrentConnection: true,
            hasLANConnection: false,
            audioRedirectionEnabled: true,
            hasUsableMediaAudioBinding: true,
            refreshStream: false,
            lastSentMediaAudioEndpointPresent: false,
            lastAcknowledgedMediaAudioEndpointPresent: false
        )

        XCTAssertTrue(plan.includeAudioEndpointInStreamConfig)
    }

    func testLANRefreshAlwaysKeepsAudioEndpointWhenAvailable() {
        let plan = RemoteDesktopViewerStreamConfigurationPushPolicy.prepare(
            activeTransportMode: .lan,
            hasCurrentConnection: false,
            hasLANConnection: true,
            audioRedirectionEnabled: true,
            hasUsableMediaAudioBinding: true,
            refreshStream: true,
            lastSentMediaAudioEndpointPresent: true,
            lastAcknowledgedMediaAudioEndpointPresent: true
        )

        XCTAssertTrue(plan.canSendOverLAN)
        XCTAssertTrue(plan.includeAudioEndpointInStreamConfig)
    }

    func testPayloadSendAndAckRetryGatesMatchExistingBehavior() {
        XCTAssertFalse(
            RemoteDesktopViewerStreamConfigurationPushPolicy.shouldSendPayload(
                force: false,
                payloadMatchesLastSent: true
            )
        )
        XCTAssertTrue(
            RemoteDesktopViewerStreamConfigurationPushPolicy.shouldSendPayload(
                force: true,
                payloadMatchesLastSent: true
            )
        )
        XCTAssertTrue(
            RemoteDesktopViewerStreamConfigurationPushPolicy.shouldScheduleAckRetry(
                activeTransportMode: .crossNetwork,
                isStreaming: true,
                hasReceivedFrameInCurrentStream: false,
                payloadIncludesAudioEndpoint: false
            )
        )
        XCTAssertFalse(
            RemoteDesktopViewerStreamConfigurationPushPolicy.shouldScheduleAckRetry(
                activeTransportMode: .crossNetwork,
                isStreaming: true,
                hasReceivedFrameInCurrentStream: false,
                payloadIncludesAudioEndpoint: true
            )
        )
        XCTAssertFalse(
            RemoteDesktopViewerStreamConfigurationPushPolicy.shouldScheduleAckRetry(
                activeTransportMode: .lan,
                isStreaming: true,
                hasReceivedFrameInCurrentStream: false,
                payloadIncludesAudioEndpoint: false
            )
        )
    }
}
