#if os(macOS)
import Combine
import CoreAudio
import Foundation
import SkyBridgeProtocolCore

/// Mac product-facing owner. Starting it installs the existing incoming MAIN
/// handler; the application must start its approval presenter first. It never
/// approves a request itself. File capabilities require the installed WAVE/FLAC/ALAC consumer.
@MainActor
public final class AudioPlaybackReceiverService: ObservableObject {
    public enum Phase: String, Sendable, CaseIterable {
        case idle, authorizing, awaitingApproval, receivingFile, validatingFile, connectingBluetooth, preparing, buffering, playing, finishing, completed, failed
    }
    public struct Output: Sendable, Equatable {
        public let uid: String
        public let name: String
        public init(uid: String, name: String) { self.uid = uid; self.name = name }
    }
    public let approvals: AudioPlaybackApprovalService
    @Published public private(set) var phase = Phase.idle
    @Published public private(set) var selectedOutput: Output?
    @Published public private(set) var failureReason: AudioStreamingStopReason?
    @Published public private(set) var outputIssue: AudioPlaybackOutputIssue?
    @Published public private(set) var cleanupFailures: [String] = []
    @Published public private(set) var completedSourceFrames: UInt64?
    /// Parsed file PCM or an authorized capture declaration; this does not assert output readiness.
    @Published public private(set) var sourceFormat: AudioStreamingPCMFormat?
    @Published public private(set) var playbackSource: AudioPlaybackSource?
    /// The exact audio operation's authenticated control carrier, retained with
    /// its terminal result even if the device list subsequently shows another session.
    @Published public private(set) var controlTransport: P2PConnection.ControlTransport?
    @Published public private(set) var authorizationExpiresAt: Date?
    @Published public private(set) var authorizationRenewalState: AudioMembershipRenewalState?
    private(set) var lastAuthorizationRenewalFailure: (any Error)?
    @Published public private(set) var senderDeviceID: String?
    @Published public private(set) var requiresOutputRecovery = false
    @Published public private(set) var outputCleanupPreservedExternalChanges = false
    @Published public private(set) var outputCleanupOutcome: AudioOutputCleanupOutcome?
    public var currentPlaybackID: UUID? { activeOwner }
    public var isReceiving: Bool { activeOwner != nil }
    private struct OwnedSession {
        let session: AudioPlaybackReceiveSession
        let task: Task<Void, Never>
    }
    private var sessions: [UUID: OwnedSession] = [:]
    private var activeOwner: UUID?
    private var handlerID: UUID?
    private var recoveryOwner: UUID?
    private var shutdownTask: Task<Bool, Never>?
    private var recoveryTask: Task<Bool, Never>?
    private let selectOutput: @MainActor () throws -> Output
    private let dependencies: Dependencies

    /// Same production lifecycle with substitutable boundaries for tests; no test needs a live
    /// discovery/account singleton or HAL output. Registration remains owned by this service.
    struct Dependencies {
        let installHandler: @MainActor (@escaping @Sendable (P2PAudioChannel) -> Void) throws -> UUID
        let removeHandler: @MainActor (UUID) -> Void
        let authorize: @Sendable (P2PAudioChannel) async throws -> AudioMembershipLease
        let renewMembership: AudioPlaybackReceiveSession.MembershipRenewal?
        let makeOutput: AudioPlaybackReceiveSession.OutputFactory
        let fileTransfers: AudioOriginalFileTransferRegistry?
        let bluetooth: AudioBluetoothPlaybackDependencies?
        let reportsFileOutputProgress: Bool

        init(installHandler: @escaping @MainActor (@escaping @Sendable (P2PAudioChannel) -> Void) throws -> UUID,
             removeHandler: @escaping @MainActor (UUID) -> Void,
             authorize: @escaping @Sendable (P2PAudioChannel) async throws -> AudioMembershipLease,
             renewMembership: AudioPlaybackReceiveSession.MembershipRenewal?,
             makeOutput: @escaping AudioPlaybackReceiveSession.OutputFactory,
             fileTransfers: AudioOriginalFileTransferRegistry? = nil,
             bluetooth: AudioBluetoothPlaybackDependencies? = nil,
             reportsFileOutputProgress: Bool = false) {
            self.installHandler = installHandler; self.removeHandler = removeHandler
            self.authorize = authorize; self.makeOutput = makeOutput; self.fileTransfers = fileTransfers
            self.renewMembership = renewMembership
            self.bluetooth = bluetooth
            self.reportsFileOutputProgress = reportsFileOutputProgress
        }

