import Foundation
import SwiftUI
import Combine

// 设备模型已在同一模块中，无需导入

/// 设备过滤管理器 - 管理设备分组、过滤和显示状态
@MainActor
public class DeviceFilterManager: BaseManager {
    
 /// 设备分组
    public struct DeviceGroup: Identifiable {
        public let id = UUID()
        public let type: DeviceClassifier.DeviceType
        public let devices: [DiscoveredDevice]
        public var isExpanded: Bool
        public var isVisible: Bool
        
        public init(type: DeviceClassifier.DeviceType, devices: [DiscoveredDevice], isExpanded: Bool = true, isVisible: Bool = true) {
            self.type = type
            self.devices = devices
            self.isExpanded = isExpanded
            self.isVisible = isVisible
        }
        
 /// 设备数量
        public var deviceCount: Int {
            return devices.count
        }
        
 /// 分组标题
        public var title: String {
            return "\(type.rawValue) (\(deviceCount))"
        }
    }
    
 /// 过滤设置
    public struct FilterSettings {
 /// 是否显示非连接设备
        public var showNonConnectableDevices: Bool = true
        
 /// 是否自动折叠非连接设备
        public var autoCollapseNonConnectable: Bool = true
        
 /// 是否显示未知设备
        public var showUnknownDevices: Bool = true
        
 /// 最小信号强度过滤
        public var minimumSignalStrength: Double = -100.0
        
 /// 设备类型过滤
        public var hiddenDeviceTypes: Set<DeviceClassifier.DeviceType> = []
        
 /// 扫描范围模式（控制过滤行为）
        public var discoveryScopeMode: DiscoveryScopeMode = .skyBridgeOnly
        
        public init() {}
    }
    
 // MARK: - 发布的属性
    
 /// 设备分组列表
    @Published public var deviceGroups: [DeviceGroup] = []
    
 /// 过滤设置
    @Published public var filterSettings = FilterSettings()
    
 /// 总设备数量
    @Published public var totalDeviceCount: Int = 0
    
 /// 可连接设备数量
    @Published public var connectableDeviceCount: Int = 0
    
 /// 隐藏设备数量
    @Published public var hiddenDeviceCount: Int = 0
    
 // MARK: - 私有属性
    
    private var allDevices: [DiscoveredDevice] = []
    private var groupExpansionStates: [DeviceClassifier.DeviceType: Bool] = [:]
    
 // MARK: - 初始化
    
    public init() {
        super.init(category: "DeviceFilterManager")
        setupDefaultGroupStates()
    }
    
 // MARK: - 公共方法
    
 /// 更新设备列表
 /// - Parameter devices: 新的设备列表
    public func updateDevices(_ devices: [DiscoveredDevice]) {
        allDevices = devices
        totalDeviceCount = devices.count
        
 // 应用过滤和分组
        applyFiltersAndGrouping()
        
 // 更新统计信息
        updateStatistics()
    }
    
 /// 切换设备组展开状态
 /// - Parameter deviceType: 设备类型
    public func toggleGroupExpansion(for deviceType: DeviceClassifier.DeviceType) {
        groupExpansionStates[deviceType] = !(groupExpansionStates[deviceType] ?? true)
        
 // 更新设备分组
        deviceGroups = deviceGroups.map { group in
            if group.type == deviceType {
                var updatedGroup = group
                updatedGroup.isExpanded = groupExpansionStates[deviceType] ?? true
                return updatedGroup
            }
            return group
        }
    }
    
 /// 隐藏设备类型
 /// - Parameter deviceType: 要隐藏的设备类型
    public func hideDeviceType(_ deviceType: DeviceClassifier.DeviceType) {
        filterSettings.hiddenDeviceTypes.insert(deviceType)
        applyFiltersAndGrouping()
    }
    
 /// 显示设备类型
 /// - Parameter deviceType: 要显示的设备类型
    public func showDeviceType(_ deviceType: DeviceClassifier.DeviceType) {
        filterSettings.hiddenDeviceTypes.remove(deviceType)
        applyFiltersAndGrouping()
    }
    
