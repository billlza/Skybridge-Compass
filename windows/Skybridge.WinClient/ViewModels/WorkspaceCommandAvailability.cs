using System;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceCommandAvailability
{
    private readonly WorkspaceCommandGateCoordinator _coordinator;
    private readonly Func<WorkspaceCommandGateState> _buildState;

    public WorkspaceCommandAvailability(
        WorkspaceCommandGateCoordinator coordinator,
        Func<WorkspaceCommandGateState> buildState)
    {
        _coordinator = coordinator ?? throw new ArgumentNullException(nameof(coordinator));
        _buildState = buildState ?? throw new ArgumentNullException(nameof(buildState));
    }

    public bool CanConnect() => _coordinator.CanConnect(BuildState());

    public bool CanDisconnect() => _coordinator.CanDisconnect(BuildState());

    public bool CanSendHeartbeat() => _coordinator.CanSendHeartbeat(BuildState());

    public bool CanUseDiscoveryBrowser() => _coordinator.CanUseDiscoveryBrowser(BuildState());

    public bool CanPrepareManualConnection() => _coordinator.CanPrepareManualConnection(BuildState());

    public bool CanUseCrossNetworkConnection() => _coordinator.CanUseCrossNetworkConnection(BuildState());

    public bool CanScanQrCode() => _coordinator.CanScanQrCode(BuildState());

    public bool CanCopyConnectionCode() => _coordinator.CanCopyConnectionCode(BuildState());

    public bool CanConnectConnectionCode() => _coordinator.CanConnectConnectionCode(BuildState());

    public bool CanParseAdvertisement() => _coordinator.CanParseAdvertisement(BuildState());

    public bool CanValidatePairingCode() => _coordinator.CanValidatePairingCode(BuildState());

    public bool CanPrepareConnection() => _coordinator.CanPrepareConnection(BuildState());

    public bool CanRefreshUsbManagement() => _coordinator.CanRefreshUsbManagement(BuildState());

    public bool CanRunCoreDiagnostics() => _coordinator.CanRunCoreDiagnostics(BuildState());

    public bool CanRefreshFileTransfer() => _coordinator.CanRefreshFileTransfer(BuildState());

    public bool CanSelectFileTransferFiles() => _coordinator.CanSelectFileTransferFiles(BuildState());

    public bool CanSelectFileTransferFolder() => _coordinator.CanSelectFileTransferFolder(BuildState());

    public bool CanGenerateFileTransferQr() => _coordinator.CanGenerateFileTransferQr(BuildState());

    public bool CanRefreshRemoteDesktop() => _coordinator.CanRefreshRemoteDesktop(BuildState());

    public bool CanRecommendedRemoteDesktopConnect() => _coordinator.CanRecommendedRemoteDesktopConnect(BuildState());

    public bool CanAdvancedRemoteDesktopConnect() => _coordinator.CanAdvancedRemoteDesktopConnect(BuildState());

    public bool CanShowRemoteDesktopPerformanceOverlay() => _coordinator.CanShowRemoteDesktopPerformanceOverlay(BuildState());

    public bool CanApplyRemoteDesktopQuality() => _coordinator.CanApplyRemoteDesktopQuality(BuildState());

    public bool CanOpenRemoteDesktopSettings() => _coordinator.CanOpenRemoteDesktopSettings(BuildState());

    public bool CanEnterRemoteDesktopFullScreen() => _coordinator.CanEnterRemoteDesktopFullScreen(BuildState());

    public bool CanDisconnectRemoteDesktopSession() => _coordinator.CanDisconnectRemoteDesktopSession(BuildState());

    public bool CanRefreshSystemMonitor() => _coordinator.CanRefreshSystemMonitor(BuildState());

    public bool CanStartSystemMonitoring() => _coordinator.CanStartSystemMonitoring(BuildState());

    public bool CanStopSystemMonitoring() => _coordinator.CanStopSystemMonitoring(BuildState());

    public bool CanEnableAdvancedSystemMonitoring() => _coordinator.CanEnableAdvancedSystemMonitoring(BuildState());

    public bool CanRefreshSettings() => _coordinator.CanRefreshSettings(BuildState());

    private WorkspaceCommandGateState BuildState() => _buildState();
}
