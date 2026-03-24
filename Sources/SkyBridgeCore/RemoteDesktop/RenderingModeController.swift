import Foundation
import os.log

// MARK: - 渲染模式

/// 远程桌面渲染模式
///
/// 三层分级：Stable（默认稳定）→ Fluid（高性能）→ Reference（高保真）
/// 降级方向为单向：Reference → Fluid → Stable，同一流内不允许回升。
public enum RenderingMode: String, Sendable, CaseIterable {
    /// 默认模式。VT 解码 + 增量合成到 backing store，绝对稳定。
    case stable = "stable"
    /// 高性能模式。显示驱动拉帧，ring buffer + pass-through shader。
    case fluid = "fluid"
    /// 高保真模式。HEVC Main10 / HDR / Display P3，需要硬件探测。
    case reference = "reference"

    /// 模式降级优先级（数值越小越稳定）
    var priority: Int {
        switch self {
        case .stable: return 0
        case .fluid: return 1
        case .reference: return 2
        }
    }
}

// MARK: - 渲染模式控制器

/// 管理远程桌面渲染模式的选择、降级和 probation。
///
/// 核心规则：
/// 1. 默认启动为 Stable
/// 2. 降级方向：Reference → Fluid → Stable（单向，同流不回升）
/// 3. 升级需要用户显式选择 + 开启新流
/// 4. Probation 机制：升级后前 N 秒为试用期，不通过则自动降级
public final class RenderingModeController: @unchecked Sendable {
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.skybridge.compass", category: "RenderingMode")

    // MARK: - 状态

    private var _currentMode: RenderingMode = .stable
    private var _userRequestedMode: RenderingMode = .stable
    /// 同流内曾降级到的最低模式——初始为 .reference 表示"尚未降级过"
    private var _lowestReachedMode: RenderingMode = .reference
    private var _probationStartTimestamp: UInt64 = 0
    private var _probationActive: Bool = false
    private var _probationFrameCount: UInt64 = 0
    private var _probationFailureCount: Int = 0

    // MARK: - 配置

    /// Probation 时长（纳秒），默认 5 秒
    public let probationDurationNs: UInt64

    /// Probation 期间最低可接受 FPS 占比（相对目标 FPS）
    public let probationMinFPSRatio: Double

    /// Probation 期间允许的最大失败帧数
    public let probationMaxFailures: Int

    // MARK: - 委托

    /// 模式变化回调
    public var onModeChanged: ((RenderingMode, RenderingMode, String) -> Void)?

    // MARK: - 健康监测

    public let healthMonitor: RendererHealthMonitor

    public init(
        probationDurationNs: UInt64 = 5_000_000_000,
        probationMinFPSRatio: Double = 0.8,
        probationMaxFailures: Int = 3,
        healthMonitor: RendererHealthMonitor = RendererHealthMonitor()
    ) {
        self.probationDurationNs = probationDurationNs
        self.probationMinFPSRatio = probationMinFPSRatio
        self.probationMaxFailures = probationMaxFailures
        self.healthMonitor = healthMonitor
    }

    // MARK: - 查询

    /// 当前活跃的渲染模式
    public var currentMode: RenderingMode {
        lock.lock()
        defer { lock.unlock() }
        return _currentMode
    }

    /// 用户请求的渲染模式
    public var userRequestedMode: RenderingMode {
        lock.lock()
        defer { lock.unlock() }
        return _userRequestedMode
    }

