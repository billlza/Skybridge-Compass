// macOS-exclusive: this file is built on frameworks that exist only on macOS
// (AppKit / IOKit / ScreenCaptureKit / CoreWLAN / MetalFX / ServiceManagement /
// ApplicationServices). It is excluded from other platforms so SkyBridgeCore can be
// the single shared core for iOS as well. No behaviour changes on macOS.
#if os(macOS)
//
// InteractiveClearSystem.swift
// SkyBridgeCore
//
// 交互式驱散系统 - 鼠标挥动驱散雾/云效果
// 支持速度检测、渐进消散、60秒自动恢复
// Created: 2025-10-19
//

import SwiftUI
import Combine
import os.log
import AppKit

// MARK: - 💨 清空区域模型

/// 渐进式清空区域
public struct DynamicClearZone: Identifiable, Sendable {
    public let id: UUID
    public var center: CGPoint
    public var radius: CGFloat
    public var strength: Float  // 0-1，驱散强度
    public var lifetime: TimeInterval  // 已存在时间
    public let maxLifetime: TimeInterval  // 最大生命周期（60秒）
    public var fadeSpeed: Float  // 恢复速度
    public let createdAt: Date  // 创建时间，用于跨视图桥接时的衰减逻辑

    public init(
        center: CGPoint,
        radius: CGFloat,
        strength: Float = 1.0,
        maxLifetime: TimeInterval = 60.0
    ) {
        self.id = UUID()
        self.center = center
        self.radius = radius
        self.strength = strength
        self.lifetime = 0
        self.maxLifetime = maxLifetime
        self.fadeSpeed = Float(1.0 / maxLifetime)
        self.createdAt = Date()
    }

 /// 更新状态（随时间衰减）
    public mutating func update(deltaTime: TimeInterval) {
        lifetime += deltaTime

 // 渐进恢复：strength从1.0衰减到0
        let progress = Float(lifetime / maxLifetime)
        strength = max(0, 1.0 - progress)

 // 范围也逐渐缩小
        radius = radius * (1.0 - CGFloat(progress) * 0.3)
    }

 /// 是否已过期
    public var isExpired: Bool {
        return lifetime >= maxLifetime
    }
}

// MARK: - 🎯 鼠标轨迹追踪

/// 鼠标轨迹点
struct MouseTrailPoint {
    let position: CGPoint
    let timestamp: TimeInterval
    let velocity: CGFloat  // 速度（像素/秒）
}

/// 鼠标轨迹管理器
@MainActor
public class MouseTrailTracker: ObservableObject {
    @Published var trail: [MouseTrailPoint] = []
    @Published public var currentVelocity: CGFloat = 0
    private let maxTrailLength = 10
    let velocityThreshold: CGFloat = 280  // 挥动触发速度阈值（像素/秒），提高以降低灵敏度
    private var smoothedVelocity: CGFloat = 0     // 指数平滑后的速度

 /// 添加轨迹点
    func addPoint(_ point: CGPoint) {
        let now = Date().timeIntervalSince1970

 // 计算速度（如果有前一个点）
        var velocity: CGFloat = 0
        if let lastPoint = trail.last {
            let deltaTime = now - lastPoint.timestamp
            if deltaTime > 0 {
                let distance = hypot(point.x - lastPoint.position.x, point.y - lastPoint.position.y)
                velocity = distance / CGFloat(deltaTime)
            }
        }

        let newPoint = MouseTrailPoint(
            position: point,
            timestamp: now,
            velocity: velocity
        )

        trail.append(newPoint)

 // 限制轨迹长度
        if trail.count > maxTrailLength {
            trail.removeFirst()
        }
    }

 /// 获取当前平均速度
    func getAverageVelocity() -> CGFloat {
        guard !trail.isEmpty else {
            currentVelocity = 0
            return 0
        }
        let recentTrail = trail.suffix(5)
        let totalVelocity = recentTrail.reduce(0) { $0 + $1.velocity }
        let avgVelocity = totalVelocity / CGFloat(recentTrail.count)
        let alpha: CGFloat = 0.20  // 指数平滑系数，降低尖峰影响
        smoothedVelocity = alpha * avgVelocity + (1 - alpha) * smoothedVelocity
        currentVelocity = smoothedVelocity
        return smoothedVelocity
    }

