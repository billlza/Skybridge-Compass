using System;
using System.Collections.Generic;
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
        ReplaceCollection(facts, snapshot.Facts, CoreDiagnosticFactView.FromFact);
        _countNotifier.CoreDiagnosticFactsChanged();
    }

    public void ApplyFileTransfer(
        FileTransferWorkspaceSnapshot snapshot,
        ObservableCollection<FileTransferQueueItemView> queue,
        ObservableCollection<FileTransferHistoryItemView> history,
        ObservableCollection<FileTransferSecurityFactView> securityFacts)
    {
        ReplaceCollection(queue, snapshot.Queue, FileTransferQueueItemView.FromItem);
        ReplaceCollection(history, snapshot.History, FileTransferHistoryItemView.FromItem);
        ReplaceCollection(securityFacts, snapshot.Security, FileTransferSecurityFactView.FromFact);
        _refreshDashboardMetrics();
        _countNotifier.FileTransferHistoryChanged();
    }

    public void ApplyUsbManagement(
        UsbManagementWorkspaceSnapshot snapshot,
        ObservableCollection<UsbDeviceStatView> stats,
        ObservableCollection<UsbDeviceItemView> devices)
    {
        ReplaceCollection(stats, snapshot.Stats, UsbDeviceStatView.FromStat);
        ReplaceCollection(devices, snapshot.Devices, UsbDeviceItemView.FromItem);
        _countNotifier.UsbDevicesChanged();
    }

    public void ApplyRemoteDesktop(
        RemoteDesktopWorkspaceSnapshot snapshot,
        ObservableCollection<RemoteDesktopSessionItemView> sessions,
        ObservableCollection<RemoteDesktopControlFactView> controlFacts)
    {
        ReplaceCollection(sessions, snapshot.Sessions, RemoteDesktopSessionItemView.FromItem);
        ReplaceCollection(controlFacts, snapshot.ControlFacts, RemoteDesktopControlFactView.FromFact);
        _countNotifier.RemoteDesktopSessionsChanged();
    }

    public void ApplySystemMonitor(
        SystemMonitorWorkspaceSnapshot snapshot,
        ObservableCollection<SystemMonitorMetricView> overview,
        ObservableCollection<SystemMonitorMetricView> details,
        ObservableCollection<SystemMonitorIndicatorView> indicators)
    {
        ReplaceCollection(overview, snapshot.Overview, SystemMonitorMetricView.FromMetric);
        ReplaceCollection(details, snapshot.Details, SystemMonitorMetricView.FromMetric);
        ReplaceCollection(indicators, snapshot.Indicators, SystemMonitorIndicatorView.FromIndicator);
        _countNotifier.SystemMonitorMetricsChanged();
    }

    public void ApplySettings(
        SettingsWorkspaceSnapshot snapshot,
        ObservableCollection<SettingsTabItemView> tabs,
        ObservableCollection<SettingsActionItemView> actions,
        ObservableCollection<SettingsDetailItemView> details)
    {
        ReplaceCollection(tabs, snapshot.Tabs, SettingsTabItemView.FromItem);
        ReplaceCollection(actions, snapshot.Actions, SettingsActionItemView.FromItem);
        ReplaceCollection(details, snapshot.Details, SettingsDetailItemView.FromItem);
        _countNotifier.SettingsActionsChanged();
    }

    private static void ReplaceCollection<TSource, TItem>(
        ObservableCollection<TItem> target,
        IEnumerable<TSource> source,
        Func<TSource, TItem> map)
    {
        target.Clear();
        foreach (var item in source)
        {
            target.Add(map(item));
        }
    }
}
