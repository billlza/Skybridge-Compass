import Foundation

@available(iOS 17.0, *)
enum CrossNetworkWebRTCPQCHandshakePolicy {
    struct RekeyProviderPlan: Equatable, Sendable {
        let label: String
        let suites: [CryptoSuite]
    }

    struct InitialHandshakeBootstrapPlan: Equatable, Sendable {
        let selection: CryptoProviderFactory.SelectionPolicy
        let bootstrapMode: String
        let usesClassicAuthorityBootstrap: Bool
    }

    struct InitialHandshakeBootstrapFailure: Equatable, Sendable {
        let code: Int
        let message: String
        let includeProviderAvailabilityInLog: Bool
    }

    enum InitialHandshakeBootstrapDecision: Equatable, Sendable {
        case proceed(InitialHandshakeBootstrapPlan)
        case reject(InitialHandshakeBootstrapFailure)
    }

    nonisolated static func shouldRequestStrictPQC(compatibilityModeEnabled _: Bool) -> Bool {
        true
    }

    nonisolated static func shouldRetryClassicBootstrap(after error: Error) -> Bool {
        if let handshakeError = error as? HandshakeError {
            if case .failed(let reason) = handshakeError,
               case .cryptoError = reason {
                return true
            }
            return false
        }
        return false
    }

    nonisolated static func describeHandshakeError(_ error: Error) -> String {
        if let hs = error as? HandshakeError {
            switch hs {
            case .alreadyInProgress:
                return "alreadyInProgress"
            case .noSigningCapability:
                return "noSigningCapability"
            case .failed(let failure):
                return String(describing: failure)
            case .emptyOfferedSuites:
                return "emptyOfferedSuites"
            case .homogeneityViolation(let message):
                return "homogeneityViolation(\(message))"
            case .providerAlgorithmMismatch(let provider, let algorithm):
                return "providerAlgorithmMismatch(provider=\(provider), algorithm=\(algorithm))"
            case .signatureAlgorithmMismatch(let algorithm, let keyHandleType):
                return "signatureAlgorithmMismatch(algorithm=\(algorithm), keyHandle=\(keyHandleType))"
            case .contextZeroized:
                return "contextZeroized"
            }
        }
        return error.localizedDescription
    }

    nonisolated static func canonicalPQCRekeyElectionDeviceId(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.lowercased().hasPrefix("webrtc-") else { return nil }
        return trimmed.lowercased()
    }

    nonisolated static func shouldInitiatePQCRekey(localDeviceId: String?, remoteDeviceId: String?) -> Bool? {
        guard let local = canonicalPQCRekeyElectionDeviceId(localDeviceId),
              let remote = canonicalPQCRekeyElectionDeviceId(remoteDeviceId) else {
            return nil
        }
        guard local != remote else { return nil }
        return local.lexicographicallyPrecedes(remote)
    }

    nonisolated static func resolveTrustedPeerKEMCoverage(
        requiredSuites: [CryptoSuite],
        trustedPeerKEM: [CryptoSuite: Data]
    ) -> (availableSuites: [CryptoSuite], missingSuites: [CryptoSuite]) {
        var keysByCanonicalWireId: [UInt16: Data] = [:]
        for (suite, publicKey) in trustedPeerKEM where !publicKey.isEmpty {
            keysByCanonicalWireId[suite.canonicalKEMSuite.wireId] = publicKey
        }

        var available: [CryptoSuite] = []
        var missing: [CryptoSuite] = []
        for suite in requiredSuites {
            if keysByCanonicalWireId[suite.canonicalKEMSuite.wireId] != nil {
                available.append(suite)
            } else {
                missing.append(suite)
            }
        }
        return (available, missing)
    }

