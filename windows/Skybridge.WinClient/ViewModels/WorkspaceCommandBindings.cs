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
        RemoteDesktopWorkspaceActions remoteDesktopWorkspaceActions,
        SystemMonitorWorkspaceActions systemMonitorWorkspaceActions,
        SettingsWorkspaceActions settingsWorkspaceActions,
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
        SelectFileTransferFilesCommand = new AsyncRelayCommand(fileTransferWorkspaceActions.SelectFilesAsync, commandAvailability.CanSelectFileTransferFiles);
        SelectFileTransferFolderCommand = new AsyncRelayCommand(fileTransferWorkspaceActions.SelectFolderAsync, commandAvailability.CanSelectFileTransferFolder);
        GenerateFileTransferQrCommand = new AsyncRelayCommand(fileTransferWorkspaceActions.GenerateQrAsync, commandAvailability.CanGenerateFileTransferQr);
        RefreshRemoteDesktopCommand = new AsyncRelayCommand(readOnlyWorkspaceRefreshActions.RefreshRemoteDesktopAsync, commandAvailability.CanRefreshRemoteDesktop);
        RecommendedRemoteDesktopConnectCommand = new AsyncRelayCommand(remoteDesktopWorkspaceActions.RecommendedConnectAsync, commandAvailability.CanRecommendedRemoteDesktopConnect);
        AdvancedRemoteDesktopConnectCommand = new AsyncRelayCommand(remoteDesktopWorkspaceActions.AdvancedConnectAsync, commandAvailability.CanAdvancedRemoteDesktopConnect);
        ShowRemoteDesktopPerformanceOverlayCommand = new AsyncRelayCommand(remoteDesktopWorkspaceActions.ShowPerformanceOverlayAsync, commandAvailability.CanShowRemoteDesktopPerformanceOverlay);
        ApplyRemoteDesktopQualityCommand = new AsyncRelayCommand(remoteDesktopWorkspaceActions.ApplyQualityAsync, commandAvailability.CanApplyRemoteDesktopQuality);
        OpenRemoteDesktopSettingsCommand = new AsyncRelayCommand(remoteDesktopWorkspaceActions.OpenSettingsAsync, commandAvailability.CanOpenRemoteDesktopSettings);
        EnterRemoteDesktopFullScreenCommand = new AsyncRelayCommand(remoteDesktopWorkspaceActions.EnterFullScreenAsync, commandAvailability.CanEnterRemoteDesktopFullScreen);
        DisconnectRemoteDesktopSessionCommand = new AsyncRelayCommand(remoteDesktopWorkspaceActions.DisconnectSessionAsync, commandAvailability.CanDisconnectRemoteDesktopSession);
        RefreshSystemMonitorCommand = new AsyncRelayCommand(readOnlyWorkspaceRefreshActions.RefreshSystemMonitorAsync, commandAvailability.CanRefreshSystemMonitor);
        StartSystemMonitoringCommand = new AsyncRelayCommand(systemMonitorWorkspaceActions.StartMonitoringAsync, commandAvailability.CanStartSystemMonitoring);
        StopSystemMonitoringCommand = new AsyncRelayCommand(systemMonitorWorkspaceActions.StopMonitoringAsync, commandAvailability.CanStopSystemMonitoring);
        EnableAdvancedSystemMonitoringCommand = new AsyncRelayCommand(systemMonitorWorkspaceActions.EnableAdvancedMonitoringAsync, commandAvailability.CanEnableAdvancedSystemMonitoring);
        RefreshUsbManagementCommand = new AsyncRelayCommand(readOnlyWorkspaceRefreshActions.RefreshUsbManagementAsync, commandAvailability.CanRefreshUsbManagement);
        RefreshSettingsCommand = new AsyncRelayCommand(readOnlyWorkspaceRefreshActions.RefreshSettingsAsync, commandAvailability.CanRefreshSettings);
        ExportSettingsCommand = new AsyncRelayCommand(settingsWorkspaceActions.ExportSettingsAsync, commandAvailability.CanExportSettings);
        ImportSettingsCommand = new AsyncRelayCommand(settingsWorkspaceActions.ImportSettingsAsync, commandAvailability.CanImportSettings);
        ResetSettingsCommand = new AsyncRelayCommand(settingsWorkspaceActions.ResetSettingsAsync, commandAvailability.CanResetSettings);
        RequestSettingsPermissionCommand = new AsyncRelayCommand(settingsWorkspaceActions.RequestPermissionAsync, commandAvailability.CanRequestSettingsPermission);
        OpenSystemPreferencesCommand = new AsyncRelayCommand(settingsWorkspaceActions.OpenSystemPreferencesAsync, commandAvailability.CanOpenSystemPreferences);
        ApplySettingsCommand = new AsyncRelayCommand(settingsWorkspaceActions.ApplySettingsAsync, commandAvailability.CanApplySettings);
        RestoreDefaultsCommand = new AsyncRelayCommand(settingsWorkspaceActions.RestoreDefaultsAsync, commandAvailability.CanRestoreDefaults);
        ResetMonitorDataCommand = new AsyncRelayCommand(settingsWorkspaceActions.ResetMonitorDataAsync, commandAvailability.CanResetMonitorData);

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
            new(WorkspaceActionCommandId.SelectFileTransferFiles, SelectFileTransferFilesCommand),
            new(WorkspaceActionCommandId.SelectFileTransferFolder, SelectFileTransferFolderCommand),
            new(WorkspaceActionCommandId.GenerateFileTransferQr, GenerateFileTransferQrCommand),
            new(WorkspaceActionCommandId.RefreshRemoteDesktop, RefreshRemoteDesktopCommand),
            new(WorkspaceActionCommandId.RecommendedRemoteDesktopConnect, RecommendedRemoteDesktopConnectCommand),
            new(WorkspaceActionCommandId.AdvancedRemoteDesktopConnect, AdvancedRemoteDesktopConnectCommand),
            new(WorkspaceActionCommandId.ShowRemoteDesktopPerformanceOverlay, ShowRemoteDesktopPerformanceOverlayCommand),
            new(WorkspaceActionCommandId.ApplyRemoteDesktopQuality, ApplyRemoteDesktopQualityCommand),
            new(WorkspaceActionCommandId.OpenRemoteDesktopSettings, OpenRemoteDesktopSettingsCommand),
            new(WorkspaceActionCommandId.EnterRemoteDesktopFullScreen, EnterRemoteDesktopFullScreenCommand),
            new(WorkspaceActionCommandId.DisconnectRemoteDesktopSession, DisconnectRemoteDesktopSessionCommand),
            new(WorkspaceActionCommandId.RefreshSystemMonitor, RefreshSystemMonitorCommand),
            new(WorkspaceActionCommandId.StartSystemMonitoring, StartSystemMonitoringCommand),
            new(WorkspaceActionCommandId.StopSystemMonitoring, StopSystemMonitoringCommand),
            new(WorkspaceActionCommandId.EnableAdvancedSystemMonitoring, EnableAdvancedSystemMonitoringCommand),
            new(WorkspaceActionCommandId.RefreshUsbManagement, RefreshUsbManagementCommand),
            new(WorkspaceActionCommandId.RefreshSettings, RefreshSettingsCommand),
            new(WorkspaceActionCommandId.ExportSettings, ExportSettingsCommand),
            new(WorkspaceActionCommandId.ImportSettings, ImportSettingsCommand),
            new(WorkspaceActionCommandId.ResetSettings, ResetSettingsCommand),
            new(WorkspaceActionCommandId.RequestSettingsPermission, RequestSettingsPermissionCommand),
            new(WorkspaceActionCommandId.OpenSystemPreferences, OpenSystemPreferencesCommand),
            new(WorkspaceActionCommandId.ApplySettings, ApplySettingsCommand),
            new(WorkspaceActionCommandId.RestoreDefaults, RestoreDefaultsCommand),
            new(WorkspaceActionCommandId.ResetMonitorData, ResetMonitorDataCommand));
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

    public ICommand SelectFileTransferFilesCommand { get; }

    public ICommand SelectFileTransferFolderCommand { get; }

    public ICommand GenerateFileTransferQrCommand { get; }

    public ICommand RefreshRemoteDesktopCommand { get; }

    public ICommand RecommendedRemoteDesktopConnectCommand { get; }

    public ICommand AdvancedRemoteDesktopConnectCommand { get; }

    public ICommand ShowRemoteDesktopPerformanceOverlayCommand { get; }

    public ICommand ApplyRemoteDesktopQualityCommand { get; }

    public ICommand OpenRemoteDesktopSettingsCommand { get; }

    public ICommand EnterRemoteDesktopFullScreenCommand { get; }

    public ICommand DisconnectRemoteDesktopSessionCommand { get; }

    public ICommand RefreshSystemMonitorCommand { get; }

    public ICommand StartSystemMonitoringCommand { get; }

    public ICommand StopSystemMonitoringCommand { get; }

    public ICommand EnableAdvancedSystemMonitoringCommand { get; }

    public ICommand RefreshUsbManagementCommand { get; }

    public ICommand RefreshSettingsCommand { get; }

    public ICommand ExportSettingsCommand { get; }

    public ICommand ImportSettingsCommand { get; }

    public ICommand ResetSettingsCommand { get; }

    public ICommand RequestSettingsPermissionCommand { get; }

    public ICommand OpenSystemPreferencesCommand { get; }

    public ICommand ApplySettingsCommand { get; }

    public ICommand RestoreDefaultsCommand { get; }

    public ICommand ResetMonitorDataCommand { get; }

    public WorkspaceCommandRegistry Registry { get; }
}
