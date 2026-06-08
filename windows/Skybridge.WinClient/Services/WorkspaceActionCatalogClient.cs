using System;
using System.Collections.Generic;

namespace Skybridge.WinClient.Services;

public interface IWorkspaceActionCatalogClient
{
    IReadOnlyList<WorkspaceActionSurface> BuildInitialSurfaces();

    IReadOnlyList<WorkspaceActionSurface> BuildDynamicRefreshSurfaces();

    WorkspaceActionCatalogSnapshot BuildReadOnlySnapshot(WorkspaceActionCatalogRequest request);

    WorkspaceActionCatalogSnapshot BuildResolvedSnapshot(
        WorkspaceActionCatalogRequest request,
        WorkspaceActionGateSnapshot gates,
        WorkspaceActionDetailSnapshot details);

    bool ResolveEnabled(
        WorkspaceActionGateId gateId,
        WorkspaceActionGateSnapshot gates,
        bool fallback);

    string ResolveDetail(
        WorkspaceActionDetailSlot detailSlot,
        WorkspaceActionDetailSnapshot details,
        string fallback);
}

public sealed class WorkspaceActionCatalogClient : IWorkspaceActionCatalogClient
{
    private static readonly WorkspaceActionSurface[] InitialSurfaces =
    {
        WorkspaceActionSurface.SidebarSession,
        WorkspaceActionSurface.TopBarActions,
        WorkspaceActionSurface.SessionControls,
        WorkspaceActionSurface.DashboardQuickActions,
        WorkspaceActionSurface.DeviceDiscoveryPrimary,
        WorkspaceActionSurface.DeviceDiscoveryScan,
        WorkspaceActionSurface.DeviceDiscoveryManualConnectFinal,
        WorkspaceActionSurface.CrossNetworkQr,
        WorkspaceActionSurface.CrossNetworkCodePrimary,
        WorkspaceActionSurface.CrossNetworkCodeConnect,
        WorkspaceActionSurface.UsbManagementHeader,
        WorkspaceActionSurface.FileTransferHeader,
        WorkspaceActionSurface.FileTransfer,
        WorkspaceActionSurface.RemoteDesktopHeader,
        WorkspaceActionSurface.RemoteDesktop,
        WorkspaceActionSurface.QuantumDiagnosticsHeader,
        WorkspaceActionSurface.SystemMonitorHeader,
        WorkspaceActionSurface.SystemMonitorControls,
        WorkspaceActionSurface.SettingsHeader,
        WorkspaceActionSurface.SettingsToolbar,
        WorkspaceActionSurface.SettingsMaintenance
    };

    private static readonly WorkspaceActionSurface[] DynamicRefreshSurfaces =
    {
        WorkspaceActionSurface.SidebarSession,
        WorkspaceActionSurface.TopBarActions,
        WorkspaceActionSurface.SessionControls,
        WorkspaceActionSurface.DeviceDiscoveryPrimary,
        WorkspaceActionSurface.DeviceDiscoveryScan,
        WorkspaceActionSurface.DeviceDiscoveryManualConnectFinal,
        WorkspaceActionSurface.CrossNetworkQr,
        WorkspaceActionSurface.CrossNetworkCodePrimary,
        WorkspaceActionSurface.CrossNetworkCodeConnect,
        WorkspaceActionSurface.UsbManagementHeader,
        WorkspaceActionSurface.FileTransferHeader,
        WorkspaceActionSurface.FileTransfer,
        WorkspaceActionSurface.RemoteDesktopHeader,
        WorkspaceActionSurface.RemoteDesktop,
        WorkspaceActionSurface.QuantumDiagnosticsHeader,
        WorkspaceActionSurface.SystemMonitorHeader,
        WorkspaceActionSurface.SystemMonitorControls,
        WorkspaceActionSurface.SettingsHeader,
        WorkspaceActionSurface.SettingsToolbar,
        WorkspaceActionSurface.SettingsMaintenance
    };

    public IReadOnlyList<WorkspaceActionSurface> BuildInitialSurfaces() => InitialSurfaces;

    public IReadOnlyList<WorkspaceActionSurface> BuildDynamicRefreshSurfaces() => DynamicRefreshSurfaces;

