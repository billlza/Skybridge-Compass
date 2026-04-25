import Foundation
import Combine

/// 受信任设备存储（持久化）
/// - 目的：让 iOS 端的“受信任设备”不再是占位 UI，并能和握手/验证流程挂钩
@MainActor
public final class TrustedDeviceStore: ObservableObject {
    public static let shared = TrustedDeviceStore()

    public enum CurrentPathLifecycleState: String, Codable, Sendable, Equatable {
        case active
        case reverificationRequired
        case quarantined
        case revoked
    }

    public enum CurrentPathTrustConflict: Sendable, Equatable {
        case identityConflict
        case deviceIdMigrationRequired
        case quarantinedIdentity
        case revokedIdentity
    }

    public struct TrustedDevice: Codable, Identifiable, Sendable, Equatable {
        public struct ConnectableContext: Codable, Sendable, Equatable {
            public var bonjourServiceName: String?
            public var bonjourServiceType: String?
            public var bonjourServiceDomain: String?
            public var services: [String]
            public var portMap: [String: UInt16]
            public var lastResolvedIPAddress: String?

            public init(
                bonjourServiceName: String? = nil,
                bonjourServiceType: String? = nil,
                bonjourServiceDomain: String? = nil,
                services: [String] = [],
                portMap: [String: UInt16] = [:],
                lastResolvedIPAddress: String? = nil
            ) {
                self.bonjourServiceName = bonjourServiceName
                self.bonjourServiceType = bonjourServiceType
                self.bonjourServiceDomain = bonjourServiceDomain
                self.services = services
                self.portMap = portMap
                self.lastResolvedIPAddress = lastResolvedIPAddress
            }
        }

        public let id: String // 建议使用 discovery TXT 的 uuid / 或配对 deviceId
        public var name: String
        public var platform: DevicePlatform
        public var ipAddress: String?
        public var addedAt: Date
        public var protocolSigningAlgorithm: String?
        public var protocolPublicKeyFingerprint: String?
        public var currentDeviceId: String?
        public var knownDeviceIds: [String]?
        public var currentPathLifecycleState: CurrentPathLifecycleState?
        public var connectableContext: ConnectableContext?

        public init(
            id: String,
            name: String,
            platform: DevicePlatform,
            ipAddress: String?,
            addedAt: Date = Date(),
            protocolSigningAlgorithm: String? = nil,
            protocolPublicKeyFingerprint: String? = nil,
            currentDeviceId: String? = nil,
            knownDeviceIds: [String]? = nil,
            currentPathLifecycleState: CurrentPathLifecycleState? = nil,
            connectableContext: ConnectableContext? = nil
        ) {
            self.id = id
            self.name = name
            self.platform = platform
            self.ipAddress = ipAddress
            self.addedAt = addedAt
            self.protocolSigningAlgorithm = protocolSigningAlgorithm
            self.protocolPublicKeyFingerprint = protocolPublicKeyFingerprint?.lowercased()
            self.currentDeviceId = currentDeviceId
            self.knownDeviceIds = knownDeviceIds
            self.currentPathLifecycleState = currentPathLifecycleState
            self.connectableContext = connectableContext
        }
    }

    @Published public private(set) var trustedDevices: [TrustedDevice] = []

    private static let trustedDevicesStore = CodablePersistenceStore<[TrustedDevice]>(
        location: .protectedApplicationSupport(
            path: "Trust/trusted-devices.json",
            legacyUserDefaultsKey: "trusted_devices.v1"
        )
    )

    private init() {
        load()
    }

    public func isTrusted(deviceId: String) -> Bool {
        let candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
        guard !candidates.isEmpty else { return false }
        return trustedDevices.contains(where: { matches($0, candidates: candidates) })
    }

    public func canonicalTrustedDeviceId(for deviceId: String) -> String? {
        let candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
        guard !candidates.isEmpty else { return nil }
        guard let matched = trustedDevices.first(where: { matches($0, candidates: candidates) }) else {
            return nil
        }
        return resolvedCurrentDeviceId(for: matched)
    }

