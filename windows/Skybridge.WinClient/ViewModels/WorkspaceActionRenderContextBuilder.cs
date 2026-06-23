using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceActionRenderContextBuilder
{
    private readonly WorkspaceCommandGateCoordinator _workspaceCommandGateCoordinator;
    private readonly Func<WorkspaceCommandGateState> _buildCommandGateState;
    private readonly TopBarStatusUpdater _topBarStatusUpdater;

    public WorkspaceActionRenderContextBuilder(
        WorkspaceCommandGateCoordinator workspaceCommandGateCoordinator,
        Func<WorkspaceCommandGateState> buildCommandGateState,
        TopBarStatusUpdater topBarStatusUpdater)
    {
        _workspaceCommandGateCoordinator = workspaceCommandGateCoordinator;
        _buildCommandGateState = buildCommandGateState;
        _topBarStatusUpdater = topBarStatusUpdater;
    }

    public WorkspaceActionGateSnapshot BuildGateSnapshot(WorkspaceActionRenderState state) =>
        _workspaceCommandGateCoordinator.BuildActionGateSnapshot(
            _buildCommandGateState());

    public TopBarStatusRequest BuildTopBarStatusRequest(WorkspaceActionRenderState state) =>
        new(
            state.ConnectionStatus,
            state.PerformanceStatus,
            state.SelectedFeatureTitle);

    public WorkspaceActionRenderContext BuildContext(
        WorkspaceActionRenderState state,
        WorkspaceActionDetailSnapshot? actionDetails = null) =>
        new(
            BuildGateSnapshot(state),
            actionDetails ?? _topBarStatusUpdater.BuildActionDetails(BuildTopBarStatusRequest(state)));
}

internal sealed record WorkspaceActionRenderState(
    bool IsBusy,
    bool IsUsbManagementSelected,
    bool IsFileTransferSelected,
    bool IsRemoteDesktopSelected,
    bool IsSystemMonitorSelected,
    bool IsSettingsSelected,
    EngineConnectionState ConnectionState,
    string ConnectionStatus,
    string PerformanceStatus,
    string SelectedFeatureTitle);

internal sealed record WorkspaceActionRenderContext(
    WorkspaceActionGateSnapshot Gates,
    WorkspaceActionDetailSnapshot Details);
