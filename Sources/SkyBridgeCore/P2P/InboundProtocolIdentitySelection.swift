import Foundation

public struct InboundProtocolIdentitySelection: Sendable, Equatable {
    public let algorithm: ProtocolSigningAlgorithm
    public let protection: ProtocolSigningKeyProtection

    public init(
        algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection
    ) {
        self.algorithm = algorithm
        self.protection = protection
    }
}

public enum InboundProtocolIdentitySelectionError: Error, LocalizedError, Sendable, Equatable {
    case invalidIdentityEncoding
    case suiteSignatureMismatch(ProtocolSigningAlgorithm)
    case authenticatedRawKeyBindingRequired(ProtocolSigningAlgorithm)
    case localProtocolIdentityNotActive(
        requested: ProtocolSigningAlgorithm,
        active: ProtocolSigningAlgorithm
    )
    case noCompatibleResponderSuite(ProtocolSigningAlgorithm)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentityEncoding:
            return "MessageA protocol identity encoding is invalid"
        case .suiteSignatureMismatch(let algorithm):
            return "MessageA suite group is incompatible with \(algorithm.rawValue)"
        case .authenticatedRawKeyBindingRequired(let algorithm):
            return "An exact authenticated raw-key binding is required for inbound \(algorithm.rawValue)"
        case .localProtocolIdentityNotActive(let requested, let active):
            return "Inbound \(requested.rawValue) requires the same active local protocol identity; current local identity is \(active.rawValue)"
        case .noCompatibleResponderSuite(let algorithm):
            return "No responder suite is compatible with inbound \(algorithm.rawValue)"
        }
    }
}

/// Resolves the protocol signer/verifier pair for a responder from the signed
/// identity carried by MessageA. ML-DSA-87 is deliberately asymmetric with the
/// legacy algorithms: it requires an exact active raw-key authority before a
/// driver is created and can never be reinterpreted as ML-DSA-65 or Ed25519.
@available(macOS 14.0, iOS 17.0, *)
public enum InboundProtocolIdentitySelectionPolicy {
    public static func decodedIdentity(
        from messageA: HandshakeMessageA
    ) throws -> ProtocolIdentityPublicKeys {
        do {
            return try messageA.decodedIdentityPublicKeys().asProtocolIdentityKeys()
        } catch {
            throw InboundProtocolIdentitySelectionError.invalidIdentityEncoding
        }
    }

    public static func select(
        peerAlgorithm: ProtocolSigningAlgorithm,
        peerSupportedSuites: [CryptoSuite],
        hasAuthenticatedExactRawKeyBinding: Bool,
        activeLocalAlgorithm: ProtocolSigningAlgorithm,
        activeLocalProtection: ProtocolSigningKeyProtection
    ) throws -> InboundProtocolIdentitySelection {
        let peerHasPQCGroup = peerSupportedSuites.contains(where: \.isPQCGroup)
        switch peerAlgorithm {
        case .ed25519:
            guard !peerHasPQCGroup else {
                throw InboundProtocolIdentitySelectionError.suiteSignatureMismatch(peerAlgorithm)
            }
            return InboundProtocolIdentitySelection(
                algorithm: .ed25519,
                protection: .softwareKeychain
            )

        case .mlDSA65:
            guard peerHasPQCGroup else {
                throw InboundProtocolIdentitySelectionError.suiteSignatureMismatch(peerAlgorithm)
            }
            return InboundProtocolIdentitySelection(
                algorithm: .mlDSA65,
                protection: activeLocalAlgorithm == .mlDSA65
                    ? activeLocalProtection
                    : .softwareKeychain
            )

        case .mlDSA87:
            guard peerHasPQCGroup else {
                throw InboundProtocolIdentitySelectionError.suiteSignatureMismatch(peerAlgorithm)
            }
            guard hasAuthenticatedExactRawKeyBinding else {
                throw InboundProtocolIdentitySelectionError
                    .authenticatedRawKeyBindingRequired(.mlDSA87)
            }
            guard activeLocalAlgorithm == .mlDSA87 else {
                throw InboundProtocolIdentitySelectionError.localProtocolIdentityNotActive(
                    requested: .mlDSA87,
                    active: activeLocalAlgorithm
                )
            }
            return InboundProtocolIdentitySelection(
                algorithm: .mlDSA87,
                protection: activeLocalProtection
            )
        }
    }

    @MainActor
    public static func resolve(
        messageA: HandshakeMessageA,
        candidateDeviceIds: [String],
        additionalAuthenticatedProtocolPublicKeys: [Data] = [],
        trustService: TrustSyncService = .shared
    ) async throws -> InboundProtocolIdentitySelection {
        let configuration = try await SettingsManager.shared
            .committedProtocolIdentityConfiguration()
        return try resolve(
            messageA: messageA,
            candidateDeviceIds: candidateDeviceIds,
            additionalAuthenticatedProtocolPublicKeys: additionalAuthenticatedProtocolPublicKeys,
            trustService: trustService,
            activeLocalAlgorithm: configuration.algorithm,
            activeLocalProtection: configuration.protection
        )
    }

    @MainActor
    public static func resolve(
        messageA: HandshakeMessageA,
        candidateDeviceIds: [String],
        additionalAuthenticatedProtocolPublicKeys: [Data] = [],
        trustService: TrustSyncService = .shared,
        activeLocalAlgorithm: ProtocolSigningAlgorithm,
        activeLocalProtection: ProtocolSigningKeyProtection
    ) throws -> InboundProtocolIdentitySelection {
        let identity = try decodedIdentity(from: messageA)

        let exactBindingExists: Bool
        if identity.protocolAlgorithm == .mlDSA87 {
            let stableCandidateIds = stableTrustCandidateIds(candidateDeviceIds)
            let candidateBindingMatches = stableCandidateIds.contains { deviceId in
                trustService.authenticatedProtocolIdentityBinding(
                    deviceId: deviceId,
                    algorithm: .mlDSA87
                )?.publicKey == identity.protocolPublicKey
            }
            let globallyBoundKeyMatches = stableCandidateIds.isEmpty
                && trustService.authenticatedProtocolIdentityBinding(
                    publicKey: identity.protocolPublicKey,
                    algorithm: .mlDSA87
                ) != nil
            exactBindingExists = candidateBindingMatches
                || globallyBoundKeyMatches
                || additionalAuthenticatedProtocolPublicKeys.contains(identity.protocolPublicKey)
        } else {
            exactBindingExists = false
        }

        return try select(
            peerAlgorithm: identity.protocolAlgorithm,
            peerSupportedSuites: messageA.supportedSuites,
            hasAuthenticatedExactRawKeyBinding: exactBindingExists,
            activeLocalAlgorithm: activeLocalAlgorithm,
            activeLocalProtection: activeLocalProtection
        )
    }

    public static func compatibleResponderPQCSuites(
        _ suites: [CryptoSuite],
        algorithm: ProtocolSigningAlgorithm
    ) -> [CryptoSuite] {
        guard algorithm != .ed25519 else { return [] }
        return suites.filter { suite in
            guard suite.isPQCGroup else { return false }
            return algorithm != .mlDSA87 || suite != .qperiaptABI2PolicyBound
        }
    }

    @MainActor
    private static func stableTrustCandidateIds(_ rawIds: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawId in rawIds {
            for candidate in PeerTrustLookup.lookupCandidates(for: rawId)
            where !PeerTrustLookup.isEndpointAlias(candidate)
                && seen.insert(candidate).inserted {
                result.append(candidate)
            }
        }
        return result
    }
}
