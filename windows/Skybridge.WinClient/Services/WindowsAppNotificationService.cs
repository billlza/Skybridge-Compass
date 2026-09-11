using System;
using System.Runtime.InteropServices;
using Microsoft.Windows.AppLifecycle;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace Skybridge.WinClient.Services;

internal sealed class WindowsAppNotificationService(string displayName, Action activated) : IDisposable
{
    private readonly Action _activated = activated ?? throw new ArgumentNullException(nameof(activated));
    private AppNotificationManager? _manager;
    public string? FailureCode { get; private set; }

    public bool Initialize()
    {
        if (_manager is not null) return true;
        AppNotificationManager? manager = null;
        var phase = "get-manager";
        try
        {
            manager = AppNotificationManager.Default;
            phase = "subscribe";
            manager.NotificationInvoked += OnInvoked;
            phase = "register";
            manager.Register(displayName, new Uri(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "SidebarBrandIcon.png")));
            _manager = manager;
            FailureCode = null;
            WindowsRuntimeLog.Write(WindowsLogLevel.Info, "notifications", "Registered Windows app notifications.");
            return true;
        }
        catch (Exception error) when (error is COMException or UnauthorizedAccessException or InvalidOperationException)
        {
            if (manager is not null) manager.NotificationInvoked -= OnInvoked;
            Report(error, phase);
            return false;
        }
    }

    public void HandleLaunchActivation()
    {
        // Register must precede GetActivatedEventArgs, including cold launches.
        if (_manager is null) return;
        try
        {
            var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
            if (activation.Kind == ExtendedActivationKind.AppNotification &&
                activation.Data is AppNotificationActivatedEventArgs notification)
                HandleActivation(notification);
        }
        catch (Exception error) when (error is COMException or InvalidOperationException)
        {
            Report(error, "launch-activation");
        }
    }

    public bool Show(WorkspaceNotification item)
    {
        if (_manager is null) return false;
        try
        {
            if (_manager.Setting != AppNotificationSetting.Enabled)
            {
                FailureCode = "notifications_disabled_by_windows";
                return false;
            }
            var notification = new AppNotificationBuilder()
                .AddArgument("action", "notifications")
                .AddText(item.Title)
                .AddText(item.Detail)
                .BuildNotification();
            _manager.Show(notification);
            // A zero id means Windows did not accept the notification.
            if (notification.Id == 0)
            {
                FailureCode = "notification_not_accepted";
                WindowsRuntimeLog.Write(WindowsLogLevel.Warning, "notifications", FailureCode);
                return false;
            }
            FailureCode = null;
            WindowsRuntimeLog.Write(WindowsLogLevel.Info, "notifications", $"Windows accepted app notification; id={notification.Id}; fileTransfer={item.IsTransfer}.");
            return true;
        }
        catch (Exception error) when (error is COMException or UnauthorizedAccessException or InvalidOperationException or ArgumentException)
        {
            Report(error);
            return false;
        }
    }

    private void OnInvoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args)
    {
        HandleActivation(args);
    }

    private void HandleActivation(AppNotificationActivatedEventArgs args)
    {
        if (args.Arguments.TryGetValue("action", out var action) && action == "notifications")
        {
            WindowsRuntimeLog.Write(WindowsLogLevel.Info, "notifications", "Notification activation received; opening notification center.");
            _activated();
        }
    }

    private void Report(Exception error, string phase = "delivery")
    {
        FailureCode = $"0x{error.HResult:X8}";
        WindowsRuntimeLog.Write(WindowsLogLevel.Warning, "notifications", $"Windows app notification failed in {phase}: {error}");
    }

    public void Dispose()
    {
        if (_manager is not { } manager) return;
        _manager = null;
        manager.NotificationInvoked -= OnInvoked;
        try { manager.Unregister(); }
        catch (Exception error) when (error is COMException or InvalidOperationException) { Report(error); }
    }
}
