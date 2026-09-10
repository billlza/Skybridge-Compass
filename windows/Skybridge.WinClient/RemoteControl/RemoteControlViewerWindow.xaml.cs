using System.Collections.ObjectModel;
using System.Collections.Specialized;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.Services.RemoteControl;
using Skybridge.WinClient.ViewModels;
using Windows.Graphics;

namespace Skybridge.WinClient.RemoteControl;

public sealed partial class RemoteControlViewerWindow : Window
{
    private readonly WindowsDeviceWorkspace _workspace;
    private readonly ObservableCollection<DiscoveredPeerView> _sourcePeers;
    private readonly ObservableCollection<PeerChoice> _peers = [];
    private readonly Func<Task<string>> _refreshPeers;
    private readonly Func<string, string> _text;
    private readonly Func<RemoteControlViewerAccount?> _currentAccount;
    private readonly CancellationTokenSource _lifetime = new();
    private CancellationTokenSource? _connectionLifetime;
    private WindowsRemoteControlViewer? _connection;
    private Task? _connectOperation;
    private Task? _shutdownOperation;
    private Task? _stopOperation;
    private Action<RemoteControlAccess>? _accessHandler;
    private Task _observation = Task.CompletedTask;
    private string _localFingerprint = "";
    private bool _refreshing, _closing, _shutdownComplete, _peerUpdatePending;

