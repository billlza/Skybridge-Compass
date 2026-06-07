using System;
using System.Collections.Generic;

namespace Skybridge.WinClient.Services;

public interface ITopBarStatusClient
{
    TopBarStatusSnapshot BuildReadOnlySnapshot(TopBarStatusRequest request);
}

public sealed class TopBarStatusClient : ITopBarStatusClient
{
    public TopBarStatusSnapshot BuildReadOnlySnapshot(TopBarStatusRequest request) =>
        new(
            DateTimeOffset.UtcNow,
            new List<TopBarStatusItem>
            {
                new(
                    "Connection",
                    request.ConnectionStatus,
                    $"Active workspace: {request.SelectedFeatureTitle}"),
                new(
                    "FPS / Diagnostics",
                    request.PerformanceStatus,
                    "Mirrors the TDSC mac top-bar diagnostics slot; renderer telemetry remains provider pending."),
                new(
                    "Notifications",
                    "Off",
                    "Visible mac-parity notification entry point; permission prompts remain disabled until Settings owns the explicit write."),
                new(
                    "Theme",
                    "System",
                    "Visible mac-parity theme entry point; persistence remains behind Settings.")
            });
}

public sealed record TopBarStatusRequest(
    string ConnectionStatus,
    string PerformanceStatus,
    string SelectedFeatureTitle);

public sealed record TopBarStatusSnapshot(
    DateTimeOffset CapturedAt,
    IReadOnlyList<TopBarStatusItem> Items);

public sealed record TopBarStatusItem(
    string Label,
    string Value,
    string Detail);
