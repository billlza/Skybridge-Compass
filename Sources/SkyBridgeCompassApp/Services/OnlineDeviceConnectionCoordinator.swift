import Foundation
import SkyBridgeCore

@available(macOS 14.0, *)
enum OnlineDeviceConnectionCoordinator {
    private struct ConnectionPlan: Sendable {
        let discoveredCandidates: [DiscoveredDevice]
        let routePreference: P2PDiscoveryService.ConnectionRoutePreference
    }

    @MainActor
    static func connect(to device: OnlineDevice) async throws {
        try await connect(
            to: device,
            unifiedDeviceManager: .shared,
            p2pDiscoveryService: .shared
        )
    }

    static func connect(
        to device: OnlineDevice,
        unifiedDeviceManager: UnifiedOnlineDeviceManager,
        p2pDiscoveryService: P2PDiscoveryService
    ) async throws {
        let plan = try await MainActor.run {
            try makeConnectionPlan(for: device, unifiedDeviceManager: unifiedDeviceManager)
        }

        var lastError: Error?
        for candidate in plan.discoveredCandidates {
            do {
                try await p2pDiscoveryService.connectToDevice(candidate, routePreference: plan.routePreference)
                await unifiedDeviceManager.markDeviceAsConnected(device.id)
                return
            } catch {
                lastError = error
                let candidateLabel = redactedPeerLabel(candidate.deviceId ?? candidate.uniqueIdentifier ?? candidate.name)
                SkyBridgeLogger.discovery.warning(
                    "在线设备候选连接失败，将尝试下一个候选: peer=\(candidateLabel, privacy: .public) err=\(errorSummary(error), privacy: .public)"
                )
            }
        }

        throw lastError ?? P2PDiscoveryError.noConnectableEndpoint
    }

    @MainActor
    private static func makeConnectionPlan(
        for device: OnlineDevice,
        unifiedDeviceManager: UnifiedOnlineDeviceManager
    ) throws -> ConnectionPlan {
        let liveDiscoveredCandidates = unifiedDeviceManager.resolvedConnectableDiscoveredCandidates(for: device, limit: 6)
        let hasUnresolvedLiveControlRoute = unifiedDeviceManager.hasUnresolvedLiveSkyBridgeControlRoute(for: device)
        let protocolFingerprint = preferredLiveProtocolFingerprint(from: liveDiscoveredCandidates)
            ?? authoritativeProtocolFingerprint(
                for: device,
                unifiedDeviceManager: unifiedDeviceManager
            )
        let directDeviceRouteAllowed = !hasUnresolvedLiveControlRoute
            && UnifiedOnlineDeviceManager.hasDirectSkyBridgeControlRoute(device)
            && hasRequiredProtocolIdentityForCachedAppleMobileRoute(
                device,
                protocolFingerprint: protocolFingerprint
            )
        let hasFreshControlRoute = !liveDiscoveredCandidates.isEmpty || directDeviceRouteAllowed
        guard hasFreshControlRoute else {
            let deviceLabel = redactedPeerLabel(device.uniqueIdentifier)
            SkyBridgeLogger.discovery.warning(
                "跳过在线设备连接：缺少新鲜可拨 SkyBridge 控制路由 peer=\(deviceLabel, privacy: .public)"
            )
            throw P2PDiscoveryError.noConnectableEndpoint
        }

        let protocolDeviceId = preferredLiveProtocolDeviceId(from: liveDiscoveredCandidates)
            ?? authoritativeProtocolDeviceId(
                for: device,
                unifiedDeviceManager: unifiedDeviceManager
            )
        var discoveredCandidates = liveDiscoveredCandidates.map {
            withPresentationRouteContext(
                withAuthoritativeProtocolIdentity(
                    $0,
                    deviceId: protocolDeviceId,
                    pubKeyFP: protocolFingerprint
                ),
                from: device
            )
        }
        if liveDiscoveredCandidates.isEmpty, directDeviceRouteAllowed {
            if let fallback = fallbackDiscoveredDevice(for: device, unifiedDeviceManager: unifiedDeviceManager),
               !discoveredCandidates.contains(where: { isSameConnectTarget($0, fallback) }) {
                discoveredCandidates.append(fallback)
            }
        }

        guard !discoveredCandidates.isEmpty else {
            throw P2PDiscoveryError.noConnectableEndpoint
        }

        let preferUSBRoute = shouldPreferUSBRoute(for: device, candidates: liveDiscoveredCandidates)
        let routePreference: P2PDiscoveryService.ConnectionRoutePreference = {
            if !SettingsManager.shared.enableP2PDirectConnection {
                return .managedRelayOnly
            }
            return preferUSBRoute ? .preferUSB : .automatic
        }()
        return ConnectionPlan(
            discoveredCandidates: discoveredCandidates,
            routePreference: routePreference
        )
    }

