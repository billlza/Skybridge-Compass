import Foundation
import OSLog
import Combine
import Network
import CoreBluetooth

/// 统一设备发现管理器
///
/// 功能特性：
/// 1. 整合多种设备发现方式（网络、USB、蓝牙）
/// 2. 智能设备去重，合并同一设备的多种连接方式
/// 3. 实时更新设备连接状态
/// 4. 符合 Swift 6.2 并发最佳实践
///
/// 适配：macOS 14.0+, macOS 15.0+, macOS 26.0

// MARK: - 扫描范围模式

/// 设备发现范围模式
///
/// 控制设备扫描和过滤的行为：
/// - skyBridgeOnly: 只关注 SkyBridge 对端设备（优化性能，减少网络负载）
/// - generalDevices: 扫描局域网设备，但 UI 默认隐藏打印机/摄像头等外设
/// - fullCompatible: 完全兼容模式，显示所有设备类型
public enum DiscoveryScopeMode: String, Codable, Sendable {
    case skyBridgeOnly = "仅 SkyBridge"
    case generalDevices = "常规设备"
    case fullCompatible = "完全兼容"
    
 /// 用户友好的描述
    public var description: String {
        switch self {
        case .skyBridgeOnly:
            return "只显示 SkyBridge 对端设备，性能最优"
        case .generalDevices:
            return "显示电脑、手机等常规设备，隐藏打印机和摄像头"
        case .fullCompatible:
            return "显示所有设备类型，包括打印机、摄像头和 IoT 设备"
        }
    }
}

@MainActor
public final class UnifiedDeviceDiscoveryManager: ObservableObject {
    
 // MARK: - 发布属性
    
 /// 统一的设备列表（已去重和合并）
    @Published public private(set) var unifiedDevices: [UnifiedDevice] = []
    
 /// 扫描状态
    @Published public private(set) var isScanning = false
    
 /// 扫描进度
    @Published public private(set) var scanProgress: ScanProgress = .idle
    
 /// 扫描范围模式（控制设备过滤和显示范围）
    @Published public var scopeMode: DiscoveryScopeMode = .skyBridgeOnly

 /// 服务运行态
    @Published public private(set) var serviceState: ServiceState = .idle
    
 /// 权限状态（综合：网络/USB/蓝牙）
    @Published public private(set) var permissionState: PermissionState = .unknown
    
 /// 详细权限状态（为避免与全局权限模型冲突，使用 Discovery 命名）
    @Published public private(set) var detailedPermissions: DiscoveryDetailedPermissions = DiscoveryDetailedPermissions()
    
 // MARK: - 子管理器
    
    private let networkDiscovery = DeviceDiscoveryManagerOptimized()
    private let usbDiscovery = USBDeviceDiscoveryManager()
    private let orchestrator = DiscoveryOrchestrator()
    
 // MARK: - 私有属性
    
    private let logger = Logger(
        subsystem: "com.skybridge.unified",
        category: "DeviceDiscovery"
    )
    
 /// 设备去重映射表：uniqueIdentifier -> UnifiedDevice
    private var deviceMap: [String: UnifiedDevice] = [:]
    
 /// 订阅集合
    private var cancellables = Set<AnyCancellable>()
    
 // MARK: - 初始化
    
    public init() {
        logger.info("🚀 初始化统一设备发现管理器")
        setupObservers()
    }
    
 // MARK: - 公开方法
    
 /// 开始扫描所有类型的设备
    public func startScanning(options: DiscoveryOptions = DiscoveryOptions()) {
        guard !isScanning else {
            logger.warning("⚠️ 扫描已在进行中")
            return
        }
        
        logger.info("🔍 开始统一扫描")
        isScanning = true
        scanProgress = .scanning(progress: 0.0)
        serviceState = .running
        
 // 清空设备列表
        deviceMap.removeAll()
        unifiedDevices.removeAll()
        
 // 预检权限（简化：默认网络/USB可用；若启用蓝牙则标记为未知，等待外部注入真实结果）
        updatePermissionState(enableBluetooth: options.enableBluetooth)

        Task { [weak self] in
            guard let self else { return }
            await orchestrator.start(options: options, network: { [weak self] in
                await MainActor.run { self?.networkDiscovery.startScanning() }
            }, usb: { [weak self] in
                await MainActor.run {
                    self?.usbDiscovery.startMonitoring()
                    self?.usbDiscovery.scanUSBDevices()
                }
            }, bluetooth: {
 // 预留：如需启用蓝牙扫描，在此接入 BluetoothManager.startScanning()
            })
        }
        
 // 进度模拟（可替换为真实进度）
        Task { await updateScanProgress() }
    }
    
