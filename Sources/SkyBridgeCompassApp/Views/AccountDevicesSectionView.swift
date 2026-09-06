import SwiftUI
import SkyBridgeCore
import SkyBridgeProtocolCore

/// 设备发现页「账号设备」标签：登录同一账号的全部设备（名称 / IP / 系统 / 在线状态），
/// 数据来自 `PresenceService`（信令服务器 `/api/devices/list`）。
///
/// 连接语义：局域网内发现且协议指纹一致 → 走现有在线设备连接路径；仅跨网在线 → 引导到智能连接码（本阶段没有账号内一键跨网直连）。
@available(macOS 14.0, *)
struct AccountDevicesSectionView: View {
    @EnvironmentObject private var themeConfiguration: ThemeConfiguration
    @EnvironmentObject private var authModel: AuthenticationViewModel
    @ObservedObject private var presence = PresenceService.shared
    @ObservedObject private var unifiedDeviceManager = UnifiedOnlineDeviceManager.shared

    let onConnect: (OnlineDevice) -> Void
    let onOpenConnectionCode: () -> Void
    /// 正在建立连接的在线设备 id（与本地扫描页共用同一份在途状态）。
    let connectingDeviceIDs: Set<UUID>
    /// 最近一次连接失败的用户可读原因；本页触发的失败必须在本页可见，不能只在本地扫描页显示。
    let connectionErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            InfoBanner(
                icon: "person.crop.rectangle.stack.fill",
                title: LocalizationManager.shared.localizedString("discovery.accountDevices.title"),
                description: LocalizationManager.shared.localizedString("discovery.accountDevices.description"),
                color: .cyan
            )

            toolbar

            if let failure = presence.lastListFailure, presence.accountDevices != nil {
                noticeRow(
                    icon: "exclamationmark.triangle.fill",
                    color: .orange,
                    text: String(
                        format: LocalizationManager.shared.localizedString("discovery.accountDevices.stale"),
                        AccountDevicePresentation.relativeTimeText(from: presence.lastSuccessfulListAt)
                    ) + " · " + AccountDevicePresentation.failureText(failure)
                )
            }

            if presence.accountDevices?.truncated == true {
                noticeRow(
                    icon: "info.circle.fill",
                    color: .blue,
                    text: LocalizationManager.shared.localizedString("discovery.accountDevices.truncated")
                )
            }

            if let heartbeatFailure = presence.lastHeartbeatFailure {
                noticeRow(
                    icon: "antenna.radiowaves.left.and.right.slash",
                    color: .orange,
                    text: LocalizationManager.shared.localizedString("discovery.accountDevices.heartbeatFailed")
                        + " · " + AccountDevicePresentation.failureText(heartbeatFailure)
                )
            }

            if let connectionErrorMessage, !connectionErrorMessage.isEmpty {
                noticeRow(icon: "exclamationmark.octagon.fill", color: .red, text: connectionErrorMessage)
            }

