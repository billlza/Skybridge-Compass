//
// SimplifiedWeatherBridge.swift
// SkyBridgeCompassApp
//
// 简化的天气效果桥接视图（过渡方案）
// Created: 2025-10-19
//

import SwiftUI
import SkyBridgeCore

/// 简化的多云效果视图
@available(macOS 14.0, *)
public struct CinematicCloudySkyView: View {
    @StateObject private var clearManager = InteractiveClearManager()
    
    public init() {}
    
    public var body: some View {
        GeometryReader { geometry in
            ZStack {
 // 多云渐变效果
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.4, green: 0.5, blue: 0.6).opacity(0.3),
                                Color(red: 0.3, green: 0.4, blue: 0.5).opacity(0.5)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(clearManager.globalOpacity)  // 🔥 驱散效果
            }
        }
        .ignoresSafeArea()
        .onAppear {
 // 🔥 启动交互式清空管理器
            Task {
 // start() 为同步方法，直接调用；移除不必要的 await。
            clearManager.start()
            }
        }
        .onDisappear {
 // 🔥 停止交互式清空管理器
            Task {
 // stop() 为同步方法，直接调用；移除不必要的 await。
            clearManager.stop()
            }
        }
 // 🔥 使用 onReceive 自动管理监听器生命周期
        .onReceive(NotificationCenter.default.publisher(for: GlobalMouseTracker.mouseMovedNotification)) { notification in
            if let locationValue = notification.userInfo?["location"] as? NSValue {
                let nsPoint = locationValue.pointValue
                let location = CGPoint(x: nsPoint.x, y: nsPoint.y)
                clearManager.handleMouseMove(location)
            }
        }
    }
}

/// 简化的雾天效果视图 - 修复配置获取问题 + 交互式驱散支持
@available(macOS 14.0, *)
public struct CinematicFogView: View {
    @State private var performanceConfig: PerformanceConfiguration?
    @StateObject private var clearManager = InteractiveClearManager()
    
    public init() {}
    
    public var body: some View {
        Group {
            if let config = performanceConfig {
 // 使用现有的 VolumetricFogView
                VolumetricFogView(config: config)
                    .opacity(clearManager.globalOpacity)  // 🔥 驱散效果
            } else {
 // 显示占位符并异步加载配置
                SimpleFogPlaceholder()
                    .onAppear {
                        loadPerformanceConfig()
                    }
            }
        }
        .onAppear {
            loadPerformanceConfig()
            clearManager.start()
        }
        .onDisappear {
            clearManager.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: GlobalMouseTracker.mouseMovedNotification)) { notification in
            if let locationValue = notification.userInfo?["location"] as? NSValue {
                let nsPoint = locationValue.pointValue
                let location = CGPoint(x: nsPoint.x, y: nsPoint.y)
                clearManager.handleMouseMove(location)
            }
        }
    }
    
 /// 异步加载性能配置
    private func loadPerformanceConfig() {
        Task { @MainActor in
 // 尝试获取性能管理器配置（已在 @available(macOS 14.0, *) 作用域内，无需再次检查）
                do {
                    let manager = try PerformanceModeManager()
                    performanceConfig = manager.currentConfiguration
                    return
                } catch {
                    SkyBridgeLogger.ui.error("⚠️ 无法获取PerformanceModeManager配置: \(error.localizedDescription, privacy: .private)")
            }
            
 // 使用默认配置（平衡模式）
            performanceConfig = PerformanceConfiguration(
                renderScale: 0.85,
                maxParticles: 8000,
                targetFrameRate: 60,
                metalFXQuality: 0.7,
                shadowQuality: 1,
                postProcessingLevel: 1,
                gpuFrequencyHint: 0.7,
                memoryBudget: 1024
            )
        }
    }
    
    private struct SimpleFogPlaceholder: View {
        var body: some View {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.gray.opacity(0.2),
                            Color.white.opacity(0.3),
                            Color.gray.opacity(0.4)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .ignoresSafeArea()
        }
    }
}

/// 简化的霾天效果视图 - 修复配置获取问题 + 交互式驱散支持
@available(macOS 14.0, *)
public struct SimplifiedCinematicHazeView: View {
    @State private var performanceConfig: PerformanceConfiguration?
    @StateObject private var clearManager = InteractiveClearManager()
    
    public init() {}
    
    public var body: some View {
        Group {
            if let config = performanceConfig {
 // 使用轻度雾效模拟霾天
                VolumetricFogView(config: config, intensity: 0.3)
                    .opacity(clearManager.globalOpacity)  // 🔥 驱散效果
            } else {
 // 显示占位符并异步加载配置
                SimpleHazePlaceholder()
                    .onAppear {
                        loadPerformanceConfig()
                    }
            }
        }
        .onAppear {
            loadPerformanceConfig()
            clearManager.start()
        }
        .onDisappear {
            clearManager.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: GlobalMouseTracker.mouseMovedNotification)) { notification in
            if let locationValue = notification.userInfo?["location"] as? NSValue {
                let nsPoint = locationValue.pointValue
                let location = CGPoint(x: nsPoint.x, y: nsPoint.y)
                clearManager.handleMouseMove(location)
            }
        }
    }
    
 /// 异步加载性能配置
    private func loadPerformanceConfig() {
        Task { @MainActor in
 // 尝试获取性能管理器配置（已在 @available(macOS 14.0, *) 作用域内，无需再次检查）
                do {
                    let manager = try PerformanceModeManager()
                    performanceConfig = manager.currentConfiguration
                    return
                } catch {
                    SkyBridgeLogger.ui.error("⚠️ 无法获取PerformanceModeManager配置: \(error.localizedDescription, privacy: .private)")
            }
            
 // 使用默认配置（平衡模式，降低粒子数量）
            performanceConfig = PerformanceConfiguration(
                renderScale: 0.85,
                maxParticles: 5000,  // 霾天粒子数量较少
                targetFrameRate: 60,
                metalFXQuality: 0.7,
                shadowQuality: 1,
                postProcessingLevel: 1,
                gpuFrequencyHint: 0.7,
                memoryBudget: 1024
            )
        }
    }
    
    private struct SimpleHazePlaceholder: View {
        var body: some View {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.brown.opacity(0.1),
                            Color.yellow.opacity(0.2),
                            Color.gray.opacity(0.3)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .ignoresSafeArea()
        }
    }
}

