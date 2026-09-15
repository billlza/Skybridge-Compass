import SwiftUI
import SkyBridgeCore
import SkyBridgeProtocolCore

/// 主控台「账号设备」液态玻璃面板：位于实时天气卡片之下、发现设备网格之上，
/// 简要展示同一账号下的设备（名称 / 状态 / 地址）与在线统计；「查看全部」跳转到设备发现页的账号设备标签。
@available(macOS 14.0, *)
struct AccountDevicesPanelView: View {
    @EnvironmentObject private var themeConfiguration: ThemeConfiguration
    @EnvironmentObject private var authModel: AuthenticationViewModel
    @ObservedObject private var presence = PresenceService.shared
    @ObservedObject private var unifiedDeviceManager = UnifiedOnlineDeviceManager.shared
    @State private var isHovering = false

    static let previewRowLimit = 4

    let onViewAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .dashboardLiquidGlassChrome(accent: .cyan, isHovering: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(LocalizationManager.shared.localizedString("dashboard.accountDevices")))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label(
                LocalizationManager.shared.localizedString("dashboard.accountDevices"),
                systemImage: "person.crop.rectangle.stack.fill"
            )
            .font(.headline)
            .foregroundStyle(themeConfiguration.primaryTextColor)

            if let snapshot = presence.accountDevices {
                let summary = AccountDevicePresentationPolicy.summary(for: snapshot.devices)
                Text(
                    String(
                        format: LocalizationManager.shared.localizedString("dashboard.accountDevices.summary"),
                        summary.total,
                        summary.online
                    )
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Text(LocalizationManager.shared.localizedString("discovery.accountDevices.nebulaId"))
                    .foregroundColor(.secondary)
                Text(authModel.displayedNebulaId)
                    .monospaced()
                    .foregroundStyle(themeConfiguration.primaryTextColor)
            }
            .font(.caption)

            Button(LocalizationManager.shared.localizedString("dashboard.accountDevices.viewAll")) {
                onViewAll()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = presence.accountDevices {
            if let issue = AccountDevicePresentation.registrationIssueText(for: snapshot) {
                Label(issue, systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let devices = Array(
                AccountDevicePresentationPolicy.orderedDevices(snapshot.devices).prefix(Self.previewRowLimit)
            )
            if devices.isEmpty {
                Text(LocalizationManager.shared.localizedString("dashboard.accountDevices.empty"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(devices) { record in
                        AccountDeviceCompactRow(
                            record: record,
                            connectivity: AccountDevicePresentationPolicy.connectivity(
                                for: record,
                                isLANReachable: isLANReachable(record)
                            )
                        )
                    }
                }
                if let failure = presence.lastListFailure {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text(AccountDevicePresentation.failureText(failure))
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
                if let heartbeatFailure = presence.lastHeartbeatFailure {
                    HStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash").foregroundColor(.orange)
                        Text(LocalizationManager.shared.localizedString("discovery.accountDevices.heartbeatFailed"))
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .help(AccountDevicePresentation.failureText(heartbeatFailure))
                }
            }
        } else if let failure = presence.lastListFailure {
            let isSignedOut = failure == .notAuthenticated && !isSignedIn
            HStack(spacing: 6) {
                Image(systemName: isSignedOut ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle.fill")
                    .foregroundColor(isSignedOut ? .secondary : .orange)
                Text(
                    isSignedOut
                        ? LocalizationManager.shared.localizedString("discovery.accountDevices.signedOut")
                        : AccountDevicePresentation.failureText(failure)
                )
            }
            .font(.caption)
            .foregroundColor(.secondary)
        } else if !presence.isActive {
            HStack(spacing: 6) {
                Image(systemName: isSignedIn ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.exclamationmark")
                    .foregroundColor(isSignedIn ? .orange : .secondary)
                Text(
                    isSignedIn
                        ? LocalizationManager.shared.localizedString("discovery.accountDevices.serviceInactive.title")
                        : LocalizationManager.shared.localizedString("discovery.accountDevices.signedOut")
                )
            }
            .font(.caption)
            .foregroundColor(.secondary)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(LocalizationManager.shared.localizedString("discovery.accountDevices.loading"))
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    /// 是否已登录（访客模式不算）：区分「未登录」与「已登录但同步服务未运行」。
    private var isSignedIn: Bool {
        authModel.currentSession != nil && !authModel.isGuestMode
    }

    private func isLANReachable(_ record: AccountDeviceRecord) -> Bool {
        guard !record.isCaller, let device = unifiedDeviceManager.resolvedOnlineDevice(for: record) else {
            return false
        }
        return unifiedDeviceManager.hasResolvedConnectableControlRoute(for: device)
    }
}

@available(macOS 14.0, *)
private struct AccountDeviceCompactRow: View {
    @EnvironmentObject private var themeConfiguration: ThemeConfiguration

    let record: AccountDeviceRecord
    let connectivity: AccountDevicePresentationPolicy.Connectivity

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: AccountDevicePresentation.systemImageName(for: record))
                .font(.system(size: 16))
                .foregroundColor(AccountDevicePresentation.statusColor(for: connectivity))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(AccountDevicePresentationPolicy.displayName(for: record))
                    .font(.subheadline)
                    .foregroundStyle(themeConfiguration.primaryTextColor)
                Text(AccountDevicePresentation.modelText(for: record))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .lineLimit(1)

            Circle()
                .fill(AccountDevicePresentation.statusColor(for: connectivity))
                .frame(width: 7, height: 7)
            Text(AccountDevicePresentation.statusText(for: connectivity))
                .font(.caption2)
                .foregroundColor(.secondary)

            Spacer()

            if let address = AccountDevicePresentationPolicy.primaryAddress(for: record) {
                Text(address)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Text(AccountDevicePresentation.relativeTimeText(from: record.lastSeenAt))
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
