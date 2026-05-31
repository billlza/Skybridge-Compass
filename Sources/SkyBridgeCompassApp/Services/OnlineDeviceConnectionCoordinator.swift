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
                SkyBridgeLogger.discovery.warning(
                    "在线设备候选连接失败，将尝试下一个候选: \(candidate.name, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
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
        var discoveredCandidates = liveDiscoveredCandidates
        if let fallback = fallbackDiscoveredDevice(for: device, unifiedDeviceManager: unifiedDeviceManager),
           !discoveredCandidates.contains(where: { isSameConnectTarget($0, fallback) }) {
            discoveredCandidates.append(fallback)
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

        guard hasDirectRoute || UnifiedOnlineDeviceManager.hasResolvedSkyBridgeControlRoute(fallback) else {
            SkyBridgeLogger.discovery.warning(
                "跳过在线设备 fallback 候选：缺少可拨 SkyBridge 控制路由 device=\(device.name, privacy: .public) id=\(device.uniqueIdentifier, privacy: .public)"
            )
            return nil
        }

        return fallback
    }

    @MainActor
    private static func authoritativeProtocolDeviceId(
        for device: OnlineDevice,
        unifiedDeviceManager: UnifiedOnlineDeviceManager
    ) -> String? {
        let records = TrustSyncService.shared.activeTrustRecords.filter { !$0.isTombstone && !$0.isExpired }
        guard let record = unifiedDeviceManager.resolvedTrustRecord(for: device, among: records) else {
            return nil
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
        let identifier = device.uniqueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.hasPrefix("fp:") else { return nil }
        let payload = String(identifier.dropFirst("fp:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
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
}
