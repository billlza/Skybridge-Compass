import SwiftUI
import SkyBridgeCore

/// 在线设备行组件(支持新的统一设备模型)
public struct OnlineDeviceRow: View {
    let device: OnlineDevice
    let onConnect: () -> Void
    @StateObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var presenceService = ConnectionPresenceService.shared
    
    public init(device: OnlineDevice, onConnect: @escaping () -> Void) {
        self.device = device
        self.onConnect = onConnect
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: settingsManager.compactMode ? 8 : 12) {
            HStack {
 // 设备图标
                if settingsManager.showDeviceIcons {
                    Image(systemName: deviceIcon)
                        .font(settingsManager.compactMode ? .body : .title2)
                        .foregroundColor(deviceColor)
                        .frame(width: settingsManager.compactMode ? 24 : 32, height: settingsManager.compactMode ? 24 : 32)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(device.name)
                            .font(.headline)
                            .foregroundColor(.white)
                        
 // 本机标签
                        if device.isLocalDevice {
                            Text(LocalizationManager.shared.localizedString("device.local"))
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.8))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        
 // 已授权标签
                        if device.isAuthorized {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                    
                    if settingsManager.showDeviceDetails {
                        Text(device.ipv4 ?? device.ipv6 ?? LocalizationManager.shared.localizedString("device.noIP"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
 // 连接状态指示器
                VStack(spacing: 4) {
                    Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    
                    if settingsManager.showConnectionStats {
                        Text(statusText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
 // 连接类型标签
            if settingsManager.showDeviceDetails && !device.connectionTypes.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(device.connectionTypes.sorted(by: { $0.rawValue < $1.rawValue })), id: \.self) { connectionType in
                        HStack(spacing: 4) {
                            Image(systemName: connectionType.iconName)
                                .font(.system(size: 10))
                            Text(connectionType.rawValue)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(connectionTypeColor(for: connectionType))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            
 // 设备信息
            if settingsManager.showConnectionStats || settingsManager.showDeviceRSSI {
                HStack {
                    if settingsManager.showConnectionStats {
                        HStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text(device.sources.map { $0.rawValue }.joined(separator: ", "))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if settingsManager.showDeviceRSSI, let signal = device.signalStrength {
                        Text("RSSI \(Int(signal))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    // 服务数量
                    if settingsManager.showConnectionStats && !device.services.isEmpty {
                        Text("\(device.services.count) \(LocalizationManager.shared.localizedString("device.servicesCount"))")
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                }
            }
            
 // 连接按钮(仅对非本机、在线或已连接的设备显示)
            if !device.isLocalDevice && (device.connectionStatus == .online || device.connectionStatus == .connected) {
                Button(action: onConnect) {
                    HStack {
                        Image(systemName: device.connectionStatus == .connected ? "link" : "link.circle")
                            .font(.caption)
                        Text(device.connectionStatus == .connected ? connectedStatusText : LocalizationManager.shared.localizedString("device.action.connect"))
                            .font(.caption.weight(.medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(device.connectionStatus == .connected ? Color.green.opacity(0.8) : Color.blue.opacity(0.8))
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(device.connectionStatus == .connected)
            }
        }
        .padding(settingsManager.compactMode ? 10 : 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 20/255, green: 25/255, blue: 45/255))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(statusBorderColor, lineWidth: device.isLocalDevice ? 2 : 1)
                )
        )
    }

    private var baseConnectedText: String {
        LocalizationManager.shared.localizedString("device.status.connected")
    }

    private var resolvedCryptoKind: String? {
        matchingPresenceConnection?.cryptoKind ?? device.lastCryptoKind
    }

    private var resolvedCryptoSuite: String? {
        matchingPresenceConnection?.suite ?? device.lastCryptoSuite
    }

    private var connectedStatusText: String {
        ConnectionCryptoPresentation.connectedStatusTextWithPolicyFallback(
            kind: resolvedCryptoKind,
            suite: resolvedCryptoSuite,
            baseConnectedText: baseConnectedText,
            compatibilityModeEnabled: settingsManager.enableCompatibilityMode
        )
    }

    private var statusText: String {
        if device.isLocalDevice {
            return device.connectionStatus.rawValue
        }
        guard device.connectionStatus == .connected else {
            return device.connectionStatus.rawValue
        }
        return connectedStatusText
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
    
    private var deviceColor: Color {
        switch device.connectionStatus {
        case .connected: return .green
        case .online: return .blue
        case .offline: return .gray
        }
    }
    
    private var statusColor: Color {
        switch device.connectionStatus {
        case .connected: return .green
        case .online: return .blue
        case .offline: return .gray
        }
    }
    
    private var statusBorderColor: Color {
        if device.isLocalDevice {
            return .blue
        }
        return Color.white.opacity(0.1)
    }
}
