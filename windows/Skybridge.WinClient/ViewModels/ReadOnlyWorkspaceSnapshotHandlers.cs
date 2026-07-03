using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class ReadOnlyWorkspaceSnapshotHandlers
{
    private readonly WorkspaceSnapshotApplier _snapshotApplier;
    private readonly WorkspaceObservableCollections _collections;

    public ReadOnlyWorkspaceSnapshotHandlers(
        WorkspaceSnapshotApplier snapshotApplier,
        WorkspaceObservableCollections collections)
    {
        _snapshotApplier = snapshotApplier;
        _collections = collections;
    }

    public void ApplyCoreDiagnostics(CoreDiagnosticsSnapshot snapshot) =>
        _snapshotApplier.ApplyCoreDiagnostics(snapshot, _collections.CoreDiagnosticFacts);

    public void ApplyFileTransfer(FileTransferWorkspaceSnapshot snapshot) =>
        _snapshotApplier.ApplyFileTransfer(
            snapshot,
            _collections.FileTransferQueue,
            _collections.FileTransferHistory,
            _collections.FileTransferSecurityFacts);

    public void ApplyUsbManagement(UsbManagementWorkspaceSnapshot snapshot) =>
        _snapshotApplier.ApplyUsbManagement(
            snapshot,
            _collections.UsbDeviceStats,
            _collections.UsbDevices);

    public void ApplyRemoteDesktop(RemoteDesktopWorkspaceSnapshot snapshot) =>
        _snapshotApplier.ApplyRemoteDesktop(
            snapshot,
            _collections.RemoteDesktopSessions,
            _collections.RemoteDesktopControlFacts);

    public void ApplySystemMonitor(SystemMonitorWorkspaceSnapshot snapshot) =>
        _snapshotApplier.ApplySystemMonitor(
            snapshot,
            _collections.SystemMonitorOverview,
            _collections.SystemMonitorDetails,
            _collections.SystemMonitorIndicators,
            _collections.SystemMonitorInsights);

    public void ApplySettings(SettingsWorkspaceSnapshot snapshot) =>
        _snapshotApplier.ApplySettings(
            snapshot,
            _collections.SettingsTabs,
            _collections.SettingsActions,
            _collections.SettingsDetails);
}
