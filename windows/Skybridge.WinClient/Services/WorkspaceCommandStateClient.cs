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

    public bool CanUseWorkspaceFeature(bool isBusy, bool isFeatureSelected) =>
        !isBusy && isFeatureSelected;

    public WorkspaceActionGateSnapshot BuildActionGateSnapshot(WorkspaceCommandGateRequest request) =>
        new(
            request.CanConnect,
            request.CanDisconnect,
            request.CanSendHeartbeat,
            CanUseWorkspaceFeature(request.IsBusy, request.IsUsbManagementSelected),
            CanUseWorkspaceFeature(request.IsBusy, request.IsFileTransferSelected),
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
    bool CanConnect,
    bool CanDisconnect,
    bool CanSendHeartbeat);
