using System;
using System.ComponentModel;
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Skybridge.WinClient.ViewModels;

namespace Skybridge.WinClient.Settings;

// =====================================================================================
//  SettingsRemoteDesktopView — Tab 5 (远程桌面 / Remote Desktop) code-behind.
//
//  Most controls are declarative two-way {Binding Settings.<Prop>} to the SettingsCoordinator.
//  This code-behind adds the two pieces the Mac 画质与性能 block has that cannot be expressed as a
//  single bound key, doing REAL work against the EXISTING coordinator props (no new persisted key,
//  no fabricated data, no <Button> — only a RadioButtons group + read-only computed TextBlocks):
//
//   1) 预设方案 (平衡/高性能/高质量/低延迟) — a selectable RadioButtons group. OnPresetSelectionChanged
//      applies the SAME multi-key combo the Mac VideoTransferSettingsManager.applyPresetConfiguration
//      applies, writing the four existing coordinator props (VideoResolution / VideoFrameRate /
//      VideoCompressionQuality / EnableAdaptiveBitrate, plus EnableHardwareAcceleration=true). Those
//      setters persist + raise PropertyChanged exactly like the bound resolution / fps / compression
//      controls, so the cards above stay in sync.
//
//   2) Status header — 当前配置 summary · 已优化/需调整 badge · 预估传输率 (MB/s) · 负载 tier. All four
//      are recomputed by UpdateStatusHeader from the LIVE coordinator selection. The rate uses the
//      exact Mac formula (VideoTransferConfiguration.estimatedDataRate): base-rate(resolution) ×
//      fps/30 × compression-ratio, divided by 1024² to MB/s. 已优化/需调整 and the load tier mirror
//      the Mac thresholds (updateOptimalStatus / status.load.*). No fabricated numbers.
//
//  The header is kept current by subscribing to the coordinator's PropertyChanged (re-emitted from
//  the SettingsService) for the five source keys — so a manual resolution / fps / compression /
//  hardware-accel / adaptive-bitrate edit, a preset apply, or a bulk Import/Reset all refresh it.
//
//  DataContext inherits the SessionViewModel from SettingsView (the MainWindow RootShell).
// =====================================================================================
public sealed partial class SettingsRemoteDesktopView : UserControl
{
    private SettingsCoordinator? _coordinator;
    private bool _applyingPreset;

    public SettingsRemoteDesktopView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    // Resolve the SettingsCoordinator from the inherited DataContext (the SessionViewModel).
    private SettingsCoordinator? Settings => (DataContext as SessionViewModel)?.Settings;

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        var coordinator = Settings;
        if (coordinator is null)
        {
            return;
        }

        // Subscribe once (defensive against a re-Loaded without an intervening Unloaded).
        if (!ReferenceEquals(_coordinator, coordinator))
        {
            if (_coordinator is not null)
            {
                _coordinator.PropertyChanged -= OnCoordinatorPropertyChanged;
            }

            _coordinator = coordinator;
            _coordinator.PropertyChanged += OnCoordinatorPropertyChanged;
        }

