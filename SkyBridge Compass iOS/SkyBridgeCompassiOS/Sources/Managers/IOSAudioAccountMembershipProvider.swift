import Foundation
import SkyBridgeProtocolCore

typealias IOSAudioMembershipRenewal = @MainActor @Sendable
    (IOSAudioChannel, AudioMembershipLease) async throws -> AudioMembershipLease

/// The authenticated native registry operations needed by audio and presence.
/// Successful returns have already validated caller/scope or the removal receipt.
protocol IOSAudioAccountRegistryClient: Sendable {
    func registerPresence(binding: ProtocolIdentityBindingCompat, report: AccountDevicePresenceReport)
        async throws -> SignalServerClient.PresenceRegisterResponseBody
    func listAccountDevices(binding: ProtocolIdentityBindingCompat) async throws -> AccountDeviceListSnapshot
    func removeAccountDevice(binding: ProtocolIdentityBindingCompat, target: AccountDeviceRecord,
                             expectedAccountScope: String) async throws
}

extension SignalServerClientCompat: IOSAudioAccountRegistryClient {}

/// Captures an account epoch before credential resolution, checks it again after
/// refresh, then freezes the bearer and authority into the native HTTP client.
@MainActor
final class IOSAudioAccountClientFactory {
    typealias ContextProvider = @MainActor () throws -> AudioAccountContext?
    private let contextProvider: ContextProvider
    private let configuredAuthority: @MainActor () -> String
    private let resolveSession: @MainActor () async throws -> SignalServerClientCompat.ResolvedAuthenticationSession
    private let buildClient: @MainActor (SignalServerClientCompat.FrozenAccountRequest) -> any IOSAudioAccountRegistryClient
    private let ownedTransport: URLSession?

    init(currentContext: @escaping ContextProvider,
         configuredAuthority: @escaping @MainActor () -> String,
         resolveSession: @escaping @MainActor () async throws -> SignalServerClientCompat.ResolvedAuthenticationSession,
         buildClient: (@MainActor (SignalServerClientCompat.FrozenAccountRequest) -> any IOSAudioAccountRegistryClient)? = nil) {
        contextProvider = currentContext; self.configuredAuthority = configuredAuthority
        self.resolveSession = resolveSession
        if let buildClient {
            self.buildClient = buildClient; ownedTransport = nil
        } else {
            let transport = SignalServerClientCompat.makeAccountRegistryTransport()
            ownedTransport = transport
            self.buildClient = { SignalServerClientCompat(urlSession: transport, frozenAccountRequest: $0) }
        }
    }

    func currentContext() throws -> AudioAccountContext? { try contextProvider() }

    func requireCurrent(_ expected: AudioAccountContext?) throws {
        let current = try contextProvider()
        switch (expected, current) {
        case (nil, nil): return
        case let (expected?, current?):
            guard expected.authorization.isCurrent, current.authorization === expected.authorization,
                  current.account == expected.account else { throw AudioMembershipLeaseFailure.accountChanged }
        default: throw AudioMembershipLeaseFailure.accountChanged
        }
    }

    func makeClient(expected: AudioAccountContext?) async throws -> any IOSAudioAccountRegistryClient {
        try Task.checkCancellation()
        try requireCurrent(expected)
        let authority = configuredAuthority()
        if let expected, authority != expected.account.authority { throw AudioMembershipLeaseFailure.accountChanged }
        let authentication = try await resolveSession()
        try requireCurrent(expected)
        guard configuredAuthority() == authority else { throw AudioMembershipLeaseFailure.accountChanged }
        try authentication.requireCurrent()
        let identity = try SignalServerClientCompat.resolveAuthenticatedJWTIdentity(
            accessToken: authentication.session.accessToken,
            expectedUserIdentifier: authentication.session.userIdentifier)
        let account = try AudioAccountIdentity(authority: authority, tenantID: identity.effectiveTenantID,
                                               userID: identity.subject)
        if let expected, expected.account != account { throw AudioMembershipError.scopeMismatch }
        let frozen = try SignalServerClientCompat.FrozenAccountRequest(account: account,
            authentication: authentication, audioAuthorization: expected?.authorization)
        return buildClient(frozen)
    }

    deinit { ownedTransport?.invalidateAndCancel() }
}