    public WorkspaceActionCatalogSnapshot BuildReadOnlySnapshot(WorkspaceActionCatalogRequest request) =>
        new(
            DateTimeOffset.UtcNow,
            request.Surface,
            request.Surface switch
            {
                WorkspaceActionSurface.SidebarSession => BuildSidebarSessionActions(),
                WorkspaceActionSurface.TopBarActions => BuildTopBarActions(),
                WorkspaceActionSurface.SessionControls => BuildSessionControlActions(),
                WorkspaceActionSurface.DashboardQuickActions => BuildDashboardQuickActions(),
                WorkspaceActionSurface.DeviceDiscoveryPrimary => BuildDeviceDiscoveryPrimaryActions(),
                WorkspaceActionSurface.DeviceDiscoveryScan => BuildDeviceDiscoveryScanActions(),
                WorkspaceActionSurface.DeviceDiscoveryManualConnectFinal => BuildDeviceDiscoveryManualConnectFinalActions(),
                WorkspaceActionSurface.CrossNetworkQr => BuildCrossNetworkQrActions(),
                WorkspaceActionSurface.CrossNetworkCodePrimary => BuildCrossNetworkCodePrimaryActions(),
                WorkspaceActionSurface.CrossNetworkCodeConnect => BuildCrossNetworkCodeConnectActions(),
                WorkspaceActionSurface.UsbManagementHeader => BuildUsbManagementHeaderActions(),
                WorkspaceActionSurface.FileTransferHeader => BuildFileTransferHeaderActions(),
                WorkspaceActionSurface.FileTransfer => BuildFileTransferActions(),
                WorkspaceActionSurface.RemoteDesktopHeader => BuildRemoteDesktopHeaderActions(),
                WorkspaceActionSurface.RemoteDesktop => BuildRemoteDesktopActions(),
                WorkspaceActionSurface.QuantumDiagnosticsHeader => BuildQuantumDiagnosticsHeaderActions(),
                WorkspaceActionSurface.SystemMonitorHeader => BuildSystemMonitorHeaderActions(),
                WorkspaceActionSurface.SystemMonitorControls => BuildSystemMonitorControlActions(),
                WorkspaceActionSurface.SettingsHeader => BuildSettingsHeaderActions(),
                WorkspaceActionSurface.SettingsToolbar => BuildSettingsToolbarActions(),
                WorkspaceActionSurface.SettingsMaintenance => BuildSettingsMaintenanceActions(),
                _ => new List<WorkspaceActionItem>()
            });

    public WorkspaceActionCatalogSnapshot BuildResolvedSnapshot(
        WorkspaceActionCatalogRequest request,
        WorkspaceActionGateSnapshot gates,
        WorkspaceActionDetailSnapshot details)
    {
        var snapshot = BuildReadOnlySnapshot(request);
        var resolvedActions = new List<WorkspaceActionItem>();

        foreach (var action in snapshot.Actions)
        {
            resolvedActions.Add(action with
            {
                IsEnabled = ResolveEnabled(action.GateId, gates, action.IsEnabled),
                Detail = ResolveDetail(action.DetailSlot, details, action.Detail)
            });
        }

        return new(snapshot.CapturedAt, snapshot.Surface, resolvedActions);
    }

