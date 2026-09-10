using System;
using System.Collections.Generic;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface IFileTransferWorkspaceClient
{
    string BuildInitialStatus();

    string BuildPendingStatus();

    string BuildCompletedStatus(FileTransferWorkspaceSnapshot snapshot);

    string BuildCompletedStatusMessage();

    bool CanSelectFiles();

    bool CanSelectFolder();

    bool CanGenerateShareQr();

    string BuildSelectFilesPendingStatus();

    string BuildSelectFolderPendingStatus();

    string BuildShareQrPendingStatus();

    Task<FileTransferWorkspaceSnapshot> BuildReadOnlySnapshotAsync();

    Task<FileTransferWorkspaceActionResult> BuildSelectFilesActionAsync();

    Task<FileTransferWorkspaceActionResult> BuildSelectFolderActionAsync();

    Task<FileTransferWorkspaceActionResult> BuildShareQrActionAsync();
}

public sealed record FileTransferWorkspaceSnapshot(
    DateTimeOffset CapturedAt,
    IReadOnlyList<FileTransferQueueItem> Queue,
    IReadOnlyList<FileTransferHistoryItem> History,
    IReadOnlyList<FileTransferSecurityFact> Security);

public sealed record FileTransferQueueItem(
    string Name,
    string State,
    string Size,
    string Binding,
    string Detail);

public sealed record FileTransferHistoryItem(
    string Name,
    string Result,
    string FileHash,
    string Detail);

public sealed record FileTransferSecurityFact(
    string Label,
    string Value,
    string Detail);

public sealed record FileTransferWorkspaceActionResult(
    string Status,
    string Message,
    string Detail,
    string? ShareQrPayload = null,
    string? ShareQrPngBase64 = null);
