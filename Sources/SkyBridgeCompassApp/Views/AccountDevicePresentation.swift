import AppKit
import SwiftUI
import SkyBridgeCore
import SkyBridgeProtocolCore

/// 账号设备在 macOS 界面上的展示辅助（图标、状态文案、时间文案、失败文案）。
/// 判定规则本身在共享的 `AccountDevicePresentationPolicy` 里，这里只做本地化与视觉映射。
@available(macOS 14.0, *)
@MainActor
enum AccountDevicePresentation {
    static func systemImageName(for record: AccountDeviceRecord) -> String {
        switch record.platform {
        case .macOS: return "laptopcomputer"
        case .iPadOS: return "ipad"
        case .iOS: return "iphone"
        case .windows: return "pc"
        case .android: return "candybarphone"
        case .linux: return "server.rack"
        case nil: return "questionmark.square.dashed"
        }
    }

    static func statusText(for connectivity: AccountDevicePresentationPolicy.Connectivity) -> String {
        let localization = LocalizationManager.shared
        switch connectivity {
        case .thisDevice: return localization.localizedString("discovery.device.thisDevice")
        case .lanReachable: return localization.localizedString("discovery.accountDevices.status.lanReachable")
        case .online: return localization.localizedString("discovery.accountDevices.status.online")
        case .offline: return localization.localizedString("discovery.accountDevices.status.offline")
        }
    }

    static func statusColor(for connectivity: AccountDevicePresentationPolicy.Connectivity) -> Color {
        switch connectivity {
        case .thisDevice: return .blue
        case .lanReachable: return .green
        case .online: return .cyan
        case .offline: return .secondary
        }
    }

    static func registrationBadgeText(for record: AccountDeviceRecord) -> String? {
        switch record.status {
        case "pending": return LocalizationManager.shared.localizedString("discovery.accountDevices.registration.pending")
        case "frozen": return LocalizationManager.shared.localizedString("discovery.accountDevices.registration.frozen")
        default: return nil
        }
    }

    static func capabilityText(for record: AccountDeviceRecord) -> String {
        AccountDevicePresentationPolicy.supportsRemoteControlHosting(record)
            ? LocalizationManager.shared.localizedString("discovery.accountDevices.capability.controllable")
            : LocalizationManager.shared.localizedString("discovery.accountDevices.capability.controlOnly")
    }

    /// 机型 · 系统 · 版本（缺失项自动省略）。
    static func detailLine(for record: AccountDeviceRecord) -> String? {
        var parts: [String] = []
        if let model = record.deviceModel, !model.isEmpty { parts.append(model) }
        if let platform = record.platform {
            let osVersion = record.osVersion.map { " \($0)" } ?? ""
            parts.append("\(platformDisplayName(platform))\(osVersion)")
        } else if let osVersion = record.osVersion, !osVersion.isEmpty {
            parts.append(osVersion)
        }
        if let appVersion = record.appVersion, !appVersion.isEmpty { parts.append("v\(appVersion)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func platformDisplayName(_ platform: AccountDevicePlatform) -> String {
        AccountDevicePresentationPolicy.platformDisplayName(platform)
    }

    /// 与设备发现页其它区域一致的相对时间文案（复用 discovery.time.* 键）。
    /// 分档规则在共享的 `AccountDevicePresentationPolicy` 里，这里只做本地化。
    static func relativeTimeText(from date: Date?, now: Date = Date()) -> String {
        let localization = LocalizationManager.shared
        switch AccountDevicePresentationPolicy.relativeTimeBucket(from: date, now: now) {
        case .never:
            return localization.localizedString("discovery.accountDevices.neverSeen")
        case .justNow:
            return localization.localizedString("discovery.time.justNow")
        case .minutes(let minutes):
            return String(format: localization.localizedString("discovery.time.minutesAgo"), minutes)
        case .hours(let hours):
            return String(format: localization.localizedString("discovery.time.hoursAgo"), hours)
        case .days(let days):
            return String(format: localization.localizedString("discovery.time.daysAgo"), days)
        }
    }

    static func failureText(_ failure: AccountPresenceFailure) -> String {
        let localization = LocalizationManager.shared
        switch failure {
        case .notAuthenticated:
            return localization.localizedString("discovery.accountDevices.failure.notAuthenticated")
        case .deviceNotActive(let code):
            return String(format: localization.localizedString("discovery.accountDevices.failure.deviceNotActive"), code)
        case .rateLimited:
            return localization.localizedString("discovery.accountDevices.failure.rateLimited")
        case .registryUnavailable(let code):
            return String(format: localization.localizedString("discovery.accountDevices.failure.registryUnavailable"), code)
        case .serverRejected(let status, _):
            return String(format: localization.localizedString("discovery.accountDevices.failure.serverRejected"), status)
        case .transport:
            return localization.localizedString("discovery.accountDevices.failure.transport")
        case .malformedResponse:
            return localization.localizedString("discovery.accountDevices.failure.malformedResponse")
        case .localIdentityUnavailable:
            return localization.localizedString("discovery.accountDevices.failure.localIdentityUnavailable")
        case .localAuthenticationUnavailable(let code):
            return String(
                format: localization.localizedString("discovery.accountDevices.failure.localAuthenticationUnavailable"),
                code
            )
        }
    }

    static func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
