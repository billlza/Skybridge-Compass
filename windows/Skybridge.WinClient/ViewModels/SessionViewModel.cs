using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using System.Windows.Input;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

public enum BitrateProfile
{
    Low,
    Medium,
    High
}

public enum FramerateProfile
{
    Fps30,
    Fps60
}

public sealed class SessionViewModel : INotifyPropertyChanged
{
    private const string SampleFingerprint =
        "f50924465c15480c8d06de12140f20c69bd2312eeec840c5372f7ce32ffd4009";

    private const string SamplePairingPublicKey =
        "c2FtcGxlLXBlZXItcHVibGljLWtleQ==";

    private readonly IEngineClient _engineClient;
    private readonly IDiscoveryClient _discoveryClient;
    private readonly IPairingMaterialClient _pairingMaterialClient;
    private readonly ICoreDiagnosticsClient _coreDiagnosticsClient;
    private readonly IFileTransferWorkspaceClient _fileTransferClient;
    private readonly IRemoteDesktopWorkspaceClient _remoteDesktopClient;
    private readonly ISystemMonitorWorkspaceClient _systemMonitorClient;
    private readonly IUsbManagementWorkspaceClient _usbManagementClient;
    private readonly ISettingsWorkspaceClient _settingsClient;
    private string _statusMessage = "Idle";
    private string _discoveryService = "_skybridge._udp";
    private string _discoveryTxtRecord =
        $"deviceId=mac-1;pubKeyFP={SampleFingerprint};platform=macOS;capabilities=webrtc,tcp;name=Desk Mac;version=v1";
    private string _pairingConnectionCode =
        $"skybridge-pair:v1;deviceId=mac-1;pubKey={SamplePairingPublicKey};pubKeyFP={SampleFingerprint};platform=macOS;name=Desk%20Mac;version=v1";
    private string _discoveryStatus = "Ready";
    private string _pairingStatus = "Ready";
    private string _coreDiagnosticsStatus = "Ready";
    private string _fileTransferStatus = "Ready";
    private string _remoteDesktopStatus = "Ready";
    private string _systemMonitorStatus = "Ready";
    private string _usbManagementStatus = "Ready";
    private string _settingsStatus = "Ready";
    private BitrateProfile _selectedBitrate = BitrateProfile.Medium;
    private FramerateProfile _selectedFramerate = FramerateProfile.Fps60;
    private EngineConnectionState _connectionState;
    private FeatureEntry _selectedFeature;
    private bool _isBusy;

