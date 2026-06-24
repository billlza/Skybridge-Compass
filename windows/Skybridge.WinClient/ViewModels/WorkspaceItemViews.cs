using System;
using System.Collections.Generic;
using System.Windows.Input;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

// Left sub-nav row for the Settings two-pane layout (element-matches the Mac
// SettingsView sidebar: per-tab icon + title, selected = filled pill). The Glyph is
// derived deterministically from the (stable, English) tab Title so the row carries a
// Segoe Fluent Icons glyph that mirrors the Mac SF Symbol per tab. Title is the stable
// filter key the right pane groups against (Section == Title on every detail row).
public sealed record SettingsTabItemView(
    string Title,
    string Detail)
{
    public string Glyph => ResolveGlyph(Title);

    // The localized (zh) label shown in the left sub-nav. The Mac SettingsView sidebar
    // lists each tab by its localizedName (通用 / 网络 / 设备 / …) with NO subtitle; the
    // Windows port mirrors that exactly. Title stays the stable English key (the
    // SettingsTabKeyVisibilityConverter matches the right-pane UserControl against it and
    // the detail re-projection groups on Section == Title); DisplayName is view-only.
    public string DisplayName => ResolveDisplayName(Title);

    private static string ResolveDisplayName(string title) => title switch
    {
        "General" => "通用",
        "Network" => "网络",
        "Devices" => "设备",
        "File Transfer" => "文件传输",
        "Remote Desktop" => "远程桌面",
        "System Monitor" => "系统监控",
        "Permissions" => "权限",
        "Advanced" => "高级",
        _ => title
    };

    public static SettingsTabItemView FromItem(SettingsTabItem item) =>
        new(item.Title, item.Detail);

    // Per-tab Segoe Fluent Icons glyph (PUA codepoints given as \u escapes so they
    // survive copy/paste/encoding), keyed off the stable English tab title. Mirrors the
    // Mac SettingsView tab symbols (gear/network/devices/transfer/remote-desktop/
    // metrics/lock/advanced). Falls back to the gear for any unknown title.
    private static string ResolveGlyph(string title) => title switch
    {
        "General" => "\uE713",        // Settings (gear)
        "Network" => "\uEC27",        // NetworkAdapter
        "Devices" => "\uE8B9",        // Devices
        "File Transfer" => "\uE8E5",  // OpenFile / transfer
        "Remote Desktop" => "\uE7F4", // Remote
        "System Monitor" => "\uE9D9", // DataSense / metrics
        "Permissions" => "\uE72E",    // Lock / permissions
        "Advanced" => "\uEC7A",       // DeveloperTools / advanced
        _ => "\uE713"
    };
}

public sealed record DashboardMetricView(
    string Title,
    string Value,
    string Detail)
{
    // The zh StatCard caption shown in the card (mirrors the Mac DashboardContentView
    // 在线设备/活跃会话/传输任务/系统状态). Title stays the stable English key — the
    // MetricGlyphConverter/MetricAccentBrushConverter key off it for the per-card icon +
    // accent, and the parity gate asserts DashboardMetricsClient carries the English labels.
    public string DisplayTitle => ResolveDisplayTitle(Title);

    public static DashboardMetricView FromMetric(DashboardMetric metric) =>
        new(metric.Label, metric.Value, metric.Detail);

    private static string ResolveDisplayTitle(string title) => title switch
    {
        "Online Devices" => "在线设备",
        "Active Sessions" => "活跃会话",
        "Transfer Tasks" => "传输任务",
        "System Status" => "系统状态",
        _ => title
    };
}

// Weather metric grid cell (Humidity / Wind speed / Visibility / AQI). Key drives the
// per-cell glyph + tint converters; Label/Value carry the localized label and the
// pre-formatted value (with Mac units). Mirrors DashboardMetricView's FromMetric idiom.
public sealed record WeatherMetricView(
    string Key,
    string Label,
    string Value,
    string TintKey)
{
    public static WeatherMetricView FromMetric(WeatherMetricSnapshot metric) =>
        new(metric.Key, metric.Label, metric.Value, metric.TintKey);
}

public sealed record SettingsActionItemView(
    string Key,
    string Title,
    string State,
    string Detail)
{
    public static SettingsActionItemView FromItem(SettingsActionItem item) =>
        new(item.Key, item.Title, item.State, item.Detail);
}