 /// 检测是否触发"挥动"
    func isSwipeDetected() -> Bool {
 // 需连续3个采样点均超过阈值，且最近150ms内路径累计长度达到门槛，避免短促抖动误触发
        guard trail.count >= 3 else { return false }
        let v1 = trail[trail.count - 1].velocity
        let v2 = trail[trail.count - 2].velocity
        let v3 = trail[trail.count - 3].velocity
        let velocity = getAverageVelocity()

 // 🔧 优化：延长滑动距离要求，从120像素增加到180像素，让驱散需要更明显的滑动动作
 // 最近150ms路径长度累计
        let now = Date().timeIntervalSince1970
        let recentPoints = trail.reversed().prefix(10).filter { now - $0.timestamp <= 0.15 }
        var totalPath: CGFloat = 0

 // Swift 6.2.1 最佳实践：在使用范围前检查边界条件
        guard recentPoints.count >= 2 else {
 // 点数不足，无法计算路径
            return false
        }

        for i in 1..<recentPoints.count {
            let a = recentPoints[i-1].position
            let b = recentPoints[i].position
            totalPath += hypot(b.x - a.x, b.y - a.y)
        }
        let pathOK = totalPath >= 180  // 从120增加到180像素，需要更长的滑动距离

        let consecutiveOK = (v1 > velocityThreshold && v2 > velocityThreshold && v3 > velocityThreshold)
        let avgOK = velocity > (velocityThreshold * 1.1)
        return pathOK && (consecutiveOK || avgOK)
    }

 /// 获取驱散强度（基于速度）
    func getClearStrength() -> Float {
        let velocity = getAverageVelocity()
        let normalized = min(1.0, Float(velocity / 2000))
        return 0.15 + normalized * 0.45
    }

 /// 获取驱散半径（基于速度）
    func getClearRadius() -> CGFloat {
        let velocity = getAverageVelocity()
        let baseRadius: CGFloat = 100
        let velocityMultiplier = min(2.5, velocity / 180)  // 降低半径增长斜率
        let radius = baseRadius + (baseRadius * velocityMultiplier)
        return radius
    }

 /// 清空轨迹
    func clear() {
        trail.removeAll()
    }
}

// MARK: - 🌫️ 交互式清空管理器

@MainActor
public class InteractiveClearManager: ObservableObject, @unchecked Sendable {

 // MARK: - 生命周期管理

 /// 管理器是否已启动
    @Published public private(set) var isStarted: Bool = false

    @Published public private(set) var clearZones: [DynamicClearZone] = []

 /// 🌟 全局透明度（0=完全透明/显示星空，1=完全不透明/显示天气）
    @Published public private(set) var globalOpacity: Double = 1.0

 /// 驱散能量（0-100%）
    @Published public private(set) var disperseEnergy: Double = 0.0

 /// 目标全局透明度（用于平滑过渡）
 /// 说明：通过将不透明度目标值与实际值解耦，避免用户一次挥动造成视觉瞬间跳变。
    private var targetGlobalOpacity: Double = 1.0

 /// 🔥 暴露鼠标追踪器以供调试面板使用
    public var mouseTracker = MouseTrailTracker()

 // 将原先使用 RunLoop 定时器的更新循环改为 Swift 并发 驱动，
 // 目的：避免在 App 进入不同的 RunLoop 模式（如菜单跟踪、滚动等）时 Timer 被停滞，
 // 导致“挥动后不恢复/透明度不更新”等间歇性失效问题。.sleep 不受 RunLoop 模式影响，
 // 可确保在 ARM64/macOS 14+ 环境下稳定运行。
    private var updateTimer: Timer?  // 保留字段以便兼容旧逻辑（不再使用）
    private var updateTask: Task<Void, Never>?  // 新的并发更新任务
    private var lastUpdateTime: TimeInterval = 0
    private var lastDisperseTrigger: TimeInterval = 0
    private var lastBelowThresholdAt: TimeInterval = 0  // 迟滞控制，低于阈值的时间戳
    private var energyWindowStart: TimeInterval = 0      // 能量增益窗口起点（秒）
    private var energyWindowGain: Double = 0             // 窗口内已增加的能量百分比
    private var mouseMoveCount = 0
 // 新增“挥动时间戳队列”，用于在管理器层面统一统计短时间内的挥动次数，
 // 当2秒内达到3次时触发全局Boost，从而所有天气效果共享同一敏感度策略。
    private var swipeTimestamps: [TimeInterval] = []
 // 新增“挥动状态”标记，用于进行上升沿检测（从未触发到触发）。
 // 只有当速度首次越过阈值时才视为一次挥动，从而避免在一次长挥动期间被多次计数。
    private var isSwipeActive: Bool = false
    private var fullClearUntil: TimeInterval = 0
    private var lastMinorZoneTime: TimeInterval = 0

 // 空间分桶（Spatial Hash）用于加速清除强度查询
 // 采用固定网格大小（60px），将清除区域按其圆形包围盒映射到若干桶中，
 // 查询时仅遍历目标点所在桶及其邻域，避免全量遍历，降低CPU占用。
    private let bucketCellSize: CGFloat = 60
    private var zoneBuckets: [Int: [Int]] = [:]

 // 计算桶键（将网格坐标压缩为单个Int）
    private func bucketKey(_ bx: Int, _ by: Int) -> Int { (bx << 20) ^ by }

