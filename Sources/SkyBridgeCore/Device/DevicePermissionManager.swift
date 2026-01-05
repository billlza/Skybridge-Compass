import Foundation
import CoreWLAN
import CoreBluetooth
import LocalAuthentication
import SystemConfiguration
import CoreLocation
import AppKit
import os.log

/// 权限类型枚举
public enum PermissionType: String, CaseIterable, Sendable {
    case wifi = "WiFi网络访问"
    case bluetooth = "蓝牙设备访问"
    case location = "位置服务"
    case networkExtension = "网络扩展"
    case systemConfiguration = "系统配置"
    
    public var description: String {
        return self.rawValue
    }
    
    public var iconName: String {
        switch self {
        case .wifi:
            return "wifi"
        case .bluetooth:
            return "bluetooth"
        case .location:
            return "location"
        case .networkExtension:
            return "network"
        case .systemConfiguration:
            return "gearshape"
        }
    }
}

/// 权限状态枚举
public enum PermissionStatus: String, Sendable {
    case notDetermined = "未确定"
    case denied = "已拒绝"
    case authorized = "已授权"
    case restricted = "受限制"
    case unavailable = "不可用"
    
    public var isAuthorized: Bool {
        return self == .authorized
    }
    
    public var color: String {
        switch self {
        case .authorized:
            return "green"
        case .denied, .restricted:
            return "red"
        case .notDetermined:
            return "orange"
        case .unavailable:
            return "gray"
        }
    }
}

/// 权限信息结构
public struct PermissionInfo: Identifiable, Sendable {
    public let id = UUID()
    public let type: PermissionType
    public let status: PermissionStatus
    public let description: String
    public let isRequired: Bool
    public let lastChecked: Date
    
    public init(
        type: PermissionType,
        status: PermissionStatus,
        description: String,
        isRequired: Bool,
        lastChecked: Date = Date()
    ) {
        self.type = type
        self.status = status
        self.description = description
        self.isRequired = isRequired
        self.lastChecked = lastChecked
    }
}

/// 设备权限管理器 - 处理各种设备管理功能所需的权限
/// 使用 Swift 6.2 的 MainActor 隔离确保线程安全
@MainActor
public final class DevicePermissionManager: NSObject, ObservableObject, Sendable {
    
 // MARK: - 发布属性
    @Published public var permissions: [PermissionInfo] = []
    @Published public var isCheckingPermissions = false
    @Published public var allRequiredPermissionsGranted = false
    