        // Public startup stays unadvertised until the direct CoC route and mobile sender pass
        // physical qualification. A qualified startup must install both capabilities and this
        // same concrete consumer, rather than enabling advertisement independently.
        @MainActor static func live(bluetooth: AudioBluetoothPlaybackDependencies? = nil) -> Self {
            .init(installHandler: { handler in
                try P2PDiscoveryService.shared.installIncomingAudioChannelHandler(advertiseCapture: true,
                    originalFileSupport: .waveFlacAndAlac, advertiseBluetoothOpus: bluetooth != nil,
                    advertiseFileOutputProgress: true, handler)
            }, removeHandler: { id in
                P2PDiscoveryService.shared.removeIncomingAudioChannelHandler(ifOwnedBy: id)
            }, authorize: { channel in
                try await AudioAccountMembershipProvider.shared.lease(for: channel)
            }, renewMembership: { channel, lease in
                _ = try await AudioAccountMembershipProvider.shared.renew(for: channel, continuing: lease)
            }, makeOutput: { owner, authorization in
                try CoreAudioCaptureOutput(ownerID: owner, authorization: authorization)
            }, fileTransfers: .shared, bluetooth: bluetooth, reportsFileOutputProgress: true)
        }
    }

    public convenience init(enableBluetoothCompatibleAudio: Bool = false) throws {
        try self.init(approvals: AudioPlaybackApprovalService(), selectOutput: Self.currentDefaultOutput,
            dependencies: .live(bluetooth: enableBluetoothCompatibleAudio ? .live : nil))
    }
    init(approvals: AudioPlaybackApprovalService, selectOutput: @escaping @MainActor () throws -> Output,
         dependencies: Dependencies? = nil) {
        self.approvals = approvals; self.selectOutput = selectOutput
        self.dependencies = dependencies ?? .live()
    }

    public func start() throws {
        guard shutdownTask == nil, !requiresOutputRecovery else { throw AudioPlaybackApprovalError.busy }
        guard handlerID == nil else { return }
        handlerID = try dependencies.installHandler { [weak self] channel in
            Task { @MainActor [weak self] in
                guard let self, self.handlerID != nil else { channel.close(); return }
                do { try channel.requireCurrent() }
                catch {
                    // A queued callback may outlive its receiver installation.
                    SkyBridgeLogger.p2p.debug("Retired audio channel rejected before receiver attachment")
                    channel.close(); return
                }
                self.attach(channel)
            }
        }
    }

    public func stopCurrentPlayback() {
        guard let activeOwner else { return }
        stopPlayback(ifOwnedBy: activeOwner)
    }

    public func stopPlayback(ifOwnedBy ownerID: UUID) {
        guard activeOwner == ownerID, let session = sessions[ownerID]?.session else { return }
        Task { await session.stop() }
    }

    /// True means no owned output cleanup obligation remains. Historical diagnostics, transport
    /// Stop delivery failure, and deliberately preserved third-party settings remain reportable.
    public func stop() async -> Bool {
        if let shutdownTask { return await shutdownTask.value }
        let task = Task { @MainActor in await self.stopOwnedSessions() }
        shutdownTask = task
        let result = await task.value
        shutdownTask = nil
        return result
    }

    private func stopOwnedSessions() async -> Bool {
        if let handlerID {
            self.handlerID = nil
            dependencies.removeHandler(handlerID)
        }
        let owned = Array(sessions.values)
        for value in owned { await value.session.stop(); value.task.cancel() }
        for value in owned { await value.task.value }
        return !requiresOutputRecovery && activeOwner == nil
    }

    /// One bounded close attempt on the retained exact owner. Concurrent requests share that
    /// attempt; this never restarts playback or converts the failed stream into a success.
    public func retryOutputCleanup() async -> Bool {
        if let recoveryTask { return await recoveryTask.value }
        guard let owner = recoveryOwner, let owned = sessions[owner] else { return !requiresOutputRecovery }
        let task = Task { @MainActor in
            do {
                let outcome = try await owned.session.retryOutputCleanup()
                guard self.recoveryOwner == owner else { return !self.requiresOutputRecovery }
                self.publishCleanup(outcome)
                if outcome.state == .released {
                    self.sessions.removeValue(forKey: owner)
                    self.recoveryOwner = nil
                    self.requiresOutputRecovery = false
                }
                return outcome.state == .released
            } catch {
                // Unexpected lifecycle failure is explicit and cannot erase the retained owner.
                let diagnostic = "cleanup_retry: " + String(reflecting: type(of: error))
                if !self.cleanupFailures.contains(diagnostic) { self.cleanupFailures.append(diagnostic) }
                return false
            }
        }
        recoveryTask = task
        let result = await task.value
        recoveryTask = nil
        return result
    }

