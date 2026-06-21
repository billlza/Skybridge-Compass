using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;

namespace Skybridge.WinClient.ViewModels;

/// <summary>
/// Maps a discovered peer's <see cref="DiscoveredPeerView.PublicKeyFingerprint"/> to a
/// status-dot brush, element-matching the Mac OnlineDeviceCard / EnhancedDeviceRow status
/// dot (connected/identified = green, otherwise = muted/offline gray).
///
/// This is keyed off REAL data only: a non-empty public-key fingerprint means the peer has
/// advertised a verifiable identity (it is wire-reachable / has completed enough of the
/// DNS-SD advertisement to expose a key), so it renders green — the same signal the Mac uses
/// for an online/connected device. When no fingerprint is present we render the muted
/// "offline/unidentified" gray rather than inventing a status. No fake "connected" claims.
/// </summary>
public sealed class PeerStatusToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var fingerprint = value as string ?? string.Empty;
        var key = string.IsNullOrWhiteSpace(fingerprint)
            ? "SkyBridgeTextMutedBrush"
            : "SkyBridgeSuccessBrush";
        return MetricKeyToBrushConverter.ResolveBrush(key);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}

/// <summary>
/// Maps a string to <see cref="Visibility"/>: Visible when the string is non-empty,
/// Collapsed when null/empty/whitespace. Used so the rich peer row only renders its
/// fingerprint / trust / capabilities sub-rows when there is real data to show (the Mac
/// OnlineDeviceCard conditionally renders each of those lines). Pass
/// ConverterParameter="Invert" to flip (Visible when empty), e.g. for a "no identity yet"
/// placeholder. Purely a view-state switch — no allocation, no fabricated data.
/// </summary>
public sealed class StringPresenceToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var hasText = !string.IsNullOrWhiteSpace(value as string);
        var invert = parameter is string mode &&
            string.Equals(mode, "Invert", StringComparison.OrdinalIgnoreCase);
        var visible = invert ? !hasText : hasText;
        return visible ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}

/// <summary>
/// Maps a peer's <see cref="DiscoveredPeerView.ServiceKind"/> (the <c>ToString()</c> of
/// <c>CoreDiscoveryServiceKind</c>: "QuicPrimary" / "TcpFallback" / "Unknown") to a Segoe
/// Fluent Icons transport glyph for the connection-type chip, element-matching the Mac
/// OnlineDeviceCard connection-type chips (small transport icon + label).
///   QuicPrimary → EC27  (NetworkAdapter, a fast/primary link) ~ SF "wifi"
///   TcpFallback → E839  (NetworkTower, a fallback link)        ~ SF "antenna.radiowaves..."
///   else        → E9CE  (Unknown / question-ish)              ~ SF "questionmark.circle"
/// </summary>
public sealed class ServiceKindToGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var kind = (value as string ?? string.Empty).ToLowerInvariant();
        if (kind.Contains("quic"))
        {
            return ""; // NetworkAdapter — primary/fast transport
        }

        if (kind.Contains("tcp") || kind.Contains("fallback"))
        {
            return ""; // NetworkTower — fallback transport
        }

        return ""; // StatusCircleQuestionMark — unknown transport
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}

/// <summary>
/// Maps a peer's <see cref="DiscoveredPeerView.ServiceKind"/> to a per-transport tint brush
/// for the connection-type chip, mirroring the Mac connection-type chip colors
/// (Wi-Fi/primary = blue, fallback = green/mint, unknown = muted gray).
///   QuicPrimary → SkyBridgeNavDashboardBrush (blue, primary link)
///   TcpFallback → SkyBridgeSuccessBrush       (green, fallback link)
///   else        → SkyBridgeTextMutedBrush     (muted, unknown)
/// </summary>
public sealed class ServiceKindToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var kind = (value as string ?? string.Empty).ToLowerInvariant();
        var key = kind switch
        {
            _ when kind.Contains("quic") => "SkyBridgeNavDashboardBrush",
            _ when kind.Contains("tcp") || kind.Contains("fallback") => "SkyBridgeSuccessBrush",
            _ => "SkyBridgeTextMutedBrush"
        };
        return MetricKeyToBrushConverter.ResolveBrush(key);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}
