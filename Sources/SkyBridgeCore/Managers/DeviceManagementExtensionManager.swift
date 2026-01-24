import Foundation
import SwiftUI
import Combine
import os.log

// 导入设备管理扩展协议
// 注意：这些协议定义在同一个模块中，应该可以直接访问

/// 设备管理扩展管理器
/// 负责管理所有设备管理相关的扩展，提供插件化架构支持
/// 使用 Swift 6.2 的 Actor 隔离和并发安全特性
@MainActor
public final class DeviceManagementExtensionManager: ObservableObject {

 // MARK: - 单例

    public static let shared = DeviceManagementExtensionManager()

 // MARK: - 日志记录器

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "ExtensionManager")

 // MARK: - 发布属性

 /// 已注册的扩展
    @Published public private(set) var registeredExtensions: [String: any DeviceManagementExtensible] = [:]

 /// 设备扫描器扩展
    @Published public private(set) var scannerExtensions: [any DeviceScannerExtension] = []

 /// 设备连接扩展
    @Published public private(set) var connectionExtensions: [any DeviceConnectionExtension] = []

 /// UI扩展
    @Published public private(set) var uiExtensions: [any DeviceManagementUIExtension] = []

 /// 数据处理扩展
    @Published public private(set) var dataProcessorExtensions: [any DeviceDataProcessorExtension] = []

 /// 安全扩展
    @Published public private(set) var securityExtensions: [any DeviceSecurityExtension] = []

 /// 扩展加载状态
    @Published public private(set) var extensionLoadingStates: [String: ExtensionLoadingState] = [:]

 // MARK: - 私有属性

    private var cancellables = Set<AnyCancellable>()
    private let userDefaults = UserDefaults.standard
    private let enabledExtensionsKey = "DeviceManagement.EnabledExtensions"

 /// 使用 Swift 6.2 的并发安全队列进行扩展管理
    private let extensionQueue = DispatchQueue(label: "com.skybridge.extension-manager", qos: .userInitiated, attributes: .concurrent)

 // MARK: - 初始化

    private init() {
        setupNotifications()
        logger.info("设备管理扩展管理器已初始化")
    }

 // MARK: - 公共方法

 /// 注册设备管理扩展
 /// 使用 Swift 6.2 的并发安全特性
 /// - Parameter extension: 要注册的扩展
    public func registerExtension(_ extension: any DeviceManagementExtensible) async {
        let extensionId = `extension`.extensionId
        logger.info("正在注册扩展: \(`extension`.extensionName)")

 // 使用 进行并发安全的扩展注册
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                self.extensionLoadingStates[extensionId] = .loading
            }

            group.addTask {
                do {
 // 在后台队列中进行扩展初始化
                    try await `extension`.initialize()

                    await MainActor.run {
                        var ext = `extension`
                        self.registeredExtensions[extensionId] = ext
                        self.extensionLoadingStates[extensionId] = .loaded
                        // Apply persisted enabled/disabled state if we have it.
                        if let saved = self.userDefaults.array(forKey: self.enabledExtensionsKey) as? [String] {
                            let shouldEnable = saved.contains(extensionId)
                            if ext.isEnabled != shouldEnable {
                                ext.isEnabled = shouldEnable
                                self.registeredExtensions[extensionId] = ext
                            }
                        }

 // 发送通知
                        NotificationCenter.default.post(
                            name: .deviceManagementExtensionRegistered,
                            object: `extension`
                        )

                        self.logger.info("扩展注册成功: \(`extension`.extensionName)")
                    }

 // 分类扩展
                    await self.categorizeExtension(`extension`)

                } catch {
                    await MainActor.run {
                        self.extensionLoadingStates[extensionId] = .failed(error)
                        self.logger.error("扩展注册失败: \(`extension`.extensionName), 错误: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

 /// 注销扩展
 /// 使用 Swift 6.2 的并发安全特性
 /// - Parameter extensionId: 扩展ID
    public func unregisterExtension(_ extensionId: String) async {
        guard let `extension` = registeredExtensions[extensionId] else {
            logger.warning("尝试注销不存在的扩展: \(extensionId)")
            return
        }

        logger.info("正在注销扩展: \(`extension`.extensionName)")

 // 使用 TaskGroup 进行并发安全的扩展注销
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
 // 清理扩展资源
                await `extension`.cleanup()
            }

            group.addTask { @MainActor in
 // 从注册表中移除
                self.registeredExtensions.removeValue(forKey: extensionId)

 // 移除加载状态
                self.extensionLoadingStates.removeValue(forKey: extensionId)

 // 发送通知
                NotificationCenter.default.post(
                    name: .deviceManagementExtensionUnregistered,
                    object: `extension`
                )

                self.logger.info("扩展注销成功: \(`extension`.extensionName)")
            }

            group.addTask {
 // 从分类存储中移除
                await self.removeExtensionFromCategories(`extension`)
            }
        }
    }

 /// 启用扩展
 /// 使用 Swift 6.2 的 MainActor 隔离确保线程安全
 /// - Parameter extensionId: 扩展ID
    @MainActor
    public func enableExtension(_ extensionId: String) {
        guard var `extension` = registeredExtensions[extensionId] else {
            logger.warning("尝试启用不存在的扩展: \(extensionId)")
            return
        }

        logger.info("正在启用扩展: \(`extension`.extensionName)")

        `extension`.isEnabled = true
        registeredExtensions[extensionId] = `extension`
        persistEnabledExtensions()

        NotificationCenter.default.post(
            name: .deviceManagementExtensionEnabled,
            object: `extension`
        )

        logger.info("扩展启用成功: \(`extension`.extensionName)")
    }

 /// 禁用扩展
 /// 使用 Swift 6.2 的 MainActor 隔离确保线程安全
 /// - Parameter extensionId: 扩展ID
    @MainActor
    public func disableExtension(_ extensionId: String) {
        guard var `extension` = registeredExtensions[extensionId] else {
            logger.warning("尝试禁用不存在的扩展: \(extensionId)")
            return
        }

        logger.info("正在禁用扩展: \(`extension`.extensionName)")

        `extension`.isEnabled = false
        registeredExtensions[extensionId] = `extension`
        persistEnabledExtensions()

        NotificationCenter.default.post(
            name: .deviceManagementExtensionDisabled,
            object: `extension`
        )

        logger.info("扩展禁用成功: \(`extension`.extensionName)")
    }

 /// 获取启用的扫描器扩展
 /// - Returns: 启用的扫描器扩展列表
    public func getEnabledScannerExtensions() -> [any DeviceScannerExtension] {
        return scannerExtensions.filter { $0.isEnabled }
    }

 /// 获取启用的连接扩展
 /// - Returns: 启用的连接扩展列表
    public func getEnabledConnectionExtensions() -> [any DeviceConnectionExtension] {
        return connectionExtensions.filter { $0.isEnabled }
    }

 /// 获取启用的UI扩展
 /// - Returns: 启用的UI扩展列表
    public func getEnabledUIExtensions() -> [any DeviceManagementUIExtension] {
        return uiExtensions.filter { $0.isEnabled }
    }

 /// 获取启用的数据处理扩展
 /// - Returns: 启用的数据处理扩展列表
    public func getEnabledDataProcessorExtensions() -> [any DeviceDataProcessorExtension] {
        return dataProcessorExtensions.filter { $0.isEnabled }
    }

 /// 获取启用的安全扩展
 /// - Returns: 启用的安全扩展列表
    public func getEnabledSecurityExtensions() -> [any DeviceSecurityExtension] {
        return securityExtensions.filter { $0.isEnabled }
    }

 /// 扫描所有设备
 /// - Returns: 发现的设备列表
    public func scanAllDevices() async throws -> [any DeviceRepresentable] {
        let enabledScanners = getEnabledScannerExtensions()
        var allDevices: [any DeviceRepresentable] = []

 // 顺序扫描所有启用的扫描器以避免并发问题
        for scanner in enabledScanners {
            do {
                let devices = try await scanner.scanDevices()
                allDevices.append(contentsOf: devices)
            } catch {
                SkyBridgeLogger.ui.error("⚠️ 扫描器 \(scanner.extensionName, privacy: .private) 扫描失败: \(error.localizedDescription, privacy: .private)")
            }
        }

 // 去重设备（基于设备ID）
        let uniqueDevices = Dictionary(grouping: allDevices, by: { $0.id })
            .compactMapValues { $0.first }
            .values

        return Array(uniqueDevices)
    }

 /// 连接设备
 /// - Parameters:
 /// - device: 要连接的设备
 /// - preferredProtocol: 首选协议
 /// - Returns: 连接是否成功
    public func connectDevice(_ device: any DeviceRepresentable, preferredProtocol: String? = nil) async throws -> Bool {
        let enabledConnectors = getEnabledConnectionExtensions()

 // 如果指定了首选协议，优先使用支持该协议的连接器
        if let preferredProtocol = preferredProtocol {
            for connector in enabledConnectors {
                if connector.supportedProtocols.contains(preferredProtocol) {
                    do {
                        return try await connector.connectDevice(device, options: [:])
                    } catch {
                        SkyBridgeLogger.ui.error("⚠️ 使用首选协议 \(preferredProtocol) 连接失败: \(error.localizedDescription, privacy: .private)")
                    }
                }
            }
        }

 // 尝试所有可用的连接器
        for connector in enabledConnectors {
            do {
                return try await connector.connectDevice(device, options: [:])
            } catch {
                SkyBridgeLogger.ui.error("⚠️ 连接器 \(connector.extensionName, privacy: .private) 连接失败: \(error.localizedDescription, privacy: .private)")
                continue
            }
        }

        throw DeviceManagementError.noAvailableConnector
    }

 /// 断开设备连接
 /// - Parameter device: 要断开的设备
    public func disconnectDevice(_ device: any DeviceRepresentable) async throws {
        let enabledConnectors = getEnabledConnectionExtensions()

        for connector in enabledConnectors {
            if connector.getConnectionStatus(for: device).isConnected {
                try await connector.disconnectDevice(device)
                return
            }
        }
    }

 /// 处理设备数据
 /// - Parameters:
 /// - data: 要处理的数据
 /// - device: 数据来源设备
 /// - dataType: 数据类型
 /// - Returns: 处理后的设备数据
    public func processDeviceData(_ data: Data, from device: any DeviceRepresentable, dataType: String) async throws -> ProcessedDeviceData? {
        let processors = getEnabledDataProcessorExtensions().filter { $0.supportedDataTypes.contains(dataType) }

        for processor in processors {
            do {
                return try await processor.processDeviceData(data, from: device)
            } catch {
                SkyBridgeLogger.ui.error("⚠️ 数据处理器 \(processor.extensionName, privacy: .private) 处理失败: \(error.localizedDescription, privacy: .private)")
            }
        }

        return nil
    }

 /// 执行设备安全检查
 /// - Parameter device: 要检查的设备
 /// - Returns: 安全检查结果
    public func performSecurityCheck(on device: any DeviceRepresentable) async throws -> DeviceSecurityResult? {
        let securityExtensions = getEnabledSecurityExtensions()
        guard let securityExtension = securityExtensions.first else {
            throw DeviceManagementError.noAvailableConnector
        }

        return try await securityExtension.performSecurityCheck(on: device)
    }

 /// 创建扩展设置视图
 /// - Returns: 扩展设置视图
    @ViewBuilder
    public func createExtensionSettingsView() -> some View {
        VStack(spacing: 16) {
 // 扩展概览
            ExtensionOverviewView(
                registeredExtensions: Array(registeredExtensions.values),
                loadingStates: extensionLoadingStates
            )

 // UI扩展的设置标签页
            if !uiExtensions.isEmpty {
                TabView {
                    ForEach(getEnabledUIExtensions(), id: \.extensionId) { uiExtension in
                        uiExtension.createSettingsView()
                            .tabItem {
                                Image(systemName: uiExtension.settingsTabIcon)
                                Text(uiExtension.settingsTabTitle)
                            }
                    }
                }
                .frame(minHeight: 400)
            }
        }
    }

 // MARK: - 私有方法

 /// 设置通知监听
    private func setupNotifications() {
 // 监听应用生命周期
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                Task {
                    await self?.cleanupAllExtensions()
                }
            }
            .store(in: &cancellables)
    }

 /// 分类存储扩展
    private func categorizeExtension(_ extension: any DeviceManagementExtensible) async {
        if let scannerExtension = `extension` as? any DeviceScannerExtension {
            scannerExtensions.append(scannerExtension)
        }

        if let connectionExtension = `extension` as? any DeviceConnectionExtension {
            connectionExtensions.append(connectionExtension)
        }

        if let uiExtension = `extension` as? any DeviceManagementUIExtension {
            uiExtensions.append(uiExtension)
        }

        if let dataProcessorExtension = `extension` as? any DeviceDataProcessorExtension {
            dataProcessorExtensions.append(dataProcessorExtension)
        }

        if let securityExtension = `extension` as? any DeviceSecurityExtension {
            securityExtensions.append(securityExtension)
        }
    }

 /// 从分类存储中移除扩展
    private func removeExtensionFromCategories(_ extension: any DeviceManagementExtensible) async {
        let extensionId = `extension`.extensionId

        scannerExtensions.removeAll { $0.extensionId == extensionId }
        connectionExtensions.removeAll { $0.extensionId == extensionId }
        uiExtensions.removeAll { $0.extensionId == extensionId }
        dataProcessorExtensions.removeAll { $0.extensionId == extensionId }
        securityExtensions.removeAll { $0.extensionId == extensionId }
    }

 /// 清理所有扩展
    private func cleanupAllExtensions() async {
        for `extension` in registeredExtensions.values {
            await `extension`.cleanup()
        }

 // 清空所有扩展列表
        registeredExtensions.removeAll()
        scannerExtensions.removeAll()
        connectionExtensions.removeAll()
        uiExtensions.removeAll()
        dataProcessorExtensions.removeAll()
        securityExtensions.removeAll()
        extensionLoadingStates.removeAll()
    }

    private func persistEnabledExtensions() {
        let enabled = registeredExtensions.values
            .filter { $0.isEnabled }
            .map { $0.extensionId }
            .sorted()
        userDefaults.set(enabled, forKey: enabledExtensionsKey)
    }
}

