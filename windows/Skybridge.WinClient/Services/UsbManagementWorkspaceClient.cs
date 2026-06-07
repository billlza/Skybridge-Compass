using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface IUsbManagementWorkspaceClient
{
    Task<UsbManagementWorkspaceSnapshot> BuildReadOnlySnapshotAsync();
}

public sealed class UsbManagementWorkspaceClient : IUsbManagementWorkspaceClient
{
    public Task<UsbManagementWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        return Task.Run(() =>
        {
            var removableDrives = DriveInfo.GetDrives()
                .Where(drive => drive.IsReady && drive.DriveType == DriveType.Removable)
                .OrderBy(drive => drive.Name, StringComparer.OrdinalIgnoreCase)
                .ToList();
            var devices = removableDrives
                .Select(drive => new UsbDeviceItem(
                    string.IsNullOrWhiteSpace(drive.VolumeLabel)
                        ? $"Removable drive {drive.Name}"
                        : drive.VolumeLabel,
                    drive.Name,
                    "Storage device",
                    "provider pending",
                    "provider pending",
                    "not available via DriveInfo",
                    "DriveInfo.Removable",
                    $"{drive.DriveFormat}; {FormatBytes(drive.TotalSize)} total; {FormatBytes(drive.AvailableFreeSpace)} free"))
                .ToList();
            var storageCount = devices.Count;
            var stats = new List<UsbDeviceStat>
            {
                new("MFi Certified", "0", "Windows MFi provider pending"),
                new("Android Devices", "0", "ADB/MTP provider pending"),
                new("Storage Devices", storageCount.ToString(), "DriveInfo removable storage scan"),
                new("Total Devices", devices.Count.ToString(), "read-only USB workspace snapshot")
            };

            return new UsbManagementWorkspaceSnapshot(
                DateTimeOffset.UtcNow,
                stats,
                devices);
        });
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
}

public sealed record UsbManagementWorkspaceSnapshot(
    DateTimeOffset CapturedAt,
    IReadOnlyList<UsbDeviceStat> Stats,
    IReadOnlyList<UsbDeviceItem> Devices);

public sealed record UsbDeviceStat(
    string Title,
    string Value,
    string Detail);

public sealed record UsbDeviceItem(
    string Name,
    string DeviceId,
    string DeviceType,
    string VendorId,
    string ProductId,
    string SerialNumber,
    string ConnectionInterface,
    string Capabilities);
