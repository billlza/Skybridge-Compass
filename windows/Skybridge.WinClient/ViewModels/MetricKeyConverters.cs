using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;

namespace Skybridge.WinClient.ViewModels;

/// <summary>
/// Maps a dashboard metric's stable Title (the <see cref="DashboardMetricView.Title"/>,
/// sourced from <c>DashboardMetric.Label</c> in DashboardMetricsClient) to a distinct
/// Segoe Fluent Icons glyph, so each StatCard reads like the Mac StatCard instead of
/// sharing one generic chart glyph.
///
/// Title → glyph (matching the Mac DashboardContentView SF Symbol intent;
/// Segoe Fluent Icons codepoints are best-fit and human-verified visually):
///   "Online Devices"  → E7F8  (Devices, a laptop)     ~ SF "laptopcomputer" (blue)
///   "Active Sessions"  → E7F4  (TVMonitor, a monitor)   ~ SF "display" (green)
///   "Transfer Tasks"   → E8B7  (Folder)                 ~ SF "folder" (orange)
///   "System Status"    → EC61  (CompletedSolid, a check ~ SF "checkmark.circle.fill" (green)
///                              mark in a filled circle)
/// Falls back to the original metric glyph (E9D2, BarChart) for unknown titles.
/// </summary>
public sealed class MetricKeyToGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var title = value as string ?? string.Empty;
        return title switch
        {
            "Online Devices" => "\uE7F8",   // Devices - a laptop, matches SF "laptopcomputer"
            "Active Sessions" => "\uE7F4",  // TVMonitor - a monitor/display, matches SF "display"
            "Transfer Tasks" => "\uE8B7",   // Folder, matches SF "folder"
            "System Status" => "\uEC61",    // CompletedSolid - checkmark in a filled circle, matches SF "checkmark.circle.fill"
            _ => "\uE9D2"
        };
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}

/// <summary>
/// Maps a dashboard metric's stable Title to a per-metric on-brand accent brush
/// (the SkyBridgeNav*/Success/Warning tokens in SkyBridgeTheme.xaml), so each
/// StatCard icon chip carries its own hue the way the Mac StatCards do
/// (blue / green / orange / status).
///
/// Title → brush (element-matching the Mac DashboardContentView StatCard colors:
/// blue / green / orange / green):
///   "Online Devices"  → SkyBridgeNavDashboardBrush  (blue,   Mac .blue)
///   "Active Sessions"  → SkyBridgeSuccessBrush        (green,  Mac .green)
///   "Transfer Tasks"   → SkyBridgeWarningBrush        (orange, Mac .orange)
///   "System Status"    → SkyBridgeSuccessBrush        (green,  Mac .green for "Excellent")
/// Falls back to the shared accent brush.
/// </summary>
public sealed class MetricKeyToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var title = value as string ?? string.Empty;
        var key = title switch
        {
            "Online Devices" => "SkyBridgeNavDashboardBrush",
            "Active Sessions" => "SkyBridgeSuccessBrush",
            "Transfer Tasks" => "SkyBridgeWarningBrush",
            "System Status" => "SkyBridgeSuccessBrush",
            _ => "SkyBridgeAccentBrush"
        };

        return ResolveBrush(key);
    }

    internal static Brush ResolveBrush(string key)
    {
        if (Application.Current?.Resources is { } resources &&
            resources.TryGetValue(key, out var brush) &&
            brush is Brush accentBrush)
        {
            return accentBrush;
        }

        if (Application.Current?.Resources is { } fallbackResources &&
            fallbackResources.TryGetValue("SkyBridgeAccentBrush", out var fallback) &&
            fallback is Brush fallbackBrush)
        {
            return fallbackBrush;
        }

        return new SolidColorBrush(Microsoft.UI.Colors.DodgerBlue);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}

/// <summary>
/// Maps a dashboard quick-action's stable Key (<see cref="WorkspaceActionItemView.Key"/>,
/// sourced from <c>WorkspaceActionItem.Key</c> in WorkspaceActionCatalogClient's
/// BuildDashboardQuickActions) to a per-action on-brand accent brush so each tile's
/// icon chip carries its own hue. The glyph itself already comes from the catalog
/// ({Binding Glyph}); only the color is keyed here.
///
/// Key → brush (element-matching the Mac QuickActionsPanelView colors:
/// scan=blue, file=orange, monitor=green, settings=gray):
///   "ScanDevices"   → SkyBridgeNavDashboardBrush     (blue,   Mac .blue)
///   "FileTransfer"  → SkyBridgeWarningBrush          (orange, Mac .orange)
///   "SystemMonitor" → SkyBridgeSuccessBrush          (green,  Mac .green)
///   "Settings"      → SkyBridgeNavSettingsBrush       (slate/gray, Mac .gray)
/// Falls back to the shared accent brush.
/// </summary>
public sealed class QuickActionKeyToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var key = value as string ?? string.Empty;
        var brushKey = key switch
        {
            "ScanDevices" => "SkyBridgeNavDashboardBrush",
            "FileTransfer" => "SkyBridgeWarningBrush",
            "SystemMonitor" => "SkyBridgeSuccessBrush",
            "Settings" => "SkyBridgeNavSettingsBrush",
            _ => "SkyBridgeAccentBrush"
        };

        return MetricKeyToBrushConverter.ResolveBrush(brushKey);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}

