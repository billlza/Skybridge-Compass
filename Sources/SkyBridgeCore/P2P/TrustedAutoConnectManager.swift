import Foundation
import os

/// 随航自动连接管理器（Phase A：局域网/可达范围）。
///
/// 职责：周期性地把「用户已开启随航开关 + 仍受密码学信任 + 当前可发现（携带 address:port）」的设备
/// 自动连接到 `P2PNetworkManager`，并在掉线后按退避重连，从而让随航剪贴板等功能在无需手动会话时
/// 也保持连接。Layer 1 已经在 `P2PNetworkManager.activeConnections` 上广播剪贴板，本管理器只负责把
/// 这些连接维持住。
///
/// 边界（与用户确认）：
/// - **仅** 自动连接「用户逐设备显式开启随航开关」的设备（默认全部关闭，不会抢连）。
/// - **仅** 能拨号当前可发现（discovery 列表中携带 address:port）的设备；离线/跨网设备无法在此路径
///   触达（需 Phase B 的跨网在线 presence/信令，另案）。
/// - 自动连接只建立/保活后台 P2P 会话（供剪贴板/在线状态用），**不**自动打开远程桌面窗口。
/// - 与全局总开关 `SettingsManager.autoConnectPairedDevices` 相与；任一关闭即不连。
/// - 不复用 `AutoConnectService`（其连接走 DeviceDiscoveryManagerOptimized 的另一套注册表，
///   与剪贴板广播所用的 `P2PNetworkManager.activeConnections` 不是同一处）。
@available(macOS 14.0, *)
@MainActor
public final class TrustedAutoConnectManager: ObservableObject {
    public static let shared = TrustedAutoConnectManager()

    private let log = Logger(subsystem: "com.skybridge.compass", category: "TrustedAutoConnect")

    private var hasStarted = false
    private var reconcileTask: Task<Void, Never>?

    /// 正在尝试连接（避免同一设备并发重复拨号）。
    private var inFlight: Set<String> = []
    /// 每设备的下次允许尝试时间（连接失败后的指数退避）。
    private var nextAttemptAt: [String: Date] = [:]
    /// 每设备当前退避秒数（指数增长，封顶 5 分钟）。
    private var backoffSeconds: [String: Double] = [:]

    private init() {}

    /// 启动后台对账循环（幂等）。应在发现/ P2P 服务就绪后从 DashboardViewModel.start() 调用一次。
    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        reconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.reconcile()
                let interval = self.currentIntervalSeconds()
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
            }
        }
        log.info("🔗 随航自动连接管理器已启动")
    }

    public func stop() {
        reconcileTask?.cancel()
        reconcileTask = nil
        hasStarted = false
    }

    /// 立即触发一次对账（例如前台恢复时）。
    public func triggerReconcile() {
        guard hasStarted else { return }
        Task { await reconcile() }
    }

    /// 电量/热量感知的对账间隔（含 ±20% 抖动，避免重连风暴同相）。
    private func currentIntervalSeconds() -> Double {
        let base: Double
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            base = 90
        } else {
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .serious || thermal == .critical {
                base = 90
            } else {
#if os(macOS)
                base = HardwareCapabilityProbe.isOnExternalPower() ? 15 : 45
#else
                // `HardwareCapabilityProbe` is IOKit-based and macOS-only. Rather than inventing a
                // new interval, pick the existing battery-powered branch, which is the conservative
                // one. Migration decision point: use the platform's own power-source signal
                // (`UIDevice.batteryState` on iOS) once iOS runs this path.
                base = 45
#endif
            }
        }
        // 0.8x–1.2x 抖动（用纳秒时钟低位作为无种子随机源，避免 Math.random / 不可复现的全局状态）
        let jitterFraction = Double(DispatchTime.now().uptimeNanoseconds % 1000) / 1000.0 // 0..1
        return base * (0.8 + 0.4 * jitterFraction)
    }

    private func reconcile() async {
        // 全局总开关（与逐设备 opt-in 开关相与）
        guard SettingsManager.shared.autoConnectPairedDevices else { return }
        let enabled = TrustedAutoConnectStore.shared.enabledFingerprints
        guard !enabled.isEmpty else { return }

        let manager = P2PNetworkManager.shared
        let trust = TrustSyncService.shared
        let now = Date()

        for device in manager.discoveredDevices {
            let id = device.id
            // 仍受密码学信任（isTrusted 已排除 tombstone/expired），并解析其稳定公钥指纹。
            guard trust.isTrusted(deviceId: id), let record = trust.getTrustRecord(deviceId: id) else { continue }
            guard enabled.contains(record.pubKeyFP) else { continue }  // 用户已对该指纹开启随航
            guard !device.address.isEmpty, device.port > 0 else { continue } // 可拨号
            // 已是「已认证」连接则跳过（仅传输态未认证不算，继续推进以完成握手）
            if let conn = manager.activeConnections[id], conn.status == .authenticated { continue }
            guard !inFlight.contains(id) else { continue }
            if let next = nextAttemptAt[id], now < next { continue }   // 退避中

            inFlight.insert(id)
            log.debug("🔗 随航：尝试自动连接 \(device.name, privacy: .public)")
            manager.connectToDevice(device, connectionEstablished: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.inFlight.remove(id)
                    self.nextAttemptAt[id] = nil
                    self.backoffSeconds[id] = nil
                }
            }, connectionFailed: { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.inFlight.remove(id)
                    // 指数退避：30s 起，每次翻倍，封顶 5 分钟
                    let prev = self.backoffSeconds[id] ?? 0
                    let nextBackoff = min(max(prev * 2, 30), 300)
                    self.backoffSeconds[id] = nextBackoff
                    self.nextAttemptAt[id] = Date().addingTimeInterval(nextBackoff)
                }
            })
        }
    }
}
