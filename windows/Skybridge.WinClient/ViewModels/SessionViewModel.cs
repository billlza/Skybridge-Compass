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
    private readonly IConnectionWorkspaceStateClient _connectionWorkspaceStateClient;
    private readonly IWorkspaceActionCatalogClient _workspaceActionCatalogClient;
    private readonly ISessionStatusClient _sessionStatusClient;
    private readonly IFeatureCatalogClient _featureCatalogClient;
    private readonly ISessionCommandStateClient _sessionCommandStateClient;
    private readonly IWorkspaceCommandStateClient _workspaceCommandStateClient;
    private readonly SessionEngineActions _sessionEngineActions;
    private readonly SessionEngineStateProjector _sessionEngineStateProjector;
    private readonly WorkspaceCommandGateCoordinator _workspaceCommandGateCoordinator;
    private readonly WorkspaceCommandAvailability _workspaceCommandAvailability;
    private readonly WorkspaceCommandRegistry _workspaceCommandRegistry;
    private readonly WorkspaceActionSurfaceTargets _workspaceActionSurfaceTargets;
    private readonly WorkspaceActionSurfaceLoader _workspaceActionSurfaceLoader;
    private readonly WorkspaceStatusPatchApplier _workspaceStatusPatchApplier;
    private readonly WorkspaceBusyCoordinator _workspaceBusyCoordinator;
    private readonly ReadOnlyWorkspaceRefreshActions _readOnlyWorkspaceRefreshActions;
    private readonly WorkspaceCountNotifier _workspaceCountNotifier;
    private readonly WorkspaceSnapshotApplier _workspaceSnapshotApplier;
    private readonly ReadOnlyWorkspaceSnapshotHandlers _readOnlyWorkspaceSnapshotHandlers;
    private readonly DashboardMetricsUpdater _dashboardMetricsUpdater;
    private readonly TopBarStatusUpdater _topBarStatusUpdater;
    private readonly WorkspaceActionRenderContextBuilder _workspaceActionRenderContextBuilder;
    private readonly WorkspaceShellRefreshCoordinator _workspaceShellRefreshCoordinator;
    private readonly WorkspaceViewStateBuilder _workspaceViewStateBuilder;
    private readonly RemoteDesktopProfileSelectionCoordinator _remoteDesktopProfileSelectionCoordinator;
    private readonly CrossNetworkCodeInputCoordinator _crossNetworkCodeInputCoordinator;
    private readonly ConnectionWorkspaceInputCoordinator _connectionInputCoordinator;
    private readonly ConnectionWorkspaceResultProjector _connectionResultProjector;
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
        _connectionWorkspaceStateClient = dependencies.ConnectionWorkspaceStateClient;
        _workspaceActionCatalogClient = dependencies.WorkspaceActionCatalogClient;
        _sessionStatusClient = dependencies.SessionStatusClient;
        _featureCatalogClient = dependencies.FeatureCatalogClient;
        _sessionCommandStateClient = dependencies.SessionCommandStateClient;
        _workspaceCommandStateClient = dependencies.WorkspaceCommandStateClient;
        _workspaceCommandGateCoordinator = new WorkspaceCommandGateCoordinator(
            _sessionCommandStateClient,
            _featureCatalogClient,
            _workspaceCommandStateClient,
            _manualConnectionClient,
            _crossNetworkConnectionClient,
            _discoveryClient,
            _pairingMaterialClient,
            _connectionWorkspaceStateClient);
        _workspaceViewStateBuilder = new WorkspaceViewStateBuilder();
        _workspaceCommandAvailability = new WorkspaceCommandAvailability(
            _workspaceCommandGateCoordinator,
            BuildWorkspaceCommandGateState);
        _remoteDesktopProfileSelectionCoordinator = new RemoteDesktopProfileSelectionCoordinator(
            _remoteDesktopProfileCatalogClient,
            value => StatusMessage = value);
        _crossNetworkCodeInputCoordinator = new CrossNetworkCodeInputCoordinator(
            _crossNetworkConnectionClient);
        var workspaceStartupStateBuilder = new WorkspaceStartupStateBuilder(
            _engineClient,
            _discoveryBrowserClient,
            _deviceDiscoveryInputDefaultsClient,
            _connectionWorkspaceStateClient,
            _sessionStatusClient,
            _featureCatalogClient,
            _coreDiagnosticsClient,
            _fileTransferClient,
            _remoteDesktopClient,
            _remoteDesktopProfileCatalogClient,
            _systemMonitorClient,
            _usbManagementClient,
            _settingsClient);
        var startupState = workspaceStartupStateBuilder.Build();
        _discoveryBrowserInputPolicy = startupState.DiscoveryBrowserInputPolicy;
        _statusMessage = startupState.StatusMessage;
        _discoveryStatus = startupState.DiscoveryStatus;
        _discoveryBrowserStatus = startupState.DiscoveryBrowserStatus;
        _manualConnectionStatus = startupState.ManualConnectionStatus;
        _crossNetworkStatus = startupState.CrossNetworkStatus;
        _pairingStatus = startupState.PairingStatus;
        _connectionPreflightStatus = startupState.ConnectionPreflightStatus;
        _isDiscoveryScanning = startupState.IsDiscoveryScanning;
        _coreDiagnosticsStatus = startupState.CoreDiagnosticsStatus;
        _fileTransferStatus = startupState.FileTransferStatus;
        _remoteDesktopStatus = startupState.RemoteDesktopStatus;
        _systemMonitorStatus = startupState.SystemMonitorStatus;
        _usbManagementStatus = startupState.UsbManagementStatus;
        _settingsStatus = startupState.SettingsStatus;
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
        _workspaceBusyCoordinator = new WorkspaceBusyCoordinator(
            () => IsBusy,
            value => IsBusy = value,
            _workspaceStatusPatchApplier,
            dependencies.WorkspaceErrorStatusClient);
        _sessionEngineActions = new SessionEngineActions(
            _engineClient,
            _workspaceBusyCoordinator,
            _sessionStatusClient,
            value => StatusMessage = value);
        _sessionEngineStateProjector = new SessionEngineStateProjector(
            _sessionStatusClient,
            value => ConnectionState = value,
            value => StatusMessage = value);
        var readOnlyWorkspaceRefreshCoordinator = new ReadOnlyWorkspaceRefreshCoordinator(
            _workspaceBusyCoordinator,
            _coreDiagnosticsClient,
            _fileTransferClient,
            _usbManagementClient,
            _remoteDesktopClient,
            _systemMonitorClient,
            _settingsClient);
        _workspaceCountNotifier = new WorkspaceCountNotifier(OnPropertyChanged);
        _workspaceSnapshotApplier = new WorkspaceSnapshotApplier(_workspaceCountNotifier, RefreshDashboardMetrics);
        _discoveryService = startupState.DiscoveryService;
        _manualConnectionPort = startupState.ManualConnectionPort;
        _discoveryTxtRecord = startupState.DiscoveryTxtRecord;
        _pairingConnectionCode = startupState.PairingConnectionCode;
        _extendedSearchCountdown = startupState.ExtendedSearchCountdown;
        _connectionState = startupState.ConnectionState;
        var collections = new WorkspaceObservableCollections(
            startupState.FeatureEntries,
            startupState.RemoteDesktopProfileCatalog);
        NavigationItems = collections.NavigationItems;
        _selectedFeature = startupState.SelectedFeature;
        DashboardMetrics = collections.DashboardMetrics;
        BitrateProfiles = collections.BitrateProfiles;
        FramerateProfiles = collections.FramerateProfiles;
        _readOnlyWorkspaceSnapshotHandlers = new ReadOnlyWorkspaceSnapshotHandlers(
            _workspaceSnapshotApplier,
            collections);
        _readOnlyWorkspaceRefreshActions = new ReadOnlyWorkspaceRefreshActions(
            readOnlyWorkspaceRefreshCoordinator,
            _readOnlyWorkspaceSnapshotHandlers,
            () => SelectedBitrate,
            () => SelectedFramerate,
            value => StatusMessage = value,
            value => CoreDiagnosticsStatus = value,
            value => FileTransferStatus = value,
            value => UsbManagementStatus = value,
            value => RemoteDesktopStatus = value,
            value => SystemMonitorStatus = value,
            value => SettingsStatus = value);
        _dashboardMetricsUpdater = new DashboardMetricsUpdater(
            _dashboardMetricsClient,
            DashboardMetrics,
            _workspaceCountNotifier,
            value => OnlineDeviceCount = value,
            value => ActiveSessionCount = value,
            value => TransferTaskCount = value,
            value => PerformanceStatus = value);
        SidebarSessionActions = collections.SidebarSessionActions;
        TopBarActions = collections.TopBarActions;
        SessionControlActions = collections.SessionControlActions;
        DiscoveredPeers = collections.DiscoveredPeers;
        DiscoveryBrowserFacts = collections.DiscoveryBrowserFacts;
        ManualConnectionFacts = collections.ManualConnectionFacts;
        CrossNetworkConnectionFacts = collections.CrossNetworkConnectionFacts;
        PairingFacts = collections.PairingFacts;
        ConnectionPreflightFacts = collections.ConnectionPreflightFacts;
        _connectionInputCoordinator = new ConnectionWorkspaceInputCoordinator(
            _connectionWorkspaceStateClient,
            _workspaceStatusPatchApplier,
            _workspaceCountNotifier,
            DiscoveredPeers,
            DiscoveryBrowserFacts,
            ManualConnectionFacts,
            PairingFacts,
            ConnectionPreflightFacts);
        _connectionResultProjector = new ConnectionWorkspaceResultProjector(
            _connectionWorkspaceStateClient,
            _connectionInputCoordinator,
            _workspaceStatusPatchApplier,
            _workspaceCountNotifier,
            DiscoveredPeers,
            DiscoveryBrowserFacts,
            ManualConnectionFacts,
            CrossNetworkConnectionFacts,
            PairingFacts,
            ConnectionPreflightFacts);
        CoreDiagnosticFacts = collections.CoreDiagnosticFacts;
        DeviceDiscoveryPrimaryActions = collections.DeviceDiscoveryPrimaryActions;
        DeviceDiscoveryScanActions = collections.DeviceDiscoveryScanActions;
        CrossNetworkQrActions = collections.CrossNetworkQrActions;
        CrossNetworkCodePrimaryActions = collections.CrossNetworkCodePrimaryActions;
        CrossNetworkCodeConnectActions = collections.CrossNetworkCodeConnectActions;
        UsbManagementHeaderActions = collections.UsbManagementHeaderActions;
        FileTransferHeaderActions = collections.FileTransferHeaderActions;
        FileTransferActions = collections.FileTransferActions;
        RemoteDesktopHeaderActions = collections.RemoteDesktopHeaderActions;
        RemoteDesktopActions = collections.RemoteDesktopActions;
        QuantumDiagnosticsHeaderActions = collections.QuantumDiagnosticsHeaderActions;
        SettingsHeaderActions = collections.SettingsHeaderActions;
        SettingsToolbarActions = collections.SettingsToolbarActions;
        SettingsMaintenanceActions = collections.SettingsMaintenanceActions;
        FileTransferQueue = collections.FileTransferQueue;
        FileTransferHistory = collections.FileTransferHistory;
        FileTransferSecurityFacts = collections.FileTransferSecurityFacts;
        RemoteDesktopSessions = collections.RemoteDesktopSessions;
        RemoteDesktopControlFacts = collections.RemoteDesktopControlFacts;
        SystemMonitorHeaderActions = collections.SystemMonitorHeaderActions;
        SystemMonitorActions = collections.SystemMonitorActions;
        SystemMonitorOverview = collections.SystemMonitorOverview;
        SystemMonitorDetails = collections.SystemMonitorDetails;
        SystemMonitorIndicators = collections.SystemMonitorIndicators;
        _workspaceActionSurfaceTargets = new WorkspaceActionSurfaceTargets(collections);
        UsbDeviceStats = collections.UsbDeviceStats;
        UsbDevices = collections.UsbDevices;
        SettingsTabs = collections.SettingsTabs;
        SettingsActions = collections.SettingsActions;
        SettingsDetails = collections.SettingsDetails;
        _selectedBitrate = startupState.RemoteDesktopProfileCatalog.DefaultBitrateProfile;
        _selectedFramerate = startupState.RemoteDesktopProfileCatalog.DefaultFramerateProfile;
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
        _topBarStatusUpdater = new TopBarStatusUpdater(
            dependencies.TopBarStatusClient,
            _workspaceActionSurfaceLoader,
            value => TopBarConnectionStatus = value,
            value => TopBarDiagnosticsStatus = value,
            value => TopBarNotificationsStatus = value,
            value => TopBarThemeStatus = value);
        _workspaceActionRenderContextBuilder = new WorkspaceActionRenderContextBuilder(
            _workspaceCommandStateClient,
            _sessionCommandStateClient,
            _topBarStatusUpdater);
        _workspaceShellRefreshCoordinator = new WorkspaceShellRefreshCoordinator(
            _workspaceCommandRegistry,
            _workspaceActionSurfaceLoader,
            _workspaceActionRenderContextBuilder,
            _dashboardMetricsUpdater,
            _topBarStatusUpdater,
            BuildDashboardMetricsRequest,
            BuildWorkspaceActionRenderState,
            OnPropertyChanged,
            WorkspaceShellNotificationCatalog.SelectedFeaturePropertyNames,
            WorkspaceShellNotificationCatalog.ConnectionStatusPropertyName);
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
                ApplyWorkspaceInputChange(_connectionInputCoordinator.InvalidatePairingAndPreflight);
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
                ApplyWorkspaceInputChange(_connectionInputCoordinator.ResetManualConnectionInput);
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
                ApplyWorkspaceInputChange(_connectionInputCoordinator.ResetManualConnectionInput);
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
                ApplyWorkspaceInputChange(_connectionInputCoordinator.ResetManualConnectionInput);
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
                ApplyWorkspaceInputChange(_connectionInputCoordinator.ResetCrossNetworkInput);
            }
        }
    }

    public string CrossNetworkCodeInput
    {
        get => _crossNetworkCodeInput;
        set
        {
            var update = _crossNetworkCodeInputCoordinator.BuildInputUpdate(
                _crossNetworkCodeInput,
                value);
            if (update.ShouldUpdateValue && SetField(ref _crossNetworkCodeInput, update.NormalizedValue))
            {
                ApplyWorkspaceInputChange(_connectionInputCoordinator.ResetCrossNetworkInput);
            }
            else if (update.ShouldNotifyNormalizedValue)
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
                ApplyWorkspaceInputChange(_connectionInputCoordinator.InvalidatePairingAndPreflight);
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
                ApplyWorkspaceInputChange(_connectionInputCoordinator.ResetPairingInput);
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
                _remoteDesktopProfileSelectionCoordinator.ApplyBitrateSelection(value);
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
                _remoteDesktopProfileSelectionCoordinator.ApplyFramerateSelection(value);
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
        _sessionEngineActions.ConnectAsync();

    private Task DisconnectAsync() =>
        _sessionEngineActions.DisconnectAsync();

    private Task SendHeartbeatAsync() =>
        _sessionEngineActions.SendHeartbeatAsync();

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
                _workspaceViewStateBuilder.BuildDiscoveryBrowserRequest(
                    action,
                    DiscoveryService,
                    DiscoveryTxtRecord,
                    DiscoverySearchText,
                    IsDiscoveryCompatibilityModeEnabled,
                    ExtendedSearchCountdown));

            _connectionResultProjector.ApplyDiscoveryBrowserResult(
                action,
                snapshot,
                PairingStatus);
        });
    }

    private async Task PrepareManualConnectionAsync()
    {
        await RunDeviceDiscoveryActionAsync(async () =>
        {
            ManualConnectionStatus = _manualConnectionClient.BuildPendingStatus();
            var snapshot = await _manualConnectionClient.BuildReadOnlySnapshotAsync(
                _workspaceViewStateBuilder.BuildManualConnectionRequest(
                    ManualConnectionHost,
                    ManualConnectionPort,
                    ManualConnectionCode));
            _connectionResultProjector.ApplyManualTargetPrepared(
                snapshot,
                value => DiscoveryService = value);
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
                _workspaceViewStateBuilder.BuildCrossNetworkConnectionRequest(
                    action,
                    CrossNetworkQrInput,
                    CrossNetworkCodeInput,
                    CrossNetworkGeneratedCode));

            _connectionResultProjector.ApplyCrossNetworkPrepared(
                snapshot,
                value => CrossNetworkGeneratedCode = value);
        });
    }

    private async Task ParseAdvertisementAsync()
    {
        await RunDeviceDiscoveryActionAsync(async () =>
        {
            DiscoveryStatus = _discoveryClient.BuildPendingStatus();
            var peer = await _discoveryClient.ParseAdvertisementAsync(DiscoveryService, DiscoveryTxtRecord);
            _connectionResultProjector.ApplyDiscoveryPeerValidated(
                peer,
                _discoveryBrowserClient.BuildPeerCandidate(peer));
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
            _connectionResultProjector.ApplyPairingValidated(snapshot);
        });
    }

    private async Task PrepareConnectionAsync()
    {
        await RunDeviceDiscoveryActionAsync(async () =>
        {
            var discoveredPeer = _connectionInputCoordinator.ValidatedState.DiscoveredPeer;
            var pairingMaterial = _connectionInputCoordinator.ValidatedState.PairingMaterial;
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
            _connectionResultProjector.ApplyPreflightPrepared(snapshot);
        });
    }

    private Task RunCoreDiagnosticsAsync() =>
        _readOnlyWorkspaceRefreshActions.RunCoreDiagnosticsAsync();

    private Task RefreshFileTransferAsync() =>
        _readOnlyWorkspaceRefreshActions.RefreshFileTransferAsync();

    private Task RefreshUsbManagementAsync() =>
        _readOnlyWorkspaceRefreshActions.RefreshUsbManagementAsync();

    private Task RefreshRemoteDesktopAsync() =>
        _readOnlyWorkspaceRefreshActions.RefreshRemoteDesktopAsync();

    private Task RefreshSystemMonitorAsync() =>
        _readOnlyWorkspaceRefreshActions.RefreshSystemMonitorAsync();

    private Task RefreshSettingsAsync() =>
        _readOnlyWorkspaceRefreshActions.RefreshSettingsAsync();

    private bool CanConnect() =>
        _workspaceCommandAvailability.CanConnect();

    private bool CanDisconnect() =>
        _workspaceCommandAvailability.CanDisconnect();

    private bool CanSendHeartbeat() =>
        _workspaceCommandAvailability.CanSendHeartbeat();

    private bool IsFeatureSelected(FeatureEntryId featureId) =>
        _workspaceCommandGateCoordinator.IsFeatureSelected(SelectedFeature, featureId);

    private bool CanUseDeviceDiscovery() =>
        _workspaceCommandAvailability.CanUseDiscoveryBrowser();

    private bool CanUseDiscoveryBrowser() => CanUseDeviceDiscovery();

    private bool CanPrepareManualConnection() =>
        _workspaceCommandAvailability.CanPrepareManualConnection();

    private bool CanUseCrossNetworkConnection() =>
        _workspaceCommandAvailability.CanUseCrossNetworkConnection();

    private bool CanScanQRCode() =>
        _workspaceCommandAvailability.CanScanQrCode();

    private bool CanCopyConnectionCode() =>
        _workspaceCommandAvailability.CanCopyConnectionCode();

    private bool CanConnectConnectionCode() =>
        _workspaceCommandAvailability.CanConnectConnectionCode();

    private bool CanParseAdvertisement() =>
        _workspaceCommandAvailability.CanParseAdvertisement();

    private bool CanValidatePairingCode() =>
        _workspaceCommandAvailability.CanValidatePairingCode();

    private bool CanPrepareConnection() =>
        _workspaceCommandAvailability.CanPrepareConnection();

    private bool CanRefreshUsbManagement() =>
        _workspaceCommandAvailability.CanRefreshUsbManagement();

    private bool CanRunCoreDiagnostics() =>
        _workspaceCommandAvailability.CanRunCoreDiagnostics();

    private bool CanRefreshFileTransfer() =>
        _workspaceCommandAvailability.CanRefreshFileTransfer();

    private bool CanRefreshRemoteDesktop() =>
        _workspaceCommandAvailability.CanRefreshRemoteDesktop();

    private bool CanRefreshSystemMonitor() =>
        _workspaceCommandAvailability.CanRefreshSystemMonitor();

    private bool CanRefreshSettings() =>
        _workspaceCommandAvailability.CanRefreshSettings();

    private Task RunDeviceDiscoveryActionAsync(Func<Task> action) =>
        _workspaceBusyCoordinator.RunAsync(WorkspaceErrorScope.DeviceDiscovery, action);

    private void RefreshCommandStates() =>
        _workspaceShellRefreshCoordinator.RefreshCommandStates();

    private void ApplyWorkspaceInputChange(Action? resetInput = null) =>
        _workspaceShellRefreshCoordinator.ApplyWorkspaceInputChange(resetInput);

    private void RefreshSelectedFeatureState() =>
        _workspaceShellRefreshCoordinator.RefreshSelectedFeatureState();

    private void RefreshConnectionState() =>
        _workspaceShellRefreshCoordinator.RefreshConnectionState();

    private void RefreshShellRuntimeState() =>
        _workspaceShellRefreshCoordinator.RefreshShellRuntimeState();

    private void RefreshDashboardMetrics() =>
        _workspaceShellRefreshCoordinator.RefreshDashboardMetrics();

    private void LoadWorkspaceActions() =>
        _workspaceShellRefreshCoordinator.LoadWorkspaceActions();

    private void RefreshTopBarStatus() =>
        _workspaceShellRefreshCoordinator.RefreshTopBarStatus();

    private DashboardMetricsRequest BuildDashboardMetricsRequest() =>
        _workspaceViewStateBuilder.BuildDashboardMetricsRequest(
            ConnectionState,
            FileTransferQueue.Count,
            IsBusy);

    private WorkspaceCommandGateState BuildWorkspaceCommandGateState() =>
        _workspaceViewStateBuilder.BuildCommandGateState(
            IsBusy,
            ConnectionState,
            SelectedFeature,
            ManualConnectionHost,
            ManualConnectionPort,
            CrossNetworkQrInput,
            CrossNetworkCodeInput,
            CrossNetworkGeneratedCode,
            DiscoveryService,
            DiscoveryTxtRecord,
            PairingConnectionCode,
            _connectionInputCoordinator.ValidatedState);

    private WorkspaceActionRenderState BuildWorkspaceActionRenderState() =>
        _workspaceViewStateBuilder.BuildActionRenderState(
            IsBusy,
            IsUsbManagementSelected,
            IsFileTransferSelected,
            IsRemoteDesktopSelected,
            IsQuantumSelected,
            IsSystemMonitorSelected,
            IsSettingsSelected,
            ConnectionState,
            ConnectionStatus,
            PerformanceStatus,
            SelectedFeature.Title);

    private void OnEngineStateChanged(object? sender, EngineConnectionState newState)
    {
        _sessionEngineStateProjector.Apply(newState);
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

}
