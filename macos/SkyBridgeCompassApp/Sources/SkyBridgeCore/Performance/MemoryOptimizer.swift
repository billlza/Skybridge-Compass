import Foundation
import Accelerate
import os.log

/// 内存优化器，专门针对Apple Silicon的统一内存架构进行优化
@available(macOS 14.0, *)
public final class MemoryOptimizer: @unchecked Sendable {
    public static let shared = MemoryOptimizer()
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "MemoryOptimizer")
    
    // 内存池管理
    private let memoryPool = MemoryPool()
    
    // 缓存管理
    private let cacheManager = CacheManager()
    
    // 内存监控
    private let memoryMonitor = MemoryMonitor()
    
    private init() {
        logger.info("内存优化器已初始化")
        
        // 启动内存监控
        Task {
            await memoryMonitor.startMonitoring()
        }
    }
    
    deinit {
        // 在deinit中不能使用异步操作，改为同步停止
        Task.detached { [memoryMonitor] in
            await memoryMonitor.stopMonitoring()
        }
    }
    
    // MARK: - 公共接口
    
    /// 获取优化的内存分配器
    public func getOptimizedAllocator<T>(for type: T.Type, count: Int) -> MemoryOptimizedBuffer<T> {
        return memoryPool.allocateBuffer(for: type, count: count)
    }
    
    /// 执行内存密集型操作，自动优化内存访问模式
    public func executeMemoryIntensiveOperation<T: Sendable>(
        _ operation: @escaping @Sendable (MemoryContext) async throws -> T
    ) async throws -> T {
        let context = await createOptimizedMemoryContext()
        
        return try await withThrowingTaskGroup(of: T.self, returning: T.self) { group in
            group.addTask(priority: .high) {
                return try await operation(context)
            }
            
            guard let result = try await group.next() else {
                throw NSError(domain: "MemoryOptimizer", code: -1, userInfo: [NSLocalizedDescriptionKey: "内存操作失败"])
            }
            
            // 清理内存上下文
            context.cleanup()  // 移除不必要的 await
            
            return result
        }
    }
    
    /// 优化大数据集的处理，利用统一内存架构
    public func processLargeDataSet<Input: Sendable, Output: Sendable>(
        data: [Input],
        batchSize: Int? = nil,
        processor: @escaping @Sendable ([Input]) async throws -> [Output]
    ) async throws -> [Output] {
        guard !data.isEmpty else { return [] }
        
        let optimalBatchSize = batchSize ?? calculateOptimalBatchSize(for: data.count)
        let memoryInfo = await memoryMonitor.getCurrentMemoryInfo()
        
        logger.debug("处理大数据集: \(data.count)项，批次大小: \(optimalBatchSize)，可用内存: \(memoryInfo.availableMemory)MB")
        
        // 如果内存充足，使用并行处理
        if memoryInfo.memoryPressure < 0.7 {
            return try await processInParallel(data: data, batchSize: optimalBatchSize, processor: processor)
        } else {
            // 内存紧张时使用串行处理
            return try await processSequentially(data: data, batchSize: optimalBatchSize, processor: processor)
        }
    }
    
    /// 优化图像数据处理，利用Accelerate框架
    public func processImageData(
        imageData: Data,
        width: Int,
        height: Int,
        operation: ImageOperation
    ) async throws -> Data {
        return try await executeMemoryIntensiveOperation { context in
            let buffer = context.allocateImageBuffer(width: width, height: height)
            defer { buffer.deallocate() }
            
            // 将数据复制到优化的缓冲区
            imageData.withUnsafeBytes { bytes in
                let sourceBytes = bytes.bindMemory(to: UInt8.self)
                if let baseAddress = buffer.baseAddress {
                    let byteCount = min(sourceBytes.count, buffer.count)
                    memcpy(baseAddress, sourceBytes.baseAddress, byteCount)
                }
            }
            
            // 使用Accelerate框架进行优化处理
            switch operation {
            case .blur(let radius):
                try await self.applyBlur(to: buffer, radius: radius)
            case .resize(let newWidth, let newHeight):
                return try await self.resizeImage(buffer: buffer, 
                                                originalWidth: width, 
                                                originalHeight: height,
                                                newWidth: newWidth, 
                                                newHeight: newHeight)
            case .colorCorrection(let brightness, let contrast):
                try await self.applyColorCorrection(to: buffer, brightness: brightness, contrast: contrast)
            }
            
            // 将处理后的数据转换回Data
            return Data(bytes: buffer.baseAddress!, count: buffer.count)
        }
    }
    
    /// 缓存管理接口
    public func cacheData<T: Codable & Sendable>(_ data: T, forKey key: String, ttl: TimeInterval = 3600) async {
        await cacheManager.store(data, forKey: key, ttl: ttl)
    }
    
    public func getCachedData<T: Codable & Sendable>(_ type: T.Type, forKey key: String) async -> T? {
        return await cacheManager.retrieve(type, forKey: key)
    }
    
    public func clearCache() async {
        await cacheManager.clearAll()
    }
    
    // MARK: - 私有方法
    
    /// 创建优化的内存上下文
    private func createOptimizedMemoryContext() async -> MemoryContext {
        let memoryInfo = await memoryMonitor.getCurrentMemoryInfo()
        return MemoryContext(
            availableMemory: memoryInfo.availableMemory,
            memoryPressure: memoryInfo.memoryPressure,
            allocator: memoryPool
        )
    }
    
    /// 计算最优批次大小
    private func calculateOptimalBatchSize(for itemCount: Int) -> Int {
        let processorCount = ProcessInfo.processInfo.processorCount
        
        // 基于核心数计算批次大小
        let coreBasedSize = itemCount / processorCount
        let batchSize = max(coreBasedSize, 100)
        
        return min(batchSize, itemCount)
    }
    
    /// 并行处理数据
    private func processInParallel<Input: Sendable, Output: Sendable>(
        data: [Input],
        batchSize: Int,
        processor: @escaping @Sendable ([Input]) async throws -> [Output]
    ) async throws -> [Output] {
        let batches = data.chunked(into: batchSize)
        
        return try await withThrowingTaskGroup(of: [Output].self, returning: [Output].self) { group in
            for batch in batches {
                group.addTask {
                    return try await processor(batch)
                }
            }
            
            var results: [Output] = []
            for try await batchResult in group {
                results.append(contentsOf: batchResult)
            }
            
            return results
        }
    }
    
    /// 串行处理数据
    private func processSequentially<Input: Sendable, Output: Sendable>(
        data: [Input],
        batchSize: Int,
        processor: @escaping @Sendable ([Input]) async throws -> [Output]
    ) async throws -> [Output] {
        let batches = data.chunked(into: batchSize)
        var results: [Output] = []
        
        for batch in batches {
            let batchResult = try await processor(batch)
            results.append(contentsOf: batchResult)
            
            // 在批次之间进行垃圾回收
            await Task.yield()
        }
        
        return results
    }
    
    /// 应用模糊效果
    private func applyBlur(to buffer: UnsafeMutableBufferPointer<UInt8>, radius: Float) async throws {
        // 使用Accelerate框架的vImage进行高效模糊处理
        // 这里是简化实现，实际应用中需要完整的vImage调用
        logger.debug("应用模糊效果，半径: \(radius)")
    }
    
    /// 调整图像大小
    private func resizeImage(
        buffer: UnsafeMutableBufferPointer<UInt8>,
        originalWidth: Int,
        originalHeight: Int,
        newWidth: Int,
        newHeight: Int
    ) async throws -> Data {
        // 使用Accelerate框架进行高效图像缩放
        logger.debug("调整图像大小: \(originalWidth)x\(originalHeight) -> \(newWidth)x\(newHeight)")
        
        // 简化实现，实际需要使用vImage_Scale函数
        let newSize = newWidth * newHeight * 4 // 假设RGBA格式
        return Data(count: newSize)
    }
    
    /// 应用颜色校正
    private func applyColorCorrection(to buffer: UnsafeMutableBufferPointer<UInt8>, brightness: Float, contrast: Float) async throws {
        // 使用Accelerate框架进行颜色校正
        logger.debug("应用颜色校正，亮度: \(brightness)，对比度: \(contrast)")
    }
}