// MARK: - 扩展加载状态

/// 扩展加载状态
public enum ExtensionLoadingState {
    case loading
    case loaded
    case failed(Error)

    public var isLoaded: Bool {
        if case .loaded = self {
            return true
        }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

// MARK: - 设备管理错误

/// 设备管理错误
public enum DeviceManagementError: LocalizedError {
    case noAvailableConnector
    case extensionNotFound(String)
    case extensionInitializationFailed(String, Error)
    case unsupportedDeviceType(String)
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAvailableConnector:
            return "没有可用的设备连接器"
        case .extensionNotFound(let extensionId):
            return "未找到扩展: \(extensionId)"
        case .extensionInitializationFailed(let extensionName, let error):
            return "扩展 \(extensionName) 初始化失败: \(error.localizedDescription)"
        case .unsupportedDeviceType(let deviceType):
            return "不支持的设备类型: \(deviceType)"
        case .connectionFailed(let reason):
            return "连接失败: \(reason)"
        }
    }
}

// MARK: - 扩展概览视图

/// 扩展概览视图
private struct ExtensionOverviewView: View {
    let registeredExtensions: [any DeviceManagementExtensible]
    let loadingStates: [String: ExtensionLoadingState]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已注册的扩展")
                .font(.headline)
                .foregroundColor(.primary)

