import Foundation
import Metal
import os.log

/// 资源生命周期管理器
///
/// 自动管理应用资源的创建、使用和销毁，防止内存泄漏
///
/// 🆕 2025年最佳实践：
/// - ✅ 自动资源追踪
/// - ✅ 弱引用管理
/// - ✅ 资源池模式
/// - ✅ 内存压力响应
/// - ✅ 资源使用统计
///
/// ⚡ Swift 6.2.1 特性：使用 actor 确保线程安全
@available(macOS 14.0, *)
public actor ResourceLifecycleManager {
    
 // MARK: - 单例
    
    public static let shared = ResourceLifecycleManager()
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "ResourceManager")
    
 // MARK: - 资源追踪
    
 /// 资源条目
    private struct ResourceEntry {
        weak var resource: AnyObject?
        let type: String
        let createdAt: Date
        let size: Int64
        var lastAccessed: Date
    }
    
 /// 已追踪的资源
    private var trackedResources: [ObjectIdentifier: ResourceEntry] = [:]
    
 /// Metal 纹理池
    private var texturePool: [TextureDescriptor: [MTLTexture]] = [:]
    
 /// 纹理描述符（用作字典键）
    private struct TextureDescriptor: Hashable {
        let width: Int
        let height: Int
        let pixelFormat: MTLPixelFormat
    }
    
 // MARK: - 统计信息
    
    private var totalAllocations: Int = 0
    private var totalDeallocations: Int = 0
    private var peakResourceCount: Int = 0
    
 // MARK: - 初始化
    
    private init() {
        logger.info("✅ 资源生命周期管理器已初始化")
        
 // 监听内存警告（异步启动）
        Task {
            await setupMemoryPressureMonitoring()
        }
    }
    
 // MARK: - 资源注册
    
 /// 注册资源以进行追踪
 ///
 /// - Parameters:
 /// - resource: 要追踪的资源对象
 /// - type: 资源类型描述
 /// - size: 估计的内存大小（字节）
    public func register<T: AnyObject>(
        _ resource: T,
        type: String,
        estimatedSize: Int64 = 0
    ) {
        let id = ObjectIdentifier(resource)
        let entry = ResourceEntry(
            resource: resource,
            type: type,
            createdAt: Date(),
            size: estimatedSize,
            lastAccessed: Date()
        )
        
        trackedResources[id] = entry
        totalAllocations += 1
        
 // 更新峰值
        if trackedResources.count > peakResourceCount {
            peakResourceCount = trackedResources.count
        }
        
        logger.debug("📝 注册资源[\(type)]：\(String(describing: id)), 大小：\(estimatedSize) 字节")
    }
    
 /// 注销资源
    public func unregister<T: AnyObject>(_ resource: T) {
        let id = ObjectIdentifier(resource)
        
        if let entry = trackedResources.removeValue(forKey: id) {
            totalDeallocations += 1
            logger.debug("🗑️ 注销资源[\(entry.type)]：\(String(describing: id))")
        }
    }
    
 /// 更新资源访问时间
    public func touch<T: AnyObject>(_ resource: T) {
        let id = ObjectIdentifier(resource)
        trackedResources[id]?.lastAccessed = Date()
    }
    
 // MARK: - Metal 纹理池
    
 /// 从池中获取或创建纹理
 ///
 /// 纹理池可以重用已释放的纹理，减少内存分配开销
    public func acquireTexture(
        device: MTLDevice,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = .bgra8Unorm
    ) -> MTLTexture? {
        let descriptor = TextureDescriptor(
            width: width,
            height: height,
            pixelFormat: pixelFormat
        )
        
 // 尝试从池中获取
        if var pool = texturePool[descriptor], !pool.isEmpty {
            let texture = pool.removeLast()
            texturePool[descriptor] = pool
            
            logger.debug("♻️ 从纹理池复用纹理: \(width)x\(height)")
            return texture
        }
        
 // 创建新纹理
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        textureDescriptor.storageMode = .private
        
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            logger.error("❌ 创建纹理失败")
            return nil
        }
        
 // 注册到追踪系统
        let sizeInBytes = Int64(width * height * 4) // BGRA = 4 bytes per pixel
        register(texture, type: "MTLTexture", estimatedSize: sizeInBytes)
        
        logger.debug("🆕 创建新纹理: \(width)x\(height), 大小: \(sizeInBytes) 字节")
        return texture
    }
    
 /// 将纹理归还到池中
    public func releaseTexture(_ texture: MTLTexture) {
        let descriptor = TextureDescriptor(
            width: texture.width,
            height: texture.height,
            pixelFormat: texture.pixelFormat
        )
        
        texturePool[descriptor, default: []].append(texture)
        logger.debug("📥 纹理已归还到池: \(texture.width)x\(texture.height)")
    }
    
 /// 清空纹理池
    public func clearTexturePool() {
        let totalTextures = texturePool.values.reduce(0) { $0 + $1.count }
        texturePool.removeAll()
        logger.info("🧹 纹理池已清空：释放 \(totalTextures) 个纹理")
    }
    
 // MARK: - 内存压力管理
    
    private func setupMemoryPressureMonitoring() {
 // 使用 DispatchSource 监听内存压力
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        
        source.setEventHandler {
            Task { @MainActor [weak self] in
                await self?.handleMemoryPressure()
            }
        }
        
        source.resume()
        logger.info("📊 内存压力监控已启动")
    }
    
    private func handleMemoryPressure() {
        logger.warning("⚠️ 检测到内存压力，开始清理资源")
        
 // 清理过期资源
        cleanupStaleResources()
        
 // 清空纹理池
        clearTexturePool()
        
 // 强制垃圾回收（仅在调试时）
        #if DEBUG
        logger.debug("🗑️ 触发垃圾回收")
        #endif
    }
    
 /// 清理长时间未使用的资源
    public func cleanupStaleResources(maxAge: TimeInterval = 600) {
        let now = Date()
        var removedCount = 0
        
        for (id, entry) in trackedResources {
 // 如果资源已被释放，从追踪中移除
            if entry.resource == nil {
                trackedResources.removeValue(forKey: id)
                removedCount += 1
                continue
            }
            
 // 如果资源长时间未访问，记录警告
            let idleTime = now.timeIntervalSince(entry.lastAccessed)
            if idleTime > maxAge {
                logger.warning("⚠️ 资源[\(entry.type)]长时间未使用: \(String(format: "%.0f", idleTime))秒")
            }
        }
        
        if removedCount > 0 {
            logger.info("🧹 清理了 \(removedCount) 个已释放的资源引用")
        }
    }
    
 // MARK: - 统计和诊断
    
 /// 获取资源使用统计
    public func getStatistics() -> ResourceStatistics {
 // 计算总内存使用
        let totalMemory = trackedResources.values.reduce(Int64(0)) { $0 + $1.size }
        
 // 按类型分组
        var resourcesByType: [String: Int] = [:]
        for entry in trackedResources.values {
            resourcesByType[entry.type, default: 0] += 1
        }
        
 // 找出最大的资源
        let largestResources = trackedResources.values
            .sorted { $0.size > $1.size }
            .prefix(5)
            .map { ResourceInfo(type: $0.type, size: $0.size, age: Date().timeIntervalSince($0.createdAt)) }
        
        return ResourceStatistics(
            totalResources: trackedResources.count,
            totalMemoryBytes: totalMemory,
            totalAllocations: totalAllocations,
            totalDeallocations: totalDeallocations,
            peakResourceCount: peakResourceCount,
            resourcesByType: resourcesByType,
            largestResources: largestResources,
            texturePoolSize: texturePool.values.reduce(0) { $0 + $1.count }
        )
    }
    
    public struct ResourceStatistics {
        public let totalResources: Int
        public let totalMemoryBytes: Int64
        public let totalAllocations: Int
        public let totalDeallocations: Int
        public let peakResourceCount: Int
        public let resourcesByType: [String: Int]
        public let largestResources: [ResourceInfo]
        public let texturePoolSize: Int
        
        public var totalMemoryMB: Double {
            Double(totalMemoryBytes) / (1024 * 1024)
        }
    }
    
    public struct ResourceInfo {
        public let type: String
        public let size: Int64
        public let age: TimeInterval
        
        public var sizeMB: Double {
            Double(size) / (1024 * 1024)
        }
    }
    
 /// 打印资源使用报告
    public func printReport() {
        let stats = getStatistics()
        
        logger.info("📊 资源使用报告")
        logger.info("   当前资源数: \(stats.totalResources)")
        logger.info("   总内存使用: \(String(format: "%.2f", stats.totalMemoryMB)) MB")
        logger.info("   峰值资源数: \(stats.peakResourceCount)")
        logger.info("   总分配次数: \(stats.totalAllocations)")
        logger.info("   总释放次数: \(stats.totalDeallocations)")
        logger.info("   纹理池大小: \(stats.texturePoolSize)")
        
        if !stats.resourcesByType.isEmpty {
            logger.info("   按类型分布:")
            for (type, count) in stats.resourcesByType.sorted(by: { $0.value > $1.value }) {
                logger.info("     - \(type): \(count)")
            }
        }
        
        if !stats.largestResources.isEmpty {
            logger.info("   最大资源 (前5):")
            for (index, resource) in stats.largestResources.enumerated() {
                logger.info("     \(index + 1). \(resource.type): \(String(format: "%.2f", resource.sizeMB)) MB, 存活 \(String(format: "%.0f", resource.age))秒")
            }
        }
    }
}