 /// 停止扫描
    public func stopScanning() {
        logger.info("⏹️ 停止统一扫描")
        
        networkDiscovery.stopScanning()
        usbDiscovery.stopMonitoring()
        Task { await orchestrator.stop() }
        
        isScanning = false
        scanProgress = .completed
        serviceState = .stopped
    }
    
 /// 刷新设备列表
    public func refreshDevices() {
        logger.info("🔄 刷新设备列表")
        stopScanning()
        
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
            startScanning()
        }
    }
    
 /// 根据唯一标识符查找设备
    public func device(withIdentifier identifier: String) -> UnifiedDevice? {
        return deviceMap[identifier]
    }
    
 /// 根据ID查找设备
    public func device(withId id: UUID) -> UnifiedDevice? {
        return unifiedDevices.first { $0.id == id }
    }
    
 // MARK: - 私有方法
    
 /// 设置观察者
    private func setupObservers() {
 // 观察网络设备变化
        networkDiscovery.$discoveredDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                self?.handleNetworkDevicesUpdate(devices)
            }
            .store(in: &cancellables)
        
 // 观察 USB 设备变化
        usbDiscovery.$usbDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                self?.handleUSBDevicesUpdate(devices)
            }
            .store(in: &cancellables)
    }
    
 /// 处理网络设备更新
    private func handleNetworkDevicesUpdate(_ devices: [DiscoveredDevice]) {
        logger.debug("📡 网络设备更新: \(devices.count) 台")
        
        for device in devices {
 // 推断连接类型
            let connectionType = inferNetworkConnectionType(device)
            
 // 生成唯一标识符
            let identifier = generateUniqueIdentifier(
                name: device.name,
                ipv4: device.ipv4,
                ipv6: device.ipv6,
                serialNumber: nil
            )
            
 // 合并或创建设备
            mergeOrCreateDevice(
                identifier: identifier,
                name: device.name,
                ipv4: device.ipv4,
                ipv6: device.ipv6,
                serialNumber: nil,
                connectionType: connectionType,
                deviceType: device.deviceType,
                services: device.services,
                portMap: device.portMap,
                sourceDevice: .network(device)
            )
        }
        
        updateUnifiedDevicesList()
    }
    
 /// 处理 USB 设备更新
    private func handleUSBDevicesUpdate(_ devices: [USBDevice]) {
        logger.debug("🔌 USB 设备更新: \(devices.count) 台")
        
        for device in devices {
 // 生成唯一标识符（优先使用序列号）
            let identifier = device.serialNumber ?? device.id
            
 // 合并或创建设备
            mergeOrCreateDevice(
                identifier: identifier,
                name: device.name,
                ipv4: nil,
                ipv6: nil,
                serialNumber: device.serialNumber,
                connectionType: .usb,
                deviceType: mapUSBDeviceType(device.deviceType),
                services: [],
                portMap: [:],
                sourceDevice: .usb(device)
            )
        }
        
        updateUnifiedDevicesList()
    }
    
 /// 合并或创建设备
    private func mergeOrCreateDevice(
        identifier: String,
        name: String,
        ipv4: String?,
        ipv6: String?,
        serialNumber: String?,
        connectionType: DeviceConnectionType,
        deviceType: DeviceClassifier.DeviceType,
        services: [String],
        portMap: [String: Int],
        sourceDevice: SourceDevice
    ) {
        if var existingDevice = deviceMap[identifier] {
 // 设备已存在，合并连接方式
            existingDevice.connectionTypes.insert(connectionType)
            
 // 更新IP地址（如果有新的）
            if let ipv4 = ipv4, existingDevice.ipv4 == nil {
                existingDevice.ipv4 = ipv4
            }
            if let ipv6 = ipv6, existingDevice.ipv6 == nil {
                existingDevice.ipv6 = ipv6
            }
            
 // 合并服务和端口
            existingDevice.services.append(contentsOf: services)
            existingDevice.portMap.merge(portMap) { current, _ in current }
            
 // 添加源设备
            existingDevice.sourceDevices.append(sourceDevice)
            
 // 更新最后发现时间
            existingDevice.lastSeen = Date()
            
            deviceMap[identifier] = existingDevice
            
            logger.debug("🔄 合并设备: \(name) - 新增连接方式: \(connectionType.rawValue)")
        } else {
 // 创建新设备
            let newDevice = UnifiedDevice(
                id: UUID(),
                name: name,
                ipv4: ipv4,
                ipv6: ipv6,
                serialNumber: serialNumber,
                connectionTypes: [connectionType],
                deviceType: deviceType,
                services: services,
                portMap: portMap,
                uniqueIdentifier: identifier,
                sourceDevices: [sourceDevice],
                discoveredAt: Date(),
                lastSeen: Date()
            )
            
            deviceMap[identifier] = newDevice
            
            logger.info("✅ 发现新设备: \(name) - 连接方式: \(connectionType.rawValue)")
        }
    }
    
 /// 更新统一设备列表
    private func updateUnifiedDevicesList() {
 // 过滤掉长时间未见的设备（超过60秒）
        let now = Date()
        let validDevices = deviceMap.values.filter { device in
            now.timeIntervalSince(device.lastSeen) < 60
        }
        
 // 按名称排序
        unifiedDevices = validDevices.sorted { $0.name < $1.name }
        
        logger.debug("📊 统一设备列表更新: \(self.unifiedDevices.count) 台")
    }
    
 /// 推断网络连接类型
    private func inferNetworkConnectionType(_ device: DiscoveredDevice) -> DeviceConnectionType {
 // 根据接口类型、服务类型等推断连接方式
        if device.services.contains("_companion-link._tcp") {
 // Apple Continuity 通常是 Wi-Fi
            return .wifi
        }
        
        if device.services.contains("_airplay._tcp") {
            return .wifi
        }
        
 // 默认认为是 Wi-Fi（可以后续增强）
        return .wifi
    }
    
 /// 映射 USB 设备类型到通用设备类型
    private func mapUSBDeviceType(_ usbType: USBDeviceType) -> DeviceClassifier.DeviceType {
        switch usbType {
        case .iPhone:
            return .computer // 或创建新的 iPhone 类型
        case .iPad:
            return .computer
        case .androidDevice:
            return .computer
        case .storage:
            return .nas
        case .camera:
            return .camera
        case .keyboard, .mouse:
            return .iot
        case .audio:
            return .speaker
        default:
            return .unknown
        }
    }
    
 /// 生成唯一标识符
    private func generateUniqueIdentifier(
        name: String,
        ipv4: String?,
        ipv6: String?,
        serialNumber: String?
    ) -> String {
 // 优先使用序列号
        if let serialNumber = serialNumber {
            return "serial:\(serialNumber)"
        }
        
 // 使用 MAC 地址（从名称或IP中提取，如果有）
 // 简化实现：使用IP地址 + 名称的组合
        if let ipv4 = ipv4 {
            return "ip:\(ipv4)"
        }
        
        if let ipv6 = ipv6 {
            return "ip:\(ipv6)"
        }
        
 // 最后使用名称（可能导致误判，但总比没有好）
        return "name:\(name)"
    }
    
 /// 更新扫描进度
    private func updateScanProgress() async {
        for i in 1...10 {
            guard isScanning else { break }
            
            await MainActor.run {
                scanProgress = .scanning(progress: Double(i) / 10.0)
            }
            
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3秒
        }
        
        await MainActor.run {
            if isScanning {
                scanProgress = .completed
            }
        }
    }

    private func updatePermissionState(enableBluetooth: Bool) {
 // 检查蓝牙权限
        var bluetoothPermissionStatus = DiscoveryPermissionStatus.unknown
        if enableBluetooth {
 // 通过CBManager检查蓝牙权限
            switch CBManager.authorization {
            case .allowedAlways:
                bluetoothPermissionStatus = .granted
            case .denied, .restricted:
                bluetoothPermissionStatus = .denied
            case .notDetermined:
                bluetoothPermissionStatus = .notDetermined
            @unknown default:
                bluetoothPermissionStatus = .unknown
            }
        }
        
 // 更新详细权限状态
        detailedPermissions.bluetooth = bluetoothPermissionStatus
        detailedPermissions.network = .granted // 网络权限默认授予
        detailedPermissions.usb = .granted // USB权限默认授予
        
 // 综合评估权限状态
        if detailedPermissions.bluetooth == .denied || detailedPermissions.network == .denied || detailedPermissions.usb == .denied {
            permissionState = .denied
        } else if detailedPermissions.bluetooth == .granted && detailedPermissions.network == .granted && detailedPermissions.usb == .granted {
            permissionState = .granted
        } else if detailedPermissions.bluetooth == .notDetermined {
            permissionState = .partiallyGranted
        } else {
            permissionState = .unknown
        }
    }
}

