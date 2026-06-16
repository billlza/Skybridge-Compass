import Foundation
import Network
import SwiftUI
#if canImport(UIKit)
@preconcurrency import UIKit
#endif

// MARK: - Core Models

/// 设备平台枚举
public enum DevicePlatform: String, Codable, Sendable, CaseIterable {
    case iOS = "ios"
    case iPadOS = "ipados"
    case macOS = "macos"
    case android = "android"
    case linux = "linux"
    case windows = "windows"
    case unknown = "unknown"
    
    /// 平台显示名称
    public var displayName: String {
        switch self {
        case .iOS: return "iOS"
        case .iPadOS: return "iPadOS"
        case .macOS: return "macOS"
        case .android: return "Android"
        case .linux: return "Linux"
        case .windows: return "Windows"
        case .unknown: return "Unknown"
        }
    }
    
    /// 平台图标名称
    public var iconName: String {
        switch self {
        case .iOS: return "iphone"
        case .iPadOS: return "ipad"
        case .macOS: return "desktopcomputer"
        case .android: return "candybarphone"
        case .linux: return "pc"
        case .windows: return "laptopcomputer"
        case .unknown: return "questionmark.circle"
        }
    }
    
    /// 平台渐变色
    public var gradientColors: [Color] {
        switch self {
        case .iOS, .iPadOS:
            return [Color(red: 0.0, green: 0.48, blue: 1.0), Color(red: 0.35, green: 0.68, blue: 1.0)]
        case .macOS:
            return [Color(red: 0.5, green: 0.5, blue: 0.5), Color(red: 0.7, green: 0.7, blue: 0.7)]
        case .android:
            return [Color(red: 0.24, green: 0.73, blue: 0.31), Color(red: 0.55, green: 0.85, blue: 0.45)]
        case .linux:
            return [Color(red: 0.87, green: 0.68, blue: 0.13), Color(red: 0.95, green: 0.82, blue: 0.40)]
        case .windows:
            return [Color(red: 0.0, green: 0.47, blue: 0.84), Color(red: 0.0, green: 0.65, blue: 0.95)]
        case .unknown:
            return [Color.gray, Color.gray.opacity(0.7)]
        }
    }
    
    /// 平台徽章颜色
    public var badgeColor: Color {
        switch self {
        case .iOS, .iPadOS: return .blue
        case .macOS: return .gray
        case .android: return .green
        case .linux: return .orange
        case .windows: return .cyan
        case .unknown: return .gray
        }
    }
}

enum AppleMobileDeviceIdentity {
    struct Snapshot: Sendable, Equatable {
        let stableDeviceId: String
        let vendorDeviceId: String?
        let deviceName: String
        let platform: DevicePlatform
        let platformName: String
        let osVersion: String
        let modelIdentifier: String
        let modelName: String
        let chip: String
    }

    struct ModelPresentation: Sendable, Equatable {
        let modelName: String
        let chip: String
    }

    static func currentSnapshot() -> Snapshot {
        #if canImport(UIKit)
        let values = currentDeviceValues()
        let platform = values.userInterfaceIdiom == .pad ? DevicePlatform.iPadOS : .iOS
        let modelIdentifier = currentModelIdentifier()
        let presentation = presentation(forModelIdentifier: modelIdentifier, platform: platform)
        let deviceName = displayDeviceName(
            rawDeviceName: values.deviceName,
            platform: platform,
            modelName: presentation.modelName
        )
        return Snapshot(
            stableDeviceId: ProtocolDeviceIdentity.stableDeviceId(),
            vendorDeviceId: values.vendorDeviceId,
            deviceName: deviceName,
            platform: platform,
            platformName: platform.displayName,
            osVersion: values.systemVersion,
            modelIdentifier: modelIdentifier,
            modelName: presentation.modelName,
            chip: presentation.chip
        )
        #else
        return Snapshot(
            stableDeviceId: "unknown-device",
            vendorDeviceId: nil,
            deviceName: "Unknown Device",
            platform: .unknown,
            platformName: DevicePlatform.unknown.displayName,
            osVersion: "",
            modelIdentifier: "unknown",
            modelName: "Unknown Device",
            chip: "Unknown SoC"
        )
        #endif
    }

