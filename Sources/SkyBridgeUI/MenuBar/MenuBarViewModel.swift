//
// MenuBarViewModel.swift
// SkyBridgeUI
//
// Menu Bar App - ViewModel for Popover
// Requirements: 2.1, 2.2, 2.4, 3.2, 3.3, 3.4, 3.5, 4.1, 4.2
//

import Foundation
import Combine
import AppKit
import os.log
import SkyBridgeCore

/// 菜单栏视图模型 - 管理弹出面板的数据和业务逻辑
/// Requirements: 2.1, 2.2, 3.2, 3.3, 3.4, 3.5, 4.1, 4.2
@available(macOS 14.0, *)
@MainActor
public final class MenuBarViewModel: ObservableObject {
    
 // MARK: - Published Properties
    
 /// 已发现设备列表
 /// Requirements: 2.1
    @Published public var discoveredDevices: [DiscoveredDevice] = []
    
 /// 当前传输任务
 /// Requirements: 4.2
    @Published public var activeTransfers: [MenuBarTransferItem] = []
    
 /// 是否正在扫描
 /// Requirements: 3.2
    @Published public var isScanning: Bool = false
    
 /// 图标状态
 /// Requirements: 4.1
    @Published public var iconState: MenuBarIconState = .normal
    
 /// 配置
    @Published public var configuration: MenuBarConfiguration = .default
    
