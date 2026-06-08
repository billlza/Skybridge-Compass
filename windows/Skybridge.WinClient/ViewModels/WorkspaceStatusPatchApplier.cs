using System;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceStatusPatchApplier
{
    private readonly Action<string> _setStatusMessage;
    private readonly Action<string> _setDiscoveryStatus;
    private readonly Action<string> _setDiscoveryBrowserStatus;
    private readonly Action<string> _setManualConnectionStatus;
    private readonly Action<string> _setCrossNetworkStatus;
    private readonly Action<string> _setPairingStatus;
    private readonly Action<string> _setConnectionPreflightStatus;
    private readonly Action<bool> _setIsDiscoveryScanning;
    private readonly Action<string> _setUsbManagementStatus;
    private readonly Action<string> _setCoreDiagnosticsStatus;
    private readonly Action<string> _setFileTransferStatus;
    private readonly Action<string> _setRemoteDesktopStatus;
    private readonly Action<string> _setSystemMonitorStatus;
    private readonly Action<string> _setSettingsStatus;

    public WorkspaceStatusPatchApplier(
        Action<string> setStatusMessage,
        Action<string> setDiscoveryStatus,
        Action<string> setDiscoveryBrowserStatus,
        Action<string> setManualConnectionStatus,
        Action<string> setCrossNetworkStatus,
        Action<string> setPairingStatus,
        Action<string> setConnectionPreflightStatus,
        Action<bool> setIsDiscoveryScanning,
        Action<string> setUsbManagementStatus,
        Action<string> setCoreDiagnosticsStatus,
        Action<string> setFileTransferStatus,
        Action<string> setRemoteDesktopStatus,
        Action<string> setSystemMonitorStatus,
        Action<string> setSettingsStatus)
    {
        _setStatusMessage = setStatusMessage;
        _setDiscoveryStatus = setDiscoveryStatus;
        _setDiscoveryBrowserStatus = setDiscoveryBrowserStatus;
        _setManualConnectionStatus = setManualConnectionStatus;
        _setCrossNetworkStatus = setCrossNetworkStatus;
        _setPairingStatus = setPairingStatus;
        _setConnectionPreflightStatus = setConnectionPreflightStatus;
        _setIsDiscoveryScanning = setIsDiscoveryScanning;
        _setUsbManagementStatus = setUsbManagementStatus;
        _setCoreDiagnosticsStatus = setCoreDiagnosticsStatus;
        _setFileTransferStatus = setFileTransferStatus;
        _setRemoteDesktopStatus = setRemoteDesktopStatus;
        _setSystemMonitorStatus = setSystemMonitorStatus;
        _setSettingsStatus = setSettingsStatus;
    }

    public void Apply(ConnectionWorkspaceStatusPatch patch)
    {
        ApplyIfPresent(patch.DiscoveryStatus, _setDiscoveryStatus);
        ApplyIfPresent(patch.DiscoveryBrowserStatus, _setDiscoveryBrowserStatus);
        ApplyIfPresent(patch.ManualConnectionStatus, _setManualConnectionStatus);
        ApplyIfPresent(patch.CrossNetworkStatus, _setCrossNetworkStatus);
        ApplyIfPresent(patch.PairingStatus, _setPairingStatus);
        ApplyIfPresent(patch.ConnectionPreflightStatus, _setConnectionPreflightStatus);
        ApplyIfPresent(patch.StatusMessage, _setStatusMessage);

        if (patch.IsDiscoveryScanning.HasValue)
        {
            _setIsDiscoveryScanning(patch.IsDiscoveryScanning.Value);
        }
    }

    public void Apply(WorkspaceErrorStatusPatch patch)
    {
        if (patch.ConnectionWorkspacePatch is not null)
        {
            Apply(patch.ConnectionWorkspacePatch);
        }

        ApplyIfPresent(patch.StatusMessage, _setStatusMessage);
        ApplyIfPresent(patch.UsbManagementStatus, _setUsbManagementStatus);
        ApplyIfPresent(patch.CoreDiagnosticsStatus, _setCoreDiagnosticsStatus);
        ApplyIfPresent(patch.FileTransferStatus, _setFileTransferStatus);
        ApplyIfPresent(patch.RemoteDesktopStatus, _setRemoteDesktopStatus);
        ApplyIfPresent(patch.SystemMonitorStatus, _setSystemMonitorStatus);
        ApplyIfPresent(patch.SettingsStatus, _setSettingsStatus);
    }

    private static void ApplyIfPresent(string? value, Action<string> setter)
    {
        if (value is not null)
        {
            setter(value);
        }
    }
}