/// 发现权限状态（避免与 DevicePermissionManager.PermissionStatus 冲突）
public enum DiscoveryPermissionStatus: String, Sendable {
    case unknown = "未知"
    case notDetermined = "未确定"
    case granted = "已授予"
    case denied = "已拒绝"
}

/// 发现详细权限信息
public struct DiscoveryDetailedPermissions: Sendable {
    public var network: DiscoveryPermissionStatus = .unknown
    public var usb: DiscoveryPermissionStatus = .unknown
    public var bluetooth: DiscoveryPermissionStatus = .unknown
    
    public init(network: DiscoveryPermissionStatus = .unknown, usb: DiscoveryPermissionStatus = .unknown, bluetooth: DiscoveryPermissionStatus = .unknown) {
        self.network = network
        self.usb = usb
        self.bluetooth = bluetooth
    }
}

// MARK: - 统一设备模型

/// 统一设备（合并了多种连接方式的设备）
public struct UnifiedDevice: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var ipv4: String?
    public var ipv6: String?
    public var serialNumber: String?
    public var connectionTypes: Set<DeviceConnectionType>
    public var deviceType: DeviceClassifier.DeviceType
    public var services: [String]
    public var portMap: [String: Int]
    public let uniqueIdentifier: String
    public var sourceDevices: [SourceDevice]
    public let discoveredAt: Date
    public var lastSeen: Date
    
 /// 主要连接方式（优先级最高的）
    public var primaryConnectionType: DeviceConnectionType {
 // 优先级：雷雳 > 有线 > USB > Wi-Fi > 蓝牙
        if connectionTypes.contains(.thunderbolt) { return .thunderbolt }
        if connectionTypes.contains(.ethernet) { return .ethernet }
        if connectionTypes.contains(.usb) { return .usb }
        if connectionTypes.contains(.wifi) { return .wifi }
        if connectionTypes.contains(.bluetooth) { return .bluetooth }
        return .unknown
    }
    
 /// 连接方式描述（用于UI显示）
    public var connectionTypesDescription: String {
        let types = connectionTypes.sorted { lhs, rhs in
 // 按优先级排序
            let priority: [DeviceConnectionType] = [.thunderbolt, .ethernet, .usb, .wifi, .bluetooth, .unknown]
            let lhsIndex = priority.firstIndex(of: lhs) ?? priority.count
            let rhsIndex = priority.firstIndex(of: rhs) ?? priority.count
            return lhsIndex < rhsIndex
        }
        return types.map { $0.rawValue }.joined(separator: " + ")
    }
    
 /// 是否有多种连接方式
    public var hasMultipleConnections: Bool {
        return connectionTypes.count > 1
    }
    
    public static func == (lhs: UnifiedDevice, rhs: UnifiedDevice) -> Bool {
        lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// 源设备（用于追溯设备来源）
public enum SourceDevice: Hashable, Sendable {
    case network(DiscoveredDevice)
    case usb(USBDevice)
}

/// 扫描进度
public enum ScanProgress: Equatable, Sendable {
    case idle
    case scanning(progress: Double)
    case completed
    
    public var description: String {
        switch self {
        case .idle:
            return "空闲"
        case .scanning(let progress):
            return String(format: "扫描中... %.0f%%", progress * 100)
        case .completed:
            return "扫描完成"
        }
    }
}

/// 服务运行态
public enum ServiceState: String, Sendable {
    case idle
    case running
    case stopped
}

/// 权限汇总状态
public enum PermissionState: String, Sendable {
    case unknown
    case granted
    case partiallyGranted
    case denied
}

