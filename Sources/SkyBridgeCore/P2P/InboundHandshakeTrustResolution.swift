import Foundation
import SkyBridgeProtocolCore

/// macOS adapter for the shared `InboundHandshakeTrustPolicy`.
///
/// Resolves the presented MessageA protocol identity against the durable
/// trust store so a cold inbound handshake classifies identically to iOS:
/// a uniquely pinned peer is admitted with its pin enforced, everything else
/// is admitted with pairing confirmation deferred to the post-handshake flow.
@available(macOS 14.0, iOS 17.0, *)
enum InboundHandshakeTrustResolution {
    static func disposition(
        for messageA: HandshakeMessageA
    ) async -> InboundHandshakeTrustDisposition {
        let presentedFingerprint: String?
        do {
            presentedFingerprint = try messageA
                .decodedIdentityPublicKeys()
                .authoritativeProtocolFingerprint()
        } catch {
            presentedFingerprint = nil
        }
        guard let fingerprint = presentedFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !fingerprint.isEmpty else {
            return .unpinnedPeer
        }

        let records = await TrustSyncService.shared.getActiveTrustRecords()
        let pinResolver = DefaultHandshakeTrustProvider()
        var matchedStablePeerIds: [String] = []
        for record in records where record.isAuthenticationEligible {
            let pinnedFingerprints = Set(
                pinResolver.authoritativeProtocolPins(for: record)
                    .map { $0.fingerprint.lowercased() }
            )
            guard pinnedFingerprints.contains(fingerprint) else { continue }
            matchedStablePeerIds.append(canonicalStablePeerId(for: record))
        }

        return InboundHandshakeTrustPolicy.disposition(
            presentedProtocolIdentityFingerprint: fingerprint,
            pinnedStablePeerIdsMatchingPresentedIdentity: matchedStablePeerIds
        )
    }

    private static func canonicalStablePeerId(for record: TrustRecord) -> String {
        for candidate in [record.currentDeviceId, record.deviceId] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let persistent = PeerTrustLookup.persistentDeviceId(from: trimmed) {
                return persistent.lowercased()
            }
            return trimmed.lowercased()
        }
        return record.deviceId.lowercased()
    }
}

/// Trust provider for an inbound peer whose presented protocol identity
/// uniquely matched one pinned stable peer. Every lookup is redirected to the
/// resolved stable peer id — the runtime peer id of a cold inbound socket is
/// endpoint-derived and never matches trust records — and the pin becomes
/// mandatory for this handshake.
@available(macOS 14.0, iOS 17.0, *)
struct PinnedStablePeerHandshakeTrustProvider: MultiFingerprintHandshakeTrustProvider,
    ExactProtocolIdentityHandshakeTrustProvider, Sendable {
    let stablePeerId: String
    private let base = DefaultHandshakeTrustProvider()

    init(stablePeerId: String) {
        self.stablePeerId = stablePeerId
    }

    func trustedFingerprint(for deviceId: String) async -> String? {
        await base.trustedFingerprint(for: stablePeerId)
    }

    func trustedFingerprints(for deviceId: String) async -> Set<String> {
        await base.trustedFingerprints(for: stablePeerId)
    }

    func trustedProtocolIdentityRawKeys(
        for deviceId: String
    ) async -> [TrustedProtocolIdentityRawKey] {
        await base.trustedProtocolIdentityRawKeys(for: stablePeerId)
    }

    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        await base.trustedKEMPublicKeys(for: stablePeerId)
    }

    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
        await base.trustedSecureEnclavePublicKey(for: stablePeerId)
    }

    func requiresPinnedProtocolIdentity(for deviceId: String) async -> Bool {
        true
    }
}
