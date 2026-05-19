import Foundation
import Network

enum P2PConnectionEndpointPolicy {
    static func parseBonjourPeerIdentifier(_ peerId: String) -> (name: String, domain: String)? {
        guard peerId.hasPrefix("bonjour:") else { return nil }
        let payload = String(peerId.dropFirst("bonjour:".count))
        let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(parts.first) else { return nil }
        let domain = parts.count > 1 ? parts[1] : "local."
        return (name, domain)
    }

    static func shouldPreferBonjourSkyBridgeEndpoint(
        for device: DiscoveredDevice,
        bonjourName: String
    ) -> Bool {
        let normalizedBonjourName = bonjourName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBonjourName.isEmpty,
              isPlausibleSkyBridgeServiceInstanceName(normalizedBonjourName) else {
            return false
        }

        if device.services.contains(DiscoveryServiceType.skybridge.rawValue)
            || device.services.contains(DiscoveryServiceType.skybridgeQUIC.rawValue) {
            return true
        }

        if let bonjourServiceType = device.bonjourServiceType?.trimmingCharacters(in: .whitespacesAndNewlines),
           bonjourServiceType.hasPrefix("_skybridge") {
            return true
        }

        if device.id.hasPrefix("bonjour:") {
            return true
        }

        return false
    }

    static func isPlausibleSkyBridgeServiceInstanceName(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(raw) != nil else {
            return false
        }
        let lowercased = raw.lowercased()
        if lowercased == "unknown device" || lowercased == "未知设备" {
            return false
        }
        if lowercased.hasPrefix("id:")
            || lowercased.hasPrefix("host:")
            || lowercased.hasPrefix("peer:")
            || lowercased.hasPrefix("recent:") {
            return false
        }
        if UUID(uuidString: raw) != nil {
            return false
        }
        if let sanitized = connectableAddress(raw),
           sanitized == raw || sanitized == lowercased {
            return false
        }
        return true
    }

