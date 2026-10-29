import CryptoKit
import Foundation

struct LANRemoteControlCurrentPathAuthority: Sendable, Equatable {
    let deviceId: String
    let trustedRecordId: String
    let lifecycleGeneration: Int64?
    let protocolPublicKeyFingerprint: String
    let protocolPublicKeyFingerprints: Set<String>
    let mlDSA87PublicKey: Data?
    let signedRefreshKEMPublicKeys: [CryptoSuite: Data]
}

struct LANRemoteControlHandshakeTrustProvider: MultiFingerprintHandshakeTrustProvider, Sendable {
    let expectedRemoteAuthority: LANRemoteControlCurrentPathAuthority

    func trustedFingerprint(for deviceId: String) async -> String? {
        guard deviceId == expectedRemoteAuthority.deviceId else { return nil }
        return expectedRemoteAuthority.protocolPublicKeyFingerprint
    }

    func trustedFingerprints(for deviceId: String) async -> Set<String> {
        guard await trustedFingerprint(for: deviceId) != nil else { return [] }
        return expectedRemoteAuthority.protocolPublicKeyFingerprints
    }

    func trustedProtocolIdentityPublicKey(
        for deviceId: String,
        algorithm: ProtocolSigningAlgorithm
    ) async -> Data? {
        guard deviceId == expectedRemoteAuthority.deviceId,
              algorithm == .mlDSA87 else {
            return nil
        }
        return expectedRemoteAuthority.mlDSA87PublicKey
    }

    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        guard deviceId == expectedRemoteAuthority.deviceId else { return [:] }
        return expectedRemoteAuthority.signedRefreshKEMPublicKeys
    }

    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
        _ = deviceId
        return nil
    }

    func requiresPinnedProtocolIdentity(for deviceId: String) async -> Bool {
        _ = deviceId
        return true
    }
}

