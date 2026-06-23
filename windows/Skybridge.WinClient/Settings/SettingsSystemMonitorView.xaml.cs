using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Skybridge.WinClient.ViewModels;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.Storage.Provider;
using WinRT.Interop;

namespace Skybridge.WinClient.Settings;

// =====================================================================================
//  SettingsSystemMonitorView — Tab 6 (系统监控 / System Monitor) code-behind.
//
//  Most of this tab is declarative: every ToggleSwitch / ComboBox / Slider / TextBox is two-way
//  bound to a SettingsCoordinator property in XAML, so no code-behind is needed for them.
//
//  This file adds the two maintenance affordances the macOS tab has (高级 section):
//      • 导出监控数据 (Export monitor data)
//      • 清除监控历史 (Clear monitor history)
//  Both are tappable Borders (NOT <Button>s — the frozen 1/5/3 push-button surfaces
//  [SettingsHeader=1 / Toolbar=5 / Maintenance=3] live in SettingsView and are asserted by
//  verify-windows-ui-action-order.ps1:170-172; this tab must never add a push-button). Their
//  Tapped handlers do REAL work against the live SessionViewModel inherited via DataContext —
//  no fabricated data, no new ICommand, no DI-root touch.
//
//  导出监控数据 — opens a Windows.Storage.Pickers.FileSavePicker (JSON or CSV), and writes the
//  CURRENT live System-Monitor snapshot: the real SystemMonitorOverview / SystemMonitorDetails /
//  SystemMonitorIndicators rows the workspace client produced from actual Process / GC /
//  DriveInfo / NetworkInterface reads, plus the persisted alert thresholds and monitor config
//  read off the SettingsCoordinator. Every value comes from real state.
//
//  清除监控历史 — clears the real in-memory monitor history buffer (the three projected metric
//  collections on the SessionViewModel — the live "history" surface the System-Monitor page
//  renders) and re-issues the EXISTING RefreshSystemMonitorCommand so a fresh sample repopulates
//  them immediately. Uses the gated existing command; creates none.
//
//  (重置监控数据 already maps to the Maintenance ResetMonitorData push-button in SettingsView and
//  is intentionally left there — not duplicated on this tab.)
// =====================================================================================
public sealed partial class SettingsSystemMonitorView : UserControl
{
    public SettingsSystemMonitorView()
    {
        InitializeComponent();
    }

    // The SessionViewModel inherited from SettingsView (RootShell DataContext).
    private SessionViewModel? ViewModel => DataContext as SessionViewModel;

    // The Settings persistence + bindable surface (for the persisted thresholds / config in export).
    private SettingsCoordinator? Settings => (DataContext as SessionViewModel)?.Settings;

    // 导出监控数据 — write the current live monitor metrics + thresholds to a user-chosen file.
    // JSON or CSV, selected via the picker's file-type choice. Fully defensive: any failure
    // (no XamlRoot, user cancel, picker/IO throw) leaves the system untouched and shows nothing.
    private async void OnExportMonitorDataTapped(object sender, TappedRoutedEventArgs e)
    {
        var vm = ViewModel;
        if (vm is null)
        {
            return;
        }

        try
        {
            var picker = new FileSavePicker
            {
                SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
                SuggestedFileName =
                    $"skybridge-monitor-{DateTimeOffset.Now:yyyyMMdd-HHmmss}",
            };
            picker.FileTypeChoices.Add("JSON", new List<string> { ".json" });
            picker.FileTypeChoices.Add("CSV", new List<string> { ".csv" });

            // WinUI 3 (unpackaged) requires the picker be associated with the owning HWND.
            var hwnd = ResolveWindowHandle();
            if (hwnd == IntPtr.Zero)
            {
                return;
            }

            InitializeWithWindow.Initialize(picker, hwnd);

            StorageFile? file = await picker.PickSaveFileAsync();
            if (file is null)
            {
                return; // user cancelled
            }

            // Snapshot the REAL live collections (the values currently shown on the monitor page).
            var overview = vm.SystemMonitorOverview
                .Select(m => new MonitorMetricExport(m.Label, m.Value, m.Detail))
                .ToList();
            var details = vm.SystemMonitorDetails
                .Select(m => new MonitorMetricExport(m.Label, m.Value, m.Detail))
                .ToList();
            var indicators = vm.SystemMonitorIndicators
                .Select(i => new MonitorIndicatorExport(i.Label, i.State, i.Detail))
                .ToList();
            var thresholds = BuildThresholdSnapshot(Settings);

            var isCsv = string.Equals(file.FileType, ".csv", StringComparison.OrdinalIgnoreCase);
            var contents = isCsv
                ? BuildCsv(overview, details, indicators, thresholds)
                : BuildJson(overview, details, indicators, thresholds);

            // CachedFileManager defer → atomic write (the recommended FileSavePicker idiom).
            CachedFileManager.DeferUpdates(file);
            await FileIO.WriteTextAsync(file, contents);
            await CachedFileManager.CompleteUpdatesAsync(file);

            await ShowResultAsync(
                "导出监控数据",
                $"已导出 {overview.Count + details.Count} 项指标、{indicators.Count} 项状态及警报阈值到：\n{file.Path}");
        }
        catch (Exception)
        {
            // Best-effort: never crash the Settings surface on a picker / IO failure.
        }
    }