 // 将指定索引的清除区域映射到桶
    private func assignZoneToBuckets(index: Int) {
        guard index >= 0 && index < clearZones.count else { return }
        let zone = clearZones[index]
        let minBX = Int(floor((zone.center.x - zone.radius) / bucketCellSize))
        let maxBX = Int(floor((zone.center.x + zone.radius) / bucketCellSize))
        let minBY = Int(floor((zone.center.y - zone.radius) / bucketCellSize))
        let maxBY = Int(floor((zone.center.y + zone.radius) / bucketCellSize))
        if minBX <= maxBX && minBY <= maxBY {
            for bx in minBX...maxBX {
                for by in minBY...maxBY {
                    let key = bucketKey(bx, by)
                    zoneBuckets[key, default: []].append(index)
                }
            }
        }
    }

 // 重建所有桶（区域半径随时间变化，使用轻量级每帧重建）
    private func rebuildZoneBuckets() {
        zoneBuckets.removeAll(keepingCapacity: true)
        for i in 0..<clearZones.count { assignZoneToBuckets(index: i) }
    }

 // 🔧 优化：鼠标事件处理频率限制（15 FPS = 66.7ms间隔）
 // 从每帧处理降低到15 FPS，大幅降低CPU占用和能耗
    private var lastMouseProcessTime: TimeInterval = 0
    private let mouseProcessInterval: TimeInterval = 1.0 / 15.0  // 15 FPS处理频率

    private static let logger = OSLog(subsystem: "com.skybridge.compass", category: "InteractiveClear")

    public init() {
        os_log(.info, log: Self.logger, "🌊 InteractiveClearManager 初始化")

 // 自动启动管理器
        Task { @MainActor in
 // start() 为同步方法，直接调用即可；移除不必要的 try/await 与 catch。
            self.start()
            os_log(.info, log: Self.logger, "✅ InteractiveClearManager 自动启动成功")
        }
    }

 // MARK: - 生命周期管理方法

 /// 启动交互式清空管理器
 // 保持与现有调用方兼容（onAppear 等直接调用），
 // 因此 start() 维持同步签名，不要求 await/throws。
    public func start() {
        guard !isStarted else { return }

        os_log(.info, log: Self.logger, "🚀 启动交互式清空管理器")
        isStarted = true

        startUpdateLoop()
    }

 /// 停止交互式清空管理器
    public func stop() {
        guard isStarted else { return }

        os_log(.info, log: Self.logger, "⏹️ 停止交互式清空管理器")
        isStarted = false

        stopUpdateLoop()
    }

 /// 清理资源
    public func cleanup() async {
        os_log(.info, log: Self.logger, "🧹 清理交互式清空管理器资源")

 // 停止更新循环
        stopUpdateLoop()

 // 清理数据
        clearZones.removeAll()
        globalOpacity = 1.0
        disperseEnergy = 0.0
        mouseMoveCount = 0

 // 清理鼠标追踪器
        mouseTracker.clear()

        isStarted = false
    }

    /// 重置“驱散/透明度”相关状态（不停止更新循环）。
    ///
    /// 用途：当天气条件切换时，避免上一种天气被用户驱散到近乎透明后，
    /// 下一种天气（例如多云）继承同一 `globalOpacity` 而“看起来完全没有云”。
    @MainActor
    public func resetDisperseState() {
        // 清空局部区域与空间分桶
        clearZones.removeAll()
        zoneBuckets.removeAll()
        disperseEnergy = 0.0
        targetGlobalOpacity = 1.0
        globalOpacity = 1.0

        // 交互状态
        swipeTimestamps.removeAll()
        isSwipeActive = false
        fullClearUntil = 0
        lastDisperseTrigger = 0
        lastBelowThresholdAt = 0
        energyWindowStart = 0
        energyWindowGain = 0
        lastMinorZoneTime = 0
        mouseMoveCount = 0
        mouseTracker.clear()
    }