    static func presentation(
        forModelIdentifier modelIdentifier: String,
        platform: DevicePlatform
    ) -> ModelPresentation {
        let normalized = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return ModelPresentation(
                modelName: fallbackModelName(for: platform),
                chip: fallbackChipName(for: platform)
            )
        }

        switch normalized {
        case "iPhone17,1":
            return ModelPresentation(modelName: "iPhone 16 Pro", chip: "A18 Pro")
        case "iPhone17,2":
            return ModelPresentation(modelName: "iPhone 16 Pro Max", chip: "A18 Pro")
        case "iPhone17,3":
            return ModelPresentation(modelName: "iPhone 16", chip: "A18")
        case "iPhone17,4":
            return ModelPresentation(modelName: "iPhone 16 Plus", chip: "A18")
        case "iPad16,3", "iPad16,4":
            return ModelPresentation(modelName: "iPad Pro 11-inch (M4)", chip: "M4")
        default:
            return ModelPresentation(
                modelName: normalized,
                chip: fallbackChipName(for: platform)
            )
        }
    }

    static func displayDeviceName(
        rawDeviceName: String?,
        platform: DevicePlatform,
        modelName: String
    ) -> String {
        let trimmedRawName = rawDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedRawName.isEmpty,
           !isGenericSystemDeviceName(trimmedRawName, platform: platform),
           !BonjourServiceIdentitySanitizer.isIdentifierLikeDisplayName(trimmedRawName) {
            return trimmedRawName
        }

        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModelName.isEmpty {
            return trimmedModelName
        }

        return fallbackModelName(for: platform)
    }

    private static func currentModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
                String(cString: ptr)
            }
        }
    }

    #if canImport(UIKit)
    @MainActor
    private static func currentDeviceValuesOnMainActor() -> (
        userInterfaceIdiom: UIUserInterfaceIdiom,
        vendorDeviceId: String?,
        deviceName: String,
        systemVersion: String
    ) {
        let device = UIDevice.current
        return (
            device.userInterfaceIdiom,
            device.identifierForVendor?.uuidString,
            device.name,
            device.systemVersion
        )
    }

    private static func currentDeviceValues() -> (
        userInterfaceIdiom: UIUserInterfaceIdiom,
        vendorDeviceId: String?,
        deviceName: String,
        systemVersion: String
    ) {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                currentDeviceValuesOnMainActor()
            }
        }

        // This path is used by networking/signaling code that may already be
        // holding a worker queue while the main actor is busy. Never synchronously
        // bounce to the main queue from here; use stable non-UIKit facts instead.
        let modelIdentifier = currentModelIdentifier()
        let platform: DevicePlatform = modelIdentifier.hasPrefix("iPad") ? .iPadOS : .iOS
        let presentation = presentation(forModelIdentifier: modelIdentifier, platform: platform)
        return (
            platform == .iPadOS ? .pad : .phone,
            nil,
            displayDeviceName(rawDeviceName: nil, platform: platform, modelName: presentation.modelName),
            ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
    #endif

    private static func fallbackModelName(for platform: DevicePlatform) -> String {
        switch platform {
        case .iPadOS:
            return "iPad"
        case .iOS:
            return "iPhone"
        default:
            return "Apple Device"
        }
    }

    private static func fallbackChipName(for platform: DevicePlatform) -> String {
        switch platform {
        case .iOS, .iPadOS:
            return "Apple SoC"
        default:
            return "Apple Silicon"
        }
    }

    private static func isGenericSystemDeviceName(_ name: String, platform: DevicePlatform) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch platform {
        case .iPadOS:
            return normalized == "ipad"
        case .iOS:
            return normalized == "iphone" || normalized == "ipod touch"
        default:
            return normalized == "ios device" || normalized == "apple device"
        }
    }
}