    private func attach(_ channel: P2PAudioChannel) {
        // The MAIN listener has its own connection cap. Bound our idle offer
        // waiters too; an idle channel retires after ten seconds and a later offer
        // can open a fresh channel through the existing incoming-offer dispatcher.
        guard sessions.count < P2PAudioIncomingChannelRegistry.maximumDeliveredChannels,
              sessions[channel.ownerID] == nil else { channel.close(); return }
        let owner = channel.ownerID
        let renewal: AudioPlaybackReceiveSession.MembershipRenewal?
        if let renew = dependencies.renewMembership {
            renewal = { [weak self] channel, lease in
                guard let self else { throw AudioPlaybackApprovalError.ownerReplaced }
                try await self.renewAuthorization(channel, lease: lease, renew: renew)
            }
        } else { renewal = nil }
        let session = AudioPlaybackReceiveSession(channel: channel, selectOutput: { [weak self] in
                guard let self else { throw AudioPlaybackApprovalError.ownerReplaced }
                return try await self.selectOutputFor(owner: owner)
            },
            authorize: { [weak self] channel in
                guard let self else { throw AudioPlaybackApprovalError.ownerReplaced }
                return try await self.claimAndAuthorize(channel)
            }, approvals: approvals, outputFactory: dependencies.makeOutput,
            fileTransfers: dependencies.fileTransfers, reportFileOutputProgress: dependencies.reportsFileOutputProgress,
            bluetooth: dependencies.bluetooth,
            renewMembership: renewal, onAuthorizationUpdate: { [weak self] update in
                await self?.publishAuthorization(update, owner: owner)
            }, onFormat: { [weak self] format in
                Task { @MainActor [weak self] in
                    guard let self, self.activeOwner == owner else { return }
                    self.sourceFormat = format
                }
            }, onSource: { [weak self] source in
                Task { @MainActor [weak self] in
                    guard let self, self.activeOwner == owner else { return }
                    self.playbackSource = source
                }
            }, onPhase: { [weak self] phase in
                Task { @MainActor [weak self] in self?.publish(phase, owner: owner) }
            })
        let task = Task { [weak self] in
            let result: Result<AudioPlaybackReceiveReceipt, Error>
            do { result = .success(try await session.run()) }
            catch { result = .failure(error) }
            let cleanup = await session.outputCleanupStatus()
            self?.finished(owner: owner, result: result, cleanup: cleanup)
        }
        sessions[owner] = OwnedSession(session: session, task: task)
    }

    private func claimAndAuthorize(_ channel: P2PAudioChannel) async throws -> AudioMembershipLease {
        guard handlerID != nil, sessions[channel.ownerID] != nil else { throw AudioPlaybackApprovalError.ownerReplaced }
        guard !requiresOutputRecovery, activeOwner == nil || activeOwner == channel.ownerID else {
            throw AudioPlaybackApprovalError.busy
        }
        activeOwner = channel.ownerID; selectedOutput = nil; failureReason = nil; outputIssue = nil
        controlTransport = channel.controlTransport
        cleanupFailures = []; completedSourceFrames = nil; sourceFormat = nil; playbackSource = nil; authorizationExpiresAt = nil
        outputCleanupOutcome = nil; outputCleanupPreservedExternalChanges = false
        authorizationRenewalState = nil; lastAuthorizationRenewalFailure = nil
        senderDeviceID = channel.remoteIdentity.deviceID; phase = .authorizing
        let lease = try await dependencies.authorize(channel)
        guard activeOwner == channel.ownerID, sessions[channel.ownerID] != nil, handlerID != nil else {
            throw AudioPlaybackApprovalError.ownerReplaced
        }
        authorizationExpiresAt = Date(timeIntervalSince1970: Double(lease.evidence.expiresAtMilliseconds) / 1_000)
        return lease
    }

