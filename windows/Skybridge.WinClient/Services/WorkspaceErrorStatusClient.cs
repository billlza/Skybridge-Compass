using System.Text.RegularExpressions;

namespace Skybridge.WinClient.Services;

public interface IWorkspaceErrorStatusClient
{
    WorkspaceErrorStatusPatch BuildErrorPatch(WorkspaceErrorScope scope, string message);
}

public sealed class WorkspaceErrorStatusClient : IWorkspaceErrorStatusClient
{
    public WorkspaceErrorStatusPatch BuildErrorPatch(WorkspaceErrorScope scope, string message)
    {
        var safeMessage = Redact(message);
        return scope switch
        {
            WorkspaceErrorScope.DeviceDiscovery => new(
                StatusMessage: safeMessage,
                ConnectionWorkspacePatch: new ConnectionWorkspaceStatusPatch(
                    DiscoveryStatus: safeMessage,
                    DiscoveryBrowserStatus: safeMessage,
                    ManualConnectionStatus: safeMessage,
                    CrossNetworkStatus: safeMessage,
                    PairingStatus: safeMessage,
                    ConnectionPreflightStatus: safeMessage)),
            WorkspaceErrorScope.UsbManagement => new(
                StatusMessage: safeMessage,
                UsbManagementStatus: safeMessage),
            WorkspaceErrorScope.CoreDiagnostics => new(
                StatusMessage: safeMessage,
                CoreDiagnosticsStatus: safeMessage),
            WorkspaceErrorScope.FileTransfer => new(
                StatusMessage: safeMessage,
                FileTransferStatus: safeMessage),
            WorkspaceErrorScope.RemoteDesktop => new(
                StatusMessage: safeMessage,
                RemoteDesktopStatus: safeMessage),
            WorkspaceErrorScope.SystemMonitor => new(
                StatusMessage: safeMessage,
                SystemMonitorStatus: safeMessage),
            WorkspaceErrorScope.Settings => new(
                StatusMessage: safeMessage,
                SettingsStatus: safeMessage),
            WorkspaceErrorScope.Weather => new(
                StatusMessage: safeMessage,
                WeatherStatus: safeMessage),
            _ => new(StatusMessage: safeMessage)
        };
    }

    public static string Redact(string? message)
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            return "Operation failed.";
        }

        var redacted = message;
        redacted = Regex.Replace(redacted, @"Bearer\s+[A-Za-z0-9._\-]+", "Bearer <redacted>", RegexOptions.IgnoreCase);
        redacted = Regex.Replace(redacted, @"(?i)(access_token|refresh_token|authToken|token|apikey)=([^&\s]+)", "$1=<redacted>");
        redacted = Regex.Replace(redacted, @"skybridge://[^\s]+", "skybridge://<redacted>");
        redacted = Regex.Replace(redacted, @"([A-Za-z]:\\[^\s]+|/Users/[^\s]+)", "<path-redacted>");
        redacted = Regex.Replace(redacted, @"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}", "<email-redacted>", RegexOptions.IgnoreCase);
        return redacted;
    }
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