enum BonjourServiceIdentitySanitizer {
    static func sanitizedServiceInstanceName(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if value.lowercased().hasPrefix("bonjour:") {
            let payload = String(value.dropFirst("bonjour:".count))
            let name = payload.split(separator: "@", maxSplits: 1).first.map(String.init)
            return sanitizedServiceInstanceName(name)
        }

        if let range = value.range(of: "._") {
            value = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lowercased = value.lowercased()
        guard !lowercased.hasPrefix("id:"),
              !lowercased.hasPrefix("host:"),
              !lowercased.hasPrefix("peer:"),
              !lowercased.hasPrefix("recent:"),
              !lowercased.hasPrefix("ip:"),
              !lowercased.hasPrefix("fp:"),
              !lowercased.hasPrefix("mac:") else {
            return nil
        }
        guard UUID(uuidString: value.uppercased()) == nil else { return nil }
        guard !isLiteralIPAddress(value) else { return nil }
        guard !value.contains("/") else { return nil }
        return value.isEmpty ? nil : value
    }

    static func sanitizedDisplayNameCandidate(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !isIdentifierLikeDisplayName(value) else {
            return nil
        }
        return value
    }

    static func isIdentifierLikeDisplayName(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let lowercased = value.lowercased()
        if lowercased.hasPrefix("id:")
            || lowercased.hasPrefix("fp:")
            || lowercased.hasPrefix("peer:")
            || lowercased.hasPrefix("host:")
            || lowercased.hasPrefix("ip:")
            || lowercased.hasPrefix("serial:")
            || lowercased.hasPrefix("mac:")
            || lowercased.hasPrefix("bonjour:")
            || lowercased.hasPrefix("recent:")
            || lowercased.hasPrefix("cross-network:")
            || lowercased.hasPrefix("webrtc-") {
            return true
        }
        if UUID(uuidString: value.uppercased()) != nil {
            return true
        }
        if value.range(of: "^[0-9A-Fa-f]{24,128}$", options: .regularExpression) != nil {
            return true
        }
        return isLiteralIPAddress(value)
    }

    private static func isLiteralIPAddress(_ raw: String) -> Bool {
        let scopedToken = raw.split(separator: "%", maxSplits: 1).first.map(String.init) ?? raw
        return IPv4Address(scopedToken) != nil || IPv6Address(scopedToken) != nil
    }
}

/// 发现的设备
public struct DiscoveredDevice: Identifiable, Codable, Sendable {
    public let id: String
    public var name: String
    /// Bonjour service instance name（用于 NWEndpoint.service 连接；通常等于对端 publish 的 serviceName）
    public var bonjourServiceName: String?
    public var modelName: String
    public var platform: DevicePlatform
    public var osVersion: String
    public var ipAddress: String?
    /// Bonjour 服务类型（例如：_skybridge._tcp / _skybridge._udp）。用于在无 IP 时仍可直接连接。
    public var bonjourServiceType: String?
    /// Bonjour 域（一般为 local.）。用于在无 IP 时构造 NWEndpoint.service 连接。
    public var bonjourServiceDomain: String?
    /// 该设备被发现到的所有 Bonjour 服务类型（用于能力推断与端口展示）
    public var services: [String]
    /// 端口映射：serviceType -> port（有些情况下端口无法直接从 NWBrowser 获得，需要依赖 TXT 记录或后续 resolve）
    public var portMap: [String: UInt16]
    public var signalStrength: Int // RSSI
    public var lastSeen: Date
    public var isConnected: Bool
    public var isTrusted: Bool
    public var publicKey: Data?
    /// 设备在 TXT 里声明的能力（comma-separated）
    public var advertisedCapabilities: [String]
    public var capabilities: [String]
    
    public init(
        id: String,
        name: String,
        bonjourServiceName: String? = nil,
        modelName: String,
        platform: DevicePlatform,
        osVersion: String,
        ipAddress: String? = nil,
        bonjourServiceType: String? = nil,
        bonjourServiceDomain: String? = nil,
        services: [String] = [],
        portMap: [String: UInt16] = [:],
        signalStrength: Int = -50,
        lastSeen: Date = Date(),
        isConnected: Bool = false,
        isTrusted: Bool = false,
        publicKey: Data? = nil,
        advertisedCapabilities: [String] = [],
        capabilities: [String] = []
    ) {
        self.id = id
        self.name = name
        self.bonjourServiceName = bonjourServiceName
        self.modelName = modelName
        self.platform = platform
        self.osVersion = osVersion
        self.ipAddress = ipAddress
        self.bonjourServiceType = bonjourServiceType
        self.bonjourServiceDomain = bonjourServiceDomain
        self.services = services
        self.portMap = portMap
        self.signalStrength = signalStrength
        self.lastSeen = lastSeen
        self.isConnected = isConnected
        self.isTrusted = isTrusted
        self.publicKey = publicKey
        self.advertisedCapabilities = advertisedCapabilities
        self.capabilities = capabilities
    }
    
