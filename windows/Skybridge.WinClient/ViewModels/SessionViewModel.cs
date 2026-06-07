using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using System.Windows.Input;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

public sealed class SessionViewModel : INotifyPropertyChanged
{
    private readonly IEngineClient _engineClient;
    private readonly IDiscoveryClient _discoveryClient;
    private readonly IDiscoveryBrowserClient _discoveryBrowserClient;
    private readonly DiscoveryBrowserInputPolicy _discoveryBrowserInputPolicy;
    private readonly IDeviceDiscoveryInputDefaultsClient _deviceDiscoveryInputDefaultsClient;
    private readonly IManualConnectionClient _manualConnectionClient;
    private readonly ICrossNetworkConnectionClient _crossNetworkConnectionClient;
    private readonly CrossNetworkCodeInputPolicy _crossNetworkCodeInputPolicy;
    private readonly IPairingMaterialClient _pairingMaterialClient;
    private readonly IConnectionPreflightClient _connectionPreflightClient;
    private readonly ICoreDiagnosticsClient _coreDiagnosticsClient;
    private readonly IFileTransferWorkspaceClient _fileTransferClient;
    private readonly IRemoteDesktopWorkspaceClient _remoteDesktopClient;
    private readonly IRemoteDesktopProfileCatalogClient _remoteDesktopProfileCatalogClient;
    private readonly ISystemMonitorWorkspaceClient _systemMonitorClient;
    private readonly IUsbManagementWorkspaceClient _usbManagementClient;
    private readonly ISettingsWorkspaceClient _settingsClient;
    private readonly IDashboardMetricsClient _dashboardMetricsClient;
    private readonly ITopBarStatusClient _topBarStatusClient;
    private readonly IConnectionWorkspaceStateClient _connectionWorkspaceStateClient;
    private readonly IWorkspaceActionCatalogClient _workspaceActionCatalogClient;
    private string _statusMessage = "Idle";
    private string _discoveryService = "";
    private string _discoverySearchText = "";
    private string _manualConnectionHost = "";
    private string _manualConnectionPort = "";
    private string _manualConnectionCode = "";
    private string _crossNetworkQrInput = "";
    private string _crossNetworkCodeInput = "";
    private string _crossNetworkGeneratedCode = "";
    private string _discoveryTxtRecord = "";
    private string _pairingConnectionCode = "";
    private string _discoveryStatus = "Ready";
    private string _discoveryBrowserStatus = "Ready";
    private string _manualConnectionStatus = "Ready";
    private string _crossNetworkStatus = "Ready";
    private string _pairingStatus = "Ready";
    private string _connectionPreflightStatus = "Ready";
    private string _coreDiagnosticsStatus = "Ready";
    private string _fileTransferStatus = "Ready";
    private string _remoteDesktopStatus = "Ready";
    private string _systemMonitorStatus = "Ready";
    private string _usbManagementStatus = "Ready";
    private string _settingsStatus = "Ready";
    private int _onlineDeviceCount;
    private int _activeSessionCount;
    private int _transferTaskCount;
    private string _performanceStatus = "Nominal";
    private string _topBarConnectionStatus = "Disconnected";
    private string _topBarDiagnosticsStatus = "Nominal";
    private string _topBarNotificationsStatus = "Off";
    private string _topBarThemeStatus = "System";
    private string _selectedBitrate = "Medium";
    private string _selectedFramerate = "Fps60";
    private EngineConnectionState _connectionState;
    private FeatureEntry _selectedFeature;
    private DiscoveredPeer? _validatedDiscoveredPeer;
    private PairingMaterial? _validatedPairingMaterial;
    private bool _isDiscoveryScanning;
    private bool _isDiscoveryCompatibilityModeEnabled;
    private int _extendedSearchCountdown;
    private bool _isBusy;

