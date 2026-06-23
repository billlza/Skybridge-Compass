using System;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;

namespace Skybridge.WinClient.ViewModels;

/// <summary>
/// Shared keyword classifier for the read-only File Transfer workspace state /
/// result strings. The Windows snapshot carries human State / Result text
/// ("Queued", "Intent ready", "Transferring", "Verified", "Completed",
/// "Failed", "pending live transfer", …) rather than a typed enum, so the
/// File Transfer converters key their glyph / tint off the same small,
/// case-insensitive keyword buckets. Pending / placeholder states stay
/// "muted" — never faked-healthy — matching the honest-data rule used by the
/// System Monitor indicator converters.
/// </summary>
internal enum FileTransferStateBucket
{
    /// <summary>Terminal success: Verified / Completed / Signature OK / Sent / Received.</summary>
    Success,

    /// <summary>In-flight: Transferring / Sending / Receiving / Uploading / Downloading.</summary>
    Active,

    /// <summary>Staged but not yet running: Queued / Intent ready / Prepared / Ready.</summary>
    Queued,

    /// <summary>Awaiting a real transfer / pairing: pending / placeholder / waiting.</summary>
    Pending,

    /// <summary>Terminal failure: Failed / Error / Cancelled / Rejected / Unsafe.</summary>
    Failed,

    /// <summary>Unrecognized text.</summary>
    Unknown
}

internal static class FileTransferStateClassifier
{
    public static FileTransferStateBucket Classify(string? value)
    {
        var text = (value ?? string.Empty).Trim().ToLowerInvariant();
        if (text.Length == 0)
        {
            return FileTransferStateBucket.Unknown;
        }

        if (Contains(text, "fail", "error", "cancel", "reject", "unsafe", "denied", "abort"))
        {
            return FileTransferStateBucket.Failed;
        }

        if (Contains(text, "verified", "completed", "complete", "signature ok", "success", "sent", "received", "ok"))
        {
            return FileTransferStateBucket.Success;
        }

        if (Contains(text, "transferring", "sending", "receiving", "uploading", "downloading", "in progress", "active"))
        {
            return FileTransferStateBucket.Active;
        }

        if (Contains(text, "pending", "placeholder", "waiting", "awaiting"))
        {
            return FileTransferStateBucket.Pending;
        }

        if (Contains(text, "queued", "ready", "prepared", "intent", "staged"))
        {
            return FileTransferStateBucket.Queued;
        }

        return FileTransferStateBucket.Unknown;
    }

    /// <summary>
    /// True when the state text reads as an INCOMING transfer (history "Received",
    /// queue "Receiving / Downloading"), used to pick the down-arrow + green tint.
    /// Everything else (including ambiguous "Queued") is treated as outgoing, which
    /// matches the Windows client's send-first surface.
    /// </summary>
    public static bool IsIncoming(string? value)
    {
        var text = (value ?? string.Empty).Trim().ToLowerInvariant();
        return Contains(text, "receiv", "download", "inbound", "incoming");
    }

