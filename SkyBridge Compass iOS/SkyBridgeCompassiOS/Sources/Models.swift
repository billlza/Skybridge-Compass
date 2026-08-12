import Foundation
import SwiftUI

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

    var supportsFileTransfer: Bool {
        capabilities.contains("file_transfer") || services.contains(Self.fileTransferServiceType)
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
        return normalized.isEmpty ? nil : normalized
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
    public let activeSessionSnapshot: ActiveSessionSnapshot?
    public let defaultPQCModeLabel: String?

    public init(
        labels: ConnectionPresentationLabels = ConnectionPresentationLabels(),
        fileTransferActive: Bool,
        latestPeerConnection: ConnectionPresentationPeer?,
        latestConnectedDevice: ConnectionPresentationPeer?,
        activeSessionSnapshot: ActiveSessionSnapshot?,
        defaultPQCModeLabel: String? = nil
    ) {
        self.labels = labels
        self.fileTransferActive = fileTransferActive
        self.latestPeerConnection = latestPeerConnection
        self.latestConnectedDevice = latestConnectedDevice
        self.activeSessionSnapshot = activeSessionSnapshot
        self.defaultPQCModeLabel = defaultPQCModeLabel
    }
}

public struct ConnectionPresentation: Sendable, Equatable {
    public let phase: ConnectionPresentationPhase
    public let isConnected: Bool
    public let statusText: String
    public let detailText: String?

    public init(
        phase: ConnectionPresentationPhase,
        isConnected: Bool,
        statusText: String,
        detailText: String?
    ) {
        self.phase = phase
        self.isConnected = isConnected
        self.statusText = statusText
        self.detailText = detailText
    }
}

public enum ActiveSessionSnapshotContract {
    public static func activate(
        sessionId: String,
        source: ActiveSessionSnapshotSource,
        phase: ActiveSessionSnapshotPhase,
        deviceId: String?,
        deviceName: String?,
        negotiatedSuite: String?,
        snapshotToken: UUID = UUID(),
        updatedAt: Date = Date()
    ) -> ActiveSessionSnapshot {
        ActiveSessionSnapshot(
            snapshotToken: snapshotToken,
            sessionId: sessionId,
            source: source,
            phase: phase,
            deviceId: deviceId,
            deviceName: deviceName,
            negotiatedSuite: negotiatedSuite,
            updatedAt: updatedAt
        )
    }

    public static func update(
        current: ActiveSessionSnapshot?,
        sessionId: String,
        snapshotToken: UUID,
        phase: ActiveSessionSnapshotPhase,
        deviceId: String? = nil,
        deviceName: String? = nil,
        negotiatedSuite: String? = nil,
        updatedAt: Date = Date()
    ) -> ActiveSessionSnapshot? {
        guard let current,
              current.sessionId == sessionId,
              current.snapshotToken == snapshotToken else {
            return current
        }

        return ActiveSessionSnapshot(
            snapshotToken: current.snapshotToken,
            sessionId: current.sessionId,
            source: current.source,
            phase: phase,
            deviceId: deviceId ?? current.deviceId,
            deviceName: deviceName ?? current.deviceName,
            negotiatedSuite: negotiatedSuite ?? current.negotiatedSuite,
            updatedAt: updatedAt
        )
    }

    public static func disconnect(
        current: ActiveSessionSnapshot?,
        sessionId: String,
        snapshotToken: UUID,
        kind: SessionDisconnectKind,
        updatedAt: Date = Date()
    ) -> ActiveSessionSnapshot? {
        guard let current,
              current.sessionId == sessionId,
              current.snapshotToken == snapshotToken else {
            return current
        }

        switch kind {
        case .explicit, .remoteLeave:
            return nil
        case .transient:
            return ActiveSessionSnapshot(
                snapshotToken: current.snapshotToken,
                sessionId: current.sessionId,
                source: current.source,
                phase: .reconnecting,
                deviceId: current.deviceId,
                deviceName: current.deviceName,
                negotiatedSuite: current.negotiatedSuite,
                updatedAt: updatedAt
            )
        }
    }
}

