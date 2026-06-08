using System;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

internal sealed class UnavailableDiscoveryClient : IDiscoveryClient
{
    public string BuildPendingStatus() => CoreDiscoveryClient.DefaultPendingStatus;

    public bool CanParseAdvertisement(string service, string txtRecord) =>
        CoreDiscoveryClient.HasParseInputs(service, txtRecord);

    public Task<DiscoveredPeer> ParseAdvertisementAsync(string service, string txtRecord)
    {
        throw new InvalidOperationException("Discovery client is not configured.");
    }
}

internal sealed class UnavailableDiscoveryBrowserClient : IDiscoveryBrowserClient
{
    public DiscoveryBrowserInputPolicy BuildInputPolicy() =>
        WindowsDiscoveryBrowserClient.DefaultInputPolicy;

    public DiscoveryBrowserPeerCandidate BuildPeerCandidate(DiscoveredPeer peer) =>
        WindowsDiscoveryBrowserClient.BuildDefaultPeerCandidate(peer);

    public string BuildPendingStatus(DiscoveryBrowserAction action) =>
        WindowsDiscoveryBrowserClient.BuildDefaultPendingStatus(action);

    public Task<DiscoveryBrowserSnapshot> BuildReadOnlySnapshotAsync(DiscoveryBrowserRequest request)
    {
        throw new InvalidOperationException("Discovery browser client is not configured.");
    }
}

internal sealed class UnavailableManualConnectionClient : IManualConnectionClient
{
    public string BuildPendingStatus() => ManualConnectionClient.DefaultPendingStatus;

    public bool CanPrepareTarget(string host, string port) =>
        ManualConnectionClient.HasManualTargetInputs(host, port);

    public Task<ManualConnectionSnapshot> BuildReadOnlySnapshotAsync(ManualConnectionRequest request)
    {
        throw new InvalidOperationException("Manual connection client is not configured.");
    }
}

internal sealed class UnavailableCrossNetworkConnectionClient : ICrossNetworkConnectionClient
{
    public CrossNetworkCodeInputPolicy BuildCodeInputPolicy() =>
        CrossNetworkConnectionClient.DefaultCodeInputPolicy;

    public string NormalizeCodeInput(string? value) =>
        CrossNetworkConnectionClient.NormalizeCodeInput(
            value,
            CrossNetworkConnectionClient.DefaultCodeInputPolicy);

    public bool CanScanQrCode(string qrInput) =>
        CrossNetworkConnectionClient.HasQrInput(qrInput);

    public bool CanCopyCode(string generatedCode) =>
        CrossNetworkConnectionClient.HasGeneratedCode(generatedCode);

    public bool CanConnectWithCode(string codeInput) =>
        CrossNetworkConnectionClient.CanConnectWithDefaultCodePolicy(codeInput);

    public string BuildPendingStatus(CrossNetworkConnectionAction action) =>
        CrossNetworkConnectionClient.BuildDefaultPendingStatus(action);

    public Task<CrossNetworkConnectionSnapshot> BuildReadOnlySnapshotAsync(CrossNetworkConnectionRequest request)
    {
        throw new InvalidOperationException("Cross-network connection client is not configured.");
    }
}

internal sealed class UnavailablePairingMaterialClient : IPairingMaterialClient
{
    public string BuildPendingStatus() => PairingMaterialClient.DefaultPendingStatus;

    public bool CanValidate(string connectionCode) =>
        PairingMaterialClient.HasConnectionCode(connectionCode);

    public Task<PairingMaterialSnapshot> BuildReadOnlySnapshotAsync(
        string connectionCode,
        string? expectedPublicKeyFingerprint)
    {
        throw new InvalidOperationException("Pairing material client is not configured.");
    }
}

internal sealed class UnavailableConnectionPreflightClient : IConnectionPreflightClient
{
    public string BuildPendingStatus() => ConnectionPreflightClient.DefaultPendingStatus;

    public Task<ConnectionPreflightSnapshot> BuildReadOnlySnapshotAsync(
        DiscoveredPeer discoveredPeer,
        PairingMaterial pairingMaterial)
    {
        throw new InvalidOperationException("Connection preflight client is not configured.");
    }
}

