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

    bool CanUseTopBarAction(bool isBusy, bool isActionReady);

    bool CanUseFileTransferAction(
        bool isBusy,
        bool isFileTransferSelected,
        bool isActionReady);

    bool CanUseRemoteDesktopAction(
        bool isBusy,
        bool isRemoteDesktopSelected,
        bool isActionReady);

    bool CanUseSystemMonitorAction(
        bool isBusy,
        bool isSystemMonitorSelected,
        bool isActionReady);

    bool CanUseSettingsAction(
        bool isBusy,
        bool isSettingsSelected,
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

    public bool CanUseTopBarAction(bool isBusy, bool isActionReady) =>
        !isBusy && isActionReady;

    public bool CanUseFileTransferAction(
        bool isBusy,
        bool isFileTransferSelected,
        bool isActionReady) =>
        CanUseWorkspaceFeature(isBusy, isFileTransferSelected) && isActionReady;

    public bool CanUseRemoteDesktopAction(
        bool isBusy,
        bool isRemoteDesktopSelected,
        bool isActionReady) =>
        CanUseWorkspaceFeature(isBusy, isRemoteDesktopSelected) && isActionReady;

    public bool CanUseSystemMonitorAction(
        bool isBusy,
        bool isSystemMonitorSelected,
        bool isActionReady) =>
        CanUseWorkspaceFeature(isBusy, isSystemMonitorSelected) && isActionReady;

    public bool CanUseSettingsAction(
        bool isBusy,
        bool isSettingsSelected,
        bool isActionReady) =>
        CanUseWorkspaceFeature(isBusy, isSettingsSelected) && isActionReady;

    public bool CanUseWorkspaceFeature(bool isBusy, bool isFeatureSelected) =>
        !isBusy && isFeatureSelected;

    public WorkspaceActionGateSnapshot BuildActionGateSnapshot(WorkspaceCommandGateRequest request) =>
        new(
            request.SessionGates.CanConnect,
            request.SessionGates.CanDisconnect,
            request.SessionGates.CanSendHeartbeat,
            request.CanOpenTopBarNotifications,
            request.CanToggleTopBarTheme,
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
            request.CanSelectFileTransferFiles,
            request.CanSelectFileTransferFolder,
            request.CanGenerateFileTransferQr,
            CanUseWorkspaceFeature(request.IsBusy, request.IsRemoteDesktopSelected),
            request.CanRecommendedRemoteDesktopConnect,
            request.CanAdvancedRemoteDesktopConnect,
            request.CanShowRemoteDesktopPerformanceOverlay,
            request.CanApplyRemoteDesktopQuality,
            request.CanOpenRemoteDesktopSettings,
            request.CanEnterRemoteDesktopFullScreen,
            request.CanDisconnectRemoteDesktopSession,
            request.CanRunCoreDiagnostics,
            CanUseWorkspaceFeature(request.IsBusy, request.IsSystemMonitorSelected),
            request.CanStartSystemMonitoring,
            request.CanStopSystemMonitoring,
            request.CanEnableAdvancedSystemMonitoring,
            CanUseWorkspaceFeature(request.IsBusy, request.IsSettingsSelected),
            request.CanExportSettings,
            request.CanImportSettings,
            request.CanResetSettings,
            request.CanRequestSettingsPermission,
            request.CanOpenSystemPreferences,
            request.CanApplySettings,
            request.CanRestoreDefaults,
            request.CanResetMonitorData);
}

public sealed record WorkspaceCommandGateRequest(
    bool IsBusy,
    bool IsUsbManagementSelected,
    bool IsFileTransferSelected,
    bool IsRemoteDesktopSelected,
    bool IsSystemMonitorSelected,
    bool IsSettingsSelected,
    SessionCommandGateSnapshot SessionGates,
    bool CanOpenTopBarNotifications,
    bool CanToggleTopBarTheme,
    bool CanUseDiscoveryBrowser,
    bool CanPrepareManualConnection,
    bool CanParseAdvertisement,
    bool CanValidatePairing,
    bool CanPrepareConnection,
    bool CanUseCrossNetworkConnection,
    bool CanScanQrCode,
    bool CanCopyConnectionCode,
    bool CanConnectConnectionCode,
    bool CanSelectFileTransferFiles,
    bool CanSelectFileTransferFolder,
    bool CanGenerateFileTransferQr,
    bool CanRecommendedRemoteDesktopConnect,
    bool CanAdvancedRemoteDesktopConnect,
    bool CanShowRemoteDesktopPerformanceOverlay,
    bool CanApplyRemoteDesktopQuality,
    bool CanOpenRemoteDesktopSettings,
    bool CanEnterRemoteDesktopFullScreen,
    bool CanDisconnectRemoteDesktopSession,
    bool CanStartSystemMonitoring,
    bool CanStopSystemMonitoring,
    bool CanEnableAdvancedSystemMonitoring,
    bool CanExportSettings,
    bool CanImportSettings,
    bool CanResetSettings,
    bool CanRequestSettingsPermission,
    bool CanOpenSystemPreferences,
    bool CanApplySettings,
    bool CanRestoreDefaults,
    bool CanResetMonitorData,
    bool CanRunCoreDiagnostics);