    /// 便捷初始化器
    public init(
        id: String,
        name: String,
        platform: DevicePlatform,
        ipAddress: String?
    ) {
        self.id = id
        self.name = name
        self.bonjourServiceName = nil
        self.modelName = name
        self.platform = platform
        self.osVersion = ""
        self.ipAddress = ipAddress
        self.bonjourServiceType = nil
        self.bonjourServiceDomain = nil
        self.services = []
        self.portMap = [:]
        self.signalStrength = -50
        self.lastSeen = Date()
        self.isConnected = false
        self.isTrusted = false
        self.publicKey = nil
        self.advertisedCapabilities = []
        self.capabilities = []
    }
}

// MARK: - DiscoveredDevice helpers (capabilities/ports)

public extension DiscoveredDevice {
    /// SkyBridge File Transfer Bonjour service type
    static let fileTransferServiceType = "_skybridge-transfer._tcp"
    /// SkyBridge Remote Control Bonjour service type
    static let remoteControlServiceType = "_skybridge-remote._tcp"
    static let classicResumeCapability = ClassicTransferCapability.classicResume

    var supportsFileTransfer: Bool {
        capabilities.contains("file_transfer") || services.contains(Self.fileTransferServiceType)
    }

    var supportsClassicResume: Bool {
        advertisedCapabilities.contains(Self.classicResumeCapability)
            || capabilities.contains(Self.classicResumeCapability)
    }

    var supportsRemoteControl: Bool {
        capabilities.contains("remote_control")
            || remoteControlPort != nil
            || services.contains(Self.remoteControlServiceType)
    }

    func port(for serviceType: String) -> UInt16? {
        portMap[serviceType]
    }

    var fileTransferPort: UInt16? { port(for: Self.fileTransferServiceType) }
    var remoteControlPort: UInt16? { port(for: Self.remoteControlServiceType) }
}

public enum ConnectableAddressCanonicalizer {
    public static func connectionTarget(_ raw: String?) -> String? {
        canonicalize(raw, preserveInterfaceScope: true)
    }

    public static func lookupKey(_ raw: String?) -> String? {
        canonicalize(raw, preserveInterfaceScope: false)
    }

    public static func isLinkLocal(_ raw: String?) -> Bool {
        guard let address = lookupKey(raw) else { return false }
        if IPv4Address(address) != nil {
            return address.hasPrefix("169.254.")
        }
        if IPv6Address(address) != nil {
            return address.hasPrefix("fe80:")
        }
        return false
    }

    public static func isRoutableLANAddress(_ raw: String?) -> Bool {
        guard lookupKey(raw) != nil else { return false }
        return !isLinkLocal(raw)
    }

    public static func routeClass(_ raw: String?) -> String {
        guard lookupKey(raw) != nil else { return "invalid" }
        return isLinkLocal(raw) ? "link-local" : "lan-direct"
    }

    public static func prefersPeerToPeer(for raw: String?) -> Bool {
        guard lookupKey(raw) != nil else { return true }
        return isLinkLocal(raw)
    }

    public static func bestLANAddress(_ candidates: [String?]) -> String? {
        candidates
            .compactMap { connectionTarget($0) }
            .max { lhs, rhs in
                routePreference(lhs) < routePreference(rhs)
            }
    }

    private static func routePreference(_ raw: String) -> Int {
        if isRoutableLANAddress(raw) { return 2 }
        if isLinkLocal(raw) { return 1 }
        return 0
    }

