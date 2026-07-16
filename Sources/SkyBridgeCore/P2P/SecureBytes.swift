//
// SecureBytes.swift
// SkyBridgeCore
//
// Tech Debt Cleanup - 3: SecureBytes 安全容器
// Requirements: 2.6
//
// 安全字节容器 - deinit 时擦除内存
// - 使用手动分配的 UnsafeMutableRawPointer，避免 Swift Array 的 COW 复制
// - deinit 时使用 explicit_bzero（Darwin 可用）确保擦除不被优化掉
// - 对外只暴露 Data in/out，内部生命周期可控
//

import Foundation

// MARK: - SecureBytes

/// 安全字节容器 - deinit 时擦除内存
///
/// **关键设计决策**：
/// - 使用手动分配的 UnsafeMutableRawPointer，避免 Swift Array 的 COW 复制
/// - deinit 时使用 explicit_bzero（Darwin 可用）确保擦除不被优化掉
/// - 对外只暴露 Data in/out，内部生命周期可控
/// - 显式测试构建可注入 wipingFunction 验证擦除路径；生产构建固定调用 secureZero
public final class SecureBytes: @unchecked Sendable {
    
 // MARK: - Properties
    
    private let pointer: UnsafeMutableRawPointer
    private let count: Int
    private let accessLock = NSRecursiveLock()
    
    public typealias WipingFunction = @Sendable (UnsafeMutableRawPointer, Int) -> Void

#if DEBUG || SKYBRIDGE_TESTING
    private final class WipingFunctionStorage: @unchecked Sendable {
        private let lock = NSLock()
        private var function: WipingFunction

        init(function: @escaping WipingFunction) {
            self.function = function
        }

        func load() -> WipingFunction {
            lock.lock()
            defer { lock.unlock() }
            return function
        }

        func store(_ function: @escaping WipingFunction) {
            lock.lock()
            self.function = function
            lock.unlock()
        }
    }

    private static let wipingFunctionStorage = WipingFunctionStorage { pointer, count in
        secureZero(pointer, count)
    }

    /// Test-only zeroization probe. Access is synchronized so concurrently scheduled
    /// test code cannot race the function storage itself.
    public static var wipingFunction: WipingFunction {
        get { wipingFunctionStorage.load() }
        set { wipingFunctionStorage.store(newValue) }
    }
#else
    /// Production zeroization entry point shared by in-module crypto providers.
    /// It is immutable in ordinary Release builds, so callers cannot replace the
    /// secure wipe implementation at runtime.
    internal static let wipingFunction: WipingFunction = { pointer, count in
        secureZero(pointer, count)
    }
#endif
    
 // MARK: - Initialization
    
 /// 创建指定大小的安全字节容器（初始化为零）
 /// - Parameter count: 字节数
    public init(count: Int) {
        precondition(count >= 0, "SecureBytes count must not be negative")
        self.count = count
 // 至少分配 1 字节避免空分配问题
        let allocSize = max(count, 1)
        self.pointer = UnsafeMutableRawPointer.allocate(
            byteCount: allocSize,
            alignment: MemoryLayout<UInt8>.alignment
        )
 // 初始化为零
        if count > 0 {
            pointer.initializeMemory(as: UInt8.self, repeating: 0, count: count)
        }
    }
    
 /// 从 Data 创建安全字节容器
 /// - Parameter data: 源数据（会被复制到安全内存）
    public init(data: Data) {
        self.count = data.count
 // 至少分配 1 字节避免空分配问题
        let allocSize = max(data.count, 1)
        self.pointer = UnsafeMutableRawPointer.allocate(
            byteCount: allocSize,
            alignment: MemoryLayout<UInt8>.alignment
        )
 // 安全处理空 Data
        if data.count > 0 {
            data.withUnsafeBytes { src in
                guard let base = src.baseAddress else { return }
                pointer.copyMemory(from: base, byteCount: data.count)
            }
        }
    }
    
 /// 从字节数组创建安全字节容器
 /// - Parameter bytes: 源字节数组
    public init(bytes: [UInt8]) {
        self.count = bytes.count
        let allocSize = max(bytes.count, 1)
        self.pointer = UnsafeMutableRawPointer.allocate(
            byteCount: allocSize,
            alignment: MemoryLayout<UInt8>.alignment
        )
        if bytes.count > 0 {
            bytes.withUnsafeBytes { src in
                guard let base = src.baseAddress else { return }
                pointer.copyMemory(from: base, byteCount: bytes.count)
            }
        }
    }
    
    deinit {
        if count > 0 {
            Self.wipe(pointer, count: count)
        }
        pointer.deallocate()
    }
    
 // MARK: - Public API
    
 /// 字节数
    public var byteCount: Int {
        count
    }
    
 /// 是否为空
    public var isEmpty: Bool {
        count == 0
    }
    
