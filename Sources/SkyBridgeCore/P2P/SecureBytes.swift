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
/// - 可注入 wipingFunction 用于测试验证擦除路径
public final class SecureBytes: @unchecked Sendable {
    
 // MARK: - Properties
    
    private let pointer: UnsafeMutableRawPointer
    private let count: Int
    
 /// 可注入的擦除函数（用于测试验证）
 /// 默认使用 secureZero
 /// 使用 nonisolated(unsafe) 因为擦除函数本身是线程安全的
    nonisolated(unsafe) public static var wipingFunction: (UnsafeMutableRawPointer, Int) -> Void = { ptr, len in
        secureZero(ptr, len)
    }
    
 // MARK: - Initialization
    
 /// 创建指定大小的安全字节容器（初始化为零）
 /// - Parameter count: 字节数
    public init(count: Int) {
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
 // 安全擦除 - 使用可注入的擦除函数
        if count > 0 {
            Self.wipingFunction(pointer, count)
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
    
 /// 导出为 Data（会创建副本）
 /// 注意：导出的 Data 不受 SecureBytes 保护
    public var data: Data {
        guard count > 0 else { return Data() }
        return Data(bytes: pointer, count: count)
    }
    
 /// 导出为 Data（不拷贝）
 /// 注意：返回的 Data 依赖 SecureBytes 的生命周期
    public func noCopyData() -> Data {
        guard count > 0 else { return Data() }
        return Data(bytesNoCopy: pointer, count: count, deallocator: .none)
    }
    
 /// 安全访问字节（只读）
 /// - Parameter body: 访问闭包
 /// - Returns: 闭包返回值
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: pointer, count: count))
    }
    
 /// 安全访问字节（可写）
 /// - Parameter body: 访问闭包
 /// - Returns: 闭包返回值
    public func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeMutableRawBufferPointer(start: pointer, count: count))
    }
    
 /// 手动擦除（不等待 deinit）
    public func zeroize() {
        if count > 0 {
            Self.wipingFunction(pointer, count)
        }
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
    if let fn = loadExplicitBzero() {
        fn(ptr, count)
        return
    }
    if let fn = loadMemsetS() {
        _ = fn(ptr, count, 0, count)
        return
    }
    let bytes = ptr.assumingMemoryBound(to: UInt8.self)
    for i in 0..<count {
        bytes[i] = 0
    }
    withExtendedLifetime(ptr) { _ in }
}

#if canImport(Darwin)
private typealias ExplicitBzeroFn = @convention(c) (UnsafeMutableRawPointer?, Int) -> Void
private typealias MemsetSFn = @convention(c) (UnsafeMutableRawPointer?, Int, Int32, Int) -> Int32

private func loadExplicitBzero() -> ExplicitBzeroFn? {
    guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "explicit_bzero") else {
        return nil
    }
    return unsafeBitCast(symbol, to: ExplicitBzeroFn.self)
}

private func loadMemsetS() -> MemsetSFn? {
    guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "memset_s") else {
        return nil
    }
    return unsafeBitCast(symbol, to: MemsetSFn.self)
}
#endif

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

#if DEBUG
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
    public func makeWipingFunction() -> (UnsafeMutableRawPointer, Int) -> Void {
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