// One control row inside a Settings card (element-matches a Mac SettingsView row).
// The backend encodes the card grouping into Label as "Card · Control" (e.g.
// "Wi-Fi · Prefer 5 GHz"); we split that here so the right pane can group rows into
// glass section cards (CardName) and label each row by its short ControlName.
//
// The CONTROL KIND is classified deterministically from the honest backend Value:
//   • Toggle  — Value begins with "On"/"Off" (the backend's on/off mirror). Renders a
//     ToggleSwitch with IsOn from the prefix. ALWAYS read-only (IsSettable=false): the
//     Windows snapshot is display-only and no set-command exists, so the switch is shown
//     but disabled — honest, never implying Windows actually performs the toggle.
//   • Dropdown — Value carries an inline option set "(default · A/B/C)" (and is not a
//     toggle). DropdownOptions is the parsed option list and DropdownSelection the chosen
//     one (the text before the parenthesis). Rendered as a display-only ComboBox.
//   • Value   — everything else (status strings like "Read-only", "Core-owned",
//     "macOS-only", "Not reported", runtime reads, intent ids). Rendered as right-aligned
//     status text.
// No fabricated state: IsSettable is always false (there is no Windows settings store
// behind the snapshot yet), and every value/option comes straight from the backend string.
public sealed record SettingsDetailItemView(
    string Section,
    string Label,
    string Value,
    string Detail)
{
    private const string CardSeparator = " · ";

    public string CardName => SplitCard(Label).Card;

    public string ControlName => SplitCard(Label).Control;

    public SettingsControlKind ControlKind => ClassifyKind(Value);

    // Display-only across the board: the read-only snapshot has no Windows settings store
    // behind it, so no row owns a real set-command. The toggle/combo render but stay
    // disabled — honest, and matches the "Display-only / Not persisted / Core-owned /
    // Read-only / macOS-only" detail captions the backend already attaches.
    public bool IsSettable => false;

    // True when the toggle mirrors an "On…" value; false for "Off…" / non-toggles.
    public bool IsOn =>
        ControlKind == SettingsControlKind.Toggle &&
        Value.StartsWith("On", StringComparison.OrdinalIgnoreCase);

    public IReadOnlyList<string> DropdownOptions => ParseOptions(Value);

    public string DropdownSelection => ParseSelection(Value);

    public static SettingsDetailItemView FromItem(SettingsDetailItem item) =>
        new(item.Section, item.Label, item.Value, item.Detail);

    private static (string Card, string Control) SplitCard(string label)
    {
        if (string.IsNullOrEmpty(label))
        {
            return ("General", "");
        }

        var idx = label.IndexOf(CardSeparator, StringComparison.Ordinal);
        if (idx < 0)
        {
            return (label, label);
        }

        var card = label.Substring(0, idx).Trim();
        var control = label.Substring(idx + CardSeparator.Length).Trim();
        return (card.Length == 0 ? label : card, control.Length == 0 ? label : control);
    }

    private static SettingsControlKind ClassifyKind(string value)
    {
        var v = value ?? string.Empty;
        if (v.StartsWith("On", StringComparison.OrdinalIgnoreCase) ||
            v.StartsWith("Off", StringComparison.OrdinalIgnoreCase))
        {
            return SettingsControlKind.Toggle;
        }

        // A dropdown carries an inline option set, e.g. "30s (default · 15/30/60/120)"
        // or "Balanced (default · balanced/highPerf/...)". Require both the option
        // delimiter "·" and a "/"-separated option list to avoid treating prose as a menu.
        if (HasOptionSet(v))
        {
            return SettingsControlKind.Dropdown;
        }

        return SettingsControlKind.Value;
    }

    private static bool HasOptionSet(string value)
    {
        var open = value.IndexOf('(');
        var close = value.LastIndexOf(')');
        if (open < 0 || close <= open)
        {
            return false;
        }

        var inner = value.Substring(open + 1, close - open - 1);
        return inner.Contains('·') && inner.Contains('/');
    }

    // Parsed option labels for the display-only ComboBox: the slash-separated tokens after
    // the "·" inside the parenthesis, with the current selection placed FIRST so a
    // single-selection (display-only) ComboBox shows the honest current value at index 0
    // while still surfacing the full Mac option set.
    private static IReadOnlyList<string> ParseOptions(string value)
    {
        var v = value ?? string.Empty;
        if (!HasOptionSet(v))
        {
            return new[] { ParseSelection(v) };
        }

        var open = v.IndexOf('(');
        var close = v.LastIndexOf(')');
        var inner = v.Substring(open + 1, close - open - 1);
        var dot = inner.IndexOf('·');
        var listPart = dot >= 0 ? inner.Substring(dot + 1) : inner;

        var options = new List<string>();
        var selection = ParseSelection(v);
        options.Add(selection);
        foreach (var token in listPart.Split('/'))
        {
            var trimmed = token.Trim();
            if (trimmed.Length == 0)
            {
                continue;
            }

            // Avoid a duplicate when an option equals the current selection token.
            if (!string.Equals(trimmed, selection, StringComparison.OrdinalIgnoreCase))
            {
                options.Add(trimmed);
            }
        }

        return options;
    }

    // The current selection is the value text BEFORE the "(default …)" annotation,
    // e.g. "30s (default · 15/30/60/120)" → "30s"; "Balanced (default · …)" → "Balanced".
    private static string ParseSelection(string value)
    {
        var v = (value ?? string.Empty).Trim();
        var open = v.IndexOf('(');
        if (open < 0)
        {
            return v;
        }

        var head = v.Substring(0, open).Trim();
        return head.Length == 0 ? v : head;
    }
}

