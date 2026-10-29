import Foundation

// MARK: - 渲染管线遥测数据

/// 单帧生命周期时间戳
public struct FrameLifecycleTimestamps: Sendable {
    /// 帧数据到达时间
    public let recvTimestamp: UInt64
    /// 解码完成时间
    public let decodeTimestamp: UInt64
    /// 提交到渲染表面的时间
    public let displayTimestamp: UInt64
    /// 实际呈现到屏幕的时间
    public let presentTimestamp: UInt64

    public init(
        recvTimestamp: UInt64,
        decodeTimestamp: UInt64,
        displayTimestamp: UInt64,
        presentTimestamp: UInt64
    ) {
        self.recvTimestamp = recvTimestamp
        self.decodeTimestamp = decodeTimestamp
        self.displayTimestamp = displayTimestamp
        self.presentTimestamp = presentTimestamp
    }

    /// recv → present 全链路延迟 (纳秒)
    public var endToEndLatencyNs: UInt64 {
        guard presentTimestamp > recvTimestamp else { return 0 }
        return presentTimestamp - recvTimestamp
    }

    /// 解码延迟 (纳秒)
    public var decodeLatencyNs: UInt64 {
        guard decodeTimestamp > recvTimestamp else { return 0 }
        return decodeTimestamp - recvTimestamp
    }

    /// 渲染延迟 (纳秒)
    public var renderLatencyNs: UInt64 {
        guard presentTimestamp > decodeTimestamp else { return 0 }
        return presentTimestamp - decodeTimestamp
    }
}

/// 掉帧原因分类
public enum FrameDropReason: String, Sendable {
    case decodeFailed = "decode_failed"
    case textureCreationFailed = "texture_creation_failed"
    case ringBufferOverflow = "ring_buffer_overflow"
    case displaySkipped = "display_skipped"
    case thermalThrottle = "thermal_throttle"
}

/// 渲染模式降级事件
public struct RenderingDegradationEvent: Sendable {
    public let timestamp: UInt64
    public let fromMode: String
    public let toMode: String
    public let reason: String

    public init(timestamp: UInt64, fromMode: String, toMode: String, reason: String) {
        self.timestamp = timestamp
        self.fromMode = fromMode
        self.toMode = toMode
        self.reason = reason
    }
}

/// 渲染管线累计遥测快照
public struct RendererTelemetrySnapshot: Sendable {
    public let presentedFrameCount: UInt64
    public let droppedFrameCount: UInt64
    public let totalRecvBytes: UInt64
    public let latencyP50Ns: UInt64
    public let latencyP95Ns: UInt64
    public let latencyP99Ns: UInt64
    public let averageFPS: Double
    public let degradationEvents: [RenderingDegradationEvent]
    public let currentMode: String
    public let uptimeSeconds: Double

    public init(
        presentedFrameCount: UInt64,
        droppedFrameCount: UInt64,
        totalRecvBytes: UInt64,
        latencyP50Ns: UInt64,
        latencyP95Ns: UInt64,
        latencyP99Ns: UInt64,
        averageFPS: Double,
        degradationEvents: [RenderingDegradationEvent],
        currentMode: String,
        uptimeSeconds: Double
    ) {
        self.presentedFrameCount = presentedFrameCount
        self.droppedFrameCount = droppedFrameCount
        self.totalRecvBytes = totalRecvBytes
        self.latencyP50Ns = latencyP50Ns
        self.latencyP95Ns = latencyP95Ns
        self.latencyP99Ns = latencyP99Ns
        self.averageFPS = averageFPS
        self.degradationEvents = degradationEvents
        self.currentMode = currentMode
        self.uptimeSeconds = uptimeSeconds
    }

    /// 掉帧率
    public var dropRate: Double {
        let total = presentedFrameCount + droppedFrameCount
        guard total > 0 else { return 0 }
        return Double(droppedFrameCount) / Double(total)
    }
}

/// 延迟百分位计算器（滑动窗口）
final class LatencyPercentileCalculator: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [UInt64] = []
    private let maxSamples: Int

    init(maxSamples: Int = 300) {
        self.maxSamples = maxSamples
    }

    func record(_ latencyNs: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        samples.append(latencyNs)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    func percentile(_ p: Double) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let index = min(Int(Double(sorted.count - 1) * p), sorted.count - 1)
        return sorted[index]
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
    }
}
