import Foundation
import Metal
import MetalKit
import os.log

/// 统一内存管理器 - 专为Apple Silicon优化的零拷贝数据共享
/// 基于Apple官方文档的统一内存架构最佳实践
@MainActor
public class UnifiedMemoryManager: BaseManager {
    
 // MARK: - 发布属性
    
    @Published public private(set) var memoryUsage: MemoryUsageInfo = MemoryUsageInfo()
    @Published public private(set) var isOptimized: Bool = false
    
 // MARK: - 私有属性
    
    private let device: MTLDevice?
    
 // 内存池管理
    private var sharedBufferPool: [MTLBuffer] = []
    private var privateBufferPool: [MTLBuffer] = []
    private var memorylessTexturePool: [MTLTexture] = []
    
 // 统一内存配置
    private let unifiedMemoryConfig: UnifiedMemoryConfiguration
    
 // 性能监控
    private var allocationHistory: [MemoryAllocation] = []
    private let maxHistoryCount = 100
    
 // MARK: - 初始化
    
    public init(device: MTLDevice? = nil) {
 // 使用系统默认Metal设备或传入的设备（不强制解包）
        self.device = device ?? MTLCreateSystemDefaultDevice()
        self.unifiedMemoryConfig = UnifiedMemoryConfiguration()
        
        super.init(category: "UnifiedMemoryManager")
        
        setupUnifiedMemoryOptimization()
        let devName = self.device?.name ?? "Unknown"
        logger.info("✅ 统一内存管理器初始化完成 - 设备: \(devName)")
    }
    
    public override func performInitialization() async {
 // 统一内存管理器的初始化逻辑
        logger.info("统一内存管理器初始化完成")
    }
    
 // MARK: - 公共方法
    
 /// 创建共享内存缓冲区 - 实现CPU/GPU零拷贝访问
    public func createSharedBuffer(length: Int, options: MTLResourceOptions = []) -> MTLBuffer? {
 // 使用.storageModeShared实现统一内存架构的零拷贝
        guard let device = device else {
            logger.error("❌ 创建共享缓冲区失败 - Metal设备不可用")
            return nil
        }
        let sharedOptions: MTLResourceOptions = [.storageModeShared, .cpuCacheModeWriteCombined]
        
        guard let buffer = device.makeBuffer(length: length, options: sharedOptions) else {
            logger.error("❌ 创建共享缓冲区失败 - 长度: \(length)")
            return nil
        }
        
 // 记录分配信息
        recordAllocation(buffer: buffer, type: .shared)
        
        logger.debug("✅ 创建共享缓冲区成功 - 长度: \(length), 地址: \(String(describing: buffer.contents()))")
        return buffer
    }
    
 /// 创建GPU专用缓冲区 - 用于GPU密集型计算
    public func createPrivateBuffer(length: Int) -> MTLBuffer? {
        guard let device = device else {
            logger.error("❌ 创建私有缓冲区失败 - Metal设备不可用")
            return nil
        }
        let privateOptions: MTLResourceOptions = [.storageModePrivate]
        
        guard let buffer = device.makeBuffer(length: length, options: privateOptions) else {
            logger.error("❌ 创建私有缓冲区失败 - 长度: \(length)")
            return nil
        }
        
        recordAllocation(buffer: buffer, type: .private)
        
        logger.debug("✅ 创建私有缓冲区成功 - 长度: \(length)")
        return buffer
    }
    
 /// 创建无内存纹理 - 利用Apple Silicon的TBDR架构
    public func createMemorylessTexture(descriptor: MTLTextureDescriptor) -> MTLTexture? {
        guard let device = device else {
            logger.error("❌ 创建无内存纹理失败 - Metal设备不可用")
            return nil
        }
 // 在Apple Silicon上使用memoryless存储模式优化tile memory
        descriptor.storageMode = .memoryless
        
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            logger.error("❌ 创建无内存纹理失败")
            return nil
        }
        
        recordAllocation(texture: texture, type: .memoryless)
        
