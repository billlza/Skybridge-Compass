using System.Collections.Generic;

namespace Skybridge.WinClient.Services;

public interface IFeatureCatalogClient
{
    IReadOnlyList<FeatureEntry> BuildReadOnlySnapshot();

    FeatureEntry ResolveDefaultSelection(IReadOnlyList<FeatureEntry> entries);

    bool IsSelected(FeatureEntry selectedFeature, FeatureEntryId featureId);
}

public sealed class FeatureCatalogClient : IFeatureCatalogClient
{
    public static IReadOnlyList<FeatureEntry> Entries { get; } =
        new List<FeatureEntry>
        {
            new(FeatureEntryId.Dashboard, "Dashboard", "\uE80F", "Live overview", true),
            new(FeatureEntryId.DeviceDiscovery, "Device Discovery", "\uE8B9", "Core TXT parse", true),
            new(FeatureEntryId.UsbManagement, "USB Management", "\uE88E", "Device routing", true),
            new(FeatureEntryId.FileTransfer, "File Transfer", "\uE8E5", "Queue and history", true),
            new(FeatureEntryId.RemoteDesktop, "Remote Desktop", "\uE7F4", "Sessions", true),
            new(FeatureEntryId.SystemMonitor, "System Monitor", "\uE9D9", "Metrics", true),
            new(FeatureEntryId.Settings, "Settings", "\uE713", "Preferences", true)
        }.AsReadOnly();

    public IReadOnlyList<FeatureEntry> BuildReadOnlySnapshot() => Entries;

    public FeatureEntry ResolveDefaultSelection(IReadOnlyList<FeatureEntry> entries) =>
        entries.Count == 0 ? Entries[0] : entries[0];

    public bool IsSelected(FeatureEntry selectedFeature, FeatureEntryId featureId) =>
        selectedFeature.Id == featureId;
}

public enum FeatureEntryId
{
    Dashboard,
    DeviceDiscovery,
    UsbManagement,
    FileTransfer,
    RemoteDesktop,
    SystemMonitor,
    Settings
}

public sealed record FeatureEntry(
    FeatureEntryId Id,
    string Title,
    string Glyph,
    string Status,
    bool IsImplemented);