 /// 处理鼠标移动
    public func handleMouseMove(_ location: CGPoint) {
 // 🔧 优化：限制鼠标事件处理频率到15 FPS，降低CPU占用和能耗
        let now = Date().timeIntervalSince1970
        guard now - lastMouseProcessTime >= mouseProcessInterval else {
 // 跳过本次处理，但更新轨迹点（用于速度计算）
            mouseTracker.addPoint(location)
            return
        }
        lastMouseProcessTime = now

        mouseMoveCount += 1
        mouseTracker.addPoint(location)

 // 🔥 强制调试：每次鼠标移动都打印（前10次）
        #if DEBUG
        if mouseMoveCount <= 10 {
            os_log(.debug, log: Self.logger, "🖱️🔥 鼠标移动事件 #%d: (%d, %d) - 管理器已启动: %@",
                   mouseMoveCount, Int(location.x), Int(location.y), isStarted ? "是" : "否")
        }

 // 🔥 调试：每10次打印一次鼠标位置
        if mouseMoveCount % 10 == 0 {
            let velocity = mouseTracker.getAverageVelocity()
            os_log(.debug, log: Self.logger, "🖱️ 鼠标移动 #%d: (%d, %d), 速度=%.1f",
                   mouseMoveCount, Int(location.x), Int(location.y), Double(velocity))
        }

 // 添加调试日志
        if mouseMoveCount % 50 == 0 {
            SkyBridgeLogger.ui.debugOnly("🖱️ Mouse move detected at: (\(location.x), \(location.y))")
        }
        #endif

 // 检测挥动手势（上升沿触发，每次约33%能量）
        let velocity = mouseTracker.getAverageVelocity()
        let nowTime = Date().timeIntervalSince1970
        if Double(velocity) < Double(mouseTracker.velocityThreshold) {
            lastBelowThresholdAt = nowTime
        }
        let swipeNow = mouseTracker.isSwipeDetected()
        if swipeNow && !isSwipeActive {
            let now = nowTime
            let minInterval = 0.18
            let highVelocity = 320.0
 // 迟滞要求——必须低于阈值至少120ms后才允许下一次触发
            let hysteresisOK = (now - lastBelowThresholdAt) >= 0.12
 // 间隔与高速豁免控制
            let intervalOK = (now - lastDisperseTrigger) > minInterval || Double(velocity) >= highVelocity
            if !(hysteresisOK && intervalOK) {
                #if DEBUG
                os_log(.debug, log: Self.logger, "⏱️ 迟滞/间隔未满足，忽略当前抖动: 低阈值间隔=%.2f s, 触发间隔=%.2f s", now - lastBelowThresholdAt, now - lastDisperseTrigger)
                #endif
                return
            }
            lastDisperseTrigger = now

 // 记录一次挥动时间戳（上升沿），并仅保留最近2秒窗口
            swipeTimestamps.append(now)
            swipeTimestamps = swipeTimestamps.filter { now - $0 <= 2.0 }

 // 适配“三次渐进驱散”策略（与其他天气效果一致）：
 // 第一次挥动 -> 35%，第二次 -> 70%，第三次 -> 100%。
 // 为了避免能量在阶段之间倒退，这里采用“就高不就低”的策略，将能量提升到对应阶段的里程碑值。
            let waveCount = min(3, swipeTimestamps.count)
            let milestones: [Double] = [0.0, 35.0, 70.0, 100.0]
            let targetEnergy = milestones[waveCount]
 // 能量增益窗口控制——1.2秒内最多增加70%，避免“一秒到100%”
            if now - energyWindowStart > 1.2 {
                energyWindowStart = now
                energyWindowGain = 0
            }
            let delta = max(0.0, targetEnergy - disperseEnergy)
            let remainingCap = max(0.0, 70.0 - energyWindowGain)
            let applyDelta = min(delta, remainingCap)
            disperseEnergy += applyDelta
            energyWindowGain += applyDelta

 // 更新全局透明度目标（globalOpacity = 1 - 能量）
            updateGlobalOpacity()

 // 创建局部清空区域（用于局部效果），半径与速度相关但不影响能量增量
            createClearZone(at: location)

            #if DEBUG
        SkyBridgeLogger.ui.debugOnly("🌪️✅ 挥动触发（上升沿）！ 速度=\(String(format: "%.1f", Double(velocity)))px/s 阶段=\(waveCount)/3 能量里程碑=\(String(format: "%.1f", targetEnergy))% 目标透明度=\(String(format: "%.1f", targetGlobalOpacity * 100))%")
            os_log(.debug, log: Self.logger, "🌊 挥动（上升沿）！速度=%.1f, 阶段=%d/3, 能量=%.1f%%, 目标透明度=%.1f%%, 清空区域数=%d",
                   Double(velocity), waveCount, disperseEnergy, targetGlobalOpacity * 100, clearZones.count)

            if let lastZone = clearZones.last {
                SkyBridgeLogger.ui.debugOnly("🎯 Created clear zone at (\(lastZone.center.x), \(lastZone.center.y)) with radius \(lastZone.radius)")
            }
            #endif

 // 三次挥动Boost：2秒内累计3次挥动后触发（能量直接提升到100%，全局透明度目标置为0，走平滑插值）
            if waveCount >= 3 {
                swipeTimestamps.removeAll()
                triggerTripleWaveBoost()
                #if DEBUG
                os_log(.debug, log: Self.logger, "🚀 三次挥动Boost触发：能量=100%，按一阶响应平滑趋近全透明")
                #endif
            }
            else if waveCount >= 2 {
                if let first = swipeTimestamps.first, now - first <= 1.6, velocity >= 120 {
                    swipeTimestamps.removeAll()
                    triggerTripleWaveBoost()
                    #if DEBUG
                    os_log(.debug, log: Self.logger, "🚀 高速双次挥动触发彻底驱散")
                    #endif
                }
            }
        } else {
            let now = Date().timeIntervalSince1970
            if now - lastMinorZoneTime > 0.15 {
                let strength = max(0.3, mouseTracker.getClearStrength() * 0.6)
                let velocitySnapshot = mouseTracker.getAverageVelocity()
                var radius = max(120.0, mouseTracker.getClearRadius() * 0.4)
                if velocitySnapshot <= 0 {
                    radius = max(radius, 180.0)
                }
 // 同点+低速门闩，避免静止时重复追加造成性能负担
                if let last = clearZones.last {
                    let dx = location.x - last.center.x
                    let dy = location.y - last.center.y
                    let distance = hypot(dx, dy)
                    let samePoint = distance < 2.0
                    let lowVelocity = velocitySnapshot < 5.0
                    if samePoint && lowVelocity {
 // 就地更新最后一个区域，轻微增强并刷新生命周期，避免append
                        var updated = last
 // 半径保持不减，必要时轻微增大以避免视觉退化
                        updated.radius = max(updated.radius, radius)
 // 强度轻微上调但不超过1.0，保持视觉稳定
                        updated.strength = min(1.0, max(updated.strength, strength * 1.02))
 // 重置已存在时间，相当于更新时间戳，延长有效期
                        updated.lifetime = 0
                        clearZones[clearZones.count - 1] = updated
                        lastMinorZoneTime = now
                    } else {
                        let zone = DynamicClearZone(center: location, radius: radius, strength: strength, maxLifetime: 4.0)
                        clearZones.append(zone)
 // 新增区域后标记需要重建桶（在更新循环中执行）
                        if clearZones.count > 20 {
                            clearZones.removeFirst()
                        }
                        lastMinorZoneTime = now
                    }
                } else {
 // 无历史区域时按常规追加
                    let zone = DynamicClearZone(center: location, radius: radius, strength: strength, maxLifetime: 4.0)
                    clearZones.append(zone)
                    if clearZones.count > 20 { clearZones.removeFirst() }
                    lastMinorZoneTime = now
                }
            }
        }

 // 更新挥动状态（用于上升沿检测）
        isSwipeActive = swipeNow
    }

