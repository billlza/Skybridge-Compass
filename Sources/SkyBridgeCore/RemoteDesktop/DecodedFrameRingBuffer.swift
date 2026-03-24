import Foundation
import CoreVideo

// MARK: - 解码帧环形缓冲区

/// 单生产者-单消费者 (SPSC) 环形缓冲区，用于解码后的视频帧。
///
/// 设计原则：
/// 1. **最新帧语义**：消费者总是取最新帧，跳过中间帧（不追求每帧都显示）
/// 2. **线程安全**：生产者（VT 解码回调线程）和消费者（主线程 MTKView.draw）不共享锁
/// 3. **零拷贝**：存储 CVPixelBuffer 引用，IOSurface 由系统管理生命周期
/// 4. **固定容量**：3 个 slot，足以吸收 decode jitter，又不积压
///
/// ```
/// Producer (decode thread)          Consumer (display thread)
///     │                                  │
///     ├─ push(pixelBuffer) ──────►  latestFrame() → CVPixelBuffer?
///     │  写入 writeIndex               读取 readIndex = writeIndex - 1
///     │  原子递增 writeIndex            （总是取最新一帧）
///     │                                  │
///     └─ 如果 buffer 满，覆盖最旧帧     └─ 无新帧时返回 nil
/// ```
public final class DecodedFrameRingBuffer: @unchecked Sendable {

    /// 环形缓冲区中的帧
    public struct BufferedFrame: @unchecked Sendable {
        /// 解码后的像素缓冲区
        public let pixelBuffer: CVPixelBuffer
        /// 帧接收时间（纳秒）
        public let recvTimestampNs: UInt64
        /// 解码完成时间（纳秒）
        public let decodeTimestampNs: UInt64
        /// 帧数据大小（字节）
        public let recvBytes: Int

        public init(
            pixelBuffer: CVPixelBuffer,
            recvTimestampNs: UInt64,
            decodeTimestampNs: UInt64,
            recvBytes: Int
        ) {
            self.pixelBuffer = pixelBuffer
            self.recvTimestampNs = recvTimestampNs
            self.decodeTimestampNs = decodeTimestampNs
            self.recvBytes = recvBytes
        }
    }

    // MARK: - 存储

    private let capacity: Int
    private var slots: [BufferedFrame?]
    private let lock = NSLock()
    private var writeIndex: Int = 0
    private var version: UInt64 = 0
    private var lastReadVersion: UInt64 = 0
    private var skippedFrames: UInt64 = 0

    // MARK: - 初始化

    /// 创建环形缓冲区。
    /// - Parameter capacity: 槽位数量，默认 3。最小为 2。
    public init(capacity: Int = 3) {
        self.capacity = max(2, capacity)
        self.slots = [BufferedFrame?](repeating: nil, count: max(2, capacity))
    }

    // MARK: - 生产者接口（解码线程调用）

    /// 推入一帧解码后的数据。
    ///
    /// 如果缓冲区满，会覆盖最旧的帧（这是设计意图——我们只关心最新帧）。
    public func push(_ frame: BufferedFrame) {
        lock.lock()
        let slotIndex = writeIndex % capacity
        slots[slotIndex] = frame
        writeIndex &+= 1
        version &+= 1
        lock.unlock()
    }

    // MARK: - 消费者接口（显示线程调用）

    /// 取出最新的一帧。
    ///
    /// 如果自上次调用以来没有新帧，返回 nil（不重复返回旧帧）。
    /// 如果跳过了中间帧，累计到 skippedFrames 计数。
    public func latestFrame() -> BufferedFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard version != lastReadVersion else { return nil }
        let skipped = version - lastReadVersion
        if skipped > 1 {
            skippedFrames &+= skipped - 1
        }
        lastReadVersion = version
        let latestSlot = ((writeIndex &- 1) % capacity + capacity) % capacity
        return slots[latestSlot]
    }

    // MARK: - 查询

    /// 累计被跳过的帧数
    public var skippedFrameCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return skippedFrames
    }

    /// 当前是否有未读的新帧
    public var hasNewFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return version != lastReadVersion
    }

    /// 重置缓冲区
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<capacity {
            slots[i] = nil
        }
        writeIndex = 0
        version = 0
        lastReadVersion = 0
        skippedFrames = 0
    }
}

// MARK: - 兼容用轻量原子封装

/// 保留给现有测试与少量辅助代码使用。
/// Ring buffer 本身已改为单锁保护，不再依赖这个类型来保证正确性。
final class ManagedAtomic<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ initialValue: Value) {
        value = initialValue
    }

    func load(ordering: AtomicLoadOrdering) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func store(_ desired: Value, ordering: AtomicStoreOrdering) {
        lock.lock()
        value = desired
        lock.unlock()
    }

    @discardableResult
    func exchange(_ desired: Value, ordering: AtomicUpdateOrdering) -> Value {
        lock.lock()
        let old = value
        value = desired
        lock.unlock()
        return old
    }
}

extension ManagedAtomic where Value: FixedWidthInteger {
    @discardableResult
    func wrappingIncrement(by delta: Value = 1, ordering: AtomicUpdateOrdering = .relaxed) -> Value {
        lock.lock()
        let old = value
        value = old &+ delta
        lock.unlock()
        return old
    }
}

enum AtomicLoadOrdering {
    case relaxed
    case acquiring
}

enum AtomicStoreOrdering {
    case relaxed
    case releasing
}

enum AtomicUpdateOrdering {
    case relaxed
    case releasing
    case acquiringAndReleasing
}
