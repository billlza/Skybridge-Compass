using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceViewStateBuilder
{
    public DiscoveryBrowserRequest BuildDiscoveryBrowserRequest(
        DiscoveryBrowserAction action,
        string discoveryService,
        string discoveryTxtRecord,
        string discoverySearchText,
        bool isDiscoveryCompatibilityModeEnabled,
        int extendedSearchCountdown) =>
        new(
            action,
            discoveryService,
            discoveryTxtRecord,
            discoverySearchText,
            isDiscoveryCompatibilityModeEnabled,
            extendedSearchCountdown);

    public ManualConnectionRequest BuildManualConnectionRequest(
        string manualConnectionHost,
        string manualConnectionPort,
        string manualConnectionCode) =>
        new(
            manualConnectionHost,
            manualConnectionPort,
            manualConnectionCode);

    public CrossNetworkConnectionRequest BuildCrossNetworkConnectionRequest(
        CrossNetworkConnectionAction action,
        string crossNetworkQrInput,
        string crossNetworkCodeInput,
        string crossNetworkGeneratedCode) =>
        new(
            action,
            crossNetworkQrInput,
            crossNetworkCodeInput,
            crossNetworkGeneratedCode);

    public DashboardMetricsRequest BuildDashboardMetricsRequest(
        EngineConnectionState connectionState,
        int transferTaskCount,
        bool isBusy) =>
        new(
            connectionState,
            transferTaskCount,
            isBusy);

    public WorkspaceCommandGateState BuildCommandGateState(
        bool isBusy,
        EngineConnectionState connectionState,
        FeatureEntry selectedFeature,
        string manualConnectionHost,
        string manualConnectionPort,
        string crossNetworkQrInput,
        string crossNetworkCodeInput,
        string crossNetworkGeneratedCode,
        string discoveryService,
        string discoveryTxtRecord,
        string pairingConnectionCode,
        ConnectionWorkspaceValidatedState validatedState) =>
        new(
            isBusy,
            connectionState,
            selectedFeature,
            manualConnectionHost,
            manualConnectionPort,
            crossNetworkQrInput,
            crossNetworkCodeInput,
            crossNetworkGeneratedCode,
            discoveryService,
            discoveryTxtRecord,
            pairingConnectionCode,
            validatedState);

    public WorkspaceActionRenderState BuildActionRenderState(
        bool isBusy,
        bool isUsbManagementSelected,
        bool isFileTransferSelected,
        bool isRemoteDesktopSelected,
        bool isQuantumSelected,
        bool isSystemMonitorSelected,
        bool isSettingsSelected,
        EngineConnectionState connectionState,
        string connectionStatus,
        string performanceStatus,
        string selectedFeatureTitle) =>
        new(
            isBusy,
            isUsbManagementSelected,
            isFileTransferSelected,
            isRemoteDesktopSelected,
            isQuantumSelected,
            isSystemMonitorSelected,
            isSettingsSelected,
            connectionState,
            connectionStatus,
            performanceStatus,
            selectedFeatureTitle);
}