        logger.debug("✅ 创建无内存纹理成功 - 尺寸: \(descriptor.width)x\(descriptor.height)")
        return texture
    }
    
 /// 优化数据传输 - 实现CPU到GPU的零拷贝传输
    public func optimizeDataTransfer<T>(data: [T], to buffer: MTLBuffer) {
        let dataSize = data.count * MemoryLayout<T>.stride
        
 // 检查缓冲区大小
        guard buffer.length >= dataSize else {
            logger.error("❌ 缓冲区大小不足 - 需要: \(dataSize), 可用: \(buffer.length)")
            return
        }
        
 // 使用统一内存架构进行零拷贝传输
        if buffer.storageMode == .shared {
 // 直接内存拷贝，无需CPU/GPU同步
            let bufferPointer = buffer.contents().bindMemory(to: T.self, capacity: data.count)
            data.withUnsafeBufferPointer { dataPointer in
                guard let base = dataPointer.baseAddress else { return }
                bufferPointer.update(from: base, count: data.count)
            }
            logger.debug("✅ 零拷贝数据传输完成 - 大小: \(dataSize) bytes")
        } else {
            logger.warning("⚠️ 缓冲区不支持零拷贝传输 - 存储模式: \(buffer.storageMode.rawValue)")
        }
    }
    
 /// 获取内存使用统计
    public func getMemoryUsageStatistics() -> MemoryUsageInfo {
        updateMemoryUsage()
        return memoryUsage
    }
    
 /// 清理未使用的内存资源
    public func cleanupUnusedResources() {
 // 清理缓冲区池 - 在ARC模式下，我们使用不同的策略来检查资源是否可以清理
        let _ = self.sharedBufferPool.count // 使用下划线忽略未使用的变量
        let _ = self.privateBufferPool.count // 使用下划线忽略未使用的变量
        let _ = self.memorylessTexturePool.count // 使用下划线忽略未使用的变量
        
 // 简单的清理策略：保留最近创建的资源，清理较旧的资源
        if self.sharedBufferPool.count > 10 {
            self.sharedBufferPool.removeFirst(self.sharedBufferPool.count - 10)
        }
        
        if self.privateBufferPool.count > 10 {
            self.privateBufferPool.removeFirst(self.privateBufferPool.count - 10)
        }
        
        if self.memorylessTexturePool.count > 10 {
            self.memorylessTexturePool.removeFirst(self.memorylessTexturePool.count - 10)
        }
        
        logger.info("🧹 内存资源清理完成 - 当前共享缓冲区数量: \(self.sharedBufferPool.count)")
        updateMemoryUsage()
    }
    
 // MARK: - 私有方法
    
    private func setupUnifiedMemoryOptimization() {
 // 检查设备是否支持统一内存架构
        guard let device = device, device.hasUnifiedMemory else {
            logger.warning("⚠️ 设备不支持统一内存架构")
            return
        }
        
 // 配置内存池
        setupMemoryPools()
        
 // 启用优化
        isOptimized = true
        logger.info("✅ 统一内存优化已启用")
    }
    
    private func setupMemoryPools() {
 // 预分配一些常用大小的共享缓冲区
        let commonSizes = [1024, 4096, 16384, 65536, 262144] // 1KB到256KB
        
        for size in commonSizes {
            if let buffer = createSharedBuffer(length: size) {
                self.sharedBufferPool.append(buffer)
            }
        }
        
        logger.info("📦 内存池初始化完成 - 共享缓冲区: \(self.sharedBufferPool.count)")
    }
    
    private func recordAllocation(buffer: MTLBuffer, type: MemoryAllocationType) {
        let allocation = MemoryAllocation(
            id: UUID(),
            type: type,
            size: buffer.length,
            timestamp: Date(),
            resourceType: .buffer
        )
        
        allocationHistory.append(allocation)
        
 // 保持历史记录在限制范围内
        if allocationHistory.count > maxHistoryCount {
            allocationHistory.removeFirst()
        }
        
        updateMemoryUsage()
    }
    
    private func recordAllocation(texture: MTLTexture, type: MemoryAllocationType) {
 // 计算纹理大小：宽度 × 高度 × 每像素字节数
        let bytesPerPixel = 4 // 假设RGBA格式
        let textureSize = texture.width * texture.height * bytesPerPixel
        
        let allocation = MemoryAllocation(
            id: UUID(),
            type: type,
            size: textureSize,
            timestamp: Date(),
            resourceType: .texture
        )
        
        allocationHistory.append(allocation)
        
        if allocationHistory.count > maxHistoryCount {
            allocationHistory.removeFirst()
        }
        
        updateMemoryUsage()
    }
    
    private func updateMemoryUsage() {
        let sharedMemory = allocationHistory
            .filter { $0.type == .shared }
            .reduce(0) { $0 + $1.size }
        
        let privateMemory = allocationHistory
            .filter { $0.type == .private }
            .reduce(0) { $0 + $1.size }
        
        let memorylessMemory = allocationHistory
            .filter { $0.type == .memoryless }
            .reduce(0) { $0 + $1.size }
        
        memoryUsage = MemoryUsageInfo(
            sharedMemoryUsage: sharedMemory,
            privateMemoryUsage: privateMemory,
            memorylessUsage: memorylessMemory,
            totalAllocations: allocationHistory.count,
            isUnifiedMemoryOptimized: isOptimized
        )
    }
}

// MARK: - 数据结构

/// 统一内存配置
private struct UnifiedMemoryConfiguration {
    let enableZeroCopyTransfer: Bool = true
    let preferSharedStorage: Bool = true
    let enableMemorylessTextures: Bool = true
    let poolingEnabled: Bool = true
}

/// 内存分配类型
public enum MemoryAllocationType {
    case shared      // 共享内存 - CPU/GPU零拷贝访问
    case `private`   // GPU专用内存
    case memoryless  // 无内存纹理 - TBDR优化
}

/// 资源类型
public enum ResourceType {
    case buffer
    case texture
}

/// 内存分配记录
public struct MemoryAllocation {
    let id: UUID
    let type: MemoryAllocationType
    let size: Int
    let timestamp: Date
    let resourceType: ResourceType
}

/// 内存使用信息
public struct MemoryUsageInfo {
    let sharedMemoryUsage: Int
    let privateMemoryUsage: Int
    let memorylessUsage: Int
    let totalAllocations: Int
    let isUnifiedMemoryOptimized: Bool
    
    init(sharedMemoryUsage: Int = 0,
         privateMemoryUsage: Int = 0,
         memorylessUsage: Int = 0,
         totalAllocations: Int = 0,
         isUnifiedMemoryOptimized: Bool = false) {
        self.sharedMemoryUsage = sharedMemoryUsage
        self.privateMemoryUsage = privateMemoryUsage
        self.memorylessUsage = memorylessUsage
        self.totalAllocations = totalAllocations
        self.isUnifiedMemoryOptimized = isUnifiedMemoryOptimized
    }
    
 /// 总内存使用量
    var totalMemoryUsage: Int {
        return sharedMemoryUsage + privateMemoryUsage + memorylessUsage
    }
    
 /// 格式化的内存使用量字符串
    var formattedTotalUsage: String {
        return ByteCountFormatter.string(fromByteCount: Int64(totalMemoryUsage), countStyle: .memory)
    }
    
 /// 格式化的共享内存使用量
    var formattedSharedUsage: String {
        return ByteCountFormatter.string(fromByteCount: Int64(sharedMemoryUsage), countStyle: .memory)
    }
}
