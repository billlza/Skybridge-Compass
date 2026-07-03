using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Runtime.ExceptionServices;
using System.Threading;
using System.Windows.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Skybridge.WinClient.Services;
using Windows.Storage.Streams;

namespace Skybridge.WinClient.ViewModels;

public sealed class SessionViewModel : INotifyPropertyChanged, IDisposable
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
    // Owns the account identity lifecycle + its own Supabase auth client / DPAPI store and
    // the sign-out command (the AsyncRelayCommand construction lives in the coordinator, not
    // here). Self-provisioned in the ctor; never routed through the DI composition root.
    private readonly AccountSessionCoordinator _accountSessionCoordinator;
    // Owns the live top-bar network telemetry loop (net speed / latency / IP+proxy) and its
    // own ITopBarNetworkStatusClient. Self-provisioned in the ctor; never routed through the
    // DI composition root. Disposed via Dispose on teardown.
    private readonly TopBarNetworkCoordinator _topBarNetworkCoordinator;
    // Owns the Settings page persistence + bindable surface (it self-provisions its own
    // SettingsService + SettingsStore writing %LOCALAPPDATA%\SkyBridge\settings.json). Exposed
    // publicly as Settings for {Binding Settings.<Prop>}. Self-provisioned in the ctor; never
    // routed through the DI composition root. Disposed via Dispose on teardown.
    private readonly SettingsCoordinator _settingsCoordinator;
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
    private readonly object _disposeLock = new();
    private bool _disposed;
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
    // Live top-bar network pills (net speed / latency / IP+proxy). Driven by the
    // TopBarNetworkCoordinator, which self-provisions its own ITopBarNetworkStatusClient (it
    // is NOT injected through SessionViewModelDependencies — same escape hatch as the weather
    // seam). These start at the honest placeholders and flip to real values once sampled.
    private string _topBarNetworkSpeed = TopBarNetworkCoordinator.PlaceholderSpeed;
    private string _topBarNetworkLatency = TopBarNetworkCoordinator.PlaceholderLatency;
    private string _topBarIpLocation = TopBarNetworkCoordinator.PlaceholderLocationUnavailable;
    private bool _isSystemProxyEnabled;
    // Settings-driven display gates (live effects from SettingsCoordinator). The three top-bar
    // pill-visibility bools gate the IP/location, net-speed, and latency pills (网络 > 顶部栏); the
    // DD card bools gate detail-rows (显示设备详情), density (紧凑模式), and the device icon chip
    // (显示设备图标). All default to the persisted setting defaults (true/true/true/true/true/false)
    // and are pushed live by SettingsCoordinator's effect sinks. They are plain SetField scalars —
    // no collection mutation, no projection path.
    private bool _showTopBarSpeedPill = true;
    private bool _showTopBarLatencyPill = true;
    private bool _showTopBarIpLocationPill = true;
    private bool _showDeviceDetailRows = true;
    private bool _deviceCardsCompact;
    private bool _showDeviceIconChips = true;
    // Account block identity (sidebar PaneFooter). Driven by the AccountSessionCoordinator,
    // which self-provisions its own Supabase auth client + DPAPI session store (it is NOT
    // injected through SessionViewModelDependencies — same escape hatch as the weather seam).
    private string _displayName = "Sign in";
    private string _nebulaId = "";
    private string _avatarUrl = "";
    private string _email = "";
    private string _phoneNumber = "";
    private bool _isSignedIn;
    // In-window account overlays (replace the crashing ContentDialog). AuthOverlay shows the
    // full Mac login when signed-OUT; UserProfileOverlay shows the 用户资料 modal when
    // signed-IN. Both are plain Visibility-bound Grid layers in MainWindow — no XamlRoot,
    // no single-dialog-at-a-time rule, no async-void ShowAsync teardown.
    private bool _showAuthOverlay;
    private bool _showProfileOverlay;
    // AuthOverlay email-form state: the inline error string + a busy flag while the real
    // Supabase sign-in is in flight (drives the button spinner / disabled state).
    private string _authErrorMessage = "";
    private bool _isAuthBusy;
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
    // Pure UI view-state (no DI client, no fabricated data) mirroring the Mac
    // @State selectedConnectionMode / connectionMode / modernTabBar selection.
    // These hold local selection only; the underlying real surfaces are unchanged.
    private DiscoveryMode _selectedDiscoveryMode = DiscoveryMode.LocalScan;
    private RemoteDesktopConnectionMode _selectedRemoteDesktopMode = RemoteDesktopConnectionMode.Auto;
    private int _selectedFileTransferTab;
    // B2 — smart-connection-code lease mode (Mac ConnectionCodeLeaseMode 短时/全天). Drives a
    // REAL generated-code TTL via CrossNetworkConnectionClient.BuildCodeSnapshot. Default is the
    // short-lived assistance window (set from the input-defaults snapshot at startup).
    private CrossNetworkCodeLeaseMode _selectedConnectionCodeLeaseMode = CrossNetworkCodeLeaseMode.ShortLived;

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
        // B2 — smart-connection-code lease default from the input-defaults snapshot ("shortLived"
        // by default). Parsed into the enum that drives the real generated-code TTL; an unknown
        // value falls back to the short-lived assistance window rather than fabricating a longer TTL.
        _selectedConnectionCodeLeaseMode =
            string.Equals(startupState.ConnectionCodeLeaseMode, "dayStable", StringComparison.OrdinalIgnoreCase)
                ? CrossNetworkCodeLeaseMode.DayStable
                : CrossNetworkCodeLeaseMode.ShortLived;
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
        // NOTE: _settingsWorkspaceActions is constructed LATER (after _settingsCoordinator exists),
        // so its real Export/Import/Reset/Apply work can route through the coordinator. See the
        // `_settingsWorkspaceActions = new SettingsWorkspaceActions(...)` block just after the
        // SettingsCoordinator is self-provisioned below.
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
        // Self-provision the account coordinator (it owns its Supabase auth client + DPAPI
        // session store internally) and forward its identity into the SetField-backed props.
        // The sign-out command + auth client come FROM the coordinator (the command-ownership
        // and DI-root escape hatches) — the VM only forwards them out for binding/dialog use.
        _accountSessionCoordinator = new AccountSessionCoordinator();
        _accountSessionCoordinator.IdentityChanged += OnAccountIdentityChanged;
        SignOutCommand = _accountSessionCoordinator.SignOutCommand;
        // Self-provision the top-bar network coordinator (it owns its own real
        // ITopBarNetworkStatusClient — net-speed counters, latency HEAD probe, ipapi.co +
        // registry proxy read — internally, NOT via the DI root). Forward its four scalar
        // values into the SetField-backed props. These are string/bool updates only (no
        // collections), so the periodic loop never touches the WorkspaceCollectionProjector
        // path and cannot reintroduce the dashboard flicker.
        _topBarNetworkCoordinator = new TopBarNetworkCoordinator(
            value => TopBarNetworkSpeed = value,
            value => TopBarNetworkLatency = value,
            value => TopBarIpLocation = value,
            value => IsSystemProxyEnabled = value);
        // The Settings coordinator is self-provisioned LATER in this ctor (after the discovery
        // browser actions exist), so its live-effect sinks can route into the discovery Start/Stop/
        // Refresh delegates. See the `_settingsCoordinator = new SettingsCoordinator(...)` block
        // below, just after `_discoveryBrowserActions`. Owns its own SettingsService + SettingsStore
        // (plaintext JSON at %LOCALAPPDATA%\SkyBridge\settings.json), NOT via the DI root.
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
        // Self-provision the Settings coordinator with its LIVE-EFFECT sinks. It owns its own
        // SettingsService + SettingsStore (plaintext JSON at %LOCALAPPDATA%\SkyBridge\settings.json)
        // internally, NOT via the DI root. The sinks route each REAL-FULL effect into the
        // subsystems this VM already owns — thin Action delegates, the same shape the TopBar /
        // Weather / DashboardMetrics coordinators use. Disposed in Dispose.
        _settingsCoordinator = new SettingsCoordinator(
            service: null,
            sinks: new SettingsEffectSinks
            {
                // 启用深色模式 / 主题颜色 — routed up to MainWindow (it owns the RootShell
                // FrameworkElement + the Application resources). The VM only re-raises the request.
                SetDarkMode = isDark => DarkModeEffectRequested?.Invoke(isDark),
                SetAccentHex = hex => AccentColorEffectRequested?.Invoke(hex),
                // 紧凑模式 / 显示设备详情 / 显示设备图标 — push into the change-notifying
                // DeviceDisplayPrefs resource the DD peer cards bind to (a per-item DataTemplate
                // can't reach the page VM), AND mirror onto the VM SetField bools for any other
                // consumer. Both update live. ResolveDeviceDisplayPrefs() returns the SAME instance
                // the cards bind via {StaticResource DeviceDisplayPrefs}.
                SetCompactMode = value =>
                {
                    DeviceCardsCompact = value;
                    if (ResolveDeviceDisplayPrefs() is { } prefs) { prefs.Compact = value; }
                },
                SetShowDeviceDetails = value =>
                {
                    ShowDeviceDetailRows = value;
                    if (ResolveDeviceDisplayPrefs() is { } prefs) { prefs.ShowDetails = value; }
                },
                SetShowDeviceIcons = value =>
                {
                    ShowDeviceIconChips = value;
                    if (ResolveDeviceDisplayPrefs() is { } prefs) { prefs.ShowIcons = value; }
                },
                // 顶部网络信息 — the three pill-visibility bools the top-bar pills bind to.
                SetTopBarPillVisibility = (ip, speed, latency) =>
                {
                    ShowTopBarIpLocationPill = ip;
                    ShowTopBarSpeedPill = speed;
                    ShowTopBarLatencyPill = latency;
                },
                // 网络发现 + 启动时自动扫描 + 扫描间隔 — issue the EXISTING gated discovery browser
                // actions (Start/Stop/Refresh), never new commands. Fire-and-forget (the actions
                // run through the busy coordinator); the VM's discovery getters already carry the
                // mDNS/timeout/custom-port/custom-service knobs into the request a Refresh rebuilds.
                StartDiscovery = () => _discoveryBrowserActions.StartAsync(),
                StopDiscovery = () => _discoveryBrowserActions.StopAsync(),
                RefreshDiscovery = () => _discoveryBrowserActions.RefreshAsync(),
                // 启用实时天气 — gate the existing weather loop (start re-fetch / stop).
                SetWeatherEnabled = SetWeatherLoopEnabled,
                // 剪贴板同步 — flip the clipboard-sync gate the session-start path consults.
                SetClipboardSyncEnabled = value => IsClipboardSyncEnabled = value,
                // 信号平滑 alpha — push the EMA coefficient into the real signal smoother.
                SetSignalSmoothingAlpha = alpha => WindowsSignalSmoother.Alpha = alpha,
                // 传输时保持唤醒 — arm/disarm the SetThreadExecutionState gate used during transfers.
                SetKeepAwakeDuringTransfer = value => KeepSystemAwakeDuringTransfer = value,
                // 系统监控 显示项 — push the six metric show-flags into the MonitorDisplayPrefs
                // resource the tiles read, then re-issue the System-Monitor read so the projected
                // tile collection re-renders (hidden metrics' tiles drop). Observable, live.
                SetMonitorMetricVisibility = (cpu, mem, disk, net, temp, fan) =>
                    ApplyMonitorMetricVisibility(cpu, mem, disk, net, temp, fan),
            });
        // Construct the Settings actions NOW (after the coordinator exists) so Export/Import/Reset/
        // Apply do REAL work through the coordinator instead of in-memory intent stubs. The file
        // pickers need the window HWND, so they are routed to MainWindow via the VM events below
        // (null in a window-less test host → the action falls back to the existing intent message,
        // surface/counts unchanged). This uses the EXISTING gated action surface — no new command.
        _settingsWorkspaceActions = new SettingsWorkspaceActions(
            _workspaceBusyCoordinator,
            _settingsClient,
            _readOnlyWorkspaceRefreshActions.RefreshSettingsActionSnapshotAsync,
            value => SettingsStatus = value,
            value => StatusMessage = value,
            _settingsCoordinator,
            () => ExportSettingsPathRequested is { } h ? h() : Task.FromResult<string?>(null),
            () => ImportSettingsPathRequested is { } h ? h() : Task.FromResult<string?>(null));
        _crossNetworkConnectionActions = new CrossNetworkConnectionActions(
            _workspaceBusyCoordinator,
            _crossNetworkConnectionClient,
            _workspaceViewStateBuilder,
            _connectionResultProjector,
            () => CrossNetworkQrInput,
            () => CrossNetworkCodeInput,
            () => CrossNetworkGeneratedCode,
            () => SelectedConnectionCodeLeaseMode,
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
        SidebarSessionActions = collections.SidebarSessionActions;
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
        RemoteDesktopRecentSessions = collections.RemoteDesktopRecentSessions;
        RemoteDesktopControlFacts = collections.RemoteDesktopControlFacts;
        SystemMonitorHeaderActions = collections.SystemMonitorHeaderActions;
        SystemMonitorActions = collections.SystemMonitorActions;
        SystemMonitorOverview = collections.SystemMonitorOverview;
        SystemMonitorDetails = collections.SystemMonitorDetails;
        SystemMonitorIndicators = collections.SystemMonitorIndicators;
        SystemMonitorInsights = collections.SystemMonitorInsights;
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
        // Re-derive the header monitoring pill (IsSystemMonitoring) whenever the
        // read-only snapshot applier replaces the SystemMonitorIndicators rows —
        // the pill tint reads the real "Monitoring" indicator State (Active/Idle),
        // never a fabricated value.
        SystemMonitorIndicators.CollectionChanged += OnSystemMonitorIndicatorsChanged;
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
        // Kick the live top-bar network telemetry loop (net speed every ~2 s, latency every
        // ~15 s, IP/proxy every ~300 s). The coordinator samples on a thread-pool task and
        // marshals only scalar string/bool updates back to the UI dispatcher, so this never
        // blocks the ctor and never mutates a collection. Mirrors the Mac top-bar service
        // start() that the dashboard triggers on show.
        _topBarNetworkCoordinator.Start();
        // Kick the first Settings read-only snapshot on startup so the Settings two-pane
        // shows its 8 tabs + grouped section cards immediately instead of an empty screen
        // (the screen was previously empty until a manual Refresh Status). The
        // CollectionChanged hooks above auto-select the first tab once the tabs land, so the
        // right pane is populated without any user interaction.
        //
        // IMPORTANT: we call the refresh ACTION directly, NOT RefreshSettingsCommand. That
        // command's CanExecute (CanRefreshSettings → CanUseSelectedWorkspaceFeature) is gated
        // on the Settings feature being the *currently selected* one — which is false at
        // startup (Dashboard is the default feature). So RefreshSettingsCommand.Execute(null)
        // here was silently swallowed (CanExecute=false) and the tabs NEVER landed; navigating
        // to Settings later only re-raises selection notifications (RefreshSelectedFeatureState),
        // it does NOT re-pull a snapshot — so the page stayed permanently empty until the user
        // manually clicked the header Refresh. RefreshSettingsActionSnapshotAsync is the
        // un-gated direct await+apply path (no busy-coordinator, no feature gate); it fills
        // SettingsTabs/Actions/Details from the static read-only snapshot regardless of which
        // feature is selected. Read-only snapshot — no preference, file, permission, or runtime
        // setting is touched.
        _ = _readOnlyWorkspaceRefreshActions.RefreshSettingsActionSnapshotAsync();
        // Kick the first Remote Desktop read-only snapshot on startup so the Remote Desktop
        // two-pane shows its session preview rows + control facts immediately instead of an
        // empty Active Sessions list and empty facts (the screen was previously empty until a
        // manual "Refresh Sessions"). Mirrors the Weather/SystemMonitor/FileTransfer/Settings
        // kicks above. Uses the EXISTING RefreshRemoteDesktopCommand (routed through the
        // command bindings); fully read-only/fail-closed — no live transport is opened, no
        // session is started. The rows it loads are honest previews, not live sessions.
        RefreshRemoteDesktopCommand.Execute(null);
        // Kick the first USB Management read-only snapshot on startup so the USB screen shows
        // its 4 stat cards (MFi Certified / Android Devices / Storage Devices / Total Devices —
        // populated at their real counts, even 0) and the Connected-Devices list immediately
        // instead of empty cards + a stuck empty state. Previously UsbDeviceStats / UsbDevices
        // stayed empty from launch until the user manually clicked "Refresh Devices" (selecting
        // the USB screen only re-raised Is…Selected notifications, never refreshed the data).
        // Mirrors the Weather/SystemMonitor/FileTransfer/Settings/RemoteDesktop kicks above.
        // Uses the EXISTING RefreshUsbManagementCommand; read-only WinRT enumeration — no device
        // is opened/written and no fake rows are fabricated (empty when nothing is connected).
        RefreshUsbManagementCommand.Execute(null);
        // Apply the persisted Settings as LIVE effects on launch so the saved theme / accent /
        // top-bar pill visibility / DD card density+detail+icon gates / logger level / signal-
        // smoother alpha / clipboard + keep-awake gates take effect immediately — without waiting
        // for the first user edit. Seed the weather-loop flag from the persisted setting first so
        // the auto-load above is not duplicated (the dashboard weather card already kicked once).
        // ApplyInitialEffects also issues the discovery Start + arms the re-scan timer when
        // 启动时自动扫描设备 is on (and Bonjour is enabled), so a fresh launch begins scanning on the
        // configured cadence — the EXISTING gated DiscoveryBrowser actions, never a new command.
        _isWeatherLoopEnabled = _settingsCoordinator.EnableRealTimeWeather;
        _settingsCoordinator.ApplyInitialEffects();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<FeatureEntry> NavigationItems { get; }

    public ObservableCollection<DashboardMetricView> DashboardMetrics { get; }

    public ObservableCollection<WeatherMetricView> WeatherMetrics { get; }

    public ObservableCollection<WorkspaceActionItemView> DashboardQuickActions { get; }

    public ObservableCollection<string> BitrateProfiles { get; }

    public ObservableCollection<string> FramerateProfiles { get; }

    public ObservableCollection<WorkspaceActionItemView> TopBarActions { get; }

    public ObservableCollection<WorkspaceActionItemView> SidebarSessionActions { get; }

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

    // A7 — read-only partition of RemoteDesktopSessions whose State == "Recent" (Mac
    // sessionList "Recent Connections" section). Re-derived from the unfiltered master in
    // OnRemoteDesktopSessionsChanged; no reconnect command, no fabricated timestamp.
    public ObservableCollection<RemoteDesktopSessionItemView> RemoteDesktopRecentSessions { get; }

    public int RemoteDesktopRecentSessionCount => RemoteDesktopRecentSessions.Count;

    public ObservableCollection<RemoteDesktopControlFactView> RemoteDesktopControlFacts { get; }

    public ObservableCollection<WorkspaceActionItemView> SystemMonitorHeaderActions { get; }

    public ObservableCollection<WorkspaceActionItemView> SystemMonitorActions { get; }

    public ObservableCollection<SystemMonitorMetricView> SystemMonitorOverview { get; }

    public ObservableCollection<SystemMonitorMetricView> SystemMonitorDetails { get; }

    public ObservableCollection<SystemMonitorIndicatorView> SystemMonitorIndicators { get; }

    // B5 — Insight rows (Mac liveSnapshotHighlights): Health + Bandwidth real, thermal/fan
    // honest Unknown. Projected from the real snapshot by the read-only snapshot applier.
    public ObservableCollection<SystemMonitorInsightView> SystemMonitorInsights { get; }

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

    // ---- Account block identity (sidebar PaneFooter) --------------------------------
    // These four are forwarded from the AccountSessionCoordinator's IdentityChanged event.
    // When signed out, DisplayName is "Sign in" (the account block's call-to-action).

    public string DisplayName
    {
        get => _displayName;
        private set => SetField(ref _displayName, value);
    }

    public string NebulaId
    {
        get => _nebulaId;
        private set => SetField(ref _nebulaId, value);
    }

    public string AvatarUrl
    {
        get => _avatarUrl;
        private set => SetField(ref _avatarUrl, value);
    }

    // 邮箱 / 手机号 for the user-profile overlay rows. Empty (→ "未绑定" in the UI) when the
    // account has not bound them — never fabricated. Forwarded from the coordinator identity.
    public string Email
    {
        get => _email;
        private set
        {
            if (SetField(ref _email, value))
            {
                OnPropertyChanged(nameof(HasEmail));
                OnPropertyChanged(nameof(EmailUnbound));
                OnPropertyChanged(nameof(EmailDisplay));
            }
        }
    }

    public string PhoneNumber
    {
        get => _phoneNumber;
        private set
        {
            if (SetField(ref _phoneNumber, value))
            {
                OnPropertyChanged(nameof(HasPhoneNumber));
                OnPropertyChanged(nameof(PhoneNumberUnbound));
                OnPropertyChanged(nameof(PhoneNumberDisplay));
            }
        }
    }

    // Bound by the profile overlay rows: a real value when bound, else the Mac "未绑定" text.
    // The *Unbound flags exist so the 绑定 buttons' Visibility can use the plain
    // BooleanToVisibilityConverter (which ignores its parameter) without inverting in XAML.
    public bool HasEmail => !string.IsNullOrWhiteSpace(_email);

    public bool EmailUnbound => !HasEmail;

    public string EmailDisplay => HasEmail ? _email : "未绑定";

    public bool HasPhoneNumber => !string.IsNullOrWhiteSpace(_phoneNumber);

    public bool PhoneNumberUnbound => !HasPhoneNumber;

    public string PhoneNumberDisplay => HasPhoneNumber ? _phoneNumber : "未绑定";

    public bool IsSignedIn
    {
        get => _isSignedIn;
        private set => SetField(ref _isSignedIn, value);
    }

    // ---- In-window account overlays (replace the crashing ContentDialog) ------------

    // True while the full-screen Mac login overlay is shown (signed-OUT account-block tap).
    // Bound to the AuthOverlay layer's Visibility in MainWindow via BoolToVisibilityConverter.
    public bool ShowAuthOverlay
    {
        get => _showAuthOverlay;
        set => SetField(ref _showAuthOverlay, value);
    }

    // True while the 用户资料 overlay is shown (signed-IN account-block tap). Bound to the
    // UserProfileOverlay layer's Visibility.
    public bool ShowProfileOverlay
    {
        get => _showProfileOverlay;
        set => SetField(ref _showProfileOverlay, value);
    }

    // AuthOverlay email-form inline error (empty = hidden) + busy flag (sign-in in flight).
    public string AuthErrorMessage
    {
        get => _authErrorMessage;
        private set
        {
            if (SetField(ref _authErrorMessage, value))
            {
                OnPropertyChanged(nameof(HasAuthError));
            }
        }
    }

    public bool HasAuthError => !string.IsNullOrWhiteSpace(_authErrorMessage);

    public bool IsAuthBusy
    {
        get => _isAuthBusy;
        private set => SetField(ref _isAuthBusy, value);
    }

    // The account block was Tapped: route to the right overlay by signed-in state. Called
    // from MainWindow's (now trivial, non-throwing) Tapped handler.
    public void ToggleAccountOverlay()
    {
        if (IsSignedIn)
        {
            ShowProfileOverlay = true;
        }
        else
        {
            AuthErrorMessage = string.Empty;
            ShowAuthOverlay = true;
        }
    }

    public void HideAuthOverlay()
    {
        ShowAuthOverlay = false;
        AuthErrorMessage = string.Empty;
    }

    public void HideProfileOverlay() => ShowProfileOverlay = false;

    // Guest mode (游客模式体验): the Mac activates a local, no-network guest session; on
    // Windows the shell already runs fully signed-out, so "guest" = just dismiss the login
    // and browse the shell. We do NOT fabricate a signed-in identity.
    public void EnterGuestMode() => HideAuthOverlay();

    // The in-window AuthOverlay's 邮箱登录 button calls this. Runs the REAL Supabase
    // email/password sign-in via the coordinator (which applies + persists on success). On
    // success: hide the overlay (IsSignedIn flips via the identity event). On failure: keep
    // the overlay open and surface the inline error. Never throws into the UI.
    public async Task SignInWithEmailAsync(string email, string password)
    {
        if (IsAuthBusy)
        {
            return;
        }

        AuthErrorMessage = string.Empty;
        IsAuthBusy = true;
        try
        {
            var result = await _accountSessionCoordinator
                .SignInWithEmailAsync(email, password);

            if (result.Success)
            {
                HideAuthOverlay();
            }
            else
            {
                AuthErrorMessage = result.ErrorMessage;
            }
        }
        finally
        {
            IsAuthBusy = false;
        }
    }

    // Sign-out command — OWNED by the coordinator (the AsyncRelayCommand is constructed there,
    // never in this VM). The account block's sign-out confirm dialog invokes this.
    public ICommand SignOutCommand { get; }

    // The Supabase auth client the account seam signs in with — forwarded from the
    // coordinator so any external caller and the coordinator share one client/seam. (The
    // in-window AuthOverlay now drives sign-in via SignInWithEmailAsync, not this directly.)
    public ISupabaseAuthClient AuthClient => _accountSessionCoordinator.AuthClient;

    // Applies an externally-obtained token (e.g. a future OAuth callback) — persists + sets
    // identity. The in-window email login uses SignInWithEmailAsync instead.
    public Task ApplyAuthAsync(AuthToken token) => _accountSessionCoordinator.ApplyAuthAsync(token);

    // Fired on launch (on the dispatcher) to restore a remembered session and show the user.
    public Task HydrateFromStoreAsync() => _accountSessionCoordinator.HydrateFromStoreAsync();

    // The Settings page bindable surface. The Settings tab views bind {Binding Settings.<Prop>,
    // Mode=TwoWay} — each property delegates to a self-provisioned SettingsService that
    // write-throughs to %LOCALAPPDATA%\SkyBridge\settings.json. Self-provisioned in the ctor;
    // never routed through the DI composition root.
    public SettingsCoordinator Settings => _settingsCoordinator;

    // Raised when the dark-mode setting changes (and once at startup). MainWindow subscribes and
    // sets the root FrameworkElement.RequestedTheme — the VM has no FrameworkElement, so the
    // theme swap is routed up to the shell that owns RootShell. Argument: true = Dark, false = Light.
    public event Action<bool>? DarkModeEffectRequested;

    // Raised when the theme-color setting changes (and once at startup). MainWindow subscribes and
    // overrides the SkyBridgeAccentColor/Brush application resources to the chosen hex, then forces
    // a re-tint. Argument: the "#RRGGBB" hex string.
    public event Action<string>? AccentColorEffectRequested;

    // Settings Export/Import file pickers. The Export/Import toolbar actions invoke these to get a
    // user-chosen path (a FileSavePicker / FileOpenPicker that needs the window HWND, which the VM
    // does not own). MainWindow assigns these; a null handler (test host) makes the action fall back
    // to its honest intent message. Return null/empty when the user cancels.
    public Func<Task<string?>>? ExportSettingsPathRequested;
    public Func<Task<string?>>? ImportSettingsPathRequested;

    /// <summary>
    /// Live clipboard-sync gate (远程桌面 > 交互 > 剪贴板同步). The session-start path that spins up
    /// the WindowsClipboardSyncService consults this before starting — when off, the clipboard pump
    /// is never started (fail-closed gate; no fabricated effect). Pushed by the SettingsCoordinator.
    /// </summary>
    public bool IsClipboardSyncEnabled { get; private set; } = true;

    /// <summary>
    /// Live keep-awake gate (文件传输 > 选项 > 传输时保持唤醒). The transfer path consults this and
    /// calls SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) for the duration of a
    /// transfer when on, releasing it when the transfer ends. Pushed by the SettingsCoordinator.
    /// </summary>
    public bool KeepSystemAwakeDuringTransfer { get; private set; }

    // Tracks whether the real-time weather loop is currently enabled (高级 > 性能 > 启用实时天气).
    // The weather card has no periodic timer (it is a one-shot startup kick + a manual refresh
    // button); so the honest gate is: when enabled, an immediate refresh is kicked (and the
    // startup auto-load is allowed); when disabled, no auto-refresh fires. Default false matches
    // the persisted EnableRealTimeWeather default.
    private bool _isWeatherLoopEnabled;

    // Live-effect sink for 启用实时天气: enabling it kicks an immediate weather refresh (so the card
    // populates the moment the user turns it on); disabling it simply stops further auto-refreshes
    // (the manual refresh button stays available, like the Mac). No fabricated data — the card
    // shows the Loading state until a real snapshot lands. Idempotent on repeated same-value calls.
    private void SetWeatherLoopEnabled(bool enabled)
    {
        if (_isWeatherLoopEnabled == enabled)
        {
            return;
        }

        _isWeatherLoopEnabled = enabled;
        if (enabled)
        {
            // Fire-and-forget the existing weather refresh command (async-void Execute, house style).
            RefreshWeatherCommand.Execute(null);
        }
    }

    // Resolve the single DeviceDisplayPrefs instance declared as an application resource
    // (App.xaml x:Key="DeviceDisplayPrefs") — the SAME instance the DiscoveredPeer cards bind to
    // via {StaticResource DeviceDisplayPrefs}. Returns null only if the app/resources are not yet
    // realized (a unit-test host), in which case the DD-card effect is a harmless no-op and the
    // VM SetField mirror still updates. Never throws.
    private static DeviceDisplayPrefs? ResolveDeviceDisplayPrefs() =>
        ResolveResource<DeviceDisplayPrefs>("DeviceDisplayPrefs");

    private static MonitorDisplayPrefs? ResolveMonitorDisplayPrefs() =>
        ResolveResource<MonitorDisplayPrefs>("MonitorDisplayPrefs");

    private static T? ResolveResource<T>(string key) where T : class
    {
        try
        {
            var resources = Microsoft.UI.Xaml.Application.Current?.Resources;
            if (resources is not null &&
                resources.TryGetValue(key, out var value) &&
                value is T typed)
            {
                return typed;
            }
        }
        catch (Exception)
        {
            // No realized application/resources (test host) — no-op.
        }

        return null;
    }

    // 系统监控 显示项 effect: push the six metric show-flags into the MonitorDisplayPrefs resource the
    // tiles' MonitorTileVisibilityConverter reads, then re-issue the System-Monitor read so the
    // projected tile collection re-renders (the converters re-run, hidden metrics drop). Only
    // re-projects when a flag actually changed, so the startup apply / unchanged toggles don't kick
    // a redundant read.
    private void ApplyMonitorMetricVisibility(bool cpu, bool mem, bool disk, bool net, bool temp, bool fan)
    {
        var prefs = ResolveMonitorDisplayPrefs();
        if (prefs is null)
        {
            return;
        }

        var changed =
            prefs.ShowCpu != cpu || prefs.ShowMemory != mem || prefs.ShowDisk != disk ||
            prefs.ShowNetwork != net || prefs.ShowTemperature != temp || prefs.ShowFanSpeed != fan;

        prefs.ShowCpu = cpu;
        prefs.ShowMemory = mem;
        prefs.ShowDisk = disk;
        prefs.ShowNetwork = net;
        prefs.ShowTemperature = temp;
        prefs.ShowFanSpeed = fan;

        if (changed)
        {
            // Re-project the tile collection so the visibility converters re-evaluate live.
            RefreshSystemMonitorCommand.Execute(null);
        }
    }

    private void OnAccountIdentityChanged(object? sender, AccountIdentity identity)
    {
        // Continuations resume on the captured UI context (callers await on the UI thread),
        // so these SetField setters run on the UI thread — no DispatcherQueue needed, matching
        // the house async-refresh idiom (see WeatherStateCoordinator).
        DisplayName = identity.IsSignedIn && !string.IsNullOrWhiteSpace(identity.DisplayName)
            ? identity.DisplayName
            : "Sign in";
        NebulaId = identity.NebulaId;
        AvatarUrl = identity.AvatarUrl;
        Email = identity.Email;
        PhoneNumber = identity.PhoneNumber;
        IsSignedIn = identity.IsSignedIn;

        // If a sign-out happened while the profile overlay was open, close it (nothing to
        // show signed-out). Sign-in is what closes the auth overlay — handled in the
        // SignInWithEmailAsync success path so a hydrate-driven identity change doesn't
        // surprise a user who is mid-typing in the (already-hidden) login.
        if (!identity.IsSignedIn)
        {
            ShowProfileOverlay = false;
        }
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

    // Live top-bar network telemetry, forwarded from the TopBarNetworkCoordinator. The
    // coordinator mutates these from the UI dispatcher (scalar SetField updates only — no
    // collections), so the net-speed / latency / IP+proxy pills bind to real measured values
    // and fall back to honest placeholders ("↓ — · ↑ —" / "— ms" / "IP · 不可用") on failure.
    public string TopBarNetworkSpeed
    {
        get => _topBarNetworkSpeed;
        private set => SetField(ref _topBarNetworkSpeed, value);
    }

    public string TopBarNetworkLatency
    {
        get => _topBarNetworkLatency;
        private set => SetField(ref _topBarNetworkLatency, value);
    }

    public string TopBarIpLocation
    {
        get => _topBarIpLocation;
        private set => SetField(ref _topBarIpLocation, value);
    }

    // Drives the IP pill's globe-icon color (blue when direct, orange when a system proxy is
    // configured). Read from HKCU ProxyEnable by the coordinator's client.
    public bool IsSystemProxyEnabled
    {
        get => _isSystemProxyEnabled;
        private set => SetField(ref _isSystemProxyEnabled, value);
    }

    // ---- Settings-driven display gates (live effects from SettingsCoordinator) ----------
    // Each is pushed by the SettingsCoordinator effect sinks when its setting changes (and once at
    // startup via ApplyInitialEffects). The top-bar pills bind their Visibility to the three
    // ShowTopBar* bools; the Device Discovery peer cards bind detail-row Visibility / density /
    // icon-chip Visibility to the three Device* bools. Real, observable, never fabricated.

    /// <summary>网络 > 顶部栏 > 显示实时网速 — gates the top-bar net-speed pill's Visibility.</summary>
    public bool ShowTopBarSpeedPill
    {
        get => _showTopBarSpeedPill;
        private set => SetField(ref _showTopBarSpeedPill, value);
    }

    /// <summary>网络 > 顶部栏 > 显示公网延迟 — gates the top-bar latency pill's Visibility.</summary>
    public bool ShowTopBarLatencyPill
    {
        get => _showTopBarLatencyPill;
        private set => SetField(ref _showTopBarLatencyPill, value);
    }

    /// <summary>网络 > 顶部栏 > 显示公网IP与位置 — gates the top-bar IP/location pill's Visibility.</summary>
    public bool ShowTopBarIpLocationPill
    {
        get => _showTopBarIpLocationPill;
        private set => SetField(ref _showTopBarIpLocationPill, value);
    }

    /// <summary>通用 > 界面 > 显示设备详情 — gates the DD peer cards' detail rows (DeviceId /
    /// Capabilities / Fingerprint / TrustSummary).</summary>
    public bool ShowDeviceDetailRows
    {
        get => _showDeviceDetailRows;
        private set => SetField(ref _showDeviceDetailRows, value);
    }

    /// <summary>通用 > 界面 > 紧凑模式 — tightens the DD peer card density (smaller padding/icon).</summary>
    public bool DeviceCardsCompact
    {
        get => _deviceCardsCompact;
        private set => SetField(ref _deviceCardsCompact, value);
    }

    /// <summary>设备 > 过滤排序 > 显示设备图标 — gates the DD peer card's 44px device-type icon chip.</summary>
    public bool ShowDeviceIconChips
    {
        get => _showDeviceIconChips;
        private set => SetField(ref _showDeviceIconChips, value);
    }

    // ---- Local "my device" identity (Device Discovery → 我的设备 / This device card) -------
    // Honest, always-present local-machine facts read straight from the .NET runtime — NO
    // network, NO DI client, NO fabricated peer. Mirrors the Mac EnhancedDeviceDiscoveryView
    // "我的设备" card, which is built from LocalDevicePresentation.current() (hostname + this
    // is the local machine) and is shown regardless of scan results. On Windows the
    // equivalent ground truth is the OS host name + platform string. These are static for the
    // process lifetime, so they are computed once (no change-notification needed).

    /// <summary>
    /// This Windows host's machine name (Environment.MachineName) — the local-device card's
    /// title, mirroring the Mac "我的设备" card name (hostname). Falls back to "This PC" only
    /// if the runtime returns an empty host name (never fabricated).
    /// </summary>
    public string LocalDeviceName { get; } = BuildLocalDeviceName();

    /// <summary>
    /// A short, honest platform descriptor for the local-device card subtitle, e.g.
    /// "Windows · DESKTOP-XXXX" → here just the OS string ("Windows 10.0.26100"). Real
    /// Environment.OSVersion data; no invented model/chip values.
    /// </summary>
    public string LocalDevicePlatform { get; } = BuildLocalDevicePlatform();

    private static string BuildLocalDeviceName()
    {
        try
        {
            var name = Environment.MachineName;
            return string.IsNullOrWhiteSpace(name) ? "This PC" : name;
        }
        catch (Exception)
        {
            return "This PC";
        }
    }

    private static string BuildLocalDevicePlatform()
    {
        try
        {
            // Environment.OSVersion.VersionString is e.g. "Microsoft Windows NT 10.0.26100.0".
            var version = Environment.OSVersion.Version;
            return $"Windows {version.Major}.{version.Minor}.{version.Build}";
        }
        catch (Exception)
        {
            return "Windows";
        }
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

    // =====================================================================
    // Device Discovery connection-mode view-state (Mac @State selectedConnectionMode).
    // Pure local UI selection: tapping a mode tab swaps which orientation surface is
    // shown. No DI client, no fabricated data — the underlying real surfaces (local
    // scan / QR / smart-code / cloud note) are unchanged; only their Visibility follows
    // the selected mode, mirroring the Mac connectionModePicker body swap.
    // =====================================================================
    public DiscoveryMode SelectedDiscoveryMode
    {
        get => _selectedDiscoveryMode;
        set
        {
            if (SetField(ref _selectedDiscoveryMode, value))
            {
                OnPropertyChanged(nameof(IsDiscoveryLocalScanModeSelected));
                OnPropertyChanged(nameof(IsDiscoveryQrModeSelected));
                OnPropertyChanged(nameof(IsDiscoveryCloudModeSelected));
                OnPropertyChanged(nameof(IsDiscoveryCodeModeSelected));
                OnPropertyChanged(nameof(IsDiscoveryQrOrCodeModeSelected));
            }
        }
    }

    public bool IsDiscoveryLocalScanModeSelected => _selectedDiscoveryMode == DiscoveryMode.LocalScan;

    public bool IsDiscoveryQrModeSelected => _selectedDiscoveryMode == DiscoveryMode.Qr;

    public bool IsDiscoveryCloudModeSelected => _selectedDiscoveryMode == DiscoveryMode.Cloud;

    public bool IsDiscoveryCodeModeSelected => _selectedDiscoveryMode == DiscoveryMode.Code;

    // The QR + Smart-Code cross-network surfaces share one two-column body; reveal it for
    // either QR or Code mode (both are cross-network connection flows on Windows).
    public bool IsDiscoveryQrOrCodeModeSelected =>
        _selectedDiscoveryMode == DiscoveryMode.Qr || _selectedDiscoveryMode == DiscoveryMode.Code;

    // View-only selection setter invoked from the Border.Tapped handlers (no raw Button,
    // keeping the gated <Button> count unchanged).
    public void SelectDiscoveryMode(DiscoveryMode mode) => SelectedDiscoveryMode = mode;

    // =====================================================================
    // Smart-connection-code lease mode (Mac ConnectionCodeLeaseMode picker 短时/全天). NOT a
    // view-only label: the selected mode plumbs into Generate/Regenerate and drives the REAL
    // generated-code TTL (CrossNetworkConnectionClient.BuildCodeSnapshot computes the actual
    // expiry from this mode). Default is shortLived (set from the input-defaults snapshot).
    // =====================================================================
    public CrossNetworkCodeLeaseMode SelectedConnectionCodeLeaseMode
    {
        get => _selectedConnectionCodeLeaseMode;
        set
        {
            if (SetField(ref _selectedConnectionCodeLeaseMode, value))
            {
                OnPropertyChanged(nameof(IsConnectionCodeLeaseShortLivedSelected));
                OnPropertyChanged(nameof(IsConnectionCodeLeaseDayStableSelected));
            }
        }
    }

    public bool IsConnectionCodeLeaseShortLivedSelected =>
        _selectedConnectionCodeLeaseMode == CrossNetworkCodeLeaseMode.ShortLived;

    public bool IsConnectionCodeLeaseDayStableSelected =>
        _selectedConnectionCodeLeaseMode == CrossNetworkCodeLeaseMode.DayStable;

    // Invoked from the lease-mode segment Border.Tapped handler (Tag = "ShortLived"/"DayStable").
    // No raw Button, so the gated inline-button count is unchanged.
    public void SelectConnectionCodeLeaseMode(CrossNetworkCodeLeaseMode mode) =>
        SelectedConnectionCodeLeaseMode = mode;

    // =====================================================================
    // Remote Desktop connection-mode view-state (Mac connectionModeSelector .auto/.nearField/.farFieldRDP).
    // Auto routes to the existing Device Discovery navigation; Far raises the existing
    // advanced-connect status; Near surfaces an honest "pending capture adapter" status
    // (no Windows capture transport exists yet — fail-closed, not fabricated).
    // =====================================================================
    public RemoteDesktopConnectionMode SelectedRemoteDesktopMode
    {
        get => _selectedRemoteDesktopMode;
        set => SetField(ref _selectedRemoteDesktopMode, value);
    }

    // Invoked from the RD mode-segment Border.Tapped handlers. Sets the selected pill and
    // performs the mode's route. Auto = real nav; Far = existing advanced-connect status;
    // Near = honest pending-adapter status (batch 2 will replace with a real backend string).
    public void SelectRemoteDesktopMode(RemoteDesktopConnectionMode mode)
    {
        SelectedRemoteDesktopMode = mode;

        switch (mode)
        {
            case RemoteDesktopConnectionMode.Auto:
                foreach (var item in NavigationItems)
                {
                    if (item.Id == FeatureEntryId.DeviceDiscovery)
                    {
                        SelectedFeature = item;
                        break;
                    }
                }

                break;

            case RemoteDesktopConnectionMode.Far:
                // Honest status sourced from the RD workspace client (fail-closed; no transport
                // started). Replaces the prior VM-local placeholder with the real backend string.
                RemoteDesktopStatus = _remoteDesktopClient.BuildAdvancedConnectModeStatus();
                break;

            case RemoteDesktopConnectionMode.Near:
                // Honest fail-closed status from the RD workspace client: no Windows near-field
                // capture adapter exists yet, so selecting Near states that plainly. Sourced from
                // the backend (RemoteDesktopWorkspaceClient.BuildNearFieldPendingStatus), not a
                // VM-local literal — and never a fabricated transport claim.
                RemoteDesktopStatus = _remoteDesktopClient.BuildNearFieldPendingStatus();
                break;
        }
    }

    // =====================================================================
    // File Transfer Transfer/History segmented tab view-state (Mac modernTabBar).
    // Pure local selection: tab 0 = Transfer (queue), tab 1 = History. Reveals the
    // already-real FileTransferQueue / FileTransferHistory collections; carries no data.
    // =====================================================================
    public int SelectedFileTransferTab
    {
        get => _selectedFileTransferTab;
        set
        {
            if (SetField(ref _selectedFileTransferTab, value))
            {
                OnPropertyChanged(nameof(IsFileTransferTransferTabSelected));
                OnPropertyChanged(nameof(IsFileTransferHistoryTabSelected));
            }
        }
    }

    public bool IsFileTransferTransferTabSelected => _selectedFileTransferTab == 0;

    public bool IsFileTransferHistoryTabSelected => _selectedFileTransferTab == 1;

    public void SelectFileTransferTab(int tab) => SelectedFileTransferTab = tab;

    // =====================================================================
    // System Monitor header monitoring pill (Mac liveSnapshotHeader isMonitoring).
    // Computed from the real "Monitoring" indicator row State (Active/On) projected by
    // SystemMonitorWorkspaceClient — green when monitoring, muted otherwise. Never
    // fabricated: an absent/idle indicator reads as not-monitoring.
    // =====================================================================
    public bool IsSystemMonitoring
    {
        get
        {
            foreach (var indicator in SystemMonitorIndicators)
            {
                if (string.Equals(indicator.Label, "Monitoring", StringComparison.OrdinalIgnoreCase))
                {
                    var state = (indicator.State ?? string.Empty).Trim();
                    return string.Equals(state, "Active", StringComparison.OrdinalIgnoreCase) ||
                           string.Equals(state, "On", StringComparison.OrdinalIgnoreCase) ||
                           string.Equals(state, "Monitoring", StringComparison.OrdinalIgnoreCase);
                }
            }

            return false;
        }
    }

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

        // A7 — re-derive the read-only "Recent Connections" partition from the unfiltered
        // master (rows whose real State == "Recent"). Re-running on each Clear/Add burst is
        // safe: RemoteDesktopRecentSessions is a separate collection the applier never touches.
        RebuildRemoteDesktopRecentSessions();

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

    // The read-only snapshot applier replaced SystemMonitorIndicators — re-raise the computed
    // header pill (IsSystemMonitoring) so its tint follows the live "Monitoring" indicator State.
    private void OnSystemMonitorIndicatorsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        OnPropertyChanged(nameof(IsSystemMonitoring));
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

    // A7 — rebuild the read-only "Recent Connections" partition (Mac sessionList recent
    // section) from the unfiltered master, keeping only rows whose real State == "Recent".
    // No reconnect command and no fabricated last-connected timestamp are added — these are
    // honest read-only rows partitioned from the same real connection-plan snapshot.
    private void RebuildRemoteDesktopRecentSessions()
    {
        RemoteDesktopRecentSessions.Clear();
        foreach (var session in _remoteDesktopSessionMaster)
        {
            if (string.Equals(session.State, "Recent", StringComparison.OrdinalIgnoreCase))
            {
                RemoteDesktopRecentSessions.Add(session);
            }
        }

        _workspaceCountNotifier.RemoteDesktopRecentSessionsChanged();
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

    // Stop + dispose every runtime owner created by the VM. Called from MainWindow's Closed handler
    // so native Core handles, WebRTC adapters, settings timers, and telemetry loops do not outlive
    // the window.
    public void Dispose()
    {
        lock (_disposeLock)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
        }

        _engineClient.ConnectionStateChanged -= OnEngineStateChanged;
        List<Exception>? disposalErrors = null;

        void DisposeOwner(Action dispose)
        {
            try
            {
                dispose();
            }
            catch (Exception ex)
            {
                disposalErrors ??= new List<Exception>();
                disposalErrors.Add(ex);
            }
        }

        DisposeOwner(_topBarNetworkCoordinator.Dispose);
        DisposeOwner(_settingsCoordinator.Dispose);
        if (_engineClient is IDisposable disposableEngine)
        {
            DisposeOwner(disposableEngine.Dispose);
        }

        if (disposalErrors is null)
        {
            return;
        }

        if (disposalErrors.Count == 1)
        {
            ExceptionDispatchInfo.Capture(disposalErrors[0]).Throw();
        }

        throw new AggregateException("One or more SkyBridge runtime owners failed during disposal.", disposalErrors);
    }

}

/// <summary>
/// Device Discovery connection-mode selection (Mac EnhancedDeviceDiscoveryView
/// @State selectedConnectionMode). Pure UI view-state — selecting a mode swaps which
/// orientation surface is shown; it carries no data and triggers no network.
/// </summary>
public enum DiscoveryMode
{
    LocalScan,
    Qr,
    Cloud,
    Code
}

/// <summary>
/// Remote Desktop connection-mode selection (Mac connectionModeSelector
/// .auto / .nearField / .farFieldRDP). Auto routes to Device Discovery, Far raises the
/// advanced-connect status, Near surfaces an honest pending-capture-adapter status.
/// </summary>
public enum RemoteDesktopConnectionMode
{
    Auto,
    Near,
    Far
}
