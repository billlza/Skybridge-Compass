using System;
using System.Collections.Generic;
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Devices.Bluetooth.Advertisement;

namespace Skybridge.WinClient.Settings;

// =====================================================================================
//  SettingsDevicesView — Tab 3 (设备 / Devices) code-behind.
//
//  The toggles / slider are declarative two-way bindings to the SettingsCoordinator. The one
//  imperative piece is the HARDWARE-REAL Bluetooth section: the 扫描蓝牙设备 ToggleSwitch starts /
//  stops a real Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher, and the
//  蓝牙状态 / 已发现设备数 rows reflect its live state + the distinct advertisers seen. This replaces
//  the static "未扫描" placeholder with a genuine BLE scan. Fully defensive: when the radio/stack is
//  absent the watcher reports an honest "蓝牙不可用" and the toggle reverts (never a fabricated scan).
//
//  DataContext inherits the SessionViewModel from SettingsView. The scan is torn down on Unloaded
//  so a watcher never outlives the view.
// =====================================================================================
public sealed partial class SettingsDevicesView : UserControl
{
    private BluetoothLEAdvertisementWatcher? _watcher;
    private readonly HashSet<ulong> _seenAddresses = new();

    public SettingsDevicesView()
    {
        InitializeComponent();
        Unloaded += OnUnloaded;
    }

    private void OnUnloaded(object sender, RoutedEventArgs e) => StopScan();

    // 扫描蓝牙设备 ToggleSwitch — start (on) or stop (off) the real BLE advertisement watcher.
    private void OnBluetoothScanToggled(object sender, RoutedEventArgs e)
    {
        if (BluetoothScanToggle is null)
        {
            return;
        }

        if (BluetoothScanToggle.IsOn)
        {
            StartScan();
        }
        else
        {
            StopScan();
        }
    }

    private void StartScan()
    {
        if (_watcher is not null)
        {
            return;
        }

        try
        {
            _seenAddresses.Clear();
            SetDiscoveredCount(0);

            _watcher = new BluetoothLEAdvertisementWatcher
            {
                ScanningMode = BluetoothLEScanningMode.Active,
            };
            _watcher.Received += OnAdvertisementReceived;
            _watcher.Stopped += OnWatcherStopped;
            _watcher.Start();
            SetStatus("扫描中", isWarning: false);
        }
        catch (Exception)
        {
            // No BLE radio / stack unavailable — honest status, revert the toggle, no fake scan.
            _watcher = null;
            SetStatus("蓝牙不可用", isWarning: true);
            if (BluetoothScanToggle is { IsOn: true } toggle)
            {
                toggle.IsOn = false;
            }
        }
    }

    private void StopScan()
    {
        var watcher = _watcher;
        _watcher = null;
        if (watcher is null)
        {
            return;
        }

        try
        {
            watcher.Received -= OnAdvertisementReceived;
            watcher.Stopped -= OnWatcherStopped;
            watcher.Stop();
        }
        catch (Exception)
        {
            // Best-effort teardown.
        }

        SetStatus("未扫描", isWarning: true);
    }

    private void OnAdvertisementReceived(
        BluetoothLEAdvertisementWatcher sender,
        BluetoothLEAdvertisementReceivedEventArgs args)
    {
        // Marshal onto the UI thread; count distinct advertiser addresses seen this scan.
        bool isNew;
        lock (_seenAddresses)
        {
            isNew = _seenAddresses.Add(args.BluetoothAddress);
        }

        if (!isNew)
        {
            return;
        }

        var count = _seenAddresses.Count;
        DispatcherQueue?.TryEnqueue(() => SetDiscoveredCount(count));
    }

    private void OnWatcherStopped(
        BluetoothLEAdvertisementWatcher sender,
        BluetoothLEAdvertisementWatcherStoppedEventArgs args)
    {
        // The OS can stop the watcher (radio off / error). Reflect it honestly + revert the toggle.
        DispatcherQueue?.TryEnqueue(() =>
        {
            SetStatus("已停止", isWarning: true);
            if (BluetoothScanToggle is { IsOn: true } toggle)
            {
                toggle.IsOn = false;
            }
        });
    }

    private void SetStatus(string text, bool isWarning)
    {
        if (BluetoothStatusValue is null)
        {
            return;
        }

        BluetoothStatusValue.Text = text;
        BluetoothStatusValue.Foreground = isWarning
            ? (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SkyBridgeWarningBrush"]
            : (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SkyBridgeSuccessBrush"];
    }

    private void SetDiscoveredCount(int count)
    {
        if (BluetoothDiscoveredCount is not null)
        {
            // Mac-faithful format: settings.devices.bluetooth.discoveredCount = "已发现: %d 设备".
            BluetoothDiscoveredCount.Text = string.Format(
                CultureInfo.CurrentCulture,
                "已发现: {0} 设备",
                count);
        }
    }
}
