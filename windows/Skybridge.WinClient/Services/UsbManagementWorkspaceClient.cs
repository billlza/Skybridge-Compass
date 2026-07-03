using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Windows.Devices.Enumeration;

namespace Skybridge.WinClient.Services;

public interface IUsbManagementWorkspaceClient
{
    string BuildInitialStatus();

    string BuildPendingStatus();

    string BuildCompletedStatus(UsbManagementWorkspaceSnapshot snapshot);

    string BuildCompletedStatusMessage();

    Task<UsbManagementWorkspaceSnapshot> BuildReadOnlySnapshotAsync();
}

/// <summary>
/// Read-only USB workspace provider for the Mac-style USB Management screen.
///
/// Enumeration is REAL and in-framework (no extra NuGet package): it uses the
/// WinRT <see cref="DeviceInformation.FindAllAsync(string)"/> projection — already on the
/// app's <c>net10.0-windows10.0.22621.0</c> TFM with TargetPlatformMinVersion
/// <c>10.0.19041.0</c> and already exercised elsewhere
/// (WeatherClient consumes Windows.Devices.Geolocation) — against the
/// <see cref="Windows.Devices.Usb.UsbDevice.GetDeviceSelector()"/> AQS selector, which is
/// what surfaces real Vendor/Product IDs. The DriveInfo removable-volume pass is kept and
/// MERGED in so mass-storage volumes still carry their human label + capacity facts.
///
/// This mirrors the Mac <c>USBCConnectionManager.enumerateUSBDevicesSnapshot()</c> shape:
/// per-device VID/PID/name/serial + a coarse device-type classification + capability chips.
/// It is honest — when nothing is connected the collections come back empty (the view shows
/// the empty state) and no placeholder/fake rows are ever fabricated. Fields that genuinely
/// cannot be read from a given source stay blank rather than carrying invented values.
/// </summary>
public sealed class UsbManagementWorkspaceClient : IUsbManagementWorkspaceClient
{
    public string BuildInitialStatus() => DefaultInitialStatus;

    public string BuildPendingStatus() => DefaultPendingStatus;

    public string BuildCompletedStatus(UsbManagementWorkspaceSnapshot snapshot) =>
        BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() => DefaultCompletedStatusMessage;

    public static string DefaultInitialStatus { get; } = "Ready";

    public static string DefaultPendingStatus { get; } = "Refreshing...";

    public static string DefaultCompletedStatusMessage { get; } = "USB management workspace updated";

    public static string BuildDefaultCompletedStatus(UsbManagementWorkspaceSnapshot snapshot) =>
        $"Last scan {snapshot.CapturedAt:HH:mm:ss} UTC";

    // ---- Vendor allow-lists, mirroring USBCConnectionManager's hardcoded lists ----
    private const ushort AppleVendorId = 0x05AC;

    private static readonly HashSet<ushort> AndroidVendorIds = new()
    {
        0x18D1, 0x04E8, 0x0BB4, 0x22B8, 0x19D2, 0x12D1, 0x0FCE, 0x0489, 0x1004, 0x2717, 0x2A45
    };

    private static readonly HashSet<ushort> StorageVendorIds = new()
    {
        0x0781, 0x0930, 0x058F, 0x090C, 0x13FE, 0x0951, 0x8564, 0x1058, 0x04C5, 0x0480
    };

