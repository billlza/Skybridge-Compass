import Foundation
import SkyBridgeProtocolCore

@available(macOS 14.0, iOS 17.0, *)
internal enum WebRTCPQCHandshakePolicy {
    internal struct RekeyProviderPlan: Equatable, Sendable {
        let label: String
        let suites: [CryptoSuite]
    }

    internal struct InitialHandshakeBootstrapPlan: Equatable, Sendable {
        let selection: CryptoProviderFactory.SelectionPolicy
        let bootstrapMode: String
        let usesClassicAuthorityBootstrap: Bool
    }

    internal struct InitialHandshakeBootstrapFailure: Equatable, Sendable {
        let code: Int
        let message: String
        let includeProviderAvailabilityInLog: Bool
    }

    internal enum InitialHandshakeBootstrapDecision: Equatable, Sendable {
        case proceed(InitialHandshakeBootstrapPlan)
        case reject(InitialHandshakeBootstrapFailure)
    }

    static func canonicalPQCRekeyElectionDeviceId(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.lowercased().hasPrefix("webrtc-") else { return nil }
        return trimmed.lowercased()
    }

    static func shouldInitiatePQCRekey(localDeviceId: String?, remoteDeviceId: String?) -> Bool? {
        guard let local = canonicalPQCRekeyElectionDeviceId(localDeviceId),
              let remote = canonicalPQCRekeyElectionDeviceId(remoteDeviceId) else {
            return nil
        }
        guard local != remote else { return nil }
        return local.lexicographicallyPrecedes(remote)
    }

    static func shouldInitiateInitialWebRTCHandshake(role: WebRTCSession.Role) -> Bool {
        role == .offerer
    }

    static func peerKEMCanonicalWireIds(_ peerKEMPublicKeys: [UInt16: Data]) -> Set<UInt16> {
        Set(peerKEMPublicKeys.compactMap { wireId, publicKey in
            guard !publicKey.isEmpty else { return nil }
            let suite = CryptoSuite(wireId: wireId)
            guard suite.isNegotiable, suite.isPQCGroup else { return nil }
            return suite.canonicalKEMSuite.wireId
        })
    }

    static func webRTCPQCRekeySharedSuites(
        localPQCSuites: [CryptoSuite],
        with peerKEMPublicKeys: [UInt16: Data]
    ) -> [CryptoSuite] {
        let peerCanonicalWireIds = peerKEMCanonicalWireIds(peerKEMPublicKeys)
        var seenWireIds = Set<UInt16>()
        var shared: [CryptoSuite] = []

        for suite in localPQCSuites where suite.isPQCGroup && suite.isNegotiable {
            guard peerCanonicalWireIds.contains(suite.canonicalKEMSuite.wireId) else { continue }
            guard seenWireIds.insert(suite.wireId).inserted else { continue }
            shared.append(suite)
        }

        return shared
    }

