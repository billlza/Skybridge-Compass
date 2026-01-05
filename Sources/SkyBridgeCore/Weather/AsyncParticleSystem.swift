//
// AsyncParticleSystem.swift
// SkyBridgeCore
//
// 异步粒子系统 - 避免主线程阻塞
// 使用Actor隔离、双缓冲、对象池、空间分区
// Created: 2025-10-19
//

import Foundation
import simd

// MARK: - 📦 对象池（避免频繁创建）

/// 通用粒子结构（值类型，高性能）
public struct UniversalParticle: Sendable {
    public var position: SIMD2<Float>
    public var velocity: SIMD2<Float>
    public var size: Float
    public var lifetime: Float
    public var maxLifetime: Float
    public var opacity: Float
    public var rotation: Float
    public var layer: Int
    public var customData: SIMD4<Float>  // 自定义数据
    
    public init() {
        self.position = SIMD2<Float>(0, 0)
        self.velocity = SIMD2<Float>(0, 0)
        self.size = 1.0
        self.lifetime = 0
        self.maxLifetime = 1.0
        self.opacity = 1.0
        self.rotation = 0
        self.layer = 0
        self.customData = SIMD4<Float>(0, 0, 0, 0)
    }
}

/// 粒子快照（不可变，用于渲染）
public struct ParticleSnapshot: Sendable {
    public let particles: [UniversalParticle]
    public let timestamp: TimeInterval
    
    public init(particles: [UniversalParticle], timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.particles = particles
        self.timestamp = timestamp
    }
}

// MARK: - 🎯 空间分区系统

/// 空间网格（加速查询）
actor SpatialGrid {
    private var cells: [Int: [Int]] = [:]  // cellIndex -> particleIndices
    private let cellSize: Float = 200.0
    private var gridWidth: Int = 10
    private var gridHeight: Int = 10
    
    func updateGrid(particles: [UniversalParticle], screenSize: CGSize) {
        cells.removeAll(keepingCapacity: true)
        
        gridWidth = Int(screenSize.width / CGFloat(cellSize)) + 1
        gridHeight = Int(screenSize.height / CGFloat(cellSize)) + 1
        
        for (index, particle) in particles.enumerated() {
            let cellIndex = getCellIndex(position: particle.position)
            cells[cellIndex, default: []].append(index)
        }
    }
    
    private func getCellIndex(position: SIMD2<Float>) -> Int {
        let x = max(0, min(gridWidth - 1, Int(position.x / cellSize)))
        let y = max(0, min(gridHeight - 1, Int(position.y / cellSize)))
        return y * gridWidth + x
    }
    
    func getVisibleParticleIndices(viewport: CGRect) -> [Int] {
        let minCellX = max(0, Int(viewport.minX / CGFloat(cellSize)))
        let maxCellX = min(gridWidth - 1, Int(viewport.maxX / CGFloat(cellSize)))
        let minCellY = max(0, Int(viewport.minY / CGFloat(cellSize)))
        let maxCellY = min(gridHeight - 1, Int(viewport.maxY / CGFloat(cellSize)))
        
        var indices: [Int] = []
        for y in minCellY...maxCellY {
            for x in minCellX...maxCellX {
                let cellIndex = y * gridWidth + x
                if let cellIndices = cells[cellIndex] {
                    indices.append(contentsOf: cellIndices)
                }
            }
        }
        
        return indices
    }
}

// MARK: - 🔄 双缓冲粒子系统Actor

