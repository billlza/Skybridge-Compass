using System;
using System.Collections.Generic;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface ITopBarStatusClient
{
    TopBarStatusSnapshot BuildReadOnlySnapshot(TopBarStatusRequest request);

    TopBarResolvedStatusSnapshot BuildResolvedStatusSnapshot(TopBarStatusRequest request);

    TopBarStatusUpdateSnapshot BuildStatusUpdate(TopBarStatusRequest request);

    string BuildDefaultStatusValue(TopBarStatusSlot slot);

    string ResolveStatusValue(
        TopBarStatusSnapshot snapshot,
        TopBarStatusSlot slot,
        string fallback);

    WorkspaceActionDetailSnapshot BuildWorkspaceActionDetailSnapshot(
        TopBarResolvedStatusSnapshot snapshot);

    bool CanOpenNotifications();

    bool CanToggleTheme();

    string BuildNotificationsPendingStatus();

    string BuildThemePendingStatus();

    Task<TopBarWorkspaceActionResult> BuildNotificationsActionAsync();

    Task<TopBarWorkspaceActionResult> BuildThemeActionAsync();
}

public interface ITopBarNotificationCenterClient
{
    string CurrentStatus { get; }

    bool CanOpenNotifications();

    TopBarWorkspaceActionResult OpenNotifications();
}

public sealed class InMemoryTopBarNotificationCenterClient : ITopBarNotificationCenterClient
{
    private readonly object _sync = new();
    private string _currentStatus;

    public InMemoryTopBarNotificationCenterClient()
        : this(TopBarStatusClient.DefaultNotificationsStatus)
    {
    }

    public InMemoryTopBarNotificationCenterClient(string initialStatus)
    {
        _currentStatus = TopBarStatusClient.NormalizeNotificationsStatus(initialStatus);
    }

    public string CurrentStatus
    {
        get
        {
            lock (_sync)
            {
                return _currentStatus;
            }
        }
    }

    public bool CanOpenNotifications() => true;

    public TopBarWorkspaceActionResult OpenNotifications()
    {
        lock (_sync)
        {
            _currentStatus = TopBarStatusClient.NotificationsViewedStatus;
            return TopBarStatusClient.BuildNotificationsOpenedActionResult(_currentStatus);
        }
    }
}

public interface ITopBarThemePreferenceClient
{
    string CurrentStatus { get; }

    string Toggle();
}

public sealed class InMemoryTopBarThemePreferenceClient : ITopBarThemePreferenceClient
{
    private readonly object _sync = new();
    private string _currentStatus;

    public InMemoryTopBarThemePreferenceClient()
        : this(TopBarStatusClient.DefaultThemeStatus)
    {
    }

    public InMemoryTopBarThemePreferenceClient(string initialStatus)
    {
        _currentStatus = NormalizeThemeStatus(initialStatus);
    }

    public string CurrentStatus
    {
        get
        {
            lock (_sync)
            {
                return _currentStatus;
            }
        }
    }

    public string Toggle()
    {
        lock (_sync)
        {
            _currentStatus = BuildNextThemeStatus(_currentStatus);
            return _currentStatus;
        }
    }

    public static string NormalizeThemeStatus(string status) =>
        status switch
        {
            var value when string.Equals(value, TopBarStatusClient.DefaultThemeStatus, StringComparison.Ordinal) =>
                TopBarStatusClient.DefaultThemeStatus,
            var value when string.Equals(value, TopBarStatusClient.DarkThemeStatus, StringComparison.Ordinal) =>
                TopBarStatusClient.DarkThemeStatus,
            var value when string.Equals(value, TopBarStatusClient.LightThemeStatus, StringComparison.Ordinal) =>
                TopBarStatusClient.LightThemeStatus,
            _ => TopBarStatusClient.DefaultThemeStatus
        };

    public static string BuildNextThemeStatus(string currentStatus) =>
        NormalizeThemeStatus(currentStatus) switch
        {
            var value when string.Equals(value, TopBarStatusClient.DefaultThemeStatus, StringComparison.Ordinal) =>
                TopBarStatusClient.DarkThemeStatus,
            var value when string.Equals(value, TopBarStatusClient.DarkThemeStatus, StringComparison.Ordinal) =>
                TopBarStatusClient.LightThemeStatus,
            _ => TopBarStatusClient.DefaultThemeStatus
        };
}

