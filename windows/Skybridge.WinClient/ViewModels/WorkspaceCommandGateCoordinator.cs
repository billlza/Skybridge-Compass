using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceCommandGateCoordinator
{
    private readonly ISessionCommandStateClient _sessionCommandStateClient;
    private readonly IFeatureCatalogClient _featureCatalogClient;
    private readonly IWorkspaceCommandStateClient _workspaceCommandStateClient;
    private readonly IManualConnectionClient _manualConnectionClient;
    private readonly ICrossNetworkConnectionClient _crossNetworkConnectionClient;
    private readonly IFileTransferWorkspaceClient _fileTransferClient;
    private readonly IDiscoveryClient _discoveryClient;
    private readonly IPairingMaterialClient _pairingMaterialClient;
    private readonly IConnectionWorkspaceStateClient _connectionWorkspaceStateClient;

    public WorkspaceCommandGateCoordinator(
        ISessionCommandStateClient sessionCommandStateClient,
        IFeatureCatalogClient featureCatalogClient,
        IWorkspaceCommandStateClient workspaceCommandStateClient,
        IManualConnectionClient manualConnectionClient,
        ICrossNetworkConnectionClient crossNetworkConnectionClient,
        IFileTransferWorkspaceClient fileTransferClient,
        IDiscoveryClient discoveryClient,
        IPairingMaterialClient pairingMaterialClient,
        IConnectionWorkspaceStateClient connectionWorkspaceStateClient)
    {
        _sessionCommandStateClient = sessionCommandStateClient;
        _featureCatalogClient = featureCatalogClient;
        _workspaceCommandStateClient = workspaceCommandStateClient;
        _manualConnectionClient = manualConnectionClient;
        _crossNetworkConnectionClient = crossNetworkConnectionClient;
        _fileTransferClient = fileTransferClient;
        _discoveryClient = discoveryClient;
        _pairingMaterialClient = pairingMaterialClient;
        _connectionWorkspaceStateClient = connectionWorkspaceStateClient;
    }

    public bool IsFeatureSelected(FeatureEntry selectedFeature, FeatureEntryId featureId) =>
        _featureCatalogClient.IsSelected(selectedFeature, featureId);

    public bool CanConnect(WorkspaceCommandGateState state) =>
        _sessionCommandStateClient.CanConnect(state.ConnectionState, state.IsBusy)
            && _connectionWorkspaceStateClient.BuildLiveConnectionLaunchReadiness(
                state.ValidatedState).IsReady;

    public bool CanDisconnect(WorkspaceCommandGateState state) =>
        _sessionCommandStateClient.CanDisconnect(state.ConnectionState, state.IsBusy);

    public bool CanSendHeartbeat(WorkspaceCommandGateState state) =>
        _sessionCommandStateClient.CanSendHeartbeat(state.ConnectionState, state.IsBusy);

    public bool CanUseDiscoveryBrowser(WorkspaceCommandGateState state) =>
        _workspaceCommandStateClient.CanUseDeviceDiscovery(
            state.IsBusy,
            IsFeatureSelected(state.SelectedFeature, FeatureEntryId.DeviceDiscovery));

    public bool CanPrepareManualConnection(WorkspaceCommandGateState state) =>
        CanUseDeviceDiscoveryAction(
            state,
            _manualConnectionClient.CanPrepareTarget(
                state.ManualConnectionHost,
                state.ManualConnectionPort));

    public bool CanUseCrossNetworkConnection(WorkspaceCommandGateState state) =>
        _workspaceCommandStateClient.CanUseCrossNetworkConnection(
            state.IsBusy,
            IsFeatureSelected(state.SelectedFeature, FeatureEntryId.DeviceDiscovery));

    public bool CanScanQrCode(WorkspaceCommandGateState state) =>
        CanUseCrossNetworkConnectionAction(
            state,
            _crossNetworkConnectionClient.CanScanQrCode(state.CrossNetworkQrInput));

    public bool CanCopyConnectionCode(WorkspaceCommandGateState state) =>
        CanUseCrossNetworkConnectionAction(
            state,
            _crossNetworkConnectionClient.CanCopyCode(state.CrossNetworkGeneratedCode));

    public bool CanConnectConnectionCode(WorkspaceCommandGateState state) =>
        CanUseCrossNetworkConnectionAction(
            state,
            _crossNetworkConnectionClient.CanConnectWithCode(state.CrossNetworkCodeInput));

    public bool CanParseAdvertisement(WorkspaceCommandGateState state) =>
        CanUseDeviceDiscoveryAction(
            state,
            _discoveryClient.CanParseAdvertisement(
                state.DiscoveryService,
                state.DiscoveryTxtRecord));

    public bool CanValidatePairingCode(WorkspaceCommandGateState state) =>
        CanUseDeviceDiscoveryAction(
            state,
            _pairingMaterialClient.CanValidate(state.PairingConnectionCode));

    public bool CanPrepareConnection(WorkspaceCommandGateState state) =>
        CanUseDeviceDiscoveryAction(
            state,
            _connectionWorkspaceStateClient.CanPreparePreflight(
                state.ValidatedState.DiscoveredPeer,
                state.ValidatedState.PairingMaterial));

    public bool CanRefreshUsbManagement(WorkspaceCommandGateState state) =>
        CanUseSelectedWorkspaceFeature(state, FeatureEntryId.UsbManagement);

    public bool CanRunCoreDiagnostics(WorkspaceCommandGateState state) =>
        CanUseSelectedWorkspaceFeature(state, FeatureEntryId.Quantum);

    public bool CanRefreshFileTransfer(WorkspaceCommandGateState state) =>
        CanUseSelectedWorkspaceFeature(state, FeatureEntryId.FileTransfer);

    public bool CanSelectFileTransferFiles(WorkspaceCommandGateState state) =>
        CanUseFileTransferAction(
            state,
            _fileTransferClient.CanSelectFiles());

    public bool CanSelectFileTransferFolder(WorkspaceCommandGateState state) =>
        CanUseFileTransferAction(
            state,
            _fileTransferClient.CanSelectFolder());

    public bool CanGenerateFileTransferQr(WorkspaceCommandGateState state) =>
        CanUseFileTransferAction(
            state,
            _fileTransferClient.CanGenerateShareQr());

    public bool CanRefreshRemoteDesktop(WorkspaceCommandGateState state) =>
        CanUseSelectedWorkspaceFeature(state, FeatureEntryId.RemoteDesktop);

    public bool CanRefreshSystemMonitor(WorkspaceCommandGateState state) =>
        CanUseSelectedWorkspaceFeature(state, FeatureEntryId.SystemMonitor);

    public bool CanRefreshSettings(WorkspaceCommandGateState state) =>
        CanUseSelectedWorkspaceFeature(state, FeatureEntryId.Settings);

    public WorkspaceActionGateSnapshot BuildActionGateSnapshot(
        WorkspaceCommandGateState state)
    {
        var sessionGates = _sessionCommandStateClient.BuildGateSnapshot(
            state.ConnectionState,
            state.IsBusy);
        var launchAwareSessionGates = sessionGates with
        {
            CanConnect = CanConnect(state)
        };

        return _workspaceCommandStateClient.BuildActionGateSnapshot(
            new WorkspaceCommandGateRequest(
                state.IsBusy,
                IsFeatureSelected(state.SelectedFeature, FeatureEntryId.UsbManagement),
                IsFeatureSelected(state.SelectedFeature, FeatureEntryId.FileTransfer),
                IsFeatureSelected(state.SelectedFeature, FeatureEntryId.RemoteDesktop),
                IsFeatureSelected(state.SelectedFeature, FeatureEntryId.Quantum),
                IsFeatureSelected(state.SelectedFeature, FeatureEntryId.SystemMonitor),
                IsFeatureSelected(state.SelectedFeature, FeatureEntryId.Settings),
                launchAwareSessionGates,
                CanUseDiscoveryBrowser(state),
                CanPrepareManualConnection(state),
                CanParseAdvertisement(state),
                CanValidatePairingCode(state),
                CanPrepareConnection(state),
                CanUseCrossNetworkConnection(state),
                CanScanQrCode(state),
                CanCopyConnectionCode(state),
                CanConnectConnectionCode(state),
                CanSelectFileTransferFiles(state),
                CanSelectFileTransferFolder(state),
                CanGenerateFileTransferQr(state)));
    }

    private bool CanUseDeviceDiscoveryAction(
        WorkspaceCommandGateState state,
        bool readiness) =>
        _workspaceCommandStateClient.CanUseDeviceDiscoveryAction(
            state.IsBusy,
            IsFeatureSelected(state.SelectedFeature, FeatureEntryId.DeviceDiscovery),
            readiness);

    private bool CanUseCrossNetworkConnectionAction(
        WorkspaceCommandGateState state,
        bool readiness) =>
        _workspaceCommandStateClient.CanUseCrossNetworkConnectionAction(
            state.IsBusy,
            IsFeatureSelected(state.SelectedFeature, FeatureEntryId.DeviceDiscovery),
            readiness);

    private bool CanUseFileTransferAction(
        WorkspaceCommandGateState state,
        bool readiness) =>
        _workspaceCommandStateClient.CanUseFileTransferAction(
            state.IsBusy,
            IsFeatureSelected(state.SelectedFeature, FeatureEntryId.FileTransfer),
            readiness);

    private bool CanUseSelectedWorkspaceFeature(
        WorkspaceCommandGateState state,
        FeatureEntryId featureId) =>
        _workspaceCommandStateClient.CanUseWorkspaceFeature(
            state.IsBusy,
            IsFeatureSelected(state.SelectedFeature, featureId));
}

internal sealed record WorkspaceCommandGateState(
    bool IsBusy,
    EngineConnectionState ConnectionState,
    FeatureEntry SelectedFeature,
    string ManualConnectionHost,
    string ManualConnectionPort,
    string CrossNetworkQrInput,
    string CrossNetworkCodeInput,
    string CrossNetworkGeneratedCode,
    string DiscoveryService,
    string DiscoveryTxtRecord,
    string PairingConnectionCode,
    ConnectionWorkspaceValidatedState ValidatedState);
