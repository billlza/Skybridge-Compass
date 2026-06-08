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
        WorkspaceActionSurface.UsbManagementHeader,
        WorkspaceActionSurface.FileTransferHeader,
        WorkspaceActionSurface.RemoteDesktopHeader,
        WorkspaceActionSurface.QuantumDiagnosticsHeader,
        WorkspaceActionSurface.SystemMonitorHeader,
        WorkspaceActionSurface.SettingsHeader
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
            WorkspaceActionGateId.CanRefreshUsbManagement => gates.CanRefreshUsbManagement,
            WorkspaceActionGateId.CanRefreshFileTransfer => gates.CanRefreshFileTransfer,
            WorkspaceActionGateId.CanRefreshRemoteDesktop => gates.CanRefreshRemoteDesktop,
            WorkspaceActionGateId.CanRunCoreDiagnostics => gates.CanRunCoreDiagnostics,
            WorkspaceActionGateId.CanRefreshSystemMonitor => gates.CanRefreshSystemMonitor,
            WorkspaceActionGateId.CanRefreshSettings => gates.CanRefreshSettings,
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
                false,
                "Off",
                DetailSlot: WorkspaceActionDetailSlot.TopBarNotifications),
            new(
                "Theme",
                "Theme",
                "\uE771",
                false,
                "System",
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
                CommandId: WorkspaceActionCommandId.ParseTxt),
            new(
                "ValidatePairing",
                "Validate Pairing",
                "\uE8D7",
                true,
                "Mac-parity pairing validation action; command stays in SessionViewModel.",
                CommandId: WorkspaceActionCommandId.ValidatePairing),
            new(
                "PrepareConnection",
                "Prepare Connection",
                "\uE768",
                true,
                "Mac-parity preflight action; command stays behind Core readiness gates.",
                CommandId: WorkspaceActionCommandId.PrepareConnection)
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
                CommandId: WorkspaceActionCommandId.RunExtendedDiscovery),
            new(
                "ManualConnect",
                "Manual Connect",
                "\uE8D7",
                true,
                "Mac-parity manual target action; command validates host/port/code without connecting.",
                CommandId: WorkspaceActionCommandId.PrepareManualConnection),
            new(
                "StartScan",
                "Start Scan",
                "\uE768",
                true,
                "Mac-parity discovery scan action; command uses the read-only browser boundary.",
                CommandId: WorkspaceActionCommandId.StartDiscovery),
            new(
                "StopScan",
                "Stop Scan",
                "\uE71A",
                true,
                "Mac-parity discovery scan action; command only stops browser state.",
                CommandId: WorkspaceActionCommandId.StopDiscovery),
            new(
                "Refresh",
                "Refresh",
                "\uE72C",
                true,
                "Mac-parity discovery scan action; command refreshes the read-only browser snapshot.",
                CommandId: WorkspaceActionCommandId.RefreshDiscovery)
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildDeviceDiscoveryManualConnectFinalActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "Connect",
                "Connect",
                "\uE768",
                false,
                "Adapter pending")
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
                CommandId: WorkspaceActionCommandId.GenerateQrCode),
            new(
                "ScanQrCode",
                "Scan QR Code",
                "\uE722",
                true,
                "Mac-parity cross-network QR action; command validates the QR envelope read-only.",
                CommandId: WorkspaceActionCommandId.ScanQrCode)
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
                CommandId: WorkspaceActionCommandId.GenerateConnectionCode),
            new(
                "CopyCode",
                "Copy",
                "\uE8C8",
                true,
                "Mac-parity smart-code action; command keeps clipboard writes behind explicit availability.",
                CommandId: WorkspaceActionCommandId.CopyConnectionCode),
            new(
                "RegenerateCode",
                "Regenerate",
                "\uE72C",
                true,
                "Mac-parity smart-code action; command reuses the read-only code generation boundary.",
                CommandId: WorkspaceActionCommandId.RegenerateConnectionCode)
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
                CommandId: WorkspaceActionCommandId.ConnectConnectionCode)
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
                false,
                "Visible mac-parity quick action; file picker is pending."),
            new(
                "SelectFolder",
                "Select Folder",
                "\uE8B7",
                false,
                "Visible mac-parity quick action; folder picker is pending."),
            new(
                "GenerateQr",
                "Generate QR",
                "\uE97E",
                false,
                "Visible mac-parity quick action; live share QR generation is pending.")
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
                false,
                "Visible mac-parity quick action; live recommended session launch is pending."),
            new(
                "AdvancedConnect",
                "Advanced Connect",
                "\uE8A7",
                false,
                "Visible mac-parity quick action; advanced endpoint selection is pending."),
            new(
                "PerformanceOverlay",
                "Performance Overlay",
                "\uE9D9",
                false,
                "Visible mac-parity quick action; live overlay telemetry is pending."),
            new(
                "Quality",
                "Quality",
                "\uE7F4",
                false,
                "Visible mac-parity quick action; live encoder quality application is pending."),
            new(
                "Settings",
                "Settings",
                "\uE713",
                false,
                "Visible mac-parity quick action; Remote Desktop runtime settings remain read-only."),
            new(
                "FullScreen",
                "Full Screen",
                "\uE740",
                false,
                "Visible mac-parity quick action; live session windowing is pending."),
            new(
                "DisconnectSession",
                "Disconnect Session",
                "\uE711",
                false,
                "Visible mac-parity quick action; no live session termination is wired.")
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
                false,
                "Visible mac-parity monitoring action; live ETW/EventSource sampling is pending."),
            new(
                "StopMonitoring",
                "Stop Monitoring",
                "\uE71A",
                false,
                "Visible mac-parity monitoring action; no background sampler is running."),
            new(
                "EnableAdvancedMonitoring",
                "Enable Advanced Monitoring",
                "\uE72E",
                false,
                "Visible mac-parity monitoring action; helper installation and elevation remain pending.")
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
                false,
                "Visible mac-parity settings action; exporting user preferences is pending."),
            new(
                "ImportSettings",
                "Import",
                "\uE8B5",
                false,
                "Visible mac-parity settings action; importing preference files is pending validation."),
            new(
                "ResetSettings",
                "Reset",
                "\uE72C",
                false,
                "Visible mac-parity settings action; destructive preference reset requires confirmation."),
            new(
                "RequestPermission",
                "Request Permission",
                "\uE72E",
                false,
                "Visible mac-parity settings action; permission prompts remain explicit high-risk writes."),
            new(
                "OpenSystemPreferences",
                "Open System Preferences",
                "\uE8A7",
                false,
                "Visible mac-parity settings action; Windows Settings deep links require explicit wiring.")
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildSettingsMaintenanceActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "ApplySettings",
                "Apply Settings",
                "\uE930",
                false,
                "Visible mac-parity settings action; runtime preference application is pending."),
            new(
                "RestoreDefaults",
                "Restore Defaults",
                "\uE777",
                false,
                "Visible mac-parity settings action; restoring defaults is a destructive preference write."),
            new(
                "ResetMonitorData",
                "Reset Monitor Data",
                "\uE9D9",
                false,
                "Visible mac-parity settings action; monitor retention deletion requires confirmation.")
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
    OpenDeviceDiscovery,
    OpenFileTransfer,
    OpenSystemMonitor,
    OpenSettings,
    ParseTxt,
    ValidatePairing,
    PrepareConnection,
    RunExtendedDiscovery,
    PrepareManualConnection,
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
    RefreshRemoteDesktop,
    RunCoreDiagnostics,
    RefreshSystemMonitor,
    RefreshSettings
}

public enum WorkspaceActionGateId
{
    None,
    CanConnect,
    CanDisconnect,
    CanSendHeartbeat,
    CanRefreshUsbManagement,
    CanRefreshFileTransfer,
    CanRefreshRemoteDesktop,
    CanRunCoreDiagnostics,
    CanRefreshSystemMonitor,
    CanRefreshSettings
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
    bool CanRefreshUsbManagement,
    bool CanRefreshFileTransfer,
    bool CanRefreshRemoteDesktop,
    bool CanRunCoreDiagnostics,
    bool CanRefreshSystemMonitor,
    bool CanRefreshSettings);

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
