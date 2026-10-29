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

    func makeEndpointCandidates(for device: DiscoveredDevice) async throws
        -> [RemoteDesktopLANEndpointCandidate]
    {
        guard P2PConnectionEndpointPolicy.normalizedStrongDeviceId(for: device) != nil,
              let preferredAdvertisement = discoveryManager.liveBonjourAdvertisement(
                for: device,
                serviceType: .skybridgeRemote
              ),
              let preferredRoute = BonjourRouteTuple(preferredAdvertisement),
              preferredRoute.type == DiscoveredDevice.remoteControlServiceType else {
            throw RemoteDesktopError.connectionFailed(
                "设备缺少当前强身份绑定的远程桌面 Bonjour 路由"
            )
        }
        let liveBonjourEndpoints = discoveryManager.liveBonjourServiceEndpoints(
            for: device,
            serviceType: .skybridgeRemote
        ).filter { endpoint in
            guard case .service(let name, let type, let domain, _) = endpoint,
                  let route = BonjourRouteTuple(name: name, type: type, domain: domain) else {
                return false
            }
            return route == preferredRoute
        }
        let plan = RemoteDesktopLANEndpointCandidateFactory.makePlan(
            liveBonjourEndpoints: liveBonjourEndpoints,
            remoteServiceType: DiscoveredDevice.remoteControlServiceType
        )
        SkyBridgeLogger.shared.info(
            "📡 远控 live route plan: eligible=\(plan.endpoints.count) ignored=\(plan.ignoredEndpointCount)"
        )

        if !plan.endpoints.isEmpty {
            return plan.endpoints
        }

        throw RemoteDesktopError.connectionFailed(
            "当前远程桌面 Bonjour 路由没有可验证的基础设施接口"
        )
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
