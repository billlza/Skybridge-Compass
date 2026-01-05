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
                    Text("通知中心")
                        .font(.headline)
                    Spacer()
                    Button("清空") {
                        events.removeAll()
                        unreadCount = 0
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.bottom, 4)
                
                if events.isEmpty {
                    Text("暂无通知")
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
                Task {
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
            let trustText = isVerified ? "已验签" : "未验证"
            var detail = "\(name) · \(address):\(port) · \(trustText)"
            if let reason = note.userInfo?["verificationFailedReason"] as? String, !reason.isEmpty { detail += " · 原因: \(reason)" }
            if settingsManager.onlyNotifyVerifiedDevices {
                if isVerified {
                    appendEvent(title: "📡 发现可连接设备", detail: detail, success: true, icon: "antenna.radiowaves.left.and.right")
                    notifiedConnectableDevices[deviceId] = now
                }
            } else {
                let isWarn = !isVerified
                appendEvent(title: isWarn ? "📡 发现可连接设备（未验证）" : "📡 发现可连接设备", detail: detail, success: !isWarn, icon: isWarn ? "exclamationmark.shield.fill" : "antenna.radiowaves.left.and.right", warning: isWarn)
                notifiedConnectableDevices[deviceId] = now
            }
        }
 // 订阅关键事件
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FileTransferCompleted"))) { note in
            let fileName = (note.userInfo?["fileName"] as? String) ?? "未知文件"
            let fileSize = (note.userInfo?["fileSize"] as? Int64) ?? 0
            appendEvent(title: "文件传输完成", detail: "\(fileName) · \(byteCount(fileSize))", success: true, icon: "checkmark.circle.fill")
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FileTransferFailed"))) { note in
            let fileName = (note.userInfo?["fileName"] as? String) ?? "未知文件"
            let error = (note.userInfo?["error"] as? String) ?? "未知错误"
            appendEvent(title: "文件传输失败", detail: "\(fileName) · \(error)", success: false, icon: "xmark.circle.fill")
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileChunkVerified)) { note in
            appendEvent(from: note, fallbackTitle: "分块校验通过", success: true, icon: "checkmark.seal")
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileChunkVerifyFailed)) { note in
            appendEvent(from: note, fallbackTitle: "分块校验失败", success: false, icon: "xmark.seal")
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileMerkleVerified)) { note in
            let ok = (note.userInfo?["ok"] as? Bool) ?? false
            appendEvent(from: note, fallbackTitle: ok ? "Merkle 校验通过" : "Merkle 校验失败", success: ok, icon: ok ? "checkmark.seal" : "exclamationmark.triangle")
        }
        .onReceive(NotificationCenter.default.publisher(for: NetworkFrameworkEnhancements.certificateValidationNotification)) { note in
            let ok = (note.userInfo?["ok"] as? Bool) ?? false
            let reason = (note.userInfo?["reason"] as? String) ?? ""
            let elapsed = (note.userInfo?["elapsed"] as? TimeInterval) ?? 0
            let title = ok ? "证书校验通过" : "证书校验失败"
            let detail = reason.isEmpty ? String(format: "耗时 %.0fms", elapsed*1000) : "\(reason) · " + String(format: "%.0fms", elapsed*1000)
            appendEvent(title: title, detail: detail, success: ok, icon: ok ? "lock.shield" : "lock.slash")
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileMerkleTiming)) { note in
            let phase = (note.userInfo?["phase"] as? String) ?? "merkle"
            let file = (note.userInfo?["fileName"] as? String) ?? ""
            let size = (note.userInfo?["fileSize"] as? Int64) ?? 0
            let chunk = (note.userInfo?["chunkSize"] as? Int) ?? 0
            let elapsed = (note.userInfo?["elapsedMs"] as? Double) ?? 0
            let metal = (note.userInfo?["metalAvailable"] as? Bool) ?? false
            let title = phase == "verify" ? "Merkle 校验耗时" : "Merkle 计算耗时"
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
            if let t = transferId { parts.append("ID:\(t)") }
            if let c = chunkIndex { parts.append("Chunk:\(c)") }
            if let e = expected, let a = actual { parts.append("期望/实际: \(e.prefix(8)) / \(a.prefix(8))") }
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
        return "\(userName)，\(timeGreeting)！"
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
        case 0..<5: return "夜深了"
        case 5..<7: return "清晨好"
        case 7..<12: return "早上好"
        case 12..<14: return "中午好"
        case 14..<18: return "下午好"
        case 18..<21: return "晚上好"
        case 21..<24: return "夜深了"
        default: return "你好"
        }
    }
    
 // MARK: - 启动欢迎和休息提醒
    
    private func sendWelcomeMessageIfNeeded() {
 // 检查是否已经发送过启动欢迎消息（本次会话内）
        if !hasShownWelcome {
            let userName = authModel.currentSession?.displayName ?? NSUserName()
            let greeting = getTimeGreeting()
            let message = "\(userName)，\(greeting)！欢迎使用 SkyBridge Compass"
            appendEvent(title: message, detail: "开始您的跨设备连接之旅", success: true, icon: welcomeIcon)
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
                    appendEvent(title: "🌙 夜深了，注意休息", detail: "建议放松眼睛，保证睡眠质量", success: true, icon: "moon.stars.fill")
                }
                
 // 天气防护建议（依据实时天气或退化为通用提示）
                sendWeatherAdvice()
                
                lastHourlyAdvice = now
            }
        }
    }
    
    private func sendRestReminder() {
        let reminders = [
            ("🌊 您已连续使用1小时", "休息片刻，喝杯水，保护您的眼睛", "cup.and.saucer.fill"),
            ("⏰ 使用时长提醒", "起来走动一下吧，久坐不利于健康", "figure.walk"),
            ("🍃 健康小贴士", "眺望远方，让眼睛得到放松", "eye.fill"),
            ("💡 建议休息", "做几个深呼吸，缓解疲劳", "lungs.fill"),
            ("☕️ 休息一下", "起身活动，保持最佳状态", "hand.raised.fill")
        ]
        
        let randomReminder = reminders.randomElement() ?? reminders[0]
        appendEvent(title: randomReminder.0, detail: randomReminder.1, success: true, icon: randomReminder.2)
    }
    
 /// 连续三小时强提醒
    private func sendThreeHourReminder() {
        appendEvent(title: "⏳ 连续使用3小时", detail: "建议充分休息、补充水分并活动一下", success: true, icon: "figure.walk")
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
                appendEvent(title: "🛑 空气质量极差 (AQI: \(aqi))", detail: "建议减少外出，佩戴口罩并关闭门窗", success: true, icon: "aqi.high")
            } else if aqi >= thresholds.unhealthy {
                appendEvent(title: "⚠️ 空气质量较差 (AQI: \(aqi))", detail: "建议佩戴口罩，尽量减少户外活动", success: true, icon: "aqi.high")
            } else if aqi >= thresholds.sensitive {
                appendEvent(title: "提示：空气质量偏高 (AQI: \(aqi))", detail: "敏感人群建议佩戴口罩，适当减少外出", success: true, icon: "aqi.medium")
            } else if aqi >= thresholds.caution {
                appendEvent(title: "提示：空气质量一般 (AQI: \(aqi))", detail: "建议适度缩短户外时长，关注实时空气质量", success: true, icon: "aqi.low")
            }
        }
        switch weatherType {
        case .clear, .partlyCloudy:
            if uv >= settingsManager.uvThresholdStrong {
                appendEvent(title: "☀️ 强紫外线提醒", detail: "建议涂抹防晒霜、佩戴太阳镜并减少日照", success: true, icon: "sun.max.fill")
            } else if uv >= settingsManager.uvThresholdModerate {
                appendEvent(title: "☀️ 防晒提醒", detail: "紫外线较强，外出注意防晒与遮阳", success: true, icon: "sun.max.fill")
            } else {
                appendEvent(title: "☀️ 天气晴好", detail: "适合外出，注意合理安排日照时间", success: true, icon: "sun.max.fill")
            }
        case .rain, .heavyRain:
            appendEvent(title: "🌧️ 防雨提醒", detail: "出门请带伞，注意道路湿滑", success: true, icon: "cloud.rain.fill")
        case .snow, .heavySnow:
            appendEvent(title: "❄️ 防雪提醒", detail: "注意保暖与防滑，谨防低温冻伤", success: true, icon: "snowflake")
        case .haze, .fog:
            appendEvent(title: "🌫️ 雾霾/大雾提醒", detail: "建议佩戴口罩，减少外出并注意行车安全", success: true, icon: "aqi.medium")
        case .thunderstorm:
 // 雷暴天气同样提醒携带雨具并减少外出
            appendEvent(title: "⛈️ 雷暴提醒", detail: "减少外出，携带雨具并注意防雷安全", success: true, icon: "cloud.bolt.rain.fill")
        default:
 // 通用提示：根据时间段提供轻量建议
            let tod = getTimeGreeting()
            appendEvent(title: "🧭 天气提示", detail: "当前时段（\(tod)），请根据实际天气合理安排出行", success: true, icon: "info.circle")
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


