namespace Skybridge.WinClient.Services;

public interface IWorkspaceErrorStatusClient
{
    WorkspaceErrorStatusPatch BuildErrorPatch(WorkspaceErrorScope scope, string message);
}

public sealed class WorkspaceErrorStatusClient : IWorkspaceErrorStatusClient
{
    public WorkspaceErrorStatusPatch BuildErrorPatch(WorkspaceErrorScope scope, string message) =>
        scope switch
        {
            WorkspaceErrorScope.DeviceDiscovery => new(
                StatusMessage: message,
                ConnectionWorkspacePatch: new ConnectionWorkspaceStatusPatch(
                    DiscoveryStatus: message,
                    DiscoveryBrowserStatus: message,
                    ManualConnectionStatus: message,
                    CrossNetworkStatus: message,
                    PairingStatus: message,
                    ConnectionPreflightStatus: message)),
            WorkspaceErrorScope.UsbManagement => new(
                StatusMessage: message,
                UsbManagementStatus: message),
            WorkspaceErrorScope.CoreDiagnostics => new(
                StatusMessage: message,
                CoreDiagnosticsStatus: message),
            WorkspaceErrorScope.FileTransfer => new(
                StatusMessage: message,
                FileTransferStatus: message),
            WorkspaceErrorScope.RemoteDesktop => new(
                StatusMessage: message,
                RemoteDesktopStatus: message),
            WorkspaceErrorScope.SystemMonitor => new(
                StatusMessage: message,
                SystemMonitorStatus: message),
            WorkspaceErrorScope.Settings => new(
                StatusMessage: message,
                SettingsStatus: message),
            WorkspaceErrorScope.Weather => new(
                StatusMessage: message,
                WeatherStatus: message),
            _ => new(StatusMessage: message)
        };
}

public enum WorkspaceErrorScope
{
    Session,
    TopBar,
    DeviceDiscovery,
    UsbManagement,
    CoreDiagnostics,
    FileTransfer,
    RemoteDesktop,
    SystemMonitor,
    Settings,
    Weather
}

public sealed record WorkspaceErrorStatusPatch(
    string? StatusMessage = null,
    ConnectionWorkspaceStatusPatch? ConnectionWorkspacePatch = null,
    string? UsbManagementStatus = null,
    string? CoreDiagnosticsStatus = null,
    string? FileTransferStatus = null,
    string? RemoteDesktopStatus = null,
    string? SystemMonitorStatus = null,
    string? SettingsStatus = null,
    string? WeatherStatus = null);
