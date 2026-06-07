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
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    private readonly IEngineClient _engineClient;
    private readonly IDiscoveryClient _discoveryClient;
    private readonly ICoreDiagnosticsClient _coreDiagnosticsClient;
    private readonly IFileTransferWorkspaceClient _fileTransferClient;
    private string _statusMessage = "Idle";
    private string _discoveryService = "_skybridge._udp";
    private string _discoveryTxtRecord =
        $"deviceId=mac-1;pubKeyFP={SampleFingerprint};platform=macOS;capabilities=webrtc,tcp;name=Desk Mac;version=v1";
    private string _discoveryStatus = "Ready";
    private string _coreDiagnosticsStatus = "Ready";
    private string _fileTransferStatus = "Ready";
    private BitrateProfile _selectedBitrate = BitrateProfile.Medium;
    private FramerateProfile _selectedFramerate = FramerateProfile.Fps60;
    private EngineConnectionState _connectionState;
    private FeatureEntry _selectedFeature;
    private bool _isBusy;

    public SessionViewModel(
        IEngineClient engineClient,
        IDiscoveryClient? discoveryClient = null,
        ICoreDiagnosticsClient? coreDiagnosticsClient = null,
        IFileTransferWorkspaceClient? fileTransferClient = null)
    {
        _engineClient = engineClient;
        _discoveryClient = discoveryClient ?? new UnavailableDiscoveryClient();
        _coreDiagnosticsClient = coreDiagnosticsClient ?? new UnavailableCoreDiagnosticsClient();
        _fileTransferClient = fileTransferClient ?? new UnavailableFileTransferWorkspaceClient();
        _connectionState = _engineClient.State;
        NavigationItems = new ObservableCollection<FeatureEntry>(FeatureEntryContract.Entries);
        _selectedFeature = NavigationItems[0];
        DiscoveredPeers = new ObservableCollection<DiscoveredPeerView>();
        CoreDiagnosticFacts = new ObservableCollection<CoreDiagnosticFactView>();
        FileTransferQueue = new ObservableCollection<FileTransferQueueItemView>();
        FileTransferHistory = new ObservableCollection<FileTransferHistoryItemView>();
        FileTransferSecurityFacts = new ObservableCollection<FileTransferSecurityFactView>();
        _engineClient.ConnectionStateChanged += OnEngineStateChanged;
        ConnectCommand = new AsyncRelayCommand(ConnectAsync, CanConnect);
        DisconnectCommand = new AsyncRelayCommand(DisconnectAsync, CanDisconnect);
        HeartbeatCommand = new AsyncRelayCommand(SendHeartbeatAsync, CanSendHeartbeat);
        ParseAdvertisementCommand = new AsyncRelayCommand(ParseAdvertisementAsync, CanParseAdvertisement);
        RunCoreDiagnosticsCommand = new AsyncRelayCommand(RunCoreDiagnosticsAsync, CanRunCoreDiagnostics);
        RefreshFileTransferCommand = new AsyncRelayCommand(RefreshFileTransferAsync, CanRefreshFileTransfer);
        BitrateProfiles = new ObservableCollection<BitrateProfile>((BitrateProfile[])Enum.GetValues(typeof(BitrateProfile)));
        FramerateProfiles = new ObservableCollection<FramerateProfile>((FramerateProfile[])Enum.GetValues(typeof(FramerateProfile)));
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<FeatureEntry> NavigationItems { get; }

    public ObservableCollection<BitrateProfile> BitrateProfiles { get; }

    public ObservableCollection<FramerateProfile> FramerateProfiles { get; }

    public ObservableCollection<DiscoveredPeerView> DiscoveredPeers { get; }

    public ObservableCollection<CoreDiagnosticFactView> CoreDiagnosticFacts { get; }

    public ObservableCollection<FileTransferQueueItemView> FileTransferQueue { get; }

    public ObservableCollection<FileTransferHistoryItemView> FileTransferHistory { get; }

    public ObservableCollection<FileTransferSecurityFactView> FileTransferSecurityFacts { get; }

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
                OnPropertyChanged(nameof(IsFileTransferSelected));
                OnPropertyChanged(nameof(IsQuantumSelected));
                RefreshCommandStates();
            }
        }
    }

    public bool IsDeviceDiscoverySelected => SelectedFeature.Id == FeatureEntryId.DeviceDiscovery;

    public bool IsFileTransferSelected => SelectedFeature.Id == FeatureEntryId.FileTransfer;

    public bool IsQuantumSelected => SelectedFeature.Id == FeatureEntryId.Quantum;

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

    public string DiscoveryStatus
    {
        get => _discoveryStatus;
        private set => SetField(ref _discoveryStatus, value);
    }

    public int DiscoveredPeerCount => DiscoveredPeers.Count;

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

    public ICommand RunCoreDiagnosticsCommand { get; }

    public ICommand RefreshFileTransferCommand { get; }

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

    private bool CanConnect() => !IsBusy && ConnectionState == EngineConnectionState.Disconnected;

    private bool CanDisconnect() => !IsBusy && (ConnectionState == EngineConnectionState.Connected || ConnectionState == EngineConnectionState.Reconnecting);

    private bool CanSendHeartbeat() => !IsBusy && ConnectionState == EngineConnectionState.Connected;

    private bool CanParseAdvertisement() =>
        !IsBusy
        && IsDeviceDiscoverySelected
        && !string.IsNullOrWhiteSpace(DiscoveryService)
        && !string.IsNullOrWhiteSpace(DiscoveryTxtRecord);

    private bool CanRunCoreDiagnostics() => !IsBusy && IsQuantumSelected;

    private bool CanRefreshFileTransfer() => !IsBusy && IsFileTransferSelected;

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
            }

            if (IsQuantumSelected)
            {
                CoreDiagnosticsStatus = ex.Message;
            }

            if (IsFileTransferSelected)
            {
                FileTransferStatus = ex.Message;
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
        (RunCoreDiagnosticsCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (RefreshFileTransferCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
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
