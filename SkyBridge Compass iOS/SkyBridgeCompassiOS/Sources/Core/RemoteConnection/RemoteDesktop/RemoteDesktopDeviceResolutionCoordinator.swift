import Foundation
import Network

@available(iOS 17.0, *)
@MainActor
struct RemoteDesktopDeviceResolutionCoordinator {
    private let manager: RemoteDesktopManager
    private let connectionManager: P2PConnectionManager
    private let discoveryManager: DeviceDiscoveryManager
    private let crossNetworkCapability: String

    init(
        manager: RemoteDesktopManager,
        connectionManager: P2PConnectionManager,
        discoveryManager: DeviceDiscoveryManager,
        crossNetworkCapability: String
    ) {
        self.manager = manager
        self.connectionManager = connectionManager
        self.discoveryManager = discoveryManager
        self.crossNetworkCapability = crossNetworkCapability
    }

    func makeEndpointCandidates(for device: DiscoveredDevice) async throws -> [NWEndpoint] {
        let bonjour = bonjourServiceIdentity(for: device).map {
            RemoteDesktopLANEndpointCandidateFactory.BonjourServiceIdentity(
                name: $0.name,
                domain: $0.domain
            )
        }
        let activePeerAddress = peerAddressBackedAddress(for: device)
        let directIP = manager.bestIPAddress(for: device)
        let resolvedIP = await resolveIPAddress(for: device)
        let remoteControlPort = preferredRemoteControlPort(for: device)
        let liveBonjourEndpoints = discoveryManager.liveBonjourServiceEndpoints(
            for: device,
            serviceType: .skybridgeRemote
        )
        let plan = RemoteDesktopLANEndpointCandidateFactory.makePlan(
            remoteControlPort: remoteControlPort,
            directIP: directIP,
            resolvedIP: resolvedIP,
            liveBonjourEndpoints: liveBonjourEndpoints,
            bonjourService: bonjour,
            activePeerAddress: activePeerAddress,
            remoteServiceType: DiscoveredDevice.remoteControlServiceType
        )
        if let resolvedIP,
           hasReachableLANEndpoint(device),
           let port = remoteControlPort {
            SkyBridgeLogger.shared.info(
                "📡 远控已解析到主服务地址: name=\(device.name) ip=\(resolvedIP) port=\(port)"
            )
        }
        for log in plan.hostCandidateLogs {
            if log.reason == "active-peer-fallback" {
                SkyBridgeLogger.shared.info(
                    "📡 远控使用已建立 P2P 会话的对端地址末尾回退连接: host=\(log.host) port=\(log.port)"
                )
            }
            SkyBridgeLogger.shared.info(log.message)
        }
        if let activePeerAddress, plan.missingActivePeerPortHost != nil {
            SkyBridgeLogger.shared.warning(
                "⚠️ 远控目标缺少显式端口，拒绝猜测默认端口: host=\(activePeerAddress)"
            )
        }

        if !plan.endpoints.isEmpty {
            return plan.endpoints
        }

        throw RemoteDesktopError.connectionFailed("设备缺少可连接地址（Bonjour/IP）")
    }

    func resolveLatestDevice(from device: DiscoveredDevice) -> DiscoveredDevice {
        if isCrossNetworkDevice(device) {
            return device
        }

        var candidates = manager.deduplicatedRemoteDesktopCandidates(
            discoveryManager.discoveredDevices + connectionManager.activeConnections.map(\.device)
        )
        let peerResolved = connectionManager.resolvedPeerDevice(for: device)
        if !candidates.contains(where: { manager.areEquivalentRemoteDesktopDevices($0, peerResolved) }) {
            candidates.insert(peerResolved, at: 0)
        }
        if let canonical = discoveryManager.canonicalDiscoveredDevice(for: device) {
            candidates.insert(canonical, at: 0)
        }

        var best = RemoteDesktopManager.resolveBestRemoteDesktopDevice(target: device, discovered: candidates)

        if shouldUseUniqueRemoteCandidateFallback(for: best) {
            let remoteCandidates = candidates.filter { hasReachableLANEndpoint($0) }
            if remoteCandidates.count == 1, let only = remoteCandidates.first {
                best = manager.preferredRemoteDesktopDevice(best, only)
            }
        }

        return devicePreservingTrustedIdentity(
            original: device,
            endpointCandidate: best
        )
    }