/// iOS adapter for the shared finite membership store. Presence observations are
/// applied inside these request boundaries, before the UI engine can discard an
/// old generation or a cancelled task. UI snapshots never grant playback.
@MainActor
final class IOSAudioAccountMembershipProvider {
    static let shared = IOSAudioAccountMembershipProvider(factory: IOSAudioAccountClientFactory(
        currentContext: { try AuthenticationManager.instance.audioAccountContextIfPublished() },
        configuredAuthority: { CrossNetworkServerConfig.signalingServerURL },
        resolveSession: { try await AuthenticationManager.instance.resolveSignalingSession() }),
        persistence: AudioMembershipPersistence(bootSessionID: IOSAudioBootWitness.read,
            load: { try await AuthenticationManager.instance.loadAudioMembershipCheckpoint(for: $0) },
            save: { try await AuthenticationManager.instance.saveAudioMembershipCheckpoint($2, replacing: $1, for: $0) },
            beginObservation: { try await AuthenticationManager.instance.beginAudioMembershipObservation(for: $0) }))

    private let factory: IOSAudioAccountClientFactory
    private let store: AudioAccountMembershipStore
    private let wall: @Sendable () -> Int64
    private let monotonic: @Sendable () -> ContinuousClock.Instant

    init(factory: IOSAudioAccountClientFactory,
         wall: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
         monotonic: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         persistence: AudioMembershipPersistence? = nil) {
        self.factory = factory; self.wall = wall; self.monotonic = monotonic
        store = AudioAccountMembershipStore(currentContext: {
            guard let context = try factory.currentContext() else { throw AudioMembershipLeaseFailure.accountChanged }
            return context
        }, fetch: { context, binding in
            let client = try await factory.makeClient(expected: context)
            return try await client.listAccountDevices(binding: Self.nativeBinding(binding))
        }, wall: wall, monotonic: monotonic, isCallerInactive: { error in
            if case .deviceNotActive = SignalServerClientCompat.presenceFailure(for: error) { return true }
            return false
        }, isTemporaryFetchFailure: Self.isTemporaryFetchFailure, persistence: persistence)
    }

    private nonisolated static func isTemporaryFetchFailure(_ error: Error) -> Bool {
        if AudioMembershipRequestFailurePolicy.isTemporaryNetworkError(error) { return true }
        if let error = error as? SupabaseService.SupabaseError {
            switch error {
            case .network(let cause): return AudioMembershipRequestFailurePolicy.isTemporaryNetworkError(cause)
            case let .httpStatus(status, body):
                return AudioMembershipRequestFailurePolicy.isTemporaryHTTPStatus(status,
                    errorCode: body.flatMap { SignalServerClient.serverRejectedErrorCode(fromSanitizedDescription: $0) })
            default: return false
            }
        }
        guard let error = error as? SignalServerClientCompat.ClientError else { return false }
        switch error {
        case .expiredAuthentication: return true // Local expiry cannot extend or revoke an existing finite grant.
        case .requestTimedOut, .resourceDeadlineExceeded: return true
        case let .serverRejected(status, body):
            return AudioMembershipRequestFailurePolicy.isTemporaryHTTPStatus(status,
                errorCode: SignalServerClient.serverRejectedErrorCode(fromSanitizedDescription: body))
        default: return false
        }
    }

    func lease(for channel: IOSAudioChannel, refresh: Bool = false) async throws -> AudioMembershipLease {
        let binding = AudioAccountChannelBinding(ownerID: channel.ownerID,
            localIdentity: try channel.localIdentityBindingForAccountRequest(), remoteIdentity: channel.remoteIdentity,
            requireCurrent: { try channel.requireCurrent() }, isCurrent: channel.isCurrentForMembership)
        return try await store.lease(for: binding, refresh: refresh)
    }

    func renew(for channel: IOSAudioChannel, continuing: AudioMembershipLease) async throws -> AudioMembershipLease {
        let binding = AudioAccountChannelBinding(ownerID: channel.ownerID,
            localIdentity: try channel.localIdentityBindingForAccountRequest(), remoteIdentity: channel.remoteIdentity,
            requireCurrent: { try channel.requireCurrent() }, isCurrent: channel.isCurrentForMembership)
        return try await store.renew(for: binding, continuing: continuing)
    }

    /// Capture before the caller's asynchronous identity lookup as well as HTTP.
    func captureContext() throws -> AudioAccountContext? { try factory.currentContext() }

    private func observeRequest<T: Sendable>(context: AudioAccountContext?, allowTemporaryFailure: Bool,
        operation: @MainActor (AudioAccountMembershipStore.RequestObservation?) async throws -> T) async throws -> T {
        guard let context else { return try await operation(nil) }
        return try await store.observeRequest(context: context, allowTemporaryFailure: allowTemporaryFailure) {
            try await operation($0)
        }
    }

