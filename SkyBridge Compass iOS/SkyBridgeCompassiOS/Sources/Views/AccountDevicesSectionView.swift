import SwiftUI
import SkyBridgeProtocolCore

/// 设备页顶部的「账号设备」区块（位于附近扫描之前）：同一账号下的全部设备（名称 / IP / 系统 / 在线状态）。
///
/// 连接语义：优先有效账号路由，其次身份一致的附近设备；没有路由时提供扫码入口。
/// iOS 是控制端，不会被别人控制：本机行标注「仅控制端」。
@available(iOS 17.0, *)
struct AccountDevicesSectionView: View {
    @ObservedObject private var presence = AccountPresenceService.shared
    @EnvironmentObject private var discoveryManager: DeviceDiscoveryManager
    @EnvironmentObject private var authManager: AuthenticationManager
    @State private var removalSelection: AccountDeviceRecord?
    @State private var selectionScope: UInt64 = 0

    var onConnectNearbyDevice: ((AccountDeviceRecord, DiscoveredDevice) -> Void)? = nil
    var onConnectRoutedDevice: ((AccountDeviceRecord) -> Void)? = nil
    var onOpenCrossNetworkConnect: (() -> Void)? = nil
    var isConnectionInProgress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let snapshot = presence.accountDevices,
               let issue = AccountDevicePresentation.registrationIssueText(for: snapshot) {
                notice(issue, tint: .orange)
            }
            if let failure = presence.lastListFailure, presence.accountDevices != nil {
                notice(
                    RuntimeLocalization.format("列表可能已过期（上次更新：%@）", [AccountDevicePresentation.relativeTimeText(from: presence.lastSuccessfulListAt)])
                        + " · " + AccountDevicePresentation.failureText(failure),
                    tint: .orange
                )
            }
            if presence.accountDevices?.truncated == true {
                notice(RuntimeLocalization.string("设备数量超过 200 台，仅显示前 200 台"), tint: .cyan)
            }
            if let heartbeatFailure = presence.lastHeartbeatFailure {
                notice(
                    RuntimeLocalization.string("本机在线状态上报失败，其他设备可能看不到这台设备")
                        + " · " + AccountDevicePresentation.failureText(heartbeatFailure),
                    tint: .orange
                )
            }
            if presence.lastRemovalFailure != nil { notice(RuntimeLocalization.string("accountDevices.remove.failed"), tint: .red) }
            if presence.callerRemoved { notice(RuntimeLocalization.string("accountDevices.remove.selfRemoved"), tint: .orange) }
            content
        }
        .alert(RuntimeLocalization.string("accountDevices.remove.title"),
               isPresented: Binding(get: { removalSelection != nil }, set: { if !$0 { removalSelection = nil } }),
               presenting: removalSelection) { record in
            Button(RuntimeLocalization.string("accountDevices.remove.confirm"), role: .destructive) {
                let scope = selectionScope; removalSelection = nil
                Task { await presence.removeDevice(record, expectedScope: scope) }
            }
            Button(RuntimeLocalization.string("accountDevices.remove.cancel"), role: .cancel) { removalSelection = nil }
        } message: { record in
            Text(RuntimeLocalization.format("accountDevices.remove.message", [AccountDevicePresentationPolicy.displayName(for: record)]))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.rectangle.stack.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(RuntimeLocalization.string("账号设备"))
                    .font(.headline)
                    .foregroundStyle(LiquidGlass.supportingText)
                if let nebulaId = authManager.currentUser?.nebulaId, !nebulaId.isEmpty {
                    Text("Nebula ID · \(nebulaId)")
                        .font(.caption.monospaced())
                        .foregroundStyle(LiquidGlass.supportingText)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let updatedAt = presence.lastSuccessfulListAt {
                Text(RuntimeLocalization.format("更新于 %@", [AccountDevicePresentation.relativeTimeText(from: updatedAt)]))
                    .font(.caption2)
                    .foregroundStyle(LiquidGlass.supportingText)
            }
            Button {
                presence.triggerRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tint)
            }
            .accessibilityLabel(Text(RuntimeLocalization.string("刷新")))
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = presence.accountDevices {
            let devices = AccountDevicePresentationPolicy.orderedDevices(snapshot.devices)
            if devices.isEmpty {
                emptyState(
                    icon: "person.crop.rectangle.stack",
                    title: RuntimeLocalization.string("还没有其他设备"),
                    message: RuntimeLocalization.string("在其他设备上用同一账号登录 SkyBridge，它就会出现在这里")
                )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(devices) { record in
                        VStack(alignment: .leading, spacing: 6) {
                        AccountDeviceRowView(
                            record: record,
                            nearbyDevice: nearbyDevice(for: record),
                            onConnectNearbyDevice: onConnectNearbyDevice,
                            hasLiveRoute: presence.hasLiveRoute(for: record),
                            onConnectRoutedDevice: onConnectRoutedDevice,
                            onOpenCrossNetworkConnect: onOpenCrossNetworkConnect,
                            isConnectionInProgress: isConnectionInProgress
                        )
                        Button(RuntimeLocalization.string("accountDevices.remove.action"), role: .destructive) {
                            selectionScope = presence.removalScope; removalSelection = record
                        }
                        .disabled(presence.removingDeviceId != nil || !snapshot.devices.contains { $0.isCaller && $0.status == "active" })
                        .accessibilityIdentifier("account-device-remove-\(record.deviceId)")
                        }
                    }
                }
                .liquidGlassGroup(spacing: 6)
            }
        } else if let failure = presence.lastListFailure {
            let isSignedOut = failure == .notAuthenticated && !presence.isAuthenticated
            emptyState(
                icon: isSignedOut ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle",
                title: isSignedOut
                    ? RuntimeLocalization.string("登录后才能看到本账号的设备")
                    : AccountDevicePresentation.failureText(failure),
                message: isSignedOut
                    ? RuntimeLocalization.string("在其他设备上用同一账号登录 SkyBridge，它就会出现在这里")
                    : RuntimeLocalization.string("将自动重试；也可以点击刷新")
            )
        } else if presence.isAuthenticated {
            HStack(spacing: 8) {
                ProgressView().tint(.cyan)
                Text(RuntimeLocalization.string("正在同步账号设备…"))
                    .font(.caption)
                    .foregroundStyle(LiquidGlass.supportingText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else {
            emptyState(
                icon: "person.crop.circle.badge.exclamationmark",
                title: RuntimeLocalization.string("登录后才能看到本账号的设备"),
                message: RuntimeLocalization.string("在其他设备上用同一账号登录 SkyBridge，它就会出现在这里")
            )
        }
    }

    /// 附近发现且身份一致（稳定 id 相同，且发现侧已验证的协议指纹与注册表一致）的设备。
    private func nearbyDevice(for record: AccountDeviceRecord) -> DiscoveredDevice? {
        guard !record.isCaller else { return nil }
        return discoveryManager.discoveredDevices.first { device in
            AccountDeviceLANMatch.matches(
                accountDeviceId: record.deviceId,
                accountFingerprint: record.protocolPublicKeyFingerprint,
                discoveredDeviceId: device.id,
                discoveredFingerprint: discoveryManager.validatedProtocolFingerprint(for: device)
            )
        }
    }

    private func notice(_ text: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundColor(tint)
            Text(text).font(.caption).foregroundStyle(LiquidGlass.supportingText)
            Spacer()
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(.cyan.opacity(0.6))
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(LiquidGlass.supportingText)
            Text(message)
                .font(.caption)
                .foregroundStyle(LiquidGlass.supportingText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

@available(iOS 17.0, *)
private struct AccountDeviceRowView: View {
    let record: AccountDeviceRecord
    let nearbyDevice: DiscoveredDevice?
    let onConnectNearbyDevice: ((AccountDeviceRecord, DiscoveredDevice) -> Void)?
    let hasLiveRoute: Bool
    let onConnectRoutedDevice: ((AccountDeviceRecord) -> Void)?
    let onOpenCrossNetworkConnect: (() -> Void)?
    let isConnectionInProgress: Bool

    private var connectivity: AccountDevicePresentationPolicy.Connectivity {
        AccountDevicePresentationPolicy.connectivity(for: record, isLANReachable: nearbyDevice != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    AccountDevicePresentation.statusColor(for: connectivity).opacity(0.3),
                                    AccountDevicePresentation.statusColor(for: connectivity).opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                    Image(systemName: AccountDevicePresentation.systemImageName(for: record))
                        .font(.system(size: 18))
                        .foregroundColor(AccountDevicePresentation.statusColor(for: connectivity))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(AccountDevicePresentationPolicy.displayName(for: record))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        badge(AccountDevicePresentation.statusText(for: connectivity), color: AccountDevicePresentation.statusColor(for: connectivity))
                        badge(
                            AccountDevicePresentation.capabilityText(for: record),
                            color: AccountDevicePresentationPolicy.supportsRemoteControlHosting(record) ? .green : .gray
                        )
                        if let registration = AccountDevicePresentation.registrationBadgeText(for: record) {
                            badge(registration, color: .orange)
                        }
                    }
                    if let detail = AccountDevicePresentation.detailLine(for: record) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(LiquidGlass.supportingText)
                            .lineLimit(2)
                    }
                    if let address = addressText {
                        Text(address)
                            .font(.caption.monospaced())
                            .foregroundStyle(LiquidGlass.supportingText)
                            .lineLimit(2)
                    }
                    Text("\(RuntimeLocalization.string("设备 ID")) \(AccountDevicePresentationPolicy.shortDeviceId(record.deviceId)) · \(RuntimeLocalization.string("最近活跃")) \(AccountDevicePresentation.relativeTimeText(from: record.lastSeenAt))")
                        .font(.caption2)
                        .foregroundStyle(LiquidGlass.supportingText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            actionButton
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 20, padding: 0)
        .contextMenu {
            ForEach(record.lanAddresses + (record.publicAddress.map { [$0] } ?? []), id: \.self) { address in
                Button {
                    AccountDevicePresentation.copyToPasteboard(address)
                } label: {
                    Label("\(RuntimeLocalization.string("复制地址")) \(address)", systemImage: "doc.on.doc")
                }
            }
            Button {
                AccountDevicePresentation.copyToPasteboard(record.deviceId)
            } label: {
                Label(RuntimeLocalization.string("复制设备 ID"), systemImage: "number")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(AccountDevicePresentationPolicy.displayName(for: record)))
        .accessibilityValue(Text(AccountDevicePresentation.statusText(for: connectivity)))
    }

    private var addressText: String? {
        var parts: [String] = []
        if !record.lanAddresses.isEmpty {
            parts.append("\(RuntimeLocalization.string("局域网")) \(record.lanAddresses.joined(separator: ", "))")
        }
        if let publicAddress = record.publicAddress {
            parts.append("\(RuntimeLocalization.string("公网")) \(publicAddress)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actionButton: some View {
        // The identity-matched live Bonjour observation retains its observed
        // peer-to-peer interface. A server-published IP is only a route hint;
        // use it when this caller has no current nearby connection action.
        if hasLiveRoute, let onConnectRoutedDevice,
           nearbyDevice == nil || onConnectNearbyDevice == nil {
            Button(RuntimeLocalization.string("连接设备")) { onConnectRoutedDevice(record) }
                .disabled(isConnectionInProgress)
                .accessibilityIdentifier("account-device-connect-\(record.deviceId)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Capsule())
        } else {
            switch connectivity {
            case .thisDevice, .offline:
                EmptyView()
            case .lanReachable:
                if let nearbyDevice, let onConnectNearbyDevice {
                    Button(RuntimeLocalization.string("连接设备")) {
                        onConnectNearbyDevice(record, nearbyDevice)
                    }
                    .disabled(isConnectionInProgress || record.status != "active")
                    .accessibilityIdentifier("account-device-connect-\(record.deviceId)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
                }
            case .online:
                if let onOpenCrossNetworkConnect {
                Button(RuntimeLocalization.string("扫码连接")) {
                    onOpenCrossNetworkConnect()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.cyan.opacity(0.15))
                .clipShape(Capsule())
                }
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16))
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
