using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Devices.Geolocation;

namespace Skybridge.WinClient.Settings;

// SettingsPermissionsView — Tab 7 (权限 / Permissions) code-behind.
//
// Permissions has NO persisted settings keys and NO settable controls. The tab is read-only status
// + HARDWARE-REAL permission rows + a static 帮助 block + the EXISTING gated actions (RefreshStatus
// header · RequestPermission + OpenSystemPreferences toolbar) preserved in SettingsView's action
// ItemsControls — so this tab adds no new commands and no <Button> surface.
//
// The one imperative piece is the HARDWARE-REAL 位置访问 (Location) status: it is read on load via
// Windows.Devices.Geolocation.Geolocator.RequestAccessAsync(), which returns the real OS consent
// state (Allowed / Denied / Unspecified). Fully defensive — any failure shows an honest "读取失败",
// never a fabricated "granted". DataContext is the SessionViewModel inherited from SettingsView.
public sealed partial class SettingsPermissionsView : UserControl
{
    public SettingsPermissionsView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e) => await RefreshLocationAccessAsync();

    private async System.Threading.Tasks.Task RefreshLocationAccessAsync()
    {
        if (LocationAccessValue is null)
        {
            return;
        }

        try
        {
            var status = await Geolocator.RequestAccessAsync();
            LocationAccessValue.Text = status switch
            {
                GeolocationAccessStatus.Allowed => "已授权",
                GeolocationAccessStatus.Denied => "已拒绝 · 见 Windows 隐私设置",
                GeolocationAccessStatus.Unspecified => "未设置 · Windows 隐私设置管理",
                _ => "未知"
            };
        }
        catch (Exception)
        {
            LocationAccessValue.Text = "读取失败";
        }
    }
}