 /// 重置过滤设置
    public func resetFilters() {
        filterSettings = FilterSettings()
        setupDefaultGroupStates()
        applyFiltersAndGrouping()
    }
    
 /// 获取可连接设备列表
 /// - Returns: 可连接的设备列表
    public func getConnectableDevices() -> [DiscoveredDevice] {
        return allDevices.filter { $0.isConnectable }
    }
    
 /// 获取指定类型的设备
 /// - Parameter deviceType: 设备类型
 /// - Returns: 指定类型的设备列表
    public func getDevices(ofType deviceType: DeviceClassifier.DeviceType) -> [DiscoveredDevice] {
        return allDevices.filter { $0.deviceType == deviceType }
    }
    
 // MARK: - 私有方法
    
 /// 设置默认分组状态
    private func setupDefaultGroupStates() {
 // 默认展开可连接设备，折叠非连接设备
        for deviceType in DeviceClassifier.DeviceType.allCases {
            groupExpansionStates[deviceType] = deviceType.isConnectable || !filterSettings.autoCollapseNonConnectable
        }
    }
    
 /// 应用过滤和分组
    private func applyFiltersAndGrouping() {
 // 1. 应用基础过滤
        var filteredDevices = allDevices
        
 // 🆕 根据扫描范围模式进行过滤
        switch filterSettings.discoveryScopeMode {
        case .skyBridgeOnly:
 // 只展示 SkyBridge 对端设备
            filteredDevices = filteredDevices.filter { $0.isSkyBridgePeer }
 // skyBridgeOnly 模式下不使用类型过滤，因为只看 SkyBridge 设备
            
        case .generalDevices:
 // 展示常规设备，但隐藏打印机/摄像头/IoT
            filterSettings.hiddenDeviceTypes = [.printer, .camera, .iot]
            filteredDevices = filteredDevices.filter { device in
                !filterSettings.hiddenDeviceTypes.contains(device.deviceType)
            }
            
        case .fullCompatible:
 // 显示所有设备类型，不隐藏任何类型
            filterSettings.hiddenDeviceTypes = []
 // 应用用户自定义的类型过滤（如果有）
            filteredDevices = filteredDevices.filter { device in
                !filterSettings.hiddenDeviceTypes.contains(device.deviceType)
            }
        }
        
 // 过滤非连接设备（如果设置了隐藏）
        if !filterSettings.showNonConnectableDevices {
            filteredDevices = filteredDevices.filter { $0.isConnectable }
        }
        
 // 过滤未知设备（如果设置了隐藏）
        if !filterSettings.showUnknownDevices {
            filteredDevices = filteredDevices.filter { $0.deviceType != DeviceClassifier.DeviceType.unknown }
        }
        
 // 2. 按设备类型分组
        let groupedDevices = Dictionary(grouping: filteredDevices) { $0.deviceType }
        
 // 3. 创建设备分组
        var newGroups: [DeviceGroup] = []
        
 // 按优先级排序设备类型（可连接设备优先）
        let sortedDeviceTypes = DeviceClassifier.DeviceType.allCases.sorted { type1, type2 in
            if type1.isConnectable && !type2.isConnectable {
                return true
            } else if !type1.isConnectable && type2.isConnectable {
                return false
            } else {
                return type1.rawValue < type2.rawValue
            }
        }
        
        for deviceType in sortedDeviceTypes {
            if let devices = groupedDevices[deviceType], !devices.isEmpty {
                let isExpanded = groupExpansionStates[deviceType] ?? true
                let isVisible = !filterSettings.hiddenDeviceTypes.contains(deviceType)
                
 // 按设备名称排序
                let sortedDevices = devices.sorted { $0.name < $1.name }
                
                let group = DeviceGroup(
                    type: deviceType,
                    devices: sortedDevices,
                    isExpanded: isExpanded,
                    isVisible: isVisible
                )
                
                newGroups.append(group)
            }
        }
        
        deviceGroups = newGroups
    }
    
