using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.Versioning;
using System.Threading;
using System.Threading.Tasks;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.Services.RemoteControl;

namespace Skybridge.WinClient.ViewModels;

[SupportedOSPlatform("windows10.0.19041")]
public sealed class RemoteControlHostViewModel : INotifyPropertyChanged, IAsyncDisposable
{
    private readonly WindowsDeviceWorkspace _workspace;
    private readonly Func<string, string> _text;
    private readonly Func<string, Task> _copyText;
    private readonly Func<Task<string>> _readText;
    private readonly Action<Action> _dispatch;
    private bool _initialized;
    private bool _disposed;
    private bool _isEnabled;
    private bool _stopRequested;
    private int _operations;
    private string _operationErrorMessage = "";
    private string _runtimeErrorMessage = "";
    private string _actionMessage = "";
    private string _publicMaterial = "";
    private string _deviceName = "";
    private string _fingerprint = "";
    private RemoteControlPairingMaterial? _pendingController;
    private IReadOnlyList<string> _trustedNames = Array.Empty<string>();
    private readonly RemoteControlNetworkSelection _networkSelection = new();
    private WindowsRemoteControlHostStatus? _status;
    private RemoteControlHostWorkspaceStatus? _pendingStatus;
    private int _statusDispatchPending;

    internal RemoteControlHostViewModel(
        WindowsDeviceWorkspace workspace,
        Func<string, string> text,
        Func<string, Task> copyText,
        Func<Task<string>> readText,
        Action<Action> dispatch)
    {
        _workspace = workspace ?? throw new ArgumentNullException(nameof(workspace));
        _text = text ?? throw new ArgumentNullException(nameof(text));
        _copyText = copyText ?? throw new ArgumentNullException(nameof(copyText));
        _readText = readText ?? throw new ArgumentNullException(nameof(readText));
        _dispatch = dispatch ?? throw new ArgumentNullException(nameof(dispatch));
        RefreshCommand = new AsyncRelayCommand(RefreshAsync, () => !IsBusy && !IsEnabled);
        CopyPairingCommand = new AsyncRelayCommand(CopyPairingAsync, () => _initialized && !IsBusy);
        ImportPairingCommand = new AsyncRelayCommand(ImportPairingAsync, () => _initialized && !IsBusy && !IsEnabled);
        ConfirmControllerCommand = new AsyncRelayCommand(ConfirmControllerAsync, () => HasPendingController && !IsBusy && !IsEnabled);
        CancelControllerCommand = new AsyncRelayCommand(CancelControllerAsync, () => HasPendingController && !IsBusy);
        StopCommand = new AsyncRelayCommand(() => SetEnabledAsync(false), () => IsEnabled || _workspace.HasHost);
        _workspace.StatusChanged += OnStatusChanged;
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action<bool>? ConnectedNoticeChanged;
    public AsyncRelayCommand RefreshCommand { get; }
    public AsyncRelayCommand CopyPairingCommand { get; }
    public AsyncRelayCommand ImportPairingCommand { get; }
    public AsyncRelayCommand ConfirmControllerCommand { get; }
    public AsyncRelayCommand CancelControllerCommand { get; }
    public AsyncRelayCommand StopCommand { get; }
    public bool IsEnabled => _isEnabled;
    public bool IsBusy => _operations > 0;
    public bool CanChooseNetwork => _initialized && !IsBusy && !IsEnabled;
    public bool CanToggle => IsEnabled || (_initialized && !IsBusy && SelectedNetwork is not null && _trustedNames.Count > 0);
    public string DeviceName => _deviceName;
    public string Fingerprint => _fingerprint;
    public bool HasPendingController => _pendingController is not null;
    public string PendingControllerName => _pendingController?.DeviceName ?? "";
    public string PendingControllerFingerprint => _pendingController?.ProtocolPublicKeyFingerprint ?? "";
    public string ErrorMessage => _runtimeErrorMessage.Length > 0 ? _runtimeErrorMessage : _operationErrorMessage;
    public bool HasError => ErrorMessage.Length > 0;
    public string ActionMessage => _actionMessage;
    public ObservableCollection<RemoteControlNetworkInterface> NetworkInterfaces => _networkSelection.Items;
    public ObservableCollection<RemoteControlHostSessionViewModel> Sessions { get; } = [];
    public string TrustedDevicesText => _trustedNames.Count == 0
        ? _text("RemoteControlHostNoTrustedDevices")
        : string.Format(CultureInfo.CurrentCulture, _text("RemoteControlHostTrustedDevices"), _trustedNames.Count, string.Join(", ", _trustedNames));
    public string NetworkHint => NetworkInterfaces.Count == 0
        ? _text("RemoteControlHostNoNetwork")
        : NetworkInterfaces.Count > 1 && SelectedNetwork is null
            ? _text("RemoteControlHostChooseNetwork")
            : _text("RemoteControlHostNetworkHint");
    public string StatusText => _text(_status?.State switch
    {
        WindowsRemoteControlHostState.Listening => "RemoteControlHostStatusListening",
        WindowsRemoteControlHostState.Authenticating => "RemoteControlHostStatusAuthenticating",
        WindowsRemoteControlHostState.Connected => "RemoteControlHostStatusConnected",
        WindowsRemoteControlHostState.Failed => "RemoteControlHostStatusFailed",
        _ => "RemoteControlHostStatusStopped"
    });
    public string TransferSummary => _status is null ? "" : string.Format(
        CultureInfo.CurrentCulture,
        _text("RemoteControlHostTransferSummary"),
        _status.FramesSent,
        _status.AudioPacketsSent);

    public RemoteControlNetworkInterface? SelectedNetwork
    {
        get => _networkSelection.Selected;
        set
        {
            if (!_networkSelection.Select(value)) return;
            Notify();
            Notify(nameof(CanToggle));
            Notify(nameof(NetworkHint));
        }
    }

    public Task InitializeAsync() => _initialized || IsBusy ? Task.CompletedTask : RefreshAsync();

    public async Task SetEnabledAsync(bool enabled)
    {
        if (_disposed) return;
        if (enabled && (IsEnabled || !CanToggle)) return;
        if (!enabled && !IsEnabled && !_workspace.HasHost) return;
        _stopRequested = !enabled;
        await RunOperationAsync(async () =>
        {
            if (enabled)
            {
                var network = SelectedNetwork ?? throw new InvalidOperationException(_text("RemoteControlHostChooseNetwork"));
                _isEnabled = true;
                RefreshState();
                await _workspace.StartAsync(network);
            }
            else
            {
                await _workspace.StopAsync();
                _isEnabled = false;
                _status = null;
                Sessions.Clear();
                _runtimeErrorMessage = "";
                ConnectedNoticeChanged?.Invoke(false);
            }
        });
    }

    public void ReportError(Exception error)
    {
        ArgumentNullException.ThrowIfNull(error);
        _operationErrorMessage = error.Message;
        _isEnabled = _workspace.HasHost;
        WindowsRuntimeLog.Write(WindowsLogLevel.Error, "RemoteControlHost", error.Message);
        RefreshState();
    }

    public async ValueTask DisposeAsync()
    {
        _stopRequested = true;
        // Keep the status subscription until cleanup succeeds so a failed
        // shutdown remains visible and can be retried from the same window.
        await _workspace.DisposeAsync();
        _disposed = true;
        _pendingController = null;
        _workspace.StatusChanged -= OnStatusChanged;
        _isEnabled = false;
        ConnectedNoticeChanged?.Invoke(false);
        RefreshState();
    }

    private Task RefreshAsync() => RunOperationAsync(async () => Apply(await _workspace.PrepareAsync()));

    private Task CopyPairingAsync() => RunOperationAsync(async () =>
    {
        await _copyText(_publicMaterial);
        _actionMessage = _text("RemoteControlHostPairingCopied");
    });

    private Task ImportPairingAsync() => RunOperationAsync(async () =>
    {
        _pendingController = null;
        var material = await _readText();
        if (string.IsNullOrWhiteSpace(material))
        {
            throw new InvalidOperationException(_text("RemoteControlHostClipboardEmpty"));
        }

        _pendingController = RemoteControlPairingMaterial.Parse(material);
    });

    private Task ConfirmControllerAsync() => RunOperationAsync(async () =>
    {
        var material = _pendingController
            ?? throw new InvalidOperationException("There is no controller identity awaiting confirmation.");
        // Commit the exact material shown in the preview. Clipboard contents can
        // change after preview and must never replace the authority being approved.
        Apply(await _workspace.ImportTrustedPeerAsync(material));
        _pendingController = null;
        _actionMessage = _text("RemoteControlHostPairingImported");
    });

    private Task CancelControllerAsync() => RunOperationAsync(() =>
    {
        _pendingController = null;
        return Task.CompletedTask;
    });

    private async Task RunOperationAsync(Func<Task> action)
    {
        if (_disposed) return;
        _operations++;
        _operationErrorMessage = "";
        _actionMessage = "";
        RefreshState();
        try
        {
            await action();
        }
        catch (OperationCanceledException) when (_stopRequested)
        {
            _isEnabled = _workspace.HasHost;
        }
        catch (Exception error)
        {
            ReportError(error);
        }
        finally
        {
            _operations--;
            RefreshState();
        }
    }

    private void Apply(RemoteControlHostPreparation preparation)
    {
        _initialized = true;
        _publicMaterial = preparation.PublicMaterialJson;
        _deviceName = preparation.DeviceName;
        _fingerprint = preparation.Fingerprint;
        _trustedNames = preparation.TrustedDeviceNames;
        _networkSelection.Apply(preparation.NetworkInterfaces);

        RefreshState();
    }

    private void OnStatusChanged(RemoteControlHostWorkspaceStatus update)
    {
        RemoteControlHostWorkspaceStatus? previous;
        do
        {
            previous = Volatile.Read(ref _pendingStatus);
            if (previous is not null && (previous.Generation > update.Generation ||
                (previous.Generation == update.Generation && previous.Status.Revision > update.Status.Revision))) return;
        }
        while (!ReferenceEquals(Interlocked.CompareExchange(ref _pendingStatus, update, previous), previous));
        if (Interlocked.Exchange(ref _statusDispatchPending, 1) != 0) return;
        _dispatch(ApplyPendingStatus);
    }

    private void ApplyPendingStatus()
    {
        Interlocked.Exchange(ref _statusDispatchPending, 0);
        var update = Volatile.Read(ref _pendingStatus);
        if (_disposed || update is null || update.Generation != _workspace.CurrentGeneration) return;
        var status = update.Status;
        var wasConnected = HasVisibleSession(_status);
        _status = status;
        _runtimeErrorMessage = status.State == WindowsRemoteControlHostState.Failed ? status.Message : "";

        var existingRows = Sessions.ToDictionary(row => row.Id);
        WorkspaceCollectionProjector.Replace(Sessions, status.Sessions ?? Array.Empty<RemoteControlHostSessionStatus>(), session =>
        {
            if (existingRows.TryGetValue(session.Id, out var existing))
            {
                existing.Apply(session);
                return existing;
            }
            return new RemoteControlHostSessionViewModel(session, _text, () => IsBusy,
                (id, allowInput) => RunOperationAsync(() => _workspace.ApproveSessionAsync(id, allowInput)),
                id => RunOperationAsync(() => _workspace.TransferInputAsync(id)),
                id => RunOperationAsync(() => _workspace.DisconnectSessionAsync(id)));
        });
        var isConnected = HasVisibleSession(status);
        if (wasConnected != isConnected) ConnectedNoticeChanged?.Invoke(isConnected);
        Notify(nameof(StatusText));
        Notify(nameof(TransferSummary));
        Notify(nameof(ErrorMessage));
        Notify(nameof(HasError));
    }

    private static bool HasVisibleSession(WindowsRemoteControlHostStatus? status) =>
        status?.Sessions?.Any(session => session.Phase is RemoteControlHostSessionPhase.AwaitingApproval
            or RemoteControlHostSessionPhase.Preparing or RemoteControlHostSessionPhase.Viewing
            or RemoteControlHostSessionPhase.Controlling) == true;

    private void RefreshState()
    {
        // NetworkInterfaces is a stable observable collection. Rebinding its
        // ItemsSource during unrelated trust/status updates can clear selection.
        Notify(nameof(IsEnabled));
        Notify(nameof(IsBusy));
        Notify(nameof(CanChooseNetwork));
        Notify(nameof(CanToggle));
        Notify(nameof(DeviceName));
        Notify(nameof(Fingerprint));
        Notify(nameof(HasPendingController));
        Notify(nameof(PendingControllerName));
        Notify(nameof(PendingControllerFingerprint));
        Notify(nameof(ErrorMessage));
        Notify(nameof(HasError));
        Notify(nameof(ActionMessage));
        Notify(nameof(TrustedDevicesText));
        Notify(nameof(NetworkHint));
        Notify(nameof(StatusText));
        Notify(nameof(TransferSummary));
        Notify(nameof(SelectedNetwork));
        RefreshCommand.RaiseCanExecuteChanged();
        CopyPairingCommand.RaiseCanExecuteChanged();
        ImportPairingCommand.RaiseCanExecuteChanged();
        ConfirmControllerCommand.RaiseCanExecuteChanged();
        CancelControllerCommand.RaiseCanExecuteChanged();
        StopCommand.RaiseCanExecuteChanged();
        foreach (var session in Sessions) session.RefreshCommands();
    }

    private void Notify([CallerMemberName] string? property = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
}

/// <summary>Preserves the UI's collection, item and selected-route identity across fresh adapter snapshots.</summary>
internal sealed class RemoteControlNetworkSelection
{
    private bool _applyingSnapshot;
    internal ObservableCollection<RemoteControlNetworkInterface> Items { get; } = new();
    internal RemoteControlNetworkInterface? Selected { get; private set; }

    internal bool Select(RemoteControlNetworkInterface? candidate)
    {
        // Removing or replacing an item can synchronously write a temporary null
        // through ComboBox.SelectedItem's TwoWay binding. The snapshot owns that
        // transition; its final selection is published after all collection edits.
        if (_applyingSnapshot) return false;
        var selected = candidate is null ? null : Items.FirstOrDefault(item => SameRoute(item, candidate));
        if (ReferenceEquals(Selected, selected)) return false;
        Selected = selected;
        return true;
    }

    internal void Apply(IReadOnlyList<RemoteControlNetworkInterface> snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        var previousSelection = Selected;
        var existingItems = Items.ToArray();
        _applyingSnapshot = true;
        try
        {
            WorkspaceCollectionProjector.Replace(Items, snapshot,
                candidate => existingItems.FirstOrDefault(item => item == candidate) ?? candidate);
        }
        finally { _applyingSnapshot = false; }

        Selected = previousSelection is null ? null : Items.FirstOrDefault(item => SameRoute(item, previousSelection));
        if (Selected is null && Items.Count == 1) Selected = Items[0];
    }

    private static bool SameRoute(RemoteControlNetworkInterface left, RemoteControlNetworkInterface right) =>
        string.Equals(left.AdapterId, right.AdapterId, StringComparison.Ordinal) &&
        left.InterfaceIndex == right.InterfaceIndex && left.Address.Equals(right.Address);
}
