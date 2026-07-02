import SwiftUI
import SkyBridgeCore
import SkyBridgeSmokeSupport
import os

/// 增强版设备发现视图 - 整合三种连接方式
///
/// 功能：
/// 1. 近距设备扫描（Bonjour/Network.framework）
/// 2. 动态二维码连接
/// 3. iCloud 设备链（真实Apple ID设备同步）
/// 4. 智能连接码
@available(macOS 14.0, *)
struct EnhancedDeviceDiscoveryView_Previews: PreviewProvider {
    static var previews: some View {
        EnhancedDeviceDiscoveryView(deviceChainViewModel: CloudDeviceListViewModel(service: PreviewCloudDeviceService()))
    }
}

private struct TrustedGroupSelection: Identifiable, Equatable {
    let id: String
}

private struct TrustedRecordCardPresentation: Identifiable, Sendable {
    let group: TrustRecordDisplayGroup
    let subtitle: String
    let status: OnlineDeviceStatus

    var id: String { group.id }
}

private struct DeviceDiscoveryPresentationSnapshot: Sendable {
    var connectedOnlineDevicesNonLocal: [OnlineDevice]
    var activeOnlineDevicesNonLocal: [OnlineDevice]
    var filteredOnlineDevicesNonLocal: [OnlineDevice]
    var groupedRecentlyConnectedDevices: [OnlineDevice]
    var displayedTrustedRecords: [TrustedRecordCardPresentation]
    var accessibilityIdentityByDeviceId: [UUID: String]
    var hasResolvedConnectableControlRouteByDeviceId: [UUID: Bool]

    static let empty = DeviceDiscoveryPresentationSnapshot(
        connectedOnlineDevicesNonLocal: [],
        activeOnlineDevicesNonLocal: [],
        filteredOnlineDevicesNonLocal: [],
        groupedRecentlyConnectedDevices: [],
        displayedTrustedRecords: [],
        accessibilityIdentityByDeviceId: [:],
        hasResolvedConnectableControlRouteByDeviceId: [:]
    )
}

private struct DeviceDiscoveryResolvedProtocolIdentity: Sendable {
    let deviceId: String?
    let pubKeyFP: String?
}

private enum DeviceDiscoveryPresentationProjector {
    struct Input: Sendable {
        let onlineDevices: [OnlineDevice]
        let trustedGroups: [TrustRecordDisplayGroup]
        let searchText: String
        let showConnectableDevicesOnly: Bool
        let trustedMetadata: [String: ApplePeerDeviceMetadataNormalizer.Presentation]
        let trustedLiveMetadata: [String: ApplePeerDeviceMetadataNormalizer.Presentation]
        let hasResolvedConnectableControlRouteByDeviceId: [UUID: Bool]
        let effectiveStatusByDeviceId: [UUID: OnlineDeviceStatus]
        let resolvedTrustRecordByDeviceId: [UUID: TrustRecord]
        let liveProtocolIdentityByDeviceId: [UUID: DeviceDiscoveryResolvedProtocolIdentity]
        let crossNetworkActiveTrustedGroupIds: Set<String>
        let presenceOnlinePeerDeviceIds: Set<String>
    }

    static func buildPresentationSnapshot(input: Input) -> DeviceDiscoveryPresentationSnapshot {
        let nonLocalDevices = input.onlineDevices.filter { !$0.isLocalDevice }
        let connectedCandidates = nonLocalDevices
            .filter { effectiveConnectionStatus(for: $0, input: input) == .connected }
        let connected = presentationDedupeOnlineDevices(
            connectedCandidates,
            trustedGroups: input.trustedGroups,
            input: input
        )
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
        let activeCandidates = nonLocalDevices
            .filter { effectiveConnectionStatus(for: $0, input: input) == .online }
            .filter { candidate in
                !hasHigherPriorityPresentation(
                    for: candidate,
                    representedDevices: connected,
                    trustedGroups: input.trustedGroups,
                    input: input
                )
            }
        let active = presentationDedupeOnlineDevices(
            activeCandidates,
            trustedGroups: input.trustedGroups,
            input: input
        )
        let recent = groupedRecentlyConnectedDevices(
            from: input.onlineDevices,
            connectedDevices: connected,
            activeDevices: active,
            trustedGroups: input.trustedGroups,
            input: input
        )

        let filteredBase = active.filter { device in
            if input.showConnectableDevicesOnly && !device.isConnectable {
                return false
            }
            return true
        }
        let filtered: [OnlineDevice]
        if input.searchText.isEmpty {
            filtered = filteredBase
        } else {
            filtered = filteredBase.filter {
                $0.name.localizedCaseInsensitiveContains(input.searchText) ||
                $0.ipv4?.contains(input.searchText) == true ||
                $0.ipv6?.contains(input.searchText) == true
            }
        }

        let representedDevices = connected + active + recent
        let displayedTrusted = input.trustedGroups
            .filter { !hasVisibleOnlineRepresentation(for: $0, representedDevices: representedDevices, input: input) }
            .map { group in
                TrustedRecordCardPresentation(
                    group: group,
                    subtitle: trustedRecordSubtitle(group, input: input),
                    status: trustedRecordStatus(
                        group,
                        liveCandidates: nonLocalDevices,
                        recentCandidates: recent,
                        input: input
                    )
                )
            }

        var identityByDeviceId: [UUID: String] = [:]
        for device in input.onlineDevices {
            identityByDeviceId[device.id] = computeResolvedPresentationIdentityKey(
                for: device,
                trustedGroups: input.trustedGroups,
                input: input
            )
        }

        return DeviceDiscoveryPresentationSnapshot(
            connectedOnlineDevicesNonLocal: connected,
            activeOnlineDevicesNonLocal: active,
            filteredOnlineDevicesNonLocal: filtered,
            groupedRecentlyConnectedDevices: recent,
            displayedTrustedRecords: displayedTrusted,
            accessibilityIdentityByDeviceId: identityByDeviceId,
            hasResolvedConnectableControlRouteByDeviceId: input.hasResolvedConnectableControlRouteByDeviceId
        )
    }

    private static func groupedRecentlyConnectedDevices(
        from onlineDevices: [OnlineDevice],
        connectedDevices: [OnlineDevice],
        activeDevices: [OnlineDevice],
        trustedGroups: [TrustRecordDisplayGroup],
        input: Input
    ) -> [OnlineDevice] {
        let liveRepresentations = connectedDevices + activeDevices
        let candidates = onlineDevices
            .filter { !$0.isLocalDevice && $0.lastConnectedAt != nil && $0.connectionStatus == .offline }
            .filter { device in
                !hasHigherPriorityPresentation(
                    for: device,
                    representedDevices: liveRepresentations,
                    trustedGroups: trustedGroups,
                    input: input
                )
            }
        guard !candidates.isEmpty else { return [] }

        var grouped: [String: OnlineDevice] = [:]
        for device in candidates {
            let groupingKey: String
            if let trustRecord = resolvedTrustRecord(for: device, trustedGroups: trustedGroups, input: input) {
                groupingKey = "trusted:\(trustRecord.deviceId)"
            } else {
                groupingKey = "device:\(device.id.uuidString)"
            }

            if let existing = grouped[groupingKey] {
                grouped[groupingKey] = preferredRecentDisplayDevice(existing, device)
            } else {
                grouped[groupingKey] = device
            }
        }

        let presentationDevices = presentationDedupeOnlineDevices(
            Array(grouped.values),
            trustedGroups: trustedGroups,
            input: input
        )
        return presentationDevices.sorted { lhs, rhs in
            if statusPriority(lhs.connectionStatus) != statusPriority(rhs.connectionStatus) {
                return statusPriority(lhs.connectionStatus) > statusPriority(rhs.connectionStatus)
            }
            let lhsConnected = lhs.lastConnectedAt ?? .distantPast
            let rhsConnected = rhs.lastConnectedAt ?? .distantPast
            if lhsConnected != rhsConnected {
                return lhsConnected > rhsConnected
            }
            if lhs.lastSeen != rhs.lastSeen {
                return lhs.lastSeen > rhs.lastSeen
            }
            return lhs.name < rhs.name
        }
    }

    private static func presentationDedupeOnlineDevices(
        _ devices: [OnlineDevice],
        trustedGroups: [TrustRecordDisplayGroup],
        input: Input
    ) -> [OnlineDevice] {
        var passthrough: [OnlineDevice] = []
        var appleMobileGroups: [[OnlineDevice]] = []

        for device in devices {
            guard appleMobilePresentationFamily(for: device) != nil,
                  !appleMobileStrongPresentationTokens(for: device, trustedGroups: trustedGroups, input: input).isEmpty else {
                passthrough.append(device)
                continue
            }

            let matchingIndices = appleMobileGroups.indices.filter { index in
                let group = appleMobileGroups[index]
                return group.contains { existing in
                    shouldCoalesceAppleMobilePresentation(existing, device, trustedGroups: trustedGroups, input: input)
                }
            }
            if let firstIndex = matchingIndices.first {
                var mergedGroup = appleMobileGroups[firstIndex]
                mergedGroup.append(device)
                for index in matchingIndices.dropFirst().reversed() {
                    mergedGroup.append(contentsOf: appleMobileGroups.remove(at: index))
                }
                appleMobileGroups[firstIndex] = mergedGroup
            } else {
                appleMobileGroups.append([device])
            }
        }

        let coalescedAppleMobile = appleMobileGroups.flatMap { group -> [OnlineDevice] in
            guard group.count > 1,
                  let winner = group.max(by: {
                      preferredOnlinePresentationOrder($1, $0, input: input)
                  }) else {
                return group
            }
            return [winner]
        }

        return (passthrough + coalescedAppleMobile).sorted {
            preferredOnlinePresentationOrder($0, $1, input: input)
        }
    }

    private static func hasHigherPriorityPresentation(
        for candidate: OnlineDevice,
        representedDevices: [OnlineDevice],
        trustedGroups: [TrustRecordDisplayGroup],
        input: Input
    ) -> Bool {
        let candidateIdentity = computeResolvedPresentationIdentityKey(
            for: candidate,
            trustedGroups: trustedGroups,
            input: input
        )
        return representedDevices.contains { represented in
            represented.id == candidate.id
                || represented.uniqueIdentifier == candidate.uniqueIdentifier
                || computeResolvedPresentationIdentityKey(for: represented, trustedGroups: trustedGroups, input: input) == candidateIdentity
                || shouldCoalesceAppleMobilePresentation(candidate, represented, trustedGroups: trustedGroups, input: input)
        }
    }

    private static func shouldCoalesceAppleMobilePresentation(
        _ lhs: OnlineDevice,
        _ rhs: OnlineDevice,
        trustedGroups: [TrustRecordDisplayGroup],
        input: Input
    ) -> Bool {
        guard let lhsFamily = appleMobilePresentationFamily(for: lhs),
              let rhsFamily = appleMobilePresentationFamily(for: rhs),
              lhsFamily == rhsFamily else {
            return false
        }

        guard appleMobilePresentationMetadataCompatible(lhs.modelName, rhs.modelName, family: lhsFamily),
              appleMobilePresentationPlatformCompatible(lhs.platformName, rhs.platformName) else {
            return false
        }

        let lhsRoutes = appleMobilePresentationRouteTokens(for: lhs)
        let rhsRoutes = appleMobilePresentationRouteTokens(for: rhs)
        if !lhsRoutes.isEmpty, !lhsRoutes.isDisjoint(with: rhsRoutes) {
            return true
        }

        let lhsTokens = appleMobileStrongPresentationTokens(for: lhs, trustedGroups: trustedGroups, input: input)
        let rhsTokens = appleMobileStrongPresentationTokens(for: rhs, trustedGroups: trustedGroups, input: input)
        return !lhsTokens.isEmpty && !rhsTokens.isEmpty && !lhsTokens.isDisjoint(with: rhsTokens)
    }

    private static func appleMobilePresentationFamily(for device: OnlineDevice) -> String? {
        let haystack = [
            device.name,
            device.modelName ?? "",
            device.platformName ?? ""
        ].joined(separator: " ").lowercased()
        if haystack.contains("ipad") || haystack.contains("ipados") {
            return "ipad"
        }
        if haystack.contains("iphone") || haystack.contains("ios") {
            return "iphone"
        }
        return nil
    }

    private static func appleMobilePresentationMetadataCompatible(
        _ lhs: String?,
        _ rhs: String?,
        family: String
    ) -> Bool {
        let lhs = normalizedSmokeToken(lhs ?? "")
        let rhs = normalizedSmokeToken(rhs ?? "")
        guard !lhs.isEmpty, !rhs.isEmpty else { return true }
        if lhs == rhs { return true }
        return lhs == family && rhs.hasPrefix(family)
            || rhs == family && lhs.hasPrefix(family)
    }

    private static func appleMobilePresentationPlatformCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        let lhs = normalizedSmokeToken(lhs ?? "")
        let rhs = normalizedSmokeToken(rhs ?? "")
        guard !lhs.isEmpty, !rhs.isEmpty else { return true }
        if lhs == rhs { return true }
        let mobilePlatforms: Set<String> = ["ios", "ipados"]
        return mobilePlatforms.contains(lhs) && mobilePlatforms.contains(rhs)
    }

    private static func appleMobilePresentationRouteTokens(for device: OnlineDevice) -> Set<String> {
        var tokens = Set<String>()
        let rawValues: [String?] = [Optional.some(device.uniqueIdentifier)] + device.routeIdentifiers.map(Optional.some)
        for raw in rawValues {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                continue
            }
            let normalized = raw.lowercased()
            guard normalized.hasPrefix("bonjour:") || normalized.hasPrefix("recent:bonjour:") else {
                continue
            }
            if let routeToken = appleMobileCanonicalBonjourRouteToken(from: raw) {
                tokens.insert(routeToken)
            }
        }
        return tokens
    }

    private static func appleMobileCanonicalBonjourRouteToken(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let lowercased = raw.lowercased()
        let payload: String
        if lowercased.hasPrefix("recent:bonjour:") {
            payload = String(raw.dropFirst("recent:bonjour:".count))
        } else if lowercased.hasPrefix("bonjour:") {
            payload = String(raw.dropFirst("bonjour:".count))
        } else {
            return nil
        }

        let parts = payload.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawServiceName = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawServiceName.isEmpty else {
            return nil
        }

        let rawDomain = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            : "local."
        let domain: String
        if rawDomain.isEmpty {
            domain = "local."
        } else if rawDomain.hasSuffix(".") {
            domain = rawDomain.lowercased()
        } else {
            domain = "\(rawDomain.lowercased())."
        }

        return "bonjour:\(rawServiceName.lowercased())@\(domain)"
    }

    private static func appleMobileStrongPresentationTokens(
        for device: OnlineDevice,
        trustedGroups: [TrustRecordDisplayGroup],
        input: Input
    ) -> Set<String> {
        var tokens = appleMobilePresentationRouteTokens(for: device)

        if let identityToken = appleMobilePresentationIdentityToken(from: device.uniqueIdentifier) {
            tokens.insert(identityToken)
        }
        for routeIdentifier in device.routeIdentifiers {
            if let identityToken = appleMobilePresentationIdentityToken(from: routeIdentifier) {
                tokens.insert(identityToken)
            }
        }

        if let trustRecord = resolvedTrustRecord(for: device, trustedGroups: trustedGroups, input: input) {
            let stableDeviceId = trustRecord.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !stableDeviceId.isEmpty {
                tokens.insert("trust:\(stableDeviceId)")
            }
        }

        return tokens
    }

    private static func appleMobilePresentationIdentityToken(from raw: String?) -> String? {
        guard var normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return nil
        }
        if normalized.hasPrefix("recent:") {
            normalized = String(normalized.dropFirst("recent:".count))
        }

        if normalized.hasPrefix("id:") {
            let payload = String(normalized.dropFirst("id:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { return nil }
            if let uuid = UUID(uuidString: payload) {
                return "id:\(uuid.uuidString.lowercased())"
            }
            return payload.count >= 8 ? "id:\(payload)" : nil
        }

        if normalized.hasPrefix("fp:") {
            let payload = String(normalized.dropFirst("fp:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return payload.count >= 16 ? "fp:\(payload)" : nil
        }

        if let uuid = UUID(uuidString: normalized) {
            return "id:\(uuid.uuidString.lowercased())"
        }

        return nil
    }

    private static func trustedRecordSubtitle(_ group: TrustRecordDisplayGroup, input: Input) -> String {
        let normalized = trustedRecordPresentation(group, input: input)

        var parts: [String] = []
        if let modelName = normalized.modelName { parts.append(modelName) }
        if let chip = normalized.chip { parts.append(chip) }
        if let platform = normalized.platform, let osVersion = normalized.osVersion {
            parts.append("\(platform) \(osVersion)")
        } else if let platform = normalized.platform {
            parts.append(platform)
        }
        return parts.isEmpty ? group.displayRecord.deviceId : parts.joined(separator: " · ")
    }

    private static func trustedRecordPresentation(
        _ group: TrustRecordDisplayGroup,
        input: Input
    ) -> ApplePeerDeviceMetadataNormalizer.Presentation {
        let record = group.displayRecord
        let c = trustedRecordCaps(record)
        let fallback = ApplePeerDeviceMetadataNormalizer.normalize(
            modelName: c["modelName"],
            chip: c["chip"],
            platform: c["platform"],
            osVersion: c["osVersion"]
        )
        let live = input.trustedMetadata[group.id] ?? input.trustedLiveMetadata[group.id]
        var merged = ApplePeerDeviceMetadataNormalizer.mergedPresentation(
            preferred: live,
            fallback: fallback
        )
        if live == nil {
            merged = ApplePeerDeviceMetadataNormalizer.normalize(
                modelName: merged.modelName,
                chip: merged.chip,
                platform: merged.platform,
                osVersion: nil
            )
        }
        return merged
    }

    private static func trustedRecordStatus(
        _ group: TrustRecordDisplayGroup,
        liveCandidates: [OnlineDevice],
        recentCandidates: [OnlineDevice],
        input: Input
    ) -> OnlineDeviceStatus {
        let resolvedStatus = trustedPresentationOnlineDevices(
            for: group,
            liveCandidates: liveCandidates,
            recentCandidates: recentCandidates,
            input: input
        )
            .map(\.connectionStatus)
            .max(by: { statusPriority($0) < statusPriority($1) })
            ?? .offline
        if input.crossNetworkActiveTrustedGroupIds.contains(group.id) { return .connected }
        if resolvedStatus == .offline, trustedGroupIsPresenceOnline(group, input: input) { return .online }
        return resolvedStatus
    }

    private static func trustedGroupIsPresenceOnline(_ group: TrustRecordDisplayGroup, input: Input) -> Bool {
        guard !input.presenceOnlinePeerDeviceIds.isEmpty else { return false }
        for record in trustedLookupRecords(for: group) {
            if input.presenceOnlinePeerDeviceIds.contains(record.deviceId) ||
                input.presenceOnlinePeerDeviceIds.contains(record.currentDeviceId) {
                return true
            }
        }
        return false
    }

    private static func trustedPresentationOnlineDevices(
        for group: TrustRecordDisplayGroup,
        liveCandidates: [OnlineDevice],
        recentCandidates: [OnlineDevice],
        input: Input
    ) -> [OnlineDevice] {
        let records = trustedLookupRecords(for: group)
        let context = trustedDeviceMatchContext(for: group)

        var mergedByIdentity: [String: (score: Int, device: OnlineDevice)] = [:]
        for device in liveCandidates + recentCandidates {
            let resolvedTrustRecord = resolvedTrustRecord(for: device, among: records, input: input)
            let fallbackScore = trustedDeviceMatchScore(device, context: context)
            let matchScore: Int
            let mergeKey: String

            if let resolvedTrustRecord {
                matchScore = 20_000 + fallbackScore
                mergeKey = "trusted:\(resolvedTrustRecord.deviceId)"
            } else {
                guard fallbackScore > 0 else { continue }
                matchScore = fallbackScore
                mergeKey = "device:\(device.id.uuidString)"
            }

            if let existing = mergedByIdentity[mergeKey] {
                if existing.score == matchScore {
                    mergedByIdentity[mergeKey] = (
                        score: matchScore,
                        device: preferredRecentDisplayDevice(existing.device, device)
                    )
                } else if existing.score < matchScore {
                    mergedByIdentity[mergeKey] = (score: matchScore, device: device)
                }
            } else {
                mergedByIdentity[mergeKey] = (score: matchScore, device: device)
            }
        }

        return mergedByIdentity.values.sorted { lhs, rhs in
            let lhsScore = lhs.score
            let rhsScore = rhs.score
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return trustedPresentationPriority(lhs.device) > trustedPresentationPriority(rhs.device)
        }
        .map(\.device)
    }

    private static func hasVisibleOnlineRepresentation(
        for group: TrustRecordDisplayGroup,
        representedDevices: [OnlineDevice],
        input: Input
    ) -> Bool {
        let records = trustedLookupRecords(for: group)
        return representedDevices.contains { device in
            resolvedTrustRecord(for: device, among: records, input: input) != nil
        }
    }

    private static func trustedLookupRecords(for group: TrustRecordDisplayGroup) -> [TrustRecord] {
        let records = [group.displayRecord] + group.relatedRecords
        var ordered: [TrustRecord] = []
        var seen = Set<String>()

        for record in records {
            let key = "\(record.deviceId)|\(record.updatedAt)"
            if seen.insert(key).inserted {
                ordered.append(record)
            }
        }
        return ordered
    }

    private static func resolvedTrustRecord(
        for device: OnlineDevice,
        trustedGroups: [TrustRecordDisplayGroup],
        input: Input
    ) -> TrustRecord? {
        let records = trustedGroups.flatMap { trustedLookupRecords(for: $0) }
        return resolvedTrustRecord(for: device, among: records, input: input)
    }

    private static func resolvedTrustRecord(
        for device: OnlineDevice,
        among records: [TrustRecord],
        input: Input
    ) -> TrustRecord? {
        guard let resolved = input.resolvedTrustRecordByDeviceId[device.id] else {
            return nil
        }
        let acceptedIds = Set(records.map(\.deviceId))
        return acceptedIds.contains(resolved.deviceId) ? resolved : nil
    }

    private static func trustedRecordCaps(_ record: TrustRecord) -> [String: String] {
        var dict: [String: String] = [:]
        for item in record.capabilities {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                dict[parts[0]] = parts[1]
            }
        }
        return dict
    }

    private static func trustedDeviceMatchContext(
        for group: TrustRecordDisplayGroup
    ) -> (identityTokens: Set<String>, nameTokens: Set<String>) {
        let records = trustedLookupRecords(for: group)
        var identityTokens = Set<String>()
        var nameTokens = Set<String>()

        for record in records {
            for raw in [record.deviceId, record.currentDeviceId, record.deviceName] + record.knownDeviceIds {
                trustedDeviceTokens(from: raw).forEach { token in
                    if token.hasPrefix("name:") {
                        nameTokens.insert(token)
                    } else {
                        identityTokens.insert(token)
                    }
                }
            }

            let caps = trustedRecordCaps(record)
            for raw in [caps["declaredDeviceId"], caps["peerEndpoint"]] {
                trustedDeviceTokens(from: raw).forEach { token in
                    if token.hasPrefix("name:") {
                        nameTokens.insert(token)
                    } else {
                        identityTokens.insert(token)
                    }
                }
            }
        }

        return (identityTokens, nameTokens)
    }

    private static func trustedDeviceMatchScore(
        _ device: OnlineDevice,
        context: (identityTokens: Set<String>, nameTokens: Set<String>)
    ) -> Int {
        let deviceTokens = trustedDeviceTokens(for: device)
        let identityMatches = deviceTokens.intersection(context.identityTokens)
        if !identityMatches.isEmpty {
            return 10_000 + identityMatches.count * 100
        }

        if context.identityTokens.isEmpty {
            let nameMatches = deviceTokens.intersection(context.nameTokens)
            if !nameMatches.isEmpty {
                return 1_000 + nameMatches.count * 10
            }
        }

        return 0
    }

    private static func trustedDeviceTokens(for device: OnlineDevice) -> Set<String> {
        var tokens = Set<String>()
        for raw in [device.uniqueIdentifier, device.ipv4, device.ipv6, device.name] {
            tokens.formUnion(trustedDeviceTokens(from: raw))
        }
        return tokens
    }

    private static func trustedDeviceTokens(from raw: String?) -> Set<String> {
        guard let raw = normalizedDiscoveryToken(raw) else { return [] }

        var tokens = Set<String>()
        tokens.insert(raw)

        if raw.hasPrefix("id:") {
            tokens.insert(String(raw.dropFirst("id:".count)))
            return tokens
        }

        if raw.hasPrefix("bonjour:") {
            tokens.insert("host:\(raw)")
            if let name = raw.split(separator: "@", maxSplits: 1).first {
                tokens.insert("name:\(String(name.dropFirst("bonjour:".count)))")
            }
            return tokens
        }

        if raw.hasPrefix("host:") {
            let payload = String(raw.dropFirst("host:".count))
            tokens.insert(payload)
            if payload.hasPrefix("bonjour:") {
                tokens.insert(payload)
            }
            if payload.hasPrefix("id:") {
                tokens.insert(String(payload.dropFirst("id:".count)))
            }
            return tokens
        }

        if raw.hasPrefix("recent:") {
            let payload = String(raw.dropFirst("recent:".count))
            tokens.insert(payload)
            if payload.hasPrefix("peer:") {
                tokens.insert(String(payload.dropFirst("peer:".count)))
            }
            return tokens
        }

        if raw.hasPrefix("peer:") {
            tokens.insert(String(raw.dropFirst("peer:".count)))
            return tokens
        }

        if raw.range(
            of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            tokens.insert(raw)
            tokens.insert("id:\(raw)")
            return tokens
        }

        if raw.contains(".") || raw.contains(":") {
            tokens.insert("host:\(raw)")
            return tokens
        }

        tokens.insert("name:\(raw)")
        return tokens
    }

    private static func normalizedDiscoveryToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return token.isEmpty ? nil : token
    }

    private static func effectiveConnectionStatus(for device: OnlineDevice, input: Input) -> OnlineDeviceStatus {
        input.effectiveStatusByDeviceId[device.id] ?? device.connectionStatus
    }

    private static func preferredOnlinePresentationOrder(
        _ lhs: OnlineDevice,
        _ rhs: OnlineDevice,
        input: Input
    ) -> Bool {
        let lhsConnectable = input.hasResolvedConnectableControlRouteByDeviceId[lhs.id] ?? false
        let rhsConnectable = input.hasResolvedConnectableControlRouteByDeviceId[rhs.id] ?? false
        if lhsConnectable != rhsConnectable {
            return lhsConnectable
        }
        if lhs.isConnectable != rhs.isConnectable {
            return lhs.isConnectable
        }
        if lhs.lastSeen != rhs.lastSeen {
            return lhs.lastSeen > rhs.lastSeen
        }
        return lhs.name < rhs.name
    }

    private static func trustedPresentationPriority(_ device: OnlineDevice) -> Int {
        var score = statusPriority(device.connectionStatus) * 1_000
        if device.isConnectable { score += 150 }
        if !(device.uniqueIdentifier.hasPrefix("recent:")) { score += 250 }
        if device.modelName?.isEmpty == false { score += 400 }
        if device.chip?.isEmpty == false { score += 300 }
        if device.platformName?.isEmpty == false { score += 200 }
        if device.osVersion?.isEmpty == false { score += 600 }
        if device.ipv4 != nil || device.ipv6 != nil { score += 100 }
        score += Int(device.lastSeen.timeIntervalSince1970)
        return score
    }

    private static func preferredRecentDisplayDevice(_ lhs: OnlineDevice, _ rhs: OnlineDevice) -> OnlineDevice {
        if statusPriority(lhs.connectionStatus) != statusPriority(rhs.connectionStatus) {
            return statusPriority(lhs.connectionStatus) > statusPriority(rhs.connectionStatus) ? lhs : rhs
        }

        if lhs.isConnectable != rhs.isConnectable {
            return lhs.isConnectable ? lhs : rhs
        }

        let lhsLooksLikeIP = isIPAddressLikeLabel(lhs.name)
        let rhsLooksLikeIP = isIPAddressLikeLabel(rhs.name)
        if lhsLooksLikeIP != rhsLooksLikeIP {
            return lhsLooksLikeIP ? rhs : lhs
        }

        let lhsConnected = lhs.lastConnectedAt ?? .distantPast
        let rhsConnected = rhs.lastConnectedAt ?? .distantPast
        if lhsConnected != rhsConnected {
            return lhsConnected > rhsConnected ? lhs : rhs
        }

        if lhs.lastSeen != rhs.lastSeen {
            return lhs.lastSeen > rhs.lastSeen ? lhs : rhs
        }

        return lhs.name.count >= rhs.name.count ? lhs : rhs
    }

    private static func isIPAddressLikeLabel(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains(":") { return true }
        let parts = trimmed.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0) != nil }
    }

    private static func statusPriority(_ status: OnlineDeviceStatus) -> Int {
        switch status {
        case .connected:
            return 3
        case .online:
            return 2
        case .offline:
            return 1
        }
    }

    private static func computeResolvedPresentationIdentityKey(
        for device: OnlineDevice,
        trustedGroups: [TrustRecordDisplayGroup],
        input: Input
    ) -> String {
        let liveProtocolIdentity = input.liveProtocolIdentityByDeviceId[device.id]
        let protocolIdentity: (authorityDeviceId: String?, protocolDeviceId: String?)
        if let trustRecord = resolvedTrustRecord(for: device, trustedGroups: trustedGroups, input: input) {
            let authorityDeviceId = liveProtocolIdentity?.deviceId ?? nonEmptySmokeIdentity(trustRecord.deviceId)
            let protocolDeviceId = liveProtocolIdentity?.deviceId
                ?? nonEmptySmokeIdentity(trustRecord.currentDeviceId)
                ?? authorityDeviceId
            protocolIdentity = (authorityDeviceId, protocolDeviceId)
        } else {
            let deviceId = liveProtocolIdentity?.deviceId
                ?? stableSmokeDeviceId(from: device.uniqueIdentifier)
                ?? device.routeIdentifiers.lazy.compactMap { stableSmokeDeviceId(from: $0) }.first
            protocolIdentity = (deviceId, deviceId)
        }

        if let stableDeviceId = protocolIdentity.protocolDeviceId ?? protocolIdentity.authorityDeviceId {
            return stableIdentityKey(for: stableDeviceId)
        }
        return device.uniqueIdentifier
    }

    private static func stableIdentityKey(for stableDeviceId: String) -> String {
        let payload = stableIdentityPayload(from: stableDeviceId)
        if stableDeviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("id:") {
            return stableDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "id:\(payload)"
    }

    private static func stableIdentityPayload(from raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("id:") {
            value = String(value.dropFirst("id:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func stableSmokeDeviceId(from raw: String?) -> String? {
        guard var value = nonEmptySmokeIdentity(raw) else { return nil }
        if value.lowercased().hasPrefix("recent:") {
            value = String(value.dropFirst("recent:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard value.lowercased().hasPrefix("id:") else { return nil }
        let payload = String(value.dropFirst("id:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
    }

    private static func nonEmptySmokeIdentity(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private static func normalizedSmokeToken(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

@MainActor
public struct EnhancedDeviceDiscoveryView: View {
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
 // 统一日志记录器，采用Apple推荐的Logger API（macOS 14+），避免使用过时的os_log。
    private let logger = Logger(subsystem: "com.skybridge.SkyBridgeCompassApp", category: "DeviceDiscovery")

 // 🆕 使用统一的在线设备管理器(单例)
    @ObservedObject private var unifiedDeviceManager = UnifiedOnlineDeviceManager.shared

    // Trusted / paired devices (from TrustSyncService)
    @StateObject private var trustSync = TrustSyncService.shared
    // 跨网在线状态（F2-B）：信令服务器上报的受信设备在线集合。
    @StateObject private var presence = PresenceService.shared

 // 跨网络连接（使用共享实例，确保与文件传输/远程桌面等模块状态一致）
    @StateObject private var crossNetworkManager = CrossNetworkConnectionManager.shared
    @StateObject private var p2pDiscoveryService = P2PDiscoveryService.shared
    @ObservedObject private var presenceService = ConnectionPresenceService.shared

 // 🆕 真实iCloud设备发现(不再单独使用,已整合到统一管理器中)
 // @StateObject private var iCloudManager = iCloudDeviceDiscoveryManager()

 // UI 状态
    @State private var selectedConnectionMode: DiscoveryMode = .localScan
    @State private var searchText = ""
    @State private var connectionCodeInput = ""
 // 控制二维码扫描弹窗显示与错误提示。
    @State private var showingScanner: Bool = false
    @State private var scannerErrorMessage: String?
    @State private var lastScannerErrorFingerprint: String?
    @State private var lastScannerErrorAt: Date = .distantPast
    @State private var connectionCodeErrorMessage: String?
    @State private var onlineDeviceConnectionErrorMessage: String?
    @State private var extendedSearchCountdown: Int = 0
    @State private var extendedSearchTimer: DispatchSourceTimer?
    @State private var showManualConnectSheet: Bool = false
    @State private var manualIP: String = ""
    @State private var manualPort: String = "11550"
    @State private var manualCode: String = ""
    @State private var hoveredConnectionMode: DiscoveryMode? = nil
    @State private var connectingOnlineDeviceIds: Set<UUID> = []

    @State private var selectedTrustedGroupSelection: TrustedGroupSelection?
    @StateObject private var trustedBonjourMetadata = TrustedBonjourMetadataStore()
    @State private var didAppendMacOnlineIPadSmokeBoot = false
    @State private var cachedTrustedRecordGroups: [TrustRecordDisplayGroup] = []
    @State private var cachedPresentationSnapshot: DeviceDiscoveryPresentationSnapshot = .empty
    @State private var cachedTrustedBonjourRefreshKey = ""
    @State private var presentationRefreshGeneration: UInt64 = 0
    @State private var presentationRefreshTask: Task<Void, Never>?



    public var body: some View {
        VStack(spacing: 0) {
 // 顶部：连接方式切换
            connectionModePicker

            Divider()

            // 主内容区
            ScrollView {
                LazyVStack(spacing: 20) {
                    switch selectedConnectionMode {
                    case .localScan:
                        localScanSection
                    case .qrCode:
                        qrCodeSection
                    case .cloudLink:
                        cloudLinkSection
                    case .connectionCode:
                        connectionCodeSection
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle(LocalizationManager.shared.localizedString("discovery.title"))
        .task {
            appendMacOnlineIPadSmokeRowsIfNeeded()
        }
        .onChange(of: smokeOnlineDeviceSnapshotKey) { _, _ in
            appendMacOnlineIPadSmokeRowsIfNeeded()
        }
        .sheet(isPresented: $showManualConnectSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizationManager.shared.localizedString("discovery.manualConnect.title")).font(.headline)
                TextField(LocalizationManager.shared.localizedString("discovery.manualConnect.ip"), text: $manualIP).textFieldStyle(.roundedBorder)
                TextField(LocalizationManager.shared.localizedString("discovery.manualConnect.port"), text: $manualPort).textFieldStyle(.roundedBorder)
                TextField(LocalizationManager.shared.localizedString("discovery.manualConnect.code"), text: $manualCode).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button(LocalizationManager.shared.localizedString("discovery.manualConnect.cancel")) { showManualConnectSheet = false }
                    Button(LocalizationManager.shared.localizedString("discovery.manualConnect.button")) {
                        showManualConnectSheet = false
                        let port = UInt16(manualPort) ?? 0
                        let device = DiscoveredDevice(
                            id: UUID(),
                            name: manualIP,
                            ipv4: manualIP,
                            ipv6: nil,
                            services: ["_skybridge._tcp"],
                            portMap: ["_skybridge._tcp": Int(port)],
                            connectionTypes: [.wifi],
                            uniqueIdentifier: manualCode.isEmpty ? nil : manualCode,
                            signalStrength: nil
                        )
                        Task {
                            do {
                                try await p2pDiscoveryService.connectToDevice(device)
                            } catch {
                                logger.error("❌ 手动连接失败: \(error.localizedDescription, privacy: .public)")
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
        .task {
 // 🆕 使用统一设备管理器,自动整合所有发现源
            startDiscoveryForInitialPresentationIfNeeded()
            refreshTrustedRecordGroups()
            refreshPresentationState()
        }
        .onReceive(trustSync.$activeTrustRecords) { records in
            let groups = Self.buildTrustedRecordGroups(from: records)
            cachedTrustedRecordGroups = groups
            refreshPresentationState(trustedGroups: groups)
        }
        // 节流：发现扫描时 onlineDevices 会高频突发更新。主线程只采集事实快照，
        // O(n²) 去重/分组交给后台 projector，并用 generation 防止旧结果覆盖新 UI。
        .onReceive(
            unifiedDeviceManager.$onlineDevices
                .throttle(for: .milliseconds(300), scheduler: DispatchQueue.main, latest: true)
        ) { devices in
            refreshPresentationState(onlineDevices: devices)
        }
        .onReceive(unifiedDeviceManager.$localDevice) { _ in
            refreshPresentationState()
        }
        .onReceive(unifiedDeviceManager.$isScanning) { _ in
            refreshTrustedBonjourRefreshKey()
        }
        .onReceive(unifiedDeviceManager.$discoveryMetadataSummary) { _ in
            refreshTrustedBonjourRefreshKey()
        }
        .onReceive(presenceService.$activeConnections) { _ in
            refreshPresentationState()
        }
        .onReceive(crossNetworkManager.$activeSessionSnapshot) { _ in
            refreshPresentationState()
        }
        .onReceive(trustedBonjourMetadata.$metadataByGroupId) { metadata in
            refreshPresentationState(trustedMetadata: metadata)
        }
        .onReceive(SettingsManager.shared.$showConnectableDevicesOnly) { _ in
            refreshPresentationState()
        }
        .onChange(of: searchText) { _, newValue in
            refreshPresentationState(searchText: newValue)
        }
        .task(id: trustedBonjourRefreshKey) {
            trustedBonjourMetadata.scheduleRefresh(for: trustedRecordsForUI)
        }
        .onDisappear {
            presentationRefreshTask?.cancel()
            presentationRefreshTask = nil
        }
        .sheet(item: $selectedTrustedGroupSelection) { selection in
            if let group = trustedRecordGroup(for: selection.id) {
                let record = group.displayRecord
                let presentationMetadata = trustedRecordPresentation(group)
                TrustedDeviceDetailView(
                    record: record,
                    relatedRecords: group.relatedRecords,
                    presentationMetadata: presentationMetadata,
                    status: trustedRecordStatus(group),
                    onDisconnect: { idsToDisconnect, declaredDeviceId in
                        Task { @MainActor in
                            var didDisconnect = false
                            let disconnectCandidateIds = Array(
                                Set(
                                    idsToDisconnect
                                        + record.knownDeviceIds
                                        + [record.deviceId, record.currentDeviceId, declaredDeviceId]
                                            .compactMap { $0 }
                                )
                            )
                            let normalizedIds = Set(
                                disconnectCandidateIds
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                            )
                            let normalizedRecordName = (record.deviceName ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .lowercased()

                            if let snapshot = crossNetworkManager.activeSessionSnapshot {
                                let snapshotId = (snapshot.deviceId ?? "")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .lowercased()
                                let snapshotName = (snapshot.deviceName ?? crossNetworkManager.currentConnection?.deviceName ?? "")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .lowercased()

                                if (!snapshotId.isEmpty && normalizedIds.contains(snapshotId))
                                    || (!normalizedRecordName.isEmpty && snapshotName == normalizedRecordName) {
                                    await crossNetworkManager.disconnect()
                                    didDisconnect = true
                                }
                            }

                            for id in disconnectCandidateIds {
                                didDisconnect = p2pDiscoveryService.disconnectFromDevice(id) || didDisconnect
                            }

                            if didDisconnect {
                                selectedTrustedGroupSelection = nil
                            }
                        }
                    },
                    onRepairP2PTrust: { idsToRepair in
                        Task { @MainActor in
                            await PeerBootstrapTrustMaterialCleanup.repairP2PTrust(deviceIds: idsToRepair)
                            selectedTrustedGroupSelection = nil
                        }
                    },
                    onRemoveTrust: { idsToRevoke, declaredDeviceId in
                        Task { @MainActor in
                            let idsToForget = Array(Set(idsToRevoke + [declaredDeviceId].compactMap { $0 }))
                            // Clear policy first so future requests prompt again.
                            if let declaredDeviceId {
                                PairingTrustApprovalService.shared.clearPolicy(for: declaredDeviceId)
                            }
                            // Revoke all related ids (canonical + alias).
                            for id in idsToForget {
                                try? await TrustSyncService.shared.revokeTrustRecord(deviceId: id)
                            }
                            await PeerBootstrapTrustMaterialCleanup.forgetDevice(deviceIds: idsToForget)
                            // Close sheet
                            selectedTrustedGroupSelection = nil
                        }
                    }
                )
                .frame(width: 520, height: 420)
                .padding(20)
            } else {
                EmptyView()
                    .frame(width: 520, height: 420)
            }
        }
        .onDisappear {
 // 注意:统一设备管理器是单例,不应在这里停止
 // 它会在DashboardViewModel中统一管理生命周期
            extendedSearchTimer?.cancel()
            extendedSearchTimer = nil
        }
    }

 // MARK: - 连接方式选择器

    private var connectionModePicker: some View {
        HStack(spacing: 0) {
            ForEach(DiscoveryMode.allCases) { mode in
                connectionModeButton(mode)
            }
        }
        .background(themeConfiguration.cardBackgroundMaterial)
        .overlay(
            Rectangle()
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private func connectionModeButton(_ mode: DiscoveryMode) -> some View {
        let isSelected = selectedConnectionMode == mode
        let isHovered = hoveredConnectionMode == mode
        return ConnectionModeButtonView(
            mode: mode,
            isSelected: isSelected,
            isHovered: isHovered,
            onSelect: {
                withAnimation(.spring(response: 0.3)) { selectedConnectionMode = mode }
            },
            onHoverChanged: { hovering in
                if hovering { hoveredConnectionMode = mode }
                else if hoveredConnectionMode == mode { hoveredConnectionMode = nil }
            }
        )
    }

    private struct ConnectionModeButtonView: View {
        @EnvironmentObject var themeConfiguration: ThemeConfiguration
        let mode: DiscoveryMode
        let isSelected: Bool
        let isHovered: Bool
        let onSelect: () -> Void
        let onHoverChanged: (Bool) -> Void
        var body: some View {
            VStack(spacing: 6) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 20))
                    .foregroundColor(mode.accentColor)
                Text(mode.title)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundColor(mode.accentColor)
                Text(mode.subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? mode.accentColor.opacity(0.12) : Color.clear)
            .background(
                Rectangle()
                    .fill(themeConfiguration.cardBackgroundMaterial)
                    .opacity(isHovered ? 0.35 : 0)
            )
            .overlay(
                Rectangle()
                    .stroke(isHovered ? themeConfiguration.borderColor : Color.clear, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .shadow(color: isHovered ? Color.white.opacity(0.06) : .clear, radius: 8, x: 0, y: 0)
            .overlay(
                Rectangle()
                    .fill(isSelected ? mode.accentColor : Color.clear)
                    .frame(height: 3),
                alignment: .bottom
            )
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
            .onHover { onHoverChanged($0) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(mode.title))
        }
    }

 // MARK: - 1️⃣ 本地扫描（原有功能增强）

    private var localScanSection: some View {
        VStack(alignment: .leading, spacing: 16) {
 // 说明卡片
            InfoBanner(
                icon: "wifi.router",
                title: LocalizationManager.shared.localizedString("discovery.localScan.title"),
                description: LocalizationManager.shared.localizedString("discovery.localScan.description"),
                color: .green
            )

 // 扫描控制
            HStack(spacing: 12) {
                if unifiedDeviceManager.isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(LocalizationManager.shared.localizedString("discovery.scanning"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Toggle(LocalizationManager.shared.localizedString("discovery.compatibilityMode"), isOn: Binding(
                    get: { SettingsManager.shared.enableCompatibilityMode },
                    set: { SettingsManager.shared.enableCompatibilityMode = $0; unifiedDeviceManager.refreshDevices() }
                ))
                .toggleStyle(.switch)
                .font(.caption)

                Button(action: {
                    extendedSearchTimer?.cancel()
                    extendedSearchTimer = nil
                    SettingsManager.shared.enableCompatibilityMode = true
                    unifiedDeviceManager.refreshDevices()
                    extendedSearchCountdown = 15
                    let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
                    t.schedule(deadline: .now() + 1.0, repeating: 1.0)
                    t.setEventHandler { [weak t] in
                        extendedSearchCountdown -= 1
                        if extendedSearchCountdown <= 0 {
                            t?.cancel()
                            extendedSearchTimer = nil
                            SettingsManager.shared.enableCompatibilityMode = false
                            unifiedDeviceManager.refreshDevices()
                        }
                    }
                    extendedSearchTimer = t
                    t.resume()
                }) {
                    Text(extendedSearchCountdown > 0 ? String(format: LocalizationManager.shared.localizedString("discovery.extendedSearch.active"), extendedSearchCountdown) : LocalizationManager.shared.localizedString("discovery.extendedSearch.static"))
                }
                .buttonStyle(.bordered)
                .font(.caption)
                .disabled(extendedSearchCountdown > 0)

                Button(LocalizationManager.shared.localizedString("discovery.manualConnect.title")) { showManualConnectSheet = true }
                .buttonStyle(.bordered)
                .font(.caption)

                Button(action: {
                    if unifiedDeviceManager.isScanning {
                        unifiedDeviceManager.stopDiscovery()
                    } else {
                        unifiedDeviceManager.startDiscovery()
                    }
                }) {
                    Label(
                        unifiedDeviceManager.isScanning ? LocalizationManager.shared.localizedString("discovery.stopScan") : LocalizationManager.shared.localizedString("discovery.startScan"),
                        systemImage: unifiedDeviceManager.isScanning ? "stop.circle" : "play.circle"
                    )
                }
                .buttonStyle(.borderedProminent)

                Button(action: {
                    unifiedDeviceManager.refreshDevices()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help(LocalizationManager.shared.localizedString("discovery.refresh"))
            }
            .padding(12)
            .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(themeConfiguration.borderColor, lineWidth: 1)
            )

            if let onlineDeviceConnectionErrorMessage,
               !onlineDeviceConnectionErrorMessage.isEmpty {
                Text(onlineDeviceConnectionErrorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 我的设备（固定展示，不依赖扫描结果；避免被“在线设备”列表/过滤逻辑吞掉）
            if let my = unifiedDeviceManager.localDevice {
                VStack(alignment: .leading, spacing: 12) {
                    Text("我的设备")
                        .font(.headline)

                    OnlineDeviceCard(
                        device: my,
                        accessibilityIdentity: cachedPresentationIdentityKey(for: my)
                    ) {
                        // no-op: 本机不需要“连接”
                    }

                    // 当前已连接设备（即使尚未“信任/配对”，也应在这里可见）
                    let connectedNow = connectedOnlineDevicesNonLocal
                    if !connectedNow.isEmpty {
                        ForEach(connectedNow) { dev in
                            OnlineDeviceCard(
                                device: dev,
                                accessibilityIdentity: cachedPresentationIdentityKey(for: dev)
                            ) {
                                // already connected; no-op
                            }
                        }
                    }
                }
                .padding(16)
                .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.blue.opacity(0.6), lineWidth: 1)
                )
            }

            // 受信任设备（已配对/已允许）——来自 TrustSyncService
            let trustedRecords = displayedTrustedRecordsForUI
            if !trustedRecords.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("已信任设备")
                        .font(.headline)

                    ForEach(trustedRecords) { group in
                        TrustedDeviceCard(
                            record: group.group.displayRecord,
                            subtitle: group.subtitle,
                            status: group.status
                        ) {
                            selectedTrustedGroupSelection = TrustedGroupSelection(id: group.id)
                        }
                    }
                }
                .padding(16)
                .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.green.opacity(0.5), lineWidth: 1)
                )
            }

            // 最近连接（不等同于“信任/已配对”，但应立即可见）
            let recentlyConnected = groupedRecentlyConnectedDevices
            if !recentlyConnected.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("最近连接")
                        .font(.headline)
                    ForEach(recentlyConnected) { device in
                        OnlineDeviceCard(
                            device: device,
                            accessibilityIdentity: cachedPresentationIdentityKey(for: device),
                            isConnecting: connectingOnlineDeviceIds.contains(device.id),
                            canConnect: cachedCanConnect(device)
                        ) {
                            // If already connected, no-op; otherwise, we keep this as a future reconnect entry.
                            connectToOnlineDevice(device)
                        }
                    }
                }
                .padding(16)
                .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.green.opacity(0.35), lineWidth: 1)
                )
            }

 // 设备列表
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(String(format: LocalizationManager.shared.localizedString("discovery.onlineDevices"), activeOnlineDevicesNonLocal.count))
                        .font(.headline)

                    if clearableOfflineDeviceCount > 0 {
                        Button {
                            unifiedDeviceManager.clearOfflineDevices()
                        } label: {
                            Label("清理离线 (\(clearableOfflineDeviceCount))", systemImage: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("移除所有已离线、未授权的发现设备（受信/在线设备保留）")
                    }

                    Spacer()

 // 搜索框
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField(LocalizationManager.shared.localizedString("discovery.searchPlaceholder"), text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(themeConfiguration.borderColor, lineWidth: 1)
                    )
                    .frame(width: 200)
                }

                if filteredOnlineDevicesNonLocal.isEmpty {
                    emptyStateView(
                        icon: "antenna.radiowaves.left.and.right.slash",
                        title: LocalizationManager.shared.localizedString("discovery.noDevices.title"),
                        message: unifiedDeviceManager.isScanning ? LocalizationManager.shared.localizedString("discovery.noDevices.scanning") : LocalizationManager.shared.localizedString("discovery.noDevices.startPrompt")
                    )
                } else {
                    ForEach(filteredOnlineDevicesNonLocal) { device in
                        OnlineDeviceCard(
                            device: device,
                            accessibilityIdentity: cachedPresentationIdentityKey(for: device),
                            isConnecting: connectingOnlineDeviceIds.contains(device.id),
                            canConnect: cachedCanConnect(device)
                        ) {
                            connectToOnlineDevice(device)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Trusted Devices helpers

    private var trustedRecordsForUI: [TrustRecordDisplayGroup] {
        cachedTrustedRecordGroups
    }

    private static func buildTrustedRecordGroups(from records: [TrustRecord]) -> [TrustRecordDisplayGroup] {
        let activeTrustedRecords = records
            .filter { $0.capabilities.contains(where: { $0.lowercased() == "trusted" || $0.lowercased() == "pqc_bootstrap" || $0.lowercased().hasPrefix("trusted") }) }
            .sorted { $0.updatedAt > $1.updatedAt }

        return TrustSyncService.buildPresentationDisplayGroups(from: activeTrustedRecords)
    }

    private func refreshTrustedRecordGroups() {
        cachedTrustedRecordGroups = Self.buildTrustedRecordGroups(from: trustSync.activeTrustRecords)
    }

    private func startDiscoveryForInitialPresentationIfNeeded() {
        guard SettingsManager.shared.autoScanOnStartup else { return }
        guard !unifiedDeviceManager.isScanning else { return }
        unifiedDeviceManager.startDiscovery()
    }

    private func refreshPresentationState(
        onlineDevices: [OnlineDevice]? = nil,
        trustedGroups: [TrustRecordDisplayGroup]? = nil,
        searchText: String? = nil,
        trustedMetadata: [String: ApplePeerDeviceMetadataNormalizer.Presentation]? = nil
    ) {
        let devices = onlineDevices ?? unifiedDeviceManager.onlineDevices
        let groups = trustedGroups ?? cachedTrustedRecordGroups
        let query = searchText ?? self.searchText
        let metadata = trustedMetadata ?? trustedBonjourMetadata.metadataByGroupId
        let input = makePresentationProjectorInput(
            onlineDevices: devices,
            trustedGroups: groups,
            searchText: query,
            trustedMetadata: metadata
        )
        let refreshKey = buildTrustedBonjourRefreshKey(
            trustedGroups: groups,
            onlineDevices: devices
        )
        presentationRefreshGeneration &+= 1
        let generation = presentationRefreshGeneration
        presentationRefreshTask?.cancel()
        presentationRefreshTask = Task(priority: .userInitiated) {
            let snapshot = await Task.detached(priority: .userInitiated) {
                DeviceDiscoveryPresentationProjector.buildPresentationSnapshot(input: input)
            }.value

            guard !Task.isCancelled, presentationRefreshGeneration == generation else { return }
            cachedPresentationSnapshot = snapshot
            cachedTrustedBonjourRefreshKey = refreshKey
            presentationRefreshTask = nil
        }
    }

    private func makePresentationProjectorInput(
        onlineDevices: [OnlineDevice],
        trustedGroups: [TrustRecordDisplayGroup],
        searchText: String,
        trustedMetadata: [String: ApplePeerDeviceMetadataNormalizer.Presentation]
    ) -> DeviceDiscoveryPresentationProjector.Input {
        let allTrustRecords = trustedGroups.flatMap { trustedLookupRecords(for: $0) }
        var hasResolvedConnectableControlRouteByDeviceId: [UUID: Bool] = [:]
        var effectiveStatusByDeviceId: [UUID: OnlineDeviceStatus] = [:]
        var resolvedTrustRecordByDeviceId: [UUID: TrustRecord] = [:]
        var liveProtocolIdentityByDeviceId: [UUID: DeviceDiscoveryResolvedProtocolIdentity] = [:]

        for device in onlineDevices {
            hasResolvedConnectableControlRouteByDeviceId[device.id] =
                unifiedDeviceManager.hasResolvedConnectableControlRoute(for: device)
            effectiveStatusByDeviceId[device.id] = effectiveConnectionStatus(for: device)
            if let trustRecord = unifiedDeviceManager.resolvedTrustRecord(for: device, among: allTrustRecords) {
                resolvedTrustRecordByDeviceId[device.id] = trustRecord
            }
            let liveProtocolIdentity = resolvedLiveProtocolIdentity(for: device)
            liveProtocolIdentityByDeviceId[device.id] = DeviceDiscoveryResolvedProtocolIdentity(
                deviceId: liveProtocolIdentity.deviceId,
                pubKeyFP: liveProtocolIdentity.pubKeyFP
            )
        }

        let trustedLiveMetadata = Dictionary(
            uniqueKeysWithValues: trustedGroups.map { group in
                (
                    group.id,
                    unifiedDeviceManager.resolvedApplePeerMetadata(for: trustedLookupRecords(for: group))
                )
            }
            .compactMap { key, value in
                value.map { (key, $0) }
            }
        )
        let crossNetworkActiveTrustedGroupIds = Set(
            trustedGroups
                .filter(isCrossNetworkSessionActive(for:))
                .map(\.id)
        )

        return DeviceDiscoveryPresentationProjector.Input(
            onlineDevices: onlineDevices,
            trustedGroups: trustedGroups,
            searchText: searchText,
            showConnectableDevicesOnly: SettingsManager.shared.showConnectableDevicesOnly,
            trustedMetadata: trustedMetadata,
            trustedLiveMetadata: trustedLiveMetadata,
            hasResolvedConnectableControlRouteByDeviceId: hasResolvedConnectableControlRouteByDeviceId,
            effectiveStatusByDeviceId: effectiveStatusByDeviceId,
            resolvedTrustRecordByDeviceId: resolvedTrustRecordByDeviceId,
            liveProtocolIdentityByDeviceId: liveProtocolIdentityByDeviceId,
            crossNetworkActiveTrustedGroupIds: crossNetworkActiveTrustedGroupIds,
            presenceOnlinePeerDeviceIds: presence.onlinePeerDeviceIds
        )
    }

    private func refreshTrustedBonjourRefreshKey() {
        cachedTrustedBonjourRefreshKey = buildTrustedBonjourRefreshKey(
            trustedGroups: cachedTrustedRecordGroups,
            onlineDevices: unifiedDeviceManager.onlineDevices
        )
    }

    private func trustedRecordGroup(for id: String) -> TrustRecordDisplayGroup? {
        trustedRecordsForUI.first { $0.id == id }
    }

    private func trustedRecordCaps(_ record: TrustRecord) -> [String: String] {
        var dict: [String: String] = [:]
        for item in record.capabilities {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                dict[parts[0]] = parts[1]
            }
        }
        return dict
    }

    private func trustedRecordSubtitle(_ group: TrustRecordDisplayGroup) -> String {
        trustedRecordSubtitle(group, metadataByGroupId: trustedBonjourMetadata.metadataByGroupId)
    }

    private func trustedRecordSubtitle(
        _ group: TrustRecordDisplayGroup,
        metadataByGroupId: [String: ApplePeerDeviceMetadataNormalizer.Presentation]
    ) -> String {
        let normalized = trustedRecordPresentation(group, metadataByGroupId: metadataByGroupId)

        var parts: [String] = []
        if let modelName = normalized.modelName { parts.append(modelName) }
        if let chip = normalized.chip { parts.append(chip) }
        if let platform = normalized.platform, let osVersion = normalized.osVersion {
            parts.append("\(platform) \(osVersion)")
        } else if let platform = normalized.platform {
            parts.append(platform)
        }
        return parts.isEmpty ? group.displayRecord.deviceId : parts.joined(separator: " · ")
    }

    private func trustedRecordPresentation(
        _ group: TrustRecordDisplayGroup
    ) -> ApplePeerDeviceMetadataNormalizer.Presentation {
        trustedRecordPresentation(group, metadataByGroupId: trustedBonjourMetadata.metadataByGroupId)
    }

    private func trustedRecordPresentation(
        _ group: TrustRecordDisplayGroup,
        metadataByGroupId: [String: ApplePeerDeviceMetadataNormalizer.Presentation]
    ) -> ApplePeerDeviceMetadataNormalizer.Presentation {
        let record = group.displayRecord
        let c = trustedRecordCaps(record)
        let fallback = ApplePeerDeviceMetadataNormalizer.normalize(
            modelName: c["modelName"],
            chip: c["chip"],
            platform: c["platform"],
            osVersion: c["osVersion"]
        )
        let bonjourLive = metadataByGroupId[group.id]
        let live = bonjourLive ?? unifiedDeviceManager.resolvedApplePeerMetadata(for: trustedLookupRecords(for: group))
        var merged = ApplePeerDeviceMetadataNormalizer.mergedPresentation(
            preferred: live,
            fallback: fallback
        )
        if live == nil {
            merged = ApplePeerDeviceMetadataNormalizer.normalize(
                modelName: merged.modelName,
                chip: merged.chip,
                platform: merged.platform,
                osVersion: nil
            )
        }
        return merged
    }

    private func trustedLivePresentation(
        _ group: TrustRecordDisplayGroup
    ) -> ApplePeerDeviceMetadataNormalizer.Presentation? {
        unifiedDeviceManager.resolvedApplePeerMetadata(for: trustedLookupRecords(for: group))
    }

    private func trustedRecordStatus(_ group: TrustRecordDisplayGroup) -> OnlineDeviceStatus {
        trustedRecordStatus(
            group,
            liveCandidates: unifiedDeviceManager.onlineDevices.filter { !$0.isLocalDevice },
            recentCandidates: groupedRecentlyConnectedDevices
        )
    }

    private func trustedRecordStatus(
        _ group: TrustRecordDisplayGroup,
        liveCandidates: [OnlineDevice],
        recentCandidates: [OnlineDevice]
    ) -> OnlineDeviceStatus {
        let resolvedStatus = trustedPresentationOnlineDevices(
            for: group,
            liveCandidates: liveCandidates,
            recentCandidates: recentCandidates
        )
            .map(\.connectionStatus)
            .max(by: { statusPriority($0) < statusPriority($1) })
            ?? .offline
        if isCrossNetworkSessionActive(for: group) { return .connected }
        // 跨网在线 presence：信令服务器上报在线即标记为在线（即使不在同一局域网、无活动会话）。
        if resolvedStatus == .offline, trustedGroupIsPresenceOnline(group) { return .online }
        return resolvedStatus
    }

    /// 该受信设备组是否有任一已知 id 在信令服务器上报为在线（跨网在线状态）。
    private func trustedGroupIsPresenceOnline(_ group: TrustRecordDisplayGroup) -> Bool {
        let online = presence.onlinePeerDeviceIds
        guard !online.isEmpty else { return false }
        for record in trustedLookupRecords(for: group) {
            if online.contains(record.deviceId) || online.contains(record.currentDeviceId) {
                return true
            }
        }
        return false
    }

    private func isCrossNetworkSessionActive(for group: TrustRecordDisplayGroup) -> Bool {
        guard let snapshot = crossNetworkManager.activeSessionSnapshot else { return false }
        switch snapshot.phase {
        case .transportReady, .handshakeComplete, .reconnecting:
            break
        case .connecting, .disconnecting:
            return false
        }

        let snapshotIds = Set(
            [
                snapshot.deviceId
            ]
            .compactMap(normalizedDiscoveryToken)
        )

        for record in trustedLookupRecords(for: group) {
            let caps = trustedRecordCaps(record)
            let recordIds = Set(
                [
                    record.deviceId,
                    record.currentDeviceId,
                    caps["declaredDeviceId"],
                    caps["peerEndpoint"]
                ]
                + record.knownDeviceIds
            .compactMap(normalizedDiscoveryToken))

            if !recordIds.isDisjoint(with: snapshotIds) {
                return true
            }

            let recordName = normalizedDiscoveryToken(record.deviceName)
            let snapshotName = normalizedDiscoveryToken(
                snapshot.deviceName ?? crossNetworkManager.currentConnection?.deviceName
            )
            if let recordName, let snapshotName, recordName == snapshotName {
                return true
            }
        }

        return false
    }

    private func trustedLookupRecords(for group: TrustRecordDisplayGroup) -> [TrustRecord] {
        let records = [group.displayRecord] + group.relatedRecords
        var ordered: [TrustRecord] = []
        var seen = Set<String>()

        for record in records {
            let key = "\(record.deviceId)|\(record.updatedAt)"
            if seen.insert(key).inserted {
                ordered.append(record)
            }
        }
        return ordered
    }

    private func trustedPresentationOnlineDevices(for group: TrustRecordDisplayGroup) -> [OnlineDevice] {
        trustedPresentationOnlineDevices(
            for: group,
            liveCandidates: unifiedDeviceManager.onlineDevices.filter { !$0.isLocalDevice },
            recentCandidates: groupedRecentlyConnectedDevices
        )
    }

    private func trustedPresentationOnlineDevices(
        for group: TrustRecordDisplayGroup,
        liveCandidates: [OnlineDevice],
        recentCandidates: [OnlineDevice]
    ) -> [OnlineDevice] {
        let records = trustedLookupRecords(for: group)
        let context = trustedDeviceMatchContext(for: group)

        var mergedByIdentity: [String: (score: Int, device: OnlineDevice)] = [:]
        for device in liveCandidates + recentCandidates {
            let resolvedTrustRecord = unifiedDeviceManager.resolvedTrustRecord(for: device, among: records)
            let fallbackScore = trustedDeviceMatchScore(device, context: context)
            let matchScore: Int
            let mergeKey: String

            if let resolvedTrustRecord {
                matchScore = 20_000 + fallbackScore
                mergeKey = "trusted:\(resolvedTrustRecord.deviceId)"
            } else {
                guard fallbackScore > 0 else { continue }
                matchScore = fallbackScore
                mergeKey = "device:\(device.id.uuidString)"
            }

            if let existing = mergedByIdentity[mergeKey] {
                if existing.score == matchScore {
                    mergedByIdentity[mergeKey] = (
                        score: matchScore,
                        device: preferredRecentDisplayDevice(existing.device, device)
                    )
                } else if existing.score < matchScore {
                    mergedByIdentity[mergeKey] = (score: matchScore, device: device)
                }
            } else {
                mergedByIdentity[mergeKey] = (score: matchScore, device: device)
            }
        }

        return mergedByIdentity.values.sorted { lhs, rhs in
            let lhsScore = lhs.score
            let rhsScore = rhs.score
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return trustedPresentationPriority(lhs.device) > trustedPresentationPriority(rhs.device)
        }
        .map(\.device)
    }

    private func trustedPresentationPriority(_ device: OnlineDevice) -> Int {
        var score = statusPriority(device.connectionStatus) * 1_000
        if device.isConnectable { score += 150 }
        if !(device.uniqueIdentifier.hasPrefix("recent:")) { score += 250 }
        if device.modelName?.isEmpty == false { score += 400 }
        if device.chip?.isEmpty == false { score += 300 }
        if device.platformName?.isEmpty == false { score += 200 }
        if device.osVersion?.isEmpty == false { score += 600 }
        if device.ipv4 != nil || device.ipv6 != nil { score += 100 }
        score += Int(device.lastSeen.timeIntervalSince1970)
        return score
    }

    private func trustedDeviceMatchContext(
        for group: TrustRecordDisplayGroup
    ) -> (identityTokens: Set<String>, nameTokens: Set<String>) {
        let records = trustedLookupRecords(for: group)
        var identityTokens = Set<String>()
        var nameTokens = Set<String>()

        for record in records {
            for raw in [record.deviceId, record.currentDeviceId, record.deviceName] + record.knownDeviceIds {
                trustedDeviceTokens(from: raw).forEach { token in
                    if token.hasPrefix("name:") {
                        nameTokens.insert(token)
                    } else {
                        identityTokens.insert(token)
                    }
                }
            }

            let caps = trustedRecordCaps(record)
            for raw in [caps["declaredDeviceId"], caps["peerEndpoint"]] {
                trustedDeviceTokens(from: raw).forEach { token in
                    if token.hasPrefix("name:") {
                        nameTokens.insert(token)
                    } else {
                        identityTokens.insert(token)
                    }
                }
            }
        }

        return (identityTokens, nameTokens)
    }

    private func trustedDeviceMatchScore(
        _ device: OnlineDevice,
        context: (identityTokens: Set<String>, nameTokens: Set<String>)
    ) -> Int {
        let deviceTokens = trustedDeviceTokens(for: device)
        let identityMatches = deviceTokens.intersection(context.identityTokens)
        if !identityMatches.isEmpty {
            return 10_000 + identityMatches.count * 100
        }

        if context.identityTokens.isEmpty {
            let nameMatches = deviceTokens.intersection(context.nameTokens)
            if !nameMatches.isEmpty {
                return 1_000 + nameMatches.count * 10
            }
        }

        return 0
    }

    private func trustedDeviceTokens(for device: OnlineDevice) -> Set<String> {
        var tokens = Set<String>()
        for raw in [device.uniqueIdentifier, device.ipv4, device.ipv6, device.name] {
            tokens.formUnion(trustedDeviceTokens(from: raw))
        }
        return tokens
    }

    private func trustedDeviceTokens(from raw: String?) -> Set<String> {
        guard let raw = normalizedDiscoveryToken(raw) else { return [] }

        var tokens = Set<String>()
        tokens.insert(raw)

        if raw.hasPrefix("id:") {
            tokens.insert(String(raw.dropFirst("id:".count)))
            return tokens
        }

        if raw.hasPrefix("bonjour:") {
            tokens.insert("host:\(raw)")
            if let name = raw.split(separator: "@", maxSplits: 1).first {
                tokens.insert("name:\(String(name.dropFirst("bonjour:".count)))")
            }
            return tokens
        }

        if raw.hasPrefix("host:") {
            let payload = String(raw.dropFirst("host:".count))
            tokens.insert(payload)
            if payload.hasPrefix("bonjour:") {
                tokens.insert(payload)
            }
            if payload.hasPrefix("id:") {
                tokens.insert(String(payload.dropFirst("id:".count)))
            }
            return tokens
        }

        if raw.hasPrefix("recent:") {
            let payload = String(raw.dropFirst("recent:".count))
            tokens.insert(payload)
            if payload.hasPrefix("peer:") {
                tokens.insert(String(payload.dropFirst("peer:".count)))
            }
            return tokens
        }

        if raw.hasPrefix("peer:") {
            tokens.insert(String(raw.dropFirst("peer:".count)))
            return tokens
        }

        if raw.range(
            of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            tokens.insert(raw)
            tokens.insert("id:\(raw)")
            return tokens
        }

        if raw.contains(".") || raw.contains(":") {
            tokens.insert("host:\(raw)")
            return tokens
        }

        tokens.insert("name:\(raw)")
        return tokens
    }

    private func normalizedDiscoveryToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return token.isEmpty ? nil : token
    }

    private func effectiveConnectionStatus(for device: OnlineDevice) -> OnlineDeviceStatus {
        matchingPresenceConnection(for: device) == nil ? device.connectionStatus : .connected
    }

    private func matchingPresenceConnection(
        for device: OnlineDevice
    ) -> ConnectionPresenceService.ActiveConnection? {
        guard !device.isLocalDevice,
              !presenceService.activeConnections.isEmpty else {
            return nil
        }

        let deviceTokens = presenceMatchTokens(
            identifier: device.uniqueIdentifier,
            displayName: device.name,
            addresses: [device.ipv4, device.ipv6]
        )
        guard !deviceTokens.isEmpty else { return nil }

        return presenceService.activeConnections
            .filter { connection in
                let connectionTokens = presenceMatchTokens(
                    identifier: connection.id,
                    displayName: connection.displayName,
                    addresses: [connection.address]
                )
                return !deviceTokens.isDisjoint(with: connectionTokens)
            }
            .max(by: { $0.connectedAt < $1.connectedAt })
    }

    private func presenceMatchTokens(
        identifier: String?,
        displayName: String?,
        addresses: [String?]
    ) -> Set<String> {
        var tokens = Set<String>()
        tokens.formUnion(trustedDeviceTokens(from: identifier))
        tokens.formUnion(trustedDeviceTokens(from: displayName))
        for address in addresses {
            tokens.formUnion(trustedDeviceTokens(from: normalizedPresenceAddress(address)))
        }
        return tokens
    }

    private func normalizedPresenceAddress(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        if let percent = value.firstIndex(of: "%") {
            value = String(value[..<percent])
        }
        return value
    }

    private var onlineNonLocalDevices: [OnlineDevice] {
        unifiedDeviceManager.onlineDevices.filter { !$0.isLocalDevice }
    }

    /// 可被「清理离线」一键移除的设备数：非本机、未授权、当前离线（即历史堆积的「未知」离线幽灵）。
    private var clearableOfflineDeviceCount: Int {
        unifiedDeviceManager.onlineDevices.filter {
            !$0.isLocalDevice && !$0.isAuthorized && $0.connectionStatus == .offline
        }.count
    }

    private var connectedOnlineDevicesNonLocal: [OnlineDevice] {
        cachedPresentationSnapshot.connectedOnlineDevicesNonLocal
    }

    private var activeOnlineDevicesNonLocal: [OnlineDevice] {
        cachedPresentationSnapshot.activeOnlineDevicesNonLocal
    }

    private var filteredOnlineDevicesNonLocal: [OnlineDevice] {
        cachedPresentationSnapshot.filteredOnlineDevicesNonLocal
    }

    private var groupedRecentlyConnectedDevices: [OnlineDevice] {
        cachedPresentationSnapshot.groupedRecentlyConnectedDevices
    }

    private func groupedRecentlyConnectedDevices(
        from onlineDevices: [OnlineDevice],
        connectedDevices: [OnlineDevice],
        activeDevices: [OnlineDevice],
        trustedGroups: [TrustRecordDisplayGroup]
    ) -> [OnlineDevice] {
        let liveRepresentations = connectedDevices + activeDevices
        let candidates = onlineDevices
            .filter { !$0.isLocalDevice && $0.lastConnectedAt != nil && $0.connectionStatus == .offline }
            .filter { device in
                !hasHigherPriorityPresentation(
                    for: device,
                    representedDevices: liveRepresentations,
                    trustedGroups: trustedGroups
                )
        }
        guard !candidates.isEmpty else { return [] }

        let trustRecords = trustedGroups.map(\.displayRecord)
        var grouped: [String: OnlineDevice] = [:]

        for device in candidates {
            let groupingKey: String
            if let trustRecord = unifiedDeviceManager.resolvedTrustRecord(for: device, among: trustRecords) {
                groupingKey = "trusted:\(trustRecord.deviceId)"
            } else {
                groupingKey = "device:\(device.id.uuidString)"
            }

            if let existing = grouped[groupingKey] {
                grouped[groupingKey] = preferredRecentDisplayDevice(existing, device)
            } else {
                grouped[groupingKey] = device
            }
        }

        let presentationDevices = presentationDedupeOnlineDevices(Array(grouped.values), trustedGroups: trustedGroups)
        return presentationDevices.sorted { lhs, rhs in
            if statusPriority(lhs.connectionStatus) != statusPriority(rhs.connectionStatus) {
                return statusPriority(lhs.connectionStatus) > statusPriority(rhs.connectionStatus)
            }
            let lhsConnected = lhs.lastConnectedAt ?? .distantPast
            let rhsConnected = rhs.lastConnectedAt ?? .distantPast
            if lhsConnected != rhsConnected {
                return lhsConnected > rhsConnected
            }
            if lhs.lastSeen != rhs.lastSeen {
                return lhs.lastSeen > rhs.lastSeen
            }
            return lhs.name < rhs.name
        }
    }

    private func presentationDedupeOnlineDevices(_ devices: [OnlineDevice]) -> [OnlineDevice] {
        presentationDedupeOnlineDevices(devices, trustedGroups: trustedRecordsForUI)
    }

    private func presentationDedupeOnlineDevices(
        _ devices: [OnlineDevice],
        trustedGroups: [TrustRecordDisplayGroup]
    ) -> [OnlineDevice] {
        let hasResolvedConnectableControlRouteByDeviceId = Dictionary(
            uniqueKeysWithValues: devices.map { device in
                (device.id, unifiedDeviceManager.hasResolvedConnectableControlRoute(for: device))
            }
        )
        return presentationDedupeOnlineDevices(
            devices,
            trustedGroups: trustedGroups,
            hasResolvedConnectableControlRouteByDeviceId: hasResolvedConnectableControlRouteByDeviceId
        )
    }

    private func presentationDedupeOnlineDevices(
        _ devices: [OnlineDevice],
        trustedGroups: [TrustRecordDisplayGroup],
        hasResolvedConnectableControlRouteByDeviceId: [UUID: Bool]
    ) -> [OnlineDevice] {
        var passthrough: [OnlineDevice] = []
        var appleMobileGroups: [[OnlineDevice]] = []

        for device in devices {
            guard appleMobilePresentationFamily(for: device) != nil,
                  !appleMobileStrongPresentationTokens(for: device, trustedGroups: trustedGroups).isEmpty else {
                passthrough.append(device)
                continue
            }

            let matchingIndices = appleMobileGroups.indices.filter { index in
                let group = appleMobileGroups[index]
                return group.contains { existing in
                    shouldCoalesceAppleMobilePresentation(existing, device, trustedGroups: trustedGroups)
                }
            }
            if let firstIndex = matchingIndices.first {
                var mergedGroup = appleMobileGroups[firstIndex]
                mergedGroup.append(device)
                for index in matchingIndices.dropFirst().reversed() {
                    mergedGroup.append(contentsOf: appleMobileGroups.remove(at: index))
                }
                appleMobileGroups[firstIndex] = mergedGroup
            } else {
                appleMobileGroups.append([device])
            }
        }

        let coalescedAppleMobile = appleMobileGroups.flatMap { group -> [OnlineDevice] in
            guard group.count > 1,
                  let winner = group.max(by: {
                      preferredOnlinePresentationOrder(
                          $1,
                          $0,
                          hasResolvedConnectableControlRouteByDeviceId: hasResolvedConnectableControlRouteByDeviceId
                      )
                  }) else {
                return group
            }
            return [winner]
        }

        return (passthrough + coalescedAppleMobile).sorted {
            preferredOnlinePresentationOrder(
                $0,
                $1,
                hasResolvedConnectableControlRouteByDeviceId: hasResolvedConnectableControlRouteByDeviceId
            )
        }
    }

    private func hasHigherPriorityPresentation(
        for candidate: OnlineDevice,
        representedDevices: [OnlineDevice],
        trustedGroups: [TrustRecordDisplayGroup]
    ) -> Bool {
        let candidateIdentity = computeResolvedPresentationIdentityKey(
            for: candidate,
            trustedGroups: trustedGroups
        )
        return representedDevices.contains { represented in
            represented.id == candidate.id
                || represented.uniqueIdentifier == candidate.uniqueIdentifier
                || computeResolvedPresentationIdentityKey(for: represented, trustedGroups: trustedGroups) == candidateIdentity
                || shouldCoalesceAppleMobilePresentation(candidate, represented, trustedGroups: trustedGroups)
        }
    }

    private func shouldCoalesceAppleMobilePresentation(_ lhs: OnlineDevice, _ rhs: OnlineDevice) -> Bool {
        shouldCoalesceAppleMobilePresentation(lhs, rhs, trustedGroups: trustedRecordsForUI)
    }

    private func shouldCoalesceAppleMobilePresentation(
        _ lhs: OnlineDevice,
        _ rhs: OnlineDevice,
        trustedGroups: [TrustRecordDisplayGroup]
    ) -> Bool {
        guard let lhsFamily = appleMobilePresentationFamily(for: lhs),
              let rhsFamily = appleMobilePresentationFamily(for: rhs),
              lhsFamily == rhsFamily else {
            return false
        }

        guard appleMobilePresentationMetadataCompatible(lhs.modelName, rhs.modelName, family: lhsFamily),
              appleMobilePresentationPlatformCompatible(lhs.platformName, rhs.platformName) else {
            return false
        }

        let lhsRoutes = appleMobilePresentationRouteTokens(for: lhs)
        let rhsRoutes = appleMobilePresentationRouteTokens(for: rhs)
        if !lhsRoutes.isEmpty, !lhsRoutes.isDisjoint(with: rhsRoutes) {
            return true
        }

        let lhsTokens = appleMobileStrongPresentationTokens(for: lhs, trustedGroups: trustedGroups)
        let rhsTokens = appleMobileStrongPresentationTokens(for: rhs, trustedGroups: trustedGroups)
        return !lhsTokens.isEmpty && !rhsTokens.isEmpty && !lhsTokens.isDisjoint(with: rhsTokens)
    }

    private func appleMobilePresentationFamily(for device: OnlineDevice) -> String? {
        let haystack = [
            device.name,
            device.modelName ?? "",
            device.platformName ?? ""
        ].joined(separator: " ").lowercased()
        if haystack.contains("ipad") || haystack.contains("ipados") {
            return "ipad"
        }
        if haystack.contains("iphone") || haystack.contains("ios") {
            return "iphone"
        }
        return nil
    }

    private func appleMobilePresentationMetadataCompatible(
        _ lhs: String?,
        _ rhs: String?,
        family: String
    ) -> Bool {
        let lhs = normalizedSmokeToken(lhs ?? "")
        let rhs = normalizedSmokeToken(rhs ?? "")
        guard !lhs.isEmpty, !rhs.isEmpty else { return true }
        if lhs == rhs { return true }
        return lhs == family && rhs.hasPrefix(family)
            || rhs == family && lhs.hasPrefix(family)
    }

    private func appleMobilePresentationPlatformCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        let lhs = normalizedSmokeToken(lhs ?? "")
        let rhs = normalizedSmokeToken(rhs ?? "")
        guard !lhs.isEmpty, !rhs.isEmpty else { return true }
        if lhs == rhs { return true }
        let mobilePlatforms: Set<String> = ["ios", "ipados"]
        return mobilePlatforms.contains(lhs) && mobilePlatforms.contains(rhs)
    }

    private func appleMobilePresentationRouteTokens(for device: OnlineDevice) -> Set<String> {
        var tokens = Set<String>()
        let rawValues: [String?] = [Optional.some(device.uniqueIdentifier)] + device.routeIdentifiers.map(Optional.some)
        for raw in rawValues {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                continue
            }
            let normalized = raw.lowercased()
            guard normalized.hasPrefix("bonjour:") || normalized.hasPrefix("recent:bonjour:") else {
                continue
            }
            if let routeToken = appleMobileCanonicalBonjourRouteToken(from: raw) {
                tokens.insert(routeToken)
            }
        }
        return tokens
    }

    private func appleMobileCanonicalBonjourRouteToken(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let lowercased = raw.lowercased()
        let payload: String
        if lowercased.hasPrefix("recent:bonjour:") {
            payload = String(raw.dropFirst("recent:bonjour:".count))
        } else if lowercased.hasPrefix("bonjour:") {
            payload = String(raw.dropFirst("bonjour:".count))
        } else {
            return nil
        }

        let parts = payload.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawServiceName = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawServiceName.isEmpty else {
            return nil
        }

        let rawDomain = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            : "local."
        let domain: String
        if rawDomain.isEmpty {
            domain = "local."
        } else if rawDomain.hasSuffix(".") {
            domain = rawDomain.lowercased()
        } else {
            domain = "\(rawDomain.lowercased())."
        }

        return "bonjour:\(rawServiceName.lowercased())@\(domain)"
    }

    private func appleMobileStrongPresentationTokens(for device: OnlineDevice) -> Set<String> {
        appleMobileStrongPresentationTokens(for: device, trustedGroups: trustedRecordsForUI)
    }

    private func appleMobileStrongPresentationTokens(
        for device: OnlineDevice,
        trustedGroups: [TrustRecordDisplayGroup]
    ) -> Set<String> {
        var tokens = appleMobilePresentationRouteTokens(for: device)

        if let identityToken = appleMobilePresentationIdentityToken(from: device.uniqueIdentifier) {
            tokens.insert(identityToken)
        }
        for routeIdentifier in device.routeIdentifiers {
            if let identityToken = appleMobilePresentationIdentityToken(from: routeIdentifier) {
                tokens.insert(identityToken)
            }
        }

        let trustRecords = trustedGroups.map(\.displayRecord)
        if let trustRecord = unifiedDeviceManager.resolvedTrustRecord(for: device, among: trustRecords) {
            let stableDeviceId = trustRecord.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !stableDeviceId.isEmpty {
                tokens.insert("trust:\(stableDeviceId)")
            }
        }

        return tokens
    }

    private func appleMobilePresentationIdentityToken(from raw: String?) -> String? {
        guard var normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return nil
        }
        if normalized.hasPrefix("recent:") {
            normalized = String(normalized.dropFirst("recent:".count))
        }

        if normalized.hasPrefix("id:") {
            let payload = String(normalized.dropFirst("id:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { return nil }
            if let uuid = UUID(uuidString: payload) {
                return "id:\(uuid.uuidString.lowercased())"
            }
            return payload.count >= 8 ? "id:\(payload)" : nil
        }

        if normalized.hasPrefix("fp:") {
            let payload = String(normalized.dropFirst("fp:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return payload.count >= 16 ? "fp:\(payload)" : nil
        }

        if let uuid = UUID(uuidString: normalized) {
            return "id:\(uuid.uuidString.lowercased())"
        }

        return nil
    }

    private func preferredOnlinePresentationOrder(
        _ lhs: OnlineDevice,
        _ rhs: OnlineDevice,
        hasResolvedConnectableControlRouteByDeviceId: [UUID: Bool]
    ) -> Bool {
        let lhsConnectable = hasResolvedConnectableControlRouteByDeviceId[lhs.id] ?? false
        let rhsConnectable = hasResolvedConnectableControlRouteByDeviceId[rhs.id] ?? false
        if lhsConnectable != rhsConnectable {
            return lhsConnectable
        }
        if lhs.isConnectable != rhs.isConnectable {
            return lhs.isConnectable
        }
        if lhs.lastSeen != rhs.lastSeen {
            return lhs.lastSeen > rhs.lastSeen
        }
        return lhs.name < rhs.name
    }

    private func cachedCanConnect(_ device: OnlineDevice) -> Bool {
        cachedPresentationSnapshot.hasResolvedConnectableControlRouteByDeviceId[device.id]
            ?? unifiedDeviceManager.hasResolvedConnectableControlRoute(for: device)
    }

    private var displayedTrustedRecordsForUI: [TrustedRecordCardPresentation] {
        cachedPresentationSnapshot.displayedTrustedRecords
    }

    private func hasVisibleOnlineRepresentation(for group: TrustRecordDisplayGroup) -> Bool {
        let records = trustedLookupRecords(for: group)
        let representedDevices = connectedOnlineDevicesNonLocal
            + activeOnlineDevicesNonLocal
            + groupedRecentlyConnectedDevices
        return representedDevices.contains { device in
            unifiedDeviceManager.resolvedTrustRecord(for: device, among: records) != nil
        }
    }

    private func hasVisibleOnlineRepresentation(
        for group: TrustRecordDisplayGroup,
        representedDevices: [OnlineDevice]
    ) -> Bool {
        let records = trustedLookupRecords(for: group)
        return representedDevices.contains { device in
            unifiedDeviceManager.resolvedTrustRecord(for: device, among: records) != nil
        }
    }

    private var trustedBonjourRefreshKey: String {
        cachedTrustedBonjourRefreshKey
    }

    private func buildTrustedBonjourRefreshKey(
        trustedGroups: [TrustRecordDisplayGroup],
        onlineDevices: [OnlineDevice]
    ) -> String {
        let trustIds = trustedGroups.map(\.id).joined(separator: "|")
        let trustEndpoints = trustedGroups
            .flatMap { trustedLookupRecords(for: $0) }
            .flatMap { record in
                [record.deviceId, record.currentDeviceId] + record.knownDeviceIds + record.capabilities
            }
            .joined(separator: "|")
        let onlineSummary = onlineDevices
            .filter { !$0.isLocalDevice }
            .map {
                "\($0.uniqueIdentifier):\($0.connectionStatus.rawValue):\($0.platformName ?? ""):\($0.osVersion ?? ""):\($0.modelName ?? ""):\($0.chip ?? "")"
            }
            .sorted()
            .joined(separator: "|")
        let discoverySummary = unifiedDeviceManager.discoveryMetadataSummary
        return "\(selectedConnectionMode.id)|\(trustIds)|\(trustEndpoints)|\(onlineSummary)|\(discoverySummary)|scan:\(unifiedDeviceManager.isScanning)"
    }

    private var smokeOnlineDeviceSnapshotKey: String {
        guard isMacOnlineIPadSmokeClient else { return "" }
        let deviceSummary = unifiedDeviceManager.onlineDevices
            .filter { !$0.isLocalDevice }
            .map { device in
                [
                    device.uniqueIdentifier,
                    device.name,
                    effectiveConnectionStatus(for: device).rawValue,
                    device.platformName ?? "",
                    device.modelName ?? "",
                    device.ipv4 ?? "",
                    device.ipv6 ?? "",
                    device.sources.map(\.rawValue).sorted().joined(separator: ","),
                    device.routeIdentifiers.joined(separator: ","),
                    device.services.joined(separator: ","),
                    device.portMap
                        .map { "\($0.key)=\($0.value)" }
                        .sorted()
                        .joined(separator: ",")
                ].joined(separator: "|")
            }
            .sorted()
            .joined(separator: "\n")
        let presenceSummary = presenceService.activeConnections
            .map {
                [
                    $0.id,
                    $0.displayName,
                    $0.address ?? "",
                    $0.cryptoKind,
                    $0.suite
                ].joined(separator: "|")
            }
            .sorted()
            .joined(separator: "\n")
        return "\(deviceSummary)\npresence:\(presenceSummary)"
    }

    private var isMacOnlineIPadSmokeClient: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "mac-online-ipad-client"
    }

    private var smokeStatusURL: URL? {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private struct MacOnlineIPadSmokeVisibleRow {
        let device: OnlineDevice
        let surface: String
    }

    private func appendMacOnlineIPadSmokeRowsIfNeeded() {
        guard isMacOnlineIPadSmokeClient,
              let statusURL = smokeStatusURL else {
            return
        }

        if !didAppendMacOnlineIPadSmokeBoot {
            didAppendMacOnlineIPadSmokeBoot = true
            appendSmokeStatusLine(
                [
                    "boot",
                    "role=mac-online-ipad-client",
                    "process=SkyBridgeCompassApp",
                    "uiRole=root-container",
                    "source=app",
                    "pid=\(ProcessInfo.processInfo.processIdentifier)"
                ].joined(separator: " "),
                to: statusURL
            )
        }

        let rows = macOnlineIPadSmokeVisibleRows()
        guard !rows.isEmpty else { return }

        for row in rows {
            appendSmokeStatusLine(smokeOnlineDeviceStatusLine(for: row.device, surface: row.surface), to: statusURL)
        }
    }

    private func macOnlineIPadSmokeVisibleRows() -> [MacOnlineIPadSmokeVisibleRow] {
        var rows: [MacOnlineIPadSmokeVisibleRow] = []
        for device in connectedOnlineDevicesNonLocal where appleMobilePresentationFamily(for: device) != nil {
            rows.append(MacOnlineIPadSmokeVisibleRow(device: device, surface: "connected"))
        }
        for device in groupedRecentlyConnectedDevices where appleMobilePresentationFamily(for: device) != nil {
            rows.append(MacOnlineIPadSmokeVisibleRow(device: device, surface: "recent"))
        }
        for device in filteredOnlineDevicesNonLocal where appleMobilePresentationFamily(for: device) != nil {
            rows.append(MacOnlineIPadSmokeVisibleRow(device: device, surface: "online"))
        }
        return rows
    }

    private func smokeOnlineDeviceStatusLine(for device: OnlineDevice, surface: String) -> String {
        let connectableCandidates = unifiedDeviceManager.resolvedConnectableDiscoveredCandidates(
            for: device,
            limit: 6
        )
        let hasControlEndpoint = unifiedDeviceManager.hasResolvedConnectableControlRoute(for: device)
        let preferredCandidate = connectableCandidates.first
        let bonjourServiceName = preferredCandidate
            .flatMap(smokeBonjourServiceName)
            ?? smokeBonjourServiceName(from: device)
            ?? "-"
        let endpointHost = preferredCandidate?.ipv4 ?? preferredCandidate?.ipv6 ?? device.ipv4 ?? device.ipv6 ?? "-"
        let endpointPort = preferredCandidate?.portMap["_skybridge._tcp"]
            ?? device.portMap["_skybridge._tcp"]
            ?? 0
        let service = (preferredCandidate?.services ?? device.services).contains("_skybridge._tcp")
            ? "_skybridge._tcp"
            : "-"
        let effectiveStatus = effectiveConnectionStatus(for: device)
        let status = effectiveStatus == .connected
            ? "connected"
            : (effectiveStatus == .online ? "online" : "offline")
        let buttonEnabled = effectiveStatus == .online && hasControlEndpoint
        let disabledReason: String = {
            if buttonEnabled { return "-" }
            if effectiveStatus != .online { return "not_online" }
            return "no_resolved_control_route"
        }()
        let matchStrength = smokeMatchStrength(for: device)
        let resolvedSource = smokeResolvedSource(for: device)
        let protocolIdentity = smokeProtocolIdentity(for: device)
        let routeIdentifier = preferredSmokeRouteIdentifier(for: device) ?? "-"
        let targetFamily = appleMobilePresentationFamily(for: device) ?? "device"
        let fields = [
            "mac-online-device-ui",
            "targetFamily=\(targetFamily)",
            "visible=1",
            "source=OnlineDeviceCard",
            "evidenceSource=app-smoke",
            "surface=\(surface)",
            "status=\(status)",
            "buttonEnabled=\(buttonEnabled ? 1 : 0)",
            "disabledReason=\(disabledReason)",
            "matchStrength=\(matchStrength)",
            "resolvedSource=\(resolvedSource)",
            "controlEndpoint=\(hasControlEndpoint ? 1 : 0)",
            "candidateCount=\(connectableCandidates.count)",
            "identityKey=\(smokeFieldValue(cachedPresentationIdentityKey(for: device)))",
            "targetDeviceId=\(smokeFieldValue(protocolIdentity.authorityDeviceId ?? "-"))",
            "p2pDeviceId=\(smokeFieldValue(protocolIdentity.protocolDeviceId ?? "-"))",
            "pubKeyFP=\(smokeFieldValue(protocolIdentity.pubKeyFP ?? "-"))",
            "routeIdentifier=\(smokeFieldValue(routeIdentifier))",
            "dedupeKey=\(smokePhysicalDedupeKey(for: device))",
            "device=\(smokeFieldValue(device.name))",
            "platform=\(smokeFieldValue(device.platformName ?? "-"))",
            "model=\(smokeFieldValue(device.modelName ?? "-"))",
            "service=\(service)",
            "bonjourServiceName=\(smokeFieldValue(bonjourServiceName))",
            "endpointHost=\(smokeFieldValue(endpointHost))",
            "endpointPort=\(endpointPort)"
        ]
        return fields.joined(separator: " ")
    }

    private func smokeProtocolIdentity(
        for device: OnlineDevice
    ) -> (authorityDeviceId: String?, protocolDeviceId: String?, pubKeyFP: String?) {
        let liveProtocolIdentity = resolvedLiveProtocolIdentity(for: device)
        let trustRecords = trustedRecordsForUI.flatMap { [$0.displayRecord] + $0.relatedRecords }
        if let trustRecord = unifiedDeviceManager.resolvedTrustRecord(for: device, among: trustRecords) {
            let authorityDeviceId = liveProtocolIdentity.deviceId ?? nonEmptySmokeIdentity(trustRecord.deviceId)
            let protocolDeviceId = liveProtocolIdentity.deviceId
                ?? nonEmptySmokeIdentity(trustRecord.currentDeviceId)
                ?? authorityDeviceId
            let pubKeyFP = liveProtocolIdentity.pubKeyFP ?? nonEmptySmokeIdentity(trustRecord.pubKeyFP)
            return (authorityDeviceId, protocolDeviceId, pubKeyFP)
        }

        let deviceId = liveProtocolIdentity.deviceId
            ?? stableSmokeDeviceId(from: device.uniqueIdentifier)
            ?? device.routeIdentifiers.lazy.compactMap { stableSmokeDeviceId(from: $0) }.first
        let pubKeyFP = liveProtocolIdentity.pubKeyFP
            ?? fingerprintSmokeIdentity(from: device.uniqueIdentifier)
            ?? device.routeIdentifiers.lazy.compactMap { fingerprintSmokeIdentity(from: $0) }.first
        return (deviceId, deviceId, pubKeyFP)
    }

    private func resolvedPresentationIdentityKey(for device: OnlineDevice) -> String {
        computeResolvedPresentationIdentityKey(for: device, trustedGroups: trustedRecordsForUI)
    }

    private func cachedPresentationIdentityKey(for device: OnlineDevice) -> String {
        cachedPresentationSnapshot.accessibilityIdentityByDeviceId[device.id]
            ?? computeResolvedPresentationIdentityKey(for: device, trustedGroups: trustedRecordsForUI)
    }

    private func computeResolvedPresentationIdentityKey(
        for device: OnlineDevice,
        trustedGroups: [TrustRecordDisplayGroup]
    ) -> String {
        let trustRecords = trustedGroups.flatMap { [$0.displayRecord] + $0.relatedRecords }
        let liveProtocolIdentity = resolvedLiveProtocolIdentity(for: device)
        let protocolIdentity: (authorityDeviceId: String?, protocolDeviceId: String?)
        if let trustRecord = unifiedDeviceManager.resolvedTrustRecord(for: device, among: trustRecords) {
            let authorityDeviceId = liveProtocolIdentity.deviceId ?? nonEmptySmokeIdentity(trustRecord.deviceId)
            let protocolDeviceId = liveProtocolIdentity.deviceId
                ?? nonEmptySmokeIdentity(trustRecord.currentDeviceId)
                ?? authorityDeviceId
            protocolIdentity = (authorityDeviceId, protocolDeviceId)
        } else {
            let deviceId = liveProtocolIdentity.deviceId
                ?? stableSmokeDeviceId(from: device.uniqueIdentifier)
                ?? device.routeIdentifiers.lazy.compactMap { stableSmokeDeviceId(from: $0) }.first
            protocolIdentity = (deviceId, deviceId)
        }

        if let stableDeviceId = protocolIdentity.protocolDeviceId ?? protocolIdentity.authorityDeviceId {
            return stableIdentityKey(for: stableDeviceId)
        }
        return device.uniqueIdentifier
    }

    private func resolvedLiveProtocolIdentity(for device: OnlineDevice) -> (deviceId: String?, pubKeyFP: String?) {
        let candidates = unifiedDeviceManager.resolvedConnectableDiscoveredCandidates(for: device, limit: 6)
            + unifiedDeviceManager.resolvedDiscoveredCandidates(for: device, limit: 6)
        for candidate in candidates {
            if let deviceId = nonEmptySmokeIdentity(candidate.deviceId) {
                let pubKeyFP = nonEmptySmokeIdentity(candidate.pubKeyFP)
                return (stableIdentityPayload(from: deviceId), pubKeyFP)
            }
        }
        return (nil, nil)
    }

    private func stableIdentityKey(for stableDeviceId: String) -> String {
        let payload = stableIdentityPayload(from: stableDeviceId)
        if stableDeviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("id:") {
            return stableDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "id:\(payload)"
    }

    private func stableIdentityPayload(from raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("id:") {
            value = String(value.dropFirst("id:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private func preferredSmokeRouteIdentifier(for device: OnlineDevice) -> String? {
        for routeIdentifier in device.routeIdentifiers {
            let trimmed = routeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let uniqueIdentifier = device.uniqueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return uniqueIdentifier.isEmpty ? nil : uniqueIdentifier
    }

    private func nonEmptySmokeIdentity(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private func stableSmokeDeviceId(from raw: String?) -> String? {
        guard var value = nonEmptySmokeIdentity(raw) else { return nil }
        if value.lowercased().hasPrefix("recent:") {
            value = String(value.dropFirst("recent:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard value.lowercased().hasPrefix("id:") else { return nil }
        let payload = String(value.dropFirst("id:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
    }

    private func fingerprintSmokeIdentity(from raw: String?) -> String? {
        guard var value = nonEmptySmokeIdentity(raw) else { return nil }
        if value.lowercased().hasPrefix("recent:") {
            value = String(value.dropFirst("recent:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard value.lowercased().hasPrefix("fp:") else { return nil }
        let payload = String(value.dropFirst("fp:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
    }

    private func appendSmokeStatusLine(_ line: String, to statusURL: URL) {
        let rendered = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
        let data = Data(rendered.utf8)
        MacSmokeStatusFailClosedWriter.append(
            data,
            to: statusURL,
            context: "mac-online-ipad device-management smoke"
        )
    }

    private func appendMacOnlineIPadConnectAppActionIfNeeded(
        result: String,
        device: OnlineDevice,
        error: Error? = nil
    ) {
        guard isMacOnlineIPadSmokeClient,
              let statusURL = smokeStatusURL else {
            return
        }

        let protocolIdentity = smokeProtocolIdentity(for: device)
        let targetFamily = appleMobilePresentationFamily(for: device) ?? "device"
        var fields = [
            "mac-online-connect-app",
            "action=button",
            "targetFamily=\(targetFamily)",
            "result=\(smokeFieldValue(result))",
            "source=OnlineDeviceCard",
            "evidenceSource=app-action",
            "identityKey=\(smokeFieldValue(cachedPresentationIdentityKey(for: device)))",
            "targetDeviceId=\(smokeFieldValue(protocolIdentity.authorityDeviceId ?? "-"))",
            "p2pDeviceId=\(smokeFieldValue(protocolIdentity.protocolDeviceId ?? "-"))",
            "pubKeyFP=\(smokeFieldValue(protocolIdentity.pubKeyFP ?? "-"))",
            "device=\(smokeFieldValue(device.name))"
        ]
        if let error {
            fields.append("error=\(smokeFieldValue(error.localizedDescription))")
        }
        appendSmokeStatusLine(fields.joined(separator: " "), to: statusURL)
    }

    private func smokeResolvedSource(for device: OnlineDevice) -> String {
        if device.sources.contains(.skybridgeBonjour) { return "skybridgeBonjour" }
        if device.sources.contains(.skybridgeP2P) { return "skybridgeP2P" }
        if device.sources.contains(.skybridgeUSB) { return "skybridgeUSB" }
        if device.sources.contains(.skybridgeCloud) { return "skybridgeCloud" }
        return "unknown"
    }

    private func smokeMatchStrength(for device: OnlineDevice) -> String {
        if device.uniqueIdentifier.hasPrefix("id:") || device.uniqueIdentifier.hasPrefix("fp:") {
            return "stable-id"
        }
        if device.uniqueIdentifier.hasPrefix("bonjour:") || device.uniqueIdentifier.hasPrefix("ip:") {
            return "endpoint"
        }
        return "name"
    }

    private func smokePhysicalDedupeKey(for device: OnlineDevice) -> String {
        let family = appleMobilePresentationFamily(for: device) ?? "device"
        let modelFamily = normalizedSmokeToken(device.modelName ?? "").hasPrefix("ipad") ? "ipad" : family
        let name = normalizedSmokeToken(device.name)
        let stable = [name, modelFamily]
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return smokeFieldValue(stable.isEmpty ? device.uniqueIdentifier : stable)
    }

    private func smokeBonjourServiceName(_ candidate: DiscoveredDevice) -> String? {
        smokeBonjourServiceName(from: candidate.uniqueIdentifier)
            ?? candidate.routeIdentifiers.compactMap(smokeBonjourServiceName).first
    }

    private func smokeBonjourServiceName(from device: OnlineDevice) -> String? {
        smokeBonjourServiceName(from: device.uniqueIdentifier)
            ?? device.routeIdentifiers.compactMap(smokeBonjourServiceName).first
    }

    private func smokeBonjourServiceName(from identifier: String?) -> String? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return nil
        }
        let prefixes = ["recent:bonjour:", "bonjour:"]
        guard let prefix = prefixes.first(where: { identifier.lowercased().hasPrefix($0) }) else {
            return nil
        }
        let payload = String(identifier.dropFirst(prefix.count))
        let name = payload.split(separator: "@", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    private func normalizedSmokeToken(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    private func smokeFieldValue(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".:-_"))
        let scalars = raw.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        let sanitized = scalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar).description : "_"
        }.joined()
        return sanitized.isEmpty ? "-" : sanitized
    }

    private func preferredRecentDisplayDevice(_ lhs: OnlineDevice, _ rhs: OnlineDevice) -> OnlineDevice {
        if statusPriority(lhs.connectionStatus) != statusPriority(rhs.connectionStatus) {
            return statusPriority(lhs.connectionStatus) > statusPriority(rhs.connectionStatus) ? lhs : rhs
        }

        if lhs.isConnectable != rhs.isConnectable {
            return lhs.isConnectable ? lhs : rhs
        }

        let lhsLooksLikeIP = isIPAddressLikeLabel(lhs.name)
        let rhsLooksLikeIP = isIPAddressLikeLabel(rhs.name)
        if lhsLooksLikeIP != rhsLooksLikeIP {
            return lhsLooksLikeIP ? rhs : lhs
        }

        let lhsConnected = lhs.lastConnectedAt ?? .distantPast
        let rhsConnected = rhs.lastConnectedAt ?? .distantPast
        if lhsConnected != rhsConnected {
            return lhsConnected > rhsConnected ? lhs : rhs
        }

        if lhs.lastSeen != rhs.lastSeen {
            return lhs.lastSeen > rhs.lastSeen ? lhs : rhs
        }

        return lhs.name.count >= rhs.name.count ? lhs : rhs
    }

    private func isIPAddressLikeLabel(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains(":") { return true }
        let parts = trimmed.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0) != nil }
    }

    private func statusPriority(_ status: OnlineDeviceStatus) -> Int {
        switch status {
        case .connected:
            return 3
        case .online:
            return 2
        case .offline:
            return 1
        }
    }

 // MARK: - 2️⃣ 动态二维码

    private var qrCodeSection: some View {
        VStack(spacing: 20) {
            InfoBanner(
                icon: "qrcode",
                title: LocalizationManager.shared.localizedString("discovery.qrCode.title"),
                description: LocalizationManager.shared.localizedString("discovery.qrCode.description"),
                color: .blue
            )

            HStack(spacing: 32) {
 // 左侧：生成二维码
                VStack(spacing: 16) {
                    Text(LocalizationManager.shared.localizedString("discovery.qrCode.thisDevice"))
                        .font(.title3)
                        .fontWeight(.semibold)

                    if let qrData = crossNetworkManager.qrCodeData {
                        QRCodeView(data: qrData)
                            .frame(width: 280, height: 280)
                            .background(Color.white)
                            .cornerRadius(12)
                            .shadow(color: .black.opacity(0.1), radius: 4)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.white, Color.blue)
                                    .padding(10)
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .help("点击二维码立即刷新")
                            .onTapGesture {
                                Task { await generateDynamicQRCodeFromUI(trigger: "tap_qr_refresh") }
                            }

                        Text("扫描此二维码，点击二维码可立即刷新")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if case .waiting = crossNetworkManager.connectionStatus {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(LocalizationManager.shared.localizedString("discovery.qrCode.waiting"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Button(LocalizationManager.shared.localizedString("discovery.qrCode.regenerate")) {
                            Task { await generateDynamicQRCodeFromUI(trigger: "regenerate_qr") }
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button(action: {
                            Task { await generateDynamicQRCodeFromUI(trigger: "generate_qr") }
                        }) {
                            VStack(spacing: 12) {
                                Image(systemName: "qrcode")
                                    .font(.system(size: 48))
                                    .foregroundColor(.blue)
                                Text(LocalizationManager.shared.localizedString("discovery.qrCode.generate"))
                                    .font(.headline)
                            }
                            .frame(width: 280, height: 280)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }

                }

                Divider()

 // 右侧：扫描二维码
                VStack(spacing: 16) {
                    Text(LocalizationManager.shared.localizedString("discovery.qrCode.otherDevice"))
                        .font(.title3)
                        .fontWeight(.semibold)

                    Button(action: {
 // 打开二维码扫描弹窗
                        showingScanner = true
                    }) {
                        VStack(spacing: 12) {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 48))
                                .foregroundColor(.green)

                            Text(LocalizationManager.shared.localizedString("discovery.qrCode.scanButton"))
                                .font(.headline)

                            Text(LocalizationManager.shared.localizedString("discovery.qrCode.cameraPrompt"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(width: 280, height: 280)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 20)
 // 二维码扫描弹窗，集成统一扫描器并回调处理连接逻辑。
            .sheet(isPresented: $showingScanner) {
                QRCodeScannerView(
                    onResult: { result in
 // 兼容两种跨网二维码格式：
 // - skybridge://connect/<base64>
 // - skybridge://connect?data=<base64>
                        if isCrossNetworkConnectLink(result) {
                            let scannedContent = result
                            showingScanner = false
                            Task { await connectScannedQRCodeFromUI(scannedContent, trigger: "qr_scanner_sheet") }
                        } else {
 // 不识别的二维码内容
                            presentScannerError(LocalizationManager.shared.localizedString("discovery.qrCode.error.unrecognized"))
                            showingScanner = false
                        }
                    },
                    onError: { message in
                        // 扫描器错误回调
                        presentScannerError(message)
                        showingScanner = false
                    }
                )
                .frame(minWidth: 500, minHeight: 320)
            }
 // 错误提示弹窗，绑定动态状态以便关闭后清空错误。
            .alert(
                LocalizationManager.shared.localizedString("discovery.qrCode.error.title"),
                isPresented: Binding(
                    get: { scannerErrorMessage != nil },
                    set: { newValue in
 // 当弹窗被关闭时清空错误信息
                        if !newValue { scannerErrorMessage = nil }
                    }
                )
            ) {
                Button(LocalizationManager.shared.localizedString("discovery.qrCode.error.ok")) { scannerErrorMessage = nil }
            } message: {
                Text(scannerErrorMessage ?? "")
            }
        }
    }

 // MARK: - 3️⃣ iCloud 设备链（统一设备显示）

 // MARK: - View Models
    @StateObject private var deviceChainViewModel: CloudDeviceListViewModel

    public init(deviceChainViewModel: CloudDeviceListViewModel = CloudDeviceListViewModel()) {
        _deviceChainViewModel = StateObject(wrappedValue: deviceChainViewModel)
    }

 // MARK: - 3️⃣ iCloud 设备链（统一设备显示）

    private var cloudLinkSection: some View {
        VStack(spacing: 20) {
            InfoBanner(
                icon: "icloud.fill",
                title: LocalizationManager.shared.localizedString("discovery.icloud.title"),
                description: LocalizationManager.shared.localizedString("discovery.icloud.description"),
                color: .purple
            )

 // 状态指示器
            HStack(spacing: 12) {
                statusIndicator

                Spacer()

                Text(deviceChainViewModel.accountStatusDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(LocalizationManager.shared.localizedString("discovery.icloud.refresh")) {
                    Task {
                        await deviceChainViewModel.refreshDevices()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(deviceChainViewModel.isLoading)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)

            if deviceChainViewModel.authorizedDevices.isEmpty {
                VStack(spacing: 16) {
                    emptyStateView(
                        icon: "magnifyingglass",
                        title: LocalizationManager.shared.localizedString("discovery.icloud.noDevices.title"),
                        message: LocalizationManager.shared.localizedString("discovery.icloud.noDevices.message")
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "icloud.fill")
                            .foregroundColor(.purple)
                        Text("\(LocalizationManager.shared.localizedString("discovery.icloud.authorizedDevices")) (\(deviceChainViewModel.authorizedDevices.count))")
                            .font(.headline)
                    }

                    ForEach(deviceChainViewModel.authorizedDevices) { device in
                        CloudDeviceRow(
                            device: mapToCloudDevice(device),
                            currentDeviceId: deviceChainViewModel.currentDeviceId,
                            onConnect: {
                                connectToCloudDevice(device)
                            }
                        )
                    }
                }
            }
        }
    }

 /// 状态指示器
    private var statusIndicator: some View {
        HStack(spacing: 8) {
            if deviceChainViewModel.isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                Text(LocalizationManager.shared.localizedString("discovery.icloud.status.syncing"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(LocalizationManager.shared.localizedString("discovery.icloud.status.synced"))
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
    }

 // MARK: - Cloud Device Row

    struct CloudDeviceRow: View {
        let device: CloudDevice
        let currentDeviceId: String?
        let onConnect: () -> Void
        @EnvironmentObject var themeConfiguration: ThemeConfiguration

        var body: some View {
            HStack(spacing: 16) {
 // 设备图标
                Image(systemName: deviceIcon)
                    .font(.system(size: 32))
                    .foregroundColor(device.isOnline ? .blue : .gray)
                    .frame(width: 50, height: 50)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(10)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(device.name)
                            .font(.headline)

                        if let currentId = currentDeviceId, device.id == currentId {
                            Text(LocalizationManager.shared.localizedString("discovery.device.thisDevice"))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.8))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    Text(device.deviceModel)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(device.isOnline ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)
                        Text(device.isOnline ? LocalizationManager.shared.localizedString("discovery.device.status.online") : LocalizationManager.shared.localizedString("discovery.device.status.offline"))
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Text("•")
                            .foregroundColor(.secondary)

                        Text(timeAgoText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if currentDeviceId == nil || device.id != currentDeviceId {
                    Button(LocalizationManager.shared.localizedString("discovery.action.connect")) {
                        onConnect()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!device.isOnline)
                }
            }
            .padding(16)
            .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(themeConfiguration.borderColor, lineWidth: 1)
            )
        }

        private var deviceIcon: String {
            switch device.type {
            case .mac: return "laptopcomputer"
            case .iPhone: return "iphone"
            case .iPad: return "ipad"
            }
        }

        private var timeAgoText: String {
            let interval = Date().timeIntervalSince(device.lastSeen)
            if interval < 60 {
                return LocalizationManager.shared.localizedString("discovery.time.justNow")
            } else if interval < 3600 {
                return String(format: LocalizationManager.shared.localizedString("discovery.time.minutesAgo"), Int(interval / 60))
            } else if interval < 86400 {
                return String(format: LocalizationManager.shared.localizedString("discovery.time.hoursAgo"), Int(interval / 3600))
            } else {
                return String(format: LocalizationManager.shared.localizedString("discovery.time.daysAgo"), Int(interval / 86400))
            }
        }
    }

 // MARK: - 在线设备卡片(新)

    struct OnlineDeviceCard: View {
        let device: OnlineDevice
        let accessibilityIdentity: String?
        let isConnecting: Bool
        let canConnect: Bool
        let onConnect: () -> Void
        @EnvironmentObject var themeConfiguration: ThemeConfiguration
        @StateObject private var settingsManager = SettingsManager.shared
        @ObservedObject private var presenceService = ConnectionPresenceService.shared

        init(
            device: OnlineDevice,
            accessibilityIdentity: String? = nil,
            isConnecting: Bool = false,
            canConnect: Bool = true,
            onConnect: @escaping () -> Void
        ) {
            self.device = device
            self.accessibilityIdentity = accessibilityIdentity
            self.isConnecting = isConnecting
            self.canConnect = canConnect
            self.onConnect = onConnect
        }

        var body: some View {
            HStack(spacing: settingsManager.compactMode ? 10 : 16) {
 // 设备图标
                Image(systemName: deviceIcon)
                    .font(.system(size: settingsManager.compactMode ? 24 : 32))
                    .foregroundColor(statusColor)
                    .frame(width: settingsManager.compactMode ? 40 : 50, height: settingsManager.compactMode ? 40 : 50)
                    .background(statusColor.opacity(0.1))
                    .cornerRadius(10)

                VStack(alignment: .leading, spacing: settingsManager.compactMode ? 4 : 6) {
                    HStack(spacing: 8) {
                        Text(device.name)
                            .font(settingsManager.compactMode ? .subheadline : .headline)

 // 本机标签
                        if device.isLocalDevice {
                            Text(LocalizationManager.shared.localizedString("discovery.device.thisDevice"))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.8))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

 // 已授权标签
                        if device.isAuthorized {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }

                    if settingsManager.showDeviceDetails, let ipv4 = device.ipv4 {
                        Text("IP: \(ipv4)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

 // 连接类型标签
                    if settingsManager.showDeviceDetails && !device.connectionTypes.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(device.connectionTypes.sorted(by: { $0.rawValue < $1.rawValue })), id: \.self) { type in
                                HStack(spacing: 3) {
                                    Image(systemName: type.iconName)
                                        .font(.system(size: 9))
                                    Text(type.rawValue)
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(connectionTypeColor(for: type))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }

                    if settingsManager.showConnectionStats || effectiveConnectionStatus == .connected {
                        Text(statusText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if settingsManager.showDeviceRSSI, let signal = device.signalStrength {
                        Text("RSSI: \(Int(signal))%")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if settingsManager.showConnectionStats,
                       let detail = connectionDetailText {
                        Text(detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // 连接按钮(仅对非本机在线设备显示)
                if !device.isLocalDevice && effectiveConnectionStatus == .online && canConnect {
                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        connectButton
                    }
                }
            }
            .padding(settingsManager.compactMode ? 10 : 16)
            .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(device.isLocalDevice ? Color.blue : themeConfiguration.borderColor, lineWidth: device.isLocalDevice ? 2 : 1)
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("skybridge-online-device-row-\(accessibilityIdentifierToken(for: canonicalAccessibilityIdentity(for: effectiveAccessibilityIdentity)))")
            .accessibilityLabel(Text(device.name))
            .accessibilityValue(Text(statusText))
        }

        private var connectButton: some View {
            let buttonIdentity = canonicalAccessibilityIdentity(for: effectiveAccessibilityIdentity)
            let buttonIdentifier = "skybridge-online-device-connect-button-\(accessibilityIdentifierToken(for: buttonIdentity))"
            let connectLabel = LocalizationManager.shared.localizedString("discovery.action.connect")
            return Button(connectLabel) {
                onConnect()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(buttonIdentifier)
            .accessibilityLabel(Text(connectLabel))
            .accessibilityHint(Text(device.name))
            .accessibilityAction {
                onConnect()
            }
        }

        private var effectiveAccessibilityIdentity: String {
            let candidate = accessibilityIdentity?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let candidate, !candidate.isEmpty {
                return candidate
            }
            return device.uniqueIdentifier
        }

        private var resolvedCryptoKind: String? {
            matchingPresenceConnection?.cryptoKind ?? device.lastCryptoKind
        }

        private var resolvedCryptoSuite: String? {
            matchingPresenceConnection?.suite ?? device.lastCryptoSuite
        }

        private var effectiveConnectionStatus: OnlineDeviceStatus {
            matchingPresenceConnection == nil ? device.connectionStatus : .connected
        }

        private var resolvedGuardStatus: String? {
            if device.isLocalDevice { return nil }
            if let guardStatus = device.guardStatus,
               !guardStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return guardStatus
            }
            return effectiveConnectionStatus == .connected ? "守护中" : nil
        }

        private var statusText: String {
            if device.isLocalDevice {
                return "在线"
            }
            guard effectiveConnectionStatus == .connected else {
                return effectiveConnectionStatus.rawValue
            }
            return ConnectionCryptoPresentation.connectedStatusTextWithPolicyFallback(
                kind: resolvedCryptoKind,
                suite: resolvedCryptoSuite,
                baseConnectedText: effectiveConnectionStatus.rawValue,
                compatibilityModeEnabled: settingsManager.enableCompatibilityMode
            )
        }

        private var connectionDetailText: String? {
            guard effectiveConnectionStatus == .connected else { return nil }
            return ConnectionCryptoPresentation.detailText(
                kind: resolvedCryptoKind,
                suite: resolvedCryptoSuite,
                guardStatus: resolvedGuardStatus
            )
        }

        private var matchingPresenceConnection: ConnectionPresenceService.ActiveConnection? {
            guard #available(macOS 14.0, iOS 17.0, *) else { return nil }

            let activeConnections = presenceService.activeConnections
            guard !activeConnections.isEmpty else { return nil }

            if device.isLocalDevice {
                return nil
            }

            let deviceTokens = presenceMatchTokens(
                identifier: device.uniqueIdentifier,
                displayName: device.name,
                addresses: [device.ipv4, device.ipv6]
            )
            if !deviceTokens.isEmpty {
                let matches = activeConnections.filter { connection in
                    let connectionTokens = presenceMatchTokens(
                        identifier: connection.id,
                        displayName: connection.displayName,
                        addresses: [connection.address]
                    )
                    return !deviceTokens.isDisjoint(with: connectionTokens)
                }
                if let newestMatch = matches.max(by: { $0.connectedAt < $1.connectedAt }) {
                    return newestMatch
                }
            }

            return nil
        }

        private func normalizedAddress(_ raw: String?) -> String? {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            var value = raw
            if value.hasPrefix("[") && value.hasSuffix("]") {
                value = String(value.dropFirst().dropLast())
            }
            if let percent = value.firstIndex(of: "%") {
                value = String(value[..<percent])
            }
            return value.lowercased()
        }

        private func normalizedToken(_ raw: String) -> String {
            raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        private func canonicalAccessibilityIdentity(for identity: String) -> String {
            let normalized = normalizedToken(identity)
            guard !normalized.isEmpty else { return identity }
            if normalized.hasPrefix("id:") {
                let payload = String(normalized.dropFirst("id:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return payload.isEmpty ? normalized : "id:\(payload)"
            }
            if UUID(uuidString: normalized) != nil {
                return "id:\(normalized)"
            }
            return normalized
        }

        private func presenceMatchTokens(
            identifier: String?,
            displayName: String?,
            addresses: [String?]
        ) -> Set<String> {
            var tokens = Set<String>()

            func addToken(_ raw: String?) {
                guard let raw else { return }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                tokens.insert(trimmed.lowercased())
            }

            func addIdentifier(_ raw: String?) {
                guard let raw else { return }
                let normalized = normalizedToken(raw)
                guard !normalized.isEmpty else { return }
                addToken(normalized)

                if normalized.hasPrefix("recent:") {
                    addIdentifier(String(normalized.dropFirst("recent:".count)))
                }
                if normalized.hasPrefix("id:") {
                    addToken(String(normalized.dropFirst("id:".count)))
                }
                if normalized.hasPrefix("bonjour:") {
                    let payload = String(normalized.dropFirst("bonjour:".count))
                    let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
                    addToken(parts.first)
                }
            }

            addIdentifier(identifier)
            addToken(displayName)
            for address in addresses {
                addToken(normalizedAddress(address))
            }

            return tokens
        }

        private func accessibilityIdentifierToken(for identity: String) -> String {
            identity.unicodeScalars.map { scalar -> String in
                switch scalar.value {
                case 48...57, 65...90, 97...122:
                    return String(scalar)
                default:
                    return "_"
                }
            }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        }

        private var deviceIcon: String {
            switch device.deviceType {
            case .computer: return "laptopcomputer"
            case .router: return "wifi.router"
            case .nas: return "externaldrive.connected.to.line.below"
            case .printer: return "printer"
            case .camera: return "video"
            case .speaker: return "hifispeaker"
            case .tv: return "tv"
            case .iot: return "sensor"
            case .unknown: return "questionmark.circle"
            }
        }

        private var statusColor: Color {
            switch effectiveConnectionStatus {
            case .connected: return .green
            case .online: return .blue
            case .offline: return .gray
            }
        }

        private func connectionTypeColor(for type: DeviceConnectionType) -> Color {
            switch type {
            case .wifi: return Color.blue.opacity(0.8)
            case .cellular: return Color.green.opacity(0.8)
            case .usb: return Color.green.opacity(0.8)
            case .ethernet: return Color.purple.opacity(0.8)
            case .thunderbolt: return Color.orange.opacity(0.8)
            case .bluetooth: return Color.cyan.opacity(0.8)
            case .unknown: return Color.gray.opacity(0.6)
            }
        }

    }

 // MARK: - 本地设备卡片

    struct LocalDeviceCard: View {
        let device: DiscoveredDevice
        let onConnect: () -> Void
        @EnvironmentObject var themeConfiguration: ThemeConfiguration

        var body: some View {
            HStack(spacing: 16) {
 // 设备图标
                Image(systemName: deviceIcon)
                    .font(.system(size: 32))
                    .foregroundColor(.blue)
                    .frame(width: 50, height: 50)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(10)

                VStack(alignment: .leading, spacing: 6) {
                    Text(device.name)
                        .font(.headline)

                    if let ipv4 = device.ipv4 {
                        Text("IP: \(ipv4)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

 // 连接类型标签
                    if !device.connectionTypes.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(device.connectionTypes.sorted(by: { $0.rawValue < $1.rawValue })), id: \.self) { type in
                                HStack(spacing: 3) {
                                    Image(systemName: type.iconName)
                                        .font(.system(size: 9))
                                    Text(type.rawValue)
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(connectionTypeColor(for: type))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                }

                Spacer()

                Button(LocalizationManager.shared.localizedString("discovery.action.connect")) {
                    onConnect()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(themeConfiguration.borderColor, lineWidth: 1)
            )
        }

        private var deviceIcon: String {
            if device.name.lowercased().contains("ipad") {
                return "ipad"
            } else if device.name.lowercased().contains("iphone") {
                return "iphone"
            } else if device.name.lowercased().contains("mac") {
                return "laptopcomputer"
            } else if device.connectionTypes.contains(.usb) {
                return "cable.connector"
            } else {
                return "network"
            }
        }

        private func connectionTypeColor(for type: DeviceConnectionType) -> Color {
            switch type {
            case .wifi: return Color.blue.opacity(0.8)
            case .cellular: return Color.green.opacity(0.8)
            case .usb: return Color.green.opacity(0.8)
            case .ethernet: return Color.purple.opacity(0.8)
            case .thunderbolt: return Color.orange.opacity(0.8)
            case .bluetooth: return Color.cyan.opacity(0.8)
            case .unknown: return Color.gray.opacity(0.6)
            }
        }

    }

 /// iCloud设备卡片
    private func iCloudDeviceCard(device: iCloudDevice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
 // 设备图标
                Image(systemName: device.iconName)
                    .font(.title2)
                    .foregroundColor(.blue)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(Color.blue.opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text(device.model)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

 // 在线状态指示器
                HStack(spacing: 4) {
                    Circle()
                        .fill(device.isOnline ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)

                    Text(device.isOnline ? LocalizationManager.shared.localizedString("discovery.device.status.online") : LocalizationManager.shared.localizedString("discovery.device.status.offline"))
                        .font(.caption2)
                        .foregroundColor(device.isOnline ? .green : .gray)
                }
            }

            Divider()

 // 设备详细信息
            VStack(alignment: .leading, spacing: 6) {
                infoRow(icon: "network", text: device.networkType.displayName)

                if let ip = device.ipAddress {
                    infoRow(icon: "wifi", text: ip)
                }

                infoRow(icon: "desktopcomputer", text: "macOS \(device.osVersion)")

                infoRow(
                    icon: "clock",
                    text: String(format: LocalizationManager.shared.localizedString("discovery.device.lastActive"), formatLastSeen(device.lastSeen))
                )
            }
            .font(.caption)
            .foregroundColor(.secondary)

 // 设备能力
            HStack(spacing: 6) {
                ForEach(device.capabilities, id: \.self) { capability in
                    capabilityBadge(capability)
                }
            }

 // 连接按钮
            Button(action: {
                connectToCloudDevice(device)
            }) {
                HStack {
                    Image(systemName: "link")
                        .font(.caption)
                    Text(LocalizationManager.shared.localizedString("discovery.action.connect"))
                        .font(.caption.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(!device.isOnline)
        }
        .padding(16)
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }

 /// 将 iCloudDevice 映射为 CloudDevice，供跨网络连接使用。
    private func mapToCloudDevice(_ device: iCloudDevice) -> CloudDevice {
 // 设备类型映射，基于型号推断。
        let type: CloudDevice.DeviceType
        if device.model.contains("iPhone") {
            type = .iPhone
        } else if device.model.contains("iPad") {
            type = .iPad
        } else {
            type = .mac
        }

 // 能力映射，仅保留跨网络连接管理器定义的能力集合。
        let mappedCapabilities: [CloudDevice.DeviceCapability] = device.capabilities.compactMap { cap in
            switch cap {
            case .remoteDesktop:
                return .remoteDesktop
            case .fileTransfer:
                return .fileTransfer
            default:
 // 其他能力当前无需在连接中使用，忽略以保持兼容。
                return nil
            }
        }

        let liveDevice = unifiedDeviceManager.resolvedOnlineDevice(for: device)
        let effectiveLastSeen: Date = {
            guard let liveDevice, liveDevice.connectionStatus != .offline else {
                return device.lastSeen
            }
            return max(device.lastSeen, liveDevice.lastSeen)
        }()

        return CloudDevice(
            id: device.id,
            name: device.name,
            type: type,
            lastSeen: effectiveLastSeen,
            capabilities: mappedCapabilities.isEmpty ? [.remoteDesktop] : mappedCapabilities
        )
    }

 /// 信息行
    private func infoRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .frame(width: 16)
            Text(text)
        }
    }

 /// 能力标签
    private func capabilityBadge(_ capability: DeviceCapability) -> some View {
        let (icon, color) = capabilityInfo(capability)

        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(capabilityName(capability))
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

 /// 获取能力信息
    private func capabilityInfo(_ capability: DeviceCapability) -> (String, Color) {
        switch capability {
        case .remoteDesktop:
            return ("display", .blue)
        case .fileTransfer:
            return ("folder", .green)
        case .clipboard:
            return ("doc.on.clipboard", .orange)
        case .notifications:
            return ("bell", .purple)
        case .calls:
            return ("phone", .cyan)
        case .messages:
            return ("message", .pink)
        }
    }

 /// 获取能力名称
    private func capabilityName(_ capability: DeviceCapability) -> String {
        switch capability {
        case .remoteDesktop: return LocalizationManager.shared.localizedString("discovery.capability.remoteDesktop")
        case .fileTransfer: return LocalizationManager.shared.localizedString("discovery.capability.fileTransfer")
        case .clipboard: return LocalizationManager.shared.localizedString("discovery.capability.clipboard")
        case .notifications: return LocalizationManager.shared.localizedString("discovery.capability.notifications")
        case .calls: return LocalizationManager.shared.localizedString("discovery.capability.calls")
        case .messages: return LocalizationManager.shared.localizedString("discovery.capability.messages")
        }
    }

 /// 格式化最后活跃时间
    private func formatLastSeen(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return LocalizationManager.shared.localizedString("discovery.time.justNow")
        } else if interval < 3600 {
            return String(format: LocalizationManager.shared.localizedString("discovery.time.minutesAgo"), Int(interval / 60))
        } else if interval < 86400 {
            return String(format: LocalizationManager.shared.localizedString("discovery.time.hoursAgo"), Int(interval / 3600))
        } else {
            return String(format: LocalizationManager.shared.localizedString("discovery.time.daysAgo"), Int(interval / 86400))
        }
    }

 // MARK: - 4️⃣ 智能连接码

    private var connectionCodeSection: some View {
        VStack(spacing: 20) {
            InfoBanner(
                icon: "number.square.fill",
                title: LocalizationManager.shared.localizedString("discovery.smartCode.title"),
                description: LocalizationManager.shared.localizedString("discovery.smartCode.description"),
                color: .orange
            )

            HStack(spacing: 32) {
 // 左侧：生成连接码
                VStack(spacing: 16) {
                    Text(LocalizationManager.shared.localizedString("discovery.smartCode.onThisDevice"))
                        .font(.title3)
                        .fontWeight(.semibold)

                    if let code = crossNetworkManager.connectionCode {
                        VStack(spacing: 12) {
                            Picker(
                                LocalizationManager.shared.localizedString("connection.codeMode.title"),
                                selection: $crossNetworkManager.connectionCodeLeaseMode
                            ) {
                                Text(LocalizationManager.shared.localizedString("connection.codeMode.short"))
                                    .tag(CrossNetworkConnectionManager.ConnectionCodeLeaseMode.shortLived)
                                Text(LocalizationManager.shared.localizedString("connection.codeMode.day"))
                                    .tag(CrossNetworkConnectionManager.ConnectionCodeLeaseMode.dayStable)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 240)

                            Text(
                                crossNetworkManager.connectionCodeLeaseMode == .dayStable
                                    ? LocalizationManager.shared.localizedString("connection.codeMode.dayHint")
                                    : LocalizationManager.shared.localizedString("connection.codeMode.shortHint")
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(width: 240)

                            Text(code)
                                .font(.system(size: 42, weight: .bold, design: .rounded))
                                .tracking(6)
                                .foregroundColor(.orange)
                                .padding(20)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(12)

                            Text(LocalizationManager.shared.localizedString("discovery.smartCode.shareInstruction"))
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack(spacing: 12) {
                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(code, forType: .string)
                                }) {
                                    Label(LocalizationManager.shared.localizedString("discovery.smartCode.copy"), systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)

                                Button(action: {
                                    Task {
                                        do {
                                            connectionCodeErrorMessage = nil
                                            _ = try await crossNetworkManager.generateConnectionCode()
                                        } catch {
                                            connectionCodeErrorMessage = userFacingConnectionErrorMessage(error)
                                            logger.error("❌ 重新生成连接码失败: \(error.localizedDescription, privacy: .public)")
                                        }
                                    }
                                }) {
                                    Label(LocalizationManager.shared.localizedString("discovery.smartCode.regenerate"), systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                            }

                            if case .waiting = crossNetworkManager.connectionStatus {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(LocalizationManager.shared.localizedString("discovery.smartCode.waiting"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    } else {
                        Button(action: {
                            Task {
                                do {
                                    connectionCodeErrorMessage = nil
                                    _ = try await crossNetworkManager.generateConnectionCode()
                                } catch {
                                    connectionCodeErrorMessage = userFacingConnectionErrorMessage(error)
                                    logger.error("❌ 生成连接码失败: \(error.localizedDescription, privacy: .public)")
                                }
                            }
                        }) {
                            VStack(spacing: 12) {
                                Image(systemName: "number.square")
                                    .font(.system(size: 48))
                                    .foregroundColor(.orange)
                                Text(LocalizationManager.shared.localizedString("discovery.smartCode.generate"))
                                    .font(.headline)
                            }
                            .frame(width: 240, height: 180)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)

                        Picker(
                            LocalizationManager.shared.localizedString("connection.codeMode.title"),
                            selection: $crossNetworkManager.connectionCodeLeaseMode
                        ) {
                            Text(LocalizationManager.shared.localizedString("connection.codeMode.short"))
                                .tag(CrossNetworkConnectionManager.ConnectionCodeLeaseMode.shortLived)
                            Text(LocalizationManager.shared.localizedString("connection.codeMode.day"))
                                .tag(CrossNetworkConnectionManager.ConnectionCodeLeaseMode.dayStable)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 240)

                        Text(
                            crossNetworkManager.connectionCodeLeaseMode == .dayStable
                                ? LocalizationManager.shared.localizedString("connection.codeMode.dayHint")
                                : LocalizationManager.shared.localizedString("connection.codeMode.shortHint")
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: 240)
                    }
                }

                Divider()

 // 右侧：输入连接码
                VStack(spacing: 16) {
                    Text(LocalizationManager.shared.localizedString("discovery.smartCode.onOtherDevice"))
                        .font(.title3)
                        .fontWeight(.semibold)

                    VStack(spacing: 12) {
                        TextField(LocalizationManager.shared.localizedString("discovery.code.enterPrompt"), text: $connectionCodeInput)
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.center)
                            .textCase(.uppercase)
                            .frame(width: 240)
                            .padding(.vertical, 16)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(12)
                            .onChange(of: connectionCodeInput) { _, newValue in
                                connectionCodeInput = CrossNetworkConnectionManager.sanitizeConnectionCodeInput(newValue)
                            }

                        Button(action: {
                            Task {
                                do {
                                    connectionCodeErrorMessage = nil
                                    _ = try await crossNetworkManager.connectWithCode(connectionCodeInput)
                                } catch {
                                    connectionCodeErrorMessage = userFacingConnectionErrorMessage(error)
                                    logger.error("❌ 连接码连接失败: \(error.localizedDescription, privacy: .public)")
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "arrow.right.circle.fill")
                                Text(LocalizationManager.shared.localizedString("discovery.code.connect"))
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!CrossNetworkConnectionManager.canSubmitConnectionCode(connectionCodeInput))
                        .frame(width: 240)

                        if let connectionCodeErrorMessage, !connectionCodeErrorMessage.isEmpty {
                            Text(connectionCodeErrorMessage)
                                .font(.caption)
                                .foregroundColor(.red)
                                .frame(width: 240)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(height: 180)
                }
            }
            .padding(.vertical, 20)
        }
    }

 // MARK: - 辅助方法

    /// 🆕 连接到在线设备
    private func connectToOnlineDevice(_ device: OnlineDevice) {
        if connectingOnlineDeviceIds.contains(device.id) { return }
        connectingOnlineDeviceIds.insert(device.id)
        onlineDeviceConnectionErrorMessage = nil
        appendMacOnlineIPadConnectAppActionIfNeeded(result: "start", device: device)
        Task {
            defer {
                Task { @MainActor in
                    connectingOnlineDeviceIds.remove(device.id)
                }
            }
            do {
                try await OnlineDeviceConnectionCoordinator.connect(
                    to: device,
                    unifiedDeviceManager: unifiedDeviceManager,
                    p2pDiscoveryService: p2pDiscoveryService
                )
                connectionCodeErrorMessage = nil
                onlineDeviceConnectionErrorMessage = nil
                appendMacOnlineIPadConnectAppActionIfNeeded(result: "success", device: device)
                logger.info("✅ 在线设备连接成功: \(device.name)")
            } catch {
                logger.error("❌ 在线设备连接失败: \(device.name, privacy: .public), \(error.localizedDescription, privacy: .public)")
                let message = userFacingConnectionErrorMessage(error)
                onlineDeviceConnectionErrorMessage = message
                appendMacOnlineIPadConnectAppActionIfNeeded(result: "failure", device: device, error: error)
            }
        }
    }

    private func connectToCloudDevice(_ device: iCloudDevice) {
        if let liveDevice = unifiedDeviceManager.resolvedOnlineDevice(for: device),
           unifiedDeviceManager.hasResolvedConnectableControlRoute(for: liveDevice) {
            connectToOnlineDevice(liveDevice)
            return
        }

        scannerErrorMessage = "没有发现这台设备的本地 P2P/Bonjour 端点，iCloud 自动连接暂不可用。请确认 iPad 与 Mac 在同一局域网、SkyBridge 在前台，并刷新设备。"
    }

    private func isCrossNetworkConnectLink(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("skybridge://connect/") { return true }
        guard let url = URL(string: trimmed), url.scheme == "skybridge", url.host == "connect" else {
            return false
        }
        let pathPayload = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !pathPayload.isEmpty { return true }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryPayload = components.queryItems?.first(where: { $0.name == "data" })?.value {
            return !queryPayload.isEmpty
        }
        return false
    }

    private func generateDynamicQRCodeFromUI(trigger: String) async {
        guard !isGeneratingQRCode else { return }
        do {
            scannerErrorMessage = nil
            logger.info("📷 QR action started: \(trigger, privacy: .public)")
            _ = try await crossNetworkManager.generateDynamicQRCode()
            logger.info("✅ QR action succeeded: \(trigger, privacy: .public)")
        } catch {
            logger.error("❌ QR action failed: \(trigger, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            presentScannerError(String(
                format: LocalizationManager.shared.localizedString("discovery.qrCode.error.connectFailed"),
                userFacingConnectionErrorMessage(error)
            ))
        }
    }

    private func connectScannedQRCodeFromUI(_ content: String, trigger: String) async {
        do {
            scannerErrorMessage = nil
            logger.info("📷 QR scan connect started: \(trigger, privacy: .public)")
            let data = Data(content.utf8)
            _ = try await crossNetworkManager.scanDynamicQRCode(data)
            logger.info("✅ QR scan connect succeeded: \(trigger, privacy: .public)")
        } catch {
            logger.error("❌ QR scan connect failed: \(trigger, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            presentScannerError(String(
                format: LocalizationManager.shared.localizedString("discovery.qrCode.error.connectFailed"),
                userFacingConnectionErrorMessage(error)
            ))
        }
    }

    private var isGeneratingQRCode: Bool {
        if case .generating = crossNetworkManager.connectionStatus {
            return true
        }
        return false
    }

    private func presentScannerError(_ message: String, dedupeWindow: TimeInterval = 12) {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let now = Date()
        if lastScannerErrorFingerprint == normalized,
           now.timeIntervalSince(lastScannerErrorAt) < dedupeWindow {
            return
        }
        lastScannerErrorFingerprint = normalized
        lastScannerErrorAt = now
        scannerErrorMessage = normalized
    }

    private func userFacingConnectionErrorMessage(_ error: Error) -> String {
        let message = HandshakeErrorLocalizer.localizedMessage(for: error)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            return message
        }
        let fallback = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "连接失败" : fallback
    }

    private func emptyStateView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @MainActor
    private final class TrustedBonjourMetadataStore: ObservableObject {
        @Published fileprivate var metadataByGroupId: [String: ApplePeerDeviceMetadataNormalizer.Presentation] = [:]
        private var refreshTask: Task<Void, Never>?
        private let logger = Logger(
            subsystem: "com.skybridge.SkyBridgeCompassApp",
            category: "TrustedBonjourMetadata"
        )

        func scheduleRefresh(for groups: [TrustRecordDisplayGroup]) {
            let snapshot = groups
            logger.debug("schedule refresh for \(snapshot.count) trusted groups")
            refreshTask?.cancel()
            refreshTask = Task { [weak self] in
                await self?.refresh(for: snapshot)
            }
        }

        deinit {
            refreshTask?.cancel()
        }

        private func refresh(for groups: [TrustRecordDisplayGroup]) async {
            var updated: [String: ApplePeerDeviceMetadataNormalizer.Presentation] = [:]
            for group in groups {
                guard !Task.isCancelled else { return }
                guard let endpoint = Self.bonjourEndpoint(for: group) else {
                    logger.debug("skip group \(group.id, privacy: .public): no bonjour endpoint")
                    continue
                }
                logger.debug(
                    "resolve group \(group.id, privacy: .public) endpoint=\(endpoint.name, privacy: .public)@\(endpoint.domain, privacy: .public)"
                )
                guard let info = await BonjourTXTLookupResolver.resolve(
                    name: endpoint.name,
                    type: "_skybridge._tcp",
                    domain: endpoint.domain,
                    timeout: 1.5
                ) else {
                    logger.debug("resolve missed group \(group.id, privacy: .public)")
                    continue
                }
                logger.debug(
                    "resolved group \(group.id, privacy: .public) platform=\(info.platform ?? "", privacy: .public) os=\(info.osVersion ?? "", privacy: .public) model=\(info.model ?? "", privacy: .public)"
                )

                let normalized = ApplePeerDeviceMetadataNormalizer.normalize(
                    modelName: info.model,
                    chip: info.chip,
                    platform: info.platform,
                    osVersion: info.osVersion
                )

                if normalized.modelName != nil
                    || normalized.chip != nil
                    || normalized.platform != nil
                    || normalized.osVersion != nil {
                    updated[group.id] = normalized
                }
            }

            applyResolvedMetadata(updated, validGroupIds: Set(groups.map(\.id)))
        }

        private func applyResolvedMetadata(
            _ updated: [String: ApplePeerDeviceMetadataNormalizer.Presentation],
            validGroupIds: Set<String>
        ) {
            var merged = metadataByGroupId.filter { validGroupIds.contains($0.key) }
            merged.merge(updated) { _, new in new }
            metadataByGroupId = merged
            logger.debug("applied trusted bonjour metadata for \(updated.count) groups; retained total \(merged.count)")
        }

        private nonisolated static func bonjourEndpoint(
            for group: TrustRecordDisplayGroup
        ) -> (name: String, domain: String)? {
            let records = [group.displayRecord] + group.relatedRecords
            for record in records {
                for token in bonjourCandidates(from: record) {
                    if let parsed = parseBonjourToken(token) {
                        return parsed
                    }
                }
            }
            return nil
        }

        private nonisolated static func bonjourCandidates(from record: TrustRecord) -> [String] {
            let caps = record.capabilities.compactMap { capability -> String? in
                let parts = capability.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == "peerEndpoint" else { return nil }
                return parts[1]
            }

            return caps
                + [record.deviceId, record.currentDeviceId]
                + record.knownDeviceIds
        }

        private nonisolated static func parseBonjourToken(_ raw: String?) -> (name: String, domain: String)? {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  raw.hasPrefix("bonjour:") else {
                return nil
            }

            let payload = String(raw.dropFirst("bonjour:".count))
            let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
            guard let name = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                return nil
            }

            let domain = parts.count > 1 ? parts[1] : "local."
            return (name, domain.hasSuffix(".") ? domain : "\(domain).")
        }
    }
}

private final class BonjourTXTLookupResolver: NSObject, NetServiceDelegate, @unchecked Sendable {
    private let resumed = OSAllocatedUnfairLock(initialState: false)
    private let service: NetService
    private var continuation: CheckedContinuation<BonjourDeviceInfo?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var selfRetain: BonjourTXTLookupResolver?

    private init(name: String, type: String, domain: String) {
        self.service = NetService(domain: domain, type: type, name: name)
        super.init()
    }

    static func resolve(
        name: String,
        type: String,
        domain: String,
        timeout: TimeInterval = 3
    ) async -> BonjourDeviceInfo? {
        let resolved = await withCheckedContinuation { continuation in
            let resolver = BonjourTXTLookupResolver(name: name, type: type, domain: domain)
            resolver.start(timeout: timeout, continuation: continuation)
        }
        if let resolved {
            return resolved
        }
        return await fallbackResolveViaDNSSD(
            name: name,
            type: type,
            domain: domain,
            timeout: timeout
        )
    }

    private func start(
        timeout: TimeInterval,
        continuation: CheckedContinuation<BonjourDeviceInfo?, Never>
    ) {
        self.continuation = continuation
        self.selfRetain = self
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: timeout)

        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.finish(with: nil)
            }
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let txtData = sender.txtRecordData() else {
            finish(with: nil)
            return
        }

        let dict = NetService.dictionary(fromTXTRecord: txtData).reduce(into: [String: String]()) { partialResult, item in
            if let value = String(data: item.value, encoding: .utf8) {
                partialResult[item.key] = value
            }
        }
        finish(with: BonjourTXTParser.extractDeviceInfo(from: dict))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        finish(with: nil)
    }

    private func finish(with info: BonjourDeviceInfo?) {
        let shouldResume = resumed.withLock { completed -> Bool in
            guard !completed else { return false }
            completed = true
            return true
        }
        guard shouldResume else { return }

        timeoutTask?.cancel()
        timeoutTask = nil
        service.delegate = nil
        service.stop()
        service.remove(from: .main, forMode: .common)
        continuation?.resume(returning: info)
        continuation = nil
        selfRetain = nil
    }

    private static func fallbackResolveViaDNSSD(
        name: String,
        type: String,
        domain: String,
        timeout: TimeInterval
    ) async -> BonjourDeviceInfo? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/dns-sd") else {
            return nil
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        process.arguments = ["-L", name, type, domain]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let completed = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            let finish: @Sendable () -> Void = {
                let shouldResume = completed.withLock { state -> Bool in
                    guard !state else { return false }
                    state = true
                    return true
                }
                guard shouldResume else { return }
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: nil)
                    return
                }
                for line in output.split(whereSeparator: \.isNewline).reversed() {
                    let parsed = parseDNSSDKeyValueLine(String(line))
                    if !parsed.isEmpty {
                        continuation.resume(returning: BonjourTXTParser.extractDeviceInfo(from: parsed))
                        return
                    }
                }
                continuation.resume(returning: nil)
            }

            process.terminationHandler = { _ in
                finish()
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }

            Task {
                try? await Task.sleep(for: .seconds(max(timeout, 0.5)))
                let shouldTerminate = completed.withLock { !$0 }
                if shouldTerminate, process.isRunning {
                    process.terminate()
                }
            }
        }
    }

    private static func parseDNSSDKeyValueLine(_ line: String) -> [String: String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("=") else { return [:] }

        let tokens = splitEscapedFields(trimmed)
        var parsed: [String: String] = [:]
        for token in tokens {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1]
                .replacingOccurrences(of: "\\ ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            parsed[key] = value
        }
        return parsed
    }

    private static func splitEscapedFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var escaping = false

        for scalar in line.unicodeScalars {
            let character = Character(scalar)
            if escaping {
                current.append(character)
                escaping = false
                continue
            }

            if character == "\\" {
                current.append(character)
                escaping = true
                continue
            }

            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !current.isEmpty {
                    fields.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }

            current.append(character)
        }

        if !current.isEmpty {
            fields.append(current)
        }

        return fields
    }
}

// MARK: - 发现模式枚举

enum DiscoveryMode: String, CaseIterable, Identifiable {
    case localScan = "local"
    case qrCode = "qr"
    case cloudLink = "cloud"
    case connectionCode = "code"

    var id: String { rawValue }

    @MainActor
    var title: String {
        switch self {
        case .localScan: return LocalizationManager.shared.localizedString("discovery.mode.localScan")
        case .qrCode: return LocalizationManager.shared.localizedString("discovery.mode.qrCode")
        case .cloudLink: return LocalizationManager.shared.localizedString("discovery.mode.cloudLink")
        case .connectionCode: return LocalizationManager.shared.localizedString("discovery.mode.connectionCode")
        }
    }

    @MainActor
    var subtitle: String {
        switch self {
        case .localScan: return LocalizationManager.shared.localizedString("discovery.mode.subtitle.localScan")
        case .qrCode: return LocalizationManager.shared.localizedString("discovery.mode.subtitle.qrCode")
        case .cloudLink: return LocalizationManager.shared.localizedString("discovery.mode.subtitle.cloudLink")
        case .connectionCode: return LocalizationManager.shared.localizedString("discovery.mode.subtitle.connectionCode")
        }
    }

    var iconName: String {
        switch self {
        case .localScan: return "wifi.router"
        case .qrCode: return "qrcode.viewfinder"
        case .cloudLink: return "icloud.fill"
        case .connectionCode: return "number.square.fill"
        }
    }
    var accentColor: Color {
        switch self {
        case .localScan: return .green
        case .qrCode: return .blue
        case .cloudLink: return .purple
        case .connectionCode: return .orange
        }
    }
}

// MARK: - 辅助组件

struct InfoBanner: View {
    let icon: String
    let title: String
    let description: String
    let color: Color
    @EnvironmentObject var themeConfiguration: ThemeConfiguration

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(color)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }
}

struct LocalDeviceCard: View {
    let device: DiscoveredDevice
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: deviceIcon)
                .font(.system(size: 32))
                .foregroundColor(.blue)
                .frame(width: 50, height: 50)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 6) {
                Text(device.name)
                    .font(.headline)

                if let ipv4 = device.ipv4 {
                    Text("IPv4: \(ipv4)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

 // 连接方式标签
                HStack(spacing: 6) {
                    ForEach(Array(device.connectionTypes), id: \.self) { connectionType in
                        HStack(spacing: 3) {
                            Image(systemName: connectionType.iconName)
                                .font(.system(size: 10))
                            Text(connectionType.rawValue)
                                .font(.caption2)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(connectionTypeColor(connectionType).opacity(0.2))
                        .foregroundColor(connectionTypeColor(connectionType))
                        .cornerRadius(4)
                    }
                }

 // 服务标签
                if !device.services.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(device.services.prefix(2)), id: \.self) { service in
                            Text(service)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                }
            }

            Spacer()

            Button(LocalizationManager.shared.localizedString("discovery.action.connect")) {
                onConnect()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    private var deviceIcon: String {
        if device.name.lowercased().contains("iphone") {
            return "iphone"
        } else if device.name.lowercased().contains("ipad") {
            return "ipad"
        } else if device.name.lowercased().contains("mac") {
            return "desktopcomputer"
        } else {
            return "server.rack"
        }
    }

    private func connectionTypeColor(_ type: DeviceConnectionType) -> Color {
        switch type {
        case .wifi: return .blue
        case .cellular: return .green
        case .ethernet: return .orange
        case .usb: return .green
        case .thunderbolt: return .purple
        case .bluetooth: return .cyan
        case .unknown: return .gray
        }
    }
}

struct CloudDeviceCardEnhanced: View {
    let device: CloudDevice
    let onConnect: () -> Void
    @EnvironmentObject var themeConfiguration: ThemeConfiguration

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: deviceIcon)
                .font(.system(size: 32))
                .foregroundColor(.purple)
                .frame(width: 50, height: 50)
                .background(Color.purple.opacity(0.1))
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.headline)

                Text(deviceTypeText)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    ForEach(device.deviceCapabilities, id: \.self) { capability in
                        Text(capability.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(timeAgoText)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Button(LocalizationManager.shared.localizedString("discovery.action.connect")) {
                    onConnect()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(16)
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }

    private var deviceIcon: String {
        switch device.type {
        case .mac: return "desktopcomputer"
        case .iPhone: return "iphone"
        case .iPad: return "ipad"
        }
    }

    private var deviceTypeText: String {
        switch device.type {
        case .mac: return "Mac"
        case .iPhone: return "iPhone"
        case .iPad: return "iPad"
        }
    }

    private var timeAgoText: String {
        let interval = Date().timeIntervalSince(device.lastSeen)
        if interval < 60 {
            return LocalizationManager.shared.localizedString("discovery.time.justNowOnline")
        } else if interval < 3600 {
            return String(format: LocalizationManager.shared.localizedString("discovery.time.minutesAgo"), Int(interval / 60))
        } else {
            return String(format: LocalizationManager.shared.localizedString("discovery.time.hoursAgo"), Int(interval / 3600))
        }
    }
}

// QR码视图组件（如果CrossNetworkConnectionView没有导出，则使用本地版本）
