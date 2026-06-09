# Windows UI parity matrix

This matrix is the compact, auditable map for macOS-to-Windows button and feature placement. It focuses on controllable parity: feature order, action position, automation anchors, and shared style/template ownership. Fonts, rendering scale, and platform-specific pixel metrics are intentionally out of scope.

## Source Baseline

- Mac baseline commit: `23ba06343bbaa58c30ef6b9bbddd09bb4e80241c` (`origin/tdsc-2026-01-0318-ios-sim-fix` at the 2026-06-09 audit).
- Mac navigation source: `23ba06343bbaa58c30ef6b9bbddd09bb4e80241c:Sources/SkyBridgeCompassApp/Dashboard/Navigation/NavigationItem.swift`.
- Mac dashboard source: `23ba06343bbaa58c30ef6b9bbddd09bb4e80241c:Sources/SkyBridgeCompassApp/Dashboard/Sections/DashboardContentView.swift`.
- Mac quick actions source: `23ba06343bbaa58c30ef6b9bbddd09bb4e80241c:Sources/SkyBridgeCompassApp/Dashboard/Sections/QuickActionsPanelView.swift`.
- Mac top bar source: `23ba06343bbaa58c30ef6b9bbddd09bb4e80241c:Sources/SkyBridgeCompassApp/Dashboard/TopBar/TopNavigationBarView.swift`.
- Windows shell source: `windows/Skybridge.WinClient/MainWindow.xaml`.
- Windows catalog source: `windows/Skybridge.WinClient/Services/FeatureCatalogClient.cs` and `windows/Skybridge.WinClient/Services/WorkspaceActionCatalogClient.cs`.

## Navigation And Workspace Matrix

| Mac order | Windows feature id | Visible title | XAML visibility gate | Required action surfaces | Required automation anchors |
| --- | --- | --- | --- | --- | --- |
| 1 | Dashboard | Dashboard | `IsDashboardSelected` | `DashboardQuickActions` | `Skybridge.Navigation.List`; `Skybridge.SelectedFeature.Title`; `Skybridge.Actions.DashboardQuickActions` |
| 2 | DeviceDiscovery | Device Discovery | `IsDeviceDiscoverySelected` | `DeviceDiscoveryPrimary`; `DeviceDiscoveryScan`; `DeviceDiscoveryManualConnectFinal`; `CrossNetworkQr`; `CrossNetworkCodePrimary`; `CrossNetworkCodeConnect` | `WorkspaceAction.DeviceDiscoveryPrimary.ParseTxt`; `WorkspaceAction.DeviceDiscoveryScan.ManualConnect`; `Skybridge.Actions.DeviceDiscoveryManualConnectFinal` |
| 3 | UsbManagement | USB Management | `IsUsbManagementSelected` | `UsbManagementHeader` | `WorkspaceAction.UsbManagementHeader.RefreshDevices` |
| 4 | FileTransfer | File Transfer | `IsFileTransferSelected` | `FileTransferHeader`; `FileTransfer` | `WorkspaceAction.FileTransfer.SelectFiles`; `WorkspaceAction.FileTransfer.SelectFolder`; `WorkspaceAction.FileTransfer.GenerateQr`; `FileTransferShareQrPreview` |
| 5 | RemoteDesktop | Remote Desktop | `IsRemoteDesktopSelected` | `RemoteDesktopHeader`; `RemoteDesktop` | `WorkspaceAction.RemoteDesktop.RecommendedConnect`; `WorkspaceAction.RemoteDesktop.AdvancedConnect`; `WorkspaceAction.RemoteDesktop.DisconnectSession` |
| 6 | Quantum | Quantum / Core Diagnostics | `IsQuantumSelected` | `QuantumDiagnosticsHeader` | `WorkspaceAction.QuantumDiagnosticsHeader.RunDiagnostics` |
| 7 | SystemMonitor | System Monitor | `IsSystemMonitorSelected` | `SystemMonitorHeader`; `SystemMonitorControls` | `WorkspaceAction.SystemMonitorControls.Monitoring`; `WorkspaceAction.SystemMonitorControls.StopMonitoring`; `WorkspaceAction.SystemMonitorControls.EnableAdvancedMonitoring` |
| 8 | Settings | Settings | `IsSettingsSelected` | `SettingsHeader`; `SettingsToolbar`; `SettingsMaintenance` | `WorkspaceAction.SettingsToolbar.ExportSettings`; `WorkspaceAction.SettingsToolbar.OpenSystemPreferences`; `WorkspaceAction.SettingsMaintenance.ApplySettings` |

## Mac-To-Windows Baseline Signal Matrix

