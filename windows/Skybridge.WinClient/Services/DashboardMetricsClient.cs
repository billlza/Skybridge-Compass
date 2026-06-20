using System;
using System.Collections.Generic;

namespace Skybridge.WinClient.Services;

public interface IDashboardMetricsClient
{
    DashboardMetricsSnapshot BuildReadOnlySnapshot(DashboardMetricsRequest request);
}

public sealed class DashboardMetricsClient : IDashboardMetricsClient
{
    public DashboardMetricsSnapshot BuildReadOnlySnapshot(DashboardMetricsRequest request)
    {
        var onlineDeviceCount = request.ConnectionState == EngineConnectionState.Connected ? 1 : 0;
        var activeSessionCount = request.ConnectionState == EngineConnectionState.Connected ? 1 : 0;

        // PerformanceStatus stays the honest busy/nominal scalar that
        // DashboardMetricsUpdater projects onto the SessionViewModel.PerformanceStatus
        // property; the dashboard StatCard surfaces it as a human-facing health
        // label (System Status: Excellent / Good) to element-match the Mac
        // DashboardContentView "系统状态 / System Status" card, which never shows a
        // caption under the value.
        var performanceStatus = request.IsBusy ? "Busy" : "Nominal";
        var systemStatusValue = request.IsBusy ? "Good" : "Excellent";

        // Mac StatCard has NO caption/description under the value (see StatCard.swift):
        // icon → small secondary label → big bold value. The Windows
        // WorkspaceMetricCardTemplate drops the Detail TextBlock to match, so the
        // empty Detail here is intentional and never rendered.
        return new DashboardMetricsSnapshot(
            DateTimeOffset.UtcNow,
            onlineDeviceCount,
            activeSessionCount,
            request.TransferTaskCount,
            performanceStatus,
            new List<DashboardMetric>
            {
                new("Online Devices", onlineDeviceCount.ToString(), string.Empty),
                new("Active Sessions", activeSessionCount.ToString(), string.Empty),
                new("Transfer Tasks", request.TransferTaskCount.ToString(), string.Empty),
                new("System Status", systemStatusValue, string.Empty)
            });
    }
}

public sealed record DashboardMetricsRequest(
    EngineConnectionState ConnectionState,
    int TransferTaskCount,
    bool IsBusy);

public sealed record DashboardMetricsSnapshot(
    DateTimeOffset CapturedAt,
    int OnlineDeviceCount,
    int ActiveSessionCount,
    int TransferTaskCount,
    string PerformanceStatus,
    IReadOnlyList<DashboardMetric> Metrics);

public sealed record DashboardMetric(
    string Label,
    string Value,
    string Detail);
