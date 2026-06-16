import Foundation
import Network
import CryptoKit
import os
#if canImport(Security)
import Security
#endif

// MARK: - P2P连接
public final class P2PConnection: ObservableObject, Identifiable, @unchecked Sendable {
    private static let protocolIdentityLogRedaction = "<redacted>"

    public let id = UUID()
    public let device: P2PDevice
    public let connection: NWConnection

    @Published public private(set) var status: P2PConnectionStatus = .connecting
    @Published public private(set) var lastActivity: Date = Date()
    @Published public private(set) var bytesReceived: UInt64 = 0
    @Published public private(set) var bytesSent: UInt64 = 0
    @available(macOS 14.0, iOS 17.0, *)
    @Published public private(set) var assuranceLevel: P2PSessionAssuranceLevel = .unknown

    // Real, continuously updated quality signals (no simulated constants).
    @Published public private(set) var measuredLatency: TimeInterval = 0
    @Published public private(set) var measuredPacketLoss: Double = 0
    @Published public private(set) var measuredBandwidthBytesPerSecond: Double = 0

    // Handshake / session state (paper-aligned).
    @available(macOS 14.0, iOS 17.0, *)
    private let handshakeDriverLock = OSAllocatedUnfairLock<HandshakeDriver?>(initialState: nil)
    @available(macOS 14.0, iOS 17.0, *)
    private let sessionKeysLock = OSAllocatedUnfairLock<SessionKeys?>(initialState: nil)
    @available(macOS 14.0, iOS 17.0, *)
    private let remoteDesktopFrameHandlerLock = OSAllocatedUnfairLock<(@Sendable (Data, UInt64) -> Void)?>(initialState: nil)
    private var handshakePeer: PeerIdentifier
    private var handshakePeerDiagnosticLabel: String {
        SkyBridgeDiagnosticRedaction.stableIdentifierLabel(handshakePeer.deviceId)
    }
    private var deviceDiagnosticLabel: String {
        SkyBridgeDiagnosticRedaction.stableIdentifierLabel(device.deviceId)
    }

    @available(macOS 14.0, iOS 17.0, *)
    private struct MetricsState: Sendable {
        var lastTotalBytes: UInt64 = 0
        var lastBandwidthSampleAt: ContinuousClock.Instant?

        var lastPingSentAt: ContinuousClock.Instant?
        var outstandingPing: (id: UInt64, sentAt: ContinuousClock.Instant)?
        var pingResults: [Bool] = []  // true=success, false=timeout
    }

    @available(macOS 14.0, iOS 17.0, *)
    private let metricsLock = OSAllocatedUnfairLock(initialState: MetricsState())
    @available(macOS 14.0, iOS 17.0, *)
    private let rekeyInProgressLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    @available(macOS 14.0, iOS 17.0, *)
    private let bootstrapAssistedHandshakeLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    @available(macOS 14.0, iOS 17.0, *)
    private let lastPairingIdentityExchangeSentAtLock = OSAllocatedUnfairLock<Date?>(initialState: nil)
    @available(macOS 14.0, iOS 17.0, *)
    private let latestRemotePairingIdentityPayloadLock = OSAllocatedUnfairLock<AppMessage.PairingIdentityExchangePayload?>(initialState: nil)
    @available(macOS 14.0, iOS 17.0, *)
    private let soaPairKeyLock = OSAllocatedUnfairLock<Data?>(initialState: nil)
    @available(macOS 14.0, iOS 17.0, *)
    private let previousSessionKeysBeforeRekeyLock = OSAllocatedUnfairLock<SessionKeys?>(initialState: nil)
    @available(macOS 14.0, iOS 17.0, *)
    private let authenticatedRemoteAuthorityLock = OSAllocatedUnfairLock<AuthenticatedRemoteAuthority?>(initialState: nil)
    private var metricsTask: Task<Void, Never>?

    private var receiveTask: Task<Void, Never>?
    private let maxFrameBytes: UInt32 = 2_000_000

    @available(macOS 14.0, iOS 17.0, *)
    private struct DirectHandshakeTransport: DiscoveryTransport {
        let sendFramed: @Sendable (Data) async throws -> Void

        func send(to peer: PeerIdentifier, data: Data) async throws {
            try await sendFramed(data)
        }
    }

    public init(device: P2PDevice, connection: NWConnection) {
        self.device = device
        self.connection = connection
        self.handshakePeer = PeerIdentifier(
            deviceId: device.deviceId,
            displayName: device.name,
            address: "\(device.address):\(device.port)"
        )
    }

    deinit {
        disconnect()
    }