    static func webRTCPQCRekeyProviderPlans(
        capability: CryptoProviderFactory.Capability,
        prefersLiboqsForPeer: Bool,
        peerHasXWing: Bool,
        appleXWingAvailable: Bool
    ) -> [RekeyProviderPlan] {
        guard capability.hasApplePQC || capability.hasLiboqs else { return [] }

        var plans: [RekeyProviderPlan] = []
        if capability.hasApplePQC, peerHasXWing, appleXWingAvailable {
            plans.append(.init(label: "native-xwing", suites: [.xwingMLDSA]))
        }
        if capability.hasApplePQC {
            plans.append(.init(label: "native-pqc", suites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65]))
        }
        if capability.hasLiboqs {
            let label = prefersLiboqsForPeer && !capability.hasApplePQC ? "liboqs" : "liboqs-fallback"
            plans.append(.init(label: label, suites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65]))
        }

        var seen = Set<String>()
        return plans.compactMap { plan in
            let key = "\(plan.label)|\(plan.suites.map(\.wireId))"
            guard seen.insert(key).inserted else { return nil }
            return plan
        }
    }

    static func shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
        sessionID: String,
        authorityBoundBootstrapSessionIds: Set<String>,
        expectedRemoteAuthorityAlgorithm: ProtocolSigningAlgorithm?,
        activeConnectionCodeSessionID: String?,
        strictPQCRequested: Bool = false
    ) -> Bool {
        guard !strictPQCRequested else { return false }
        return authorityBoundBootstrapSessionIds.contains(sessionID)
            || activeConnectionCodeSessionID == sessionID
            || expectedRemoteAuthorityAlgorithm == .ed25519
    }

    static func shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
        supportedSuites: [CryptoSuite],
        strictPQCRequested: Bool,
        expectedRemoteAuthorityAlgorithm: ProtocolSigningAlgorithm?
    ) -> Bool {
        // SKR-1 is the strict recovery path. StrictPQC must fail closed rather
        // than accepting a classic bootstrap-only WebRTC session.
        false
    }

    static func initialWebRTCHandshakePeerResolution(
        expectedRemoteDeviceId: String?,
        learnedRemoteDeviceId: String?,
        endpointDescription: String
    ) -> (resolvedPeerDeviceId: String?, candidateIds: [String]) {
        let resolvedPeerDeviceId = [expectedRemoteDeviceId, learnedRemoteDeviceId]
            .compactMap { raw -> String? in
                guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !trimmed.isEmpty else {
                    return nil
                }
                return trimmed
            }
            .first

        var seen = Set<String>()
        var candidateIds: [String] = []
        for raw in [expectedRemoteDeviceId, learnedRemoteDeviceId, endpointDescription] {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                continue
            }
            if seen.insert(trimmed).inserted {
                candidateIds.append(trimmed)
            }
        }

        return (resolvedPeerDeviceId: resolvedPeerDeviceId, candidateIds: candidateIds)
    }

    static func shouldWaitForStrictPQCInitialWebRTCHandshake(
        strictPQCRequested: Bool,
        resolvedPeerDeviceId: String?,
        hasTrustedPeerKEM: Bool
    ) -> Bool {
        guard strictPQCRequested else { return false }
        guard let resolvedPeerDeviceId,
              !resolvedPeerDeviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        return !hasTrustedPeerKEM
    }

    static func initialWebRTCHandshakeBootstrapDecision(
        strictPQCRequested: Bool,
        hasTrustedPeerKEM: Bool,
        capability: CryptoProviderFactory.Capability,
        useClassicAuthorityBootstrap: Bool,
        peerDeviceId: String
    ) -> InitialHandshakeBootstrapDecision {
        if useClassicAuthorityBootstrap {
            if strictPQCRequested {
                return .reject(.init(
                    code: 703,
                    message: "严格 PQC 已启用，但 WebRTC 初始握手请求 classic authority bootstrap；当前已拒绝 classic bootstrap。peer=\(peerDeviceId)",
                    includeProviderAvailabilityInLog: false
                ))
            }
            return .proceed(.init(
                selection: .classicOnly,
                bootstrapMode: "classic_authority_bootstrap",
                usesClassicAuthorityBootstrap: true
            ))
        }

        guard hasTrustedPeerKEM else {
            if strictPQCRequested {
                return .reject(.init(
                    code: 701,
                    message: "严格 PQC 已启用，但 WebRTC 对端 authoritative deviceId / 受信任 KEM 尚未就绪；当前已拒绝 classic bootstrap。peer=\(peerDeviceId)",
                    includeProviderAvailabilityInLog: false
                ))
            }
            return .proceed(.init(
                selection: .classicOnly,
                bootstrapMode: "classic_bootstrap",
                usesClassicAuthorityBootstrap: false
            ))
        }

        guard capability.hasApplePQC || capability.hasLiboqs else {
            if strictPQCRequested {
                return .reject(.init(
                    code: 702,
                    message: "严格 PQC 已启用，但当前设备没有可用的 PQC Provider；WebRTC 初始握手不会再降级到 Classic。",
                    includeProviderAvailabilityInLog: true
                ))
            }
            return .proceed(.init(
                selection: .classicOnly,
                bootstrapMode: "classic_bootstrap_no_local_pqc_provider",
                usesClassicAuthorityBootstrap: false
            ))
        }

        return .proceed(.init(
            selection: .requirePQC,
            bootstrapMode: "trusted_kem",
            usesClassicAuthorityBootstrap: false
        ))
    }
}
