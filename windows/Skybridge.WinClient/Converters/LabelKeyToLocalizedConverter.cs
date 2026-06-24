using System;
using System.Collections.Generic;
using System.Globalization;
using Microsoft.UI.Xaml.Data;

namespace Skybridge.WinClient.Converters;

/// <summary>
/// Localizes the System Monitor data-bound LABEL/STATE/CAPTION strings (the indicator-pill
/// Label + State, the metric-tile Label, and the metric-tile short caption) at the BINDING
/// layer only -- without ever touching the canonical English literals the providers emit.
///
/// WHY a binding-layer converter and NOT localized backing fields (same rationale as the
/// sibling <see cref="StatusKeyToLocalizedConverter"/>):
///   SystemMonitorWorkspaceClient builds its indicator/metric rows with canonical English
///   literals -- the indicator <c>Label</c>s ("Health"/"Monitoring"/"Advanced"/"Thermal"/
///   "Load"), the indicator <c>State</c>s ("Healthy"/"Caution"/"Network offline"/"Active"/
///   "Idle"/"Read-only"/"Off"/"Unknown"/"Nominal"), and the metric <c>Label</c>s
///   ("CPU"/"Memory"/"Disk"/"Network"). The CI parity gate
///   (Scripts/verify-windows-ui-parity.ps1) asserts those exact literals are PRESENT in the
///   System Monitor source/markup (e.g. the "CPU"/"Memory"/"GPU"/"Thermal"/"Helper"/"Network"/
///   "Monitoring" signals checked against $systemMonitor + $mainWindow). Changing the
///   field/value would break the gate. So the canonical English string stays the source of
///   truth and we translate ONLY what the user sees.
///
/// Behaviour (identical contract to StatusKeyToLocalizedConverter):
///   - A KNOWN canonical English label/state/caption is mapped to its localized form for the
///     current UI language.
///   - Any UNKNOWN / dynamic string (honest live values such as "8 logical", "42.0%",
///     "C:\ 240 GB free") passes through VERBATIM -- we never swallow a real value.
///   - null / empty passes through unchanged.
///
/// The CAPTION map ("Processor"/"Working set"/"Storage"/"Adapters") is the human caption that
/// SystemMetricLabelToCaptionConverter derives from a metric Label; chain this converter after
/// it (or map both the raw Label and the caption here) so the sub-caption localizes too.
///
/// Language resolution and resw-first/dictionary-fallback resolution mirror
/// StatusKeyToLocalizedConverter exactly, so either path renders the same text and the
/// resw values + in-code table stay identical.
/// </summary>
public sealed class LabelKeyToLocalizedConverter : IValueConverter
{
    // Canonical English label/state/caption string -> resw key (also the in-code table key).
    // Ordinal, case-sensitive: the provider emits these exact spellings.
    private static readonly Dictionary<string, string> CanonicalToResourceKey =
        new(StringComparer.Ordinal)
        {
            // Indicator labels (SystemMonitorIndicators).
            ["Health"] = "SysMonLabel.Health",
            ["Monitoring"] = "SysMonLabel.Monitoring",
            ["Advanced"] = "SysMonLabel.Advanced",
            ["Thermal"] = "SysMonLabel.Thermal",
            ["Load"] = "SysMonLabel.Load",
            // Metric labels (SystemMonitorOverview tiles). CPU/Memory/Disk/Network are
            // common acronyms but mapped so zh/ja can localize the human-facing tile label.
            ["CPU"] = "SysMonLabel.CPU",
            ["Memory"] = "SysMonLabel.Memory",
            ["Disk"] = "SysMonLabel.Disk",
            ["Network"] = "SysMonLabel.Network",
            // Indicator states (SystemMonitorIndicators.State).
            ["Healthy"] = "SysMonState.Healthy",
            ["Caution"] = "SysMonState.Caution",
            ["Network offline"] = "SysMonState.NetworkOffline",
            ["Active"] = "SysMonState.Active",
            ["Idle"] = "SysMonState.Idle",
            ["Read-only"] = "SysMonState.ReadOnly",
            ["Off"] = "SysMonState.Off",
            ["Unknown"] = "SysMonState.Unknown",
            ["Nominal"] = "SysMonState.Nominal",
            // Metric-tile captions (output of SystemMetricLabelToCaptionConverter).
            ["Processor"] = "SysMonCaption.Processor",
            ["Working set"] = "SysMonCaption.WorkingSet",
            ["Storage"] = "SysMonCaption.Storage",
            ["Adapters"] = "SysMonCaption.Adapters",
            // Sidebar nav titles (FeatureCatalogClient feeds FeatureEntry.Title as the canonical
            // English key; FeatureCatalogClient localizes the rendered Title through Localize()).
            ["Dashboard"] = "Nav.Dashboard",
            ["Device Discovery"] = "Nav.DeviceDiscovery",
            ["USB Management"] = "Nav.UsbManagement",
            ["File Transfer"] = "Nav.FileTransfer",
            ["Remote Desktop"] = "Nav.RemoteDesktop",
            ["System Monitor"] = "Nav.SystemMonitor",
            ["Settings"] = "Nav.Settings",
            // NOTE: the Settings left sub-nav tab names are NOT in this string-keyed map. Two of
            // them ("Advanced", "Network") collide with SysMon indicator/metric labels above that
            // want a DIFFERENT translation, so settings tabs resolve by SettingsTab.* RESOURCE KEY
            // via LocalizeByResourceKey (see SettingsTabResourceKey + the SettingsTab.* fallback
            // rows below). "Dashboard"/"File Transfer"/"Remote Desktop"/"System Monitor"/"Settings"
            // are unambiguous and shared with the Nav.* keys (identical text).
            // ---- Settings Actions row Titles (SettingsActionItem.Title; the VISIBLE "Settings
            // Actions" list rendered by MainWindow's SettingsActionRowTemplate). The canonical
            // English Title stays the model value (the SettingsWorkspaceClient source + gate read
            // the Key/action ids, NOT these display Titles); only the displayed text is localized.
            ["Export settings"] = "SettingsAction.ExportSettings",
            ["Import settings"] = "SettingsAction.ImportSettings",
            ["Reset settings"] = "SettingsAction.ResetSettings",
            ["Refresh Status"] = "SettingsAction.RefreshStatus",
            ["Request Permission"] = "SettingsAction.RequestPermission",
            ["Open System Preferences"] = "SettingsAction.OpenSystemPreferences",
            ["Apply file transfer settings"] = "SettingsAction.ApplyFileTransferSettings",
            ["Apply remote desktop settings"] = "SettingsAction.ApplyRemoteDesktopSettings",
            ["Restore Defaults"] = "SettingsAction.RestoreDefaults",
            ["Reset Monitor Data"] = "SettingsAction.ResetMonitorData",
            ["Clear History Data"] = "SettingsAction.ClearHistoryData",
            // ---- Settings detail Section names (SettingsDetailItem.Section; the flat read-only
            // mirror rendered by SettingsDetailRowTemplate). Section text mirrors the SettingsTab.*
            // / Nav.* tab names; map them so the Section column localizes too. The canonical English
            // Section stays the model value (it is also the SettingsTabKeyVisibilityConverter group
            // key). "Devices"/"File Transfer"/"Remote Desktop"/"System Monitor" reuse Nav.* / tab keys.
            ["General"] = "SettingsTab.General",
            ["Devices"] = "SettingsTab.Devices",
            ["Permissions"] = "SettingsTab.Permissions",
            // NOTE: "Network"/"Advanced" Section names intentionally NOT added here -- they collide
            // with the SysMon indicator/metric labels above that want a different translation. The
            // collapsed flat-mirror detail rows are not user-visible, so leaving those two Sections
            // English in that hidden block is harmless; the visible tab nav localizes via
            // LocalizeSettingsTab (SettingsTab.* keys) which already handles them correctly.
        };