    // USB instance-path VID/PID, e.g. "USB\VID_05AC&PID_12A8\..." or "...#vid_05ac&pid_12a8#...".
    private static readonly Regex VidPidRegex = new(
        @"VID_(?<vid>[0-9A-Fa-f]{4}).*?PID_(?<pid>[0-9A-Fa-f]{4})",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public async Task<UsbManagementWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        // 1) Real USB-device enumeration via the in-framework WinRT projection.
        var usbDevices = await EnumerateUsbDevicesAsync().ConfigureAwait(false);

        // 2) Removable-storage volumes (DriveInfo) — merged so storage volumes keep their
        //    human label + capacity facts. Matched onto a USB device by drive letter where
        //    possible; otherwise surfaced as a standalone storage row.
        var storageVolumes = await Task.Run(EnumerateRemovableVolumes).ConfigureAwait(false);

        var devices = MergeDevices(usbDevices, storageVolumes);

        var mfiCount = devices.Count(d => d.IsMfiCertified);
        var androidCount = devices.Count(d => d.DeviceTypeKind == UsbDeviceTypeKind.Android);
        var storageCount = devices.Count(d =>
            d.DeviceTypeKind is UsbDeviceTypeKind.ExternalDrive or UsbDeviceTypeKind.FlashDrive);

        var stats = new List<UsbDeviceStat>
        {
            new("MFi Certified", mfiCount.ToString(CultureInfo.InvariantCulture), "Apple-certified accessories"),
            new("Android Devices", androidCount.ToString(CultureInfo.InvariantCulture), "ADB/MTP-class handsets"),
            new("Storage Devices", storageCount.ToString(CultureInfo.InvariantCulture), "External drives + flash media"),
            new("Total Devices", devices.Count.ToString(CultureInfo.InvariantCulture), "Connected USB devices")
        };

        return new UsbManagementWorkspaceSnapshot(
            DateTimeOffset.UtcNow,
            stats,
            devices.Select(d => d.ToItem()).ToList());
    }

    private static async Task<List<EnumeratedUsbDevice>> EnumerateUsbDevicesAsync()
    {
        var results = new List<EnumeratedUsbDevice>();
        try
        {
            // Enumerate all USB peripherals via the GUID_DEVINTERFACE_USB_DEVICE interface-class AQS.
            // (UsbDevice.GetDeviceSelector requires a VID/PID or class, so it can't list "all"; this
            // generic interface AQS lists every USB device, and TryBuildDevice parses VID/PID from
            // each device's instance Id — USB\VID_xxxx&PID_yyyy&... .)
            const string usbDeviceInterfaceClass = "{A5DCBF10-6530-11D2-901F-00C04FB951ED}";
            var selector = $"System.Devices.InterfaceClassGuid:=\"{usbDeviceInterfaceClass}\"";
            var collection = await DeviceInformation
                .FindAllAsync(selector, UsbInformationProperties)
                .AsTask()
                .ConfigureAwait(false);

            foreach (var info in collection)
            {
                var device = TryBuildDevice(info);
                if (device is not null)
                {
                    results.Add(device);
                }
            }
        }
        catch (Exception)
        {
            // Enumeration is best-effort. If the WinRT projection is unavailable on a given
            // host we surface zero USB devices (and let the storage pass / empty state stand)
            // rather than throwing the whole workspace refresh.
        }

        return results;
    }

    private static readonly string[] UsbInformationProperties =
    {
        "System.Devices.DeviceInstanceId",
        "System.ItemNameDisplay"
    };

    private static EnumeratedUsbDevice? TryBuildDevice(DeviceInformation info)
    {
        var instanceId = ReadStringProperty(info, "System.Devices.DeviceInstanceId");
        var source = !string.IsNullOrWhiteSpace(instanceId) ? instanceId : info.Id;

        ushort vendorId = 0;
        ushort productId = 0;
        var match = VidPidRegex.Match(source ?? string.Empty);
        if (match.Success)
        {
            vendorId = ParseHex(match.Groups["vid"].Value);
            productId = ParseHex(match.Groups["pid"].Value);
        }

        var name = !string.IsNullOrWhiteSpace(info.Name)
            ? info.Name
            : ReadStringProperty(info, "System.ItemNameDisplay");
        if (string.IsNullOrWhiteSpace(name))
        {
            name = "USB device";
        }

        var serial = ExtractSerial(instanceId);
        var kind = ClassifyDevice(vendorId, name);
        var isMfi = kind == UsbDeviceTypeKind.AppleMfi;

        var deviceId = vendorId != 0 || productId != 0
            ? string.Create(CultureInfo.InvariantCulture, $"{vendorId:X4}:{productId:X4}{(string.IsNullOrEmpty(serial) ? string.Empty : ":" + serial)}")
            : (instanceId ?? info.Id ?? name);

        var capabilities = new List<string> { "USB" };
        if (info.IsEnabled)
        {
            capabilities.Add("Connected");
        }

        return new EnumeratedUsbDevice(
            DeviceId: deviceId,
            Name: name,
            DeviceTypeKind: kind,
            VendorId: vendorId,
            ProductId: productId,
            SerialNumber: serial,
            IsMfiCertified: isMfi,
            ConnectionInterface: "USB",
            DriveLetter: null,
            Capabilities: capabilities);
    }

