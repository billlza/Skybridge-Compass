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
    let relatedRecords: [TrustRecord]
    let presentationMetadata: ApplePeerDeviceMetadataNormalizer.Presentation
    let status: OnlineDeviceStatus
    let onDisconnect: ((_ idsToDisconnect: [String], _ declaredDeviceId: String?) -> Void)?
    let onRepairP2PTrust: (_ idsToRepair: [String]) -> Void
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
                
                let normalizedMetadata = presentationMetadata
                if let v = normalizedMetadata.platform, !v.isEmpty { infoRow(ui(chinese: "平台", english: "Platform", japanese: "プラットフォーム"), value: v) }
                if let v = normalizedMetadata.osVersion, !v.isEmpty { infoRow(ui(chinese: "系统版本", english: "OS Version", japanese: "OS バージョン"), value: v) }
                if let v = normalizedMetadata.modelName, !v.isEmpty { infoRow(ui(chinese: "型号", english: "Model", japanese: "モデル"), value: v) }
                if let v = normalizedMetadata.chip, !v.isEmpty { infoRow(ui(chinese: "芯片", english: "Chip", japanese: "チップ"), value: v) }
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
                Button {
                    onRepairP2PTrust(idsToRevoke)
                } label: {
                    Label(ui(chinese: "修复 P2P 信任", english: "Repair P2P Trust", japanese: "P2P 信頼を修復"), systemImage: "wrench.and.screwdriver")
                }
                Button(role: .destructive) {
                    onRemoveTrust(idsToRevoke, declaredDeviceId)
                } label: {
                    Label(ui(chinese: "彻底忘记设备", english: "Forget Device", japanese: "デバイスを完全に忘れる"), systemImage: "trash")
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
        for item in mergedCapabilities {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                dict[parts[0]] = parts[1]
            }
        }
        return dict
    }

    private var mergedCapabilities: [String] {
        let records = relatedRecords.isEmpty ? [record] : relatedRecords
        return TrustSyncService.buildDisplayGroups(from: records).first?.displayRecord.capabilities ?? record.capabilities
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
        let records = relatedRecords.isEmpty ? [record] : relatedRecords

        for relatedRecord in records {
            ids.insert(relatedRecord.deviceId)
            ids.formUnion(relatedRecord.knownDeviceIds)

            let caps = capabilityDictionary(for: relatedRecord.capabilities)
            if let peer = caps["peerEndpoint"], !peer.isEmpty {
                ids.insert(peer)
            }
            if let declared = caps["declaredDeviceId"], !declared.isEmpty {
                ids.insert(declared)
            }
        }
        return Array(ids)
    }

    private func capabilityDictionary(for capabilities: [String]) -> [String: String] {
        var dict: [String: String] = [:]
        for item in capabilities {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    dict[parts[0]] = value
                }
            }
        }
        return dict
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
