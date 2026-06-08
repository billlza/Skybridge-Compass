namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceInputChangeRouter
{
    private readonly WorkspaceShellRefreshCoordinator _shellRefreshCoordinator;
    private readonly ConnectionWorkspaceInputCoordinator _inputCoordinator;

    public WorkspaceInputChangeRouter(
        WorkspaceShellRefreshCoordinator shellRefreshCoordinator,
        ConnectionWorkspaceInputCoordinator inputCoordinator)
    {
        _shellRefreshCoordinator = shellRefreshCoordinator;
        _inputCoordinator = inputCoordinator;
    }

    public void DiscoveryInputChanged() =>
        _shellRefreshCoordinator.ApplyWorkspaceInputChange(
            _inputCoordinator.InvalidatePairingAndPreflight);

    public void DiscoverySearchChanged() =>
        _shellRefreshCoordinator.ApplyWorkspaceInputChange();

    public void ManualTargetChanged() =>
        _shellRefreshCoordinator.ApplyWorkspaceInputChange(
            _inputCoordinator.ResetManualConnectionInput);

    public void CrossNetworkInputChanged() =>
        _shellRefreshCoordinator.ApplyWorkspaceInputChange(
            _inputCoordinator.ResetCrossNetworkInput);

    public void PairingInputChanged() =>
        _shellRefreshCoordinator.ApplyWorkspaceInputChange(
            _inputCoordinator.ResetPairingInput);
}