 // MARK: - Private Properties
    
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "com.skybridge.ui", category: "MenuBarViewModel")
    
 // MARK: - Initialization
    
    public init() {
        setupBindings()
    }
    
 // MARK: - Public Methods
    
 /// 触发设备扫描
 /// Requirements: 3.2
    public func startDeviceScan() async {
        logger.info("🔍 开始设备扫描")
        isScanning = true
        iconState = .scanning
        
 // 先关闭 popover
        MenuBarController.shared.closePopover()
        
        await DeviceDiscoveryService.shared.start(force: true)
        
 // 扫描完成后恢复状态
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒后恢复
        isScanning = false
        updateIconStateFromTransfers()
    }
    
 /// 打开文件传输选择器
 /// Requirements: 3.3
    public func openFileTransfer() {
        logger.info("📁 打开文件传输选择器")
        
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "选择要传输的文件"
        
        panel.begin { [weak self] response in
            if response == .OK {
                let urls = panel.urls
                self?.logger.info("选择了 \(urls.count) 个文件")
                
 // 发送通知，由主应用处理文件传输
                NotificationCenter.default.post(
                    name: .menuBarOpenFileTransfer,
                    object: nil,
                    userInfo: ["urls": urls]
                )
            }
        }
    }
    
 /// 打开屏幕镜像
 /// Requirements: 3.4
    public func openScreenMirror() {
        logger.info("🖥️ 打开屏幕镜像")
        
 // 先关闭 popover
        MenuBarController.shared.closePopover()
        
 // 延迟执行以确保 popover 关闭
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .menuBarOpenScreenMirror, object: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
 /// 打开设置
 /// Requirements: 3.5
    public func openSettings() {
        logger.info("⚙️ 打开设置")
        
 // 先关闭 popover
        MenuBarController.shared.closePopover()
        
 // 延迟执行以确保 popover 关闭
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
 // 尝试多种方式打开设置窗口
            if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
 // 成功
            } else if NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil) {
 // 旧版 API
            } else {
 // 回退：发送通知让主应用处理
                NotificationCenter.default.post(name: .menuBarOpenSettings, object: nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
 /// 打开主窗口
    public func openMainWindow() {
        logger.info("🏠 打开主窗口")
        NotificationCenter.default.post(name: .menuBarOpenMainWindow, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
 /// 选择设备
 /// Requirements: 2.4
    public func selectDevice(_ device: DiscoveredDevice) {
        logger.info("📱 选择设备: \(device.name)")
        NotificationCenter.default.post(
            name: .menuBarOpenDeviceDetail,
            object: nil,
            userInfo: ["device": device]
        )
        NSApp.activate(ignoringOtherApps: true)
    }
    
 // MARK: - Private Methods
    
 /// 设置数据绑定
 /// Requirements: 2.1, 2.2, 4.1, 4.2
    private func setupBindings() {
 // 订阅设备发现服务
 // Requirements: 2.1, 2.2
        DeviceDiscoveryService.shared.$discoveredDevices
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main) // 2秒防抖
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                guard let self = self else { return }
 // 🔧 修复：过滤掉本机设备，只显示远程设备
                let remoteDevices = devices.filter { !$0.isLocalDevice }
 // 限制显示数量
                let maxDevices = self.configuration.maxDevicesShown
                self.discoveredDevices = Array(remoteDevices.prefix(maxDevices))
                self.logger.debug("设备列表已更新: \(remoteDevices.count) 个远程设备（总共 \(devices.count) 个）")
            }
            .store(in: &cancellables)
        
 // 订阅扫描状态
        DeviceDiscoveryService.shared.$isScanning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] scanning in
                self?.isScanning = scanning
                if scanning {
                    self?.iconState = .scanning
                } else {
                    self?.updateIconStateFromTransfers()
                }
            }
            .store(in: &cancellables)
        
 // 订阅文件传输引擎
 // Requirements: 4.1, 4.2
        setupTransferBindings()
    }
    
 /// 设置传输绑定
    private func setupTransferBindings() {
 // 注意：FileTransferEngine 是 MainActor 隔离的
 // 这里使用 NotificationCenter 作为桥接
        NotificationCenter.default.publisher(for: .fileTransferProgressUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleTransferProgressUpdate(notification)
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: .fileTransferCompleted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleTransferCompleted(notification)
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: .fileTransferFailed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleTransferFailed(notification)
            }
            .store(in: &cancellables)
    }
    
 /// 处理传输进度更新
    private func handleTransferProgressUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let transferId = userInfo["transferId"] as? String,
              let fileName = userInfo["fileName"] as? String,
              let progress = userInfo["progress"] as? Double,
              let speed = userInfo["speed"] as? Double else {
            return
        }
        
 // 更新或添加传输项
        if let index = activeTransfers.firstIndex(where: { $0.id == transferId }) {
            activeTransfers[index] = MenuBarTransferItem(
                id: transferId,
                fileName: fileName,
                progress: progress,
                speed: speed,
                state: .transferring
            )
        } else {
            activeTransfers.append(MenuBarTransferItem(
                id: transferId,
                fileName: fileName,
                progress: progress,
                speed: speed,
                state: .transferring
            ))
        }
        
        updateIconStateFromTransfers()
    }
    
 /// 处理传输完成
    private func handleTransferCompleted(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let transferId = userInfo["transferId"] as? String else {
            return
        }
        
 // 移除已完成的传输
        activeTransfers.removeAll { $0.id == transferId }
        updateIconStateFromTransfers()
    }
    
 /// 处理传输失败
    private func handleTransferFailed(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let transferId = userInfo["transferId"] as? String else {
            return
        }
        
 // 标记为失败
        if let index = activeTransfers.firstIndex(where: { $0.id == transferId }) {
            let item = activeTransfers[index]
            activeTransfers[index] = MenuBarTransferItem(
                id: item.id,
                fileName: item.fileName,
                progress: item.progress,
                speed: 0,
                state: .failed
            )
        }
        
        iconState = .error
    }
    
 /// 根据传输状态更新图标
    private func updateIconStateFromTransfers() {
        if activeTransfers.isEmpty {
            iconState = .normal
        } else if activeTransfers.contains(where: { $0.state == .failed }) {
            iconState = .error
        } else {
 // 计算总进度
            let totalProgress = activeTransfers.reduce(0.0) { $0 + $1.progress } / Double(activeTransfers.count)
            iconState = .transferring(progress: totalProgress)
        }
    }
}

// MARK: - Notification Names

public extension Notification.Name {
 /// 文件传输进度更新
    static let fileTransferProgressUpdated = Notification.Name("com.skybridge.fileTransfer.progressUpdated")
    
 /// 文件传输完成
    static let fileTransferCompleted = Notification.Name("com.skybridge.fileTransfer.completed")
    
 /// 文件传输失败
    static let fileTransferFailed = Notification.Name("com.skybridge.fileTransfer.failed")
    
 /// 打开设置（回退通知）
    static let menuBarOpenSettings = Notification.Name("com.skybridge.menuBar.openSettings")
}
