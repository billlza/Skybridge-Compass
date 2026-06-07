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
    string BuildPendingStatus();

    string BuildCompletedStatus(SystemMonitorWorkspaceSnapshot snapshot);

    string BuildCompletedStatusMessage();

    Task<SystemMonitorWorkspaceSnapshot> BuildReadOnlySnapshotAsync();
}

public sealed class SystemMonitorWorkspaceClient : ISystemMonitorWorkspaceClient
{
    public string BuildPendingStatus() => DefaultPendingStatus;

    public string BuildCompletedStatus(SystemMonitorWorkspaceSnapshot snapshot) =>
        BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() => DefaultCompletedStatusMessage;

    public static string DefaultPendingStatus { get; } = "Refreshing...";

    public static string DefaultCompletedStatusMessage { get; } = "System monitor workspace updated";

    public static string BuildDefaultCompletedStatus(SystemMonitorWorkspaceSnapshot snapshot) =>
        $"Snapshot {snapshot.CapturedAt:HH:mm:ss} UTC";

    public Task<SystemMonitorWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        return Task.Run(() =>
        {
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