/// 异步粒子系统（后台更新，主线程渲染）
public actor AsyncParticleSystemActor {
 // 双缓冲
    private var bufferA: [UniversalParticle] = []
    private var bufferB: [UniversalParticle] = []
    private var currentBuffer: Int = 0  // 0=A, 1=B
    
 // 空间分区
    private let spatialGrid = SpatialGrid()
    
 // 配置
    private let maxParticles: Int
    private var activeCount: Int = 0
    
 // 统计
    private var updateTime: TimeInterval = 0
    
    public init(maxParticles: Int) {
        self.maxParticles = maxParticles
        
 // 预分配缓冲区
        bufferA.reserveCapacity(maxParticles)
        bufferB.reserveCapacity(maxParticles)
        
        for _ in 0..<maxParticles {
            bufferA.append(UniversalParticle())
            bufferB.append(UniversalParticle())
        }
    }
    
 /// 添加粒子（从对象池获取）
    public func spawnParticle(_ particle: UniversalParticle) {
        guard activeCount < maxParticles else { return }
        
        if currentBuffer == 0 {
            bufferA[activeCount] = particle
        } else {
            bufferB[activeCount] = particle
        }
        activeCount += 1
    }
    
 /// 异步更新（在后台线程执行）
    public func update(deltaTime: Float, screenSize: CGSize, windField: ((SIMD2<Float>) -> SIMD2<Float>)?) async {
        let startTime = Date().timeIntervalSince1970
        
 // 在当前actor上下文中更新（后台线程）
        var writeBuffer = currentBuffer == 0 ? bufferA : bufferB
        
        var newActiveCount = 0
        for i in 0..<activeCount {
            var particle = writeBuffer[i]
            
 // 更新生命周期
            particle.lifetime += deltaTime
            if particle.lifetime > particle.maxLifetime {
                continue  // 跳过过期粒子
            }
            
 // 应用风力
            if let windField = windField {
                let wind = windField(particle.position)
                particle.velocity += wind * deltaTime
            }
            
 // 更新位置
            particle.position += particle.velocity * deltaTime
            
 // 边界检查
            if particle.position.y > Float(screenSize.height) + 100 ||
               particle.position.x < -100 ||
               particle.position.x > Float(screenSize.width) + 100 {
                continue  // 移除越界粒子
            }
            
 // 写回存活的粒子
            writeBuffer[newActiveCount] = particle
            newActiveCount += 1
        }
        
        activeCount = newActiveCount
        
 // 更新缓冲区
        if currentBuffer == 0 {
            bufferA = writeBuffer
        } else {
            bufferB = writeBuffer
        }
        
 // 更新空间分区
        let validParticles = Array(writeBuffer[0..<activeCount])
        await spatialGrid.updateGrid(particles: validParticles, screenSize: screenSize)
        
        updateTime = Date().timeIntervalSince1970 - startTime
    }
    
 /// 交换缓冲区（在主线程调用）
    nonisolated public func swapBuffers() {
        Task {
            await _swapBuffers()
        }
    }
    
    private func _swapBuffers() {
        currentBuffer = currentBuffer == 0 ? 1 : 0
    }
    
 /// 获取渲染快照（主线程安全）
    public func getSnapshot() -> ParticleSnapshot {
 // 读取当前非活动缓冲区（稳定的）
        let readBuffer = currentBuffer == 0 ? bufferB : bufferA
        let snapshot = Array(readBuffer[0..<activeCount])
        
        return ParticleSnapshot(particles: snapshot)
    }
    
 /// 获取可见粒子快照（带视锥剔除）
    public func getVisibleSnapshot(viewport: CGRect) async -> ParticleSnapshot {
        let indices = await spatialGrid.getVisibleParticleIndices(viewport: viewport)
        
        let readBuffer = currentBuffer == 0 ? bufferB : bufferA
        let visibleParticles = indices.compactMap { index in
            index < activeCount ? readBuffer[index] : nil
        }
        
        return ParticleSnapshot(particles: visibleParticles)
    }
    
 /// 性能统计
    public func getStats() -> (activeCount: Int, updateTimeMs: Double) {
        return (activeCount, updateTime * 1000)
    }
}

// MARK: - 🎨 噪声缓存Actor