public sealed class TopBarStatusClient : ITopBarStatusClient
{
    private readonly ITopBarNotificationCenterClient _notificationCenterClient;
    private readonly ITopBarThemePreferenceClient _themePreferenceClient;

    public TopBarStatusClient()
        : this(new InMemoryTopBarNotificationCenterClient(), new InMemoryTopBarThemePreferenceClient())
    {
    }

    public TopBarStatusClient(ITopBarThemePreferenceClient themePreferenceClient)
        : this(new InMemoryTopBarNotificationCenterClient(), themePreferenceClient)
    {
    }

    public TopBarStatusClient(
        ITopBarNotificationCenterClient notificationCenterClient,
        ITopBarThemePreferenceClient themePreferenceClient)
    {
        _notificationCenterClient =
            notificationCenterClient ?? throw new ArgumentNullException(nameof(notificationCenterClient));
        _themePreferenceClient = themePreferenceClient ?? throw new ArgumentNullException(nameof(themePreferenceClient));
    }

    public static string DefaultNotificationsStatus { get; } = "Off";

    public static string NotificationsViewedStatus { get; } = "Viewed";

    public static string DefaultThemeStatus { get; } = "System";

    public static string DarkThemeStatus { get; } = "Dark";

    public static string LightThemeStatus { get; } = "Light";

    public TopBarStatusSnapshot BuildReadOnlySnapshot(TopBarStatusRequest request) =>
        new(
            DateTimeOffset.UtcNow,
            new List<TopBarStatusItem>
            {
                new(
                    TopBarStatusSlot.Connection,
                    "Connection",
                    request.ConnectionStatus,
                    $"Active workspace: {request.SelectedFeatureTitle}"),
                new(
                    TopBarStatusSlot.Diagnostics,
                    "FPS / Diagnostics",
                    request.PerformanceStatus,
                    "Mirrors the TDSC mac top-bar diagnostics slot; renderer telemetry remains provider pending."),
                new(
                    TopBarStatusSlot.Notifications,
                    "Notifications",
                    BuildDefaultStatusValue(TopBarStatusSlot.Notifications),
                    "Visible mac-parity notification entry point; default provider opens an in-memory notification center without permission prompts."),
                new(
                    TopBarStatusSlot.Theme,
                    "Theme",
                    BuildDefaultStatusValue(TopBarStatusSlot.Theme),
                    "Visible mac-parity theme entry point; persistence remains behind Settings.")
            });

    public TopBarResolvedStatusSnapshot BuildResolvedStatusSnapshot(TopBarStatusRequest request)
    {
        var snapshot = BuildReadOnlySnapshot(request);

        return new(
            snapshot.CapturedAt,
            ResolveStatusValue(snapshot, TopBarStatusSlot.Connection, request.ConnectionStatus),
            ResolveStatusValue(snapshot, TopBarStatusSlot.Diagnostics, request.PerformanceStatus),
            ResolveStatusValue(
                snapshot,
                TopBarStatusSlot.Notifications,
                BuildDefaultStatusValue(TopBarStatusSlot.Notifications)),
            ResolveStatusValue(
                snapshot,
                TopBarStatusSlot.Theme,
                BuildDefaultStatusValue(TopBarStatusSlot.Theme)));
    }

    public TopBarStatusUpdateSnapshot BuildStatusUpdate(TopBarStatusRequest request)
    {
        var resolvedStatus = BuildResolvedStatusSnapshot(request);

        return new(
            resolvedStatus,
            BuildWorkspaceActionDetailSnapshot(resolvedStatus));
    }

    public string BuildDefaultStatusValue(TopBarStatusSlot slot) =>
        slot switch
        {
            TopBarStatusSlot.Notifications => _notificationCenterClient.CurrentStatus,
            TopBarStatusSlot.Theme => _themePreferenceClient.CurrentStatus,
            _ => ""
        };

