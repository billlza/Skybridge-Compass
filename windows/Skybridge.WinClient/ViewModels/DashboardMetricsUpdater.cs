using System;
using System.Collections.ObjectModel;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class DashboardMetricsUpdater
{
    private readonly IDashboardMetricsClient _dashboardMetricsClient;
    private readonly ObservableCollection<DashboardMetricView> _dashboardMetrics;
    private readonly WorkspaceCountNotifier _countNotifier;
    private readonly Action<int> _setOnlineDeviceCount;
    private readonly Action<int> _setActiveSessionCount;
    private readonly Action<int> _setTransferTaskCount;
    private readonly Action<string> _setPerformanceStatus;

    public DashboardMetricsUpdater(
        IDashboardMetricsClient dashboardMetricsClient,
        ObservableCollection<DashboardMetricView> dashboardMetrics,
        WorkspaceCountNotifier countNotifier,
        Action<int> setOnlineDeviceCount,
        Action<int> setActiveSessionCount,
        Action<int> setTransferTaskCount,
        Action<string> setPerformanceStatus)
    {
        _dashboardMetricsClient = dashboardMetricsClient;
        _dashboardMetrics = dashboardMetrics;
        _countNotifier = countNotifier;
        _setOnlineDeviceCount = setOnlineDeviceCount;
        _setActiveSessionCount = setActiveSessionCount;
        _setTransferTaskCount = setTransferTaskCount;
        _setPerformanceStatus = setPerformanceStatus;
    }

    public void Refresh(DashboardMetricsRequest request)
    {
        var snapshot = _dashboardMetricsClient.BuildReadOnlySnapshot(request);

        _setOnlineDeviceCount(snapshot.OnlineDeviceCount);
        _setActiveSessionCount(snapshot.ActiveSessionCount);
        _setTransferTaskCount(snapshot.TransferTaskCount);
        _setPerformanceStatus(snapshot.PerformanceStatus);
        WorkspaceCollectionProjector.Replace(_dashboardMetrics, snapshot.Metrics, DashboardMetricView.FromMetric);

        _countNotifier.DashboardMetricsChanged();
    }
}