    // Settings left sub-nav tab Title (stable English key) -> SettingsTab.* / Nav.* resource key.
    // Kept SEPARATE from the string map above so the colliding "Advanced"/"Network" tab names get
    // their own (tab-specific) translation instead of the SysMon indicator/metric one.
    private static readonly Dictionary<string, string> SettingsTabResourceKey =
        new(StringComparer.Ordinal)
        {
            ["General"] = "SettingsTab.General",
            ["Network"] = "SettingsTab.Network",
            ["Devices"] = "SettingsTab.Devices",
            ["File Transfer"] = "Nav.FileTransfer",
            ["Remote Desktop"] = "Nav.RemoteDesktop",
            ["System Monitor"] = "Nav.SystemMonitor",
            ["Permissions"] = "SettingsTab.Permissions",
            ["Advanced"] = "SettingsTab.Advanced",
        };

    // In-code trilingual fallback, keyed by resource key then language fold ("en"/"zh"/"ja").
    // Mirrors Strings/{en-US,zh-Hans,ja}/Resources.resw values exactly.
    private static readonly Dictionary<string, Dictionary<string, string>> FallbackTable =
        new(StringComparer.Ordinal)
        {
            ["SysMonLabel.Health"] = new() { ["en"] = "Health", ["zh"] = "健康", ["ja"] = "ヘルス" },
            ["SysMonLabel.Monitoring"] = new() { ["en"] = "Monitoring", ["zh"] = "监控", ["ja"] = "監視" },
            ["SysMonLabel.Advanced"] = new() { ["en"] = "Advanced", ["zh"] = "高级", ["ja"] = "詳細" },
            ["SysMonLabel.Thermal"] = new() { ["en"] = "Thermal", ["zh"] = "热量", ["ja"] = "温度" },
            ["SysMonLabel.Load"] = new() { ["en"] = "Load", ["zh"] = "负载", ["ja"] = "負荷" },
            ["SysMonLabel.CPU"] = new() { ["en"] = "CPU", ["zh"] = "处理器", ["ja"] = "CPU" },
            ["SysMonLabel.Memory"] = new() { ["en"] = "Memory", ["zh"] = "内存", ["ja"] = "メモリ" },
            ["SysMonLabel.Disk"] = new() { ["en"] = "Disk", ["zh"] = "磁盘", ["ja"] = "ディスク" },
            ["SysMonLabel.Network"] = new() { ["en"] = "Network", ["zh"] = "网络", ["ja"] = "ネットワーク" },
            ["SysMonState.Healthy"] = new() { ["en"] = "Healthy", ["zh"] = "良好", ["ja"] = "正常" },
            ["SysMonState.Caution"] = new() { ["en"] = "Caution", ["zh"] = "注意", ["ja"] = "注意" },
            ["SysMonState.NetworkOffline"] = new() { ["en"] = "Network offline", ["zh"] = "网络离线", ["ja"] = "ネットワークオフライン" },
            ["SysMonState.Active"] = new() { ["en"] = "Active", ["zh"] = "活动中", ["ja"] = "稼働中" },
            ["SysMonState.Idle"] = new() { ["en"] = "Idle", ["zh"] = "空闲", ["ja"] = "アイドル" },
            ["SysMonState.ReadOnly"] = new() { ["en"] = "Read-only", ["zh"] = "只读", ["ja"] = "読み取り専用" },
            ["SysMonState.Off"] = new() { ["en"] = "Off", ["zh"] = "关闭", ["ja"] = "オフ" },
            ["SysMonState.Unknown"] = new() { ["en"] = "Unknown", ["zh"] = "未知", ["ja"] = "不明" },
            ["SysMonState.Nominal"] = new() { ["en"] = "Nominal", ["zh"] = "正常", ["ja"] = "正常" },
            ["SysMonCaption.Processor"] = new() { ["en"] = "Processor", ["zh"] = "处理器", ["ja"] = "プロセッサ" },
            ["SysMonCaption.WorkingSet"] = new() { ["en"] = "Working set", ["zh"] = "工作集", ["ja"] = "ワーキングセット" },
            ["SysMonCaption.Storage"] = new() { ["en"] = "Storage", ["zh"] = "存储", ["ja"] = "ストレージ" },
            ["SysMonCaption.Adapters"] = new() { ["en"] = "Adapters", ["zh"] = "适配器", ["ja"] = "アダプター" },
            // Sidebar nav titles (mirror the Mac NavigationItem.localizedTitle).
            ["Nav.Dashboard"] = new() { ["en"] = "Dashboard", ["zh"] = "主控台", ["ja"] = "ダッシュボード" },
            ["Nav.DeviceDiscovery"] = new() { ["en"] = "Device Discovery", ["zh"] = "设备发现", ["ja"] = "デバイス検出" },
            ["Nav.UsbManagement"] = new() { ["en"] = "USB Management", ["zh"] = "USB 管理", ["ja"] = "USB 管理" },
            ["Nav.FileTransfer"] = new() { ["en"] = "File Transfer", ["zh"] = "文件传输", ["ja"] = "ファイル転送" },
            ["Nav.RemoteDesktop"] = new() { ["en"] = "Remote Desktop", ["zh"] = "远程桌面", ["ja"] = "リモートデスクトップ" },
            ["Nav.SystemMonitor"] = new() { ["en"] = "System Monitor", ["zh"] = "系统监控", ["ja"] = "システムモニター" },
            ["Nav.Settings"] = new() { ["en"] = "Settings", ["zh"] = "设置", ["ja"] = "設定" },
            // Settings left sub-nav tab names (mirror the Mac SettingsView tab localizedName).
            ["SettingsTab.General"] = new() { ["en"] = "General", ["zh"] = "通用", ["ja"] = "一般" },
            ["SettingsTab.Network"] = new() { ["en"] = "Network", ["zh"] = "网络", ["ja"] = "ネットワーク" },
            ["SettingsTab.Devices"] = new() { ["en"] = "Devices", ["zh"] = "设备", ["ja"] = "デバイス" },
            ["SettingsTab.Permissions"] = new() { ["en"] = "Permissions", ["zh"] = "权限", ["ja"] = "権限" },
            ["SettingsTab.Advanced"] = new() { ["en"] = "Advanced", ["zh"] = "高级", ["ja"] = "詳細設定" },
            // Settings Actions row Titles (mirror the Mac SettingsView action labels).
            ["SettingsAction.ExportSettings"] = new() { ["en"] = "Export settings", ["zh"] = "导出设置", ["ja"] = "設定をエクスポート" },
            ["SettingsAction.ImportSettings"] = new() { ["en"] = "Import settings", ["zh"] = "导入设置", ["ja"] = "設定をインポート" },
            ["SettingsAction.ResetSettings"] = new() { ["en"] = "Reset settings", ["zh"] = "重置设置", ["ja"] = "設定をリセット" },
            ["SettingsAction.RefreshStatus"] = new() { ["en"] = "Refresh Status", ["zh"] = "刷新状态", ["ja"] = "ステータスを更新" },
            ["SettingsAction.RequestPermission"] = new() { ["en"] = "Request Permission", ["zh"] = "请求权限", ["ja"] = "権限をリクエスト" },
            ["SettingsAction.OpenSystemPreferences"] = new() { ["en"] = "Open System Preferences", ["zh"] = "打开系统设置", ["ja"] = "システム設定を開く" },
            ["SettingsAction.ApplyFileTransferSettings"] = new() { ["en"] = "Apply file transfer settings", ["zh"] = "应用文件传输设置", ["ja"] = "ファイル転送設定を適用" },
            ["SettingsAction.ApplyRemoteDesktopSettings"] = new() { ["en"] = "Apply remote desktop settings", ["zh"] = "应用远程桌面设置", ["ja"] = "リモートデスクトップ設定を適用" },
            ["SettingsAction.RestoreDefaults"] = new() { ["en"] = "Restore Defaults", ["zh"] = "恢复默认", ["ja"] = "既定値に戻す" },
            ["SettingsAction.ResetMonitorData"] = new() { ["en"] = "Reset Monitor Data", ["zh"] = "重置监控数据", ["ja"] = "監視データをリセット" },
            ["SettingsAction.ClearHistoryData"] = new() { ["en"] = "Clear History Data", ["zh"] = "清除历史数据", ["ja"] = "履歴データを消去" },
        };

