using System.Collections.Generic;
using Skybridge.WinClient.Converters;

namespace Skybridge.WinClient.Services;

public interface IFeatureCatalogClient
{
    IReadOnlyList<FeatureEntry> BuildReadOnlySnapshot();

    FeatureEntry ResolveDefaultSelection(IReadOnlyList<FeatureEntry> entries);

    bool IsSelected(FeatureEntry selectedFeature, FeatureEntryId featureId);
}

public sealed class FeatureCatalogClient : IFeatureCatalogClient
{
    // The rendered sidebar nav title, localized (zh/ja/en) for the active UI language. The
    // CANONICAL ENGLISH string below ("Dashboard"/"Device Discovery"/...) is the stable key
    // LabelKeyToLocalizedConverter.Localize maps to its resw value (Nav.*); it mirrors the Mac
    // NavigationItem.localizedTitle so the two read as ONE product, not a knock-off. The stable
    // identity is FeatureEntryId (used for selection, AutomationId, gate order asserts), NOT the
    // Title string; Status (EN, never rendered) stays a backend contract field.
    //
    // Built per-call (not a static field) so language resolution happens AFTER App.OnLaunched has
    // applied PrimaryLanguageOverride -- a static initializer could run before the override is set.
    public static IReadOnlyList<FeatureEntry> Entries => BuildEntries();

    private static IReadOnlyList<FeatureEntry> BuildEntries() =>
        new List<FeatureEntry>
        {
            new(FeatureEntryId.Dashboard, LabelKeyToLocalizedConverter.Localize("Dashboard"), "\uE80F", "Live overview", true),
            new(FeatureEntryId.DeviceDiscovery, LabelKeyToLocalizedConverter.Localize("Device Discovery"), "\uE8B9", "Core TXT parse", true),
            new(FeatureEntryId.UsbManagement, LabelKeyToLocalizedConverter.Localize("USB Management"), "\uE88E", "Device routing", true),
            new(FeatureEntryId.FileTransfer, LabelKeyToLocalizedConverter.Localize("File Transfer"), "\uE8E5", "Queue and history", true),
            new(FeatureEntryId.RemoteDesktop, LabelKeyToLocalizedConverter.Localize("Remote Desktop"), "\uE7F4", "Sessions", true),
            new(FeatureEntryId.Quantum, LabelKeyToLocalizedConverter.Localize("Quantum"), "\uE72E", "Core diagnostics", true),
            new(FeatureEntryId.SystemMonitor, LabelKeyToLocalizedConverter.Localize("System Monitor"), "\uE9D9", "Metrics", true),
            new(FeatureEntryId.Settings, LabelKeyToLocalizedConverter.Localize("Settings"), "\uE713", "Preferences", true)
        }.AsReadOnly();

    public IReadOnlyList<FeatureEntry> BuildReadOnlySnapshot() => BuildEntries();

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
