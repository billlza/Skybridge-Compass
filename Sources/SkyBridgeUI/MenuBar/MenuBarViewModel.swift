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
import Network
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
                let remoteDevices = Self.deduplicatedMenuBarDevices(
                    devices.filter { !$0.isLocalDevice }
                )
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

    static func deduplicatedMenuBarDevices(_ devices: [DiscoveredDevice]) -> [DiscoveredDevice] {
        var orderedKeys: [String] = []
        var devicesByKey: [String: DiscoveredDevice] = [:]
        var passthrough: [DiscoveredDevice] = []

        for device in devices {
            guard let key = stablePresentationKey(for: device) else {
                passthrough.append(device)
                continue
            }

            if let existing = devicesByKey[key] {
                devicesByKey[key] = preferredMenuBarDevice(existing, device)
            } else {
                orderedKeys.append(key)
                devicesByKey[key] = device
            }
        }

        let deduplicated = orderedKeys.compactMap { devicesByKey[$0] }
        return deduplicated + passthrough
    }

    private static func preferredMenuBarDevice(
        _ lhs: DiscoveredDevice,
        _ rhs: DiscoveredDevice
    ) -> DiscoveredDevice {
        scoreForMenuBarPresentation(rhs) > scoreForMenuBarPresentation(lhs) ? rhs : lhs
    }

    private static func scoreForMenuBarPresentation(_ device: DiscoveredDevice) -> Int {
        var score = 0
        if stableIdentityPayload(from: device.deviceId) != nil { score += 1_000 }
        if stableFingerprintPayload(from: device.pubKeyFP) != nil { score += 800 }
        if device.networkLinkStatus != nil { score += 300 }
        if device.signalStrength != nil { score += 120 }
        if device.ipv4 != nil { score += 80 }
        if device.ipv6 != nil { score += 60 }
        score += min(device.services.count, 20) * 4
        score += min(device.portMap.count, 20) * 4
        score += min(device.routeIdentifiers.count, 20) * 2
        if device.platformName != nil { score += 8 }
        if device.osVersion != nil { score += 8 }
        if device.modelName != nil { score += 8 }
        if !device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += min(device.name.count, 40)
        }
        return score
    }

    private static func stablePresentationKey(for device: DiscoveredDevice) -> String? {
        if let deviceId = stableIdentityPayload(from: device.deviceId) {
            return "id:\(deviceId)"
        }
        if let fingerprint = stableFingerprintPayload(from: device.pubKeyFP) {
            return "fp:\(fingerprint)"
        }

        for raw in [device.uniqueIdentifier] + device.routeIdentifiers.map(Optional.some) {
            guard let raw else { continue }
            if let deviceId = stableIdentityAliasPayload(from: raw) {
                return "id:\(deviceId)"
            }
            if let fingerprint = stableFingerprintAliasPayload(from: raw) {
                return "fp:\(fingerprint)"
            }
            if let serial = stableSerialPayload(from: raw) {
                return "serial:\(serial)"
            }
        }

        if let routeKey = stableBonjourRouteKey(for: device) {
            return routeKey
        }
        if let ipKey = stableIPAddressKey(for: device) {
            return ipKey
        }
        return nil
    }

    private static func stableIdentityPayload(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let payload: String
        if trimmed.lowercased().hasPrefix("id:") {
            payload = String(trimmed.dropFirst(3))
        } else {
            payload = trimmed
        }
        let normalized = payload.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count >= 8 else { return nil }
        return normalized
    }

    private static func stableIdentityAliasPayload(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.lowercased().hasPrefix("id:") else {
            return nil
        }
        return stableIdentityPayload(from: trimmed)
    }

    private static func stableFingerprintPayload(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let payload: String
        if trimmed.lowercased().hasPrefix("fp:") {
            payload = String(trimmed.dropFirst(3))
        } else {
            payload = trimmed
        }
        let normalized = payload.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.range(of: "^[0-9a-f]{16,128}$", options: .regularExpression) != nil else {
            return nil
        }
        return normalized
    }

    private static func stableFingerprintAliasPayload(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.lowercased().hasPrefix("fp:") else {
            return nil
        }
        return stableFingerprintPayload(from: trimmed)
    }

    private static func stableSerialPayload(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.lowercased().hasPrefix("serial:") else {
            return nil
        }
        let payload = String(trimmed.dropFirst("serial:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard payload.count >= 4 else { return nil }
        return payload
    }

    private static func stableBonjourRouteKey(for device: DiscoveredDevice) -> String? {
        let candidates = [device.uniqueIdentifier] + device.routeIdentifiers.map(Optional.some)
        for candidate in candidates {
            guard let normalized = normalizedBonjourIdentifier(candidate) else { continue }
            return "bonjour:\(normalized)"
        }
        return nil
    }

    private static func normalizedBonjourIdentifier(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("recent:") {
            value = String(value.dropFirst("recent:".count))
        }
        guard value.hasPrefix("bonjour:") else { return nil }
        let payload = String(value.dropFirst("bonjour:".count))
        guard payload.contains("@"), payload.count >= 4 else { return nil }
        return payload
    }

    private static func stableIPAddressKey(for device: DiscoveredDevice) -> String? {
        if let ipv4 = normalizedIPAddress(device.ipv4) {
            return "ip:\(ipv4)"
        }
        if let ipv6 = normalizedIPAddress(device.ipv6) {
            return "ip:\(ipv6)"
        }
        return nil
    }

    private static func normalizedIPAddress(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return nil
        }
        let unscoped = raw.split(separator: "%", maxSplits: 1).first.map(String.init) ?? raw
        guard IPv4Address(unscoped) != nil || IPv6Address(unscoped) != nil else {
            return nil
        }
        return unscoped
    }
    
 /// 处理传输进度更新
    private func handleTransferProgressUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let transferId = userInfo["transferId"] as? String,
              let fileName = userInfo["fileName"] as? String,
              let progress = userInfo["progress"] as? Double,
              let speed = userInfo["speed"] as? Double,
              let transferredBytes = Self.int64UserInfoValue(userInfo["transferredBytes"]),
              let totalBytes = Self.int64UserInfoValue(userInfo["totalBytes"]) else {
            return
        }
        
 // 更新或添加传输项
        if let index = activeTransfers.firstIndex(where: { $0.id == transferId }) {
            activeTransfers[index] = MenuBarTransferItem(
                id: transferId,
                fileName: fileName,
                progress: progress,
                speed: speed,
                transferredBytes: transferredBytes,
                totalBytes: totalBytes,
                state: .transferring
            )
        } else {
            activeTransfers.append(MenuBarTransferItem(
                id: transferId,
                fileName: fileName,
                progress: progress,
                speed: speed,
                transferredBytes: transferredBytes,
                totalBytes: totalBytes,
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
                transferredBytes: item.transferredBytes,
                totalBytes: item.totalBytes,
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
            let totalBytes = activeTransfers.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
            let totalProgress: Double
            if totalBytes > 0 {
                let transferredBytes = activeTransfers.reduce(Int64(0)) { total, item in
                    total + max(0, min(item.transferredBytes, item.totalBytes))
                }
                totalProgress = Double(transferredBytes) / Double(totalBytes)
            } else {
                totalProgress = activeTransfers.allSatisfy { $0.progress >= 1.0 } ? 1.0 : 0.0
            }
            iconState = .transferring(progress: totalProgress)
        }
    }

    private static func int64UserInfoValue(_ value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? NSNumber {
            return value.int64Value
        }
        return nil
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