            content
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            nebulaChip
            Spacer()
            if let updatedAt = presence.lastSuccessfulListAt {
                Text(
                    String(
                        format: LocalizationManager.shared.localizedString("discovery.accountDevices.lastUpdated"),
                        AccountDevicePresentation.relativeTimeText(from: updatedAt)
                    )
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Button {
                presence.triggerRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .help(LocalizationManager.shared.localizedString("discovery.refresh"))
            .accessibilityLabel(Text(LocalizationManager.shared.localizedString("discovery.refresh")))
        }
        .padding(12)
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }

    private var nebulaChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle")
                .foregroundColor(.cyan)
            Text(LocalizationManager.shared.localizedString("discovery.accountDevices.nebulaId"))
                .font(.caption)
                .foregroundColor(.secondary)
            Text(authModel.displayedNebulaId)
                .font(.caption.monospaced())
                .foregroundColor(themeConfiguration.primaryTextColor)
                .textSelection(.enabled)
        }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        if let snapshot = presence.accountDevices {
            let devices = AccountDevicePresentationPolicy.orderedDevices(snapshot.devices)
            if devices.isEmpty {
                emptyState(
                    icon: "person.crop.rectangle.stack",
                    title: LocalizationManager.shared.localizedString("discovery.accountDevices.empty.title"),
                    message: LocalizationManager.shared.localizedString("discovery.accountDevices.empty.message")
                )
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(devices) { record in
                        let lanDevice = lanReachableDevice(for: record)
                        AccountDeviceRow(
                            record: record,
                            lanDevice: lanDevice,
                            isConnecting: lanDevice.map { connectingDeviceIDs.contains($0.id) } ?? false,
                            onConnect: onConnect,
                            onOpenConnectionCode: onOpenConnectionCode
                        )
                    }
                }
            }
        } else if let failure = presence.lastListFailure {
            if failure == .notAuthenticated, !isSignedIn {
                emptyState(
                    icon: "person.crop.circle.badge.exclamationmark",
                    title: LocalizationManager.shared.localizedString("discovery.accountDevices.signedOut"),
                    message: LocalizationManager.shared.localizedString("discovery.accountDevices.empty.message")
                )
            } else {
                emptyState(
                    icon: "exclamationmark.triangle",
                    title: AccountDevicePresentation.failureText(failure),
                    message: LocalizationManager.shared.localizedString("discovery.accountDevices.retryHint")
                )
            }
        } else if !presence.isActive {
            // 未登录与「已登录但同步服务没跑起来」是两种状态：后者曾被误显示成登录引导，
            // 用户按提示反复登录也无济于事。
            if isSignedIn {
                emptyState(
                    icon: "exclamationmark.triangle",
                    title: LocalizationManager.shared.localizedString("discovery.accountDevices.serviceInactive.title"),
                    message: LocalizationManager.shared.localizedString("discovery.accountDevices.serviceInactive.message")
                )
            } else {
                emptyState(
                    icon: "person.crop.circle.badge.exclamationmark",
                    title: LocalizationManager.shared.localizedString("discovery.accountDevices.signedOut"),
                    message: LocalizationManager.shared.localizedString("discovery.accountDevices.empty.message")
                )
            }
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(LocalizationManager.shared.localizedString("discovery.accountDevices.loading"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
        }
    }

    /// 是否已登录（访客模式不算）。用于区分「未登录」与「已登录但服务未运行」。
    private var isSignedIn: Bool {
        authModel.currentSession != nil && !authModel.isGuestMode
    }

    /// 局域网内发现、协议指纹一致且有可连接控制路由的在线行（否则 nil）。
    private func lanReachableDevice(for record: AccountDeviceRecord) -> OnlineDevice? {
        guard !record.isCaller,
              let device = unifiedDeviceManager.resolvedOnlineDevice(for: record),
              unifiedDeviceManager.hasResolvedConnectableControlRoute(for: device) else {
            return nil
        }
        return device
    }

    private func noticeRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(color)
            Text(text).font(.caption).foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

/// 单台账号设备行。
@available(macOS 14.0, *)
private struct AccountDeviceRow: View {
    @EnvironmentObject private var themeConfiguration: ThemeConfiguration
    @ObservedObject private var settingsManager = SettingsManager.shared

    let record: AccountDeviceRecord
    let lanDevice: OnlineDevice?
    let isConnecting: Bool
    let onConnect: (OnlineDevice) -> Void
    let onOpenConnectionCode: () -> Void

    private var connectivity: AccountDevicePresentationPolicy.Connectivity {
        AccountDevicePresentationPolicy.connectivity(for: record, isLANReachable: lanDevice != nil)
    }

    var body: some View {
        HStack(spacing: settingsManager.compactMode ? 10 : 16) {
            Image(systemName: AccountDevicePresentation.systemImageName(for: record))
                .font(.system(size: settingsManager.compactMode ? 24 : 32))
                .foregroundColor(AccountDevicePresentation.statusColor(for: connectivity))
                .frame(width: settingsManager.compactMode ? 40 : 50, height: settingsManager.compactMode ? 40 : 50)
                .background(AccountDevicePresentation.statusColor(for: connectivity).opacity(0.1))
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: settingsManager.compactMode ? 4 : 6) {
                HStack(spacing: 8) {
                    Text(AccountDevicePresentationPolicy.displayName(for: record))
                        .font(settingsManager.compactMode ? .subheadline : .headline)
                        .lineLimit(1)
                    badge(
                        AccountDevicePresentation.statusText(for: connectivity),
                        color: AccountDevicePresentation.statusColor(for: connectivity)
                    )
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
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                addressLine

                HStack(spacing: 12) {
                    Text("\(LocalizationManager.shared.localizedString("discovery.accountDevices.deviceId")): \(AccountDevicePresentationPolicy.shortDeviceId(record.deviceId))")
                    Text("\(LocalizationManager.shared.localizedString("discovery.accountDevices.lastSeen")): \(AccountDevicePresentation.relativeTimeText(from: record.lastSeenAt))")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }

            Spacer()

            actionButton
        }
        .padding(16)
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
        .contextMenu {
            ForEach(record.lanAddresses + (record.publicAddress.map { [$0] } ?? []), id: \.self) { address in
                Button("\(LocalizationManager.shared.localizedString("discovery.accountDevices.copyAddress")) \(address)") {
                    AccountDevicePresentation.copyToPasteboard(address)
                }
            }
            Button("\(LocalizationManager.shared.localizedString("discovery.accountDevices.copyDeviceId")) \(record.deviceId)") {
                AccountDevicePresentation.copyToPasteboard(record.deviceId)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(AccountDevicePresentationPolicy.displayName(for: record)))
        .accessibilityValue(Text(AccountDevicePresentation.statusText(for: connectivity)))
    }

    @ViewBuilder
    private var addressLine: some View {
        let lan = record.lanAddresses.joined(separator: ", ")
        if !lan.isEmpty || record.publicAddress != nil {
            HStack(spacing: 10) {
                if !lan.isEmpty {
                    Text("\(LocalizationManager.shared.localizedString("discovery.accountDevices.lan")): \(lan)")
                }
                if let publicAddress = record.publicAddress {
                    Text("\(LocalizationManager.shared.localizedString("discovery.accountDevices.public")): \(publicAddress)")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch connectivity {
        case .thisDevice, .offline:
            EmptyView()
        case .lanReachable:
            if let lanDevice {
                if isConnecting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(LocalizationManager.shared.localizedString("dashboard.status.connecting"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Button(LocalizationManager.shared.localizedString("discovery.action.connect")) {
                        onConnect(lanDevice)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        case .online:
            Button(LocalizationManager.shared.localizedString("discovery.accountDevices.action.useConnectionCode")) {
                onOpenConnectionCode()
            }
            .buttonStyle(.bordered)
            .help(LocalizationManager.shared.localizedString("discovery.accountDevices.hint.online"))
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.8))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