    static func deduplicatedConnectableCandidates(_ candidates: [DiscoveredDevice]) -> [DiscoveredDevice] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            let key = candidate.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return false }
            return seen.insert(key).inserted
        }
    }

    static func preferredConnectableDevice(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> DiscoveredDevice {
        connectableDeviceScore(rhs) > connectableDeviceScore(lhs) ? rhs : lhs
    }

    static func connectableDeviceScore(_ device: DiscoveredDevice) -> Int {
        let skybridgeTCP = DiscoveryServiceType.skybridge.rawValue
        let skybridgeUDP = DiscoveryServiceType.skybridgeQUIC.rawValue
        let remoteService = DiscoveredDevice.remoteControlServiceType
        let transferService = DiscoveredDevice.fileTransferServiceType

        var score = 0
        if normalizedStrongDeviceId(for: device) != nil {
            score += 220
        }
        if device.services.contains(skybridgeTCP) {
            score += 200
        }
        if device.bonjourServiceType == skybridgeTCP {
            score += 140
        }
        if device.portMap[skybridgeTCP] != nil {
            score += 100
        }
        if device.services.contains(skybridgeUDP) || device.portMap[skybridgeUDP] != nil {
            score += 40
        }
        if device.services.contains(remoteService) || device.bonjourServiceType == remoteService {
            score += 180
        }
        if device.remoteControlPort != nil {
            score += 140
        }
        if device.supportsRemoteControl {
            score += 120
        }
        if device.services.contains(transferService) || device.bonjourServiceType == transferService {
            score += 100
        }
        if device.fileTransferPort != nil {
            score += 80
        }
        if device.supportsFileTransfer {
            score += 60
        }
        if device.bonjourServiceName?.isEmpty == false {
            score += 60
        }
        if sanitizedConnectableAddress(for: device) != nil {
            score += 50
        }
        return score
    }

    static func uniqueSameNameConnectableCandidate(
        for device: DiscoveredDevice,
        candidates: [DiscoveredDevice]
    ) -> DiscoveredDevice? {
        let targetName = normalizedDeviceNameToken(device.name)
        guard !targetName.isEmpty else { return nil }

        let matches = candidates.filter { candidate in
            let candidateName = normalizedDeviceNameToken(candidate.name)
            guard candidateName == targetName else { return false }
            return candidate.platform == .unknown
                || device.platform == .unknown
                || candidate.platform == device.platform
        }

        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func normalizedDeviceNameToken(_ raw: String?) -> String {
        raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased() ?? ""
    }

    static func connectionEndpointCandidates(
        for device: DiscoveredDevice,
        preferDirectHostPort: Bool = false
    ) -> [NWEndpoint] {
        let parsedBonjourIdentity = parseBonjourPeerIdentifier(device.id)
        let bonjourName = BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(device.bonjourServiceName)
            ?? parsedBonjourIdentity?.name
        let bonjourDomain = device.bonjourServiceDomain
            ?? parsedBonjourIdentity?.domain
            ?? "local."
        let skybridgeTCP = DiscoveryServiceType.skybridge.rawValue
        let skybridgeUDP = DiscoveryServiceType.skybridgeQUIC.rawValue
        let portValue: UInt16 = device.portMap[skybridgeTCP]
            ?? device.portMap[skybridgeUDP]
            ?? 9527

        var candidates: [NWEndpoint] = []
        let scopedConnectableAddress = connectableAddress(for: device)
        let usableBonjourName =
            isPlausibleSkyBridgeServiceInstanceName(bonjourName)
            ? bonjourName?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let prefersBonjour = !preferDirectHostPort && shouldPreferBonjourSkyBridgeEndpoint(
            for: device,
            bonjourName: usableBonjourName ?? ""
        )

        if prefersBonjour, let usableBonjourName {
            candidates.append(
                .service(
                    name: usableBonjourName,
                    type: skybridgeTCP,
                    domain: bonjourDomain,
                    interface: nil
                )
            )
        }

        if let ipAddress = scopedConnectableAddress {
            candidates.append(
                .hostPort(
                    host: NWEndpoint.Host(ipAddress),
                    port: NWEndpoint.Port(integerLiteral: portValue)
                )
            )
        }

        if (preferDirectHostPort || !prefersBonjour),
           let usableBonjourName {
            candidates.append(
                .service(
                    name: usableBonjourName,
                    type: skybridgeTCP,
                    domain: bonjourDomain,
                    interface: nil
                )
            )
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert(String(describing: $0)).inserted }
    }

    static func signedLANRefreshEndpointClass(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort:
            return "direct-host"
        case .service:
            return "bonjour-service"
        default:
            return "other"
        }
    }

    static func shouldIncludePeerToPeer(for endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return true }
        return ConnectableAddressCanonicalizer.prefersPeerToPeer(for: String(describing: host))
    }

    static func normalizedStrongDeviceId(for device: DiscoveredDevice) -> String? {
        PeerIdentityAliasResolver.persistentDeviceId(from: device.id)
    }

    static func sanitizedConnectableAddress(for device: DiscoveredDevice) -> String? {
        sanitizedConnectableAddress(device.ipAddress) ?? sanitizedConnectableAddress(hostAddress(from: device.id))
    }

    static func connectableAddress(for device: DiscoveredDevice) -> String? {
        let hostScopedAddress = connectableAddress(hostAddress(from: device.id))
        if let directAddress = connectableAddress(device.ipAddress) {
            return directAddress
        }
        return hostScopedAddress
    }

    static func hostAddress(from identifier: String) -> String? {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("host:") {
            return String(normalized.dropFirst("host:".count))
        }
        if normalized.hasPrefix("peer:") {
            return String(normalized.dropFirst("peer:".count))
        }
        return nil
    }

    static func sanitizedConnectableAddress(_ raw: String?) -> String? {
        ConnectableAddressCanonicalizer.lookupKey(raw)
    }

    static func connectableAddress(_ raw: String?) -> String? {
        ConnectableAddressCanonicalizer.connectionTarget(raw)
    }

    static func endpointHostAddress(_ endpoint: NWEndpoint?) -> String? {
        guard let endpoint else { return nil }
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let ipv4):
            return "\(ipv4)"
        case .ipv6(let ipv6):
            return "\(ipv6)"
        case .name(let name, _):
            return name
        @unknown default:
            return nil
        }
    }

    static func isLoopbackAddress(_ ipAddress: String) -> Bool {
        let normalized = ipAddress.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
        return normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized == "0:0:0:0:0:0:0:1"
            || normalized == "::ffff:127.0.0.1"
            || normalized == "localhost"
    }
}
