import SwiftUI
import SkyBridgeProtocolCore

/// 设备页顶部的「账号设备」区块（位于附近扫描之前）：同一账号下的全部设备（名称 / IP / 系统 / 在线状态）。
///
/// 连接语义：局域网内发现且身份一致 → 打开该附近设备的详情页（走现有配对/连接流程）；仅跨网在线 → 提示使用连接码/二维码。
/// iOS 是控制端，不会被别人控制：本机行标注「仅控制端」。
@available(iOS 17.0, *)
struct AccountDevicesSectionView: View {
    @ObservedObject private var presence = AccountPresenceService.shared
    @EnvironmentObject private var discoveryManager: DeviceDiscoveryManager
    @EnvironmentObject private var authManager: AuthenticationManager

    let onOpenNearbyDevice: (DiscoveredDevice) -> Void
    let onOpenCrossNetworkConnect: () -> Void

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
            content
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
                    .foregroundStyle(.secondary)
                if let nebulaId = authManager.currentUser?.nebulaId, !nebulaId.isEmpty {
                    Text("Nebula ID · \(nebulaId)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let updatedAt = presence.lastSuccessfulListAt {
                Text(RuntimeLocalization.format("更新于 %@", [AccountDevicePresentation.relativeTimeText(from: updatedAt)]))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                        AccountDeviceRowView(
                            record: record,
                            nearbyDevice: nearbyDevice(for: record),
                            onOpenNearbyDevice: onOpenNearbyDevice,
                            onOpenCrossNetworkConnect: onOpenCrossNetworkConnect
                        )
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
                    .foregroundStyle(.secondary)
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
            Text(text).font(.caption).foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
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
    let onOpenNearbyDevice: (DiscoveredDevice) -> Void
    let onOpenCrossNetworkConnect: () -> Void

    private var connectivity: AccountDevicePresentationPolicy.Connectivity {
        AccountDevicePresentationPolicy.connectivity(for: record, isLANReachable: nearbyDevice != nil)
    }

    var body: some View {
        HStack(spacing: 14) {
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
                HStack(spacing: 6) {
                    Text(AccountDevicePresentationPolicy.displayName(for: record))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
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
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let address = addressText {
                    Text(address)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("\(RuntimeLocalization.string("设备 ID")) \(AccountDevicePresentationPolicy.shortDeviceId(record.deviceId)) · \(RuntimeLocalization.string("最近活跃")) \(AccountDevicePresentation.relativeTimeText(from: record.lastSeenAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            actionButton
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
        switch connectivity {
        case .thisDevice, .offline:
            EmptyView()
        case .lanReachable:
            if let nearbyDevice {
                Button(RuntimeLocalization.string("连接设备")) {
                    onOpenNearbyDevice(nearbyDevice)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing))
                .clipShape(Capsule())
            }
        case .online:
            Button(RuntimeLocalization.string("用连接码连接")) {
                onOpenCrossNetworkConnect()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.cyan.opacity(0.15))
            .clipShape(Capsule())
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.8))
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
