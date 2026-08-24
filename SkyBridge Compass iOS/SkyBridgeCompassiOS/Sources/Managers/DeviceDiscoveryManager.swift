//
// DeviceDiscoveryManager.swift
// SkyBridgeCompassiOS
//
// 跨平台设备发现管理器
// 使用 Bonjour/mDNS/DNS-SD 发现 iOS、macOS、Android、Windows、Linux 设备
//
// 最佳实践参考：
// - Apple Developer Documentation: Network.framework, NWBrowser
// - RFC 6762 (mDNS) 和 RFC 6763 (DNS-SD)
// - 跨平台兼容：统一服务类型 + TXT 记录格式
//

import Combine
import Darwin
import Foundation
import Network

import class SkyBridgeProtocolCore.BonjourRegistrationReadinessGate
import enum SkyBridgeProtocolCore.BonjourInteropProtocolContract
import enum SkyBridgeProtocolCore.PeerIdentityFusionPolicy
import enum SkyBridgeProtocolCore.SelfDeviceIdentityPolicy
import enum SkyBridgeProtocolCore.P2PInboundAdmissionPolicy

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Service Types

/// 跨平台服务类型定义
public enum DiscoveryServiceType: CaseIterable, Sendable, RawRepresentable {
    /// SkyBridge 主服务（所有平台）
    case skybridge

    /// SkyBridge QUIC 服务（高性能传输）
    case skybridgeQUIC

    /// SkyBridge 文件传输服务
    case skybridgeTransfer

    /// SkyBridge 远程桌面/远控服务
    case skybridgeRemote
    
    /// Apple Companion Link（Apple 设备间）
    case companionLink
    
    /// AirDrop 服务（Apple 设备）
    case airdrop
    
    /// SFTP/SSH 服务（开发者设备）
    case sftp
    
    /// SMB 文件共享（Windows/Linux/macOS）
    case smb
    
    /// HTTP 服务（通用 Web 服务）
    case http

    /// 局域网摄像头 RTSP 服务（仅用于预填用户确认的流地址）
    case rtsp
    
    /// 远程桌面（RDP 协议）
    case rdp
    
    /// 自定义 Android 服务（如果 Android 客户端使用）
    case androidShare

    public var rawValue: String {
        switch self {
        case .skybridge:
            return BonjourInteropProtocolContract.controlServiceType
        case .skybridgeQUIC:
            return BonjourInteropProtocolContract.legacyQuicPrimaryServiceType
        case .skybridgeTransfer:
            return BonjourInteropProtocolContract.fileTransferServiceType
        case .skybridgeRemote:
            return BonjourInteropProtocolContract.remoteControlServiceType
        case .companionLink:
            return BonjourInteropProtocolContract.companionLinkServiceType
        case .airdrop:
            return "_airdrop._tcp"
        case .sftp:
            return "_sftp-ssh._tcp"
        case .smb:
            return "_smb._tcp"
        case .http:
            return "_http._tcp"
        case .rtsp:
            return "_rtsp._tcp"
        case .rdp:
            return "_rdlink._tcp"
        case .androidShare:
            return "_androidshare._tcp"
        }
    }

    public init?(rawValue: String) {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let match = Self.allCases.first(where: {
            $0.rawValue.lowercased() == normalized
        }) else {
            return nil
        }
        self = match
    }

    /// 运行时可能浏览的全部 Bonjour 服务；Info.plist 的 NSBonjourServices 需要覆盖这份清单。
    public static var requiredBonjourPrivacyDeclarations: [String] {
        allCases.map(\.rawValue)
    }
    
    /// 服务的显示名称
    public var displayName: String {
        switch self {
        case .skybridge: return "SkyBridge"
        case .skybridgeQUIC: return "SkyBridge QUIC"
        case .skybridgeTransfer: return "File Transfer"
        case .skybridgeRemote: return "Remote Control"
        case .companionLink: return "Companion Link"
        case .airdrop: return "AirDrop"
        case .sftp: return "SFTP"
        case .smb: return "SMB Share"
        case .http: return "HTTP"
        case .rtsp: return "RTSP Camera"
        case .rdp: return "Remote Desktop"
        case .androidShare: return "Android Share"
        }
    }
    
    /// 是否是 SkyBridge 核心服务
    public var isSkyBridgeService: Bool {
        self == .skybridge || self == .skybridgeQUIC || self == .skybridgeTransfer
            || self == .skybridgeRemote
    }
}

private struct ValidatedBonjourAdvertisement {
    let skyBridgeProjection: BonjourInteropProtocolContract.DiscoveryProjection?
    let presentationFields: [String: String]

    var advertisesStrongOwnerAuthentication: Bool {
        skyBridgeProjection?.advertisesStrongOwnerAuthentication ?? false
    }
}

// MARK: - Discovery Mode

/// 发现模式
public enum DiscoveryMode: Sendable {
    /// 仅 SkyBridge 服务（默认，节能）
    case skybridgeOnly
    
    /// 扩展模式（包含常见服务）
    case extended
    
    /// 完整模式（所有支持的服务）
    case full
    
    /// 自定义服务类型
    case custom([DiscoveryServiceType])
    
    var serviceTypes: [DiscoveryServiceType] {
        switch self {
        case .skybridgeOnly:
            return [.skybridge, .skybridgeQUIC, .skybridgeTransfer, .skybridgeRemote]
        case .extended:
            return [
                .skybridge, .skybridgeQUIC, .skybridgeTransfer, .skybridgeRemote, .companionLink, .smb,
                .sftp
            ]
        case .full:
            return DiscoveryServiceType.allCases
        case .custom(let types):
            return types
        }
    }
}

/// A process-stable identity for one concrete Network.framework endpoint.
///
/// `NWEndpoint.debugDescription` is diagnostic text, not an identity contract. In
/// particular, using it as a dictionary key makes browse reconciliation depend on
/// framework formatting. Length-prefixed components also prevent a peer-controlled
/// Bonjour instance name from colliding with the service type or domain delimiters.
enum BonjourBrowseEndpointIdentity {
    static func key(for endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .service(let name, let type, let domain, let interface):
            return framedKey(
                kind: "service",
                components: [
                    normalized(name),
                    normalizedDNSComponent(type),
                    normalizedDNSComponent(domain, defaultValue: "local"),
                    normalized(interface?.name ?? "*")
                ]
            )

        case .hostPort(let host, let port):
            return framedKey(
                kind: "host-port",
                components: [normalized(String(describing: host)), String(port.rawValue)]
            )

        default:
            // Service and host/port endpoints cover Bonjour browse results and inbound
            // sockets. Keep uncommon endpoint kinds isolated instead of conflating them.
            return framedKey(
                kind: "other",
                components: [normalized(endpoint.debugDescription)]
            )
        }
    }

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    private static func normalizedDNSComponent(
        _ raw: String,
        defaultValue: String = ""
    ) -> String {
        var value = normalized(raw)
        while value.hasSuffix(".") {
            value.removeLast()
        }
        return value.isEmpty ? defaultValue : value
    }

    private static func framedKey(kind: String, components: [String]) -> String {
        ([kind] + components).map { component in
            "\(component.utf8.count):\(component)"
        }.joined(separator: "|")
    }
}

/// Reconciles the authoritative post-change browser snapshot with the bounded set
/// of advertisements for which the app currently keeps parsed state.
enum BonjourBrowseReconciliationPolicy {
    struct Decision: Equatable, Sendable {
        let selectedEndpointKeys: [String]
        let withdrawnEndpointKeys: [String]
    }

    static func decide<EndpointKeys: Sequence>(
        liveEndpointKeys: EndpointKeys,
        trackedEndpointKeys: Set<String>,
        capacity: Int
    ) -> Decision where EndpointKeys.Element == String {
        let boundedCapacity = max(0, capacity)
        var liveTrackedEndpointKeys = Set<String>()
        var newcomerMaxHeap: [String] = []
        var newcomerKeys = Set<String>()

        for endpointKey in liveEndpointKeys {
            if trackedEndpointKeys.contains(endpointKey) {
                liveTrackedEndpointKeys.insert(endpointKey)
            } else {
                insertBoundedSmallest(
                    endpointKey,
                    capacity: boundedCapacity,
                    heap: &newcomerMaxHeap,
                    members: &newcomerKeys
                )
            }
        }

        let retainedKeys = Array(
            liveTrackedEndpointKeys.sorted().prefix(boundedCapacity)
        )
        let remainingCapacity = boundedCapacity - retainedKeys.count
        let selected =
            retainedKeys
            + Array(newcomerMaxHeap.sorted().prefix(remainingCapacity))
        let selectedSet = Set(selected)

        return Decision(
            selectedEndpointKeys: selected,
            withdrawnEndpointKeys:
                trackedEndpointKeys
                .subtracting(selectedSet)
                .sorted()
        )
    }

    /// Maintains a max-heap containing only the lexicographically smallest `capacity`
    /// unique keys seen so far. This keeps browse-flood reconciliation O(capacity) in
    /// memory instead of copying every Network.framework result into another dictionary.
    private static func insertBoundedSmallest(
        _ key: String,
        capacity: Int,
        heap: inout [String],
        members: inout Set<String>
    ) {
        guard capacity > 0, !members.contains(key) else { return }

        if heap.count < capacity {
            members.insert(key)
            heap.append(key)
            siftUpMaxHeap(&heap, from: heap.index(before: heap.endIndex))
            return
        }

        guard let largestSelected = heap.first, key < largestSelected else { return }
        members.remove(largestSelected)
        members.insert(key)
        heap[0] = key
        siftDownMaxHeap(&heap, from: 0)
    }

    private static func siftUpMaxHeap(_ heap: inout [String], from startIndex: Int) {
        var childIndex = startIndex
        while childIndex > 0 {
            let parentIndex = (childIndex - 1) / 2
            guard heap[parentIndex] < heap[childIndex] else { return }
            heap.swapAt(parentIndex, childIndex)
            childIndex = parentIndex
        }
    }

    private static func siftDownMaxHeap(_ heap: inout [String], from startIndex: Int) {
        var parentIndex = startIndex
        while true {
            let leftChildIndex = parentIndex * 2 + 1
            guard leftChildIndex < heap.count else { return }
            let rightChildIndex = leftChildIndex + 1
            let largerChildIndex: Int
            if rightChildIndex < heap.count,
                heap[leftChildIndex] < heap[rightChildIndex]
            {
                largerChildIndex = rightChildIndex
            } else {
                largerChildIndex = leftChildIndex
            }
            guard heap[parentIndex] < heap[largerChildIndex] else { return }
            heap.swapAt(parentIndex, largerChildIndex)
            parentIndex = largerChildIndex
        }
    }
}

enum PeerIdentityAliasResolver {
    static func normalizedIdentifier(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }
        return raw.lowercased()
    }

    private static func isPlausibleStableDeviceIdentifierPayload(_ raw: String) -> Bool {
        guard raw.count >= 8 else { return false }
        guard !raw.contains(where: \.isWhitespace) else { return false }
        return raw.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || character == "-" || character == "_"
                    || character == ".")
        }
    }

    private static func isLiteralIPAddress(_ raw: String) -> Bool {
        let scopedToken = raw.split(separator: "%", maxSplits: 1).first.map(String.init) ?? raw
        return IPv4Address(scopedToken) != nil || IPv6Address(scopedToken) != nil
    }

    static func persistentDeviceId(from raw: String?) -> String? {
        guard let normalized = normalizedIdentifier(raw) else { return nil }
        if normalized.hasPrefix("id:") {
            let payload = String(normalized.dropFirst("id:".count))
            guard isPlausibleStableDeviceIdentifierPayload(payload) else { return nil }
            guard !isLiteralIPAddress(payload) else { return nil }
            return "id:\(payload)"
        }
        if normalized.hasPrefix("host:")
            || normalized.hasPrefix("peer:")
            || normalized.hasPrefix("bonjour:")
            || normalized.hasPrefix("recent:")
            || normalized.contains("@")
        {
            return nil
        }
        guard isPlausibleStableDeviceIdentifierPayload(normalized) else { return nil }
        guard !isLiteralIPAddress(normalized) else { return nil }
        return "id:\(normalized)"
    }

    /// Resolves only the presentation wrappers that may be covered by an
    /// already-authenticated SOA identity. This must not be used for discovery
    /// or unauthenticated trust lookup: endpoint aliases remain non-authority.
    static func authorityBoundPersistentDeviceId(from raw: String?) -> String? {
        guard var normalized = normalizedIdentifier(raw) else { return nil }
        while normalized.hasPrefix("recent:") {
            normalized.removeFirst("recent:".count)
        }
        if normalized.hasPrefix("mac:") {
            normalized.removeFirst("mac:".count)
        }
        return persistentDeviceId(from: normalized)
    }

    static func isEndpointAlias(_ raw: String?) -> Bool {
        guard let normalized = normalizedIdentifier(raw) else { return false }
        if normalized.hasPrefix("recent:") {
            return isEndpointAlias(String(normalized.dropFirst("recent:".count)))
        }
        if normalized.hasPrefix("host:")
            || normalized.hasPrefix("peer:")
            || normalized.hasPrefix("bonjour:")
        {
            return true
        }
        if normalized.hasPrefix("id:") {
            let payload = String(normalized.dropFirst("id:".count))
            return isLiteralIPAddress(payload)
        }
        return isLiteralIPAddress(normalized)
    }

    static func lookupCandidates(for identifier: String?) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            guard let normalized = normalizedIdentifier(raw),
                  !normalized.isEmpty,
                seen.insert(normalized).inserted
            else {
                return
            }
            ordered.append(normalized)
        }

        func appendDerived(_ raw: String?) {
            guard let normalized = normalizedIdentifier(raw) else { return }
            append(normalized)

            if normalized.hasPrefix("recent:") {
                appendDerived(String(normalized.dropFirst("recent:".count)))
            }

            if normalized.hasPrefix("id:") {
                append(String(normalized.dropFirst("id:".count)))
            } else if let persistent = persistentDeviceId(from: normalized) {
                append(persistent)
            }

            if let alias = hostAlias(from: normalized) {
                append(alias)
            }

            if let alias = hostAlias(fromIPAddress: normalized) {
                append(alias)
            }

            if let alias = bonjourAlias(from: normalized) {
                append(alias)
            }
        }

        appendDerived(identifier)
        return ordered
    }

    static func aliasKeys(for device: DiscoveredDevice) -> [String] {
        var keys = Set<String>()

        let normalizedId = device.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedId.isEmpty {
            keys.insert(normalizedId)
        }

        if let alias = hostAlias(from: device.id) {
            keys.insert(alias)
        }

        if let alias = bonjourAlias(
            name: device.bonjourServiceName,
            domain: device.bonjourServiceDomain
        ) {
            keys.insert(alias)
        } else if let alias = bonjourAlias(from: device.id) {
            keys.insert(alias)
        }

        return Array(keys)
    }

    static func resolveDeviceId(
        for endpoint: NWEndpoint,
        endpointKey: String? = nil,
        exactEndpointMap: [String: String],
        aliasMap: [String: String]
    ) -> String? {
        if let endpointKey,
            let exact = exactEndpointMap[endpointKey]
        {
            return exact
        }

        for alias in candidateAliases(for: endpoint, endpointKey: endpointKey) {
            if let mapped = aliasMap[alias] {
                return mapped
            }
        }

        return nil
    }

    private static func candidateAliases(for endpoint: NWEndpoint, endpointKey: String? = nil)
        -> [String]
    {
        var keys = Set<String>()
        if let endpointKey {
            let normalized = endpointKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty {
                keys.insert(normalized)
            }
        }

        switch endpoint {
        case .service(let name, _, let domain, _):
            if let alias = bonjourAlias(name: name, domain: domain) {
                keys.insert(alias)
            }
        case .hostPort(let host, _):
            if let alias = hostAlias(fromIPAddress: String(describing: host)) {
                keys.insert(alias)
            }
        default:
            break
        }

        return Array(keys)
    }

    private static func hostAlias(from identifier: String) -> String? {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("host:") {
            return hostAlias(fromIPAddress: String(normalized.dropFirst("host:".count)))
        }
        if normalized.hasPrefix("peer:") {
            return hostAlias(fromIPAddress: String(normalized.dropFirst("peer:".count)))
        }
        return nil
    }

    static func hostAlias(fromIPAddress raw: String?) -> String? {
        guard var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !token.isEmpty
        else {
            return nil
        }

        if token.hasPrefix("host:") {
            token = String(token.dropFirst("host:".count))
        } else if token.hasPrefix("peer:") {
            token = String(token.dropFirst("peer:".count))
        }

        if token.hasPrefix("["),
           let closeBracket = token.firstIndex(of: "]"),
            closeBracket > token.startIndex
        {
            token = String(token[token.index(after: token.startIndex)..<closeBracket])
        }

        if let percent = token.firstIndex(of: "%") {
            token = String(token[..<percent])
        }

        if token.contains(":"),
           let dot = token.lastIndex(of: "."),
            token[token.index(after: dot)...].allSatisfy({ $0.isNumber })
        {
            token = String(token[..<dot])
        } else {
            let parts = token.split(separator: ".")
            if parts.count == 5,
               parts.dropLast().allSatisfy({ Int($0) != nil }),
               let port = Int(parts.last ?? ""),
                (0...65535).contains(port)
            {
                token = parts.dropLast().map(String.init).joined(separator: ".")
            }
        }

        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, isLiteralIPAddress(normalized) else { return nil }
        return "host:\(normalized)"
    }

    private static func bonjourAlias(from identifier: String) -> String? {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.lowercased().hasPrefix("bonjour:") else { return nil }

        let payload = String(normalized.dropFirst("bonjour:".count))
        let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return nil }
        let domain = parts.count > 1 ? parts[1] : "local."
        return bonjourAlias(name: name, domain: domain)
    }

    private static func bonjourAlias(name: String?, domain: String?) -> String? {
        guard let rawName = name?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawName.isEmpty
        else {
            return nil
        }

        let rawDomain = domain?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "local."
        let normalizedDomain: String
        if rawDomain.isEmpty {
            normalizedDomain = "local."
        } else if rawDomain.hasSuffix(".") {
            normalizedDomain = rawDomain.lowercased()
        } else {
            normalizedDomain = "\(rawDomain.lowercased())."
        }

        return "bonjour:\(rawName.lowercased())@\(normalizedDomain)"
    }
}

/// Projects authenticated session state onto exactly one cached discovery identity.
/// Endpoint and Bonjour aliases are intentionally absent: they are peer-controlled
/// routing hints and cannot authorize trust on a different discovery row.
enum DiscoveryConnectionLivenessProjectionPolicy {
    struct Projection: Equatable, Sendable {
        let deviceId: String
        let isConnected: Bool
        let isTrusted: Bool
    }

    static func projection(
        presentedDeviceId: String,
        cachedDeviceIds: Set<String>,
        isConnected: Bool,
        authenticatedSessionIsTrusted: Bool
    ) -> Projection? {
        let trimmedDeviceId =
            presentedDeviceId
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDeviceId.isEmpty else { return nil }

        let stableDeviceId = PeerIdentityAliasResolver.persistentDeviceId(
            from: trimmedDeviceId
        )
        let exactDeviceId: String
        if let stableDeviceId, cachedDeviceIds.contains(stableDeviceId) {
            exactDeviceId = stableDeviceId
        } else if cachedDeviceIds.contains(trimmedDeviceId) {
            exactDeviceId = trimmedDeviceId
        } else {
            return nil
        }

        return Projection(
            deviceId: exactDeviceId,
            isConnected: isConnected,
            isTrusted: isConnected
                && authenticatedSessionIsTrusted
                && stableDeviceId == exactDeviceId
        )
    }
}

