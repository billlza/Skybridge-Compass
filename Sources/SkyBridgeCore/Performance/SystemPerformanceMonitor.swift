import Foundation
import os.log
import UserNotifications

/// 系统性能监控器（统一真实值后端）
///
/// 数据策略：
/// - CPU/内存/负载：内核 API
/// - GPU 使用率：IOAccelerator
/// - 温度/风扇/功耗：仅专家模式 + Helper 真实采样
/// - 拿不到即明确 unavailable reason，不走估算
@available(macOS 14.0, *)
@MainActor
public final class SystemPerformanceMonitor: ObservableObject {
    @Published public private(set) var cpuUsage: Double = 0
    @Published public private(set) var gpuUsage: Double = 0
    @Published public private(set) var gpuPower: Double = 0
    @Published public private(set) var memoryUsage: Double = 0
    @Published public private(set) var cpuTemperature: Double = 0
    @Published public private(set) var gpuTemperature: Double = 0
    @Published public private(set) var fanSpeed: [Int] = []
    @Published public private(set) var loadAverage1Min: Double = 0
    @Published public private(set) var loadAverage5Min: Double = 0
    @Published public private(set) var loadAverage15Min: Double = 0

    @Published public private(set) var gpuUsageState: MetricState = .unavailable(reason: .temporarilyInitializing, source: .ioAccelerator)
    @Published public private(set) var gpuPowerState: MetricState = .unavailable(reason: .temporarilyInitializing, source: .powermetrics)
    @Published public private(set) var cpuTemperatureState: MetricState = .unavailable(reason: .temporarilyInitializing, source: .smc)
    @Published public private(set) var gpuTemperatureState: MetricState = .unavailable(reason: .temporarilyInitializing, source: .smc)
    @Published public private(set) var fanState: MetricState = .unavailable(reason: .temporarilyInitializing, source: .smc)

    @Published public private(set) var monitoringMode: MonitoringMode
    @Published public private(set) var helperServiceInfo: PowerMetricsServiceInfo?
    @Published public private(set) var isInitialized: Bool = false
    @Published public private(set) var isMonitoring: Bool = false

    private let logger = Logger(subsystem: "SkyBridgeCore.Performance", category: "SystemPerformanceMonitor")

    private var monitoringTimer: Timer?
    private var startupDelayTimer: Timer?
    private var monitoringInterval: TimeInterval = 2.0

    private var notificationThresholds = NotificationThresholds()
    private var lastNotificationTime: Date = .distantPast
    private let notificationCooldown: TimeInterval = 300
    private var notificationAuthChecked = false
    private var notificationAuthGranted = false

    private var lastDiagnosticLogAt: Date = .distantPast
    private var lastDiagnosticSignature = ""

    public init() {
        let storedModeRaw = UserDefaults.standard.string(forKey: MonitoringMode.userDefaultsKey)
        self.monitoringMode = storedModeRaw.flatMap { MonitoringMode(rawValue: $0) } ?? .standardPublic
        logger.info("SystemPerformanceMonitor initialized, mode=\(self.monitoringMode.rawValue, privacy: .public)")
    }

