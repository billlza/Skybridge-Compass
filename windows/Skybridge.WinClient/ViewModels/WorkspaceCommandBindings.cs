using System.Windows.Input;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceCommandBindings
{
    public WorkspaceCommandBindings(
        SessionEngineActions sessionEngineActions,
        DashboardNavigationActions dashboardNavigationActions,
        DiscoveryBrowserActions discoveryBrowserActions,
        ConnectionWorkspaceActions connectionWorkspaceActions,
        CrossNetworkConnectionActions crossNetworkConnectionActions,
        ReadOnlyWorkspaceRefreshActions readOnlyWorkspaceRefreshActions,
        FileTransferWorkspaceActions fileTransferWorkspaceActions,
        WorkspaceCommandAvailability commandAvailability)
    {
        ConnectCommand = new AsyncRelayCommand(sessionEngineActions.ConnectAsync, commandAvailability.CanConnect);
        DisconnectCommand = new AsyncRelayCommand(sessionEngineActions.DisconnectAsync, commandAvailability.CanDisconnect);
        HeartbeatCommand = new AsyncRelayCommand(sessionEngineActions.SendHeartbeatAsync, commandAvailability.CanSendHeartbeat);
        OpenDeviceDiscoveryCommand = new AsyncRelayCommand(dashboardNavigationActions.SelectDeviceDiscoveryAsync);
        OpenFileTransferCommand = new AsyncRelayCommand(dashboardNavigationActions.SelectFileTransferAsync);
        OpenSystemMonitorCommand = new AsyncRelayCommand(dashboardNavigationActions.SelectSystemMonitorAsync);
        OpenSettingsCommand = new AsyncRelayCommand(dashboardNavigationActions.SelectSettingsAsync);
        StartDiscoveryCommand = new AsyncRelayCommand(discoveryBrowserActions.StartAsync, commandAvailability.CanUseDiscoveryBrowser);
        StopDiscoveryCommand = new AsyncRelayCommand(discoveryBrowserActions.StopAsync, commandAvailability.CanUseDiscoveryBrowser);
        RefreshDiscoveryCommand = new AsyncRelayCommand(discoveryBrowserActions.RefreshAsync, commandAvailability.CanUseDiscoveryBrowser);
        RunExtendedDiscoveryCommand = new AsyncRelayCommand(discoveryBrowserActions.RunExtendedSearchAsync, commandAvailability.CanUseDiscoveryBrowser);
        PrepareManualConnectionCommand = new AsyncRelayCommand(connectionWorkspaceActions.PrepareManualConnectionAsync, commandAvailability.CanPrepareManualConnection);
        GenerateQRCodeCommand = new AsyncRelayCommand(crossNetworkConnectionActions.GenerateQrCodeAsync, commandAvailability.CanUseCrossNetworkConnection);
        ScanQRCodeCommand = new AsyncRelayCommand(crossNetworkConnectionActions.ScanQrCodeAsync, commandAvailability.CanScanQrCode);
        GenerateConnectionCodeCommand = new AsyncRelayCommand(crossNetworkConnectionActions.GenerateCodeAsync, commandAvailability.CanUseCrossNetworkConnection);
        RegenerateConnectionCodeCommand = new AsyncRelayCommand(crossNetworkConnectionActions.RegenerateCodeAsync, commandAvailability.CanUseCrossNetworkConnection);
        CopyConnectionCodeCommand = new AsyncRelayCommand(crossNetworkConnectionActions.CopyCodeAsync, commandAvailability.CanCopyConnectionCode);
        ConnectConnectionCodeCommand = new AsyncRelayCommand(crossNetworkConnectionActions.ConnectWithCodeAsync, commandAvailability.CanConnectConnectionCode);
        ParseAdvertisementCommand = new AsyncRelayCommand(connectionWorkspaceActions.ParseAdvertisementAsync, commandAvailability.CanParseAdvertisement);
        ValidatePairingCodeCommand = new AsyncRelayCommand(connectionWorkspaceActions.ValidatePairingCodeAsync, commandAvailability.CanValidatePairingCode);
        PrepareConnectionCommand = new AsyncRelayCommand(connectionWorkspaceActions.PrepareConnectionAsync, commandAvailability.CanPrepareConnection);
        RunCoreDiagnosticsCommand = new AsyncRelayCommand(readOnlyWorkspaceRefreshActions.RunCoreDiagnosticsAsync, commandAvailability.CanRunCoreDiagnostics);
        RefreshFileTransferCommand = new AsyncRelayCommand(readOnlyWorkspaceRefreshActions.RefreshFileTransferAsync, commandAvailability.CanRefreshFileTransfer);
        GenerateFileTransferQrCommand = new AsyncRelayCommand(fileTransferWorkspaceActions.GenerateQrAsync, commandAvailability.CanGenerateFileTransferQr);
        RefreshRemoteDesktopCommand = new AsyncRelayCommand(readOnlyWorkspaceRefreshActions.RefreshRemoteDesktopAsync, commandAvailability.CanRefreshRemoteDesktop);
        RefreshSystemMonitorCommand = new AsyncRelayCommand(readOnlyWorkspaceRefreshActions.RefreshSystemMonitorAsync, commandAvailability.CanRefreshSystemMonitor);
        RefreshUsbManagementCommand = new AsyncRelayCommand(readOnlyWorkspaceRefreshActions.RefreshUsbManagementAsync, commandAvailability.CanRefreshUsbManagement);
        RefreshSettingsCommand = new AsyncRelayCommand(readOnlyWorkspaceRefreshActions.RefreshSettingsAsync, commandAvailability.CanRefreshSettings);

        Registry = WorkspaceCommandRegistry.Create(
            new(WorkspaceActionCommandId.Connect, ConnectCommand),
            new(WorkspaceActionCommandId.Disconnect, DisconnectCommand),
            new(WorkspaceActionCommandId.Heartbeat, HeartbeatCommand),
            new(WorkspaceActionCommandId.OpenDeviceDiscovery, OpenDeviceDiscoveryCommand),
            new(WorkspaceActionCommandId.OpenFileTransfer, OpenFileTransferCommand),
            new(WorkspaceActionCommandId.OpenSystemMonitor, OpenSystemMonitorCommand),
            new(WorkspaceActionCommandId.OpenSettings, OpenSettingsCommand),
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
            new(WorkspaceActionCommandId.GenerateFileTransferQr, GenerateFileTransferQrCommand),
            new(WorkspaceActionCommandId.RefreshRemoteDesktop, RefreshRemoteDesktopCommand),
            new(WorkspaceActionCommandId.RefreshSystemMonitor, RefreshSystemMonitorCommand),
            new(WorkspaceActionCommandId.RefreshUsbManagement, RefreshUsbManagementCommand),
            new(WorkspaceActionCommandId.RefreshSettings, RefreshSettingsCommand));
    }

    public ICommand ConnectCommand { get; }

    public ICommand DisconnectCommand { get; }

    public ICommand HeartbeatCommand { get; }

    public ICommand OpenDeviceDiscoveryCommand { get; }

    public ICommand OpenFileTransferCommand { get; }

    public ICommand OpenSystemMonitorCommand { get; }

    public ICommand OpenSettingsCommand { get; }

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

    public ICommand GenerateFileTransferQrCommand { get; }

    public ICommand RefreshRemoteDesktopCommand { get; }

    public ICommand RefreshSystemMonitorCommand { get; }

    public ICommand RefreshUsbManagementCommand { get; }

    public ICommand RefreshSettingsCommand { get; }

    public WorkspaceCommandRegistry Registry { get; }
}