// MARK: - 自动资源管理协议

/// 可自动管理的资源协议
@available(macOS 14.0, *)
public protocol ManagedResource: AnyObject {
 /// 资源类型名称
    var resourceType: String { get }
    
 /// 估计的内存大小
    var estimatedSize: Int64 { get }
    
 /// 清理资源
    func cleanup()
}

extension ManagedResource where Self: AnyObject & Sendable {
 /// 自动注册资源（需要从异步上下文调用）
    public func autoRegister() async {
        await ResourceLifecycleManager.shared.register(
            self,
            type: resourceType,
            estimatedSize: estimatedSize
        )
    }
    
 /// 自动注销资源（需要从异步上下文调用）
    public func autoUnregister() async {
        cleanup()
        await ResourceLifecycleManager.shared.unregister(self)
    }
}

// MARK: - 使用示例

/*
 ## 使用示例
 
 ### 1. 注册和追踪资源
 
 ```swift
 let texture = device.makeTexture(descriptor: descriptor)
 await ResourceLifecycleManager.shared.register(
     texture,
     type: "RenderTexture",
     estimatedSize: 1920 * 1080 * 4
 )
 ```
 
 ### 2. 使用纹理池
 
 ```swift
 // 获取纹理
 if let texture = await ResourceLifecycleManager.shared.acquireTexture(
     device: device,
     width: 1920,
     height: 1080
 ) {
 // 使用纹理...
     
 // 归还纹理
     await ResourceLifecycleManager.shared.releaseTexture(texture)
 }
 ```
 
 ### 3. 定期清理
 
 ```swift
 // 清理长时间未使用的资源
 await ResourceLifecycleManager.shared.cleanupStaleResources()
 
 // 打印资源使用报告
 await ResourceLifecycleManager.shared.printReport()
 ```
 
 ### 4. 实现 ManagedResource 协议
 
 ```swift
 class MyResource: ManagedResource {
     var resourceType: String { "MyCustomResource" }
     var estimatedSize: Int64 { 1024 * 1024 } // 1 MB
     
     init() {
         autoRegister()
     }
     
     func cleanup() {
 // 清理逻辑
     }
     
     deinit {
         autoUnregister()
     }
 }
 ```
 */