internal sealed class UnavailableCoreDiagnosticsClient : ICoreDiagnosticsClient
{
    public string BuildInitialStatus() => CoreDiagnosticsClient.DefaultInitialStatus;

    public string BuildPendingStatus() => CoreDiagnosticsClient.DefaultPendingStatus;

    public string BuildCompletedStatus(CoreDiagnosticsSnapshot snapshot) =>
        CoreDiagnosticsClient.BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() =>
        CoreDiagnosticsClient.DefaultCompletedStatusMessage;

    public Task<CoreDiagnosticsSnapshot> BuildInteropSnapshotAsync()
    {
        throw new InvalidOperationException("Core diagnostics client is not configured.");
    }
}

internal sealed class UnavailableFileTransferWorkspaceClient : IFileTransferWorkspaceClient
{
    public string BuildInitialStatus() => FileTransferWorkspaceClient.DefaultInitialStatus;

    public string BuildPendingStatus() => FileTransferWorkspaceClient.DefaultPendingStatus;

    public string BuildCompletedStatus(FileTransferWorkspaceSnapshot snapshot) =>
        FileTransferWorkspaceClient.BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() =>
        FileTransferWorkspaceClient.DefaultCompletedStatusMessage;

    public bool CanSelectFiles() => false;

    public bool CanSelectFolder() => false;

    public bool CanGenerateShareQr() => false;

    public string BuildSelectFilesPendingStatus() =>
        FileTransferWorkspaceClient.DefaultSelectFilesPendingStatus;

    public string BuildSelectFolderPendingStatus() =>
        FileTransferWorkspaceClient.DefaultSelectFolderPendingStatus;

    public string BuildShareQrPendingStatus() =>
        FileTransferWorkspaceClient.DefaultShareQrPendingStatus;

    public Task<FileTransferWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        throw new InvalidOperationException("File transfer workspace client is not configured.");
    }

    public Task<FileTransferWorkspaceActionResult> BuildSelectFilesActionAsync() =>
        Task.FromResult(FileTransferWorkspaceClient.BuildDefaultSelectFilesActionResult());

    public Task<FileTransferWorkspaceActionResult> BuildSelectFolderActionAsync() =>
        Task.FromResult(FileTransferWorkspaceClient.BuildDefaultSelectFolderActionResult());

    public Task<FileTransferWorkspaceActionResult> BuildShareQrActionAsync() =>
        Task.FromResult(FileTransferWorkspaceClient.BuildDefaultShareQrActionResult());
}

internal sealed class UnavailableRemoteDesktopWorkspaceClient : IRemoteDesktopWorkspaceClient
{
    public string BuildInitialStatus() => RemoteDesktopWorkspaceClient.DefaultInitialStatus;

    public string BuildPendingStatus() => RemoteDesktopWorkspaceClient.DefaultPendingStatus;

    public string BuildCompletedStatus(RemoteDesktopWorkspaceSnapshot snapshot) =>
        RemoteDesktopWorkspaceClient.BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() =>
        RemoteDesktopWorkspaceClient.DefaultCompletedStatusMessage;

    public bool CanStartRecommendedSession() => false;

    public bool CanStartAdvancedSession() => false;

    public bool CanShowPerformanceOverlay() => false;

    public bool CanApplyQuality() => false;

    public bool CanOpenSettings() => false;

    public bool CanEnterFullScreen() => false;

    public bool CanDisconnectSession() => false;

    public string BuildRecommendedConnectPendingStatus() =>
        RemoteDesktopWorkspaceClient.DefaultRecommendedConnectPendingStatus;

    public string BuildAdvancedConnectPendingStatus() =>
        RemoteDesktopWorkspaceClient.DefaultAdvancedConnectPendingStatus;

    public string BuildPerformanceOverlayPendingStatus() =>
        RemoteDesktopWorkspaceClient.DefaultPerformanceOverlayPendingStatus;

    public string BuildQualityPendingStatus() =>
        RemoteDesktopWorkspaceClient.DefaultQualityPendingStatus;

    public string BuildSettingsPendingStatus() =>
        RemoteDesktopWorkspaceClient.DefaultSettingsPendingStatus;

    public string BuildFullScreenPendingStatus() =>
        RemoteDesktopWorkspaceClient.DefaultFullScreenPendingStatus;

