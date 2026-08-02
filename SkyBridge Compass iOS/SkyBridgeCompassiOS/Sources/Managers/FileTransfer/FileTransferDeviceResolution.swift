import Foundation

@available(iOS 17.0, *)
extension FileTransferManager {
    static func shouldPreferCrossNetworkTransfer(
        targetDeviceId: String,
        crossNetworkState: CrossNetworkWebRTCManager.State,
        crossNetworkRemoteDeviceId: String?,
        localActiveConnectionDeviceIds: Set<String>
    ) -> Bool {
        guard case .connected = crossNetworkState else { return false }

        let normalizedTarget = normalizedTransferIdentity(targetDeviceId)
        guard !normalizedTarget.isEmpty else { return false }

        let normalizedRemote = normalizedTransferIdentity(crossNetworkRemoteDeviceId)
        guard normalizedRemote == normalizedTarget else { return false }

        let normalizedLocalActiveIds = Set(localActiveConnectionDeviceIds.map(normalizedTransferIdentity))
        return !normalizedLocalActiveIds.contains(normalizedTarget)
    }

    static func resolveBestTransferDevice(
        target: DiscoveredDevice,
        discovered: [DiscoveredDevice]
    ) -> DiscoveredDevice {
        let scopedTargetAddresses = scopedLinkLocalTransferAddresses(for: target)
        if !scopedTargetAddresses.isEmpty {
            guard scopedTargetAddresses.count == 1,
                  let scopedTargetAddress = scopedTargetAddresses.first else {
                return target
            }
            return uniquelyResolvedScopedLinkLocalTransferCandidate(
                targetAddress: scopedTargetAddress,
                discovered: discovered
            ) ?? target
        }

        let targetScore = transferResolutionScore(candidate: target, target: target)
        let bestCandidate = discovered.max { lhs, rhs in
            let left = transferResolutionScore(candidate: lhs, target: target)
            let right = transferResolutionScore(candidate: rhs, target: target)
            if left != right { return left < right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedDescending
        }

        guard let bestCandidate else { return target }
        let bestScore = transferResolutionScore(candidate: bestCandidate, target: target)
        return bestScore > targetScore ? bestCandidate : target
    }

    private static func uniquelyResolvedScopedLinkLocalTransferCandidate(
        targetAddress: String,
        discovered: [DiscoveredDevice]
    ) -> DiscoveredDevice? {
        guard let targetLookupKey = ConnectableAddressCanonicalizer.lookupKey(targetAddress) else {
            return nil
        }

        let matches = discovered.filter { candidate in
            guard hasCompleteFileTransferRoute(candidate) else { return false }

            let candidateAddresses = transferConnectionAddresses(for: candidate)
            let candidateScopedAddresses = Set(candidateAddresses.filter { $0.contains("%") })
            guard candidateScopedAddresses.isEmpty
                    || candidateScopedAddresses == [targetAddress] else {
                return false
            }

            return candidateAddresses.contains { address in
                ConnectableAddressCanonicalizer.lookupKey(address) == targetLookupKey
            }
        }

        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private static func scopedLinkLocalTransferAddresses(
        for device: DiscoveredDevice
    ) -> Set<String> {
        Set(
            transferConnectionAddresses(for: device).filter { address in
                address.contains("%")
                    && ConnectableAddressCanonicalizer.isLinkLocal(address)
            }
        )
    }

    private static func transferConnectionAddresses(for device: DiscoveredDevice) -> [String] {
        [device.ipAddress, addressFromTransferIdentifier(device.id)]
            .compactMap(ConnectableAddressCanonicalizer.connectionTarget)
    }

    private static func hasCompleteFileTransferRoute(_ device: DiscoveredDevice) -> Bool {
        guard BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(
            device.bonjourServiceName
        ) != nil,
        device.bonjourServiceType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == DiscoveredDevice.fileTransferServiceType,
        let domain = device.bonjourServiceDomain?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !domain.isEmpty,
        let port = device.fileTransferPort,
        port > 0 else {
            return false
        }
        return true
    }

    static func areEquivalentTransferDevices(
        _ lhs: DiscoveredDevice,
        _ rhs: DiscoveredDevice
    ) -> Bool {
        if lhs.id == rhs.id {
            return true
        }

        let lhsAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: lhs))
        let rhsAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: rhs))
        return !lhsAliases.isEmpty && !rhsAliases.isEmpty && !lhsAliases.isDisjoint(with: rhsAliases)
    }

    static func normalizedTransferIdentity(_ raw: String?) -> String {
        raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    static func sanitizeTransferAddress(_ raw: String?) -> String? {
        ConnectableAddressCanonicalizer.lookupKey(raw)
    }

    private static func transferResolutionScore(candidate: DiscoveredDevice, target: DiscoveredDevice) -> Int {
        let targetIdentity = normalizedTransferIdentity(target.id)
        let candidateIdentity = normalizedTransferIdentity(candidate.id)
        let exactIdMatch = !targetIdentity.isEmpty && targetIdentity == candidateIdentity
        let stableExactIdMatch = exactIdMatch && isStableTransferIdentity(candidate.id)

        let targetIP = bestTransferIPAddress(for: target)
        let candidateIP = bestTransferIPAddress(for: candidate)
        let ipMatch = targetIP != nil && targetIP == candidateIP

        let targetBonjour = bonjourIdentityComponents(for: target)
        let candidateBonjour = bonjourIdentityComponents(for: candidate)
        let bonjourMatch = targetBonjour != nil && targetBonjour == candidateBonjour

        let targetName = normalizedTransferDeviceName(target.name)
        let candidateName = normalizedTransferDeviceName(candidate.name)
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

        if candidate.services.contains(DiscoveredDevice.fileTransferServiceType)
            || candidate.bonjourServiceType == DiscoveredDevice.fileTransferServiceType {
            score += 240
        }
        if candidate.fileTransferPort != nil { score += 160 }
        if candidateIP != nil { score += 120 }
        if !candidate.services.isEmpty { score += 40 }

        return score
    }

    private static func isStableTransferIdentity(_ raw: String?) -> Bool {
        let normalized = normalizedTransferIdentity(raw)
        guard !normalized.isEmpty else {
            return false
        }
        return !(normalized.hasPrefix("host:")
            || normalized.hasPrefix("peer:")
            || normalized.hasPrefix("bonjour:")
            || normalized.hasPrefix("recent:"))
    }

    private static func normalizedTransferDeviceName(_ raw: String) -> String {
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

        if let parsed = parseTransferBonjourIdentity(from: device.id) {
            return "\(parsed.name.lowercased())@\(parsed.domain.lowercased())"
        }

        return nil
    }

    private static func parseTransferBonjourIdentity(from identifier: String) -> (name: String, domain: String)? {
        guard identifier.hasPrefix("bonjour:") else { return nil }
        let payload = String(identifier.dropFirst("bonjour:".count))
        let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return nil }
        let domain = parts.count > 1 ? parts[1] : "local."
        return (name, domain)
    }

    private static func bestTransferIPAddress(for device: DiscoveredDevice) -> String? {
        sanitizeTransferAddress(device.ipAddress)
            ?? sanitizeTransferAddress(addressFromTransferIdentifier(device.id))
    }

    private static func addressFromTransferIdentifier(_ identifier: String) -> String? {
        if identifier.hasPrefix("host:") {
            return String(identifier.dropFirst("host:".count))
        }
        if identifier.hasPrefix("peer:") {
            return String(identifier.dropFirst("peer:".count))
        }
        return nil
    }
}
