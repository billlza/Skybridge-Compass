using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

/// <summary>
/// Resolves a feature's accent brush token (SkyBridgeNav*Brush in SkyBridgeTheme.xaml), the
/// colour the Mac GlassSidebar gives that tab: dashboard blue, device discovery green, USB
/// indigo, file transfer orange, remote desktop cyan, system monitor orange, settings grey.
/// The sidebar row selector is the consumer; a missing or mistyped token is a theme defect
/// and is reported as such rather than painted over with a stand-in colour.
/// </summary>
public static class FeatureAccentBrushes
{
    public static SolidColorBrush Resolve(FeatureEntryId id)
    {
        string key = id switch
        {
            FeatureEntryId.Dashboard => "SkyBridgeNavDashboardBrush",
            FeatureEntryId.DeviceDiscovery => "SkyBridgeNavDevicesBrush",
            FeatureEntryId.UsbManagement => "SkyBridgeNavUsbBrush",
            FeatureEntryId.FileTransfer => "SkyBridgeNavFileTransferBrush",
            FeatureEntryId.RemoteDesktop => "SkyBridgeNavRemoteDesktopBrush",
            FeatureEntryId.SystemMonitor => "SkyBridgeNavMonitorBrush",
            FeatureEntryId.Settings => "SkyBridgeNavSettingsBrush",
            FeatureEntryId.Quantum => "SkyBridgeNavQuantumBrush",
            _ => throw new ArgumentOutOfRangeException(nameof(id), id, "No accent brush token is defined for this feature."),
        };

        if (Application.Current.Resources.TryGetValue(key, out object? value) && value is SolidColorBrush brush)
        {
            return brush;
        }

        throw new InvalidOperationException(
            $"Theme token {key} for feature {id} is missing from Application.Resources or is not a SolidColorBrush.");
    }
}
