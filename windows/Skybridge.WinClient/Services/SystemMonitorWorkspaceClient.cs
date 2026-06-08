using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface ISystemMonitorWorkspaceClient
{
    string BuildInitialStatus();

    string BuildPendingStatus();

    string BuildCompletedStatus(SystemMonitorWorkspaceSnapshot snapshot);

    string BuildCompletedStatusMessage();

    bool CanStartMonitoring();

    bool CanStopMonitoring();

    bool CanEnableAdvancedMonitoring();

    string BuildStartMonitoringPendingStatus();

    string BuildStopMonitoringPendingStatus();

    string BuildAdvancedMonitoringPendingStatus();

    Task<SystemMonitorWorkspaceSnapshot> BuildReadOnlySnapshotAsync();

    Task<SystemMonitorWorkspaceActionResult> BuildStartMonitoringActionAsync();

    Task<SystemMonitorWorkspaceActionResult> BuildStopMonitoringActionAsync();

    Task<SystemMonitorWorkspaceActionResult> BuildAdvancedMonitoringActionAsync();
}

public sealed class SystemMonitorWorkspaceClient : ISystemMonitorWorkspaceClient
{
    private readonly object _monitoringLock = new();
    private DateTimeOffset? _monitoringStartedAt;
    private int _monitoringSampleCount;

    public string BuildInitialStatus() => DefaultInitialStatus;

    public string BuildPendingStatus() => DefaultPendingStatus;

    public string BuildCompletedStatus(SystemMonitorWorkspaceSnapshot snapshot) =>
        BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() => DefaultCompletedStatusMessage;

    public bool CanStartMonitoring() => !GetMonitoringSession().IsActive;

    public bool CanStopMonitoring() => GetMonitoringSession().IsActive;

    public bool CanEnableAdvancedMonitoring() => false;

    public string BuildStartMonitoringPendingStatus() => DefaultStartMonitoringPendingStatus;

    public string BuildStopMonitoringPendingStatus() => DefaultStopMonitoringPendingStatus;

    public string BuildAdvancedMonitoringPendingStatus() => DefaultAdvancedMonitoringPendingStatus;

    public static string DefaultInitialStatus { get; } = "Ready";

    public static string DefaultPendingStatus { get; } = "Refreshing...";

    public static string DefaultCompletedStatusMessage { get; } = "System monitor workspace updated";

    public static string DefaultStartMonitoringPendingStatus { get; } = "Preparing monitoring...";

    public static string DefaultStopMonitoringPendingStatus { get; } = "Preparing monitoring stop...";

    public static string DefaultAdvancedMonitoringPendingStatus { get; } = "Preparing advanced monitoring...";

    public static string DefaultStartMonitoringBlockedStatus { get; } = "Monitoring already active";

    public static string DefaultStopMonitoringBlockedStatus { get; } = "Monitoring inactive";

    public static string DefaultAdvancedMonitoringBlockedStatus { get; } = "Advanced monitoring unavailable";

    public static string DefaultStartMonitoringBlockedMessage { get; } =
        "System monitor is already running in the in-process read-only sampler.";

    public static string DefaultStopMonitoringBlockedMessage { get; } =
        "System monitor background sampling is not running.";

    public static string DefaultAdvancedMonitoringBlockedMessage { get; } =
        "Advanced system monitoring requires a helper installation and elevation boundary.";

    public static string DefaultStartMonitoringStartedStatus { get; } = "Monitoring started";

    public static string DefaultStartMonitoringStartedMessage { get; } =
        "In-process read-only monitoring is active; refresh samples process, runtime, disk, and network snapshots without installing helpers.";

    public static string DefaultStopMonitoringStoppedStatus { get; } = "Monitoring stopped";

    public static string BuildDefaultCompletedStatus(SystemMonitorWorkspaceSnapshot snapshot) =>
        $"Snapshot {snapshot.CapturedAt:HH:mm:ss} UTC";

    public static SystemMonitorWorkspaceActionResult BuildDefaultStartMonitoringActionResult() =>
        new(DefaultStartMonitoringBlockedStatus, DefaultStartMonitoringBlockedMessage);

    public static SystemMonitorWorkspaceActionResult BuildDefaultStopMonitoringActionResult() =>
        new(DefaultStopMonitoringBlockedStatus, DefaultStopMonitoringBlockedMessage);