    private static UsbDeviceTypeKind ClassifyDevice(ushort vendorId, string name)
    {
        var lowered = name.ToLowerInvariant();

        if (vendorId == AppleVendorId)
        {
            if (lowered.Contains("iphone") || lowered.Contains("ipad") || lowered.Contains("ipod") ||
                lowered.Contains("airpods") || lowered.Contains("earpods") || lowered.Contains("beats"))
            {
                return UsbDeviceTypeKind.AppleMfi;
            }

            return UsbDeviceTypeKind.AppleMfi;
        }

        if (AndroidVendorIds.Contains(vendorId) ||
            lowered.Contains("android") || lowered.Contains("pixel") || lowered.Contains("galaxy"))
        {
            return UsbDeviceTypeKind.Android;
        }

        if (StorageVendorIds.Contains(vendorId) ||
            lowered.Contains("flash") || lowered.Contains("usb drive") || lowered.Contains("thumb"))
        {
            return UsbDeviceTypeKind.FlashDrive;
        }

        if (lowered.Contains("disk") || lowered.Contains("ssd") || lowered.Contains("hdd") ||
            lowered.Contains("drive") || lowered.Contains("storage"))
        {
            return UsbDeviceTypeKind.ExternalDrive;
        }

        if (lowered.Contains("audio") || lowered.Contains("headphone") || lowered.Contains("headset") ||
            lowered.Contains("microphone") || lowered.Contains("speaker"))
        {
            return UsbDeviceTypeKind.Audio;
        }

        return UsbDeviceTypeKind.Unknown;
    }