 /// 更新全局透明度
    private func updateGlobalOpacity() {
 // 目标透明度：能量越高，透明度越低
 // 0%能量 -> 100%不透明
 // 100%能量 -> 0%不透明（完全透明，显示星空）
 // 说明：仅更新目标透明度，实际透明度在更新循环中做平滑插值，避免瞬间跳变。
 // 为增强中间态的可感知性，采用非线性映射提升中间能量的透明度（gamma > 1 使中低能量更不透明）
        let gamma: Double = 1.35
        let e = max(0.0, min(1.0, disperseEnergy / 100.0))
        let mapped = pow(e, gamma)
        targetGlobalOpacity = max(0.0, min(1.0, 1.0 - mapped))
    }

 /// 三次挥动触发的强力驱散（全局透明度Boost）
 /// 当用户在短时间内完成三次挥动时，将驱散能量直接拉满，目标透明度置为0，
 /// 并快速将实际透明度插值至接近透明，保证“露出最底层背景”的即时性。
    public func triggerTripleWaveBoost() {
 // 三次挥动后驱散能量拉满，并强制进入“彻底驱散”时间窗
        disperseEnergy = 100.0
        updateGlobalOpacity()
        fullClearUntil = Date().timeIntervalSince1970 + 1.8
    }

 /// 创建清空区域
    private func createClearZone(at location: CGPoint) {
 // 说明：半径基于最近平均速度计算；在采样时刻速度可能瞬时归零，导致半径退化为100。
 // 为保证可见性与一致性，这里先取一个速度快照，并在归零时提供安全回退（至少300）。
        let strength = mouseTracker.getClearStrength()
        let velocitySnapshot = mouseTracker.getAverageVelocity()
        var radius = mouseTracker.getClearRadius()
        if velocitySnapshot <= 0 {
 // 当速度快照为0（可能是采样间隔或轨迹被清空导致）时，避免半径退化过小
            radius = max(radius, 300)
            #if DEBUG
            SkyBridgeLogger.ui.debugOnly("🔧 半径安全回退: 速度快照=0，采用半径=\(radius)")
            #endif
        }

        let newZone = DynamicClearZone(
            center: location,
            radius: radius,
            strength: strength,
            maxLifetime: 60.0
        )

        clearZones.append(newZone)
 // 新增区域后标记需要重建桶（在更新循环中执行）
        #if DEBUG
 // 调试：统一在此记录实际创建的清除区域参数，确保日志与实际使用值一致
        SkyBridgeLogger.ui.debugOnly("🎯 InteractiveClearManager: 新增清除区域 - 位置: (\(location.x), \(location.y)) 半径: \(radius) 强度: \(strength) 总数: \(clearZones.count)")
        #endif

 // 限制最大区域数量
        if clearZones.count > 20 {
            clearZones.removeFirst()
        }

 // 清空轨迹
        mouseTracker.clear()
    }

