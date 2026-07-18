import Foundation

/// Owns the durable write portion of an authenticated pairing identity exchange.
///
/// Transport handlers remain responsible for approval, reply construction, and
/// connection teardown. This coordinator keeps authority and KEM persistence in
/// one ordered path so every transport uses the same generation and
/// pre-commit rollback semantics.
@available(macOS 14.0, iOS 17.0, *)
enum PairingIdentityExchangeCommitCoordinator {
    struct Reservation: Sendable {
        fileprivate let deviceIds: [String]
        fileprivate let generation: UInt64
    }

    struct CommitReceipt: Sendable {
        fileprivate let reservation: Reservation
        fileprivate let protocolIdentityFingerprint: String
    }

    enum CommitResult: Sendable {
        case committed(CommitReceipt)
        case superseded
    }

    enum RollbackResult: Sendable {
        case completed(Bool)
        case failed(String)
    }

    enum CommitError: Error, LocalizedError, Sendable {
        case authorityNotPromoted
        case rollbackFailed(primary: String, rollback: String)

        var errorDescription: String? {
            switch self {
            case .authorityNotPromoted:
                return "Authenticated pairing authority was not promoted"
            case .rollbackFailed(let primary, let rollback):
                return "Pairing commit failed (\(primary)); exact KEM rollback also failed (\(rollback))"
            }
        }
    }

    static func reserve(deviceIds: [String]) async throws -> Reservation {
        let normalizedIds = normalizedUniqueIdentifiers(deviceIds)
        let generation = try await PeerKEMBootstrapStore.shared
            .reservePairingWriteGeneration(deviceIds: normalizedIds)
        return Reservation(deviceIds: normalizedIds, generation: generation)
    }

    @discardableResult
    static func rollback(_ reservation: Reservation) async throws -> Bool {
        try await PeerKEMBootstrapStore.shared.rollbackPairingIdentityExchangeEntries(
            deviceIds: reservation.deviceIds,
            matchingWriteGeneration: reservation.generation
        )
    }

    static func rollbackResult(_ reservation: Reservation) async -> RollbackResult {
        do {
            return .completed(try await rollback(reservation))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Stages the generation-bound KEM, then durably commits authenticated
    /// authority as the transaction's final commit point.
    ///
    /// A staged pairing KEM is not authentication authority: production lookup
    /// returns it only when an independently durable TrustSync pin supplies the
    /// exact protocol fingerprint. If authority persistence fails or is
    /// superseded, the exact KEM generation is rolled back. Once authority is
    /// durably saved, the transaction is committed; later supersession only
    /// makes the receipt stale and must not undo that historical commit.
    static func commitAuthorityAndKEM(
        reservation: Reservation,
        payload: AppMessage.PairingIdentityExchangePayload,
        authority: AuthenticatedRemoteAuthority,
        displayName: String?,
        platform: String? = nil,
        osVersion: String? = nil,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async throws -> CommitResult {
        let reservationIsCurrent: PairingAuthorityCommitValidator = {
            guard isCurrent() else { return false }
            return await PeerKEMBootstrapStore.shared.isCurrentPairingWriteReservation(
                deviceIds: reservation.deviceIds,
                matchingGeneration: reservation.generation
            )
        }
        do {
            try Task.checkCancellation()
            guard await reservationIsCurrent() else {
                _ = try await rollback(reservation)
                return .superseded
            }

            let staged = try await PeerKEMBootstrapStore.shared.upsert(
                deviceIds: reservation.deviceIds,
                kemPublicKeys: payload.kemPublicKeys,
                platform: platform ?? payload.platform,
                osVersion: osVersion ?? payload.osVersion,
                verifiedProtocolFingerprint: authority.protocolPublicKeyFingerprint,
                pairingWriteGeneration: reservation.generation
            )
            guard staged else {
                _ = try await rollback(reservation)
                return .superseded
            }

            let stagedCommitIsCurrent: PairingAuthorityCommitValidator = {
                guard isCurrent() else { return false }
                return await PeerKEMBootstrapStore.shared.isCurrentPairingWriteCommit(
                    deviceIds: reservation.deviceIds,
                    matchingGeneration: reservation.generation,
                    matchingProtocolFingerprint: authority.protocolPublicKeyFingerprint
                )
            }
            try Task.checkCancellation()
            guard await stagedCommitIsCurrent() else {
                _ = try await rollback(reservation)
                return .superseded
            }

            let authenticatedProtocolPublicKey = AuthenticatedProtocolIdentityBinding.matchingPublicKey(
                in: payload,
                authority: authority
            )
            let persisted = try await TrustSyncService.shared.recordAuthenticatedRemoteAuthorityForPairing(
                deviceId: payload.deviceId,
                displayName: displayName,
                preferredCurrentDeviceId: payload.deviceId,
                knownDeviceIds: reservation.deviceIds,
                protocolSigningAlgorithm: authority.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint,
                authenticatedProtocolPublicKey: authenticatedProtocolPublicKey,
                isCurrent: stagedCommitIsCurrent
            )
            guard persisted else {
                throw CommitError.authorityNotPromoted
            }

            // Authority persistence is the final commit point. There must be
            // no cancellation check, receipt-current validation, or durable
            // cache mutation after this point: a completed authority/KEM pair
            // is historical committed state and is never partially rolled
            // back because its transport later disconnects or is superseded.
            return .committed(CommitReceipt(
                reservation: reservation,
                protocolIdentityFingerprint: authority.protocolPublicKeyFingerprint
            ))
        } catch {
            do {
                _ = try await rollback(reservation)
            } catch let rollbackError {
                throw CommitError.rollbackFailed(
                    primary: error.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw error
        }
    }

    static func isCurrent(
        _ receipt: CommitReceipt,
        transportIsCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        guard await transportIsCurrent() else { return false }
        return await PeerKEMBootstrapStore.shared.isCurrentPairingWriteCommit(
            deviceIds: receipt.reservation.deviceIds,
            matchingGeneration: receipt.reservation.generation,
            matchingProtocolFingerprint: receipt.protocolIdentityFingerprint
        )
    }

    private static func normalizedUniqueIdentifiers(_ rawIdentifiers: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawIdentifier in rawIdentifiers {
            let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty else { continue }
            guard seen.insert(identifier.lowercased()).inserted else { continue }
            result.append(identifier)
        }
        return result
    }
}
