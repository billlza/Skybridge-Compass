import Foundation
import SkyBridgeCore

@available(macOS 14.0, *)
@MainActor
enum OnlineDeviceConnectionCoordinator {
    static func connect(
        to device: OnlineDevice,
        unifiedDeviceManager: UnifiedOnlineDeviceManager = .shared,
        p2pDiscoveryService: P2PDiscoveryService = .shared
    ) async throws {
        var discoveredCandidates = unifiedDeviceManager.resolvedDiscoveredCandidates(for: device, limit: 6)
        if let fallback = fallbackDiscoveredDevice(for: device),
           !discoveredCandidates.contains(where: { isSameConnectTarget($0, fallback) }) {
            discoveredCandidates.append(fallback)
        }

        guard !discoveredCandidates.isEmpty else {
            throw P2PDiscoveryError.noConnectableEndpoint
        }

        let preferUSBRoute = shouldPreferUSBRoute(for: device, candidates: discoveredCandidates)
        let routePreference: P2PDiscoveryService.ConnectionRoutePreference = {
            if !SettingsManager.shared.enableP2PDirectConnection {
                return .managedRelayOnly
            }
            return preferUSBRoute ? .preferUSB : .automatic
        }()

        var lastError: Error?
        for candidate in discoveredCandidates {
            do {
                try await p2pDiscoveryService.connectToDevice(candidate, routePreference: routePreference)
                unifiedDeviceManager.markDeviceAsConnected(device.id)
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
                    || candidate.uniqueIdentifier?.hasPrefix("bonjour:") == true
                    || candidate.uniqueIdentifier?.hasPrefix("recent:bonjour:") == true)
        }
    }

    private static func fallbackDiscoveredDevice(for device: OnlineDevice) -> DiscoveredDevice? {
        var normalizedServices = device.services
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.hasPrefix("_") && ($0.hasSuffix("._tcp") || $0.hasSuffix("._udp")) }

        let hasSkyBridgeSource = device.sources.contains(.skybridgeBonjour) || device.sources.contains(.skybridgeP2P)
        let hasBonjourIdentifier = device.uniqueIdentifier.hasPrefix("bonjour:")
            || device.uniqueIdentifier.hasPrefix("recent:bonjour:")
        let hasSkyBridgeControlPort = (device.portMap["_skybridge._tcp"] ?? 0) > 0
            || (device.portMap["_skybridge._udp"] ?? 0) > 0
        let hasSkyBridgeControlService = normalizedServices.contains("_skybridge._tcp")
            || normalizedServices.contains("_skybridge._udp")

        if normalizedServices.isEmpty, hasSkyBridgeSource, hasBonjourIdentifier {
            normalizedServices = ["_skybridge._tcp"]
        }

        guard hasSkyBridgeControlService
            || hasSkyBridgeControlPort
            || (hasSkyBridgeSource && hasBonjourIdentifier)
        else {
            SkyBridgeLogger.discovery.warning(
                "跳过在线设备 fallback 候选：缺少真实 SkyBridge 控制端点 device=\(device.name, privacy: .public) id=\(device.uniqueIdentifier, privacy: .public)"
            )
            return nil
        }

        let mappedDeviceId: String? = {
            guard device.uniqueIdentifier.hasPrefix("id:") else { return nil }
            return String(device.uniqueIdentifier.dropFirst("id:".count))
        }()
        let inferredDeviceId: String? = {
            let trimmed = device.uniqueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard !trimmed.contains(":") else { return nil }
            guard trimmed.count >= 8 else { return nil }
            return trimmed
        }()
        let mappedPubKeyFP: String? = {
            guard device.uniqueIdentifier.hasPrefix("fp:") else { return nil }
            return String(device.uniqueIdentifier.dropFirst("fp:".count))
        }()
        let source: DeviceSource = {
            if device.sources.contains(.skybridgeP2P) { return .skybridgeP2P }
            if device.sources.contains(.skybridgeBonjour) { return .skybridgeBonjour }
            return .unknown
        }()

        return DiscoveredDevice(
            id: device.id,
            name: device.name,
            ipv4: device.ipv4,
            ipv6: device.ipv6,
            services: normalizedServices,
            portMap: device.portMap,
            connectionTypes: device.connectionTypes,
            uniqueIdentifier: device.uniqueIdentifier,
            signalStrength: device.signalStrength,
            source: source,
            isLocalDevice: device.isLocalDevice,
            deviceId: mappedDeviceId ?? inferredDeviceId,
            pubKeyFP: mappedPubKeyFP
        )
    }
}
