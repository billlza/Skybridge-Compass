import Foundation

/// Non-secret preferences supported by the native settings owner. Security
/// policy, identity provisioning and peer consent are deliberately separate.
public enum OperatorPreferenceContract {
    public static let booleanIDs: Set<String> = [
        "general.auto_scan_startup",
        "general.notifications",
        "general.dark_mode",
        "general.device_details",
        "general.connection_stats",
        "general.compact_mode",
        "network.bonjour_discovery",
        "network.mdns_resolution",
        "device.auto_connect_paired",
        "device.show_rssi",
        "device.connectable_only",
        "device.hide_offline",
        "device.sort_by_signal",
        "device.icons",
        "file.notifications",
        "file.keep_history",
        "file.keep_awake",
        "monitor.cpu_visible",
        "monitor.memory_visible",
        "monitor.temperature_visible",
        "monitor.fan_visible",
        "monitor.disk_visible",
        "monitor.network_visible",
        "monitor.trend_indicators",
        "monitor.auto_refresh",
        "advanced.realtime_weather",
        "advanced.hardware_acceleration"
    ]
}

@MainActor
public enum OperatorPreferenceAccess {
    private static let properties: [String: ReferenceWritableKeyPath<SettingsManager, Bool>] = [
        "general.auto_scan_startup": \SettingsManager.autoScanOnStartup,
        "general.notifications": \SettingsManager.showSystemNotifications,
        "general.dark_mode": \SettingsManager.useDarkMode,
        "general.device_details": \SettingsManager.showDeviceDetails,
        "general.connection_stats": \SettingsManager.showConnectionStats,
        "general.compact_mode": \SettingsManager.compactMode,
        "network.bonjour_discovery": \SettingsManager.enableBonjourDiscovery,
        "network.mdns_resolution": \SettingsManager.enableMDNSResolution,
        "device.auto_connect_paired": \SettingsManager.autoConnectPairedDevices,
        "device.show_rssi": \SettingsManager.showDeviceRSSI,
        "device.connectable_only": \SettingsManager.showConnectableDevicesOnly,
        "device.hide_offline": \SettingsManager.hideOfflineDevices,
        "device.sort_by_signal": \SettingsManager.sortBySignalStrength,
        "device.icons": \SettingsManager.showDeviceIcons,
        "file.notifications": \SettingsManager.showFileTransferNotifications,
        "file.keep_history": \SettingsManager.keepTransferHistory,
        "file.keep_awake": \SettingsManager.keepSystemAwakeDuringTransfer,
        "monitor.cpu_visible": \SettingsManager.showMonitorCPU,
        "monitor.memory_visible": \SettingsManager.showMonitorMemory,
        "monitor.temperature_visible": \SettingsManager.showMonitorTemperature,
        "monitor.fan_visible": \SettingsManager.showMonitorFanSpeed,
        "monitor.disk_visible": \SettingsManager.showMonitorDisk,
        "monitor.network_visible": \SettingsManager.showMonitorNetwork,
        "monitor.trend_indicators": \SettingsManager.showTrendIndicators,
        "monitor.auto_refresh": \SettingsManager.enableAutoRefresh,
        "advanced.realtime_weather": \SettingsManager.enableRealTimeWeather,
        "advanced.hardware_acceleration": \SettingsManager.enableHardwareAcceleration
    ]

    public static func snapshot(_ settings: SettingsManager) -> [CrossnetControlSettingSnapshot] {
        properties.sorted { $0.key < $1.key }.map { id, keyPath in
            return CrossnetControlSettingSnapshot(id: id, valueType: "bool",
                value: .bool(settings[keyPath: keyPath]), mutable: false)
        }
    }

    public static func read(_ id: String, from settings: SettingsManager) throws -> CrossnetControlJSONValue {
        guard let keyPath = properties[id] else { throw CrossnetControlFailure.settingNotFound }
        return .bool(settings[keyPath: keyPath])
    }

    public static func apply(_ request: CrossnetControlSettingsMutationRequest, to settings: SettingsManager) throws {
        guard let keyPath = properties[request.id] else { throw CrossnetControlFailure.settingNotFound }
        guard case .bool(let value) = request.value else { throw CrossnetControlFailure.settingInvalidValue }
        settings[keyPath: keyPath] = value
    }
}