enum RemoteDesktopLANHandshakeTrust {
    static func resolveTrustedRemoteAuthority(
        for device: DiscoveredDevice,
        trustedDevices: [TrustedDeviceStore.TrustedDevice]
    ) async throws -> LANRemoteControlCurrentPathAuthority {
        guard let selectedStableDeviceId = PeerIdentityAliasResolver.persistentDeviceId(
            from: device.id
        ) else {
            throw RemoteDesktopError.connectionFailed("远控目标缺少稳定身份")
        }
        let record: TrustedDeviceStore.TrustedDevice
        let deviceId: String
        switch LANRemoteControlTrustResolver.resolve(
            device: device,
            trustedPeerId: selectedStableDeviceId,
            trustedDevices: trustedDevices
        ) {
        case .resolved(let matchedRecord, let canonicalPeerId):
            record = matchedRecord
            guard let canonicalDeviceId = PeerIdentityAliasResolver.persistentDeviceId(
                from: canonicalPeerId
            ) else {
                throw RemoteDesktopError.connectionFailed("远控目标受信任记录缺少规范稳定身份")
            }
            deviceId = canonicalDeviceId
        case .missing:
            throw RemoteDesktopError.connectionFailed("远控目标缺少受信任指纹")
        case .ambiguous(let deviceIds, let fingerprints):
            let summary = [
                "deviceIds=\(deviceIds.joined(separator: ","))",
                "fingerprints=\(fingerprints.joined(separator: ","))"
            ].joined(separator: " ")
            throw RemoteDesktopError.connectionFailed("远控目标受信任指纹映射不唯一: \(summary)")
        }

        guard let fingerprint = record.protocolPublicKeyFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fingerprint.isEmpty else {
            throw RemoteDesktopError.connectionFailed("远控目标缺少受信任指纹")
        }
        let primaryFingerprint = fingerprint.lowercased()

        var identityLookupCandidates: [String] = []
        var seenIdentityLookupCandidates = Set<String>()
        func appendStableIdentityLookupCandidates(for identifier: String?) {
            guard let persistentIdentifier = PeerIdentityAliasResolver.persistentDeviceId(
                from: identifier
            ) else {
                return
            }
            for candidate in PeerIdentityAliasResolver.lookupCandidates(for: persistentIdentifier)
            where seenIdentityLookupCandidates.insert(candidate).inserted {
                identityLookupCandidates.append(candidate)
            }
        }
        // Only identifiers that participated in the unique trusted-authority
        // resolution may select KEM material. Display names, observed hosts,
        // and route metadata are locators, never identity aliases here.
        appendStableIdentityLookupCandidates(for: device.id)
        appendStableIdentityLookupCandidates(for: selectedStableDeviceId)
        appendStableIdentityLookupCandidates(for: deviceId)
        appendStableIdentityLookupCandidates(for: record.currentDeviceId)
        appendStableIdentityLookupCandidates(for: record.id)
        for knownDeviceId in record.knownDeviceIds ?? [] {
            appendStableIdentityLookupCandidates(for: knownDeviceId)
        }

        let supplementalFingerprints = await ProtocolIdentityTrustStore.shared.trustedFingerprints(
            forAny: identityLookupCandidates
        )
        var durableFingerprints = Set([primaryFingerprint])
        durableFingerprints.formUnion(
            (record.protocolIdentityPins ?? []).compactMap {
                let fingerprint = $0.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return fingerprint.isEmpty ? nil : fingerprint
            }
        )
        durableFingerprints.formUnion(
            (record.protocolIdentityKeyBindings ?? []).compactMap {
                let fingerprint = $0.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return fingerprint.isEmpty ? nil : fingerprint
            }
        )
        let trustedFingerprints: Set<String>
        if supplementalFingerprints.contains(primaryFingerprint) {
            trustedFingerprints = durableFingerprints.intersection(supplementalFingerprints)
                .union([primaryFingerprint])
        } else {
            trustedFingerprints = [primaryFingerprint]
            if !supplementalFingerprints.isEmpty {
                SkyBridgeLogger.shared.warning(
                    "⚠️ LAN 远控忽略未绑定到既有受信任指纹的 supplemental protocol identities: peer=<redacted> count=\(supplementalFingerprints.count)"
                )
            }
        }

        let mlDSA87Bindings = (record.protocolIdentityKeyBindings ?? []).filter {
            $0.algorithm == ProtocolSigningAlgorithm.mlDSA87.rawValue
                && trustedFingerprints.contains($0.fingerprint.lowercased())
                && $0.publicKeyBytes != nil
        }
        guard mlDSA87Bindings.count <= 1 else {
            throw RemoteDesktopError.connectionFailed(
                "远控目标存在冲突的 ML-DSA-87 原始公钥绑定"
            )
        }

        var signedRefreshSnapshots: [[CryptoSuite: Data]] = []
        var primarySignedRefreshKEMPublicKeys: [CryptoSuite: Data] = [:]
        for trustedFingerprint in trustedFingerprints.sorted() {
            let snapshot = await KEMTrustStore.shared.signedRefreshKEMPublicKeys(
                forAny: identityLookupCandidates,
                pinnedProtocolFingerprints: [trustedFingerprint]
            )
            if trustedFingerprint == primaryFingerprint {
                primarySignedRefreshKEMPublicKeys = snapshot
            }
            signedRefreshSnapshots.append(snapshot)
        }
        guard !primarySignedRefreshKEMPublicKeys.isEmpty else {
            throw RemoteDesktopError.connectionFailed(
                "远控目标当前 protocol identity 缺少已签名 KEM 公钥"
            )
        }
        let signedRefreshKEMPublicKeys = try mergeAuthorityBoundSignedRefreshKEMPublicKeys(
            signedRefreshSnapshots
        )
        guard !signedRefreshKEMPublicKeys.isEmpty else {
            throw RemoteDesktopError.connectionFailed(
                "远控目标缺少与当前 protocol identity 绑定的已签名 KEM 公钥"
            )
        }

        return LANRemoteControlCurrentPathAuthority(
            deviceId: deviceId,
            trustedRecordId: record.id,
            lifecycleGeneration: record.currentPathLifecycleGeneration,
            protocolPublicKeyFingerprint: primaryFingerprint,
            protocolPublicKeyFingerprints: trustedFingerprints,
            mlDSA87PublicKey: mlDSA87Bindings.first?.publicKeyBytes,
            signedRefreshKEMPublicKeys: signedRefreshKEMPublicKeys
        )
    }

    static func mergeAuthorityBoundSignedRefreshKEMPublicKeys(
        _ snapshots: [[CryptoSuite: Data]]
    ) throws -> [CryptoSuite: Data] {
        var merged: [CryptoSuite: Data] = [:]
        for snapshot in snapshots {
            for (suite, publicKey) in snapshot {
                if let existing = merged[suite], existing != publicKey {
                    throw RemoteDesktopError.connectionFailed(
                        "远控目标同一 KEM suite 存在多个互相冲突的 authority-bound 公钥"
                    )
                }
                merged[suite] = publicKey
            }
        }
        return merged
    }

    static func requireBootstrapAuthorityBinding(
        _ authority: LANRemoteControlCurrentPathAuthority,
        declaredDeviceId: String,
        protocolPublicKeyFingerprint: String
    ) throws {
        let expectedDeviceId = PeerIdentityAliasResolver.persistentDeviceId(
            from: declaredDeviceId
        )
        let expectedFingerprint = protocolPublicKeyFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard expectedDeviceId == authority.deviceId,
              !expectedFingerprint.isEmpty,
              expectedFingerprint == authority.protocolPublicKeyFingerprint else {
            throw RemoteDesktopError.connectionFailed(
                "远控 bootstrap observation 与冻结 authority 不匹配"
            )
        }
    }

