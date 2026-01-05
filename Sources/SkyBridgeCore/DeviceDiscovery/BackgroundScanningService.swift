//
// BackgroundScanningService.swift
// SkyBridgeCore
//
// 后台设备扫描服务
// 在应用进入后台时继续扫描设备
//

import Foundation
import OSLog
import Combine
import AppKit

/// 后台扫描服务 - 管理应用后台时的设备扫描
/// 当 enableBackgroundScanning 启用时，应用进入后台后继续扫描设备
@MainActor
public class BackgroundScanningService: ObservableObject {
    
    public static let shared = BackgroundScanningService()
    
 // MARK: - 发布属性
    
    @Published public var isBackgroundScanningEnabled: Bool = false {
        didSet {
            let enabled = isBackgroundScanningEnabled
            logger.info("🔄 后台扫描已\(enabled ? "启用" : "禁用")")
            if enabled {
                registerForAppLifecycleNotifications()
            } else {
                unregisterFromAppLifecycleNotifications()
                stopBackgroundScanning()
            }
        }
    }
    
    @Published public var isCurrentlyScanning: Bool = false
    @Published public var lastScanTime: Date?
    @Published public var backgroundScanInterval: TimeInterval = 60.0 // 默认60秒
    @Published public var discoveredDevicesInBackground: [DiscoveredDevice] = []
    
 // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "com.skybridge.discovery", category: "BackgroundScanning")
    private var backgroundTask: Task<Void, Never>?
    private var scanTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var isInBackground: Bool = false
    
 // 后台扫描配置
    private var maxBackgroundScans: Int = 100 // 最大后台扫描次数
    private var currentBackgroundScanCount: Int = 0
    
    private init() {
        setupSettingsObserver()
    }
    
 // MARK: - 设置观察
    