    public bool ResolveEnabled(
        WorkspaceActionGateId gateId,
        WorkspaceActionGateSnapshot gates,
        bool fallback) =>
        gateId switch
        {
            WorkspaceActionGateId.CanConnect => gates.CanConnect,
            WorkspaceActionGateId.CanDisconnect => gates.CanDisconnect,
            WorkspaceActionGateId.CanSendHeartbeat => gates.CanSendHeartbeat,
            WorkspaceActionGateId.CanOpenTopBarNotifications => gates.CanOpenTopBarNotifications,
            WorkspaceActionGateId.CanToggleTopBarTheme => gates.CanToggleTopBarTheme,
            WorkspaceActionGateId.CanUseDiscoveryBrowser => gates.CanUseDiscoveryBrowser,
            WorkspaceActionGateId.CanPrepareManualConnection => gates.CanPrepareManualConnection,
            WorkspaceActionGateId.CanParseAdvertisement => gates.CanParseAdvertisement,
            WorkspaceActionGateId.CanValidatePairing => gates.CanValidatePairing,
            WorkspaceActionGateId.CanPrepareConnection => gates.CanPrepareConnection,
            WorkspaceActionGateId.CanUseCrossNetworkConnection => gates.CanUseCrossNetworkConnection,
            WorkspaceActionGateId.CanScanQrCode => gates.CanScanQrCode,
            WorkspaceActionGateId.CanCopyConnectionCode => gates.CanCopyConnectionCode,
            WorkspaceActionGateId.CanConnectConnectionCode => gates.CanConnectConnectionCode,
            WorkspaceActionGateId.CanRefreshUsbManagement => gates.CanRefreshUsbManagement,
            WorkspaceActionGateId.CanRefreshFileTransfer => gates.CanRefreshFileTransfer,
            WorkspaceActionGateId.CanSelectFileTransferFiles => gates.CanSelectFileTransferFiles,
            WorkspaceActionGateId.CanSelectFileTransferFolder => gates.CanSelectFileTransferFolder,
            WorkspaceActionGateId.CanGenerateFileTransferQr => gates.CanGenerateFileTransferQr,
            WorkspaceActionGateId.CanRefreshRemoteDesktop => gates.CanRefreshRemoteDesktop,
            WorkspaceActionGateId.CanRecommendedRemoteDesktopConnect => gates.CanRecommendedRemoteDesktopConnect,
            WorkspaceActionGateId.CanAdvancedRemoteDesktopConnect => gates.CanAdvancedRemoteDesktopConnect,
            WorkspaceActionGateId.CanShowRemoteDesktopPerformanceOverlay => gates.CanShowRemoteDesktopPerformanceOverlay,
            WorkspaceActionGateId.CanApplyRemoteDesktopQuality => gates.CanApplyRemoteDesktopQuality,
            WorkspaceActionGateId.CanOpenRemoteDesktopSettings => gates.CanOpenRemoteDesktopSettings,
            WorkspaceActionGateId.CanEnterRemoteDesktopFullScreen => gates.CanEnterRemoteDesktopFullScreen,
            WorkspaceActionGateId.CanDisconnectRemoteDesktopSession => gates.CanDisconnectRemoteDesktopSession,
            WorkspaceActionGateId.CanRunCoreDiagnostics => gates.CanRunCoreDiagnostics,
            WorkspaceActionGateId.CanRefreshSystemMonitor => gates.CanRefreshSystemMonitor,
            WorkspaceActionGateId.CanStartSystemMonitoring => gates.CanStartSystemMonitoring,
            WorkspaceActionGateId.CanStopSystemMonitoring => gates.CanStopSystemMonitoring,
            WorkspaceActionGateId.CanEnableAdvancedSystemMonitoring => gates.CanEnableAdvancedSystemMonitoring,
            WorkspaceActionGateId.CanRefreshSettings => gates.CanRefreshSettings,
            WorkspaceActionGateId.CanExportSettings => gates.CanExportSettings,
            WorkspaceActionGateId.CanImportSettings => gates.CanImportSettings,
            WorkspaceActionGateId.CanResetSettings => gates.CanResetSettings,
            WorkspaceActionGateId.CanRequestSettingsPermission => gates.CanRequestSettingsPermission,
            WorkspaceActionGateId.CanOpenSystemPreferences => gates.CanOpenSystemPreferences,
            WorkspaceActionGateId.CanApplySettings => gates.CanApplySettings,
            WorkspaceActionGateId.CanRestoreDefaults => gates.CanRestoreDefaults,
            WorkspaceActionGateId.CanResetMonitorData => gates.CanResetMonitorData,
            _ => fallback
        };