    internal RemoteControlViewerWindow(WindowsDeviceWorkspace workspace,
        ObservableCollection<DiscoveredPeerView> peers, Func<Task<string>> refreshPeers, Func<string, string> text,
        Func<RemoteControlViewerAccount?> currentAccount, RectInt32 bounds)
    {
        _workspace = workspace;
        _sourcePeers = peers;
        _refreshPeers = refreshPeers;
        _text = text;
        _currentAccount = currentAccount;
        InitializeComponent();
        AttachInput();
        Title = text("RemoteViewerTitle");
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "SkyBridgeCompass.ico"));
        AppWindow.MoveAndResize(bounds);
        PeerPicker.ItemsSource = _peers;
        _sourcePeers.CollectionChanged += OnPeersChanged;
        AppWindow.Closing += OnClosing;
        Closed += OnClosed;
        StatusText.Text = text("RemoteViewerChoose");
    }

    private async void OnLoaded(object sender, RoutedEventArgs args)
    {
        ViewerRoot.Loaded -= OnLoaded;
        try
        {
            _localFingerprint = (await _workspace.PrepareAsync(_lifetime.Token)).Fingerprint;
            RebuildPeers();
            await RefreshAsync();
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
        catch (Exception failure) { if (!_closing) StatusText.Text = failure.Message; }
    }

    private void OnPeersChanged(object? sender, NotifyCollectionChangedEventArgs args)
    {
        if (_closing || _peerUpdatePending) return;
        _peerUpdatePending = true;
        if (!DispatcherQueue.TryEnqueue(() => { _peerUpdatePending = false; RebuildPeers(); }) && !_closing)
            throw new InvalidOperationException("The viewer could not present the updated discovery snapshot.");
    }
    private void RebuildPeers()
    {
        if (_closing || _connection is not null || _connectOperation is { IsCompleted: false }) return;
        var selected = (PeerPicker.SelectedItem as PeerChoice)?.Candidate;
        _peers.Clear();
        foreach (var peer in _sourcePeers)
        {
            if (peer.Candidate is not { Routes.RemoteDesktop: { } endpoint } candidate ||
                candidate.Peer.PublicKeyFingerprint == _localFingerprint) continue;
            if (_peers.Any(item => item.Candidate.Peer.DeviceId == candidate.Peer.DeviceId &&
                item.Candidate.Peer.PublicKeyFingerprint == candidate.Peer.PublicKeyFingerprint &&
                item.Candidate.Routes.RemoteDesktop == endpoint)) continue;
            _peers.Add(new(candidate, $"{peer.DisplayName} · {endpoint.HostName}:{endpoint.Port}"));
        }
        if (selected is not null)
            PeerPicker.SelectedItem = _peers.FirstOrDefault(item =>
                string.Equals(item.Candidate.Peer.DeviceId, selected.Peer.DeviceId, StringComparison.OrdinalIgnoreCase) &&
                item.Candidate.Peer.PublicKeyFingerprint == selected.Peer.PublicKeyFingerprint &&
                item.Candidate.Routes.RemoteDesktop == selected.Routes.RemoteDesktop);
        UpdateActions();
    }

    private async void OnRefreshClicked(object sender, RoutedEventArgs args) => await RefreshAsync();
    private async Task RefreshAsync()
    {
        if (_refreshing || _closing || _connection is not null) return;
        _refreshing = true;
        UpdateActions();
        StatusText.Text = _text("RemoteViewerScanning");
        try
        {
            var status = await _refreshPeers();
            if (!_closing)
            {
                RebuildPeers();
                StatusText.Text = status;
            }
        }
        catch (Exception failure) { if (!_closing) StatusText.Text = failure.Message; }
        finally { _refreshing = false; if (!_closing) UpdateActions(); }
    }

    private void OnPeerChanged(object sender, SelectionChangedEventArgs args) => UpdateActions();
    private async void OnConnectClicked(object sender, RoutedEventArgs args)
    {
        if (_connectOperation is { IsCompleted: false } || _connection is not null || PeerPicker.SelectedItem is not PeerChoice peer) return;
        _connectOperation = ConnectAsync(peer.Candidate);
        try { await _connectOperation; }
        catch (Exception failure) { if (!_closing) StatusText.Text = failure.Message; }
        finally { if (!_closing) { RebuildPeers(); UpdateActions(); } }
    }

    private async Task ConnectAsync(DiscoveryBrowserPeerCandidate candidate)
    {
        _connectionLifetime = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        _stopOperation = null;
        var token = _connectionLifetime.Token;
        PeerPicker.IsEnabled = false;
        ConnectButton.IsEnabled = false;
        RefreshButton.IsEnabled = false;
        StatusText.Text = _text("RemoteViewerAuthenticating");
        try
        {
            var account = _currentAccount() ?? throw new InvalidOperationException(_text("RemoteViewerSignInRequired"));
            using var authority = await _workspace.PrepareViewerAuthenticationAsync(candidate, account, token);
            var connection = await WindowsRemoteControlViewer.ConnectAsync(authority, token);
            _connection = connection;
            StartInput(connection, token);
            _accessHandler = access => OnAccessChanged(connection, access);
            connection.AccessChanged += _accessHandler;
            _observation = ObserveAsync(connection);
            StatusText.Text = _text("RemoteViewerWaitingApproval");
            _ = await connection.Ready.WaitAsync(token);
            var player = await connection.Player.WaitAsync(token);
            if (_closing || token.IsCancellationRequested || _connection != connection) return;
            VideoElement.SetMediaPlayer(player);
            player.Play();
            _presenting = true;
            InputSurface.IsEnabled = true;
            OnAccessChanged(connection, connection.Access ?? throw new InvalidOperationException("The host did not retain its approved viewing grant."));
            DisconnectButton.IsEnabled = true;
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception failure)
        {
            if (!_closing) StatusText.Text = failure.Message;
            try { await StopConnectionAsync(); }
            catch (Exception cleanup) { throw new AggregateException("Remote connection and cleanup failed.", failure, cleanup); }
        }
        finally { if (!_closing) UpdateActions(); }
    }

    private void OnAccessChanged(WindowsRemoteControlViewer owner, RemoteControlAccess access)
    {
        if (!DispatcherQueue.TryEnqueue(() =>
        {
            if (_closing || _connection != owner || _stopOperation is not null) return;
            if (_inputGrant != access) { ClearInputState(); _inputGrant = access; }
            StatusText.Text = _text(access.AllowsInput ? "RemoteViewerControlling" : "RemoteViewerObserving");
        }) && !_closing)
            throw new InvalidOperationException("The viewer window could not receive the host's input ownership update.");
    }

    private async Task ObserveAsync(WindowsRemoteControlViewer connection)
    {
        var outcome = await connection.Completion;
        if (_closing || _connection != connection) return;
        InputSurface.IsEnabled = false;
        if (outcome.CleanupFailures.Count > 0)
            StatusText.Text = new AggregateException("Remote viewing cleanup failed.", outcome.CleanupFailures).Message;
        else StatusText.Text = (_inputFailure ?? outcome.Failure)?.Message ?? _text("RemoteViewerDisconnected");
        try { await FinishConnectionAsync(connection); }
        catch (Exception failure) { if (!_closing) StatusText.Text = failure.Message; }
    }

    private async void OnDisconnectClicked(object sender, RoutedEventArgs args)
    {
        try { await StopConnectionAsync(); StatusText.Text = _text("RemoteViewerDisconnected"); }
        catch (Exception failure) { StatusText.Text = failure.Message; }
    }

    private async Task StopConnectionAsync()
    {
        _connectionLifetime?.Cancel();
        if (_connection is { } connection) await FinishConnectionAsync(connection);
        await _observation;
        _connectionLifetime?.Dispose();
        _connectionLifetime = null;
        if (!_closing) { RebuildPeers(); UpdateActions(); }
    }

    private Task FinishConnectionAsync(WindowsRemoteControlViewer connection) =>
        _stopOperation ??= FinishConnectionCoreAsync(connection);

    private async Task FinishConnectionCoreAsync(WindowsRemoteControlViewer connection)
    {
        InputSurface.IsEnabled = false;
        _presenting = false;
        _connectionLifetime?.Cancel();
        _inputs?.Writer.TryComplete();
        VideoElement.SetMediaPlayer(null);
        connection.AccessChanged -= _accessHandler;
        _accessHandler = null;
        await connection.DisposeAsync();
        await _inputPump;
        _inputs = null;
        ClearInputState();
        _connection = null;
        _connectionLifetime?.Dispose();
        _connectionLifetime = null;
        if (!_closing) { RebuildPeers(); UpdateActions(); }
    }

    private void UpdateActions()
    {
        if (_closing) return;
        var idle = _connection is null && !_refreshing && _connectOperation is not { IsCompleted: false };
        PeerPicker.IsEnabled = idle;
        RefreshButton.IsEnabled = idle;
        ConnectButton.IsEnabled = idle && PeerPicker.SelectedItem is PeerChoice;
        DisconnectButton.IsEnabled = _connection is not null;
    }

    private async void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_shutdownComplete) return;
        args.Cancel = true;
        try { await CloseForShutdownAsync(); }
        catch (Exception failure) { StatusText.Text = failure.Message; _closing = false; _shutdownOperation = null; }
    }

    internal Task CloseForShutdownAsync()
    {
        if (_shutdownOperation is not null) return _shutdownOperation;
        _closing = true;
        _shutdownOperation = CloseCoreAsync();
        return _shutdownOperation;
    }

    private async Task CloseCoreAsync()
    {
        _lifetime.Cancel();
        var failures = new List<Exception>();
        try { if (_connectOperation is { } connect) await connect; }
        catch (Exception failure) { failures.Add(failure); }
        try { await StopConnectionAsync(); }
        catch (Exception failure) { failures.Add(failure); }
        if (failures.Count > 0) throw new AggregateException("The remote viewer could not finish shutting down.", failures);
        _shutdownComplete = true;
        Close();
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        _sourcePeers.CollectionChanged -= OnPeersChanged;
        AppWindow.Closing -= OnClosing;
        Closed -= OnClosed;
        _lifetime.Dispose();
    }

    private sealed record PeerChoice(DiscoveryBrowserPeerCandidate Candidate, string Label);
}
