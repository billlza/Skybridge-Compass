using System;
using System.Collections.ObjectModel;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceSnapshotApplier
{
    private readonly WorkspaceCountNotifier _countNotifier;
    private readonly Action _refreshDashboardMetrics;

    public WorkspaceSnapshotApplier(
        WorkspaceCountNotifier countNotifier,
        Action refreshDashboardMetrics)
    {
        _countNotifier = countNotifier;
        _refreshDashboardMetrics = refreshDashboardMetrics;
    }

    public void ApplyCoreDiagnostics(
        CoreDiagnosticsSnapshot snapshot,
        ObservableCollection<CoreDiagnosticFactView> facts)
    {
        WorkspaceCollectionProjector.Replace(facts, snapshot.Facts, CoreDiagnosticFactView.FromFact);
        _countNotifier.CoreDiagnosticFactsChanged();
    }

    public void ApplyFileTransfer(
        FileTransferWorkspaceSnapshot snapshot,
        ObservableCollection<FileTransferQueueItemView> queue,
        ObservableCollection<FileTransferHistoryItemView> history,
        ObservableCollection<FileTransferSecurityFactView> securityFacts)
    {
        WorkspaceCollectionProjector.Replace(queue, snapshot.Queue, FileTransferQueueItemView.FromItem);
        WorkspaceCollectionProjector.Replace(history, snapshot.History, FileTransferHistoryItemView.FromItem);
        WorkspaceCollectionProjector.Replace(securityFacts, snapshot.Security, FileTransferSecurityFactView.FromFact);
        _refreshDashboardMetrics();
        _countNotifier.FileTransferHistoryChanged();
    }

    public void ApplyUsbManagement(
        UsbManagementWorkspaceSnapshot snapshot,
        ObservableCollection<UsbDeviceStatView> stats,
        ObservableCollection<UsbDeviceItemView> devices)
    {
        WorkspaceCollectionProjector.Replace(stats, snapshot.Stats, UsbDeviceStatView.FromStat);
        WorkspaceCollectionProjector.Replace(devices, snapshot.Devices, UsbDeviceItemView.FromItem);
        _countNotifier.UsbDevicesChanged();
    }

    public void ApplyRemoteDesktop(
        RemoteDesktopWorkspaceSnapshot snapshot,
        ObservableCollection<RemoteDesktopSessionItemView> sessions,
        ObservableCollection<RemoteDesktopControlFactView> controlFacts)
    {
        WorkspaceCollectionProjector.Replace(sessions, snapshot.Sessions, RemoteDesktopSessionItemView.FromItem);
        WorkspaceCollectionProjector.Replace(controlFacts, snapshot.ControlFacts, RemoteDesktopControlFactView.FromFact);
        _countNotifier.RemoteDesktopSessionsChanged();
    }

    public void ApplySystemMonitor(
        SystemMonitorWorkspaceSnapshot snapshot,
        ObservableCollection<SystemMonitorMetricView> overview,
        ObservableCollection<SystemMonitorMetricView> details,
        ObservableCollection<SystemMonitorIndicatorView> indicators)
    {
        WorkspaceCollectionProjector.Replace(overview, snapshot.Overview, SystemMonitorMetricView.FromMetric);
        WorkspaceCollectionProjector.Replace(details, snapshot.Details, SystemMonitorMetricView.FromMetric);
        WorkspaceCollectionProjector.Replace(indicators, snapshot.Indicators, SystemMonitorIndicatorView.FromIndicator);
        _countNotifier.SystemMonitorMetricsChanged();
    }

    public void ApplySettings(
        SettingsWorkspaceSnapshot snapshot,
        ObservableCollection<SettingsTabItemView> tabs,
        ObservableCollection<SettingsActionItemView> actions,
        ObservableCollection<SettingsDetailItemView> details)
    {
        WorkspaceCollectionProjector.Replace(tabs, snapshot.Tabs, SettingsTabItemView.FromItem);
        WorkspaceCollectionProjector.Replace(actions, snapshot.Actions, SettingsActionItemView.FromItem);
        WorkspaceCollectionProjector.Replace(details, snapshot.Details, SettingsDetailItemView.FromItem);
        _countNotifier.SettingsActionsChanged();
    }
}