    @MainActor
    static func captureStableAuthoritySnapshot(
        timeout: Duration,
        pollInterval: Duration = .milliseconds(100),
        isRecoveryReady: () -> Bool,
        readCurrent: () async throws -> LANRemoteControlCurrentPathAuthority
    ) async throws -> LANRemoteControlCurrentPathAuthority {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var previous: LANRemoteControlCurrentPathAuthority?
        var readableFailureCount = 0
        var lastReadError: Error?

        while clock.now < deadline {
            try Task.checkCancellation()
            guard isRecoveryReady() else {
                previous = nil
                readableFailureCount = 0
                try await Task.sleep(for: pollInterval)
                continue
            }

            let candidate: LANRemoteControlCurrentPathAuthority
            do {
                candidate = try await readCurrent()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastReadError = error
                previous = nil
                guard isRecoveryReady() else {
                    readableFailureCount = 0
                    try await Task.sleep(for: pollInterval)
                    continue
                }
                // The strict stores currently represent an in-progress journal
                // as an empty read. Confirm one readable failure so a journal
                // that completed between the actor read and this catch is not
                // misreported as permanently missing KEM material.
                readableFailureCount += 1
                guard readableFailureCount < 2 else { throw error }
                try await Task.sleep(for: pollInterval)
                continue
            }

            guard isRecoveryReady() else {
                previous = nil
                readableFailureCount = 0
                try await Task.sleep(for: pollInterval)
                continue
            }
            readableFailureCount = 0
            if previous == candidate {
                return candidate
            }
            previous = candidate
            try await Task.sleep(for: pollInterval)
        }

        if let lastReadError {
            throw lastReadError
        }
        throw RemoteDesktopError.connectionFailed(
            "远控目标 authority 持久化事务未在期限内恢复可读"
        )
    }

    @MainActor
    static func captureCurrentAuthoritySnapshot(
        for device: DiscoveredDevice,
        timeout: Duration = .seconds(3)
    ) async throws -> LANRemoteControlCurrentPathAuthority {
        try await captureStableAuthoritySnapshot(
            timeout: timeout,
            isRecoveryReady: { PairingAcceptancePersistence.isRecoveryReady },
            readCurrent: {
                try await resolveTrustedRemoteAuthority(
                    for: device,
                    trustedDevices: try TrustedDeviceStore.shared.activeAuthoritySnapshot()
                )
            }
        )
    }

    @MainActor
    static func requireCurrentAuthoritySnapshot(
        _ authority: LANRemoteControlCurrentPathAuthority,
        for device: DiscoveredDevice,
        timeout: Duration = .seconds(3)
    ) async throws {
        let current = try await captureCurrentAuthoritySnapshot(
            for: device,
            timeout: timeout
        )
        guard current == authority else {
            throw RemoteDesktopError.connectionFailed(
                "远控目标 authority 在媒体握手期间已变更"
            )
        }
    }

    static func remoteControlSOAPeerId(for identifier: String?) -> Data? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return nil
        }
        let persistentIdentifier = PeerIdentityAliasResolver.persistentDeviceId(from: identifier) ?? identifier
        var normalized = persistentIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("id:") {
            normalized.removeFirst(3)
        }
        guard !normalized.isEmpty else { return nil }
        return Data(SHA256.hash(data: Data(normalized.utf8)))
    }

    static func randomRemoteControlAttemptId() -> Data {
        var bytes = [UInt8](repeating: 0, count: HandshakeSOAExtension.attemptIdLength)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return Data(bytes)
    }
}

@available(iOS 17.0, *)
extension RemoteDesktopManager {
    public nonisolated static func shouldContinueLANBootstrap(
        activeTransportModeIsLAN: Bool,
        isCurrentLANConnection: Bool,
        state: RemoteDesktopState
    ) -> Bool {
        guard activeTransportModeIsLAN, isCurrentLANConnection else { return false }
        if case .error = state {
            return false
        }
        return true
    }

    public nonisolated static func lanRemoteControlTrustBootstrapFailureReason(
        observedReply: Bool,
        bootstrapReady: Bool
    ) -> String? {
        guard !bootstrapReady else { return nil }
        return "stage=lan_remote_trust_bootstrap reason=metadata_kem_readiness_timeout observedReply=\(observedReply ? 1 : 0) noFallback=1"
    }
}
