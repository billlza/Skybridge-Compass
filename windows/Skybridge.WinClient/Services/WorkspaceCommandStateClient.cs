namespace Skybridge.WinClient.Services;

public interface IWorkspaceCommandStateClient
{
    bool CanUseDeviceDiscovery(bool isBusy, bool isDeviceDiscoverySelected);

    bool CanUseDeviceDiscoveryAction(
        bool isBusy,
        bool isDeviceDiscoverySelected,
        bool isActionReady);

    bool CanUseCrossNetworkConnection(bool isBusy, bool isDeviceDiscoverySelected);

    bool CanUseCrossNetworkConnectionAction(
        bool isBusy,
        bool isDeviceDiscoverySelected,
        bool isActionReady);

    bool CanUseFileTransferAction(
        bool isBusy,
        bool isFileTransferSelected,
        bool isActionReady);

    bool CanUseWorkspaceFeature(bool isBusy, bool isFeatureSelected);

    WorkspaceActionGateSnapshot BuildActionGateSnapshot(WorkspaceCommandGateRequest request);
}

public sealed class WorkspaceCommandStateClient : IWorkspaceCommandStateClient
{
    public bool CanUseDeviceDiscovery(bool isBusy, bool isDeviceDiscoverySelected) =>
        !isBusy && isDeviceDiscoverySelected;

    public bool CanUseDeviceDiscoveryAction(
        bool isBusy,
        bool isDeviceDiscoverySelected,
        bool isActionReady) =>
        CanUseDeviceDiscovery(isBusy, isDeviceDiscoverySelected) && isActionReady;

    public bool CanUseCrossNetworkConnection(bool isBusy, bool isDeviceDiscoverySelected) =>
        CanUseDeviceDiscovery(isBusy, isDeviceDiscoverySelected);

    public bool CanUseCrossNetworkConnectionAction(
        bool isBusy,
        bool isDeviceDiscoverySelected,
        bool isActionReady) =>
        CanUseCrossNetworkConnection(isBusy, isDeviceDiscoverySelected) && isActionReady;

    public bool CanUseFileTransferAction(
        bool isBusy,
        bool isFileTransferSelected,
        bool isActionReady) =>
        CanUseWorkspaceFeature(isBusy, isFileTransferSelected) && isActionReady;

    public bool CanUseWorkspaceFeature(bool isBusy, bool isFeatureSelected) =>
        !isBusy && isFeatureSelected;

    public WorkspaceActionGateSnapshot BuildActionGateSnapshot(WorkspaceCommandGateRequest request) =>
        new(
            request.SessionGates.CanConnect,
            request.SessionGates.CanDisconnect,
            request.SessionGates.CanSendHeartbeat,
            request.CanUseDiscoveryBrowser,
            request.CanPrepareManualConnection,
            request.CanParseAdvertisement,
            request.CanValidatePairing,
            request.CanPrepareConnection,
            request.CanUseCrossNetworkConnection,
            request.CanScanQrCode,
            request.CanCopyConnectionCode,
            request.CanConnectConnectionCode,
            CanUseWorkspaceFeature(request.IsBusy, request.IsUsbManagementSelected),
            CanUseWorkspaceFeature(request.IsBusy, request.IsFileTransferSelected),
            request.CanGenerateFileTransferQr,
            CanUseWorkspaceFeature(request.IsBusy, request.IsRemoteDesktopSelected),
            CanUseWorkspaceFeature(request.IsBusy, request.IsQuantumSelected),
            CanUseWorkspaceFeature(request.IsBusy, request.IsSystemMonitorSelected),
            CanUseWorkspaceFeature(request.IsBusy, request.IsSettingsSelected));
}

public sealed record WorkspaceCommandGateRequest(
    bool IsBusy,
    bool IsUsbManagementSelected,
    bool IsFileTransferSelected,
    bool IsRemoteDesktopSelected,
    bool IsQuantumSelected,
    bool IsSystemMonitorSelected,
    bool IsSettingsSelected,
    SessionCommandGateSnapshot SessionGates,
    bool CanUseDiscoveryBrowser,
    bool CanPrepareManualConnection,
    bool CanParseAdvertisement,
    bool CanValidatePairing,
    bool CanPrepareConnection,
    bool CanUseCrossNetworkConnection,
    bool CanScanQrCode,
    bool CanCopyConnectionCode,
    bool CanConnectConnectionCode,
    bool CanGenerateFileTransferQr);
