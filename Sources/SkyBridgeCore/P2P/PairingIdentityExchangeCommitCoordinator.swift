import Foundation

/// Single durable boundary for an authenticated pairing identity exchange.
///
/// KEM material is staged first because it is not authority on its own. The
/// exact protocol authority is then committed through TrustSync as the final
/// commit point. Reservation generations cover every normalized identity, so
/// overlapping aliases supersede an old operation as one transaction.
@available(macOS 14.0, iOS 17.0, *)
enum PairingIdentityExchangeCommitCoordinator {
    struct Reservation: Sendable {
        fileprivate let registryIdentifier: UUID
        fileprivate let token: UUID
        fileprivate let generation: UInt64
        fileprivate let deviceIds: [String]
        fileprivate let registryDeviceIds: [String]
    }

    struct CommitReceipt: Sendable {
        fileprivate let reservation: Reservation
        fileprivate let protocolIdentityFingerprint: String
        fileprivate let kemMutationReceipt:
            PeerKEMBootstrapStore.AuthorityBoundPairingKEMMutationReceipt
    }

    enum CommitResult: Sendable {
        case committed(CommitReceipt)
        case superseded
    }

    enum CommitError: Error, LocalizedError, Sendable {
        case noStableDeviceIdentifiers
        case tooManyStableDeviceIdentifiers(maximum: Int)
        case reservationCapacityExceeded(maximum: Int)
        case reservationGenerationExhausted
        case invalidAuthorityBinding
        case authorityNotPromoted

        var errorDescription: String? {
            switch self {
            case .noStableDeviceIdentifiers:
                return "Pairing commit requires at least one stable device identifier"
            case .tooManyStableDeviceIdentifiers(let maximum):
                return "Pairing commit accepts at most \(maximum) stable device identifiers"
            case .reservationCapacityExceeded(let maximum):
                return "Pairing commit reservation capacity is limited to \(maximum) live device identifiers"
            case .reservationGenerationExhausted:
                return "Pairing commit reservation generation is exhausted"
            case .invalidAuthorityBinding:
                return "Pairing payload does not contain the authenticated protocol authority"
            case .authorityNotPromoted:
                return "Authenticated pairing authority was not promoted"
            }
        }
    }

    private actor ReservationRegistry {
        static let maximumDeviceIdsPerReservation = 8
        static let maximumLiveDeviceEntries = 64

        private struct Epoch: Equatable {
            let token: UUID
            let generation: UInt64
        }

        let identifier = UUID()
        private var nextGeneration: UInt64 = 0
        private var currentEpochByDeviceId: [String: Epoch] = [:]

        func reserve(deviceIds: [String]) throws -> Reservation {
            guard deviceIds.count <= Self.maximumDeviceIdsPerReservation else {
                throw CommitError.tooManyStableDeviceIdentifiers(
                    maximum: Self.maximumDeviceIdsPerReservation
                )
            }
            let registryDeviceIds = deviceIds.map { $0.lowercased() }
            let newDeviceEntryCount = registryDeviceIds.reduce(into: 0) { count, deviceId in
                if currentEpochByDeviceId[deviceId] == nil {
                    count += 1
                }
            }
            guard currentEpochByDeviceId.count
                    <= Self.maximumLiveDeviceEntries - newDeviceEntryCount else {
                throw CommitError.reservationCapacityExceeded(
                    maximum: Self.maximumLiveDeviceEntries
                )
            }
            guard nextGeneration < .max else {
                throw CommitError.reservationGenerationExhausted
            }
            nextGeneration += 1
            let token = UUID()
            let epoch = Epoch(token: token, generation: nextGeneration)
            for deviceId in registryDeviceIds {
                currentEpochByDeviceId[deviceId] = epoch
            }
            return Reservation(
                registryIdentifier: identifier,
                token: token,
                generation: nextGeneration,
                deviceIds: deviceIds,
                registryDeviceIds: registryDeviceIds
            )
        }

        func isCurrent(_ reservation: Reservation) -> Bool {
            reservation.registryIdentifier == identifier
                && !reservation.registryDeviceIds.isEmpty
                && reservation.registryDeviceIds.allSatisfy {
                    currentEpochByDeviceId[$0] == Epoch(
                        token: reservation.token,
                        generation: reservation.generation
                    )
                }
        }

        @discardableResult
        func retire(_ reservation: Reservation) -> Bool {
            guard reservation.registryIdentifier == identifier else { return false }
            var retired = false
            let expectedEpoch = Epoch(
                token: reservation.token,
                generation: reservation.generation
            )
            for deviceId in reservation.registryDeviceIds
            where currentEpochByDeviceId[deviceId] == expectedEpoch {
                currentEpochByDeviceId.removeValue(forKey: deviceId)
                retired = true
            }
            return retired
        }

#if DEBUG || SKYBRIDGE_TESTING
        func liveDeviceEntryCountForTesting() -> Int {
            currentEpochByDeviceId.count
        }
#endif
    }

