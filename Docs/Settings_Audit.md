# Settings Audit (auto-generated)

Scanned **2156** Swift files. Found **366** controls.

## 1) Toggles bound to `@State Bool` (review for persistence / wiring)

- **Sources/SkyBridgeCore/Managers/DeviceManagementExtensionManager.swift:554** — bound `$isEnabled` — `Toggle("", isOn: $isEnabled)`
- **Sources/SkyBridgeCore/SystemMonitor/SystemMonitorSettingsView.swift:91** — bound `$enableAutoRefresh` — `Toggle("启用自动刷新", isOn: $enableAutoRefresh)`
- **Sources/SkyBridgeCore/SystemMonitor/SystemMonitorSettingsView.swift:174** — bound `$enablePerformanceAlerts` — `Toggle("启用性能警报", isOn: $enablePerformanceAlerts)`
- **Sources/SkyBridgeCore/SystemMonitor/SystemMonitorSettingsView.swift:181** — bound `$enableTemperatureMonitoring` — `Toggle("启用温度监控", isOn: $enableTemperatureMonitoring)`
- **Sources/SkyBridgeCore/SystemMonitor/SystemMonitorSettingsView.swift:203** — bound `$enableFanSpeedMonitoring` — `Toggle("启用风扇转速监控", isOn: $enableFanSpeedMonitoring)`
- **Sources/SkyBridgeCore/SystemMonitor/SystemMonitorSettingsView.swift:224** — bound `$enableThermalThrottlingAlert` — `Toggle("启用热量节流警报", isOn: $enableThermalThrottlingAlert)`
- **Sources/SkyBridgeCore/SystemMonitor/SystemMonitorSettingsView.swift:237** — bound `$showTrendIndicators` — `Toggle("显示趋势指示器", isOn: $showTrendIndicators)`
- **Sources/SkyBridgeCore/SystemMonitor/SystemMonitorSettingsView.swift:262** — bound `$enableNotifications` — `Toggle("启用通知提醒", isOn: $enableNotifications)`
- **Sources/SkyBridgeCore/SystemMonitor/SystemMonitorSettingsView.swift:264** — bound `$enableSoundAlerts` — `Toggle("启用声音提醒", isOn: $enableSoundAlerts)`
- **Sources/SkyBridgeUI/Network/BandwidthSettingsView.swift:27** — bound `$engine.isEnabled` — `Toggle("启用带宽限速", isOn: $engine.isEnabled)`
- **Sources/SkyBridgeUI/Network/BandwidthSettingsView.swift:263** — bound `$isEnabled` — `Toggle("启用", isOn: $isEnabled)`

## 2) Placeholder markers in settings-related files (needs manual review)

- **SkyBridge Compass iOS__inside_release_backup_20260120_175411/SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift**
  - L224: // 这里简化处理，实际使用时需要从 ScreenData 获取宽高
- **Sources/SkyBridgeCore/RemoteDesktop/Metal4EnhancedRenderer.swift**
  - L624: // MARK: - 兼容性占位符
  - L627: // MetalFX 占位符类型（macOS < 15.0）
  - L648: /// 旧系统优雅降级的简单缩放器——当无法使用 MetalFX 时，提供基本的纹理复制/缩放占位实现。
- **Sources/SkyBridgeCore/SystemMonitor/AppleOfficialSystemMonitor.swift**
  - L326: // 这里简化处理，实际应该使用IOKit
- **Sources/SkyBridgeCore/Weather/WeatherEffectView.swift**
  - L61: // ☀️ 晴天 - 简化占位符（由 DashboardView 处理完整效果）
  - L65: // ☁️ 多云 - 简化占位符（由 DashboardView 处理完整效果）
  - L69: // 🌧️ 雨天 - 简化占位符（由 DashboardView 处理完整效果）
  - L73: // ❄️ 雪天 - 简化占位符（由 DashboardView 处理完整效果）
- **Sources/SkyBridgeCore/Views/SettingsView.swift**
  - L900: // 显示实时FPS（顶部导航全局显示，开启后无数据时显示占位 — FPS）
- **Sources/SkyBridgeCompassApp/PreferencesView.swift**
  - L591: // 这里用“已配置/未配置”表达（避免占位假数据）。
  - L938: .help("在顶部导航显示Metal渲染FPS；无数据时显示占位字符 — FPS")
- **Sources/SkyBridgeCompassApp/Views/SimplifiedWeatherBridge.swift**
  - L78: // 显示占位符并异步加载配置
  - L161: // 显示占位符并异步加载配置

> Full raw inventory is in `Docs/settings_inventory.json`.

