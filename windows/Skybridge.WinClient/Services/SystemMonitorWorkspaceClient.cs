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

public interface ISystemMonitorAdvancedModeClient
{
    bool CanEnableAdvancedMonitoring();

    SystemMonitorAdvancedModeSnapshot CaptureSnapshot();

    SystemMonitorWorkspaceActionResult EnableAdvancedMonitoring();
}

public sealed class InMemorySystemMonitorAdvancedModeClient : ISystemMonitorAdvancedModeClient
{
    private readonly object _lock = new();
    private DateTimeOffset? _enabledAt;
    private int _activationCount;

    public bool CanEnableAdvancedMonitoring()
    {
        lock (_lock)
        {
            return !_enabledAt.HasValue;
        }
    }

    public SystemMonitorAdvancedModeSnapshot CaptureSnapshot()
    {
        lock (_lock)
        {
            return new SystemMonitorAdvancedModeSnapshot(
                _enabledAt.HasValue,
                _enabledAt,
                _activationCount);
        }
    }

    public SystemMonitorWorkspaceActionResult EnableAdvancedMonitoring()
    {
        lock (_lock)
        {
            if (_enabledAt.HasValue)
            {
                return SystemMonitorWorkspaceClient.BuildDefaultAdvancedMonitoringActionResult();
            }

            _enabledAt = DateTimeOffset.UtcNow;
            _activationCount++;
            return SystemMonitorWorkspaceClient.BuildAdvancedMonitoringEnabledActionResult();
        }
    }
}

public sealed class SystemMonitorWorkspaceClient : ISystemMonitorWorkspaceClient
{
    private readonly ISystemMonitorAdvancedModeClient _advancedModeClient;
    private readonly object _monitoringLock = new();
    private DateTimeOffset? _monitoringStartedAt;
    private int _monitoringSampleCount;

    // Bandwidth sampler state (real, in-process). Each snapshot reads the cumulative IPv4
    // byte counters off NetworkInterface; the throughput is the delta over the wall-clock
    // gap since the previous sample. No helper, no elevation, no fabricated number — the
    // first sample (no prior baseline) honestly reports "Sampling..." until a delta exists.
    private readonly object _bandwidthLock = new();
    private long? _lastTotalBytes;
    private DateTimeOffset _lastBandwidthSampleAt;

    public SystemMonitorWorkspaceClient()
        : this(new InMemorySystemMonitorAdvancedModeClient())
    {
    }

    public SystemMonitorWorkspaceClient(ISystemMonitorAdvancedModeClient advancedModeClient)
    {
        _advancedModeClient = advancedModeClient ?? throw new ArgumentNullException(nameof(advancedModeClient));
    }

    public string BuildInitialStatus() => DefaultInitialStatus;

    public string BuildPendingStatus() => DefaultPendingStatus;

    public string BuildCompletedStatus(SystemMonitorWorkspaceSnapshot snapshot) =>
        BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() => DefaultCompletedStatusMessage;

    public bool CanStartMonitoring() => !GetMonitoringSession().IsActive;

    public bool CanStopMonitoring() => GetMonitoringSession().IsActive;

    public bool CanEnableAdvancedMonitoring() => _advancedModeClient.CanEnableAdvancedMonitoring();

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

    public static string DefaultAdvancedMonitoringBlockedStatus { get; } = "Advanced monitoring already enabled";

    public static string DefaultStartMonitoringBlockedMessage { get; } =
        "System monitor is already running in the in-process read-only sampler.";

    public static string DefaultStopMonitoringBlockedMessage { get; } =
        "System monitor background sampling is not running.";

    public static string DefaultAdvancedMonitoringBlockedMessage { get; } =
        "Advanced read-only diagnostics are already enabled in memory.";

    public static string DefaultStartMonitoringStartedStatus { get; } = "Monitoring started";

    public static string DefaultStartMonitoringStartedMessage { get; } =
        "In-process read-only monitoring is active; refresh samples process, runtime, disk, and network snapshots without installing helpers.";

    public static string DefaultStopMonitoringStoppedStatus { get; } = "Monitoring stopped";

    public static string DefaultAdvancedMonitoringEnabledStatus { get; } = "Advanced monitoring enabled";

    public static string DefaultAdvancedMonitoringEnabledMessage { get; } =
        "Advanced read-only diagnostics are enabled in memory only; no helper was installed and no elevation was requested.";

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

