using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

/// <summary>
/// Maps a <see cref="FeatureEntryId"/> to the per-feature accent brush token
/// (SkyBridgeNav*Brush) defined in SkyBridgeTheme.xaml. This lets the
/// NavigationView MenuItemTemplate paint each item's 32x32 icon chip with the
/// same accent palette the Mac sidebar uses (blue / green / indigo / orange /
/// cyan / purple / ... per tab). Falls back to the shared accent brush.
/// </summary>
public sealed class FeatureEntryIdToAccentBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var key = value switch
        {
            FeatureEntryId.Dashboard => "SkyBridgeNavDashboardBrush",
            FeatureEntryId.DeviceDiscovery => "SkyBridgeNavDevicesBrush",
            FeatureEntryId.UsbManagement => "SkyBridgeNavUsbBrush",
            FeatureEntryId.FileTransfer => "SkyBridgeNavFileTransferBrush",
            FeatureEntryId.RemoteDesktop => "SkyBridgeNavRemoteDesktopBrush",
            FeatureEntryId.Quantum => "SkyBridgeNavQuantumBrush",
            FeatureEntryId.SystemMonitor => "SkyBridgeNavMonitorBrush",
            FeatureEntryId.Settings => "SkyBridgeNavSettingsBrush",
            _ => "SkyBridgeAccentBrush"
        };

        if (Application.Current?.Resources is { } resources &&
            resources.TryGetValue(key, out var brush) &&
            brush is Brush accentBrush)
        {
            return accentBrush;
        }

        if (Application.Current?.Resources is { } fallbackResources &&
            fallbackResources.TryGetValue("SkyBridgeAccentBrush", out var fallback) &&
            fallback is Brush fallbackBrush)
        {
            return fallbackBrush;
        }

        return new SolidColorBrush(Microsoft.UI.Colors.DodgerBlue);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}