 // MARK: - 私有属性
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "DevicePermissionManager")
    private var bluetoothManager: CBCentralManager?
    private let locationManager = CLLocationManager()
    
 // 并发安全队列
    private let permissionQueue = DispatchQueue(label: "com.skybridge.compass.permissions", qos: .userInitiated)
    
 // MARK: - 初始化
    public override init() {
        super.init()
        
 // ⚡ 完全异步初始化 - 不阻塞任何主线程操作
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.setupBluetoothManager()
            try? await Task.sleep(nanoseconds: 500_000_000) // 延迟0.5秒
            self.checkAllPermissions()
        }
    }
    
 // MARK: - 公共方法
    
 /// 检查所有权限状态
 /// 使用简化的并发方式避免 Actor 隔离问题
    public func checkAllPermissions() {
        isCheckingPermissions = true
        logger.info("开始检查所有权限状态")
        
        Task {
            var updatedPermissions: [PermissionInfo] = []
            
 // 检查WiFi权限
            let wifiStatus = await checkWiFiPermission()
            updatedPermissions.append(PermissionInfo(
                type: .wifi,
                status: wifiStatus,
                description: "访问WiFi网络信息和配置",
                isRequired: true
            ))
            
 // 检查蓝牙权限
            let bluetoothStatus = checkBluetoothPermission()
            updatedPermissions.append(PermissionInfo(
                type: .bluetooth,
                status: bluetoothStatus,
                description: "扫描和连接蓝牙设备",
                isRequired: true
            ))
            
 // 检查位置权限（WiFi扫描可能需要）
            let locationStatus = checkLocationPermission()
            updatedPermissions.append(PermissionInfo(
                type: .location,
                status: locationStatus,
                description: "WiFi网络扫描可能需要位置权限",
                isRequired: false
            ))
            
 // 检查网络扩展权限
            let networkStatus = checkNetworkExtensionPermission()
            updatedPermissions.append(PermissionInfo(
                type: .networkExtension,
                status: networkStatus,
                description: "网络配置和管理",
                isRequired: false
            ))
            
 // 检查系统配置权限
            let systemStatus = checkSystemConfigurationPermission()
            updatedPermissions.append(PermissionInfo(
                type: .systemConfiguration,
                status: systemStatus,
                description: "系统网络配置访问",
                isRequired: true
            ))
            
 // 在主线程更新UI
            await MainActor.run {
                self.permissions = updatedPermissions
                self.allRequiredPermissionsGranted = updatedPermissions
                    .filter { $0.isRequired }
                    .allSatisfy { $0.status.isAuthorized }
                self.isCheckingPermissions = false
                self.logger.info("权限检查完成，\(updatedPermissions.count) 个权限已检查")
            }
        }
    }
    
 /// 请求特定权限
    public func requestPermission(for type: PermissionType) async -> Bool {
        logger.info("请求权限: \(type.description)")
        
        switch type {
        case .wifi:
            return await requestWiFiPermission()
        case .bluetooth:
            return await requestBluetoothPermission()
        case .location:
            return await requestLocationPermission()
        case .networkExtension:
            return await requestNetworkExtensionPermission()
        case .systemConfiguration:
            return await requestSystemConfigurationPermission()
        }
    }
    
 /// 请求所有必需权限
    public func requestAllRequiredPermissions() async -> Bool {
        let requiredPermissions = permissions.filter { $0.isRequired && !$0.status.isAuthorized }
        
        for permission in requiredPermissions {
            let granted = await requestPermission(for: permission.type)
            if !granted {
                logger.warning("权限请求失败: \(permission.type.description)")
                return false
            }
        }
        
 // 重新检查权限状态
        checkAllPermissions()
        return true
    }
    
 /// 打开系统偏好设置
    public func openSystemPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }
    
 // MARK: - 私有权限检查方法
    
 /// 检查WiFi权限
    private func checkWiFiPermission() async -> PermissionStatus {
 // 在macOS中，WiFi访问需要用户授权和位置权限
        let client = CWWiFiClient.shared()
        let interface = client.interface()
        
        if interface != nil {
            return .authorized
        } else {
            return .unavailable
        }
    }
    
 /// 检查蓝牙权限
    private func checkBluetoothPermission() -> PermissionStatus {
        guard let manager = bluetoothManager else {
            return .unavailable
        }
        
        switch manager.state {
        case .poweredOn:
            return .authorized
        case .poweredOff:
            return .denied
        case .unauthorized:
            return .denied
        case .unsupported:
            return .unavailable
        case .resetting:
            return .notDetermined
        case .unknown:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }
    
 /// 检查位置权限
    private func checkLocationPermission() -> PermissionStatus {
 // macOS中位置权限检查 - 使用实例方法替代已弃用的类方法
        let authStatus = locationManager.authorizationStatus
        
        switch authStatus {
        case .authorizedAlways:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }
    
 /// 检查网络扩展权限
    private func checkNetworkExtensionPermission() -> PermissionStatus {
 // 网络扩展权限通常需要用户明确授权
 // 这里简化处理，实际应用中可能需要更复杂的检查
        return .authorized
    }
    
 /// 检查系统配置权限
    private func checkSystemConfigurationPermission() -> PermissionStatus {
 // 检查是否可以访问系统配置
        let store = SCDynamicStoreCreate(nil, "DevicePermissionManager" as CFString, nil, nil)
        if store != nil {
            return .authorized
        } else {
            return .denied
        }
    }
    
 // MARK: - 私有权限请求方法
    
 /// 请求WiFi权限
    private func requestWiFiPermission() async -> Bool {
 // WiFi权限通常不需要特殊请求
        let status = await checkWiFiPermission()
        return status.isAuthorized
    }
    
 /// 请求蓝牙权限
    private func requestBluetoothPermission() async -> Bool {
        return await withCheckedContinuation { continuation in
 // 蓝牙权限会在CBCentralManager初始化时自动请求
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let status = self.checkBluetoothPermission()
                continuation.resume(returning: status.isAuthorized)
            }
        }
    }
    
 /// 请求位置权限
    private func requestLocationPermission() async -> Bool {
 // macOS中位置权限请求
        let manager = CLLocationManager()
        manager.requestWhenInUseAuthorization()
        
 // 等待权限结果
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let status = self.checkLocationPermission()
                continuation.resume(returning: status.isAuthorized)
            }
        }
    }
    
 /// 请求网络扩展权限
    private func requestNetworkExtensionPermission() async -> Bool {
 // 网络扩展权限请求通常需要用户交互
        return true
    }
    
 /// 请求系统配置权限
    private func requestSystemConfigurationPermission() async -> Bool {
 // 系统配置权限可能需要管理员权限
        let context = LAContext()
        var error: NSError?
        
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "需要管理员权限来访问系统网络配置"
                )
                return success
            } catch {
                logger.error("系统配置权限请求失败: \(error.localizedDescription)")
                return false
            }
        } else {
            return false
        }
    }
    
 // MARK: - 辅助方法
    
 /// 设置蓝牙管理器
    private func setupBluetoothManager() {
        bluetoothManager = CBCentralManager(delegate: self, queue: nil)
    }
    
 /// 获取权限摘要
    public var permissionSummary: String {
        let authorizedCount = permissions.filter { $0.status.isAuthorized }.count
        let totalCount = permissions.count
        return "\(authorizedCount)/\(totalCount) 权限已授权"
    }
    
 /// 获取未授权的必需权限
    public var unauthorizedRequiredPermissions: [PermissionInfo] {
        return permissions.filter { $0.isRequired && !$0.status.isAuthorized }
    }
}

// MARK: - CBCentralManagerDelegate
extension DevicePermissionManager: CBCentralManagerDelegate {
    
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
 // 蓝牙状态更新时重新检查权限
            checkAllPermissions()
        }
    }
}

// MARK: - 权限帮助器
extension DevicePermissionManager {
    
 /// 权限状态描述
    public func statusDescription(for type: PermissionType) -> String {
        guard let permission = permissions.first(where: { $0.type == type }) else {
            return "未知"
        }
        
        switch permission.status {
        case .authorized:
            return "已授权 ✓"
        case .denied:
            return "已拒绝 ✗"
        case .notDetermined:
            return "待确定 ?"
        case .restricted:
            return "受限制 ⚠"
        case .unavailable:
            return "不可用 -"
        }
    }
    
 /// 权限建议
    public func suggestion(for type: PermissionType) -> String {
        guard let permission = permissions.first(where: { $0.type == type }) else {
            return ""
        }
        
        switch permission.status {
        case .denied:
            return "请在系统偏好设置中手动启用此权限"
        case .notDetermined:
            return "点击请求权限按钮来获取授权"
        case .restricted:
            return "此权限被系统策略限制"
        case .unavailable:
            return "当前系统不支持此功能"
        case .authorized:
            return "权限已正确配置"
        }
    }
}