    private func setupSettingsObserver() {
 // 监听设置变化
        SettingsManager.shared.$enableBackgroundScanning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.isBackgroundScanningEnabled = enabled
            }
            .store(in: &cancellables)
    }
    
 // MARK: - 生命周期通知
    
    private func registerForAppLifecycleNotifications() {
 // 监听应用进入后台
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        
 // 监听应用进入前台
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        
 // 监听应用即将终止
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        
        logger.info("📋 已注册应用生命周期通知")
    }
    
    private func unregisterFromAppLifecycleNotifications() {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSApplication.willTerminateNotification, object: nil)
        
        logger.info("📋 已取消注册应用生命周期通知")
    }
    
 // MARK: - 生命周期回调
    
    @objc private func applicationDidResignActive(_ notification: Notification) {
        guard isBackgroundScanningEnabled else { return }
        
        logger.info("📱 应用进入后台，启动后台扫描")
        isInBackground = true
        startBackgroundScanning()
    }
    
    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        logger.info("📱 应用进入前台，停止后台扫描")
        isInBackground = false
        stopBackgroundScanning()
        
 // 将后台发现的设备合并到主列表
        if !discoveredDevicesInBackground.isEmpty {
            mergeBackgroundDiscoveredDevices()
        }
    }
    
    @objc private func applicationWillTerminate(_ notification: Notification) {
        logger.info("📱 应用即将终止，清理后台扫描资源")
        stopBackgroundScanning()
    }
    
 // MARK: - 后台扫描控制
    
 /// 启动后台扫描
    public func startBackgroundScanning() {
        guard isBackgroundScanningEnabled, isInBackground else { return }
        guard !isCurrentlyScanning else {
            logger.debug("后台扫描已在运行中")
            return
        }
        
        logger.info("🔍 启动后台设备扫描")
        isCurrentlyScanning = true
        currentBackgroundScanCount = 0
        
 // 启动定时扫描任务
        backgroundTask = Task { [weak self] in
            guard let self = self else { return }
            
            while !Task.isCancelled && self.isInBackground && self.isBackgroundScanningEnabled {
                await self.performBackgroundScan()
                
 // 检查是否超过最大扫描次数
                if self.currentBackgroundScanCount >= self.maxBackgroundScans {
                    self.logger.info("⚠️ 达到最大后台扫描次数，暂停扫描")
                    break
                }
                
 // 等待下一次扫描
                do {
                    try await Task.sleep(nanoseconds: UInt64(self.backgroundScanInterval * 1_000_000_000))
                } catch {
                    break
                }
            }
            
            await MainActor.run {
                self.isCurrentlyScanning = false
            }
        }
    }
    
 /// 停止后台扫描
    public func stopBackgroundScanning() {
        logger.info("⏹️ 停止后台设备扫描")
        
        backgroundTask?.cancel()
        backgroundTask = nil
        scanTimer?.invalidate()
        scanTimer = nil
        isCurrentlyScanning = false
    }
    
 /// 执行单次后台扫描
    private func performBackgroundScan() async {
        currentBackgroundScanCount += 1
        lastScanTime = Date()
        
        logger.debug("🔄 执行后台扫描 #\(self.currentBackgroundScanCount)")
        
 // 使用轻量级扫描策略
        let discoveryManager = DeviceDiscoveryManagerOptimized()
        
 // 配置为低功耗模式
        discoveryManager.enableCompatibilityMode = false
        discoveryManager.enableCompanionLink = false
        
 // 启动扫描
        discoveryManager.startScanning()
        
 // 等待扫描结果（限时 10 秒）
        do {
            try await Task.sleep(nanoseconds: 10_000_000_000) // 10秒
        } catch {
 // 任务被取消
        }
        
 // 停止扫描
        discoveryManager.stopScanning()
        
 // 收集发现的设备
        let newDevices = discoveryManager.discoveredDevices
        
        await MainActor.run {
 // 合并新发现的设备
            for device in newDevices {
                if !self.discoveredDevicesInBackground.contains(where: { $0.id == device.id }) {
                    self.discoveredDevicesInBackground.append(device)
                    
 // 发送通知
                    NotificationCenter.default.post(
                        name: .deviceDiscoveredInBackground,
                        object: nil,
                        userInfo: ["device": device]
                    )
                }
            }
        }
        
        logger.debug("✅ 后台扫描完成，发现 \(newDevices.count) 台设备")
    }
    
 /// 合并后台发现的设备到主列表
    private func mergeBackgroundDiscoveredDevices() {
        logger.info("🔄 合并后台发现的 \(self.discoveredDevicesInBackground.count) 台设备")
        
 // 通知主发现管理器合并设备
        NotificationCenter.default.post(
            name: .mergeBackgroundDiscoveredDevices,
            object: nil,
            userInfo: ["devices": discoveredDevicesInBackground]
        )
        
 // 清空后台发现列表
        discoveredDevicesInBackground.removeAll()
    }
    
 // MARK: - 公共方法
    
 /// 手动触发一次后台扫描
    public func triggerManualScan() async {
        guard isBackgroundScanningEnabled else {
            logger.warning("⚠️ 后台扫描未启用")
            return
        }
        
        await performBackgroundScan()
    }
    
 /// 重置扫描计数
    public func resetScanCount() {
        currentBackgroundScanCount = 0
        logger.info("🔄 重置后台扫描计数")
    }
    
 /// 配置后台扫描参数
    public func configure(interval: TimeInterval, maxScans: Int) {
        backgroundScanInterval = max(30, interval) // 最小 30 秒
        maxBackgroundScans = max(10, maxScans) // 最小 10 次
        
        logger.info("⚙️ 后台扫描配置: 间隔=\(self.backgroundScanInterval)秒, 最大次数=\(self.maxBackgroundScans)")
    }
}

// MARK: - 通知扩展

public extension Notification.Name {
    static let deviceDiscoveredInBackground = Notification.Name("com.skybridge.deviceDiscoveredInBackground")
    static let mergeBackgroundDiscoveredDevices = Notification.Name("com.skybridge.mergeBackgroundDiscoveredDevices")
}

