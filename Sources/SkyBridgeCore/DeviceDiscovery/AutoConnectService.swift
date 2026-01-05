//
// AutoConnectService.swift
// SkyBridgeCore
//
// 自动连接服务
// 实现已配对设备的自动连接功能
//

import Foundation
import OSLog
import Combine

/// 配对设备信息
public struct PairedDevice: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let deviceType: String
    public let lastConnected: Date
    public let trustLevel: TrustLevel
    public let publicKeyFingerprint: String?
    
    public enum TrustLevel: String, Codable, Sendable {
        case trusted = "trusted"
        case verified = "verified"
        case unknown = "unknown"
    }
    
    public init(id: String, name: String, deviceType: String, lastConnected: Date = Date(), trustLevel: TrustLevel = .unknown, publicKeyFingerprint: String? = nil) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.lastConnected = lastConnected
        self.trustLevel = trustLevel
        self.publicKeyFingerprint = publicKeyFingerprint
    }
}

/// 自动连接服务 - 管理已配对设备的自动连接
/// 实现 autoConnectPairedDevices 功能
@MainActor
public class AutoConnectService: ObservableObject {
    
    public static let shared = AutoConnectService()
    
 // MARK: - 发布属性
    
    @Published public var autoConnectEnabled: Bool = true {
        didSet {
            let enabled = autoConnectEnabled
            logger.info("🔗 自动连接已配对设备已\(enabled ? "启用" : "禁用")")
            if enabled {
                startAutoConnectMonitoring()
            } else {
                stopAutoConnectMonitoring()
            }
        }
    }
    
    @Published public var pairedDevices: [PairedDevice] = []
    @Published public var autoConnectedDevices: Set<String> = []
    @Published public var pendingConnections: Set<String> = []
    @Published public var connectionAttempts: [String: Int] = [:]
    
 // MARK: - 配置
    
 /// 最大自动重连尝试次数
    public var maxAutoConnectAttempts: Int = 3
 /// 自动连接检查间隔（秒）
    public var autoConnectInterval: TimeInterval = 10.0
 /// 连接超时时间（秒）
    public var connectionTimeout: TimeInterval = 30.0
    
 // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "com.skybridge.device", category: "AutoConnect")
    private var cancellables = Set<AnyCancellable>()
    private var monitoringTask: Task<Void, Never>?
    private let userDefaultsKey = "PairedDevices"
    
    private init() {
        loadPairedDevices()
        setupSettingsObserver()
        setupDeviceDiscoveryObserver()
    }
    
 // MARK: - 初始化
    
