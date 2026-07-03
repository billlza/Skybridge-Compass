using System;
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;

namespace Skybridge.WinClient.ViewModels;

/// <summary>
/// Maps a connection-mode enum (Device Discovery <see cref="DiscoveryMode"/> or Remote
/// Desktop <see cref="RemoteDesktopConnectionMode"/>) to the selected-segment accent fill,
/// element-matching the Mac segmented controls whose selected pill is a soft accent fill
/// (accentColor.opacity(~0.2)) while unselected segments stay transparent.
///
/// The bound value is the VM's current selected mode; the <c>ConverterParameter</c> is the
/// segment's own mode name (e.g. "Auto", "Near", "Far", "LocalScan", "Qr", "Cloud", "Code").
/// When they match (case-insensitive, compared via enum name) the segment paints with the
/// soft Remote-Desktop accent brush; otherwise it is transparent. Pure presentation — no
/// data, mirrors the Mac selection highlight following @State.
/// </summary>
public sealed class ModeToAccentBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var selected = value?.ToString() ?? string.Empty;
        var segment = parameter as string ?? string.Empty;

        if (selected.Length > 0 &&
            segment.Length > 0 &&
            string.Equals(selected, segment, StringComparison.OrdinalIgnoreCase))
        {
            return ResolveBrush("SkyBridgeRemoteDesktopSoftBrush");
        }

        return new SolidColorBrush(Microsoft.UI.Colors.Transparent);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();

    internal static Brush ResolveBrush(string key)
    {
        if (Microsoft.UI.Xaml.Application.Current?.Resources is { } resources &&
            resources.TryGetValue(key, out var resource) &&
            resource is Brush brush)
        {
            return brush;
        }

        return new SolidColorBrush(Microsoft.UI.Colors.Transparent);
    }
}

/// <summary>
/// Maps a Remote Desktop session <c>State</c> string to a status tint, element-matching the
/// Mac per-session status capsule color (green connected / muted recent / neutral unknown).
/// The Windows read-only snapshot carries human State text ("Ready" / "Recent") derived from
/// the real Rust connection plan, so the converter keys its tint off a small case-insensitive
/// keyword set. Honest mapping: "Ready" reads as success-tinted, "Recent" as muted, anything
/// else as neutral — never fabricated-healthy for an unknown state.
/// </summary>
public sealed class StateToStatusBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var text = (value as string ?? string.Empty).Trim().ToLowerInvariant();

        var key = text switch
        {
            _ when text.Contains("ready", StringComparison.Ordinal) ||
                   text.Contains("connected", StringComparison.Ordinal) ||
                   text.Contains("active", StringComparison.Ordinal) => "SkyBridgeSuccessBrush",
            _ when text.Contains("connecting", StringComparison.Ordinal) ||
                   text.Contains("pending", StringComparison.Ordinal) => "SkyBridgeWarningBrush",
            _ when text.Contains("recent", StringComparison.Ordinal) ||
                   text.Contains("idle", StringComparison.Ordinal) => "SkyBridgeTextMutedBrush",
            _ when text.Contains("disconnect", StringComparison.Ordinal) ||
                   text.Contains("fail", StringComparison.Ordinal) ||
                   text.Contains("error", StringComparison.Ordinal) => "SkyBridgeDangerBrush",
            _ => "SkyBridgeTextMutedBrush"
        };

        return ModeToAccentBrushConverter.ResolveBrush(key);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>
/// Maps a monitoring-active bool (the System Monitor header <c>IsSystemMonitoring</c>) to a
/// status tint, element-matching the Mac liveSnapshotHeader pill: green when monitoring is
/// active, muted otherwise. Honest — a false/idle state reads muted, never fabricated-green.
/// <c>ConverterParameter="Soft"</c> returns the same hue at low opacity for the pill fill.
/// </summary>
public sealed class BoolToMonitoringBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var active = value is bool b && b;
        var key = active ? "SkyBridgeSuccessBrush" : "SkyBridgeTextMutedBrush";
        var brush = ModeToAccentBrushConverter.ResolveBrush(key);

        if (parameter is string mode && string.Equals(mode, "Soft", StringComparison.OrdinalIgnoreCase))
        {
            if (brush is SolidColorBrush solid)
            {
                var color = solid.Color;
                return new SolidColorBrush(Windows.UI.Color.FromArgb(0x2E, color.R, color.G, color.B));
            }
        }

        return brush;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>
/// Maps an integer (the File Transfer <c>SelectedFileTransferTab</c> index) to a
/// <see cref="Visibility"/> by comparing it against the <c>ConverterParameter</c> (the tab's
/// own index, e.g. "0" for Transfer, "1" for History). Visible when they are equal, Collapsed
/// otherwise — element-matching the Mac modernTabBar which reveals exactly one tab body at a
/// time. Pure view-state switch; the revealed FileTransferQueue / FileTransferHistory
/// collections are the existing real data.
/// </summary>
public sealed class IntEqualsToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var current = value switch
        {
            int i => i,
            null => -1,
            _ => int.TryParse(value.ToString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed) ? parsed : -1
        };

        var target = parameter switch
        {
            int p => p,
            null => -2,
            _ => int.TryParse(parameter.ToString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed) ? parsed : -2
        };

        return current == target ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
