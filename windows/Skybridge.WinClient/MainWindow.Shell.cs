using System;
using System.ComponentModel;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient;

public sealed partial class MainWindow
{
    private readonly WorkspaceNotificationCenter _notifications;
    private WindowsAppNotificationService? _systemNotifications;
    private Flyout? _notificationFlyout;
    private TextBlock? _notificationEmpty;
    private TextBlock? _notificationDelivery;
    private readonly CancellationTokenSource _shellLifetime = new();
    private bool _remoteNotificationConnected;
    private bool _accountNotificationSignedIn;
    private bool _showNotificationsOnLoad;
    private int _backgroundGeneration;
    private Task _backgroundTask = Task.CompletedTask;
    private Task _backgroundImportTask = Task.CompletedTask;

    private void ConfigureShellActions()
    {
        _notifications.PropertyChanged += OnNotificationCenterChanged;
        _notifications.NotificationAdded += OnNotificationAdded;
        ViewModel.PropertyChanged += OnShellStateChanged;
        ViewModel.Settings.PropertyChanged += OnShellSettingsChanged;
        _systemNotifications = new WindowsAppNotificationService(Title, () =>
        {
            if (!DispatcherQueue.TryEnqueue(() =>
            {
                if (_hostShutdownInProgress) return;
                Activate();
                if (RootShell.IsLoaded) ShowNotifications();
                else _showNotificationsOnLoad = true;
            }) && !_hostShutdownComplete)
                WindowsRuntimeLog.Write(WindowsLogLevel.Warning, "notifications", "Notification activation dispatcher is unavailable.");
        });
        if (_systemNotifications.Initialize()) _systemNotifications.HandleLaunchActivation();
        RootShell.Loaded += OnShellLoaded;
        UpdateNotificationBadge();
    }

    private async void OnShellLoaded(object sender, RoutedEventArgs args)
    {
        RootShell.Loaded -= OnShellLoaded;
        await ApplyShellBackgroundAsync();
        if (_showNotificationsOnLoad && !_hostShutdownInProgress)
        {
            _showNotificationsOnLoad = false;
            ShowNotifications();
        }
    }

