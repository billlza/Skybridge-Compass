import Foundation
import Combine
import os.log
import UserNotifications
import Darwin

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
    @Published public private(set) var cpuPower: Double = 0
    @Published public private(set) var gpuPower: Double = 0
    @Published public private(set) var anePower: Double = 0
    @Published public private(set) var ramPower: Double = 0
    @Published public private(set) var packagePower: Double = 0
    @Published public private(set) var powerReadings: [PowerMetricsPowerReading] = []
    @Published public private(set) var memoryUsage: Double = 0
    @Published public private(set) var diskUsage: Double = 0
    @Published public private(set) var networkThroughputMbps: Double = 0
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
    @Published public private(set) var historyPoints: [SystemMonitorHistoryPoint] = []

    private let logger = Logger(subsystem: "SkyBridgeCore.Performance", category: "SystemPerformanceMonitor")

    private var monitoringTimer: Timer?
    private var startupDelayTimer: Timer?
    private var monitoringInterval: TimeInterval = 2.0
    private var settingsCancellables = Set<AnyCancellable>()

    private var notificationThresholds = NotificationThresholds()
    private var lastNotificationTime: Date = .distantPast
    private let notificationCooldown: TimeInterval = 300
    private var notificationAuthChecked = false
    private var notificationAuthGranted = false
    private var enableAutoRefresh = true
    private var enablePerformanceAlerts = true
    private var enableSystemNotifications = true
    private var enableSoundAlerts = false
    private var enableTemperatureMonitoring = true
    private var enableFanSpeedMonitoring = true
    private var enableThermalThrottlingAlert = true
    private var enableRemoteMonitoring = false
    private var historyRetentionDays = 7
    private var historyPointBudget = 300
    private var optimizeMemoryUsage = true

    private var previousNetworkSample: (inBytes: UInt64, outBytes: UInt64, timestamp: Date)?

    private var lastDiagnosticLogAt: Date = .distantPast
    private var lastDiagnosticSignature = ""

    public init() {
        let storedModeRaw = UserDefaults.standard.string(forKey: MonitoringMode.userDefaultsKey)
        self.monitoringMode = storedModeRaw.flatMap { MonitoringMode(rawValue: $0) } ?? .standardPublic
        applySettings(SettingsManager.shared)
        setupSettingsObservers()
        setupHistoryNotifications()
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

    public func updateMonitoringInterval(basedOnLoad _: Double) {
        let previous = monitoringInterval
        applySettings(SettingsManager.shared)
        let newInterval = monitoringInterval
        monitoringInterval = newInterval
        guard newInterval != previous else { return }
        if isMonitoring && enableAutoRefresh {
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

    private func setupSettingsObservers() {
        let settingsManager = SettingsManager.shared

        settingsManager.$systemMonitorRefreshInterval.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applySettings(settingsManager)
                self.applyAutoRefreshState()
            }
        }.store(in: &settingsCancellables)

        settingsManager.$enableAutoRefresh.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applySettings(settingsManager)
                self.applyAutoRefreshState()
            }
        }.store(in: &settingsCancellables)

        settingsManager.$enablePerformanceAlerts.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettings(settingsManager)
            }
        }.store(in: &settingsCancellables)

        settingsManager.$enableSystemNotifications.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettings(settingsManager)
            }
        }.store(in: &settingsCancellables)

        settingsManager.$enableSoundAlerts.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettings(settingsManager)
            }
        }.store(in: &settingsCancellables)

        settingsManager.$cpuThreshold.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettings(settingsManager)
            }
        }.store(in: &settingsCancellables)

        settingsManager.$memoryThreshold.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettings(settingsManager)
            }
        }.store(in: &settingsCancellables)

        settingsManager.$diskThreshold.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettings(settingsManager)
            }
        }.store(in: &settingsCancellables)

        settingsManager.$temperatureThreshold.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettings(settingsManager)
            }
        }.store(in: &settingsCancellables)

        settingsManager.$fanSpeedThreshold.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettings(settingsManager)
            }
        }.store(in: &settingsCancellables)

        settingsManager.$enableTemperatureMonitoring.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettings(settingsManager)
            }
        }.store(in: &settingsCancellables)

        settingsManager.$enableFanSpeedMonitoring.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettings(settingsManager)
            }
        }.store(in: &settingsCancellables)

        settingsManager.$enableThermalThrottlingAlert.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettings(settingsManager)
            }
        }.store(in: &settingsCancellables)

        settingsManager.$maxHistoryPoints.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettings(settingsManager)
            }
        }.store(in: &settingsCancellables)

        settingsManager.$systemMonitorRetentionDays.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettings(settingsManager)
            }
        }.store(in: &settingsCancellables)

        settingsManager.$systemMonitorSamplingPrecision.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applySettings(settingsManager)
                self.applyAutoRefreshState()
            }
        }.store(in: &settingsCancellables)

        settingsManager.$optimizeMemoryUsage.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettings(settingsManager)
            }
        }.store(in: &settingsCancellables)

        settingsManager.$enableRemoteMonitoring.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettings(settingsManager)
            }
        }.store(in: &settingsCancellables)
    }

    private func setupHistoryNotifications() {
        NotificationCenter.default.publisher(for: .systemMonitorClearHistory)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.clearHistory()
                }
            }
            .store(in: &settingsCancellables)

        NotificationCenter.default.publisher(for: .systemMonitorExport)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.exportHistorySnapshot()
                }
            }
            .store(in: &settingsCancellables)
    }

    private func applySettings(_ settingsManager: SettingsManager) {
        let precisionMultiplier: Double
        switch settingsManager.systemMonitorSamplingPrecision {
        case .low:
            precisionMultiplier = 2.0
        case .normal:
            precisionMultiplier = 1.0
        case .high:
            precisionMultiplier = 0.5
        }
        monitoringInterval = max(0.5, settingsManager.systemMonitorRefreshInterval * precisionMultiplier)
        enableAutoRefresh = settingsManager.enableAutoRefresh
        enablePerformanceAlerts = settingsManager.enablePerformanceAlerts
        enableSystemNotifications = settingsManager.enableSystemNotifications
        enableSoundAlerts = settingsManager.enableSoundAlerts
        enableTemperatureMonitoring = settingsManager.enableTemperatureMonitoring
        enableFanSpeedMonitoring = settingsManager.enableFanSpeedMonitoring
        enableThermalThrottlingAlert = settingsManager.enableThermalThrottlingAlert
        enableRemoteMonitoring = settingsManager.enableRemoteMonitoring
        historyRetentionDays = max(1, settingsManager.systemMonitorRetentionDays)
        optimizeMemoryUsage = settingsManager.optimizeMemoryUsage
        let baseBudget = Int(max(50, settingsManager.maxHistoryPoints))
        historyPointBudget = optimizeMemoryUsage ? min(baseBudget, 120) : baseBudget
        notificationThresholds.cpuUsage = settingsManager.cpuThreshold
        notificationThresholds.memoryUsage = settingsManager.memoryThreshold
        notificationThresholds.diskUsage = settingsManager.diskThreshold
        notificationThresholds.cpuTemperature = settingsManager.temperatureThreshold
        notificationThresholds.fanSpeedRPM = settingsManager.fanSpeedThreshold
        trimHistory()
    }

    private func applyAutoRefreshState() {
        guard isMonitoring else { return }
        if enableAutoRefresh {
            startMonitoringTimer()
        } else {
            monitoringTimer?.invalidate()
            monitoringTimer = nil
        }
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
        if enableAutoRefresh {
            startMonitoringTimer()
        }
        logger.info("SystemPerformanceMonitor started")
    }

    private func startMonitoringTimer() {
        guard enableAutoRefresh else {
            monitoringTimer?.invalidate()
            monitoringTimer = nil
            return
        }
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
        diskUsage = sampleDiskUsagePercent()
        networkThroughputMbps = sampleNetworkThroughputMbps()
        loadAverage1Min = snapshot.loadAvg1
        loadAverage5Min = snapshot.loadAvg5
        loadAverage15Min = snapshot.loadAvg15

        gpuUsage = snapshot.gpuUsage
        cpuPower = snapshot.cpuPower
        gpuPower = snapshot.gpuPower
        anePower = snapshot.anePower
        ramPower = snapshot.ramPower
        packagePower = snapshot.packagePower
        powerReadings = snapshot.powerReadings
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

        appendHistoryPoint(from: snapshot)
        if enableRemoteMonitoring {
            NotificationCenter.default.post(
                name: Notification.Name("SystemMonitor.RemoteSnapshotUpdated"),
                object: nil,
                userInfo: [
                    "timestamp": Date(),
                    "cpu": cpuUsage,
                    "memory": memoryUsage,
                    "disk": diskUsage,
                    "network": networkThroughputMbps
                ]
            )
        }

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

    private func appendHistoryPoint(from snapshot: UnifiedMetricsSnapshot) {
        let now = Date()
        historyPoints.append(
            SystemMonitorHistoryPoint(
                timestamp: now,
                cpuUsage: snapshot.cpuUsage,
                memoryUsage: snapshot.memoryUsage,
                diskUsage: diskUsage,
                networkThroughputMbps: networkThroughputMbps,
                temperature: cpuTemperature,
                fanSpeed: Double(fanSpeed.first ?? 0)
            )
        )
        trimHistory()
    }

    private func trimHistory() {
        if historyPointBudget > 0, historyPoints.count > historyPointBudget {
            historyPoints.removeFirst(historyPoints.count - historyPointBudget)
        }

        let cutoff = Date().addingTimeInterval(-Double(historyRetentionDays) * 86_400)
        historyPoints.removeAll { $0.timestamp < cutoff }
    }

    private func clearHistory() {
        historyPoints.removeAll()
        previousNetworkSample = nil
        logger.info("SystemPerformanceMonitor history cleared")
    }

    private func exportHistorySnapshot() {
        let payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "cpuUsage": cpuUsage,
            "memoryUsage": memoryUsage,
            "diskUsage": diskUsage,
            "networkThroughputMbps": networkThroughputMbps,
            "history": historyPoints.map {
                [
                    "timestamp": ISO8601DateFormatter().string(from: $0.timestamp),
                    "cpuUsage": $0.cpuUsage,
                    "memoryUsage": $0.memoryUsage,
                    "diskUsage": $0.diskUsage,
                    "networkThroughputMbps": $0.networkThroughputMbps,
                    "temperature": $0.temperature,
                    "fanSpeed": $0.fanSpeed
                ]
            }
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let filename = "system_monitor_export_\(formatter.string(from: Date())).json"
            let desktopURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop", isDirectory: true)
                .appendingPathComponent(filename)
            try data.write(to: desktopURL, options: .atomic)
            logger.info("SystemPerformanceMonitor history exported: \(desktopURL.path, privacy: .public)")
        } catch {
            logger.error("SystemPerformanceMonitor export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sampleDiskUsagePercent() -> Double {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            let total = (attrs[.systemSize] as? NSNumber)?.doubleValue ?? 0
            let free = (attrs[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0
            guard total > 0 else { return diskUsage }
            return max(0, min(100, (1.0 - (free / total)) * 100))
        } catch {
            return diskUsage
        }
    }

    private func sampleNetworkThroughputMbps() -> Double {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var mib = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len: size_t = 0
        let now = Date()

        guard sysctl(&mib, 6, nil, &len, nil, 0) >= 0 else { return networkThroughputMbps }
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: len)
        defer { buffer.deallocate() }
        guard sysctl(&mib, 6, buffer, &len, nil, 0) >= 0 else { return networkThroughputMbps }

        var offset = 0
        while offset < len {
            let header = buffer.advanced(by: offset).withMemoryRebound(to: if_msghdr.self, capacity: 1) { $0.pointee }
            if header.ifm_type == RTM_IFINFO2 {
                let ifInfo = buffer.advanced(by: offset).withMemoryRebound(to: if_msghdr2.self, capacity: 1) { $0.pointee }
                bytesIn += ifInfo.ifm_data.ifi_ibytes
                bytesOut += ifInfo.ifm_data.ifi_obytes
            }
            offset += Int(header.ifm_msglen)
        }

        let current = (inBytes: bytesIn, outBytes: bytesOut, timestamp: now)
        defer { previousNetworkSample = current }

        guard let previous = previousNetworkSample else { return 0 }
        let elapsed = now.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return networkThroughputMbps }

        let inDiff = bytesIn >= previous.inBytes ? bytesIn - previous.inBytes : 0
        let outDiff = bytesOut >= previous.outBytes ? bytesOut - previous.outBytes : 0
        let bytesPerSecond = Double(inDiff + outDiff) / elapsed
        let mbps = bytesPerSecond * 8 / (1024 * 1024)
        return max(0, mbps)
    }

    private func checkAndSendNotifications() async {
        guard enablePerformanceAlerts, enableSystemNotifications else { return }

        let sinceLast = Date().timeIntervalSince(lastNotificationTime)
        guard sinceLast >= notificationCooldown else { return }

        var title = ""
        var body = ""

        if cpuUsage >= notificationThresholds.cpuUsage {
            title = "⚠️ CPU负载过高"
            body = String(format: "当前CPU使用率: %.1f%%", cpuUsage)
        } else if memoryUsage >= notificationThresholds.memoryUsage {
            title = "💾 内存使用过高"
            body = String(format: "当前内存使用率: %.1f%%", memoryUsage)
        } else if diskUsage >= notificationThresholds.diskUsage {
            title = "💽 磁盘使用率过高"
            body = String(format: "当前磁盘使用率: %.1f%%", diskUsage)
        } else if enableTemperatureMonitoring,
                  cpuTemperatureState.availability == .available,
                  cpuTemperature >= notificationThresholds.cpuTemperature {
            title = "🌡️ CPU温度过高"
            body = String(format: "当前CPU温度: %.1f°C", cpuTemperature)
        } else if enableFanSpeedMonitoring,
                  fanState.availability == .available,
                  Double(fanSpeed.first ?? 0) >= notificationThresholds.fanSpeedRPM {
            title = "🌀 风扇转速过高"
            body = String(format: "当前风扇转速: %.0f RPM", Double(fanSpeed.first ?? 0))
        } else if enableThermalThrottlingAlert,
                  ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            title = "🔥 检测到热节流风险"
            body = "系统热状态达到严重级别，请降低负载或改善散热。"
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
        content.sound = enableSoundAlerts ? .default : nil

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }
}

private struct NotificationThresholds {
    var cpuUsage: Double = 85
    var cpuTemperature: Double = 85
    var memoryUsage: Double = 85
    var diskUsage: Double = 90
    var fanSpeedRPM: Double = 4000
}

public struct SystemMonitorHistoryPoint: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let cpuUsage: Double
    public let memoryUsage: Double
    public let diskUsage: Double
    public let networkThroughputMbps: Double
    public let temperature: Double
    public let fanSpeed: Double
}