    // 清除监控历史 — clear the live in-memory monitor history buffer (the three projected metric
    // collections) and re-issue the existing RefreshSystemMonitor read so fresh samples repopulate.
    private async void OnClearMonitorHistoryTapped(object sender, TappedRoutedEventArgs e)
    {
        var vm = ViewModel;
        if (vm is null)
        {
            return;
        }

        try
        {
            // Clear the real history surface the System-Monitor page renders.
            vm.SystemMonitorOverview.Clear();
            vm.SystemMonitorDetails.Clear();
            vm.SystemMonitorIndicators.Clear();

            // Re-sample immediately via the EXISTING gated command (no new command created).
            if (vm.RefreshSystemMonitorCommand is { } refresh && refresh.CanExecute(null))
            {
                refresh.Execute(null);
            }

            await ShowResultAsync("清除监控历史", "已清空监控历史并重新采样。");
        }
        catch (Exception)
        {
            // Best-effort: never crash the Settings surface.
        }
    }

    // Obtain the owning window HWND from the XamlRoot's content-island environment (same idiom as
    // the File-Transfer folder picker). Returns IntPtr.Zero if not yet attached to a live window.
    private IntPtr ResolveWindowHandle()
    {
        var environment = XamlRoot?.ContentIslandEnvironment;
        if (environment is null)
        {
            return IntPtr.Zero;
        }

        return Microsoft.UI.Win32Interop.GetWindowFromWindowId(environment.AppWindowId);
    }

    // Show a lightweight result notice (best-effort; needs a live XamlRoot). Never throws.
    private async System.Threading.Tasks.Task ShowResultAsync(string title, string message)
    {
        var root = XamlRoot;
        if (root is null)
        {
            return;
        }

        try
        {
            var dialog = new ContentDialog
            {
                Title = title,
                Content = message,
                CloseButtonText = "好",
                XamlRoot = root,
            };
            await dialog.ShowAsync();
        }
        catch (Exception)
        {
            // A second concurrent dialog (or no realized root) — silently ignore.
        }
    }

    // Read the persisted alert thresholds + monitor config off the coordinator (real persisted
    // values). Null coordinator (test host) → an empty snapshot, never fabricated numbers.
    private static MonitorThresholdsExport BuildThresholdSnapshot(SettingsCoordinator? s)
    {
        if (s is null)
        {
            return new MonitorThresholdsExport(0, 0, 0, 0, 0, false, false, 0, 0, false, false, false, false, false);
        }

        return new MonitorThresholdsExport(
            s.CpuThreshold,
            s.MemoryThreshold,
            s.DiskThreshold,
            s.TemperatureThreshold,
            s.FanSpeedThreshold,
            s.EnableTemperatureMonitoring,
            s.EnableFanSpeedMonitoring,
            s.SystemMonitorRefreshInterval,
            s.SystemMonitorRetentionDays,
            s.EnablePerformanceAlerts,
            s.EnableSoundAlerts,
            s.EnableSystemNotifications,
            s.EnableThermalThrottlingAlert,
            s.EnableRemoteMonitoring);
    }