 /// 手动添加清空区域（用于点击）
    public func addClearZone(at location: CGPoint, radius: CGFloat = 100) {
        let zone = DynamicClearZone(
            center: location,
            radius: radius,
            strength: 0.8,
            maxLifetime: 60.0
        )

        clearZones.append(zone)
 // 新增区域后标记需要重建桶（在更新循环中执行）

        #if DEBUG
 // 添加调试日志
        SkyBridgeLogger.ui.debugOnly("🎯 InteractiveClearManager: 添加清除区域 - 位置: (\(location.x), \(location.y)) 半径: \(radius) 总数: \(clearZones.count)")
        #endif

        if clearZones.count > 20 {
            clearZones.removeFirst()
            #if DEBUG
            SkyBridgeLogger.ui.debugOnly("🎯 InteractiveClearManager: 移除最旧的清除区域，当前总数: \(clearZones.count)")
            #endif
        }
    }

 // 提供像素半径与强度的当前快照，供渲染器每帧采样，保持粒子与片段驱散一致
    public func currentDisperseRadiusPixels() -> CGFloat {
        let velocity = mouseTracker.getAverageVelocity()
        let baseRadius: CGFloat = 100
        let velocityMultiplier = min(4.0, velocity / 100)
        let radius = baseRadius + (baseRadius * velocityMultiplier)
        return max(radius, 100)
    }

    public func currentDisperseStrength() -> Float {
        let velocity = mouseTracker.getAverageVelocity()
        let normalized = min(1.0, Float(velocity / 2000))
        return 0.3 + normalized * 0.7
    }

 /// 启动更新循环
    private func startUpdateLoop() {
 // 启动并发任务版本的更新循环，避免 RunLoop 模式切换导致 Timer 不触发。
        lastUpdateTime = Date().timeIntervalSince1970

 // 若已有旧的 ，先取消（防止重复启动）
        updateTask?.cancel()

        updateTask = Task { [weak self] in
 // 使用连续时钟提升时间测量精度
            let clock = ContinuousClock()
            var lastTick = clock.now
 // 避免在非主线程直接读取 @MainActor 成员（如 isStarted），
 // 通过 MainActor 查询启动状态，保证严格并发安全。
            while !Task.isCancelled {
                guard let strongSelf = self else { break }
                let started = await MainActor.run { strongSelf.isStarted }
                if !started {
 // 未启动时保持轻量休眠，等待外部调用 start()
                    try? await Task.sleep(nanoseconds: 33_333_333)
                    continue
                }
 // 计算时间增量（秒）
                let nowTick = clock.now
 // ContinuousClock API 使用 lastTick.duration(to: nowTick) 计算时间差。
                let tickDelta = lastTick.duration(to: nowTick)
                lastTick = nowTick
 // 将秒与阿秒转换为 Double 再相加，得到以秒为单位的时间增量
                let deltaTime = Double(tickDelta.components.seconds) + Double(tickDelta.components.attoseconds) / 1e18

                await MainActor.run {
                    guard let self = self else { return }

                    let currentTime = Date().timeIntervalSince1970
                    self.lastUpdateTime = currentTime

 // 更新所有区域（衰减与过期清理）
                    for i in (0..<self.clearZones.count).reversed() {
                        self.clearZones[i].update(deltaTime: deltaTime)
                        if self.clearZones[i].isExpired {
                            self.clearZones.remove(at: i)
                        }
                    }
 // 区域半径与数量可能发生变化，轻量级重建空间分桶
                    self.rebuildZoneBuckets()

 // 🌟 渐进恢复驱散能量（20秒内从100%恢复到0%）
                    if self.disperseEnergy > 0 {
                        let oldEnergy = self.disperseEnergy
                        let recoverySpeed = 100.0 / 20.0  // 每秒恢复约5%
                        self.disperseEnergy = max(0, self.disperseEnergy - recoverySpeed * deltaTime)
                        self.updateGlobalOpacity()  // 能量变化后同步更新目标透明度

                        #if DEBUG
 // 调试输出（每5秒打印一次）
                        if Int(currentTime) % 5 == 0 && Int(currentTime * 10) % 10 == 0 {
                            os_log(.debug, log: Self.logger, "🔄 恢复中... 能量: %.1f%% -> %.1f%%, 透明度: %.1f%%",
                                   oldEnergy, self.disperseEnergy, self.globalOpacity * 100)
                        }
                        #endif
                    }

 // 透明度平滑过渡（避免瞬间跳变）——一阶响应模型
                    let now = currentTime
                    if now < self.fullClearUntil {
 // 三次挥动后的"彻底驱散"时间窗内，直接清零不透明度
                        self.globalOpacity = 0.0
                    } else {
 // 🔧 优化：进一步降低响应速度（从1.2降到0.9），让三个阶段的中间态更明显
 // 这样用户可以清楚看到：35% → 70% → 100% 的渐进驱散过程
 // 0.9的响应速度意味着每个阶段需要约1.1秒才能完全过渡，给用户足够时间感知
                        let opacityResponseRate = 0.9  // 更慢的过渡，增强视觉反馈和阶段可见性
                        let k = min(1.0, opacityResponseRate * deltaTime)
                        self.globalOpacity = self.globalOpacity + (self.targetGlobalOpacity - self.globalOpacity) * k
 // 当能量为满值且目标为0时，接近阈值直接清零以消除残留
                        if self.disperseEnergy >= 99.9 && self.targetGlobalOpacity <= 0.001 && self.globalOpacity <= 0.02 {
                            self.globalOpacity = 0.0
                        }
                    }
                }

 // 🔧 优化：降低更新频率到 12 FPS（83.3ms），大幅降低CPU占用和能耗
 // 从30 FPS降到12 FPS，性能提升约60%，同时保持流畅的视觉效果
                try? await Task.sleep(nanoseconds: 83_333_333)
            }
        }
    }