    public static SystemMonitorWorkspaceActionResult BuildDefaultAdvancedMonitoringActionResult() =>
        new(DefaultAdvancedMonitoringBlockedStatus, DefaultAdvancedMonitoringBlockedMessage);

    public static SystemMonitorWorkspaceActionResult BuildStartMonitoringStartedActionResult() =>
        new(DefaultStartMonitoringStartedStatus, DefaultStartMonitoringStartedMessage);

    public static SystemMonitorWorkspaceActionResult BuildStopMonitoringStoppedActionResult(int sampleCount, TimeSpan elapsed) =>
        new(
            DefaultStopMonitoringStoppedStatus,
            $"Stopped in-process read-only monitoring after {sampleCount} refresh sample(s) over {FormatElapsed(elapsed)}.");

    public Task<SystemMonitorWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        return Task.Run(() =>
        {
            var monitoring = CaptureMonitoringSample();
            using var process = Process.GetCurrentProcess();
            var memory = GC.GetGCMemoryInfo();
            var processMemoryBytes = process.WorkingSet64;
            var totalMemoryBytes = memory.TotalAvailableMemoryBytes > 0
                ? memory.TotalAvailableMemoryBytes
                : 0;
            var memoryPercent = totalMemoryBytes == 0
                ? 0
                : ClampPercent((double)processMemoryBytes / totalMemoryBytes * 100);
            var drive = DriveInfo.GetDrives()
                .Where(candidate => candidate.IsReady)
                .OrderByDescending(candidate => candidate.TotalSize)
                .FirstOrDefault();
            var diskPercent = drive is null || drive.TotalSize == 0
                ? 0
                : ClampPercent((double)(drive.TotalSize - drive.AvailableFreeSpace) / drive.TotalSize * 100);
            var activeNetworkCount = NetworkInterface.GetAllNetworkInterfaces()
                .Count(adapter =>
                    adapter.OperationalStatus == OperationalStatus.Up
                    && adapter.NetworkInterfaceType != NetworkInterfaceType.Loopback);
            var overallHealth = CalculateHealth(memoryPercent, diskPercent, activeNetworkCount);

            var overview = new List<SystemMonitorMetric>
            {
                new("CPU", $"{Environment.ProcessorCount} logical", "Usage sampling requires ETW/EventSource wiring"),
                new("Memory", $"{memoryPercent:0.0}%", $"{FormatBytes(processMemoryBytes)} process working set"),
                new("Disk", $"{diskPercent:0.0}%", drive is null ? "no ready drive" : $"{drive.Name} {FormatBytes(drive.AvailableFreeSpace)} free"),
                new("Network", $"{activeNetworkCount} active", "NetworkInterface read-only adapter count")
            };
            var details = new List<SystemMonitorMetric>
            {
                new("OS", RuntimeInformation.OSDescription, RuntimeInformation.OSArchitecture.ToString()),
                new(".NET", RuntimeInformation.FrameworkDescription, RuntimeInformation.ProcessArchitecture.ToString()),
                new("GC heap", FormatBytes(memory.HeapSizeBytes), $"fragmented={FormatBytes(memory.FragmentedBytes)}"),
                new("Thermal", "Windows provider pending", "mac helper parity requires ETW/WMI adapter, not UI code"),
                new("GPU", "provider pending", "Windows GPU counters need a diagnostics adapter"),
                new("Helper", "not installed", "no elevation or background service is started by this workspace")
            };
            var indicators = new List<SystemMonitorIndicator>
            {
                new("Health", overallHealth, "derived from memory, disk, and network adapter availability"),
                new("Monitoring", monitoring.IsActive ? "Active" : "Idle", BuildMonitoringDetail(monitoring)),
                new("Thermal", "Unknown", "read-only shell avoids unsupported temperature claims"),
                new("Load", "Nominal", "process/runtime snapshot only until ETW sampling is wired")
            };

            return new SystemMonitorWorkspaceSnapshot(
                DateTimeOffset.UtcNow,
                overview,
                details,
                indicators);
        });
    }

    public Task<SystemMonitorWorkspaceActionResult> BuildStartMonitoringActionAsync()
    {
        lock (_monitoringLock)
        {
            if (_monitoringStartedAt.HasValue)
            {
                return Task.FromResult(BuildDefaultStartMonitoringActionResult());
            }

            _monitoringStartedAt = DateTimeOffset.UtcNow;
            _monitoringSampleCount = 0;
        }

        return Task.FromResult(BuildStartMonitoringStartedActionResult());
    }

    public Task<SystemMonitorWorkspaceActionResult> BuildStopMonitoringActionAsync()
    {
        DateTimeOffset startedAt;
        int sampleCount;

        lock (_monitoringLock)
        {
            if (!_monitoringStartedAt.HasValue)
            {
                return Task.FromResult(BuildDefaultStopMonitoringActionResult());
            }

            startedAt = _monitoringStartedAt.Value;
            sampleCount = _monitoringSampleCount;
            _monitoringStartedAt = null;
            _monitoringSampleCount = 0;
        }

        return Task.FromResult(BuildStopMonitoringStoppedActionResult(sampleCount, DateTimeOffset.UtcNow - startedAt));
    }

    public Task<SystemMonitorWorkspaceActionResult> BuildAdvancedMonitoringActionAsync() =>
        Task.FromResult(BuildDefaultAdvancedMonitoringActionResult());

    private static string CalculateHealth(double memoryPercent, double diskPercent, int activeNetworkCount)
    {
        if (memoryPercent >= 85 || diskPercent >= 95)
        {
            return "Caution";
        }

        if (activeNetworkCount == 0)
        {
            return "Network offline";
        }

        return "Healthy";
    }

    private static double ClampPercent(double value) => Math.Clamp(value, 0, 100);

    private MonitoringSessionSnapshot GetMonitoringSession()
    {
        lock (_monitoringLock)
        {
            return new MonitoringSessionSnapshot(
                _monitoringStartedAt.HasValue,
                _monitoringStartedAt,
                _monitoringSampleCount);
        }
    }

    private MonitoringSessionSnapshot CaptureMonitoringSample()
    {
        lock (_monitoringLock)
        {
            if (!_monitoringStartedAt.HasValue)
            {
                return new MonitoringSessionSnapshot(false, null, _monitoringSampleCount);
            }

            _monitoringSampleCount++;
            return new MonitoringSessionSnapshot(true, _monitoringStartedAt, _monitoringSampleCount);
        }
    }

    private static string BuildMonitoringDetail(MonitoringSessionSnapshot monitoring)
    {
        if (!monitoring.IsActive || !monitoring.StartedAt.HasValue)
        {
            return "Use Monitoring to start in-process read-only sampling; no helper or elevation is required.";
        }

        return $"started={monitoring.StartedAt.Value:HH:mm:ss} UTC; samples={monitoring.SampleCount}";
    }

    private static string FormatBytes(long bytes)
    {
        if (bytes < 1024)
        {
            return $"{bytes} B";
        }

        var units = new[] { "KB", "MB", "GB", "TB" };
        var value = bytes / 1024d;
        var unitIndex = 0;
        while (value >= 1024 && unitIndex < units.Length - 1)
        {
            value /= 1024;
            unitIndex++;
        }

        return $"{value:0.0} {units[unitIndex]}";
    }

    private static string FormatElapsed(TimeSpan elapsed)
    {
        if (elapsed.TotalSeconds < 1)
        {
            return "less than 1 second";
        }

        if (elapsed.TotalMinutes < 1)
        {
            return $"{elapsed.TotalSeconds:0} second(s)";
        }

        return $"{elapsed.TotalMinutes:0.0} minute(s)";
    }

    private sealed record MonitoringSessionSnapshot(
        bool IsActive,
        DateTimeOffset? StartedAt,
        int SampleCount);
}

public sealed record SystemMonitorWorkspaceSnapshot(
    DateTimeOffset CapturedAt,
    IReadOnlyList<SystemMonitorMetric> Overview,
    IReadOnlyList<SystemMonitorMetric> Details,
    IReadOnlyList<SystemMonitorIndicator> Indicators);

public sealed record SystemMonitorMetric(
    string Label,
    string Value,
    string Detail);

public sealed record SystemMonitorIndicator(
    string Label,
    string State,
    string Detail);

public sealed record SystemMonitorWorkspaceActionResult(
    string Status,
    string Message);
