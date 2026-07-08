import Foundation

enum P2PDiscoveryBonjourPolicy {
    nonisolated static func normalizedConnectableServiceTypes(from rawTypes: [String]) -> [String] {
        let allowedTypes: Set<String> = ["_skybridge._tcp", "_skybridge._udp"]
        var seen = Set<String>()
        var ordered: [String] = []

        for rawType in rawTypes {
            let normalized = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard allowedTypes.contains(normalized), isValidBonjourServiceType(normalized) else {
                continue
            }
            if seen.insert(normalized).inserted {
                ordered.append(normalized)
            }
        }
        return ordered
    }

    nonisolated static func isValidBonjourServiceType(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.hasPrefix("_") else { return false }
        guard value.hasSuffix("._tcp") || value.hasSuffix("._udp") else { return false }

        let serviceLabel = value
            .replacingOccurrences(of: "._tcp", with: "")
            .replacingOccurrences(of: "._udp", with: "")
            .dropFirst()
        guard !serviceLabel.isEmpty, serviceLabel.count <= 15 else { return false }
        return serviceLabel.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    nonisolated static func isBonjourIdentifier(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("bonjour:") || normalized.hasPrefix("recent:bonjour:")
    }

    nonisolated static func preferredRoutableBonjourIdentifier(for device: DiscoveredDevice) -> String? {
        for routeIdentifier in device.routeIdentifiers {
            if let routable = routableBonjourIdentifier(routeIdentifier) {
                return routable
            }
        }
        return routableBonjourIdentifier(device.uniqueIdentifier)
    }

    nonisolated static func connectionPeerIdentifier(
        for device: DiscoveredDevice,
        usesBonjourServiceEndpoint: Bool
    ) -> String? {
        if usesBonjourServiceEndpoint,
           let routeIdentifier = preferredRoutableBonjourIdentifier(for: device) {
            return routeIdentifier
        }
        if let persistentDeviceId = trimmedNonEmpty(device.deviceId) {
            return persistentDeviceId
        }
        return trimmedNonEmpty(device.uniqueIdentifier)
    }

    nonisolated static func isRoutableBonjourIdentifier(_ identifier: String?) -> Bool {
        routableBonjourIdentifier(identifier) != nil
    }

    nonisolated static func isLikelyIPAddress(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(":") { return true }
        let segments = trimmed.split(separator: ".")
        return segments.count == 4 && segments.allSatisfy { part in
            guard let value = Int(part), (0...255).contains(value) else { return false }
            return String(value) == String(part) || part == "0"
        }
    }

    nonisolated static func resolvedBonjourServiceName(for device: DiscoveredDevice) -> String {
        resolvedBonjourServiceNameCandidates(for: device).first ?? ""
    }

    nonisolated static func resolvedBonjourServiceNameCandidates(for device: DiscoveredDevice) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()
        let hasStrongIdentity =
            device.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || device.pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || isStrongUniqueIdentifier(device.uniqueIdentifier)

        func append(_ raw: String?) {
            let sanitized = sanitizedBonjourServiceName(raw ?? "")
            guard !sanitized.isEmpty else { return }
            guard !seen.contains(sanitized) else { return }
            seen.insert(sanitized)
            candidates.append(sanitized)
        }

        for routeIdentifier in device.routeIdentifiers {
            append(extractBonjourServiceName(fromIdentifier: routeIdentifier))
        }

        let identifierName = extractBonjourServiceName(fromIdentifier: device.uniqueIdentifier)
        let inferredAppleName = inferredDefaultAppleBonjourServiceName(fromDisplayName: device.name)

        append(identifierName)
        guard !hasStrongIdentity else {
            return candidates
        }
        if identifierName == nil {
            append(inferredAppleName)
            append(device.name)
        } else {
            append(device.name)
            append(inferredAppleName)
        }
        return candidates
    }

