import Foundation

/// Shared inbound-handshake trust classification.
///
/// A responder receiving a cold inbound MessageA must decide how to admit the
/// peer *before* runtime session state exists. That decision is protocol
/// semantics, not adapter tuning: macOS and iOS must classify the same
/// presented identity against the same durable-trust facts identically.
/// Platform adapters own their stores and sockets; they feed this policy the
/// presented protocol identity fingerprint plus the stable peer ids whose
/// pinned trust material matches it, and then apply the returned action.
///
/// Contract for adapters applying `InboundHandshakeAdmissionAction`:
/// - `.admitPinned` admits the handshake with the pinned identity enforced for
///   the resolved stable peer. This is the product semantic that a paired
///   device connects immediately, without re-prompting.
/// - `.admitDeferringPairingConfirmation` admits the handshake without a pin so
///   the platform's post-handshake pairing confirmation (operator prompt for
///   unknown peers, automatic approval for durable trust) decides persistence.
///   The session-scoped authority must not become durable trust by itself.
///
/// Admission never silently drops a connection: every action admits the
/// handshake, so any final refusal happens inside the handshake (a
/// user-visible cryptographic failure) or at the pairing confirmation (a
/// user-visible operator decision). An adapter that closes an inbound
/// connection for any other reason must surface that reason to the operator.
public enum InboundHandshakeTrustDisposition: Sendable, Equatable {
    /// The presented protocol identity uniquely matches one pinned peer.
    case pinnedPeer(stablePeerId: String)
    /// No pinned peer matches the presented protocol identity.
    case unpinnedPeer
    /// The presented protocol identity matches more than one distinct pinned
    /// peer: the durable trust store cannot say which logical device this is.
    case ambiguousPinnedIdentity(stablePeerIds: [String])
}

public enum InboundHandshakeAdmissionAction: Sendable, Equatable {
    case admitPinned(stablePeerId: String)
    case admitDeferringPairingConfirmation
}

public enum InboundHandshakeTrustPolicy {
    /// Classifies one presented protocol identity against durable pins.
    ///
    /// - Parameters:
    ///   - presentedProtocolIdentityFingerprint: the authoritative protocol
    ///     fingerprint decoded from MessageA identity keys
    ///     (`IdentityPublicKeys.authoritativeProtocolFingerprint()`), or `nil`
    ///     when the identity block could not be decoded.
    ///   - pinnedStablePeerIdsMatchingPresentedIdentity: every stable peer id
    ///     whose durable pinned protocol identity material contains the
    ///     presented fingerprint. Aliases of the same physical peer must be
    ///     collapsed to one canonical id by the caller; this policy only
    ///     deduplicates trivially equal ids.
    public static func disposition(
        presentedProtocolIdentityFingerprint: String?,
        pinnedStablePeerIdsMatchingPresentedIdentity: [String]
    ) -> InboundHandshakeTrustDisposition {
        guard let fingerprint = normalized(presentedProtocolIdentityFingerprint),
              !fingerprint.isEmpty else {
            return .unpinnedPeer
        }

        var seen = Set<String>()
        var matched: [String] = []
        for raw in pinnedStablePeerIdsMatchingPresentedIdentity {
            guard let stablePeerId = normalized(raw),
                  !stablePeerId.isEmpty,
                  seen.insert(stablePeerId).inserted else {
                continue
            }
            matched.append(stablePeerId)
        }

        switch matched.count {
        case 0:
            return .unpinnedPeer
        case 1:
            return .pinnedPeer(stablePeerId: matched[0])
        default:
            return .ambiguousPinnedIdentity(stablePeerIds: matched)
        }
    }

    /// Maps a disposition to the admission action both platforms must apply.
    ///
    /// A pinned peer is admitted automatically with its pin enforced. An
    /// unpinned peer is admitted into the handshake and confirmed by the
    /// post-handshake pairing flow instead of being dropped. An ambiguous pin
    /// set also defers to pairing confirmation: the presented key is still
    /// transcript-verified in the handshake, but the ambiguous bookkeeping
    /// must not auto-select a stable identity, become durable trust, or be
    /// preauthorized for automatic pairing.
    public static func action(
        for disposition: InboundHandshakeTrustDisposition
    ) -> InboundHandshakeAdmissionAction {
        switch disposition {
        case .pinnedPeer(let stablePeerId):
            return .admitPinned(stablePeerId: stablePeerId)
        case .unpinnedPeer, .ambiguousPinnedIdentity:
            return .admitDeferringPairingConfirmation
        }
    }

    private static func normalized(_ raw: String?) -> String? {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
