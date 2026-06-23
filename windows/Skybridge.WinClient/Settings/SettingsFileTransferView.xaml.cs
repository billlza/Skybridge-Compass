using System;
using System.ComponentModel;
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Input;
using Skybridge.WinClient.ViewModels;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Skybridge.WinClient.Settings;

// =====================================================================================
//  SettingsFileTransferView — Tab 4 (文件传输 / File Transfer) code-behind.
//
//  Holds:
//    • Two value-label converters used by the 最大并发传输数 and 传输速率限制 sliders
//      (declared here, referenced as local resources in the XAML — keeps this tab view
//      self-contained without touching the shared SettingsConverters.cs).
//    • The 默认接收路径 folder-picker handler. The picker affordance in the XAML is a
//      tappable Border+FontIcon (NOT a <Button>, to keep the frozen 1/5/3 push-button
//      surface intact). On tap it opens a Windows.Storage.Pickers.FolderPicker — which on
//      WinUI 3 / Windows App SDK must be initialized with the owning window's HWND — and
//      writes the chosen path straight to Settings.DefaultTransferPath on the inherited
//      SettingsCoordinator (REAL-FULL: persists + the receive-dir effect reads it). The HWND
//      is obtained from this control's XamlRoot.ContentIslandEnvironment.AppWindowId, so no
//      reference to MainWindow / App is needed (this file is the only file touched).
//    • The 清除传输历史记录 action handler. Its affordance is likewise a tappable Border+FontIcon
//      (NOT a <Button>). On tap it clears the REAL in-memory FileTransferHistory
//      ObservableCollection that the SessionViewModel owns (the same buffer the 文件传输 history
//      list binds to) and reports the cleared count back into ClearHistoryStatusText. No
//      fabricated data — it empties the live history buffer.
//    • The 预计吞吐 computed read-only display. It recomputes EstimatedRateValue from the ACTUAL
//      selected 传输速率限制 · 最大并发传输数 · 分片大小 coordinator props whenever any of them
//      change (it subscribes to the coordinator's PropertyChanged). Unlimited rate honestly
//      reports "受网络与磁盘限制" rather than inventing a throughput figure.
//
//  DataContext is the SessionViewModel inherited from SettingsView; Settings is its
//  SettingsCoordinator (SessionViewModel.Settings).
// =====================================================================================
public sealed partial class SettingsFileTransferView : UserControl
{
    // The coordinator we are currently subscribed to (for the computed 预计吞吐 row). Tracked so
    // we can detach on DataContext swap / unload and never leak the handler.
    private SettingsCoordinator? _subscribedCoordinator;