    func registerPresence(binding: ProtocolIdentityBindingCompat, report: AccountDevicePresenceReport,
                          context: AudioAccountContext?) async throws {
        let caller = try Self.identity(binding)
        try await observeRequest(context: context, allowTemporaryFailure: true) { observation in
            let response: SignalServerClient.PresenceRegisterResponseBody
            do {
                let client = try await factory.makeClient(expected: context)
                response = try await client.registerPresence(binding: binding, report: report)
            } catch {
                try await self.revokeInactiveCaller(error, context: context, caller: caller, observation: observation)
                throw error
            }
            try factory.requireCurrent(context)
            if let context {
                guard let observation else { throw ProtectedAccountSessionError.invalidRecord }
                try await store.observeHeartbeat(response, context: context, caller: caller, observation: observation)
            }
        }
    }

    func listAccountDevices(binding: ProtocolIdentityBindingCompat,
                            context: AudioAccountContext?) async throws -> AccountDeviceListSnapshot {
        let caller = try Self.identity(binding)
        return try await observeRequest(context: context, allowTemporaryFailure: true) { observation in
            let startedWall = wall(), startedMonotonic = monotonic()
            let response: AccountDeviceListSnapshot
            do {
                let client = try await factory.makeClient(expected: context)
                response = try await client.listAccountDevices(binding: binding)
            } catch {
                try await self.revokeInactiveCaller(error, context: context, caller: caller, observation: observation)
                throw error
            }
            try factory.requireCurrent(context)
            if let context {
                guard let observation else { throw ProtectedAccountSessionError.invalidRecord }
                try await store.observeFreshRegistry(response, context: context, caller: caller,
                    startedWall: startedWall, receivedWall: wall(),
                    startedMonotonic: startedMonotonic, receivedMonotonic: monotonic(), observation: observation)
            }
            return response
        }
    }

    func removeAccountDevice(binding: ProtocolIdentityBindingCompat, target: AccountDeviceRecord,
                             expectedAccountScope: String, context: AudioAccountContext?) async throws {
        let caller = try Self.identity(binding)
        let selected = try Self.audioIdentityIfSupported(target)
        try await observeRequest(context: context, allowTemporaryFailure: false) { observation in
            do {
                let client = try await factory.makeClient(expected: context)
                try await client.removeAccountDevice(binding: binding, target: target,
                                                      expectedAccountScope: expectedAccountScope)
            } catch {
                try await self.revokeInactiveCaller(error, context: context, caller: caller, observation: observation)
                throw error
            }
            try factory.requireCurrent(context)
            if let context, let selected {
                guard let observation else { throw ProtectedAccountSessionError.invalidRecord }
                try await store.revoke(identity: selected, context: context, observation: observation)
            }
        }
    }

    private func revokeInactiveCaller(_ error: Error, context: AudioAccountContext?, caller: AudioProtocolIdentity,
                                     observation: AudioAccountMembershipStore.RequestObservation?) async throws {
        if let context, case .deviceNotActive = SignalServerClientCompat.presenceFailure(for: error) {
            guard let observation else { throw ProtectedAccountSessionError.invalidRecord }
            try await store.revoke(identity: caller, context: context, observation: observation)
        }
    }

    private static func nativeBinding(_ binding: ProtocolIdentityBinding) throws -> ProtocolIdentityBindingCompat {
        guard let algorithm = ProtocolSigningAlgorithm(rawValue: binding.protocolSigningAlgorithm.rawValue) else {
            throw AudioMembershipError.invalidIdentity
        }
        return try ProtocolIdentityBindingCompat(deviceId: binding.deviceId, protocolSigningAlgorithm: algorithm,
            protocolPublicKeyBytes: binding.protocolPublicKeyBytes,
            protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint)
    }

    private static func identity(_ binding: ProtocolIdentityBindingCompat) throws -> AudioProtocolIdentity {
        guard let algorithm = SkyBridgeProtocolCore.ProtocolSigningAlgorithm(rawValue: binding.protocolSigningAlgorithm.rawValue) else {
            throw AudioMembershipError.invalidIdentity
        }
        return try AudioProtocolIdentity(deviceID: binding.deviceId, algorithm: algorithm,
                                        fingerprint: binding.protocolPublicKeyFingerprint)
    }

    private static func audioIdentityIfSupported(_ record: AccountDeviceRecord) throws -> AudioProtocolIdentity? {
        guard let algorithm = SkyBridgeProtocolCore.ProtocolSigningAlgorithm(rawValue: record.protocolSigningAlgorithm) else {
            // An unsupported signing algorithm cannot own an audio lease, but
            // it must not prevent the account UI from removing that device.
            return nil
        }
        return try AudioProtocolIdentity(deviceID: record.deviceId, algorithm: algorithm,
                                        fingerprint: record.protocolPublicKeyFingerprint)
    }
}