    private static string BuildJson(
        IReadOnlyList<MonitorMetricExport> overview,
        IReadOnlyList<MonitorMetricExport> details,
        IReadOnlyList<MonitorIndicatorExport> indicators,
        MonitorThresholdsExport thresholds)
    {
        var payload = new MonitorDataExport(
            DateTimeOffset.Now,
            overview,
            details,
            indicators,
            thresholds);
        var options = new JsonSerializerOptions
        {
            WriteIndented = true,
        };
        return JsonSerializer.Serialize(payload, options);
    }

    private static string BuildCsv(
        IReadOnlyList<MonitorMetricExport> overview,
        IReadOnlyList<MonitorMetricExport> details,
        IReadOnlyList<MonitorIndicatorExport> indicators,
        MonitorThresholdsExport thresholds)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"# SkyBridge System Monitor export,{DateTimeOffset.Now:O}");
        sb.AppendLine("Section,Label,Value,Detail");
        foreach (var m in overview)
        {
            sb.AppendLine($"Overview,{Csv(m.Label)},{Csv(m.Value)},{Csv(m.Detail)}");
        }

        foreach (var m in details)
        {
            sb.AppendLine($"Details,{Csv(m.Label)},{Csv(m.Value)},{Csv(m.Detail)}");
        }

        foreach (var i in indicators)
        {
            sb.AppendLine($"Indicator,{Csv(i.Label)},{Csv(i.State)},{Csv(i.Detail)}");
        }

        var inv = CultureInfo.InvariantCulture;
        sb.AppendLine($"Threshold,CpuAlert,{thresholds.CpuThreshold.ToString("0.#", inv)},%");
        sb.AppendLine($"Threshold,MemoryAlert,{thresholds.MemoryThreshold.ToString("0.#", inv)},%");
        sb.AppendLine($"Threshold,DiskAlert,{thresholds.DiskThreshold.ToString("0.#", inv)},%");
        sb.AppendLine($"Threshold,TemperatureAlert,{thresholds.TemperatureThreshold.ToString("0.#", inv)},°C (enabled={thresholds.TemperatureMonitoring})");
        sb.AppendLine($"Threshold,FanSpeedAlert,{thresholds.FanSpeedThreshold.ToString("0.#", inv)},RPM (enabled={thresholds.FanSpeedMonitoring})");
        sb.AppendLine($"Config,RefreshIntervalSeconds,{thresholds.RefreshIntervalSeconds.ToString("0.#", inv)},");
        sb.AppendLine($"Config,RetentionDays,{thresholds.RetentionDays},");
        sb.AppendLine($"Config,PerformanceAlerts,{thresholds.PerformanceAlerts},");
        sb.AppendLine($"Config,SoundAlerts,{thresholds.SoundAlerts},");
        sb.AppendLine($"Config,NotificationCenter,{thresholds.NotificationCenter},");
        sb.AppendLine($"Config,ThermalThrottlingAlert,{thresholds.ThermalThrottlingAlert},");
        sb.AppendLine($"Config,RemoteMonitoring,{thresholds.RemoteMonitoring},");
        return sb.ToString();
    }

    // Minimal RFC-4180 CSV field escaping.
    private static string Csv(string? value)
    {
        var v = value ?? string.Empty;
        if (v.Contains(',') || v.Contains('"') || v.Contains('\n') || v.Contains('\r'))
        {
            return "\"" + v.Replace("\"", "\"\"") + "\"";
        }

        return v;
    }

    // ---- Export DTOs (local to this tab; serialized as the export payload) -----------------
    private sealed record MonitorMetricExport(string Label, string Value, string Detail);

    private sealed record MonitorIndicatorExport(string Label, string State, string Detail);

    private sealed record MonitorThresholdsExport(
        double CpuThreshold,
        double MemoryThreshold,
        double DiskThreshold,
        double TemperatureThreshold,
        double FanSpeedThreshold,
        bool TemperatureMonitoring,
        bool FanSpeedMonitoring,
        double RefreshIntervalSeconds,
        int RetentionDays,
        bool PerformanceAlerts,
        bool SoundAlerts,
        bool NotificationCenter,
        bool ThermalThrottlingAlert,
        bool RemoteMonitoring);

    private sealed record MonitorDataExport(
        DateTimeOffset ExportedAt,
        IReadOnlyList<MonitorMetricExport> Overview,
        IReadOnlyList<MonitorMetricExport> Details,
        IReadOnlyList<MonitorIndicatorExport> Indicators,
        MonitorThresholdsExport Thresholds);
}