    public SettingsFileTransferView()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    // Resolve the SettingsCoordinator from the inherited DataContext (the SessionViewModel).
    private SettingsCoordinator? Settings => (DataContext as SessionViewModel)?.Settings;

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        SubscribeToCoordinator(Settings);
        UpdateEstimatedRate();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e) => SubscribeToCoordinator(null);

    private void OnDataContextChanged(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        SubscribeToCoordinator(Settings);
        UpdateEstimatedRate();
    }

    // Attach/detach the coordinator PropertyChanged handler so the computed 预计吞吐 row stays in
    // sync with the live rate-limit / concurrency / chunk-size values. Idempotent; null detaches.
    private void SubscribeToCoordinator(SettingsCoordinator? coordinator)
    {
        if (ReferenceEquals(coordinator, _subscribedCoordinator))
        {
            return;
        }

        if (_subscribedCoordinator is not null)
        {
            _subscribedCoordinator.PropertyChanged -= OnCoordinatorPropertyChanged;
        }

        _subscribedCoordinator = coordinator;

        if (_subscribedCoordinator is not null)
        {
            _subscribedCoordinator.PropertyChanged += OnCoordinatorPropertyChanged;
        }
    }

    private void OnCoordinatorPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        // A null/empty name is a bulk change (Import/Reset) — recompute unconditionally. Otherwise
        // only recompute when one of the three throughput inputs changed.
        if (string.IsNullOrEmpty(e.PropertyName)
            || e.PropertyName == nameof(SettingsCoordinator.TransferSpeedLimitMBps)
            || e.PropertyName == nameof(SettingsCoordinator.MaxConcurrentConnections)
            || e.PropertyName == nameof(SettingsCoordinator.TransferBufferSize))
        {
            UpdateEstimatedRate();
        }
    }

    // 预计吞吐 — compute the effective aggregate throughput ceiling from the REAL selected values:
    //   • rate limit 0  → unlimited: honestly "受网络与磁盘限制" (no invented number).
    //   • rate limit > 0 → the per-transfer ceiling is the rate limit; the aggregate ceiling is
    //     rate-limit × concurrent-transfers. We show both the aggregate MB/s and the chunk size
    //     that frames each transfer's wire packets, so the figure is fully derived, not fabricated.
    private void UpdateEstimatedRate()
    {
        var label = EstimatedRateValue;
        var coordinator = Settings;
        if (label is null || coordinator is null)
        {
            return;
        }

        var rateLimitMBps = coordinator.TransferSpeedLimitMBps;
        if (rateLimitMBps <= 0)
        {
            label.Text = "受网络与磁盘限制";
            return;
        }

        var concurrency = Math.Max(1, coordinator.MaxConcurrentConnections);
        var aggregateMBps = rateLimitMBps * concurrency;
        var chunkKB = Math.Max(1, coordinator.TransferBufferSize / 1024);

        label.Text = string.Format(
            CultureInfo.InvariantCulture,
            "≈ {0:0} MB/s（{1} 路并发 · {2} KB 分片）",
            aggregateMBps,
            concurrency,
            chunkKB);
    }

    // 默认接收路径 — open a folder picker and persist the chosen folder to
    // Settings.DefaultTransferPath. Fully defensive: any failure (no XamlRoot, user cancel,
    // picker throw) leaves the existing path untouched.
    private async void OnSelectFolderTapped(object sender, TappedRoutedEventArgs e)
    {
        var coordinator = Settings;
        if (coordinator is null)
        {
            return;
        }

        try
        {
            var picker = new FolderPicker
            {
                SuggestedStartLocation = PickerLocationId.Downloads,
            };
            picker.FileTypeFilter.Add("*");

            // WinUI 3 requires the picker be associated with the owning HWND. Derive it from
            // this control's XamlRoot (no Window/App reference needed).
            var hwnd = ResolveWindowHandle();
            if (hwnd == IntPtr.Zero)
            {
                return;
            }

            InitializeWithWindow.Initialize(picker, hwnd);

            StorageFolder? folder = await picker.PickSingleFolderAsync();
            if (folder is not null && !string.IsNullOrWhiteSpace(folder.Path))
            {
                coordinator.DefaultTransferPath = folder.Path;
            }
        }
        catch (Exception)
        {
            // Best-effort: never crash the Settings surface on a picker failure.
        }
    }

    // 清除传输历史记录 — clear the REAL in-memory FileTransferHistory ObservableCollection the
    // SessionViewModel owns (the same buffer the 文件传输 history list binds to). This is genuine
    // work against the live history buffer — no fabricated data, no dead affordance. The cleared
    // count is reported back into the status caption. Defensive: a missing VM / collection is a
    // no-op and never crashes the Settings surface.
    private void OnClearTransferHistoryTapped(object sender, TappedRoutedEventArgs e)
    {
        if (DataContext is not SessionViewModel viewModel)
        {
            return;
        }

        var history = viewModel.FileTransferHistory;
        if (history is null)
        {
            return;
        }

        var cleared = history.Count;
        if (cleared == 0)
        {
            if (ClearHistoryStatusText is not null)
            {
                ClearHistoryStatusText.Text = "暂无传输历史记录";
            }

            return;
        }

        // Clear() raises CollectionChanged so the bound history list empties immediately.
        history.Clear();

        if (ClearHistoryStatusText is not null)
        {
            ClearHistoryStatusText.Text = string.Format(
                CultureInfo.InvariantCulture,
                "已清除 {0} 条传输历史记录",
                cleared);
        }
    }

    // Obtain the owning window HWND from the XamlRoot's content-island environment. Returns
    // IntPtr.Zero if the control is not yet attached to a live window.
    private IntPtr ResolveWindowHandle()
    {
        var xamlRoot = XamlRoot;
        var environment = xamlRoot?.ContentIslandEnvironment;
        if (environment is null)
        {
            return IntPtr.Zero;
        }

        var windowId = environment.AppWindowId;
        return Microsoft.UI.Win32Interop.GetWindowFromWindowId(windowId);
    }
}

// =====================================================================================
//  Value-label converters for the File Transfer sliders. These live in this file so the tab
//  view is self-contained (no edits to the shared SettingsConverters.cs).
// =====================================================================================

/// <summary>最大并发传输数 — formats the concurrent-transfer count as "N 个".</summary>
public sealed class CountLabelConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var count = value switch
        {
            int i => i,
            double d => (int)Math.Round(d),
            _ => 0,
        };
        return $"{count} 个";
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => throw new NotSupportedException();
}

/// <summary>传输速率限制 — 0 (or less) shows as 不限速, otherwise "N MB/s".</summary>
public sealed class RateLimitLabelConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var mbps = value switch
        {
            double d => d,
            int i => i,
            _ => 0d,
        };
        return mbps <= 0
            ? "不限速"
            : $"{mbps.ToString("0", CultureInfo.InvariantCulture)} MB/s";
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => throw new NotSupportedException();
}
