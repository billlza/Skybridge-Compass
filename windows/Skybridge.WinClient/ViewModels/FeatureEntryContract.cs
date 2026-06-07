using System.Collections.Generic;

namespace Skybridge.WinClient.ViewModels;

public enum FeatureEntryId
{
    Dashboard,
    DeviceDiscovery,
    UsbManagement,
    FileTransfer,
    RemoteDesktop,
    Quantum,
    SystemMonitor,
    Settings
}

public sealed record FeatureEntry(
    FeatureEntryId Id,
    string Title,
    string Glyph,
    string Status,
    bool IsImplemented);

public static class FeatureEntryContract
{
    public static IReadOnlyList<FeatureEntry> Entries { get; } =
        new List<FeatureEntry>
        {
            new(FeatureEntryId.Dashboard, "Dashboard", "\uE80F", "Live overview", true),
            new(FeatureEntryId.DeviceDiscovery, "Device Discovery", "\uE8B9", "Core TXT parse", true),
            new(FeatureEntryId.UsbManagement, "USB Management", "\uE88E", "Device routing", false),
            new(FeatureEntryId.FileTransfer, "File Transfer", "\uE8E5", "Queue and history", true),
            new(FeatureEntryId.RemoteDesktop, "Remote Desktop", "\uE7F4", "Sessions", false),
            new(FeatureEntryId.Quantum, "Quantum", "\uE72E", "Core diagnostics", true),
            new(FeatureEntryId.SystemMonitor, "System Monitor", "\uE9D9", "Metrics", false),
            new(FeatureEntryId.Settings, "Settings", "\uE713", "Preferences", false)
        }.AsReadOnly();
}
