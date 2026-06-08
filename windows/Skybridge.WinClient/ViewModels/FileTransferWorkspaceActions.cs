using System;
using System.Threading.Tasks;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class FileTransferWorkspaceActions
{
    private readonly WorkspaceBusyCoordinator _busyCoordinator;
    private readonly IFileTransferWorkspaceClient _fileTransferClient;
    private readonly Action<string> _setFileTransferStatus;
    private readonly Action<string> _setStatusMessage;

    public FileTransferWorkspaceActions(
        WorkspaceBusyCoordinator busyCoordinator,
        IFileTransferWorkspaceClient fileTransferClient,
        Action<string> setFileTransferStatus,
        Action<string> setStatusMessage)
    {
        _busyCoordinator = busyCoordinator ?? throw new ArgumentNullException(nameof(busyCoordinator));
        _fileTransferClient = fileTransferClient ?? throw new ArgumentNullException(nameof(fileTransferClient));
        _setFileTransferStatus = setFileTransferStatus ?? throw new ArgumentNullException(nameof(setFileTransferStatus));
        _setStatusMessage = setStatusMessage ?? throw new ArgumentNullException(nameof(setStatusMessage));
    }

    public Task SelectFilesAsync() =>
        RunAsync(
            _fileTransferClient.BuildSelectFilesPendingStatus,
            _fileTransferClient.BuildSelectFilesActionAsync);

    public Task SelectFolderAsync() =>
        RunAsync(
            _fileTransferClient.BuildSelectFolderPendingStatus,
            _fileTransferClient.BuildSelectFolderActionAsync);

    public Task GenerateQrAsync() =>
        RunAsync(
            _fileTransferClient.BuildShareQrPendingStatus,
            _fileTransferClient.BuildShareQrActionAsync);

    private Task RunAsync(
        Func<string> buildPendingStatus,
        Func<Task<FileTransferWorkspaceActionResult>> buildActionAsync) =>
        _busyCoordinator.RunAsync(
            WorkspaceErrorScope.FileTransfer,
            async () =>
            {
                _setFileTransferStatus(buildPendingStatus());
                var result = await buildActionAsync();
                _setFileTransferStatus(result.Status);
                _setStatusMessage(result.Message);
            });
}