    nonisolated static func webRTCPQCRekeyProviderPlans(
        capability: CryptoProviderFactory.Capability,
        prefersLiboqsForPeer: Bool,
        peerHasXWing: Bool,
        appleXWingAvailable: Bool
    ) -> [RekeyProviderPlan] {
        guard capability.hasApplePQC || capability.hasLiboqs else { return [] }

        var plans: [RekeyProviderPlan] = []
        if capability.hasApplePQC, peerHasXWing, appleXWingAvailable {
            plans.append(.init(label: "native-xwing", suites: [.xwing]))
        }
        if capability.hasApplePQC {
            plans.append(.init(label: "native-pqc", suites: [.mlkem768fs, .mlkem768]))
        }
        if capability.hasLiboqs {
            let label = prefersLiboqsForPeer && !capability.hasApplePQC ? "liboqs" : "liboqs-fallback"
            plans.append(.init(label: label, suites: [.mlkem768fs, .mlkem768]))
        }

        var seen = Set<String>()
        return plans.compactMap { plan in
            let key = "\(plan.label)|\(plan.suites.map(\.wireId))"
            guard seen.insert(key).inserted else { return nil }
            return plan
        }
    }

    nonisolated static func strictPQCRekeyCandidateSuites(
        capability: CryptoProviderFactory.Capability,
        selectedProviderSuites: [CryptoSuite],
        selectedProviderTier: CryptoTier,
        appleXWingAvailable: Bool
    ) -> [CryptoSuite] {
        guard capability.hasApplePQC || capability.hasLiboqs else { return [] }

        let selectedPQCSuites = selectedProviderSuites.filter { $0.isPQCGroup && $0.isNegotiable }
        if capability.hasApplePQC || selectedProviderTier == .nativePQC {
            var suites: [CryptoSuite] = []
            let prefersXWing = selectedPQCSuites.contains { $0.isHybrid }
            if prefersXWing, appleXWingAvailable {
                suites.append(.xwing)
            }
            suites.append(.mlkem768fs)
            suites.append(.mlkem768)
            if !prefersXWing, appleXWingAvailable {
                suites.append(.xwing)
            }
            suites.append(contentsOf: selectedPQCSuites)
            return deduplicatedSuitesByWire(suites)
        }

        return deduplicatedSuitesByWire(selectedPQCSuites)
    }

    nonisolated static func strictPQCRekeyCandidateSuites(
        capability: CryptoProviderFactory.Capability,
        selectedProvider: any CryptoProvider,
        appleXWingAvailable: Bool
    ) -> [CryptoSuite] {
        strictPQCRekeyCandidateSuites(
            capability: capability,
            selectedProviderSuites: selectedProvider.supportedSuites,
            selectedProviderTier: selectedProvider.tier,
            appleXWingAvailable: appleXWingAvailable
        )
    }

    nonisolated static func inboundPQCRekeySelectionPolicy(
        supportedSuites: [CryptoSuite],
        strictPQCRequested: Bool,
        localPQCAvailable: Bool
    ) -> CryptoProviderFactory.SelectionPolicy? {
        let hasPQCGroup = supportedSuites.contains { $0.isPQCGroup }
        guard !strictPQCRequested || hasPQCGroup else { return nil }
        guard !strictPQCRequested || localPQCAvailable else { return nil }
        return hasPQCGroup ? (strictPQCRequested ? .requirePQC : .preferPQC) : .classicOnly
    }