    public string BuildDisconnectSessionPendingStatus() =>
        RemoteDesktopWorkspaceClient.DefaultDisconnectSessionPendingStatus;

    public Task<RemoteDesktopWorkspaceSnapshot> BuildReadOnlySnapshotAsync(
        string bitrateProfile,
        string framerateProfile)
    {
        throw new InvalidOperationException("Remote desktop workspace client is not configured.");
    }

    public Task<RemoteDesktopWorkspaceActionResult> BuildRecommendedConnectActionAsync() =>
        Task.FromResult(RemoteDesktopWorkspaceClient.BuildDefaultRecommendedConnectActionResult());

    public Task<RemoteDesktopWorkspaceActionResult> BuildAdvancedConnectActionAsync() =>
        Task.FromResult(RemoteDesktopWorkspaceClient.BuildDefaultAdvancedConnectActionResult());

    public Task<RemoteDesktopWorkspaceActionResult> BuildPerformanceOverlayActionAsync() =>
        Task.FromResult(RemoteDesktopWorkspaceClient.BuildDefaultPerformanceOverlayActionResult());

    public Task<RemoteDesktopWorkspaceActionResult> BuildQualityActionAsync() =>
        Task.FromResult(RemoteDesktopWorkspaceClient.BuildDefaultQualityActionResult());

    public Task<RemoteDesktopWorkspaceActionResult> BuildSettingsActionAsync() =>
        Task.FromResult(RemoteDesktopWorkspaceClient.BuildDefaultSettingsActionResult());

    public Task<RemoteDesktopWorkspaceActionResult> BuildFullScreenActionAsync() =>
        Task.FromResult(RemoteDesktopWorkspaceClient.BuildDefaultFullScreenActionResult());

    public Task<RemoteDesktopWorkspaceActionResult> BuildDisconnectSessionActionAsync() =>
        Task.FromResult(RemoteDesktopWorkspaceClient.BuildDefaultDisconnectSessionActionResult());
}

internal sealed class UnavailableSystemMonitorWorkspaceClient : ISystemMonitorWorkspaceClient
{
    public string BuildInitialStatus() => SystemMonitorWorkspaceClient.DefaultInitialStatus;

    public string BuildPendingStatus() => SystemMonitorWorkspaceClient.DefaultPendingStatus;

    public string BuildCompletedStatus(SystemMonitorWorkspaceSnapshot snapshot) =>
        SystemMonitorWorkspaceClient.BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() =>
        SystemMonitorWorkspaceClient.DefaultCompletedStatusMessage;

    public bool CanStartMonitoring() => false;

    public bool CanStopMonitoring() => false;

    public bool CanEnableAdvancedMonitoring() => false;

    public string BuildStartMonitoringPendingStatus() =>
        SystemMonitorWorkspaceClient.DefaultStartMonitoringPendingStatus;

    public string BuildStopMonitoringPendingStatus() =>
        SystemMonitorWorkspaceClient.DefaultStopMonitoringPendingStatus;

    public string BuildAdvancedMonitoringPendingStatus() =>
        SystemMonitorWorkspaceClient.DefaultAdvancedMonitoringPendingStatus;

    public Task<SystemMonitorWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        throw new InvalidOperationException("System monitor workspace client is not configured.");
    }

    public Task<SystemMonitorWorkspaceActionResult> BuildStartMonitoringActionAsync() =>
        Task.FromResult(SystemMonitorWorkspaceClient.BuildDefaultStartMonitoringActionResult());

    public Task<SystemMonitorWorkspaceActionResult> BuildStopMonitoringActionAsync() =>
        Task.FromResult(SystemMonitorWorkspaceClient.BuildDefaultStopMonitoringActionResult());

    public Task<SystemMonitorWorkspaceActionResult> BuildAdvancedMonitoringActionAsync() =>
        Task.FromResult(SystemMonitorWorkspaceClient.BuildDefaultAdvancedMonitoringActionResult());
}

internal sealed class UnavailableUsbManagementWorkspaceClient : IUsbManagementWorkspaceClient
{
    public string BuildInitialStatus() => UsbManagementWorkspaceClient.DefaultInitialStatus;