public enum SettingsControlKind
{
    Value,
    Toggle,
    Dropdown
}

// A section card in the Settings right pane: a card title (gray section header on Mac) over
// a glass card holding that card's control rows. Built by grouping the selected tab's
// SettingsDetailItemView rows on CardName, preserving the backend's row order within each
// card. Read-only snapshot of the current selection — rebuilt on every tab/snapshot change.
public sealed record SettingsCardGroupView(
    string CardName,
    System.Collections.Generic.IReadOnlyList<SettingsDetailItemView> Rows);

public sealed record UsbDeviceStatView(
    string Title,
    string Value,
    string Detail)
{
    // zh caption for the USB stat card (mirrors the Mac USB 管理 stat cards). Title stays the
    // English key — the MetricGlyphConverter/MetricAccentBrushConverter key off it and the
    // parity gate asserts the English labels in UsbManagementWorkspaceClient.
    public string DisplayTitle => ResolveDisplayTitle(Title);

    public static UsbDeviceStatView FromStat(UsbDeviceStat stat) =>
        new(stat.Title, stat.Value, stat.Detail);

    private static string ResolveDisplayTitle(string title) => title switch
    {
        "MFi Certified" => "MFi 认证",
        "Android Devices" => "Android 设备",
        "Storage Devices" => "存储设备",
        "Total Devices" => "设备总数",
        _ => title
    };
}

public sealed record UsbDeviceItemView(
    string Name,
    string DeviceId,
    string DeviceType,
    string VendorId,
    string ProductId,
    string SerialNumber,
    string ConnectionInterface,
    string Capabilities,
    string DeviceTypeKey,
    bool IsMfiCertified)
{
    public static UsbDeviceItemView FromItem(UsbDeviceItem item) =>
        new(
            item.Name,
            item.DeviceId,
            item.DeviceType,
            item.VendorId,
            item.ProductId,
            item.SerialNumber,
            item.ConnectionInterface,
            item.Capabilities,
            item.DeviceTypeKey,
            item.IsMfiCertified);
}

public sealed record SystemMonitorMetricView(
    string Label,
    string Value,
    string Detail)
{
    public static SystemMonitorMetricView FromMetric(SystemMonitorMetric metric) =>
        new(metric.Label, metric.Value, metric.Detail);
}

public sealed record SystemMonitorIndicatorView(
    string Label,
    string State,
    string Detail)
{
    public static SystemMonitorIndicatorView FromIndicator(SystemMonitorIndicator indicator) =>
        new(indicator.Label, indicator.State, indicator.Detail);
}

public sealed record RemoteDesktopSessionItemView(
    string TargetName,
    string State,
    string Transport,
    string Quality,
    string Detail)
{
    public static RemoteDesktopSessionItemView FromItem(RemoteDesktopSessionItem item) =>
        new(item.TargetName, item.State, item.Transport, item.Quality, item.Detail);
}

