using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceActionRenderContextBuilder
{
    private readonly IWorkspaceCommandStateClient _workspaceCommandStateClient;
    private readonly ISessionCommandStateClient _sessionCommandStateClient;
    private readonly TopBarStatusUpdater _topBarStatusUpdater;

    public WorkspaceActionRenderContextBuilder(
        IWorkspaceCommandStateClient workspaceCommandStateClient,
        ISessionCommandStateClient sessionCommandStateClient,
        TopBarStatusUpdater topBarStatusUpdater)
    {
        _workspaceCommandStateClient = workspaceCommandStateClient;
        _sessionCommandStateClient = sessionCommandStateClient;
        _topBarStatusUpdater = topBarStatusUpdater;
    }

    public WorkspaceActionGateSnapshot BuildGateSnapshot(WorkspaceActionRenderState state) =>
        _workspaceCommandStateClient.BuildActionGateSnapshot(
            new WorkspaceCommandGateRequest(
                state.IsBusy,
                state.IsUsbManagementSelected,
                state.IsFileTransferSelected,
                state.IsRemoteDesktopSelected,
                state.IsQuantumSelected,
                state.IsSystemMonitorSelected,
                state.IsSettingsSelected,
                _sessionCommandStateClient.BuildGateSnapshot(
                    state.ConnectionState,
                    state.IsBusy)));

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
    bool IsQuantumSelected,
    bool IsSystemMonitorSelected,
    bool IsSettingsSelected,
    EngineConnectionState ConnectionState,
    string ConnectionStatus,
    string PerformanceStatus,
    string SelectedFeatureTitle);

internal sealed record WorkspaceActionRenderContext(
    WorkspaceActionGateSnapshot Gates,
    WorkspaceActionDetailSnapshot Details);