    public string ResolveStatusValue(
        TopBarStatusSnapshot snapshot,
        TopBarStatusSlot slot,
        string fallback)
    {
        foreach (var item in snapshot.Items)
        {
            if (item.Slot == slot)
            {
                return item.Value;
            }
        }

        return fallback;
    }

    public WorkspaceActionDetailSnapshot BuildWorkspaceActionDetailSnapshot(
        TopBarResolvedStatusSnapshot snapshot) =>
        new(snapshot.NotificationsStatus, snapshot.ThemeStatus);

    public bool CanOpenNotifications() => _notificationCenterClient.CanOpenNotifications();

    public bool CanToggleTheme() => true;

    public string BuildNotificationsPendingStatus() => DefaultNotificationsPendingStatus;

    public string BuildThemePendingStatus() => DefaultThemePendingStatus;

    public Task<TopBarWorkspaceActionResult> BuildNotificationsActionAsync() =>
        Task.FromResult(_notificationCenterClient.OpenNotifications());

    public Task<TopBarWorkspaceActionResult> BuildThemeActionAsync() =>
        Task.FromResult(BuildThemeUpdatedActionResult(_themePreferenceClient.Toggle()));

    public static string DefaultNotificationsPendingStatus { get; } = "Preparing notifications...";

    public static string DefaultThemePendingStatus { get; } = "Preparing theme action...";

    public static string DefaultNotificationsBlockedStatus { get; } = "Notifications unavailable";

    public static string DefaultThemeBlockedStatus { get; } = "Theme action unavailable";

    public static string DefaultNotificationsBlockedMessage { get; } =
        "Notification center and permission prompts require an explicit provider before opening.";

    public static string DefaultThemeBlockedMessage { get; } =
        "Theme mutation and persistence remain behind the Settings workspace provider.";

    public static string DefaultNotificationsOpenedMessage { get; } =
        "Top-bar notification center opened in memory only; no Windows notification permissions were requested.";

    public static string DefaultThemeUpdatedMessage { get; } =
        "Top-bar theme preference changed in memory only; no Windows theme or persisted settings were written.";

    public static string NormalizeNotificationsStatus(string status) =>
        status switch
        {
            var value when string.Equals(value, DefaultNotificationsStatus, StringComparison.Ordinal) =>
                DefaultNotificationsStatus,
            var value when string.Equals(value, NotificationsViewedStatus, StringComparison.Ordinal) =>
                NotificationsViewedStatus,
            _ => DefaultNotificationsStatus
        };

    public static TopBarWorkspaceActionResult BuildDefaultNotificationsActionResult() =>
        new(DefaultNotificationsBlockedStatus, DefaultNotificationsBlockedMessage);

    public static TopBarWorkspaceActionResult BuildDefaultThemeActionResult() =>
        new(DefaultThemeBlockedStatus, DefaultThemeBlockedMessage);

    public static TopBarWorkspaceActionResult BuildNotificationsOpenedActionResult(string status) =>
        new(NormalizeNotificationsStatus(status), DefaultNotificationsOpenedMessage);

    public static TopBarWorkspaceActionResult BuildThemeUpdatedActionResult(string status) =>
        new(InMemoryTopBarThemePreferenceClient.NormalizeThemeStatus(status), DefaultThemeUpdatedMessage);
}

public enum TopBarStatusSlot
{
    Connection,
    Diagnostics,
    Notifications,
    Theme
}

public sealed record TopBarStatusRequest(
    string ConnectionStatus,
    string PerformanceStatus,
    string SelectedFeatureTitle);

public sealed record TopBarStatusSnapshot(
    DateTimeOffset CapturedAt,
    IReadOnlyList<TopBarStatusItem> Items);

public sealed record TopBarResolvedStatusSnapshot(
    DateTimeOffset CapturedAt,
    string ConnectionStatus,
    string DiagnosticsStatus,
    string NotificationsStatus,
    string ThemeStatus);

public sealed record TopBarStatusUpdateSnapshot(
    TopBarResolvedStatusSnapshot ResolvedStatus,
    WorkspaceActionDetailSnapshot ActionDetails);

public sealed record TopBarStatusItem(
    TopBarStatusSlot Slot,
    string Label,
    string Value,
    string Detail);

public sealed record TopBarWorkspaceActionResult(
    string Status,
    string Message);
