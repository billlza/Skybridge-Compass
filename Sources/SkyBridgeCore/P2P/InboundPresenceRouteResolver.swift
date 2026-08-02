//
// InboundPresenceRouteResolver.swift
// Skybridge-Compass
//
// Resolves file-transfer route metadata for inbound P2P presence updates.
//

import Foundation

enum P2PPeerHostTokenNormalizer {
    static func normalize(_ raw: String) -> String {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("[") && token.hasSuffix("]") {
            token = String(token.dropFirst().dropLast())
        }
        // IPv6 链路本地地址 (fe80::/10) 必须保留 %zone 作用域 id：去掉后地址不可路由
        // （例如入站文件传输到 fe80::…%en0 无法连接）。只对非链路本地主机剥离 '%'，
        // 那里的 '%' 不承载连接作用域含义。
        if let pct = token.firstIndex(of: "%") {
            let isLinkLocalIPv6 = token.contains(":") && token.lowercased().hasPrefix("fe80")
            if !isLinkLocalIPv6 {
                token = String(token[..<pct])
            }
        }
        if token.contains(":"),
           let dot = token.lastIndex(of: "."),
           token[token.index(after: dot)...].allSatisfy({ $0.isNumber }) {
            token = String(token[..<dot])
        } else {
            let parts = token.split(separator: ".")
            if parts.count == 5,
               parts.dropLast().allSatisfy({ Int($0) != nil }),
               let port = Int(parts.last ?? ""), (0...65535).contains(port) {
                token = parts.dropLast().map(String.init).joined(separator: ".")
            }
        }
        return token.lowercased()
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension P2PDiscoveryService {
    struct InboundPresenceResolution: Sendable, Equatable {
        var name: String
        let displayAddress: String?
        let transferPort: Int
    }

    nonisolated static func resolveInboundPresenceRoute(
        peerId: String,
        endpointLabel: String,
        discoveredDevices: [DiscoveredDevice],
        unifiedDevices: [OnlineDevice]
    ) -> InboundPresenceResolution {
        InboundPresenceRouteResolver.resolve(
            peerId: peerId,
            endpointLabel: endpointLabel,
            discoveredDevices: discoveredDevices,
            unifiedDevices: unifiedDevices
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
private enum InboundPresenceRouteResolver {
    typealias Resolution = P2PDiscoveryService.InboundPresenceResolution

    static func resolve(
        peerId: String,
        endpointLabel: String,
        discoveredDevices: [DiscoveredDevice],
        unifiedDevices: [OnlineDevice]
    ) -> Resolution {
        func displayName(from identifier: String) -> String? {
            if identifier.hasPrefix("bonjour:") {
                let rest = identifier.dropFirst("bonjour:".count)
                return LocalDevicePresentation.sanitizedDisplayNameCandidate(
                    rest.split(separator: "@", maxSplits: 1).first.map(String.init)
                )
            }
            return LocalDevicePresentation.sanitizedDisplayNameCandidate(identifier)
        }

        func parseBonjourName(from identifier: String) -> String? {
            guard identifier.hasPrefix("bonjour:") else { return nil }
            let rest = identifier.dropFirst("bonjour:".count)
            return rest.split(separator: "@", maxSplits: 1).first.map(String.init)
        }

        func extractIP(from identifier: String) -> (ipv4: String?, ipv6: String?) {
            let payload: String
            if identifier.hasPrefix("peer:") {
                payload = String(identifier.dropFirst("peer:".count))
            } else if identifier.hasPrefix("host:") {
                payload = String(identifier.dropFirst("host:".count))
            } else if identifier.hasPrefix("bonjour:") || identifier.hasPrefix("id:") {
                return (nil, nil)
            } else {
                payload = identifier
            }

            let normalized = P2PPeerHostTokenNormalizer.normalize(payload)
            if normalized.contains(":") {
                return (nil, normalized)
            }
            if normalized.contains(".") {
                return (normalized, nil)
            }
            return (nil, nil)
        }

        func normalizedIdentifier(_ raw: String?) -> String? {
            raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        func canonicalDeviceId(from normalizedIdentifier: String?) -> String? {
            guard let identifier = normalizedIdentifier,
                  !identifier.isEmpty else {
                return nil
            }
            if identifier.hasPrefix("id:") {
                let value = String(identifier.dropFirst(3))
                return UUID(uuidString: value) == nil ? nil : value
            }
            return UUID(uuidString: identifier) == nil ? nil : identifier
        }

        func transferPort(from portMap: [String: Int]) -> Int {
            guard let candidate = portMap[BonjourInteropContract.fileTransferServiceType]
                    ?? portMap[BonjourInteropContract.legacyFileTransferServiceType],
                  (1...65535).contains(candidate) else {
                return -1
            }
            return candidate
        }

        func resolvedAddress(ipv4: String?, ipv6: String?, fallback: String?) -> String? {
            let candidate = ipv4 ?? ipv6 ?? fallback
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }

        let normalizedPeerId = normalizedIdentifier(peerId)
        let normalizedEndpointLabel = normalizedIdentifier(endpointLabel)
        let declaredDeviceId = canonicalDeviceId(from: normalizedPeerId)
        let hasStrongPeerIdentity = declaredDeviceId != nil
            || normalizedPeerId?.hasPrefix("fp:") == true
        let endpointLabelIsWeakBonjour = normalizedEndpointLabel?.hasPrefix("bonjour:") == true
        let endpointExtractedIP = extractIP(from: endpointLabel)
        let peerExtractedIP = extractIP(from: peerId)
        let bonjourName = parseBonjourName(from: endpointLabel) ?? parseBonjourName(from: peerId)
        let fallbackAddress = endpointExtractedIP.ipv4
            ?? endpointExtractedIP.ipv6
            ?? peerExtractedIP.ipv4
            ?? peerExtractedIP.ipv6
        let fallbackName = bonjourName.flatMap(displayName(from:)) ?? displayName(from: peerId)

        func normalizedAddressToken(_ raw: String?) -> String? {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                return nil
            }
            return P2PPeerHostTokenNormalizer.normalize(trimmed).lowercased()
        }

        func addressTokens(ipv4: String?, ipv6: String?, fallback: String? = nil) -> Set<String> {
            var tokens = Set<String>()
            for raw in [ipv4, ipv6, fallback] {
                if let token = normalizedAddressToken(raw) {
                    tokens.insert(token)
                }
            }
            return tokens
        }

        func stableIdentityTokens(_ raw: String?) -> Set<String> {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                return []
            }
            let lowercased = trimmed.lowercased()
            var tokens: Set<String> = [lowercased]
            if lowercased.hasPrefix("id:") {
                tokens.insert(String(lowercased.dropFirst(3)))
            } else if lowercased.hasPrefix("fp:") {
                tokens.insert(String(lowercased.dropFirst(3)))
            } else if UUID(uuidString: trimmed) != nil {
                tokens.insert("id:\(lowercased)")
            }
            return tokens
        }

        func discoveredIdentityTokens(_ device: DiscoveredDevice) -> Set<String> {
            stableIdentityTokens(device.deviceId)
                .union(stableIdentityTokens(device.uniqueIdentifier))
                .union(stableIdentityTokens(device.pubKeyFP.map { "fp:\($0)" }))
        }

        func unifiedIdentityTokens(_ device: OnlineDevice) -> Set<String> {
            stableIdentityTokens(device.uniqueIdentifier)
                .union(stableIdentityTokens(device.id.uuidString))
        }

        func peerIdentityTokens() -> Set<String> {
            stableIdentityTokens(declaredDeviceId)
                .union(stableIdentityTokens(normalizedPeerId))
        }

        let peerStableTokens = peerIdentityTokens()

        func hasPeerIdentityMatch(_ tokens: Set<String>) -> Bool {
            !peerStableTokens.isEmpty && !tokens.isDisjoint(with: peerStableTokens)
        }

        func discoveredRecordsAreRouteCompatible(
            identity: DiscoveredDevice,
            transfer: DiscoveredDevice
        ) -> Bool {
            if identity.id == transfer.id { return true }
            let identityTokens = discoveredIdentityTokens(identity)
            let transferTokens = discoveredIdentityTokens(transfer)
            if !identityTokens.isEmpty && !transferTokens.isEmpty,
               !identityTokens.isDisjoint(with: transferTokens) {
                return true
            }

            let identityExplicitAddresses = addressTokens(ipv4: identity.ipv4, ipv6: identity.ipv6)
            let transferAddresses = addressTokens(ipv4: transfer.ipv4, ipv6: transfer.ipv6)
            guard !transferAddresses.isEmpty else { return false }
            if !identityExplicitAddresses.isEmpty {
                return !identityExplicitAddresses.isDisjoint(with: transferAddresses)
            }

            let endpointAddresses = addressTokens(ipv4: nil, ipv6: nil, fallback: fallbackAddress)
            return !endpointAddresses.isEmpty && !endpointAddresses.isDisjoint(with: transferAddresses)
        }

        func unifiedRecordsAreRouteCompatible(
            identity: OnlineDevice,
            transfer: OnlineDevice
        ) -> Bool {
            if identity.id == transfer.id { return true }
            let identityTokens = unifiedIdentityTokens(identity)
            let transferTokens = unifiedIdentityTokens(transfer)
            if !identityTokens.isEmpty && !transferTokens.isEmpty,
               !identityTokens.isDisjoint(with: transferTokens) {
                return true
            }

            let identityExplicitAddresses = addressTokens(ipv4: identity.ipv4, ipv6: identity.ipv6)
            let transferAddresses = addressTokens(ipv4: transfer.ipv4, ipv6: transfer.ipv6)
            guard !transferAddresses.isEmpty else { return false }
            if !identityExplicitAddresses.isEmpty {
                return !identityExplicitAddresses.isDisjoint(with: transferAddresses)
            }

            let endpointAddresses = addressTokens(ipv4: nil, ipv6: nil, fallback: fallbackAddress)
            return !endpointAddresses.isEmpty && !endpointAddresses.isDisjoint(with: transferAddresses)
        }

        func discoveredScore(_ device: DiscoveredDevice) -> Int {
            var score = 0
            if let declaredDeviceId,
               device.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == declaredDeviceId {
                score += 500
            }
            if let normalizedPeerId,
               device.uniqueIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedPeerId {
                score += 420
            }
            if !endpointLabelIsWeakBonjour || !hasStrongPeerIdentity,
               let normalizedEndpointLabel,
               device.uniqueIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedEndpointLabel {
                score += 380
            }
            if let v4 = endpointExtractedIP.ipv4,
               device.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == v4 {
                score += 320
            }
            if let v6 = endpointExtractedIP.ipv6,
               device.ipv6?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == v6 {
                score += 320
            }
            if let v4 = peerExtractedIP.ipv4,
               device.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == v4 {
                score += 280
            }
            if let v6 = peerExtractedIP.ipv6,
               device.ipv6?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == v6 {
                score += 280
            }
            if !hasStrongPeerIdentity,
               let bonjourName,
               device.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains(bonjourName.lowercased()) {
                score += 180
            }
            if score > 0,
               device.portMap[BonjourInteropContract.fileTransferServiceType] != nil
                || device.portMap[BonjourInteropContract.legacyFileTransferServiceType] != nil {
                score += 40
            }
            return score
        }

        let scoredDiscovered = discoveredDevices
            .map { (device: $0, score: discoveredScore($0), port: transferPort(from: $0.portMap)) }
            .filter { $0.score > 0 }
            .sorted {
                if ($0.port > 0) != ($1.port > 0) { return $0.port > 0 }
                return $0.score > $1.score
            }

        let bestDiscoveredIdentity = scoredDiscovered.max(by: { $0.score < $1.score })
        if let bestDiscovered = scoredDiscovered.first(where: { candidate in
            guard candidate.port > 0,
                  resolvedAddress(ipv4: candidate.device.ipv4, ipv6: candidate.device.ipv6, fallback: fallbackAddress) != nil else {
                return false
            }
            guard hasStrongPeerIdentity else { return true }
            if hasPeerIdentityMatch(discoveredIdentityTokens(candidate.device)) {
                return true
            }
            guard let bestDiscoveredIdentity else { return false }
            return discoveredRecordsAreRouteCompatible(
                identity: bestDiscoveredIdentity.device,
                transfer: candidate.device
            )
        }) {
            return Resolution(
                name: bestDiscovered.device.name,
                displayAddress: resolvedAddress(
                    ipv4: bestDiscovered.device.ipv4,
                    ipv6: bestDiscovered.device.ipv6,
                    fallback: fallbackAddress
                ),
                transferPort: bestDiscovered.port
            )
        }

        if let bestIdentity = bestDiscoveredIdentity {
            let port = scoredDiscovered.first { candidate in
                candidate.port > 0
                    && discoveredRecordsAreRouteCompatible(
                        identity: bestIdentity.device,
                        transfer: candidate.device
                    )
            }?.port ?? -1
            if port > 0,
               let address = resolvedAddress(
                   ipv4: bestIdentity.device.ipv4,
                   ipv6: bestIdentity.device.ipv6,
                   fallback: fallbackAddress
               ) {
                return Resolution(
                    name: bestIdentity.device.name,
                    displayAddress: address,
                    transferPort: port
                )
            }
        }

        func unifiedScore(_ device: OnlineDevice) -> Int {
            var score = 0
            if let declaredDeviceId,
               device.uniqueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "id:\(declaredDeviceId)" {
                score += 500
            }
            if let normalizedPeerId,
               device.uniqueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedPeerId {
                score += 420
            }
            if !endpointLabelIsWeakBonjour || !hasStrongPeerIdentity,
               let normalizedEndpointLabel,
               device.uniqueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedEndpointLabel {
                score += 380
            }
            if let v4 = endpointExtractedIP.ipv4,
               device.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == v4 {
                score += 320
            }
            if let v6 = endpointExtractedIP.ipv6,
               device.ipv6?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == v6 {
                score += 320
            }
            if !hasStrongPeerIdentity,
               let bonjourName,
               device.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == bonjourName.lowercased() {
                score += 180
            }
            if score > 0,
               device.portMap[BonjourInteropContract.fileTransferServiceType] != nil
                || device.portMap[BonjourInteropContract.legacyFileTransferServiceType] != nil {
                score += 40
            }
            return score
        }

        let scoredUnified = unifiedDevices
            .map { (device: $0, score: unifiedScore($0), port: transferPort(from: $0.portMap)) }
            .filter { $0.score > 0 }
            .sorted {
                if ($0.port > 0) != ($1.port > 0) { return $0.port > 0 }
                return $0.score > $1.score
            }

        let bestUnifiedIdentity = scoredUnified.max(by: { $0.score < $1.score })
        if let bestUnified = scoredUnified.first(where: { candidate in
            guard candidate.port > 0,
                  resolvedAddress(ipv4: candidate.device.ipv4, ipv6: candidate.device.ipv6, fallback: fallbackAddress) != nil else {
                return false
            }
            guard hasStrongPeerIdentity else { return true }
            if hasPeerIdentityMatch(unifiedIdentityTokens(candidate.device)) {
                return true
            }
            guard let bestUnifiedIdentity else { return false }
            return unifiedRecordsAreRouteCompatible(
                identity: bestUnifiedIdentity.device,
                transfer: candidate.device
            )
        }) {
            return Resolution(
                name: bestUnified.device.name,
                displayAddress: resolvedAddress(
                    ipv4: bestUnified.device.ipv4,
                    ipv6: bestUnified.device.ipv6,
                    fallback: fallbackAddress
                ),
                transferPort: bestUnified.port
            )
        }

        if let bestIdentity = bestUnifiedIdentity {
            let port = scoredUnified.first { candidate in
                candidate.port > 0
                    && unifiedRecordsAreRouteCompatible(
                        identity: bestIdentity.device,
                        transfer: candidate.device
                    )
            }?.port ?? -1
            if port > 0,
               let address = resolvedAddress(
                   ipv4: bestIdentity.device.ipv4,
                   ipv6: bestIdentity.device.ipv6,
                   fallback: fallbackAddress
               ) {
                return Resolution(
                    name: bestIdentity.device.name,
                    displayAddress: address,
                    transferPort: port
                )
            }
        }

        return Resolution(
            name: fallbackName ?? "P2P Peer",
            displayAddress: fallbackAddress,
            transferPort: -1
        )
    }
}