    public string BuildPendingStatus() => UsbManagementWorkspaceClient.DefaultPendingStatus;

    public string BuildCompletedStatus(UsbManagementWorkspaceSnapshot snapshot) =>
        UsbManagementWorkspaceClient.BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() =>
        UsbManagementWorkspaceClient.DefaultCompletedStatusMessage;

    public Task<UsbManagementWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        throw new InvalidOperationException("USB management workspace client is not configured.");
    }
}

internal sealed class UnavailableSettingsWorkspaceClient : ISettingsWorkspaceClient
{
    public string BuildInitialStatus() => SettingsWorkspaceClient.DefaultInitialStatus;

    public string BuildPendingStatus() => SettingsWorkspaceClient.DefaultPendingStatus;

    public string BuildCompletedStatus(SettingsWorkspaceSnapshot snapshot) =>
        SettingsWorkspaceClient.BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() =>
        SettingsWorkspaceClient.DefaultCompletedStatusMessage;

    public bool CanExportSettings() => false;

    public bool CanImportSettings() => false;

    public bool CanResetSettings() => false;

    public bool CanRequestPermission() => false;

    public bool CanOpenSystemPreferences() => false;

    public bool CanApplySettings() => false;

    public bool CanRestoreDefaults() => false;

    public bool CanResetMonitorData() => false;

    public string BuildExportSettingsPendingStatus() =>
        SettingsWorkspaceClient.DefaultExportSettingsPendingStatus;

    public string BuildImportSettingsPendingStatus() =>
        SettingsWorkspaceClient.DefaultImportSettingsPendingStatus;

    public string BuildResetSettingsPendingStatus() =>
        SettingsWorkspaceClient.DefaultResetSettingsPendingStatus;

    public string BuildPermissionRequestPendingStatus() =>
        SettingsWorkspaceClient.DefaultPermissionRequestPendingStatus;

    public string BuildSystemPreferencesPendingStatus() =>
        SettingsWorkspaceClient.DefaultSystemPreferencesPendingStatus;

    public string BuildApplySettingsPendingStatus() =>
        SettingsWorkspaceClient.DefaultApplySettingsPendingStatus;

    public string BuildRestoreDefaultsPendingStatus() =>
        SettingsWorkspaceClient.DefaultRestoreDefaultsPendingStatus;

    public string BuildResetMonitorDataPendingStatus() =>
        SettingsWorkspaceClient.DefaultResetMonitorDataPendingStatus;

    public Task<SettingsWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        throw new InvalidOperationException("Settings workspace client is not configured.");
    }

    public Task<SettingsWorkspaceActionResult> BuildExportSettingsActionAsync() =>
        Task.FromResult(SettingsWorkspaceClient.BuildDefaultExportSettingsActionResult());

    public Task<SettingsWorkspaceActionResult> BuildImportSettingsActionAsync() =>
        Task.FromResult(SettingsWorkspaceClient.BuildDefaultImportSettingsActionResult());

    public Task<SettingsWorkspaceActionResult> BuildResetSettingsActionAsync() =>
        Task.FromResult(SettingsWorkspaceClient.BuildDefaultResetSettingsActionResult());

    public Task<SettingsWorkspaceActionResult> BuildPermissionRequestActionAsync() =>
        Task.FromResult(SettingsWorkspaceClient.BuildDefaultPermissionRequestActionResult());

    public Task<SettingsWorkspaceActionResult> BuildSystemPreferencesActionAsync() =>
        Task.FromResult(SettingsWorkspaceClient.BuildDefaultSystemPreferencesActionResult());

    public Task<SettingsWorkspaceActionResult> BuildApplySettingsActionAsync() =>
        Task.FromResult(SettingsWorkspaceClient.BuildDefaultApplySettingsActionResult());

    public Task<SettingsWorkspaceActionResult> BuildRestoreDefaultsActionAsync() =>
        Task.FromResult(SettingsWorkspaceClient.BuildDefaultRestoreDefaultsActionResult());

    public Task<SettingsWorkspaceActionResult> BuildResetMonitorDataActionAsync() =>
        Task.FromResult(SettingsWorkspaceClient.BuildDefaultResetMonitorDataActionResult());
}