    private func renewAuthorization(_ channel: P2PAudioChannel, lease: AudioMembershipLease,
                                    renew: AudioPlaybackReceiveSession.MembershipRenewal) async throws {
        try Task.checkCancellation()
        guard activeOwner == channel.ownerID, sessions[channel.ownerID] != nil, handlerID != nil else {
            throw AudioPlaybackApprovalError.ownerReplaced
        }
        try await renew(channel, lease)
        try Task.checkCancellation()
        guard activeOwner == channel.ownerID, sessions[channel.ownerID] != nil, handlerID != nil else {
            throw AudioPlaybackApprovalError.ownerReplaced
        }
    }

    private func publishAuthorization(_ update: AudioMembershipRenewalUpdate, owner: UUID) {
        guard activeOwner == owner, sessions[owner] != nil else { return }
        authorizationExpiresAt = Date(timeIntervalSince1970: Double(update.evidence.expiresAtMilliseconds) / 1_000)
        authorizationRenewalState = update.state
        lastAuthorizationRenewalFailure = update.failure
    }

    private func selectOutputFor(owner: UUID) throws -> String {
        guard activeOwner == owner, sessions[owner] != nil, handlerID != nil else {
            throw AudioPlaybackApprovalError.ownerReplaced
        }
        let output = try selectOutput()
        selectedOutput = output
        return output.uid
    }

    private func publish(_ value: AudioPlaybackReceiveSession.Phase, owner: UUID) {
        guard activeOwner == owner, sessions[owner] != nil else { return }
        let next: Phase
        switch value {
        case .awaitingOffer: return
        case .authorizing: next = .authorizing
        case .awaitingApproval: next = .awaitingApproval
        case .receivingFile: next = .receivingFile
        case .validatingFile: next = .validatingFile
        case .connectingBluetooth: next = .connectingBluetooth
        case .preparing: next = .preparing
        case .buffering: next = .buffering
        case .playing: next = .playing
        case .finishing: next = .finishing
        }
        // Actor-to-UI task delivery may reorder; a stale phase cannot move the
        // same owner back from playing to an earlier preparation screen.
        if let nextIndex = Phase.allCases.firstIndex(of: next), let currentIndex = Phase.allCases.firstIndex(of: phase),
           nextIndex >= currentIndex { phase = next }
    }

    private func finished(owner: UUID, result: Result<AudioPlaybackReceiveReceipt, Error>, cleanup: AudioOutputCleanupOutcome) {
        if cleanup.state == .pending {
            // Admission is serialized before creating any output. Keep this single failed owner
            // in the inventory; even a later UI/service stop cannot discard its obligation.
            recoveryOwner = owner
            requiresOutputRecovery = true
        } else { sessions.removeValue(forKey: owner) }
        guard activeOwner == owner else { return }
        activeOwner = nil
        publishCleanup(cleanup)
        switch result {
        case .success(let receipt): completedSourceFrames = receipt.sourceFrames; phase = .completed
        case .failure(let failure as AudioPlaybackReceiveFailure):
            failureReason = failure.reason
            // Callback delivery can lose a race with terminal completion. Publish the exact
            // owner's retained metadata synchronously, even when preparation failed immediately.
            sourceFormat = failure.sourceFormat
            outputIssue = failure.outputIssue
            for diagnostic in failure.cleanupFailures where !cleanupFailures.contains(diagnostic) { cleanupFailures.append(diagnostic) }
            phase = .failed
        case .failure:
            failureReason = .outputLost; phase = .failed
        }
    }

    private func publishCleanup(_ outcome: AudioOutputCleanupOutcome) {
        outputCleanupOutcome = outcome
        outputCleanupPreservedExternalChanges = !outcome.preservedExternalChanges.isEmpty
        for diagnostic in outcome.diagnostics where !cleanupFailures.contains(diagnostic) { cleanupFailures.append(diagnostic) }
    }

    private static func currentDefaultOutput() throws -> Output {
        let inspector = CoreAudioExactPcmEndpointInspector.self
        let device: AudioDeviceID = try inspector.scalar(AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(kAudioObjectUnknown))
        guard device != kAudioObjectUnknown else { throw CoreAudioExactPcmError.endpointUnavailable }
        let uid = try inspector.string(device, kAudioDevicePropertyDeviceUID)
        let name = try inspector.string(device, kAudioObjectPropertyName)
        guard !uid.isEmpty, !name.isEmpty else { throw CoreAudioExactPcmError.invalidEndpoint }
        return Output(uid: uid, name: name)
    }
}
#endif