// MARK: - DeviceDiscoveryManager

private enum IOSPrimaryBonjourCapabilityPolicy {
    static func supportedCapabilities(fileTransferReady: Bool) -> Set<String> {
        var capabilities = Set(BonjourInteropProtocolContract.basePrimaryCapabilities)
        if fileTransferReady {
            capabilities.formUnion(
                BonjourInteropProtocolContract.fileTransferCapabilities.filter {
                    $0 != BonjourInteropProtocolContract.classicResumeCapability
                }
            )
        }
        return capabilities
    }
}

/// 跨平台设备发现管理器
/// 支持发现 iOS、iPadOS、macOS、Android、Windows、Linux 设备
@MainActor
public class DeviceDiscoveryManager: ObservableObject {
    public static let instance = DeviceDiscoveryManager()
    nonisolated static let bonjourNoAuthDNSCode: Int32 = -65555
    nonisolated static let bonjourPolicyDeniedDNSCode: Int32 = -65570

    enum BonjourAuthorizationFailure: String, Sendable, Equatable {
        case noAuth = "NoAuth"
        case policyDenied = "PolicyDenied"
    }
    
    // MARK: - Published Properties
    
    /// 发现的设备列表
    @Published public private(set) var discoveredDevices: [DiscoveredDevice] = []
    
    /// 按平台分组的设备
    @Published public private(set) var devicesByPlatform: [DevicePlatform: [DiscoveredDevice]] = [:]
    
    /// 是否正在发现
    @Published public private(set) var isDiscovering: Bool = false
    
    /// 是否正在广播
    @Published public private(set) var isAdvertising: Bool = false

    /// 当前广播启动是否卡在「等待用户授权本地网络访问」。
    ///
    /// This is a user-actionable blocker, not an internal error, so it must be observable
    /// by the UI instead of only appearing as a failed startup in the log.
    @Published public private(set) var isAwaitingLocalNetworkAuthorization: Bool = false

    /// 是否有浏览器因本地网络授权被拒而无法运行。
    ///
    /// Denied local-network access breaks *both* directions at once: nothing is discovered and
    /// nothing is published. Browsing already tracked this internally for its retry logic, but it
    /// was never surfaced, so the app simply looked empty. Publishing it lets one banner explain
    /// both halves of the symptom.
    @Published public private(set) var isBrowseAuthorizationBlocked: Bool = false

    public struct AdvertisingReadinessSnapshot: Equatable, Sendable {
        public let isAdvertising: Bool
        public let listenerPresent: Bool
        public let handlerInstalled: Bool
        public let requestedPort: UInt16?
        public let actualPort: UInt16?
        public let serviceType: String
        public let readyGeneration: UInt64
        public let authorityDeviceID: String?
        public let authorityAlgorithm: ProtocolSigningAlgorithm?
        public let authorityFingerprint: String?

        public var isReady: Bool {
            isAdvertising
                && listenerPresent
                && handlerInstalled
                && serviceType == DiscoveryServiceType.skybridge.rawValue
                && readyGeneration > 0
                && actualPort.map { $0 > 0 } == true
        }

        public func isReady(for requestedPort: UInt16) -> Bool {
            guard isReady,
                  self.requestedPort == requestedPort,
                  let actualPort else {
                return false
            }
            return requestedPort == 0 || actualPort == requestedPort
        }

        func isReady(
            for requestedPort: UInt16,
            authority: ProtocolIdentitySnapshot
        ) -> Bool {
            isReady(for: requestedPort)
                && authorityDeviceID == authority.deviceId
                && authorityAlgorithm == authority.signingAlgorithm
                && authorityFingerprint == authority.signingPublicKeyFingerprint
        }
    }
    
    /// 最后一次错误
    @Published public private(set) var error: Error?
    
    /// 当前发现模式
    @Published public var discoveryMode: DiscoveryMode = .skybridgeOnly
    
    // MARK: - Private Properties
    
    /// Bonjour 浏览器（每种服务类型一个）
    private struct BrowserLease {
        let generation: UUID
        let browser: NWBrowser
    }
    private var browsers: [DiscoveryServiceType: BrowserLease] = [:]
    
    /// Bonjour 监听器（广播用）
    private var listener: NWListener?
    private var listenerGeneration: UInt64 = 0

    private static let advertisingStartupTimeoutSeconds: TimeInterval = 8
    /// Publishing a Bonjour service triggers the iOS local-network permission alert on
    /// first use. Until the user answers it the listener stays in `.waiting`, which is a
    /// user-gated wait rather than a hung startup, so the 8 s hang deadline must not
    /// apply. Extending it once keeps the listener alive so it can reach `.ready` the
    /// moment permission is granted.
    private static let advertisingAuthorizationWaitTimeoutSeconds: TimeInterval = 45
    private static let maximumInboundAdmissionConnections =
        P2PInboundAdmissionPolicy.maximumConcurrentConnections
    private static let maximumInboundAdmissionConnectionsPerEndpoint =
        P2PInboundAdmissionPolicy.maximumConcurrentConnectionsPerRemoteEndpoint
    private enum InboundAdmissionPhase {
        case preReady
        case protocolReady
    }
    private struct InboundAdmissionConnection {
        let connection: NWConnection
        let endpointKey: String
        let firstFrameDeadline: ContinuousClock.Instant
        var phase: InboundAdmissionPhase
    }
    private var inboundAdmissionConnections: [
        ObjectIdentifier: InboundAdmissionConnection
    ] = [:]
    private var advertisingStartupTask: Task<Void, Error>?
    private var advertisingStartupTaskPort: UInt16?
    private var advertisingStartupTaskAuthority: ProtocolIdentitySnapshot?
    private var advertisingStartupTaskGeneration: UInt64 = 0
    private var advertisingAuthorityUpdateGeneration: UInt64 = 0
    private var advertisingStartupContinuation: CheckedContinuation<Void, Error>?
    private var advertisingStartupTimeoutTask: Task<Void, Never>?
    private var advertisingReadinessGate: BonjourRegistrationReadinessGate?
    private var advertisingRequestedPort: UInt16?
    private var advertisingActualPort: UInt16?
    private var advertisingServiceType: String = DiscoveryServiceType.skybridge.rawValue
    private var advertisingHandlerInstalled: Bool = false
    private var advertisingReadyGeneration: UInt64 = 0
    private var advertisingAuthority: ProtocolIdentitySnapshot?
    /// True once the current startup has observed `.waiting` with the local-network
    /// authorization error. Also gates the one-shot deadline extension so a listener that
    /// keeps re-entering `.waiting` cannot postpone failure indefinitely.
    private var advertisingAuthorizationWaitObserved: Bool = false
    private var advertisingAuthorizationDeadlineExtended: Bool = false
    
    /// 设备缓存
    private static let maximumCachedDevices = 128
    private static let maximumEndpointMappings = 1_024
    private static let maximumAliasesPerDevice = 32
    private static let maximumBrowseResultsPerService = 256
    private var deviceCache: [String: DiscoveredDevice] = [:]

    /// endpoint debugDescription -> stable deviceId（用于处理 removed 事件时定位缓存项）
    private var endpointToDeviceId: [String: String] = [:]

    /// 每个浏览器当前仍持有的 endpoint 快照；用于区分“设备静默在线”与“设备已真正离线”。
    private var liveBrowseEndpointKeysByServiceType: [DiscoveryServiceType: Set<String>] = [:]

    /// Authoritative live advertisements, partitioned by browser service type and exact
    /// endpoint key. A changed result replaces one snapshot and a removed result deletes it;
    /// aggregate services, TXT capabilities, and diagnostic ports are rebuilt from the
    /// remaining snapshots instead of growing monotonically for the process lifetime.
    struct BonjourAdvertisementSnapshot {
        var deviceId: String
        let endpointKey: String
        let serviceType: DiscoveryServiceType
        /// The exact live Network.framework service endpoint. `NWBrowser` may legally
        /// aggregate this endpoint with a nil interface and report route ownership in
        /// `NWBrowser.Result.interfaces` instead, so both values must remain process-local.
        let endpoint: NWEndpoint
        /// Interfaces observed on the same live browser result as `endpoint`.
        /// Reconstructing these from persisted metadata would lose AWDL ownership.
        let interfaces: [NWInterface]
        /// Unauthenticated discovery claim. It is retained only to prevent two
        /// conflicting strong tuples from being merged before the handshake.
        let protocolIdentityFingerprint: String?
        let device: DiscoveredDevice
    }
    private var advertisementSnapshotsByServiceType: [DiscoveryServiceType: [String: BonjourAdvertisementSnapshot]] = [:]

    /// host/bonjour 等别名 -> 稳定 deviceId，避免入站连接退化成临时 host 身份
    private var identityAliasToDeviceId: [String: String] = [:]

    /// 从已解析 browse endpoint 捕获的身份别名；TXT host 仅用于诊断，不能参与身份或路由归属。
    private var discoveryIdentityAliasesByDeviceId: [String: Set<String>] = [:]
    
    /// 设备最后活动时间
    private var deviceLastActivity: [String: Date] = [:]
    
    /// 调度队列
    private let queue = DispatchQueue(label: "com.skybridge.discovery", qos: .userInitiated)
    
    /// 设备清理定时器
    private var cleanupTimer: Timer?

    /// 合并高频 Bonjour 浏览事件的去抖任务：避免每个 add/change/remove 都同步触发 O(n²) 去重+重建
    /// （主线程负担、扫描时耗电/卡顿）。在最后一个事件后 ~250ms 统一重算一次。
    private var pendingDiscoveredDevicesUpdateTask: Task<Void, Never>?

    /// 周期性刷新定时器（省电策略：周期 refresh，而不是一直保持浏览器常驻）
    private var periodicRefreshTimer: Timer?
    private var periodicRefreshIntervalSeconds: TimeInterval = 0
    private var lastAlreadyRunningLogAt: Date?
    private var authorizationBlockedServiceTypes = Set<DiscoveryServiceType>()
    private var browserRecoveryTasks: [DiscoveryServiceType: Task<Void, Never>] = [:]
    private var browserRecoveryTaskTokens: [DiscoveryServiceType: UUID] = [:]
    private var authorizationRecoveryTasks: [DiscoveryServiceType: Task<Void, Never>] = [:]
    private var authorizationRecoveryAttempts: [DiscoveryServiceType: Int] = [:]
    /// Authorization is app-wide but `NWBrowser` reports failure per service type. Keep each
    /// service supervised while discovery remains desired, with one task per service and a
    /// capped retry state so a long-lived denial cannot overflow or become a busy loop.
    nonisolated private static let maximumAuthorizationRecoveryAttempt = 4
    
    /// 设备超时时间（秒）
    private let deviceTimeout: TimeInterval = 60
    
    /// 新连接回调
    public var onNewConnection: ((NWConnection, String) -> Void)?

    public var advertisingReadinessSnapshot: AdvertisingReadinessSnapshot {
        AdvertisingReadinessSnapshot(
            isAdvertising: isAdvertising,
            listenerPresent: listener != nil,
            handlerInstalled: advertisingHandlerInstalled,
            requestedPort: advertisingRequestedPort,
            actualPort: advertisingActualPort,
            serviceType: advertisingServiceType,
            readyGeneration: advertisingReadyGeneration,
            authorityDeviceID: advertisingAuthority?.deviceId,
            authorityAlgorithm: advertisingAuthority?.signingAlgorithm,
            authorityFingerprint: advertisingAuthority?.signingPublicKeyFingerprint
        )
    }

    enum AdvertisingStartupError: LocalizedError, Sendable {
        case timedOut(seconds: TimeInterval)
        case localNetworkAuthorizationPending(seconds: TimeInterval)
        case cancelledBeforeReady
        case superseded

        var errorDescription: String? {
            switch self {
            case .timedOut(let seconds):
                return "P2P Bonjour 广播监听器在 \(Int(seconds)) 秒内未进入 ready 状态"
            case .localNetworkAuthorizationPending(let seconds):
                return "P2P Bonjour 广播在 \(Int(seconds)) 秒内仍未获得本地网络访问授权"
            case .cancelledBeforeReady:
                return "P2P Bonjour 广播监听器在 ready 前被取消"
            case .superseded:
                return "P2P Bonjour 广播监听器启动被新的启动请求替换"
            }
        }
    }

    /// True when advertising failed only because the user has not answered the local-network
    /// permission prompt yet. Callers surface this as a user-actionable blocker rather than
    /// as an internal error.
    nonisolated static func isPendingLocalNetworkAuthorization(_ error: Error) -> Bool {
        if case AdvertisingStartupError.localNetworkAuthorizationPending = error { return true }
        if let nwError = error as? NWError { return isBonjourAuthorizationError(nwError) }
        return false
    }

    /// Advertising startup failures that a retry can still resolve.
    ///
    /// `superseded` and `cancelledBeforeReady` are caused by a newer start request or an
    /// explicit teardown, so retrying them would fight the current owner. Everything else
    /// (pending local-network authorization, startup timeout, transient `NWListener`
    /// failures such as a not-yet-released port) is recoverable and must be retried:
    /// without it a single failed startup leaves the device permanently unadvertised.
    ///
    /// Note the split of concerns: the *content* of the Bonjour TXT record stays strictly
    /// fail-closed (an unbound or stale identity is never published, because peers pin it),
    /// while *liveness* is supervised and retried indefinitely.
    nonisolated static func shouldRetryAdvertising(after error: Error) -> Bool {
        switch error {
        case is CancellationError:
            return false
        case let startupError as AdvertisingStartupError:
            switch startupError {
            case .timedOut, .localNetworkAuthorizationPending:
                return true
            case .cancelledBeforeReady, .superseded:
                return false
            }
        case let networkError as NWError:
            if isBonjourAuthorizationError(networkError)
                || shouldAutoRecoverBrowser(after: networkError)
            {
                return true
            }
            if case .posix(let code) = networkError {
                return code == .EADDRINUSE || code == .EADDRNOTAVAIL
            }
            return false
        default:
            return false
        }
    }

    nonisolated static func shouldFailClosedAfterAuthorityUpdateFailure(
        failedGeneration: UInt64,
        currentGeneration: UInt64,
        listenerStillMatches: Bool
    ) -> Bool {
        failedGeneration == currentGeneration && listenerStillMatches
    }

    private func resetAdvertisingReadiness(requestedPort: UInt16? = nil) {
        advertisingRequestedPort = requestedPort
        advertisingActualPort = nil
        advertisingServiceType = DiscoveryServiceType.skybridge.rawValue
        advertisingHandlerInstalled = false
        advertisingAuthority = nil
        advertisingReadinessGate = nil
        advertisingAuthorizationWaitObserved = false
        advertisingAuthorizationDeadlineExtended = false
        isAwaitingLocalNetworkAuthorization = false
    }

    private func appendListenerStatus(_ body: String) {
        SkyBridgeDiagnosticTrace.appendStatus("p2p-listener \(body)")
    }
    
    /// 本机设备名称
    private var deviceName: String {
        #if canImport(UIKit)
        return AppleMobileDeviceIdentity.currentSnapshot().deviceName
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }
    
    /// 本机平台
    private var localPlatform: DevicePlatform {
        #if os(iOS)
        return AppleMobileDeviceIdentity.currentSnapshot().platform
        #elseif os(macOS)
        return .macOS
        #else
        return .unknown
        #endif
    }
    
    /// 本机 OS 版本
    private var localOSVersion: String {
        #if canImport(UIKit)
        return AppleMobileDeviceIdentity.currentSnapshot().osVersion
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #endif
    }
    
    /// 本机型号
    private var localModel: String {
        #if canImport(UIKit)
        return AppleMobileDeviceIdentity.currentSnapshot().modelName
        #else
        return "Mac"
        #endif
    }

    /// 本机芯片信息（用于对端 UI 与诊断）
    private var localChip: String? {
        #if canImport(UIKit)
        return AppleMobileDeviceIdentity.currentSnapshot().chip
        #else
        return nil
        #endif
    }

    /// 本机稳定设备 ID（与 stableDeviceId 生成策略对齐）
    private var localProtocolIdentitySnapshot: ProtocolIdentitySnapshot?

    private var localStableDeviceId: String? {
        #if canImport(UIKit)
        guard let raw = localProtocolIdentitySnapshot?.deviceId.lowercased() else {
            return nil
        }
        return "id:\(raw)"
        #else
        return nil
        #endif
    }
    
    private init() {}

