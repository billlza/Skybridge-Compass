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
    private readonly IWorkspaceErrorStatusClient _workspaceErrorStatusClient;
    private readonly ISessionStatusClient _sessionStatusClient;
    private readonly IFeatureCatalogClient _featureCatalogClient;
    private readonly ISessionCommandStateClient _sessionCommandStateClient;
    private readonly IWorkspaceCommandStateClient _workspaceCommandStateClient;
    private readonly WorkspaceCommandRegistry _workspaceCommandRegistry;
    private readonly WorkspaceActionSurfaceTargets _workspaceActionSurfaceTargets;
    private readonly WorkspaceActionSurfaceLoader _workspaceActionSurfaceLoader;
    private readonly WorkspaceStatusPatchApplier _workspaceStatusPatchApplier;
    private readonly WorkspaceCountNotifier _workspaceCountNotifier;
    private readonly WorkspaceSnapshotApplier _workspaceSnapshotApplier;
    private readonly DashboardMetricsUpdater _dashboardMetricsUpdater;
    private string _statusMessage = "";
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
    private string _discoveryStatus = "";
    private string _discoveryBrowserStatus = "";
    private string _manualConnectionStatus = "";
    private string _crossNetworkStatus = "";
    private string _pairingStatus = "";
    private string _connectionPreflightStatus = "";
    private string _coreDiagnosticsStatus = "";
    private string _fileTransferStatus = "";
    private string _remoteDesktopStatus = "";
    private string _systemMonitorStatus = "";
    private string _usbManagementStatus = "";
    private string _settingsStatus = "";
    private int _onlineDeviceCount;
    private int _activeSessionCount;
    private int _transferTaskCount;
    private string _performanceStatus = "";
    private string _topBarConnectionStatus = "";
    private string _topBarDiagnosticsStatus = "";
    private string _topBarNotificationsStatus = "";
    private string _topBarThemeStatus = "";
    private string _selectedBitrate = "";
    private string _selectedFramerate = "";
    private EngineConnectionState _connectionState;
    private FeatureEntry _selectedFeature;
    private ConnectionWorkspaceValidatedState _connectionValidatedState;
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
        IWorkspaceActionCatalogClient? workspaceActionCatalogClient = null,
        IWorkspaceErrorStatusClient? workspaceErrorStatusClient = null,
        ISessionStatusClient? sessionStatusClient = null,
        IFeatureCatalogClient? featureCatalogClient = null,
        ISessionCommandStateClient? sessionCommandStateClient = null,
        IWorkspaceCommandStateClient? workspaceCommandStateClient = null)
        : this(new SessionViewModelDependencies(
            engineClient,
            discoveryClient,
            discoveryBrowserClient,
            deviceDiscoveryInputDefaultsClient,
            manualConnectionClient,
            crossNetworkConnectionClient,
            pairingMaterialClient,
            connectionPreflightClient,
            coreDiagnosticsClient,
            fileTransferClient,
            remoteDesktopClient,
            remoteDesktopProfileCatalogClient,
            systemMonitorClient,
            usbManagementClient,
            settingsClient,
            dashboardMetricsClient,
            topBarStatusClient,
            connectionWorkspaceStateClient,
            workspaceActionCatalogClient,
            workspaceErrorStatusClient,
            sessionStatusClient,
            featureCatalogClient,
            sessionCommandStateClient,
            workspaceCommandStateClient))
    {
    }

    public SessionViewModel(SessionViewModelDependencies dependencies)
    {
        ArgumentNullException.ThrowIfNull(dependencies);

        _engineClient = dependencies.EngineClient;
        _discoveryClient = dependencies.DiscoveryClient;
        _discoveryBrowserClient = dependencies.DiscoveryBrowserClient;
        _discoveryBrowserInputPolicy = _discoveryBrowserClient.BuildInputPolicy();
        _deviceDiscoveryInputDefaultsClient = dependencies.DeviceDiscoveryInputDefaultsClient;
        _manualConnectionClient = dependencies.ManualConnectionClient;
        _crossNetworkConnectionClient = dependencies.CrossNetworkConnectionClient;
        _pairingMaterialClient = dependencies.PairingMaterialClient;
        _connectionPreflightClient = dependencies.ConnectionPreflightClient;
        _coreDiagnosticsClient = dependencies.CoreDiagnosticsClient;
        _fileTransferClient = dependencies.FileTransferClient;
        _remoteDesktopClient = dependencies.RemoteDesktopClient;
        _remoteDesktopProfileCatalogClient = dependencies.RemoteDesktopProfileCatalogClient;
        _systemMonitorClient = dependencies.SystemMonitorClient;
        _usbManagementClient = dependencies.UsbManagementClient;
        _settingsClient = dependencies.SettingsClient;
        _dashboardMetricsClient = dependencies.DashboardMetricsClient;
        _topBarStatusClient = dependencies.TopBarStatusClient;
        _connectionWorkspaceStateClient = dependencies.ConnectionWorkspaceStateClient;
        _workspaceActionCatalogClient = dependencies.WorkspaceActionCatalogClient;
        _workspaceErrorStatusClient = dependencies.WorkspaceErrorStatusClient;
        _sessionStatusClient = dependencies.SessionStatusClient;
        _featureCatalogClient = dependencies.FeatureCatalogClient;
        _sessionCommandStateClient = dependencies.SessionCommandStateClient;
        _workspaceCommandStateClient = dependencies.WorkspaceCommandStateClient;
        _statusMessage = _sessionStatusClient.BuildInitialStatusMessage();
        var initialConnectionStatusPatch = _connectionWorkspaceStateClient.BuildInitialStatusPatch();
        _discoveryStatus = initialConnectionStatusPatch.DiscoveryStatus ?? "";
        _discoveryBrowserStatus = initialConnectionStatusPatch.DiscoveryBrowserStatus ?? "";
        _manualConnectionStatus = initialConnectionStatusPatch.ManualConnectionStatus ?? "";
        _crossNetworkStatus = initialConnectionStatusPatch.CrossNetworkStatus ?? "";
        _pairingStatus = initialConnectionStatusPatch.PairingStatus ?? "";
        _connectionPreflightStatus = initialConnectionStatusPatch.ConnectionPreflightStatus ?? "";
        _isDiscoveryScanning = initialConnectionStatusPatch.IsDiscoveryScanning ?? false;
        _coreDiagnosticsStatus = _coreDiagnosticsClient.BuildInitialStatus();
        _fileTransferStatus = _fileTransferClient.BuildInitialStatus();
        _remoteDesktopStatus = _remoteDesktopClient.BuildInitialStatus();
        _systemMonitorStatus = _systemMonitorClient.BuildInitialStatus();
        _usbManagementStatus = _usbManagementClient.BuildInitialStatus();
        _settingsStatus = _settingsClient.BuildInitialStatus();
        _workspaceStatusPatchApplier = new WorkspaceStatusPatchApplier(
            value => StatusMessage = value,
            value => DiscoveryStatus = value,
            value => DiscoveryBrowserStatus = value,
            value => ManualConnectionStatus = value,
            value => CrossNetworkStatus = value,
            value => PairingStatus = value,
            value => ConnectionPreflightStatus = value,
            value => IsDiscoveryScanning = value,
            value => UsbManagementStatus = value,
            value => CoreDiagnosticsStatus = value,
            value => FileTransferStatus = value,
            value => RemoteDesktopStatus = value,
            value => SystemMonitorStatus = value,
            value => SettingsStatus = value);
        _workspaceCountNotifier = new WorkspaceCountNotifier(OnPropertyChanged);
        _workspaceSnapshotApplier = new WorkspaceSnapshotApplier(_workspaceCountNotifier, RefreshDashboardMetrics);
        _connectionValidatedState = _connectionWorkspaceStateClient.BuildInputInvalidatedState();
        var deviceDiscoveryInputDefaults = _deviceDiscoveryInputDefaultsClient.BuildReadOnlySnapshot();
        _discoveryService = deviceDiscoveryInputDefaults.DiscoveryService;
        _manualConnectionPort = deviceDiscoveryInputDefaults.ManualConnectionPort;
        _discoveryTxtRecord = deviceDiscoveryInputDefaults.DiscoveryTxtRecord;
        _pairingConnectionCode = deviceDiscoveryInputDefaults.PairingConnectionCode;
        _extendedSearchCountdown = _discoveryBrowserInputPolicy.ExtendedSearchSeconds;
        _connectionState = _engineClient.State;
        var featureEntries = _featureCatalogClient.BuildReadOnlySnapshot();
        NavigationItems = new ObservableCollection<FeatureEntry>(featureEntries);
        _selectedFeature = _featureCatalogClient.ResolveDefaultSelection(featureEntries);
        DashboardMetrics = new ObservableCollection<DashboardMetricView>();
        _dashboardMetricsUpdater = new DashboardMetricsUpdater(
            _dashboardMetricsClient,
            DashboardMetrics,
            _workspaceCountNotifier,
            value => OnlineDeviceCount = value,
            value => ActiveSessionCount = value,
            value => TransferTaskCount = value,
            value => PerformanceStatus = value);
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
        _workspaceActionSurfaceTargets = new WorkspaceActionSurfaceTargets(
            SidebarSessionActions,
            TopBarActions,
            SessionControlActions,
            DeviceDiscoveryPrimaryActions,
            DeviceDiscoveryScanActions,
            CrossNetworkQrActions,
            CrossNetworkCodePrimaryActions,
            CrossNetworkCodeConnectActions,
            UsbManagementHeaderActions,
            FileTransferHeaderActions,
            FileTransferActions,
            RemoteDesktopHeaderActions,
            RemoteDesktopActions,
            QuantumDiagnosticsHeaderActions,
            SystemMonitorHeaderActions,
            SystemMonitorActions,
            SettingsHeaderActions,
            SettingsToolbarActions,
            SettingsMaintenanceActions);
        UsbDeviceStats = new ObservableCollection<UsbDeviceStatView>();
        UsbDevices = new ObservableCollection<UsbDeviceItemView>();
        SettingsTabs = new ObservableCollection<SettingsTabItemView>();
        SettingsActions = new ObservableCollection<SettingsActionItemView>();
        SettingsDetails = new ObservableCollection<SettingsDetailItemView>();
        _engineClient.ConnectionStateChanged += OnEngineStateChanged;
        var commandBindings = new WorkspaceCommandBindings(
            ConnectAsync,
            CanConnect,
            DisconnectAsync,
            CanDisconnect,
            SendHeartbeatAsync,
            CanSendHeartbeat,
            StartDiscoveryAsync,
            CanUseDiscoveryBrowser,
            StopDiscoveryAsync,
            RefreshDiscoveryAsync,
            RunExtendedDiscoveryAsync,
            PrepareManualConnectionAsync,
            CanPrepareManualConnection,
            GenerateQRCodeAsync,
            CanUseCrossNetworkConnection,
            ScanQRCodeAsync,
            CanScanQRCode,
            GenerateConnectionCodeAsync,
            RegenerateConnectionCodeAsync,
            CopyConnectionCodeAsync,
            CanCopyConnectionCode,
            ConnectConnectionCodeAsync,
            CanConnectConnectionCode,
            ParseAdvertisementAsync,
            CanParseAdvertisement,
            ValidatePairingCodeAsync,
            CanValidatePairingCode,
            PrepareConnectionAsync,
            CanPrepareConnection,
            RunCoreDiagnosticsAsync,
            CanRunCoreDiagnostics,
            RefreshFileTransferAsync,
            CanRefreshFileTransfer,
            RefreshRemoteDesktopAsync,
            CanRefreshRemoteDesktop,
            RefreshSystemMonitorAsync,
            CanRefreshSystemMonitor,
            RefreshUsbManagementAsync,
            CanRefreshUsbManagement,
            RefreshSettingsAsync,
            CanRefreshSettings);
        ConnectCommand = commandBindings.ConnectCommand;
        DisconnectCommand = commandBindings.DisconnectCommand;
        HeartbeatCommand = commandBindings.HeartbeatCommand;
        StartDiscoveryCommand = commandBindings.StartDiscoveryCommand;
        StopDiscoveryCommand = commandBindings.StopDiscoveryCommand;
        RefreshDiscoveryCommand = commandBindings.RefreshDiscoveryCommand;
        RunExtendedDiscoveryCommand = commandBindings.RunExtendedDiscoveryCommand;
        PrepareManualConnectionCommand = commandBindings.PrepareManualConnectionCommand;
        GenerateQRCodeCommand = commandBindings.GenerateQRCodeCommand;
        ScanQRCodeCommand = commandBindings.ScanQRCodeCommand;
        GenerateConnectionCodeCommand = commandBindings.GenerateConnectionCodeCommand;
        RegenerateConnectionCodeCommand = commandBindings.RegenerateConnectionCodeCommand;
        CopyConnectionCodeCommand = commandBindings.CopyConnectionCodeCommand;
        ConnectConnectionCodeCommand = commandBindings.ConnectConnectionCodeCommand;
        ParseAdvertisementCommand = commandBindings.ParseAdvertisementCommand;
        ValidatePairingCodeCommand = commandBindings.ValidatePairingCodeCommand;
        PrepareConnectionCommand = commandBindings.PrepareConnectionCommand;
        RunCoreDiagnosticsCommand = commandBindings.RunCoreDiagnosticsCommand;
        RefreshFileTransferCommand = commandBindings.RefreshFileTransferCommand;
        RefreshRemoteDesktopCommand = commandBindings.RefreshRemoteDesktopCommand;
        RefreshSystemMonitorCommand = commandBindings.RefreshSystemMonitorCommand;
        RefreshUsbManagementCommand = commandBindings.RefreshUsbManagementCommand;
        RefreshSettingsCommand = commandBindings.RefreshSettingsCommand;
        _workspaceCommandRegistry = commandBindings.Registry;
        _workspaceActionSurfaceLoader = new WorkspaceActionSurfaceLoader(
            _workspaceActionCatalogClient,
            _workspaceActionSurfaceTargets,
            _workspaceCommandRegistry);
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
                RefreshSelectedFeatureState();
            }
        }
    }

    public bool IsDeviceDiscoverySelected =>
        IsFeatureSelected(FeatureEntryId.DeviceDiscovery);

    public bool IsUsbManagementSelected =>
        IsFeatureSelected(FeatureEntryId.UsbManagement);

    public bool IsFileTransferSelected =>
        IsFeatureSelected(FeatureEntryId.FileTransfer);

    public bool IsRemoteDesktopSelected =>
        IsFeatureSelected(FeatureEntryId.RemoteDesktop);

    public bool IsQuantumSelected =>
        IsFeatureSelected(FeatureEntryId.Quantum);

    public bool IsSystemMonitorSelected =>
        IsFeatureSelected(FeatureEntryId.SystemMonitor);

    public bool IsSettingsSelected =>
        IsFeatureSelected(FeatureEntryId.Settings);

    public EngineConnectionState ConnectionState
    {
        get => _connectionState;
        private set
        {
            if (SetField(ref _connectionState, value))
            {
                RefreshConnectionState();
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
                RefreshShellRuntimeState();
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
                ApplyWorkspaceInputChange(InvalidatePairingAndPreflight);
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
                ApplyWorkspaceInputChange();
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
                ApplyWorkspaceInputChange(ResetManualConnectionInput);
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
                ApplyWorkspaceInputChange(ResetManualConnectionInput);
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
                ApplyWorkspaceInputChange(ResetManualConnectionInput);
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
                ApplyWorkspaceInputChange(ResetCrossNetworkInput);
            }
        }
    }

    public string CrossNetworkCodeInput
    {
        get => _crossNetworkCodeInput;
        set
        {
            var normalized = _crossNetworkConnectionClient.NormalizeCodeInput(value);
            if (SetField(ref _crossNetworkCodeInput, normalized))
            {
                ApplyWorkspaceInputChange(ResetCrossNetworkInput);
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
                ApplyWorkspaceInputChange(InvalidatePairingAndPreflight);
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
                ApplyWorkspaceInputChange(ResetPairingInput);
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
                StatusMessage = _remoteDesktopProfileCatalogClient.BuildBitrateSelectionStatus(value);
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
                StatusMessage = _remoteDesktopProfileCatalogClient.BuildFramerateSelectionStatus(value);
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

    private Task ConnectAsync() =>
        RunSessionEngineActionAsync(SessionStatusAction.Connect, _engineClient.ConnectAsync);

    private Task DisconnectAsync() =>
        RunSessionEngineActionAsync(SessionStatusAction.Disconnect, _engineClient.DisconnectAsync);

    private Task SendHeartbeatAsync() =>
        RunSessionEngineActionAsync(SessionStatusAction.Heartbeat, _engineClient.SendHeartbeatAsync);

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
        await RunDeviceDiscoveryActionAsync(async () =>
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

            WorkspaceCollectionProjector.Replace(DiscoveryBrowserFacts, snapshot.Facts, DiscoveryBrowserFactView.FromFact);

            if (action != DiscoveryBrowserAction.Stop)
            {
                ApplyConnectionValidatedState(
                    _connectionWorkspaceStateClient.BuildDiscoveryBrowserValidatedState(snapshot));
                WorkspaceCollectionProjector.Replace(DiscoveredPeers, snapshot.Peers, DiscoveredPeerView.FromCandidate);

                ClearPairingAndPreflight();
                _workspaceCountNotifier.DiscoveredPeersChanged();
            }

            _workspaceCountNotifier.DiscoveryBrowserFactsChanged();
            _workspaceStatusPatchApplier.Apply(
                _connectionWorkspaceStateClient.BuildDiscoveryBrowserResultPatch(
                    action,
                    snapshot,
                    PairingStatus));
        });
    }

    private async Task PrepareManualConnectionAsync()
    {
        await RunDeviceDiscoveryActionAsync(async () =>
        {
            ManualConnectionStatus = _manualConnectionClient.BuildPendingStatus();
            var snapshot = await _manualConnectionClient.BuildReadOnlySnapshotAsync(
                new ManualConnectionRequest(
                    ManualConnectionHost,
                    ManualConnectionPort,
                    ManualConnectionCode));
            WorkspaceCollectionProjector.Replace(ManualConnectionFacts, snapshot.Facts, ManualConnectionFactView.FromFact);

            ApplyConnectionInputInvalidation();
            _workspaceCountNotifier.ManualConnectionFactsChanged();
            DiscoveryService = snapshot.Target.Service;
            _workspaceStatusPatchApplier.Apply(
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
        await RunDeviceDiscoveryActionAsync(async () =>
        {
            CrossNetworkStatus = _crossNetworkConnectionClient.BuildPendingStatus(action);

            var snapshot = await _crossNetworkConnectionClient.BuildReadOnlySnapshotAsync(
                new CrossNetworkConnectionRequest(
                    action,
                    CrossNetworkQrInput,
                    CrossNetworkCodeInput,
                    CrossNetworkGeneratedCode));

            WorkspaceCollectionProjector.Replace(
                CrossNetworkConnectionFacts,
                snapshot.Facts,
                CrossNetworkConnectionFactView.FromFact);

            if (!string.IsNullOrWhiteSpace(snapshot.GeneratedCode))
            {
                CrossNetworkGeneratedCode = snapshot.GeneratedCode;
            }

            ApplyConnectionInputInvalidation();
            _workspaceCountNotifier.CrossNetworkConnectionFactsChanged();
            _workspaceStatusPatchApplier.Apply(
                _connectionWorkspaceStateClient.BuildCrossNetworkPreparedPatch(snapshot));
        });
    }

    private async Task ParseAdvertisementAsync()
    {
        await RunDeviceDiscoveryActionAsync(async () =>
        {
            DiscoveryStatus = _discoveryClient.BuildPendingStatus();
            var peer = await _discoveryClient.ParseAdvertisementAsync(DiscoveryService, DiscoveryTxtRecord);
            ApplyConnectionValidatedState(
                _connectionWorkspaceStateClient.BuildDiscoveryPeerValidatedState(peer));
            DiscoveredPeers.Clear();
            DiscoveredPeers.Add(DiscoveredPeerView.FromCandidate(_discoveryBrowserClient.BuildPeerCandidate(peer)));
            ClearPairingAndPreflight();
            _workspaceCountNotifier.DiscoveredPeersChanged();
            _workspaceStatusPatchApplier.Apply(
                _connectionWorkspaceStateClient.BuildDiscoveryPeerValidatedPatch(peer));
        });
    }

    private async Task ValidatePairingCodeAsync()
    {
        await RunDeviceDiscoveryActionAsync(async () =>
        {
            PairingStatus = _pairingMaterialClient.BuildPendingStatus();
            var expectedFingerprint = DiscoveredPeers.Count == 1
                ? DiscoveredPeers[0].PublicKeyFingerprint
                : null;
            var snapshot = await _pairingMaterialClient.BuildReadOnlySnapshotAsync(
                PairingConnectionCode,
                expectedFingerprint);
            var material = snapshot.Material;
            ApplyConnectionValidatedState(
                _connectionWorkspaceStateClient.BuildPairingValidatedState(
                    _connectionValidatedState,
                    material));
            ClearConnectionPreflight();
            WorkspaceCollectionProjector.Replace(PairingFacts, snapshot.Facts, PairingFactView.FromFact);

            _workspaceCountNotifier.PairingFactsChanged();
            _workspaceStatusPatchApplier.Apply(
                _connectionWorkspaceStateClient.BuildPairingValidatedPatch(material));
        });
    }

    private async Task PrepareConnectionAsync()
    {
        await RunDeviceDiscoveryActionAsync(async () =>
        {
            var discoveredPeer = _connectionValidatedState.DiscoveredPeer;
            var pairingMaterial = _connectionValidatedState.PairingMaterial;
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
            WorkspaceCollectionProjector.Replace(
                ConnectionPreflightFacts,
                snapshot.Facts,
                ConnectionPreflightFactView.FromFact);

            _workspaceCountNotifier.ConnectionPreflightFactsChanged();
            _workspaceStatusPatchApplier.Apply(
                _connectionWorkspaceStateClient.BuildPreflightPreparedPatch(snapshot));
        });
    }

    private Task RunCoreDiagnosticsAsync() =>
        RefreshReadOnlyWorkspaceAsync<CoreDiagnosticsSnapshot>(
            WorkspaceErrorScope.CoreDiagnostics,
            _coreDiagnosticsClient.BuildPendingStatus,
            _coreDiagnosticsClient.BuildInteropSnapshotAsync,
            ApplyCoreDiagnosticsSnapshot,
            _coreDiagnosticsClient.BuildCompletedStatus,
            _coreDiagnosticsClient.BuildCompletedStatusMessage,
            value => CoreDiagnosticsStatus = value);

    private Task RefreshFileTransferAsync() =>
        RefreshReadOnlyWorkspaceAsync<FileTransferWorkspaceSnapshot>(
            WorkspaceErrorScope.FileTransfer,
            _fileTransferClient.BuildPendingStatus,
            _fileTransferClient.BuildReadOnlySnapshotAsync,
            ApplyFileTransferSnapshot,
            _fileTransferClient.BuildCompletedStatus,
            _fileTransferClient.BuildCompletedStatusMessage,
            value => FileTransferStatus = value);

    private Task RefreshUsbManagementAsync() =>
        RefreshReadOnlyWorkspaceAsync<UsbManagementWorkspaceSnapshot>(
            WorkspaceErrorScope.UsbManagement,
            _usbManagementClient.BuildPendingStatus,
            _usbManagementClient.BuildReadOnlySnapshotAsync,
            ApplyUsbManagementSnapshot,
            _usbManagementClient.BuildCompletedStatus,
            _usbManagementClient.BuildCompletedStatusMessage,
            value => UsbManagementStatus = value);

    private Task RefreshRemoteDesktopAsync() =>
        RefreshReadOnlyWorkspaceAsync<RemoteDesktopWorkspaceSnapshot>(
            WorkspaceErrorScope.RemoteDesktop,
            _remoteDesktopClient.BuildPendingStatus,
            () => _remoteDesktopClient.BuildReadOnlySnapshotAsync(SelectedBitrate, SelectedFramerate),
            ApplyRemoteDesktopSnapshot,
            _remoteDesktopClient.BuildCompletedStatus,
            _remoteDesktopClient.BuildCompletedStatusMessage,
            value => RemoteDesktopStatus = value);

    private Task RefreshSystemMonitorAsync() =>
        RefreshReadOnlyWorkspaceAsync<SystemMonitorWorkspaceSnapshot>(
            WorkspaceErrorScope.SystemMonitor,
            _systemMonitorClient.BuildPendingStatus,
            _systemMonitorClient.BuildReadOnlySnapshotAsync,
            ApplySystemMonitorSnapshot,
            _systemMonitorClient.BuildCompletedStatus,
            _systemMonitorClient.BuildCompletedStatusMessage,
            value => SystemMonitorStatus = value);

    private Task RefreshSettingsAsync() =>
        RefreshReadOnlyWorkspaceAsync<SettingsWorkspaceSnapshot>(
            WorkspaceErrorScope.Settings,
            _settingsClient.BuildPendingStatus,
            _settingsClient.BuildReadOnlySnapshotAsync,
            ApplySettingsSnapshot,
            _settingsClient.BuildCompletedStatus,
            _settingsClient.BuildCompletedStatusMessage,
            value => SettingsStatus = value);

    private void ApplyCoreDiagnosticsSnapshot(CoreDiagnosticsSnapshot snapshot)
        => _workspaceSnapshotApplier.ApplyCoreDiagnostics(snapshot, CoreDiagnosticFacts);

    private void ApplyFileTransferSnapshot(FileTransferWorkspaceSnapshot snapshot)
        => _workspaceSnapshotApplier.ApplyFileTransfer(
            snapshot,
            FileTransferQueue,
            FileTransferHistory,
            FileTransferSecurityFacts);

    private void ApplyUsbManagementSnapshot(UsbManagementWorkspaceSnapshot snapshot)
        => _workspaceSnapshotApplier.ApplyUsbManagement(snapshot, UsbDeviceStats, UsbDevices);

    private void ApplyRemoteDesktopSnapshot(RemoteDesktopWorkspaceSnapshot snapshot)
        => _workspaceSnapshotApplier.ApplyRemoteDesktop(
            snapshot,
            RemoteDesktopSessions,
            RemoteDesktopControlFacts);

    private void ApplySystemMonitorSnapshot(SystemMonitorWorkspaceSnapshot snapshot)
        => _workspaceSnapshotApplier.ApplySystemMonitor(
            snapshot,
            SystemMonitorOverview,
            SystemMonitorDetails,
            SystemMonitorIndicators);

    private void ApplySettingsSnapshot(SettingsWorkspaceSnapshot snapshot)
        => _workspaceSnapshotApplier.ApplySettings(
            snapshot,
            SettingsTabs,
            SettingsActions,
            SettingsDetails);

    private bool CanConnect() => _sessionCommandStateClient.CanConnect(ConnectionState, IsBusy);

    private bool CanDisconnect() => _sessionCommandStateClient.CanDisconnect(ConnectionState, IsBusy);

    private bool CanSendHeartbeat() => _sessionCommandStateClient.CanSendHeartbeat(ConnectionState, IsBusy);

    private bool IsFeatureSelected(FeatureEntryId featureId) =>
        _featureCatalogClient.IsSelected(SelectedFeature, featureId);

    private bool CanUseDeviceDiscovery() =>
        _workspaceCommandStateClient.CanUseDeviceDiscovery(IsBusy, IsDeviceDiscoverySelected);

    private bool CanUseDiscoveryBrowser() => CanUseDeviceDiscovery();

    private bool CanPrepareManualConnection() =>
        CanUseDeviceDiscoveryAction(
            _manualConnectionClient.CanPrepareTarget(ManualConnectionHost, ManualConnectionPort));

    private bool CanUseCrossNetworkConnection() =>
        _workspaceCommandStateClient.CanUseCrossNetworkConnection(IsBusy, IsDeviceDiscoverySelected);

    private bool CanScanQRCode() =>
        CanUseCrossNetworkConnectionAction(_crossNetworkConnectionClient.CanScanQrCode(CrossNetworkQrInput));

    private bool CanCopyConnectionCode() =>
        CanUseCrossNetworkConnectionAction(_crossNetworkConnectionClient.CanCopyCode(CrossNetworkGeneratedCode));

    private bool CanConnectConnectionCode() =>
        CanUseCrossNetworkConnectionAction(_crossNetworkConnectionClient.CanConnectWithCode(CrossNetworkCodeInput));

    private bool CanParseAdvertisement() =>
        CanUseDeviceDiscoveryAction(
            _discoveryClient.CanParseAdvertisement(DiscoveryService, DiscoveryTxtRecord));

    private bool CanValidatePairingCode() =>
        CanUseDeviceDiscoveryAction(_pairingMaterialClient.CanValidate(PairingConnectionCode));

    private bool CanPrepareConnection() =>
        CanUseDeviceDiscoveryAction(
            _connectionWorkspaceStateClient.CanPreparePreflight(
                _connectionValidatedState.DiscoveredPeer,
                _connectionValidatedState.PairingMaterial));

    private bool CanRefreshUsbManagement() =>
        CanUseSelectedWorkspaceFeature(IsUsbManagementSelected);

    private bool CanRunCoreDiagnostics() =>
        CanUseSelectedWorkspaceFeature(IsQuantumSelected);

    private bool CanRefreshFileTransfer() =>
        CanUseSelectedWorkspaceFeature(IsFileTransferSelected);

    private bool CanRefreshRemoteDesktop() =>
        CanUseSelectedWorkspaceFeature(IsRemoteDesktopSelected);

    private bool CanRefreshSystemMonitor() =>
        CanUseSelectedWorkspaceFeature(IsSystemMonitorSelected);

    private bool CanRefreshSettings() =>
        CanUseSelectedWorkspaceFeature(IsSettingsSelected);

    private bool CanUseDeviceDiscoveryAction(bool readiness) =>
        _workspaceCommandStateClient.CanUseDeviceDiscoveryAction(
            IsBusy,
            IsDeviceDiscoverySelected,
            readiness);

    private bool CanUseCrossNetworkConnectionAction(bool readiness) =>
        _workspaceCommandStateClient.CanUseCrossNetworkConnectionAction(
            IsBusy,
            IsDeviceDiscoverySelected,
            readiness);

    private bool CanUseSelectedWorkspaceFeature(bool isSelected) =>
        _workspaceCommandStateClient.CanUseWorkspaceFeature(IsBusy, isSelected);

    private async Task RunWithBusyState(
        WorkspaceErrorScope errorScope,
        Func<Task> action)
    {
        try
        {
            IsBusy = true;
            await action();
        }
        catch (Exception ex)
        {
            _workspaceStatusPatchApplier.Apply(
                _workspaceErrorStatusClient.BuildErrorPatch(errorScope, ex.Message));
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task RunSessionEngineActionAsync(
        SessionStatusAction action,
        Func<Task> engineAction)
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(WorkspaceErrorScope.Session, async () =>
        {
            StatusMessage = _sessionStatusClient.BuildPendingStatus(action);
            await engineAction();
            StatusMessage = _sessionStatusClient.BuildCompletedStatus(action);
        });
    }

    private async Task RunDeviceDiscoveryActionAsync(Func<Task> action)
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(WorkspaceErrorScope.DeviceDiscovery, action);
    }

    private async Task RefreshReadOnlyWorkspaceAsync<TSnapshot>(
        WorkspaceErrorScope errorScope,
        Func<string> buildPendingStatus,
        Func<Task<TSnapshot>> buildSnapshotAsync,
        Action<TSnapshot> applySnapshot,
        Func<TSnapshot, string> buildCompletedStatus,
        Func<string> buildCompletedStatusMessage,
        Action<string> setWorkspaceStatus)
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(errorScope, async () =>
        {
            setWorkspaceStatus(buildPendingStatus());
            var snapshot = await buildSnapshotAsync();
            applySnapshot(snapshot);
            setWorkspaceStatus(buildCompletedStatus(snapshot));
            StatusMessage = buildCompletedStatusMessage();
        });
    }

    private void RefreshCommandStates()
    {
        foreach (var command in _workspaceCommandRegistry.RefreshableCommands)
        {
            (command as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        }

        RefreshDynamicWorkspaceActionStates();
    }

    private void ApplyWorkspaceInputChange(Action? resetInput = null)
    {
        resetInput?.Invoke();
        RefreshCommandStates();
    }

    private void RefreshSelectedFeatureState()
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

    private void RefreshConnectionState()
    {
        OnPropertyChanged(nameof(ConnectionStatus));
        RefreshShellRuntimeState();
    }

    private void RefreshShellRuntimeState()
    {
        RefreshDashboardMetrics();
        RefreshTopBarStatus();
        RefreshCommandStates();
    }

    private void RefreshDynamicWorkspaceActionStates()
    {
        _workspaceActionSurfaceLoader.RefreshDynamicSurfaces(BuildWorkspaceActionRenderContext());
    }

    private void RefreshDashboardMetrics()
    {
        _dashboardMetricsUpdater.Refresh(
            new DashboardMetricsRequest(
                ConnectionState,
                FileTransferQueue.Count,
                IsBusy));
    }

    private void LoadWorkspaceActions()
    {
        _workspaceActionSurfaceLoader.LoadInitialSurfaces(BuildWorkspaceActionRenderContext());
    }

    private WorkspaceActionGateSnapshot BuildWorkspaceActionGateSnapshot() =>
        _workspaceCommandStateClient.BuildActionGateSnapshot(
            new WorkspaceCommandGateRequest(
                IsBusy,
                IsUsbManagementSelected,
                IsFileTransferSelected,
                IsRemoteDesktopSelected,
                IsQuantumSelected,
                IsSystemMonitorSelected,
                IsSettingsSelected,
                _sessionCommandStateClient.BuildGateSnapshot(ConnectionState, IsBusy)));

    private WorkspaceActionRenderContext BuildWorkspaceActionRenderContext(
        WorkspaceActionDetailSnapshot? actionDetails = null) =>
        new(
            BuildWorkspaceActionGateSnapshot(),
            actionDetails ?? _topBarStatusClient.BuildStatusUpdate(BuildTopBarStatusRequest()).ActionDetails);

    private void RefreshTopBarStatus()
    {
        var update = _topBarStatusClient.BuildStatusUpdate(BuildTopBarStatusRequest());

        TopBarConnectionStatus = update.ResolvedStatus.ConnectionStatus;
        TopBarDiagnosticsStatus = update.ResolvedStatus.DiagnosticsStatus;
        TopBarNotificationsStatus = update.ResolvedStatus.NotificationsStatus;
        TopBarThemeStatus = update.ResolvedStatus.ThemeStatus;
        _workspaceActionSurfaceLoader.LoadSurface(
            WorkspaceActionSurface.TopBarActions,
            BuildWorkspaceActionRenderContext(update.ActionDetails));
    }

    private TopBarStatusRequest BuildTopBarStatusRequest() =>
        new(
            ConnectionStatus,
            PerformanceStatus,
            SelectedFeature.Title);

    private void OnEngineStateChanged(object? sender, EngineConnectionState newState)
    {
        ConnectionState = newState;
        StatusMessage = _sessionStatusClient.BuildEngineStateStatus(newState);
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

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }

    private void ApplyConnectionValidatedState(ConnectionWorkspaceValidatedState state)
    {
        _connectionValidatedState = state;
    }

    private void ApplyConnectionInputInvalidation()
    {
        ApplyConnectionValidatedState(_connectionWorkspaceStateClient.BuildInputInvalidatedState());
        ClearPairingAndPreflight();
    }

    private void ClearPairingAndPreflight()
    {
        PairingFacts.Clear();
        ClearConnectionPreflight();
        _workspaceCountNotifier.PairingFactsChanged();
    }

    private void InvalidatePairingAndPreflight()
    {
        ApplyConnectionValidatedState(_connectionWorkspaceStateClient.BuildInputInvalidatedState());
        DiscoveredPeers.Clear();
        DiscoveryBrowserFacts.Clear();
        ClearPairingAndPreflight();
        _workspaceStatusPatchApplier.Apply(
            _connectionWorkspaceStateClient.BuildInputResetPatch(
                ConnectionWorkspaceResetReason.DiscoveryInputChanged));
        _workspaceCountNotifier.DiscoveredPeersChanged();
        _workspaceCountNotifier.DiscoveryBrowserFactsChanged();
    }

    private void ResetManualConnectionInput()
    {
        ManualConnectionFacts.Clear();
        _workspaceStatusPatchApplier.Apply(
            _connectionWorkspaceStateClient.BuildInputResetPatch(
                ConnectionWorkspaceResetReason.ManualTargetInputChanged));
        _workspaceCountNotifier.ManualConnectionFactsChanged();
    }

    private void ResetCrossNetworkInput()
    {
        _workspaceStatusPatchApplier.Apply(
            _connectionWorkspaceStateClient.BuildInputResetPatch(
                ConnectionWorkspaceResetReason.CrossNetworkInputChanged));
    }

    private void ResetPairingInput()
    {
        ApplyConnectionValidatedState(
            _connectionWorkspaceStateClient.BuildPairingInputResetState(_connectionValidatedState));
        ClearPairingAndPreflight();
        _workspaceStatusPatchApplier.Apply(
            _connectionWorkspaceStateClient.BuildInputResetPatch(
                ConnectionWorkspaceResetReason.PairingInputChanged));
    }

    private void ClearConnectionPreflight()
    {
        ConnectionPreflightFacts.Clear();
        _workspaceStatusPatchApplier.Apply(
            _connectionWorkspaceStateClient.BuildInputResetPatch(
                ConnectionWorkspaceResetReason.PreflightCleared));
        _workspaceCountNotifier.ConnectionPreflightFactsChanged();
    }
}

internal sealed record WorkspaceActionRenderContext(
    WorkspaceActionGateSnapshot Gates,
    WorkspaceActionDetailSnapshot Details);
