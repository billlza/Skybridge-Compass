using System;
using System.Threading.Tasks;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceBusyCoordinator
{
    private readonly Func<bool> _isBusy;
    private readonly Action<bool> _setBusy;
    private readonly WorkspaceStatusPatchApplier _statusPatchApplier;
    private readonly IWorkspaceErrorStatusClient _workspaceErrorStatusClient;

    public WorkspaceBusyCoordinator(
        Func<bool> isBusy,
        Action<bool> setBusy,
        WorkspaceStatusPatchApplier statusPatchApplier,
        IWorkspaceErrorStatusClient workspaceErrorStatusClient)
    {
        _isBusy = isBusy;
        _setBusy = setBusy;
        _statusPatchApplier = statusPatchApplier;
        _workspaceErrorStatusClient = workspaceErrorStatusClient;
    }

    public async Task RunAsync(
        WorkspaceErrorScope errorScope,
        Func<Task> action)
    {
        if (_isBusy())
        {
            return;
        }

        try
        {
            _setBusy(true);
            await action();
        }
        catch (Exception ex)
        {
            _statusPatchApplier.Apply(
                _workspaceErrorStatusClient.BuildErrorPatch(errorScope, ex.Message));
        }
        finally
        {
            _setBusy(false);
        }
    }

    public Task RefreshReadOnlyWorkspaceAsync<TSnapshot>(
        WorkspaceErrorScope errorScope,
        Func<string> buildPendingStatus,
        Func<Task<TSnapshot>> buildSnapshotAsync,
        Action<TSnapshot> applySnapshot,
        Func<TSnapshot, string> buildCompletedStatus,
        Func<string> buildCompletedStatusMessage,
        Action<string> setWorkspaceStatus,
        Action<string> setStatusMessage) =>
        RunAsync(errorScope, async () =>
        {
            setWorkspaceStatus(buildPendingStatus());
            var snapshot = await buildSnapshotAsync();
            applySnapshot(snapshot);
            setWorkspaceStatus(buildCompletedStatus(snapshot));
            setStatusMessage(buildCompletedStatusMessage());
        });
}