    private static func canonicalize(
        _ raw: String?,
        preserveInterfaceScope: Bool
    ) -> String? {
        guard var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !token.isEmpty else {
            return nil
        }

        if token.hasPrefix("host:") {
            token = String(token.dropFirst("host:".count))
        } else if token.hasPrefix("peer:") {
            token = String(token.dropFirst("peer:".count))
        } else if token.hasPrefix("ip:") {
            token = String(token.dropFirst("ip:".count))
        }

        if token.hasPrefix("["),
           let closingBracket = token.lastIndex(of: "]"),
           closingBracket > token.startIndex {
            let suffixStart = token.index(after: closingBracket)
            let suffix = token[suffixStart...]
            let suffixIsPort = suffix.first == "."
                && suffix.dropFirst().allSatisfy({ $0.isNumber })
            if suffix.isEmpty || suffixIsPort {
                token = String(token[token.index(after: token.startIndex)..<closingBracket])
            }
        }

        if !preserveInterfaceScope,
           let percentIndex = token.firstIndex(of: "%") {
            token = String(token[..<percentIndex])
        }

        if !token.contains(":"),
           let colonIndex = token.lastIndex(of: ":"),
           token[token.index(after: colonIndex)...].allSatisfy({ $0.isNumber }) {
            token = String(token[..<colonIndex])
        }

        if token.contains(":"),
           let dot = token.lastIndex(of: "."),
           token[token.index(after: dot)...].allSatisfy({ $0.isNumber }) {
            token = String(token[..<dot])
        } else {
            let parts = token.split(separator: ".")
            if parts.count == 5,
               parts.dropLast().allSatisfy({ Int($0) != nil }),
               let port = Int(parts.last ?? ""),
               (0...65535).contains(port) {
                token = parts.dropLast().map(String.init).joined(separator: ".")
            }
        }

        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let validationToken: String
        if let percentIndex = normalized.firstIndex(of: "%") {
            validationToken = String(normalized[..<percentIndex])
        } else {
            validationToken = normalized
        }

        if IPv4Address(validationToken) != nil || IPv6Address(validationToken) != nil {
            return normalized
        }

        return nil
    }
}

/// P2P 连接
public struct Connection: Identifiable, Sendable {
    public let id: String
    public let device: DiscoveredDevice
    public var status: ConnectionStatus
    public var encryptionType: EncryptionType
    public var latency: TimeInterval
    public var bandwidth: Int64
    public var connectedAt: Date
    
    public init(
        id: String = UUID().uuidString,
        device: DiscoveredDevice,
        status: ConnectionStatus = .connected,
        encryptionType: EncryptionType = .pqc,
        latency: TimeInterval = 0.01,
        bandwidth: Int64 = 100_000_000,
        connectedAt: Date = Date()
    ) {
        self.id = id
        self.device = device
        self.status = status
        self.encryptionType = encryptionType
        self.latency = latency
        self.bandwidth = bandwidth
        self.connectedAt = connectedAt
    }
}

/// 连接状态
public enum ConnectionStatus: String, Codable, Sendable {
    case connecting = "connecting"
    case connected = "connected"
    case disconnecting = "disconnecting"
    case disconnected = "disconnected"
    case failed = "failed"
    case error = "error"
    
    /// 显示名称
    public var displayName: String {
        switch self {
        case .connecting: return RuntimeLocalization.string("连接中")
        case .connected: return RuntimeLocalization.string("已连接")
        case .disconnecting: return RuntimeLocalization.string("断开中")
        case .disconnected: return RuntimeLocalization.string("已断开")
        case .failed: return RuntimeLocalization.string("连接失败")
        case .error: return RuntimeLocalization.string("错误")
        }
    }
}

public enum ConnectionPresentationPhase: String, Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

public enum SessionDisconnectKind: String, Sendable, Equatable {
    case explicit
    case remoteLeave
    case transient
}

public enum ActiveSessionSnapshotSource: String, Sendable, Equatable {
    case p2p
    case qr
    case code
    case icloud
    case reused
}

public enum ActiveSessionSnapshotPhase: String, Sendable, Equatable {
    case connecting
    case transportReady
    case handshakeComplete
    case reconnecting
    case disconnecting
}

public struct ConnectionPresentationLabels: Sendable, Equatable {
    public let connectedText: String
    public let disconnectedText: String
    public let connectingText: String
    public let reconnectingText: String
    public let defaultGuardStatus: String
    public let crossNetworkGuardStatus: String

