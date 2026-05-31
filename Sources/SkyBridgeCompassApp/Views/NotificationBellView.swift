import SwiftUI
import Combine
import SkyBridgeCore
import CoreLocation

@available(macOS 14.0, *)
public struct NotificationBellView: View {
    @EnvironmentObject var authModel: AuthenticationViewModel
 // 使用全局注入的 WeatherDataService，避免在本视图中单独创建导致数据未初始化
 // 改为使用环境对象，确保UV指数等来自真实WeatherKit数据（如可用）
    @EnvironmentObject var weatherDataService: WeatherDataService
 // 可选：位置服务（用于在需要时启动WeatherKit更新），此处仅保持引用，不主动强制启动
    @EnvironmentObject var weatherLocationService: WeatherLocationService
    @State private var showPopover = false
    @State private var unreadCount: Int = 0
    @State private var events: [NotificationItem] = []
    @State private var appStartTime = Date()
    @State private var lastRestReminder: Date? = nil
    @State private var lastHourlyAdvice: Date? = nil
    @State private var lastThreeHourReminder: Date? = nil
    @State private var hasShownWelcome = false
    private let maxEvents = 100
    private let restReminderInterval: TimeInterval = 3600 // 1小时
 /// 天气集成（含AQI）
    @StateObject private var weatherIntegration = WeatherIntegrationManager.shared
 /// 设置管理器（控制是否启用实时天气）
    @StateObject private var settingsManager = SettingsManager.shared
 /// P2P网络管理器（用于监听可连接设备出现）
    @StateObject private var p2pManager = P2PNetworkManager.shared
 /// 已提醒的可连接设备ID及时间（用于去重与限频）
    @State private var notifiedConnectableDevices: [String: Date] = [:]
 // 事件详情弹窗状态
    @State private var showEventDetailAlert: Bool = false
    @State private var selectedEventDetail: String? = nil

    public init() {}

    public var body: some View { bellContent }

    private func t(_ key: String) -> String {
        LocalizationManager.shared.localizedString(key)
    }

