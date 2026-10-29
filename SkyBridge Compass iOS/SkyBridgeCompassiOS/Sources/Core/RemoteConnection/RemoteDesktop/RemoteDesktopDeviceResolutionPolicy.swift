import Foundation

@available(iOS 17.0, *)
extension RemoteDesktopManager {
    static func hasExplicitLANRemoteDesktopEndpoint(_ device: DiscoveredDevice) -> Bool {
        device.remoteControlPort != nil
            || device.services.contains(DiscoveredDevice.remoteControlServiceType)
            || device.bonjourServiceType == DiscoveredDevice.remoteControlServiceType
    }

    public static func resolveBestRemoteDesktopDevice(
        target: DiscoveredDevice,
        discovered: [DiscoveredDevice]
    ) -> DiscoveredDevice {
        let targetScore = remoteDesktopResolutionScore(candidate: target, target: target)
        let bestCandidate = discovered.max { lhs, rhs in
            remoteDesktopResolutionScore(candidate: lhs, target: target)
                < remoteDesktopResolutionScore(candidate: rhs, target: target)
        }

        guard let bestCandidate else { return target }
        let bestScore = remoteDesktopResolutionScore(candidate: bestCandidate, target: target)
        return bestScore > targetScore ? bestCandidate : target
    }

    private static func remoteDesktopResolutionScore(
        candidate: DiscoveredDevice,
        target: DiscoveredDevice
    ) -> Int {
        let targetIdentity = normalizedRemoteDesktopIdentity(target.id)
        let candidateIdentity = normalizedRemoteDesktopIdentity(candidate.id)
        let exactIdMatch = !targetIdentity.isEmpty && targetIdentity == candidateIdentity
        let stableExactIdMatch = exactIdMatch && isStableRemoteDesktopIdentity(candidate.id)

        let targetIP = bestRemoteDesktopIPAddress(for: target)
        let candidateIP = bestRemoteDesktopIPAddress(for: candidate)
        let ipMatch = targetIP != nil && targetIP == candidateIP

        let targetBonjour = bonjourIdentityComponents(for: target)
        let candidateBonjour = bonjourIdentityComponents(for: candidate)
        let bonjourMatch = targetBonjour != nil && targetBonjour == candidateBonjour

        let targetName = normalizedRemoteDesktopDeviceName(target.name)
        let candidateName = normalizedRemoteDesktopDeviceName(candidate.name)
        let nameMatch = !targetName.isEmpty && targetName == candidateName

        let targetAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: target))
        let candidateAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: candidate))
        let aliasMatch = !targetAliases.isEmpty && !candidateAliases.isDisjoint(with: targetAliases)

        guard exactIdMatch || ipMatch || bonjourMatch || nameMatch || aliasMatch else {
            return 0
        }

        var score = 0
        if stableExactIdMatch {
            score += 300
        } else if exactIdMatch {
            score += 80
        }
        if ipMatch { score += 250 }
        if bonjourMatch { score += 220 }
        if nameMatch { score += 160 }
        if aliasMatch { score += 260 }

        if candidate.services.contains(DiscoveredDevice.remoteControlServiceType)
            || candidate.bonjourServiceType == DiscoveredDevice.remoteControlServiceType {
            score += 260
        }
        if candidate.remoteControlPort != nil { score += 180 }
        if candidateIP != nil { score += 120 }
        if candidate.supportsRemoteControl { score += 60 }
        if !candidate.services.isEmpty { score += 40 }

        return score
    }

    static func isStableRemoteDesktopIdentity(_ raw: String?) -> Bool {
        let normalized = normalizedRemoteDesktopIdentity(raw)
        guard !normalized.isEmpty else {
            return false
        }
        return !(normalized.hasPrefix("host:")
            || normalized.hasPrefix("peer:")
            || normalized.hasPrefix("bonjour:")
            || normalized.hasPrefix("recent:"))
    }

    private static func normalizedRemoteDesktopIdentity(_ raw: String?) -> String {
        raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func normalizedRemoteDesktopDeviceName(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    private static func bonjourIdentityComponents(for device: DiscoveredDevice) -> String? {
        let name = device.bonjourServiceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = device.bonjourServiceDomain?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            let normalizedDomain = (domain?.isEmpty == false ? domain! : "local.")
            return "\(name.lowercased())@\(normalizedDomain.lowercased())"
        }

        if let parsed = parseRemoteDesktopBonjourIdentity(from: device.id) {
            return "\(parsed.name.lowercased())@\(parsed.domain.lowercased())"
        }

        return nil
    }

    private static func parseRemoteDesktopBonjourIdentity(
        from identifier: String
    ) -> (name: String, domain: String)? {
        guard identifier.hasPrefix("bonjour:") else { return nil }
        let payload = String(identifier.dropFirst("bonjour:".count))
        let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return nil }
        let domain = parts.count > 1 ? parts[1] : "local."
        return (name, domain)
    }

    private static func bestRemoteDesktopIPAddress(for device: DiscoveredDevice) -> String? {
        sanitizeRemoteDesktopAddress(device.ipAddress)
            ?? sanitizeRemoteDesktopAddress(addressFromRemoteDesktopIdentifier(device.id))
    }

    private static func addressFromRemoteDesktopIdentifier(_ identifier: String) -> String? {
        if identifier.hasPrefix("host:") {
            return String(identifier.dropFirst("host:".count))
        }
        if identifier.hasPrefix("peer:") {
            return String(identifier.dropFirst("peer:".count))
        }
        return nil
    }

    private static func sanitizeRemoteDesktopAddress(_ raw: String?) -> String? {
        ConnectableAddressCanonicalizer.lookupKey(raw)
    }

    static func mergingUniqueStrings(_ primary: [String], _ secondary: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in primary + secondary {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    static func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func deduplicatedRemoteDesktopCandidates(_ candidates: [DiscoveredDevice]) -> [DiscoveredDevice] {
        var deduplicated: [DiscoveredDevice] = []

        for candidate in candidates {
            let candidateId = candidate.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidateId.isEmpty else { continue }

            let candidateAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: candidate))
            if let index = deduplicated.firstIndex(where: { existing in
                if existing.id == candidate.id {
                    return true
                }
                let existingAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: existing))
                return !candidateAliases.isEmpty
                    && !existingAliases.isEmpty
                    && !candidateAliases.isDisjoint(with: existingAliases)
            }) {
                deduplicated[index] = preferredRemoteDesktopDevice(deduplicated[index], candidate)
            } else {
                deduplicated.append(candidate)
            }
        }
        return deduplicated
    }

    func isPlausibleRemoteServiceInstanceName(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
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
        if let sanitized = sanitizeAddress(raw),
           sanitized == lowercased || sanitized == raw {
            return false
        }
        return true
    }

    func preferredRemoteDesktopDevice(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> DiscoveredDevice {
        remoteDesktopDeviceScore(rhs) > remoteDesktopDeviceScore(lhs) ? rhs : lhs
    }

    func areEquivalentRemoteDesktopDevices(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> Bool {
        if lhs.id == rhs.id {
            return true
        }

        let lhsAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: lhs))
        let rhsAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: rhs))
        return !lhsAliases.isEmpty && !rhsAliases.isEmpty && !lhsAliases.isDisjoint(with: rhsAliases)
    }

    func remoteDesktopDeviceScore(_ device: DiscoveredDevice) -> Int {
        var score = 0
        if device.services.contains(DiscoveredDevice.remoteControlServiceType)
            || device.bonjourServiceType == DiscoveredDevice.remoteControlServiceType {
            score += 120
        }
        if device.remoteControlPort != nil {
            score += 100
        }
        if bestIPAddress(for: device) != nil {
            score += 80
        }
        if device.supportsRemoteControl {
            score += 40
        }
        if let serviceName = device.bonjourServiceName, !serviceName.isEmpty {
            score += 40
        }
        if !device.services.isEmpty {
            score += 20
        }
        if !normalizeDeviceName(device.name).isEmpty {
            score += 10
        }
        return score
    }

    func normalizeDeviceName(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    func parseBonjourIdentity(from identifier: String) -> (name: String, domain: String)? {
        guard identifier.hasPrefix("bonjour:") else { return nil }
        let payload = String(identifier.dropFirst("bonjour:".count))
        let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return nil }
        let domain = parts.count > 1 ? parts[1] : "local."
        return (name, domain)
    }

    func bestIPAddress(for device: DiscoveredDevice) -> String? {
        ConnectableAddressCanonicalizer.bestLANAddress([
            device.ipAddress,
            addressFromIdentifier(device.id)
        ])
    }

    func addressFromIdentifier(_ identifier: String) -> String? {
        if identifier.hasPrefix("host:") {
            return String(identifier.dropFirst("host:".count))
        }
        if identifier.hasPrefix("peer:") {
            return String(identifier.dropFirst("peer:".count))
        }
        return nil
    }

    func sanitizeAddress(_ raw: String?) -> String? {
        ConnectableAddressCanonicalizer.connectionTarget(raw)
    }
}