    public init(
        connectedText: String = "已连接",
        disconnectedText: String = "离线",
        connectingText: String = "连接中",
        reconnectingText: String = "重连中",
        defaultGuardStatus: String = "守护中",
        crossNetworkGuardStatus: String = "跨网已连接"
    ) {
        self.connectedText = connectedText
        self.disconnectedText = disconnectedText
        self.connectingText = connectingText
        self.reconnectingText = reconnectingText
        self.defaultGuardStatus = defaultGuardStatus
        self.crossNetworkGuardStatus = crossNetworkGuardStatus
    }
}

public struct ConnectionPresentationPeer: Sendable, Equatable {
    public let displayName: String
    public let cryptoKind: String?
    public let suite: String?
    public let guardStatus: String?
    public let isRekeying: Bool
    public let connectedAt: Date

    public init(
        displayName: String,
        cryptoKind: String? = nil,
        suite: String? = nil,
        guardStatus: String? = nil,
        isRekeying: Bool = false,
        connectedAt: Date = Date()
    ) {
        self.displayName = displayName
        self.cryptoKind = cryptoKind
        self.suite = suite
        self.guardStatus = guardStatus
        self.isRekeying = isRekeying
        self.connectedAt = connectedAt
    }
}

public struct ActiveSessionSnapshot: Sendable, Equatable {
    public let snapshotToken: UUID
    public let sessionId: String
    public let source: ActiveSessionSnapshotSource
    public let phase: ActiveSessionSnapshotPhase
    public let deviceId: String?
    public let deviceName: String?
    public let negotiatedSuite: String?
    public let updatedAt: Date

    public init(
        snapshotToken: UUID = UUID(),
        sessionId: String,
        source: ActiveSessionSnapshotSource,
        phase: ActiveSessionSnapshotPhase,
        deviceId: String? = nil,
        deviceName: String? = nil,
        negotiatedSuite: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.snapshotToken = snapshotToken
        self.sessionId = sessionId
        self.source = source
        self.phase = phase
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.negotiatedSuite = negotiatedSuite
        self.updatedAt = updatedAt
    }
}

public struct ConnectionPresentationInput: Sendable, Equatable {
    public let labels: ConnectionPresentationLabels
    public let fileTransferActive: Bool
    public let latestPeerConnection: ConnectionPresentationPeer?
    public let latestConnectedDevice: ConnectionPresentationPeer?
    public let latestPendingPeer: ConnectionPresentationPendingPeer?
    public let activeSessionSnapshot: ActiveSessionSnapshot?
    public let defaultPQCModeLabel: String?

    public init(
        labels: ConnectionPresentationLabels = ConnectionPresentationLabels(),
        fileTransferActive: Bool,
        latestPeerConnection: ConnectionPresentationPeer?,
        latestConnectedDevice: ConnectionPresentationPeer?,
        latestPendingPeer: ConnectionPresentationPendingPeer? = nil,
        activeSessionSnapshot: ActiveSessionSnapshot?,
        defaultPQCModeLabel: String? = nil
    ) {
        self.labels = labels
        self.fileTransferActive = fileTransferActive
        self.latestPeerConnection = latestPeerConnection
        self.latestConnectedDevice = latestConnectedDevice
        self.latestPendingPeer = latestPendingPeer
        self.activeSessionSnapshot = activeSessionSnapshot
        self.defaultPQCModeLabel = defaultPQCModeLabel
    }
}

public struct ConnectionPresentationPendingPeer: Sendable, Equatable {
    public let displayName: String
    public let cryptoKind: String?
    public let suite: String?
    public let guardStatus: String?
    public let isRekeying: Bool
    public let phase: ConnectionPresentationPhase