    // Lazily-created MRT Core manager (shared; cheap to reuse). null if construction fails.
    private static Microsoft.Windows.ApplicationModel.Resources.ResourceManager? _resourceManager;
    private static bool _resourceManagerTried;

    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var input = value as string;
        if (string.IsNullOrEmpty(input))
        {
            return value ?? string.Empty;
        }

        return Localize(input);
    }

    /// <summary>
    /// Localizes one canonical English label/state/caption string to the active UI language,
    /// passing through any unknown/dynamic value verbatim. Exposed as a static so sibling
    /// converters (e.g. SystemMetricLabelToCaptionConverter, which derives the English caption
    /// from a metric Label) can reuse the SAME resw-first/dictionary-fallback table instead of
    /// duplicating the resolution logic -- XAML cannot chain two converters on one binding.
    /// </summary>
    public static string Localize(string input)
    {
        if (string.IsNullOrEmpty(input))
        {
            return input;
        }

        // Unknown / dynamic value -> pass through untouched (honest live values survive).
        if (!CanonicalToResourceKey.TryGetValue(input, out var resourceKey))
        {
            return input;
        }

        var lang = ResolveLanguageFold();

        // resw-first: try the indexed resources.pri under the resolved language.
        var fromResw = TryResolveFromResw(resourceKey, lang);
        if (!string.IsNullOrEmpty(fromResw))
        {
            return fromResw!;
        }

        // Dictionary fallback (always yields a value for a known key).
        if (FallbackTable.TryGetValue(resourceKey, out var perLang) &&
            (perLang.TryGetValue(lang, out var localized) || perLang.TryGetValue("en", out localized)))
        {
            return localized;
        }

        // Last resort: the canonical English the caller passed in.
        return input;
    }

    /// <summary>
    /// Localizes the Settings left sub-nav tab name from its stable English tab Title to the
    /// active UI language. Kept separate from <see cref="Localize"/> because two tab names
    /// ("Advanced", "Network") collide with SysMon indicator/metric labels that want a different
    /// translation; this resolves through a tab-specific Title -> resource-key map. Unknown tab
    /// titles pass through verbatim (honest fallback). Used by SettingsTabItemView.DisplayName.
    /// </summary>
    public static string LocalizeSettingsTab(string title)
    {
        if (string.IsNullOrEmpty(title))
        {
            return title;
        }

        if (!SettingsTabResourceKey.TryGetValue(title, out var resourceKey))
        {
            return title;
        }

        return LocalizeByResourceKey(resourceKey, title);
    }

    /// <summary>
    /// Resolves one resource key (e.g. "SettingsTab.General") to the active UI language using the
    /// SAME resw-first / dictionary-fallback path as <see cref="Localize"/>, falling back to the
    /// supplied English text if neither source has the key. Lets callers that already know the
    /// resource key (rather than a canonical English string) reuse the shared resolution.
    /// </summary>
    public static string LocalizeByResourceKey(string resourceKey, string fallbackEnglish)
    {
        if (string.IsNullOrEmpty(resourceKey))
        {
            return fallbackEnglish;
        }

        var lang = ResolveLanguageFold();

        var fromResw = TryResolveFromResw(resourceKey, lang);
        if (!string.IsNullOrEmpty(fromResw))
        {
            return fromResw!;
        }

        if (FallbackTable.TryGetValue(resourceKey, out var perLang) &&
            (perLang.TryGetValue(lang, out var localized) || perLang.TryGetValue("en", out localized)))
        {
            return localized;
        }

        return fallbackEnglish;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }

    // Fold the active UI language to one of "zh" / "ja" / "en".
    private static string ResolveLanguageFold()
    {
        string? tag = null;
        try
        {
            var over = Microsoft.Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride;
            if (!string.IsNullOrWhiteSpace(over))
            {
                tag = over;
            }
        }
        catch (Exception)
        {
            // Runtime not ready / unsupported -- fall through to the culture below.
        }

        if (string.IsNullOrWhiteSpace(tag))
        {
            try
            {
                tag = CultureInfo.CurrentUICulture.Name;
            }
            catch (Exception)
            {
                tag = "en";
            }
        }

        tag = (tag ?? "en").Trim().ToLowerInvariant();
        if (tag.StartsWith("zh", StringComparison.Ordinal))
        {
            return "zh";
        }
        if (tag.StartsWith("ja", StringComparison.Ordinal))
        {
            return "ja";
        }
        return "en";
    }

    // Returns the resw value for the requested language fold, or null on any failure.
    private static string? TryResolveFromResw(string resourceKey, string langFold)
    {
        var manager = GetResourceManager();
        if (manager is null)
        {
            return null;
        }

        try
        {
            var context = manager.CreateResourceContext();
            var bcp47 = langFold switch
            {
                "zh" => "zh-Hans",
                "ja" => "ja",
                _ => "en-US",
            };
            context.QualifierValues["Language"] = bcp47;

            var candidate = manager.MainResourceMap.TryGetValue("Resources/" + resourceKey, context);
            var text = candidate?.ValueAsString;
            return string.IsNullOrEmpty(text) ? null : text;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static Microsoft.Windows.ApplicationModel.Resources.ResourceManager? GetResourceManager()
    {
        if (_resourceManagerTried)
        {
            return _resourceManager;
        }

        _resourceManagerTried = true;
        try
        {
            _resourceManager = new Microsoft.Windows.ApplicationModel.Resources.ResourceManager();
        }
        catch (Exception)
        {
            _resourceManager = null;
        }
        return _resourceManager;
    }
}
