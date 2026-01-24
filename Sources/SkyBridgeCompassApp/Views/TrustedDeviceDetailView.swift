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

                Text(status.rawValue)
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
}

@available(macOS 14.0, *)
struct TrustedDeviceDetailView: View {
    let record: TrustRecord
    let onRemoveTrust: (_ idsToRevoke: [String], _ declaredDeviceId: String?) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.deviceName ?? "受信任设备")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("已配对/已信任")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 10) {
                infoRow("设备 ID", value: record.deviceId)
                infoRow("公钥指纹", value: record.pubKeyFP.isEmpty ? "（未绑定/引导模式）" : record.pubKeyFP)
                
                let c = capsDict
                if let v = c["platform"], !v.isEmpty { infoRow("平台", value: v) }
                if let v = c["osVersion"], !v.isEmpty { infoRow("系统版本", value: v) }
                if let v = c["modelName"], !v.isEmpty { infoRow("型号", value: v) }
                if let v = c["chip"], !v.isEmpty { infoRow("芯片", value: v) }
                infoRow("更新时间", value: record.updatedAt.formatted(date: .numeric, time: .standard))
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            
            Spacer()
            
            HStack {
                Spacer()
                Button(role: .destructive) {
                    onRemoveTrust(idsToRevoke, declaredDeviceId)
                } label: {
                    Label("移除信任", systemImage: "trash")
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
}