/// Perlin噪声缓存（避免重复计算）
public actor NoiseCacheActor {
    private var cache: [SIMD3<Int16>: Float] = [:]
    private let maxCacheSize: Int = 10000
    private let noise: PerlinNoise3D
    
    public init(seed: Int = 42) {
        self.noise = PerlinNoise3D(seed: seed)
    }
    
 /// 获取噪声值（带缓存）
    public func getNoise(x: Float, y: Float, z: Float, octaves: Int = 4) async -> Float {
 // 创建缓存键（量化到0.1精度）
        let key = SIMD3<Int16>(
            Int16(x * 10),
            Int16(y * 10),
            Int16(z * 10)
        )
        
        if let cached = cache[key] {
            return cached
        }
        
 // 在后台计算
        let value = await Task.detached(priority: .utility) { [noise] in
            noise.fbm(x: x, y: y, z: z, octaves: octaves)
        }.value
        
 // 限制缓存大小
        if cache.count >= maxCacheSize {
            cache.removeAll(keepingCapacity: true)
        }
        
        cache[key] = value
        return value
    }
    
 /// 批量预计算噪声（启动时）
    public func precompute(range: ClosedRange<Float>, resolution: Float) async {
        var tasks: [Task<(SIMD3<Int16>, Float), Never>] = []
        
        for x in stride(from: range.lowerBound, through: range.upperBound, by: resolution) {
            for y in stride(from: range.lowerBound, through: range.upperBound, by: resolution) {
                for z in stride(from: range.lowerBound, through: range.upperBound, by: resolution) {
                    let task = Task.detached(priority: .background) { [noise] in
                        let key = SIMD3<Int16>(Int16(x * 10), Int16(y * 10), Int16(z * 10))
                        let value = noise.fbm(x: x, y: y, z: z, octaves: 4)
                        return (key, value)
                    }
                    tasks.append(task)
                }
            }
        }
        
 // 等待所有任务完成
        for task in tasks {
            let (key, value) = await task.value
            cache[key] = value
        }
    }
}

// MARK: - 🎮 粒子系统管理器（SwiftUI友好）

/// 主线程粒子系统管理器
@MainActor
public class AsyncParticleSystemManager: ObservableObject {
    private let actor: AsyncParticleSystemActor
    private let noiseCache: NoiseCacheActor
    
    @Published public private(set) var currentSnapshot: ParticleSnapshot
    @Published public private(set) var stats: String = ""
    
    private var updateTask: Task<Void, Never>?
    private let updateInterval: TimeInterval
    
    public init(maxParticles: Int, targetFPS: Int = 60) {
        self.actor = AsyncParticleSystemActor(maxParticles: maxParticles)
        self.noiseCache = NoiseCacheActor()
        self.currentSnapshot = ParticleSnapshot(particles: [])
        self.updateInterval = 1.0 / Double(targetFPS)
        
 // 启动预计算（后台）
        Task.detached(priority: .background) { [noiseCache] in
            await noiseCache.precompute(range: -10...10, resolution: 0.5)
        }
    }
    
 /// 启动异步更新循环
    public func startUpdateLoop(screenSize: CGSize) {
        stopUpdateLoop()
        
        updateTask = Task.detached(priority: .high) { [weak self] in
            guard let self = self else { return }
            
            var lastTime = Date().timeIntervalSince1970
            
            while !Task.isCancelled {
                let currentTime = Date().timeIntervalSince1970
                let deltaTime = Float(currentTime - lastTime)
                lastTime = currentTime
                
 // 在后台更新粒子
                await self.actor.update(deltaTime: deltaTime, screenSize: screenSize, windField: nil)
                
 // 获取快照并更新UI（切换到主线程）
                let snapshot = await self.actor.getSnapshot()
                let (activeCount, updateTimeMs) = await self.actor.getStats()
                
                await MainActor.run {
                    self.currentSnapshot = snapshot
                    self.stats = "粒子: \(activeCount) | 更新: \(String(format: "%.2f", updateTimeMs))ms"
                }
                
 // 交换缓冲区
                self.actor.swapBuffers()
                
 // 控制帧率
                let elapsed = Date().timeIntervalSince1970 - currentTime
                let sleepTime = max(0, self.updateInterval - elapsed)
                try? await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
            }
        }
    }
    
 /// 停止更新循环
    public func stopUpdateLoop() {
        updateTask?.cancel()
        updateTask = nil
    }
    
 /// 添加粒子
    public func spawn(_ particle: UniversalParticle) {
        Task {
            await actor.spawnParticle(particle)
        }
    }
    
    deinit {
        updateTask?.cancel()
    }
}

