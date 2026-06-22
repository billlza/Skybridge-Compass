using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Windows.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Skybridge.WinClient.Services;
using Windows.Storage.Streams;

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
    private readonly IWeatherClient _weatherClient;
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
    private readonly WorkspaceShellStateAccessor _workspaceShellStateAccessor;
    private readonly WorkspaceCommandRegistry _workspaceCommandRegistry;
    private readonly WorkspaceActionSurfaceTargets _workspaceActionSurfaceTargets;
    private readonly WorkspaceActionSurfaceLoader _workspaceActionSurfaceLoader;
    private readonly WorkspaceStatusPatchApplier _workspaceStatusPatchApplier;
    private readonly WorkspaceBusyCoordinator _workspaceBusyCoordinator;
    private readonly ReadOnlyWorkspaceRefreshActions _readOnlyWorkspaceRefreshActions;
    private readonly FileTransferWorkspaceActions _fileTransferWorkspaceActions;
    private readonly RemoteDesktopWorkspaceActions _remoteDesktopWorkspaceActions;
    private readonly SystemMonitorWorkspaceActions _systemMonitorWorkspaceActions;
    private readonly SettingsWorkspaceActions _settingsWorkspaceActions;
    private readonly TopBarWorkspaceActions _topBarWorkspaceActions;
    private readonly WorkspaceCountNotifier _workspaceCountNotifier;
    private readonly WorkspaceSnapshotApplier _workspaceSnapshotApplier;
    private readonly ReadOnlyWorkspaceSnapshotHandlers _readOnlyWorkspaceSnapshotHandlers;
    private readonly DashboardMetricsUpdater _dashboardMetricsUpdater;
    private readonly WeatherStateCoordinator _weatherStateCoordinator;
    private readonly TopBarStatusUpdater _topBarStatusUpdater;
    private readonly WorkspaceActionRenderContextBuilder _workspaceActionRenderContextBuilder;
    private readonly WorkspaceShellRefreshCoordinator _workspaceShellRefreshCoordinator;
    private readonly WorkspaceInputChangeRouter _workspaceInputChangeRouter;
    private readonly WorkspaceViewStateBuilder _workspaceViewStateBuilder;
    private readonly RemoteDesktopProfileSelectionCoordinator _remoteDesktopProfileSelectionCoordinator;
    private readonly CrossNetworkCodeInputCoordinator _crossNetworkCodeInputCoordinator;
    private readonly DiscoveryBrowserActions _discoveryBrowserActions;
    private readonly CrossNetworkConnectionActions _crossNetworkConnectionActions;
    private readonly ConnectionWorkspaceActions _connectionWorkspaceActions;
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
    private ImageSource? _crossNetworkGeneratedQrCodeImage;
    private ImageSource? _fileTransferShareQrCodeImage;
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
    private string _weatherPhase = WeatherStateCoordinator.PhaseLoading;
    private string _weatherLocation = "";
    private string _weatherTemperature = "";
    private string _weatherCondition = "";
    private string _weatherConditionKey = "";
    private string _weatherSource = "";
    private string _weatherUpdatedRelative = "";
    private string _weatherErrorMessage = "";
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
    private string _remoteDesktopSearchText = "";
    // Unfiltered master snapshot of the Remote Desktop session rows. The read-only
    // snapshot applier (single writer) replaces RemoteDesktopSessions; we mirror that
    // here so the left-pane search box can re-project the visible rows without inventing
    // any data. Mirrors the SettingsTabs/SettingsDetails CollectionChanged re-derive
    // pattern used a few lines below in the ctor.
    private readonly List<RemoteDesktopSessionItemView> _remoteDesktopSessionMaster = new();
    // Re-entrancy guard: true while ApplyRemoteDesktopSessionFilter is mutating
    // RemoteDesktopSessions, so the CollectionChanged mirror does not treat the
    // filter's own Clear/Add churn as a fresh snapshot.
    private bool _isFilteringRemoteDesktopSessions;
    // Coalesce guard: at most one deferred re-filter is queued on the UI sync context per
    // applier burst, so a multi-event Clear+Add snapshot schedules a single re-filter.
    private bool _remoteDesktopFilterReapplyQueued;
    private EngineConnectionState _connectionState;
    private FeatureEntry _selectedFeature;
    private SettingsTabItemView? _selectedSettingsTab;
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
        IWeatherClient? weatherClient = null,
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
            weatherClient,
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
        _weatherClient = dependencies.WeatherClient;
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
            dependencies.TopBarStatusClient,
            _manualConnectionClient,
            _crossNetworkConnectionClient,
            _fileTransferClient,
            _remoteDesktopClient,
            _systemMonitorClient,
            _settingsClient,
            _discoveryClient,
            _pairingMaterialClient,
            _connectionWorkspaceStateClient);
        _workspaceViewStateBuilder = new WorkspaceViewStateBuilder();
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
        var dashboardRefreshAction = new WorkspaceDeferredRefreshAction();
        _workspaceCountNotifier = new WorkspaceCountNotifier(OnPropertyChanged);
        _workspaceSnapshotApplier = new WorkspaceSnapshotApplier(
            _workspaceCountNotifier,
            dashboardRefreshAction.Invoke);
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
        WeatherMetrics = collections.WeatherMetrics;
        DashboardQuickActions = collections.DashboardQuickActions;
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
        _fileTransferWorkspaceActions = new FileTransferWorkspaceActions(
            _workspaceBusyCoordinator,
            _fileTransferClient,
            value => FileTransferStatus = value,
            value => StatusMessage = value,
            value => FileTransferShareQrCodeImage = BuildQrCodeImageSource(value));
        _remoteDesktopWorkspaceActions = new RemoteDesktopWorkspaceActions(
            _workspaceBusyCoordinator,
            _remoteDesktopClient,
            () => SelectedBitrate,
            () => SelectedFramerate,
            value => RemoteDesktopStatus = value,
            value => StatusMessage = value);
        _systemMonitorWorkspaceActions = new SystemMonitorWorkspaceActions(
            _workspaceBusyCoordinator,
            _systemMonitorClient,
            value => SystemMonitorStatus = value,
            value => StatusMessage = value);
        _settingsWorkspaceActions = new SettingsWorkspaceActions(
            _workspaceBusyCoordinator,
            _settingsClient,
            _readOnlyWorkspaceRefreshActions.RefreshSettingsActionSnapshotAsync,
            value => SettingsStatus = value,
            value => StatusMessage = value);
        _topBarWorkspaceActions = new TopBarWorkspaceActions(
            _workspaceBusyCoordinator,
            dependencies.TopBarStatusClient,
            value => TopBarNotificationsStatus = value,
            value => TopBarThemeStatus = value,
            value => StatusMessage = value);
        _dashboardMetricsUpdater = new DashboardMetricsUpdater(
            _dashboardMetricsClient,
            DashboardMetrics,
            _workspaceCountNotifier,
            value => OnlineDeviceCount = value,
            value => ActiveSessionCount = value,
            value => TransferTaskCount = value,
            value => PerformanceStatus = value);
        _weatherStateCoordinator = new WeatherStateCoordinator(
            _weatherClient,
            WeatherMetrics,
            value => WeatherPhase = value,
            value => WeatherLocation = value,
            value => WeatherTemperature = value,
            value => WeatherCondition = value,
            value => WeatherConditionKey = value,
            value => WeatherSource = value,
            value => WeatherUpdatedRelative = value,
            value => WeatherErrorMessage = value,
            value => StatusMessage = value);
        RefreshWeatherCommand = _weatherStateCoordinator.RefreshCommand;
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
        _sessionEngineActions = new SessionEngineActions(
            _engineClient,
            _workspaceBusyCoordinator,
            _sessionStatusClient,
            () => _connectionWorkspaceStateClient.BuildConnectionLaunchRequest(
                _connectionInputCoordinator.ValidatedState),
            value => StatusMessage = value);
        _discoveryBrowserActions = new DiscoveryBrowserActions(
            _discoveryBrowserInputPolicy,
            _workspaceBusyCoordinator,
            _discoveryBrowserClient,
            _workspaceViewStateBuilder,
            _connectionResultProjector,
            () => DiscoveryService,
            () => DiscoveryTxtRecord,
            () => DiscoverySearchText,
            () => IsDiscoveryCompatibilityModeEnabled,
            () => ExtendedSearchCountdown,
            () => PairingStatus,
            value => ExtendedSearchCountdown = value,
            value => DiscoveryBrowserStatus = value);
        _crossNetworkConnectionActions = new CrossNetworkConnectionActions(
            _workspaceBusyCoordinator,
            _crossNetworkConnectionClient,
            _workspaceViewStateBuilder,
            _connectionResultProjector,
            () => CrossNetworkQrInput,
            () => CrossNetworkCodeInput,
            () => CrossNetworkGeneratedCode,
            value => CrossNetworkStatus = value,
            value => CrossNetworkGeneratedCode = value,
            value => CrossNetworkGeneratedQrCodeImage = BuildQrCodeImageSource(value));
        _connectionWorkspaceActions = new ConnectionWorkspaceActions(
            _workspaceBusyCoordinator,
            _manualConnectionClient,
            _discoveryClient,
            _discoveryBrowserClient,
            _pairingMaterialClient,
            _connectionPreflightClient,
            _connectionWorkspaceStateClient,
            _workspaceViewStateBuilder,
            _connectionInputCoordinator,
            _connectionResultProjector,
            DiscoveredPeers,
            () => ManualConnectionHost,
            () => ManualConnectionPort,
            () => ManualConnectionCode,
            () => DiscoveryService,
            () => DiscoveryTxtRecord,
            () => PairingConnectionCode,
            value => ManualConnectionStatus = value,
            value => DiscoveryStatus = value,
            value => PairingStatus = value,
            value => ConnectionPreflightStatus = value,
            value => DiscoveryService = value);
        CoreDiagnosticFacts = collections.CoreDiagnosticFacts;
        DeviceDiscoveryPrimaryActions = collections.DeviceDiscoveryPrimaryActions;
        DeviceDiscoveryScanActions = collections.DeviceDiscoveryScanActions;
        DeviceDiscoveryManualConnectFinalActions = collections.DeviceDiscoveryManualConnectFinalActions;
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
        // Drive the Settings two-pane: when a snapshot replaces the tab/detail collections,
        // keep a valid left-pane selection and re-derive the right-pane (selected-tab) slice.
        SettingsTabs.CollectionChanged += OnSettingsTabsChanged;
        SettingsDetails.CollectionChanged += OnSettingsDetailsChanged;
        // Drive the Remote Desktop left-pane search: when the read-only snapshot applier
        // replaces RemoteDesktopSessions, re-capture the unfiltered master and re-apply the
        // current search text so the visible rows stay in sync. Mirrors the Settings hooks
        // directly above. The filter is the only re-projector of RemoteDesktopSessions; a
        // re-entrancy guard keeps it from reacting to its own Clear/Add churn.
        RemoteDesktopSessions.CollectionChanged += OnRemoteDesktopSessionsChanged;
        _selectedBitrate = startupState.RemoteDesktopProfileCatalog.DefaultBitrateProfile;
        _selectedFramerate = startupState.RemoteDesktopProfileCatalog.DefaultFramerateProfile;
        var workspaceShellStateSource = new WorkspaceShellStateSource(this);
        _workspaceShellStateAccessor = new WorkspaceShellStateAccessor(
            _workspaceViewStateBuilder,
            workspaceShellStateSource);
        _workspaceCommandAvailability = new WorkspaceCommandAvailability(
            _workspaceCommandGateCoordinator,
            _workspaceShellStateAccessor.BuildCommandGateState);
        _engineClient.ConnectionStateChanged += OnEngineStateChanged;
        var dashboardNavigationActions = new DashboardNavigationActions(
            () => NavigationItems,
            value => SelectedFeature = value);
        var commandBindings = new WorkspaceCommandBindings(
            _sessionEngineActions,
            dashboardNavigationActions,
            _topBarWorkspaceActions,
            _discoveryBrowserActions,
            _connectionWorkspaceActions,
            _crossNetworkConnectionActions,
            _readOnlyWorkspaceRefreshActions,
            _fileTransferWorkspaceActions,
            _remoteDesktopWorkspaceActions,
            _systemMonitorWorkspaceActions,
            _settingsWorkspaceActions,
            _workspaceCommandAvailability);
        ConnectCommand = commandBindings.ConnectCommand;
        DisconnectCommand = commandBindings.DisconnectCommand;
        HeartbeatCommand = commandBindings.HeartbeatCommand;
        OpenTopBarNotificationsCommand = commandBindings.OpenTopBarNotificationsCommand;
        ToggleTopBarThemeCommand = commandBindings.ToggleTopBarThemeCommand;
        StartDiscoveryCommand = commandBindings.StartDiscoveryCommand;
        StopDiscoveryCommand = commandBindings.StopDiscoveryCommand;
        RefreshDiscoveryCommand = commandBindings.RefreshDiscoveryCommand;
        RunExtendedDiscoveryCommand = commandBindings.RunExtendedDiscoveryCommand;
        PrepareManualConnectionCommand = commandBindings.PrepareManualConnectionCommand;
        CancelManualConnectionCommand = commandBindings.CancelManualConnectionCommand;
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
        SelectFileTransferFilesCommand = commandBindings.SelectFileTransferFilesCommand;
        SelectFileTransferFolderCommand = commandBindings.SelectFileTransferFolderCommand;
        GenerateFileTransferQrCommand = commandBindings.GenerateFileTransferQrCommand;
        RefreshRemoteDesktopCommand = commandBindings.RefreshRemoteDesktopCommand;
        RecommendedRemoteDesktopConnectCommand = commandBindings.RecommendedRemoteDesktopConnectCommand;
        AdvancedRemoteDesktopConnectCommand = commandBindings.AdvancedRemoteDesktopConnectCommand;
        ShowRemoteDesktopPerformanceOverlayCommand = commandBindings.ShowRemoteDesktopPerformanceOverlayCommand;
        ApplyRemoteDesktopQualityCommand = commandBindings.ApplyRemoteDesktopQualityCommand;
        OpenRemoteDesktopSettingsCommand = commandBindings.OpenRemoteDesktopSettingsCommand;
        EnterRemoteDesktopFullScreenCommand = commandBindings.EnterRemoteDesktopFullScreenCommand;
        DisconnectRemoteDesktopSessionCommand = commandBindings.DisconnectRemoteDesktopSessionCommand;
        RefreshSystemMonitorCommand = commandBindings.RefreshSystemMonitorCommand;
        StartSystemMonitoringCommand = commandBindings.StartSystemMonitoringCommand;
        StopSystemMonitoringCommand = commandBindings.StopSystemMonitoringCommand;
        EnableAdvancedSystemMonitoringCommand = commandBindings.EnableAdvancedSystemMonitoringCommand;
        RefreshUsbManagementCommand = commandBindings.RefreshUsbManagementCommand;
        RefreshSettingsCommand = commandBindings.RefreshSettingsCommand;
        ExportSettingsCommand = commandBindings.ExportSettingsCommand;
        ImportSettingsCommand = commandBindings.ImportSettingsCommand;
        ResetSettingsCommand = commandBindings.ResetSettingsCommand;
        RequestSettingsPermissionCommand = commandBindings.RequestSettingsPermissionCommand;
        OpenSystemPreferencesCommand = commandBindings.OpenSystemPreferencesCommand;
        ApplySettingsCommand = commandBindings.ApplySettingsCommand;
        RestoreDefaultsCommand = commandBindings.RestoreDefaultsCommand;
        ResetMonitorDataCommand = commandBindings.ResetMonitorDataCommand;
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
            _workspaceCommandGateCoordinator,
            _workspaceShellStateAccessor.BuildCommandGateState,
            _topBarStatusUpdater);
        _workspaceShellRefreshCoordinator = new WorkspaceShellRefreshCoordinator(
            _workspaceCommandRegistry,
            _workspaceActionSurfaceLoader,
            _workspaceActionRenderContextBuilder,
            _dashboardMetricsUpdater,
            _topBarStatusUpdater,
            _workspaceShellStateAccessor.BuildDashboardMetricsRequest,
            _workspaceShellStateAccessor.BuildActionRenderState,
            OnPropertyChanged,
            WorkspaceShellNotificationCatalog.SelectedFeaturePropertyNames,
            WorkspaceShellNotificationCatalog.ConnectionStatusPropertyName);
        _workspaceInputChangeRouter = new WorkspaceInputChangeRouter(
            _workspaceShellRefreshCoordinator,
            _connectionInputCoordinator);
        dashboardRefreshAction.Attach(_workspaceShellRefreshCoordinator.RefreshDashboardMetrics);
        _workspaceShellRefreshCoordinator.LoadWorkspaceActions();
        _workspaceShellRefreshCoordinator.RefreshDashboardMetrics();
        _workspaceShellRefreshCoordinator.RefreshTopBarStatus();
        // Kick the first weather fetch on startup (the dashboard is the default feature),
        // mirroring the Mac auto-load on dashboard show. Fire-and-forget via the command's
        // async-void Execute is consistent with the house style; the card shows the
        // Loading state until the real snapshot lands (never fake numbers).
        RefreshWeatherCommand.Execute(null);
        // Kick the first System Monitor read-only snapshot on startup so the dashboard
        // System-Performance panel AND the System Monitor screen show real Memory/Disk/
        // Network/Health telemetry immediately, instead of empty sections. This is a
        // one-shot sample (no "start monitoring" needed); honest values, never faked.
        RefreshSystemMonitorCommand.Execute(null);
        // Kick the first File Transfer read-only snapshot on startup so the File Transfer
        // screen shows the real transport/channel plan, queue, history, and security
        // facts immediately instead of empty Queue/History/Security sections (the screen
        // was previously empty until a manual refresh or navigation). Mirrors the Mac
        // auto-load on file-transfer show; fire-and-forget via the command's async-void
        // Execute, consistent with the Weather/SystemMonitor kicks above. Read-only
        // snapshot — no picker is opened and no local files are read.
        RefreshFileTransferCommand.Execute(null);
        // Kick the first Settings read-only snapshot on startup so the Settings two-pane
        // shows its 8 tabs + grouped section cards immediately instead of an empty screen
        // (the screen was previously empty until a manual Refresh Status). The
        // CollectionChanged hooks above auto-select the first tab once the tabs land, so the
        // right pane is populated without any user interaction. Uses the EXISTING command
        // (routed through the action catalog / command bindings); read-only snapshot — no
        // preference, file, permission, or runtime setting is touched.
        RefreshSettingsCommand.Execute(null);
        // Kick the first Remote Desktop read-only snapshot on startup so the Remote Desktop
        // two-pane shows its session preview rows + control facts immediately instead of an
        // empty Active Sessions list and empty facts (the screen was previously empty until a
        // manual "Refresh Sessions"). Mirrors the Weather/SystemMonitor/FileTransfer/Settings
        // kicks above. Uses the EXISTING RefreshRemoteDesktopCommand (routed through the
        // command bindings); fully read-only/fail-closed — no live transport is opened, no
        // session is started. The rows it loads are honest previews, not live sessions.
        RefreshRemoteDesktopCommand.Execute(null);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<FeatureEntry> NavigationItems { get; }

    public ObservableCollection<DashboardMetricView> DashboardMetrics { get; }

    public ObservableCollection<WeatherMetricView> WeatherMetrics { get; }

    public ObservableCollection<WorkspaceActionItemView> DashboardQuickActions { get; }

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

    public ObservableCollection<WorkspaceActionItemView> DeviceDiscoveryManualConnectFinalActions { get; }

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

    // Right-pane rows for the Settings two-pane layout: the subset of SettingsDetails whose
    // Section matches the currently SelectedSettingsTab. Re-derived whenever the selection
    // changes OR the backing SettingsDetails / SettingsTabs collections are replaced by a
    // snapshot refresh.
    public ObservableCollection<SettingsDetailItemView> SelectedSettingsTabDetails { get; } = new();

    // The same selected-tab rows grouped into section cards (by CardName), in backend order.
    // This is what the right pane binds to: each group renders a gray card title + a glass
    // card of control rows, element-matching the Mac SettingsView section cards.
    public ObservableCollection<SettingsCardGroupView> SelectedSettingsTabCards { get; } = new();

    // ---- Weather hero card surface (element-matches the Mac WeatherDashboardCard) ----
    // Phase drives the three state layers via WeatherPhaseToVisibilityConverter; the
    // scalar strings/collection are mutated by WeatherStateCoordinator on the UI context.

    public string WeatherPhase
    {
        get => _weatherPhase;
        private set
        {
            if (SetField(ref _weatherPhase, value))
            {
                OnPropertyChanged(nameof(IsWeatherLoading));
            }
        }
    }

    // Convenience flag for the loading spinner's IsActive (avoids a converter on a bool).
    public bool IsWeatherLoading =>
        string.Equals(WeatherPhase, WeatherStateCoordinator.PhaseLoading, StringComparison.Ordinal);

    public string WeatherLocation
    {
        get => _weatherLocation;
        private set => SetField(ref _weatherLocation, value);
    }

    public string WeatherTemperature
    {
        get => _weatherTemperature;
        private set => SetField(ref _weatherTemperature, value);
    }

    public string WeatherCondition
    {
        get => _weatherCondition;
        private set => SetField(ref _weatherCondition, value);
    }

    // The enum name (Clear/Cloudy/...) the glyph + accent converters key off.
    public string WeatherConditionKey
    {
        get => _weatherConditionKey;
        private set => SetField(ref _weatherConditionKey, value);
    }

    public string WeatherSource
    {
        get => _weatherSource;
        private set => SetField(ref _weatherSource, value);
    }

    public string WeatherUpdatedRelative
    {
        get => _weatherUpdatedRelative;
        private set => SetField(ref _weatherUpdatedRelative, value);
    }

    public string WeatherErrorMessage
    {
        get => _weatherErrorMessage;
        private set => SetField(ref _weatherErrorMessage, value);
    }

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
                _workspaceShellRefreshCoordinator.RefreshSelectedFeatureState();
            }
        }
    }

    // Sub-nav selection for the Settings two-pane layout (left tab list ⇄ right section
    // cards). TwoWay-bound to the tab ListView's SelectedItem; changing it re-filters the
    // right pane to that tab's rows. Nullable because the tab list is empty until the first
    // settings snapshot lands (then the ctor's CollectionChanged hook auto-selects tab 0).
    public SettingsTabItemView? SelectedSettingsTab
    {
        get => _selectedSettingsTab;
        set
        {
            if (SetField(ref _selectedSettingsTab, value))
            {
                RefreshSelectedSettingsTabDetails();
            }
        }
    }

    public bool IsDashboardSelected =>
        IsFeatureSelected(FeatureEntryId.Dashboard);

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
                _workspaceShellRefreshCoordinator.RefreshConnectionState();
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
                _workspaceShellRefreshCoordinator.RefreshShellRuntimeState();
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
                _workspaceInputChangeRouter.DiscoveryInputChanged();
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
                _workspaceInputChangeRouter.DiscoverySearchChanged();
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
                _workspaceInputChangeRouter.ManualTargetChanged();
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
                _workspaceInputChangeRouter.ManualTargetChanged();
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
                _workspaceInputChangeRouter.ManualTargetChanged();
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
                _workspaceInputChangeRouter.CrossNetworkInputChanged();
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
                _workspaceInputChangeRouter.CrossNetworkInputChanged();
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

    public ImageSource? CrossNetworkGeneratedQrCodeImage
    {
        get => _crossNetworkGeneratedQrCodeImage;
        private set
        {
            if (SetField(ref _crossNetworkGeneratedQrCodeImage, value))
            {
                OnPropertyChanged(nameof(IsCrossNetworkGeneratedQrCodeVisible));
            }
        }
    }

    public bool IsCrossNetworkGeneratedQrCodeVisible =>
        CrossNetworkGeneratedQrCodeImage is not null;

    public ImageSource? FileTransferShareQrCodeImage
    {
        get => _fileTransferShareQrCodeImage;
        private set
        {
            if (SetField(ref _fileTransferShareQrCodeImage, value))
            {
                OnPropertyChanged(nameof(IsFileTransferShareQrCodeVisible));
            }
        }
    }

    public bool IsFileTransferShareQrCodeVisible =>
        FileTransferShareQrCodeImage is not null;

    public string DiscoveryTxtRecord
    {
        get => _discoveryTxtRecord;
        set
        {
            if (SetField(ref _discoveryTxtRecord, value))
            {
                _workspaceInputChangeRouter.DiscoveryInputChanged();
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
                _workspaceInputChangeRouter.PairingInputChanged();
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

    /// <summary>
    /// Free-text filter for the Remote Desktop left-pane session list, element-matching
    /// the Mac RemoteDesktopView search field (filters the active/recent session rows by
    /// target name). Purely a view-state filter over the existing
    /// <see cref="RemoteDesktopSessions"/> rows projected by the read-only snapshot — it
    /// never fabricates rows and never reaches the engine.
    /// </summary>
    public string RemoteDesktopSearchText
    {
        get => _remoteDesktopSearchText;
        set
        {
            if (SetField(ref _remoteDesktopSearchText, value ?? ""))
            {
                ApplyRemoteDesktopSessionFilter();
            }
        }
    }

    // Mirror the unfiltered master from the snapshot applier's replace. The applier does a
    // Clear() + per-item Add() burst (WorkspaceCollectionProjector.Replace), so this fires
    // several times per snapshot; each fire just re-captures the current rows, leaving the
    // master complete after the final Add. We deliberately do NOT mutate RemoteDesktopSessions
    // from inside this handler (the applier is still appending to it), which would corrupt the
    // list / re-enter. Instead, when a search is active we re-apply the filter on the captured
    // UI synchronization context — i.e. AFTER the applier's synchronous burst settles — matching
    // the codebase's captured-context style (no DispatcherQueue). Changes the filter itself
    // makes are skipped via the guard.
    private void OnRemoteDesktopSessionsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (_isFilteringRemoteDesktopSessions)
        {
            return;
        }

        _remoteDesktopSessionMaster.Clear();
        _remoteDesktopSessionMaster.AddRange(RemoteDesktopSessions);

        if (_remoteDesktopSearchText.Length > 0 && !_remoteDesktopFilterReapplyQueued)
        {
            // Defer the re-filter until the current synchronous Clear+Add burst completes so we
            // never mutate the collection the applier is mid-way through populating.
            var context = SynchronizationContext.Current;
            if (context is not null)
            {
                _remoteDesktopFilterReapplyQueued = true;
                context.Post(_ =>
                {
                    _remoteDesktopFilterReapplyQueued = false;
                    ApplyRemoteDesktopSessionFilter();
                }, null);
            }
        }
    }

    // Re-project RemoteDesktopSessions from the unfiltered master, keeping only rows whose
    // target name contains the search text (case-insensitive). When the search is empty the
    // full master is restored. This is the only re-projector of RemoteDesktopSessions outside
    // the snapshot applier; the guard prevents the CollectionChanged mirror from looping.
    private void ApplyRemoteDesktopSessionFilter()
    {
        _isFilteringRemoteDesktopSessions = true;
        try
        {
            RemoteDesktopSessions.Clear();
            foreach (var session in _remoteDesktopSessionMaster)
            {
                if (_remoteDesktopSearchText.Length == 0 ||
                    (session.TargetName?.Contains(_remoteDesktopSearchText, StringComparison.OrdinalIgnoreCase) ?? false))
                {
                    RemoteDesktopSessions.Add(session);
                }
            }
        }
        finally
        {
            _isFilteringRemoteDesktopSessions = false;
        }

        _workspaceCountNotifier.RemoteDesktopSessionsChanged();
    }

    public ICommand ConnectCommand { get; }

    public ICommand DisconnectCommand { get; }

    public ICommand HeartbeatCommand { get; }

    public ICommand OpenTopBarNotificationsCommand { get; }

    public ICommand ToggleTopBarThemeCommand { get; }

    public ICommand StartDiscoveryCommand { get; }

    public ICommand StopDiscoveryCommand { get; }

    public ICommand RefreshDiscoveryCommand { get; }

    public ICommand RunExtendedDiscoveryCommand { get; }

    public ICommand PrepareManualConnectionCommand { get; }

    public ICommand CancelManualConnectionCommand { get; }

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

    // Refresh button on the weather hero card (the only nav control on the Mac card).
    public ICommand RefreshWeatherCommand { get; }

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

    private bool IsFeatureSelected(FeatureEntryId featureId) =>
        _workspaceCommandGateCoordinator.IsFeatureSelected(SelectedFeature, featureId);

    private static ImageSource? BuildQrCodeImageSource(string? pngBase64)
    {
        if (string.IsNullOrWhiteSpace(pngBase64))
        {
            return null;
        }

        var bytes = Convert.FromBase64String(pngBase64);
        var image = new BitmapImage();
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
        {
            writer.WriteBytes(bytes);
            writer.StoreAsync().AsTask().GetAwaiter().GetResult();
            writer.DetachStream();
        }

        stream.Seek(0);
        image.SetSource(stream);
        return image;
    }

    internal ConnectionWorkspaceValidatedState ValidatedConnectionState =>
        _connectionInputCoordinator.ValidatedState;

    private void OnEngineStateChanged(object? sender, EngineConnectionState newState)
    {
        _sessionEngineStateProjector.Apply(newState);
    }

    // Re-derives the right pane for the SelectedSettingsTab: the flat row slice
    // (SelectedSettingsTabDetails = SettingsDetails where Section == tab Title) and the
    // grouped-by-card projection (SelectedSettingsTabCards) the pane actually renders.
    // Both are replaced in place, preserving the backend's row order within each card.
    private void RefreshSelectedSettingsTabDetails()
    {
        SelectedSettingsTabDetails.Clear();
        SelectedSettingsTabCards.Clear();

        var section = _selectedSettingsTab?.Title;
        if (string.IsNullOrEmpty(section))
        {
            return;
        }

        var cardOrder = new List<string>();
        var cardRows = new Dictionary<string, List<SettingsDetailItemView>>(StringComparer.Ordinal);

        foreach (var row in SettingsDetails)
        {
            if (!string.Equals(row.Section, section, StringComparison.Ordinal))
            {
                continue;
            }

            SelectedSettingsTabDetails.Add(row);

            var card = row.CardName;
            if (!cardRows.TryGetValue(card, out var rows))
            {
                rows = new List<SettingsDetailItemView>();
                cardRows[card] = rows;
                cardOrder.Add(card);
            }

            rows.Add(row);
        }

        foreach (var card in cardOrder)
        {
            SelectedSettingsTabCards.Add(new SettingsCardGroupView(card, cardRows[card]));
        }
    }

    // When a settings snapshot replaces the tab list, keep a valid selection: if nothing is
    // selected yet (first load), or the previously-selected tab is gone, select the first
    // tab. Otherwise preserve the user's current tab (re-resolved to the new instance so the
    // ListView selection and the right-pane filter both stay correct).
    private void OnSettingsTabsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (SettingsTabs.Count == 0)
        {
            SelectedSettingsTab = null;
            return;
        }

        var currentTitle = _selectedSettingsTab?.Title;
        SettingsTabItemView? resolved = null;
        if (!string.IsNullOrEmpty(currentTitle))
        {
            foreach (var tab in SettingsTabs)
            {
                if (string.Equals(tab.Title, currentTitle, StringComparison.Ordinal))
                {
                    resolved = tab;
                    break;
                }
            }
        }

        SelectedSettingsTab = resolved ?? SettingsTabs[0];
    }

    // When a settings snapshot replaces the detail rows, re-derive the right-pane slice for
    // the currently selected tab (the row instances changed even if the tab did not).
    private void OnSettingsDetailsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        RefreshSelectedSettingsTabDetails();
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
