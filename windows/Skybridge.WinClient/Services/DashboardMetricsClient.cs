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
        var performanceStatus = request.IsBusy ? "Busy" : "Nominal";

        return new DashboardMetricsSnapshot(
            DateTimeOffset.UtcNow,
            onlineDeviceCount,
            activeSessionCount,
            request.TransferTaskCount,
            performanceStatus,
            new List<DashboardMetric>
            {
                new("Online Devices", onlineDeviceCount.ToString(), "Core engine connected peer count placeholder."),
                new("Active Sessions", activeSessionCount.ToString(), "Live session count remains adapter pending."),
                new("Transfer Tasks", request.TransferTaskCount.ToString(), "Mirrors the read-only File Transfer queue count."),
                new("Performance", performanceStatus, "Busy state until renderer and ETW telemetry providers are wired.")
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