    private void OnShellStateChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName != nameof(ViewModel.IsSignedIn)) return;
        var signedIn = ViewModel.IsSignedIn;
        if (signedIn == _accountNotificationSignedIn) return;
        _accountNotificationSignedIn = signedIn;
        _notifications.Add(RemoteControlText(signedIn ? "NotificationsAccountConnected" : "NotificationsAccountSignedOut"),
            RemoteControlText(signedIn ? "NotificationsAccountConnectedDetail" : "NotificationsAccountSignedOutDetail"), "\uE77B");
    }

    private async void OnShellSettingsChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (string.IsNullOrEmpty(args.PropertyName) || args.PropertyName is nameof(ViewModels.SettingsCoordinator.BackgroundTheme) or nameof(ViewModels.SettingsCoordinator.CustomBackgroundPath))
            await ApplyShellBackgroundAsync();
        if (string.IsNullOrEmpty(args.PropertyName) || args.PropertyName == nameof(ViewModels.SettingsCoordinator.ShowSystemNotifications))
        {
            if (ViewModel.Settings.ShowSystemNotifications) _systemNotifications?.Initialize();
            UpdateNotificationBadge();
        }
    }

    private void OnNotificationCenterChanged(object? sender, PropertyChangedEventArgs args) => UpdateNotificationBadge();

    private void UpdateNotificationBadge()
    {
        NotificationUnreadText.Text = _notifications.UnreadCount > 99 ? "99+" : _notifications.UnreadCount.ToString();
        NotificationUnreadBadge.Visibility = _notifications.UnreadCount == 0 ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetItemStatus(NotificationsButton, _notifications.CurrentStatus);
        if (_notificationEmpty is not null) _notificationEmpty.Visibility = _notifications.IsEmpty ? Visibility.Visible : Visibility.Collapsed;
        if (_notificationDelivery is not null)
            _notificationDelivery.Text = !ViewModel.Settings.ShowSystemNotifications ? RemoteControlText("NotificationsSystemDisabled") :
                _systemNotifications?.FailureCode is { } code ? RemoteControlText("NotificationsSystemUnavailable") + " · " + code : string.Empty;
    }

    private void OnNotificationAdded(WorkspaceNotification notification)
    {
        if (ViewModel.Settings.ShowSystemNotifications && (!notification.IsTransfer || ViewModel.Settings.ShowFileTransferNotifications))
            _systemNotifications?.Show(notification);
        UpdateNotificationBadge();
    }

    private void ShowNotifications()
    {
        if (_notificationFlyout is null)
        {
            var header = new Grid { ColumnSpacing = 12 };
            header.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            header.Children.Add(new TextBlock { Text = RemoteControlText("NotificationsCenterTitle"), FontSize = 16, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
            var clear = new Button { Content = RemoteControlText("NotificationsClear"), Padding = new Thickness(8, 4, 8, 4) };
            AutomationProperties.SetAutomationId(clear, "Skybridge.Notifications.Clear");
            clear.Click += (_, _) => _notifications.Clear();
            Grid.SetColumn(clear, 1); header.Children.Add(clear);
            _notificationEmpty = new TextBlock { Text = RemoteControlText("NotificationsEmpty"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 20, 0, 20) };
            var list = new ListView { ItemsSource = _notifications.Items, ItemTemplate = (DataTemplate)RootShell.Resources["NotificationItemTemplate"], SelectionMode = ListViewSelectionMode.None, MaxHeight = 280, IsItemClickEnabled = false };
            AutomationProperties.SetAutomationId(list, "Skybridge.Notifications.List");
            _notificationDelivery = new TextBlock { FontSize = 11, TextWrapping = TextWrapping.Wrap };
            var content = new StackPanel { Width = 340, Spacing = 8 };
            content.Children.Add(header); content.Children.Add(_notificationEmpty); content.Children.Add(list); content.Children.Add(_notificationDelivery);
            _notificationFlyout = new Flyout { Content = content, Placement = FlyoutPlacementMode.BottomEdgeAlignedRight };
            _notificationFlyout.Opened += (_, _) => _notifications.SetOpen(true);
            _notificationFlyout.Closed += (_, _) => _notifications.SetOpen(false);
        }
        UpdateNotificationBadge();
        _notificationFlyout.ShowAt(NotificationsButton);
    }

    private void ShowAppearanceMenu()
    {
        var menu = new MenuFlyout();
        foreach (var mode in new[] { "system", "light", "dark" })
        {
            var item = new ToggleMenuFlyoutItem { Text = RemoteControlText("AppearanceMode_" + mode), IsChecked = ViewModel.Settings.AppearanceMode == mode };
            AutomationProperties.SetAutomationId(item, "Skybridge.Appearance." + mode);
            item.Click += (_, _) => ViewModel.Settings.AppearanceMode = mode;
            menu.Items.Add(item);
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        foreach (var theme in new[] { "weather", "starryNight", "deepSpace", "aurora", "classic" })
        {
            var item = new ToggleMenuFlyoutItem { Text = RemoteControlText("BackgroundTheme_" + theme), IsChecked = ViewModel.Settings.BackgroundTheme == theme };
            AutomationProperties.SetAutomationId(item, "Skybridge.Background." + theme);
            item.Click += (_, _) => ViewModel.Settings.BackgroundTheme = theme;
            menu.Items.Add(item);
        }
        var custom = new MenuFlyoutItem { Text = RemoteControlText("BackgroundChooseImage"), Icon = new FontIcon { Glyph = "\uEB9F" } };
        AutomationProperties.SetAutomationId(custom, "Skybridge.Background.ChooseImage");
        custom.Click += OnChooseBackgroundImage;
        menu.Items.Add(custom);
        menu.ShowAt(AppearanceButton, new FlyoutShowOptions { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight });
    }

    private async void OnChooseBackgroundImage(object sender, RoutedEventArgs args)
    {
        if (!_backgroundImportTask.IsCompleted || _hostShutdownInProgress) return;
        _backgroundImportTask = ImportBackgroundAsync();
        await _backgroundImportTask;
    }

    private async Task ImportBackgroundAsync()
    {
        try
        {
            var picker = new Microsoft.Windows.Storage.Pickers.FileOpenPicker(AppWindow.Id);
            foreach (var extension in new[] { ".png", ".jpg", ".jpeg", ".bmp", ".webp" }) picker.FileTypeFilter.Add(extension);
            var selected = await picker.PickSingleFileAsync().AsTask(_shellLifetime.Token);
            if (selected is null || _hostShutdownInProgress) return;
            var imported = await WallpaperImageStore.ImportAsync(selected.Path, _shellLifetime.Token);
            ViewModel.Settings.CustomBackgroundPath = imported;
            ViewModel.Settings.BackgroundTheme = "custom";
        }
        catch (OperationCanceledException) when (_shellLifetime.IsCancellationRequested) { }
        catch (Exception error) when (error is System.IO.IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException or ArgumentException)
        {
            _notifications.Add(RemoteControlText("BackgroundLoadFailed"), error.Message, "\uEA39");
            ShowNotifications();
        }
    }

    private Task ApplyShellBackgroundAsync()
    {
        var generation = ++_backgroundGeneration;
        _backgroundTask = LoadShellBackgroundAfterAsync(_backgroundTask, generation);
        return _backgroundTask;
    }

    private async Task LoadShellBackgroundAfterAsync(Task preceding, int generation)
    {
        await preceding;
        if (_shellLifetime.IsCancellationRequested || generation != _backgroundGeneration) return;
        try
        {
            var theme = ViewModel.Settings.BackgroundTheme;
            var image = theme == "custom" ? await WallpaperImageStore.DecodeAsync(ViewModel.Settings.CustomBackgroundPath!, _shellLifetime.Token) : null;
            if (_shellLifetime.IsCancellationRequested || generation != _backgroundGeneration) return;
            WeatherBackdrop.SetBackground(theme, image);
            AutomationProperties.SetItemStatus(AppearanceButton, theme);
        }
        catch (OperationCanceledException) when (_shellLifetime.IsCancellationRequested) { }
        catch (Exception error) when (error is System.IO.IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException or ArgumentException or InvalidOperationException)
        {
            if (generation != _backgroundGeneration || _hostShutdownInProgress) return;
            _notifications.Add(RemoteControlText("BackgroundLoadFailed"), error.Message, "\uEA39");
        }
    }

    private async Task StopShellActionsAsync()
    {
        _shellLifetime.Cancel();
        await _backgroundImportTask;
        await _backgroundTask;
    }

    private void DisposeShellActions()
    {
        _notificationFlyout?.Hide();
        _systemNotifications?.Dispose();
        _notifications.PropertyChanged -= OnNotificationCenterChanged;
        _notifications.NotificationAdded -= OnNotificationAdded;
        ViewModel.PropertyChanged -= OnShellStateChanged;
        ViewModel.Settings.PropertyChanged -= OnShellSettingsChanged;
        RootShell.Loaded -= OnShellLoaded;
        _shellLifetime.Dispose();
    }
}
