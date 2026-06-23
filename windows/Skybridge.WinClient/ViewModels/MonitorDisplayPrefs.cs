using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace Skybridge.WinClient.ViewModels;

// =====================================================================================
//  MonitorDisplayPrefs — the process-wide source the System-Monitor metric TILES read to decide
//  which metrics render (系统监控 > 显示项 > CPU / 内存 / 磁盘 / 网络 / 温度 / 风扇转速). The tiles
//  live in a projected ItemsControl (SystemMonitorOverview) whose DataTemplate cannot reach the
//  page VM, so this ONE instance is declared as an app resource (App.xaml x:Key="MonitorDisplayPrefs")
//  and the SettingsCoordinator monitor-gate sink pushes the six show-flags into it.
//
//  Per-tile Visibility binds {Binding Label, Converter={StaticResource MonitorTileVisibilityConverter}}
//  — the converter maps the tile's Label ("CPU"/"内存"/"磁盘"/"网络"/"温度"/"风扇转速") to the matching
//  flag here. Because a {Binding Label} only re-runs when Label changes, the SessionViewModel
//  re-issues the System-Monitor read after a flag flips (re-projecting the collection so the
//  converters re-evaluate). Real gating: a hidden metric's tile is removed from the grid.
// =====================================================================================

public sealed class MonitorDisplayPrefs
{
    public bool ShowCpu { get; set; } = true;
    public bool ShowMemory { get; set; } = true;
    public bool ShowDisk { get; set; } = true;
    public bool ShowNetwork { get; set; } = true;
    public bool ShowTemperature { get; set; } = true;
    public bool ShowFanSpeed { get; set; } = true;

    /// <summary>True when the metric named by <paramref name="label"/> should render. Unknown
    /// labels default to visible (never hide a metric we do not have a gate for).</summary>
    public bool IsVisible(string? label)
    {
        var l = (label ?? string.Empty).Trim().ToLowerInvariant();
        return l switch
        {
            _ when l.Contains("cpu") => ShowCpu,
            _ when l.Contains("内存") || l.Contains("memory") => ShowMemory,
            _ when l.Contains("磁盘") || l.Contains("disk") => ShowDisk,
            _ when l.Contains("网络") || l.Contains("network") => ShowNetwork,
            _ when l.Contains("温度") || l.Contains("temp") => ShowTemperature,
            _ when l.Contains("风扇") || l.Contains("fan") => ShowFanSpeed,
            _ => true
        };
    }
}

/// <summary>
/// Maps a System-Monitor tile's <c>Label</c> to <see cref="Visibility"/> by consulting the live
/// per-metric show-flags on the <see cref="MonitorDisplayPrefs"/> app resource. Visible when the
/// metric's flag is on (or unknown); Collapsed when the user turned that metric off in Settings.
/// Pure view-state — never invents a metric. The SessionViewModel re-projects the tile collection
/// after a flag flips so this converter re-runs.
/// </summary>
public sealed class MonitorTileVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var prefs = ResolvePrefs();
        var visible = prefs is null || prefs.IsVisible(value as string);
        return visible ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();

    private static MonitorDisplayPrefs? ResolvePrefs()
    {
        try
        {
            var resources = Application.Current?.Resources;
            if (resources is not null &&
                resources.TryGetValue("MonitorDisplayPrefs", out var value) &&
                value is MonitorDisplayPrefs prefs)
            {
                return prefs;
            }
        }
        catch (Exception)
        {
            // No realized application/resources (test host) — treat all metrics visible.
        }

        return null;
    }
}
