import Foundation
import CoreBluetooth
import Combine
import os.log

/// 蓝牙设备信息模型
public struct BluetoothDevice: Identifiable, Hashable, Equatable, Sendable {
    public let id = UUID()
    public let identifier: UUID
    public let name: String?
    public let rssi: Int
    public let isConnectable: Bool
    public let isConnected: Bool
    public let services: [String] // 修改为 Sendable 类型
    public let advertisementData: [String: String] // 修改为 Sendable 类型
    public let lastSeen: Date
    
    public init(
        identifier: UUID,
        name: String?,
        rssi: Int,
        isConnectable: Bool,
        isConnected: Bool,
        services: [String],
        advertisementData: [String: String],
        lastSeen: Date
    ) {
        self.identifier = identifier
        self.name = name
        self.rssi = rssi
        self.isConnectable = isConnectable
        self.isConnected = isConnected
        self.services = services
        self.advertisementData = advertisementData
        self.lastSeen = lastSeen
    }
    
 // MARK: - Hashable & Equatable
    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
    
    public static func == (lhs: BluetoothDevice, rhs: BluetoothDevice) -> Bool {
        return lhs.identifier == rhs.identifier
    }
    
 /// 显示名称
    public var displayName: String {
        return name ?? "未知设备"
    }
    
 /// 信号强度描述
    public var signalStrengthDescription: String {
        switch rssi {
        case -30...0:
            return "优秀"
        case -50...(-30):
            return "良好"
        case -70...(-50):
            return "一般"
        case -90...(-70):
            return "较差"
        default:
            return "很差"
        }
    }
    
 /// 信号强度百分比
    public var signalStrengthPercentage: Double {
        let normalizedRSSI = max(-100, min(0, rssi))
        return Double(normalizedRSSI + 100)
    }
    
 /// 设备类型描述
    public var deviceTypeDescription: String {
 // 根据服务UUID判断设备类型
        for service in services {
            switch service.uppercased() {
            case "180F":
                return "电池服务设备"
            case "180A":
                return "设备信息服务"
            case "1800":
                return "通用访问服务"
            case "1801":
                return "通用属性服务"
            case "110A", "110B", "110C", "110D":
                return "音频设备"
            case "1812":
                return "人机接口设备"
            default:
                continue
            }
        }
        
 // 根据广告数据判断设备类型
        if let localName = advertisementData[CBAdvertisementDataLocalNameKey] {
            let lowercaseName = localName.lowercased()
            if lowercaseName.contains("airpods") || lowercaseName.contains("headphone") {
                return "音频设备"
            } else if lowercaseName.contains("keyboard") {
                return "键盘"
            } else if lowercaseName.contains("mouse") {
                return "鼠标"
            } else if lowercaseName.contains("watch") {
                return "智能手表"
            }
        }
        
        return "蓝牙设备"
    }
}

/// 蓝牙错误类型
public enum BluetoothError: LocalizedError {
    case bluetoothNotAvailable
    case deviceNotFound
    case connectionFailed
    case scanningFailed
    case permissionDenied
    
    public var errorDescription: String? {
        switch self {
        case .bluetoothNotAvailable:
            return "蓝牙不可用"
        case .deviceNotFound:
            return "设备未找到"
        case .connectionFailed:
            return "连接失败"
        case .scanningFailed:
            return "扫描失败"
        case .permissionDenied:
            return "权限被拒绝"
        }
    }
}

/// 蓝牙管理器状态
public enum BluetoothManagerState {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
    
    public var description: String {
        switch self {
        case .unknown:
            return "未知状态"
        case .resetting:
            return "重置中"
        case .unsupported:
            return "不支持"
        case .unauthorized:
            return "未授权"
        case .poweredOff:
            return "蓝牙已关闭"
        case .poweredOn:
            return "蓝牙已开启"
        }
    }
}

/// 蓝牙管理器 - 负责蓝牙设备的扫描、连接和管理
/// 使用 Swift 6.2 的 Actor 隔离和并发安全特性
@MainActor
public final class BluetoothManager: NSObject, ObservableObject, Sendable {
    
 // MARK: - 发布属性
    @Published public var discoveredDevices: [BluetoothDevice] = []
    @Published public var connectedDevices: [BluetoothDevice] = []
    @Published public var managerState: BluetoothManagerState = .unknown
    @Published public var isScanning = false
    @Published public var hasPermission = false
    
