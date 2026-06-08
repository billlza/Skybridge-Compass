# Windows UI parity matrix

This matrix is the compact, auditable map for macOS-to-Windows button and feature placement. It focuses on controllable parity: feature order, action position, automation anchors, and shared style/template ownership. Fonts, rendering scale, and platform-specific pixel metrics are intentionally out of scope.

## Source Baseline

- Mac navigation source: `origin/tdsc-2026-01-0318-ios-sim-fix:Sources/SkyBridgeCompassApp/Dashboard/Navigation/NavigationItem.swift`.
- Mac dashboard source: `origin/tdsc-2026-01-0318-ios-sim-fix:Sources/SkyBridgeCompassApp/Dashboard/Sections/DashboardContentView.swift`.
- Mac quick actions source: `origin/tdsc-2026-01-0318-ios-sim-fix:Sources/SkyBridgeCompassApp/Dashboard/Sections/QuickActionsPanelView.swift`.
- Mac top bar source: `origin/tdsc-2026-01-0318-ios-sim-fix:Sources/SkyBridgeCompassApp/Dashboard/TopBar/TopNavigationBarView.swift`.
- Windows shell source: `windows/Skybridge.WinClient/MainWindow.xaml`.
- Windows catalog source: `windows/Skybridge.WinClient/Services/FeatureCatalogClient.cs` and `windows/Skybridge.WinClient/Services/WorkspaceActionCatalogClient.cs`.

## Navigation And Workspace Matrix

| Mac order | Windows feature id | Visible title | XAML visibility gate | Required action surfaces | Required automation anchors |
| --- | --- | --- | --- | --- | --- |
| 1 | Dashboard | Dashboard | `IsDashboardSelected` | `DashboardQuickActions` | `Skybridge.Navigation.List`; `Skybridge.SelectedFeature.Title`; `Skybridge.Actions.DashboardQuickActions` |
| 2 | DeviceDiscovery | Device Discovery | `IsDeviceDiscoverySelected` | `DeviceDiscoveryPrimary`; `DeviceDiscoveryScan`; `DeviceDiscoveryManualConnectFinal`; `CrossNetworkQr`; `CrossNetworkCodePrimary`; `CrossNetworkCodeConnect` | `WorkspaceAction.DeviceDiscoveryPrimary.ParseTxt`; `WorkspaceAction.DeviceDiscoveryScan.ManualConnect`; `Skybridge.Actions.DeviceDiscoveryManualConnectFinal` |
| 3 | UsbManagement | USB Management | `IsUsbManagementSelected` | `UsbManagementHeader` | `WorkspaceAction.UsbManagementHeader.RefreshDevices` |
| 4 | FileTransfer | File Transfer | `IsFileTransferSelected` | `FileTransferHeader`; `FileTransfer` | `WorkspaceAction.FileTransfer.SelectFiles`; `WorkspaceAction.FileTransfer.SelectFolder`; `WorkspaceAction.FileTransfer.GenerateQr` |
| 5 | RemoteDesktop | Remote Desktop | `IsRemoteDesktopSelected` | `RemoteDesktopHeader`; `RemoteDesktop` | `WorkspaceAction.RemoteDesktop.RecommendedConnect`; `WorkspaceAction.RemoteDesktop.AdvancedConnect`; `WorkspaceAction.RemoteDesktop.DisconnectSession` |
| 6 | Quantum | Quantum / Core Diagnostics | `IsQuantumSelected` | `QuantumDiagnosticsHeader` | `WorkspaceAction.QuantumDiagnosticsHeader.RunDiagnostics` |
| 7 | SystemMonitor | System Monitor | `IsSystemMonitorSelected` | `SystemMonitorHeader`; `SystemMonitorControls` | `WorkspaceAction.SystemMonitorControls.Monitoring`; `WorkspaceAction.SystemMonitorControls.StopMonitoring`; `WorkspaceAction.SystemMonitorControls.EnableAdvancedMonitoring` |
| 8 | Settings | Settings | `IsSettingsSelected` | `SettingsHeader`; `SettingsToolbar`; `SettingsMaintenance` | `WorkspaceAction.SettingsToolbar.ExportSettings`; `WorkspaceAction.SettingsToolbar.OpenSystemPreferences`; `WorkspaceAction.SettingsMaintenance.ApplySettings` |

## Global Shell Matrix

| Region | Mac position | Windows binding | Required order |
| --- | --- | --- | --- |
| Sidebar | Product name, navigation, session actions | `NavigationItems`; `SidebarSessionActions` | Navigation list before sidebar connect/disconnect |
| Top bar | Selected feature, Core/connection state, diagnostics, notifications, theme | `SelectedFeature`; `ConnectionStatus`; `TopBarStatusItems`; `TopBarActions` | selected feature, status message, connection status, diagnostics status, notifications/theme actions |
| Session controls | Global connection controls | `SessionControlActions`; `BitrateProfiles`; `FramerateProfiles` | Connect, Heartbeat, Disconnect before bitrate/framerate selectors |

## Action Order Matrix

| Surface | Required action key order |
| --- | --- |
| `SidebarSession` | `Connect`, `Disconnect` |
| `TopBarActions` | `Notifications`, `Theme` |
| `SessionControls` | `Connect`, `Heartbeat`, `Disconnect` |
| `DashboardQuickActions` | `ScanDevices`, `FileTransfer`, `SystemMonitor`, `Settings` |
| `DeviceDiscoveryPrimary` | `ParseTxt`, `ValidatePairing`, `PrepareConnection` |
| `DeviceDiscoveryScan` | `ExtendedSearch`, `ManualConnect`, `StartScan`, `StopScan`, `Refresh` |
| `DeviceDiscoveryManualConnectFinal` | `Connect` |
| `CrossNetworkQr` | `GenerateQrCode`, `ScanQrCode` |
| `CrossNetworkCodePrimary` | `GenerateCode`, `CopyCode`, `RegenerateCode` |
| `CrossNetworkCodeConnect` | `ConnectWithCode` |
| `UsbManagementHeader` | `RefreshDevices` |
| `FileTransferHeader` | `RefreshPlan` |
| `FileTransfer` | `SelectFiles`, `SelectFolder`, `GenerateQr` |
| `RemoteDesktopHeader` | `RefreshSessions` |
| `RemoteDesktop` | `RecommendedConnect`, `AdvancedConnect`, `PerformanceOverlay`, `Quality`, `Settings`, `FullScreen`, `DisconnectSession` |
| `QuantumDiagnosticsHeader` | `RunDiagnostics` |
| `SystemMonitorHeader` | `RefreshMetrics` |
| `SystemMonitorControls` | `Monitoring`, `StopMonitoring`, `EnableAdvancedMonitoring` |
| `SettingsHeader` | `RefreshStatus` |
| `SettingsToolbar` | `ExportSettings`, `ImportSettings`, `ResetSettings`, `RequestPermission`, `OpenSystemPreferences` |
| `SettingsMaintenance` | `ApplySettings`, `RestoreDefaults`, `ResetMonitorData` |

## Verification

- `Scripts/verify-windows-ui-parity-matrix.ps1` verifies this matrix, `MainWindow.xaml`, `FeatureCatalogClient`, and `WorkspaceActionCatalogClient` agree on feature order, workspace visibility order, top-bar/session anchors, and per-surface action order.
- `Scripts/verify-windows-ui-action-order.ps1` remains the executable catalog smoke for action keys and automation ids.
- `Scripts/verify-windows-ui-parity.ps1` remains the broader static modularity gate.