    func canResolveLANEndpoint(for device: DiscoveredDevice) async -> Bool {
        if hasReachableLANEndpoint(device) {
            return true
        }

        if hasPeerAddressBackedFallback(for: device) {
            return true
        }

        if preferredServiceName(for: device) != nil {
            return true
        }

        if device.supportsRemoteControl {
            if manager.bestIPAddress(for: device) != nil {
                return true
            }
            if preferredServiceName(for: device) != nil {
                return true
            }
            if await resolveIPAddress(for: device) != nil {
                return true
            }
        }

        return false
    }

    func preferredServiceName(for device: DiscoveredDevice) -> String? {
        bonjourServiceIdentity(for: device)?.name
    }

    func hasReachableLANEndpoint(_ device: DiscoveredDevice) -> Bool {
        if bonjourServiceIdentity(for: device) != nil {
            return true
        }
        if peerAddressBackedAddress(for: device) != nil,
           device.remoteControlPort != nil {
            return true
        }
        return device.remoteControlPort != nil && manager.bestIPAddress(for: device) != nil
    }

    func hasPeerAddressBackedFallback(for device: DiscoveredDevice) -> Bool {
        device.remoteControlPort != nil && peerAddressBackedAddress(for: device) != nil
    }

    func activeP2PBootstrapDevice(for device: DiscoveredDevice) -> DiscoveredDevice? {
        let resolvedDevice = connectionManager.resolvedPeerDevice(for: device)
        let targetAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: device))
            .union(PeerIdentityAliasResolver.aliasKeys(for: resolvedDevice))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: device.id))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: resolvedDevice.id))
        let normalizedName = manager.normalizeDeviceName(
            resolvedDevice.name.isEmpty ? device.name : resolvedDevice.name
        )

        var nameMatches: [DiscoveredDevice] = []
        for connection in connectionManager.activeConnections where connection.status == .connected {
            let candidate = connectionManager.resolvedPeerDevice(for: connection.device)
            let candidateAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: connection.device))
                .union(PeerIdentityAliasResolver.aliasKeys(for: candidate))
                .union(PeerIdentityAliasResolver.lookupCandidates(for: connection.device.id))
                .union(PeerIdentityAliasResolver.lookupCandidates(for: candidate.id))
            if !targetAliases.isEmpty,
               !candidateAliases.isDisjoint(with: targetAliases) {
                return candidate
            }

            let candidateName = manager.normalizeDeviceName(
                candidate.name.isEmpty ? connection.device.name : candidate.name
            )
            let platformMatches = candidate.platform == resolvedDevice.platform
                || candidate.platform == device.platform
                || resolvedDevice.platform == .unknown
                || device.platform == .unknown
            if !normalizedName.isEmpty,
               candidateName == normalizedName,
               platformMatches {
                nameMatches.append(candidate)
            }
        }

        return nameMatches.count == 1 ? nameMatches[0] : nil
    }

    private func devicePreservingTrustedIdentity(
        original device: DiscoveredDevice,
        endpointCandidate: DiscoveredDevice
    ) -> DiscoveredDevice {
        guard endpointCandidate.id != device.id,
              RemoteDesktopManager.isStableRemoteDesktopIdentity(device.id),
              hasReachableLANEndpoint(endpointCandidate),
              hasActiveP2PSession(for: device) else {
            return endpointCandidate
        }

        var merged = device
        merged.name = RemoteDesktopManager.trimmedNonEmpty(endpointCandidate.name) ?? device.name
        merged.modelName = RemoteDesktopManager.trimmedNonEmpty(endpointCandidate.modelName) ?? device.modelName
        merged.platform = endpointCandidate.platform
        merged.osVersion = RemoteDesktopManager.trimmedNonEmpty(endpointCandidate.osVersion) ?? device.osVersion
        merged.ipAddress = endpointCandidate.ipAddress ?? device.ipAddress
        merged.bonjourServiceName = endpointCandidate.bonjourServiceName ?? device.bonjourServiceName
        merged.bonjourServiceType = endpointCandidate.bonjourServiceType ?? device.bonjourServiceType
        merged.bonjourServiceDomain = endpointCandidate.bonjourServiceDomain ?? device.bonjourServiceDomain
        merged.services = RemoteDesktopManager.mergingUniqueStrings(device.services, endpointCandidate.services)
        merged.portMap = device.portMap.merging(endpointCandidate.portMap) { _, endpointPort in endpointPort }
        merged.signalStrength = max(device.signalStrength, endpointCandidate.signalStrength)
        merged.lastSeen = max(device.lastSeen, endpointCandidate.lastSeen)
        merged.isConnected = device.isConnected || endpointCandidate.isConnected
        merged.isTrusted = device.isTrusted || endpointCandidate.isTrusted
        merged.publicKey = device.publicKey ?? endpointCandidate.publicKey
        merged.advertisedCapabilities = RemoteDesktopManager.mergingUniqueStrings(
            device.advertisedCapabilities,
            endpointCandidate.advertisedCapabilities
        )
        merged.capabilities = RemoteDesktopManager.mergingUniqueStrings(
            device.capabilities,
            endpointCandidate.capabilities
        )

        SkyBridgeLogger.shared.info(
            "ℹ️ LAN 远控保留可信 P2P 身份并合并远控端点: \(device.id) endpoint=\(endpointCandidate.id)"
        )
        return merged
    }

    private func hasActiveP2PSession(for device: DiscoveredDevice) -> Bool {
        let resolved = connectionManager.resolvedPeerDevice(for: device)
        return connectionManager.resolvedConnectionStatus(for: device) == .connected
            || connectionManager.resolvedConnectionStatus(for: resolved) == .connected
            || activeP2PBootstrapDevice(for: device) != nil
    }

    private func bonjourServiceIdentity(for device: DiscoveredDevice) -> (name: String, domain: String)? {
        if let liveAdvertisement = discoveryManager.liveBonjourAdvertisement(
            for: device,
            serviceType: .skybridgeRemote
        ),
           let name = liveAdvertisement.bonjourServiceName,
           manager.isPlausibleRemoteServiceInstanceName(name) {
            let domain = liveAdvertisement.bonjourServiceDomain?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                domain: domain?.isEmpty == false ? domain! : "local."
            )
        }

        for candidate in identityCandidates(for: device) {
            let hasRemoteServiceEvidence = candidate.bonjourServiceType == DiscoveredDevice.remoteControlServiceType
                || (
                    candidate.id.hasPrefix("bonjour:")
                        && candidate.services.contains(DiscoveredDevice.remoteControlServiceType)
                        && candidate.remoteControlPort != nil
                )

            guard hasRemoteServiceEvidence else { continue }

            if let bonjourServiceName = candidate.bonjourServiceName,
               manager.isPlausibleRemoteServiceInstanceName(bonjourServiceName) {
                let domain = candidate.bonjourServiceDomain?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (
                    name: bonjourServiceName.trimmingCharacters(in: .whitespacesAndNewlines),
                    domain: domain?.isEmpty == false ? domain! : "local."
                )
            }
            if let parsed = manager.parseBonjourIdentity(from: candidate.id),
               manager.isPlausibleRemoteServiceInstanceName(parsed.name) {
                return (name: parsed.name.trimmingCharacters(in: .whitespacesAndNewlines), domain: parsed.domain)
            }
        }
        return nil
    }

    /// Prefer the `remoteControlPort` carried by a candidate that advertises the
    /// explicit `_skybridge-rd._tcp` Bonjour service (the authoritative remote
    /// endpoint), mirroring the file-transfer port-provenance fix. A
    /// session/pairing-derived record can carry a non-advertised port in
    /// `portMap[remoteControlServiceType]` (and gets the remote service appended to
    /// its `services` list when merged via `mergePeerServiceMetadata`), so it must
    /// not win over the real advertised remote-control port.
    private func preferredRemoteControlPort(for device: DiscoveredDevice) -> UInt16? {
        if let livePort = discoveryManager.liveBonjourAdvertisement(
            for: device,
            serviceType: .skybridgeRemote
        )?.remoteControlPort,
           livePort > 0 {
            return livePort
        }

        let candidates = identityCandidates(for: device)

        for candidate in candidates where advertisesExplicitRemoteControlService(candidate) {
            if let port = candidate.remoteControlPort, port > 0 {
                return port
            }
        }

        for candidate in candidates {
            if let port = candidate.remoteControlPort, port > 0 {
                return port
            }
        }
        return nil
    }

    /// True when the candidate carries an explicit `_skybridge-rd._tcp`
    /// advertisement (Bonjour SRV/TXT provenance) rather than a session/pairing
    /// heartbeat merge. `services` membership alone is not authoritative because
    /// the pairing merge appends `remoteControlServiceType` to `services`.
    private func advertisesExplicitRemoteControlService(_ candidate: DiscoveredDevice) -> Bool {
        if candidate.bonjourServiceType == DiscoveredDevice.remoteControlServiceType {
            return true
        }
        if candidate.id.hasPrefix("bonjour:"),
           manager.parseBonjourIdentity(from: candidate.id) != nil,
           candidate.remoteControlPort != nil {
            return true
        }
        return false
    }

    private func identityCandidates(for device: DiscoveredDevice) -> [DiscoveredDevice] {
        var candidates: [DiscoveredDevice] = []

        func append(_ candidate: DiscoveredDevice?) {
            guard let candidate else { return }
            if candidates.contains(where: { manager.areEquivalentRemoteDesktopDevices($0, candidate) }) {
                return
            }
            candidates.append(candidate)
        }

        append(device)
        append(connectionManager.resolvedPeerDevice(for: device))
        append(discoveryManager.canonicalDiscoveredDevice(for: device))
        for active in connectionManager.activeConnections.map(\.device)
        where manager.areEquivalentRemoteDesktopDevices(active, device) {
            append(active)
        }
        return candidates
    }

    private func shouldUseUniqueRemoteCandidateFallback(for device: DiscoveredDevice) -> Bool {
        if isCrossNetworkDevice(device) {
            return false
        }

        if hasAdvertisedRemoteDesktopService(device) {
            return false
        }

        guard device.supportsRemoteControl || device.remoteControlPort != nil else {
            return false
        }

        if device.id.hasPrefix("host:") || device.id.hasPrefix("peer:") {
            return true
        }
        if manager.bestIPAddress(for: device) != nil {
            return true
        }
        return manager.normalizeDeviceName(device.name).contains(":")
    }

    private func hasAdvertisedRemoteDesktopService(_ device: DiscoveredDevice) -> Bool {
        bonjourServiceIdentity(for: device) != nil
    }

    private func peerAddressBackedAddress(for device: DiscoveredDevice) -> String? {
        let resolved = connectionManager.resolvedPeerDevice(for: device)
        let status = connectionManager.resolvedConnectionStatus(for: resolved)
            ?? connectionManager.resolvedConnectionStatus(for: device)
        guard status == .connected else {
            return nil
        }

        let candidate = resolved.platform == .macOS ? resolved : device
        guard candidate.platform == .macOS || candidate.supportsRemoteControl else {
            return nil
        }

        if let activePeerAddress = connectionManager.activePeerHostAddress(for: resolved),
           let sanitized = manager.sanitizeAddress(activePeerAddress) {
            return sanitized
        }

        if let activePeerAddress = connectionManager.activePeerHostAddress(for: device),
           let sanitized = manager.sanitizeAddress(activePeerAddress) {
            return sanitized
        }

        return nil
    }

    private func resolveIPAddress(for device: DiscoveredDevice) async -> String? {
        var candidates: [DiscoveredDevice] = []

        func append(_ candidate: DiscoveredDevice?) {
            guard let candidate else { return }
            if candidates.contains(where: { manager.areEquivalentRemoteDesktopDevices($0, candidate) }) {
                return
            }
            candidates.append(candidate)
        }

        append(device)
        append(connectionManager.resolvedPeerDevice(for: device))
        append(discoveryManager.canonicalDiscoveredDevice(for: device))
        append(RemoteDesktopManager.resolveBestRemoteDesktopDevice(
            target: device,
            discovered: manager.deduplicatedRemoteDesktopCandidates(
                discoveryManager.discoveredDevices + connectionManager.activeConnections.map(\.device)
            )
        ))

        var addresses: [String?] = []
        for candidate in candidates {
            addresses.append(manager.bestIPAddress(for: candidate))
            addresses.append(connectionManager.activePeerHostAddress(for: candidate))
            addresses.append(await discoveryManager.resolveEndpoint(candidate))
        }

        return ConnectableAddressCanonicalizer.bestLANAddress(addresses)
    }

    private func isCrossNetworkDevice(_ device: DiscoveredDevice) -> Bool {
        RemoteDesktopTransportSelectionPolicy.isCrossNetworkDevice(
            device,
            capability: crossNetworkCapability
        )
    }
}