    public string ResolveDetail(
        WorkspaceActionDetailSlot detailSlot,
        WorkspaceActionDetailSnapshot details,
        string fallback) =>
        detailSlot switch
        {
            WorkspaceActionDetailSlot.TopBarNotifications => details.TopBarNotificationsStatus,
            WorkspaceActionDetailSlot.TopBarTheme => details.TopBarThemeStatus,
            _ => fallback
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildSidebarSessionActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "Connect",
                "Connect",
                "\uE768",
                true,
                "Global session action; command stays in SessionViewModel.",
                CommandId: WorkspaceActionCommandId.Connect,
                GateId: WorkspaceActionGateId.CanConnect),
            new(
                "Disconnect",
                "Disconnect",
                "\uE711",
                true,
                "Global session action; command stays in SessionViewModel.",
                CommandId: WorkspaceActionCommandId.Disconnect,
                GateId: WorkspaceActionGateId.CanDisconnect)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildTopBarActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "Notifications",
                "Notifications",
                "\uEA8F",
                true,
                "Off",
                CommandId: WorkspaceActionCommandId.OpenTopBarNotifications,
                GateId: WorkspaceActionGateId.CanOpenTopBarNotifications,
                DetailSlot: WorkspaceActionDetailSlot.TopBarNotifications),
            new(
                "Theme",
                "Theme",
                "\uE771",
                true,
                "System",
                CommandId: WorkspaceActionCommandId.ToggleTopBarTheme,
                GateId: WorkspaceActionGateId.CanToggleTopBarTheme,
                DetailSlot: WorkspaceActionDetailSlot.TopBarTheme)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildSessionControlActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "Connect",
                "Connect",
                "\uE768",
                true,
                "Global session action; command stays in SessionViewModel.",
                CommandId: WorkspaceActionCommandId.Connect,
                GateId: WorkspaceActionGateId.CanConnect),
            new(
                "Heartbeat",
                "Heartbeat",
                "\uE95B",
                true,
                "Global session action; command stays in SessionViewModel.",
                CommandId: WorkspaceActionCommandId.Heartbeat,
                GateId: WorkspaceActionGateId.CanSendHeartbeat),
            new(
                "Disconnect",
                "Disconnect",
                "\uE711",
                true,
                "Global session action; command stays in SessionViewModel.",
                CommandId: WorkspaceActionCommandId.Disconnect,
                GateId: WorkspaceActionGateId.CanDisconnect)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildDashboardQuickActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "ScanDevices",
                "Scan Devices",
                "\uE721",
                true,
                "Device Discovery",
                CommandId: WorkspaceActionCommandId.OpenDeviceDiscovery),
            new(
                "FileTransfer",
                "File Transfer",
                "\uE8E5",
                true,
                "Queue and history",
                CommandId: WorkspaceActionCommandId.OpenFileTransfer),
            new(
                "SystemMonitor",
                "System Monitor",
                "\uE9D9",
                true,
                "Metrics",
                CommandId: WorkspaceActionCommandId.OpenSystemMonitor),
            new(
                "Settings",
                "Settings",
                "\uE713",
                true,
                "Preferences",
                CommandId: WorkspaceActionCommandId.OpenSettings)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildDeviceDiscoveryPrimaryActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "ParseTxt",
                "Parse TXT",
                "\uE8B9",
                true,
                "Mac-parity discovery parser action; command stays in SessionViewModel.",
                CommandId: WorkspaceActionCommandId.ParseTxt,
                GateId: WorkspaceActionGateId.CanParseAdvertisement),
            new(
                "ValidatePairing",
                "Validate Pairing",
                "\uE8D7",
                true,
                "Mac-parity pairing validation action; command stays in SessionViewModel.",
                CommandId: WorkspaceActionCommandId.ValidatePairing,
                GateId: WorkspaceActionGateId.CanValidatePairing),
            new(
                "PrepareConnection",
                "Prepare Connection",
                "\uE768",
                true,
                "Mac-parity preflight action; command stays behind Core readiness gates.",
                CommandId: WorkspaceActionCommandId.PrepareConnection,
                GateId: WorkspaceActionGateId.CanPrepareConnection)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildDeviceDiscoveryScanActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "ExtendedSearch",
                "Extended Search",
                "\uE7B3",
                true,
                "Mac-parity discovery scan action; command stays in SessionViewModel.",
                CommandId: WorkspaceActionCommandId.RunExtendedDiscovery,
                GateId: WorkspaceActionGateId.CanUseDiscoveryBrowser),
            new(
                "ManualConnect",
                "Manual Connect",
                "\uE8D7",
                true,
                "Mac-parity manual target action; command validates host/port/code without connecting.",
                CommandId: WorkspaceActionCommandId.PrepareManualConnection,
                GateId: WorkspaceActionGateId.CanPrepareManualConnection),
            new(
                "StartScan",
                "Start Scan",
                "\uE768",
                true,
                "Mac-parity discovery scan action; command uses the read-only browser boundary.",
                CommandId: WorkspaceActionCommandId.StartDiscovery,
                GateId: WorkspaceActionGateId.CanUseDiscoveryBrowser),
            new(
                "StopScan",
                "Stop Scan",
                "\uE71A",
                true,
                "Mac-parity discovery scan action; command only stops browser state.",
                CommandId: WorkspaceActionCommandId.StopDiscovery,
                GateId: WorkspaceActionGateId.CanUseDiscoveryBrowser),
            new(
                "Refresh",
                "Refresh",
                "\uE72C",
                true,
                "Mac-parity discovery scan action; command refreshes the read-only browser snapshot.",
                CommandId: WorkspaceActionCommandId.RefreshDiscovery,
                GateId: WorkspaceActionGateId.CanUseDiscoveryBrowser)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildDeviceDiscoveryManualConnectFinalActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "Cancel",
                "Cancel",
                "\uE711",
                true,
                "Mac-parity manual connection cancel action; clears prepared manual-target facts without starting transport.",
                CommandId: WorkspaceActionCommandId.CancelManualConnection,
                GateId: WorkspaceActionGateId.CanUseDiscoveryBrowser),
            new(
                "Connect",
                "Connect",
                "\uE768",
                true,
                "Global session action; requires live Windows adapter.",
                CommandId: WorkspaceActionCommandId.Connect,
                GateId: WorkspaceActionGateId.CanConnect)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildCrossNetworkQrActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "GenerateQrCode",
                "Generate QR Code",
                "\uE8EF",
                true,
                "Mac-parity cross-network QR action; command does not start signaling.",
                CommandId: WorkspaceActionCommandId.GenerateQrCode,
                GateId: WorkspaceActionGateId.CanUseCrossNetworkConnection),
            new(
                "ScanQrCode",
                "Scan QR Code",
                "\uE722",
                true,
                "Mac-parity cross-network QR action; command validates the QR envelope read-only.",
                CommandId: WorkspaceActionCommandId.ScanQrCode,
                GateId: WorkspaceActionGateId.CanScanQrCode)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildCrossNetworkCodePrimaryActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "GenerateCode",
                "Generate Code",
                "\uE710",
                true,
                "Mac-parity smart-code action; command does not register a signaling room.",
                CommandId: WorkspaceActionCommandId.GenerateConnectionCode,
                GateId: WorkspaceActionGateId.CanUseCrossNetworkConnection),
            new(
                "CopyCode",
                "Copy",
                "\uE8C8",
                true,
                "Mac-parity smart-code action; command keeps clipboard writes behind explicit availability.",
                CommandId: WorkspaceActionCommandId.CopyConnectionCode,
                GateId: WorkspaceActionGateId.CanCopyConnectionCode),
            new(
                "RegenerateCode",
                "Regenerate",
                "\uE72C",
                true,
                "Mac-parity smart-code action; command reuses the read-only code generation boundary.",
                CommandId: WorkspaceActionCommandId.RegenerateConnectionCode,
                GateId: WorkspaceActionGateId.CanUseCrossNetworkConnection)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildCrossNetworkCodeConnectActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "ConnectWithCode",
                "Connect",
                "\uE768",
                true,
                "Mac-parity smart-code action; command validates code shape without starting transport.",
                CommandId: WorkspaceActionCommandId.ConnectConnectionCode,
                GateId: WorkspaceActionGateId.CanConnectConnectionCode)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildUsbManagementHeaderActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "RefreshDevices",
                "Refresh Devices",
                "\uE895",
                true,
                "Mac-parity USB Management refresh action; command stays in SessionViewModel.",
                CommandId: WorkspaceActionCommandId.RefreshUsbManagement,
                GateId: WorkspaceActionGateId.CanRefreshUsbManagement)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildFileTransferHeaderActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "RefreshPlan",
                "Refresh Plan",
                "\uE895",
                true,
                "Mac-parity File Transfer header action; command refreshes the read-only Core plan.",
                CommandId: WorkspaceActionCommandId.RefreshFileTransfer,
                GateId: WorkspaceActionGateId.CanRefreshFileTransfer)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildFileTransferActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "SelectFiles",
                "Select Files",
                "\uE8E5",
                true,
                "Mac-parity quick action; prepares an in-memory file selection intent without opening a picker or reading files.",
                CommandId: WorkspaceActionCommandId.SelectFileTransferFiles,
                GateId: WorkspaceActionGateId.CanSelectFileTransferFiles),
            new(
                "SelectFolder",
                "Select Folder",
                "\uE8B7",
                true,
                "Mac-parity quick action; prepares an in-memory folder selection intent without opening a picker or scanning directories.",
                CommandId: WorkspaceActionCommandId.SelectFileTransferFolder,
                GateId: WorkspaceActionGateId.CanSelectFileTransferFolder),
            new(
                "GenerateQr",
                "Generate QR",
                "\uE97E",
                true,
                "Mac-parity quick action; prepares an in-memory QR share plan without reading files or starting transport.",
                CommandId: WorkspaceActionCommandId.GenerateFileTransferQr,
                GateId: WorkspaceActionGateId.CanGenerateFileTransferQr)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildRemoteDesktopHeaderActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "RefreshSessions",
                "Refresh Sessions",
                "\uE895",
                true,
                "Mac-parity Remote Desktop header action; command refreshes the read-only session plan.",
                CommandId: WorkspaceActionCommandId.RefreshRemoteDesktop,
                GateId: WorkspaceActionGateId.CanRefreshRemoteDesktop)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildRemoteDesktopActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "RecommendedConnect",
                "Recommended Connect",
                "\uE710",
                true,
                "Visible mac-parity quick action; fail-closed command does not start capture or transport.",
                CommandId: WorkspaceActionCommandId.RecommendedRemoteDesktopConnect,
                GateId: WorkspaceActionGateId.CanRecommendedRemoteDesktopConnect),
            new(
                "AdvancedConnect",
                "Advanced Connect",
                "\uE8A7",
                true,
                "Visible mac-parity quick action; fail-closed command does not open endpoint selection or transport.",
                CommandId: WorkspaceActionCommandId.AdvancedRemoteDesktopConnect,
                GateId: WorkspaceActionGateId.CanAdvancedRemoteDesktopConnect),
            new(
                "PerformanceOverlay",
                "Performance Overlay",
                "\uE9D9",
                true,
                "Visible mac-parity quick action; command records in-memory overlay state without starting telemetry.",
                CommandId: WorkspaceActionCommandId.ShowRemoteDesktopPerformanceOverlay,
                GateId: WorkspaceActionGateId.CanShowRemoteDesktopPerformanceOverlay),
            new(
                "Quality",
                "Quality",
                "\uE7F4",
                true,
                "Visible mac-parity quick action; command records selected quality in memory without changing encoder or transport.",
                CommandId: WorkspaceActionCommandId.ApplyRemoteDesktopQuality,
                GateId: WorkspaceActionGateId.CanApplyRemoteDesktopQuality),
            new(
                "Settings",
                "Settings",
                "\uE713",
                true,
                "Visible mac-parity quick action; command opens in-memory settings state without mutating runtime settings.",
                CommandId: WorkspaceActionCommandId.OpenRemoteDesktopSettings,
                GateId: WorkspaceActionGateId.CanOpenRemoteDesktopSettings),
            new(
                "FullScreen",
                "Full Screen",
                "\uE740",
                true,
                "Visible mac-parity quick action; fail-closed command does not open or resize a session window.",
                CommandId: WorkspaceActionCommandId.EnterRemoteDesktopFullScreen,
                GateId: WorkspaceActionGateId.CanEnterRemoteDesktopFullScreen),
            new(
                "DisconnectSession",
                "Disconnect Session",
                "\uE711",
                true,
                "Visible mac-parity quick action; fail-closed command does not terminate a live session.",
                CommandId: WorkspaceActionCommandId.DisconnectRemoteDesktopSession,
                GateId: WorkspaceActionGateId.CanDisconnectRemoteDesktopSession)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildQuantumDiagnosticsHeaderActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "RunDiagnostics",
                "Run Diagnostics",
                "\uE9D9",
                true,
                "Mac-parity Quantum/Core diagnostics header action; command stays in SessionViewModel.",
                CommandId: WorkspaceActionCommandId.RunCoreDiagnostics,
                GateId: WorkspaceActionGateId.CanRunCoreDiagnostics)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildSystemMonitorHeaderActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "RefreshMetrics",
                "Refresh Metrics",
                "\uE895",
                true,
                "Mac-parity System Monitor refresh action; command stays in SessionViewModel.",
                CommandId: WorkspaceActionCommandId.RefreshSystemMonitor,
                GateId: WorkspaceActionGateId.CanRefreshSystemMonitor)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildSystemMonitorControlActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "Monitoring",
                "Monitoring",
                "\uF16B",
                true,
                "Visible mac-parity monitoring action; starts in-process read-only sampling without ETW/EventSource helpers.",
                CommandId: WorkspaceActionCommandId.StartSystemMonitoring,
                GateId: WorkspaceActionGateId.CanStartSystemMonitoring),
            new(
                "StopMonitoring",
                "Stop Monitoring",
                "\uE71A",
                true,
                "Visible mac-parity monitoring action; stops the in-process read-only sampler.",
                CommandId: WorkspaceActionCommandId.StopSystemMonitoring,
                GateId: WorkspaceActionGateId.CanStopSystemMonitoring),
            new(
                "EnableAdvancedMonitoring",
                "Enable Advanced Monitoring",
                "\uE72E",
                true,
                "Visible mac-parity monitoring action; enables in-memory advanced read-only diagnostics without installing helpers or requesting elevation.",
                CommandId: WorkspaceActionCommandId.EnableAdvancedSystemMonitoring,
                GateId: WorkspaceActionGateId.CanEnableAdvancedSystemMonitoring)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildSettingsHeaderActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "RefreshStatus",
                "Refresh Status",
                "\uE895",
                true,
                "Mac-parity Settings header action; command refreshes the read-only settings snapshot.",
                CommandId: WorkspaceActionCommandId.RefreshSettings,
                GateId: WorkspaceActionGateId.CanRefreshSettings)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildSettingsToolbarActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "ExportSettings",
                "Export",
                "\uE74E",
                true,
                "Visible mac-parity settings action; prepares an in-memory export preview without writing preference files.",
                CommandId: WorkspaceActionCommandId.ExportSettings,
                GateId: WorkspaceActionGateId.CanExportSettings),
            new(
                "ImportSettings",
                "Import",
                "\uE8B5",
                true,
                "Visible mac-parity settings action; fail-closed command does not import preference files.",
                CommandId: WorkspaceActionCommandId.ImportSettings,
                GateId: WorkspaceActionGateId.CanImportSettings),
            new(
                "ResetSettings",
                "Reset",
                "\uE72C",
                true,
                "Visible mac-parity settings action; fail-closed command does not reset preferences.",
                CommandId: WorkspaceActionCommandId.ResetSettings,
                GateId: WorkspaceActionGateId.CanResetSettings),
            new(
                "RequestPermission",
                "Request Permission",
                "\uE72E",
                true,
                "Visible mac-parity settings action; fail-closed command does not request permissions.",
                CommandId: WorkspaceActionCommandId.RequestSettingsPermission,
                GateId: WorkspaceActionGateId.CanRequestSettingsPermission),
            new(
                "OpenSystemPreferences",
                "Open System Preferences",
                "\uE8A7",
                true,
                "Visible mac-parity settings action; fail-closed command does not open Windows Settings.",
                CommandId: WorkspaceActionCommandId.OpenSystemPreferences,
                GateId: WorkspaceActionGateId.CanOpenSystemPreferences)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildSettingsMaintenanceActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "ApplySettings",
                "Apply Settings",
                "\uE930",
                true,
                "Visible mac-parity settings action; fail-closed command does not apply runtime preferences.",
                CommandId: WorkspaceActionCommandId.ApplySettings,
                GateId: WorkspaceActionGateId.CanApplySettings),
            new(
                "RestoreDefaults",
                "Restore Defaults",
                "\uE777",
                true,
                "Visible mac-parity settings action; fail-closed command does not restore defaults.",
                CommandId: WorkspaceActionCommandId.RestoreDefaults,
                GateId: WorkspaceActionGateId.CanRestoreDefaults),
            new(
                "ResetMonitorData",
                "Reset Monitor Data",
                "\uE9D9",
                true,
                "Visible mac-parity settings action; fail-closed command does not delete monitor retention data.",
                CommandId: WorkspaceActionCommandId.ResetMonitorData,
                GateId: WorkspaceActionGateId.CanResetMonitorData)
        };
}

