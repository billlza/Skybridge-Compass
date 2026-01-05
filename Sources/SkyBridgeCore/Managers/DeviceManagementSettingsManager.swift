import Foundation
import SwiftUI

// 注意：PermissionStatus 已在 DevicePermissionManager.swift 中定义，这里不需要重复定义

/// 设备管理设置管理器
/// 负责管理设备扫描、显示、连接等相关设置的持久化和同步
@MainActor
public class DeviceManagementSettingsManager: ObservableObject {
    public static let shared = DeviceManagementSettingsManager()
    
    private let userDefaults = UserDefaults.standard
    private let settingsPrefix = "DeviceManagement."
    
 // MARK: - 扫描设置
    @Published public var wifiScanInterval: Double = 5.0 {
        didSet { saveValue(wifiScanInterval, forKey: "wifiScanInterval") }
    }
    
    @Published public var wifiScanTimeout: Double = 30.0 {
        didSet { saveValue(wifiScanTimeout, forKey: "wifiScanTimeout") }
    }
    
    @Published public var autoScanWiFi: Bool = true {
        didSet { saveValue(autoScanWiFi, forKey: "autoScanWiFi") }
    }
    
    @Published public var bluetoothScanInterval: Double = 5.0 {
        didSet { saveValue(bluetoothScanInterval, forKey: "bluetoothScanInterval") }
    }
    
    @Published public var bluetoothScanTimeout: Double = 30.0 {
        didSet { saveValue(bluetoothScanTimeout, forKey: "bluetoothScanTimeout") }
    }
    
    @Published public var autoScanBluetooth: Bool = true {
        didSet { saveValue(autoScanBluetooth, forKey: "autoScanBluetooth") }
    }
    
    @Published public var scanBLEDevices: Bool = true {
        didSet { saveValue(scanBLEDevices, forKey: "scanBLEDevices") }
    }
    
    @Published public var airplayScanInterval: Double = 10.0 {
        didSet { saveValue(airplayScanInterval, forKey: "airplayScanInterval") }
    }
    
    @Published public var autoScanAirPlay: Bool = true {
        didSet { saveValue(autoScanAirPlay, forKey: "autoScanAirPlay") }
    }
    
 // MARK: - 显示设置
    @Published public var showOfflineDevices: Bool = true {
        didSet { saveValue(showOfflineDevices, forKey: "showOfflineDevices") }
    }
    
    @Published public var showSignalStrength: Bool = true {
        didSet { saveValue(showSignalStrength, forKey: "showSignalStrength") }
    }
    
    @Published public var showDeviceIcons: Bool = true {
        didSet { saveValue(showDeviceIcons, forKey: "showDeviceIcons") }
    }
    
    @Published public var listRefreshInterval: Double = 2.0 {
        didSet { saveValue(listRefreshInterval, forKey: "listRefreshInterval") }
    }
    
    @Published public var showMACAddress: Bool = false {
        didSet { saveValue(showMACAddress, forKey: "showMACAddress") }
    }
    
    @Published public var showManufacturer: Bool = true {
        didSet { saveValue(showManufacturer, forKey: "showManufacturer") }
    }
    
    @Published public var showLastSeen: Bool = true {
        didSet { saveValue(showLastSeen, forKey: "showLastSeen") }
    }
    
    @Published public var defaultSortOption: String = "name" {
        didSet { saveValue(defaultSortOption, forKey: "defaultSortOption") }
    }
    
    @Published public var rememberFilterSettings: Bool = true {
        didSet { saveValue(rememberFilterSettings, forKey: "rememberFilterSettings") }
    }
    
 // MARK: - 连接设置
    @Published public var connectionTimeout: Double = 30.0 {
        didSet { saveValue(connectionTimeout, forKey: "connectionTimeout") }
    }
    
    @Published public var connectionRetryCount: Double = 3.0 {
        didSet { saveValue(connectionRetryCount, forKey: "connectionRetryCount") }
    }
    
    @Published public var autoReconnect: Bool = true {
        didSet { saveValue(autoReconnect, forKey: "autoReconnect") }
    }
    
    @Published public var rememberWiFiPasswords: Bool = true {
        didSet { saveValue(rememberWiFiPasswords, forKey: "rememberWiFiPasswords") }
    }
    
    @Published public var preferKnownNetworks: Bool = true {
        didSet { saveValue(preferKnownNetworks, forKey: "preferKnownNetworks") }
    }
    
    @Published public var autoBluetoothPairing: Bool = false {
        didSet { saveValue(autoBluetoothPairing, forKey: "autoBluetoothPairing") }
    }
    
    @Published public var keepBluetoothActive: Bool = true {
        didSet { saveValue(keepBluetoothActive, forKey: "keepBluetoothActive") }
    }
    
 // MARK: - 高级设置
    @Published public var maxDeviceCache: Double = 500.0 {
        didSet { saveValue(maxDeviceCache, forKey: "maxDeviceCache") }
    }
    
    @Published public var cacheCleanupInterval: Double = 6.0 {
        didSet { saveValue(cacheCleanupInterval, forKey: "cacheCleanupInterval") }
    }
    
    @Published public var enablePerformanceMonitoring: Bool = false {
        didSet { saveValue(enablePerformanceMonitoring, forKey: "enablePerformanceMonitoring") }
    }
    
    @Published public var logLevel: String = "info" {
        didSet { saveValue(logLevel, forKey: "logLevel") }
    }
    