    private func tf(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: LocalizationManager.shared.locale, arguments: args)
    }

 /// 主体视图内容（拆分以降低类型推断复杂度）
    private var bellContent: some View {
        AnyView(
        Button(action: { showPopover.toggle() }) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell")
                    .font(.title3)
                    .foregroundColor(.primary)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(
                        Circle()
                            .stroke(.primary.opacity(0.1), lineWidth: 1)
                    )
                if unreadCount > 0 {
                    Text("\(min(unreadCount, 99))")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            LinearGradient(
                                gradient: Gradient(colors: [.red, .pink]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: Capsule()
                        )
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(t("notifications.center.title"))
                        .font(.headline)
                    Spacer()
                    Button(t("action.clear")) {
                        events.removeAll()
                        unreadCount = 0
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.bottom, 4)

                if events.isEmpty {
                    Text(t("notifications.center.empty"))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(events) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: item.iconName)
                                        .foregroundColor(item.isError ? .red : (item.isWarning ? .orange : (item.isSuccess ? .green : .blue)))
                                        .frame(width: 14)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .font(.subheadline.bold())
                                        if let detail = item.detail { Text(detail).font(.caption).foregroundColor(.secondary) }
                                        Text(item.timestampFormatted)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(8)
                                .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
 // 点击事件已移除，详细原因在详情文本中直接显示
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 280)
                }
            }
            .padding(12)
            .frame(width: 360)
            .onAppear {
                unreadCount = 0
            }
        }
        .task {
 // 在视图创建时执行一次欢迎消息和休息提醒调度
            sendWelcomeMessageIfNeeded()
            scheduleRestReminders()
            scheduleHourlyWellness()
 // 可选：启用实时天气获取（包含AQI），避免阻塞主线程
            if settingsManager.enableRealTimeWeather, !weatherIntegration.isInitialized {
                await StartupCoordinator.shared.waitUntilLaunchSettled()
 // 启动集成天气（wttr.in/Open‑Meteo + AQI），用于雨天等提醒
                await weatherIntegration.start()
 // 启动完成后立即触发一次天气建议，避免用户需要等待定时器
                if let cond = weatherIntegration.currentWeather?.condition {
                    let t = mapConditionToWeatherType(cond)
 // 仅在首次或上次建议超过30分钟时立即提醒，避免短时间内重复
                    let shouldImmediate = {
                        if let last = lastHourlyAdvice { return Date().timeIntervalSince(last) >= 1800 }
                        return true
                    }()
                    if shouldImmediate {
 // 若为雨天或暴风雨，立即触发雨伞提醒
                        switch t {
                        case .rain, .heavyRain, .thunderstorm:
                            sendWeatherAdvice()
                            lastHourlyAdvice = Date()
                        default:
                            break
                        }
                    }
                }
            }
        }
 // 监听“可连接设备”通知（由 P2PNetworkManager 发布）
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ConnectableDeviceDiscovered"))) { note in
            let now = Date()
            notifiedConnectableDevices = notifiedConnectableDevices.filter { now.timeIntervalSince($0.value) < 3600 }
            guard let deviceId = note.userInfo?["deviceId"] as? String,
                  let name = note.userInfo?["name"] as? String,
                  let address = note.userInfo?["address"] as? String,
                  let port = note.userInfo?["port"] as? UInt16,
                  let isVerified = note.userInfo?["isVerified"] as? Bool else { return }
            if notifiedConnectableDevices[deviceId] != nil { return }
            let trustText = isVerified ? t("notifications.discovery.trust.verified") : t("notifications.discovery.trust.unverified")
            var detail = tf("notifications.discovery.detail", name, address, String(Int(port)), trustText)
            if let reason = note.userInfo?["verificationFailedReason"] as? String, !reason.isEmpty {
                detail += " · " + tf("notifications.discovery.reason", reason)
            }
            if settingsManager.onlyNotifyVerifiedDevices {
                if isVerified {
                    appendEvent(title: t("notifications.discovery.title"), detail: detail, success: true, icon: "antenna.radiowaves.left.and.right")
                    notifiedConnectableDevices[deviceId] = now
                }
            } else {
                let isWarn = !isVerified
                appendEvent(
                    title: isWarn ? t("notifications.discovery.title.unverified") : t("notifications.discovery.title"),
                    detail: detail,
                    success: !isWarn,
                    icon: isWarn ? "exclamationmark.shield.fill" : "antenna.radiowaves.left.and.right",
                    warning: isWarn
                )
                notifiedConnectableDevices[deviceId] = now
            }
        }
 // 订阅关键事件
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FileTransferCompleted"))) { note in
            let fileName = (note.userInfo?["fileName"] as? String) ?? t("notifications.common.unknownFile")
            let fileSize = (note.userInfo?["fileSize"] as? Int64) ?? 0
            let direction = (note.userInfo?["direction"] as? String) ?? ""
            let localPath = (note.userInfo?["localPath"] as? String)
            var detail = "\(fileName) · \(byteCount(fileSize))"
            if let localPath, !localPath.isEmpty, direction == "incoming" {
                detail += " · " + tf("notifications.fileTransfer.savedTo", localPath)
            }
            appendEvent(title: t("notifications.fileTransfer.completed"), detail: detail, success: true, icon: "checkmark.circle.fill")
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FileTransferFailed"))) { note in
            let fileName = (note.userInfo?["fileName"] as? String) ?? t("notifications.common.unknownFile")
            let error = (note.userInfo?["error"] as? String) ?? t("notifications.common.unknownError")
            appendEvent(title: t("notifications.fileTransfer.failed"), detail: "\(fileName) · \(error)", success: false, icon: "xmark.circle.fill")
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileChunkVerified)) { note in
            appendEvent(from: note, fallbackTitle: t("notifications.chunkVerification.passed"), success: true, icon: "checkmark.seal")
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileChunkVerifyFailed)) { note in
            appendEvent(from: note, fallbackTitle: t("notifications.chunkVerification.failed"), success: false, icon: "xmark.seal")
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileMerkleVerified)) { note in
            let ok = (note.userInfo?["ok"] as? Bool) ?? false
            appendEvent(
                from: note,
                fallbackTitle: ok ? t("notifications.merkleVerification.passed") : t("notifications.merkleVerification.failed"),
                success: ok,
                icon: ok ? "checkmark.seal" : "exclamationmark.triangle"
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: NetworkFrameworkEnhancements.certificateValidationNotification)) { note in
            let ok = (note.userInfo?["ok"] as? Bool) ?? false
            let reason = (note.userInfo?["reason"] as? String) ?? ""
            let elapsed = (note.userInfo?["elapsed"] as? TimeInterval) ?? 0
            let title = ok ? t("notifications.certificate.passed") : t("notifications.certificate.failed")
            let timing = tf("notifications.certificate.elapsed", String(format: "%.0f", elapsed * 1000))
            let detail = reason.isEmpty ? timing : "\(reason) · \(timing)"
            appendEvent(title: title, detail: detail, success: ok, icon: ok ? "lock.shield" : "lock.slash")
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileMerkleTiming)) { note in
            let phase = (note.userInfo?["phase"] as? String) ?? "merkle"
            let file = (note.userInfo?["fileName"] as? String) ?? ""
            let size = (note.userInfo?["fileSize"] as? Int64) ?? 0
            let chunk = (note.userInfo?["chunkSize"] as? Int) ?? 0
            let elapsed = (note.userInfo?["elapsedMs"] as? Double) ?? 0
            let metal = (note.userInfo?["metalAvailable"] as? Bool) ?? false
            let title = phase == "verify" ? t("notifications.merkleTiming.verify") : t("notifications.merkleTiming.compute")
            let detail = "\(file) · \(byteCount(size)) · chunk=\(byteCount(Int64(chunk))) · " + String(format: "%.0fms", elapsed) + (metal ? " · Metal" : "")
            appendEvent(title: title, detail: detail, success: true, icon: "timer")
        }
        )
    }