        SyncPresetSelectionToCurrentConfig();
        UpdateStatusHeader();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (_coordinator is not null)
        {
            _coordinator.PropertyChanged -= OnCoordinatorPropertyChanged;
            _coordinator = null;
        }
    }

    private void OnCoordinatorPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        // A null/empty name is a bulk change (Import / Reset) — refresh everything. Otherwise only
        // the five keys that feed the status header / preset reflection matter here.
        var name = e.PropertyName;
        if (string.IsNullOrEmpty(name)
            || name == nameof(SettingsCoordinator.VideoResolution)
            || name == nameof(SettingsCoordinator.VideoFrameRate)
            || name == nameof(SettingsCoordinator.VideoCompressionQuality)
            || name == nameof(SettingsCoordinator.EnableHardwareAcceleration)
            || name == nameof(SettingsCoordinator.EnableAdaptiveBitrate))
        {
            // Re-marshal in case the change was raised off the UI thread (bulk import path).
            if (DispatcherQueue is { } queue && !queue.HasThreadAccess)
            {
                queue.TryEnqueue(() =>
                {
                    SyncPresetSelectionToCurrentConfig();
                    UpdateStatusHeader();
                });
                return;
            }

            SyncPresetSelectionToCurrentConfig();
            UpdateStatusHeader();
        }
    }

    // =================================================================================
    //  预设方案 — apply the real Mac preset combo to the EXISTING coordinator props.
    // =================================================================================
    private void OnPresetSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        // Ignore the programmatic re-selection done by SyncPresetSelectionToCurrentConfig.
        if (_applyingPreset)
        {
            return;
        }

        var coordinator = Settings;
        if (coordinator is null || PresetGroup?.SelectedItem is not RadioButton { Tag: string presetTag })
        {
            return;
        }

        ApplyPreset(coordinator, presetTag);
        // UpdateStatusHeader is driven by the coordinator PropertyChanged the setters raise.
    }

    // Mirrors VideoTransferSettingsManager.applyPresetConfiguration (macSpec line 143 / the Mac
    // applyPresetConfiguration switch). Each preset sets resolution + frameRate + compression +
    // adaptiveBitrate, and forces hardware acceleration on (Apple-Silicon optimization is the
    // OMIT-APPLE-ONLY row and is not represented on Windows).
    private static void ApplyPreset(SettingsCoordinator coordinator, string presetTag)
    {
        switch (presetTag)
        {
            case "balanced":
                coordinator.VideoResolution = "hd1080p";
                coordinator.VideoFrameRate = "fps30";
                coordinator.VideoCompressionQuality = "balanced";
                coordinator.EnableAdaptiveBitrate = true;
                break;
            case "highPerformance":
                coordinator.VideoResolution = "apple5k";
                coordinator.VideoFrameRate = "fps120";
                coordinator.VideoCompressionQuality = "fast";
                coordinator.EnableAdaptiveBitrate = true;
                break;
            case "highQuality":
                coordinator.VideoResolution = "uhd4k";
                coordinator.VideoFrameRate = "fps60";
                coordinator.VideoCompressionQuality = "maximum";
                coordinator.EnableAdaptiveBitrate = false;
                break;
            case "lowLatency":
                coordinator.VideoResolution = "hd1080p";
                coordinator.VideoFrameRate = "fps60";
                coordinator.VideoCompressionQuality = "fast";
                coordinator.EnableAdaptiveBitrate = true;
                break;
            default:
                return;
        }

        coordinator.EnableHardwareAcceleration = true;
    }

    // Highlight the preset whose combo exactly matches the current selection (so the group reflects
    // a preset chosen earlier or restored from disk, and clears when the user diverges). Guarded so
    // the programmatic selection does not re-trigger ApplyPreset.
    private void SyncPresetSelectionToCurrentConfig()
    {
        if (PresetGroup is null)
        {
            return;
        }

        var coordinator = Settings;
        var matched = coordinator is null ? null : MatchPreset(coordinator);

        _applyingPreset = true;
        try
        {
            if (matched is null)
            {
                PresetGroup.SelectedIndex = -1;
                return;
            }

            for (var i = 0; i < PresetGroup.Items.Count; i++)
            {
                if (PresetGroup.Items[i] is RadioButton { Tag: string tag } && tag == matched)
                {
                    PresetGroup.SelectedIndex = i;
                    return;
                }
            }

            PresetGroup.SelectedIndex = -1;
        }
        finally
        {
            _applyingPreset = false;
        }
    }

    // Return the preset tag whose combo matches the current coordinator selection, or null.
    private static string? MatchPreset(SettingsCoordinator c)
    {
        var res = c.VideoResolution;
        var fps = c.VideoFrameRate;
        var comp = c.VideoCompressionQuality;
        var adaptive = c.EnableAdaptiveBitrate;
        var hwOn = c.EnableHardwareAcceleration;

        // Hardware acceleration is on for every preset; a divergent value means "custom".
        if (!hwOn)
        {
            return null;
        }

        if (res == "hd1080p" && fps == "fps30" && comp == "balanced" && adaptive)
        {
            return "balanced";
        }

        if (res == "apple5k" && fps == "fps120" && comp == "fast" && adaptive)
        {
            return "highPerformance";
        }

        if (res == "uhd4k" && fps == "fps60" && comp == "maximum" && !adaptive)
        {
            return "highQuality";
        }

        if (res == "hd1080p" && fps == "fps60" && comp == "fast" && adaptive)
        {
            return "lowLatency";
        }

        return null;
    }

    // =================================================================================
    //  Status header — computed read-only summary / badge / estimated rate / load tier.
    // =================================================================================
    private void UpdateStatusHeader()
    {
        var coordinator = Settings;
        if (coordinator is null
            || ConfigSummaryText is null
            || StatusBadge is null
            || StatusBadgeText is null
            || EstimatedRateText is null
            || LoadTierText is null)
        {
            return;
        }

        var res = coordinator.VideoResolution;
        var fps = coordinator.VideoFrameRate;
        var comp = coordinator.VideoCompressionQuality;
        var hwOn = coordinator.EnableHardwareAcceleration;
        var adaptive = coordinator.EnableAdaptiveBitrate;

        // 当前配置 summary: "1080P (Full HD) · 30 fps · 平衡压缩 [· 硬件加速 · 自适应比特率]".
        var summary = $"{ResolutionDisplayName(res)} · {FrameRateDisplayName(fps)} · {CompressionDisplayName(comp)}";
        if (hwOn)
        {
            summary += " · 硬件加速";
        }

        if (adaptive)
        {
            summary += " · 自适应比特率";
        }

        ConfigSummaryText.Text = summary;

        // 预估传输率 — exact Mac formula: base-rate(res) × (fps/30) × compression-ratio, → MB/s.
        var baseRateBytesPerSec = ResolutionBaseRate(res);
        var rateBytesPerSec = baseRateBytesPerSec * FrameRateMultiplier(fps) * CompressionRatio(comp);
        var rateMbps = rateBytesPerSec / (1024.0 * 1024.0);
        EstimatedRateText.Text = string.Format(CultureInfo.InvariantCulture, "{0:0.0} MB/s", rateMbps);

        // 负载 tier (Mac status.load.*): >10 高, >5 中, else 低.
        string loadLabel;
        Brush loadBrush;
        if (rateMbps > 10.0)
        {
            loadLabel = "负载 高";
            loadBrush = WarningBrush;
        }
        else if (rateMbps > 5.0)
        {
            loadLabel = "负载 中";
            loadBrush = AccentBrush;
        }
        else
        {
            loadLabel = "负载 低";
            loadBrush = SuccessBrush;
        }

        LoadTierText.Text = loadLabel;
        LoadTierText.Foreground = loadBrush;

        // 已优化 / 需调整 — mirrors the Mac updateOptimalStatus thresholds: not optimal if the rate
        // is too high, hardware-accel is off, 4K@60 with no compression, or adaptive-bitrate off.
        var isOptimal = true;
        if (rateMbps > 10.0)
        {
            isOptimal = false;
        }

        if (!hwOn)
        {
            isOptimal = false;
        }

        if (res == "uhd4k" && fps == "fps60" && comp == "none")
        {
            isOptimal = false;
        }

        if (!adaptive)
        {
            isOptimal = false;
        }

        if (isOptimal)
        {
            StatusBadgeText.Text = "已优化";
            StatusBadgeText.Foreground = SuccessBrush;
            StatusBadge.BorderBrush = SuccessBrush;
        }
        else
        {
            StatusBadgeText.Text = "需调整";
            StatusBadgeText.Foreground = WarningBrush;
            StatusBadge.BorderBrush = WarningBrush;
        }
    }

    // ---- Mac-faithful value maps (FileTransferModels.swift) --------------------------

    private static string ResolutionDisplayName(string tag) => tag switch
    {
        "hd1080p" => "1080P (Full HD)",
        "qhd2k" => "2K (QHD)",
        "uhd4k" => "4K (Ultra HD)",
        "apple5k" => "5K (Apple Retina)",
        _ => "1080P (Full HD)",
    };

    // Base data rate in bytes/sec (VideoTransferConfiguration.estimatedDataRate baseRate switch).
    private static double ResolutionBaseRate(string tag) => tag switch
    {
        "hd1080p" => 5_000_000d,
        "qhd2k" => 12_000_000d,
        "uhd4k" => 25_000_000d,
        "apple5k" => 40_000_000d,
        _ => 5_000_000d,
    };

    private static string FrameRateDisplayName(string tag) => tag switch
    {
        "fps30" => "30 fps",
        "fps60" => "60 fps",
        "fps120" => "120 fps",
        _ => "30 fps",
    };

    // VideoFrameRate.dataRateMultiplier = rawValue / 30.
    private static double FrameRateMultiplier(string tag) => tag switch
    {
        "fps30" => 30d / 30d,
        "fps60" => 60d / 30d,
        "fps120" => 120d / 30d,
        _ => 1d,
    };

    private static string CompressionDisplayName(string tag) => tag switch
    {
        "none" => "无压缩",
        "fast" => "快速压缩",
        "balanced" => "平衡压缩",
        "maximum" => "最大压缩",
        _ => "平衡压缩",
    };

    // VideoCompressionQuality.compressionRatio (1.0 = no compression).
    private static double CompressionRatio(string tag) => tag switch
    {
        "none" => 1.0,
        "fast" => 0.8,
        "balanced" => 0.6,
        "maximum" => 0.4,
        _ => 0.6,
    };

    // ---- Brush helpers (resolved from the app resources, like SettingsDevicesView) --
    private static Brush SuccessBrush => (Brush)Application.Current.Resources["SkyBridgeSuccessBrush"];
    private static Brush WarningBrush => (Brush)Application.Current.Resources["SkyBridgeWarningBrush"];
    private static Brush AccentBrush => (Brush)Application.Current.Resources["SkyBridgeAccentBrush"];
}
