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
            currentPathLifecycleState: CurrentPathLifecycleState? = nil
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

    public func currentPathTrustRecord(fingerprint: String) -> TrustedDevice? {
        guard let normalized = normalizedFingerprint(fingerprint) else { return nil }
        return trustedDevices.first { device in
            device.protocolPublicKeyFingerprint == normalized &&
            (device.currentPathLifecycleState ?? .active) == .active
        }
    }

    public func evaluateCurrentPathBinding(
        deviceId: String,
        protocolPublicKeyFingerprint: String
    ) -> CurrentPathTrustConflict? {
        guard let normalized = normalizedFingerprint(protocolPublicKeyFingerprint) else { return nil }

        if let byFingerprint = trustedDevices.first(where: { $0.protocolPublicKeyFingerprint == normalized }) {
            switch byFingerprint.currentPathLifecycleState ?? .active {
            case .active:
                // The authoritative signing key is the stronger identity anchor.
                // If the same key now advertises a new deviceId, allow the session
                // to proceed and heal the stored deviceId/aliases after success.
                break
            case .reverificationRequired, .quarantined:
                return .quarantinedIdentity
            case .revoked:
                return .revokedIdentity
            }
        }

        if let byDevice = trustedDevices.first(where: { resolvedCurrentDeviceId(for: $0) == deviceId }),
           let pinnedFingerprint = byDevice.protocolPublicKeyFingerprint,
           pinnedFingerprint != normalized {
            switch byDevice.currentPathLifecycleState ?? .active {
            case .active:
                return .identityConflict
            case .reverificationRequired, .quarantined:
                return .quarantinedIdentity
            case .revoked:
                return .revokedIdentity
            }
        }

        return nil
    }

    public func trust(_ device: DiscoveredDevice) {
        let id = device.id
        var candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: id))
        candidates.formUnion(PeerIdentityAliasResolver.aliasKeys(for: device))
        guard !candidates.isEmpty else { return }

        if let idx = trustedDevices.firstIndex(where: { matches($0, candidates: candidates) }) {
            trustedDevices[idx].name = device.name
            trustedDevices[idx].platform = device.platform
            trustedDevices[idx].ipAddress = device.ipAddress
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
                    knownDeviceIds: Array(candidates).sorted()
                )
            )
        }
        save()
    }

    public func trustResolvedPeer(
        _ device: DiscoveredDevice,
        declaredDeviceId: String
    ) {
        let normalizedDeclaredDeviceId = declaredDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
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

        if let idx = trustedDevices.firstIndex(where: { matches($0, candidates: candidates) }) {
            trustedDevices[idx].name = device.name
            trustedDevices[idx].platform = device.platform
            trustedDevices[idx].ipAddress = device.ipAddress
            trustedDevices[idx].currentDeviceId = normalizedDeclaredDeviceId
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
                    currentDeviceId: normalizedDeclaredDeviceId,
                    knownDeviceIds: Array(candidates).sorted()
                )
            )
        }
        save()
    }

    public func upsertCurrentPathAuthority(
        deviceId: String,
        name: String,
        platform: DevicePlatform = .unknown,
        ipAddress: String? = nil,
        protocolSigningAlgorithm: String,
        protocolPublicKeyFingerprint: String
    ) {
        guard let normalizedFingerprint = normalizedFingerprint(protocolPublicKeyFingerprint) else { return }
        if let idx = trustedDevices.firstIndex(where: { $0.protocolPublicKeyFingerprint == normalizedFingerprint }) {
            trustedDevices[idx].name = name.isEmpty ? trustedDevices[idx].name : name
            if platform != .unknown {
                trustedDevices[idx].platform = platform
            }
            if let ipAddress, !ipAddress.isEmpty {
                trustedDevices[idx].ipAddress = ipAddress
            }
            trustedDevices[idx].protocolSigningAlgorithm = protocolSigningAlgorithm
            trustedDevices[idx].protocolPublicKeyFingerprint = normalizedFingerprint
            trustedDevices[idx].currentDeviceId = deviceId
            trustedDevices[idx].knownDeviceIds = mergedKnownDeviceIds(existing: trustedDevices[idx].knownDeviceIds, adding: deviceId)
            trustedDevices[idx].currentPathLifecycleState = .active
        } else {
            trustedDevices.append(
                TrustedDevice(
                    id: deviceId,
                    name: name,
                    platform: platform,
                    ipAddress: ipAddress,
                    protocolSigningAlgorithm: protocolSigningAlgorithm,
                    protocolPublicKeyFingerprint: normalizedFingerprint,
                    currentDeviceId: deviceId,
                    knownDeviceIds: [deviceId],
                    currentPathLifecycleState: .active
                )
            )
        }
        save()
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
        trustedDevices = Self.trustedDevicesStore.load() ?? []
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

    private func mergedKnownDeviceIds(existing: [String]?, adding newValue: String) -> [String] {
        mergedKnownDeviceIds(existing: existing, adding: [newValue])
    }

    private func mergedKnownDeviceIds(existing: [String]?, adding newValues: [String]) -> [String] {
        Array(Set((existing ?? []) + newValues.filter { !$0.isEmpty })).sorted()
    }

    private func matches(_ device: TrustedDevice, candidates: Set<String>) -> Bool {
        if candidates.contains(device.id.lowercased()) {
            return true
        }

        if let hostAlias = PeerIdentityAliasResolver.hostAlias(fromIPAddress: device.ipAddress),
           candidates.contains(hostAlias) {
            return true
        }

        if let current = device.currentDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           candidates.contains(current) {
            return true
        }

        if let knownDeviceIds = device.knownDeviceIds {
            for known in knownDeviceIds {
                if candidates.contains(known.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                    return true
                }
            }
        }

        return false
    }

    private func resolvedCurrentDeviceId(for device: TrustedDevice) -> String {
        device.currentDeviceId ?? device.id
    }
}