    public SessionViewModel(
        IEngineClient engineClient,
        IDiscoveryClient? discoveryClient = null,
        IPairingMaterialClient? pairingMaterialClient = null,
        ICoreDiagnosticsClient? coreDiagnosticsClient = null,
        IFileTransferWorkspaceClient? fileTransferClient = null,
        IRemoteDesktopWorkspaceClient? remoteDesktopClient = null,
        ISystemMonitorWorkspaceClient? systemMonitorClient = null,
        IUsbManagementWorkspaceClient? usbManagementClient = null,
        ISettingsWorkspaceClient? settingsClient = null)
    {
        _engineClient = engineClient;
        _discoveryClient = discoveryClient ?? new UnavailableDiscoveryClient();
        _pairingMaterialClient = pairingMaterialClient ?? new UnavailablePairingMaterialClient();
        _coreDiagnosticsClient = coreDiagnosticsClient ?? new UnavailableCoreDiagnosticsClient();
        _fileTransferClient = fileTransferClient ?? new UnavailableFileTransferWorkspaceClient();
        _remoteDesktopClient = remoteDesktopClient ?? new UnavailableRemoteDesktopWorkspaceClient();
        _systemMonitorClient = systemMonitorClient ?? new UnavailableSystemMonitorWorkspaceClient();
        _usbManagementClient = usbManagementClient ?? new UnavailableUsbManagementWorkspaceClient();
        _settingsClient = settingsClient ?? new UnavailableSettingsWorkspaceClient();
        _connectionState = _engineClient.State;
        NavigationItems = new ObservableCollection<FeatureEntry>(FeatureEntryContract.Entries);
        _selectedFeature = NavigationItems[0];
        DiscoveredPeers = new ObservableCollection<DiscoveredPeerView>();
        PairingFacts = new ObservableCollection<PairingFactView>();
        CoreDiagnosticFacts = new ObservableCollection<CoreDiagnosticFactView>();
        FileTransferQueue = new ObservableCollection<FileTransferQueueItemView>();
        FileTransferHistory = new ObservableCollection<FileTransferHistoryItemView>();
        FileTransferSecurityFacts = new ObservableCollection<FileTransferSecurityFactView>();
        RemoteDesktopSessions = new ObservableCollection<RemoteDesktopSessionItemView>();
        RemoteDesktopControlFacts = new ObservableCollection<RemoteDesktopControlFactView>();
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
        ParseAdvertisementCommand = new AsyncRelayCommand(ParseAdvertisementAsync, CanParseAdvertisement);
        ValidatePairingCodeCommand = new AsyncRelayCommand(ValidatePairingCodeAsync, CanValidatePairingCode);
        RunCoreDiagnosticsCommand = new AsyncRelayCommand(RunCoreDiagnosticsAsync, CanRunCoreDiagnostics);
        RefreshFileTransferCommand = new AsyncRelayCommand(RefreshFileTransferAsync, CanRefreshFileTransfer);
        RefreshRemoteDesktopCommand = new AsyncRelayCommand(RefreshRemoteDesktopAsync, CanRefreshRemoteDesktop);
        RefreshSystemMonitorCommand = new AsyncRelayCommand(RefreshSystemMonitorAsync, CanRefreshSystemMonitor);
        RefreshUsbManagementCommand = new AsyncRelayCommand(RefreshUsbManagementAsync, CanRefreshUsbManagement);
        RefreshSettingsCommand = new AsyncRelayCommand(RefreshSettingsAsync, CanRefreshSettings);
        BitrateProfiles = new ObservableCollection<BitrateProfile>((BitrateProfile[])Enum.GetValues(typeof(BitrateProfile)));
        FramerateProfiles = new ObservableCollection<FramerateProfile>((FramerateProfile[])Enum.GetValues(typeof(FramerateProfile)));
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<FeatureEntry> NavigationItems { get; }

    public ObservableCollection<BitrateProfile> BitrateProfiles { get; }

    public ObservableCollection<FramerateProfile> FramerateProfiles { get; }

    public ObservableCollection<DiscoveredPeerView> DiscoveredPeers { get; }

    public ObservableCollection<PairingFactView> PairingFacts { get; }

    public ObservableCollection<CoreDiagnosticFactView> CoreDiagnosticFacts { get; }

    public ObservableCollection<FileTransferQueueItemView> FileTransferQueue { get; }

    public ObservableCollection<FileTransferHistoryItemView> FileTransferHistory { get; }

    public ObservableCollection<FileTransferSecurityFactView> FileTransferSecurityFacts { get; }

    public ObservableCollection<RemoteDesktopSessionItemView> RemoteDesktopSessions { get; }

    public ObservableCollection<RemoteDesktopControlFactView> RemoteDesktopControlFacts { get; }

    public ObservableCollection<SystemMonitorMetricView> SystemMonitorOverview { get; }

    public ObservableCollection<SystemMonitorMetricView> SystemMonitorDetails { get; }

    public ObservableCollection<SystemMonitorIndicatorView> SystemMonitorIndicators { get; }

    public ObservableCollection<UsbDeviceStatView> UsbDeviceStats { get; }

    public ObservableCollection<UsbDeviceItemView> UsbDevices { get; }

    public ObservableCollection<SettingsTabItemView> SettingsTabs { get; }

    public ObservableCollection<SettingsActionItemView> SettingsActions { get; }

    public ObservableCollection<SettingsDetailItemView> SettingsDetails { get; }

    public int OnlineDeviceCount => ConnectionState == EngineConnectionState.Connected ? 1 : 0;

    public int ActiveSessionCount => ConnectionState == EngineConnectionState.Connected ? 1 : 0;

    public int TransferTaskCount => FileTransferQueue.Count;

    public string PerformanceStatus => IsBusy ? "Busy" : "Nominal";

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
                OnPropertyChanged(nameof(OnlineDeviceCount));
                OnPropertyChanged(nameof(ActiveSessionCount));
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
                OnPropertyChanged(nameof(PerformanceStatus));
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
                RefreshCommandStates();
            }
        }
    }

    public string DiscoveryTxtRecord
    {
        get => _discoveryTxtRecord;
        set
        {
            if (SetField(ref _discoveryTxtRecord, value))
            {
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
                RefreshCommandStates();
            }
        }
    }

    public string DiscoveryStatus
    {
        get => _discoveryStatus;
        private set => SetField(ref _discoveryStatus, value);
    }

    public string PairingStatus
    {
        get => _pairingStatus;
        private set => SetField(ref _pairingStatus, value);
    }

    public int DiscoveredPeerCount => DiscoveredPeers.Count;

    public int PairingFactCount => PairingFacts.Count;

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

    public BitrateProfile SelectedBitrate
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

    public FramerateProfile SelectedFramerate
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

    public ICommand ParseAdvertisementCommand { get; }

    public ICommand ValidatePairingCodeCommand { get; }

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

    private async Task ParseAdvertisementAsync()
    {
        if (IsBusy)
        {
            return;
        }

        await RunWithBusyState(async () =>
        {
            DiscoveryStatus = "Parsing...";
            var peer = await _discoveryClient.ParseAdvertisementAsync(DiscoveryService, DiscoveryTxtRecord);
            DiscoveredPeers.Clear();
            DiscoveredPeers.Add(DiscoveredPeerView.FromPeer(peer));
            OnPropertyChanged(nameof(DiscoveredPeerCount));
            DiscoveryStatus = $"Validated {peer.DeviceId}";
            StatusMessage = "Discovery advertisement validated";
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
            PairingStatus = "Validating...";
            var expectedFingerprint = DiscoveredPeers.Count == 1
                ? DiscoveredPeers[0].PublicKeyFingerprint
                : null;
            var material = await _pairingMaterialClient.ParseConnectionCodeAsync(
                PairingConnectionCode,
                expectedFingerprint);
            PairingFacts.Clear();
            PairingFacts.Add(new PairingFactView("Device", material.DeviceId, $"{material.DisplayName} / {material.PlatformLabel}"));
            PairingFacts.Add(new PairingFactView("Public key fingerprint", material.PublicKeyFingerprint, "Verified against connection-code public key bytes."));
            PairingFacts.Add(new PairingFactView(
                "Discovery fingerprint",
                material.VerifiedAgainstDiscoveryFingerprint ? "matched" : "not provided",
                "Discovery pubKeyFP is verification input only; it is never used as the peer public key."));
            PairingFacts.Add(new PairingFactView("Peer key provider", "available", "Pairing material can create IPeerPublicKeyProvider for FfiEngineClient when native DLL deployment is explicit."));
            PairingFacts.Add(new PairingFactView("Source", material.Source, "Manual validation only; no connection attempt is started."));

            OnPropertyChanged(nameof(PairingFactCount));
            PairingStatus = $"Validated {material.DeviceId}";
            StatusMessage = "Pairing code validated";
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
            CoreDiagnosticsStatus = "Running...";
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
            FileTransferStatus = "Refreshing...";
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

            OnPropertyChanged(nameof(TransferTaskCount));
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
            UsbManagementStatus = "Refreshing...";
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
            RemoteDesktopStatus = "Refreshing...";
            var snapshot = await _remoteDesktopClient.BuildReadOnlySnapshotAsync(
                SelectedBitrate.ToString(),
                SelectedFramerate.ToString());
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
            SystemMonitorStatus = "Refreshing...";
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
            SettingsStatus = "Refreshing...";
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

    private bool CanParseAdvertisement() =>
        !IsBusy
        && IsDeviceDiscoverySelected
        && !string.IsNullOrWhiteSpace(DiscoveryService)
        && !string.IsNullOrWhiteSpace(DiscoveryTxtRecord);

    private bool CanValidatePairingCode() =>
        !IsBusy
        && IsDeviceDiscoverySelected
        && !string.IsNullOrWhiteSpace(PairingConnectionCode);

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
                DiscoveryStatus = ex.Message;
                PairingStatus = ex.Message;
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
        (ParseAdvertisementCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (ValidatePairingCodeCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (RefreshUsbManagementCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (RunCoreDiagnosticsCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (RefreshFileTransferCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (RefreshRemoteDesktopCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (RefreshSystemMonitorCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (RefreshSettingsCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
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

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}

public sealed record SettingsTabItemView(
    string Title,
    string Detail)
{
    public static SettingsTabItemView FromItem(SettingsTabItem item) =>
        new(item.Title, item.Detail);
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
    string Detail);

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
    public static DiscoveredPeerView FromPeer(DiscoveredPeer peer) =>
        new(
            peer.DeviceId,
            peer.DisplayName,
            peer.Platform.ToString(),
            peer.ServiceKind.ToString(),
            peer.PublicKeyFingerprint,
            FormatCapabilities(peer.Capabilities),
            peer.ProtocolVersion,
            "pubKeyFP fingerprint only; pairing must provide the peer public key.");

    private static string FormatCapabilities(PeerCapabilities capabilities)
    {
        var values = new Collection<string>();
        if (capabilities.SupportsAppleNative)
        {
            values.Add("apple-native");
        }

        if (capabilities.SupportsMsQuic)
        {
            values.Add("msquic");
        }

        if (capabilities.SupportsSkyBridgeIceMsQuic)
        {
            values.Add("ice-msquic");
        }

        if (capabilities.SupportsWebRtcDataChannel)
        {
            values.Add("webrtc");
        }

        if (capabilities.SupportsTcpFallback)
        {
            values.Add("tcp");
        }

        if (capabilities.SupportsRelay)
        {
            values.Add("relay");
        }

        return values.Count == 0 ? "none" : string.Join(", ", values);
    }
}

internal sealed class UnavailableDiscoveryClient : IDiscoveryClient
{
    public Task<DiscoveredPeer> ParseAdvertisementAsync(string service, string txtRecord)
    {
        throw new InvalidOperationException("Discovery client is not configured.");
    }
}

internal sealed class UnavailablePairingMaterialClient : IPairingMaterialClient
{
    public Task<PairingMaterial> ParseConnectionCodeAsync(
        string connectionCode,
        string? expectedPublicKeyFingerprint)
    {
        throw new InvalidOperationException("Pairing material client is not configured.");
    }
}

internal sealed class UnavailableCoreDiagnosticsClient : ICoreDiagnosticsClient
{
    public Task<CoreDiagnosticsSnapshot> BuildInteropSnapshotAsync()
    {
        throw new InvalidOperationException("Core diagnostics client is not configured.");
    }
}

internal sealed class UnavailableFileTransferWorkspaceClient : IFileTransferWorkspaceClient
{
    public Task<FileTransferWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        throw new InvalidOperationException("File transfer workspace client is not configured.");
    }
}

internal sealed class UnavailableRemoteDesktopWorkspaceClient : IRemoteDesktopWorkspaceClient
{
    public Task<RemoteDesktopWorkspaceSnapshot> BuildReadOnlySnapshotAsync(
        string bitrateProfile,
        string framerateProfile)
    {
        throw new InvalidOperationException("Remote desktop workspace client is not configured.");
    }
}

internal sealed class UnavailableSystemMonitorWorkspaceClient : ISystemMonitorWorkspaceClient
{
    public Task<SystemMonitorWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        throw new InvalidOperationException("System monitor workspace client is not configured.");
    }
}

internal sealed class UnavailableUsbManagementWorkspaceClient : IUsbManagementWorkspaceClient
{
    public Task<UsbManagementWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        throw new InvalidOperationException("USB management workspace client is not configured.");
    }
}

internal sealed class UnavailableSettingsWorkspaceClient : ISettingsWorkspaceClient
{
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
