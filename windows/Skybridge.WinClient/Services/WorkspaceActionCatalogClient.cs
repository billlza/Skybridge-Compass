using System;
using System.Collections.Generic;

namespace Skybridge.WinClient.Services;

public interface IWorkspaceActionCatalogClient
{
    WorkspaceActionCatalogSnapshot BuildReadOnlySnapshot(WorkspaceActionCatalogRequest request);
}

public sealed class WorkspaceActionCatalogClient : IWorkspaceActionCatalogClient
{
    public WorkspaceActionCatalogSnapshot BuildReadOnlySnapshot(WorkspaceActionCatalogRequest request) =>
        new(
            DateTimeOffset.UtcNow,
            request.Surface,
            request.Surface switch
            {
                WorkspaceActionSurface.SidebarSession => BuildSidebarSessionActions(),
                WorkspaceActionSurface.TopBarActions => BuildTopBarActions(),
                WorkspaceActionSurface.SessionControls => BuildSessionControlActions(),
                WorkspaceActionSurface.DeviceDiscoveryPrimary => BuildDeviceDiscoveryPrimaryActions(),
                WorkspaceActionSurface.DeviceDiscoveryScan => BuildDeviceDiscoveryScanActions(),
                WorkspaceActionSurface.CrossNetworkQr => BuildCrossNetworkQrActions(),
                WorkspaceActionSurface.CrossNetworkCodePrimary => BuildCrossNetworkCodePrimaryActions(),
                WorkspaceActionSurface.CrossNetworkCodeConnect => BuildCrossNetworkCodeConnectActions(),
                WorkspaceActionSurface.FileTransfer => BuildFileTransferActions(),
                WorkspaceActionSurface.RemoteDesktop => BuildRemoteDesktopActions(),
                WorkspaceActionSurface.SystemMonitorHeader => BuildSystemMonitorHeaderActions(),
                WorkspaceActionSurface.SystemMonitorControls => BuildSystemMonitorControlActions(),
                WorkspaceActionSurface.SettingsToolbar => BuildSettingsToolbarActions(),
                WorkspaceActionSurface.SettingsMaintenance => BuildSettingsMaintenanceActions(),
                _ => new List<WorkspaceActionItem>()
            });

    private static IReadOnlyList<WorkspaceActionItem> BuildSidebarSessionActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "Connect",
                "Connect",
                "\uE768",
                true,
                "Global session action; command stays in SessionViewModel."),
            new(
                "Disconnect",
                "Disconnect",
                "\uE711",
                true,
                "Global session action; command stays in SessionViewModel.")
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildTopBarActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "Notifications",
                "Notifications",
                "\uEA8F",
                false,
                "Off"),
            new(
                "Theme",
                "Theme",
                "\uE771",
                false,
                "System"),
            new(
                "Heartbeat",
                "Heartbeat",
                "\uE95B",
                true,
                "")
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildSessionControlActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "Connect",
                "Connect",
                "\uE768",
                true,
                "Global session action; command stays in SessionViewModel."),
            new(
                "Heartbeat",
                "Heartbeat",
                "\uE95B",
                true,
                "Global session action; command stays in SessionViewModel."),
            new(
                "Disconnect",
                "Disconnect",
                "\uE711",
                true,
                "Global session action; command stays in SessionViewModel.")
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildDeviceDiscoveryPrimaryActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "ParseTxt",
                "Parse TXT",
                "\uE8B9",
                true,
                "Mac-parity discovery parser action; command stays in SessionViewModel."),
            new(
                "ValidatePairing",
                "Validate Pairing",
                "\uE8D7",
                true,
                "Mac-parity pairing validation action; command stays in SessionViewModel."),
            new(
                "PrepareConnection",
                "Prepare Connection",
                "\uE768",
                true,
                "Mac-parity preflight action; command stays behind Core readiness gates.")
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildDeviceDiscoveryScanActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "ExtendedSearch",
                "Extended Search",
                "\uE7B3",
                true,
                "Mac-parity discovery scan action; command stays in SessionViewModel."),
            new(
                "ManualConnect",
                "Manual Connect",
                "\uE8D7",
                true,
                "Mac-parity manual target action; command validates host/port/code without connecting."),
            new(
                "StartScan",
                "Start Scan",
                "\uE768",
                true,
                "Mac-parity discovery scan action; command uses the read-only browser boundary."),
            new(
                "StopScan",
                "Stop Scan",
                "\uE71A",
                true,
                "Mac-parity discovery scan action; command only stops browser state."),
            new(
                "Refresh",
                "Refresh",
                "\uE72C",
                true,
                "Mac-parity discovery scan action; command refreshes the read-only browser snapshot.")
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildCrossNetworkQrActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "GenerateQrCode",
                "Generate QR Code",
                "\uE8EF",
                true,
                "Mac-parity cross-network QR action; command does not start signaling."),
            new(
                "ScanQrCode",
                "Scan QR Code",
                "\uE722",
                true,
                "Mac-parity cross-network QR action; command validates the QR envelope read-only.")
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildCrossNetworkCodePrimaryActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "GenerateCode",
                "Generate Code",
                "\uE710",
                true,
                "Mac-parity smart-code action; command does not register a signaling room."),
            new(
                "CopyCode",
                "Copy",
                "\uE8C8",
                true,
                "Mac-parity smart-code action; command keeps clipboard writes behind explicit availability."),
            new(
                "RegenerateCode",
                "Regenerate",
                "\uE72C",
                true,
                "Mac-parity smart-code action; command reuses the read-only code generation boundary.")
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildCrossNetworkCodeConnectActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "ConnectWithCode",
                "Connect",
                "\uE768",
                true,
                "Mac-parity smart-code action; command validates code shape without starting transport.")
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

    private static IReadOnlyList<WorkspaceActionItem> BuildSystemMonitorHeaderActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "RefreshMetrics",
                "Refresh Metrics",
                "\uE895",
                true,
                "Mac-parity System Monitor refresh action; command stays in SessionViewModel.")
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
    DeviceDiscoveryPrimary,
    DeviceDiscoveryScan,
    CrossNetworkQr,
    CrossNetworkCodePrimary,
    CrossNetworkCodeConnect,
    FileTransfer,
    RemoteDesktop,
    SystemMonitorHeader,
    SystemMonitorControls,
    SettingsToolbar,
    SettingsMaintenance
}

public sealed record WorkspaceActionCatalogRequest(
    WorkspaceActionSurface Surface);

public sealed record WorkspaceActionCatalogSnapshot(
    DateTimeOffset CapturedAt,
    WorkspaceActionSurface Surface,
    IReadOnlyList<WorkspaceActionItem> Actions);

public sealed record WorkspaceActionItem(
    string Key,
    string Title,
    string Glyph,
    bool IsEnabled,
    string Detail);
