//
// GlobalMouseTracker.swift
// SkyBridgeCompassApp
//
// 全局鼠标追踪器 - 苹果官方推荐方式
// 在 App 级别注册 NSEvent 监听器，而不是在 SwiftUI 视图中
// Created: 2025-10-19
//

import AppKit
import Foundation
import os.log
import QuartzCore

/// 🖱️ 全局鼠标追踪器 - 单例模式
///
/// 根据苹果官方最佳实践：
/// 1. 全局事件监听器应在 App/Window 生命周期中注册
/// 2. 使用 NotificationCenter 广播事件给需要的视图
/// 3. 避免在 SwiftUI 视图中直接创建监听器（可能被优化掉）
@MainActor
final class GlobalMouseTracker: ObservableObject {
    
 // MARK: - Singleton
    
    static let shared = GlobalMouseTracker()
    
 // MARK: - Properties
    
    private var localMonitor: Any?
    private static let logger = OSLog(subsystem: "com.skybridge.compass", category: "GlobalMouseTracker")
    
 /// 鼠标移动通知名称
    static let mouseMovedNotification = NSNotification.Name("GlobalMouseMoved")
    
 // MARK: - Initialization
    
    private init() {
        os_log(.error, log: Self.logger, "🖱️ GlobalMouseTracker: 单例初始化")
    }
    
 // MARK: - Public Methods
    
 /// 启动全局鼠标追踪
 /// 应该在 AppDelegate 的 applicationDidFinishLaunching 中调用
    func startTracking() {
        guard localMonitor == nil else {
            os_log(.error, log: Self.logger, "🖱️ 全局鼠标追踪已在运行")
            return
        }
        
        os_log(.error, log: Self.logger, "🖱️ 开始注册全局鼠标监听器...")
        
 // 🔥 使用 addLocalMonitorForEvents 监听本应用内的鼠标移动事件
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMoved(event)
            return event  // 🔥 返回 event 让它继续传播，不阻挡任何交互
        }
        
 // 🔥 确保主窗口接受鼠标移动事件
 // Swift 6.2: 使用 @MainActor 替代 DispatchQueue 以保持 actor 隔离
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            if let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first {
                window.acceptsMouseMovedEvents = true
                os_log(.error, log: Self.logger, "🖱️ 主窗口已设置为接受鼠标移动事件")
            } else {
                os_log(.error, log: Self.logger, "⚠️ 未找到主窗口，将在后续尝试设置")
 // 如果窗口还没创建，在 1 秒后再试
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1.0s
                if let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first {
                    window.acceptsMouseMovedEvents = true
                    os_log(.error, log: Self.logger, "🖱️ 主窗口已设置为接受鼠标移动事件（延迟）")
                }
            }
        }
        
        os_log(.error, log: Self.logger, "✅ 全局鼠标监听器注册成功")
    }
    
 /// 停止全局鼠标追踪
 /// 应该在 AppDelegate 的 applicationWillTerminate 中调用
    func stopTracking() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
            os_log(.error, log: Self.logger, "🖱️ 全局鼠标监听器已移除")
        }
    }
    
 // MARK: - Private Methods
    
    private var eventCount = 0
 // 源头节流与合并位移控制参数
    private var lastPostTime: CFTimeInterval = 0
    private var maxRateHz: Int = 30 // 默认30Hz，上限可调到60Hz
    private var minInterval: CFTimeInterval { 1.0 / CFTimeInterval(maxRateHz) }
    private var latestPoint: CGPoint?
    private var scheduled: Bool = false

 /// 更新事件处理频率（30或60Hz）
    func updateMouseEventRate(hz: Int) {
 // 仅允许设置为30或60Hz，避免不合理频率导致主线程抖动
        if hz == 60 {
            maxRateHz = 60
        } else {
            maxRateHz = 30
        }
    }
    
 /// 处理鼠标移动事件
    private func handleMouseMoved(_ event: NSEvent) {
        eventCount += 1
        
 // 预处理坐标，仅保留最新位置用于合并；避免高频事件重复计算与广播。
        guard let window = event.window ?? NSApp.mainWindow ?? NSApp.keyWindow,
              let contentView = window.contentView else {
            return
        }
        let locationInWindow = event.locationInWindow
        let locationInContentView = contentView.convert(locationInWindow, from: nil)
        
 // 仅在内容区域内记录位置
        guard contentView.bounds.contains(locationInContentView) else { return }
        let flippedY = contentView.bounds.height - locationInContentView.y
        latestPoint = CGPoint(x: locationInContentView.x, y: flippedY)

 // 源头节流 + 合并位移：仅在间隔到达时发送一次最新坐标
        guard !scheduled else { return }
        scheduled = true
        let now = CACurrentMediaTime()
        let elapsed = now - lastPostTime
        let delay = max(0, minInterval - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.lastPostTime = CACurrentMediaTime()
            guard let p = self.latestPoint else { return }
            NotificationCenter.default.post(
                name: Self.mouseMovedNotification,
                object: nil,
                userInfo: ["location": NSValue(point: NSPoint(x: p.x, y: p.y))]
            )
        }
    }
}
