import Foundation
import SkyBridgeProtocolCore
import os

typealias AudioAccountContext = SkyBridgeProtocolCore.AudioAccountContext
typealias AudioAccountProviderError = SkyBridgeProtocolCore.AudioAccountProviderError

/// Mac account/network and channel adapter. Cache ownership and revocation live
/// exclusively in the shared store used by both Apple platforms.
@MainActor
final class AudioAccountMembershipProvider {
    static let shared = makeLive()

    private static func makeLive() -> AudioAccountMembershipProvider {
        AudioAccountMembershipProvider(
        currentContext: { try CrossNetworkConnectionManager.currentAudioAccountContext() },
        fetch: { context, binding in
            let client = try await CrossNetworkConnectionManager.makeAudioAccountClient(context)
            return try await client.listAccountDevices(binding: binding)
        }, wall: { Int64(Date().timeIntervalSince1970 * 1_000) }, monotonic: { .now },
        persistence: AudioMembershipPersistence(bootSessionID: MacAudioBootSessionID.read,
            load: { context in
                try await AuthenticationService.shared.loadAudioMembershipCheckpoint(for: context.authorization)
            }, save: { context, revision, bytes in
                try await AuthenticationService.shared.saveAudioMembershipCheckpoint(bytes,
                    replacing: revision, for: context.authorization)
            }, beginObservation: { context in
                try await AuthenticationService.shared.beginAudioMembershipObservation(for: context.authorization)
            }))
    }

    private let store: AudioAccountMembershipStore
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "AudioMembership")

    init(currentContext: @escaping @MainActor () throws -> AudioAccountContext,
         fetch: @escaping @MainActor (AudioAccountContext, ProtocolIdentityBinding) async throws -> AccountDeviceListSnapshot,
         wall: @escaping @Sendable () -> Int64,
         monotonic: @escaping @Sendable () -> ContinuousClock.Instant,
         persistence: AudioMembershipPersistence? = nil) {
        store = AudioAccountMembershipStore(currentContext: currentContext, fetch: fetch,
            wall: wall, monotonic: monotonic, isCallerInactive: { error in
                if case .deviceNotActive = SignalServerClient.presenceFailure(for: error) { return true }
                return false
            }, isTemporaryFetchFailure: Self.isTemporaryFetchFailure, persistence: persistence)
    }

    private nonisolated static func isTemporaryFetchFailure(_ error: Error) -> Bool {
        if AudioMembershipRequestFailurePolicy.isTemporaryNetworkError(error) { return true }
        if let error = error as? AuthenticationService.AuthenticationError,
           case .refreshCredentialUnavailable = error { return true }
        if let error = error as? SignalServerClient.ClientError {
            switch error {
            case .requestTimedOut, .resourceDeadlineExceeded: return true
            case let .serverRejected(status, body):
                return AudioMembershipRequestFailurePolicy.isTemporaryHTTPStatus(status,
                    errorCode: SignalServerClient.serverRejectedErrorCode(fromSanitizedDescription: body))
            default: return false
            }
        }
        // Credential resolution can perform its own authenticated token refresh.
        // Only transport/temporary HTTP failures retain the original finite grant.
        if let error = error as? SupabaseService.SupabaseError {
            switch error {
            case .networkError(let cause): return AudioMembershipRequestFailurePolicy.isTemporaryNetworkError(cause)
            case let .httpStatus(status, body):
                return AudioMembershipRequestFailurePolicy.isTemporaryHTTPStatus(status,
                    errorCode: body.flatMap { SignalServerClient.serverRejectedErrorCode(fromSanitizedDescription: $0) })
            default: return false
            }
        }
        return false
    }

    func lease(for channel: P2PAudioChannel, refresh: Bool = false) async throws -> AudioMembershipLease {
        try await acquire(for: channel, refresh: refresh, continuing: nil)
    }

    func renew(for channel: P2PAudioChannel, continuing: AudioMembershipLease) async throws -> AudioMembershipLease {
        try await acquire(for: channel, refresh: true, continuing: continuing)
    }

    private func acquire(for channel: P2PAudioChannel, refresh: Bool,
                         continuing: AudioMembershipLease?) async throws -> AudioMembershipLease {
        try Task.checkCancellation()
        let binding = AudioAccountChannelBinding(ownerID: channel.ownerID,
            localIdentity: try channel.localIdentityBindingForAccountRequest(), remoteIdentity: channel.remoteIdentity,
            requireCurrent: { try channel.requireCurrent() }, isCurrent: {
                do { try channel.requireCurrent(); return true }
                catch { return false } // Terminal channel failure is revoked admission, never a replacement lookup.
            })
        let lease: AudioMembershipLease
        if let continuing { lease = try await store.renew(for: binding, continuing: continuing) }
        else { lease = try await store.lease(for: binding, refresh: refresh) }
        // Local evidence IDs carry no account credential or peer payload. This
        // permits diagnosing restoration/expiry without reading protected bytes.
        let restoration = String(describing: store.restorationStatus)
        logger.info("Audio membership admitted grant=\(lease.evidence.id.uuidString, privacy: .public) expiry=\(lease.evidence.expiresAtMilliseconds, privacy: .public) restoration=\(restoration, privacy: .public)")
        return lease
    }

    func observeRequest<T: Sendable>(context: AudioAccountContext, allowTemporaryFailure: Bool = true,
        operation: @MainActor (AudioAccountMembershipStore.RequestObservation) async throws -> T) async throws -> T {
        try await store.observeRequest(context: context, allowTemporaryFailure: allowTemporaryFailure, operation: operation)
    }

    /// A request captured without audio authority never borrows a later login.
    func observeOptionalRequest<T: Sendable>(context: AudioAccountContext?, allowTemporaryFailure: Bool,
        operation: @MainActor (AudioAccountMembershipStore.RequestObservation?) async throws -> T) async throws -> T {
        guard let context else { return try await operation(nil) }
        return try await observeRequest(context: context, allowTemporaryFailure: allowTemporaryFailure) {
            try await operation($0)
        }
    }

    func observeFreshRegistry(_ response: AccountDeviceListSnapshot, context: AudioAccountContext,
                              caller: AudioProtocolIdentity, startedWall: Int64, receivedWall: Int64,
                              startedMonotonic: ContinuousClock.Instant,
                              receivedMonotonic: ContinuousClock.Instant,
                              observation: AudioAccountMembershipStore.RequestObservation) async throws {
        try await store.observeFreshRegistry(response, context: context, caller: caller,
            startedWall: startedWall, receivedWall: receivedWall,
            startedMonotonic: startedMonotonic, receivedMonotonic: receivedMonotonic, observation: observation)
    }

    func revoke(identity: AudioProtocolIdentity, authorization: AccountAudioAuthorization,
                observation: AudioAccountMembershipStore.RequestObservation) async throws {
        try await store.revoke(identity: identity, authorization: authorization, observation: observation)
    }

    func observeHeartbeat(_ response: SignalServerClient.PresenceRegisterResponseBody,
                          context: AudioAccountContext, caller: AudioProtocolIdentity,
                          observation: AudioAccountMembershipStore.RequestObservation) async throws {
        try await store.observeHeartbeat(response, context: context, caller: caller, observation: observation)
    }

    func revoke(identity: AudioProtocolIdentity, context: AudioAccountContext,
                observation: AudioAccountMembershipStore.RequestObservation) async throws {
        try await store.revoke(identity: identity, context: context, observation: observation)
    }
}