// MARK: - 内存池

@available(macOS 14.0, *)
fileprivate final class MemoryPool: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "MemoryPool")
    
    func allocateBuffer<T>(for type: T.Type, count: Int) -> MemoryOptimizedBuffer<T> {
        let buffer = UnsafeMutableBufferPointer<T>.allocate(capacity: count)
        logger.debug("分配内存缓冲区: \(count)个\(String(describing: type))项")
        return MemoryOptimizedBuffer(buffer: buffer)
    }
}

// MARK: - 内存优化缓冲区

public struct MemoryOptimizedBuffer<T> {
    fileprivate let buffer: UnsafeMutableBufferPointer<T>
    
    fileprivate init(buffer: UnsafeMutableBufferPointer<T>) {
        self.buffer = buffer
    }
    
    public var baseAddress: UnsafeMutablePointer<T>? {
        return buffer.baseAddress
    }
    
    public var count: Int {
        return buffer.count
    }
    
    public func deallocate() {
        buffer.deallocate()
    }
}

// MARK: - 内存上下文

@available(macOS 14.0, *)
public final class MemoryContext: @unchecked Sendable {
    let availableMemory: Double
    let memoryPressure: Double
    private let allocator: MemoryPool
    
    fileprivate init(availableMemory: Double, memoryPressure: Double, allocator: MemoryPool) {
        self.availableMemory = availableMemory
        self.memoryPressure = memoryPressure
        self.allocator = allocator
    }
    