    private static bool Contains(string text, params string[] needles)
    {
        foreach (var needle in needles)
        {
            if (text.Contains(needle, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }
}

/// <summary>
/// Maps a File Transfer queue State / history Result string to a tint brush,
/// element-matching the Mac transfer-row status colors (green = completed /
/// verified, blue = transferring / queued accent, orange = pending-live, red =
/// failed, muted = unknown). Pending stays muted-orange rather than green so the
/// UI never claims a transfer succeeded before it has.
/// </summary>
public sealed class FileTransferStateToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var key = FileTransferStateClassifier.Classify(value as string) switch
        {
            FileTransferStateBucket.Success => "SkyBridgeSuccessBrush",
            FileTransferStateBucket.Active => "SkyBridgeNavDashboardBrush",
            FileTransferStateBucket.Queued => "SkyBridgeNavDashboardBrush",
            FileTransferStateBucket.Pending => "SkyBridgeWarningBrush",
            FileTransferStateBucket.Failed => "SkyBridgeDangerBrush",
            _ => "SkyBridgeTextMutedBrush"
        };

        return ResolveBrush(key);
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

        return new SolidColorBrush(Microsoft.UI.Colors.Gray);
    }
}

/// <summary>
/// Maps a File Transfer queue State / history Result string to a Segoe Fluent
/// Icons status glyph (best-fit, human-verified), element-matching the Mac
/// transfer-row status icon intent:
///   Success  → EC61 CompletedSolid     (~ SF "checkmark.circle.fill")
///   Active   → E895 Sync               (~ SF "arrow.triangle.2.circlepath", in-flight)
///   Queued   → E916 Clock              (~ SF "clock", staged / queued)
///   Pending  → E916 Clock              (~ SF awaiting-live; reads cleaner than hourglass)
///   Failed   → EB90 StatusErrorFull    (~ SF "xmark.circle.fill")
///   Unknown  → E9CE Unknown            (~ SF "questionmark.circle")
/// </summary>
public sealed class FileTransferStateToGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        FileTransferStateClassifier.Classify(value as string) switch
        {
            FileTransferStateBucket.Success => "\uEC61", // CompletedSolid - checkmark in filled circle
            FileTransferStateBucket.Active => "\uE895",  // Sync - in-flight
            FileTransferStateBucket.Queued => "\uE916",  // Clock - staged / queued
            FileTransferStateBucket.Pending => "\uE916", // Clock - awaiting live transfer
            FileTransferStateBucket.Failed => "\uEB90",  // StatusErrorFull - x in filled circle
            _ => "\uE9CE"                                  // Unknown - question mark
        };

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>
/// Maps a File Transfer state string to a DIRECTION glyph, element-matching the
/// Mac ModernTransferRowView direction icon: outgoing = up-arrow (blue),
/// incoming = down-arrow (green). The Windows snapshot has no explicit
/// direction field, so direction is derived honestly from the state text
/// (FileTransferStateClassifier.IsIncoming): only "received / downloading /
/// inbound" reads as incoming; everything else (send-first surface) is outgoing.
///   Outgoing → E898 Upload   (up arrow)   ~ SF "arrow.up.circle.fill"
///   Incoming → E896 Download (down arrow) ~ SF "arrow.down.circle.fill"
/// </summary>
public sealed class FileTransferDirectionToGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        FileTransferStateClassifier.IsIncoming(value as string)
            ? "\uE896"  // Download - down arrow (incoming)
            : "\uE898"; // Upload - up arrow (outgoing)

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>
/// Maps a File Transfer state string to the direction TINT, element-matching the
/// Mac outgoing = blue / incoming = green convention.
/// </summary>
public sealed class FileTransferDirectionToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        FileTransferStateToBrushConverter.ResolveBrush(
            FileTransferStateClassifier.IsIncoming(value as string)
                ? "SkyBridgeSuccessBrush"         // incoming = green
                : "SkyBridgeNavDashboardBrush");  // outgoing = blue

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>
/// Maps a File Transfer history Result string to a verification Segoe Fluent
/// glyph, element-matching the Mac EnhancedHistoryRowView scan-result shield:
///   Success → EB95 Shield (filled, "Verified") ~ SF "checkmark.shield.fill"
///   Failed  → EB95 Shield with danger tint      ~ SF "xmark.shield.fill"
///   else    → E946 Info                         ~ SF "info.circle"
/// (Tint is supplied separately by FileTransferStateToBrushConverter so the
/// shield reads green when verified, red when failed.)
/// </summary>
public sealed class FileTransferResultToShieldGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        FileTransferStateClassifier.Classify(value as string) switch
        {
            FileTransferStateBucket.Success => "\uEB95", // Shield - verified
            FileTransferStateBucket.Failed => "\uEB95",  // Shield - failed (red tint)
            _ => "\uE946"                                  // Info
        };

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