    nonisolated static func declaredBonjourServices(in bundle: Bundle = .main) -> Set<String> {
        let raw = bundle.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] ?? []
        return Set(
            raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    nonisolated static func hasLocalNetworkUsageDescription(in bundle: Bundle = .main) -> Bool {
        guard let raw = bundle.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
        else {
            return false
        }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func bonjourAuthorizationFailure(
        _ error: NWError
    ) -> BonjourAuthorizationFailure? {
        guard case .dns(let dnsError) = error else { return nil }
        switch dnsError {
        case bonjourNoAuthDNSCode:
            return .noAuth
        case bonjourPolicyDeniedDNSCode:
            return .policyDenied
        default:
            return nil
        }
    }

    nonisolated static func isBonjourAuthorizationError(_ error: NWError) -> Bool {
        bonjourAuthorizationFailure(error) != nil
        }

    nonisolated static func shouldAutoRecoverBrowser(after error: NWError) -> Bool {
        switch error {
        case .dns(let code):
            return [-65562, -65563, -65566, -65568, -65569, -65572].contains(code)
        case .posix(let code):
            return [
                POSIXErrorCode.ENETDOWN,
                .ENETUNREACH,
                .EHOSTUNREACH,
                .ECONNABORTED,
                .ECONNRESET,
                .ETIMEDOUT
            ].contains(code)
        case .tls:
            return false
        case .wifiAware:
        return false
        @unknown default:
            return false
        }
    }

    nonisolated static func nextAuthorizationRecoveryAttempt(after currentAttempt: Int) -> Int {
        min(max(currentAttempt, 0), maximumAuthorizationRecoveryAttempt - 1) + 1
    }

    nonisolated static func authorizationRecoveryDelay(forAttempt attempt: Int) -> TimeInterval? {
        switch attempt {
        case 1: return 2
        case 2: return 5
        case 3: return 10
        case maximumAuthorizationRecoveryAttempt...: return 30
        default: return nil
        }
    }
    
    // MARK: - Discovery Control
    
    /// 开始发现设备
    /// - Parameter mode: 发现模式
    public func startDiscovery(mode: DiscoveryMode? = nil) async throws {
        if let mode = mode {
            self.discoveryMode = mode
        }

        if isDiscovering {
            // 这里很容易被重复触发（UI/scenePhase/设置变更），加节流避免日志刷屏与内存压力
            let now = Date()
            if let lastLogAt = lastAlreadyRunningLogAt,
                now.timeIntervalSince(lastLogAt) > 5
            {
                lastAlreadyRunningLogAt = now
                SkyBridgeLogger.shared.debug("📡 设备发现已在运行，执行自愈检查")
            } else if lastAlreadyRunningLogAt == nil {
                lastAlreadyRunningLogAt = now
                SkyBridgeLogger.shared.debug("📡 设备发现已在运行，执行自愈检查")
            }

            // 关键修复：即使 isDiscovering=true，也要按当前模式补齐/重建浏览器，
            // 避免网络抖动或系统省电导致 NWBrowser 失效后“手动发现无效”。
            reconcileBrowsersForCurrentMode()
            startCleanupTimer()
            if periodicRefreshIntervalSeconds > 0 {
                startPeriodicRefreshTimer()
            }
            return
        }

        isDiscovering = true
        error = nil

        SkyBridgeLogger.shared.info("🔍 开始设备发现 (模式: \(String(describing: discoveryMode)))")
        reconcileBrowsersForCurrentMode()

        // 启动设备清理定时器
        startCleanupTimer()

        // 如果配置了周期刷新，则启动（否则为持续发现）
        if periodicRefreshIntervalSeconds > 0 {
            startPeriodicRefreshTimer()
        }
    }
    
    /// 停止发现设备
    public func stopDiscovery() {
        guard isDiscovering else { return }
        
        // 取消所有浏览器
        for (serviceType, lease) in browsers {
            lease.browser.cancel()
            withdrawAdvertisementSnapshots(for: serviceType)
            SkyBridgeLogger.shared.debug("⏹️ 停止浏览器: \(serviceType.rawValue)")
        }
        browsers.removeAll()
        liveBrowseEndpointKeysByServiceType.removeAll()
        
        // 停止清理定时器
        cleanupTimer?.invalidate()
        cleanupTimer = nil

        // 停止周期刷新
        periodicRefreshTimer?.invalidate()
        periodicRefreshTimer = nil
        authorizationBlockedServiceTypes.removeAll()
        isBrowseAuthorizationBlocked = false
        cancelBrowserRecoveryTasks()
        cancelAuthorizationRecoveryTasks()
        authorizationRecoveryAttempts.removeAll()
        
        isDiscovering = false
        SkyBridgeLogger.shared.info("⏹️ 设备发现已停止")
    }

    func retryAuthorizationBlockedBrowsers() {
        guard !authorizationBlockedServiceTypes.isEmpty else { return }
        let blockedTypes = authorizationBlockedServiceTypes
        authorizationBlockedServiceTypes.removeAll()
        isBrowseAuthorizationBlocked = false
        for serviceType in blockedTypes {
            authorizationRecoveryTasks[serviceType]?.cancel()
            authorizationRecoveryTasks.removeValue(forKey: serviceType)
            authorizationRecoveryAttempts.removeValue(forKey: serviceType)
        }
        if isDiscovering {
            reconcileBrowsersForCurrentMode()
        }
    }
    
    /// 刷新设备列表
    public func refresh() async {
        if !isDiscovering {
            deviceCache.removeAll()
            endpointToDeviceId.removeAll()
            identityAliasToDeviceId.removeAll()
            discoveryIdentityAliasesByDeviceId.removeAll()
            deviceLastActivity.removeAll()
            liveBrowseEndpointKeysByServiceType.removeAll()
            advertisementSnapshotsByServiceType.removeAll()
            updateDiscoveredDevices()
            try? await startDiscovery()
        } else {
            // Soft refresh only.  Keep the current cache alive and let the
            // active browser snapshots decide which devices are still present.
            reconcileBrowsersForCurrentMode()
            cleanupStaleDevices()
            updateDiscoveredDevices()
        }
    }

    /// 设置周期性刷新扫描间隔（秒）
    /// - 0 表示关闭（持续发现）
    public func setPeriodicRefreshInterval(seconds: Double) {
        // Guardrail: extremely small intervals create stop/start storms (NWBrowser churn) and can blow memory.
        // 0 = continuous discovery (no periodic refresh).
        let clamped: Double
        if seconds <= 0 {
            clamped = 0
        } else {
            clamped = max(5.0, seconds)
        }
        periodicRefreshIntervalSeconds = clamped

        periodicRefreshTimer?.invalidate()
        periodicRefreshTimer = nil

        guard isDiscovering, periodicRefreshIntervalSeconds > 0 else { return }
        startPeriodicRefreshTimer()
    }
    
    // MARK: - Advertising Control
    
    /// 开始广播服务（让其他平台发现我们）
    /// - Parameter port: 监听端口
    func startAdvertising(
        port: UInt16 = 9527,
        authority: ProtocolIdentitySnapshot
    ) async throws {
        if let existingTask = advertisingStartupTask {
            if advertisingStartupTaskPort == port,
                advertisingStartupTaskAuthority == authority
            {
                try await existingTask.value
                try Task.checkCancellation()
                return
            }

            // A different configuration supersedes the in-flight request. Do
            // not wait and then start: an explicit stop during that suspension
            // could otherwise be followed by this waiter resurrecting a new
            // listener. Advancing the generation first makes the replacement
            // the only request allowed to commit.
            existingTask.cancel()
            stopAdvertising()
            try Task.checkCancellation()
        }

        advertisingStartupTaskGeneration &+= 1
        let generation = advertisingStartupTaskGeneration
        let startupTask = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performStartAdvertising(
                port: port,
                authority: authority
            )
        }
        advertisingStartupTask = startupTask
        advertisingStartupTaskPort = port
        advertisingStartupTaskAuthority = authority

        defer {
            if advertisingStartupTaskGeneration == generation {
                advertisingStartupTask = nil
                advertisingStartupTaskPort = nil
                advertisingStartupTaskAuthority = nil
            }
        }
        try await startupTask.value
    }

    private func performStartAdvertising(
        port: UInt16,
        authority: ProtocolIdentitySnapshot
    ) async throws {
        if isAdvertising, listener != nil {
            let snapshot = advertisingReadinessSnapshot
            if snapshot.isReady(for: port, authority: authority) {
                SkyBridgeLogger.shared.debug("📡 广播已在运行且监听器已就绪")
                return
            }
            if snapshot.isReady(for: port) {
                try await updateAdvertisingAuthority(authority)
                return
            }

            SkyBridgeLogger.shared.warning(
                "⚠️ P2P Bonjour 广播状态缺少 ready 证明，正在重建监听器: requestedPort=\(port) actualPort=\(snapshot.actualPort.map(String.init) ?? "-") handlerInstalled=\(snapshot.handlerInstalled ? 1 : 0)"
            )
            appendListenerStatus(
                "unhealthy action=rebuild requestedPort=\(port) actualPort=\(snapshot.actualPort.map(String.init) ?? "-") handlerInstalled=\(snapshot.handlerInstalled ? 1 : 0)"
            )
            isAdvertising = false
        }

        if isAdvertising {
            isAdvertising = false
        }

        if let staleListener = listener {
            finishAdvertisingStartup(.failure(AdvertisingStartupError.superseded))
            listener = nil
            Self.cancelListener(staleListener)
            cancelAllInboundAdmissionConnections()
        }

        resetAdvertisingReadiness(requestedPort: port)
        
        // 创建 TXT 记录。Bonjour `deviceId` must be the same protocol authority
        // identity used by MessageA/PIB; Apple mobile/vendor IDs are aliases only.
        let txtRecord = try createTXTRecord(authority: authority)
        try Task.checkCancellation()
        
        // 创建监听器参数
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
        }
        
        do {
            listenerGeneration &+= 1
            if port > 0 {
                guard let boundPort = NWEndpoint.Port(rawValue: port) else {
                    throw NSError(
                        domain: "DeviceDiscoveryManager",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "无效监听端口: \(port)"]
                    )
                }
                // Bind on port only (no fixed host), so the listener can accept both IPv4/IPv6.
                listener = try NWListener(using: parameters, on: boundPort)
            } else {
                listener = try NWListener(using: parameters)
            }
        } catch {
            SkyBridgeLogger.shared.error("❌ 创建监听器失败: \(Self.diagnosticErrorSummary(error))")
            resetAdvertisingReadiness(requestedPort: port)
            self.error = error
            throw error
        }

        guard let activeListener = listener else {
            let startupError = AdvertisingStartupError.cancelledBeforeReady
            self.error = startupError
            throw startupError
        }
        let activeListenerGeneration = listenerGeneration
        advertisingReadinessGate = BonjourRegistrationReadinessGate()
        
        // 设置 Bonjour 服务广播
        activeListener.service = NWListener.Service(
            name: deviceName,
            type: DiscoveryServiceType.skybridge.rawValue,
            txtRecord: txtRecord
        )
        advertisingAuthority = authority
        localProtocolIdentitySnapshot = authority
        
        activeListener.stateUpdateHandler = { [weak self, weak activeListener] state in
            Task { @MainActor in
                guard let activeListener else { return }
                await self?.handleListenerStateChange(
                    state,
                    for: activeListener,
                    generation: activeListenerGeneration
                )
            }
        }

        activeListener.serviceRegistrationUpdateHandler = { [weak self, weak activeListener] change in
            Task { @MainActor in
                guard let activeListener else { return }
                await self?.handleServiceRegistrationChange(
                    change,
                    for: activeListener,
                    generation: activeListenerGeneration
                )
            }
        }
        
        activeListener.newConnectionHandler = { [weak self, weak activeListener] connection in
            Task { @MainActor in
                guard let self,
                    let activeListener,
                    self.listener === activeListener,
                    self.listenerGeneration == activeListenerGeneration
                else {
                    connection.cancel()
                    return
                }
                await self.handleNewIncomingConnection(connection)
            }
        }
        advertisingHandlerInstalled = true
        
        do {
            try await waitForAdvertisingReady(
                activeListener,
                generation: activeListenerGeneration
            )
        } catch {
            if listener === activeListener {
                listener = nil
            }
            isAdvertising = false
            resetAdvertisingReadiness(requestedPort: port)
            self.error = error
            throw error
        }