    private static func withAuthoritativeProtocolIdentity(
        _ candidate: DiscoveredDevice,
        deviceId: String?,
        pubKeyFP: String?
    ) -> DiscoveredDevice {
        var enriched = candidate
        let currentStableDeviceId = stableProtocolIdentityKey(from: enriched.deviceId)
        let replacementStableDeviceId = stableProtocolIdentityKey(from: deviceId)
        if let replacementStableDeviceId {
            if currentStableDeviceId == nil {
                enriched.deviceId = deviceId
            } else if let currentStableDeviceId,
                      currentStableDeviceId != replacementStableDeviceId {
                let currentLabel = redactedPeerLabel(currentStableDeviceId)
                let replacementLabel = redactedPeerLabel(replacementStableDeviceId)
                SkyBridgeLogger.discovery.warning(
                    "拒绝覆盖 live discovery protocol identity: current=\(currentLabel, privacy: .public) replacement=\(replacementLabel, privacy: .public)"
                )
            }
        }
        if normalizedProtocolFingerprint(enriched.pubKeyFP) == nil,
           pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            enriched.pubKeyFP = pubKeyFP
        }
        return enriched
    }

    private static func withPresentationRouteContext(
        _ candidate: DiscoveredDevice,
        from device: OnlineDevice
    ) -> DiscoveredDevice {
        guard canBorrowPresentationRouteContext(candidate, from: device) else {
            return candidate
        }

        var enriched = candidate
        let ipv4 = enriched.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            ? routableIPv4(device.ipv4)
            : nil
        let ipv6 = enriched.ipv6?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            ? routableIPv6(device.ipv6)
            : nil
        enriched._updateTransient(ipv4: ipv4, ipv6: ipv6)
        for service in device.services {
            let normalized = service.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "_skybridge._tcp" || normalized == "_skybridge._udp" else { continue }
            if !enriched.services.contains(normalized) {
                enriched.services.append(normalized)
            }
        }
        for (service, port) in device.portMap where port > 0 {
            let normalized = service.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "_skybridge._tcp" || normalized == "_skybridge._udp" else { continue }
            if (enriched.portMap[normalized] ?? 0) <= 0 {
                enriched.portMap[normalized] = port
            }
        }
        enriched.routeIdentifiers = DiscoveredDevice.mergedRouteIdentifiers(
            enriched.routeIdentifiers,
            device.routeIdentifiers
        )
        return enriched
    }

    private static func canBorrowPresentationRouteContext(
        _ candidate: DiscoveredDevice,
        from device: OnlineDevice
    ) -> Bool {
        guard normalizedProtocolFingerprint(candidate.pubKeyFP) != nil
                || normalizedProtocolFingerprint(device.protocolFingerprint) != nil else {
            return false
        }
        if candidateRoutes(candidate).isDisjoint(with: onlineRoutes(device)) {
            return false
        }
        guard UnifiedOnlineDeviceManager.hasResolvedSkyBridgeControlRoute(candidate)
                || UnifiedOnlineDeviceManager.hasDirectSkyBridgeControlRoute(device) else {
            return false
        }
        return true
    }

    private static func candidateRoutes(_ candidate: DiscoveredDevice) -> Set<String> {
        normalizedRouteIdentifiers([candidate.uniqueIdentifier].compactMap { $0 } + candidate.routeIdentifiers)
    }

    private static func onlineRoutes(_ device: OnlineDevice) -> Set<String> {
        normalizedRouteIdentifiers([device.uniqueIdentifier] + device.routeIdentifiers)
    }

    private static func normalizedRouteIdentifiers(_ identifiers: [String]) -> Set<String> {
        Set(identifiers.compactMap { identifier -> String? in
            let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard value.hasPrefix("bonjour:") || value.hasPrefix("recent:bonjour:") else {
                return nil
            }
            return value
        })
    }

    private static func isSameConnectTarget(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> Bool {
        if let leftID = lhs.uniqueIdentifier,
           let rightID = rhs.uniqueIdentifier,
           !leftID.isEmpty,
           leftID == rightID {
            return true
        }

        let leftIPv4 = lhs.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightIPv4 = rhs.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let leftIPv4, let rightIPv4, !leftIPv4.isEmpty, leftIPv4 == rightIPv4 {
            return true
        }

        let leftIPv6 = lhs.ipv6?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightIPv6 = rhs.ipv6?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let leftIPv6, let rightIPv6, !leftIPv6.isEmpty, leftIPv6 == rightIPv6 {
            return true
        }

        return lhs.name == rhs.name && Set(lhs.services) == Set(rhs.services)
    }

    private static func shouldPreferUSBRoute(for device: OnlineDevice, candidates: [DiscoveredDevice]) -> Bool {
        guard device.connectionTypes.contains(.usb) else { return false }
        return candidates.contains { candidate in
            candidate.connectionTypes.contains(.usb)
                && ((candidate.portMap["_skybridge._tcp"] ?? 0) > 0
                    || (candidate.portMap["_skybridge._udp"] ?? 0) > 0
                    || candidate.uniqueIdentifier.map(isUsableBonjourIdentifier) == true
                    || candidate.routeIdentifiers.contains(where: isUsableBonjourIdentifier))
        }
    }

    @MainActor
    private static func fallbackDiscoveredDevice(
        for device: OnlineDevice,
        unifiedDeviceManager: UnifiedOnlineDeviceManager
    ) -> DiscoveredDevice? {
        var normalizedServices = device.services
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.hasPrefix("_") && ($0.hasSuffix("._tcp") || $0.hasSuffix("._udp")) }

        let hasSkyBridgeSource = device.sources.contains(.skybridgeBonjour) || device.sources.contains(.skybridgeP2P)
        let hasBonjourIdentifier = UnifiedOnlineDeviceManager.hasBonjourSkyBridgeControlRoute(
            identifier: device.uniqueIdentifier,
            services: normalizedServices,
            portMap: device.portMap,
            routeIdentifiers: device.routeIdentifiers
        )
        let hasSkyBridgeControlPort = (device.portMap["_skybridge._tcp"] ?? 0) > 0
            || (device.portMap["_skybridge._udp"] ?? 0) > 0
        let hasDirectRoute = UnifiedOnlineDeviceManager.hasDirectSkyBridgeControlRoute(device)

        if normalizedServices.isEmpty, hasSkyBridgeControlPort {
            normalizedServices = (device.portMap["_skybridge._udp"] ?? 0) > 0
                ? ["_skybridge._udp"]
                : ["_skybridge._tcp"]
        } else if normalizedServices.isEmpty, hasSkyBridgeSource, hasBonjourIdentifier {
            normalizedServices = ["_skybridge._tcp"]
        }

        let fallback = DiscoveredDevice(
            id: device.id,
            name: device.name,
            ipv4: device.ipv4,
            ipv6: device.ipv6,
            services: normalizedServices,
            portMap: device.portMap,
            connectionTypes: device.connectionTypes,
            uniqueIdentifier: preferredRouteIdentifier(for: device) ?? device.uniqueIdentifier,
            routeIdentifiers: device.routeIdentifiers,
            signalStrength: device.signalStrength,
            source: {
                if device.sources.contains(.skybridgeP2P) { return .skybridgeP2P }
                if device.sources.contains(.skybridgeBonjour) { return .skybridgeBonjour }
                return .unknown
            }(),
            isLocalDevice: device.isLocalDevice,
            deviceId: authoritativeProtocolDeviceId(for: device, unifiedDeviceManager: unifiedDeviceManager),
            pubKeyFP: authoritativeProtocolFingerprint(for: device, unifiedDeviceManager: unifiedDeviceManager)
        )

        if isAppleMobilePresentation(device),
           normalizedProtocolFingerprint(fallback.pubKeyFP) == nil {
            let deviceLabel = redactedPeerLabel(device.uniqueIdentifier)
            SkyBridgeLogger.discovery.warning(
                "跳过在线设备 Apple mobile fallback：缺少协议指纹 peer=\(deviceLabel, privacy: .public)"
            )
            return nil
        }

        guard hasDirectRoute || UnifiedOnlineDeviceManager.hasResolvedSkyBridgeControlRoute(fallback) else {
            let deviceLabel = redactedPeerLabel(device.uniqueIdentifier)
            SkyBridgeLogger.discovery.warning(
                "跳过在线设备 fallback 候选：缺少可拨 SkyBridge 控制路由 peer=\(deviceLabel, privacy: .public)"
            )
            return nil
        }

        return fallback
    }

    private static func preferredLiveProtocolDeviceId(from candidates: [DiscoveredDevice]) -> String? {
        let candidatesWithFingerprint = candidates.filter {
            stableProtocolIdentityKey(from: $0.deviceId) != nil
                && normalizedProtocolFingerprint($0.pubKeyFP) != nil
        }
        return (candidatesWithFingerprint + candidates).lazy.compactMap { candidate in
            stableIdPayload(from: candidate.deviceId)
        }.first
    }

    private static func preferredLiveProtocolFingerprint(from candidates: [DiscoveredDevice]) -> String? {
        candidates.lazy.compactMap { candidate in
            normalizedProtocolFingerprint(candidate.pubKeyFP)
        }.first
    }

    private static func hasRequiredProtocolIdentityForCachedAppleMobileRoute(
        _ device: OnlineDevice,
        protocolFingerprint: String?
    ) -> Bool {
        guard isAppleMobilePresentation(device) else {
            return true
        }
        if normalizedProtocolFingerprint(protocolFingerprint) != nil {
            return true
        }
        return normalizedProtocolFingerprint(device.protocolFingerprint) != nil
    }

    private static func isAppleMobilePresentation(_ device: OnlineDevice) -> Bool {
        let haystack = [
            device.name,
            device.modelName ?? "",
            device.platformName ?? ""
        ]
        .joined(separator: " ")
        .lowercased()
        return haystack.contains("iphone")
            || haystack.contains("ipad")
            || haystack.contains("ios")
            || haystack.contains("ipados")
    }

    @MainActor
    private static func authoritativeProtocolDeviceId(
        for device: OnlineDevice,
        unifiedDeviceManager: UnifiedOnlineDeviceManager
    ) -> String? {
        let records = TrustSyncService.shared.activeTrustRecords.filter { !$0.isTombstone && !$0.isExpired }
        guard let record = unifiedDeviceManager.resolvedTrustRecord(for: device, among: records) else {
            return stableProtocolIdentityKey(from: device.uniqueIdentifier)
                ?? device.routeIdentifiers.lazy.compactMap(stableProtocolIdentityKey).first
        }
        return stableIdPayload(from: record.currentDeviceId)
            ?? stableIdPayload(from: record.deviceId)
            ?? nonEmptyIdentity(record.currentDeviceId)
            ?? nonEmptyIdentity(record.deviceId)
    }

    @MainActor
    private static func authoritativeProtocolFingerprint(
        for device: OnlineDevice,
        unifiedDeviceManager: UnifiedOnlineDeviceManager
    ) -> String? {
        let records = TrustSyncService.shared.activeTrustRecords.filter { !$0.isTombstone && !$0.isExpired }
        if let record = unifiedDeviceManager.resolvedTrustRecord(for: device, among: records) {
            let fingerprint = record.pubKeyFP.trimmingCharacters(in: .whitespacesAndNewlines)
            return fingerprint.isEmpty ? nil : fingerprint
        }
        if let fingerprint = normalizedProtocolFingerprint(device.protocolFingerprint) {
            return fingerprint
        }
        let identifier = device.uniqueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.hasPrefix("fp:") else { return nil }
        let payload = String(identifier.dropFirst("fp:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
    }

    private static func routableIPv4(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.hasPrefix("169.254."),
              !value.hasPrefix("127."),
              !value.hasPrefix("0."),
              value != "255.255.255.255" else {
            return nil
        }
        let segments = value.split(separator: ".")
        guard segments.count == 4,
              segments.allSatisfy({
                  guard let octet = Int($0), (0...255).contains(octet) else { return false }
                  return String(octet) == String($0) || $0 == "0"
              }) else {
            return nil
        }
        return value
    }

    private static func routableIPv6(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        let address = value.split(separator: "%", maxSplits: 1).first.map(String.init) ?? value
        let normalized = address.lowercased()
        guard normalized.contains(":"),
              normalized != "::",
              normalized != "::1",
              !normalized.hasPrefix("ff") else {
            return nil
        }
        if normalized.hasPrefix("fe80:") {
            return value.contains("%") ? value : nil
        }
        return value
    }

    private static func stableIdPayload(from raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.lowercased().hasPrefix("id:") {
            value = String(value.dropFirst("id:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }

    private static func nonEmptyIdentity(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func normalizedProtocolFingerprint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64,
              value.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return value
    }

    private static func stableProtocolIdentityKey(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.lowercased()
        if normalized.hasPrefix("id:") {
            let payload = String(normalized.dropFirst("id:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return isPlausibleStableProtocolIdentityPayload(payload) ? "id:\(payload)" : nil
        }
        guard UUID(uuidString: normalized.uppercased()) != nil else { return nil }
        return "id:\(normalized)"
    }

    private static func isPlausibleStableProtocolIdentityPayload(_ raw: String) -> Bool {
        guard raw.count >= 8,
              !raw.contains(where: \.isWhitespace),
              !isLikelyIPAddress(raw),
              !raw.contains("/") else {
            return false
        }
        return raw.allSatisfy { character in
            character.isASCII
                && (character.isLetter
                    || character.isNumber
                    || character == "-"
                    || character == "_"
                    || character == ".")
        }
    }

    private static func preferredRouteIdentifier(for device: OnlineDevice) -> String? {
        for routeIdentifier in device.routeIdentifiers {
            let trimmed = routeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if isUsableBonjourIdentifier(trimmed) {
                return trimmed
            }
        }
        let identifier = device.uniqueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if isUsableBonjourIdentifier(identifier) {
            return identifier
        }
        return nil
    }

    private static func isUsableBonjourIdentifier(_ identifier: String) -> Bool {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        guard normalized.hasPrefix("bonjour:") || normalized.hasPrefix("recent:bonjour:") else {
            return false
        }
        let prefixLength = normalized.hasPrefix("recent:bonjour:")
            ? "recent:bonjour:".count
            : "bonjour:".count
        let payload = String(trimmed.dropFirst(prefixLength))
        guard let serviceName = payload.split(separator: "@", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !serviceName.isEmpty else {
            return false
        }
        let lowercasedName = serviceName.lowercased()
        guard !lowercasedName.hasPrefix("id:"),
              !lowercasedName.hasPrefix("fp:"),
              !lowercasedName.hasPrefix("host:"),
              !lowercasedName.hasPrefix("peer:"),
              UUID(uuidString: serviceName.uppercased()) == nil,
              !isLikelyIPAddress(lowercasedName) else {
            return false
        }
        return true
    }

    private static func isLikelyIPAddress(_ value: String) -> Bool {
        if value.contains(":") { return true }
        let segments = value.split(separator: ".")
        return segments.count == 4 && segments.allSatisfy { segment in
            guard let intValue = Int(segment), (0...255).contains(intValue) else {
                return false
            }
            return String(intValue) == String(segment) || segment == "0"
        }
    }

    private static func redactedPeerLabel(_ raw: String?) -> String {
        guard raw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return "<redacted>"
        }
        return "<redacted>"
    }

    private static func errorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        return "error_domain=\(nsError.domain) code=\(nsError.code)"
    }
}
