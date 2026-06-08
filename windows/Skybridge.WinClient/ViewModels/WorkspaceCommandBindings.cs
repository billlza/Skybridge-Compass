using System;
using System.Threading.Tasks;
using System.Windows.Input;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceCommandBindings
{
    public WorkspaceCommandBindings(
        Func<Task> connectAsync,
        Func<bool> canConnect,
        Func<Task> disconnectAsync,
        Func<bool> canDisconnect,
        Func<Task> heartbeatAsync,
        Func<bool> canHeartbeat,
        Func<Task> startDiscoveryAsync,
        Func<bool> canUseDiscoveryBrowser,
        Func<Task> stopDiscoveryAsync,
        Func<Task> refreshDiscoveryAsync,
        Func<Task> runExtendedDiscoveryAsync,
        Func<Task> prepareManualConnectionAsync,
        Func<bool> canPrepareManualConnection,
        Func<Task> generateQrCodeAsync,
        Func<bool> canUseCrossNetworkConnection,
        Func<Task> scanQrCodeAsync,
        Func<bool> canScanQrCode,
        Func<Task> generateConnectionCodeAsync,
        Func<Task> regenerateConnectionCodeAsync,
        Func<Task> copyConnectionCodeAsync,
        Func<bool> canCopyConnectionCode,
        Func<Task> connectConnectionCodeAsync,
        Func<bool> canConnectConnectionCode,
        Func<Task> parseAdvertisementAsync,
        Func<bool> canParseAdvertisement,
        Func<Task> validatePairingCodeAsync,
        Func<bool> canValidatePairingCode,
        Func<Task> prepareConnectionAsync,
        Func<bool> canPrepareConnection,
        Func<Task> runCoreDiagnosticsAsync,
        Func<bool> canRunCoreDiagnostics,
        Func<Task> refreshFileTransferAsync,
        Func<bool> canRefreshFileTransfer,
        Func<Task> refreshRemoteDesktopAsync,
        Func<bool> canRefreshRemoteDesktop,
        Func<Task> refreshSystemMonitorAsync,
        Func<bool> canRefreshSystemMonitor,
        Func<Task> refreshUsbManagementAsync,
        Func<bool> canRefreshUsbManagement,
        Func<Task> refreshSettingsAsync,
        Func<bool> canRefreshSettings)
    {
        ConnectCommand = new AsyncRelayCommand(connectAsync, canConnect);
        DisconnectCommand = new AsyncRelayCommand(disconnectAsync, canDisconnect);
        HeartbeatCommand = new AsyncRelayCommand(heartbeatAsync, canHeartbeat);
        StartDiscoveryCommand = new AsyncRelayCommand(startDiscoveryAsync, canUseDiscoveryBrowser);
        StopDiscoveryCommand = new AsyncRelayCommand(stopDiscoveryAsync, canUseDiscoveryBrowser);
        RefreshDiscoveryCommand = new AsyncRelayCommand(refreshDiscoveryAsync, canUseDiscoveryBrowser);
        RunExtendedDiscoveryCommand = new AsyncRelayCommand(runExtendedDiscoveryAsync, canUseDiscoveryBrowser);
        PrepareManualConnectionCommand = new AsyncRelayCommand(prepareManualConnectionAsync, canPrepareManualConnection);
        GenerateQRCodeCommand = new AsyncRelayCommand(generateQrCodeAsync, canUseCrossNetworkConnection);
        ScanQRCodeCommand = new AsyncRelayCommand(scanQrCodeAsync, canScanQrCode);
        GenerateConnectionCodeCommand = new AsyncRelayCommand(generateConnectionCodeAsync, canUseCrossNetworkConnection);
        RegenerateConnectionCodeCommand = new AsyncRelayCommand(regenerateConnectionCodeAsync, canUseCrossNetworkConnection);
        CopyConnectionCodeCommand = new AsyncRelayCommand(copyConnectionCodeAsync, canCopyConnectionCode);
        ConnectConnectionCodeCommand = new AsyncRelayCommand(connectConnectionCodeAsync, canConnectConnectionCode);
        ParseAdvertisementCommand = new AsyncRelayCommand(parseAdvertisementAsync, canParseAdvertisement);
        ValidatePairingCodeCommand = new AsyncRelayCommand(validatePairingCodeAsync, canValidatePairingCode);
        PrepareConnectionCommand = new AsyncRelayCommand(prepareConnectionAsync, canPrepareConnection);
        RunCoreDiagnosticsCommand = new AsyncRelayCommand(runCoreDiagnosticsAsync, canRunCoreDiagnostics);
        RefreshFileTransferCommand = new AsyncRelayCommand(refreshFileTransferAsync, canRefreshFileTransfer);
        RefreshRemoteDesktopCommand = new AsyncRelayCommand(refreshRemoteDesktopAsync, canRefreshRemoteDesktop);
        RefreshSystemMonitorCommand = new AsyncRelayCommand(refreshSystemMonitorAsync, canRefreshSystemMonitor);
        RefreshUsbManagementCommand = new AsyncRelayCommand(refreshUsbManagementAsync, canRefreshUsbManagement);
        RefreshSettingsCommand = new AsyncRelayCommand(refreshSettingsAsync, canRefreshSettings);

        Registry = WorkspaceCommandRegistry.Create(
            new(WorkspaceActionCommandId.Connect, ConnectCommand),
            new(WorkspaceActionCommandId.Disconnect, DisconnectCommand),
            new(WorkspaceActionCommandId.Heartbeat, HeartbeatCommand),
            new(WorkspaceActionCommandId.StartDiscovery, StartDiscoveryCommand),
            new(WorkspaceActionCommandId.StopDiscovery, StopDiscoveryCommand),
            new(WorkspaceActionCommandId.RefreshDiscovery, RefreshDiscoveryCommand),
            new(WorkspaceActionCommandId.RunExtendedDiscovery, RunExtendedDiscoveryCommand),
            new(WorkspaceActionCommandId.PrepareManualConnection, PrepareManualConnectionCommand),
            new(WorkspaceActionCommandId.GenerateQrCode, GenerateQRCodeCommand),
            new(WorkspaceActionCommandId.ScanQrCode, ScanQRCodeCommand),
            new(WorkspaceActionCommandId.GenerateConnectionCode, GenerateConnectionCodeCommand),
            new(WorkspaceActionCommandId.RegenerateConnectionCode, RegenerateConnectionCodeCommand),
            new(WorkspaceActionCommandId.CopyConnectionCode, CopyConnectionCodeCommand),
            new(WorkspaceActionCommandId.ConnectConnectionCode, ConnectConnectionCodeCommand),
            new(WorkspaceActionCommandId.ParseTxt, ParseAdvertisementCommand),
            new(WorkspaceActionCommandId.ValidatePairing, ValidatePairingCodeCommand),
            new(WorkspaceActionCommandId.PrepareConnection, PrepareConnectionCommand),
            new(WorkspaceActionCommandId.RunCoreDiagnostics, RunCoreDiagnosticsCommand),
            new(WorkspaceActionCommandId.RefreshFileTransfer, RefreshFileTransferCommand),
            new(WorkspaceActionCommandId.RefreshRemoteDesktop, RefreshRemoteDesktopCommand),
            new(WorkspaceActionCommandId.RefreshSystemMonitor, RefreshSystemMonitorCommand),
            new(WorkspaceActionCommandId.RefreshUsbManagement, RefreshUsbManagementCommand),
            new(WorkspaceActionCommandId.RefreshSettings, RefreshSettingsCommand));
    }

    public ICommand ConnectCommand { get; }

    public ICommand DisconnectCommand { get; }

    public ICommand HeartbeatCommand { get; }

    public ICommand StartDiscoveryCommand { get; }

    public ICommand StopDiscoveryCommand { get; }

    public ICommand RefreshDiscoveryCommand { get; }

    public ICommand RunExtendedDiscoveryCommand { get; }

    public ICommand PrepareManualConnectionCommand { get; }

    public ICommand GenerateQRCodeCommand { get; }

    public ICommand ScanQRCodeCommand { get; }

    public ICommand GenerateConnectionCodeCommand { get; }

    public ICommand RegenerateConnectionCodeCommand { get; }

    public ICommand CopyConnectionCodeCommand { get; }

    public ICommand ConnectConnectionCodeCommand { get; }

    public ICommand ParseAdvertisementCommand { get; }

    public ICommand ValidatePairingCodeCommand { get; }

    public ICommand PrepareConnectionCommand { get; }

    public ICommand RunCoreDiagnosticsCommand { get; }

    public ICommand RefreshFileTransferCommand { get; }

    public ICommand RefreshRemoteDesktopCommand { get; }

    public ICommand RefreshSystemMonitorCommand { get; }

    public ICommand RefreshUsbManagementCommand { get; }

    public ICommand RefreshSettingsCommand { get; }

    public WorkspaceCommandRegistry Registry { get; }
}
