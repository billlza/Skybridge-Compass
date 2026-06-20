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
/// Title → glyph (matching the Mac SF Symbol intent):
///   "Online Devices"  → E977  (Devices)        ~ laptopcomputer
///   "Active Sessions"  → E7EE  (Contact/People) ~ display / person.2
///   "Transfer Tasks"   → E8CB  (Sort / up-down) ~ arrow.up.arrow.down
///   "Performance"      → E9D9  (Speed / pulse)  ~ speedometer / gauge
/// Falls back to the original metric glyph (E9D2, BarChart) for unknown titles.
/// </summary>
public sealed class MetricKeyToGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var title = value as string ?? string.Empty;
        return title switch
        {
            "Online Devices" => "\uE977",
            "Active Sessions" => "\uE7EE",
            "Transfer Tasks" => "\uE8CB",
            "Performance" => "\uE9D9",
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
/// Title → brush:
///   "Online Devices"  → SkyBridgeNavDevicesBrush   (cyan)
///   "Active Sessions"  → SkyBridgeSuccessBrush       (green)
///   "Transfer Tasks"   → SkyBridgeWarningBrush       (orange)
///   "Performance"      → SkyBridgeNavQuantumBrush    (violet)
/// Falls back to the shared accent brush.
/// </summary>
public sealed class MetricKeyToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var title = value as string ?? string.Empty;
        var key = title switch
        {
            "Online Devices" => "SkyBridgeNavDevicesBrush",
            "Active Sessions" => "SkyBridgeSuccessBrush",
            "Transfer Tasks" => "SkyBridgeWarningBrush",
            "Performance" => "SkyBridgeNavQuantumBrush",
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
/// Key → brush:
///   "ScanDevices"   → SkyBridgeNavDevicesBrush      (cyan)
///   "FileTransfer"  → SkyBridgeNavFileTransferBrush (green)
///   "SystemMonitor" → SkyBridgeNavMonitorBrush      (orange)
///   "Settings"      → SkyBridgeNavSettingsBrush      (slate)
/// Falls back to the shared accent brush.
/// </summary>
public sealed class QuickActionKeyToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var key = value as string ?? string.Empty;
        var brushKey = key switch
        {
            "ScanDevices" => "SkyBridgeNavDevicesBrush",
            "FileTransfer" => "SkyBridgeNavFileTransferBrush",
            "SystemMonitor" => "SkyBridgeNavMonitorBrush",
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
