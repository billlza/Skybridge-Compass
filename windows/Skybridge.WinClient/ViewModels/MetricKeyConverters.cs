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
/// The same shared WorkspaceMetricCardTemplate is reused for the USB Management screen's
/// 4 stat cards (UsbDeviceStats), whose stable Titles are also keyed here so each USB card
/// reads with its own glyph the way the Mac USBStatCard does (the gate locks UsbDeviceStats
/// to this exact template, so the per-card icon has to be resolved off the shared converter):
///   "MFi Certified"   \u2192 EC61  (CompletedSolid, sealed check) ~ SF "checkmark.seal.fill"
///   "Android Devices" \u2192 E8EA  (CellPhone)                    ~ SF "smartphone"
///   "Storage Devices" \u2192 EDA2  (HardDrive)                    ~ SF "externaldrive.fill"
///   "Total Devices"   \u2192 E88E  (USB / connector)              ~ SF "cable.connector"
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
            // USB Management stat cards (shared template) \u2014 Mac USBStatCard icons.
            "MFi Certified" => "\uEC61",    // CompletedSolid (sealed checkmark), matches SF "checkmark.seal.fill"
            "Android Devices" => "\uE8EA",  // CellPhone, matches SF "smartphone"
            "Storage Devices" => "\uEDA2",  // HardDrive, matches SF "externaldrive.fill"
            "Total Devices" => "\uE88E",    // USB / connector, matches SF "cable.connector"
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
/// The USB Management screen reuses the same shared metric-card template, so its 4 stat-card
/// titles are keyed here too, element-matching the Mac USBStatCard hues:
///   "MFi Certified"   → SkyBridgeSuccessBrush         (green,  Mac .green)
///   "Android Devices" → SkyBridgeNavDashboardBrush    (blue,   Mac .blue)
///   "Storage Devices" → SkyBridgeWarningBrush         (orange, Mac .orange)
///   "Total Devices"   → SkyBridgeNavQuantumBrush      (purple, Mac .purple)
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
            // USB Management stat cards (shared template) — Mac USBStatCard hues.
            "MFi Certified" => "SkyBridgeSuccessBrush",
            "Android Devices" => "SkyBridgeNavDashboardBrush",
            "Storage Devices" => "SkyBridgeWarningBrush",
            "Total Devices" => "SkyBridgeNavQuantumBrush",
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
/// Maps a <c>SystemMonitorIndicatorView.Label</c> (Health / Monitoring / Advanced /
/// Thermal / Load — the SystemMonitorIndicators rows built by SystemMonitorWorkspaceClient)
/// to a Segoe Fluent Icons glyph for the System Monitor status-pill strip, mirroring the
/// Mac PerformanceMonitoringPanelView indicator icons (thermometer / load / health).
///   "Health"     → EA80  (Health, heart-pulse) ~ SF "heart.fill"/health
///   "Monitoring"  → E9D9  (Speed gauge)          ~ SF "speedometer"
///   "Advanced"    → E713  (Settings gear)        ~ SF "gearshape"
///   "Thermal"     → E9CA  (Diagnostic/temp dial) ~ SF "thermometer"
///   "Load"        → E9D2  (BarChart)             ~ SF "chart.line.uptrend.xyaxis"
/// Falls back to a generic gauge glyph (E9D9, Speed) for unknown labels.
/// NOTE: Segoe Fluent has no dedicated "fan"/"thermometer" — E9CA (Diagnostic) is the
/// closest dial-style temperature affordance; human-verify the glyph if exact icon matters.
/// </summary>
public sealed class SystemIndicatorLabelToGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var label = value as string ?? string.Empty;
        return label switch
        {
            "Health" => "\uEA80",      // Health (heart-pulse)
            "Monitoring" => "\uE9D9",  // Speed gauge
            "Advanced" => "\uE713",    // Settings gear
            "Thermal" => "\uE9CA",     // Diagnostic dial (closest to thermometer)
            "Load" => "\uE9D2",        // BarChart (load trend)
            _ => "\uE9D9"              // Speed gauge
        };
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}

/// <summary>
/// Maps a <c>SystemMonitorIndicatorView.State</c> (the live status string produced by
/// SystemMonitorWorkspaceClient: "Healthy" / "Caution" / "Network offline" for Health;
/// "Active" / "Idle" for Monitoring; "Read-only" / "Off" for Advanced; "Unknown" for
/// Thermal; "Nominal" for Load) to a status brush, so the System Monitor status-pill
/// strip tints each pill the way the Mac PerformanceMonitoringPanelView does:
///   good / active / nominal     → SkyBridgeSuccessBrush (green)
///   caution / read-only         → SkyBridgeWarningBrush (orange)
///   offline / error             → SkyBridgeDangerBrush  (red)
///   unknown / idle / off / else → SkyBridgeTextMutedBrush (muted, honest "pending/unknown")
/// Matching is case-insensitive and substring-based so wording variants still resolve;
/// nothing is faked-healthy — an unknown/pending state stays muted, never green.
/// </summary>
public sealed class SystemIndicatorStateToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var state = (value as string ?? string.Empty).ToLowerInvariant();

        string brushKey;
        if (state.Contains("offline") || state.Contains("error") || state.Contains("fail") || state.Contains("critical"))
        {
            brushKey = "SkyBridgeDangerBrush";
        }
        else if (state.Contains("caution") || state.Contains("warn") || state.Contains("read-only") || state.Contains("readonly"))
        {
            brushKey = "SkyBridgeWarningBrush";
        }
        else if (state.Contains("healthy") || state.Contains("good") || state.Contains("active") || state.Contains("nominal") || state.Contains("ok"))
        {
            brushKey = "SkyBridgeSuccessBrush";
        }
        else
        {
            // Unknown / Idle / Off / pending — deliberately NOT tinted healthy.
            brushKey = "SkyBridgeTextMutedBrush";
        }

        return MetricKeyToBrushConverter.ResolveBrush(brushKey);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}

/// <summary>
/// Maps a <c>SystemMonitorMetricView.Label</c> (CPU / Memory / Disk / Network) to a short
/// human caption for the colored metric tile's sub-label, mirroring the Mac MetricChartView
/// row caption. Kept tiny and honest — purely a display string, no fabricated numbers.
///   "CPU"     → "Processor"
///   "Memory"  → "Working set"
///   "Disk"    → "Storage"
///   "Network" → "Adapters"
/// Falls back to the raw label for unknown metrics.
/// </summary>
public sealed class SystemMetricLabelToCaptionConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var label = value as string ?? string.Empty;
        // Canonical English caption per metric (the source-of-truth caption). Then localize
        // it at the binding layer via the shared converter table (zh/ja), passing unknown
        // metrics through. XAML can't chain two converters, so we localize inline here.
        var caption = label switch
        {
            "CPU" => "Processor",
            "Memory" => "Working set",
            "Disk" => "Storage",
            "Network" => "Adapters",
            _ => label
        };

        return Skybridge.WinClient.Converters.LabelKeyToLocalizedConverter.Localize(caption);
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