 /// 更新统计信息
    private func updateStatistics() {
        connectableDeviceCount = allDevices.filter { $0.isConnectable }.count
        
 // 计算隐藏的设备数量
        let visibleDeviceCount = deviceGroups.reduce(0) { total, group in
            total + (group.isVisible ? group.deviceCount : 0)
        }
        hiddenDeviceCount = totalDeviceCount - visibleDeviceCount
    }
}

// MARK: - 扩展：用户偏好设置

extension DeviceFilterManager {
    
 /// 保存用户偏好设置
    public func saveUserPreferences() {
        let encoder = JSONEncoder()
        
 // 保存过滤设置
        if let filterData = try? encoder.encode(filterSettings) {
            UserDefaults.standard.set(filterData, forKey: "DeviceFilterSettings")
        }
        
 // 保存分组展开状态
        let expansionData = groupExpansionStates.mapValues { $0 }
        UserDefaults.standard.set(expansionData, forKey: "DeviceGroupExpansionStates")
    }
    
 /// 加载用户偏好设置
    public func loadUserPreferences() {
        let decoder = JSONDecoder()
        
 // 加载过滤设置
        if let filterData = UserDefaults.standard.data(forKey: "DeviceFilterSettings"),
           let loadedSettings = try? decoder.decode(FilterSettings.self, from: filterData) {
            filterSettings = loadedSettings
        }
        
 // 加载分组展开状态
        if let expansionData = UserDefaults.standard.dictionary(forKey: "DeviceGroupExpansionStates") as? [String: Bool] {
            for (typeString, isExpanded) in expansionData {
                if let deviceType = DeviceClassifier.DeviceType.allCases.first(where: { $0.rawValue == typeString }) {
                    groupExpansionStates[deviceType] = isExpanded
                }
            }
        }
        
 // 重新应用过滤和分组
        applyFiltersAndGrouping()
    }
}

// MARK: - 扩展：FilterSettings支持Codable

extension DeviceFilterManager.FilterSettings: Codable {
    
    private enum CodingKeys: String, CodingKey {
        case showNonConnectableDevices
        case autoCollapseNonConnectable
        case showUnknownDevices
        case minimumSignalStrength
        case hiddenDeviceTypes
        case discoveryScopeMode
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        showNonConnectableDevices = try container.decodeIfPresent(Bool.self, forKey: .showNonConnectableDevices) ?? true
        autoCollapseNonConnectable = try container.decodeIfPresent(Bool.self, forKey: .autoCollapseNonConnectable) ?? true
        showUnknownDevices = try container.decodeIfPresent(Bool.self, forKey: .showUnknownDevices) ?? true
        minimumSignalStrength = try container.decodeIfPresent(Double.self, forKey: .minimumSignalStrength) ?? -100.0
        discoveryScopeMode = try container.decodeIfPresent(DiscoveryScopeMode.self, forKey: .discoveryScopeMode) ?? .skyBridgeOnly
        
        let hiddenTypeStrings = try container.decodeIfPresent([String].self, forKey: .hiddenDeviceTypes) ?? []
        hiddenDeviceTypes = Set(hiddenTypeStrings.compactMap { typeString in
            DeviceClassifier.DeviceType.allCases.first { $0.rawValue == typeString }
        })
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(showNonConnectableDevices, forKey: .showNonConnectableDevices)
        try container.encode(autoCollapseNonConnectable, forKey: .autoCollapseNonConnectable)
        try container.encode(showUnknownDevices, forKey: .showUnknownDevices)
        try container.encode(minimumSignalStrength, forKey: .minimumSignalStrength)
        try container.encode(discoveryScopeMode, forKey: .discoveryScopeMode)
        
        let hiddenTypeStrings = hiddenDeviceTypes.map { $0.rawValue }
        try container.encode(hiddenTypeStrings, forKey: .hiddenDeviceTypes)
    }
}