    public func startMonitoring(afterDelay delay: TimeInterval = 1.5) {
        guard !isMonitoring else { return }

        initializeIfNeeded()

        startupDelayTimer?.invalidate()
        startupDelayTimer = Timer.scheduledTimer(withTimeInterval: max(0, delay), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.startBackendCollection()
            }
        }
    }

    public func stopMonitoring() {
        startupDelayTimer?.invalidate()
        startupDelayTimer = nil
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        isMonitoring = false
        logger.info("SystemPerformanceMonitor stopped")
    }

    public func updateMonitoringInterval(basedOnLoad load: Double) {
        let newInterval: TimeInterval
        switch load {
        case 80...:
            newInterval = 1.0
        case 50...:
            newInterval = 1.5
        default:
            newInterval = 2.0
        }

        guard newInterval != monitoringInterval else { return }
        monitoringInterval = newInterval
        if isMonitoring {
            startMonitoringTimer()
        }
    }

    public func setMonitoringMode(_ mode: MonitoringMode) {
        guard monitoringMode != mode else { return }
        monitoringMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: MonitoringMode.userDefaultsKey)
        Task {
            await UnifiedMetricsBackend.shared.setMonitoringMode(mode)
            await collectPerformanceData(force: true)
        }
    }

    public func toggleMonitoringMode() {
        setMonitoringMode(monitoringMode == .standardPublic ? .expertPrivate : .standardPublic)
    }

    private func initializeIfNeeded() {
        guard !isInitialized else { return }
        isInitialized = true

        Task {
            await UnifiedMetricsBackend.shared.setMonitoringMode(monitoringMode)
        }
    }

    private func startBackendCollection() async {
        await collectPerformanceData(force: true)
        isMonitoring = true
        startMonitoringTimer()
        logger.info("SystemPerformanceMonitor started")
    }

    private func startMonitoringTimer() {
        monitoringTimer?.invalidate()
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: monitoringInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.collectPerformanceData(force: false)
            }
        }
    }

    private func collectPerformanceData(force: Bool) async {
        let snapshot = await UnifiedMetricsBackend.shared.collectSnapshot(force: force)
        applySnapshot(snapshot)
        await checkAndSendNotifications()
    }

    private func applySnapshot(_ snapshot: UnifiedMetricsSnapshot) {
        cpuUsage = snapshot.cpuUsage
        memoryUsage = snapshot.memoryUsage
        loadAverage1Min = snapshot.loadAvg1
        loadAverage5Min = snapshot.loadAvg5
        loadAverage15Min = snapshot.loadAvg15

        gpuUsage = snapshot.gpuUsage
        gpuPower = snapshot.gpuPower
        cpuTemperature = snapshot.cpuTemperature
        gpuTemperature = snapshot.gpuTemperature
        fanSpeed = snapshot.fanRPMs

        gpuUsageState = snapshot.gpuUsageState
        gpuPowerState = snapshot.gpuPowerState
        cpuTemperatureState = snapshot.cpuTemperatureState
        gpuTemperatureState = snapshot.gpuTemperatureState
        fanState = snapshot.fanState

        monitoringMode = snapshot.mode
        helperServiceInfo = snapshot.serviceInfo

        updateMonitoringInterval(basedOnLoad: snapshot.cpuUsage)
        logMetricDiagnostics(snapshot: snapshot)
    }

    private func logMetricDiagnostics(snapshot: UnifiedMetricsSnapshot) {
        let now = Date()
        if now.timeIntervalSince(lastDiagnosticLogAt) < 8 { return }

        let signature = [
            "mode=\(snapshot.mode.rawValue)",
            "gpuUsage=\(snapshot.gpuUsageState.availability.rawValue):\(snapshot.gpuUsageState.reason?.rawValue ?? "-")",
            "gpuPower=\(snapshot.gpuPowerState.availability.rawValue):\(snapshot.gpuPowerState.reason?.rawValue ?? "-")",
            "cpuTemp=\(snapshot.cpuTemperatureState.availability.rawValue):\(snapshot.cpuTemperatureState.reason?.rawValue ?? "-")",
            "gpuTemp=\(snapshot.gpuTemperatureState.availability.rawValue):\(snapshot.gpuTemperatureState.reason?.rawValue ?? "-")",
            "fan=\(snapshot.fanState.availability.rawValue):\(snapshot.fanState.reason?.rawValue ?? "-")"
        ].joined(separator: ",")

        if signature != lastDiagnosticSignature || now.timeIntervalSince(lastDiagnosticLogAt) > 20 {
            logger.info("Metric state: \(signature, privacy: .public)")
            lastDiagnosticSignature = signature
            lastDiagnosticLogAt = now
        }
    }

    private func checkAndSendNotifications() async {
        let sinceLast = Date().timeIntervalSince(lastNotificationTime)
        guard sinceLast >= notificationCooldown else { return }

        var title = ""
        var body = ""

        if cpuUsage >= notificationThresholds.cpuUsage {
            title = "⚠️ CPU负载过高"
            body = String(format: "当前CPU使用率: %.1f%%", cpuUsage)
        } else if gpuUsageState.availability == .available, gpuUsage >= notificationThresholds.gpuUsage {
            title = "⚠️ GPU负载过高"
            body = String(format: "当前GPU使用率: %.1f%%", gpuUsage)
        } else if cpuTemperatureState.availability == .available, cpuTemperature >= notificationThresholds.cpuTemperature {
            title = "🌡️ CPU温度过高"
            body = String(format: "当前CPU温度: %.1f°C", cpuTemperature)
        } else if gpuTemperatureState.availability == .available, gpuTemperature >= notificationThresholds.gpuTemperature {
            title = "🌡️ GPU温度过高"
            body = String(format: "当前GPU温度: %.1f°C", gpuTemperature)
        } else if memoryUsage >= notificationThresholds.memoryUsage {
            title = "💾 内存使用过高"
            body = String(format: "当前内存使用率: %.1f%%", memoryUsage)
        }

        guard !title.isEmpty else { return }
        await sendNotification(title: title, body: body)
        lastNotificationTime = Date()
    }

    private func sendNotification(title: String, body: String) async {
        guard let bundleURL = Bundle.main.bundleURL as URL?,
              bundleURL.path.lowercased().hasSuffix(".app"),
              Bundle.main.bundleIdentifier != nil else {
            return
        }

        let center = UNUserNotificationCenter.current()
        if !notificationAuthChecked {
            do {
                notificationAuthGranted = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                notificationAuthGranted = false
            }
            notificationAuthChecked = true
        }

        guard notificationAuthGranted else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }
}

private struct NotificationThresholds {
    let cpuUsage: Double = 85
    let gpuUsage: Double = 90
    let cpuTemperature: Double = 85
    let gpuTemperature: Double = 90
    let memoryUsage: Double = 85
}