    public static SystemMonitorWorkspaceActionResult BuildAdvancedMonitoringEnabledActionResult() =>
        new(DefaultAdvancedMonitoringEnabledStatus, DefaultAdvancedMonitoringEnabledMessage);

    public Task<SystemMonitorWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        return Task.Run(() =>
        {
            var monitoring = CaptureMonitoringSample();
            var advanced = _advancedModeClient.CaptureSnapshot();
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
            var bandwidth = CaptureBandwidthSample();
            var overallHealth = CalculateHealth(memoryPercent, diskPercent, activeNetworkCount);

            var overview = new List<SystemMonitorMetric>
            {
                new("CPU", $"{Environment.ProcessorCount} logical", "Usage sampling requires ETW/EventSource wiring"),
                new("Memory", $"{memoryPercent:0.0}%", $"{FormatBytes(processMemoryBytes)} process working set"),
                new("Disk", $"{diskPercent:0.0}%", drive is null ? "no ready drive" : $"{drive.Name} {FormatBytes(drive.AvailableFreeSpace)} free"),
                // REAL throughput from NetworkInterface IPv4 byte-counter delta over the refresh
                // interval (Mbps), replacing the prior adapter-count placeholder. Mac parity:
                // liveSnapshotMetrics "Bandwidth" tile. First sample shows "Sampling..." honestly.
                new("Bandwidth", bandwidth.Value, bandwidth.Detail),
                // HONEST unavailable (C14): Windows ships no temperature/fan provider reachable
                // from unprivileged UI code. Never fabricate a temperature — mirrors the Mac
                // Thermal tile showing "不可用" when no helper is installed.
                new("Thermal", "Unavailable", "No Windows temperature provider; an ETW/WMI/LibreHardwareMonitor adapter would be required")
            };
            var details = new List<SystemMonitorMetric>
            {
                new("OS", RuntimeInformation.OSDescription, RuntimeInformation.OSArchitecture.ToString()),
                new(".NET", RuntimeInformation.FrameworkDescription, RuntimeInformation.ProcessArchitecture.ToString()),
                new("GC heap", FormatBytes(memory.HeapSizeBytes), $"fragmented={FormatBytes(memory.FragmentedBytes)}"),
                new("Advanced", advanced.IsEnabled ? "read-only enabled" : "off", BuildAdvancedMonitoringDetail(advanced)),
                new("Thermal", "Windows provider pending", "mac helper parity requires ETW/WMI adapter, not UI code"),
                new("GPU", "provider pending", "Windows GPU counters need a diagnostics adapter"),
                new("Helper", "not installed", "no elevation or background service is started by this workspace")
            };
            var indicators = new List<SystemMonitorIndicator>
            {
                new("Health", overallHealth, "derived from memory, disk, and network adapter availability"),
                new("Monitoring", monitoring.IsActive ? "Active" : "Idle", BuildMonitoringDetail(monitoring)),
                new("Advanced", advanced.IsEnabled ? "Read-only" : "Off", BuildAdvancedMonitoringDetail(advanced)),
                new("Thermal", "Unknown", "read-only shell avoids unsupported temperature claims"),
                new("Load", "Nominal", "process/runtime snapshot only until ETW sampling is wired")
            };

            // Insight rows (Mac liveSnapshotHighlights). Partial-honest by design:
            //  - Overall Health  = REAL (CalculateHealth over memory/disk/network).
            //  - Thermal Envelope = HONEST Unknown (no Windows temperature provider; never a temp).
            //  - Cooling + Transport = fan RPM is HONEST Unknown (no fan provider); the transport
            //    portion is the REAL bandwidth sample from the NetworkInterface byte-rate delta.
            var insights = new List<SystemMonitorInsight>
            {
                new(
                    "Overall Health",
                    overallHealth,
                    "Aggregated from memory pressure, disk usage, and network adapter availability."),
                new(
                    "Thermal Envelope",
                    "Unknown",
                    "No Windows temperature provider; CPU/GPU temps require an ETW/WMI/LibreHardwareMonitor adapter."),
                new(
                    "Cooling + Transport",
                    bandwidth.Value,
                    $"Fan RPM unavailable (no Windows provider); transport throughput {bandwidth.Detail}.")
            };

            return new SystemMonitorWorkspaceSnapshot(
                DateTimeOffset.UtcNow,
                overview,
                details,
                indicators,
                insights);
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
        Task.FromResult(_advancedModeClient.EnableAdvancedMonitoring());

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

    // Two-sample network throughput sampler (REAL, in-process). Sums the cumulative IPv4
    // BytesReceived+BytesSent across every non-loopback up adapter, then divides the delta
    // since the previous snapshot by the elapsed wall-clock seconds to get bits/s -> Mbps.
    // No helper, no elevation. The first call has no baseline, so it honestly reports a
    // "Sampling..." placeholder rather than fabricating a rate.
    private BandwidthSample CaptureBandwidthSample()
    {
        long totalBytes = 0;
        var counterAvailable = false;
        foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (adapter.OperationalStatus != OperationalStatus.Up
                || adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback)
            {
                continue;
            }

            try
            {
                var stats = adapter.GetIPv4Statistics();
                totalBytes += stats.BytesReceived + stats.BytesSent;
                counterAvailable = true;
            }
            catch (NetworkInformationException)
            {
                // Some adapters expose no IPv4 statistics; skip them without claiming a number.
            }
            catch (PlatformNotSupportedException)
            {
                // No IPv4 statistics provider on this adapter; honestly skip it.
            }
        }

        var now = DateTimeOffset.UtcNow;

        lock (_bandwidthLock)
        {
            if (!counterAvailable)
            {
                _lastTotalBytes = null;
                return new BandwidthSample("Unavailable", "No IPv4-capable adapter exposed byte counters");
            }

            if (!_lastTotalBytes.HasValue)
            {
                _lastTotalBytes = totalBytes;
                _lastBandwidthSampleAt = now;
                return new BandwidthSample("Sampling...", "First sample; throughput appears on the next refresh");
            }

            var elapsedSeconds = (now - _lastBandwidthSampleAt).TotalSeconds;
            var byteDelta = totalBytes - _lastTotalBytes.Value;
            _lastTotalBytes = totalBytes;
            _lastBandwidthSampleAt = now;

            if (elapsedSeconds <= 0 || byteDelta < 0)
            {
                // Clock skew or counter reset (adapter reconnect) — do not fabricate a rate.
                return new BandwidthSample("Sampling...", "Counter reset; throughput appears on the next refresh");
            }

            var megabitsPerSecond = byteDelta * 8d / 1_000_000d / elapsedSeconds;
            return new BandwidthSample(
                $"{megabitsPerSecond:0.00} Mbps",
                $"IPv4 byte-counter delta over {elapsedSeconds:0.0}s across active adapters");
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

    private static string BuildAdvancedMonitoringDetail(SystemMonitorAdvancedModeSnapshot advanced)
    {
        if (!advanced.IsEnabled || !advanced.EnabledAt.HasValue)
        {
            return "Use Enable Advanced Monitoring to expose additional read-only diagnostics; no helper or elevation is required.";
        }

        return $"enabled={advanced.EnabledAt.Value:HH:mm:ss} UTC; activations={advanced.ActivationCount}; no helper/elevation";
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

    private sealed record BandwidthSample(
        string Value,
        string Detail);
}

public sealed record SystemMonitorWorkspaceSnapshot(
    DateTimeOffset CapturedAt,
    IReadOnlyList<SystemMonitorMetric> Overview,
    IReadOnlyList<SystemMonitorMetric> Details,
    IReadOnlyList<SystemMonitorIndicator> Indicators,
    IReadOnlyList<SystemMonitorInsight> Insights);

public sealed record SystemMonitorMetric(
    string Label,
    string Value,
    string Detail);

public sealed record SystemMonitorIndicator(
    string Label,
    string State,
    string Detail);

// Insight row (Mac liveSnapshotHighlights): a titled health/throughput line with a
// right-aligned value and a caption. Partial-honest — Health + the transport portion of
// Cooling are real; the thermal/fan portions carry an honest "Unknown" value, never a
// fabricated temperature or RPM.
public sealed record SystemMonitorInsight(
    string Title,
    string Value,
    string Caption);

public sealed record SystemMonitorAdvancedModeSnapshot(
    bool IsEnabled,
    DateTimeOffset? EnabledAt,
    int ActivationCount);

public sealed record SystemMonitorWorkspaceActionResult(
    string Status,
    string Message);
