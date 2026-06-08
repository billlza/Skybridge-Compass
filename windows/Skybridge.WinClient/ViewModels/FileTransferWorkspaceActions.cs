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
    private readonly Action<string?> _setFileTransferShareQrCodePngBase64;

    public FileTransferWorkspaceActions(
        WorkspaceBusyCoordinator busyCoordinator,
        IFileTransferWorkspaceClient fileTransferClient,
        Action<string> setFileTransferStatus,
        Action<string> setStatusMessage,
        Action<string?> setFileTransferShareQrCodePngBase64)
    {
        _busyCoordinator = busyCoordinator ?? throw new ArgumentNullException(nameof(busyCoordinator));
        _fileTransferClient = fileTransferClient ?? throw new ArgumentNullException(nameof(fileTransferClient));
        _setFileTransferStatus = setFileTransferStatus ?? throw new ArgumentNullException(nameof(setFileTransferStatus));
        _setStatusMessage = setStatusMessage ?? throw new ArgumentNullException(nameof(setStatusMessage));
        _setFileTransferShareQrCodePngBase64 = setFileTransferShareQrCodePngBase64 ?? throw new ArgumentNullException(nameof(setFileTransferShareQrCodePngBase64));
    }

    public Task SelectFilesAsync() =>
        RunAsync(
            _fileTransferClient.BuildSelectFilesPendingStatus,
            _fileTransferClient.BuildSelectFilesActionAsync,
            _ => { });

    public Task SelectFolderAsync() =>
        RunAsync(
            _fileTransferClient.BuildSelectFolderPendingStatus,
            _fileTransferClient.BuildSelectFolderActionAsync,
            _ => { });

    public Task GenerateQrAsync() =>
        RunAsync(
            _fileTransferClient.BuildShareQrPendingStatus,
            _fileTransferClient.BuildShareQrActionAsync,
            result => _setFileTransferShareQrCodePngBase64(result.ShareQrPngBase64));

    private Task RunAsync(
        Func<string> buildPendingStatus,
        Func<Task<FileTransferWorkspaceActionResult>> buildActionAsync,
        Action<FileTransferWorkspaceActionResult> applyResult) =>
        _busyCoordinator.RunAsync(
            WorkspaceErrorScope.FileTransfer,
            async () =>
            {
                _setFileTransferStatus(buildPendingStatus());
                var result = await buildActionAsync();
                _setFileTransferStatus(result.Status);
                _setStatusMessage(result.Message);
                applyResult(result);
            });
}