    nonisolated static func inboundInitialHandshakeSelectionPolicy(
        supportedSuites: [CryptoSuite],
        strictPQCRequested: Bool,
        localPQCAvailable: Bool,
        expectedRemoteAuthorityAlgorithm: ProtocolSigningAlgorithm?
    ) -> CryptoProviderFactory.SelectionPolicy? {
        let hasPQCGroup = supportedSuites.contains { $0.isPQCGroup }
        if hasPQCGroup {
            guard !strictPQCRequested || localPQCAvailable else { return nil }
            return strictPQCRequested ? .requirePQC : .preferPQC
        }
        guard !strictPQCRequested || shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
            supportedSuites: supportedSuites,
            strictPQCRequested: strictPQCRequested,
            expectedRemoteAuthorityAlgorithm: expectedRemoteAuthorityAlgorithm
        ) else {
            return nil
        }
        return .classicOnly
    }

    nonisolated static func shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
        supportedSuites: [CryptoSuite],
        strictPQCRequested: Bool,
        expectedRemoteAuthorityAlgorithm: ProtocolSigningAlgorithm?
    ) -> Bool {
        guard !strictPQCRequested else { return false }
        return expectedRemoteAuthorityAlgorithm == .ed25519
            && !supportedSuites.contains(where: { $0.isPQCGroup })
            && supportedSuites.contains(where: { !$0.isPQCGroup })
    }

    nonisolated static func inboundPQCRekeyNegotiatedSuiteAllowed(
        _ suite: CryptoSuite,
        strictPQCRequested: Bool
    ) -> Bool {
        !strictPQCRequested || suite.isPQCGroup
    }

    nonisolated static func inboundInitialHandshakeNegotiatedSuiteAllowed(
        _ suite: CryptoSuite,
        strictPQCRequested: Bool,
        allowsClassicAuthorityBootstrap: Bool
    ) -> Bool {
        !strictPQCRequested || suite.isPQCGroup
    }

    nonisolated static func shouldInitiateInitialWebRTCHandshake(role: WebRTCSession.Role) -> Bool {
        role == .offerer
    }

    nonisolated static func shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
        sessionId: String,
        authorityBoundBootstrapSessionIds: Set<String>,
        expectedRemoteAuthorityAlgorithm: ProtocolSigningAlgorithm?,
        localConnectionSessionId: String?
    ) -> Bool {
        authorityBoundBootstrapSessionIds.contains(sessionId)
            || localConnectionSessionId == sessionId
            || expectedRemoteAuthorityAlgorithm == .ed25519
    }

    nonisolated static func initialWebRTCHandshakeBootstrapDecision(
        strictPQCRequested: Bool,
        hasTrustedPeerKEMKey: Bool,
        capability: CryptoProviderFactory.Capability,
        useClassicAuthorityBootstrap: Bool,
        peerDeviceId: String
    ) -> InitialHandshakeBootstrapDecision {
        if useClassicAuthorityBootstrap {
            if strictPQCRequested {
                return .reject(.init(
                    code: 43,
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

        guard hasTrustedPeerKEMKey else {
            if strictPQCRequested {
                return .reject(.init(
                    code: 41,
                    message: "严格 PQC 已启用，但跨网对端缺少已信任的 KEM 公钥；当前已拒绝 classic bootstrap。peer=\(peerDeviceId)",
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
                    code: 42,
                    message: "严格 PQC 已启用，但当前设备没有可用的 PQC Provider；跨网路径不会再降级到 Classic/PreferPQC。",
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

    nonisolated private static func deduplicatedSuitesByWire(_ suites: [CryptoSuite]) -> [CryptoSuite] {
        var seen = Set<UInt16>()
        var result: [CryptoSuite] = []
        result.reserveCapacity(suites.count)
        for suite in suites where suite.isNegotiable && seen.insert(suite.wireId).inserted {
            result.append(suite)
        }
        return result
    }
}

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    typealias WebRTCPQCRekeyProviderPlan = CrossNetworkWebRTCPQCHandshakePolicy.RekeyProviderPlan

    nonisolated static func canonicalPQCRekeyElectionDeviceId(_ raw: String?) -> String? {
        CrossNetworkWebRTCPQCHandshakePolicy.canonicalPQCRekeyElectionDeviceId(raw)
    }

    nonisolated static func shouldInitiatePQCRekey(localDeviceId: String?, remoteDeviceId: String?) -> Bool? {
        CrossNetworkWebRTCPQCHandshakePolicy.shouldInitiatePQCRekey(
            localDeviceId: localDeviceId,
            remoteDeviceId: remoteDeviceId
        )
    }
}