public enum ConnectionPresentationContract {
    public static func evaluate(_ input: ConnectionPresentationInput) -> ConnectionPresentation {
        if let snapshot = input.activeSessionSnapshot, snapshot.phase == .reconnecting {
            let detail = [input.labels.reconnectingText, snapshot.deviceName]
                .compactMap { normalized($0) }
                .joined(separator: " · ")
            return ConnectionPresentation(
                phase: .reconnecting,
                isConnected: true,
                statusText: input.labels.reconnectingText,
                detailText: detail.isEmpty ? input.labels.reconnectingText : detail
            )
        }

        if let peer = input.latestPeerConnection {
            return connectedPresentation(
                displayName: peer.displayName,
                kind: peer.cryptoKind,
                suite: peer.suite,
                guardStatus: peer.guardStatus ?? input.labels.defaultGuardStatus,
                isRekeying: peer.isRekeying,
                input: input
            )
        }

        if let snapshot = input.activeSessionSnapshot,
           snapshot.phase == .transportReady || snapshot.phase == .handshakeComplete {
            let detail = detailText(
                kind: nil,
                suite: snapshot.negotiatedSuite,
                guardStatus: input.labels.crossNetworkGuardStatus
            ) ?? normalized(snapshot.deviceName) ?? input.labels.crossNetworkGuardStatus
            return ConnectionPresentation(
                phase: .connected,
                isConnected: true,
                statusText: connectedStatusText(kind: nil, suite: snapshot.negotiatedSuite, isRekeying: false, input: input),
                detailText: detail
            )
        }

        if let device = input.latestConnectedDevice {
            return connectedPresentation(
                displayName: device.displayName,
                kind: device.cryptoKind,
                suite: device.suite,
                guardStatus: device.guardStatus ?? input.labels.defaultGuardStatus,
                isRekeying: device.isRekeying,
                input: input
            )
        }

        if input.fileTransferActive {
            return ConnectionPresentation(
                phase: .connected,
                isConnected: true,
                statusText: connectedStatusText(kind: nil, suite: nil, isRekeying: false, input: input),
                detailText: nil
            )
        }

        if let snapshot = input.activeSessionSnapshot, snapshot.phase == .connecting {
            return ConnectionPresentation(
                phase: .connecting,
                isConnected: false,
                statusText: input.labels.connectingText,
                detailText: normalized(snapshot.deviceName)
            )
        }

        return ConnectionPresentation(
            phase: .disconnected,
            isConnected: false,
            statusText: input.labels.disconnectedText,
            detailText: nil
        )
    }

    private static func connectedPresentation(
        displayName: String,
        kind: String?,
        suite: String?,
        guardStatus: String?,
        isRekeying: Bool,
        input: ConnectionPresentationInput
    ) -> ConnectionPresentation {
        ConnectionPresentation(
            phase: .connected,
            isConnected: true,
            statusText: connectedStatusText(kind: kind, suite: suite, isRekeying: isRekeying, input: input),
            detailText: rekeyDetailText(kind: kind, suite: suite, guardStatus: guardStatus, isRekeying: isRekeying)
                ?? detailText(kind: kind, suite: suite, guardStatus: guardStatus)
                ?? normalized(displayName)
        )
    }

    private static func connectedStatusText(
        kind: String?,
        suite: String?,
        isRekeying: Bool,
        input: ConnectionPresentationInput
    ) -> String {
        let base = input.labels.connectedText
        if isRekeying {
            return base
        }
        if let mode = modeLabel(kind: kind, suite: suite, defaultPQCModeLabel: input.defaultPQCModeLabel) {
            return "\(mode)\(base)"
        }
        return base
    }

    private static func rekeyDetailText(
        kind: String?,
        suite: String?,
        guardStatus: String?,
        isRekeying: Bool
    ) -> String? {
        guard isRekeying else {
            return nil
        }

        var components: [String] = []
        if let kind = normalized(kind) {
            components.append(kind)
        } else if let suite = normalized(suite) {
            components.append(suite)
        }
        if let guardStatus = normalized(guardStatus) {
            components.append(guardStatus)
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private static func detailText(kind: String?, suite: String?, guardStatus: String?) -> String? {
        let mode = modeLabel(kind: kind, suite: suite, defaultPQCModeLabel: nil)
        let trimmedSuite = normalized(suite)
        let trimmedGuard = normalized(guardStatus)

        var components: [String] = []
        if let mode {
            components.append(mode)
        }
        if let trimmedSuite, !shouldSuppressSuite(mode: mode, suite: trimmedSuite) {
            components.append(trimmedSuite)
        }
        if let trimmedGuard {
            components.append(trimmedGuard)
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private static func modeLabel(kind: String?, suite: String?, defaultPQCModeLabel: String?) -> String? {
        let suiteToken = normalizedToken(suite)
        if suiteToken.contains("xwing") {
            return "X-Wing"
        }
        if suiteToken.contains("x25519") || suiteToken.contains("p256") {
            return "Classic"
        }

        let kindToken = normalizedToken(kind)
        if kindToken.contains("xwing") {
            return "X-Wing"
        }
        if kindToken.contains("liboqs") || kindToken.contains("oqs") {
            return "liboqs"
        }
        if kindToken.contains("apple") {
            return "Apple PQC"
        }
        if kindToken.contains("classic") {
            return "Classic"
        }

        if suiteToken.contains("mlkem") || suiteToken.contains("mldsa") {
            return normalized(defaultPQCModeLabel)
        }

        return nil
    }

    private static func shouldSuppressSuite(mode: String?, suite: String) -> Bool {
        guard let mode else { return false }
        let modeToken = normalizedToken(mode)
        let suiteToken = normalizedToken(suite)
        if modeToken == suiteToken {
            return true
        }
        if modeToken == "xwing" && suiteToken.contains("xwing") {
            return true
        }
        return false
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedToken(_ value: String?) -> String {
        guard let raw = normalized(value)?.lowercased() else { return "" }
        var token = ""
        token.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            token.unicodeScalars.append(scalar)
        }
        return token
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
        id: String = UUID().uuidString.lowercased(),
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