    /// 是否处于 probation 期
    public var isProbationActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _probationActive
    }

    // MARK: - 模式请求

    /// 用户请求切换渲染模式。
    ///
    /// 只有当请求的模式不低于当前已降级到的最低模式时才会生效。
    /// 如果请求的模式高于 stable，会进入 probation 期。
    ///
    /// - Parameter mode: 用户请求的渲染模式
    /// - Returns: 实际生效的渲染模式
    @discardableResult
    public func requestMode(_ mode: RenderingMode) -> RenderingMode {
        lock.lock()

        _userRequestedMode = mode

        // 检查是否可以升级到请求的模式
        // 同一流内只允许降级，不允许升回
        let effectiveMode: RenderingMode
        if mode.priority > _lowestReachedMode.priority {
            // 请求升级到比当前流中曾降级过的最低点还高——不允许
            effectiveMode = _lowestReachedMode
            log.info("Mode upgrade denied: requested \(mode.rawValue) but lowest reached is \(self._lowestReachedMode.rawValue)")
        } else {
            effectiveMode = mode
        }

        let previousMode = _currentMode

        if effectiveMode.priority < _currentMode.priority {
            // 降级——立即生效
            _currentMode = effectiveMode
            _lowestReachedMode = effectiveMode
            _probationActive = false
            lock.unlock()
            notifyModeChange(from: previousMode, to: effectiveMode, reason: "user_requested_downgrade")
            return effectiveMode
        } else if effectiveMode == _currentMode {
            lock.unlock()
            return effectiveMode
        } else {
            // 升级——进入 probation
            _currentMode = effectiveMode
            _probationActive = true
            _probationStartTimestamp = DispatchTime.now().uptimeNanoseconds
            _probationFrameCount = 0
            _probationFailureCount = 0
            lock.unlock()
            log.info("Mode upgrade to \(effectiveMode.rawValue) — entering probation")
            notifyModeChange(from: previousMode, to: effectiveMode, reason: "user_requested_upgrade_probation")
            return effectiveMode
        }
    }

    /// 为新流重置模式控制器。
    ///
    /// 允许重新升级，因为这是一个全新的流。
    public func resetForNewStream() {
        lock.lock()
        let previousMode = _currentMode
        _currentMode = .stable
        _lowestReachedMode = .reference
        _userRequestedMode = .stable
        _probationActive = false
        _probationStartTimestamp = 0
        _probationFrameCount = 0
        _probationFailureCount = 0
        lock.unlock()
        healthMonitor.reset()
        if previousMode != .stable {
            notifyModeChange(from: previousMode, to: .stable, reason: "new_stream_reset")
        }
    }

    // MARK: - Probation 管理

    /// 在 probation 期间报告一帧成功呈现。
    ///
    /// 当 probation 期满且表现合格时，probation 自动结束，模式锁定。
    public func reportProbationFrameSuccess() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard _probationActive else {
            lock.unlock()
            return
        }

        _probationFrameCount += 1

        let elapsed = now - _probationStartTimestamp
        if elapsed >= probationDurationNs {
            // probation 到期——检查是否通过
            let passed = _probationFailureCount <= probationMaxFailures
            if passed {
                _probationActive = false
                let mode = _currentMode
                let frameCount = _probationFrameCount
                lock.unlock()
                log.info("Probation passed for \(mode.rawValue) after \(frameCount) frames")
            } else {
                // 未通过——降级
                let from = _currentMode
                let failures = _probationFailureCount
                lock.unlock()
                degradeFromCurrentMode(reason: "probation_failed_\(failures)_failures")
                log.warning("Probation failed for \(from.rawValue), degrading")
            }
        } else {
            lock.unlock()
        }
    }

    /// 在 probation 期间报告一帧失败。
    ///
    /// 如果失败次数超过阈值，立即降级。
    public func reportProbationFrameFailure() {
        lock.lock()
        guard _probationActive else {
            lock.unlock()
            return
        }

        _probationFailureCount += 1
        let failures = _probationFailureCount
        let maxFailures = probationMaxFailures
        let from = _currentMode
        lock.unlock()

        if failures > maxFailures {
            degradeFromCurrentMode(reason: "probation_immediate_failure_\(failures)")
            log.warning("Probation immediate failure for \(from.rawValue), \(failures) failures")
        }
    }

    // MARK: - 自动降级

    /// 由健康监测器触发的自动降级。
    ///
    /// 当检测到冻屏或持续掉帧时调用。
    public func triggerAutoDegradation(reason: String) {
        degradeFromCurrentMode(reason: "auto_\(reason)")
    }

    /// 将当前模式降级一级。
    private func degradeFromCurrentMode(reason: String) {
        lock.lock()
        let from = _currentMode
        let to: RenderingMode
        switch from {
        case .reference:
            to = .fluid
        case .fluid:
            to = .stable
        case .stable:
            // 已经在最低级，无法再降
            lock.unlock()
            return
        }
        _currentMode = to
        _lowestReachedMode = to
        _probationActive = false
        lock.unlock()

        healthMonitor.recordDegradation(from: from.rawValue, to: to.rawValue, reason: reason)
        notifyModeChange(from: from, to: to, reason: reason)
    }

    // MARK: - 通知

    private func notifyModeChange(from: RenderingMode, to: RenderingMode, reason: String) {
        guard from != to else { return }
        log.info("Rendering mode: \(from.rawValue) → \(to.rawValue) (\(reason))")
        onModeChanged?(from, to, reason)
    }

    // MARK: - 遥测

    /// 生成当前遥测快照
    public func telemetrySnapshot() -> RendererTelemetrySnapshot {
        lock.lock()
        let mode = _currentMode
        lock.unlock()
        return healthMonitor.snapshot(currentMode: mode.rawValue)
    }
}
