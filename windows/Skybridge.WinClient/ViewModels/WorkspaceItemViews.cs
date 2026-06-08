using System.Windows.Input;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

public sealed record SettingsTabItemView(
    string Title,
    string Detail)
{
    public static SettingsTabItemView FromItem(SettingsTabItem item) =>
        new(item.Title, item.Detail);
}

public sealed record DashboardMetricView(
    string Title,
    string Value,
    string Detail)
{
    public static DashboardMetricView FromMetric(DashboardMetric metric) =>
        new(metric.Label, metric.Value, metric.Detail);
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

public sealed record SettingsDetailItemView(
    string Section,
    string Label,
    string Value,
    string Detail)
{
    public static SettingsDetailItemView FromItem(SettingsDetailItem item) =>
        new(item.Section, item.Label, item.Value, item.Detail);
}

public sealed record UsbDeviceStatView(
    string Title,
    string Value,
    string Detail)
{
    public static UsbDeviceStatView FromStat(UsbDeviceStat stat) =>
        new(stat.Title, stat.Value, stat.Detail);
}

public sealed record UsbDeviceItemView(
    string Name,
    string DeviceId,
    string DeviceType,
    string VendorId,
    string ProductId,
    string SerialNumber,
    string ConnectionInterface,
    string Capabilities)
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
            item.Capabilities);
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
    ICommand? Command = null)
{
    public static WorkspaceActionItemView FromItem(
        WorkspaceActionItem item,
        ICommand? command = null,
        bool? isEnabled = null,
        string? detail = null) =>
        new(item.Key, item.Title, item.Glyph, isEnabled ?? item.IsEnabled, detail ?? item.Detail, command);
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