 /// 停止更新
    public func stopUpdateLoop() {
 // 停止并发更新任务，确保不会继续修改状态。
        updateTimer?.invalidate()  // 兼容旧逻辑
        updateTimer = nil
        updateTask?.cancel()
        updateTask = nil
    }

 /// 获取指定位置的总驱散强度
    public func getClearStrengthAt(_ point: CGPoint) -> Float {
 // 若无区域，直接返回0
        guard !clearZones.isEmpty else { return 0 }
 // 计算目标点所在桶坐标与搜索邻域范围（基于最大半径）
        let bx = Int(floor(point.x / bucketCellSize))
        let by = Int(floor(point.y / bucketCellSize))
        let maxRadius = clearZones.map { $0.radius }.max() ?? bucketCellSize
        let extent = max(0, Int(ceil(maxRadius / bucketCellSize)))

 // 收集候选区域索引（邻域桶）
        var candidateIndices = Set<Int>()
        for dx in -extent...extent {
            for dy in -extent...extent {
                let key = bucketKey(bx + dx, by + dy)
                if let list = zoneBuckets[key] {
                    for idx in list { candidateIndices.insert(idx) }
                }
            }
        }

 // 若邻域为空，退化为全量遍历（保证正确性）
        let indicesToCheck: [Int]
        if candidateIndices.isEmpty {
            indicesToCheck = Array(clearZones.indices)
        } else {
            indicesToCheck = Array(candidateIndices)
        }

        var totalStrength: Float = 0
        for i in indicesToCheck {
            let zone = clearZones[i]
            let dx = point.x - zone.center.x
            let dy = point.y - zone.center.y
            let r = zone.radius
            let r2 = r * r
            let d2 = dx * dx + dy * dy
            if d2 < r2 {
                let distance = sqrt(d2)
                let normalizedDistance = Float(distance / r)
                let falloff = 1.0 - normalizedDistance * normalizedDistance
                totalStrength += zone.strength * falloff
            }
        }
        return min(1.0, totalStrength)
    }

 /// 恢复更新循环（在已启动情况下）
    public func resumeUpdateLoop() {
 // 仅当管理器已启动且当前没有运行中的更新任务时重启更新循环
        guard isStarted else { return }
        if updateTask == nil {
            startUpdateLoop()
        }
    }

 // Timer will be automatically invalidated when deallocated
}

// MARK: - 🖱️ 鼠标跟踪视图

/// 全屏鼠标跟踪视图
public struct InteractiveMouseTrackingView: NSViewRepresentable {
    let onMouseMove: (CGPoint) -> Void

    private static let logger = OSLog(subsystem: "com.skybridge.compass", category: "MouseTracking")

    public init(onMouseMove: @escaping (CGPoint) -> Void) {
        self.onMouseMove = onMouseMove
        #if DEBUG
        os_log(.debug, log: InteractiveMouseTrackingView.logger, "🔥 InteractiveMouseTrackingView: 初始化")
        #endif
    }

    public func makeNSView(context: Context) -> NSView {
        #if DEBUG
        os_log(.debug, log: InteractiveMouseTrackingView.logger, "🔥 InteractiveMouseTrackingView: makeNSView 被调用")
        #endif
        let view = MouseTrackingNSView()
        view.onMouseMove = onMouseMove
        #if DEBUG
        os_log(.debug, log: InteractiveMouseTrackingView.logger, "🔥 InteractiveMouseTrackingView: MouseTrackingNSView 已创建")
        #endif
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        if let trackingView = nsView as? MouseTrackingNSView {
            trackingView.onMouseMove = onMouseMove
        }
    }
}

class MouseTrackingNSView: NSView {
    var onMouseMove: ((CGPoint) -> Void)?
    private var globalMonitor: Any?

 // 🔧 优化：限制全局监听器的日志频率，降低性能开销
    private var eventCount = 0
    private var lastLogTime: TimeInterval = 0
    private let logInterval: TimeInterval = 2.0  // 每2秒最多记录一次日志

    private static let logger = OSLog(subsystem: "com.skybridge.compass", category: "MouseTracking")

