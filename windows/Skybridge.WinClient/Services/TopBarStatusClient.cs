using System;
using System.Collections.Generic;

namespace Skybridge.WinClient.Services;

public interface ITopBarStatusClient
{
    TopBarStatusSnapshot BuildReadOnlySnapshot(TopBarStatusRequest request);

    string BuildDefaultStatusValue(TopBarStatusSlot slot);

    string ResolveStatusValue(
        TopBarStatusSnapshot snapshot,
        TopBarStatusSlot slot,
        string fallback);
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

public sealed record TopBarStatusItem(
    TopBarStatusSlot Slot,
    string Label,
    string Value,
    string Detail);
