using System;
using System.Threading.Tasks;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class ReadOnlyWorkspaceRefreshCoordinator
{
    private readonly WorkspaceBusyCoordinator _busyCoordinator;
    private readonly ICoreDiagnosticsClient _coreDiagnosticsClient;
    private readonly IFileTransferWorkspaceClient _fileTransferClient;
    private readonly IUsbManagementWorkspaceClient _usbManagementClient;
    private readonly IRemoteDesktopWorkspaceClient _remoteDesktopClient;
    private readonly ISystemMonitorWorkspaceClient _systemMonitorClient;
    private readonly ISettingsWorkspaceClient _settingsClient;

    public ReadOnlyWorkspaceRefreshCoordinator(
        WorkspaceBusyCoordinator busyCoordinator,
        ICoreDiagnosticsClient coreDiagnosticsClient,
        IFileTransferWorkspaceClient fileTransferClient,
        IUsbManagementWorkspaceClient usbManagementClient,
        IRemoteDesktopWorkspaceClient remoteDesktopClient,
        ISystemMonitorWorkspaceClient systemMonitorClient,
        ISettingsWorkspaceClient settingsClient)
    {
        _busyCoordinator = busyCoordinator ?? throw new ArgumentNullException(nameof(busyCoordinator));
        _coreDiagnosticsClient = coreDiagnosticsClient ?? throw new ArgumentNullException(nameof(coreDiagnosticsClient));
        _fileTransferClient = fileTransferClient ?? throw new ArgumentNullException(nameof(fileTransferClient));
        _usbManagementClient = usbManagementClient ?? throw new ArgumentNullException(nameof(usbManagementClient));
        _remoteDesktopClient = remoteDesktopClient ?? throw new ArgumentNullException(nameof(remoteDesktopClient));
        _systemMonitorClient = systemMonitorClient ?? throw new ArgumentNullException(nameof(systemMonitorClient));
        _settingsClient = settingsClient ?? throw new ArgumentNullException(nameof(settingsClient));
    }

    public Task RunCoreDiagnosticsAsync(
        Action<CoreDiagnosticsSnapshot> applySnapshot,
        Action<string> setWorkspaceStatus,
        Action<string> setStatusMessage) =>
        _busyCoordinator.RefreshReadOnlyWorkspaceAsync<CoreDiagnosticsSnapshot>(
            WorkspaceErrorScope.CoreDiagnostics,
            _coreDiagnosticsClient.BuildPendingStatus,
            _coreDiagnosticsClient.BuildInteropSnapshotAsync,
            applySnapshot,
            _coreDiagnosticsClient.BuildCompletedStatus,
            _coreDiagnosticsClient.BuildCompletedStatusMessage,
            setWorkspaceStatus,
            setStatusMessage);

    public Task RefreshFileTransferAsync(
        Action<FileTransferWorkspaceSnapshot> applySnapshot,
        Action<string> setWorkspaceStatus,
        Action<string> setStatusMessage) =>
        _busyCoordinator.RefreshReadOnlyWorkspaceAsync<FileTransferWorkspaceSnapshot>(
            WorkspaceErrorScope.FileTransfer,
            _fileTransferClient.BuildPendingStatus,
            _fileTransferClient.BuildReadOnlySnapshotAsync,
            applySnapshot,
            _fileTransferClient.BuildCompletedStatus,
            _fileTransferClient.BuildCompletedStatusMessage,
            setWorkspaceStatus,
            setStatusMessage);

    public Task RefreshUsbManagementAsync(
        Action<UsbManagementWorkspaceSnapshot> applySnapshot,
        Action<string> setWorkspaceStatus,
        Action<string> setStatusMessage) =>
        _busyCoordinator.RefreshReadOnlyWorkspaceAsync<UsbManagementWorkspaceSnapshot>(
            WorkspaceErrorScope.UsbManagement,
            _usbManagementClient.BuildPendingStatus,
            _usbManagementClient.BuildReadOnlySnapshotAsync,
            applySnapshot,
            _usbManagementClient.BuildCompletedStatus,
            _usbManagementClient.BuildCompletedStatusMessage,
            setWorkspaceStatus,
            setStatusMessage);

    public Task RefreshRemoteDesktopAsync(
        string selectedBitrate,
        string selectedFramerate,
        Action<RemoteDesktopWorkspaceSnapshot> applySnapshot,
        Action<string> setWorkspaceStatus,
        Action<string> setStatusMessage) =>
        _busyCoordinator.RefreshReadOnlyWorkspaceAsync<RemoteDesktopWorkspaceSnapshot>(
            WorkspaceErrorScope.RemoteDesktop,
            _remoteDesktopClient.BuildPendingStatus,
            () => _remoteDesktopClient.BuildReadOnlySnapshotAsync(selectedBitrate, selectedFramerate),
            applySnapshot,
            _remoteDesktopClient.BuildCompletedStatus,
            _remoteDesktopClient.BuildCompletedStatusMessage,
            setWorkspaceStatus,
            setStatusMessage);

    public Task RefreshSystemMonitorAsync(
        Action<SystemMonitorWorkspaceSnapshot> applySnapshot,
        Action<string> setWorkspaceStatus,
        Action<string> setStatusMessage) =>
        _busyCoordinator.RefreshReadOnlyWorkspaceAsync<SystemMonitorWorkspaceSnapshot>(
            WorkspaceErrorScope.SystemMonitor,
            _systemMonitorClient.BuildPendingStatus,
            _systemMonitorClient.BuildReadOnlySnapshotAsync,
            applySnapshot,
            _systemMonitorClient.BuildCompletedStatus,
            _systemMonitorClient.BuildCompletedStatusMessage,
            setWorkspaceStatus,
            setStatusMessage);

    public Task RefreshSettingsAsync(
        Action<SettingsWorkspaceSnapshot> applySnapshot,
        Action<string> setWorkspaceStatus,
        Action<string> setStatusMessage) =>
        _busyCoordinator.RefreshReadOnlyWorkspaceAsync<SettingsWorkspaceSnapshot>(
            WorkspaceErrorScope.Settings,
            _settingsClient.BuildPendingStatus,
            _settingsClient.BuildReadOnlySnapshotAsync,
            applySnapshot,
            _settingsClient.BuildCompletedStatus,
            _settingsClient.BuildCompletedStatusMessage,
            setWorkspaceStatus,
            setStatusMessage);
}
