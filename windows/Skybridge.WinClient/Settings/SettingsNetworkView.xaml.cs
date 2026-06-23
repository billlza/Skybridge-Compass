using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Skybridge.WinClient.ViewModels;
using Windows.System;

namespace Skybridge.WinClient.Settings;

// =====================================================================================
//  SettingsNetworkView — Tab 2 (网络 / Network) code-behind.
//
//  Almost everything in this tab is declarative two-way binding to the SettingsCoordinator
//  (Settings.<Prop>) — no code needed for the toggles / sliders / numeric field. The one
//  imperative piece is the 自定义服务类型 (CustomServiceTypes) list editor: it is a
//  string[] on the coordinator, and the contract forbids adding a new ICommand to the VM
//  and forbids <Button> inside the gated Settings cards. So the add / remove affordances are
//  tappable Border+FontIcon elements whose handlers live here. Each mutation re-assigns the
//  whole array (so SettingsService.CustomServiceTypes' setter persists + raises Changed),
//  then re-binds the ItemsControl to show the new list. This is REAL-FULL wiring — the edits
//  round-trip through the coordinator to %LOCALAPPDATA%\SkyBridge\settings.json.
//
//  DataContext is the SessionViewModel inherited from SettingsView; Settings is its
//  SettingsCoordinator (SessionViewModel.Settings).
// =====================================================================================
public sealed partial class SettingsNetworkView : UserControl
{
    public SettingsNetworkView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        DataContextChanged += OnDataContextChanged;
    }

    // Resolve the SettingsCoordinator from the inherited DataContext (the SessionViewModel).
    private SettingsCoordinator? Settings => (DataContext as SessionViewModel)?.Settings;

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        RefreshCustomServiceTypeList();
        RefreshCurrentNetwork();
    }

    private void OnDataContextChanged(FrameworkElement sender, DataContextChangedEventArgs args)
        => RefreshCustomServiceTypeList();

    // 当前网络 — HARDWARE-REAL read. Resolve the live internet connection profile from
    // Windows.Networking.Connectivity and surface its name (the Wi-Fi SSID for a WLAN adapter,
    // the adapter/connection name otherwise) + a connectivity-level detail line. Fully defensive:
    // any failure or no-connection state shows an honest "未连接"/read-failure, never a fabricated SSID.
    private void RefreshCurrentNetwork()
    {
        if (CurrentNetworkValue is null || CurrentNetworkDetail is null)
        {
            return;
        }

        try
        {
            var profile = Windows.Networking.Connectivity.NetworkInformation.GetInternetConnectionProfile();
            if (profile is null)
            {
                CurrentNetworkValue.Text = "未连接";
                CurrentNetworkDetail.Text = "未检测到活动的 Internet 连接配置文件";
                return;
            }

            // ProfileName is the SSID for a Wi-Fi adapter; the adapter/connection name otherwise.
            var name = profile.ProfileName;
            CurrentNetworkValue.Text = string.IsNullOrWhiteSpace(name) ? "已连接" : name;

            var level = profile.GetNetworkConnectivityLevel();
            var isWlan = profile.IsWlanConnectionProfile;
            var kind = isWlan ? "Wi-Fi" : "有线 / 其他";
            CurrentNetworkDetail.Text = $"{kind} · {DescribeConnectivity(level)}";
        }
        catch (Exception)
        {
            CurrentNetworkValue.Text = "读取失败";
            CurrentNetworkDetail.Text = "无法读取系统网络配置文件";
        }
    }

    private static string DescribeConnectivity(Windows.Networking.Connectivity.NetworkConnectivityLevel level) =>
        level switch
        {
            Windows.Networking.Connectivity.NetworkConnectivityLevel.InternetAccess => "可访问 Internet",
            Windows.Networking.Connectivity.NetworkConnectivityLevel.ConstrainedInternetAccess => "受限 Internet",
            Windows.Networking.Connectivity.NetworkConnectivityLevel.LocalAccess => "仅本地网络",
            Windows.Networking.Connectivity.NetworkConnectivityLevel.None => "无网络",
            _ => "未知"
        };

    // Re-bind the list editor to the coordinator's current array. A defensive copy avoids
    // mutating the live array in place (the setter compares + clones).
    private void RefreshCustomServiceTypeList()
    {
        if (CustomServiceTypeList is null)
        {
            return;
        }

        var current = Settings?.CustomServiceTypes ?? Array.Empty<string>();
        // Bind to a fresh list instance so the ItemsControl re-renders on every mutation.
        CustomServiceTypeList.ItemsSource = current.ToList();
    }

    // Inline add affordance (tapped Border+FontIcon). Reads the new-type TextBox, normalizes,
    // de-dupes, and persists by re-assigning the whole array on the coordinator.
    private void OnAddCustomServiceType(object sender, TappedRoutedEventArgs e) => AddCurrentEntry();

    // Enter in the new-type TextBox also commits the add.
    private void OnNewServiceTypeKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            AddCurrentEntry();
        }
    }

    private void AddCurrentEntry()
    {
        var coordinator = Settings;
        if (coordinator is null || NewServiceTypeBox is null)
        {
            return;
        }

        var entry = (NewServiceTypeBox.Text ?? string.Empty).Trim();
        if (string.IsNullOrEmpty(entry))
        {
            return;
        }

        var list = new List<string>(coordinator.CustomServiceTypes ?? Array.Empty<string>());
        // Case-insensitive de-dupe so the discovery query order stays clean.
        if (list.Any(existing => string.Equals(existing, entry, StringComparison.OrdinalIgnoreCase)))
        {
            NewServiceTypeBox.Text = string.Empty;
            return;
        }

        list.Add(entry);
        coordinator.CustomServiceTypes = list.ToArray();
        NewServiceTypeBox.Text = string.Empty;
        RefreshCustomServiceTypeList();
    }

    // Inline remove affordance (tapped Border+FontIcon). The Border's Tag carries the entry
    // string to drop; persists by re-assigning the trimmed array on the coordinator.
    private void OnRemoveCustomServiceType(object sender, TappedRoutedEventArgs e)
    {
        var coordinator = Settings;
        if (coordinator is null)
        {
            return;
        }

        if (sender is not FrameworkElement element || element.Tag is not string target)
        {
            return;
        }

        var list = new List<string>(coordinator.CustomServiceTypes ?? Array.Empty<string>());
        var removed = list.RemoveAll(existing => string.Equals(existing, target, StringComparison.Ordinal)) > 0;
        if (!removed)
        {
            return;
        }

        coordinator.CustomServiceTypes = list.ToArray();
        RefreshCustomServiceTypeList();
    }
}
