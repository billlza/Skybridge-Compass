using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceShellStateAccessor
{
    private readonly WorkspaceViewStateBuilder _viewStateBuilder;
    private readonly WorkspaceShellStateSource _stateSource;

    public WorkspaceShellStateAccessor(
        WorkspaceViewStateBuilder viewStateBuilder,
        WorkspaceShellStateSource stateSource)
    {
        _viewStateBuilder = viewStateBuilder;
        _stateSource = stateSource;
    }

    public DashboardMetricsRequest BuildDashboardMetricsRequest() =>
        _viewStateBuilder.BuildDashboardMetricsRequest(
            _stateSource.ConnectionState,
            _stateSource.TransferTaskCount,
            _stateSource.IsBusy);

    public WorkspaceCommandGateState BuildCommandGateState() =>
        _viewStateBuilder.BuildCommandGateState(
            _stateSource.IsBusy,
            _stateSource.ConnectionState,
            _stateSource.SelectedFeature,
            _stateSource.ManualConnectionHost,
            _stateSource.ManualConnectionPort,
            _stateSource.CrossNetworkQrInput,
            _stateSource.CrossNetworkCodeInput,
            _stateSource.CrossNetworkGeneratedCode,
            _stateSource.DiscoveryService,
            _stateSource.DiscoveryTxtRecord,
            _stateSource.PairingConnectionCode,
            _stateSource.ValidatedState);

    public WorkspaceActionRenderState BuildActionRenderState()
    {
        return _viewStateBuilder.BuildActionRenderState(
            _stateSource.IsBusy,
            _stateSource.IsUsbManagementSelected,
            _stateSource.IsFileTransferSelected,
            _stateSource.IsRemoteDesktopSelected,
            _stateSource.IsSystemMonitorSelected,
            _stateSource.IsSettingsSelected,
            _stateSource.ConnectionState,
            _stateSource.ConnectionStatus,
            _stateSource.PerformanceStatus,
            _stateSource.SelectedFeature.Title);
    }
}