public sealed record RemoteDesktopControlFactView(
    string Label,
    string Value,
    string Detail)
{
    public static RemoteDesktopControlFactView FromFact(RemoteDesktopControlFact fact) =>
        new(fact.Label, fact.Value, fact.Detail);
}

public sealed record FileTransferQueueItemView(
    string Name,
    string State,
    string Size,
    string Binding,
    string Detail)
{
    public static FileTransferQueueItemView FromItem(FileTransferQueueItem item) =>
        new(item.Name, item.State, item.Size, item.Binding, item.Detail);
}

public sealed record FileTransferHistoryItemView(
    string Name,
    string Result,
    string Hmac,
    string Signature)
{
    public static FileTransferHistoryItemView FromItem(FileTransferHistoryItem item) =>
        new(item.Name, item.Result, item.Hmac, item.Signature);
}

public sealed record FileTransferSecurityFactView(
    string Label,
    string Value,
    string Detail)
{
    public static FileTransferSecurityFactView FromFact(FileTransferSecurityFact fact) =>
        new(fact.Label, fact.Value, fact.Detail);
}

public sealed record WorkspaceActionItemView(
    string Key,
    string Title,
    string Glyph,
    bool IsEnabled,
    string Detail,
    string AutomationId,
    ICommand? Command = null)
{
    public static WorkspaceActionItemView FromItem(
        WorkspaceActionSurface surface,
        WorkspaceActionItem item,
        ICommand? command = null,
        bool? isEnabled = null,
        string? detail = null) =>
        new(
            item.Key,
            item.Title,
            item.Glyph,
            isEnabled ?? item.IsEnabled,
            detail ?? item.Detail,
            BuildAutomationId(surface, item.Key),
            command);

    private static string BuildAutomationId(
        WorkspaceActionSurface surface,
        string key) =>
        $"WorkspaceAction.{surface}.{key}";
}

public sealed record CoreDiagnosticFactView(
    string Label,
    string Value,
    string Detail)
{
    public static CoreDiagnosticFactView FromFact(CoreDiagnosticFact fact) =>
        new(fact.Label, fact.Value, fact.Detail);
}

public sealed record PairingFactView(
    string Label,
    string Value,
    string Detail)
{
    public static PairingFactView FromFact(PairingFact fact) =>
        new(fact.Label, fact.Value, fact.Detail);
}

public sealed record DiscoveryBrowserFactView(
    string Label,
    string Value,
    string Detail)
{
    public static DiscoveryBrowserFactView FromFact(DiscoveryBrowserFact fact) =>
        new(fact.Label, fact.Value, fact.Detail);
}

public sealed record ManualConnectionFactView(
    string Label,
    string Value,
    string Detail)
{
    public static ManualConnectionFactView FromFact(ManualConnectionFact fact) =>
        new(fact.Label, fact.Value, fact.Detail);
}

public sealed record CrossNetworkConnectionFactView(
    string Label,
    string Value,
    string Detail)
{
    public static CrossNetworkConnectionFactView FromFact(CrossNetworkConnectionFact fact) =>
        new(fact.Label, fact.Value, fact.Detail);
}

public sealed record ConnectionPreflightFactView(
    string Label,
    string Value,
    string Detail)
{
    public static ConnectionPreflightFactView FromFact(ConnectionPreflightFact fact) =>
        new(fact.Label, fact.Value, fact.Detail);
}

public sealed record DiscoveredPeerView(
    string DeviceId,
    string DisplayName,
    string Platform,
    string ServiceKind,
    string PublicKeyFingerprint,
    string CapabilitiesSummary,
    string ProtocolVersion,
    string TrustSummary)
{
    public static DiscoveredPeerView FromCandidate(DiscoveryBrowserPeerCandidate candidate) =>
        new(
            candidate.Peer.DeviceId,
            candidate.Peer.DisplayName,
            candidate.Peer.Platform.ToString(),
            candidate.Peer.ServiceKind.ToString(),
            candidate.Peer.PublicKeyFingerprint,
            candidate.CapabilitiesSummary,
            candidate.Peer.ProtocolVersion,
            candidate.TrustSummary);
}