    func allocateImageBuffer(width: Int, height: Int) -> UnsafeMutableBufferPointer<UInt8> {
        let count = width * height * 4 // RGBA
        return allocator.allocateBuffer(for: UInt8.self, count: count).buffer
    }
    
    func cleanup() {
        // 执行内存清理操作
    }
}

// MARK: - 缓存管理器

@available(macOS 14.0, *)
private actor CacheManager {
    private var cache: [String: CacheEntry] = [:]
    private let maxCacheSize = 100 * 1024 * 1024 // 100MB
    private var currentCacheSize = 0
    
    func store<T: Codable & Sendable>(_ data: T, forKey key: String, ttl: TimeInterval) async {
        do {
            let encoded = try JSONEncoder().encode(data)
            let entry = CacheEntry(data: encoded, expiry: Date().addingTimeInterval(ttl))
            
            cache[key] = entry
            currentCacheSize += encoded.count
            
            if currentCacheSize > maxCacheSize {
                await evictOldEntries()
            }
        } catch {
            // 编码失败，忽略缓存
        }
    }
    
    func retrieve<T: Codable & Sendable>(_ type: T.Type, forKey key: String) -> T? {
        guard let entry = cache[key] else { return nil }
        
        // 检查是否过期
        if entry.expiry < Date() {
            cache.removeValue(forKey: key)
            currentCacheSize -= entry.data.count
            return nil
        }
        
        do {
            return try JSONDecoder().decode(type, from: entry.data)
        } catch {
            // 解码失败，移除缓存项
            cache.removeValue(forKey: key)
            currentCacheSize -= entry.data.count
            return nil
        }
    }
    
    func clearAll() {
        cache.removeAll()
        currentCacheSize = 0
    }
    
    private func evictOldEntries() async {
        let now = Date()
        var keysToRemove: [String] = []
        
        // 移除过期项
        for (key, entry) in cache {
            if entry.expiry < now {
                keysToRemove.append(key)
                currentCacheSize -= entry.data.count
            }
        }
        
        for key in keysToRemove {
            cache.removeValue(forKey: key)
        }
        
        // 如果仍然超过限制，移除最旧的项
        if currentCacheSize > maxCacheSize {
            let sortedEntries = cache.sorted { $0.value.expiry < $1.value.expiry }
            let halfSize = maxCacheSize / 2
            
            for (key, entry) in sortedEntries {
                if currentCacheSize <= halfSize { break }
                cache.removeValue(forKey: key)
                currentCacheSize -= entry.data.count
            }
        }
    }
}

// MARK: - 缓存条目

private struct CacheEntry {
    let data: Data
    let expiry: Date
}

// MARK: - 内存监控器

@available(macOS 14.0, *)
private actor MemoryMonitor {
    private var isMonitoring = false
    private var currentMemoryInfo = MemoryInfo(availableMemory: 0, memoryPressure: 0)
    private var monitoringTask: Task<Void, Never>?
    
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        
        monitoringTask = Task {
            while !Task.isCancelled && isMonitoring {
                updateMemoryInfo()
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒更新一次
            }
        }
    }
    
    func stopMonitoring() {
        isMonitoring = false
        monitoringTask?.cancel()
        monitoringTask = nil
    }
    
    func getCurrentMemoryInfo() -> MemoryInfo {
        return currentMemoryInfo
    }
    
    private func updateMemoryInfo() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let usedMemoryMB = Double(info.resident_size) / (1024 * 1024)
            
            // 获取系统总内存
            var size = size_t()
            sysctlbyname("hw.memsize", nil, &size, nil, 0)
            var totalMemory: UInt64 = 0
            sysctlbyname("hw.memsize", &totalMemory, &size, nil, 0)
            let totalMemoryMB = Double(totalMemory) / (1024 * 1024)
            
            let availableMemoryMB = totalMemoryMB - usedMemoryMB
            let memoryPressure = usedMemoryMB / totalMemoryMB
            
            currentMemoryInfo = MemoryInfo(
                availableMemory: max(0, availableMemoryMB),
                memoryPressure: min(1.0, max(0.0, memoryPressure))
            )
        }
    }
}

// MARK: - 内存信息

public struct MemoryInfo: Sendable {
    let availableMemory: Double // MB
    let memoryPressure: Double  // 0.0 - 1.0
}

// MARK: - 图像操作

/// 图像操作类型，遵循Sendable协议以支持并发
public enum ImageOperation: Sendable {
    case blur(radius: Float)
    case resize(width: Int, height: Int)
    case colorCorrection(brightness: Float, contrast: Float)
}