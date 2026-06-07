using System;
using System.Collections.Generic;

namespace Skybridge.WinClient.Services;

public interface IWorkspaceActionCatalogClient
{
    WorkspaceActionCatalogSnapshot BuildReadOnlySnapshot(WorkspaceActionCatalogRequest request);
}

public sealed class WorkspaceActionCatalogClient : IWorkspaceActionCatalogClient
{
    public WorkspaceActionCatalogSnapshot BuildReadOnlySnapshot(WorkspaceActionCatalogRequest request) =>
        new(
            DateTimeOffset.UtcNow,
            request.Surface,
            request.Surface switch
            {
                WorkspaceActionSurface.FileTransfer => BuildFileTransferActions(),
                WorkspaceActionSurface.RemoteDesktop => BuildRemoteDesktopActions(),
                _ => new List<WorkspaceActionItem>()
            });

    private static IReadOnlyList<WorkspaceActionItem> BuildFileTransferActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "SelectFiles",
                "Select Files",
                "\uE8E5",
                false,
                "Visible mac-parity quick action; file picker is pending."),
            new(
                "SelectFolder",
                "Select Folder",
                "\uE8B7",
                false,
                "Visible mac-parity quick action; folder picker is pending."),
            new(
                "GenerateQr",
                "Generate QR",
                "\uE97E",
                false,
                "Visible mac-parity quick action; live share QR generation is pending.")
        };

    private static IReadOnlyList<WorkspaceActionItem> BuildRemoteDesktopActions() =>
        new List<WorkspaceActionItem>
        {
            new(
                "RecommendedConnect",
                "Recommended Connect",
                "\uE710",
                false,
                "Visible mac-parity quick action; live recommended session launch is pending."),
            new(
                "AdvancedConnect",
                "Advanced Connect",
                "\uE8A7",
                false,
                "Visible mac-parity quick action; advanced endpoint selection is pending."),
            new(
                "PerformanceOverlay",
                "Performance Overlay",
                "\uE9D9",
                false,
                "Visible mac-parity quick action; live overlay telemetry is pending."),
            new(
                "Quality",
                "Quality",
                "\uE7F4",
                false,
                "Visible mac-parity quick action; live encoder quality application is pending."),
            new(
                "Settings",
                "Settings",
                "\uE713",
                false,
                "Visible mac-parity quick action; Remote Desktop runtime settings remain read-only."),
            new(
                "FullScreen",
                "Full Screen",
                "\uE740",
                false,
                "Visible mac-parity quick action; live session windowing is pending."),
            new(
                "DisconnectSession",
                "Disconnect Session",
                "\uE711",
                false,
                "Visible mac-parity quick action; no live session termination is wired.")
        };
}

public enum WorkspaceActionSurface
{
    FileTransfer,
    RemoteDesktop
}

public sealed record WorkspaceActionCatalogRequest(
    WorkspaceActionSurface Surface);

public sealed record WorkspaceActionCatalogSnapshot(
    DateTimeOffset CapturedAt,
    WorkspaceActionSurface Surface,
    IReadOnlyList<WorkspaceActionItem> Actions);

public sealed record WorkspaceActionItem(
    string Key,
    string Title,
    string Glyph,
    bool IsEnabled,
    string Detail);