| Mac source | Required ordered mac symbols | Windows parity anchor |
| --- | --- | --- |
| `NavigationItem.swift` | `case dashboard = "sidebar.dashboard"`; `case deviceManagement = "sidebar.deviceDiscovery"`; `case usbDeviceManagement = "sidebar.usbManagement"`; `case fileTransfer = "sidebar.fileTransfer"`; `case remoteDesktop = "sidebar.remoteDesktop"`; `case quantumCommunication = "quantum.title"`; `case systemMonitor = "sidebar.systemMonitor"`; `case settings = "sidebar.settings"` | `FeatureCatalogClient.Entries` |
| `DashboardContentView.swift` | `topStatsRow`; `WeatherDashboardCard()`; `DeviceDiscoveryPanelView(`; `RemoteSessionsPanelView(selectedSession: $selectedSession)`; `QuickActionsPanelView(selectedNavigation: $selectedNavigation)`; `AppleSiliconInfoCardView()` | `DashboardMetrics`; `DeviceDiscoveryScan`; `RemoteDesktopSessions`; `DashboardQuickActions`; `QuantumDiagnosticsHeader` |
| `QuickActionsPanelView.swift` | `action.scanDevices`; `appModel.triggerDiscoveryRefresh()`; `dashboard.fileTransfer`; `selectedNavigation = .fileTransfer`; `action.systemMonitor`; `selectedNavigation = .systemMonitor`; `action.settings`; `selectedNavigation = .settings` | `DashboardQuickActions` |
| `TopNavigationBarView.swift` | `ipLocationIndicator`; `networkSpeedIndicator`; `networkLatencyIndicator`; `connectionStatusIndicator`; `fpsIndicator`; `NotificationBellView()`; `themeToggleButton`; `manualConnect.title`; `manualConnect.ipAddress`; `manualConnect.port`; `manualConnect.pairingCode`; `action.cancel`; `device.action.connect`; `appModel.manualConnect(ip: manualIP, port: port, pairingCode: manualCode)` | `TopBarStatusClient`; `TopBarStatusSlot`; `TopBarActions`; `DeviceDiscoveryScan`; `ManualConnectionClient`; `DeviceDiscoveryManualConnectFinal` |

## Global Shell Matrix

| Region | Mac position | Windows binding | Required order |
| --- | --- | --- | --- |
| Sidebar | Product name, navigation, session actions | `NavigationItems`; `SidebarSessionActions` | Navigation list before sidebar connect/disconnect |
| Top bar | Selected feature, Core/connection state, diagnostics, notifications, theme | `SelectedFeature`; `ConnectionStatus`; `TopBarConnectionStatus`; `PerformanceStatus`; `TopBarDiagnosticsStatus`; `TopBarActions` | selected feature, status message, connection status, diagnostics status, notifications/theme actions |
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
| `DeviceDiscoveryManualConnectFinal` | `Cancel`, `Connect` |
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

## Dynamic Refresh Surface Matrix

| Source | Required dynamic surface order |
| --- | --- |
| `WorkspaceActionCatalogClient.DynamicRefreshSurfaces` | `SidebarSession`; `TopBarActions`; `SessionControls`; `DeviceDiscoveryPrimary`; `DeviceDiscoveryScan`; `DeviceDiscoveryManualConnectFinal`; `CrossNetworkQr`; `CrossNetworkCodePrimary`; `CrossNetworkCodeConnect`; `UsbManagementHeader`; `FileTransferHeader`; `FileTransfer`; `RemoteDesktopHeader`; `RemoteDesktop`; `QuantumDiagnosticsHeader`; `SystemMonitorHeader`; `SystemMonitorControls`; `SettingsHeader`; `SettingsToolbar`; `SettingsMaintenance` |

## Shared Style And Template Matrix

| Region | Required shared template | Required panel/style ownership |
| --- | --- | --- |
| Sidebar session actions | `SidebarWorkspaceActionButtonTemplate` | `VerticalWorkspaceActionItemsPanel` |
| Top-bar actions | `TopBarStatusActionButtonTemplate` | `HorizontalWorkspaceActionItemsPanel` |
| Dashboard quick actions | `DashboardQuickActionTemplate` | `DashboardQuickActionItemsPanel` |
| Workspace action surfaces | `WorkspaceActionButtonTemplate` | `HorizontalWorkspaceActionItemsPanel` |
| Final/manual connect action | `WorkspaceActionButtonWithDetailTemplate` | `HorizontalWorkspaceActionItemsPanel` |

All action buttons must be rendered through these shared templates. Feature sections must not introduce inline `Button` controls for local-only styling, because button shape, command binding, automation id/name binding, tooltip title binding, compact workspace tool-button sizing, and spacing are part of the mac-parity contract.

## Verification

- `Scripts/verify-windows-ui-parity-matrix.ps1` parses these markdown tables and verifies exact row counts, row order, duplicate prevention, pinned mac baseline objects, ordered mac source symbols, `MainWindow.xaml`, `FeatureCatalogClient`, and `WorkspaceActionCatalogClient` agree on feature order, workspace visibility order, top-bar/session anchors, and per-surface action order.
- The matrix smoke also verifies shared action templates, compact workspace tool-button sizing, tooltip title binding, and rejects inline XAML action buttons outside the approved templates.
- The matrix smoke verifies both initial and dynamic workspace action surface orders so selected-feature, readiness, and pending-provider state changes cannot leave visible buttons stale.
- `Scripts/verify-windows-ui-action-order.ps1` remains the executable catalog smoke for action keys and automation ids.
- `Scripts/verify-windows-ui-automation-smoke.ps1 -EvidenceDir <dir>` captures the rendered WinUI shell for all eight workspaces at requested logical window sizes 1280x900 and 1366x768 and writes `windows-ui-visual-evidence.json` with requested size, actual screenshot pixel size, the corresponding automation-anchor bounds, and `runtimeActionBounds` generated from this matrix's Action Order Matrix. The runtime bounds gate verifies every visible global and selected-workspace `WorkspaceAction.<Surface>.<Key>` AutomationId exists with minimum usable bounds and flows in matrix order before the screenshot evidence is accepted. These artifacts are the local visual evidence package for mac/iOS comparison while fonts, OS scale, and platform pixel metrics remain out of scope.
- `Scripts/verify-windows-ui-visual-evidence.ps1 -EvidenceDir <dir>` is the standalone artifact verifier for that package. It checks the manifest, 16 PNG screenshots, all eight workspaces, both requested window sizes, anchor bounds, screenshot headers, and every recorded `runtimeActionBounds` surface/key/order against this Action Order Matrix so visual evidence can be revalidated after capture.
- `Scripts/verify-windows-ui-parity.ps1` remains the broader static modularity gate.