    override init(frame frameRect: NSRect) {
        #if DEBUG
        os_log(.debug, log: MouseTrackingNSView.logger, "🔥🔥🔥 MouseTrackingNSView: init 开始, frame=%@", String(describing: frameRect))
        #endif
        super.init(frame: frameRect)
        self.wantsLayer = true

 // 使用全局事件监听器（不依赖 hitTest）
 // 这样可以：1) 接收鼠标移动事件，2) 让点击穿透
        #if DEBUG
        os_log(.debug, log: MouseTrackingNSView.logger, "🔥🔥🔥 MouseTrackingNSView: 准备调用 setupGlobalMonitor")
        #endif
        setupGlobalMonitor()

        #if DEBUG
        os_log(.debug, log: MouseTrackingNSView.logger, "🖱️🔥🔥🔥 MouseTrackingNSView: 初始化完成（全局监听模式）")
        #endif
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private func setupGlobalMonitor() {
        #if DEBUG
        SkyBridgeLogger.ui.debugOnly("🔧 Setting up global mouse monitor...")
        #endif

 // 监听本地鼠标移动事件
        globalMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self = self else {
 // self已释放，直接返回事件
                return event
            }

            self.eventCount += 1

            guard self.window != nil else {
                #if DEBUG
                let now = Date().timeIntervalSince1970
                if now - self.lastLogTime >= self.logInterval {
                    self.lastLogTime = now
                    os_log(.debug, log: MouseTrackingNSView.logger, "⚠️ window 为 nil")
                }
                #endif
                return event
            }

 // 获取鼠标在窗口中的位置
            let locationInWindow = event.locationInWindow
            let locationInView = self.convert(locationInWindow, from: nil)

 // 检查鼠标是否在视图范围内
            let isInBounds = self.bounds.contains(locationInView)

            #if DEBUG
 // 🔧 优化：大幅降低日志频率，仅在必要时记录
            let now = Date().timeIntervalSince1970
            if now - self.lastLogTime >= self.logInterval {
                self.lastLogTime = now
                if self.eventCount % 100 == 0 {
                    SkyBridgeLogger.ui.debugOnly("🖱️ Global mouse monitor - Window: \(String(describing: locationInWindow)) View: \(String(describing: locationInView)) InBounds: \(isInBounds) Events: \(self.eventCount)")
                    os_log(.debug, log: MouseTrackingNSView.logger, "🖱️ 鼠标位置 - 窗口: (%d, %d), 视图: (%d, %d), 事件数: %d",
                           Int(locationInWindow.x), Int(locationInWindow.y),
                           Int(locationInView.x), Int(locationInView.y),
                           self.eventCount)
                }
            }
            #endif

            if isInBounds {
 // 转换坐标系（AppKit的y轴从下到上，需要翻转）
                let flippedY = self.bounds.height - locationInView.y
                let point = CGPoint(x: locationInView.x, y: flippedY)
                self.onMouseMove?(point)
            }

            return event  // 让事件继续传播，不阻挡点击
        }

        #if DEBUG
        if globalMonitor != nil {
            SkyBridgeLogger.ui.debugOnly("✅ Global mouse monitor setup successfully")
            os_log(.debug, log: MouseTrackingNSView.logger, "🖱️ MouseTrackingNSView: 全局事件监听器已启动")
        } else {
            SkyBridgeLogger.ui.error("❌ Failed to setup global mouse monitor")
            os_log(.error, log: MouseTrackingNSView.logger, "❌ 全局事件监听器启动失败")
        }
        #endif
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            window.acceptsMouseMovedEvents = true
            #if DEBUG
            os_log(.debug, log: MouseTrackingNSView.logger, "🖱️ MouseTrackingNSView: 窗口已设置接受鼠标移动事件")
            #endif
        }
    }

 // 🔥 让点击穿透此视图
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil  // 返回 nil 让所有点击事件穿透
    }

 // 注意：不在 deinit 清理 globalMonitor 以避免 Swift 6 并发问题
 // 由于闭包中使用了 weak self，视图销毁后闭包会自动失效，不会造成内存问题
}

// MARK: - 🎨 可视化调试视图（可选）

@available(macOS 14.0, *)
public struct ClearZoneDebugView: View {
    @ObservedObject var manager: InteractiveClearManager

    public init(manager: InteractiveClearManager) {
        self.manager = manager
    }

    public var body: some View {
        Canvas { context, size in
            for zone in manager.clearZones {
 // 绘制清空区域（调试用）
                let rect = CGRect(
                    x: zone.center.x - zone.radius,
                    y: zone.center.y - zone.radius,
                    width: zone.radius * 2,
                    height: zone.radius * 2
                )

                let gradient = Gradient(colors: [
                    Color.red.opacity(Double(zone.strength) * 0.3),
                    Color.red.opacity(0)
                ])

                context.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        gradient,
                        center: zone.center,
                        startRadius: 0,
                        endRadius: zone.radius
                    )
                )

 // 显示信息
                context.draw(
                    Text("\(Int(zone.strength * 100))%")
                        .font(.caption)
                        .foregroundColor(.white),
                    at: zone.center
                )
            }
        }
    }
}
// 保持文件末尾仅包含调试视图定义
#endif