        SkyBridgeLogger.shared.info(
            "📡 开始广播服务: device_ref=\(Self.diagnosticReference(deviceName)) service=\(DiscoveryServiceType.skybridge.rawValue)"
        )
    }

    /// Rebinds the accepting listener for a new protocol identity authority.
    ///
    /// Network.framework registration callbacks do not carry a TXT epoch, so
    /// mutating `service` in place cannot prove whether a later `.add` belongs
    /// to the old or new authority. A new listener generation gives every
    /// callback exact ownership while already accepted TCP sessions continue
    /// independently of the accepting listener.
    func updateAdvertisingAuthority(
        _ authority: ProtocolIdentitySnapshot
    ) async throws {
        guard let activeListener = listener else {
            throw AdvertisingStartupError.cancelledBeforeReady
        }
        let requestedPort = advertisingRequestedPort
            ?? advertisingActualPort
            ?? activeListener.port?.rawValue
            ?? 0
        if advertisingReadinessSnapshot.isReady(
            for: requestedPort,
            authority: authority
        ) {
            return
        }

        advertisingAuthorityUpdateGeneration &+= 1
        let updateGeneration = advertisingAuthorityUpdateGeneration
        let replacedListenerGeneration = listenerGeneration
        do {
            try Task.checkCancellation()
            guard updateGeneration == advertisingAuthorityUpdateGeneration,
                  listener === activeListener,
                  listenerGeneration == replacedListenerGeneration else {
                throw AdvertisingStartupError.superseded
            }

            listenerGeneration &+= 1
            listener = nil
            Self.cancelListener(activeListener)
            cancelAllInboundAdmissionConnections()
            isAdvertising = false
            resetAdvertisingReadiness(requestedPort: requestedPort)

            try await performStartAdvertising(
                port: requestedPort,
                authority: authority
            )
            try Task.checkCancellation()
            guard updateGeneration == advertisingAuthorityUpdateGeneration,
                  advertisingReadinessSnapshot.isReady(
                    for: requestedPort,
                    authority: authority
                  ) else {
                throw AdvertisingStartupError.superseded
            }
            appendListenerStatus(
                "authority-rebound algorithm=\(authority.signingAlgorithm.rawValue) fingerprint=redacted registration=confirmed"
            )
        } catch {
            if Self.shouldFailClosedAfterAuthorityUpdateFailure(
                failedGeneration: updateGeneration,
                currentGeneration: advertisingAuthorityUpdateGeneration,
                listenerStillMatches: listener === activeListener || listener != nil
            ) {
                stopAdvertising()
            }
            throw error
        }
    }

    /// 停止广播服务
    public func stopAdvertising() {
        guard
            isAdvertising
                || listener != nil
                || advertisingStartupContinuation != nil
                || advertisingStartupTask != nil
        else { return }

        advertisingStartupTask?.cancel()
        advertisingStartupTask = nil
        advertisingStartupTaskPort = nil
        advertisingStartupTaskAuthority = nil
        advertisingStartupTaskGeneration &+= 1
        advertisingAuthorityUpdateGeneration &+= 1
        listenerGeneration &+= 1
        
        let activeListener = listener
        listener = nil
        finishAdvertisingStartup(.failure(AdvertisingStartupError.cancelledBeforeReady))
        if let activeListener { Self.cancelListener(activeListener) }
        cancelAllInboundAdmissionConnections()
        isAdvertising = false
        resetAdvertisingReadiness()
        
        SkyBridgeLogger.shared.info("📡 停止广播服务")
        appendListenerStatus("stopped")
    }
    
    // MARK: - Private Methods - Browser

    private func reconcileBrowsersForCurrentMode() {
        let desiredTypes = Set(discoveryMode.serviceTypes)
        authorizationBlockedServiceTypes.formIntersection(desiredTypes)

        let staleTypes = browsers.keys.filter { !desiredTypes.contains($0) }
        for stale in staleTypes {
            browsers[stale]?.browser.cancel()
            browsers.removeValue(forKey: stale)
            liveBrowseEndpointKeysByServiceType.removeValue(forKey: stale)
            withdrawAdvertisementSnapshots(for: stale)
            SkyBridgeLogger.shared.debug("⏹️ 停止非当前模式浏览器: \(stale.rawValue)")
        }

        for serviceType in discoveryMode.serviceTypes where browsers[serviceType] == nil {
            guard !authorizationBlockedServiceTypes.contains(serviceType) else {
                SkyBridgeLogger.shared.debug("⏸️ 跳过被授权/隐私策略阻断的浏览器: \(serviceType.rawValue)")
                continue
            }
            startBrowser(for: serviceType)
        }
    }

    private func scheduleBrowserRecovery(for serviceType: DiscoveryServiceType, reason: String) {
        guard isDiscovering else { return }
        guard discoveryMode.serviceTypes.contains(serviceType) else { return }

        browserRecoveryTasks[serviceType]?.cancel()
        let token = UUID()
        browserRecoveryTaskTokens[serviceType] = token
        browserRecoveryTasks[serviceType] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.browserRecoveryTaskTokens[serviceType] == token {
                    self.browserRecoveryTasks.removeValue(forKey: serviceType)
                    self.browserRecoveryTaskTokens.removeValue(forKey: serviceType)
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(900))
            } catch {
                return
            }
            guard self.isDiscovering else { return }
            guard self.discoveryMode.serviceTypes.contains(serviceType) else { return }
            guard self.browsers[serviceType] == nil else { return }

            SkyBridgeLogger.shared.info("🔁 重建浏览器: \(serviceType.rawValue) reason=\(reason)")
            self.startBrowser(for: serviceType)
        }
    }

    private func scheduleAuthorizationRecovery(for serviceType: DiscoveryServiceType) {
        guard isDiscovering else { return }
        guard discoveryMode.serviceTypes.contains(serviceType) else { return }
        guard authorizationBlockedServiceTypes.contains(serviceType) else { return }
        guard browsers[serviceType] == nil else { return }

        let nextAttempt = Self.nextAuthorizationRecoveryAttempt(
            after: authorizationRecoveryAttempts[serviceType] ?? 0
            )
        guard let delay = Self.authorizationRecoveryDelay(forAttempt: nextAttempt) else {
            return
        }

        authorizationRecoveryAttempts[serviceType] = nextAttempt
        authorizationRecoveryTasks[serviceType]?.cancel()
        authorizationRecoveryTasks[serviceType] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard self.isDiscovering else { return }
            guard self.discoveryMode.serviceTypes.contains(serviceType) else { return }
            guard self.authorizationBlockedServiceTypes.contains(serviceType) else { return }
            guard self.browsers[serviceType] == nil else { return }

            SkyBridgeLogger.shared.info(
                "🔁 本地网络授权恢复重试: \(serviceType.rawValue) attempt=\(nextAttempt) delay=\(Int(delay))s"
            )
            self.authorizationBlockedServiceTypes.remove(serviceType)
            self.startBrowser(for: serviceType)
        }
    }

    private func cancelBrowserRecoveryTasks() {
        for task in browserRecoveryTasks.values {
            task.cancel()
        }
        browserRecoveryTasks.removeAll()
        browserRecoveryTaskTokens.removeAll()
    }

    private func cancelAuthorizationRecoveryTasks() {
        for task in authorizationRecoveryTasks.values {
            task.cancel()
        }
        authorizationRecoveryTasks.removeAll()
    }

    /// 启动特定服务类型的浏览器
    private func startBrowser(for serviceType: DiscoveryServiceType) {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        let browser = NWBrowser(
            // 关键：必须使用 bonjourWithTXTRecord 才能在 Result.metadata 中拿到 TXT，
            // 否则 osVersion/modelName 等字段会长期显示为 "Unknown"（即使 macOS 端已正确广播）。
            for: .bonjourWithTXTRecord(type: serviceType.rawValue, domain: nil),
            using: parameters
        )
        
        let generation = UUID()
        browser.stateUpdateHandler = { [weak self, weak browser, serviceType] state in
            Task { @MainActor in
                guard let self, let browser,
                    self.isCurrentBrowser(
                        browser,
                        generation: generation,
                        for: serviceType
                    )
                else { return }
                await self.handleBrowserStateChange(
                    state,
                    for: serviceType,
                    browser: browser,
                    generation: generation
                )
            }
        }
        
        browser.browseResultsChangedHandler = {
            [weak self, weak browser, serviceType] results, changes in
            Task { @MainActor in
                guard let self, let browser,
                    self.isCurrentBrowser(
                        browser,
                        generation: generation,
                        for: serviceType
                    )
                else { return }
                await self.handleBrowseResults(
                    results,
                    changes: changes,
                    serviceType: serviceType,
                    browser: browser,
                    generation: generation
                )
            }
        }
        
        browsers[serviceType] = BrowserLease(generation: generation, browser: browser)
        browser.start(queue: queue)
        
        SkyBridgeLogger.shared.debug("🔍 启动浏览器: \(serviceType.rawValue)")
    }
    
    private func isCurrentBrowser(
        _ browser: NWBrowser,
        generation: UUID,
        for serviceType: DiscoveryServiceType
    ) -> Bool {
        guard let lease = browsers[serviceType] else { return false }
        return lease.generation == generation && lease.browser === browser
    }

    private func handleBrowserStateChange(
        _ state: NWBrowser.State,
        for serviceType: DiscoveryServiceType,
        browser: NWBrowser,
        generation: UUID
    ) async {
        guard isCurrentBrowser(browser, generation: generation, for: serviceType) else { return }
        switch state {
        case .ready:
            authorizationBlockedServiceTypes.remove(serviceType)
            isBrowseAuthorizationBlocked = !authorizationBlockedServiceTypes.isEmpty
            authorizationRecoveryTasks[serviceType]?.cancel()
            authorizationRecoveryTasks.removeValue(forKey: serviceType)
            authorizationRecoveryAttempts.removeValue(forKey: serviceType)
            SkyBridgeLogger.shared.debug("✅ 浏览器就绪: \(serviceType.rawValue)")
            
        case .failed(let error):
            self.error = error
            browsers.removeValue(forKey: serviceType)
            liveBrowseEndpointKeysByServiceType.removeValue(forKey: serviceType)
            withdrawAdvertisementSnapshots(for: serviceType)

            if let authorizationFailure = Self.bonjourAuthorizationFailure(error) {
                authorizationBlockedServiceTypes.insert(serviceType)
                isBrowseAuthorizationBlocked = true
                let declaredServices = Self.declaredBonjourServices()
                let hasUsageDescription = Self.hasLocalNetworkUsageDescription()
                if !declaredServices.contains(serviceType.rawValue) {
                    SkyBridgeLogger.shared.error(
                        "❌ 浏览器失败 (\(serviceType.rawValue)): \(authorizationFailure.rawValue)。当前服务类型未声明到 Info.plist 的 NSBonjourServices；iOS 会直接拒绝 DNSServiceBrowse。"
                    )
                } else if !hasUsageDescription {
                    SkyBridgeLogger.shared.error(
                        "❌ 浏览器失败 (\(serviceType.rawValue)): \(authorizationFailure.rawValue)。Info.plist 缺少 NSLocalNetworkUsageDescription，本地网络授权无法正常申请。"
                    )
                } else {
                    SkyBridgeLogger.shared.error(
                        "❌ 浏览器失败 (\(serviceType.rawValue)): \(authorizationFailure.rawValue)。本地网络权限当前未授权或已被系统策略拒绝；暂停普通自动重建，待用户在系统设置授权后再重试。"
                    )
                }
                scheduleAuthorizationRecovery(for: serviceType)
                return
            }

            authorizationBlockedServiceTypes.remove(serviceType)
            authorizationRecoveryTasks[serviceType]?.cancel()
            authorizationRecoveryTasks.removeValue(forKey: serviceType)
            authorizationRecoveryAttempts.removeValue(forKey: serviceType)
            SkyBridgeLogger.shared.error(
                "❌ 浏览器失败 (\(serviceType.rawValue)): \(Self.diagnosticErrorSummary(error))"
            )
            if Self.shouldAutoRecoverBrowser(after: error) {
                scheduleBrowserRecovery(for: serviceType, reason: "failed")
            }
            
        case .cancelled:
            SkyBridgeLogger.shared.debug("⏹️ 浏览器已取消: \(serviceType.rawValue)")
            browsers.removeValue(forKey: serviceType)
            liveBrowseEndpointKeysByServiceType.removeValue(forKey: serviceType)
            withdrawAdvertisementSnapshots(for: serviceType)
            scheduleBrowserRecovery(for: serviceType, reason: "cancelled")
            
        default:
            break
        }
    }
    
    private func handleBrowseResults(
        _ results: Set<NWBrowser.Result>,
        changes: Set<NWBrowser.Result.Change>,
        serviceType: DiscoveryServiceType,
        browser: NWBrowser,
        generation: UUID
    ) async {
        guard isCurrentBrowser(browser, generation: generation, for: serviceType) else { return }

        let trackedEndpointKeys = Set(
            advertisementSnapshotsByServiceType[serviceType]?.keys.map { $0 } ?? []
        )
        let decision = BonjourBrowseReconciliationPolicy.decide(
            liveEndpointKeys: results.lazy.map {
                BonjourBrowseEndpointIdentity.key(for: $0.endpoint)
            },
            trackedEndpointKeys: trackedEndpointKeys,
            capacity: Self.maximumBrowseResultsPerService
        )
        let selectedEndpointKeys = Set(decision.selectedEndpointKeys)
        liveBrowseEndpointKeysByServiceType[serviceType] = selectedEndpointKeys

        var resultByEndpointKey: [String: NWBrowser.Result] = [:]
        resultByEndpointKey.reserveCapacity(selectedEndpointKeys.count)
        for result in results {
            let endpointKey = BonjourBrowseEndpointIdentity.key(for: result.endpoint)
            guard selectedEndpointKeys.contains(endpointKey) else { continue }
            // A key describes the complete Network.framework route tuple, so duplicate
            // keys are equivalent for reconciliation. Never trap on peer-controlled input.
            if resultByEndpointKey[endpointKey] == nil {
                resultByEndpointKey[endpointKey] = result
            }
        }

        // The complete post-change `results` snapshot is authoritative for removals.
        // This closes the hole where truncating an unordered `changes` set could leave
        // withdrawn advertisements alive indefinitely.
        if !decision.withdrawnEndpointKeys.isEmpty {
            let protectedIdentifiers = P2PConnectionManager.instance.protectedDiscoveryIdentifiers
            let activeIdentifiers = P2PConnectionManager.instance.activeDiscoveryIdentifiers
            let snapshots = advertisementSnapshotsByServiceType[serviceType]
            for endpointKey in decision.withdrawnEndpointKeys {
                removeAdvertisementSnapshot(
                    endpointKey: endpointKey,
                    fallbackDeviceId: snapshots?[endpointKey]?.deviceId
                        ?? endpointToDeviceId[endpointKey]
                        ?? endpointKey,
                    serviceType: serviceType,
                    protectedIdentifiers: protectedIdentifiers,
                    activeIdentifiers: activeIdentifiers
                )
            }
            scheduleDiscoveredDevicesUpdate()
        }

        var changedOrAddedEndpointKeys = Set<String>()
        changedOrAddedEndpointKeys.reserveCapacity(
            min(changes.count, Self.maximumBrowseResultsPerService)
        )
        for change in changes {
            switch change {
            case .added(let result):
                let endpointKey = BonjourBrowseEndpointIdentity.key(for: result.endpoint)
                if selectedEndpointKeys.contains(endpointKey) {
                    changedOrAddedEndpointKeys.insert(endpointKey)
                }
                
            case .changed(old: _, new: let result, flags: _):
                let endpointKey = BonjourBrowseEndpointIdentity.key(for: result.endpoint)
                if selectedEndpointKeys.contains(endpointKey) {
                    changedOrAddedEndpointKeys.insert(endpointKey)
                }
                
            case .removed, .identical:
                break
                
            @unknown default:
                break
            }
        }

        // New selected results are parsed even if Network.framework omitted a matching
        // change record; changed results refresh TXT metadata. Sorting the selected keys
        // makes admission independent of Set iteration order.
        for endpointKey in decision.selectedEndpointKeys
        where !trackedEndpointKeys.contains(endpointKey)
            || changedOrAddedEndpointKeys.contains(endpointKey)
        {
            guard let result = resultByEndpointKey[endpointKey] else { continue }
            await handleDeviceAdded(result, serviceType: serviceType)
        }
    }
    
    // MARK: - Private Methods - Device Handling
    
    private func handleDeviceAdded(_ result: NWBrowser.Result, serviceType: DiscoveryServiceType)
        async
    {
        guard let advertisement = extractTXTRecord(
            from: result,
            serviceType: serviceType
        ) else {
            return
        }
        let device = await createDevice(
            from: result,
            serviceType: serviceType,
            advertisement: advertisement
        )
        
        // 过滤自己（同名同平台 / 本机稳定 ID / loopback 地址）
        if isSelfDevice(device) {
            return
        }
        let protocolIdentityFingerprint = advertisement.skyBridgeProjection?
            .protocolPublicKeyFingerprint
        guard !hasConflictingAdvertisementIdentity(
            deviceId: device.id,
            protocolIdentityFingerprint: protocolIdentityFingerprint
        ) else {
            SkyBridgeLogger.shared.error(
                "❌ 拒绝冲突的 Bonjour 强身份声明；路由未合并"
            )
            return
        }
        guard admitDiscoveryDeviceIfNeeded(device.id) else { return }
        
        replaceAdvertisementSnapshot(
            device,
            endpoint: result.endpoint,
            interfaces: result.interfaces,
            endpointKey: BonjourBrowseEndpointIdentity.key(for: result.endpoint),
            serviceType: serviceType,
            protocolIdentityFingerprint: protocolIdentityFingerprint
        )
        recordDiscoveryAliases(
            identityAliases(from: result),
            deviceId: device.id
        )
        deviceLastActivity[device.id] = Date()
        scheduleDiscoveredDevicesUpdate()

        SkyBridgeLogger.shared.info(
            "➕ 发现设备: device_ref=\(Self.diagnosticReference(device.id)) platform=\(device.platform.rawValue) via=\(serviceType.rawValue)"
        )
    }

    /// 从 NWBrowser.Result 创建设备对象
    private func createDevice(
        from result: NWBrowser.Result,
        serviceType: DiscoveryServiceType,
        advertisement: ValidatedBonjourAdvertisement
    ) async
        -> DiscoveredDevice
    {
        let endpoint = result.endpoint
        let txtRecord = advertisement.presentationFields
        
        // Bonjour 实例名（连接用）。只接受真实服务实例名，避免 id:/host:/UUID/IP 被伪装成 SOA 身份。
        let rawBonjourName = extractDeviceName(from: endpoint)
        let bonjourName = BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(rawBonjourName)
        let displayBonjourName = bonjourName ?? "Unknown Device"
        // 设备主键：使用“物理身份 key”（忽略 serviceType），避免同一设备多服务重复展示
        let id = stableDeviceId(
            from: endpoint,
            txtRecord: txtRecord,
            sanitizedBonjourName: bonjourName,
            claimedDeviceId: advertisement.skyBridgeProjection?.deviceId
        )
        
        // 解析 TXT 记录
        let platform = detectPlatform(
            from: txtRecord, serviceType: serviceType, name: displayBonjourName)
        // macOS 端的 TXT 记录字段可能不同：兼容更多常见键名
        let osVersion =
            txtValue(
            txtRecord,
            "osVersion",
            "os_version",
            "platformVersion",
            "platform_version",
            "systemVersion",
            "systemversion",
            "os"
        ) ?? "Unknown"
        let modelName =
            txtValue(
            txtRecord,
            "model",
            "hardwareModel",
            "hardwaremodel",
            "hwModel",
            "hwmodel"
        ) ?? detectModelFromName(displayBonjourName, platform: platform)

        // 显示名称：优先可信 TXT name，其次可信 Bonjour name，再回落到型号。
        let txtDisplayName = BonjourServiceIdentitySanitizer.sanitizedDisplayNameCandidate(
            txtValue(txtRecord, "name")
        )
        let bonjourDisplayName = BonjourServiceIdentitySanitizer.sanitizedDisplayNameCandidate(
            displayBonjourName)
        let displayName =
            txtDisplayName
            ?? AppleMobileDeviceIdentity.displayDeviceName(
                rawDeviceName: bonjourDisplayName,
                platform: platform,
                modelName: modelName
            )
        
        // 提取 Bonjour service 信息 / IP 地址
        let ipAddress = extractIPAddress(from: endpoint, txtRecord: txtRecord)
        let (bonjourType, bonjourDomain) = extractBonjourService(
            from: endpoint, fallbackServiceType: serviceType)
        
        // 提取 PQC 支持信息（当前仅解析，后续可用于 UI 展示/能力协商）
        _ = txtRecord["pqc"] ?? "unknown"
        
        // Bonjour TXT identity is peer-controlled discovery metadata. Durable
        // trust is published only after the live P2P session proves an exact
        // active raw-key authority and calls setConnectionLiveness.
        let isTrusted = false

        // Bonjour capability strings are peer-controlled metadata. Product
        // capabilities come only from the service type here and are replaced
        // by authenticated handshake state after a connection is established.
        let advertisedCaps: [String] = []
        var unionCaps = capabilitiesInferred(from: serviceType)
        if advertisement.advertisesStrongOwnerAuthentication {
            unionCaps.insert("hs_soa")
        }

        // DNS-SD SRV owns the service port. TXT values are untrusted metadata and
        // the third `.service` associated value is a domain, not a port.
        // Actionable host/port fallbacks may only arrive later from a resolved SRV
        // endpoint or an authenticated route binding.
        let portMap: [String: UInt16] = [:]

        let signalStrength = resolveSignalStrength(from: txtRecord, endpoint: endpoint)

        return DiscoveredDevice(
            id: id,
            name: displayName,
            bonjourServiceName: bonjourName,
            modelName: modelName,
            platform: platform,
            osVersion: osVersion,
            ipAddress: ipAddress,
            bonjourServiceType: bonjourType,
            bonjourServiceDomain: bonjourDomain,
            services: [serviceType.rawValue],
            portMap: portMap,
            signalStrength: signalStrength,
            lastSeen: Date(),
            isConnected: false,
            isTrusted: isTrusted,
            publicKey: nil,
            advertisedCapabilities: advertisedCaps,
            capabilities: Array(unionCaps).sorted()
        )
    }
    
    private func isUnknownValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.lowercased() == "unknown"
    }

    private func txtValue(_ txt: [String: String], _ keys: String...) -> String? {
        for key in keys {
            if let v = txt[key], !v.isEmpty {
                return v.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            }
            let lower = key.lowercased()
            if let v = txt[lower], !v.isEmpty {
                return v.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func isLoopbackAddress(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
        return normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized == "0:0:0:0:0:0:0:1"
            || normalized == "::ffff:127.0.0.1"
    }

    private func isLoopbackEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }

        switch host {
        case .ipv4(let address):
            return isLoopbackAddress("\(address)")
        case .ipv6(let address):
            return isLoopbackAddress("\(address)")
        default:
            return false
        }
    }

    private func isSelfDevice(_ device: DiscoveredDevice) -> Bool {
        Self.isProvenSelfDevice(
            localStableDeviceId: localStableDeviceId,
            remoteDeviceId: device.id,
            hasLoopbackAddress: device.ipAddress.map(isLoopbackAddress) ?? false
        )
        }

    nonisolated static func isProvenSelfDevice(
        localStableDeviceId: String?,
        remoteDeviceId: String,
        hasLoopbackAddress: Bool
    ) -> Bool {
        // 自识别统一走 SkyBridgeProtocolCore 的共享规则（与 macOS 同一份 SelfDeviceIdentityPolicy）。
        // 名称与平台仍然不参与判定——两台默认同名设备必须仍能互相发现；这条不变量现在由共享策略保证。
        SelfDeviceIdentityPolicy.isSelf(
            local: SelfDeviceIdentityPolicy.LocalIdentity(stableDeviceId: localStableDeviceId),
            candidate: SelfDeviceIdentityPolicy.CandidateIdentity(
                stableDeviceId: remoteDeviceId,
                hasLoopbackAddress: hasLoopbackAddress
            )
        )
    }

    /// 生成尽可能稳定的设备 id：
    /// - 使用 Bonjour 实例名 + domain（忽略 serviceType），确保同一设备多个服务只展示一次
    private func stableDeviceId(
        from endpoint: NWEndpoint,
        txtRecord: [String: String],
        sanitizedBonjourName: String?,
        claimedDeviceId: String? = nil
    ) -> String {
        if let claimedDeviceId,
           let persistent = PeerIdentityAliasResolver.persistentDeviceId(
               from: claimedDeviceId
           ) {
            return persistent
        }
        if let strongId = txtValue(
            txtRecord,
            "deviceId", "deviceID", "device_id",
            "uniqueId", "unique_id",
            "uuid", "id"
        ), let persistent = PeerIdentityAliasResolver.persistentDeviceId(from: strongId) {
            return persistent
        }

        if case .service(let name, _, let domain, _) = endpoint {
            guard
                let sanitizedName = sanitizedBonjourName
                    ?? BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(name)
            else {
                return "endpoint:\(BonjourBrowseEndpointIdentity.key(for: endpoint))"
            }
            let d = domain.isEmpty ? "local." : domain
            return "bonjour:\(sanitizedName)@\(d)"
        }

        if case .hostPort(let host, _) = endpoint {
            return "host:\(host)"
        }

        return BonjourBrowseEndpointIdentity.key(for: endpoint)
    }
    
    /// 从 endpoint 提取设备名称
    private func extractDeviceName(from endpoint: NWEndpoint) -> String {
        if case .service(let name, _, _, _) = endpoint {
            return name
        }
        return "Unknown Device"
    }
    
    /// 提取 TXT 记录
    private func extractTXTRecord(
        from result: NWBrowser.Result,
        serviceType: DiscoveryServiceType
    ) -> ValidatedBonjourAdvertisement? {
        guard case .bonjour(let txtRecord) = result.metadata else {
            return serviceType.isSkyBridgeService
                ? nil
                : ValidatedBonjourAdvertisement(
                    skyBridgeProjection: nil,
                    presentationFields: [:]
                )
        }

        let role: BonjourInteropProtocolContract.AdvertisementRole?
        switch serviceType {
        case .skybridge, .skybridgeQUIC:
            role = .control
        case .skybridgeTransfer, .skybridgeRemote:
            role = .dedicatedService
        default:
            role = nil
        }
        if let role {
            do {
                let decoded = try BonjourInteropProtocolContract.decodeAdvertisement(
                    txtRecord.data,
                    role: role
                )
                let projection = decoded.discoveryProjection
                let presentationFields = projection.platform.map {
                    ["platform": $0.rawValue]
                } ?? [:]
                return ValidatedBonjourAdvertisement(
                    skyBridgeProjection: projection,
                    presentationFields: presentationFields
                )
            } catch {
                SkyBridgeLogger.shared.error(
                    "❌ 拒绝无效 SkyBridge Bonjour TXT: service=\(serviceType.rawValue) error=\(Self.diagnosticErrorSummary(error))"
                )
                return nil
            }
        }

        let dictionary = NetService.dictionary(fromTXTRecord: txtRecord.data)
        var fields: [String: String] = [:]
        fields.reserveCapacity(dictionary.count)
        for (key, value) in dictionary {
            guard let string = String(data: value, encoding: .utf8) else { continue }
            fields[key] = string
        }
        return ValidatedBonjourAdvertisement(
            skyBridgeProjection: nil,
            presentationFields: fields
        )
    }

    private func identityAliases(from result: NWBrowser.Result) -> Set<String> {
        var aliases = Set<String>()

        func appendHost(_ raw: String?) {
            guard let alias = PeerIdentityAliasResolver.hostAlias(fromIPAddress: raw) else { return }
            aliases.insert(alias)
        }

        func appendBonjour(name: String?, domain: String?) {
            guard let name = BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(name) else {
                return
            }
            let trimmedDomain = domain?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedDomain: String
            if let trimmedDomain, !trimmedDomain.isEmpty {
                resolvedDomain = trimmedDomain
            } else {
                resolvedDomain = "local."
            }
            for candidate in PeerIdentityAliasResolver.lookupCandidates(
                for: "bonjour:\(name)@\(resolvedDomain)")
            {
                aliases.insert(candidate)
            }
        }

        switch result.endpoint {
        case .hostPort(let host, _):
            appendHost(String(describing: host))
        case .service(let name, _, let domain, _):
            appendBonjour(name: name, domain: domain)
        default:
            break
        }

        return aliases
        }

    // MARK: - Advertisement snapshots / Merge helpers

    private func replaceAdvertisementSnapshot(
        _ device: DiscoveredDevice,
        endpoint: NWEndpoint,
        interfaces: [NWInterface],
        endpointKey: String,
        serviceType: DiscoveryServiceType,
        protocolIdentityFingerprint: String? = nil,
        replacingEndpointKey: String? = nil
    ) {
        var affectedDeviceIds = Set<String>()

        if let replacingEndpointKey {
            if let removed = advertisementSnapshotsByServiceType[serviceType]?
                .removeValue(forKey: replacingEndpointKey)
            {
                affectedDeviceIds.insert(removed.deviceId)
            }
            endpointToDeviceId.removeValue(forKey: replacingEndpointKey)
        }

        // An endpoint key has one current owner. If Network.framework reports an identity
        // rotation as an add instead of a changed event, revoke the previous snapshot first.
        for existingServiceType in Array(advertisementSnapshotsByServiceType.keys) {
            guard let existing = advertisementSnapshotsByServiceType[existingServiceType]?[endpointKey],
                existing.deviceId != device.id || existingServiceType != serviceType
            else {
                continue
            }
            advertisementSnapshotsByServiceType[existingServiceType]?.removeValue(forKey: endpointKey)
            if advertisementSnapshotsByServiceType[existingServiceType]?.isEmpty == true {
                advertisementSnapshotsByServiceType.removeValue(forKey: existingServiceType)
            }
            affectedDeviceIds.insert(existing.deviceId)
        }

        guard recordEndpointMapping(endpointKey, deviceId: device.id) else {
            for affectedDeviceId in affectedDeviceIds {
                rebuildDeviceFromAdvertisementSnapshots(deviceId: affectedDeviceId)
            }
            return
        }

        let snapshot = BonjourAdvertisementSnapshot(
            deviceId: device.id,
            endpointKey: endpointKey,
            serviceType: serviceType,
            endpoint: endpoint,
            interfaces: interfaces,
            protocolIdentityFingerprint: protocolIdentityFingerprint,
            device: device
        )
        advertisementSnapshotsByServiceType[serviceType, default: [:]][endpointKey] = snapshot
        affectedDeviceIds.insert(device.id)

        for affectedDeviceId in affectedDeviceIds {
            rebuildDeviceFromAdvertisementSnapshots(deviceId: affectedDeviceId)
        }
    }

    private func hasConflictingAdvertisementIdentity(
        deviceId: String,
        protocolIdentityFingerprint: String?
    ) -> Bool {
        guard let protocolIdentityFingerprint,
              !protocolIdentityFingerprint.isEmpty else {
            return false
        }
        return advertisementSnapshotsByServiceType.values
            .flatMap(\.values)
            .contains { snapshot in
                guard let existingFingerprint = snapshot.protocolIdentityFingerprint else {
                    return false
                }
                return (snapshot.deviceId == deviceId
                        && existingFingerprint != protocolIdentityFingerprint)
                    || (existingFingerprint == protocolIdentityFingerprint
                        && snapshot.deviceId != deviceId)
            }
    }

    private func removeAdvertisementSnapshot(
        endpointKey: String,
        fallbackDeviceId: String,
        serviceType: DiscoveryServiceType,
        protectedIdentifiers: Set<String>,
        activeIdentifiers: Set<String>
    ) {
        endpointToDeviceId.removeValue(forKey: endpointKey)
        let removed = advertisementSnapshotsByServiceType[serviceType]?
            .removeValue(forKey: endpointKey)
        if advertisementSnapshotsByServiceType[serviceType]?.isEmpty == true {
            advertisementSnapshotsByServiceType.removeValue(forKey: serviceType)
        }
        rebuildDeviceFromAdvertisementSnapshots(
            deviceId: removed?.deviceId ?? fallbackDeviceId,
            protectedIdentifiers: protectedIdentifiers,
            activeIdentifiers: activeIdentifiers
        )
    }

    private func liveAdvertisementSnapshots(
        for deviceId: String
    ) -> [BonjourAdvertisementSnapshot] {
        advertisementSnapshotsByServiceType.values
            .flatMap(\.values)
            .filter { $0.deviceId == deviceId }
            .sorted { lhs, rhs in
                if lhs.device.lastSeen != rhs.device.lastSeen {
                    return lhs.device.lastSeen < rhs.device.lastSeen
                }
                if lhs.serviceType.rawValue != rhs.serviceType.rawValue {
                    return lhs.serviceType.rawValue < rhs.serviceType.rawValue
                }
                return lhs.endpointKey < rhs.endpointKey
            }
    }

    private func rebuildDeviceFromAdvertisementSnapshots(
        deviceId: String,
        protectedIdentifiers: Set<String> = [],
        activeIdentifiers: Set<String> = []
    ) {
        let snapshots = liveAdvertisementSnapshots(for: deviceId)
        guard let first = snapshots.first else {
            guard var existing = deviceCache[deviceId] else { return }
            let aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
            let shouldPreserve =
                protectedIdentifiers.contains(deviceId)
                || !aliases.isDisjoint(with: protectedIdentifiers)
            let shouldMarkConnected =
                activeIdentifiers.contains(deviceId)
                || !aliases.isDisjoint(with: activeIdentifiers)

            guard shouldPreserve || shouldMarkConnected else {
                removeCachedDiscoveryDevice(deviceId)
                return
            }

            BonjourRouteTuple.clear(from: &existing)
            existing.services = []
            existing.portMap = [:]
            existing.advertisedCapabilities = []
            existing.capabilities = []
            existing.isConnected = shouldMarkConnected
            existing.lastSeen = Date()
            deviceCache[deviceId] = existing
            deviceLastActivity[deviceId] = existing.lastSeen
            return
        }

        var rebuilt = first.device
        for snapshot in snapshots.dropFirst() {
            rebuilt = merge(existing: rebuilt, update: snapshot.device)
        }
        if rebuilt.id != deviceId {
            rebuilt = copyDiscoveryDevice(rebuilt, id: deviceId)
        }

        if let existing = deviceCache[deviceId] {
            rebuilt.isConnected = existing.isConnected
            rebuilt.isTrusted = rebuilt.isTrusted || existing.isTrusted
            if rebuilt.publicKey == nil {
                rebuilt.publicKey = existing.publicKey
            }
            rebuilt.lastSeen = max(rebuilt.lastSeen, existing.lastSeen)
        }

        deviceCache[deviceId] = rebuilt
        deviceLastActivity[deviceId] = rebuilt.lastSeen
    }

    private func withdrawAdvertisementSnapshots(for serviceType: DiscoveryServiceType) {
        guard let withdrawn = advertisementSnapshotsByServiceType.removeValue(forKey: serviceType),
            !withdrawn.isEmpty
        else {
            return
        }

        let protectedIdentifiers = P2PConnectionManager.instance.protectedDiscoveryIdentifiers
        let activeIdentifiers = P2PConnectionManager.instance.activeDiscoveryIdentifiers
        var affectedDeviceIds = Set<String>()
        for (endpointKey, snapshot) in withdrawn {
            if endpointToDeviceId[endpointKey] == snapshot.deviceId {
                endpointToDeviceId.removeValue(forKey: endpointKey)
            }
            affectedDeviceIds.insert(snapshot.deviceId)
        }
        for deviceId in affectedDeviceIds {
            rebuildDeviceFromAdvertisementSnapshots(
                deviceId: deviceId,
                protectedIdentifiers: protectedIdentifiers,
                activeIdentifiers: activeIdentifiers
            )
        }
        scheduleDiscoveredDevicesUpdate()
    }

    // MARK: - Merge / Capabilities helpers

    private func merge(existing: DiscoveredDevice, update: DiscoveredDevice) -> DiscoveredDevice {
        var merged = existing

        // name：只接受可展示的人类可读名称/型号，不让 UUID、IP、peer/host 路由覆盖。
        if shouldReplaceDisplayName(existing: merged.name, candidate: update.name) {
            merged.name = update.name
        }

        // A device can publish transfer/remote/QUIC before its P2P control listener. When the
        // primary record arrives, promote the complete DNS-SD tuple atomically; combining the
        // primary type with an auxiliary instance name/domain creates a plausible but invalid
        // endpoint. Auxiliary records may enrich an empty route, but must never overwrite an
        // already selected primary route.
        if let selectedRoute = BonjourRouteTuple.preferred(
            existing: BonjourRouteTuple(existing),
            update: BonjourRouteTuple(update)
        ) {
            selectedRoute.apply(to: &merged)
        } else {
            BonjourRouteTuple.clear(from: &merged)
        }

        // platform/osVersion/model：尽量补齐（避免 Unknown 覆盖有效值）
        if merged.platform == .unknown && update.platform != .unknown {
            merged.platform = update.platform
        } else if merged.platform == .iOS,
                  update.platform == .iPadOS,
            isIPadPresentation(update)
        {
            merged.platform = .iPadOS
        }
        if isUnknownValue(merged.osVersion) && !isUnknownValue(update.osVersion) {
            merged.osVersion = update.osVersion
        }
        if isUnknownValue(merged.modelName) && !isUnknownValue(update.modelName) {
            merged.modelName = update.modelName
        } else if discoveryGenericModel(
            normalizedDiscoveryName(merged.modelName),
            containsDetailedModel: normalizedDiscoveryName(update.modelName))
        {
            merged.modelName = update.modelName
        }

        // 最新 IP / Bonjour type/domain（优先保留可路由 LAN 地址，避免 Bonjour service 解析退回 link-local）。
        if let bestAddress = ConnectableAddressCanonicalizer.bestLANAddress([
            merged.ipAddress,
            update.ipAddress
        ]) {
            merged.ipAddress = bestAddress
        }
        // 合并 services / portMap
        for s in update.services where !merged.services.contains(s) { merged.services.append(s) }
        for (k, v) in update.portMap { merged.portMap[k] = v }

        // 信号强度：Bonjour 不一定能拿到“真实 RSSI”，但如果 TXT/启发式有新值，优先采用最新值
        merged.signalStrength = update.signalStrength

        // 合并 advertisedCapabilities（TXT）
        let txtUnion = Set(merged.advertisedCapabilities).union(update.advertisedCapabilities)
        merged.advertisedCapabilities = Array(txtUnion).sorted()

        // 合并 capabilities（TXT + inferred）
        merged.capabilities = recomputeCapabilities(existing: merged)

        // 时间戳
        merged.lastSeen = Date()

        return merged
    }

    private func shouldReplaceDisplayName(existing: String, candidate: String) -> Bool {
        let existingScore = displayNameQualityScore(existing)
        let candidateScore = displayNameQualityScore(candidate)
        if candidateScore != existingScore {
            return candidateScore > existingScore
        }
        return candidate.count > existing.count
    }

    private func displayNameQualityScore(_ raw: String) -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        if BonjourServiceIdentitySanitizer.isIdentifierLikeDisplayName(trimmed) { return 10 }
        let normalized = normalizedDiscoveryName(trimmed)
        if normalized == "unknowndevice" || normalized == "unknown" || normalized == "未知设备" {
            return 20
        }
        if normalized == "ipad" || normalized == "iphone" {
            return 40
        }
        if normalized.hasPrefix("ipad") || normalized.hasPrefix("iphone") || normalized.contains("mac") {
            return 70
        }
        if normalized.contains("ipad") || normalized.contains("iphone") {
            return 90
        }
        return 100
    }

    private func aliasPriority(for device: DiscoveredDevice) -> Int {
        var score = 0
        if device.id.lowercased().hasPrefix("id:") {
            score += 300
        }
        if device.services.contains(DiscoveryServiceType.skybridge.rawValue) {
            score += 120
        }
        if device.bonjourServiceType == DiscoveryServiceType.skybridge.rawValue {
            score += 80
        }
        if device.bonjourServiceName?.isEmpty == false {
            score += 30
        }
        if device.ipAddress?.isEmpty == false {
            score += 20
        }
        return score
    }

    private func rebuildIdentityAliasIndex() {
        var aliasMap: [String: String] = [:]
        var ownerScores: [String: Int] = [:]

        for device in deviceCache.values.sorted(by: { $0.lastSeen > $1.lastSeen }) {
            let score = aliasPriority(for: device)
            let aliases = Set(PeerIdentityAliasResolver.aliasKeys(for: device))
                .union(discoveryIdentityAliasesByDeviceId[device.id] ?? [])
            for alias in aliases {
                let existingScore = ownerScores[alias] ?? Int.min
                if aliasMap[alias] == nil || score >= existingScore {
                    aliasMap[alias] = device.id
                    ownerScores[alias] = score
                }
            }
        }

        identityAliasToDeviceId = aliasMap
    }

    private func capabilitiesInferred(from serviceType: DiscoveryServiceType) -> Set<String> {
        switch serviceType {
        case .skybridgeTransfer:
            return ["file", "file_transfer"]
        case .skybridgeRemote:
            return ["screen_sharing", "remote_desktop", "rdview", "remote_control", "rdcontrol"]
        default:
            return []
        }
    }

    private func recomputeCapabilities(existing: DiscoveredDevice) -> [String] {
        var caps = Set(existing.advertisedCapabilities)
        for s in existing.services {
            if s == DiscoveryServiceType.skybridgeTransfer.rawValue {
                caps.formUnion(["file", "file_transfer"])
            }
            if s == DiscoveryServiceType.skybridgeRemote.rawValue {
                caps.formUnion([
                    "screen_sharing", "remote_desktop", "rdview", "remote_control", "rdcontrol"
                ])
            }
        }
        return Array(caps).sorted()
    }

    private func parsePort(for serviceType: DiscoveryServiceType, from txt: [String: String])
        -> UInt16?
    {
        switch serviceType {
        case .skybridge, .skybridgeQUIC:
            return parseUInt16(txtValue(txt, "port"))
                ?? parseUInt16(txtValue(txt, "skybridgePort"))
                ?? parseUInt16(txtValue(txt, "p2pPort"))
                ?? parseUInt16(txtValue(txt, "controlPort"))
        case .skybridgeTransfer:
            return parseUInt16(txtValue(txt, "transferPort"))
                ?? parseUInt16(txtValue(txt, "fileTransferPort"))
                ?? parseUInt16(txtValue(txt, "file_transfer_port"))
                ?? parseUInt16(txtValue(txt, "port"))
        case .skybridgeRemote:
            return parseUInt16(txtValue(txt, "remotePort"))
                ?? parseUInt16(txtValue(txt, "remoteControlPort"))
                ?? parseUInt16(txtValue(txt, "remote_port"))
                ?? parseUInt16(txtValue(txt, "port"))
        default:
            return nil
        }
    }

    private func parseUInt16(_ s: String?) -> UInt16? {
        guard let s, !s.isEmpty else { return nil }
        return UInt16(s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))
    }

    // MARK: - Signal strength (RSSI)

    /// 尝试从 TXT 记录提取 RSSI；若不存在，则根据网络接口类型给出一个稳定的启发式默认值。
    ///
    /// 说明：
    /// - Bonjour/mDNS 本身不携带 RSSI；若需要“真实 RSSI”，需由发布方把 `rssi` 写入 TXT 记录，
    ///   或使用更底层的无线扫描 API（iOS 上通常不可行/受限）。
    private func resolveSignalStrength(from txtRecord: [String: String], endpoint: NWEndpoint) -> Int {
        if let raw = txtValue(txtRecord, "rssi", "signalStrength", "signal_strength", "signal"),
            let parsed = parseRSSI(raw)
        {
            return parsed
        }
        return defaultSignalStrength(for: endpoint)
    }

    private func parseRSSI(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 常见形式："-65" / "-65.2" / "-65 dBm"
        let cleaned =
            trimmed
            .replacingOccurrences(of: "dbm", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        if let v = Int(cleaned) { return v }
        if let d = Double(cleaned) { return Int(d.rounded()) }

        // 兜底：提取数字部分
        let numeric = cleaned.filter { "-0123456789.".contains($0) }
        if let d = Double(numeric) { return Int(d.rounded()) }
        return nil
    }

    private func defaultSignalStrength(for endpoint: NWEndpoint) -> Int {
        if case .service(_, _, _, let interface) = endpoint, let interface {
            // AWDL（AirDrop/点对点）一般信号更好一些
            if interface.name == "awdl0" { return -45 }
            switch interface.type {
            case .wifi: return -50
            case .wiredEthernet: return -35
            case .cellular: return -85
            case .loopback: return -10
            case .other: return -65
            @unknown default: return -60
            }
        }
        return -60
    }
    
    /// 检测平台
    private func detectPlatform(
        from txtRecord: [String: String],
        serviceType: DiscoveryServiceType,
        name: String
    ) -> DevicePlatform {
        // 1. 优先从 TXT 记录获取
        if let platformStr = txtValue(txtRecord, "platform", "os")?.lowercased() {
            switch platformStr {
            case "ios": return .iOS
            case "ipados": return .iPadOS
            case "macos", "mac": return .macOS
            case "android": return .android
            case "windows", "win": return .windows
            case "linux": return .linux
            default: break
            }
        }
        
        // 2. 根据服务类型推断
        switch serviceType {
        case .airdrop, .companionLink:
            // Apple 专属服务
            if name.lowercased().contains("iphone") {
                return .iOS
            } else if name.lowercased().contains("ipad") {
                return .iPadOS
            } else if name.lowercased().contains("mac") {
                return .macOS
            }
            return .macOS // 默认 Apple 设备
            
        case .androidShare:
            return .android
            
        case .rdp:
            // RDP 通常是 Windows
            return .windows
            
        default:
            break
        }
        
        // 3. 根据设备名称推断
        let nameLower = name.lowercased()
        if nameLower.contains("iphone") {
            return .iOS
        } else if nameLower.contains("ipad") {
            return .iPadOS
        } else if nameLower.contains("mac") || nameLower.contains("imac")
            || nameLower.contains("macbook")
        {
            return .macOS
        } else if nameLower.contains("pixel") || nameLower.contains("samsung")
            || nameLower.contains("xiaomi") || nameLower.contains("android")
        {
            return .android
        } else if nameLower.contains("windows") || nameLower.contains("desktop-")
            || nameLower.contains("laptop-")
        {
            return .windows
        } else if nameLower.contains("linux") || nameLower.contains("ubuntu")
            || nameLower.contains("fedora") || nameLower.contains("debian")
        {
            return .linux
        }
        
        return .unknown
    }
    
    /// 根据名称推断型号
    private func detectModelFromName(_ name: String, platform: DevicePlatform) -> String {
        let nameLower = name.lowercased()
        
        switch platform {
        case .iOS:
            if nameLower.contains("iphone") {
                return "iPhone"
            }
            return "iOS Device"
            
        case .iPadOS:
            if nameLower.contains("ipad pro") {
                return "iPad Pro"
            } else if nameLower.contains("ipad air") {
                return "iPad Air"
            } else if nameLower.contains("ipad mini") {
                return "iPad mini"
            }
            return "iPad"
            
        case .macOS:
            if nameLower.contains("macbook pro") {
                return "MacBook Pro"
            } else if nameLower.contains("macbook air") {
                return "MacBook Air"
            } else if nameLower.contains("imac") {
                return "iMac"
            } else if nameLower.contains("mac mini") {
                return "Mac mini"
            } else if nameLower.contains("mac studio") {
                return "Mac Studio"
            } else if nameLower.contains("mac pro") {
                return "Mac Pro"
            }
            return "Mac"
            
        case .android:
            if nameLower.contains("pixel") {
                return "Google Pixel"
            } else if nameLower.contains("samsung") || nameLower.contains("galaxy") {
                return "Samsung Galaxy"
            } else if nameLower.contains("xiaomi") {
                return "Xiaomi"
            } else if nameLower.contains("oneplus") {
                return "OnePlus"
            }
            return "Android Device"
            
        case .windows:
            return "Windows PC"
            
        case .linux:
            return "Linux PC"
            
        case .unknown:
            return "Unknown"
        }
    }
    
    /// 提取 IP 地址
    private func extractIPAddress(from endpoint: NWEndpoint, txtRecord: [String: String]) -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let address):
                return "\(address)"
            case .ipv6(let address):
                return "\(address)"
            default:
                return nil
            }
        case .service(_, _, _, _):
            return ConnectableAddressCanonicalizer.bestLANAddress([
                txtValue(txtRecord, "lanHost", "host", "ip", "ipv4", "address", "hostAddress"),
                txtValue(txtRecord, "lanIPv4"),
                txtValue(txtRecord, "lanIPv6", "ipv6")
            ]).flatMap {
                ConnectableAddressCanonicalizer.isRoutableLANAddress($0) ? $0 : nil
            }
        default:
            return nil
        }
    }

    /// 提取 Bonjour Service (type/domain)，用于后续直接通过 NWEndpoint.service 连接（无需解析出 IP）
    private func extractBonjourService(
        from endpoint: NWEndpoint,
        fallbackServiceType: DiscoveryServiceType
    ) -> (type: String?, domain: String?) {
        if case .service(_, let type, let domain, _) = endpoint {
            return (type, domain)
        }
        // 兜底：至少保存本次发现的 serviceType（domain 通常为 local.）
        return (fallbackServiceType.rawValue, "local.")
    }
    
    // MARK: - Private Methods - Listener

    private nonisolated static func clearListenerHandlers(_ listener: NWListener) {
        listener.stateUpdateHandler = nil
        listener.serviceRegistrationUpdateHandler = nil
        listener.newConnectionHandler = nil
    }

    private nonisolated static func cancelListener(_ listener: NWListener) {
        clearListenerHandlers(listener)
        listener.cancel()
    }

    private func waitForAdvertisingReady(
        _ activeListener: NWListener,
        generation: UInt64
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                advertisingStartupContinuation = continuation
                scheduleAdvertisingStartupTimeout(
                    seconds: Self.advertisingStartupTimeoutSeconds,
                    listener: activeListener,
                    generation: generation
                )
                activeListener.start(queue: queue)
            }
        } onCancel: {
            Task { @MainActor [weak self, weak activeListener] in
                guard let self,
                      let activeListener,
                    self.listener === activeListener,
                    self.listenerGeneration == generation
                else {
                    return
                }

                self.listener = nil
                self.isAdvertising = false
                self.finishAdvertisingStartup(.failure(CancellationError()))
                Self.cancelListener(activeListener)
            }
        }
    }

    private func scheduleAdvertisingStartupTimeout(
        seconds: TimeInterval,
        listener expectedListener: NWListener,
        generation: UInt64
    ) {
        advertisingStartupTimeoutTask?.cancel()
        advertisingStartupTimeoutTask = Task { @MainActor [weak self, weak expectedListener] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }

            guard let self,
                let expectedListener,
                  self.advertisingStartupContinuation != nil,
                self.listener === expectedListener,
                self.listenerGeneration == generation,
                !self.isAdvertising
            else {
                return
            }

            // Distinguish "never got local-network permission" from a genuine hang so the
            // caller and the diagnostics trace both name the actual blocker.
            let timeoutError: AdvertisingStartupError =
                self.advertisingAuthorizationWaitObserved
                ? AdvertisingStartupError.localNetworkAuthorizationPending(seconds: seconds)
                : AdvertisingStartupError.timedOut(seconds: seconds)
            self.listener = nil
            self.isAdvertising = false
            self.error = timeoutError
            self.appendListenerStatus(
                "startup-timeout authorizationPending=\(self.advertisingAuthorizationWaitObserved ? 1 : 0) seconds=\(Int(seconds))"
            )
            self.finishAdvertisingStartup(.failure(timeoutError))
            Self.cancelListener(expectedListener)
        }
    }

    private func finishAdvertisingStartup(_ result: Result<Void, Error>) {
        guard let continuation = advertisingStartupContinuation else { return }
        advertisingStartupContinuation = nil
        advertisingStartupTimeoutTask?.cancel()
        advertisingStartupTimeoutTask = nil

        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
    
    private func handleListenerStateChange(
        _ state: NWListener.State,
        for activeListener: NWListener,
        generation: UInt64
    ) async {
        guard listener === activeListener, listenerGeneration == generation else { return }

        switch state {
        case .ready:
            guard let gate = advertisingReadinessGate else {
                finishAdvertisingStartup(.failure(AdvertisingStartupError.superseded))
                return
            }
            let observation = gate.observeSocketReady()
            if observation == .completesStartup || observation == .runtimeReady {
                completeAdvertisingReadiness(
                    for: activeListener,
                    generation: generation
                )
            } else {
                appendListenerStatus("socket-ready registration=pending")
            }

        case .failed(let error):
            _ = advertisingReadinessGate?.observeTerminal()
            SkyBridgeLogger.shared.error("❌ 监听器失败: \(Self.diagnosticErrorSummary(error))")
            self.error = error
            isAdvertising = false
            listener = nil
            resetAdvertisingReadiness()
            appendListenerStatus("failed \(Self.diagnosticErrorSummary(error))")
            finishAdvertisingStartup(.failure(error))
            Self.cancelListener(activeListener)
            cancelAllInboundAdmissionConnections()

        case .cancelled:
            _ = advertisingReadinessGate?.observeTerminal()
            SkyBridgeLogger.shared.info("⏹️ 监听器已取消")
            isAdvertising = false
            listener = nil
            resetAdvertisingReadiness()
            appendListenerStatus("cancelled")
            finishAdvertisingStartup(.failure(AdvertisingStartupError.cancelledBeforeReady))
            Self.clearListenerHandlers(activeListener)
            cancelAllInboundAdmissionConnections()
            
        case .waiting(let waitError):
            _ = advertisingReadinessGate?.observeSocketUnavailable()
            // `.waiting` is recoverable by definition: Network.framework keeps retrying
            // publication. Letting it fall through to the unhandled-state branch made the
            // most common first-launch failure invisible in logs.
            let authorizationFailure = Self.bonjourAuthorizationFailure(waitError)
            let isAuthorizationWait = authorizationFailure != nil
            // A listener in `.waiting` is not currently dialable. Keep the listener/handler/
            // authority so this exact generation may recover, but revoke all readiness signals.
            isAdvertising = false
            advertisingActualPort = nil
            isAwaitingLocalNetworkAuthorization = isAuthorizationWait
            appendListenerStatus(
                "waiting authorization=\(isAuthorizationWait ? 1 : 0) kind=\(authorizationFailure?.rawValue ?? "transient") \(Self.diagnosticErrorSummary(waitError))"
            )

            guard isAuthorizationWait else {
                // Interface churn makes a transient `.waiting` normal; the diagnostics
                // trace above keeps the detail without warning-level Release noise.
                SkyBridgeLogger.shared.info(
                    "⏳ P2P Bonjour 广播监听器等待中: \(Self.diagnosticErrorSummary(waitError))"
                )
                return
            }

            advertisingAuthorizationWaitObserved = true
            isAwaitingLocalNetworkAuthorization = true
            guard !advertisingAuthorizationDeadlineExtended,
                advertisingStartupContinuation != nil
            else {
                return
            }
            advertisingAuthorizationDeadlineExtended = true
            SkyBridgeLogger.shared.warning(
                """
                ⏳ P2P Bonjour 广播等待本地网络访问授权；已将启动窗口延长至 \
                \(Int(Self.advertisingAuthorizationWaitTimeoutSeconds)) 秒
                """
            )
            appendListenerStatus(
                "waiting-extended seconds=\(Int(Self.advertisingAuthorizationWaitTimeoutSeconds))"
            )
            scheduleAdvertisingStartupTimeout(
                seconds: Self.advertisingAuthorizationWaitTimeoutSeconds,
                listener: activeListener,
                generation: generation
            )

        default:
            break
        }
    }

    private func handleServiceRegistrationChange(
        _ change: NWListener.ServiceRegistrationChange,
        for activeListener: NWListener,
        generation: UInt64
    ) async {
        guard listener === activeListener,
              listenerGeneration == generation,
              let gate = advertisingReadinessGate else {
            return
        }

        let observation: BonjourRegistrationReadinessGate.Observation
        switch change {
        case .add(let endpoint):
            observation = gate.observeRegistrationAdded(endpoint.debugDescription)
        case .remove(let endpoint):
            observation = gate.observeRegistrationRemoved(endpoint.debugDescription)
        @unknown default:
            let protocolError = POSIXError(.EPROTO)
            self.error = protocolError
            isAdvertising = false
            advertisingActualPort = nil
            finishAdvertisingStartup(.failure(protocolError))
            Self.cancelListener(activeListener)
            listener = nil
            return
        }

        switch observation {
        case .completesStartup, .runtimeReady:
            completeAdvertisingReadiness(
                for: activeListener,
                generation: generation
            )
        case .runtimeDegraded:
            isAdvertising = false
            advertisingActualPort = nil
            appendListenerStatus("registration-removed")
        case .pending, .runtimeTerminal, .ignored:
            break
        }
    }

    private func completeAdvertisingReadiness(
        for activeListener: NWListener,
        generation: UInt64
    ) {
        guard listener === activeListener,
              listenerGeneration == generation,
              let port = activeListener.port?.rawValue,
              port > 0 else {
            return
        }
        advertisingActualPort = port
        advertisingServiceType = DiscoveryServiceType.skybridge.rawValue
        advertisingReadyGeneration += 1
        isAdvertising = true
        isAwaitingLocalNetworkAuthorization = false
        error = nil
        finishAdvertisingStartup(.success(()))
        SkyBridgeLogger.shared.info("✅ 监听器与 Bonjour registration 就绪，端口: \(port)")
        appendListenerStatus(
            "ready service=\(DiscoveryServiceType.skybridge.rawValue) requestedPort=\(advertisingRequestedPort.map(String.init) ?? "-") actualPort=\(port) handlerInstalled=\(advertisingHandlerInstalled ? 1 : 0) generation=\(advertisingReadyGeneration) registration=confirmed"
        )
    }
    
    private func handleNewIncomingConnection(_ connection: NWConnection) async {
        let endpointDescription = connection.endpoint.debugDescription
        let endpointReference = Self.diagnosticReference(endpointDescription)

        if isLoopbackEndpoint(connection.endpoint) {
            SkyBridgeLogger.shared.warning("⚠️ 已忽略回环地址入站连接: endpoint_ref=\(endpointReference)")
            SkyBridgeDiagnosticTrace.appendStatus(
                "p2p-listener inbound-ignored reason=loopback endpoint_ref=\(endpointReference)"
            )
            connection.cancel()
            return
        }

        SkyBridgeLogger.shared.info("📞 收到新连接: endpoint_ref=\(endpointReference)")
        SkyBridgeDiagnosticTrace.appendStatus(
            "p2p-listener inbound-new endpoint_ref=\(endpointReference)"
        )

        let peerId = extractPeerId(from: connection)
        let peerReference = Self.diagnosticReference(peerId)
        if let localStableDeviceId,
            peerId.caseInsensitiveCompare(localStableDeviceId) == .orderedSame
        {
            SkyBridgeLogger.shared.warning("⚠️ 已忽略疑似自连接入站连接: peer_ref=\(peerReference)")
            SkyBridgeDiagnosticTrace.appendStatus(
                "p2p-listener inbound-ignored reason=self peer_ref=\(peerReference)"
            )
            connection.cancel()
            return
        }

        guard registerInboundAdmissionConnection(connection) else {
            SkyBridgeLogger.shared.error("❌ 已拒绝超过入站连接容量的 P2P 连接")
            SkyBridgeDiagnosticTrace.appendStatus(
                "p2p-listener inbound-ignored reason=admission-capacity"
            )
            connection.cancel()
            return
        }

        let readinessTimeoutTask = Task { @MainActor [weak self, weak connection] in
            do {
                try await Task.sleep(
                    for: .seconds(
                        P2PInboundAdmissionPolicy.deadlineSeconds(
                            for: .awaitingFirstFrame
                        )
                    )
                )
            } catch {
                return
            }
            guard !Task.isCancelled, let connection else { return }
            SkyBridgeLogger.shared.error("❌ 入站连接在期限内未就绪: peer_ref=\(peerReference)")
            SkyBridgeDiagnosticTrace.appendStatus(
                "p2p-listener inbound-timeout peer_ref=\(peerReference)"
            )
            self?.finishInboundAdmissionConnection(connection)
            connection.cancel()
        }

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self, weak connection] in
                guard let connection else { return }
                switch state {
                case .ready:
                    readinessTimeoutTask.cancel()
                    connection.stateUpdateHandler = nil
                    SkyBridgeLogger.shared.info("✅ 入站连接就绪: peer_ref=\(peerReference)")
                    SkyBridgeDiagnosticTrace.appendStatus(
                        "p2p-listener inbound-ready peer_ref=\(peerReference)"
                    )
                    guard let onNewConnection = self?.onNewConnection else {
                        self?.finishInboundAdmissionConnection(connection)
                        connection.cancel()
                        return
                    }
                    onNewConnection(connection, peerId)

                case .failed(let error):
                    readinessTimeoutTask.cancel()
                    self?.finishInboundAdmissionConnection(connection)
                    connection.stateUpdateHandler = nil
                    SkyBridgeLogger.shared.error(
                        "❌ 入站连接失败: peer_ref=\(peerReference) \(Self.diagnosticErrorSummary(error))"
                    )
                    SkyBridgeDiagnosticTrace.appendStatus(
                        "p2p-listener inbound-failed peer_ref=\(peerReference) \(Self.diagnosticErrorSummary(error))"
                    )

                case .cancelled:
                    readinessTimeoutTask.cancel()
                    self?.finishInboundAdmissionConnection(connection)
                    connection.stateUpdateHandler = nil
                    SkyBridgeLogger.shared.info("⏹️ 入站连接已取消")
                    SkyBridgeDiagnosticTrace.appendStatus(
                        "p2p-listener inbound-cancelled peer_ref=\(peerReference)"
                    )

                default:
                    break
                }
            }
        }

        connection.start(queue: queue)
    }

    private func registerInboundAdmissionConnection(_ connection: NWConnection) -> Bool {
        let identifier = ObjectIdentifier(connection)
        if inboundAdmissionConnections[identifier] != nil {
            return true
        }
        let endpointKey = Self.preReadyEndpointKey(connection.endpoint)
        let endpointCount = inboundAdmissionConnections.values.reduce(into: 0) { count, entry in
            if entry.endpointKey == endpointKey {
                count += 1
            }
        }
        guard inboundAdmissionConnections.count < Self.maximumInboundAdmissionConnections,
            endpointCount < Self.maximumInboundAdmissionConnectionsPerEndpoint
        else {
            return false
        }
        inboundAdmissionConnections[identifier] = InboundAdmissionConnection(
            connection: connection,
            endpointKey: endpointKey,
            firstFrameDeadline: ContinuousClock.now.advanced(
                by: .seconds(
                    P2PInboundAdmissionPolicy.deadlineSeconds(
                        for: .awaitingFirstFrame
                    )
                )
            ),
            phase: .preReady
        )
        return true
    }

    /// Transfers the listener-owned slot into the protocol adapter without
    /// changing total occupancy or resetting the absolute first-frame budget.
    func claimProtocolInboundAdmission(
        _ connection: NWConnection,
        now: ContinuousClock.Instant = ContinuousClock.now
    ) -> TimeInterval? {
        let identifier = ObjectIdentifier(connection)
        guard var entry = inboundAdmissionConnections[identifier],
              entry.connection === connection,
              entry.phase == .preReady else {
            return nil
        }
        guard let remaining = P2PInboundAdmissionPolicy.remainingSeconds(
            until: entry.firstFrameDeadline,
            now: now
        ) else {
            inboundAdmissionConnections.removeValue(forKey: identifier)
            return nil
        }
        entry.phase = .protocolReady
        inboundAdmissionConnections[identifier] = entry
        return remaining
    }

    func finishInboundAdmissionConnection(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        guard inboundAdmissionConnections[identifier]?.connection === connection else {
            return
        }
        inboundAdmissionConnections.removeValue(forKey: identifier)
    }

    private func cancelAllInboundAdmissionConnections() {
        let connections = inboundAdmissionConnections.values.map(\.connection)
        inboundAdmissionConnections.removeAll(keepingCapacity: false)
        for connection in connections {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    private nonisolated static func preReadyEndpointKey(_ endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint {
            // Admission is deliberately per remote host rather than per ephemeral source
            // port; otherwise one host could bypass the pre-ready cap with new sockets.
            return PeerIdentityAliasResolver.hostAlias(
                fromIPAddress: String(describing: host)
            ) ?? "host:\(String(describing: host).lowercased())"
        }
        return BonjourBrowseEndpointIdentity.key(for: endpoint)
    }

    private nonisolated static func smokeSanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private nonisolated static func diagnosticReference(_ value: String?) -> String {
        SkyBridgeDiagnosticReference.stableReference(value)
    }

    private nonisolated static func diagnosticErrorSummary(_ error: Error) -> String {
        let diagnosticError = error as NSError
        return "error_domain=\(diagnosticError.domain) code=\(diagnosticError.code)"
    }

    private func extractPeerId(from connection: NWConnection) -> String {
        // Prefer mapping back to an already-discovered stable device id if possible.
        // This is critical for UI refresh: the device list is keyed by `DiscoveredDevice.id` (stableDeviceId),
        // while inbound NWConnection endpoints often arrive as hostPort (IP) and would otherwise mismatch.
        let endpointKey = BonjourBrowseEndpointIdentity.key(for: connection.endpoint)
        if let mapped = PeerIdentityAliasResolver.resolveDeviceId(
            for: connection.endpoint,
            endpointKey: endpointKey,
            exactEndpointMap: endpointToDeviceId,
            aliasMap: identityAliasToDeviceId
        ) {
            return mapped
        }

        // Fall back to a stable host-based id (matches stableDeviceId(from:) for hostPort endpoints).
        if case .hostPort(let host, _) = connection.endpoint {
            switch host {
            case .ipv4(let addr):
                return "host:\(addr)"
            case .ipv6(let addr):
                return "host:\(addr)"
            default:
                break
            }
        }

        return endpointKey
    }

    func canonicalDiscoveredDevice(for device: DiscoveredDevice) -> DiscoveredDevice? {
        var candidateIds: [String] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                seen.insert(raw).inserted
            else {
                return
            }
            candidateIds.append(raw)
        }

        append(device.id)
        for alias in PeerIdentityAliasResolver.lookupCandidates(for: device.id) {
            append(identityAliasToDeviceId[alias])
        }
        for alias in PeerIdentityAliasResolver.aliasKeys(for: device) {
            append(identityAliasToDeviceId[alias])
        }
        if let ipAddress = device.ipAddress,
            let alias = PeerIdentityAliasResolver.hostAlias(fromIPAddress: ipAddress)
        {
            append(identityAliasToDeviceId[alias])
        }
        if let bonjourServiceName = BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(
            device.bonjourServiceName),
           let alias = PeerIdentityAliasResolver.lookupCandidates(
                for: "bonjour:\(bonjourServiceName)@\(device.bonjourServiceDomain ?? "local.")"
            ).first
        {
            append(identityAliasToDeviceId[alias])
        }

        for candidateId in candidateIds {
            if let cached = deviceCache[candidateId] {
                return cached
            }
            if let discovered = discoveredDevices.first(where: { $0.id == candidateId }) {
                return discovered
            }
        }
        return nil
    }

    /// Returns one exact, currently live DNS-SD advertisement for the requested service.
    ///
    /// The aggregate device intentionally keeps only one preferred Bonjour tuple. Callers that
    /// need an auxiliary route (remote control or file transfer) must read the independently
    /// observed per-service snapshot instead of combining the aggregate service name with an
    /// unrelated TXT port.
    func liveBonjourAdvertisement(
        for device: DiscoveredDevice,
        serviceType: DiscoveryServiceType
    ) -> DiscoveredDevice? {
        liveBonjourAdvertisementSnapshots(for: device, serviceType: serviceType).first?.device
    }

    private func liveBonjourAdvertisementSnapshots(
        for device: DiscoveredDevice,
        serviceType: DiscoveryServiceType
    ) -> [BonjourAdvertisementSnapshot] {
        let requestedID = device.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedPersistentID = PeerIdentityAliasResolver.persistentDeviceId(from: requestedID)
        let canonical = canonicalDiscoveredDevice(for: device) ?? device
        let canonicalID = canonical.id.trimmingCharacters(in: .whitespacesAndNewlines)
        // A caller that already holds a strong identity must never let a weak Bonjour alias
        // replace that authority with another cached strong identity. Canonical alias lookup is
        // only an enrichment path for callers whose original identifier is non-authoritative.
        let persistentID = requestedPersistentID
            ?? PeerIdentityAliasResolver.persistentDeviceId(from: canonicalID)
        let exactFallbackID = requestedPersistentID == nil ? canonicalID : requestedID
        let snapshots = advertisementSnapshotsByServiceType[serviceType]
            .map { Array($0.values) } ?? []

        return snapshots
            .filter { snapshot in
                guard BonjourRouteTuple(snapshot.device)?.type == serviceType.rawValue else {
                    return false
                }
                if let persistentID {
                    return PeerIdentityAliasResolver.persistentDeviceId(from: snapshot.deviceId)
                        == persistentID
                }
                return snapshot.deviceId.caseInsensitiveCompare(exactFallbackID) == .orderedSame
            }
            .sorted { lhs, rhs in
                let lhsInterfacePriority = Self.liveBonjourInterfacePriority(lhs.endpoint)
                let rhsInterfacePriority = Self.liveBonjourInterfacePriority(rhs.endpoint)
                if lhsInterfacePriority != rhsInterfacePriority {
                    return lhsInterfacePriority < rhsInterfacePriority
                }
                if lhs.device.lastSeen != rhs.device.lastSeen {
                    return lhs.device.lastSeen > rhs.device.lastSeen
                }
                return lhs.endpointKey < rhs.endpointKey
            }
    }

    private nonisolated static func liveBonjourInterfacePriority(_ endpoint: NWEndpoint) -> Int {
        guard case .service(_, _, _, let interface) = endpoint,
              let interfaceName = interface?.name else {
            return liveBonjourInterfacePriority(interfaceName: nil)
        }
        return liveBonjourInterfacePriority(interfaceName: interfaceName)
    }

    nonisolated static func liveBonjourInterfacePriority(interfaceName: String?) -> Int {
        guard let interfaceName = interfaceName?.lowercased() else { return 3 }
        if interfaceName.hasPrefix("awdl") || interfaceName.hasPrefix("p2p") {
            return 0
        }
        if interfaceName.hasPrefix("en") {
            return 1
        }
        return 2
    }

    private nonisolated static func liveBonjourInterfaceSort(
        _ lhs: NWInterface,
        _ rhs: NWInterface
    ) -> Bool {
        let lhsPriority = liveBonjourInterfacePriority(interfaceName: lhs.name)
        let rhsPriority = liveBonjourInterfacePriority(interfaceName: rhs.name)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        let nameComparison = lhs.name.localizedStandardCompare(rhs.name)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        return lhs.index < rhs.index
    }

    func liveBonjourServiceEndpoint(
        for device: DiscoveredDevice,
        serviceType: DiscoveryServiceType
    ) -> NWEndpoint? {
        liveBonjourServiceEndpoints(for: device, serviceType: serviceType).first
    }

    func liveBonjourServiceEndpoints(
        for device: DiscoveredDevice,
        serviceType: DiscoveryServiceType
    ) -> [NWEndpoint] {
        var seenEndpointKeys = Set<String>()
        var candidates: [(endpoint: NWEndpoint, lastSeen: Date, snapshotKey: String)] = []

        for snapshot in liveBonjourAdvertisementSnapshots(for: device, serviceType: serviceType) {
                guard let advertisedRoute = BonjourRouteTuple(snapshot.device),
                      advertisedRoute.type == serviceType.rawValue,
                      case .service(let name, let type, let domain, _) = snapshot.endpoint,
                      let endpointRoute = BonjourRouteTuple(name: name, type: type, domain: domain),
                      endpointRoute == advertisedRoute else {
                    continue
                }

                let observedInterfaces = Array(Set(snapshot.interfaces))
                    .sorted(by: Self.liveBonjourInterfaceSort)
                if observedInterfaces.isEmpty {
                    candidates.append((snapshot.endpoint, snapshot.device.lastSeen, snapshot.endpointKey))
                } else {
                    for interface in observedInterfaces {
                        candidates.append((
                            .service(
                                name: name,
                                type: type,
                                domain: domain,
                                interface: interface
                            ),
                            snapshot.device.lastSeen,
                            snapshot.endpointKey
                        ))
                    }
                }
        }

        return candidates
            .sorted { lhs, rhs in
                let lhsPriority = Self.liveBonjourInterfacePriority(lhs.endpoint)
                let rhsPriority = Self.liveBonjourInterfacePriority(rhs.endpoint)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                if lhs.lastSeen != rhs.lastSeen {
                    return lhs.lastSeen > rhs.lastSeen
                }
                return lhs.snapshotKey < rhs.snapshotKey
            }
            .compactMap { candidate in
                let endpointKey = BonjourBrowseEndpointIdentity.key(for: candidate.endpoint)
                guard seenEndpointKeys.insert(endpointKey).inserted else { return nil }
                return candidate.endpoint
            }
    }

    // MARK: - Private Methods - TXT Record
    
    /// Builds untrusted discovery metadata from values already validated against
    /// the committed protocol identity. Trust is established only by handshake.
    nonisolated static func primaryBonjourInteropAdvertisementWireData(
        validatedDeviceId: String,
        protocolIdentityFingerprint: String,
        platform: BonjourInteropProtocolContract.AdvertisementPlatform
    ) throws -> Data {
        try BonjourInteropProtocolContract.canonicalAdvertisementWireData(
            deviceId: validatedDeviceId,
            pubKeyFingerprint: protocolIdentityFingerprint,
            platform: platform,
            role: .control
        )
    }

    /// 创建 TXT 记录（用于广播）
    private func createTXTRecord(
        authority: ProtocolIdentitySnapshot
    ) throws -> NWTXTRecord {
        let validatedAuthority = try ProtocolIdentityBindingCompat(
            deviceId: authority.deviceId,
            protocolSigningAlgorithm: authority.signingAlgorithm,
            protocolPublicKeyBytes: authority.signingPublicKey
        )
        guard validatedAuthority.deviceId == authority.deviceId,
              validatedAuthority.protocolPublicKeyFingerprint
                == authority.signingPublicKeyFingerprint
        else {
            throw NSError(
                domain: "DeviceDiscoveryManager",
                code: -2203,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Bonjour authority fingerprint does not match its algorithm-tagged public key"
                ]
            )
        }
        let wireData = try Self.primaryBonjourInteropAdvertisementWireData(
            validatedDeviceId: validatedAuthority.deviceId,
            protocolIdentityFingerprint: validatedAuthority.protocolPublicKeyFingerprint,
            platform: localPlatform == .iPadOS ? .iPadOS : .iOS
        )
        return NWTXTRecord(wireData)
    }

    // MARK: - Private Methods - Cleanup
    
    /// 启动设备清理定时器
    private func startCleanupTimer() {
        cleanupTimer?.invalidate()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupStaleDevices()
            }
        }
        cleanupTimer?.tolerance = 6 // 允许系统合并唤醒（省电）
    }

    private func startPeriodicRefreshTimer() {
        periodicRefreshTimer?.invalidate()
        periodicRefreshTimer = nil

        guard periodicRefreshIntervalSeconds > 0 else { return }

        periodicRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: periodicRefreshIntervalSeconds, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Soft refresh only (see `refresh()`).
                await self?.refresh()
            }
        }
        SkyBridgeLogger.shared.debug("🔁 设备发现周期刷新已启用：\(periodicRefreshIntervalSeconds)s")
    }

    private func admitDiscoveryDeviceIfNeeded(_ deviceId: String) -> Bool {
        if deviceCache[deviceId] != nil { return true }
        pruneDiscoveryReverseIndexes()
        guard deviceCache.count >= Self.maximumCachedDevices else { return true }

        let protectedIdentifiers = P2PConnectionManager.instance.protectedDiscoveryIdentifiers
        let activeIdentifiers = P2PConnectionManager.instance.activeDiscoveryIdentifiers
        let evictionCandidate =
            deviceLastActivity
            .sorted { $0.value < $1.value }
            .map(\.key)
            .first { candidateId in
                let aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: candidateId))
                return !protectedIdentifiers.contains(candidateId)
                    && aliases.isDisjoint(with: protectedIdentifiers)
                    && !activeIdentifiers.contains(candidateId)
                    && aliases.isDisjoint(with: activeIdentifiers)
                    && !hasLiveBrowseEndpoint(for: candidateId)
            }
        guard let evictionCandidate else {
            SkyBridgeLogger.shared.warning(
                "⚠️ Bonjour 设备缓存已达上限，拒绝未受保护的新设备: limit=\(Self.maximumCachedDevices)"
            )
            return false
        }
        removeCachedDiscoveryDevice(evictionCandidate)
        return true
    }

    @discardableResult
    private func recordEndpointMapping(_ endpointKey: String, deviceId: String) -> Bool {
        if endpointToDeviceId[endpointKey] == nil,
            endpointToDeviceId.count >= Self.maximumEndpointMappings
        {
            pruneDiscoveryReverseIndexes()
        }
        guard
            endpointToDeviceId[endpointKey] != nil
                || endpointToDeviceId.count < Self.maximumEndpointMappings
        else {
            return false
        }
        endpointToDeviceId[endpointKey] = deviceId
        return true
    }

    private func recordDiscoveryAliases(_ aliases: Set<String>, deviceId: String) {
        var combined = discoveryIdentityAliasesByDeviceId[deviceId] ?? []
        combined.formUnion(aliases)
        if combined.count > Self.maximumAliasesPerDevice {
            combined = Set(
                combined.sorted { lhs, rhs in
                    let lhsStrong = lhs.lowercased().hasPrefix("id:")
                    let rhsStrong = rhs.lowercased().hasPrefix("id:")
                    if lhsStrong != rhsStrong { return lhsStrong }
                    return lhs < rhs
                }.prefix(Self.maximumAliasesPerDevice)
            )
        }
        discoveryIdentityAliasesByDeviceId[deviceId] = combined
    }

    private func removeCachedDiscoveryDevice(_ deviceId: String) {
        deviceCache.removeValue(forKey: deviceId)
        deviceLastActivity.removeValue(forKey: deviceId)
        discoveryIdentityAliasesByDeviceId.removeValue(forKey: deviceId)
        endpointToDeviceId = endpointToDeviceId.filter { $0.value != deviceId }
        identityAliasToDeviceId = identityAliasToDeviceId.filter { $0.value != deviceId }
        for serviceType in Array(advertisementSnapshotsByServiceType.keys) {
            advertisementSnapshotsByServiceType[serviceType] =
                advertisementSnapshotsByServiceType[serviceType]?.filter { $0.value.deviceId != deviceId }
            if advertisementSnapshotsByServiceType[serviceType]?.isEmpty == true {
                advertisementSnapshotsByServiceType.removeValue(forKey: serviceType)
            }
        }
    }

    private func pruneDiscoveryReverseIndexes() {
        let validDeviceIds = Set(deviceCache.keys)
        endpointToDeviceId = endpointToDeviceId.filter { validDeviceIds.contains($0.value) }
        discoveryIdentityAliasesByDeviceId = discoveryIdentityAliasesByDeviceId.filter {
            validDeviceIds.contains($0.key)
        }
        identityAliasToDeviceId = identityAliasToDeviceId.filter {
            validDeviceIds.contains($0.value)
        }
        for serviceType in Array(advertisementSnapshotsByServiceType.keys) {
            advertisementSnapshotsByServiceType[serviceType] =
                advertisementSnapshotsByServiceType[serviceType]?.filter {
                    validDeviceIds.contains($0.value.deviceId)
                }
            if advertisementSnapshotsByServiceType[serviceType]?.isEmpty == true {
                advertisementSnapshotsByServiceType.removeValue(forKey: serviceType)
            }
        }
    }
    
    /// 清理过期设备
    private func cleanupStaleDevices() {
        let now = Date()
        var removedCount = 0
        let protectedIdentifiers = P2PConnectionManager.instance.protectedDiscoveryIdentifiers
        let activeIdentifiers = P2PConnectionManager.instance.activeDiscoveryIdentifiers
        
        for (deviceId, lastActivity) in deviceLastActivity {
            let deviceAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
            let isProtected =
                protectedIdentifiers.contains(deviceId)
                || !deviceAliases.isDisjoint(with: protectedIdentifiers)
            let isActivelyConnected =
                activeIdentifiers.contains(deviceId) || !deviceAliases.isDisjoint(with: activeIdentifiers)
            let hasLiveEndpoint = hasLiveBrowseEndpoint(for: deviceId)
            if isProtected || hasLiveEndpoint {
                deviceLastActivity[deviceId] = now
                if var device = deviceCache[deviceId] {
                    device.lastSeen = now
                    device.isConnected = isActivelyConnected
                    deviceCache[deviceId] = device
                }
                continue
            }
            if now.timeIntervalSince(lastActivity) > deviceTimeout {
                removeCachedDiscoveryDevice(deviceId)
                removedCount += 1
            }
        }
        
        if removedCount > 0 {
            updateDiscoveredDevices()
            SkyBridgeLogger.shared.debug("🧹 清理了 \(removedCount) 个过期设备")
        }
    }

    private func hasLiveBrowseEndpoint(for deviceId: String) -> Bool {
        let targetAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
        guard !targetAliases.isEmpty else { return false }

        for endpointKeys in liveBrowseEndpointKeysByServiceType.values {
            for endpointKey in endpointKeys {
                guard let mappedDeviceId = endpointToDeviceId[endpointKey] else { continue }
                let mappedAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: mappedDeviceId))
                if !targetAliases.isDisjoint(with: mappedAliases) {
                    return true
                }
            }
        }

        return false
    }
    
    /// 更新发现的设备列表
    private func updateDiscoveredDevices() {
        coalesceEquivalentCachedDevices()
        rebuildIdentityAliasIndex()

        // 按最后活动时间排序
        discoveredDevices = Array(deviceCache.values).sorted { $0.lastSeen > $1.lastSeen }
        
        // 按平台分组
        var grouped: [DevicePlatform: [DiscoveredDevice]] = [:]
        for device in discoveredDevices {
            grouped[device.platform, default: []].append(device)
        }
        devicesByPlatform = grouped
    }

    /// 去抖触发 updateDiscoveredDevices()：合并高频浏览事件突发，避免每个事件都同步跑 O(n²) 去重。
    /// 缓存的增删改是廉价同步操作（已在调用处完成）；昂贵的合并/重建/发布推迟到突发结束后一次完成。
    private func scheduleDiscoveredDevicesUpdate() {
        pendingDiscoveredDevicesUpdateTask?.cancel()
        pendingDiscoveredDevicesUpdateTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            self?.pendingDiscoveredDevicesUpdateTask = nil
            self?.updateDiscoveredDevices()
        }
    }

    private func coalesceEquivalentCachedDevices() {
        let devices = Array(deviceCache.values)
        guard devices.count > 1 else { return }

        var parent = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.id) })

        func find(_ id: String) -> String {
            var current = id
            while let next = parent[current], next != current {
                current = next
            }
            return current
        }

        func union(_ lhs: String, _ rhs: String) {
            let lhsRoot = find(lhs)
            let rhsRoot = find(rhs)
            guard lhsRoot != rhsRoot else { return }
            parent[rhsRoot] = lhsRoot
        }

        for lhsIndex in devices.indices {
            for rhsIndex in devices.index(after: lhsIndex)..<devices.endIndex {
                if shouldCoalesceDiscoveryDevices(devices[lhsIndex], devices[rhsIndex]) {
                    union(devices[lhsIndex].id, devices[rhsIndex].id)
                }
            }
        }

        var groups: [String: [DiscoveredDevice]] = [:]
        for device in devices {
            groups[find(device.id), default: []].append(device)
        }

        guard groups.values.contains(where: { $0.count > 1 }) else { return }

        var replacementByOriginalId: [String: String] = [:]
        var nextCache: [String: DiscoveredDevice] = [:]
        var nextLastActivity: [String: Date] = [:]

        for group in groups.values {
            let merged = mergeEquivalentDiscoveryGroup(group)
            nextCache[merged.id] = merged
            nextLastActivity[merged.id] =
                group
                .compactMap { deviceLastActivity[$0.id] }
                .max()
                ?? group.map(\.lastSeen).max()
                ?? Date()
            for device in group {
                replacementByOriginalId[device.id] = merged.id
            }
        }

        deviceCache = nextCache
        deviceLastActivity = nextLastActivity
        endpointToDeviceId = endpointToDeviceId.reduce(into: [:]) { result, element in
            result[element.key] = replacementByOriginalId[element.value] ?? element.value
        }
        for serviceType in Array(advertisementSnapshotsByServiceType.keys) {
            var remappedSnapshots = advertisementSnapshotsByServiceType[serviceType] ?? [:]
            for endpointKey in Array(remappedSnapshots.keys) {
                guard var snapshot = remappedSnapshots[endpointKey] else { continue }
                snapshot.deviceId = replacementByOriginalId[snapshot.deviceId] ?? snapshot.deviceId
                remappedSnapshots[endpointKey] = snapshot
            }
            advertisementSnapshotsByServiceType[serviceType] = remappedSnapshots
        }
        discoveryIdentityAliasesByDeviceId = discoveryIdentityAliasesByDeviceId.reduce(into: [:]) {
            result, element in
            let replacementId = replacementByOriginalId[element.key] ?? element.key
            result[replacementId, default: []].formUnion(element.value)
        }
    }

    private func shouldCoalesceDiscoveryDevices(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice)
        -> Bool
    {
        guard lhs.id != rhs.id else { return true }

        // 身份矛盾判定走 SkyBridgeProtocolCore 的共享规则，与 macOS 侧
        // (UnifiedOnlineDeviceManager.findSimilarDevice / DeviceDiscoveryService.findSimilarDevice)
        // 使用同一份实现，避免两端各写一套、修好一端另一端还错。
        // 语义与原先的 PeerIdentityAliasResolver.persistentDeviceId 比对保持一致。
        let lhsEvidence = PeerIdentityFusionPolicy.IdentityEvidence(
            stableDeviceId: PeerIdentityFusionPolicy.normalizedStableDeviceId(lhs.id),
            publicKeyFingerprint: nil
        )
        let rhsEvidence = PeerIdentityFusionPolicy.IdentityEvidence(
            stableDeviceId: PeerIdentityFusionPolicy.normalizedStableDeviceId(rhs.id),
            publicKeyFingerprint: nil
        )
        guard PeerIdentityFusionPolicy.mayFuseOnCorroboratingSignal(
            lhs: lhsEvidence,
            rhs: rhsEvidence
        ) else {
            return false
        }

        let lhsAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: lhs))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: lhs.id))
        let rhsAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: rhs))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: rhs.id))
        if !lhsAliases.isEmpty, !lhsAliases.isDisjoint(with: rhsAliases) {
            return true
        }

        guard discoveryModelsCompatible(lhs.modelName, rhs.modelName) else { return false }
        guard discoveryPlatformsCompatible(lhs.platform, rhs.platform) else { return false }
        guard discoveryCandidateAddressesCompatible(lhs, rhs) else { return false }
        guard hasAuthoritativeDiscoveryAnchor(lhs, rhs) else { return false }
        guard hasEndpointDiscoveryRoute(lhs, rhs) else { return false }

        if discoveryNamesRepresentSameDevice(lhs.name, rhs.name) {
            return true
        }

        return discoveryMacNamesRepresentSameDevice(lhs.name, rhs.name)
            && isAppleMacPresentation(lhs)
            && isAppleMacPresentation(rhs)
            && hasSkyBridgeDiscoveryRouteEvidence(lhs)
            && hasSkyBridgeDiscoveryRouteEvidence(rhs)
    }

    private func mergeEquivalentDiscoveryGroup(_ group: [DiscoveredDevice]) -> DiscoveredDevice {
        guard var merged = group.sorted(by: shouldPreferDiscoveryDevice).first else {
            fatalError("mergeEquivalentDiscoveryGroup requires at least one device")
        }

        for device in group where device.id != merged.id {
            merged = merge(existing: merged, update: device)
        }

        if let preferredId = group.map(\.id).max(by: { identifierPriority($0) < identifierPriority($1) }
        ),
            preferredId != merged.id
        {
            merged = copyDiscoveryDevice(merged, id: preferredId)
        }

        merged.lastSeen = group.map(\.lastSeen).max() ?? merged.lastSeen
        merged.isConnected = group.contains(where: \.isConnected)
        merged.isTrusted = group.contains(where: \.isTrusted)
        return merged
    }

    private func copyDiscoveryDevice(_ device: DiscoveredDevice, id: String) -> DiscoveredDevice {
        DiscoveredDevice(
            id: id,
            name: device.name,
            bonjourServiceName: device.bonjourServiceName,
            modelName: device.modelName,
            platform: device.platform,
            osVersion: device.osVersion,
            ipAddress: device.ipAddress,
            bonjourServiceType: device.bonjourServiceType,
            bonjourServiceDomain: device.bonjourServiceDomain,
            services: device.services,
            portMap: device.portMap,
            signalStrength: device.signalStrength,
            lastSeen: device.lastSeen,
            isConnected: device.isConnected,
            isTrusted: device.isTrusted,
            publicKey: device.publicKey,
            advertisedCapabilities: device.advertisedCapabilities,
            capabilities: device.capabilities
        )
    }

    private func shouldPreferDiscoveryDevice(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> Bool {
        let lhsPriority = identifierPriority(lhs.id)
        let rhsPriority = identifierPriority(rhs.id)
        if lhsPriority != rhsPriority {
            return lhsPriority > rhsPriority
        }
        if hasBonjourRoute(lhs) != hasBonjourRoute(rhs) {
            return hasBonjourRoute(lhs)
        }
        if lhs.ipAddress != nil, rhs.ipAddress == nil { return true }
        if lhs.ipAddress == nil, rhs.ipAddress != nil { return false }
        return lhs.lastSeen > rhs.lastSeen
    }

    private func identifierPriority(_ id: String) -> Int {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("id:") { return 500 }
        if normalized.hasPrefix("bonjour:") { return 320 }
        if normalized.hasPrefix("host:") { return 220 }
        if normalized.hasPrefix("endpoint:") { return 120 }
        return 80
    }

    private func isStrongDiscoveryIdentifier(_ id: String) -> Bool {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("id:")
    }

    private func hasBonjourRoute(_ device: DiscoveredDevice) -> Bool {
        device.bonjourServiceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || device.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix(
                "bonjour:")
    }

    private func hasAuthoritativeDiscoveryAnchor(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice)
        -> Bool
    {
        authoritativeDiscoveryAnchor(lhs) || authoritativeDiscoveryAnchor(rhs)
    }

    private func authoritativeDiscoveryAnchor(_ device: DiscoveredDevice) -> Bool {
        isStrongDiscoveryIdentifier(device.id) && (device.isTrusted || device.isConnected)
    }

    private func hasEndpointDiscoveryRoute(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> Bool {
        hasEndpointDiscoveryRoute(lhs) || hasEndpointDiscoveryRoute(rhs)
    }

    private func hasEndpointDiscoveryRoute(_ device: DiscoveredDevice) -> Bool {
        !isStrongDiscoveryIdentifier(device.id) && hasSkyBridgeDiscoveryRouteEvidence(device)
    }

    private func discoveryCandidateAddressesCompatible(
        _ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice
    ) -> Bool {
        guard let lhsIP = normalizedDiscoveryAddress(lhs.ipAddress),
            let rhsIP = normalizedDiscoveryAddress(rhs.ipAddress)
        else {
            return true
        }
        return lhsIP == rhsIP
    }

    private func normalizedDiscoveryAddress(_ raw: String?) -> String? {
        guard var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !token.isEmpty
        else {
            return nil
        }
        if let percent = token.firstIndex(of: "%") {
            token = String(token[..<percent])
        }
        return token
    }

    private func isIPadPresentation(_ device: DiscoveredDevice) -> Bool {
        [
            device.name,
            device.modelName,
            device.platform.rawValue
        ]
        .joined(separator: " ")
        .lowercased()
        .contains("ipad")
    }

    private func discoveryNamesRepresentSameDevice(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = normalizedDiscoveryName(lhs)
        let rhs = normalizedDiscoveryName(rhs)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        let minLength = min(lhs.count, rhs.count)
        guard minLength >= 8 else { return false }
        return lhs.contains(rhs) || rhs.contains(lhs)
    }

    private func discoveryMacNamesRepresentSameDevice(_ lhs: String, _ rhs: String) -> Bool {
        let lhsName = normalizedDiscoveryName(lhs)
        let rhsName = normalizedDiscoveryName(rhs)
        let lhsIsModelIdentifier = isAppleMacHardwareModelIdentifier(lhsName)
        let rhsIsModelIdentifier = isAppleMacHardwareModelIdentifier(rhsName)
        guard lhsIsModelIdentifier != rhsIsModelIdentifier else {
            return false
        }

        let presentationName = lhsIsModelIdentifier ? rhsName : lhsName
        return discoveryAppleDeviceFamilyToken(presentationName) == "mac"
    }

    private func isAppleMacHardwareModelIdentifier(_ normalizedName: String) -> Bool {
        guard normalizedName.contains(where: { $0.isNumber }) else { return false }
        return normalizedName.hasPrefix("macbookpro")
            || normalizedName.hasPrefix("macbookair")
            || normalizedName.hasPrefix("macmini")
            || normalizedName.hasPrefix("macstudio")
            || normalizedName.hasPrefix("macpro")
            || normalizedName.hasPrefix("imac")
    }

    private func isAppleMacPresentation(_ device: DiscoveredDevice) -> Bool {
        if device.platform == .macOS { return true }
        return discoveryAppleDeviceFamilyToken(
            [
                device.modelName,
                device.name,
                device.platform.rawValue
            ].joined(separator: " ")
        ) == "mac"
    }

    private func discoveryAppleDeviceFamilyToken(_ raw: String) -> String? {
        let normalized = normalizedDiscoveryName(raw)
        guard !normalized.isEmpty else { return nil }
        if normalized.contains("ipad") { return "ipad" }
        if normalized.contains("iphone") || normalized.contains("ios") { return "iphone" }
        if normalized.contains("macbook")
            || normalized.contains("macmini")
            || normalized.contains("macstudio")
            || normalized.contains("macpro")
            || normalized.contains("imac")
            || normalized == "mac"
            || normalized == "macos"
        {
            return "mac"
        }
        return nil
    }

    private func hasSkyBridgeDiscoveryRouteEvidence(_ device: DiscoveredDevice) -> Bool {
        if hasBonjourRoute(device) || device.ipAddress != nil {
            return true
        }

        let routeHints =
            device.services
            + Array(device.portMap.keys)
            + [device.bonjourServiceType, device.id].compactMap { $0 }
        return routeHints.contains { hint in
            hint.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .contains("skybridge")
        }
    }

    private func discoveryModelsCompatible(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = normalizedDiscoveryName(lhs)
        let rhs = normalizedDiscoveryName(rhs)
        guard !lhs.isEmpty, !rhs.isEmpty else { return true }
        if lhs == rhs { return true }
        return discoveryGenericModel(lhs, containsDetailedModel: rhs)
            || discoveryGenericModel(rhs, containsDetailedModel: lhs)
    }

    private func discoveryGenericModel(_ generic: String, containsDetailedModel detailed: String)
        -> Bool
    {
        switch generic {
        case "ipad":
            return detailed.hasPrefix("ipad")
        case "iphone":
            return detailed.hasPrefix("iphone")
        case "mac":
            return detailed.hasPrefix("mac")
        default:
            return false
        }
    }

    private func discoveryPlatformsCompatible(_ lhs: DevicePlatform, _ rhs: DevicePlatform) -> Bool {
        if lhs == .unknown || rhs == .unknown || lhs == rhs {
            return true
        }
        let mobile: Set<DevicePlatform> = [.iOS, .iPadOS]
        return mobile.contains(lhs) && mobile.contains(rhs)
    }

    private func normalizedDiscoveryName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
    
    // MARK: - Public Helpers
    
    /// 获取特定平台的设备
    public func devices(for platform: DevicePlatform) -> [DiscoveredDevice] {
        devicesByPlatform[platform] ?? []
    }

#if DEBUG || SKYBRIDGE_TESTING
    func injectDiscoveredDevicesForTesting(_ devices: [DiscoveredDevice]) {
        discoveredDevices = devices
        devicesByPlatform = Dictionary(grouping: devices, by: \.platform)
    }

        func debugMergeDiscoveryDevice(
            existing: DiscoveredDevice,
            update: DiscoveredDevice
        ) -> DiscoveredDevice {
            merge(existing: existing, update: update)
        }

        @discardableResult
        func debugReplaceAdvertisementSnapshot(
            _ device: DiscoveredDevice,
            endpoint: NWEndpoint? = nil,
            interfaces: [NWInterface] = [],
            endpointKey: String,
            serviceType: DiscoveryServiceType,
            replacingEndpointKey: String? = nil
        ) -> DiscoveredDevice? {
            guard let observedEndpoint = endpoint ?? BonjourRouteTuple(device).map({ route in
                NWEndpoint.service(
                    name: route.name,
                    type: route.type,
                    domain: route.domain,
                    interface: nil
                )
            }) else {
                return nil
            }
            replaceAdvertisementSnapshot(
                device,
                endpoint: observedEndpoint,
                interfaces: interfaces,
                endpointKey: endpointKey,
                serviceType: serviceType,
                replacingEndpointKey: replacingEndpointKey
            )
            updateDiscoveredDevices()
            return deviceCache[device.id]
        }

        @discardableResult
        func debugRemoveAdvertisementSnapshot(
            endpointKey: String,
            deviceId: String,
            serviceType: DiscoveryServiceType,
            protectedIdentifiers: Set<String> = [],
            activeIdentifiers: Set<String> = []
        ) -> DiscoveredDevice? {
            removeAdvertisementSnapshot(
                endpointKey: endpointKey,
                fallbackDeviceId: deviceId,
                serviceType: serviceType,
                protectedIdentifiers: protectedIdentifiers,
                activeIdentifiers: activeIdentifiers
            )
            updateDiscoveredDevices()
            return deviceCache[deviceId]
        }

    func debugCreateAdvertisingTXTRecord(
        authority: ProtocolIdentitySnapshot
    ) throws -> NWTXTRecord {
        try createTXTRecord(authority: authority)
    }
#endif
    
    /// 获取 SkyBridge 兼容设备（支持 PQC 握手）
    public func skybridgeCompatibleDevices() -> [DiscoveredDevice] {
        // 目前所有发现的设备都可能兼容
        // 后续可以根据 TXT 记录中的 pqc 字段过滤
        discoveredDevices
    }

    struct DebugState {
        let deviceCache: [String: DiscoveredDevice]
        let endpointToDeviceId: [String: String]
        let liveBrowseEndpointKeysByServiceType: [DiscoveryServiceType: Set<String>]
        let advertisementSnapshotsByServiceType: [DiscoveryServiceType: [String: BonjourAdvertisementSnapshot]]
        let deviceLastActivity: [String: Date]
        let isDiscovering: Bool
        let authorizationBlockedServiceTypes: Set<DiscoveryServiceType>
        let authorizationRecoveryAttempts: [DiscoveryServiceType: Int]
    }

    static func debugMakeIsolatedInstance() -> DeviceDiscoveryManager {
        DeviceDiscoveryManager()
    }

    func debugCaptureState() -> DebugState {
        DebugState(
            deviceCache: deviceCache,
            endpointToDeviceId: endpointToDeviceId,
            liveBrowseEndpointKeysByServiceType: liveBrowseEndpointKeysByServiceType,
            advertisementSnapshotsByServiceType: advertisementSnapshotsByServiceType,
            deviceLastActivity: deviceLastActivity,
            isDiscovering: isDiscovering,
            authorizationBlockedServiceTypes: authorizationBlockedServiceTypes,
            authorizationRecoveryAttempts: authorizationRecoveryAttempts
        )
    }

    func debugRestoreState(_ state: DebugState) {
        deviceCache = state.deviceCache
        endpointToDeviceId = state.endpointToDeviceId
        liveBrowseEndpointKeysByServiceType = state.liveBrowseEndpointKeysByServiceType
        advertisementSnapshotsByServiceType = state.advertisementSnapshotsByServiceType
        deviceLastActivity = state.deviceLastActivity
        isDiscovering = state.isDiscovering
        authorizationBlockedServiceTypes = state.authorizationBlockedServiceTypes
        authorizationRecoveryAttempts = state.authorizationRecoveryAttempts
        updateDiscoveredDevices()
    }

    func debugSeedDiscoveryState(
        devices: [DiscoveredDevice],
        lastActivity: Date,
        endpointToDeviceId: [String: String],
        liveBrowseEndpointKeysByServiceType: [DiscoveryServiceType: Set<String>],
        isDiscovering: Bool = false
    ) {
        deviceCache = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        deviceLastActivity = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, lastActivity) })
        self.endpointToDeviceId = endpointToDeviceId
        self.liveBrowseEndpointKeysByServiceType = liveBrowseEndpointKeysByServiceType
        advertisementSnapshotsByServiceType.removeAll()
        self.isDiscovering = isDiscovering
        updateDiscoveredDevices()
    }

    func debugRunCleanupStaleDevices() {
        cleanupStaleDevices()
    }

    var debugCachedDeviceIds: Set<String> {
        Set(deviceCache.keys)
    }

    func debugSeedAuthorizationRecoveryState(
        blockedServiceTypes: Set<DiscoveryServiceType>,
        attempts: [DiscoveryServiceType: Int],
        isDiscovering: Bool
    ) {
        authorizationBlockedServiceTypes = blockedServiceTypes
        authorizationRecoveryAttempts = attempts
        self.isDiscovering = isDiscovering
    }

    var debugAuthorizationBlockedServiceTypes: Set<DiscoveryServiceType> {
        authorizationBlockedServiceTypes
    }

    var debugAuthorizationRecoveryAttempts: [DiscoveryServiceType: Int] {
        authorizationRecoveryAttempts
    }
    
    /// 解析服务端点以获取 IP 地址
    public func resolveEndpoint(_ device: DiscoveredDevice) async -> String? {
        // 如果已经有 IP 地址，直接返回
        if let ip = device.ipAddress {
            return ip
        }

        guard let name = device.bonjourServiceName,
              let type = device.bonjourServiceType,
            let domain = device.bonjourServiceDomain
        else {
            return nil
        }

        // Bonjour service -> IP：优先用 NetService 做 DNS-SD 解析（不需要真的建立 TCP 连接）
        let resolved = await resolveBonjourServiceIPAddress(
            name: name,
            type: type,
            domain: domain,
            timeout: 2.0
        )

        if let resolved, var cached = deviceCache[device.id] {
            cached.ipAddress = resolved
            cached.lastSeen = Date()
            deviceCache[device.id] = cached
            updateDiscoveredDevices()
        }

        return resolved
    }

    public func setConnectionLiveness(for device: DiscoveredDevice, isConnected: Bool) {
        guard
            let projection = DiscoveryConnectionLivenessProjectionPolicy.projection(
                presentedDeviceId: device.id,
                cachedDeviceIds: Set(deviceCache.keys),
                isConnected: isConnected,
                authenticatedSessionIsTrusted: device.isTrusted
            ), var cached = deviceCache[projection.deviceId]
        else {
                return
            }

        let timestamp = Date()
        cached.isConnected = projection.isConnected
        cached.isTrusted = projection.isTrusted
            cached.lastSeen = timestamp
        deviceCache[projection.deviceId] = cached
        deviceLastActivity[projection.deviceId] = timestamp
            updateDiscoveredDevices()
        }

    private func resolveBonjourServiceIPAddress(
        name: String,
        type: String,
        domain: String,
        timeout: TimeInterval
    ) async -> String? {
        let normalizedType = type.hasSuffix(".") ? type : (type + ".")
        let d = domain.isEmpty ? "local." : domain
        let normalizedDomain = d.hasSuffix(".") ? d : (d + ".")

        let service = NetService(domain: normalizedDomain, type: normalizedType, name: name)
        let resolver = BonjourNetServiceResolver(service: service, timeout: timeout)
        return await resolver.resolve()
    }
}

