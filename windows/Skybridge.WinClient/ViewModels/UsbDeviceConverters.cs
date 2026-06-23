using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace Skybridge.WinClient.ViewModels;

/// <summary>
/// Maps a <c>UsbDeviceItemView.DeviceTypeKey</c> (the stable, non-localized classification key
/// from <c>UsbDeviceTypeKindExtensions.ToKey()</c>: appleMfi / android / externalDrive /
/// flashDrive / audio / unknown) to a Segoe Fluent Icons device glyph for the USB device-row
/// icon chip, element-matching the Mac <c>DeviceCard.deviceIcon</c> SF Symbols:
///   appleMfi      → E8EA  (CellPhone)        ~ SF "iphone"
///   android       → E8EA  (CellPhone)        ~ SF "smartphone"
///   externalDrive → EDA2  (HardDrive)        ~ SF "externaldrive.fill"
///   flashDrive    → E88E  (USB / media)      ~ SF "externaldrive.fill.badge.plus"
///   audio         → E7F6  (Headphone)        ~ SF "headphones"
///   unknown       → E897  (Unknown/help)     ~ SF "questionmark.circle"
/// Falls back to a generic USB glyph (E88E) for unrecognized keys. Best-fit Segoe Fluent
/// codepoints; human-verify if exact icon parity matters.
/// </summary>
public sealed class UsbDeviceTypeToGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var key = (value as string ?? string.Empty).ToLowerInvariant();
        return key switch
        {
            "applemfi" => "",      // CellPhone (iPhone)
            "android" => "",       // CellPhone (Android)
            "externaldrive" => "", // HardDrive
            "flashdrive" => "",    // USB / flash media
            "audio" => "",         // Headphone
            _ => ""                // Unknown / help
        };
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}

/// <summary>
/// Maps a <c>UsbDeviceItemView.DeviceTypeKey</c> to a per-type tint brush for the USB
/// device-row icon, mirroring the Mac <c>DeviceCard.deviceIcon</c> colors:
///   appleMfi      → blue   (SkyBridgeNavDashboardBrush)   ~ Mac .blue
///   android       → green  (SkyBridgeSuccessBrush)        ~ Mac .green
///   externalDrive → orange (SkyBridgeWarningBrush)        ~ Mac .orange
///   flashDrive    → purple (SkyBridgeNavQuantumBrush)     ~ Mac .purple
///   audio         → cyan   (SkyBridgeAccentSecondaryBrush) ~ Mac .pink (closest distinct)
///   unknown       → muted  (SkyBridgeTextMutedBrush)      ~ Mac .gray
/// NOTE: the theme has no dedicated pink token; audio uses the secondary accent (cyan) so it
/// still reads distinctly from the others without inventing a new brush. Falls back to the
/// shared accent brush.
/// </summary>
public sealed class UsbDeviceTypeToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var key = (value as string ?? string.Empty).ToLowerInvariant();
        var brushKey = key switch
        {
            "applemfi" => "SkyBridgeNavDashboardBrush",
            "android" => "SkyBridgeSuccessBrush",
            "externaldrive" => "SkyBridgeWarningBrush",
            "flashdrive" => "SkyBridgeNavQuantumBrush",
            "audio" => "SkyBridgeAccentSecondaryBrush",
            "unknown" => "SkyBridgeTextMutedBrush",
            _ => "SkyBridgeAccentBrush"
        };

        return MetricKeyToBrushConverter.ResolveBrush(brushKey);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}

/// <summary>
/// Maps a USB stat card's stable Title (MFi Certified / Android Devices / Storage Devices /
/// Total Devices — from <c>UsbManagementWorkspaceClient</c>) to a Segoe Fluent Icons glyph,
/// element-matching the Mac <c>USBStatCard</c> icons:
///   "MFi Certified"   → EC61  (CompletedSolid, sealed check) ~ SF "checkmark.seal.fill"
///   "Android Devices" → E8EA  (CellPhone)                    ~ SF "smartphone"
///   "Storage Devices" → EDA2  (HardDrive)                    ~ SF "externaldrive.fill"
///   "Total Devices"   → E88E  (USB / media)                  ~ SF "cable.connector"
/// Falls back to a generic USB glyph (E88E) for unknown titles.
/// </summary>
public sealed class UsbMetricKeyToGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var title = value as string ?? string.Empty;
        return title switch
        {
            "MFi Certified" => "",   // CompletedSolid (sealed checkmark)
            "Android Devices" => "", // CellPhone
            "Storage Devices" => "", // HardDrive
            "Total Devices" => "",   // USB / connector
            _ => ""
        };
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}

/// <summary>
/// Maps a USB stat card's stable Title to a per-card accent brush, mirroring the Mac
/// <c>USBStatCard</c> colors:
///   "MFi Certified"   → green  (SkyBridgeSuccessBrush)       ~ Mac .green
///   "Android Devices" → blue   (SkyBridgeNavDashboardBrush)  ~ Mac .blue
///   "Storage Devices" → orange (SkyBridgeWarningBrush)       ~ Mac .orange
///   "Total Devices"   → purple (SkyBridgeNavQuantumBrush)    ~ Mac .purple
/// Falls back to the shared accent brush.
/// </summary>
public sealed class UsbMetricKeyToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var title = value as string ?? string.Empty;
        var brushKey = title switch
        {
            "MFi Certified" => "SkyBridgeSuccessBrush",
            "Android Devices" => "SkyBridgeNavDashboardBrush",
            "Storage Devices" => "SkyBridgeWarningBrush",
            "Total Devices" => "SkyBridgeNavQuantumBrush",
            _ => "SkyBridgeAccentBrush"
        };

        return MetricKeyToBrushConverter.ResolveBrush(brushKey);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}

/// <summary>
/// Maps a <c>bool</c> (the USB device's <c>IsMfiCertified</c> flag) to <see cref="Visibility"/>
/// so the MFi badge in the USB device row only renders for MFi-certified devices — element-
/// matching the Mac <c>DeviceCard</c> MFi badge (shown only when <c>device.isMFiCertified</c>).
/// Pass ConverterParameter="Invert" to flip the sense.
/// </summary>
public sealed class BoolToVisibilityValueConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var flag = value is bool b && b;
        var invert = parameter is string mode &&
            string.Equals(mode, "Invert", StringComparison.OrdinalIgnoreCase);
        var visible = invert ? !flag : flag;
        return visible ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}