    public func canonicalTrustedDeviceId(for device: DiscoveredDevice) -> String? {
        var candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: device.id))
        candidates.formUnion(PeerIdentityAliasResolver.aliasKeys(for: device))
        if let ipAddress = device.ipAddress {
            candidates.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: ipAddress))
        }

        if let matched = trustedDevices.first(where: { matches($0, candidates: candidates) }) {
            return resolvedCurrentDeviceId(for: matched)
        }

        let normalizedDeviceName = normalizedNameToken(device.name)
        guard !normalizedDeviceName.isEmpty else { return nil }

        let sameNameMatches = trustedDevices.filter { trusted in
            normalizedNameToken(trusted.name) == normalizedDeviceName
                && (trusted.platform == .unknown || device.platform == .unknown || trusted.platform == device.platform)
        }

        guard sameNameMatches.count == 1 else { return nil }
        return resolvedCurrentDeviceId(for: sameNameMatches[0])
    }

    public func resolvedConnectableDevice(for device: DiscoveredDevice) -> DiscoveredDevice? {
        var candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: device.id))
        candidates.formUnion(PeerIdentityAliasResolver.aliasKeys(for: device))
        if let ipAddress = device.ipAddress {
            candidates.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: ipAddress))
        }

        guard let matched = trustedDevices.first(where: { matches($0, candidates: candidates) }) else {
            return nil
        }

        let fallbackContext = connectableContext(from: matched)
        let mergedContext = mergedConnectableContext(
            fallbackContext,
            with: connectableContext(from: device)
        )

        guard let mergedContext,
              mergedContext.bonjourServiceName?.isEmpty == false
                || mergedContext.lastResolvedIPAddress?.isEmpty == false
                || !mergedContext.services.isEmpty
                || !mergedContext.portMap.isEmpty else {
            return nil
        }

        let mergedServices = Array(Set(device.services).union(mergedContext.services)).sorted()
        let mergedPortMap = mergedContext.portMap.merging(device.portMap) { _, latest in latest }

        return DiscoveredDevice(
            id: device.id,
            name: device.name,
            bonjourServiceName: device.bonjourServiceName ?? mergedContext.bonjourServiceName,
            modelName: device.modelName,
            platform: device.platform,
            osVersion: device.osVersion,
            ipAddress: device.ipAddress ?? mergedContext.lastResolvedIPAddress ?? matched.ipAddress,
            bonjourServiceType: device.bonjourServiceType ?? mergedContext.bonjourServiceType,
            bonjourServiceDomain: device.bonjourServiceDomain ?? mergedContext.bonjourServiceDomain,
            services: mergedServices,
            portMap: mergedPortMap,
            signalStrength: device.signalStrength,
            lastSeen: device.lastSeen,
            isConnected: device.isConnected,
            isTrusted: true,
            publicKey: device.publicKey,
            advertisedCapabilities: device.advertisedCapabilities,
            capabilities: device.capabilities
        )
    }

    @discardableResult
    func repairLegacyTrustedDeviceIdentity(
        requestedDevice: DiscoveredDevice,
        liveDiscoveredDevice: DiscoveredDevice
    ) -> [String] {
        guard let canonicalStableId = canonicalPersistentTrustedDeviceIdentifier(liveDiscoveredDevice.id) else {
            return []
        }

        var candidateAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: requestedDevice.id))
        candidateAliases.formUnion(PeerIdentityAliasResolver.aliasKeys(for: requestedDevice))
        candidateAliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: liveDiscoveredDevice.id))
        candidateAliases.formUnion(PeerIdentityAliasResolver.aliasKeys(for: liveDiscoveredDevice))
        if let requestedIPAddress = requestedDevice.ipAddress {
            candidateAliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: requestedIPAddress))
        }
        if let liveIPAddress = liveDiscoveredDevice.ipAddress {
            candidateAliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: liveIPAddress))
        }

        var matchingIndices = trustedDevices.indices.filter { index in
            matches(trustedDevices[index], candidates: candidateAliases)
        }
        if matchingIndices.isEmpty {
            matchingIndices = uniqueNameMatchedTrustedDeviceIndices(for: liveDiscoveredDevice)
        }
        guard !matchingIndices.isEmpty else { return [] }

        let primaryIndex =
            preferredPrimaryAuthorityIndex(
                matchingIndices: matchingIndices,
                preferredCurrentDeviceId: canonicalStableId,
                preferredFingerprint: ""
            )
            ?? matchingIndices.first!

        var mergedRecord = trustedDevices[primaryIndex]
        for index in matchingIndices where index != primaryIndex {
            mergedRecord = mergedTrustedDeviceRecord(mergedRecord, with: trustedDevices[index])
        }

        var legacyIdentifiers = Set(candidateAliases)
        legacyIdentifiers.insert(requestedDevice.id)
        legacyIdentifiers.insert(liveDiscoveredDevice.id)
        for index in matchingIndices {
            let record = trustedDevices[index]
            legacyIdentifiers.insert(record.id)
            if let currentDeviceId = record.currentDeviceId {
                legacyIdentifiers.insert(currentDeviceId)
            }
            for knownDeviceId in record.knownDeviceIds ?? [] {
                legacyIdentifiers.insert(knownDeviceId)
            }
        }
        legacyIdentifiers.insert(canonicalStableId)

        if !liveDiscoveredDevice.name.isEmpty {
            mergedRecord.name = liveDiscoveredDevice.name
        }
        if liveDiscoveredDevice.platform != .unknown {
            mergedRecord.platform = liveDiscoveredDevice.platform
        }
        if let ipAddress = liveDiscoveredDevice.ipAddress, !ipAddress.isEmpty {
            mergedRecord.ipAddress = ipAddress
        }
        mergedRecord.currentDeviceId = canonicalStableId
        mergedRecord.knownDeviceIds = mergedKnownDeviceIds(
            existing: mergedRecord.knownDeviceIds,
            adding: Array(legacyIdentifiers).sorted()
        )
        mergedRecord.connectableContext = mergedConnectableContext(
            mergedRecord.connectableContext,
            with: connectableContext(from: liveDiscoveredDevice)
        )
        if mergedRecord.currentPathLifecycleState == nil {
            mergedRecord.currentPathLifecycleState = .active
        }

        trustedDevices[primaryIndex] = migratedTrustedDeviceRecord(mergedRecord)
        for index in matchingIndices.sorted(by: >) where index != primaryIndex {
            trustedDevices.remove(at: index)
        }
        save()

        return Array(legacyIdentifiers.subtracting([canonicalStableId])).sorted()
    }

    public func currentPathTrustRecord(fingerprint: String) -> TrustedDevice? {
        guard let normalized = normalizedFingerprint(fingerprint) else { return nil }
        return trustedDevices.first { device in
            device.protocolPublicKeyFingerprint == normalized &&
            (device.currentPathLifecycleState ?? .active) == .active
        }
    }

    public func currentPathTrustRecord(
        fingerprint: String,
        matchingDeviceId deviceId: String
    ) -> TrustedDevice? {
        guard let normalized = normalizedFingerprint(fingerprint) else { return nil }
        return trustedDevices.first { device in
            guard device.protocolPublicKeyFingerprint == normalized else { return false }
            guard (device.currentPathLifecycleState ?? .active) == .active else { return false }
            return currentPathDeviceMatches(device, deviceId: deviceId)
        }
    }

    public func evaluateCurrentPathBinding(
        deviceId: String,
        protocolPublicKeyFingerprint: String
    ) -> CurrentPathTrustConflict? {
        guard let normalized = normalizedFingerprint(protocolPublicKeyFingerprint) else { return nil }

        let fingerprintMatches = trustedDevices.filter { $0.protocolPublicKeyFingerprint == normalized }
        if fingerprintMatches.contains(where: { ($0.currentPathLifecycleState ?? .active) == .revoked }) {
            return .revokedIdentity
        }
        if fingerprintMatches.contains(where: {
            switch $0.currentPathLifecycleState ?? .active {
            case .reverificationRequired, .quarantined:
                return true
            case .active, .revoked:
                return false
            }
        }) {
            return .quarantinedIdentity
        }
        if fingerprintMatches.contains(where: { ($0.currentPathLifecycleState ?? .active) == .active }) {
            // The authoritative signing key is the stronger identity anchor.
            // If the same key now advertises a new deviceId, allow the session
            // to proceed and heal the stored deviceId/aliases after success.
            return nil
        }

        let deviceMatches = trustedDevices.filter { currentPathDeviceMatches($0, deviceId: deviceId) }
        if deviceMatches.contains(where: {
            guard let pinnedFingerprint = $0.protocolPublicKeyFingerprint else { return false }
            return pinnedFingerprint != normalized && ($0.currentPathLifecycleState ?? .active) == .revoked
        }) {
            return .revokedIdentity
        }
        if deviceMatches.contains(where: {
            guard let pinnedFingerprint = $0.protocolPublicKeyFingerprint else { return false }
            guard pinnedFingerprint != normalized else { return false }
            switch $0.currentPathLifecycleState ?? .active {
            case .reverificationRequired, .quarantined:
                return true
            case .active, .revoked:
                return false
            }
        }) {
            return .quarantinedIdentity
        }
        if deviceMatches.contains(where: {
            guard let pinnedFingerprint = $0.protocolPublicKeyFingerprint else { return false }
            return pinnedFingerprint != normalized && ($0.currentPathLifecycleState ?? .active) == .active
        }) {
            return .identityConflict
        }

        return nil
    }

    public func trust(_ device: DiscoveredDevice) {
        let id = device.id
        var candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: id))
        candidates.formUnion(PeerIdentityAliasResolver.aliasKeys(for: device))
        guard !candidates.isEmpty else { return }
        let latestConnectableContext = connectableContext(from: device)

        if let idx = trustedDevices.firstIndex(where: { matches($0, candidates: candidates) }) {
            trustedDevices[idx].name = device.name
            trustedDevices[idx].platform = device.platform
            trustedDevices[idx].ipAddress = device.ipAddress
            trustedDevices[idx].connectableContext = mergedConnectableContext(
                trustedDevices[idx].connectableContext,
                with: latestConnectableContext
            )
            trustedDevices[idx].knownDeviceIds = mergedKnownDeviceIds(
                existing: trustedDevices[idx].knownDeviceIds,
                adding: Array(candidates)
            )
            if let persistent = PeerIdentityAliasResolver.persistentDeviceId(from: id) {
                trustedDevices[idx].currentDeviceId = persistent
            }
        } else {
            trustedDevices.append(
                TrustedDevice(
                    id: id,
                    name: device.name,
                    platform: device.platform,
                    ipAddress: device.ipAddress,
                    currentDeviceId: PeerIdentityAliasResolver.persistentDeviceId(from: id),
                    knownDeviceIds: Array(candidates).sorted(),
                    connectableContext: latestConnectableContext
                )
            )
        }
        save()
    }

    public func trustResolvedPeer(
        _ device: DiscoveredDevice,
        declaredDeviceId: String,
        protocolSigningAlgorithm: String? = nil,
        protocolPublicKeyFingerprint: String? = nil
    ) {
        let normalizedDeclaredDeviceId = declaredDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAlgorithm = protocolSigningAlgorithm?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFingerprint = normalizedFingerprint(protocolPublicKeyFingerprint)
        guard !normalizedDeclaredDeviceId.isEmpty else {
            trust(device)
            return
        }

        var candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: device.id))
        candidates.formUnion(PeerIdentityAliasResolver.aliasKeys(for: device))
        candidates.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: normalizedDeclaredDeviceId))
        if let ipAddress = device.ipAddress {
            candidates.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: ipAddress))
        }
        guard !candidates.isEmpty else { return }
        let latestConnectableContext = connectableContext(from: device)

        if let idx = trustedDevices.firstIndex(where: { matches($0, candidates: candidates) }) {
            trustedDevices[idx].name = device.name
            trustedDevices[idx].platform = device.platform
            trustedDevices[idx].ipAddress = device.ipAddress
            trustedDevices[idx].currentDeviceId = normalizedDeclaredDeviceId
            trustedDevices[idx].connectableContext = mergedConnectableContext(
                trustedDevices[idx].connectableContext,
                with: latestConnectableContext
            )
            if let normalizedAlgorithm, !normalizedAlgorithm.isEmpty {
                trustedDevices[idx].protocolSigningAlgorithm = normalizedAlgorithm
            }
            if let normalizedFingerprint {
                trustedDevices[idx].protocolPublicKeyFingerprint = normalizedFingerprint
            }
            trustedDevices[idx].knownDeviceIds = mergedKnownDeviceIds(
                existing: trustedDevices[idx].knownDeviceIds,
                adding: Array(candidates)
            )
        } else {
            trustedDevices.append(
                TrustedDevice(
                    id: device.id,
                    name: device.name,
                    platform: device.platform,
                    ipAddress: device.ipAddress,
                    protocolSigningAlgorithm: normalizedAlgorithm,
                    protocolPublicKeyFingerprint: normalizedFingerprint,
                    currentDeviceId: normalizedDeclaredDeviceId,
                    knownDeviceIds: Array(candidates).sorted(),
                    connectableContext: latestConnectableContext
                )
            )
        }
        save()
    }

    @discardableResult
    public func recordAuthenticatedRemoteAuthority(
        for device: DiscoveredDevice,
        preferredCurrentDeviceId: String? = nil,
        protocolSigningAlgorithm: String,
        protocolPublicKeyFingerprint: String
    ) -> Bool {
        guard let normalizedFingerprint = normalizedFingerprint(protocolPublicKeyFingerprint) else {
            return false
        }
        let normalizedAlgorithm = protocolSigningAlgorithm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAlgorithm.isEmpty else {
            return false
        }

        let stableCurrentDeviceId = normalizedTrustedDeviceIdentifier(preferredCurrentDeviceId)

        var candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: device.id))
        candidates.formUnion(PeerIdentityAliasResolver.aliasKeys(for: device))
        candidates.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: stableCurrentDeviceId))
        if let ipAddress = device.ipAddress {
            candidates.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: ipAddress))
        }
        guard !candidates.isEmpty else {
            return false
        }

        return upsertAuthoritativeTrustedDevice(
            preferredRecordId: device.id,
            candidateAliases: candidates,
            name: device.name,
            platform: device.platform,
            ipAddress: device.ipAddress,
            protocolSigningAlgorithm: normalizedAlgorithm,
            protocolPublicKeyFingerprint: normalizedFingerprint,
            preferredCurrentDeviceId: stableCurrentDeviceId,
            connectableContext: connectableContext(from: device)
        )
    }

    public func upsertCurrentPathAuthority(
        deviceId: String,
        name: String,
        platform: DevicePlatform = .unknown,
        ipAddress: String? = nil,
        protocolSigningAlgorithm: String,
        protocolPublicKeyFingerprint: String,
        connectableContext: TrustedDevice.ConnectableContext? = nil
    ) {
        guard let normalizedFingerprint = normalizedFingerprint(protocolPublicKeyFingerprint) else { return }
        let normalizedAlgorithm = protocolSigningAlgorithm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAlgorithm.isEmpty else { return }
        guard let stableCurrentDeviceId = normalizedTrustedDeviceIdentifier(deviceId) else { return }

        var candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: stableCurrentDeviceId))
        if let ipAddress {
            candidates.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: ipAddress))
        }
        if candidates.isEmpty {
            candidates.insert(stableCurrentDeviceId.lowercased())
        }

        _ = upsertAuthoritativeTrustedDevice(
            preferredRecordId: stableCurrentDeviceId,
            candidateAliases: candidates,
            name: name,
            platform: platform,
            ipAddress: ipAddress,
            protocolSigningAlgorithm: normalizedAlgorithm,
            protocolPublicKeyFingerprint: normalizedFingerprint,
            preferredCurrentDeviceId: stableCurrentDeviceId,
            connectableContext: connectableContext
        )
    }

    /// 合并 CloudKit 同步的可信设备（并集策略：不自动删除本地设备）
    public func mergeFromCloud(_ devices: [TrustedDevice]) {
        guard !devices.isEmpty else { return }

        var changed = false

        for remote in devices {
            guard !remote.id.isEmpty else { continue }

            if let idx = trustedDevices.firstIndex(where: { $0.id == remote.id }) {
                var current = trustedDevices[idx]

                if !remote.name.isEmpty, remote.name != current.name {
                    current.name = remote.name
                    changed = true
                }
                if remote.platform != .unknown, remote.platform != current.platform {
                    current.platform = remote.platform
                    changed = true
                }
                if let ip = remote.ipAddress, !ip.isEmpty, ip != current.ipAddress {
                    current.ipAddress = ip
                    changed = true
                }
                if let algorithm = remote.protocolSigningAlgorithm, !algorithm.isEmpty, algorithm != current.protocolSigningAlgorithm {
                    current.protocolSigningAlgorithm = algorithm
                    changed = true
                }
                if let fingerprint = normalizedFingerprint(remote.protocolPublicKeyFingerprint),
                   fingerprint != current.protocolPublicKeyFingerprint {
                    current.protocolPublicKeyFingerprint = fingerprint
                    changed = true
                }
                if let currentDeviceId = remote.currentDeviceId, !currentDeviceId.isEmpty, currentDeviceId != current.currentDeviceId {
                    current.currentDeviceId = currentDeviceId
                    changed = true
                }
                if let known = remote.knownDeviceIds {
                    let merged = mergedKnownDeviceIds(existing: current.knownDeviceIds, adding: known)
                    if merged != current.knownDeviceIds {
                        current.knownDeviceIds = merged
                        changed = true
                    }
                }
                if let lifecycle = remote.currentPathLifecycleState, lifecycle != current.currentPathLifecycleState {
                    current.currentPathLifecycleState = lifecycle
                    changed = true
                }
                let mergedContext = mergedConnectableContext(current.connectableContext, with: remote.connectableContext)
                if mergedContext != current.connectableContext {
                    current.connectableContext = mergedContext
                    changed = true
                }
                // addedAt：取更早的时间，保持“首次信任时间”语义
                if remote.addedAt < current.addedAt {
                    current.addedAt = remote.addedAt
                    changed = true
                }

                if changed {
                    trustedDevices[idx] = current
                }
            } else {
                trustedDevices.append(remote)
                changed = true
            }
        }

        if changed {
            save()
        }
    }

    public func untrust(deviceId: String) {
        trustedDevices.removeAll { $0.id == deviceId }
        save()
    }

    public func clearAll() {
        trustedDevices.removeAll()
        save()
    }

    private func load() {
        trustedDevices = (Self.trustedDevicesStore.load() ?? []).map(migratedTrustedDeviceRecord)
    }

    private func save() {
        try? Self.trustedDevicesStore.save(trustedDevices)
    }

    private func normalizedFingerprint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    private func normalizedNameToken(_ raw: String?) -> String {
        guard let raw else { return "" }
        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    @discardableResult
    private func upsertAuthoritativeTrustedDevice(
        preferredRecordId: String,
        candidateAliases: Set<String>,
        name: String,
        platform: DevicePlatform,
        ipAddress: String?,
        protocolSigningAlgorithm: String,
        protocolPublicKeyFingerprint: String,
        preferredCurrentDeviceId: String?,
        connectableContext: TrustedDevice.ConnectableContext? = nil
    ) -> Bool {
        let matchingIndices = trustedDevices.indices.filter { index in
            let record = trustedDevices[index]
            if matches(record, candidates: candidateAliases) {
                return true
            }
            if let preferredCurrentDeviceId,
               normalizedTrustedDeviceIdentifier(resolvedCurrentDeviceId(for: record)) == preferredCurrentDeviceId {
                return true
            }
            return normalizedFingerprint(record.protocolPublicKeyFingerprint) == protocolPublicKeyFingerprint
        }

        let primaryIndex = preferredPrimaryAuthorityIndex(
            matchingIndices: matchingIndices,
            preferredCurrentDeviceId: preferredCurrentDeviceId,
            preferredFingerprint: protocolPublicKeyFingerprint
        )

        let canonicalCurrentDeviceId =
            preferredCurrentDeviceId
            ?? primaryIndex.flatMap { normalizedTrustedDeviceIdentifier(resolvedCurrentDeviceId(for: trustedDevices[$0])) }
            ?? normalizedTrustedDeviceIdentifier(preferredRecordId)

        guard let canonicalCurrentDeviceId else {
            return false
        }
        if primaryIndex == nil, preferredCurrentDeviceId == nil {
            // Do not mint a new authoritative trust record from an ephemeral alias
            // alone. The caller must first provide a persistent device id or match
            // an existing trusted alias chain.
            return false
        }

        let knownDeviceIds = Array(candidateAliases.union([canonicalCurrentDeviceId])).sorted()

        if let primaryIndex {
            var mergedRecord = trustedDevices[primaryIndex]
            for index in matchingIndices where index != primaryIndex {
                mergedRecord = mergedTrustedDeviceRecord(mergedRecord, with: trustedDevices[index])
            }
            if !name.isEmpty {
                mergedRecord.name = name
            }
            if platform != .unknown {
                mergedRecord.platform = platform
            }
            if let ipAddress, !ipAddress.isEmpty {
                mergedRecord.ipAddress = ipAddress
            }
            mergedRecord.connectableContext = mergedConnectableContext(
                mergedRecord.connectableContext,
                with: connectableContext
            )
            mergedRecord.protocolSigningAlgorithm = protocolSigningAlgorithm
            mergedRecord.protocolPublicKeyFingerprint = protocolPublicKeyFingerprint
            mergedRecord.currentDeviceId = canonicalCurrentDeviceId
            mergedRecord.knownDeviceIds = mergedKnownDeviceIds(
                existing: mergedRecord.knownDeviceIds,
                adding: knownDeviceIds
            )
            mergedRecord.currentPathLifecycleState = CurrentPathLifecycleState.active
            trustedDevices[primaryIndex] = mergedRecord

            for index in matchingIndices.sorted(by: >) where index != primaryIndex {
                trustedDevices.remove(at: index)
            }
        } else {
            trustedDevices.append(
                TrustedDevice(
                    id: canonicalCurrentDeviceId,
                    name: name,
                    platform: platform,
                    ipAddress: ipAddress,
                    protocolSigningAlgorithm: protocolSigningAlgorithm,
                    protocolPublicKeyFingerprint: protocolPublicKeyFingerprint,
                    currentDeviceId: canonicalCurrentDeviceId,
                    knownDeviceIds: knownDeviceIds,
                    currentPathLifecycleState: CurrentPathLifecycleState.active,
                    connectableContext: connectableContext
                )
            )
        }

        save()
        return true
    }

    private func preferredPrimaryAuthorityIndex(
        matchingIndices: [Int],
        preferredCurrentDeviceId: String?,
        preferredFingerprint: String
    ) -> Int? {
        matchingIndices.sorted { lhs, rhs in
            let lhsRecord = trustedDevices[lhs]
            let rhsRecord = trustedDevices[rhs]

            let lhsIdMatchesPreferred = normalizedTrustedDeviceIdentifier(lhsRecord.id) == preferredCurrentDeviceId
            let rhsIdMatchesPreferred = normalizedTrustedDeviceIdentifier(rhsRecord.id) == preferredCurrentDeviceId
            if lhsIdMatchesPreferred != rhsIdMatchesPreferred {
                return lhsIdMatchesPreferred && !rhsIdMatchesPreferred
            }

            let lhsCurrentMatchesPreferred =
                normalizedTrustedDeviceIdentifier(resolvedCurrentDeviceId(for: lhsRecord)) == preferredCurrentDeviceId
            let rhsCurrentMatchesPreferred =
                normalizedTrustedDeviceIdentifier(resolvedCurrentDeviceId(for: rhsRecord)) == preferredCurrentDeviceId
            if lhsCurrentMatchesPreferred != rhsCurrentMatchesPreferred {
                return lhsCurrentMatchesPreferred && !rhsCurrentMatchesPreferred
            }

            let lhsFingerprintMatches = normalizedFingerprint(lhsRecord.protocolPublicKeyFingerprint) == preferredFingerprint
            let rhsFingerprintMatches = normalizedFingerprint(rhsRecord.protocolPublicKeyFingerprint) == preferredFingerprint
            if lhsFingerprintMatches != rhsFingerprintMatches {
                return lhsFingerprintMatches && !rhsFingerprintMatches
            }

            let lhsHasAuthority = !(lhsRecord.protocolSigningAlgorithm?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true)
            let rhsHasAuthority = !(rhsRecord.protocolSigningAlgorithm?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true)
            if lhsHasAuthority != rhsHasAuthority {
                return lhsHasAuthority && !rhsHasAuthority
            }

            if lhsRecord.addedAt != rhsRecord.addedAt {
                return lhsRecord.addedAt < rhsRecord.addedAt
            }
            return lhsRecord.id < rhsRecord.id
        }.first
    }

    private func mergedTrustedDeviceRecord(
        _ primary: TrustedDevice,
        with duplicate: TrustedDevice
    ) -> TrustedDevice {
        var merged = primary

        if merged.name.isEmpty, !duplicate.name.isEmpty {
            merged.name = duplicate.name
        }
        if merged.platform == .unknown, duplicate.platform != .unknown {
            merged.platform = duplicate.platform
        }
        if (merged.ipAddress?.isEmpty ?? true), let duplicateIPAddress = duplicate.ipAddress, !duplicateIPAddress.isEmpty {
            merged.ipAddress = duplicateIPAddress
        }
        if merged.protocolSigningAlgorithm?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
           let duplicateAlgorithm = duplicate.protocolSigningAlgorithm?.trimmingCharacters(in: .whitespacesAndNewlines),
           !duplicateAlgorithm.isEmpty {
            merged.protocolSigningAlgorithm = duplicateAlgorithm
        }
        if merged.protocolPublicKeyFingerprint == nil,
           let duplicateFingerprint = normalizedFingerprint(duplicate.protocolPublicKeyFingerprint) {
            merged.protocolPublicKeyFingerprint = duplicateFingerprint
        }
        if merged.currentDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
           let duplicateCurrentDeviceId = normalizedTrustedDeviceIdentifier(resolvedCurrentDeviceId(for: duplicate)) {
            merged.currentDeviceId = duplicateCurrentDeviceId
        }
        if duplicate.addedAt < merged.addedAt {
            merged.addedAt = duplicate.addedAt
        }
        merged.connectableContext = mergedConnectableContext(
            merged.connectableContext,
            with: duplicate.connectableContext
        )

        var combinedKnownDeviceIds = mergedKnownDeviceIds(existing: merged.knownDeviceIds, adding: duplicate.id)
        if let duplicateCurrentDeviceId = duplicate.currentDeviceId {
            combinedKnownDeviceIds = mergedKnownDeviceIds(existing: combinedKnownDeviceIds, adding: duplicateCurrentDeviceId)
        }
        if let duplicateKnownDeviceIds = duplicate.knownDeviceIds {
            combinedKnownDeviceIds = mergedKnownDeviceIds(existing: combinedKnownDeviceIds, adding: duplicateKnownDeviceIds)
        }
        merged.knownDeviceIds = combinedKnownDeviceIds

        return merged
    }

    private func normalizedTrustedDeviceIdentifier(_ raw: String?) -> String? {
        canonicalPersistentTrustedDeviceIdentifier(raw)
    }

    private func mergedKnownDeviceIds(existing: [String]?, adding newValue: String) -> [String] {
        mergedKnownDeviceIds(existing: existing, adding: [newValue])
    }

    private func mergedKnownDeviceIds(existing: [String]?, adding newValues: [String]) -> [String] {
        Array(Set((existing ?? []) + newValues.filter { !$0.isEmpty })).sorted()
    }

    private func matches(_ device: TrustedDevice, candidates: Set<String>) -> Bool {
        !trustedAliasCandidates(for: device).isDisjoint(with: candidates)
    }

    private func currentPathDeviceMatches(_ device: TrustedDevice, deviceId: String) -> Bool {
        let candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
        guard !candidates.isEmpty else { return false }
        return !trustedAliasCandidates(for: device).isDisjoint(with: candidates)
    }

    private func uniqueNameMatchedTrustedDeviceIndices(for device: DiscoveredDevice) -> [Int] {
        let normalizedDeviceName = normalizedNameToken(device.name)
        guard !normalizedDeviceName.isEmpty else { return [] }

        let matches = trustedDevices.indices.filter { index in
            let trusted = trustedDevices[index]
            guard normalizedNameToken(trusted.name) == normalizedDeviceName else { return false }
            return trusted.platform == .unknown || device.platform == .unknown || trusted.platform == device.platform
        }

        return matches.count == 1 ? matches : []
    }

    private func resolvedCurrentDeviceId(for device: TrustedDevice) -> String {
        bestPersistentTrustedDeviceIdentifier(for: device) ?? device.id
    }

    private func trustedAliasCandidates(for device: TrustedDevice) -> Set<String> {
        var aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: device.id))
        aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: device.currentDeviceId))

        if let knownDeviceIds = device.knownDeviceIds {
            for knownDeviceId in knownDeviceIds {
                aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: knownDeviceId))
            }
        }

        if let ipAddress = device.ipAddress {
            aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: ipAddress))
        }

        if let context = device.connectableContext {
            if let ipAddress = context.lastResolvedIPAddress {
                aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: ipAddress))
            }
            if let bonjourAlias = bonjourAlias(from: context) {
                aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: bonjourAlias))
            }
        }

        return aliases
    }

    private func connectableContext(from device: DiscoveredDevice) -> TrustedDevice.ConnectableContext? {
        let bonjourServiceName = device.bonjourServiceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bonjourServiceType = device.bonjourServiceType?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bonjourServiceDomain = device.bonjourServiceDomain?.trimmingCharacters(in: .whitespacesAndNewlines)
        let services = Array(Set(device.services.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        let portMap = device.portMap.filter { !$0.key.isEmpty && $0.value > 0 }
        let ipAddress = device.ipAddress?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard bonjourServiceName?.isEmpty == false
                || bonjourServiceType?.isEmpty == false
                || bonjourServiceDomain?.isEmpty == false
                || !services.isEmpty
                || !portMap.isEmpty
                || ipAddress?.isEmpty == false else {
            return nil
        }

        return TrustedDevice.ConnectableContext(
            bonjourServiceName: bonjourServiceName,
            bonjourServiceType: bonjourServiceType,
            bonjourServiceDomain: bonjourServiceDomain,
            services: services,
            portMap: portMap,
            lastResolvedIPAddress: ipAddress
        )
    }

    private func connectableContext(from trustedDevice: TrustedDevice) -> TrustedDevice.ConnectableContext? {
        mergedConnectableContext(
            trustedDevice.connectableContext,
            with: TrustedDevice.ConnectableContext(lastResolvedIPAddress: trustedDevice.ipAddress)
        )
    }

    private func mergedConnectableContext(
        _ existing: TrustedDevice.ConnectableContext?,
        with update: TrustedDevice.ConnectableContext?
    ) -> TrustedDevice.ConnectableContext? {
        guard let existing else { return update }
        guard let update else { return existing }

        return TrustedDevice.ConnectableContext(
            bonjourServiceName: existing.bonjourServiceName ?? update.bonjourServiceName,
            bonjourServiceType: existing.bonjourServiceType ?? update.bonjourServiceType,
            bonjourServiceDomain: existing.bonjourServiceDomain ?? update.bonjourServiceDomain,
            services: Array(Set(existing.services).union(update.services)).sorted(),
            portMap: existing.portMap.merging(update.portMap) { _, latest in latest },
            lastResolvedIPAddress: existing.lastResolvedIPAddress ?? update.lastResolvedIPAddress
        )
    }

    private func bonjourAlias(from context: TrustedDevice.ConnectableContext) -> String? {
        guard let name = context.bonjourServiceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        let domain = context.bonjourServiceDomain?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDomain = (domain?.isEmpty == false ? domain! : "local.")
        return "bonjour:\(name)@\(resolvedDomain)"
    }

    private func canonicalPersistentTrustedDeviceIdentifier(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return PeerIdentityAliasResolver.persistentDeviceId(from: trimmed)
    }

    private func bestPersistentTrustedDeviceIdentifier(for device: TrustedDevice) -> String? {
        if let current = canonicalPersistentTrustedDeviceIdentifier(device.currentDeviceId) {
            return current
        }
        if let recordID = canonicalPersistentTrustedDeviceIdentifier(device.id) {
            return recordID
        }
        for knownDeviceId in device.knownDeviceIds ?? [] {
            if let known = canonicalPersistentTrustedDeviceIdentifier(knownDeviceId) {
                return known
            }
        }
        return nil
    }

    private func migratedTrustedDeviceRecord(_ device: TrustedDevice) -> TrustedDevice {
        var migrated = device
        migrated.currentDeviceId = bestPersistentTrustedDeviceIdentifier(for: device)
        return migrated
    }
}