    public init(
        displayName: String,
        cryptoKind: String? = nil,
        suite: String? = nil,
        guardStatus: String? = nil,
        isRekeying: Bool = false,
        phase: ConnectionPresentationPhase
    ) {
        self.displayName = displayName
        self.cryptoKind = cryptoKind
        self.suite = suite
        self.guardStatus = guardStatus
        self.isRekeying = isRekeying
        self.phase = phase
    }
}

public enum ConnectionSecurityEvidence: String, Sendable, Equatable {
    case none
    case classic
    case pqc
}

public struct ConnectionPresentation: Sendable, Equatable {
    public let phase: ConnectionPresentationPhase
    public let isConnected: Bool
    public let statusText: String
    public let detailText: String?
    public let securityEvidence: ConnectionSecurityEvidence

    public init(
        phase: ConnectionPresentationPhase,
        isConnected: Bool,
        statusText: String,
        detailText: String?,
        securityEvidence: ConnectionSecurityEvidence = .none
    ) {
        self.phase = phase
        self.isConnected = isConnected
        self.statusText = statusText
        self.detailText = detailText
        self.securityEvidence = securityEvidence
    }
}

/// 加密类型
public enum EncryptionType: String, Codable, Sendable {
    case pqc = "pqc"          // 后量子加密
    case hybrid = "hybrid"     // 混合加密 (PQC + 经典)
    case classic = "classic"   // 经典加密
    case none = "none"
}

/// 文件传输
public struct FileTransfer: Identifiable, Codable, Sendable {
    public let id: String
    public var fileName: String
    public var fileSize: Int64
    public var fileType: FileType
    public var progress: Double
    public var speed: Double // bytes per second
    public var status: TransferStatus
    public var isIncoming: Bool
    public var remotePeer: String
    public var timestamp: Date
    /// 本地文件路径（接收时用于展示“保存位置”）
    public var localPath: String?
    
    public init(
        id: String = UUID().uuidString,
        fileName: String,
        fileSize: Int64,
        fileType: FileType = .other,
        progress: Double = 0.0,
        speed: Double = 0.0,
        status: TransferStatus = .pending,
        isIncoming: Bool,
        remotePeer: String,
        timestamp: Date = Date(),
        localPath: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.fileType = fileType
        self.progress = progress
        self.speed = speed
        self.status = status
        self.isIncoming = isIncoming
        self.remotePeer = remotePeer
        self.timestamp = timestamp
        self.localPath = localPath
    }
}

/// 文件类型
public enum FileType: String, Codable, Sendable {
    case image
    case video
    case audio
    case document
    case archive
    case other
}

/// 传输状态
public enum TransferStatus: String, Codable, Sendable {
    case pending
    case transferring
    case completed
    case failed
}

/// 用户信息
public struct User: Identifiable, Codable, Sendable {
    public let id: String
    public var email: String
    public var displayName: String
    public var avatarURL: URL?
    public var nebulaId: String?
    public var createdAt: Date
    
    public init(
        id: String,
        email: String,
        displayName: String,
        avatarURL: URL? = nil,
        nebulaId: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.nebulaId = nebulaId
        self.createdAt = createdAt
    }
}

/// 应用语言
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case system = "system"
    case english = "en"
    case chinese = "zh-Hans"
    case japanese = "ja"
    
    public var displayName: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        case .chinese: return "简体中文"
        case .japanese: return "日本語"
        }
    }
    
    public var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .english:
            return Locale(identifier: "en")
        case .chinese:
            return Locale(identifier: "zh-Hans")
        case .japanese:
            return Locale(identifier: "ja")
        }
    }

    public var acceptLanguageTag: String {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages
            guard !preferred.isEmpty else {
                return "en-US,en;q=0.9"
            }
            return preferred.prefix(3).enumerated().map { index, raw in
                let lang = raw.replacingOccurrences(of: "_", with: "-")
                if index == 0 {
                    return lang
                }
                let quality = max(0.1, 1.0 - Double(index) * 0.1)
                return "\(lang);q=\(String(format: "%.1f", quality))"
            }.joined(separator: ",")
        case .english:
            return "en-US,en;q=0.9"
        case .chinese:
            return "zh-CN,zh-Hans;q=0.9,en;q=0.5"
        case .japanese:
            return "ja-JP,ja;q=0.9,en;q=0.5"
        }
    }
}