            if registeredExtensions.isEmpty {
                Text("暂无已注册的扩展")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(registeredExtensions, id: \.extensionId) { extensionItem in
                        ExtensionRowView(
                            extensionItem: extensionItem,
                            loadingState: loadingStates[extensionItem.extensionId]
                        )
                    }
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

/// 扩展行视图
private struct ExtensionRowView: View {
    let extensionItem: any DeviceManagementExtensible
    let loadingState: ExtensionLoadingState?
    @State private var isEnabled: Bool

    init(extensionItem: any DeviceManagementExtensible, loadingState: ExtensionLoadingState?) {
        self.extensionItem = extensionItem
        self.loadingState = loadingState
        self._isEnabled = State(initialValue: extensionItem.isEnabled)
    }

    var body: some View {
        HStack {
 // 状态指示器
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(extensionItem.extensionName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("v\(extensionItem.extensionVersion) • \(extensionItem.extensionDescription)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

 // 启用状态切换
            Toggle("", isOn: $isEnabled)
                .toggleStyle(SwitchToggleStyle())
                .disabled(loadingState?.isFailed == true)
                .onChange(of: isEnabled) { _, newValue in
                    let manager = DeviceManagementExtensionManager.shared
                    if newValue {
                        Task { @MainActor in
                            manager.enableExtension(extensionItem.extensionId)
                        }
                    } else {
                        Task { @MainActor in
                            manager.disableExtension(extensionItem.extensionId)
                        }
                    }
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(6)
    }

    private var statusColor: Color {
        guard let loadingState = loadingState else {
            return .gray
        }

        switch loadingState {
        case .loading:
            return .orange
        case .loaded:
            return isEnabled ? .green : .gray
        case .failed:
            return .red
        }
    }
}

// MARK: - 通知扩展

extension Notification.Name {
 /// 设备管理扩展已注册
    public static let deviceManagementExtensionRegistered = Notification.Name("deviceManagementExtensionRegistered")

 /// 设备管理扩展已注销
    public static let deviceManagementExtensionUnregistered = Notification.Name("deviceManagementExtensionUnregistered")

 /// 设备管理扩展已启用
    public static let deviceManagementExtensionEnabled = Notification.Name("deviceManagementExtensionEnabled")

 /// 设备管理扩展已禁用
    public static let deviceManagementExtensionDisabled = Notification.Name("deviceManagementExtensionDisabled")
}