// MARK: - Bonjour resolver (NetService)

/// 将 Bonjour service (name/type/domain) 解析为一个可展示/可连接的 IP 字符串。
///
/// Swift 6 严格并发说明：
/// - `NetService` 不是 Sendable，delegate 回调可能发生在任意线程；因此 delegate 方法标记为 `nonisolated`
/// - 回调中只提取 `Data`（Sendable）后切回 `@MainActor` 完成收尾与 continuation
@MainActor
private final class BonjourNetServiceResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<String?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    init(service: NetService, timeout: TimeInterval) {
        self.service = service
        self.timeout = timeout
        super.init()
    }

    func resolve() async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            self.continuation = cont
            service.delegate = self
            service.resolve(withTimeout: timeout)

            // 兜底超时：确保 continuation 一定会被 resume
            timeoutTask?.cancel()
            timeoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let nanos = UInt64((timeout + 0.2) * 1_000_000_000)
                do {
                    try await Task.sleep(nanoseconds: nanos)
                } catch {
                    return
                }
                self.finish(nil)
            }
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let ip = preferredIPAddress(from: sender.addresses)
        Task { @MainActor in
            self.finish(ip)
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        _ = errorDict
        Task { @MainActor in
            self.finish(nil)
        }
    }

    private func finish(_ ip: String?) {
        guard !finished else { return }
        finished = true

        timeoutTask?.cancel()
        timeoutTask = nil

        service.stop()
        service.delegate = nil

        continuation?.resume(returning: ip)
        continuation = nil
    }
}

private func preferredIPAddress(from addresses: [Data]?) -> String? {
    guard let addresses, !addresses.isEmpty else { return nil }

    var ipv6Candidate: String?
    for data in addresses {
        guard let ip = ipString(from: data) else { continue }
        // 优先返回 IPv4（更易用于 UI 展示与后续连接）
        if ip.contains(".") { return ip }
        if ipv6Candidate == nil { ipv6Candidate = ip }
    }
    return ipv6Candidate
}

private func ipString(from addressData: Data) -> String? {
    addressData.withUnsafeBytes { rawBuffer -> String? in
        guard let base = rawBuffer.baseAddress else { return nil }
        let sockaddrPtr = base.assumingMemoryBound(to: sockaddr.self)

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            sockaddrPtr,
            socklen_t(addressData.count),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
	        )
	        guard result == 0 else { return nil }
	        return host.withUnsafeBufferPointer { buffer in
	            guard let base = buffer.baseAddress else { return nil }
	            return String(cString: base)
	        }
	    }
	}