    /// 导出为 Data（会创建独立副本）。
    /// 返回值不依赖 SecureBytes 的生命周期，也不受其清零保护。
    public var data: Data {
        copyData()
    }

    /// 导出为具有独立所有权的 Data 副本。
    public func copyData() -> Data {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard count > 0 else { return Data() }
        return Data(bytes: pointer, count: count)
    }
    
 /// 安全访问字节（只读）
    /// - Parameter body: 访问闭包
    /// - Returns: 闭包返回值
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        accessLock.lock()
        defer { accessLock.unlock() }
        return try body(UnsafeRawBufferPointer(start: pointer, count: count))
    }
    
 /// 安全访问字节（可写）
    /// - Parameter body: 访问闭包
    /// - Returns: 闭包返回值
    public func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        accessLock.lock()
        defer { accessLock.unlock() }
        return try body(UnsafeMutableRawBufferPointer(start: pointer, count: count))
    }
    
    /// 手动擦除（不等待 deinit）
    public func zeroize() {
        accessLock.lock()
        defer { accessLock.unlock() }
        if count > 0 {
            Self.wipe(pointer, count: count)
        }
    }

    private static func wipe(_ pointer: UnsafeMutableRawPointer, count: Int) {
        wipingFunction(pointer, count)
    }
}

extension SecureBytes: ContiguousBytes {}

// MARK: - Secure Zero Implementation

/// 安全擦除函数
///
/// 使用 memset_s（C11 标准）或 bzero + 内存屏障
/// 确保擦除不被编译器优化掉
#if canImport(Darwin)
import Darwin

/// 安全擦除内存
/// - Parameters:
/// - ptr: 内存指针
/// - count: 字节数
private func secureZero(_ ptr: UnsafeMutableRawPointer, _ count: Int) {
    let symbols = SecureZeroSymbols.shared
    if let fn = symbols.explicitBzero {
        fn(ptr, count)
        return
    }
    if let fn = symbols.memsetS {
        _ = fn(ptr, count, 0, count)
        return
    }
    let bytes = ptr.assumingMemoryBound(to: UInt8.self)
    for i in 0..<count {
        bytes[i] = 0
    }
    withExtendedLifetime(ptr) { _ in }
}

private typealias ExplicitBzeroFn = @convention(c) (UnsafeMutableRawPointer?, Int) -> Void
private typealias MemsetSFn = @convention(c) (UnsafeMutableRawPointer?, Int, Int32, Int) -> Int32

/// `dlopen(nil, ...)` acquires a process-image handle. Keep exactly one handle for
/// the process lifetime so secure wipes do not repeatedly acquire and leak handles.
private final class SecureZeroSymbols: @unchecked Sendable {
    static let shared = SecureZeroSymbols()

    let explicitBzero: ExplicitBzeroFn?
    let memsetS: MemsetSFn?
    private let processHandle: UnsafeMutableRawPointer?

    private init() {
        let handle = dlopen(nil, RTLD_NOW)
        processHandle = handle
        if let handle {
            explicitBzero = dlsym(handle, "explicit_bzero").map {
                unsafeBitCast($0, to: ExplicitBzeroFn.self)
            }
            memsetS = dlsym(handle, "memset_s").map {
                unsafeBitCast($0, to: MemsetSFn.self)
            }
        } else {
            explicitBzero = nil
            memsetS = nil
        }
    }
}

#else

/// Fallback 安全擦除（非 Darwin 平台）
/// 使用 volatile 语义尽量防止优化
private func secureZero(_ ptr: UnsafeMutableRawPointer, _ count: Int) {
    let bytes = ptr.assumingMemoryBound(to: UInt8.self)
    for i in 0..<count {
 // 逐字节写零
        bytes[i] = 0
    }
 // 内存屏障，尽量防止编译器优化掉
    withExtendedLifetime(ptr) { _ in }
}

#endif

// MARK: - Testing Support

#if DEBUG || SKYBRIDGE_TESTING
/// 测试用擦除追踪器
public final class SecureBytesWipeTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _wipeCount: Int = 0
    private var _lastWipedSize: Int = 0
    
    public init() {}
    
 /// 擦除调用次数
    public var wipeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _wipeCount
    }
    
 /// 最后一次擦除的大小
    public var lastWipedSize: Int {
        lock.lock()
        defer { lock.unlock() }
        return _lastWipedSize
    }
    
 /// 重置追踪器
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _wipeCount = 0
        _lastWipedSize = 0
    }
    
 /// 创建追踪擦除函数
    public func makeWipingFunction() -> SecureBytes.WipingFunction {
        return { [weak self] ptr, len in
 // 先执行真正的擦除
            secureZero(ptr, len)
 // 再记录
            guard let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self._wipeCount += 1
            self._lastWipedSize = len
        }
    }
}
#endif