    public SessionViewModel(
        IEngineClient engineClient,
        IDiscoveryClient? discoveryClient = null,
        IDiscoveryBrowserClient? discoveryBrowserClient = null,
        IDeviceDiscoveryInputDefaultsClient? deviceDiscoveryInputDefaultsClient = null,
        IManualConnectionClient? manualConnectionClient = null,
        ICrossNetworkConnectionClient? crossNetworkConnectionClient = null,
        IPairingMaterialClient? pairingMaterialClient = null,
        IConnectionPreflightClient? connectionPreflightClient = null,
        ICoreDiagnosticsClient? coreDiagnosticsClient = null,
        IFileTransferWorkspaceClient? fileTransferClient = null,
        IRemoteDesktopWorkspaceClient? remoteDesktopClient = null,
        IRemoteDesktopProfileCatalogClient? remoteDesktopProfileCatalogClient = null,
        ISystemMonitorWorkspaceClient? systemMonitorClient = null,
        IUsbManagementWorkspaceClient? usbManagementClient = null,
        ISettingsWorkspaceClient? settingsClient = null,
        IDashboardMetricsClient? dashboardMetricsClient = null,
        ITopBarStatusClient? topBarStatusClient = null,
        IConnectionWorkspaceStateClient? connectionWorkspaceStateClient = null,
        IWorkspaceActionCatalogClient? workspaceActionCatalogClient = null)
    {
        _engineClient = engineClient;
        _discoveryClient = discoveryClient ?? new UnavailableDiscoveryClient();
        _discoveryBrowserClient = discoveryBrowserClient ?? new UnavailableDiscoveryBrowserClient();
        _discoveryBrowserInputPolicy = _discoveryBrowserClient.BuildInputPolicy();
        _deviceDiscoveryInputDefaultsClient = deviceDiscoveryInputDefaultsClient ?? new DeviceDiscoveryInputDefaultsClient();
        _manualConnectionClient = manualConnectionClient ?? new UnavailableManualConnectionClient();
        _crossNetworkConnectionClient = crossNetworkConnectionClient ?? new UnavailableCrossNetworkConnectionClient();
        _crossNetworkCodeInputPolicy = _crossNetworkConnectionClient.BuildCodeInputPolicy();
        _pairingMaterialClient = pairingMaterialClient ?? new UnavailablePairingMaterialClient();
        _connectionPreflightClient = connectionPreflightClient ?? new UnavailableConnectionPreflightClient();
        _coreDiagnosticsClient = coreDiagnosticsClient ?? new UnavailableCoreDiagnosticsClient();
        _fileTransferClient = fileTransferClient ?? new UnavailableFileTransferWorkspaceClient();
        _remoteDesktopClient = remoteDesktopClient ?? new UnavailableRemoteDesktopWorkspaceClient();
        _remoteDesktopProfileCatalogClient = remoteDesktopProfileCatalogClient ?? new RemoteDesktopProfileCatalogClient();
        _systemMonitorClient = systemMonitorClient ?? new UnavailableSystemMonitorWorkspaceClient();
        _usbManagementClient = usbManagementClient ?? new UnavailableUsbManagementWorkspaceClient();
        _settingsClient = settingsClient ?? new UnavailableSettingsWorkspaceClient();
        _dashboardMetricsClient = dashboardMetricsClient ?? new DashboardMetricsClient();
        _topBarStatusClient = topBarStatusClient ?? new TopBarStatusClient();
        _connectionWorkspaceStateClient = connectionWorkspaceStateClient ?? new ConnectionWorkspaceStateClient();
        _workspaceActionCatalogClient = workspaceActionCatalogClient ?? new WorkspaceActionCatalogClient();
        var deviceDiscoveryInputDefaults = _deviceDiscoveryInputDefaultsClient.BuildReadOnlySnapshot();
        _discoveryService = deviceDiscoveryInputDefaults.DiscoveryService;
        _manualConnectionPort = deviceDiscoveryInputDefaults.ManualConnectionPort;
        _discoveryTxtRecord = deviceDiscoveryInputDefaults.DiscoveryTxtRecord;
        _pairingConnectionCode = deviceDiscoveryInputDefaults.PairingConnectionCode;
        _extendedSearchCountdown = _discoveryBrowserInputPolicy.ExtendedSearchSeconds;
        _connectionState = _engineClient.State;
        NavigationItems = new ObservableCollection<FeatureEntry>(FeatureEntryContract.Entries);
        _selectedFeature = NavigationItems[0];
        DashboardMetrics = new ObservableCollection<DashboardMetricView>();
        SidebarSessionActions = new ObservableCollection<WorkspaceActionItemView>();
        TopBarActions = new ObservableCollection<WorkspaceActionItemView>();
        SessionControlActions = new ObservableCollection<WorkspaceActionItemView>();
        DiscoveredPeers = new ObservableCollection<DiscoveredPeerView>();
        DiscoveryBrowserFacts = new ObservableCollection<DiscoveryBrowserFactView>();
        ManualConnectionFacts = new ObservableCollection<ManualConnectionFactView>();
        CrossNetworkConnectionFacts = new ObservableCollection<CrossNetworkConnectionFactView>();
        PairingFacts = new ObservableCollection<PairingFactView>();
        ConnectionPreflightFacts = new ObservableCollection<ConnectionPreflightFactView>();
        CoreDiagnosticFacts = new ObservableCollection<CoreDiagnosticFactView>();
        DeviceDiscoveryPrimaryActions = new ObservableCollection<WorkspaceActionItemView>();
        DeviceDiscoveryScanActions = new ObservableCollection<WorkspaceActionItemView>();
        CrossNetworkQrActions = new ObservableCollection<WorkspaceActionItemView>();
        CrossNetworkCodePrimaryActions = new ObservableCollection<WorkspaceActionItemView>();
        CrossNetworkCodeConnectActions = new ObservableCollection<WorkspaceActionItemView>();
        UsbManagementHeaderActions = new ObservableCollection<WorkspaceActionItemView>();
        FileTransferHeaderActions = new ObservableCollection<WorkspaceActionItemView>();
        FileTransferActions = new ObservableCollection<WorkspaceActionItemView>();
        RemoteDesktopHeaderActions = new ObservableCollection<WorkspaceActionItemView>();
        RemoteDesktopActions = new ObservableCollection<WorkspaceActionItemView>();
        QuantumDiagnosticsHeaderActions = new ObservableCollection<WorkspaceActionItemView>();
        SettingsHeaderActions = new ObservableCollection<WorkspaceActionItemView>();
        SettingsToolbarActions = new ObservableCollection<WorkspaceActionItemView>();
        SettingsMaintenanceActions = new ObservableCollection<WorkspaceActionItemView>();
        FileTransferQueue = new ObservableCollection<FileTransferQueueItemView>();
        FileTransferHistory = new ObservableCollection<FileTransferHistoryItemView>();
        FileTransferSecurityFacts = new ObservableCollection<FileTransferSecurityFactView>();
        RemoteDesktopSessions = new ObservableCollection<RemoteDesktopSessionItemView>();
        RemoteDesktopControlFacts = new ObservableCollection<RemoteDesktopControlFactView>();
        SystemMonitorHeaderActions = new ObservableCollection<WorkspaceActionItemView>();
        SystemMonitorActions = new ObservableCollection<WorkspaceActionItemView>();
        SystemMonitorOverview = new ObservableCollection<SystemMonitorMetricView>();
        SystemMonitorDetails = new ObservableCollection<SystemMonitorMetricView>();
        SystemMonitorIndicators = new ObservableCollection<SystemMonitorIndicatorView>();
        UsbDeviceStats = new ObservableCollection<UsbDeviceStatView>();
        UsbDevices = new ObservableCollection<UsbDeviceItemView>();
        SettingsTabs = new ObservableCollection<SettingsTabItemView>();
        SettingsActions = new ObservableCollection<SettingsActionItemView>();
        SettingsDetails = new ObservableCollection<SettingsDetailItemView>();
        _engineClient.ConnectionStateChanged += OnEngineStateChanged;
        ConnectCommand = new AsyncRelayCommand(ConnectAsync, CanConnect);
        DisconnectCommand = new AsyncRelayCommand(DisconnectAsync, CanDisconnect);
        HeartbeatCommand = new AsyncRelayCommand(SendHeartbeatAsync, CanSendHeartbeat);
        StartDiscoveryCommand = new AsyncRelayCommand(StartDiscoveryAsync, CanUseDiscoveryBrowser);
        StopDiscoveryCommand = new AsyncRelayCommand(StopDiscoveryAsync, CanUseDiscoveryBrowser);
        RefreshDiscoveryCommand = new AsyncRelayCommand(RefreshDiscoveryAsync, CanUseDiscoveryBrowser);
        RunExtendedDiscoveryCommand = new AsyncRelayCommand(RunExtendedDiscoveryAsync, CanUseDiscoveryBrowser);
        PrepareManualConnectionCommand = new AsyncRelayCommand(PrepareManualConnectionAsync, CanPrepareManualConnection);
        GenerateQRCodeCommand = new AsyncRelayCommand(GenerateQRCodeAsync, CanUseCrossNetworkConnection);
        ScanQRCodeCommand = new AsyncRelayCommand(ScanQRCodeAsync, CanScanQRCode);
        GenerateConnectionCodeCommand = new AsyncRelayCommand(GenerateConnectionCodeAsync, CanUseCrossNetworkConnection);
        RegenerateConnectionCodeCommand = new AsyncRelayCommand(RegenerateConnectionCodeAsync, CanUseCrossNetworkConnection);
        CopyConnectionCodeCommand = new AsyncRelayCommand(CopyConnectionCodeAsync, CanCopyConnectionCode);
        ConnectConnectionCodeCommand = new AsyncRelayCommand(ConnectConnectionCodeAsync, CanConnectConnectionCode);
        ParseAdvertisementCommand = new AsyncRelayCommand(ParseAdvertisementAsync, CanParseAdvertisement);
        ValidatePairingCodeCommand = new AsyncRelayCommand(ValidatePairingCodeAsync, CanValidatePairingCode);
        PrepareConnectionCommand = new AsyncRelayCommand(PrepareConnectionAsync, CanPrepareConnection);
        RunCoreDiagnosticsCommand = new AsyncRelayCommand(RunCoreDiagnosticsAsync, CanRunCoreDiagnostics);
        RefreshFileTransferCommand = new AsyncRelayCommand(RefreshFileTransferAsync, CanRefreshFileTransfer);
        RefreshRemoteDesktopCommand = new AsyncRelayCommand(RefreshRemoteDesktopAsync, CanRefreshRemoteDesktop);
        RefreshSystemMonitorCommand = new AsyncRelayCommand(RefreshSystemMonitorAsync, CanRefreshSystemMonitor);
        RefreshUsbManagementCommand = new AsyncRelayCommand(RefreshUsbManagementAsync, CanRefreshUsbManagement);
        RefreshSettingsCommand = new AsyncRelayCommand(RefreshSettingsAsync, CanRefreshSettings);
        var profileCatalog = _remoteDesktopProfileCatalogClient.BuildReadOnlySnapshot();
        BitrateProfiles = new ObservableCollection<string>(profileCatalog.BitrateProfiles);
        FramerateProfiles = new ObservableCollection<string>(profileCatalog.FramerateProfiles);
        _selectedBitrate = profileCatalog.DefaultBitrateProfile;
        _selectedFramerate = profileCatalog.DefaultFramerateProfile;
        LoadWorkspaceActions();
        RefreshDashboardMetrics();
        RefreshTopBarStatus();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<FeatureEntry> NavigationItems { get; }

    public ObservableCollection<DashboardMetricView> DashboardMetrics { get; }

    public ObservableCollection<string> BitrateProfiles { get; }

    public ObservableCollection<string> FramerateProfiles { get; }

    public ObservableCollection<WorkspaceActionItemView> SidebarSessionActions { get; }

    public ObservableCollection<WorkspaceActionItemView> TopBarActions { get; }

    public ObservableCollection<WorkspaceActionItemView> SessionControlActions { get; }

    public ObservableCollection<DiscoveredPeerView> DiscoveredPeers { get; }

    public ObservableCollection<DiscoveryBrowserFactView> DiscoveryBrowserFacts { get; }

    public ObservableCollection<ManualConnectionFactView> ManualConnectionFacts { get; }

    public ObservableCollection<CrossNetworkConnectionFactView> CrossNetworkConnectionFacts { get; }

    public ObservableCollection<PairingFactView> PairingFacts { get; }

    public ObservableCollection<ConnectionPreflightFactView> ConnectionPreflightFacts { get; }

    public ObservableCollection<CoreDiagnosticFactView> CoreDiagnosticFacts { get; }

    public ObservableCollection<WorkspaceActionItemView> DeviceDiscoveryPrimaryActions { get; }

    public ObservableCollection<WorkspaceActionItemView> DeviceDiscoveryScanActions { get; }

    public ObservableCollection<WorkspaceActionItemView> CrossNetworkQrActions { get; }

    public ObservableCollection<WorkspaceActionItemView> CrossNetworkCodePrimaryActions { get; }

    public ObservableCollection<WorkspaceActionItemView> CrossNetworkCodeConnectActions { get; }

    public ObservableCollection<WorkspaceActionItemView> UsbManagementHeaderActions { get; }

    public ObservableCollection<WorkspaceActionItemView> FileTransferHeaderActions { get; }

    public ObservableCollection<WorkspaceActionItemView> FileTransferActions { get; }

    public ObservableCollection<WorkspaceActionItemView> RemoteDesktopHeaderActions { get; }

    public ObservableCollection<WorkspaceActionItemView> RemoteDesktopActions { get; }

    public ObservableCollection<WorkspaceActionItemView> QuantumDiagnosticsHeaderActions { get; }

    public ObservableCollection<WorkspaceActionItemView> SettingsHeaderActions { get; }

    public ObservableCollection<WorkspaceActionItemView> SettingsToolbarActions { get; }

    public ObservableCollection<WorkspaceActionItemView> SettingsMaintenanceActions { get; }

    public ObservableCollection<FileTransferQueueItemView> FileTransferQueue { get; }

    public ObservableCollection<FileTransferHistoryItemView> FileTransferHistory { get; }

    public ObservableCollection<FileTransferSecurityFactView> FileTransferSecurityFacts { get; }

    public ObservableCollection<RemoteDesktopSessionItemView> RemoteDesktopSessions { get; }

    public ObservableCollection<RemoteDesktopControlFactView> RemoteDesktopControlFacts { get; }

    public ObservableCollection<WorkspaceActionItemView> SystemMonitorHeaderActions { get; }

    public ObservableCollection<WorkspaceActionItemView> SystemMonitorActions { get; }

    public ObservableCollection<SystemMonitorMetricView> SystemMonitorOverview { get; }

    public ObservableCollection<SystemMonitorMetricView> SystemMonitorDetails { get; }

    public ObservableCollection<SystemMonitorIndicatorView> SystemMonitorIndicators { get; }

    public ObservableCollection<UsbDeviceStatView> UsbDeviceStats { get; }

    public ObservableCollection<UsbDeviceItemView> UsbDevices { get; }

    public ObservableCollection<SettingsTabItemView> SettingsTabs { get; }

    public ObservableCollection<SettingsActionItemView> SettingsActions { get; }

    public ObservableCollection<SettingsDetailItemView> SettingsDetails { get; }

    public int OnlineDeviceCount
    {
        get => _onlineDeviceCount;
        private set => SetField(ref _onlineDeviceCount, value);
    }

    public int ActiveSessionCount
    {
        get => _activeSessionCount;
        private set => SetField(ref _activeSessionCount, value);
    }

    public int TransferTaskCount
    {
        get => _transferTaskCount;
        private set => SetField(ref _transferTaskCount, value);
    }

    public string PerformanceStatus
    {
        get => _performanceStatus;
        private set => SetField(ref _performanceStatus, value);
    }

    public string TopBarConnectionStatus
    {
        get => _topBarConnectionStatus;
        private set => SetField(ref _topBarConnectionStatus, value);
    }

    public string TopBarDiagnosticsStatus
    {
        get => _topBarDiagnosticsStatus;
        private set => SetField(ref _topBarDiagnosticsStatus, value);
    }

    public string TopBarNotificationsStatus
    {
        get => _topBarNotificationsStatus;
        private set => SetField(ref _topBarNotificationsStatus, value);
    }

    public string TopBarThemeStatus
    {
        get => _topBarThemeStatus;
        private set => SetField(ref _topBarThemeStatus, value);
    }

    public FeatureEntry SelectedFeature
    {
        get => _selectedFeature;
        set
        {
            if (SetField(ref _selectedFeature, value))
            {
                OnPropertyChanged(nameof(IsDeviceDiscoverySelected));
                OnPropertyChanged(nameof(IsUsbManagementSelected));
                OnPropertyChanged(nameof(IsFileTransferSelected));
                OnPropertyChanged(nameof(IsRemoteDesktopSelected));
                OnPropertyChanged(nameof(IsQuantumSelected));
                OnPropertyChanged(nameof(IsSystemMonitorSelected));
                OnPropertyChanged(nameof(IsSettingsSelected));
                RefreshTopBarStatus();
                RefreshCommandStates();
            }
        }
    }

    public bool IsDeviceDiscoverySelected => SelectedFeature.Id == FeatureEntryId.DeviceDiscovery;

    public bool IsUsbManagementSelected => SelectedFeature.Id == FeatureEntryId.UsbManagement;

    public bool IsFileTransferSelected => SelectedFeature.Id == FeatureEntryId.FileTransfer;

    public bool IsRemoteDesktopSelected => SelectedFeature.Id == FeatureEntryId.RemoteDesktop;

    public bool IsQuantumSelected => SelectedFeature.Id == FeatureEntryId.Quantum;

    public bool IsSystemMonitorSelected => SelectedFeature.Id == FeatureEntryId.SystemMonitor;

    public bool IsSettingsSelected => SelectedFeature.Id == FeatureEntryId.Settings;

    public EngineConnectionState ConnectionState
    {
        get => _connectionState;
        private set
        {
            if (SetField(ref _connectionState, value))
            {
                OnPropertyChanged(nameof(ConnectionStatus));
                RefreshDashboardMetrics();
                RefreshTopBarStatus();
                RefreshCommandStates();
            }
        }
    }

    public string ConnectionStatus => ConnectionState.ToString();

    public bool IsBusy
    {
        get => _isBusy;
        private set
        {
            if (SetField(ref _isBusy, value))
            {
                RefreshDashboardMetrics();
                RefreshTopBarStatus();
                RefreshCommandStates();
            }
        }
    }

    public string StatusMessage
    {
        get => _statusMessage;
        private set => SetField(ref _statusMessage, value);
    }

    public string DiscoveryService
    {
        get => _discoveryService;
        set
        {
            if (SetField(ref _discoveryService, value))
            {
                InvalidatePairingAndPreflight();
                RefreshCommandStates();
            }
        }
    }

    public string DiscoverySearchText
    {
        get => _discoverySearchText;
        set
        {
            if (SetField(ref _discoverySearchText, value))
            {
                RefreshCommandStates();
            }
        }
    }

    public string ManualConnectionHost
    {
        get => _manualConnectionHost;
        set
        {
            if (SetField(ref _manualConnectionHost, value))
            {
                ManualConnectionFacts.Clear();
                ApplyConnectionWorkspaceStatusPatch(
                    _connectionWorkspaceStateClient.BuildInputResetPatch(
                        ConnectionWorkspaceResetReason.ManualTargetInputChanged));
                OnPropertyChanged(nameof(ManualConnectionFactCount));
                RefreshCommandStates();
            }
        }
    }

    public string ManualConnectionPort
    {
        get => _manualConnectionPort;
        set
        {
            if (SetField(ref _manualConnectionPort, value))
            {
                ManualConnectionFacts.Clear();
                ApplyConnectionWorkspaceStatusPatch(
                    _connectionWorkspaceStateClient.BuildInputResetPatch(
                        ConnectionWorkspaceResetReason.ManualTargetInputChanged));
                OnPropertyChanged(nameof(ManualConnectionFactCount));
                RefreshCommandStates();
            }
        }
    }

    public string ManualConnectionCode
    {
        get => _manualConnectionCode;
        set
        {
            if (SetField(ref _manualConnectionCode, value))
            {
                ManualConnectionFacts.Clear();
                ApplyConnectionWorkspaceStatusPatch(
                    _connectionWorkspaceStateClient.BuildInputResetPatch(
                        ConnectionWorkspaceResetReason.ManualTargetInputChanged));
                OnPropertyChanged(nameof(ManualConnectionFactCount));
                RefreshCommandStates();
            }
        }
    }

    public string CrossNetworkQrInput
    {
        get => _crossNetworkQrInput;
        set
        {
            if (SetField(ref _crossNetworkQrInput, value))
            {
                ApplyConnectionWorkspaceStatusPatch(
                    _connectionWorkspaceStateClient.BuildInputResetPatch(
                        ConnectionWorkspaceResetReason.CrossNetworkInputChanged));
                RefreshCommandStates();
            }
        }
    }

    public string CrossNetworkCodeInput
    {
        get => _crossNetworkCodeInput;
        set
        {
            var normalized = NormalizeCrossNetworkCodeInput(value, _crossNetworkCodeInputPolicy);
            if (SetField(ref _crossNetworkCodeInput, normalized))
            {
                ApplyConnectionWorkspaceStatusPatch(
                    _connectionWorkspaceStateClient.BuildInputResetPatch(
                        ConnectionWorkspaceResetReason.CrossNetworkInputChanged));
                RefreshCommandStates();
            }
            else if (!string.Equals(value, normalized, StringComparison.Ordinal))
            {
                OnPropertyChanged(nameof(CrossNetworkCodeInput));
            }
        }
    }

    public string CrossNetworkGeneratedCode
    {
        get => _crossNetworkGeneratedCode;
        private set => SetField(ref _crossNetworkGeneratedCode, value);
    }

    public string DiscoveryTxtRecord
    {
        get => _discoveryTxtRecord;
        set
        {
            if (SetField(ref _discoveryTxtRecord, value))
            {
                InvalidatePairingAndPreflight();
                RefreshCommandStates();
            }
        }
    }

    public string PairingConnectionCode
    {
        get => _pairingConnectionCode;
        set
        {
            if (SetField(ref _pairingConnectionCode, value))
            {
                _validatedPairingMaterial = null;
                PairingFacts.Clear();
                ClearConnectionPreflight();
                ApplyConnectionWorkspaceStatusPatch(
                    _connectionWorkspaceStateClient.BuildInputResetPatch(
                        ConnectionWorkspaceResetReason.PairingInputChanged));
                OnPropertyChanged(nameof(PairingFactCount));
                RefreshCommandStates();
            }
        }
    }

    public string DiscoveryStatus
    {
        get => _discoveryStatus;
        private set => SetField(ref _discoveryStatus, value);
    }

    public string DiscoveryBrowserStatus
    {
        get => _discoveryBrowserStatus;
        private set => SetField(ref _discoveryBrowserStatus, value);
    }

    public string ManualConnectionStatus
    {
        get => _manualConnectionStatus;
        private set => SetField(ref _manualConnectionStatus, value);
    }

    public string CrossNetworkStatus
    {
        get => _crossNetworkStatus;
        private set => SetField(ref _crossNetworkStatus, value);
    }

    public bool IsDiscoveryScanning
    {
        get => _isDiscoveryScanning;
        private set => SetField(ref _isDiscoveryScanning, value);
    }

    public bool IsDiscoveryCompatibilityModeEnabled
    {
        get => _isDiscoveryCompatibilityModeEnabled;
        set => SetField(ref _isDiscoveryCompatibilityModeEnabled, value);
    }

    public int ExtendedSearchCountdown
    {
        get => _extendedSearchCountdown;
        private set => SetField(ref _extendedSearchCountdown, value);
    }

    public string PairingStatus
    {
        get => _pairingStatus;
        private set => SetField(ref _pairingStatus, value);
    }

    public string ConnectionPreflightStatus
    {
        get => _connectionPreflightStatus;
        private set => SetField(ref _connectionPreflightStatus, value);
    }

    public int DiscoveredPeerCount => DiscoveredPeers.Count;

    public int DiscoveryBrowserFactCount => DiscoveryBrowserFacts.Count;

    public int ManualConnectionFactCount => ManualConnectionFacts.Count;

    public int CrossNetworkConnectionFactCount => CrossNetworkConnectionFacts.Count;

    public int PairingFactCount => PairingFacts.Count;

    public int ConnectionPreflightFactCount => ConnectionPreflightFacts.Count;

    public int DashboardMetricCount => DashboardMetrics.Count;

    public string CoreDiagnosticsStatus
    {
        get => _coreDiagnosticsStatus;
        private set => SetField(ref _coreDiagnosticsStatus, value);
    }

    public int CoreDiagnosticFactCount => CoreDiagnosticFacts.Count;

    public string FileTransferStatus
    {
        get => _fileTransferStatus;
        private set => SetField(ref _fileTransferStatus, value);
    }

    public int FileTransferHistoryCount => FileTransferHistory.Count;

    public string RemoteDesktopStatus
    {
        get => _remoteDesktopStatus;
        private set => SetField(ref _remoteDesktopStatus, value);
    }

    public int RemoteDesktopSessionCount => RemoteDesktopSessions.Count;

    public string SystemMonitorStatus
    {
        get => _systemMonitorStatus;
        private set => SetField(ref _systemMonitorStatus, value);
    }

    public int SystemMonitorMetricCount => SystemMonitorOverview.Count;

    public string UsbManagementStatus
    {
        get => _usbManagementStatus;
        private set => SetField(ref _usbManagementStatus, value);
    }

    public int UsbDeviceCount => UsbDevices.Count;

    public string SettingsStatus
    {
        get => _settingsStatus;
        private set => SetField(ref _settingsStatus, value);
    }

    public int SettingsActionCount => SettingsActions.Count;

    public string SelectedBitrate
    {
        get => _selectedBitrate;
        set
        {
            if (SetField(ref _selectedBitrate, value))
            {
                StatusMessage = $"Bitrate set to {value}";
            }
        }
    }

    public string SelectedFramerate
    {
        get => _selectedFramerate;
        set
        {
            if (SetField(ref _selectedFramerate, value))
            {
                StatusMessage = $"Framerate set to {value}";
            }
        }
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

    private async Task ConnectAsync()
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            StatusMessage = "Connecting...";
            await _engineClient.ConnectAsync();
            StatusMessage = "Connected";
        });
    }

    private async Task DisconnectAsync()
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            StatusMessage = "Disconnecting...";
            await _engineClient.DisconnectAsync();
            StatusMessage = "Disconnected";
        });
    }

    private async Task SendHeartbeatAsync()
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            await _engineClient.SendHeartbeatAsync();
            StatusMessage = "Heartbeat acknowledged";
        });
    }

    private Task StartDiscoveryAsync() =>
        RunDiscoveryBrowserAsync(DiscoveryBrowserAction.Start);

    private Task StopDiscoveryAsync() =>
        RunDiscoveryBrowserAsync(DiscoveryBrowserAction.Stop);

    private Task RefreshDiscoveryAsync() =>
        RunDiscoveryBrowserAsync(DiscoveryBrowserAction.Refresh);

    private async Task RunExtendedDiscoveryAsync()
    {
        ExtendedSearchCountdown = _discoveryBrowserInputPolicy.ExtendedSearchSeconds;
        await RunDiscoveryBrowserAsync(DiscoveryBrowserAction.ExtendedSearch);
    }

    private async Task RunDiscoveryBrowserAsync(DiscoveryBrowserAction action)
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            DiscoveryBrowserStatus = _discoveryBrowserClient.BuildPendingStatus(action);
            var snapshot = await _discoveryBrowserClient.BuildReadOnlySnapshotAsync(
                new DiscoveryBrowserRequest(
                    action,
                    DiscoveryService,
                    DiscoveryTxtRecord,
                    DiscoverySearchText,
                    IsDiscoveryCompatibilityModeEnabled,
                    ExtendedSearchCountdown));

            DiscoveryBrowserFacts.Clear();
            foreach (var fact in snapshot.Facts)
            {
                DiscoveryBrowserFacts.Add(DiscoveryBrowserFactView.FromFact(fact));
            }

            if (action != DiscoveryBrowserAction.Stop)
            {
                _validatedDiscoveredPeer = snapshot.Peers.Count == 1 ? snapshot.Peers[0].Peer : null;
                _validatedPairingMaterial = null;
                DiscoveredPeers.Clear();
                foreach (var peer in snapshot.Peers)
                {
                    DiscoveredPeers.Add(DiscoveredPeerView.FromCandidate(peer));
                }

                PairingFacts.Clear();
                ClearConnectionPreflight();
                OnPropertyChanged(nameof(DiscoveredPeerCount));
                OnPropertyChanged(nameof(PairingFactCount));
            }

            OnPropertyChanged(nameof(DiscoveryBrowserFactCount));
            ApplyConnectionWorkspaceStatusPatch(
                _connectionWorkspaceStateClient.BuildDiscoveryBrowserResultPatch(
                    action,
                    snapshot,
                    PairingStatus));
        });
    }

    private async Task PrepareManualConnectionAsync()
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            ManualConnectionStatus = _manualConnectionClient.BuildPendingStatus();
            var snapshot = await _manualConnectionClient.BuildReadOnlySnapshotAsync(
                new ManualConnectionRequest(
                    ManualConnectionHost,
                    ManualConnectionPort,
                    ManualConnectionCode));
            ManualConnectionFacts.Clear();
            foreach (var fact in snapshot.Facts)
            {
                ManualConnectionFacts.Add(ManualConnectionFactView.FromFact(fact));
            }

            _validatedDiscoveredPeer = null;
            _validatedPairingMaterial = null;
            PairingFacts.Clear();
            ClearConnectionPreflight();
            OnPropertyChanged(nameof(ManualConnectionFactCount));
            OnPropertyChanged(nameof(PairingFactCount));
            DiscoveryService = snapshot.Target.Service;
            ApplyConnectionWorkspaceStatusPatch(
                _connectionWorkspaceStateClient.BuildManualTargetPreparedPatch(snapshot));
        });
    }

    private Task GenerateQRCodeAsync() =>
        RunCrossNetworkConnectionAsync(CrossNetworkConnectionAction.GenerateQrCode);

    private Task ScanQRCodeAsync() =>
        RunCrossNetworkConnectionAsync(CrossNetworkConnectionAction.ScanQrCode);

    private Task GenerateConnectionCodeAsync() =>
        RunCrossNetworkConnectionAsync(CrossNetworkConnectionAction.GenerateCode);

    private Task RegenerateConnectionCodeAsync() =>
        RunCrossNetworkConnectionAsync(CrossNetworkConnectionAction.RegenerateCode);

    private Task CopyConnectionCodeAsync() =>
        RunCrossNetworkConnectionAsync(CrossNetworkConnectionAction.CopyCode);

    private Task ConnectConnectionCodeAsync() =>
        RunCrossNetworkConnectionAsync(CrossNetworkConnectionAction.ConnectWithCode);

    private async Task RunCrossNetworkConnectionAsync(CrossNetworkConnectionAction action)
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            CrossNetworkStatus = _crossNetworkConnectionClient.BuildPendingStatus(action);

            var snapshot = await _crossNetworkConnectionClient.BuildReadOnlySnapshotAsync(
                new CrossNetworkConnectionRequest(
                    action,
                    CrossNetworkQrInput,
                    CrossNetworkCodeInput,
                    CrossNetworkGeneratedCode));

            CrossNetworkConnectionFacts.Clear();
            foreach (var fact in snapshot.Facts)
            {
                CrossNetworkConnectionFacts.Add(CrossNetworkConnectionFactView.FromFact(fact));
            }

            if (!string.IsNullOrWhiteSpace(snapshot.GeneratedCode))
            {
                CrossNetworkGeneratedCode = snapshot.GeneratedCode;
            }

            _validatedDiscoveredPeer = null;
            _validatedPairingMaterial = null;
            PairingFacts.Clear();
            ClearConnectionPreflight();
            OnPropertyChanged(nameof(CrossNetworkConnectionFactCount));
            OnPropertyChanged(nameof(PairingFactCount));
            ApplyConnectionWorkspaceStatusPatch(
                _connectionWorkspaceStateClient.BuildCrossNetworkPreparedPatch(snapshot));
        });
    }

    private async Task ParseAdvertisementAsync()
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            DiscoveryStatus = _discoveryClient.BuildPendingStatus();
            var peer = await _discoveryClient.ParseAdvertisementAsync(DiscoveryService, DiscoveryTxtRecord);
            _validatedDiscoveredPeer = peer;
            _validatedPairingMaterial = null;
            DiscoveredPeers.Clear();
            DiscoveredPeers.Add(DiscoveredPeerView.FromCandidate(_discoveryBrowserClient.BuildPeerCandidate(peer)));
            PairingFacts.Clear();
            ClearConnectionPreflight();
            OnPropertyChanged(nameof(DiscoveredPeerCount));
            OnPropertyChanged(nameof(PairingFactCount));
            ApplyConnectionWorkspaceStatusPatch(
                _connectionWorkspaceStateClient.BuildDiscoveryPeerValidatedPatch(peer));
        });
    }

    private async Task ValidatePairingCodeAsync()
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            PairingStatus = _pairingMaterialClient.BuildPendingStatus();
            var expectedFingerprint = DiscoveredPeers.Count == 1
                ? DiscoveredPeers[0].PublicKeyFingerprint
                : null;
            var snapshot = await _pairingMaterialClient.BuildReadOnlySnapshotAsync(
                PairingConnectionCode,
                expectedFingerprint);
            var material = snapshot.Material;
            _validatedPairingMaterial = material;
            ClearConnectionPreflight();
            PairingFacts.Clear();
            foreach (var fact in snapshot.Facts)
            {
                PairingFacts.Add(PairingFactView.FromFact(fact));
            }

            OnPropertyChanged(nameof(PairingFactCount));
            ApplyConnectionWorkspaceStatusPatch(
                _connectionWorkspaceStateClient.BuildPairingValidatedPatch(material));
        });
    }

    private async Task PrepareConnectionAsync()
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            var discoveredPeer = _validatedDiscoveredPeer;
            var pairingMaterial = _validatedPairingMaterial;
            var readiness = _connectionWorkspaceStateClient.BuildPreflightReadiness(
                discoveredPeer,
                pairingMaterial);
            if (!readiness.IsReady)
            {
                throw new InvalidOperationException(readiness.ErrorMessage);
            }

            ConnectionPreflightStatus = _connectionPreflightClient.BuildPendingStatus();
            var snapshot = await _connectionPreflightClient.BuildReadOnlySnapshotAsync(
                discoveredPeer!,
                pairingMaterial!);
            ConnectionPreflightFacts.Clear();
            foreach (var fact in snapshot.Facts)
            {
                ConnectionPreflightFacts.Add(ConnectionPreflightFactView.FromFact(fact));
            }

            OnPropertyChanged(nameof(ConnectionPreflightFactCount));
            ApplyConnectionWorkspaceStatusPatch(
                _connectionWorkspaceStateClient.BuildPreflightPreparedPatch(snapshot));
        });
    }

    private async Task RunCoreDiagnosticsAsync()
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            CoreDiagnosticsStatus = _coreDiagnosticsClient.BuildPendingStatus();
            var snapshot = await _coreDiagnosticsClient.BuildInteropSnapshotAsync();
            CoreDiagnosticFacts.Clear();
            foreach (var fact in snapshot.Facts)
            {
                CoreDiagnosticFacts.Add(CoreDiagnosticFactView.FromFact(fact));
            }

            OnPropertyChanged(nameof(CoreDiagnosticFactCount));
            CoreDiagnosticsStatus = $"Snapshot {snapshot.CapturedAt:HH:mm:ss} UTC";
            StatusMessage = "Core diagnostics updated";
        });
    }

    private async Task RefreshFileTransferAsync()
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            FileTransferStatus = _fileTransferClient.BuildPendingStatus();
            var snapshot = await _fileTransferClient.BuildReadOnlySnapshotAsync();
            FileTransferQueue.Clear();
            foreach (var item in snapshot.Queue)
            {
                FileTransferQueue.Add(FileTransferQueueItemView.FromItem(item));
            }

            FileTransferHistory.Clear();
            foreach (var item in snapshot.History)
            {
                FileTransferHistory.Add(FileTransferHistoryItemView.FromItem(item));
            }

            FileTransferSecurityFacts.Clear();
            foreach (var fact in snapshot.Security)
            {
                FileTransferSecurityFacts.Add(FileTransferSecurityFactView.FromFact(fact));
            }

            RefreshDashboardMetrics();
            OnPropertyChanged(nameof(FileTransferHistoryCount));
            FileTransferStatus = $"Snapshot {snapshot.CapturedAt:HH:mm:ss} UTC";
            StatusMessage = "File transfer workspace updated";
        });
    }

    private async Task RefreshUsbManagementAsync()
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            UsbManagementStatus = _usbManagementClient.BuildPendingStatus();
            var snapshot = await _usbManagementClient.BuildReadOnlySnapshotAsync();
            UsbDeviceStats.Clear();
            foreach (var stat in snapshot.Stats)
            {
                UsbDeviceStats.Add(UsbDeviceStatView.FromStat(stat));
            }

            UsbDevices.Clear();
            foreach (var device in snapshot.Devices)
            {
                UsbDevices.Add(UsbDeviceItemView.FromItem(device));
            }

            OnPropertyChanged(nameof(UsbDeviceCount));
            UsbManagementStatus = $"Last scan {snapshot.CapturedAt:HH:mm:ss} UTC";
            StatusMessage = "USB management workspace updated";
        });
    }

    private async Task RefreshRemoteDesktopAsync()
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            RemoteDesktopStatus = _remoteDesktopClient.BuildPendingStatus();
            var snapshot = await _remoteDesktopClient.BuildReadOnlySnapshotAsync(
                SelectedBitrate,
                SelectedFramerate);
            RemoteDesktopSessions.Clear();
            foreach (var item in snapshot.Sessions)
            {
                RemoteDesktopSessions.Add(RemoteDesktopSessionItemView.FromItem(item));
            }

            RemoteDesktopControlFacts.Clear();
            foreach (var fact in snapshot.ControlFacts)
            {
                RemoteDesktopControlFacts.Add(RemoteDesktopControlFactView.FromFact(fact));
            }

            OnPropertyChanged(nameof(RemoteDesktopSessionCount));
            RemoteDesktopStatus = $"Snapshot {snapshot.CapturedAt:HH:mm:ss} UTC";
            StatusMessage = "Remote desktop workspace updated";
        });
    }

    private async Task RefreshSystemMonitorAsync()
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            SystemMonitorStatus = _systemMonitorClient.BuildPendingStatus();
            var snapshot = await _systemMonitorClient.BuildReadOnlySnapshotAsync();
            SystemMonitorOverview.Clear();
            foreach (var metric in snapshot.Overview)
            {
                SystemMonitorOverview.Add(SystemMonitorMetricView.FromMetric(metric));
            }

            SystemMonitorDetails.Clear();
            foreach (var metric in snapshot.Details)
            {
                SystemMonitorDetails.Add(SystemMonitorMetricView.FromMetric(metric));
            }

            SystemMonitorIndicators.Clear();
            foreach (var indicator in snapshot.Indicators)
            {
                SystemMonitorIndicators.Add(SystemMonitorIndicatorView.FromIndicator(indicator));
            }

            OnPropertyChanged(nameof(SystemMonitorMetricCount));
            SystemMonitorStatus = $"Snapshot {snapshot.CapturedAt:HH:mm:ss} UTC";
            StatusMessage = "System monitor workspace updated";
        });
    }

    private async Task RefreshSettingsAsync()
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            SettingsStatus = _settingsClient.BuildPendingStatus();
            var snapshot = await _settingsClient.BuildReadOnlySnapshotAsync();
            SettingsTabs.Clear();
            foreach (var tab in snapshot.Tabs)
            {
                SettingsTabs.Add(SettingsTabItemView.FromItem(tab));
            }

            SettingsActions.Clear();
            foreach (var action in snapshot.Actions)
            {
                SettingsActions.Add(SettingsActionItemView.FromItem(action));
            }

            SettingsDetails.Clear();
            foreach (var detail in snapshot.Details)
            {
                SettingsDetails.Add(SettingsDetailItemView.FromItem(detail));
            }

            OnPropertyChanged(nameof(SettingsActionCount));
            SettingsStatus = $"Snapshot {snapshot.CapturedAt:HH:mm:ss} UTC";
            StatusMessage = "Settings workspace updated";
        });
    }

    private bool CanConnect() => !IsBusy && ConnectionState == EngineConnectionState.Disconnected;

    private bool CanDisconnect() => !IsBusy && (ConnectionState == EngineConnectionState.Connected || ConnectionState == EngineConnectionState.Reconnecting);

    private bool CanSendHeartbeat() => !IsBusy && ConnectionState == EngineConnectionState.Connected;

    private bool CanUseDiscoveryBrowser() => !IsBusy && IsDeviceDiscoverySelected;

    private bool CanPrepareManualConnection() =>
        !IsBusy
        && IsDeviceDiscoverySelected
        && !string.IsNullOrWhiteSpace(ManualConnectionHost)
        && !string.IsNullOrWhiteSpace(ManualConnectionPort);

    private bool CanUseCrossNetworkConnection() => !IsBusy && IsDeviceDiscoverySelected;

    private bool CanScanQRCode() =>
        CanUseCrossNetworkConnection()
        && !string.IsNullOrWhiteSpace(CrossNetworkQrInput);

    private bool CanCopyConnectionCode() =>
        CanUseCrossNetworkConnection()
        && !string.IsNullOrWhiteSpace(CrossNetworkGeneratedCode);

    private bool CanConnectConnectionCode() =>
        CanUseCrossNetworkConnection()
        && _crossNetworkConnectionClient.CanConnectWithCode(CrossNetworkCodeInput);

    private bool CanParseAdvertisement() =>
        !IsBusy
        && IsDeviceDiscoverySelected
        && !string.IsNullOrWhiteSpace(DiscoveryService)
        && !string.IsNullOrWhiteSpace(DiscoveryTxtRecord);

    private bool CanValidatePairingCode() =>
        !IsBusy
        && IsDeviceDiscoverySelected
        && !string.IsNullOrWhiteSpace(PairingConnectionCode);

    private bool CanPrepareConnection() =>
        !IsBusy
        && IsDeviceDiscoverySelected
        && _validatedDiscoveredPeer is not null
        && _validatedPairingMaterial is not null;

    private bool CanRefreshUsbManagement() => !IsBusy && IsUsbManagementSelected;

    private bool CanRunCoreDiagnostics() => !IsBusy && IsQuantumSelected;

    private bool CanRefreshFileTransfer() => !IsBusy && IsFileTransferSelected;

    private bool CanRefreshRemoteDesktop() => !IsBusy && IsRemoteDesktopSelected;

    private bool CanRefreshSystemMonitor() => !IsBusy && IsSystemMonitorSelected;

    private bool CanRefreshSettings() => !IsBusy && IsSettingsSelected;

    private async Task RunWithBusyState(Func<Task> action)
    {
        try
        {
            IsBusy = true;
            await action();
        }
        catch (Exception ex)
        {
            StatusMessage = ex.Message;
            if (IsDeviceDiscoverySelected)
            {
                ApplyConnectionWorkspaceStatusPatch(
                    _connectionWorkspaceStateClient.BuildErrorPatch(ex.Message));
            }

            if (IsUsbManagementSelected)
            {
                UsbManagementStatus = ex.Message;
            }

            if (IsQuantumSelected)
            {
                CoreDiagnosticsStatus = ex.Message;
            }

            if (IsFileTransferSelected)
            {
                FileTransferStatus = ex.Message;
            }

            if (IsRemoteDesktopSelected)
            {
                RemoteDesktopStatus = ex.Message;
            }

            if (IsSystemMonitorSelected)
            {
                SystemMonitorStatus = ex.Message;
            }

            if (IsSettingsSelected)
            {
                SettingsStatus = ex.Message;
            }
        }
        finally
        {
            IsBusy = false;
        }
    }

    private void RefreshCommandStates()
    {
        (ConnectCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (DisconnectCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (HeartbeatCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (StartDiscoveryCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (StopDiscoveryCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (RefreshDiscoveryCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (RunExtendedDiscoveryCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (PrepareManualConnectionCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (GenerateQRCodeCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (ScanQRCodeCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (GenerateConnectionCodeCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (RegenerateConnectionCodeCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (CopyConnectionCodeCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (ConnectConnectionCodeCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (ParseAdvertisementCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (ValidatePairingCodeCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (PrepareConnectionCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (RefreshUsbManagementCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (RunCoreDiagnosticsCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (RefreshFileTransferCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (RefreshRemoteDesktopCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (RefreshSystemMonitorCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (RefreshSettingsCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        RefreshDynamicWorkspaceActionStates();
    }

    private void RefreshDynamicWorkspaceActionStates()
    {
        LoadWorkspaceActionSurface(WorkspaceActionSurface.SidebarSession, SidebarSessionActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.TopBarActions, TopBarActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.SessionControls, SessionControlActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.UsbManagementHeader, UsbManagementHeaderActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.FileTransferHeader, FileTransferHeaderActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.RemoteDesktopHeader, RemoteDesktopHeaderActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.QuantumDiagnosticsHeader, QuantumDiagnosticsHeaderActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.SystemMonitorHeader, SystemMonitorHeaderActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.SettingsHeader, SettingsHeaderActions);
    }

    private void ApplyConnectionWorkspaceStatusPatch(ConnectionWorkspaceStatusPatch patch)
    {
        if (patch.DiscoveryStatus is not null)
        {
            DiscoveryStatus = patch.DiscoveryStatus;
        }

        if (patch.DiscoveryBrowserStatus is not null)
        {
            DiscoveryBrowserStatus = patch.DiscoveryBrowserStatus;
        }

        if (patch.ManualConnectionStatus is not null)
        {
            ManualConnectionStatus = patch.ManualConnectionStatus;
        }

        if (patch.CrossNetworkStatus is not null)
        {
            CrossNetworkStatus = patch.CrossNetworkStatus;
        }

        if (patch.PairingStatus is not null)
        {
            PairingStatus = patch.PairingStatus;
        }

        if (patch.ConnectionPreflightStatus is not null)
        {
            ConnectionPreflightStatus = patch.ConnectionPreflightStatus;
        }

        if (patch.StatusMessage is not null)
        {
            StatusMessage = patch.StatusMessage;
        }

        if (patch.IsDiscoveryScanning.HasValue)
        {
            IsDiscoveryScanning = patch.IsDiscoveryScanning.Value;
        }
    }

    private void RefreshDashboardMetrics()
    {
        var snapshot = _dashboardMetricsClient.BuildReadOnlySnapshot(
            new DashboardMetricsRequest(
                ConnectionState,
                FileTransferQueue.Count,
                IsBusy));

        OnlineDeviceCount = snapshot.OnlineDeviceCount;
        ActiveSessionCount = snapshot.ActiveSessionCount;
        TransferTaskCount = snapshot.TransferTaskCount;
        PerformanceStatus = snapshot.PerformanceStatus;
        DashboardMetrics.Clear();
        foreach (var metric in snapshot.Metrics)
        {
            DashboardMetrics.Add(DashboardMetricView.FromMetric(metric));
        }

        OnPropertyChanged(nameof(DashboardMetricCount));
    }

    private void LoadWorkspaceActions()
    {
        LoadWorkspaceActionSurface(WorkspaceActionSurface.SidebarSession, SidebarSessionActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.TopBarActions, TopBarActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.SessionControls, SessionControlActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.DeviceDiscoveryPrimary, DeviceDiscoveryPrimaryActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.DeviceDiscoveryScan, DeviceDiscoveryScanActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.CrossNetworkQr, CrossNetworkQrActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.CrossNetworkCodePrimary, CrossNetworkCodePrimaryActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.CrossNetworkCodeConnect, CrossNetworkCodeConnectActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.UsbManagementHeader, UsbManagementHeaderActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.FileTransferHeader, FileTransferHeaderActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.FileTransfer, FileTransferActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.RemoteDesktopHeader, RemoteDesktopHeaderActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.RemoteDesktop, RemoteDesktopActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.QuantumDiagnosticsHeader, QuantumDiagnosticsHeaderActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.SystemMonitorHeader, SystemMonitorHeaderActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.SystemMonitorControls, SystemMonitorActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.SettingsHeader, SettingsHeaderActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.SettingsToolbar, SettingsToolbarActions);
        LoadWorkspaceActionSurface(WorkspaceActionSurface.SettingsMaintenance, SettingsMaintenanceActions);
    }

    private void LoadWorkspaceActionSurface(
        WorkspaceActionSurface surface,
        ObservableCollection<WorkspaceActionItemView> target)
    {
        var snapshot = _workspaceActionCatalogClient.BuildReadOnlySnapshot(
            new WorkspaceActionCatalogRequest(surface));

        target.Clear();
        foreach (var action in snapshot.Actions)
        {
            target.Add(WorkspaceActionItemView.FromItem(
                action,
                ResolveWorkspaceActionCommand(action.CommandId),
                ResolveWorkspaceActionEnabled(action.GateId, action.IsEnabled),
                ResolveWorkspaceActionDetail(action.DetailSlot, action.Detail)));
        }
    }

    private ICommand? ResolveWorkspaceActionCommand(WorkspaceActionCommandId commandId) =>
        commandId switch
        {
            WorkspaceActionCommandId.Connect => ConnectCommand,
            WorkspaceActionCommandId.Disconnect => DisconnectCommand,
            WorkspaceActionCommandId.Heartbeat => HeartbeatCommand,
            WorkspaceActionCommandId.ParseTxt => ParseAdvertisementCommand,
            WorkspaceActionCommandId.ValidatePairing => ValidatePairingCodeCommand,
            WorkspaceActionCommandId.PrepareConnection => PrepareConnectionCommand,
            WorkspaceActionCommandId.RunExtendedDiscovery => RunExtendedDiscoveryCommand,
            WorkspaceActionCommandId.PrepareManualConnection => PrepareManualConnectionCommand,
            WorkspaceActionCommandId.StartDiscovery => StartDiscoveryCommand,
            WorkspaceActionCommandId.StopDiscovery => StopDiscoveryCommand,
            WorkspaceActionCommandId.RefreshDiscovery => RefreshDiscoveryCommand,
            WorkspaceActionCommandId.GenerateQrCode => GenerateQRCodeCommand,
            WorkspaceActionCommandId.ScanQrCode => ScanQRCodeCommand,
            WorkspaceActionCommandId.GenerateConnectionCode => GenerateConnectionCodeCommand,
            WorkspaceActionCommandId.CopyConnectionCode => CopyConnectionCodeCommand,
            WorkspaceActionCommandId.RegenerateConnectionCode => RegenerateConnectionCodeCommand,
            WorkspaceActionCommandId.ConnectConnectionCode => ConnectConnectionCodeCommand,
            WorkspaceActionCommandId.RefreshUsbManagement => RefreshUsbManagementCommand,
            WorkspaceActionCommandId.RefreshFileTransfer => RefreshFileTransferCommand,
            WorkspaceActionCommandId.RefreshRemoteDesktop => RefreshRemoteDesktopCommand,
            WorkspaceActionCommandId.RunCoreDiagnostics => RunCoreDiagnosticsCommand,
            WorkspaceActionCommandId.RefreshSystemMonitor => RefreshSystemMonitorCommand,
            WorkspaceActionCommandId.RefreshSettings => RefreshSettingsCommand,
            _ => null
        };

    private bool ResolveWorkspaceActionEnabled(
        WorkspaceActionGateId gateId,
        bool fallback) =>
        gateId switch
        {
            WorkspaceActionGateId.CanConnect => CanConnect(),
            WorkspaceActionGateId.CanDisconnect => CanDisconnect(),
            WorkspaceActionGateId.CanSendHeartbeat => CanSendHeartbeat(),
            WorkspaceActionGateId.CanRefreshUsbManagement => CanRefreshUsbManagement(),
            WorkspaceActionGateId.CanRefreshFileTransfer => CanRefreshFileTransfer(),
            WorkspaceActionGateId.CanRefreshRemoteDesktop => CanRefreshRemoteDesktop(),
            WorkspaceActionGateId.CanRunCoreDiagnostics => CanRunCoreDiagnostics(),
            WorkspaceActionGateId.CanRefreshSystemMonitor => CanRefreshSystemMonitor(),
            WorkspaceActionGateId.CanRefreshSettings => CanRefreshSettings(),
            _ => fallback
        };

    private string ResolveWorkspaceActionDetail(
        WorkspaceActionDetailSlot detailSlot,
        string fallback) =>
        detailSlot switch
        {
            WorkspaceActionDetailSlot.TopBarNotifications => TopBarNotificationsStatus,
            WorkspaceActionDetailSlot.TopBarTheme => TopBarThemeStatus,
            _ => fallback
        };

    private void RefreshTopBarStatus()
    {
        var snapshot = _topBarStatusClient.BuildReadOnlySnapshot(
            new TopBarStatusRequest(
                ConnectionStatus,
                PerformanceStatus,
                SelectedFeature.Title));

        TopBarConnectionStatus = GetTopBarStatusValue(snapshot, TopBarStatusSlot.Connection, ConnectionStatus);
        TopBarDiagnosticsStatus = GetTopBarStatusValue(snapshot, TopBarStatusSlot.Diagnostics, PerformanceStatus);
        TopBarNotificationsStatus = GetTopBarStatusValue(snapshot, TopBarStatusSlot.Notifications, "Off");
        TopBarThemeStatus = GetTopBarStatusValue(snapshot, TopBarStatusSlot.Theme, "System");
        LoadWorkspaceActionSurface(WorkspaceActionSurface.TopBarActions, TopBarActions);
    }

    private static string GetTopBarStatusValue(
        TopBarStatusSnapshot snapshot,
        TopBarStatusSlot slot,
        string fallback)
    {
        foreach (var item in snapshot.Items)
        {
            if (item.Slot == slot)
            {
                return item.Value;
            }
        }

        return fallback;
    }

    private void OnEngineStateChanged(object? sender, EngineConnectionState newState)
    {
        ConnectionState = newState;
        StatusMessage = newState switch
        {
            EngineConnectionState.Connecting => "Connecting...",
            EngineConnectionState.Connected => "Connected",
            EngineConnectionState.Reconnecting => "Reconnecting...",
            EngineConnectionState.ShuttingDown => "Disconnecting...",
            _ => "Disconnected"
        };
    }

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (Equals(field, value))
        {
            return false;
        }

        field = value;
        OnPropertyChanged(propertyName);
        return true;
    }

    private static string NormalizeCrossNetworkCodeInput(
        string? value,
        CrossNetworkCodeInputPolicy inputPolicy)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return "";
        }

        var normalized = new char[inputPolicy.CodeLength];
        var count = 0;
        foreach (var current in value.ToUpperInvariant())
        {
            if (!inputPolicy.Alphabet.Contains(current))
            {
                continue;
            }

            normalized[count] = current;
            count++;
            if (count == normalized.Length)
            {
                break;
            }
        }

        return new string(normalized, 0, count);
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }

    private void InvalidatePairingAndPreflight()
    {
        _validatedDiscoveredPeer = null;
        _validatedPairingMaterial = null;
        DiscoveredPeers.Clear();
        DiscoveryBrowserFacts.Clear();
        PairingFacts.Clear();
        ClearConnectionPreflight();
        ApplyConnectionWorkspaceStatusPatch(
            _connectionWorkspaceStateClient.BuildInputResetPatch(
                ConnectionWorkspaceResetReason.DiscoveryInputChanged));
        OnPropertyChanged(nameof(DiscoveredPeerCount));
        OnPropertyChanged(nameof(DiscoveryBrowserFactCount));
        OnPropertyChanged(nameof(PairingFactCount));
    }

    private void ClearConnectionPreflight()
    {
        ConnectionPreflightFacts.Clear();
        ApplyConnectionWorkspaceStatusPatch(
            _connectionWorkspaceStateClient.BuildInputResetPatch(
                ConnectionWorkspaceResetReason.PreflightCleared));
        OnPropertyChanged(nameof(ConnectionPreflightFactCount));
    }
}

public sealed record SettingsTabItemView(
    string Title,
    string Detail)
{
    public static SettingsTabItemView FromItem(SettingsTabItem item) =>
        new(item.Title, item.Detail);
}

public sealed record DashboardMetricView(
    string Title,
    string Value,
    string Detail)
{
    public static DashboardMetricView FromMetric(DashboardMetric metric) =>
        new(metric.Label, metric.Value, metric.Detail);
}

public sealed record SettingsActionItemView(
    string Key,
    string Title,
    string State,
    string Detail)
{
    public static SettingsActionItemView FromItem(SettingsActionItem item) =>
        new(item.Key, item.Title, item.State, item.Detail);
}

public sealed record SettingsDetailItemView(
    string Section,
    string Label,
    string Value,
    string Detail)
{
    public static SettingsDetailItemView FromItem(SettingsDetailItem item) =>
        new(item.Section, item.Label, item.Value, item.Detail);
}

public sealed record UsbDeviceStatView(
    string Title,
    string Value,
    string Detail)
{
    public static UsbDeviceStatView FromStat(UsbDeviceStat stat) =>
        new(stat.Title, stat.Value, stat.Detail);
}

public sealed record UsbDeviceItemView(
    string Name,
    string DeviceId,
    string DeviceType,
    string VendorId,
    string ProductId,
    string SerialNumber,
    string ConnectionInterface,
    string Capabilities)
{
    public static UsbDeviceItemView FromItem(UsbDeviceItem item) =>
        new(
            item.Name,
            item.DeviceId,
            item.DeviceType,
            item.VendorId,
            item.ProductId,
            item.SerialNumber,
            item.ConnectionInterface,
            item.Capabilities);
}

public sealed record SystemMonitorMetricView(
    string Label,
    string Value,
    string Detail)
{
    public static SystemMonitorMetricView FromMetric(SystemMonitorMetric metric) =>
        new(metric.Label, metric.Value, metric.Detail);
}

public sealed record SystemMonitorIndicatorView(
    string Label,
    string State,
    string Detail)
{
    public static SystemMonitorIndicatorView FromIndicator(SystemMonitorIndicator indicator) =>
        new(indicator.Label, indicator.State, indicator.Detail);
}

public sealed record RemoteDesktopSessionItemView(
    string TargetName,
    string State,
    string Transport,
    string Quality,
    string Detail)
{
    public static RemoteDesktopSessionItemView FromItem(RemoteDesktopSessionItem item) =>
        new(item.TargetName, item.State, item.Transport, item.Quality, item.Detail);
}

public sealed record RemoteDesktopControlFactView(
    string Label,
    string Value,
    string Detail)
{
    public static RemoteDesktopControlFactView FromFact(RemoteDesktopControlFact fact) =>
        new(fact.Label, fact.Value, fact.Detail);
}

public sealed record FileTransferQueueItemView(
    string Name,
    string State,
    string Size,
    string Binding,
    string Detail)
{
    public static FileTransferQueueItemView FromItem(FileTransferQueueItem item) =>
        new(item.Name, item.State, item.Size, item.Binding, item.Detail);
}

public sealed record FileTransferHistoryItemView(
    string Name,
    string Result,
    string Hmac,
    string Signature)
{
    public static FileTransferHistoryItemView FromItem(FileTransferHistoryItem item) =>
        new(item.Name, item.Result, item.Hmac, item.Signature);
}

public sealed record FileTransferSecurityFactView(
    string Label,
    string Value,
    string Detail)
{
    public static FileTransferSecurityFactView FromFact(FileTransferSecurityFact fact) =>
        new(fact.Label, fact.Value, fact.Detail);
}

public sealed record WorkspaceActionItemView(
    string Key,
    string Title,
    string Glyph,
    bool IsEnabled,
    string Detail,
    ICommand? Command = null)
{
    public static WorkspaceActionItemView FromItem(
        WorkspaceActionItem item,
        ICommand? command = null,
        bool? isEnabled = null,
        string? detail = null) =>
        new(item.Key, item.Title, item.Glyph, isEnabled ?? item.IsEnabled, detail ?? item.Detail, command);
}

public sealed record CoreDiagnosticFactView(
    string Label,
    string Value,
    string Detail)
{
    public static CoreDiagnosticFactView FromFact(CoreDiagnosticFact fact) =>
        new(fact.Label, fact.Value, fact.Detail);
}

public sealed record PairingFactView(
    string Label,
    string Value,
    string Detail)
{
    public static PairingFactView FromFact(PairingFact fact) =>
        new(fact.Label, fact.Value, fact.Detail);
}

public sealed record DiscoveryBrowserFactView(
    string Label,
    string Value,
    string Detail)
{
    public static DiscoveryBrowserFactView FromFact(DiscoveryBrowserFact fact) =>
        new(fact.Label, fact.Value, fact.Detail);
}

public sealed record ManualConnectionFactView(
    string Label,
    string Value,
    string Detail)
{
    public static ManualConnectionFactView FromFact(ManualConnectionFact fact) =>
        new(fact.Label, fact.Value, fact.Detail);
}

public sealed record CrossNetworkConnectionFactView(
    string Label,
    string Value,
    string Detail)
{
    public static CrossNetworkConnectionFactView FromFact(CrossNetworkConnectionFact fact) =>
        new(fact.Label, fact.Value, fact.Detail);
}

public sealed record ConnectionPreflightFactView(
    string Label,
    string Value,
    string Detail)
{
    public static ConnectionPreflightFactView FromFact(ConnectionPreflightFact fact) =>
        new(fact.Label, fact.Value, fact.Detail);
}

public sealed record DiscoveredPeerView(
    string DeviceId,
    string DisplayName,
    string Platform,
    string ServiceKind,
    string PublicKeyFingerprint,
    string CapabilitiesSummary,
    string ProtocolVersion,
    string TrustSummary)
{
    public static DiscoveredPeerView FromCandidate(DiscoveryBrowserPeerCandidate candidate) =>
        new(
            candidate.Peer.DeviceId,
            candidate.Peer.DisplayName,
            candidate.Peer.Platform.ToString(),
            candidate.Peer.ServiceKind.ToString(),
            candidate.Peer.PublicKeyFingerprint,
            candidate.CapabilitiesSummary,
            candidate.Peer.ProtocolVersion,
            candidate.TrustSummary);
}

internal sealed class UnavailableDiscoveryClient : IDiscoveryClient
{
    public string BuildPendingStatus() => CoreDiscoveryClient.DefaultPendingStatus;

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

    public Task<ManualConnectionSnapshot> BuildReadOnlySnapshotAsync(ManualConnectionRequest request)
    {
        throw new InvalidOperationException("Manual connection client is not configured.");
    }
}

internal sealed class UnavailableCrossNetworkConnectionClient : ICrossNetworkConnectionClient
{
    public CrossNetworkCodeInputPolicy BuildCodeInputPolicy() =>
        CrossNetworkConnectionClient.DefaultCodeInputPolicy;

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
    public string BuildPendingStatus() => CoreDiagnosticsClient.DefaultPendingStatus;

    public Task<CoreDiagnosticsSnapshot> BuildInteropSnapshotAsync()
    {
        throw new InvalidOperationException("Core diagnostics client is not configured.");
    }
}

internal sealed class UnavailableFileTransferWorkspaceClient : IFileTransferWorkspaceClient
{
    public string BuildPendingStatus() => FileTransferWorkspaceClient.DefaultPendingStatus;

    public Task<FileTransferWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        throw new InvalidOperationException("File transfer workspace client is not configured.");
    }
}

internal sealed class UnavailableRemoteDesktopWorkspaceClient : IRemoteDesktopWorkspaceClient
{
    public string BuildPendingStatus() => RemoteDesktopWorkspaceClient.DefaultPendingStatus;

    public Task<RemoteDesktopWorkspaceSnapshot> BuildReadOnlySnapshotAsync(
        string bitrateProfile,
        string framerateProfile)
    {
        throw new InvalidOperationException("Remote desktop workspace client is not configured.");
    }
}

internal sealed class UnavailableSystemMonitorWorkspaceClient : ISystemMonitorWorkspaceClient
{
    public string BuildPendingStatus() => SystemMonitorWorkspaceClient.DefaultPendingStatus;

    public Task<SystemMonitorWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        throw new InvalidOperationException("System monitor workspace client is not configured.");
    }
}

internal sealed class UnavailableUsbManagementWorkspaceClient : IUsbManagementWorkspaceClient
{
    public string BuildPendingStatus() => UsbManagementWorkspaceClient.DefaultPendingStatus;

    public Task<UsbManagementWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        throw new InvalidOperationException("USB management workspace client is not configured.");
    }
}

internal sealed class UnavailableSettingsWorkspaceClient : ISettingsWorkspaceClient
{
    public string BuildPendingStatus() => SettingsWorkspaceClient.DefaultPendingStatus;

    public Task<SettingsWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        throw new InvalidOperationException("Settings workspace client is not configured.");
    }
}

public sealed class AsyncRelayCommand : ICommand
{
    private readonly Func<Task> _execute;
    private readonly Func<bool>? _canExecute;

    public AsyncRelayCommand(Func<Task> execute, Func<bool>? canExecute = null)
    {
        _execute = execute;
        _canExecute = canExecute;
    }

    public event EventHandler? CanExecuteChanged;

    public bool CanExecute(object? parameter) => _canExecute?.Invoke() ?? true;

    public async void Execute(object? parameter)
    {
        await _execute();
    }

    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}
