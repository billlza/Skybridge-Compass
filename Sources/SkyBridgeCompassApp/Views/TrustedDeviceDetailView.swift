import SwiftUI
import SkyBridgeCore

@available(macOS 14.0, *)
struct TrustedDeviceCard: View {
    let record: TrustRecord
    let subtitle: String
    let status: OnlineDeviceStatus
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(.green)
                    .frame(width: 28)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.deviceName ?? "未知设备")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()

                Text(statusText)
                    .font(.caption2)
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.14), in: Capsule())
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    private var iconName: String {
        let caps = record.capabilities.joined(separator: "|").lowercased()
        if caps.contains("ios") || caps.contains("iphone") { return "iphone" }
        if caps.contains("ipad") { return "ipad" }
        if caps.contains("macos") || caps.contains("mac") { return "laptopcomputer" }
        return "shield.checkered"
    }
    
    private var statusColor: Color {
        switch status {
        case .connected:
            return .green
        case .online:
            return .blue
        case .offline:
            return .secondary
        }
    }

    private var statusText: String {
        switch status {
        case .connected:
            return localizedText(
                chinese: "已连接",
                english: "Connected",
                japanese: "接続済み"
            )
        case .online:
            return localizedText(
                chinese: "在线",
                english: "Online",
                japanese: "オンライン"
            )
        case .offline:
            return localizedText(
                chinese: "离线",
                english: "Offline",
                japanese: "オフライン"
            )
        }
    }

    private func localizedText(chinese: String, english: String, japanese: String) -> String {
        switch currentLanguageCode {
        case "en":
            return english
        case "ja":
            return japanese
        default:
            return chinese
        }
    }

    private var currentLanguageCode: String {
        switch LocalizationManager.shared.currentLanguage {
        case .en:
            return "en"
        case .ja:
            return "ja"
        case .zhHans:
            return "zh"
        case .system:
            let identifier = LocalizationManager.shared.locale.identifier.lowercased()
            if identifier.hasPrefix("ja") {
                return "ja"
            }
            if identifier.hasPrefix("en") {
                return "en"
            }
            return "zh"
        }
    }
}

@available(macOS 14.0, *)
struct TrustedDeviceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let record: TrustRecord
    let status: OnlineDeviceStatus
    let onDisconnect: ((_ idsToDisconnect: [String], _ declaredDeviceId: String?) -> Void)?
    let onRemoveTrust: (_ idsToRevoke: [String], _ declaredDeviceId: String?) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Image(systemName: "checkmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.deviceName ?? "受信任设备")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(ui(chinese: "已配对/已信任", english: "Paired / Trusted", japanese: "ペア済み / 信頼済み"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 10) {
                infoRow(ui(chinese: "设备 ID", english: "Device ID", japanese: "デバイス ID"), value: record.deviceId)
                infoRow(
                    ui(chinese: "公钥指纹", english: "Public Key Fingerprint", japanese: "公開鍵フィンガープリント"),
                    value: record.pubKeyFP.isEmpty ? ui(chinese: "（未绑定/引导模式）", english: "(Bootstrap / Unbound)", japanese: "（未バインド / ブートストラップ）") : record.pubKeyFP
                )
                
                let c = capsDict
                if let v = c["platform"], !v.isEmpty { infoRow(ui(chinese: "平台", english: "Platform", japanese: "プラットフォーム"), value: v) }
                if let v = c["osVersion"], !v.isEmpty { infoRow(ui(chinese: "系统版本", english: "OS Version", japanese: "OS バージョン"), value: v) }
                if let v = c["modelName"], !v.isEmpty { infoRow(ui(chinese: "型号", english: "Model", japanese: "モデル"), value: v) }
                if let v = c["chip"], !v.isEmpty { infoRow(ui(chinese: "芯片", english: "Chip", japanese: "チップ"), value: v) }
                infoRow(ui(chinese: "更新时间", english: "Updated At", japanese: "更新日時"), value: record.updatedAt.formatted(date: .numeric, time: .standard))
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            
            Spacer()
            
            HStack {
                Button(LocalizationManager.shared.localizedString("action.close")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()
                if status == .connected, let onDisconnect {
                    Button(role: .destructive) {
                        onDisconnect(idsToRevoke, declaredDeviceId)
                    } label: {
                        Label(LocalizationManager.shared.localizedString("action.disconnect"), systemImage: "xmark.circle")
                    }
                }
                Button(role: .destructive) {
                    onRemoveTrust(idsToRevoke, declaredDeviceId)
                } label: {
                    Label(ui(chinese: "移除信任", english: "Remove Trust", japanese: "信頼を解除"), systemImage: "trash")
                }
                .keyboardShortcut(.delete)
            }
        }
    }
    
    private func infoRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundColor(.primary)
                .textSelection(.enabled)
            Spacer()
        }
    }
    
    private var capsDict: [String: String] {
        var dict: [String: String] = [:]
        for item in record.capabilities {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                dict[parts[0]] = parts[1]
            }
        }
        return dict
    }
    
    private var declaredDeviceId: String? {
        // If this record is an alias, it carries declaredDeviceId.
        // If this is canonical, declaredDeviceId is the record.deviceId itself.
        if let declared = capsDict["declaredDeviceId"], !declared.isEmpty {
            return declared
        }
        return record.deviceId
    }
    
    private var idsToRevoke: [String] {
        var ids = Set<String>()
        ids.insert(record.deviceId)
        let c = capsDict
        
        // If canonical record holds peerEndpoint=bonjour:..., revoke that alias too.
        if let peer = c["peerEndpoint"], !peer.isEmpty {
            ids.insert(peer)
        }
        // If alias record carries declaredDeviceId, revoke canonical too.
        if let declared = c["declaredDeviceId"], !declared.isEmpty {
            ids.insert(declared)
        }
        return Array(ids)
    }

    private func ui(chinese: String, english: String, japanese: String) -> String {
        switch LocalizationManager.shared.currentLanguage {
        case .en:
            return english
        case .ja:
            return japanese
        case .zhHans:
            return chinese
        case .system:
            let identifier = LocalizationManager.shared.locale.identifier.lowercased()
            if identifier.hasPrefix("ja") {
                return japanese
            }
            if identifier.hasPrefix("en") {
                return english
            }
            return chinese
        }
    }
}