public enum WorkspaceActionSurface
{
    SidebarSession,
    TopBarActions,
    SessionControls,
    DashboardQuickActions,
    DeviceDiscoveryPrimary,
    DeviceDiscoveryScan,
    DeviceDiscoveryManualConnectFinal,
    CrossNetworkQr,
    CrossNetworkCodePrimary,
    CrossNetworkCodeConnect,
    UsbManagementHeader,
    FileTransferHeader,
    FileTransfer,
    RemoteDesktopHeader,
    RemoteDesktop,
    QuantumDiagnosticsHeader,
    SystemMonitorHeader,
    SystemMonitorControls,
    SettingsHeader,
    SettingsToolbar,
    SettingsMaintenance
}

public enum WorkspaceActionCommandId
{
    None,
    Connect,
    Disconnect,
    Heartbeat,
    OpenTopBarNotifications,
    ToggleTopBarTheme,
    OpenDeviceDiscovery,
    OpenFileTransfer,
    OpenSystemMonitor,
    OpenSettings,
    ParseTxt,
    ValidatePairing,
    PrepareConnection,
    RunExtendedDiscovery,
    PrepareManualConnection,
    CancelManualConnection,
    StartDiscovery,
    StopDiscovery,
    RefreshDiscovery,
    GenerateQrCode,
    ScanQrCode,
    GenerateConnectionCode,
    CopyConnectionCode,
    RegenerateConnectionCode,
    ConnectConnectionCode,
    RefreshUsbManagement,
    RefreshFileTransfer,
    SelectFileTransferFiles,
    SelectFileTransferFolder,
    GenerateFileTransferQr,
    RefreshRemoteDesktop,
    RecommendedRemoteDesktopConnect,
    AdvancedRemoteDesktopConnect,
    ShowRemoteDesktopPerformanceOverlay,
    ApplyRemoteDesktopQuality,
    OpenRemoteDesktopSettings,
    EnterRemoteDesktopFullScreen,
    DisconnectRemoteDesktopSession,
    RunCoreDiagnostics,
    RefreshSystemMonitor,
    StartSystemMonitoring,
    StopSystemMonitoring,
    EnableAdvancedSystemMonitoring,
    RefreshSettings,
    ExportSettings,
    ImportSettings,
    ResetSettings,
    RequestSettingsPermission,
    OpenSystemPreferences,
    ApplySettings,
    RestoreDefaults,
    ResetMonitorData
}

