import SwiftUI
import SkyBridgeProtocolCore
#if canImport(UIKit)
import UIKit
#endif

/// 账号设备在 iOS 界面上的展示辅助（图标、状态文案、时间文案、失败文案）。
/// 判定规则本身在共享的 `AccountDevicePresentationPolicy` 里，这里只做本地化与视觉映射。
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
        switch connectivity {
        case .thisDevice: return RuntimeLocalization.string("本机")
        case .lanReachable: return RuntimeLocalization.string("局域网可达")
        case .online: return RuntimeLocalization.string("在线")
        case .offline: return RuntimeLocalization.string("离线")
        }
    }

    static func statusColor(for connectivity: AccountDevicePresentationPolicy.Connectivity) -> Color {
        switch connectivity {
        case .thisDevice: return .blue
        case .lanReachable: return .green
        case .online: return .cyan
        case .offline: return .gray
        }
    }

    static func registrationBadgeText(for record: AccountDeviceRecord) -> String? {
        switch record.status {
        case "pending": return RuntimeLocalization.string("待批准")
        case "frozen": return RuntimeLocalization.string("已冻结")
        default: return nil
        }
    }

    static func capabilityText(for record: AccountDeviceRecord) -> String {
        AccountDevicePresentationPolicy.supportsRemoteControlHosting(record)
            ? RuntimeLocalization.string("可被控")
            : RuntimeLocalization.string("仅控制端")
    }

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

    static func relativeTimeText(from date: Date?, now: Date = Date()) -> String {
        // 分档规则在共享的 `AccountDevicePresentationPolicy` 里，这里只做本地化。
        switch AccountDevicePresentationPolicy.relativeTimeBucket(from: date, now: now) {
        case .never: return RuntimeLocalization.string("尚未上线")
        case .justNow: return RuntimeLocalization.string("刚刚")
        case .minutes(let minutes): return RuntimeLocalization.format("%d 分钟前", [minutes])
        case .hours(let hours): return RuntimeLocalization.format("%d 小时前", [hours])
        case .days(let days): return RuntimeLocalization.format("%d 天前", [days])
        }
    }

    static func failureText(_ failure: AccountPresenceFailure) -> String {
        switch failure {
        case .notAuthenticated:
            return RuntimeLocalization.string("未登录")
        case .deviceNotActive(let code):
            return RuntimeLocalization.format("本机尚未在账号中激活（%@）", [code])
        case .rateLimited:
            return RuntimeLocalization.string("请求过于频繁，稍后自动重试")
        case .registryUnavailable(let code):
            return RuntimeLocalization.format("设备注册表暂不可用（%@）", [code])
        case .serverRejected(let status, _):
            return RuntimeLocalization.format("服务器拒绝了请求（HTTP %d）", [status])
        case .transport:
            return RuntimeLocalization.string("无法连接信令服务器")
        case .malformedResponse:
            return RuntimeLocalization.string("服务器响应无法解析")
        case .localIdentityUnavailable:
            return RuntimeLocalization.string("本机身份尚未就绪")
        case .localAuthenticationUnavailable(let code):
            return RuntimeLocalization.format("本机登录状态异常（%@）", [code])
        }
    }

    static func copyToPasteboard(_ value: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #endif
    }
}
