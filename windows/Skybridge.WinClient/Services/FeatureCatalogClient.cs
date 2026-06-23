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
            // Title is the zh sidebar label (mirrors the Mac NavigationItem.localizedTitle \u2014
            // \u4E3B\u63A7\u53F0/\u8BBE\u5907\u53D1\u73B0/\u2026 \u2014 so the two read as ONE product, not a knock-off). The stable
            // identity is FeatureEntryId (used for selection, AutomationId, gate order asserts),
            // NOT the Title string; Status (EN, never rendered) stays a backend contract field.
            new(FeatureEntryId.Dashboard, "\u4E3B\u63A7\u53F0", "\uE80F", "Live overview", true),
            new(FeatureEntryId.DeviceDiscovery, "\u8BBE\u5907\u53D1\u73B0", "\uE8B9", "Core TXT parse", true),
            new(FeatureEntryId.UsbManagement, "USB \u7BA1\u7406", "\uE88E", "Device routing", true),
            new(FeatureEntryId.FileTransfer, "\u6587\u4EF6\u4F20\u8F93", "\uE8E5", "Queue and history", true),
            new(FeatureEntryId.RemoteDesktop, "\u8FDC\u7A0B\u684C\u9762", "\uE7F4", "Sessions", true),
            new(FeatureEntryId.SystemMonitor, "\u7CFB\u7EDF\u76D1\u63A7", "\uE9D9", "Metrics", true),
            new(FeatureEntryId.Settings, "\u8BBE\u7F6E", "\uE713", "Preferences", true)
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
