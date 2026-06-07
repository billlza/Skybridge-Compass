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
}

public enum WorkspaceActionSurface
{
    FileTransfer
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