    @Published public var saveLogsToFile: Bool = true {
        didSet { saveValue(saveLogsToFile, forKey: "saveLogsToFile") }
    }
    
    @Published public var logRetentionDays: Double = 7.0 {
        didSet { saveValue(logRetentionDays, forKey: "logRetentionDays") }
    }
    
 // MARK: - 初始化
    private init() {
        loadSettings()
    }
    
 // MARK: - 设置加载和保存
    private func loadSettings() {
 // 扫描设置
        wifiScanInterval = loadValue(forKey: "wifiScanInterval", defaultValue: 5.0)
        wifiScanTimeout = loadValue(forKey: "wifiScanTimeout", defaultValue: 30.0)
        autoScanWiFi = loadValue(forKey: "autoScanWiFi", defaultValue: true)
        
        bluetoothScanInterval = loadValue(forKey: "bluetoothScanInterval", defaultValue: 5.0)
        bluetoothScanTimeout = loadValue(forKey: "bluetoothScanTimeout", defaultValue: 30.0)
        autoScanBluetooth = loadValue(forKey: "autoScanBluetooth", defaultValue: true)
        scanBLEDevices = loadValue(forKey: "scanBLEDevices", defaultValue: true)
        
        airplayScanInterval = loadValue(forKey: "airplayScanInterval", defaultValue: 10.0)
        autoScanAirPlay = loadValue(forKey: "autoScanAirPlay", defaultValue: true)
        
 // 显示设置
        showOfflineDevices = loadValue(forKey: "showOfflineDevices", defaultValue: true)
        showSignalStrength = loadValue(forKey: "showSignalStrength", defaultValue: true)
        showDeviceIcons = loadValue(forKey: "showDeviceIcons", defaultValue: true)
        listRefreshInterval = loadValue(forKey: "listRefreshInterval", defaultValue: 2.0)
        
        showMACAddress = loadValue(forKey: "showMACAddress", defaultValue: false)
        showManufacturer = loadValue(forKey: "showManufacturer", defaultValue: true)
        showLastSeen = loadValue(forKey: "showLastSeen", defaultValue: true)
        
        defaultSortOption = loadValue(forKey: "defaultSortOption", defaultValue: "name")
        rememberFilterSettings = loadValue(forKey: "rememberFilterSettings", defaultValue: true)
        
 // 连接设置
        connectionTimeout = loadValue(forKey: "connectionTimeout", defaultValue: 30.0)
        connectionRetryCount = loadValue(forKey: "connectionRetryCount", defaultValue: 3.0)
        autoReconnect = loadValue(forKey: "autoReconnect", defaultValue: true)
        
        rememberWiFiPasswords = loadValue(forKey: "rememberWiFiPasswords", defaultValue: true)
        preferKnownNetworks = loadValue(forKey: "preferKnownNetworks", defaultValue: true)
        
        autoBluetoothPairing = loadValue(forKey: "autoBluetoothPairing", defaultValue: false)
        keepBluetoothActive = loadValue(forKey: "keepBluetoothActive", defaultValue: true)
        
 // 高级设置
        maxDeviceCache = loadValue(forKey: "maxDeviceCache", defaultValue: 500.0)
        cacheCleanupInterval = loadValue(forKey: "cacheCleanupInterval", defaultValue: 6.0)
        enablePerformanceMonitoring = loadValue(forKey: "enablePerformanceMonitoring", defaultValue: false)
        
        logLevel = loadValue(forKey: "logLevel", defaultValue: "info")
        saveLogsToFile = loadValue(forKey: "saveLogsToFile", defaultValue: true)
        logRetentionDays = loadValue(forKey: "logRetentionDays", defaultValue: 7.0)
    }
    
 /// 保存所有设置
    public func saveSettings() {
        userDefaults.synchronize()
        
 // 发送设置更新通知
        NotificationCenter.default.post(
            name: .deviceManagementSettingsDidChange,
            object: self
        )
    }
    
 /// 重置为默认设置
    public func resetToDefaults() {
 // 清除所有相关的UserDefaults键
        let keys = userDefaults.dictionaryRepresentation().keys
        for key in keys {
            if key.hasPrefix(settingsPrefix) {
                userDefaults.removeObject(forKey: key)
            }
        }
        
 // 重新加载默认设置
        loadSettings()
        
 // 保存更改
        saveSettings()
    }
    
 /// 清除设备缓存
    public func clearDeviceCache() {
 // 发送清除缓存通知
        NotificationCenter.default.post(
            name: .clearDeviceCache,
            object: self
        )
    }
    
 // MARK: - 私有辅助方法
    private func saveValue<T>(_ value: T, forKey key: String) {
        userDefaults.set(value, forKey: settingsPrefix + key)
    }
    
    private func loadValue<T>(forKey key: String, defaultValue: T) -> T {
        let fullKey = settingsPrefix + key
        
        if userDefaults.object(forKey: fullKey) != nil {
            if let value = userDefaults.object(forKey: fullKey) as? T {
                return value
            }
        }
        
        return defaultValue
    }
}

// MARK: - 通知名称扩展
extension Notification.Name {
 /// 设备管理设置发生变化
    static let deviceManagementSettingsDidChange = Notification.Name("deviceManagementSettingsDidChange")
    
 /// 清除设备缓存
    static let clearDeviceCache = Notification.Name("clearDeviceCache")
}