    private nonisolated static func routableBonjourIdentifier(_ identifier: String?) -> String? {
        guard let raw = trimmedNonEmpty(identifier),
              isBonjourIdentifier(raw),
              let serviceName = extractBonjourServiceName(fromIdentifier: raw) else {
            return nil
        }
        let trimmedServiceName = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedServiceName = trimmedServiceName.lowercased()
        guard !trimmedServiceName.isEmpty,
              !lowercasedServiceName.hasPrefix("id:"),
              !lowercasedServiceName.hasPrefix("fp:"),
              !lowercasedServiceName.hasPrefix("host:"),
              !lowercasedServiceName.hasPrefix("peer:"),
              UUID(uuidString: trimmedServiceName.uppercased()) == nil,
              !isLikelyIPAddress(lowercasedServiceName),
              !sanitizedBonjourServiceName(trimmedServiceName).isEmpty else {
            return nil
        }
        return raw
    }

    nonisolated static func extractBonjourServiceName(fromIdentifier identifier: String?) -> String? {
        guard let identifier else { return nil }
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)

        func parseName(from payload: String) -> String? {
            let name = payload.split(separator: "@", maxSplits: 1).first.map(String.init)
            guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                return nil
            }
            return legacyMangledBonjourServiceName(from: trimmed) ?? trimmed
        }

        func parsePlainName(from payload: String) -> String? {
            payload.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if normalized.hasPrefix("recent:bonjour:") {
            let payload = String(normalized.dropFirst("recent:bonjour:".count))
            return parseName(from: payload)
        }
        if normalized.hasPrefix("bonjour:") {
            let payload = String(normalized.dropFirst("bonjour:".count))
            return parseName(from: payload)
        }
        if normalized.hasPrefix("recent:name:") {
            let payload = String(normalized.dropFirst("recent:name:".count))
            return parsePlainName(from: payload)
        }
        if normalized.hasPrefix("name:") {
            let payload = String(normalized.dropFirst("name:".count))
            return parsePlainName(from: payload)
        }
        return nil
    }

    nonisolated static func sanitizedBonjourServiceName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }

        if PeerTrustLookup.sanitizedBonjourServiceInstanceName(name) == nil {
            return ""
        }

        while true {
            if let suffix = trailingBracketSuffix(from: name, open: "(", close: ")") {
                guard shouldStripTrailingBracketSuffix(payload: suffix.payload, open: "(") else {
                    break
                }
                name = suffix.prefix
                continue
            }
            if let suffix = trailingBracketSuffix(from: name, open: "[", close: "]") {
                name = suffix.prefix
                continue
            }
            if let suffix = trailingBracketSuffix(from: name, open: "【", close: "】") {
                name = suffix.prefix
                continue
            }
            break
        }

        for suffix in [" 📱", " 🍎"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return PeerTrustLookup.sanitizedBonjourServiceInstanceName(name) ?? ""
    }

    private nonisolated static func shouldStripTrailingBracketSuffix(payload: String, open: Character) -> Bool {
        guard open == "(" else { return true }
        return !isAppleHardwareModelSuffix(payload)
    }

    private nonisolated static func isAppleHardwareModelSuffix(_ raw: String) -> Bool {
        let compact = raw
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard compact.count >= 2 else { return false }

        if compact.hasPrefix("m") {
            var tail = String(compact.dropFirst())
            for suffix in ["ultra", "max", "pro"] where tail.hasSuffix(suffix) {
                tail.removeLast(suffix.count)
                break
            }
            return !tail.isEmpty && tail.allSatisfy(\.isNumber)
        }

        if compact.hasPrefix("a") {
            var tail = String(compact.dropFirst())
            if tail.hasSuffix("x") || tail.hasSuffix("z") {
                tail.removeLast()
            }
            return !tail.isEmpty && tail.allSatisfy(\.isNumber)
        }

        return false
    }

    private nonisolated static func legacyMangledBonjourServiceName(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        let suffixes = ["__local.", "_local.", ".local."]
        guard let suffix = suffixes.first(where: { lowered.hasSuffix($0) }) else {
            return nil
        }

        var value = String(trimmed.dropLast(suffix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        var bracketedSuffix: String?
        if let range = value.range(of: "__", options: .backwards) {
            let suffixCandidate = String(value[range.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "_ ").union(.whitespacesAndNewlines))
            let baseCandidate = String(value[..<range.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: "_ ").union(.whitespacesAndNewlines))
            if !suffixCandidate.isEmpty, !baseCandidate.isEmpty {
                bracketedSuffix = suffixCandidate.replacingOccurrences(of: "_", with: " ")
                value = baseCandidate
            }
        }

        let baseName = value
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseName.isEmpty else { return nil }
        if let bracketedSuffix, !bracketedSuffix.isEmpty {
            return "\(baseName) (\(bracketedSuffix))"
        }
        return baseName
    }

    nonisolated static func stripTrailingBracketSuffix(
        from raw: String,
        open: Character,
        close: Character
    ) -> String? {
        trailingBracketSuffix(from: raw, open: open, close: close)?.prefix
    }

    private nonisolated static func trailingBracketSuffix(
        from raw: String,
        open: Character,
        close: Character
    ) -> (prefix: String, payload: String)? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.last == close else { return nil }
        guard let openIndex = value.lastIndex(of: open), openIndex > value.startIndex else { return nil }

        let prefix = value[..<openIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let payloadStart = value.index(after: openIndex)
        let payloadEnd = value.index(before: value.endIndex)
        let payload = value[payloadStart..<payloadEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return nil }
        return (String(prefix), String(payload))
    }

    nonisolated static func inferredDefaultAppleBonjourServiceName(fromDisplayName displayName: String) -> String? {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        if normalized.contains("iphone") { return "iPhone" }
        if normalized.contains("ipad") { return "iPad" }
        if normalized.contains("macbook")
            || normalized.contains("imac")
            || normalized.contains("mac mini")
            || normalized.contains("mac studio")
            || normalized.contains("mac pro")
            || normalized == "mac"
            || normalized.contains(" mac ") {
            return "Mac"
        }
        return nil
    }

    nonisolated static func advertisedServicePort(from txt: [String: String], serviceType: String) -> Int? {
        let keys: [String]
        switch serviceType {
        case "_skybridge._tcp", "_skybridge._udp":
            keys = ["port", "skybridgePort", "p2pPort", "controlPort"]
        case "_skybridge-transfer._tcp":
            keys = ["transferPort", "fileTransferPort", "file_transfer_port", "port"]
        case "_skybridge-remote._tcp":
            keys = ["remotePort", "remoteControlPort", "remote_port", "port"]
        default:
            keys = ["port"]
        }

        let raw = keys.lazy.compactMap { txt[$0] }.first
        guard let raw,
              let port = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(port) else {
            return nil
        }
        return port
    }

    nonisolated static func normalizeSOAFlag(_ value: String?) -> Bool {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return false
        }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    nonisolated static func isStrongUniqueIdentifier(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.hasPrefix("id:") || value.hasPrefix("fp:")
    }

    nonisolated static func preferredUniqueIdentifier(
        deviceId: String?,
        pubKeyFP: String?,
        bonjourIdentifier: String?,
        ipv4: String?,
        ipv6: String?
    ) -> String? {
        if let deviceId, !deviceId.isEmpty { return "id:\(deviceId)" }
        if let pubKeyFP, !pubKeyFP.isEmpty { return "fp:\(pubKeyFP)" }
        if let bonjourIdentifier, !bonjourIdentifier.isEmpty { return bonjourIdentifier }
        if let ipv4, !ipv4.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "ip:\(ipv4)" }
        if let ipv6, !ipv6.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "ip:\(ipv6)" }
        return nil
    }

    nonisolated static func normalizeIdentifierForMatching(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("recent:") {
            value.removeFirst("recent:".count)
        }
        return value.isEmpty ? nil : value
    }

    nonisolated static func normalizeIPAddressForMatching(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if value.contains(":"), let base = value.split(separator: "%", maxSplits: 1).first {
            value = String(base)
        }
        return value
    }

    nonisolated static func normalizedNameTokenForMatching(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private nonisolated static func trimmedNonEmpty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
