import Foundation
import os.log

/// 渲染管线健康监测器
///
/// 追踪呈现帧数、掉帧、冻屏检测、延迟统计等指标，
/// 为 `RenderingModeController` 提供降级决策依据。
public final class RendererHealthMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.skybridge.compass", category: "RendererHealth")

    // MARK: - 计数器

    private var _presentedFrameCount: UInt64 = 0
    private var _droppedFrameCount: UInt64 = 0
    private var _totalRecvBytes: UInt64 = 0
    private var _degradationCount: Int = 0

    // MARK: - 时间追踪

    private var _lastPresentedTimestamp: UInt64 = 0
    private var _startTimestamp: UInt64 = 0
    private var _fpsWindowStart: UInt64 = 0
    private var _fpsWindowFrames: UInt64 = 0
    private var _currentFPS: Double = 0

    // MARK: - 降级事件

    private var _degradationEvents: [RenderingDegradationEvent] = []

    // MARK: - 延迟

    private let latencyCalculator = LatencyPercentileCalculator(maxSamples: 300)

    // MARK: - 配置

    /// 冻屏检测阈值（纳秒），默认 500ms
    public let freezeThresholdNs: UInt64

    /// FPS 计算窗口（纳秒），默认 1 秒
    private let fpsWindowNs: UInt64 = 1_000_000_000

    public init(freezeThresholdNs: UInt64 = 500_000_000) {
        self.freezeThresholdNs = freezeThresholdNs
        let now = DispatchTime.now().uptimeNanoseconds
        _startTimestamp = now
        _fpsWindowStart = now
    }

    // MARK: - 记录事件

    /// 记录一帧成功呈现
    public func recordPresentedFrame(latencyNs: UInt64, recvBytes: Int) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        _presentedFrameCount += 1
        _totalRecvBytes += UInt64(recvBytes)
        _lastPresentedTimestamp = now
        _fpsWindowFrames += 1

        // 滑动窗口 FPS 计算
        let elapsed = now - _fpsWindowStart
        if elapsed >= fpsWindowNs {
            _currentFPS = Double(_fpsWindowFrames) * 1_000_000_000.0 / Double(elapsed)
            _fpsWindowFrames = 0
            _fpsWindowStart = now
        }
        lock.unlock()

        latencyCalculator.record(latencyNs)
    }

    /// 记录一帧掉帧
    public func recordDroppedFrame(reason: FrameDropReason) {
        lock.lock()
        _droppedFrameCount += 1
        lock.unlock()
        log.debug("Frame dropped: \(reason.rawValue)")
    }

    /// 记录降级事件
    public func recordDegradation(from: String, to: String, reason: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        let event = RenderingDegradationEvent(
            timestamp: now,
            fromMode: from,
            toMode: to,
            reason: reason
        )
        lock.lock()
        _degradationCount += 1
        _degradationEvents.append(event)
        // 只保留最近 50 条降级记录
        if _degradationEvents.count > 50 {
            _degradationEvents.removeFirst(_degradationEvents.count - 50)
        }
        lock.unlock()
        log.warning("Rendering degraded: \(from) → \(to), reason: \(reason)")
    }

    // MARK: - 查询

    /// 是否检测到冻屏
    public var isFrozen: Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let lastPresented = _lastPresentedTimestamp
        let presented = _presentedFrameCount
        lock.unlock()
        // 如果还没有任何帧呈现，不算冻屏（可能还在初始化）
        guard presented > 0 else { return false }
        guard lastPresented > 0 else { return false }
        return (now - lastPresented) > freezeThresholdNs
    }

    /// 当前 FPS
    public var currentFPS: Double {
        lock.lock()
        defer { lock.unlock() }
        return _currentFPS
    }

    /// 呈现帧总数
    public var presentedFrameCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _presentedFrameCount
    }

    /// 掉帧总数
    public var droppedFrameCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _droppedFrameCount
    }

    /// 降级次数
    public var degradationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _degradationCount
    }

    /// 生成遥测快照
    public func snapshot(currentMode: String) -> RendererTelemetrySnapshot {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let presented = _presentedFrameCount
        let dropped = _droppedFrameCount
        let recvBytes = _totalRecvBytes
        let fps = _currentFPS
        let events = _degradationEvents
        let start = _startTimestamp
        lock.unlock()

        let uptimeSeconds = Double(now - start) / 1_000_000_000.0

        return RendererTelemetrySnapshot(
            presentedFrameCount: presented,
            droppedFrameCount: dropped,
            totalRecvBytes: recvBytes,
            latencyP50Ns: latencyCalculator.percentile(0.5),
            latencyP95Ns: latencyCalculator.percentile(0.95),
            latencyP99Ns: latencyCalculator.percentile(0.99),
            averageFPS: fps,
            degradationEvents: events,
            currentMode: currentMode,
            uptimeSeconds: uptimeSeconds
        )
    }

    /// 重置所有计数器
    public func reset() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        _presentedFrameCount = 0
        _droppedFrameCount = 0
        _totalRecvBytes = 0
        _degradationCount = 0
        _lastPresentedTimestamp = 0
        _startTimestamp = now
        _fpsWindowStart = now
        _fpsWindowFrames = 0
        _currentFPS = 0
        _degradationEvents.removeAll()
        lock.unlock()
        latencyCalculator.reset()
    }
}