    private static List<EnumeratedUsbDevice> MergeDevices(
        List<EnumeratedUsbDevice> usbDevices,
        List<RemovableVolume> storageVolumes)
    {
        var merged = new List<EnumeratedUsbDevice>(usbDevices);

        foreach (var volume in storageVolumes)
        {
            // Attach the storage facts to an existing storage-class USB device when we can,
            // otherwise surface the volume as its own storage row so removable media that
            // the UsbDevice selector does not expose is still represented.
            var host = merged.FirstOrDefault(d =>
                d.DeviceTypeKind is UsbDeviceTypeKind.ExternalDrive or UsbDeviceTypeKind.FlashDrive &&
                string.IsNullOrEmpty(d.DriveLetter));

            if (host is not null)
            {
                merged.Remove(host);
                merged.Add(host with
                {
                    DriveLetter = volume.DriveLetter,
                    ConnectionInterface = "USB mass storage",
                    Capabilities = host.Capabilities.Concat(volume.Capabilities).ToList()
                });
            }
            else
            {
                merged.Add(new EnumeratedUsbDevice(
                    DeviceId: volume.DriveLetter,
                    Name: volume.Name,
                    DeviceTypeKind: UsbDeviceTypeKind.ExternalDrive,
                    VendorId: 0,
                    ProductId: 0,
                    SerialNumber: string.Empty,
                    IsMfiCertified: false,
                    ConnectionInterface: "USB mass storage",
                    DriveLetter: volume.DriveLetter,
                    Capabilities: volume.Capabilities));
            }
        }

        return merged
            .OrderBy(d => d.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static List<RemovableVolume> EnumerateRemovableVolumes()
    {
        try
        {
            return DriveInfo.GetDrives()
                .Where(drive => drive.IsReady && drive.DriveType == DriveType.Removable)
                .OrderBy(drive => drive.Name, StringComparer.OrdinalIgnoreCase)
                .Select(drive => new RemovableVolume(
                    DriveLetter: drive.Name,
                    Name: string.IsNullOrWhiteSpace(drive.VolumeLabel)
                        ? $"Removable drive {drive.Name}"
                        : drive.VolumeLabel,
                    Capabilities: new List<string>
                    {
                        drive.DriveFormat,
                        $"{FormatBytes(drive.TotalSize)} total",
                        $"{FormatBytes(drive.AvailableFreeSpace)} free"
                    }))
                .ToList();
        }
        catch (Exception)
        {
            return new List<RemovableVolume>();
        }
    }

    private static string ReadStringProperty(DeviceInformation info, string key)
    {
        if (info.Properties.TryGetValue(key, out var value) && value is string text)
        {
            return text;
        }

        return string.Empty;
    }

    private static string ExtractSerial(string? instanceId)
    {
        if (string.IsNullOrWhiteSpace(instanceId))
        {
            return string.Empty;
        }

        // Instance id is "USB\VID_xxxx&PID_yyyy\<serial-or-instance>".
        var lastSeparator = instanceId.LastIndexOf('\\');
        if (lastSeparator < 0 || lastSeparator == instanceId.Length - 1)
        {
            return string.Empty;
        }

        var tail = instanceId[(lastSeparator + 1)..];

        // A tail that contains '&' is an OS-generated instance path (not a real serial).
        if (tail.Contains('&'))
        {
            return string.Empty;
        }

        return tail;
    }

    private static ushort ParseHex(string value) =>
        ushort.TryParse(value, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var parsed)
            ? parsed
            : (ushort)0;

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

    private sealed record EnumeratedUsbDevice(
        string DeviceId,
        string Name,
        UsbDeviceTypeKind DeviceTypeKind,
        ushort VendorId,
        ushort ProductId,
        string SerialNumber,
        bool IsMfiCertified,
        string ConnectionInterface,
        string? DriveLetter,
        IReadOnlyList<string> Capabilities)
    {
        public UsbDeviceItem ToItem() => new(
            Name,
            DeviceId,
            DeviceTypeKind.ToDisplayString(),
            VendorId != 0 || ProductId != 0
                ? string.Create(CultureInfo.InvariantCulture, $"0x{VendorId:X4}")
                : string.Empty,
            VendorId != 0 || ProductId != 0
                ? string.Create(CultureInfo.InvariantCulture, $"0x{ProductId:X4}")
                : string.Empty,
            SerialNumber ?? string.Empty,
            ConnectionInterface,
            // A15 — pass the capability strings through as a list (no string.Join); the
            // view projects them to chips. A copied list keeps the record value-immutable.
            Capabilities.Count == 0
                ? System.Array.Empty<string>()
                : Capabilities.ToList(),
            DeviceTypeKind.ToKey(),
            IsMfiCertified);
    }

    private sealed record RemovableVolume(
        string DriveLetter,
        string Name,
        IReadOnlyList<string> Capabilities);
}

/// <summary>Coarse device classification mirroring the Mac <c>USBCDeviceType</c>.</summary>
public enum UsbDeviceTypeKind
{
    AppleMfi,
    Android,
    ExternalDrive,
    FlashDrive,
    Audio,
    Unknown
}

internal static class UsbDeviceTypeKindExtensions
{
    public static string ToDisplayString(this UsbDeviceTypeKind kind) => kind switch
    {
        UsbDeviceTypeKind.AppleMfi => "Apple MFi device",
        UsbDeviceTypeKind.Android => "Android device",
        UsbDeviceTypeKind.ExternalDrive => "External drive",
        UsbDeviceTypeKind.FlashDrive => "USB flash drive",
        UsbDeviceTypeKind.Audio => "Audio device",
        _ => "USB device"
    };

    // Stable key consumed by the icon/brush converters (not user-facing).
    public static string ToKey(this UsbDeviceTypeKind kind) => kind switch
    {
        UsbDeviceTypeKind.AppleMfi => "appleMfi",
        UsbDeviceTypeKind.Android => "android",
        UsbDeviceTypeKind.ExternalDrive => "externalDrive",
        UsbDeviceTypeKind.FlashDrive => "flashDrive",
        UsbDeviceTypeKind.Audio => "audio",
        _ => "unknown"
    };
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
    // A15 — the REAL per-device capability strings (e.g. "USB", "Connected", a drive
    // format, "<n> GB total/free"), kept as a list so the Mac LazyVGrid chip parity can
    // render each as its own chip instead of one joined "a; b; c" line. The values come
    // straight from the enumeration pass and stay non-localized (device formats / "USB" /
    // "Connected"). An empty list renders no chip row (honest — no fabricated capability).
    IReadOnlyList<string> Capabilities,
    string DeviceTypeKey,
    bool IsMfiCertified);