public enum WorkspaceActionGateId
{
    None,
    CanConnect,
    CanDisconnect,
    CanSendHeartbeat,
    CanOpenTopBarNotifications,
    CanToggleTopBarTheme,
    CanUseDiscoveryBrowser,
    CanPrepareManualConnection,
    CanParseAdvertisement,
    CanValidatePairing,
    CanPrepareConnection,
    CanUseCrossNetworkConnection,
    CanScanQrCode,
    CanCopyConnectionCode,
    CanConnectConnectionCode,
    CanRefreshUsbManagement,
    CanRefreshFileTransfer,
    CanSelectFileTransferFiles,
    CanSelectFileTransferFolder,
    CanGenerateFileTransferQr,
    CanRefreshRemoteDesktop,
    CanRecommendedRemoteDesktopConnect,
    CanAdvancedRemoteDesktopConnect,
    CanShowRemoteDesktopPerformanceOverlay,
    CanApplyRemoteDesktopQuality,
    CanOpenRemoteDesktopSettings,
    CanEnterRemoteDesktopFullScreen,
    CanDisconnectRemoteDesktopSession,
    CanRunCoreDiagnostics,
    CanRefreshSystemMonitor,
    CanStartSystemMonitoring,
    CanStopSystemMonitoring,
    CanEnableAdvancedSystemMonitoring,
    CanRefreshSettings,
    CanExportSettings,
    CanImportSettings,
    CanResetSettings,
    CanRequestSettingsPermission,
    CanOpenSystemPreferences,
    CanApplySettings,
    CanRestoreDefaults,
    CanResetMonitorData
}