 // MARK: - 私有属性
 /// 蓝牙中央管理器 - 延迟初始化以避免阻塞主线程
 /// 使用 Optional 而非隐式解包，所有访问点都需要安全检查
    private var centralManager: CBCentralManager?
    private var connectedPeripherals: [UUID: CBPeripheral] = [:]
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "BluetoothManager")
    private var scanTimer: Timer?
    private let scanTimeout: TimeInterval = 30.0
    private var bluetoothCancellables = Set<AnyCancellable>()
    
 /// 标记 centralManager 是否已初始化
    private var isCentralManagerInitialized: Bool {
        centralManager != nil
    }
    
 /// 使用 Swift 6.2 的并发安全队列进行蓝牙操作
    private let bluetoothQueue = DispatchQueue(label: "com.skybridge.bluetooth-manager", qos: .userInitiated, attributes: .concurrent)
    
 // MARK: - 初始化
    public override init() {
        super.init()
        logger.info("📱 蓝牙管理器初始化完成")
        setupSettingsObservers()
 // 延迟初始化蓝牙管理器，避免阻塞主线程
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            DispatchQueue.main.async {
                self?.setupCentralManager()
            }
        }
    }
    
 // MARK: - 生命周期管理方法
    
 /// 启动蓝牙管理器
    public func start() async throws {
        checkPermissions()
        logger.info("📱 蓝牙管理器已启动")
    }
    
 /// 停止蓝牙管理器
    public func stop() async {
        stopScanning()
        logger.info("📱 蓝牙管理器已停止")
    }
    
 /// 清理资源
    public func cleanup() {
        stopScanning()
        bluetoothCancellables.removeAll()
        logger.info("📱 蓝牙管理器资源已清理")
    }
    
 // MARK: - 公共方法
    
 /// 开始扫描蓝牙设备
    public func startScanning() {
        guard let manager = centralManager else {
            logger.warning("蓝牙管理器未初始化，无法扫描设备")
            return
        }
        
        guard managerState == .poweredOn else {
            logger.warning("蓝牙未开启，无法扫描设备")
            return
        }
        
        guard !isScanning else {
            logger.info("已在扫描中")
            return
        }
        
 // 清空之前的发现设备列表
        discoveredDevices.removeAll()
        
 // 开始扫描所有设备
        manager.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
            CBCentralManagerScanOptionSolicitedServiceUUIDsKey: []
        ])
        
        isScanning = true
        
 // 设置扫描超时
        startScanTimeout()
        
        logger.info("开始扫描蓝牙设备")
    }
    
 /// 停止扫描蓝牙设备
    public func stopScanning() {
        guard isScanning else { return }
        
        centralManager?.stopScan()
        isScanning = false
        scanTimer?.invalidate()
        scanTimer = nil
        
        logger.info("停止扫描蓝牙设备")
    }
    
 /// 连接到指定蓝牙设备
 /// 使用 Swift 6.2 的并发安全特性
    public func connect(to device: BluetoothDevice) async throws {
        guard centralManager != nil else {
            logger.error("蓝牙管理器未初始化，无法连接设备")
            throw BluetoothError.bluetoothNotAvailable
        }
        
        guard managerState == .poweredOn else {
            logger.error("蓝牙未开启，无法连接设备")
            throw BluetoothError.bluetoothNotAvailable
        }
        
        logger.info("正在连接蓝牙设备: \(device.displayName)")
        
 // 在后台队列中查找设备
        guard let peripheralId = await findPeripheralSafely(with: device.identifier) else {
            throw BluetoothError.deviceNotFound
        }
        
 // 在 MainActor 上执行连接操作（BluetoothManager 已经是 @MainActor）
 // 从connectedPeripherals中获取实际的CBPeripheral对象
        if let actualPeripheral = connectedPeripherals[peripheralId] {
            centralManager?.connect(actualPeripheral, options: nil)
        } else {
 // 如果没有找到已连接的外围设备，尝试重新检索
            if let manager = centralManager {
                let peripherals = manager.retrievePeripherals(withIdentifiers: [peripheralId])
                if let foundPeripheral = peripherals.first {
                    manager.connect(foundPeripheral, options: nil)
                }
            }
        }
    }
    
 /// 线程安全的外围设备查找方法 - 返回CBPeripheral对象而不是UUID
    private func findPeripheralSafely(with identifier: UUID) async -> UUID? {
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                guard let manager = self.centralManager else {
                    continuation.resume(returning: nil)
                    return
                }
                let peripherals = manager.retrievePeripherals(withIdentifiers: [identifier])
                if let peripheral = peripherals.first {
 // 将找到的外围设备存储到connectedPeripherals中
                    self.connectedPeripherals[identifier] = peripheral
                }
                continuation.resume(returning: peripherals.first?.identifier)
            }
        }
    }
    
 /// 断开指定蓝牙设备连接
    public func disconnect(from device: BluetoothDevice) {
        guard let manager = centralManager else {
            logger.error("蓝牙管理器未初始化")
            return
        }
        
        guard let peripheral = connectedPeripherals[device.identifier] else {
            logger.error("设备未连接")
            return
        }
        
        manager.cancelPeripheralConnection(peripheral)
        logger.info("断开蓝牙设备连接: \(device.displayName)")
    }
    
 /// 刷新设备列表
    public func refreshDevices() {
        if isScanning {
            stopScanning()
        }
        startScanning()
    }
    
 /// 检查蓝牙权限
    public func checkPermissions() {
        switch CBManager.authorization {
        case .allowedAlways:
            hasPermission = true
            logger.info("蓝牙权限已获得")
        case .denied, .restricted:
            hasPermission = false
            logger.warning("蓝牙权限被拒绝")
        case .notDetermined:
            hasPermission = false
            logger.info("蓝牙权限未确定")
        @unknown default:
            hasPermission = false
            logger.warning("未知蓝牙权限状态")
        }
    }
    
 // MARK: - 私有方法
    
 /// 设置中央管理器
    private func setupCentralManager() {
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
 /// 查找外围设备
    private func findPeripheral(with identifier: UUID) -> CBPeripheral? {
        guard let manager = centralManager else { return nil }
        let peripherals = manager.retrievePeripherals(withIdentifiers: [identifier])
        return peripherals.first
    }
    
 /// 启动扫描超时
    private func startScanTimeout() {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: scanTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.stopScanning()
                self?.logger.info("蓝牙扫描超时，自动停止")
            }
        }
    }
    
 /// 更新设备列表
    private func updateDeviceList(with peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
 // 安全地转换服务 UUID 为字符串数组
        let serviceStrings = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString } ?? []
        
 // 安全地转换广告数据为字符串字典
        var stringAdvertisementData: [String: String] = [:]
        for (key, value) in advertisementData {
            if let stringValue = value as? String {
                stringAdvertisementData[key] = stringValue
            } else if let numberValue = value as? NSNumber {
                stringAdvertisementData[key] = numberValue.stringValue
            } else {
                stringAdvertisementData[key] = String(describing: value)
            }
        }
        
        let device = BluetoothDevice(
            identifier: peripheral.identifier,
            name: peripheral.name,
            rssi: rssi.intValue,
            isConnectable: advertisementData[CBAdvertisementDataIsConnectable] as? Bool ?? false,
            isConnected: peripheral.state == .connected,
            services: serviceStrings,
            advertisementData: stringAdvertisementData,
            lastSeen: Date()
        )
        
 // 检查是否已存在该设备
        if let existingIndex = discoveredDevices.firstIndex(where: { $0.identifier == device.identifier }) {
            discoveredDevices[existingIndex] = device
        } else {
            discoveredDevices.append(device)
        }
        
 // 按信号强度排序
        discoveredDevices.sort { $0.rssi > $1.rssi }
    }
    
 /// 更新连接设备列表
    private func updateConnectedDevices() {
        guard let manager = centralManager else {
            connectedDevices = []
            return
        }
        
        let connected = manager.retrieveConnectedPeripherals(withServices: [])
        
        connectedDevices = connected.map { peripheral in
            BluetoothDevice(
                identifier: peripheral.identifier,
                name: peripheral.name,
                rssi: 0, // 连接设备无法获取RSSI
                isConnectable: true,
                isConnected: true,
                services: peripheral.services?.map { $0.uuid.uuidString } ?? [],
                advertisementData: [:],
                lastSeen: Date()
            )
        }
    }
    
 /// 设置观察者，监听设置变化
    private func setupSettingsObservers() {
 // 监听蓝牙设置变化的通知
        NotificationCenter.default.publisher(for: NSNotification.Name("BluetoothSettingsChanged"))
            .sink { [weak self] notification in
                Task { @MainActor in
                    await self?.handleSettingsChange(notification)
                }
            }
            .store(in: &bluetoothCancellables)
    }
    
 /// 处理设置变化
    @MainActor
    private func handleSettingsChange(_ notification: Notification) async {
        guard let userInfo = notification.userInfo else { return }
        
 // 处理蓝牙扫描启用设置
        if let enableBluetoothScanning = userInfo["enableBluetoothScanning"] as? Bool {
            if enableBluetoothScanning && !isScanning && managerState == .poweredOn {
                startScanning()
                logger.info("蓝牙扫描已启用")
            } else if !enableBluetoothScanning && isScanning {
                stopScanning()
                logger.info("蓝牙扫描已禁用")
            }
        }
        
 // 处理扫描间隔变化
        if let _ = userInfo["scanInterval"] as? TimeInterval {
 // 如果正在扫描，重启扫描以应用新的间隔
            if isScanning {
                stopScanning()
                startScanning()
                logger.info("蓝牙扫描间隔已更新")
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothManager: CBCentralManagerDelegate {
    
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
 // 提取central的状态到局部常量，避免在闭包中捕获central对象
        let centralState = central.state
        
        Task { @MainActor in
            switch centralState {
            case .unknown:
                managerState = .unknown
            case .resetting:
                managerState = .resetting
            case .unsupported:
                managerState = .unsupported
            case .unauthorized:
                managerState = .unauthorized
                hasPermission = false
            case .poweredOff:
                managerState = .poweredOff
                isScanning = false
            case .poweredOn:
                managerState = .poweredOn
                hasPermission = true
                updateConnectedDevices()
            @unknown default:
                managerState = .unknown
            }
            
            logger.info("蓝牙状态更新: \(self.managerState.description)")
        }
    }
    
    nonisolated public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
 // 提取peripheral的属性到局部常量，避免在闭包中捕获peripheral对象
        let peripheralId = peripheral.identifier
        let peripheralName = peripheral.name
        let peripheralState = peripheral.state
        let rssiValue = RSSI.intValue
        let isConnectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool ?? false
        
        Task { @MainActor in
 // 在主线程上重新获取广告数据，避免数据竞争
 // Swift 6.2.1：services 和 advertisementData 在后续连接时异步获取
 // 初始发现时使用空值，避免 CoreBluetooth 回调中的数据竞争
            let device = BluetoothDevice(
                identifier: peripheralId,
                name: peripheralName,
                rssi: rssiValue,
                isConnectable: isConnectable,
                isConnected: peripheralState == .connected,
                services: [],
                advertisementData: [:],
                lastSeen: Date()
            )
            
 // 检查是否已存在该设备
            if let existingIndex = discoveredDevices.firstIndex(where: { $0.identifier == peripheralId }) {
                discoveredDevices[existingIndex] = device
            } else {
                discoveredDevices.append(device)
            }
            
 // 按信号强度排序
            discoveredDevices.sort { $0.rssi > $1.rssi }
        }
    }
    
    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
 // 提取peripheral的属性到局部常量，避免在闭包中捕获peripheral对象
        let peripheralId = peripheral.identifier
        let peripheralName = peripheral.name
        
        Task { @MainActor in
 // 注意：这里不能直接存储peripheral对象，因为它可能导致数据竞争
 // 如果需要存储peripheral，应该在主线程上重新获取
            if let manager = centralManager,
               let existingPeripheral = manager.retrievePeripherals(withIdentifiers: [peripheralId]).first {
                connectedPeripherals[peripheralId] = existingPeripheral
            }
            updateConnectedDevices()
            logger.info("蓝牙设备连接成功: \(peripheralName ?? "未知设备")")
        }
    }
    
    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            logger.error("蓝牙设备连接失败: \(error?.localizedDescription ?? "未知错误")")
        }
    }
    
    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let peripheralId = peripheral.identifier
        let peripheralName = peripheral.name
        
        Task { @MainActor in
            connectedPeripherals.removeValue(forKey: peripheralId)
            updateConnectedDevices()
            
            if let error = error {
                logger.error("蓝牙设备断开连接（错误）: \(peripheralName ?? "未知设备") - \(error.localizedDescription)")
            } else {
                logger.info("蓝牙设备断开连接: \(peripheralName ?? "未知设备")")
            }
        }
    }
}

// MARK: - 扩展方法
extension BluetoothManager {
    
 /// 获取蓝牙统计信息
    public var bluetoothStats: BluetoothStats {
        BluetoothStats(
            discoveredDevicesCount: discoveredDevices.count,
            connectedDevicesCount: connectedDevices.count,
            managerState: managerState,
            isScanning: isScanning
        )
    }
    
 /// 蓝牙统计信息结构
    public struct BluetoothStats {
        public let discoveredDevicesCount: Int
        public let connectedDevicesCount: Int
        public let managerState: BluetoothManagerState
        public let isScanning: Bool
    }
}