    private func setupSettingsObserver() {
 // 监听设置变化
        SettingsManager.shared.$autoConnectPairedDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.autoConnectEnabled = enabled
            }
            .store(in: &cancellables)
    }
    
    private func setupDeviceDiscoveryObserver() {
 // 监听设备发现事件
        NotificationCenter.default.publisher(for: .deviceDiscovered)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let device = notification.userInfo?["device"] as? DiscoveredDevice {
                    self?.handleDiscoveredDevice(device)
                }
            }
            .store(in: &cancellables)
    }
    
 // MARK: - 配对设备管理
    
    private func loadPairedDevices() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            logger.info("📋 无已保存的配对设备")
            return
        }
        
        do {
            let devices = try JSONDecoder().decode([PairedDevice].self, from: data)
            pairedDevices = devices
            logger.info("📋 加载了 \(devices.count) 个配对设备")
        } catch {
            logger.error("❌ 加载配对设备失败: \(error.localizedDescription)")
        }
    }
    
    private func savePairedDevices() {
        do {
            let data = try JSONEncoder().encode(pairedDevices)
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
            logger.debug("💾 保存了 \(self.pairedDevices.count) 个配对设备")
        } catch {
            logger.error("❌ 保存配对设备失败: \(error.localizedDescription)")
        }
    }
    
 /// 添加配对设备
    public func addPairedDevice(_ device: DiscoveredDevice, trustLevel: PairedDevice.TrustLevel = .unknown) {
 // 检查是否已存在
        if pairedDevices.contains(where: { $0.id == device.id.uuidString }) {
 // 更新最后连接时间
            if let index = pairedDevices.firstIndex(where: { $0.id == device.id.uuidString }) {
                let existing = pairedDevices[index]
                pairedDevices[index] = PairedDevice(
                    id: existing.id,
                    name: device.name,
                    deviceType: device.deviceType.rawValue,
                    lastConnected: Date(),
                    trustLevel: existing.trustLevel,
                    publicKeyFingerprint: device.pubKeyFP ?? existing.publicKeyFingerprint
                )
            }
        } else {
 // 添加新设备
            let pairedDevice = PairedDevice(
                id: device.id.uuidString,
                name: device.name,
                deviceType: device.deviceType.rawValue,
                lastConnected: Date(),
                trustLevel: trustLevel,
                publicKeyFingerprint: device.pubKeyFP
            )
            pairedDevices.append(pairedDevice)
            logger.info("➕ 已添加配对设备: \(device.name)")
        }
        
        savePairedDevices()
    }
    
 /// 移除配对设备
    public func removePairedDevice(id: String) {
        pairedDevices.removeAll { $0.id == id }
        autoConnectedDevices.remove(id)
        connectionAttempts.removeValue(forKey: id)
        savePairedDevices()
        logger.info("➖ 已移除配对设备: \(id)")
    }
    
 /// 检查设备是否已配对
    public func isPaired(_ deviceId: String) -> Bool {
        return pairedDevices.contains { $0.id == deviceId }
    }
    
 /// 更新设备信任级别
    public func updateTrustLevel(deviceId: String, trustLevel: PairedDevice.TrustLevel) {
        if let index = pairedDevices.firstIndex(where: { $0.id == deviceId }) {
            let device = pairedDevices[index]
            pairedDevices[index] = PairedDevice(
                id: device.id,
                name: device.name,
                deviceType: device.deviceType,
                lastConnected: device.lastConnected,
                trustLevel: trustLevel,
                publicKeyFingerprint: device.publicKeyFingerprint
            )
            savePairedDevices()
            logger.info("🔒 已更新设备信任级别: \(device.name) -> \(trustLevel.rawValue)")
        }
    }
    
 // MARK: - 自动连接逻辑
    
 /// 处理发现的设备
    private func handleDiscoveredDevice(_ device: DiscoveredDevice) {
        guard autoConnectEnabled else { return }
        
        let deviceId = device.id.uuidString
        
 // 检查是否为已配对设备
        guard let pairedDevice = pairedDevices.first(where: { $0.id == deviceId }) else {
            return
        }
        
 // 检查是否已连接或正在连接
        guard !autoConnectedDevices.contains(deviceId),
              !pendingConnections.contains(deviceId) else {
            return
        }
        
 // 检查连接尝试次数
        let attempts = connectionAttempts[deviceId] ?? 0
        guard attempts < maxAutoConnectAttempts else {
            logger.warning("⚠️ 设备 \(pairedDevice.name) 已达到最大连接尝试次数")
            return
        }
        
 // 检查信任级别
        if pairedDevice.trustLevel == .unknown {
            logger.info("⚠️ 设备 \(pairedDevice.name) 信任级别未知，跳过自动连接")
            return
        }
        
 // 发起自动连接
        logger.info("🔗 发起自动连接到配对设备: \(pairedDevice.name)")
        initiateAutoConnect(to: device)
    }
    
 /// 发起自动连接
    private func initiateAutoConnect(to device: DiscoveredDevice) {
        let deviceId = device.id.uuidString
        
        pendingConnections.insert(deviceId)
        connectionAttempts[deviceId] = (connectionAttempts[deviceId] ?? 0) + 1
        
        Task {
            do {
 // 尝试连接设备
                try await connectToDevice(device)
                
                await MainActor.run {
                    self.pendingConnections.remove(deviceId)
                    self.autoConnectedDevices.insert(deviceId)
                    self.connectionAttempts.removeValue(forKey: deviceId)
                    
 // 更新最后连接时间
                    if let index = self.pairedDevices.firstIndex(where: { $0.id == deviceId }) {
                        let existing = self.pairedDevices[index]
                        self.pairedDevices[index] = PairedDevice(
                            id: existing.id,
                            name: existing.name,
                            deviceType: existing.deviceType,
                            lastConnected: Date(),
                            trustLevel: existing.trustLevel,
                            publicKeyFingerprint: existing.publicKeyFingerprint
                        )
                        self.savePairedDevices()
                    }
                    
                    self.logger.info("✅ 自动连接成功: \(device.name)")
                    
 // 发送通知
                    NotificationCenter.default.post(
                        name: .deviceAutoConnected,
                        object: nil,
                        userInfo: ["device": device]
                    )
                }
                
            } catch {
                await MainActor.run {
                    self.pendingConnections.remove(deviceId)
                    self.logger.warning("⚠️ 自动连接失败: \(device.name) - \(error.localizedDescription)")
                    
 // 发送失败通知
                    NotificationCenter.default.post(
                        name: .deviceAutoConnectFailed,
                        object: nil,
                        userInfo: ["device": device, "error": error]
                    )
                }
            }
        }
    }
    
 /// 连接到设备
    private func connectToDevice(_ device: DiscoveredDevice) async throws {
 // 使用 DeviceDiscoveryManagerOptimized 进行连接
        let discoveryManager = DeviceDiscoveryManagerOptimized()
        
 // 设置连接超时
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(connectionTimeout * 1_000_000_000))
            throw AutoConnectError.connectionTimeout
        }
        
        let connectTask = Task {
            try await discoveryManager.connectToDevice(device)
        }
        
 // 等待连接或超时
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await connectTask.value
                }
                
                group.addTask {
                    try await timeoutTask.value
                }
                
 // 等待第一个完成的任务
                _ = try await group.next()
                
 // 取消其他任务
                group.cancelAll()
            }
        } catch {
            timeoutTask.cancel()
            connectTask.cancel()
            throw error
        }
    }
    
 // MARK: - 监控
    
 /// 启动自动连接监控
    public func startAutoConnectMonitoring() {
        guard autoConnectEnabled else { return }
        
        stopAutoConnectMonitoring()
        
        logger.info("🔄 启动自动连接监控")
        
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkForPairedDevices()
                
                do {
                    try await Task.sleep(nanoseconds: UInt64((self?.autoConnectInterval ?? 10) * 1_000_000_000))
                } catch {
                    break
                }
            }
        }
    }
    
 /// 停止自动连接监控
    public func stopAutoConnectMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        logger.info("⏹️ 停止自动连接监控")
    }
    
 /// 检查可连接的配对设备
    private func checkForPairedDevices() async {
 // 获取当前发现的设备列表
 // 这里应该从设备发现服务获取
 // 简化实现：发送检查请求
        NotificationCenter.default.post(name: .checkPairedDevicesAvailability, object: nil)
    }
    
 /// 手动触发自动连接检查
    public func triggerAutoConnectCheck() {
        Task {
            await checkForPairedDevices()
        }
    }
    
 /// 重置连接尝试计数
    public func resetConnectionAttempts(for deviceId: String? = nil) {
        if let id = deviceId {
            connectionAttempts.removeValue(forKey: id)
        } else {
            connectionAttempts.removeAll()
        }
        logger.info("🔄 重置连接尝试计数")
    }
    
 /// 断开自动连接的设备
    public func disconnectAutoConnectedDevice(_ deviceId: String) {
        autoConnectedDevices.remove(deviceId)
        logger.info("🔌 已断开自动连接设备: \(deviceId)")
    }
}

// MARK: - 错误类型

public enum AutoConnectError: LocalizedError {
    case connectionTimeout
    case deviceNotFound
    case connectionRefused
    case trustLevelInsufficient
    
    public var errorDescription: String? {
        switch self {
        case .connectionTimeout:
            return "连接超时"
        case .deviceNotFound:
            return "设备未找到"
        case .connectionRefused:
            return "连接被拒绝"
        case .trustLevelInsufficient:
            return "信任级别不足"
        }
    }
}

// MARK: - 通知扩展

public extension Notification.Name {
    static let deviceAutoConnected = Notification.Name("com.skybridge.deviceAutoConnected")
    static let deviceAutoConnectFailed = Notification.Name("com.skybridge.deviceAutoConnectFailed")
    static let deviceDiscovered = Notification.Name("com.skybridge.deviceDiscovered")
    static let checkPairedDevicesAvailability = Notification.Name("com.skybridge.checkPairedDevicesAvailability")
}

