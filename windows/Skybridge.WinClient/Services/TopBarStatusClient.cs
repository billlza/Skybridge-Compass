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

public sealed class TopBarStatusClient : ITopBarStatusClient
{
    public static string DefaultNotificationsStatus { get; } = "Off";

    public static string DefaultThemeStatus { get; } = "System";

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
                    "Visible mac-parity notification entry point; permission prompts remain disabled until Settings owns the explicit write."),
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
            TopBarStatusSlot.Notifications => DefaultNotificationsStatus,
            TopBarStatusSlot.Theme => DefaultThemeStatus,
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

    public bool CanOpenNotifications() => false;

    public bool CanToggleTheme() => false;

    public string BuildNotificationsPendingStatus() => DefaultNotificationsPendingStatus;

    public string BuildThemePendingStatus() => DefaultThemePendingStatus;

    public Task<TopBarWorkspaceActionResult> BuildNotificationsActionAsync() =>
        Task.FromResult(BuildDefaultNotificationsActionResult());

    public Task<TopBarWorkspaceActionResult> BuildThemeActionAsync() =>
        Task.FromResult(BuildDefaultThemeActionResult());

    public static string DefaultNotificationsPendingStatus { get; } = "Preparing notifications...";

    public static string DefaultThemePendingStatus { get; } = "Preparing theme action...";

    public static string DefaultNotificationsBlockedStatus { get; } = "Notifications unavailable";

    public static string DefaultThemeBlockedStatus { get; } = "Theme action unavailable";

    public static string DefaultNotificationsBlockedMessage { get; } =
        "Notification center and permission prompts require an explicit provider before opening.";

    public static string DefaultThemeBlockedMessage { get; } =
        "Theme mutation and persistence remain behind the Settings workspace provider.";

    public static TopBarWorkspaceActionResult BuildDefaultNotificationsActionResult() =>
        new(DefaultNotificationsBlockedStatus, DefaultNotificationsBlockedMessage);

    public static TopBarWorkspaceActionResult BuildDefaultThemeActionResult() =>
        new(DefaultThemeBlockedStatus, DefaultThemeBlockedMessage);
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
