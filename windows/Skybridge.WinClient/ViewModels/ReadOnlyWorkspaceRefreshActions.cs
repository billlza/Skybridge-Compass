using System;
using System.Threading.Tasks;

namespace Skybridge.WinClient.ViewModels;

internal sealed class ReadOnlyWorkspaceRefreshActions
{
    private readonly ReadOnlyWorkspaceRefreshCoordinator _refreshCoordinator;
    private readonly ReadOnlyWorkspaceSnapshotHandlers _snapshotHandlers;
    private readonly Func<string> _getSelectedBitrate;
    private readonly Func<string> _getSelectedFramerate;
    private readonly Action<string> _setStatusMessage;
    private readonly Action<string> _setCoreDiagnosticsStatus;
    private readonly Action<string> _setFileTransferStatus;
    private readonly Action<string> _setUsbManagementStatus;
    private readonly Action<string> _setRemoteDesktopStatus;
    private readonly Action<string> _setSystemMonitorStatus;
    private readonly Action<string> _setSettingsStatus;

    public ReadOnlyWorkspaceRefreshActions(
        ReadOnlyWorkspaceRefreshCoordinator refreshCoordinator,
        ReadOnlyWorkspaceSnapshotHandlers snapshotHandlers,
        Func<string> getSelectedBitrate,
        Func<string> getSelectedFramerate,
        Action<string> setStatusMessage,
        Action<string> setCoreDiagnosticsStatus,
        Action<string> setFileTransferStatus,
        Action<string> setUsbManagementStatus,
        Action<string> setRemoteDesktopStatus,
        Action<string> setSystemMonitorStatus,
        Action<string> setSettingsStatus)
    {
        _refreshCoordinator = refreshCoordinator;
        _snapshotHandlers = snapshotHandlers;
        _getSelectedBitrate = getSelectedBitrate;
        _getSelectedFramerate = getSelectedFramerate;
        _setStatusMessage = setStatusMessage;
        _setCoreDiagnosticsStatus = setCoreDiagnosticsStatus;
        _setFileTransferStatus = setFileTransferStatus;
        _setUsbManagementStatus = setUsbManagementStatus;
        _setRemoteDesktopStatus = setRemoteDesktopStatus;
        _setSystemMonitorStatus = setSystemMonitorStatus;
        _setSettingsStatus = setSettingsStatus;
    }

    public Task RunCoreDiagnosticsAsync() =>
        _refreshCoordinator.RunCoreDiagnosticsAsync(
            _snapshotHandlers.ApplyCoreDiagnostics,
            _setCoreDiagnosticsStatus,
            _setStatusMessage);

    public Task RefreshFileTransferAsync() =>
        _refreshCoordinator.RefreshFileTransferAsync(
            _snapshotHandlers.ApplyFileTransfer,
            _setFileTransferStatus,
            _setStatusMessage);

    public Task RefreshUsbManagementAsync() =>
        _refreshCoordinator.RefreshUsbManagementAsync(
            _snapshotHandlers.ApplyUsbManagement,
            _setUsbManagementStatus,
            _setStatusMessage);

    public Task RefreshRemoteDesktopAsync() =>
        _refreshCoordinator.RefreshRemoteDesktopAsync(
            _getSelectedBitrate(),
            _getSelectedFramerate(),
            _snapshotHandlers.ApplyRemoteDesktop,
            _setRemoteDesktopStatus,
            _setStatusMessage);

    public Task RefreshSystemMonitorAsync() =>
        _refreshCoordinator.RefreshSystemMonitorAsync(
            _snapshotHandlers.ApplySystemMonitor,
            _setSystemMonitorStatus,
            _setStatusMessage);

    public Task RefreshSettingsAsync() =>
        _refreshCoordinator.RefreshSettingsAsync(
            _snapshotHandlers.ApplySettings,
            _setSettingsStatus,
            _setStatusMessage);
}
