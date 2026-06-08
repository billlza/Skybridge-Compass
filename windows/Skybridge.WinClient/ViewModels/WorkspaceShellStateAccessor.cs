using System;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceShellStateAccessor
{
    private readonly WorkspaceViewStateBuilder _viewStateBuilder;
    private readonly Func<EngineConnectionState> _getConnectionState;
    private readonly Func<int> _getTransferTaskCount;
    private readonly Func<bool> _getIsBusy;
    private readonly Func<FeatureEntry> _getSelectedFeature;
    private readonly Func<string> _getManualConnectionHost;
    private readonly Func<string> _getManualConnectionPort;
    private readonly Func<string> _getCrossNetworkQrInput;
    private readonly Func<string> _getCrossNetworkCodeInput;
    private readonly Func<string> _getCrossNetworkGeneratedCode;
    private readonly Func<string> _getDiscoveryService;
    private readonly Func<string> _getDiscoveryTxtRecord;
    private readonly Func<string> _getPairingConnectionCode;
    private readonly Func<ConnectionWorkspaceValidatedState> _getValidatedState;
    private readonly Func<bool> _getIsUsbManagementSelected;
    private readonly Func<bool> _getIsFileTransferSelected;
    private readonly Func<bool> _getIsRemoteDesktopSelected;
    private readonly Func<bool> _getIsQuantumSelected;
    private readonly Func<bool> _getIsSystemMonitorSelected;
    private readonly Func<bool> _getIsSettingsSelected;
    private readonly Func<string> _getConnectionStatus;
    private readonly Func<string> _getPerformanceStatus;

    public WorkspaceShellStateAccessor(
        WorkspaceViewStateBuilder viewStateBuilder,
        Func<EngineConnectionState> getConnectionState,
        Func<int> getTransferTaskCount,
        Func<bool> getIsBusy,
        Func<FeatureEntry> getSelectedFeature,
        Func<string> getManualConnectionHost,
        Func<string> getManualConnectionPort,
        Func<string> getCrossNetworkQrInput,
        Func<string> getCrossNetworkCodeInput,
        Func<string> getCrossNetworkGeneratedCode,
        Func<string> getDiscoveryService,
        Func<string> getDiscoveryTxtRecord,
        Func<string> getPairingConnectionCode,
        Func<ConnectionWorkspaceValidatedState> getValidatedState,
        Func<bool> getIsUsbManagementSelected,
        Func<bool> getIsFileTransferSelected,
        Func<bool> getIsRemoteDesktopSelected,
        Func<bool> getIsQuantumSelected,
        Func<bool> getIsSystemMonitorSelected,
        Func<bool> getIsSettingsSelected,
        Func<string> getConnectionStatus,
        Func<string> getPerformanceStatus)
    {
        _viewStateBuilder = viewStateBuilder;
        _getConnectionState = getConnectionState;
        _getTransferTaskCount = getTransferTaskCount;
        _getIsBusy = getIsBusy;
        _getSelectedFeature = getSelectedFeature;
        _getManualConnectionHost = getManualConnectionHost;
        _getManualConnectionPort = getManualConnectionPort;
        _getCrossNetworkQrInput = getCrossNetworkQrInput;
        _getCrossNetworkCodeInput = getCrossNetworkCodeInput;
        _getCrossNetworkGeneratedCode = getCrossNetworkGeneratedCode;
        _getDiscoveryService = getDiscoveryService;
        _getDiscoveryTxtRecord = getDiscoveryTxtRecord;
        _getPairingConnectionCode = getPairingConnectionCode;
        _getValidatedState = getValidatedState;
        _getIsUsbManagementSelected = getIsUsbManagementSelected;
        _getIsFileTransferSelected = getIsFileTransferSelected;
        _getIsRemoteDesktopSelected = getIsRemoteDesktopSelected;
        _getIsQuantumSelected = getIsQuantumSelected;
        _getIsSystemMonitorSelected = getIsSystemMonitorSelected;
        _getIsSettingsSelected = getIsSettingsSelected;
        _getConnectionStatus = getConnectionStatus;
        _getPerformanceStatus = getPerformanceStatus;
    }

    public DashboardMetricsRequest BuildDashboardMetricsRequest() =>
        _viewStateBuilder.BuildDashboardMetricsRequest(
            _getConnectionState(),
            _getTransferTaskCount(),
            _getIsBusy());

    public WorkspaceCommandGateState BuildCommandGateState() =>
        _viewStateBuilder.BuildCommandGateState(
            _getIsBusy(),
            _getConnectionState(),
            _getSelectedFeature(),
            _getManualConnectionHost(),
            _getManualConnectionPort(),
            _getCrossNetworkQrInput(),
            _getCrossNetworkCodeInput(),
            _getCrossNetworkGeneratedCode(),
            _getDiscoveryService(),
            _getDiscoveryTxtRecord(),
            _getPairingConnectionCode(),
            _getValidatedState());

    public WorkspaceActionRenderState BuildActionRenderState()
    {
        var selectedFeature = _getSelectedFeature();
        return _viewStateBuilder.BuildActionRenderState(
            _getIsBusy(),
            _getIsUsbManagementSelected(),
            _getIsFileTransferSelected(),
            _getIsRemoteDesktopSelected(),
            _getIsQuantumSelected(),
            _getIsSystemMonitorSelected(),
            _getIsSettingsSelected(),
            _getConnectionState(),
            _getConnectionStatus(),
            _getPerformanceStatus(),
            selectedFeature.Title);
    }
}