/// <summary>
/// Maps a <c>SystemMonitorMetricView.Label</c> from the dashboard System Performance
/// summary (CPU / Memory / Disk / Network — the SystemMonitorOverview rows built by
/// SystemMonitorWorkspaceClient) to a Segoe Fluent Icons glyph, mirroring the Mac
/// AppleSiliconInfoCard / PerformanceMonitor metric icons.
///   "CPU"     → E950  (Processor)        ~ SF "cpu"
///   "Memory"  → EEA0  (Memory)           ~ SF "memorychip"
///   "Disk"    → EDA2  (HardDrive)        ~ SF "internaldrive"
///   "Network" → E839  (NetworkTower)     ~ SF "network"
/// Falls back to a generic gauge glyph (E9D9, Speed) for unknown labels.
/// </summary>
public sealed class SystemMetricKeyToGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var label = value as string ?? string.Empty;
        return label switch
        {
            "CPU" => "\uE950",      // Processor
            "Memory" => "\uEEA0",   // Memory
            "Disk" => "\uEDA2",     // HardDrive
            "Network" => "\uE839",  // NetworkTower
            _ => "\uE9D9"           // Speed gauge
        };
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}

/// <summary>
/// Maps a <c>SystemMonitorMetricView.Label</c> to a per-metric on-brand accent brush,
/// so each System Performance summary row's value/icon carries its own hue the way the
/// Mac metric rows tint per-channel (CPU orange, Memory blue, Disk violet, Network green).
///   "CPU"     → SkyBridgeWarningBrush         (orange, Mac CPU)
///   "Memory"  → SkyBridgeNavDashboardBrush    (blue,   Mac Memory)
///   "Disk"    → SkyBridgeNavQuantumBrush       (violet)
///   "Network" → SkyBridgeSuccessBrush          (green,  Mac download/network)
/// Falls back to the shared accent brush.
/// </summary>
public sealed class SystemMetricKeyToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var label = value as string ?? string.Empty;
        var brushKey = label switch
        {
            "CPU" => "SkyBridgeWarningBrush",
            "Memory" => "SkyBridgeNavDashboardBrush",
            "Disk" => "SkyBridgeNavQuantumBrush",
            "Network" => "SkyBridgeSuccessBrush",
            _ => "SkyBridgeAccentBrush"
        };

        return MetricKeyToBrushConverter.ResolveBrush(brushKey);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}

/// <summary>
/// Maps a <c>DiscoveredPeerView.Platform</c> (the live DNS-SD peer's platform string,
/// e.g. "MacOS" / "iOS" / "Windows" / "Android" / "Linux") to a Segoe Fluent Icons
/// device glyph, so the dashboard Device Discovery summary rows carry a per-device-type
/// icon like the Mac EnhancedDeviceRow. Matching is case-insensitive and substring-based
/// so platform enum spellings (e.g. "MacOS", "iOS") still resolve.
///   windows      → E977  (Windows tile)
///   android      → E8EA  (CellPhone)
///   linux / unix → EC7A  (DeveloperTools)
///   ios handheld → E8EA  (CellPhone)
///   mac / apple  → E70C  (Laptop)
/// Falls back to a generic Devices glyph (E772) for unknown platforms.
/// </summary>
public sealed class PlatformToGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var platform = (value as string ?? string.Empty).ToLowerInvariant();

        if (platform.Contains("windows"))
        {
            return "\uE977"; // Windows tile
        }

        if (platform.Contains("android"))
        {
            return "\uE8EA"; // CellPhone
        }

        if (platform.Contains("linux") || platform.Contains("unix"))
        {
            return "\uEC7A"; // DeveloperTools
        }

        if (platform.Contains("ios") || platform.Contains("ipad") || platform.Contains("iphone"))
        {
            return "\uE8EA"; // CellPhone (iOS handheld)
        }

        if (platform.Contains("mac") || platform.Contains("apple") || platform.Contains("osx"))
        {
            return "\uE70C"; // Laptop / Mac
        }

        return "\uE772"; // Devices (generic)
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}