public enum WorkspaceActionDetailSlot
{
    None,
    TopBarNotifications,
    TopBarTheme
}

public sealed record WorkspaceActionCatalogRequest(
    WorkspaceActionSurface Surface);

public sealed record WorkspaceActionCatalogSnapshot(
    DateTimeOffset CapturedAt,
    WorkspaceActionSurface Surface,
    IReadOnlyList<WorkspaceActionItem> Actions);

public sealed record WorkspaceActionGateSnapshot(
    bool CanConnect,
    bool CanDisconnect,
    bool CanSendHeartbeat,
    bool CanOpenTopBarNotifications,
    bool CanToggleTopBarTheme,
    bool CanUseDiscoveryBrowser,
    bool CanPrepareManualConnection,
    bool CanParseAdvertisement,
    bool CanValidatePairing,
    bool CanPrepareConnection,
    bool CanUseCrossNetworkConnection,
    bool CanScanQrCode,
    bool CanCopyConnectionCode,
    bool CanConnectConnectionCode,
    bool CanRefreshUsbManagement,
    bool CanRefreshFileTransfer,
    bool CanSelectFileTransferFiles,
    bool CanSelectFileTransferFolder,
    bool CanGenerateFileTransferQr,
    bool CanRefreshRemoteDesktop,
    bool CanRecommendedRemoteDesktopConnect,
    bool CanAdvancedRemoteDesktopConnect,
    bool CanShowRemoteDesktopPerformanceOverlay,
    bool CanApplyRemoteDesktopQuality,
    bool CanOpenRemoteDesktopSettings,
    bool CanEnterRemoteDesktopFullScreen,
    bool CanDisconnectRemoteDesktopSession,
    bool CanRunCoreDiagnostics,
    bool CanRefreshSystemMonitor,
    bool CanStartSystemMonitoring,
    bool CanStopSystemMonitoring,
    bool CanEnableAdvancedSystemMonitoring,
    bool CanRefreshSettings,
    bool CanExportSettings,
    bool CanImportSettings,
    bool CanResetSettings,
    bool CanRequestSettingsPermission,
    bool CanOpenSystemPreferences,
    bool CanApplySettings,
    bool CanRestoreDefaults,
    bool CanResetMonitorData);

public sealed record WorkspaceActionDetailSnapshot(
    string TopBarNotificationsStatus,
    string TopBarThemeStatus);

public sealed record WorkspaceActionItem(
    string Key,
    string Title,
    string Glyph,
    bool IsEnabled,
    string Detail,
    WorkspaceActionCommandId CommandId = WorkspaceActionCommandId.None,
    WorkspaceActionGateId GateId = WorkspaceActionGateId.None,
    WorkspaceActionDetailSlot DetailSlot = WorkspaceActionDetailSlot.None);