    private func resolveCurrentRemoteIP() -> String? {
        // Try active path first (most reliable)
        if let endpoint = connection.currentPath?.remoteEndpoint,
           case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let ipv4): return "\(ipv4)"
            case .ipv6(let ipv6): return "\(ipv6)"
            case .name(let name, _): return name
            default: break
            }
        }
        
        // Fallback to initial endpoint
        if case .hostPort(let host, _) = connection.endpoint {
             switch host {
             case .ipv4(let ipv4): return "\(ipv4)"
             case .ipv6(let ipv6): return "\(ipv6)"
             case .name(let name, _): return name
             default: break
             }
        }
        return nil
    }

    @available(macOS 14.0, iOS 17.0, *)
    func classicTransferEndpointHostOrIP() -> String? {
        resolveCurrentRemoteIP() ?? normalizedNonEmptyString(device.address)
    }

    @available(macOS 14.0, iOS 17.0, *)
    func classicTransferMatchDeviceId(
        remoteIdentityPayload: AppMessage.PairingIdentityExchangePayload? = nil
    ) -> String {
        let payload = remoteIdentityPayload ?? latestRemotePairingIdentityPayloadLock.withLock { $0 }
        return normalizedNonEmptyString(payload?.deviceId)
            ?? normalizedNonEmptyString(handshakePeer.deviceId)
            ?? normalizedNonEmptyString(device.persistentDeviceId)
            ?? normalizedNonEmptyString(device.deviceId)
            ?? device.deviceId
    }

    @available(macOS 14.0, iOS 17.0, *)
    func classicTransferResolvedPeerDeviceId(
        remoteIdentityPayload: AppMessage.PairingIdentityExchangePayload? = nil
    ) -> String {
        let payload = remoteIdentityPayload ?? latestRemotePairingIdentityPayloadLock.withLock { $0 }
        let preferred = [
            normalizedNonEmptyString(payload?.deviceId),
            normalizedNonEmptyString(device.persistentDeviceId),
            normalizedNonEmptyString(handshakePeer.deviceId),
            normalizedNonEmptyString(device.deviceId)
        ]

        for candidate in preferred {
            if let persistent = PeerTrustLookup.persistentDeviceId(from: candidate) {
                return persistent
            }
        }

        return preferred.compactMap { $0 }.first ?? device.deviceId
    }

    @available(macOS 14.0, iOS 17.0, *)
    func classicTransferPeerLookupAliases(
        remoteIdentityPayload: AppMessage.PairingIdentityExchangePayload? = nil
    ) -> [String] {
        let payload = remoteIdentityPayload ?? latestRemotePairingIdentityPayloadLock.withLock { $0 }
        let endpoint = classicTransferEndpointHostOrIP()
        let rawAliases: [String?] = [
            payload?.deviceId,
            payload?.deviceName,
            device.persistentDeviceId,
            handshakePeer.deviceId,
            device.deviceId,
            device.name,
            device.address,
            endpoint
        ] + device.endpoints.map(Optional.some)

        var aliases: [String] = []
        var seen = Set<String>()
        for raw in rawAliases {
            guard let raw = normalizedNonEmptyString(raw) else { continue }
            for candidate in PeerTrustLookup.lookupCandidates(for: raw) {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard seen.insert(trimmed.lowercased()).inserted else { continue }
                aliases.append(trimmed)
            }
        }
        return aliases
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func recordRemoteControlSecurityIdentity(
        from payload: AppMessage.PairingIdentityExchangePayload
    ) {
        let identity = RemoteControlSecurityIdentity(
            accountDisplayName: payload.accountDisplayName,
            nebulaId: payload.nebulaId,
            deviceId: payload.deviceId,
            deviceName: LocalDevicePresentation.sanitizedDisplayNameCandidate(payload.deviceName)
        )
        guard !identity.isEmpty else { return }

        let aliases = classicTransferPeerLookupAliases(remoteIdentityPayload: payload)
            + [
                payload.deviceId,
                LocalDevicePresentation.sanitizedDisplayNameCandidate(payload.deviceName),
                handshakePeer.deviceId,
                LocalDevicePresentation.sanitizedDisplayNameCandidate(handshakePeer.displayName),
                handshakePeer.address,
                device.persistentDeviceId,
                device.deviceId,
                device.name,
                device.address,
                classicTransferEndpointHostOrIP()
            ].compactMap { $0 }
        RemoteControlSecurityPeerIdentityStore.record(identity: identity, aliases: aliases)
    }

    @available(macOS 14.0, iOS 17.0, *)
    func classicTransferCapabilities(
        remoteIdentityPayload: AppMessage.PairingIdentityExchangePayload? = nil
    ) -> [String] {
        let payload = remoteIdentityPayload ?? latestRemotePairingIdentityPayloadLock.withLock { $0 }
        var values = device.capabilities
        values.append(contentsOf: payload?.capabilities ?? [])
        if let port = payload?.fileTransferPort, (1...65535).contains(Int(port)) {
            values.append("fileTransferPort=\(port)")
        }

        var deduped: [String] = []
        var seen = Set<String>()
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            deduped.append(trimmed)
        }
        return deduped
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func publishClassicTransferSessionSnapshot(
        keys: SessionKeys,
        remoteIdentityPayload: AppMessage.PairingIdentityExchangePayload? = nil
    ) async {
        let payload = remoteIdentityPayload ?? latestRemotePairingIdentityPayloadLock.withLock { $0 }
        let aliases = classicTransferPeerLookupAliases(remoteIdentityPayload: payload)
        let endpoint = classicTransferEndpointHostOrIP()
        let snapshot = ClassicTransferSessionSnapshot(
            sessionId: "p2p-\(id.uuidString)-\(keys.sessionId)",
            matchDeviceId: classicTransferMatchDeviceId(remoteIdentityPayload: payload),
            resolvedPeerDeviceId: classicTransferResolvedPeerDeviceId(remoteIdentityPayload: payload),
            aliases: aliases,
            endpointHostOrIP: endpoint,
            capabilities: classicTransferCapabilities(remoteIdentityPayload: payload),
            sessionKeys: keys
        )

        await ClassicTransferSessionRegistry.shared.upsert(session: snapshot)
        await ClassicTransferSessionRegistry.shared.upsert(
            connection: self,
            peerKeys: [snapshot.matchDeviceId, snapshot.resolvedPeerDeviceId]
                + aliases
                + [endpoint].compactMap { $0 }
        )
    }

    #if DEBUG
    @available(macOS 14.0, iOS 17.0, *)
    func testingSetClassicTransferRemoteIdentity(
        deviceId: String,
        fileTransferPort: UInt16? = nil,
        capabilities: [String]? = nil
    ) {
        latestRemotePairingIdentityPayloadLock.withLock {
            $0 = AppMessage.PairingIdentityExchangePayload(
                deviceId: deviceId,
                kemPublicKeys: [],
                capabilities: capabilities,
                fileTransferPort: fileTransferPort
            )
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    func testingSetHandshakePeerDeviceId(_ deviceId: String) {
        handshakePeer = PeerIdentifier(
            deviceId: deviceId,
            displayName: device.name,
            address: "\(device.address):\(device.port)"
        )
    }
    #endif

    // MARK: - Lifecycle

    public func markConnectedAndStartReceiving() {
        status = .connected
        lastActivity = Date()
        startReceivingIfNeeded()
    }

    /// Start frame receiving before application-layer authentication without promoting state to "connected".
    /// This avoids transport-ready false positives while still allowing handshake traffic.
    public func startReceivingForHandshake() {
        lastActivity = Date()
        startReceivingIfNeeded()
    }

    public func markFailed() {
        status = .failed
    }

    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        metricsTask?.cancel()
        metricsTask = nil
        if #available(macOS 14.0, iOS 17.0, *) {
            let peerIds = Array(
                Set(([handshakePeer.deviceId] + classicTransferPeerLookupAliases())
                    .compactMap { normalizedNonEmptyString($0) })
            )
            let displayName = device.name
            Task { @MainActor in
                for peerId in peerIds {
                    ConnectionPresenceService.shared.markDisconnected(peerId: peerId)
                    UnifiedOnlineDeviceManager.shared.markDeviceAsDisconnected(
                        peerId: peerId,
                        displayName: displayName
                    )
                }
            }
        }

        if #available(macOS 14.0, iOS 17.0, *) {
            let peerKeys = classicTransferPeerLookupAliases()
                + [device.deviceId, handshakePeer.deviceId, device.persistentDeviceId].compactMap { $0 }
            handshakeDriverLock.withLock { $0 = nil }
            sessionKeysLock.withLock { $0 = nil }
            previousSessionKeysBeforeRekeyLock.withLock { $0 = nil }
            authenticatedRemoteAuthorityLock.withLock { $0 = nil }
            lastPairingIdentityExchangeSentAtLock.withLock { $0 = nil }
            latestRemotePairingIdentityPayloadLock.withLock { $0 = nil }
            let stalePairKey = soaPairKeyLock.withLock { state -> Data? in
                let current = state
                state = nil
                return current
            }
            metricsLock.withLock { state in
                state.lastBandwidthSampleAt = nil
                state.lastPingSentAt = nil
                state.outstandingPing = nil
                state.pingResults.removeAll()
            }
            rekeyInProgressLock.withLock { $0 = false }
            bootstrapAssistedHandshakeLock.withLock { $0 = false }
            if let stalePairKey {
                Task {
                    await PeerSessionArbiter.shared.clearEstablished(pairKey: stalePairKey)
                    await PeerSessionArbiter.shared.clearOutgoing(pairKey: stalePairKey, attemptId: nil)
                }
            }
            Task {
                await ClassicTransferSessionRegistry.shared.remove(peerKeys: peerKeys)
            }
        }
        connection.cancel()
        status = .disconnected
        measuredLatency = 0
        measuredPacketLoss = 0
        measuredBandwidthBytesPerSecond = 0
        if #available(macOS 14.0, iOS 17.0, *) {
            assuranceLevel = .unknown
        }
    }

    // MARK: - Authentication (HandshakeDriver)

    public func authenticate() async throws {
        await MainActor.run { self.status = .authenticating }

        guard #available(macOS 14.0, iOS 17.0, *) else {
            throw P2PConnectionError.handshakeUnavailable
        }

        authenticatedRemoteAuthorityLock.withLock { $0 = nil }
        latestRemotePairingIdentityPayloadLock.withLock { $0 = nil }

        handshakePeer = await resolveHandshakePeerIdentifier()
        if handshakePeer.deviceId != device.deviceId {
            SkyBridgeLogger.p2p.info(
                "🧭 Handshake peer id normalized: raw=\(self.deviceDiagnosticLabel, privacy: .public) resolved=\(self.handshakePeerDiagnosticLabel, privacy: .public)"
            )
        }
        startReceivingIfNeeded()

        do {
            let keys = try await performHandshake()
            sessionKeysLock.withLock { $0 = keys }
            handshakeDriverLock.withLock { $0 = nil }
            if shouldUseSOA() {
                let pairKey = await currentSOAPairKey()
                soaPairKeyLock.withLock { $0 = pairKey }
            } else {
                soaPairKeyLock.withLock { $0 = nil }
            }
            await MainActor.run { self.status = .authenticated }
            let peerKeys = [device.deviceId, handshakePeer.deviceId, device.persistentDeviceId].compactMap { $0 }
            await ClassicTransferSessionRegistry.shared.upsert(connection: self, peerKeys: peerKeys)
            await publishAuthenticatedPresence(keys: keys)
            schedulePostAuthPairingIdentityExchange()
            startMetricsIfNeeded()
        } catch {
            soaPairKeyLock.withLock { $0 = nil }
            authenticatedRemoteAuthorityLock.withLock { $0 = nil }
            latestRemotePairingIdentityPayloadLock.withLock { $0 = nil }
            let peerKeys = [device.deviceId, handshakePeer.deviceId, device.persistentDeviceId].compactMap { $0 }
            await ClassicTransferSessionRegistry.shared.remove(peerKeys: peerKeys)
            await MainActor.run { self.status = .failed }
            throw error
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func performHandshake() async throws -> SessionKeys {
        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
        let policy = HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)
        let selection: CryptoProviderFactory.SelectionPolicy = policy.requirePQC ? .requirePQC : .preferPQC
        let requestedProvider = CryptoProviderFactory.make(policy: selection)

        do {
            let sessionKeys = try await performHandshakeAttempt(
                policy: policy,
                selectionPolicy: selection,
                preferPQC: true
            )
            return await finalizeAuthenticatedSession(sessionKeys, policy: policy)
        } catch {
            if let sessionKeys = try await performPQCBootstrapRecoveryIfNeeded(
                for: error,
                requestedPolicy: policy,
                requestedSelection: selection,
                requestedProvider: requestedProvider
            ) {
                return await finalizeAuthenticatedSession(sessionKeys, policy: policy)
            }

            if let sessionKeys = try await performPQCKeyRefreshBootstrapRecoveryIfNeeded(
                for: error,
                requestedPolicy: policy,
                requestedSelection: selection,
                requestedProvider: requestedProvider
            ) {
                return await finalizeAuthenticatedSession(sessionKeys, policy: policy)
            }

            bootstrapAssistedHandshakeLock.withLock { $0 = false }
            await logSuiteNegotiationDiagnosticsIfNeeded(error, policy: policy, cryptoProvider: requestedProvider)
            throw error
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func finalizeAuthenticatedSession(
        _ sessionKeys: SessionKeys,
        policy: HandshakePolicy
    ) async -> SessionKeys {
        let usedBootstrapAssistedPath = bootstrapAssistedHandshakeLock.withLock { state in
            let current = state
            state = false
            return current
        }
        let assurance = Self.classifySessionAssurance(
            policy: policy,
            negotiatedSuite: sessionKeys.negotiatedSuite,
            bootstrapAssisted: usedBootstrapAssistedPath
        )
        await MainActor.run {
            self.assuranceLevel = assurance
        }
        SkyBridgeLogger.p2p.info(
            "🔐 Session assurance: \(assurance.rawValue, privacy: .public) suite=\(sessionKeys.negotiatedSuite.rawValue, privacy: .public) requirePQC=\(policy.requirePQC, privacy: .public) bootstrapAssisted=\(usedBootstrapAssistedPath, privacy: .public)"
        )

        await publishAuthenticatedPresence(keys: sessionKeys)
        return sessionKeys
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func performHandshakeAttempt(
        policy: HandshakePolicy,
        selectionPolicy: CryptoProviderFactory.SelectionPolicy,
        preferPQC: Bool,
        allowSOA: Bool = true
    ) async throws -> SessionKeys {
        let baseProvider = CryptoProviderFactory.make(policy: selectionPolicy)

        let transport = DirectHandshakeTransport(sendFramed: { [weak self] data in
            guard let self else { throw P2PConnectionError.disconnected }
            try await self.sendFramed(data)
        })

        handshakeDriverLock.withLock { $0 = nil }
        let shouldAdvertiseSOA = allowSOA && shouldUseSOA()
        let hadEstablishedSession = sessionKeysLock.withLock { $0 != nil }
        let localSOAPeerId: Data? = shouldAdvertiseSOA ? await localSOAPeerIdBytes() : nil
        let expectedRemoteSOAPeerId: Data?
        if shouldAdvertiseSOA {
            expectedRemoteSOAPeerId = remoteSOAPeerIdBytes(for: handshakePeer.deviceId)
        } else {
            expectedRemoteSOAPeerId = nil
        }
        let rekeyPairKey: Data?
        if shouldAdvertiseSOA, hadEstablishedSession {
            if let existingPairKey = soaPairKeyLock.withLock({ $0 }) {
                rekeyPairKey = existingPairKey
            } else {
                rekeyPairKey = await currentSOAPairKey()
            }
                if let rekeyPairKey {
                SkyBridgeLogger.p2p.info(
                    "🧩 outbound rekey: releasing SOA established guard. peer=\(self.handshakePeerDiagnosticLabel, privacy: .public)"
                )
                await PeerSessionArbiter.shared.clearEstablished(pairKey: rekeyPairKey)
                await PeerSessionArbiter.shared.clearOutgoing(pairKey: rekeyPairKey, attemptId: nil)
            }
        } else {
            rekeyPairKey = nil
        }

        do {
            return try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
                deviceId: handshakePeer.deviceId,
                preferPQC: preferPQC,
                policy: policy,
                cryptoProvider: baseProvider
            ) { [weak self] preparation in
                guard let self else { throw P2PConnectionError.disconnected }

                let cryptoProvider: any CryptoProvider = {
                    switch preparation.strategy {
                    case .pqcOnly:
                        return CryptoProviderFactory.make(policy: selectionPolicy)
                    case .classicOnly:
                        return CryptoProviderFactory.make(policy: .classicOnly)
                    }
                }()

                let identityProvider = DeviceIdentityHandshakeProvider(
                    sigAAlgorithm: preparation.sigAAlgorithm,
                    includeSecureEnclavePoP: policy.requireSecureEnclavePoP
                )

                let outboundSOA: HandshakeSOAMetadata? = {
                    guard shouldAdvertiseSOA,
                          let localSOAPeerId,
                          let expectedRemoteSOAPeerId else {
                        return nil
                    }
                    return try? HandshakeSOAMetadata(
                        initiatorPeerId: localSOAPeerId,
                        targetPeerId: expectedRemoteSOAPeerId,
                        attemptId: Self.randomAttemptIdBytes()
                    )
                }()

                let cryptoPolicy = HandshakeCryptoPolicyResolver.policy(for: preparation.offeredSuites)
                let driver = try HandshakeDriver(
                    transport: transport,
                    cryptoProvider: cryptoProvider,
                    protocolSignatureProvider: ProtocolSignatureProviderSelector.select(for: preparation.sigAAlgorithm),
                    identityProvider: identityProvider,
                    sigAAlgorithm: preparation.sigAAlgorithm,
                    offeredSuites: preparation.offeredSuites,
                    policy: policy,
                    cryptoPolicy: cryptoPolicy,
                    soaMetadata: outboundSOA,
                    localSOAPeerId: localSOAPeerId,
                    expectedRemoteSOAPeerId: expectedRemoteSOAPeerId
                )
                self.handshakeDriverLock.withLock { $0 = driver }
                let sessionKeys = try await driver.initiateHandshake(with: self.handshakePeer)
                await self.captureAuthenticatedRemoteAuthority(from: driver)
                return sessionKeys
            }
        } catch {
            if hadEstablishedSession, let rekeyPairKey {
                SkyBridgeLogger.p2p.info(
                    "🧩 outbound rekey: restoring SOA established guard after failed rekey. peer=\(self.handshakePeerDiagnosticLabel, privacy: .public)"
                )
                await PeerSessionArbiter.shared.markEstablished(pairKey: rekeyPairKey)
            }
            throw error
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func performPQCBootstrapRecoveryIfNeeded(
        for error: Error,
        requestedPolicy: HandshakePolicy,
        requestedSelection: CryptoProviderFactory.SelectionPolicy,
        requestedProvider: any CryptoProvider
    ) async throws -> SessionKeys? {
        let requiredPQCSuites = requestedProvider.supportedSuites.filter { $0.isPQCGroup }
        let requiredWireIds = Set(requiredPQCSuites.map { $0.canonicalKEMSuite.wireId })
        guard !requiredWireIds.isEmpty else { return nil }

        let hasRequiredPeerKEM = await hasRequiredPeerKEMPublicKeys(requiredWireIds: requiredWireIds)

        guard Self.shouldAttemptPQCBootstrapRecovery(
            policy: requestedPolicy,
            error: error,
            hasRequiredPeerKEM: hasRequiredPeerKEM,
            requestedSelection: requestedSelection
        ) else {
            return nil
        }

        let targetSuites = requiredPQCSuites.map(\.rawValue).joined(separator: ",")
        let recoveryMode = requestedPolicy.requirePQC ? "strictPQC" : "preferredPQC"
        SkyBridgeLogger.p2p.info(
            "🧩 \(recoveryMode, privacy: .public) bootstrap start: peer=\(self.handshakePeerDiagnosticLabel, privacy: .public) target=\(targetSuites, privacy: .public)"
        )

        do {
            let classicKeys = try await performHandshakeAttempt(
                policy: .default,
                selectionPolicy: .classicOnly,
                preferPQC: false
            )
            sessionKeysLock.withLock { $0 = classicKeys }
            handshakeDriverLock.withLock { $0 = nil }
            bootstrapAssistedHandshakeLock.withLock { $0 = true }

            try await sendPairingIdentityExchange(force: true)
            let readyForPQC = await waitForPeerKEMPublicKeys(
                requiredSuites: requiredPQCSuites,
                timeoutSeconds: 8
            )
            guard readyForPQC else {
                SkyBridgeLogger.p2p.warning(
                    "⏳ \(recoveryMode, privacy: .public) bootstrap 未在时限内收到对端 KEM 公钥: peer=\(self.handshakePeerDiagnosticLabel, privacy: .public)"
                )
                sessionKeysLock.withLock { $0 = nil }
                bootstrapAssistedHandshakeLock.withLock { $0 = false }
                return nil
            }

            let sessionKeys = try await performHandshakeAttempt(
                policy: requestedPolicy,
                selectionPolicy: requestedSelection,
                preferPQC: true
            )
            return sessionKeys
        } catch {
            sessionKeysLock.withLock { $0 = nil }
            handshakeDriverLock.withLock { $0 = nil }
            bootstrapAssistedHandshakeLock.withLock { $0 = false }
            throw error
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func performPQCKeyRefreshBootstrapRecoveryIfNeeded(
        for error: Error,
        requestedPolicy: HandshakePolicy,
        requestedSelection: CryptoProviderFactory.SelectionPolicy,
        requestedProvider: any CryptoProvider
    ) async throws -> SessionKeys? {
        let requiredPQCSuites = requestedProvider.supportedSuites.filter { $0.isPQCGroup }
        let requiredWireIds = Set(requiredPQCSuites.map { $0.canonicalKEMSuite.wireId })
        guard !requiredWireIds.isEmpty else { return nil }

        let hasRequiredPeerKEM = await hasRequiredPeerKEMPublicKeys(requiredWireIds: requiredWireIds)
        guard Self.shouldAttemptPQCKeyRefreshBootstrapRecovery(
            policy: requestedPolicy,
            error: error,
            hasRequiredPeerKEM: hasRequiredPeerKEM,
            requestedSelection: requestedSelection
        ) else {
            return nil
        }

        let baselinePeerKEM = await currentKnownPeerKEMPublicKeysByCanonicalWireId()
        let targetSuites = requiredPQCSuites.map(\.rawValue).joined(separator: ",")
        let recoveryMode = requestedPolicy.requirePQC ? "strictPQC" : "preferredPQC"
        SkyBridgeLogger.p2p.info(
            "🧩 \(recoveryMode, privacy: .public) key-refresh bootstrap start: peer=\(self.handshakePeerDiagnosticLabel, privacy: .public) target=\(targetSuites, privacy: .public)"
        )

        do {
            let classicKeys = try await performHandshakeAttempt(
                policy: .default,
                selectionPolicy: .classicOnly,
                preferPQC: false
            )
            sessionKeysLock.withLock { $0 = classicKeys }
            handshakeDriverLock.withLock { $0 = nil }
            bootstrapAssistedHandshakeLock.withLock { $0 = true }

            try await sendPairingIdentityExchange(force: true)
            let refreshedPeerKEM = await waitForPeerKEMPublicKeys(
                requiredSuites: requiredPQCSuites,
                timeoutSeconds: 8,
                requiringFreshKeyMaterialComparedTo: baselinePeerKEM
            )
            guard refreshedPeerKEM else {
                SkyBridgeLogger.p2p.warning(
                    "⏳ \(recoveryMode, privacy: .public) key-refresh bootstrap 未在时限内刷新对端 KEM 公钥: peer=\(self.handshakePeerDiagnosticLabel, privacy: .public)"
                )
                sessionKeysLock.withLock { $0 = nil }
                bootstrapAssistedHandshakeLock.withLock { $0 = false }
                return nil
            }

            let sessionKeys = try await performHandshakeAttempt(
                policy: requestedPolicy,
                selectionPolicy: requestedSelection,
                preferPQC: true
            )
            return sessionKeys
        } catch {
            sessionKeysLock.withLock { $0 = nil }
            handshakeDriverLock.withLock { $0 = nil }
            bootstrapAssistedHandshakeLock.withLock { $0 = false }
            throw error
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    nonisolated static func shouldAttemptStrictPQCBootstrap(
        policy: HandshakePolicy,
        error: Error,
        hasRequiredPeerKEM: Bool
    ) -> Bool {
        false
    }

    @available(macOS 14.0, iOS 17.0, *)
    nonisolated static func shouldAttemptPQCBootstrapRecovery(
        policy: HandshakePolicy,
        error: Error,
        hasRequiredPeerKEM: Bool,
        requestedSelection: CryptoProviderFactory.SelectionPolicy
    ) -> Bool {
        guard requestedSelection != .classicOnly else { return false }
        if policy.requirePQC {
            return shouldAttemptStrictPQCBootstrap(
                policy: policy,
                error: error,
                hasRequiredPeerKEM: hasRequiredPeerKEM
            )
        }

        guard !hasRequiredPeerKEM else { return false }
        guard let handshakeError = error as? HandshakeError,
              case .failed(.suiteNegotiationFailed) = handshakeError else {
            return false
        }
        return true
    }

    @available(macOS 14.0, iOS 17.0, *)
    nonisolated static func shouldAttemptStrictPQCKeyRefreshBootstrap(
        policy: HandshakePolicy,
        error: Error,
        hasRequiredPeerKEM: Bool
    ) -> Bool {
        false
    }

    @available(macOS 14.0, iOS 17.0, *)
    nonisolated static func shouldAttemptPQCKeyRefreshBootstrapRecovery(
        policy: HandshakePolicy,
        error: Error,
        hasRequiredPeerKEM: Bool,
        requestedSelection: CryptoProviderFactory.SelectionPolicy
    ) -> Bool {
        guard requestedSelection != .classicOnly else { return false }
        if policy.requirePQC {
            return shouldAttemptStrictPQCKeyRefreshBootstrap(
                policy: policy,
                error: error,
                hasRequiredPeerKEM: hasRequiredPeerKEM
            )
        }

        guard hasRequiredPeerKEM else { return false }
        guard let handshakeError = error as? HandshakeError,
              case .failed(let reason) = handshakeError else {
            return false
        }

        switch reason {
        case .cryptoError(let detail):
            return looksLikeStalePeerKEMCryptoFailure(detail)
        case .timeout:
            return true
        case .transportError(let detail):
            return looksLikeStalePeerKEMTransportFailure(detail)
        default:
            return false
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    nonisolated static func looksLikeStalePeerKEMCryptoFailure(_ detail: String) -> Bool {
        let normalized = detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        let markers = [
            "cryptokiterror",
            "aead",
            "authentication failure",
            "decrypt",
            "decryption",
            "failed to open"
        ]
        return markers.contains(where: normalized.contains)
    }

    @available(macOS 14.0, iOS 17.0, *)
    nonisolated static func looksLikeStalePeerKEMTransportFailure(_ detail: String) -> Bool {
        let normalized = detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        let markers = [
            "connection reset by peer",
            "connection refused",
            "error 54",
            "error 61"
        ]
        return markers.contains(where: normalized.contains)
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func resolveHandshakePeerIdentifier() async -> PeerIdentifier {
        let fallback = PeerIdentifier(
            deviceId: device.deviceId,
            displayName: device.name,
            address: "\(device.address):\(device.port)"
        )

        let candidates = trustLookupCandidates(
            primary: fallback.deviceId,
            persistent: device.persistentDeviceId
        )
        let fingerprint = normalizedFingerprint(device.pubKeyFingerprint)

        let resolvedId: String = await MainActor.run {
            let trust = TrustSyncService.shared

            for candidate in candidates {
                if trust.getTrustRecord(deviceId: candidate) != nil {
                    return candidate
                }
            }

            if let fingerprint {
                let matches = trust.activeTrustRecords.filter { record in
                    !record.pubKeyFP.isEmpty && record.pubKeyFP.caseInsensitiveCompare(fingerprint) == .orderedSame
                }
                if let resolvedRecord = resolvedUniqueTrustRecord(from: matches),
                   !resolvedRecord.deviceId.isEmpty {
                    return resolvedRecord.deviceId
                }
            }

            return candidates.first ?? fallback.deviceId
        }

        return PeerIdentifier(
            deviceId: resolvedId,
            displayName: fallback.displayName,
            address: fallback.address
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    static func shouldAdvertiseSOAForCurrentPath(
        capabilities: [String],
        handshakePeerDeviceId: String,
        connectionDeviceId: String,
        persistentDeviceId: String?
    ) -> Bool {
        let normalizedCapabilities = Set(capabilities.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        if normalizedCapabilities.contains("hs_soa") {
            return true
        }

        return [handshakePeerDeviceId, connectionDeviceId, persistentDeviceId].compactMap { $0 }.contains { candidate in
            Self.strongSOARemoteIdentity(candidate) != nil
        }
    }

    private func shouldUseSOA() -> Bool {
        Self.shouldAdvertiseSOAForCurrentPath(
            capabilities: device.capabilities,
            handshakePeerDeviceId: handshakePeer.deviceId,
            connectionDeviceId: device.deviceId,
            persistentDeviceId: device.persistentDeviceId
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func localSOAPeerIdBytes() async -> Data {
        let deviceId = await SelfIdentityProvider.shared.protocolIdentityDeviceId(allowCreate: true)
        if !deviceId.isEmpty {
            return Self.soaPeerIdBytes(from: deviceId)
        }
        return Self.soaPeerIdBytes(from: Host.current().localizedName ?? "mac-local")
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func remoteSOAPeerIdBytes(for peerId: String) -> Data? {
        guard let strongIdentity = Self.strongSOARemoteIdentity(peerId) else {
            return nil
        }
        return Self.soaPeerIdBytes(from: strongIdentity)
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func currentSOAPairKey() async -> Data? {
        let local = await localSOAPeerIdBytes()
        guard let remote = remoteSOAPeerIdBytes(for: handshakePeer.deviceId) else {
            return nil
        }
        return PeerSessionArbiter.pairKey(localPeerId: local, remotePeerId: remote)
    }

    private nonisolated static func soaPeerIdBytes(from raw: String) -> Data {
        let canonical = canonicalSOAIdentityString(raw)
        return Data(SHA256.hash(data: Data(canonical.utf8)))
    }

    private nonisolated static func canonicalSOAIdentityString(_ raw: String) -> String {
        PeerSessionArbiter.canonicalSOAIdentifier(raw)
    }

    private nonisolated static func strongSOARemoteIdentity(_ raw: String) -> String? {
        let canonical = canonicalSOAIdentityString(raw)
        guard !canonical.isEmpty else { return nil }
        guard UUID(uuidString: canonical.uppercased()) != nil else {
            return nil
        }
        return canonical
    }

    private nonisolated static func randomAttemptIdBytes() -> Data {
        var bytes = [UInt8](repeating: 0, count: HandshakeSOAExtension.attemptIdLength)
        #if canImport(Security)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for idx in bytes.indices {
                bytes[idx] = UInt8.random(in: UInt8.min...UInt8.max)
            }
        }
        #else
        for idx in bytes.indices {
            bytes[idx] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        #endif
        return Data(bytes)
    }

    private func trustLookupCandidates(primary: String, persistent: String?) -> [String] {
        PeerTrustLookup.lookupCandidates(primary: primary, persistent: persistent)
    }

    private func normalizeHostAlias(_ identifier: String) -> String? {
        if identifier.hasPrefix("host:") {
            return normalizeHostAliasFromIPAddress(String(identifier.dropFirst("host:".count)))
        }
        if identifier.hasPrefix("peer:") {
            return normalizeHostAliasFromIPAddress(String(identifier.dropFirst("peer:".count)))
        }
        return nil
    }

    private func normalizeHostAliasFromIPAddress(_ raw: String?) -> String? {
        guard var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !token.isEmpty else {
            return nil
        }

        if token.hasPrefix("host:") {
            token = String(token.dropFirst("host:".count))
        } else if token.hasPrefix("peer:") {
            token = String(token.dropFirst("peer:".count))
        }

        if token.hasPrefix("[") && token.hasSuffix("]") && token.count >= 2 {
            token = String(token.dropFirst().dropLast())
        }
        if let percent = token.firstIndex(of: "%") {
            token = String(token[..<percent])
        }

        if token.contains(":"),
           let dot = token.lastIndex(of: "."),
           token[token.index(after: dot)...].allSatisfy({ $0.isNumber }) {
            token = String(token[..<dot])
        } else {
            let parts = token.split(separator: ".")
            if parts.count == 5,
               parts.dropLast().allSatisfy({ Int($0) != nil }),
               let port = Int(parts.last ?? ""),
               (0...65535).contains(port) {
                token = parts.dropLast().map(String.init).joined(separator: ".")
            }
        }

        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return "host:\(normalized)"
    }

    private func normalizeBonjourIdentifier(_ identifier: String) -> String? {
        guard identifier.hasPrefix("bonjour:") else { return nil }
        let payload = String(identifier.dropFirst("bonjour:".count))
        let pieces = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let rawName = pieces.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty else { return nil }
        let rawDomain = pieces.count > 1 ? pieces[1] : "local"
        let domain = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "local"
            : rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "bonjour:\(rawName)@\(domain)"
    }

    private func normalizedFingerprint(_ fingerprint: String?) -> String? {
        guard let raw = fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw.lowercased()
    }

    private func extractDisplayNameAlias(from identifier: String) -> String? {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("recent:name:") {
            let payload = String(normalized.dropFirst("recent:name:".count))
            return payload.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if normalized.hasPrefix("name:") {
            let payload = String(normalized.dropFirst("name:".count))
            return payload.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func normalizedDisplayName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private func capabilityValue(prefix: String, in capabilities: [String]) -> String? {
        for capability in capabilities {
            guard capability.hasPrefix(prefix) else { continue }
            let value = String(capability.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    @MainActor
    private func trustRecordsMatchingCandidates(_ candidates: [String]) -> [TrustRecord] {
        let normalizedCandidates = Set(candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        guard !normalizedCandidates.isEmpty else { return [] }
        let normalizedCandidatesLower = Set(normalizedCandidates.map { $0.lowercased() })

        var matchedByDeviceId: [String: TrustRecord] = [:]
        for record in TrustSyncService.shared.activeTrustRecords where !record.isTombstone {
            if PeerTrustLookup.recordMatches(
                record,
                candidates: normalizedCandidates,
                candidateLowercased: normalizedCandidatesLower
            ) {
                matchedByDeviceId[record.deviceId] = record
            }
        }

        return Array(matchedByDeviceId.values)
    }

    @available(macOS 14.0, iOS 17.0, *)
    @MainActor
    private func resolvedUniqueTrustRecord(from matches: [TrustRecord]) -> TrustRecord? {
        let activeMatches = matches.filter { !$0.isTombstone && !$0.isExpired }
        guard !activeMatches.isEmpty else { return nil }
        if activeMatches.count == 1 {
            return activeMatches[0]
        }

        let groups = TrustSyncService.buildDisplayGroups(from: activeMatches)
        guard groups.count == 1 else { return nil }
        return groups[0].displayRecord
    }

    @available(macOS 14.0, iOS 17.0, *)
    private struct SuiteNegotiationTrustDiagnostic: Sendable {
        let resolvedId: String?
        let hasTrust: Bool
        let kemSuiteWireIds: [UInt16]
        let matchedBy: String
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func resolveSuiteNegotiationTrustDiagnostic() async -> SuiteNegotiationTrustDiagnostic {
        let fallback = PeerIdentifier(
            deviceId: device.deviceId,
            displayName: device.name,
            address: "\(device.address):\(device.port)"
        )
        let candidates = trustLookupCandidates(primary: fallback.deviceId, persistent: device.persistentDeviceId)
        let fingerprint = normalizedFingerprint(device.pubKeyFingerprint)
        let alias = extractDisplayNameAlias(from: fallback.deviceId) ?? normalizedDisplayName(fallback.displayName)

        var diagnostic = await MainActor.run {
            let trust = TrustSyncService.shared
            for candidate in candidates {
                if let record = trust.getTrustRecord(deviceId: candidate) {
                    let kemIds = record.kemPublicKeys?.map(\.suiteWireId) ?? []
                    return SuiteNegotiationTrustDiagnostic(
                        resolvedId: candidate,
                        hasTrust: true,
                        kemSuiteWireIds: kemIds,
                        matchedBy: "candidate"
                    )
                }
            }

            let related = trustRecordsMatchingCandidates(candidates)
            if !related.isEmpty {
                let kemUnion = Set(related
                    .flatMap { $0.kemPublicKeys?.map(\.suiteWireId) ?? [] })
                    .sorted()
                return SuiteNegotiationTrustDiagnostic(
                    resolvedId: related.first?.deviceId,
                    hasTrust: true,
                    kemSuiteWireIds: kemUnion,
                    matchedBy: "candidateAlias"
                )
            }

            if let fingerprint {
                let matches = trust.activeTrustRecords.filter { record in
                    !record.pubKeyFP.isEmpty && record.pubKeyFP.caseInsensitiveCompare(fingerprint) == .orderedSame
                }
                if let resolvedRecord = resolvedUniqueTrustRecord(from: matches),
                   !resolvedRecord.deviceId.isEmpty {
                    let kemIds = Set(matches
                        .flatMap { $0.kemPublicKeys?.map(\.suiteWireId) ?? [] })
                        .sorted()
                    return SuiteNegotiationTrustDiagnostic(
                        resolvedId: resolvedRecord.deviceId,
                        hasTrust: true,
                        kemSuiteWireIds: kemIds,
                        matchedBy: "fingerprint"
                    )
                }
            }

            if let alias {
                let matches = trust.activeTrustRecords.filter { record in
                    guard let recordName = record.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !recordName.isEmpty else { return false }
                    return recordName.caseInsensitiveCompare(alias) == .orderedSame
                }
                if let resolvedRecord = resolvedUniqueTrustRecord(from: matches),
                   !resolvedRecord.deviceId.isEmpty {
                    let kemIds = Set(matches
                        .flatMap { $0.kemPublicKeys?.map(\.suiteWireId) ?? [] })
                        .sorted()
                    return SuiteNegotiationTrustDiagnostic(
                        resolvedId: resolvedRecord.deviceId,
                        hasTrust: true,
                        kemSuiteWireIds: kemIds,
                        matchedBy: "name"
                    )
                }
            }

            return SuiteNegotiationTrustDiagnostic(
                resolvedId: nil,
                hasTrust: false,
                kemSuiteWireIds: [],
                matchedBy: "none"
            )
        }

        let cachedSuites = await PeerKEMBootstrapStore.shared.availableSuiteWireIds(forCandidates: candidates)
        guard !cachedSuites.isEmpty else { return diagnostic }

        let mergedSuites = Set(diagnostic.kemSuiteWireIds).union(cachedSuites).sorted()
        let matchedBy: String = {
            if diagnostic.matchedBy == "none" {
                return "bootstrapCache"
            }
            return "\(diagnostic.matchedBy)+bootstrapCache"
        }()
        let resolvedId = diagnostic.resolvedId ?? candidates.first
        diagnostic = SuiteNegotiationTrustDiagnostic(
            resolvedId: resolvedId,
            hasTrust: diagnostic.hasTrust,
            kemSuiteWireIds: mergedSuites,
            matchedBy: matchedBy
        )
        return diagnostic
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func logSuiteNegotiationDiagnosticsIfNeeded(
        _ error: Error,
        policy: HandshakePolicy,
        cryptoProvider: any CryptoProvider
    ) async {
        guard let handshakeError = error as? HandshakeError,
              case .failed(.suiteNegotiationFailed) = handshakeError else {
            return
        }
        let diag = await resolveSuiteNegotiationTrustDiagnostic()

        let requiredPQC = cryptoProvider.supportedSuites
            .filter { $0.isPQCGroup }
            .map(\.wireId)

        let missingPQC = requiredPQC.filter { !diag.kemSuiteWireIds.contains($0) }
	        let requiredPQCSummary = requiredPQC.map(String.init).joined(separator: ",")
	        let knownKEMSummary = diag.kemSuiteWireIds.map(String.init).joined(separator: ",")
	        let missingKEMSummary = missingPQC.map(String.init).joined(separator: ",")
	        let resolvedTrustId = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(diag.resolvedId)
	        let policyRequirePQC = policy.requirePQC ? "1" : "0"
	        let policyAllowClassicFallback = policy.allowClassicFallback ? "1" : "0"
	        let diagnostic = "🧩 握手协商失败诊断: peer=\(handshakePeerDiagnosticLabel) " +
	            "policy(requirePQC=\(policyRequirePQC),allowClassicFallback=\(policyAllowClassicFallback)) " +
	            "trustResolved=\(resolvedTrustId) by=\(diag.matchedBy) " +
            "requiredPQC=\(requiredPQCSummary) knownKEM=\(knownKEMSummary) missingKEM=\(missingKEMSummary)"
        SkyBridgeLogger.p2p.warning("\(diagnostic, privacy: .public)")

        if policy.requirePQC && (!diag.hasTrust || !missingPQC.isEmpty) {
            SkyBridgeLogger.p2p.warning(
                "🔐 strictPQC 当前缺少对端 KEM 公钥。请先完成配对/信任引导（交换 KEM identity keys）后重试。"
            )
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func schedulePostAuthPairingIdentityExchange() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sendPostAuthPairingIdentityExchangeWithTimeout()
            } catch {
                SkyBridgeLogger.p2p.info(
                    "ℹ️ optional post-auth pairingIdentityExchange deferred: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                )
            }
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func sendPostAuthPairingIdentityExchangeWithTimeout(timeoutSeconds: TimeInterval = 2) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw P2PConnectionError.disconnected }
                try await self.sendPairingIdentityExchange(force: true)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw P2PConnectionError.postAuthPairingIdentityExchangeTimeout
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func sendPairingIdentityExchange(force: Bool = false) async throws {
        let now = Date()
        if !force {
            let canSend = lastPairingIdentityExchangeSentAtLock.withLock { last in
                guard let last else { return true }
                return now.timeIntervalSince(last) >= 10
            }
            guard canSend else { return }
        }

        let provider = CryptoProviderFactory.make(policy: .preferPQC)
        let keyManager = DeviceIdentityKeyManager.shared
        let kemKeys = KEMPublicKeyInfo.normalizedValidKeys(
            try await keyManager.pairingIdentityKEMPublicKeys(using: provider)
        )
        guard !kemKeys.isEmpty else {
            SkyBridgeLogger.p2p.warning("⚠️ 跳过 pairingIdentityExchange：本机 KEM 公钥为空")
            return
        }

        let localDeviceIdRaw = await keyManager.getDeviceId()
        let localDeviceId = localDeviceIdRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localDeviceId.isEmpty else {
            SkyBridgeLogger.p2p.warning("⚠️ 跳过 pairingIdentityExchange：本机 deviceId 为空")
            return
        }
        let protocolIdentityPublicKeys = await localProtocolIdentityPublicKeysForPairing()
        let localPresentation = LocalDevicePresentation.current()
        let localIdentity = RemoteControlSecurityNoticeCenter.cachedLocalIdentitySnapshot()

        let message = AppMessage.pairingIdentityExchange(.init(
            deviceId: localDeviceId,
            kemPublicKeys: kemKeys,
            protocolIdentityPublicKeys: protocolIdentityPublicKeys,
            deviceName: localPresentation.deviceName,
            modelName: localPresentation.modelName,
            platform: localPresentation.platformName,
            osVersion: localPresentation.osVersion,
            chip: nil,
            accountDisplayName: localIdentity?.accountDisplayName,
            nebulaId: localIdentity?.nebulaId,
            capabilities: ["clipboard_sync", "file_transfer", "remote_desktop", "remote_control", ClassicTransferCapability.classicResume],
            fileTransferPort: ServiceEndpointRegistry.shared.snapshot().fileTransferPort,
            remoteControlPort: ServiceEndpointRegistry.shared.snapshot().remoteControlPort
        ))
        try await sendEncryptedAppMessage(message)
        lastPairingIdentityExchangeSentAtLock.withLock { $0 = now }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func localProtocolIdentityPublicKeysForPairing() async -> [AppMessage.ProtocolIdentityPublicKeyInfo] {
        var keys: [AppMessage.ProtocolIdentityPublicKeyInfo] = []
        for algorithm in [ProtocolSigningAlgorithm.ed25519, .mlDSA65] {
            do {
                let publicKey = try await DeviceIdentityKeyManager.shared.getProtocolSigningPublicKey(for: algorithm)
                keys.append(.init(protocolSigningAlgorithm: algorithm.rawValue, publicKey: publicKey))
            } catch {
                SkyBridgeLogger.p2p.debug(
                    "ℹ️ P2P pairingIdentityExchange skipped protocol identity key alg=\(algorithm.rawValue, privacy: .public): \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                )
            }
        }
        return AppMessage.ProtocolIdentityPublicKeyInfo.normalizedValidKeys(keys) ?? []
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func waitForPeerKEMPublicKeys(
        requiredSuites: [CryptoSuite],
        timeoutSeconds: TimeInterval,
        requiringFreshKeyMaterialComparedTo baselineKeys: [UInt16: Data] = [:]
    ) async -> Bool {
        let requiredWireIds = Set(requiredSuites.map { $0.canonicalKEMSuite.wireId })
        guard !requiredWireIds.isEmpty else { return true }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let ready = await hasRequiredPeerKEMPublicKeys(
                requiredWireIds: requiredWireIds,
                requiringFreshKeyMaterialComparedTo: baselineKeys
            )
            if ready { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return await hasRequiredPeerKEMPublicKeys(
            requiredWireIds: requiredWireIds,
            requiringFreshKeyMaterialComparedTo: baselineKeys
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func hasRequiredPeerKEMPublicKeys(
        requiredWireIds: Set<UInt16>,
        requiringFreshKeyMaterialComparedTo baselineKeys: [UInt16: Data] = [:]
    ) async -> Bool {
        let currentKeys = await currentKnownPeerKEMPublicKeysByCanonicalWireId()
        let currentWireIds = Set(currentKeys.keys)
        guard requiredWireIds.isSubset(of: currentWireIds) else {
            return false
        }
        guard !baselineKeys.isEmpty else {
            return true
        }

        for wireId in requiredWireIds {
            guard let current = currentKeys[wireId] else { return false }
            if baselineKeys[wireId] != current {
                return true
            }
        }
        return false
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func currentKnownPeerKEMPublicKeysByCanonicalWireId() async -> [UInt16: Data] {
        let candidates = trustLookupCandidates(primary: handshakePeer.deviceId, persistent: device.persistentDeviceId)
        let trustKeys: [UInt16: Data] = await MainActor.run {
            let trust = TrustSyncService.shared
            var availableUnion: [UInt16: Data] = [:]

            for candidate in candidates {
                guard let record = trust.getTrustRecord(deviceId: candidate),
                      let kemKeys = record.kemPublicKeys else {
                    continue
                }
                for key in kemKeys {
                    availableUnion[CryptoSuite(wireId: key.suiteWireId).canonicalKEMSuite.wireId] = key.publicKey
                }
            }

            let related = trustRecordsMatchingCandidates(candidates)
            for record in related {
                if let kemKeys = record.kemPublicKeys {
                    for key in kemKeys {
                        availableUnion[CryptoSuite(wireId: key.suiteWireId).canonicalKEMSuite.wireId] = key.publicKey
                    }
                }
            }

            return availableUnion
        }

        let cachedKeysRaw = await PeerKEMBootstrapStore.shared.mergedKEMPublicKeys(forCandidates: candidates)
        var combined = trustKeys
        for (wireId, publicKey) in cachedKeysRaw {
            combined[CryptoSuite(wireId: wireId).canonicalKEMSuite.wireId] = publicKey
        }
        return combined
    }

    // MARK: - Framing IO (4-byte big-endian length)

    /// Send a single length-framed payload on the control channel.
    /// Note: For post-handshake business traffic, prefer `AppMessage` over the encrypted SessionKeys channel.
    public func send(_ payload: Data) async throws {
        try await sendFramed(payload)
    }

    /// Legacy JSON message API kept for source compatibility.
    /// New code should use `AppMessage` (encrypted) instead of `P2PMessage`.
    @available(*, deprecated, message: "Use AppMessage over the encrypted SessionKeys channel (HandshakeDriver).")
    public func sendMessage(_ message: P2PMessage) async throws {
        let data = try JSONEncoder().encode(message)
        try await sendFramed(data)
    }

    @available(macOS 14.0, iOS 17.0, *)
    public func setRemoteDesktopFrameHandler(_ handler: (@Sendable (Data, UInt64) -> Void)?) {
        remoteDesktopFrameHandlerLock.withLock { $0 = handler }
    }

    @available(macOS 14.0, iOS 17.0, *)
    public func sendRemoteDesktopFrame(_ data: Data, timestampNs: UInt64) async throws {
        let envelope = BusinessEnvelope.remoteDesktopFrame(timestampNs: timestampNs, payload: data)
        try await sendEncryptedBusinessPlaintext(envelope.encode(), label: "remote_desktop")
    }

    @available(macOS 14.0, iOS 17.0, *)
    public func sendAppMessage(_ message: AppMessage) async throws {
        try await sendEncryptedAppMessage(message)
    }

    @available(macOS 14.0, iOS 17.0, *)
    public func deriveClassicFileTransferKey(transferId: String) throws -> SymmetricKey {
        guard let keys = sessionKeysLock.withLock({ $0 }) else {
            throw P2PConnectionError.noSessionKeys
        }

        let orderedKeys = [keys.sendKey, keys.receiveKey].sorted { lhs, rhs in
            lhs.lexicographicallyPrecedes(rhs)
        }
        let combinedMaterial = orderedKeys.reduce(into: Data()) { partial, key in
            partial.append(key)
        }

        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: combinedMaterial),
            salt: Data("skybridge-classic-file-transfer-v1".utf8),
            info: Data(transferId.utf8),
            outputByteCount: 32
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func sendEncryptedAppMessage(_ message: AppMessage) async throws {
        let allowDuringBootstrap = Self.isBootstrapControlMessage(message)
        if rekeyInProgressLock.withLock({ $0 }), !allowDuringBootstrap {
            throw P2PConnectionError.bootstrapControlOnly
        }
        let plaintext = try JSONEncoder().encode(message)
        try await sendEncryptedBusinessPlaintext(
            plaintext,
            label: "tx",
            allowDuringBootstrap: allowDuringBootstrap
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func sendEncryptedBusinessPlaintext(
        _ plaintext: Data,
        label: String,
        allowDuringBootstrap: Bool = false
    ) async throws {
        if rekeyInProgressLock.withLock({ $0 }), !allowDuringBootstrap {
            throw P2PConnectionError.bootstrapControlOnly
        }
        guard let keys = sessionKeysLock.withLock({ $0 }) else {
            throw P2PConnectionError.noSessionKeys
        }
        let ciphertext = try encryptAppPayload(plaintext, with: keys)
        let padded = TrafficPadding.wrapIfEnabled(ciphertext, label: label)
        try await sendFramed(padded)
    }

    @available(macOS 14.0, iOS 17.0, *)
    private enum BusinessEnvelopeKind: UInt8, Sendable {
        case remoteDesktopFrame = 1
    }

    /// Encrypted business payload envelope (v1).
    ///
    /// - Why: `AppMessage` is JSON (and `Data` in JSON becomes base64), which is too expensive for high-rate streams.
    /// - This envelope allows binary payloads (e.g. remote desktop frames) to reuse the post-handshake SessionKeys
    ///   channel, while keeping backwards compatibility with legacy JSON `AppMessage` frames.
    @available(macOS 14.0, iOS 17.0, *)
    private struct BusinessEnvelope: Sendable {
        // "SBE1"
        private static let magic: [UInt8] = [0x53, 0x42, 0x45, 0x31]
        private static let headerLen = 4 + 1 + 8 // magic + kind + timestampNs

        let kind: BusinessEnvelopeKind
        let timestampNs: UInt64
        let payload: Data

        static func remoteDesktopFrame(timestampNs: UInt64, payload: Data) -> BusinessEnvelope {
            BusinessEnvelope(kind: .remoteDesktopFrame, timestampNs: timestampNs, payload: payload)
        }

        func encode() -> Data {
            var out = Data(capacity: Self.headerLen + payload.count)
            out.append(contentsOf: Self.magic)
            out.append(kind.rawValue)
            var tsBE = timestampNs.bigEndian
            out.append(Data(bytes: &tsBE, count: MemoryLayout.size(ofValue: tsBE)))
            out.append(payload)
            return out
        }

        static func decode(_ data: Data) -> BusinessEnvelope? {
            guard data.count >= headerLen else { return nil }
            guard data.prefix(4).elementsEqual(magic) else { return nil }

            let kindRaw = data[data.startIndex.advanced(by: 4)]
            guard let kind = BusinessEnvelopeKind(rawValue: kindRaw) else { return nil }

            let tsStart = data.startIndex.advanced(by: 5)
            let tsEnd = tsStart.advanced(by: 8)
            guard tsEnd <= data.endIndex else { return nil }
            var timestampNs: UInt64 = 0
            for b in data[tsStart..<tsEnd] {
                timestampNs = (timestampNs << 8) | UInt64(b)
            }

            let payload = data.suffix(from: tsEnd)
            return BusinessEnvelope(kind: kind, timestampNs: timestampNs, payload: payload)
        }
    }

    private func sendFramed(_ payload: Data) async throws {
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(payload)

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }

        // Update counters on main thread for SwiftUI.
        DispatchQueue.main.async {
            self.bytesSent &+= UInt64(payload.count)
            self.lastActivity = Date()
        }
    }

    // MARK: - Metrics (RTT / bandwidth)

    @available(macOS 14.0, iOS 17.0, *)
    private func startMetricsIfNeeded() {
        guard metricsTask == nil else { return }
        metricsTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            let clock = ContinuousClock()
            let now = clock.now
            let initialBytes = await MainActor.run { self.bytesReceived &+ self.bytesSent }
            self.metricsLock.withLock { state in
                state.lastTotalBytes = initialBytes
                state.lastBandwidthSampleAt = now
            }

            while !Task.isCancelled {
                await self.sampleBandwidth(clock: clock)
                await self.tickPing(clock: clock)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func sampleBandwidth(clock: ContinuousClock) async {
        let now = clock.now
        let totalBytes = await MainActor.run { self.bytesReceived &+ self.bytesSent }

        let bps: Double? = metricsLock.withLock { state in
            guard let lastAt = state.lastBandwidthSampleAt else {
                state.lastBandwidthSampleAt = now
                state.lastTotalBytes = totalBytes
                return nil
            }
            let dt = Self.durationSeconds(lastAt.duration(to: now))
            guard dt > 0 else {
                state.lastBandwidthSampleAt = now
                state.lastTotalBytes = totalBytes
                return nil
            }
            let deltaBytes = totalBytes >= state.lastTotalBytes ? (totalBytes - state.lastTotalBytes) : 0
            state.lastTotalBytes = totalBytes
            state.lastBandwidthSampleAt = now
            return Double(deltaBytes) / dt
        }

        guard let bps else { return }
        DispatchQueue.main.async {
            let current = self.measuredBandwidthBytesPerSecond
            if current <= 0 {
                self.measuredBandwidthBytesPerSecond = bps
            } else {
                self.measuredBandwidthBytesPerSecond = (current * 0.8) + (bps * 0.2)
            }
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func tickPing(clock: ContinuousClock) async {
        // Only ping once the encrypted session is established.
        guard await MainActor.run(body: { self.status == .authenticated }) else { return }
        guard !rekeyInProgressLock.withLock({ $0 }) else { return }
        guard sessionKeysLock.withLock({ $0 }) != nil else { return }

        let now = clock.now

        // 1) Timeout outstanding ping if needed.
        let didUpdateLoss = metricsLock.withLock { state -> Bool in
            if let outstanding = state.outstandingPing {
                let ageSeconds = Self.durationSeconds(outstanding.sentAt.duration(to: now))
                if ageSeconds > 6.0 {
                    state.outstandingPing = nil
                    state.pingResults.append(false)
                    if state.pingResults.count > 20 {
                        state.pingResults.removeFirst(state.pingResults.count - 20)
                    }
                    return true
                }
            }
            return false
        }

        if didUpdateLoss {
            updatePacketLossFromHistory()
        }

        // 2) Send a new ping (at most one in-flight).
        let pingId: UInt64? = metricsLock.withLock { state in
            if state.outstandingPing != nil { return nil }
            if let last = state.lastPingSentAt {
                let since = Self.durationSeconds(last.duration(to: now))
                if since < 2.0 { return nil }
            }
            let id = UInt64.random(in: UInt64.min...UInt64.max)
            state.lastPingSentAt = now
            state.outstandingPing = (id: id, sentAt: now)
            return id
        }

        guard let pingId else { return }

        do {
            try await sendEncryptedAppMessage(.ping(.init(id: pingId)))
        } catch {
            // Treat send failure as a ping failure (but keep it best-effort).
            metricsLock.withLock { state in
                if let outstanding = state.outstandingPing, outstanding.id == pingId {
                    state.outstandingPing = nil
                    state.pingResults.append(false)
                    if state.pingResults.count > 20 {
                        state.pingResults.removeFirst(state.pingResults.count - 20)
                    }
                }
            }
            updatePacketLossFromHistory()
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func handlePong(id: UInt64) {
        let now = ContinuousClock().now

        let rttSeconds: Double? = metricsLock.withLock { state in
            guard let outstanding = state.outstandingPing, outstanding.id == id else {
                return nil
            }
            state.outstandingPing = nil
            state.pingResults.append(true)
            if state.pingResults.count > 20 {
                state.pingResults.removeFirst(state.pingResults.count - 20)
            }
            let rtt = Self.durationSeconds(outstanding.sentAt.duration(to: now))
            return rtt
        }

        guard let rttSeconds else { return }

        DispatchQueue.main.async {
            let current = self.measuredLatency
            if current <= 0 {
                self.measuredLatency = rttSeconds
            } else {
                self.measuredLatency = (current * 0.8) + (rttSeconds * 0.2)
            }
        }
        updatePacketLossFromHistory()
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func updatePacketLossFromHistory() {
        let loss: Double = metricsLock.withLock { state in
            guard !state.pingResults.isEmpty else { return 0 }
            let lost = state.pingResults.filter { !$0 }.count
            return Double(lost) / Double(state.pingResults.count)
        }
        DispatchQueue.main.async {
            self.measuredPacketLoss = loss
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private static func durationSeconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + (Double(c.attoseconds) / 1_000_000_000_000_000_000.0)
    }

    private func startReceivingIfNeeded() {
        guard receiveTask == nil else { return }
        receiveTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let lenData = try await self.receiveExactly(4)
                    let totalLen = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
                    guard totalLen > 0, totalLen <= self.maxFrameBytes else {
                        throw P2PConnectionError.invalidFrameLength(Int(totalLen))
                    }
                    let payload = try await self.receiveExactly(Int(totalLen))
                    await self.handleInboundFrame(payload)
                }
            } catch {
                if !Task.isCancelled {
                    SkyBridgeLogger.p2p.warning(
                        "⚠️ P2P receive loop ended; tearing down authenticated session: peer=\(self.handshakePeerDiagnosticLabel, privacy: .public) error=\(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                    )
                    self.disconnect()
                }
            }
        }
    }

    private func receiveSome(max: Int) async throws -> Data {
        enum ReceiveError: Error { case eof }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, _, error in
                if let error { c.resume(throwing: error) }
                else if let data, !data.isEmpty { c.resume(returning: data) }
                else { c.resume(throwing: ReceiveError.eof) }
            }
        }
    }

    private func receiveExactly(_ length: Int) async throws -> Data {
        var buffer = Data()
        buffer.reserveCapacity(length)
        while buffer.count < length {
            let remaining = length - buffer.count
            let chunk = try await receiveSome(max: min(65536, remaining))
            buffer.append(chunk)
        }
        return buffer
    }

    private func handleInboundFrame(_ payload: Data) async {
        // Phase C2: optional post-handshake traffic padding (SBP2).
        let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx")
        // Phase C1: optional handshake padding (SBP1).
        let frame = HandshakePadding.unwrapIfNeeded(trafficUnwrapped, label: "rx")

        DispatchQueue.main.async {
            self.bytesReceived &+= UInt64(payload.count)
            self.lastActivity = Date()
        }

        if #available(macOS 14.0, iOS 17.0, *),
           sessionKeysLock.withLock({ $0 }) != nil,
           let inboundDriver = await restartInboundRekeyDriver(for: frame) {
            await inboundDriver.handleMessage(frame, from: handshakePeer)
            await syncHandshakeState(after: inboundDriver)
            return
        }

        if #available(macOS 14.0, iOS 17.0, *), let driver = handshakeDriverLock.withLock({ $0 }) {
            let driverState = await driver.getCurrentState()
            if Self.shouldRestartInboundHandshakeForRekey(state: driverState, frame: frame),
               let inboundDriver = await restartInboundRekeyDriver(for: frame) {
                await inboundDriver.handleMessage(frame, from: handshakePeer)
                await syncHandshakeState(after: inboundDriver)
                return
            }

            await driver.handleMessage(frame, from: handshakePeer)
            await syncHandshakeState(after: driver)
            return
        }

        if #available(macOS 14.0, iOS 17.0, *),
           let inboundDriver = await restartInboundRekeyDriver(for: frame) {
            await inboundDriver.handleMessage(frame, from: handshakePeer)
            await syncHandshakeState(after: inboundDriver)
            return
        }

        guard #available(macOS 14.0, iOS 17.0, *), let keys = sessionKeysLock.withLock({ $0 }) else {
            return
        }
        if isLikelyHandshakeControlPacket(frame) { return }

        do {
            let plaintext = try decryptAppPayload(frame, with: keys)
            if let envelope = BusinessEnvelope.decode(plaintext) {
                switch envelope.kind {
                case .remoteDesktopFrame:
                    if let handler = remoteDesktopFrameHandlerLock.withLock({ $0 }) {
                        handler(envelope.payload, envelope.timestampNs)
                    }
                    return
                }
            }

            if let msg = try? JSONDecoder().decode(AppMessage.self, from: plaintext) {
                await handleAppMessage(msg)
            } else if rekeyInProgressLock.withLock({ $0 }) {
                SkyBridgeLogger.p2p.debug("ℹ️ rekey期间收到无法解析的业务帧（忽略）")
            }
        } catch {
            // Best-effort: ignore frames that aren't business messages for this channel.
            if rekeyInProgressLock.withLock({ $0 }) {
                SkyBridgeLogger.p2p.debug("ℹ️ rekey期间业务帧解密失败（忽略）: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)")
            }
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func encryptAppPayload(_ plaintext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.sendKey)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        return sealed.combined ?? Data()
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func decryptAppPayload(_ ciphertext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.receiveKey)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func isLikelyHandshakeControlPacket(_ data: Data) -> Bool {
        if data.count == 38, (try? HandshakeFinished.decode(from: data)) != nil { return true }
        if (try? HandshakeMessageA.decode(from: data)) != nil { return true }
        if (try? HandshakeMessageB.decode(from: data)) != nil { return true }
        return false
    }

    @available(macOS 14.0, iOS 17.0, *)
    static func shouldRestartInboundHandshakeForRekey(
        state: HandshakeState,
        frame: Data
    ) -> Bool {
        switch state {
        case .waitingFinished, .established:
            return (try? HandshakeMessageA.decode(from: frame)) != nil
        default:
            return false
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func restartInboundRekeyDriver(for frame: Data) async -> HandshakeDriver? {
        guard let previousKeys = sessionKeysLock.withLock({ $0 }) else { return nil }
        guard let messageA = try? HandshakeMessageA.decode(from: frame),
              !messageA.supportedSuites.isEmpty else {
            return nil
        }

        if let existingDriver = handshakeDriverLock.withLock({ $0 }) {
            let existingState = await existingDriver.getCurrentState()
            SkyBridgeLogger.p2p.info("🧩 inbound rekey replacing existing handshake driver state=\(existingState.diagnosticSummary, privacy: .public) peer=\(self.handshakePeerDiagnosticLabel, privacy: .public)")
            handshakeDriverLock.withLock { $0 = nil }
        }

        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
        let requestedPolicy = HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)
        let capability = CryptoProviderFactory.detectCapability()
        let localPQCAvailable = capability.hasApplePQC || capability.hasLiboqs
        let peerHasPQCGroup = messageA.supportedSuites.contains { $0.isPQCGroup }
        let peerHasClassicGroup = messageA.supportedSuites.contains { !$0.isPQCGroup }
        if let rejection = StrictPQCAdmissionGate.inboundRejection(
            policy: requestedPolicy,
            peerSupportedSuites: messageA.supportedSuites,
            localPQCSuitesAvailable: localPQCAvailable
        ), rejection == .peerOfferedClassicOnly {
            SkyBridgeLogger.p2p.error(
                "❌ \(rejection.diagnosticMessage, privacy: .public). peer=\(self.handshakePeerDiagnosticLabel, privacy: .public)"
            )
            return nil
        }
        let effectivePolicy = requestedPolicy

        var selection: CryptoProviderFactory.SelectionPolicy = .classicOnly
        var cryptoProvider: any CryptoProvider = CryptoProviderFactory.make(policy: .classicOnly)
        var sigAAlgorithm: ProtocolSigningAlgorithm = .ed25519
        var offeredSuites: [CryptoSuite] = cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }

        if peerHasPQCGroup {
            selection = effectivePolicy.requirePQC ? .requirePQC : .preferPQC
            cryptoProvider = CryptoProviderFactory.makeInboundPQCResponderProvider(
                policy: selection,
                peerSupportedSuites: messageA.supportedSuites
            )
            let localPQCSuites = CryptoProviderFactory.handshakeOfferedPQCSuites(using: cryptoProvider)
            if let rejection = StrictPQCAdmissionGate.inboundRejection(
                policy: effectivePolicy,
                peerSupportedSuites: messageA.supportedSuites,
                localPQCSuitesAvailable: !localPQCSuites.isEmpty
            ) {
                SkyBridgeLogger.p2p.error(
                    "❌ \(rejection.diagnosticMessage, privacy: .public). peer=\(self.handshakePeerDiagnosticLabel, privacy: .public)"
                )
                return nil
            }
            if localPQCSuites.isEmpty {
                if !peerHasClassicGroup {
                    SkyBridgeLogger.p2p.error(
                        "❌ inbound rekey rejected: peer offered PQC suites but local PQC responder unavailable. peer=\(self.handshakePeerDiagnosticLabel, privacy: .public)"
                    )
                    return nil
                }
                selection = .classicOnly
                cryptoProvider = CryptoProviderFactory.make(policy: selection)
                sigAAlgorithm = .ed25519
                offeredSuites = cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }
            } else {
                sigAAlgorithm = .mlDSA65
                offeredSuites = localPQCSuites
            }
        }

        let localSOAPeerId = await localSOAPeerIdBytes()
        let soaBinding = InboundHandshakeAdapter.bindSOAState(
            from: messageA,
            localPeerId: localSOAPeerId
        )
        let identityProvider = DeviceIdentityHandshakeProvider(
            sigAAlgorithm: sigAAlgorithm,
            includeSecureEnclavePoP: effectivePolicy.requireSecureEnclavePoP
        )

        do {
            let cryptoPolicy = HandshakeCryptoPolicyResolver.policy(for: offeredSuites)
            let driver = try HandshakeDriver(
                transport: DirectHandshakeTransport(sendFramed: { [weak self] data in
                    guard let self else { throw P2PConnectionError.disconnected }
                    try await self.sendFramed(data)
                }),
                cryptoProvider: cryptoProvider,
                protocolSignatureProvider: ProtocolSignatureProviderSelector.select(for: sigAAlgorithm),
                identityProvider: identityProvider,
                sigAAlgorithm: sigAAlgorithm,
                offeredSuites: offeredSuites,
                policy: effectivePolicy,
                cryptoPolicy: cryptoPolicy,
                localSOAPeerId: localSOAPeerId,
                expectedRemoteSOAPeerId: soaBinding.expectedRemotePeerId
            )
            handshakeDriverLock.withLock { $0 = driver }
            previousSessionKeysBeforeRekeyLock.withLock { $0 = previousKeys }
            sessionKeysLock.withLock { $0 = nil }
            rekeyInProgressLock.withLock { $0 = true }

            let stalePairKey = soaPairKeyLock.withLock { state -> Data? in
                let current = state
                state = nil
                return current
            }
            if let stalePairKey {
                await PeerSessionArbiter.shared.clearEstablished(pairKey: stalePairKey)
                await PeerSessionArbiter.shared.clearOutgoing(pairKey: stalePairKey, attemptId: nil)
            }

            let targetSuites = messageA.supportedSuites.map(\.rawValue).joined(separator: ",")
            SkyBridgeLogger.p2p.info(
                "🔁 inbound rekey start: peer=\(self.handshakePeerDiagnosticLabel, privacy: .public) current=\(previousKeys.negotiatedSuite.rawValue, privacy: .public) target=\(targetSuites, privacy: .public)"
            )
            return driver
        } catch {
            SkyBridgeLogger.p2p.error(
                "❌ inbound rekey driver init failed: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
            )
            return nil
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func syncHandshakeState(after driver: HandshakeDriver) async {
        let state = await driver.getCurrentState()
        switch state {
        case .established(let keys):
            await captureAuthenticatedRemoteAuthority(from: driver)
            sessionKeysLock.withLock { $0 = keys }
            previousSessionKeysBeforeRekeyLock.withLock { $0 = nil }
            handshakeDriverLock.withLock { $0 = nil }
            rekeyInProgressLock.withLock { $0 = false }
            if shouldUseSOA(), let pairKey = await currentSOAPairKey() {
                soaPairKeyLock.withLock { $0 = pairKey }
            }
            await publishAuthenticatedPresence(keys: keys)
            await MainActor.run {
                if self.status != .authenticated {
                    self.status = .authenticated
                }
            }
            startMetricsIfNeeded()

        case .failed(let reason):
            let previousKeys = previousSessionKeysBeforeRekeyLock.withLock { state -> SessionKeys? in
                let current = state
                state = nil
                return current
            }
            handshakeDriverLock.withLock { $0 = nil }
            if let previousKeys {
                sessionKeysLock.withLock { $0 = previousKeys }
                rekeyInProgressLock.withLock { $0 = false }
                if shouldUseSOA(), let pairKey = await currentSOAPairKey() {
                    soaPairKeyLock.withLock { $0 = pairKey }
                    await PeerSessionArbiter.shared.markEstablished(pairKey: pairKey)
                }
                SkyBridgeLogger.p2p.warning(
                    "⚠️ inbound rekey failed; restored previous session. peer=\(self.handshakePeerDiagnosticLabel, privacy: .public) reason=\(reason.diagnosticReasonCode, privacy: .public) suite=\(previousKeys.negotiatedSuite.rawValue, privacy: .public)"
                )
                await MainActor.run {
                    if self.status != .authenticated {
                        self.status = .authenticated
                    }
                }
                return
            }

            rekeyInProgressLock.withLock { $0 = false }
            authenticatedRemoteAuthorityLock.withLock { $0 = nil }
            latestRemotePairingIdentityPayloadLock.withLock { $0 = nil }
            await MainActor.run {
                self.status = .failed
            }

        default:
            break
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func publishAuthenticatedPresence(
        keys: SessionKeys,
        remoteIdentityPayload: AppMessage.PairingIdentityExchangePayload? = nil
    ) async {
        await publishClassicTransferSessionSnapshot(
            keys: keys,
            remoteIdentityPayload: remoteIdentityPayload
        )

        let suite = keys.negotiatedSuite
        let cryptoKind = ConnectionCryptoPresentation.modeLabel(
            kind: nil,
            suite: suite.rawValue
        ) ?? suite.rawValue
        let declaredPeerId = normalizedNonEmptyString(remoteIdentityPayload?.deviceId)
        let remoteDisplayName = LocalDevicePresentation.sanitizedDisplayNameCandidate(remoteIdentityPayload?.deviceName)
        let advertisedTransferPort = remoteIdentityPayload?.fileTransferPort.flatMap { port -> Int? in
            let value = Int(port)
            return (1...65535).contains(value) ? value : nil
        }

        await MainActor.run {
            let peerId = declaredPeerId ?? self.handshakePeer.deviceId
            let displayName = remoteDisplayName ?? self.device.name
            let address = self.resolveCurrentRemoteIP() ?? self.device.address
            let endpointLabel = address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? self.handshakePeer.deviceId
                : "host:\(address)"
            let resolvedRoute = P2PDiscoveryService.resolveInboundPresenceRoute(
                peerId: peerId,
                endpointLabel: endpointLabel,
                discoveredDevices: P2PDiscoveryService.shared.discoveredDevices,
                unifiedDevices: UnifiedOnlineDeviceManager.shared.onlineDevices
            )
            let displayAddress = resolvedRoute.displayAddress?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let transferAddress = displayAddress?.isEmpty == false ? displayAddress! : address
            let transferPort = advertisedTransferPort ?? resolvedRoute.transferPort

            if !transferAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               (1...65535).contains(transferPort) {
                let routeDescriptor = ConnectionPresenceService.PresenceRouteDescriptor(
                    peerId: peerId,
                    deviceName: remoteDisplayName ?? resolvedRoute.name,
                    displayAddress: transferAddress,
                    transferAddress: transferAddress,
                    transferPort: transferPort,
                    routeSource: .outbound,
                    connectedAt: Date()
                )
                _ = ConnectionPresenceService.shared.publishConnectedAtomically(
                    peerId: peerId,
                    displayName: remoteDisplayName ?? resolvedRoute.name,
                    address: transferAddress,
                    cryptoKind: cryptoKind,
                    suite: suite.rawValue,
                    routeDescriptor: routeDescriptor
                )
            } else {
                ConnectionPresenceService.shared.markConnected(
                    peerId: peerId,
                    displayName: displayName,
                    address: address,
                    cryptoKind: cryptoKind,
                    suite: suite.rawValue
                )
            }
            UnifiedOnlineDeviceManager.shared.markDeviceAsConnected(
                peerId: peerId,
                displayName: displayName,
                cryptoKind: cryptoKind,
                suite: suite.rawValue,
                guardStatus: "守护中"
            )
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func handleAppMessage(_ message: AppMessage) async {
        if rekeyInProgressLock.withLock({ $0 }), !Self.isBootstrapControlMessage(message) {
            SkyBridgeLogger.p2p.debug(
                "ℹ️ bootstrap-assisted 模式下丢弃非引导控制消息: \(String(describing: message), privacy: .public)"
            )
            return
        }
        switch message {
        case .clipboard(let payload):
            // 随航剪贴板：把远端剪贴板内容交给 ClipboardSyncService 应用到本地（仅 macOS 主机端）。
            #if os(macOS)
            await ClipboardSyncService.shared.ingestRemoteContent(
                mimeType: payload.mimeType,
                data: payload.decodedData ?? Data(),
                fromDeviceID: handshakePeer.deviceId
            )
            #else
            _ = payload
            #endif
        case .textMessage(let payload):
            // 设备间文本消息：按发送者稳定公钥指纹归档到会话存储。
            if let record = await TrustSyncService.shared.getTrustRecord(deviceId: handshakePeer.deviceId),
               !record.pubKeyFP.isEmpty {
                await DeviceMessagingService.shared.handleIncoming(payload, fingerprint: record.pubKeyFP)
            }
        case .kemRefreshRequest, .signedKEMRefresh, .kemRefreshFailure,
             .protocolIdentityBindingRequest, .signedProtocolIdentityBinding:
            break
        case .pairingIdentityExchange(let payload):
            await handlePairingIdentityExchange(payload)
        case .heartbeat:
            break
        case .peerDisconnecting:
            disconnect()
        case .ping(let payload):
            guard !rekeyInProgressLock.withLock({ $0 }) else { return }
            // RTT probe: reply as fast as possible.
            do {
                try await sendEncryptedAppMessage(.pong(.init(id: payload.id)))
            } catch {
                // Best-effort: ignore reply failures.
            }
        case .pong(let payload):
            handlePong(id: payload.id)
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func handlePairingIdentityExchange(_ payload: AppMessage.PairingIdentityExchangePayload) async {
        guard let payload = payload.normalizedBootstrapPayload else {
            SkyBridgeLogger.p2p.warning(
                "⚠️ pairingIdentityExchange ignored: empty declaredDeviceId or empty KEM public key"
            )
            return
        }
        recordRemoteControlSecurityIdentity(from: payload)
        let shouldForceIdentityReply = latestRemotePairingIdentityPayloadLock.withLock { current -> Bool in
            let previousDeviceId = normalizedNonEmptyString(current?.deviceId)
            current = payload
            guard let previousDeviceId else { return true }
            return previousDeviceId.caseInsensitiveCompare(payload.deviceId) != .orderedSame
        }

        do {
            try await persistPeerKEMTrustRecords(from: payload)
        } catch {
            SkyBridgeLogger.p2p.warning(
                "⚠️ pairingIdentityExchange trust persistence failed closed: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
            )
        }

        do {
            try await persistAuthenticatedRemoteAuthority(from: payload)
        } catch {
            SkyBridgeLogger.p2p.warning(
                "⚠️ pairingIdentityExchange current-path trust bridge degraded: \(error.localizedDescription, privacy: .private)"
            )
        }

        if let keys = sessionKeysLock.withLock({ $0 }) {
            await publishAuthenticatedPresence(keys: keys, remoteIdentityPayload: payload)
        }

        do {
            try await sendPairingIdentityExchange(force: shouldForceIdentityReply)
        } catch {
            SkyBridgeLogger.p2p.warning(
                "⚠️ pairingIdentityExchange reply failed: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
            )
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    internal static func isBootstrapControlMessage(_ message: AppMessage) -> Bool {
        if case .pairingIdentityExchange = message {
            return true
        }
        if case .kemRefreshRequest = message {
            return true
        }
        if case .signedKEMRefresh = message {
            return true
        }
        if case .kemRefreshFailure = message {
            return true
        }
        if case .protocolIdentityBindingRequest = message {
            return true
        }
        if case .signedProtocolIdentityBinding = message {
            return true
        }
        return false
    }

    @available(macOS 14.0, iOS 17.0, *)
    internal static func classifySessionAssurance(
        policy: HandshakePolicy,
        negotiatedSuite: CryptoSuite,
        bootstrapAssisted: Bool
    ) -> P2PSessionAssuranceLevel {
        if bootstrapAssisted {
            return .bootstrapAssisted
        }
        if negotiatedSuite.isPQCGroup {
            return .pqcStrict
        }
        if !policy.requirePQC {
            return .legacyClassic
        }
        return .unknown
    }

    private func normalizedNonEmptyString(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func captureAuthenticatedRemoteAuthority(from driver: HandshakeDriver) async {
        let authority = await driver.getAuthenticatedRemoteAuthority()
        authenticatedRemoteAuthorityLock.withLock { $0 = authority }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func persistAuthenticatedRemoteAuthority(
        from payload: AppMessage.PairingIdentityExchangePayload
    ) async throws {
        guard let authority = authenticatedRemoteAuthorityLock.withLock({ $0 }) else {
            SkyBridgeLogger.p2p.warning(
                "⚠️ pairingIdentityExchange missing authenticated authority; skipping current-path trust bridge: peer=\(Self.protocolIdentityLogRedaction, privacy: .public) declared=\(Self.protocolIdentityLogRedaction, privacy: .public)"
            )
            return
        }

        let declaredDeviceId = normalizedNonEmptyString(payload.deviceId)
        let displayName = LocalDevicePresentation.sanitizedDisplayNameCandidate(payload.deviceName)
            ?? LocalDevicePresentation.sanitizedDisplayNameCandidate(device.name)
            ?? LocalDevicePresentation.sanitizedDisplayNameCandidate(handshakePeer.displayName)

        var knownDeviceIds: [String] = []
        var seenKnownDeviceIds = Set<String>()

        func appendKnownDeviceId(_ raw: String?) {
            guard let value = normalizedNonEmptyString(raw) else { return }
            guard seenKnownDeviceIds.insert(value).inserted else { return }
            knownDeviceIds.append(value)
        }

        appendKnownDeviceId(declaredDeviceId)
        appendKnownDeviceId(handshakePeer.deviceId)
        appendKnownDeviceId(device.deviceId)
        appendKnownDeviceId(device.persistentDeviceId)

        let persisted = try await TrustSyncService.shared.recordAuthenticatedRemoteAuthority(
            deviceId: declaredDeviceId ?? handshakePeer.deviceId,
            displayName: displayName,
            preferredCurrentDeviceId: declaredDeviceId,
            knownDeviceIds: knownDeviceIds,
            protocolSigningAlgorithm: authority.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint
        )

        guard persisted else {
            SkyBridgeLogger.p2p.warning(
                "⚠️ current-path trust bridge skipped: peer=\(Self.protocolIdentityLogRedaction, privacy: .public) declared=\(Self.protocolIdentityLogRedaction, privacy: .public)"
            )
            return
        }

        func normalizedFingerprint(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
            return value
        }

        let advertisedFingerprints = Set(
            (AppMessage.ProtocolIdentityPublicKeyInfo.normalizedValidKeys(payload.protocolIdentityPublicKeys) ?? [])
                .compactMap { normalizedFingerprint($0.authoritativeFingerprint) }
        )
        let authenticatedFingerprint = normalizedFingerprint(authority.protocolPublicKeyFingerprint)
        if let authenticatedFingerprint, advertisedFingerprints.contains(authenticatedFingerprint) {
            await PeerProtocolIdentityBootstrapStore.shared.upsert(
                deviceIds: knownDeviceIds,
                fingerprints: advertisedFingerprints
            )
        } else if !advertisedFingerprints.isEmpty {
            SkyBridgeLogger.p2p.warning(
                "⚠️ pairingIdentityExchange protocol identity pins ignored because they are not bound to the authenticated session: peer=\(Self.protocolIdentityLogRedaction, privacy: .public) declared=\(Self.protocolIdentityLogRedaction, privacy: .public) count=\(advertisedFingerprints.count, privacy: .public)"
            )
        }

        SkyBridgeLogger.p2p.info(
            "🔐 current-path trust bridge persisted: peer=\(Self.protocolIdentityLogRedaction, privacy: .public) current=\(Self.protocolIdentityLogRedaction, privacy: .public) alg=\(authority.protocolSigningAlgorithm.rawValue, privacy: .public) fp=\(Self.protocolIdentityLogRedaction, privacy: .public)"
        )
    }

    private func mergedKEMPublicKeys(
        existing: [KEMPublicKeyInfo]?,
        incoming: [KEMPublicKeyInfo]
    ) -> [KEMPublicKeyInfo]? {
        var bySuite: [UInt16: Data] = [:]
        for key in KEMPublicKeyInfo.normalizedValidKeys(existing ?? []) {
            bySuite[key.suiteWireId] = key.publicKey
        }
        for key in KEMPublicKeyInfo.normalizedValidKeys(incoming) {
            bySuite[key.suiteWireId] = key.publicKey
        }
        guard !bySuite.isEmpty else { return nil }
        return bySuite.keys.sorted().compactMap { suite in
            guard let publicKey = bySuite[suite] else { return nil }
            return KEMPublicKeyInfo(suiteWireId: suite, publicKey: publicKey)
        }
    }

    private func mergedKnownDeviceIds(
        existing: [String]?,
        incoming: [String]
    ) -> [String]? {
        let merged = Set((existing ?? []) + incoming)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !merged.isEmpty else { return nil }
        return Array(merged).sorted()
    }

    private func resolvedCapabilities(
        existing: [String]?,
        incoming: [String]
    ) -> [String] {
        var flagCapabilities: Set<String> = []
        var keyedCapabilities: [String: String] = [:]

        func ingest(_ items: [String], preferIncoming: Bool) {
            for raw in items {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty, !value.isEmpty else { continue }
                    if preferIncoming || keyedCapabilities[key] == nil {
                        keyedCapabilities[key] = value
                    }
                } else {
                    flagCapabilities.insert(trimmed)
                }
            }
        }

        ingest(existing ?? [], preferIncoming: false)
        ingest(incoming, preferIncoming: true)

        return flagCapabilities.sorted() + keyedCapabilities.keys.sorted().compactMap { key in
            keyedCapabilities[key].map { "\(key)=\($0)" }
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func persistPeerKEMTrustRecords(from payload: AppMessage.PairingIdentityExchangePayload) async throws {
        guard let declaredDeviceId = normalizedNonEmptyString(payload.deviceId) else { return }
        let peerDeviceId = handshakePeer.deviceId
        let rawDeviceId = normalizedNonEmptyString(device.deviceId)
        let persistentDeviceId = normalizedNonEmptyString(device.persistentDeviceId)
        let displayName = LocalDevicePresentation.sanitizedDisplayNameCandidate(payload.deviceName)
            ?? LocalDevicePresentation.sanitizedDisplayNameCandidate(device.name)

        let platform = normalizedNonEmptyString(payload.platform) ?? ""
        let osVersion = normalizedNonEmptyString(payload.osVersion) ?? ""
        let modelName = normalizedNonEmptyString(payload.modelName) ?? ""
        let chip = normalizedNonEmptyString(payload.chip) ?? ""

        var baseCapabilities = [String]()
        baseCapabilities.append("trusted")
        baseCapabilities.append("pqc_bootstrap")
        for capability in payload.capabilities ?? [] {
            if let capability = normalizedNonEmptyString(capability) {
                baseCapabilities.append(capability)
            }
        }
        if !platform.isEmpty { baseCapabilities.append("platform=\(platform)") }
        if !osVersion.isEmpty { baseCapabilities.append("osVersion=\(osVersion)") }
        if !modelName.isEmpty { baseCapabilities.append("modelName=\(modelName)") }
        if !chip.isEmpty { baseCapabilities.append("chip=\(chip)") }
        baseCapabilities.append("peerEndpoint=\(peerDeviceId)")
        if let fileTransferPort = payload.fileTransferPort, fileTransferPort > 0 {
            baseCapabilities.append("fileTransferPort=\(fileTransferPort)")
        }
        if let remoteControlPort = payload.remoteControlPort, remoteControlPort > 0 {
            baseCapabilities.append("remoteControlPort=\(remoteControlPort)")
        }

        var bootstrapIds: [String] = []
        var bootstrapSeen: Set<String> = []
        func appendBootstrapId(_ raw: String?) {
            guard let value = normalizedNonEmptyString(raw) else { return }
            guard bootstrapSeen.insert(value).inserted else { return }
            bootstrapIds.append(value)
        }
        appendBootstrapId(declaredDeviceId)
        appendBootstrapId(peerDeviceId)
        appendBootstrapId(rawDeviceId)
        appendBootstrapId(persistentDeviceId)

        let bootstrapCacheEnabled = !bootstrapIds.isEmpty && !payload.kemPublicKeys.isEmpty
        if bootstrapCacheEnabled {
            await PeerKEMBootstrapStore.shared.upsert(
                deviceIds: bootstrapIds,
                kemPublicKeys: payload.kemPublicKeys
            )
        }

        var savedIds: [String] = []
        var lastError: Error?

	        func upsert(_ deviceId: String, caps: [String]) async {
	            do {
	                try await upsertTrustRecordForBootstrap(
	                    deviceId: deviceId,
                    displayName: displayName,
                    incomingKEMKeys: payload.kemPublicKeys,
                    capabilities: caps,
                    currentDeviceId: declaredDeviceId,
                    knownDeviceIds: bootstrapIds
                )
	                savedIds.append(deviceId)
	            } catch {
	                lastError = error
	                let redactedDeviceId = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(deviceId)
	                SkyBridgeLogger.p2p.warning(
	                    "⚠️ KEM trust alias upsert failed: id=\(redactedDeviceId, privacy: .public) err=\(error.localizedDescription, privacy: .private)"
	                )
	            }
	        }

        await upsert(declaredDeviceId, caps: baseCapabilities)

        if savedIds.isEmpty, let lastError {
            if bootstrapCacheEnabled {
	                await PeerKEMBootstrapStore.shared.clearPairingIdentityExchangeEntries(deviceIds: bootstrapIds)
	                SkyBridgeLogger.p2p.warning(
	                    "⚠️ TrustSync KEM persistence failed; cleared unsigned bootstrap KEM cache and failing closed: err=\(lastError.localizedDescription, privacy: .private)"
	                )
	            }
            throw lastError
        }

	        let savedSummary = savedIds
	            .map { SkyBridgeDiagnosticRedaction.stableIdentifierLabel($0) }
	            .joined(separator: ",")
	        let cachedSuites = await PeerKEMBootstrapStore.shared.availableSuiteWireIds(forCandidates: bootstrapIds)
	        let cachedSummary = cachedSuites.map(String.init).joined(separator: ",")
	        if !savedIds.isEmpty {
	            let redactedDeclaredDeviceId = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(declaredDeviceId)
	            let redactedPeerDeviceId = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(peerDeviceId)
	            SkyBridgeLogger.p2p.info(
	                "🔑 已保存对端 KEM 公钥：declared=\(redactedDeclaredDeviceId, privacy: .public) peer=\(redactedPeerDeviceId, privacy: .public) trust=\(savedSummary, privacy: .public) cacheSuites=\(cachedSummary, privacy: .public) keys=\(payload.kemPublicKeys.count)"
	            )
	        }
	    }

    @available(macOS 14.0, iOS 17.0, *)
    @MainActor
    private func upsertTrustRecordForBootstrap(
        deviceId: String,
        displayName: String?,
        incomingKEMKeys: [KEMPublicKeyInfo],
        capabilities: [String],
        currentDeviceId: String?,
        knownDeviceIds: [String]
    ) async throws {
        let trust = TrustSyncService.shared
        let existing = trust.getTrustRecord(deviceId: deviceId)
        let mergedCapabilities = resolvedCapabilities(
            existing: existing?.capabilities,
            incoming: capabilities
        )
        let mergedKEM = mergedKEMPublicKeys(existing: existing?.kemPublicKeys, incoming: incomingKEMKeys)
        let resolvedDisplayName = LocalDevicePresentation.sanitizedDisplayNameCandidate(displayName)
            ?? existing?.deviceName
        let mergedKnownDeviceIds = mergedKnownDeviceIds(
            existing: existing?.knownDeviceIdsMetadata,
            incoming: knownDeviceIds
        )

        let record = TrustRecord(
            deviceId: deviceId,
            pubKeyFP: existing?.pubKeyFP ?? "",
            publicKey: existing?.publicKey ?? Data(),
            secureEnclavePublicKey: existing?.secureEnclavePublicKey,
            protocolPublicKey: existing?.protocolPublicKey,
            protocolSigningAlgorithm: existing?.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: existing?.protocolPublicKeyFingerprint,
            legacyP256PublicKey: existing?.legacyP256PublicKey,
            signatureAlgorithm: existing?.signatureAlgorithm,
            kemPublicKeys: mergedKEM,
            attestationLevel: existing?.attestationLevel ?? .none,
            attestationData: existing?.attestationData,
            capabilities: mergedCapabilities,
            signature: Data(),
            deviceName: resolvedDisplayName,
            currentDeviceId: currentDeviceId ?? existing?.currentDeviceIdMetadata,
            knownDeviceIds: mergedKnownDeviceIds,
            lifecycleState: existing?.lifecycleStateMetadata
        )
        _ = try await trust.addTrustRecord(record)
    }
}

#if DEBUG
extension P2PConnection {
    @MainActor
    func testingSetStatus(_ status: P2PConnectionStatus) {
        self.status = status
    }
}
#endif

public enum P2PConnectionError: Error, LocalizedError, Sendable {
    case handshakeUnavailable
    case noSessionKeys
    case disconnected
    case invalidFrameLength(Int)
    case bootstrapKEMKeyTimeout
    case bootstrapControlOnly
    case postAuthPairingIdentityExchangeTimeout

    public var errorDescription: String? {
        switch self {
        case .handshakeUnavailable:
            return "握手不可用：系统版本不满足要求"
        case .noSessionKeys:
            return "尚未建立会话密钥"
        case .disconnected:
            return "连接已断开"
        case .invalidFrameLength(let length):
            return "无效的帧长度：\(length)"
        case .bootstrapKEMKeyTimeout:
            return "等待对端 KEM 公钥超时（请确认对端已批准配对/信任并重试）"
        case .bootstrapControlOnly:
            return "引导恢复期间仅允许 pairingIdentityExchange 控制消息"
        case .postAuthPairingIdentityExchangeTimeout:
            return "post-auth pairingIdentityExchange 超时"
        }
    }
}

// MARK: - 扩展和辅助方法

extension P2PDevice {
 /// 信号强度 (0.0 - 1.0)
    public var signalStrength: Double {
 // 基于距离和网络质量计算信号强度
        let baseStrength = 1.0 - min(1.0, Double(port) / 65535.0 * 0.3)
        return max(0.1, baseStrength)
    }
    
 /// 信任日期
 /// Swift 6.2.1：通过 DeviceSecurityManager 单例获取设备信任日期
    @MainActor
    public var trustedDate: Date? {
        return DeviceSecurityManager.shared.getTrustedDate(for: id)
    }
    
 /// 创建模拟设备用于预览
    public static var mockDevice: P2PDevice {
        P2PDevice(
            id: "mock-device-id",
            name: "测试设备",
            type: .macOS,
            address: "192.168.1.100",
            port: 8080,
            osVersion: "macOS 14.0",
            capabilities: ["remote_desktop", "file_transfer"],
            publicKey: Data(),
            lastSeen: Date(),
            endpoints: ["192.168.1.100:8080"]
        )
    }
}

extension P2PConnection {
 /// 连接延迟（秒）
    public var latency: Double {
        measuredLatency
    }
    
 /// 带宽（字节/秒）
    public var bandwidth: Double {
        measuredBandwidthBytesPerSecond
    }
    
 /// 连接质量
    public var quality: P2PConnectionQuality {
        let score: Int = {
            // Keep the same thresholds as P2PNetworkManager for consistent UI.
            let latency = measuredLatency
            let loss = measuredPacketLoss
            if latency <= 0 { return 0 }
            if latency < 0.05 && loss < 0.01 { return 90 }
            if latency < 0.1 && loss < 0.03 { return 70 }
            if latency < 0.2 && loss < 0.05 { return 50 }
            return 20
        }()
        return P2PConnectionQuality(
            latency: measuredLatency,
            packetLoss: measuredPacketLoss,
            bandwidth: UInt64(max(0, measuredBandwidthBytesPerSecond)),
            stabilityScore: score
        )
    }
}
