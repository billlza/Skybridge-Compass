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

    public Task<RemoteDesktopWorkspaceSnapshot> BuildReadOnlySnapshotAsync(
        string bitrateProfile,
        string framerateProfile)
    {
        throw new InvalidOperationException("Remote desktop workspace client is not configured.");
    }
}

internal sealed class UnavailableSystemMonitorWorkspaceClient : ISystemMonitorWorkspaceClient
{
    public string BuildInitialStatus() => SystemMonitorWorkspaceClient.DefaultInitialStatus;

    public string BuildPendingStatus() => SystemMonitorWorkspaceClient.DefaultPendingStatus;

    public string BuildCompletedStatus(SystemMonitorWorkspaceSnapshot snapshot) =>
        SystemMonitorWorkspaceClient.BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() =>
        SystemMonitorWorkspaceClient.DefaultCompletedStatusMessage;

    public Task<SystemMonitorWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        throw new InvalidOperationException("System monitor workspace client is not configured.");
    }
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

    public Task<SettingsWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        throw new InvalidOperationException("Settings workspace client is not configured.");
    }
}