private func appendEvent(from note: Notification, fallbackTitle: String, success: Bool, icon: String) {
        var detail: String? = nil
        if let info = note.userInfo {
            let transferId = info["transferId"] as? String
            let chunkIndex = info["chunkIndex"] as? Int
            let expected = info["expected"] as? String
            let actual = info["actual"] as? String
            let error = info["error"] as? String
            var parts: [String] = []
            if let t = transferId { parts.append(tf("notifications.common.id", t)) }
            if let c = chunkIndex { parts.append(tf("notifications.common.chunk", String(c))) }
            if let e = expected, let a = actual { parts.append(tf("notifications.common.expectedActual", String(e.prefix(8)), String(a.prefix(8)))) }
            if let err = error { parts.append(err) }
            if !parts.isEmpty { detail = parts.joined(separator: " · ") }
        }
        appendEvent(title: fallbackTitle, detail: detail, success: success, icon: icon)
    }

    private func appendEvent(title: String, detail: String?, success: Bool, icon: String, warning: Bool = false) {
        let item = NotificationItem(title: title, detail: detail, isSuccess: success, isError: !success && !warning, isWarning: warning, iconName: icon, timestamp: Date())
        events.insert(item, at: 0)
        if events.count > maxEvents { events.removeLast(events.count - maxEvents) }
        if !showPopover { unreadCount += 1 }
    }

 // MARK: - 欢迎消息

    private var welcomeMessage: String {
        let userName = authModel.currentSession?.displayName ?? NSUserName()
        let timeGreeting = getTimeGreeting()
        return tf("notifications.welcome.greeting", userName, timeGreeting)
    }

    private var welcomeIcon: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
 // 采用更清晰的 24 小时分段，避免跨午夜非法区间并提升图标语义。
        case 0..<5: return "moon.stars.fill"  // 凌晨/深夜
        case 5..<7: return "sunrise.fill"     // 清晨
        case 7..<12: return "sun.max.fill"    // 早上
        case 12..<14: return "sun.haze.fill"  // 中午
        case 14..<18: return "sun.dust.fill"  // 下午
        case 18..<21: return "sunset.fill"    // 傍晚
        case 21..<24: return "moon.stars.fill" // 夜深了
        default: return "hand.wave.fill"  // 默认
        }
    }

    private func getTimeGreeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
 // 使用 24 小时明确分段，文案更贴合语义并便于扩展。
        case 0..<5: return t("notifications.greeting.lateNight")
        case 5..<7: return t("notifications.greeting.earlyMorning")
        case 7..<12: return t("notifications.greeting.morning")
        case 12..<14: return t("notifications.greeting.noon")
        case 14..<18: return t("notifications.greeting.afternoon")
        case 18..<21: return t("notifications.greeting.evening")
        case 21..<24: return t("notifications.greeting.lateNight")
        default: return t("notifications.greeting.default")
        }
    }

 // MARK: - 启动欢迎和休息提醒

    private func sendWelcomeMessageIfNeeded() {
 // 检查是否已经发送过启动欢迎消息（本次会话内）
        if !hasShownWelcome {
            let userName = authModel.currentSession?.displayName ?? NSUserName()
            let greeting = getTimeGreeting()
            let message = tf("notifications.welcome.title", userName, greeting)
            appendEvent(title: message, detail: t("notifications.welcome.detail"), success: true, icon: welcomeIcon)
            hasShownWelcome = true
        }
    }

    private func scheduleRestReminders() {
 // 启动后台任务检查休息提醒
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 300_000_000_000) // 每5分钟检查一次

                let now = Date()
                let timeSinceStart = now.timeIntervalSince(appStartTime)

 // 检查是否超过1小时
                if timeSinceStart >= restReminderInterval {
 // 检查是否已经发送过休息提醒（避免重复发送）
                    if let lastReminder = lastRestReminder {
                        let timeSinceLastReminder = now.timeIntervalSince(lastReminder)
                        if timeSinceLastReminder < restReminderInterval {
                            continue // 距离上次提醒不足1小时，跳过
                        }
                    }

 // 发送休息提醒
                    sendRestReminder()
                    lastRestReminder = now
                }

 // 连续使用满3小时的强提示（每3小时仅提示一次）
                if timeSinceStart >= (3 * 3600) {
                    if let last3h = lastThreeHourReminder {
                        if now.timeIntervalSince(last3h) >= (3 * 3600) {
                            sendThreeHourReminder()
                            lastThreeHourReminder = now
                        }
                    } else {
                        sendThreeHourReminder()
                        lastThreeHourReminder = now
                    }
                }
            }
        }
    }

 /// 每小时健康与天气提示（丰富程度增强：夜深了提示、天气防护建议）
    private func scheduleHourlyWellness() {
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 300_000_000_000) // 每5分钟检查一次，满足1小时条件后发送
                let now = Date()
                let shouldSend: Bool = {
                    if let last = lastHourlyAdvice { return now.timeIntervalSince(last) >= 3600 }
                    return true
                }()
                if !shouldSend { continue }

 // 夜深了（22:00~05:00）主动提示休息
                let hour = Calendar.current.component(.hour, from: now)
                if hour >= 22 || hour < 5 {
                    appendEvent(title: t("notifications.wellness.lateNight.title"), detail: t("notifications.wellness.lateNight.detail"), success: true, icon: "moon.stars.fill")
                }

 // 天气防护建议（依据实时天气或退化为通用提示）
                sendWeatherAdvice()

                lastHourlyAdvice = now
            }
        }
    }

    private func sendRestReminder() {
        let reminders = [
            (t("notifications.rest.1h.title"), t("notifications.rest.1h.detail"), "cup.and.saucer.fill"),
            (t("notifications.rest.duration.title"), t("notifications.rest.duration.detail"), "figure.walk"),
            (t("notifications.rest.tip.title"), t("notifications.rest.tip.detail"), "eye.fill"),
            (t("notifications.rest.breathe.title"), t("notifications.rest.breathe.detail"), "lungs.fill"),
            (t("notifications.rest.break.title"), t("notifications.rest.break.detail"), "hand.raised.fill")
        ]

        let randomReminder = reminders.randomElement() ?? reminders[0]
        appendEvent(title: randomReminder.0, detail: randomReminder.1, success: true, icon: randomReminder.2)
    }

 /// 连续三小时强提醒
    private func sendThreeHourReminder() {
        appendEvent(title: t("notifications.rest.3h.title"), detail: t("notifications.rest.3h.detail"), success: true, icon: "figure.walk")
    }

 /// 天气防护建议（晴天防晒、雨天防雨、雪天防雪、雾霾/雾建议佩戴口罩）
    private func sendWeatherAdvice() {
 // 优先使用集成天气的数据源（wttr.in / Open‑Meteo），避免WeatherKit未初始化导致类型为unknown
 // 若集成天气不可用，则退回到WeatherKit的类型判断（保持真实API）
        let integratedType: WeatherDataService.WeatherType? = weatherIntegration.currentWeather.map { mapConditionToWeatherType($0.condition) }
        let weatherType = integratedType ?? weatherDataService.getCurrentWeatherType()
 // UV指数优先来自WeatherKit，若不可用则为0（不影响雨伞提醒）
        let params = weatherDataService.getWeatherRenderingParameters()
        let uv = params.uvIndex
 // AQI来自集成服务（真实API或推断），用于空气质量提醒
        let aqi = weatherIntegration.currentWeather?.aqi
 // 高AQI优先提示（不局限于雾霾天气）。AQI阈值参考：100中等、150对敏感人群不健康、200不健康、300非常不健康
        if let aqi {
            let thresholds = aqiThresholdsForCurrentLocation()
            if aqi >= thresholds.veryUnhealthy {
                appendEvent(title: tf("notifications.weather.aqi.veryUnhealthy.title", String(aqi)), detail: t("notifications.weather.aqi.veryUnhealthy.detail"), success: true, icon: "aqi.high")
            } else if aqi >= thresholds.unhealthy {
                appendEvent(title: tf("notifications.weather.aqi.unhealthy.title", String(aqi)), detail: t("notifications.weather.aqi.unhealthy.detail"), success: true, icon: "aqi.high")
            } else if aqi >= thresholds.sensitive {
                appendEvent(title: tf("notifications.weather.aqi.sensitive.title", String(aqi)), detail: t("notifications.weather.aqi.sensitive.detail"), success: true, icon: "aqi.medium")
            } else if aqi >= thresholds.caution {
                appendEvent(title: tf("notifications.weather.aqi.caution.title", String(aqi)), detail: t("notifications.weather.aqi.caution.detail"), success: true, icon: "aqi.low")
            }
        }
        switch weatherType {
        case .clear, .partlyCloudy:
            if uv >= settingsManager.uvThresholdStrong {
                appendEvent(title: t("notifications.weather.uv.strong.title"), detail: t("notifications.weather.uv.strong.detail"), success: true, icon: "sun.max.fill")
            } else if uv >= settingsManager.uvThresholdModerate {
                appendEvent(title: t("notifications.weather.uv.moderate.title"), detail: t("notifications.weather.uv.moderate.detail"), success: true, icon: "sun.max.fill")
            } else {
                appendEvent(title: t("notifications.weather.clear.title"), detail: t("notifications.weather.clear.detail"), success: true, icon: "sun.max.fill")
            }
        case .rain, .heavyRain:
            appendEvent(title: t("notifications.weather.rain.title"), detail: t("notifications.weather.rain.detail"), success: true, icon: "cloud.rain.fill")
        case .snow, .heavySnow:
            appendEvent(title: t("notifications.weather.snow.title"), detail: t("notifications.weather.snow.detail"), success: true, icon: "snowflake")
        case .haze, .fog:
            appendEvent(title: t("notifications.weather.haze.title"), detail: t("notifications.weather.haze.detail"), success: true, icon: "aqi.medium")
        case .thunderstorm:
 // 雷暴天气同样提醒携带雨具并减少外出
            appendEvent(title: t("notifications.weather.thunderstorm.title"), detail: t("notifications.weather.thunderstorm.detail"), success: true, icon: "cloud.bolt.rain.fill")
        default:
 // 通用提示：根据时间段提供轻量建议
            let tod = getTimeGreeting()
            appendEvent(title: t("notifications.weather.generic.title"), detail: tf("notifications.weather.generic.detail", tod), success: true, icon: "info.circle")
        }
    }

 // MARK: - 天气类型映射（集成服务 -> WeatherKit风格枚举）
 /// 将集成服务的 WeatherCondition 映射到本视图使用的 WeatherDataService.WeatherType，便于统一处理
    private func mapConditionToWeatherType(_ condition: WeatherCondition) -> WeatherDataService.WeatherType {
        switch condition {
        case .clear:
            return .clear
        case .cloudy:
 // 集成服务的“多云/阴”统一映射为cloudy
            return .cloudy
        case .rainy:
 // 无法直接判断强度时默认按rain处理
            return .rain
        case .snowy:
            return .snow
        case .foggy:
            return .fog
        case .haze:
            return .haze
        case .stormy:
            return .thunderstorm
        case .unknown:
            return .unknown
        }
    }

 /// 依据位置（城市/郊区）调整AQI阈值策略
    private func aqiThresholdsForCurrentLocation() -> (caution: Int, sensitive: Int, unhealthy: Int, veryUnhealthy: Int) {
        let loc = weatherIntegration.locationManager.currentLocation
        let isUrban = UrbanDensityClassifier.shared.isUrban(
            latitude: loc?.latitude,
            longitude: loc?.longitude,
            city: loc?.city
        )
 // 读取可配置阈值并根据敏感人群模式调整
        let strict = settingsManager.strictModeForSensitiveGroups
        if isUrban {
            var c = settingsManager.aqiThresholdCautionUrban
            var s = settingsManager.aqiThresholdSensitiveUrban
            var u = settingsManager.aqiThresholdUnhealthyUrban
            let v = settingsManager.aqiThresholdVeryUnhealthyUrban
            if strict { c = max(0, c - 20); s = max(0, s - 20); u = max(0, u - 20) }
            return (caution: c, sensitive: s, unhealthy: u, veryUnhealthy: v)
        } else {
            var c = settingsManager.aqiThresholdCautionSuburban
            var s = settingsManager.aqiThresholdSensitiveSuburban
            var u = settingsManager.aqiThresholdUnhealthySuburban
            let v = settingsManager.aqiThresholdVeryUnhealthySuburban
            if strict { c = max(0, c - 10); s = max(0, s - 10); u = max(0, u - 10) }
            return (caution: c, sensitive: s, unhealthy: u, veryUnhealthy: v)
        }
    }
}

@available(macOS 14.0, *)
private struct NotificationItem: Identifiable {
    let id = UUID().uuidString
    let title: String
    let detail: String?
    let isSuccess: Bool
    let isError: Bool
    let isWarning: Bool
    let iconName: String
    let timestamp: Date
    var timestampFormatted: String {
 // DateFormatter 创建开销较大，使用静态缓存避免重复构造，提高视图渲染与销毁时的性能。
        return NotificationItem.timeFormatter.string(from: timestamp)
    }
 // 静态时间格式器缓存，避免每次渲染创建对象造成主线程卡顿。
    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()
}

@available(macOS 14.0, *)
private func byteCount(_ bytes: Int64) -> String {
    let units = ["B","KB","MB","GB","TB"]
    var value = Double(bytes)
    var idx = 0
    while value >= 1024.0 && idx < units.count - 1 {
        value /= 1024.0
        idx += 1
    }
    return String(format: idx == 0 ? "%.0f%@" : "%.1f%@", value, units[idx])
}