    private static let registry = ReservationRegistry()

    static func reserve(deviceIds: [String]) async throws -> Reservation {
        try Task.checkCancellation()
        let normalizedIds = normalizedUniqueIdentifiers(deviceIds)
        guard !normalizedIds.isEmpty else {
            throw CommitError.noStableDeviceIdentifiers
        }
        let reservation = try await registry.reserve(deviceIds: normalizedIds)
        do {
            try Task.checkCancellation()
            return reservation
        } catch {
            _ = await registry.retire(reservation)
            throw error
        }
    }

    @discardableResult
    static func rollback(_ reservation: Reservation) async -> Bool {
        await registry.retire(reservation)
    }


    /// Ends the transient generation lease after every post-commit side effect.
    /// Durable authority and KEM state are intentionally left untouched.
    @discardableResult
    static func finish(_ receipt: CommitReceipt) async -> Bool {
        await registry.retire(receipt.reservation)
    }

    /// Runs all generation-dependent post-commit effects and retires the
    /// transient reservation on success, early return, cancellation, or error.
    static func withCommittedReceipt<T>(
        _ receipt: CommitReceipt,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            try Task.checkCancellation()
            let value = try await operation()
            _ = await finish(receipt)
            return value
        } catch {
            _ = await finish(receipt)
            throw error
        }
    }

    @MainActor
    static func withMainActorCommittedReceipt<T: Sendable>(
        _ receipt: CommitReceipt,
        operation: @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        do {
            try Task.checkCancellation()
            let value = try await operation()
            _ = await finish(receipt)
            return value
        } catch {
            _ = await finish(receipt)
            throw error
        }
    }

    static func commitAuthorityAndKEM(
        reservation: Reservation,
        payload: AppMessage.PairingIdentityExchangePayload,
        authority: AuthenticatedRemoteAuthority,
        displayName: String?,
        platform: String? = nil,
        osVersion: String? = nil,
        isCurrent transportIsCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async throws -> CommitResult {
        guard let payload = payload.normalizedBootstrapPayload,
              let authenticatedProtocolPublicKey =
                AuthenticatedProtocolIdentityBinding.matchingPublicKey(
                    in: payload,
                    authority: authority
                ) else {
            _ = await rollback(reservation)
            throw CommitError.invalidAuthorityBinding
        }

        let reservationIsCurrent: PairingAuthorityCommitValidator = {
            guard transportIsCurrent() else { return false }
            return await registry.isCurrent(reservation)
        }

        do {
            try Task.checkCancellation()
        } catch {
            _ = await rollback(reservation)
            throw error
        }
        guard await reservationIsCurrent() else {
            _ = await rollback(reservation)
            return .superseded
        }

        let kemReceipt: PeerKEMBootstrapStore.AuthorityBoundPairingKEMMutationReceipt
        do {
            kemReceipt = try await PeerKEMBootstrapStore.shared
                .upsertAuthorityBoundPairingKEM(
                    deviceIds: reservation.deviceIds,
                    kemPublicKeys: payload.kemPublicKeys,
                    platform: platform ?? payload.platform,
                    osVersion: osVersion ?? payload.osVersion,
                    verifiedProtocolFingerprint: authority.protocolPublicKeyFingerprint
                )
        } catch {
            _ = await rollback(reservation)
            throw error
        }

        do {
            try Task.checkCancellation()
            guard await reservationIsCurrent() else {
                _ = await PeerKEMBootstrapStore.shared
                    .rollbackAuthorityBoundPairingKEMMutation(kemReceipt)
                _ = await rollback(reservation)
                return .superseded
            }

            let persisted = try await TrustSyncService.shared
                .recordAuthenticatedRemoteAuthorityForPairing(
                    deviceId: payload.deviceId,
                    displayName: displayName,
                    preferredCurrentDeviceId: payload.deviceId,
                    knownDeviceIds: reservation.deviceIds,
                    protocolSigningAlgorithm: authority.protocolSigningAlgorithm,
                    protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint,
                    authenticatedProtocolPublicKey: authenticatedProtocolPublicKey,
                    isCurrent: reservationIsCurrent
                )
            guard persisted else {
                throw CommitError.authorityNotPromoted
            }

            // Authority persistence is the final commit point. There is
            // intentionally no cancellation/current check or rollback after it.
            return .committed(CommitReceipt(
                reservation: reservation,
                protocolIdentityFingerprint: authority.protocolPublicKeyFingerprint,
                kemMutationReceipt: kemReceipt
            ))
        } catch let trustError as TrustSyncError {
            switch trustError {
            case .aliasCleanupFailedAfterAuthoritativeCommit,
                 .fallbackCleanupFailedAfterAuthoritativeCommit:
                // The authority is already durable; preserve its exact KEM.
                return .committed(CommitReceipt(
                    reservation: reservation,
                    protocolIdentityFingerprint: authority.protocolPublicKeyFingerprint,
                    kemMutationReceipt: kemReceipt
                ))
            default:
                _ = await PeerKEMBootstrapStore.shared
                    .rollbackAuthorityBoundPairingKEMMutation(kemReceipt)
                _ = await rollback(reservation)
                throw trustError
            }
        } catch {
            _ = await PeerKEMBootstrapStore.shared
                .rollbackAuthorityBoundPairingKEMMutation(kemReceipt)
            _ = await rollback(reservation)
            throw error
        }
    }

    static func isCurrent(
        _ receipt: CommitReceipt,
        transportIsCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        guard await transportIsCurrent(),
              await registry.isCurrent(receipt.reservation) else {
            return false
        }
        return await PeerKEMBootstrapStore.shared
            .isCurrentAuthorityBoundPairingKEMMutation(receipt.kemMutationReceipt)
    }

    private static func normalizedUniqueIdentifiers(_ rawIdentifiers: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawIdentifier in rawIdentifiers {
            for candidate in PeerTrustLookup.lookupCandidates(for: rawIdentifier) {
                let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty,
                      !PeerTrustLookup.isEndpointAlias(normalized),
                      seen.insert(normalized.lowercased()).inserted else {
                    continue
                }
                // The reservation is the first durable pairing boundary. Use
                // the same canonical identity for the generation registry and
                // every KEM persistence target so a case-only successor cannot
                // leave an authority-bound entry under the older spelling.
                result.append(normalized.lowercased())
                if result.count > ReservationRegistry.maximumDeviceIdsPerReservation {
                    return result
                }
            }
        }
        return result
    }

#if DEBUG || SKYBRIDGE_TESTING
    static func liveReservationDeviceEntryCountForTesting() async -> Int {
        await registry.liveDeviceEntryCountForTesting()
    }
#endif
}
