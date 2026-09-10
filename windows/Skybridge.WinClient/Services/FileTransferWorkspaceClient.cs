using System.Net.Sockets;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using Skybridge.WinClient.Services.FileTransfer;
using Skybridge.WinClient.Services.RemoteControl;

namespace Skybridge.WinClient.Services;

internal interface IFileTransferSelectionClient
{
    Task<IReadOnlyList<string>> SelectPathsAsync(bool folder, CancellationToken cancellationToken);
    Task<DiscoveryBrowserPeerCandidate?> SelectPeerAsync(CancellationToken cancellationToken);
    Task<bool> ApproveIncomingAsync(ClassicFileMetadata metadata, string destinationDirectory, CancellationToken cancellationToken);
    string DestinationDirectory { get; }
}

/// <summary>Live transfer workspace. Identities and control sessions belong to WindowsDeviceWorkspace.</summary>
[SupportedOSPlatform("windows10.0.19041")]
internal sealed class FileTransferWorkspaceClient : IFileTransferWorkspaceClient, IAsyncDisposable
{
    private readonly WindowsDeviceWorkspace _workspace;
    private readonly IFileTransferSelectionClient _selection;
    private readonly Func<RemoteControlViewerAccount?> _account;
    private readonly Func<string, string> _text;
    private readonly object _state = new();
    private readonly SemaphoreSlim _outbound = new(1, 1);
    private readonly CancellationTokenSource _lifetime = new();
    private CancellationTokenSource _connectionsLifetime = new();
    private readonly Dictionary<string, FileTransferQueueItem> _active = new(StringComparer.Ordinal);
    private readonly List<FileTransferHistoryItem> _history = [];
    private readonly HashSet<string> _connected = new(StringComparer.Ordinal);
    private readonly List<Task> _observations = [];
    private readonly TransferProgress _progress;
    private ClassicFileTransferListener? _listener;
    private Task _listenerObservation = Task.CompletedTask;
    private long _lastProgress;
    private bool _disposed;
    private int _disconnecting;
    private string? _destinationDirectory;
    private string _status;

    internal FileTransferWorkspaceClient(WindowsDeviceWorkspace workspace, IFileTransferSelectionClient selection,
        Func<RemoteControlViewerAccount?> account, Func<string, string> text)
    {
        _workspace = workspace; _selection = selection; _account = account; _text = text;
        _status = text("FileTransferLiveReady");
        _progress = new(ReportProgress);
    }

    internal event Action<FileTransferWorkspaceSnapshot, string>? Changed;
    public static string DefaultInitialStatus => "Ready";
    public static string DefaultPendingStatus => "Refreshing...";
    public static string DefaultCompletedStatusMessage => "File transfer workspace updated";
    public static string DefaultSelectFilesPendingStatus => "Preparing file picker...";
    public static string DefaultSelectFolderPendingStatus => "Preparing folder picker...";
    public static string DefaultShareQrPendingStatus => "Preparing QR...";
    public static string BuildDefaultCompletedStatus(FileTransferWorkspaceSnapshot snapshot) => $"Snapshot {snapshot.CapturedAt:HH:mm:ss} UTC";
    public static FileTransferWorkspaceActionResult BuildDefaultSelectFilesActionResult() => new("Unavailable", "File picker is not configured.", "");
    public static FileTransferWorkspaceActionResult BuildDefaultSelectFolderActionResult() => new("Unavailable", "Folder picker is not configured.", "");
    public static FileTransferWorkspaceActionResult BuildDefaultShareQrActionResult() => new("Unavailable", "QR sharing is not available for the current LAN transfer session.", "");
    public string BuildInitialStatus() => _text("FileTransferLiveReady");
    public string BuildPendingStatus() => DefaultPendingStatus;
    public string BuildCompletedStatus(FileTransferWorkspaceSnapshot snapshot) { lock (_state) return _status; }
    public string BuildCompletedStatusMessage() => DefaultCompletedStatusMessage;
    public bool CanSelectFiles() => !_disposed;
    public bool CanSelectFolder() => !_disposed;
    public bool CanGenerateShareQr() => false;
    public string BuildSelectFilesPendingStatus() => DefaultSelectFilesPendingStatus;
    public string BuildSelectFolderPendingStatus() => DefaultSelectFolderPendingStatus;
    public string BuildShareQrPendingStatus() => DefaultShareQrPendingStatus;
    public Task<FileTransferWorkspaceSnapshot> BuildReadOnlySnapshotAsync() => Task.FromResult(Snapshot());
    public Task<FileTransferWorkspaceActionResult> BuildSelectFilesActionAsync() => SelectAndSendAsync(false);
    public Task<FileTransferWorkspaceActionResult> BuildSelectFolderActionAsync() => SelectAndSendAsync(true);
    public Task<FileTransferWorkspaceActionResult> BuildShareQrActionAsync() => Task.FromResult(BuildDefaultShareQrActionResult());

    internal async Task ConnectSelectedPeerAsync()
    {
        if (!await _outbound.WaitAsync(0)) throw new InvalidOperationException(_text("FileTransferLiveBusy"));
        try
        {
            var account = RequireAccount();
            var peer = await _selection.SelectPeerAsync(_lifetime.Token);
            if (peer is not null) await ConnectAsync(peer, account);
        }
        catch (Exception failure) { SetStatus(failure.Message); throw; }
        finally { _outbound.Release(); }
    }

    internal async Task DisconnectAsync()
    {
        if (Interlocked.Exchange(ref _disconnecting, 1) != 0) throw new InvalidOperationException(_text("FileTransferLiveBusy"));
        try
        {
            _connectionsLifetime.Cancel();
            await _outbound.WaitAsync();
            try
            {
                ObjectDisposedException.ThrowIf(_disposed, this);
                await _workspace.DisconnectControlSessionsAsync();
                if (_listener is { } listener) { await listener.DisposeAsync(); _listener = null; }
                await _listenerObservation;
                await Task.WhenAll(_observations);
                _observations.Clear();
                _connectionsLifetime.Dispose();
                _connectionsLifetime = new();
                SetStatus(_text("FileTransferLiveDisconnected"));
            }
            finally { _outbound.Release(); }
        }
        finally { Volatile.Write(ref _disconnecting, 0); }
    }

    internal Task<FileTransferWorkspaceActionResult> SendSelectedPathsAsync(IReadOnlyList<string> paths, bool folder) => SelectAndSendAsync(folder, paths);

    private async Task<FileTransferWorkspaceActionResult> SelectAndSendAsync(bool folder, IReadOnlyList<string>? selectedPaths = null)
    {
        if (!await _outbound.WaitAsync(0)) throw new InvalidOperationException(_text("FileTransferLiveBusy"));
        string? staging = null;
        try
        {
            var account = RequireAccount();
            var paths = selectedPaths ?? await _selection.SelectPathsAsync(folder, _lifetime.Token);
            if (paths.Count == 0) return Result("FileTransferLiveCancelled");
            if (paths.Count > 64 || (folder && paths.Count != 1) || paths.Any(string.IsNullOrWhiteSpace))
                throw new InvalidOperationException(_text("FileTransferLiveSelectionLimit"));
            var peer = await _selection.SelectPeerAsync(_lifetime.Token);
            if (peer is null) return Result("FileTransferLiveCancelled");
            var session = await ConnectAsync(peer, account);
            using var power = WindowsPowerKeepAwake.Arm();
            if (folder)
            {
                SetStatus(_text("FileTransferLivePackaging"));
                staging = Path.Combine(Path.GetTempPath(), "SkyBridgeTransfer-" + Guid.NewGuid().ToString("N"));
                paths = [await FileTransferFolderArchive.CreateAsync(paths[0], staging, _lifetime.Token)];
            }
            foreach (var path in paths) await SendFileAsync(session, peer, path);
            return Result("FileTransferLiveCompleted");
        }
        catch (Exception failure)
        {
            SetStatus(failure.Message);
            try { if (staging is not null && Directory.Exists(staging)) Directory.Delete(staging, recursive: true); staging = null; }
            catch (Exception cleanup) { throw new AggregateException("Transfer and selected-folder staging cleanup failed.", failure, cleanup); }
            throw;
        }
        finally
        {
            try { if (staging is not null) Directory.Delete(staging, recursive: true); }
            finally { _outbound.Release(); }
        }
    }

    private async Task SendFileAsync(LanProductControlSession session, DiscoveryBrowserPeerCandidate peer, string path)
    {
        var transferId = Guid.NewGuid().ToString("D");
        using var operation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token, session.Lifetime);
        var key = session.AuthorizeFileTransfer(peer, transferId);
        try
        {
            SetStatus(_text("FileTransferLiveSending"));
            await using var prepared = await ClassicFileTransferSender.PrepareAsync(path, transferId, session.LocalIdentity, key, operation.Token);
            using var client = new TcpClient();
            using var connect = CancellationTokenSource.CreateLinkedTokenSource(operation.Token);
            connect.CancelAfter(TimeSpan.FromSeconds(10));
            await client.ConnectAsync(session.RemoteAddress, peer.Routes.FileTransfer!.Port, connect.Token);
            var result = await ClassicFileTransferSender.SendAsync(client.GetStream(), prepared, key, _progress, operation.Token);
            Complete(transferId, Path.GetFileName(path), result, null);
        }
        catch (Exception failure) { Complete(transferId, Path.GetFileName(path), null, failure); throw; }
        finally { CryptographicOperations.ZeroMemory(key); }
    }

    private RemoteControlViewerAccount RequireAccount()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (Volatile.Read(ref _disconnecting) != 0) throw new InvalidOperationException(_text("FileTransferLiveBusy"));
        return _account() ?? throw new InvalidOperationException(_text("FileTransferLiveSignIn"));
    }

    private async Task<LanProductControlSession> ConnectAsync(DiscoveryBrowserPeerCandidate peer, RemoteControlViewerAccount account)
    {
        if (_listener is null)
        {
            _destinationDirectory = Path.GetFullPath(_selection.DestinationDirectory);
            if (!Directory.Exists(_destinationDirectory)) throw new DirectoryNotFoundException(_text("FileTransferLiveMissingDestination"));
            _listener = new(_workspace, _destinationDirectory, _selection.ApproveIncomingAsync, _progress,
                (metadata, result, failure) => Complete(metadata?.TransferId, metadata?.FileName, result, failure), _lifetime.Token);
            _listenerObservation = ObserveListenerAsync(_listener);
        }
        if (_listener.Completion.IsCompleted) throw new IOException(_text("FileTransferLiveListenerStopped"));
        SetStatus(_text("FileTransferLiveConnecting"));
        var session = await _workspace.ConnectControlAsync(peer, account, _listener.Port, _connectionsLifetime.Token);
        bool added;
        lock (_state) added = _connected.Add(session.SessionId);
        if (added)
        {
            _observations.RemoveAll(task => task.IsCompletedSuccessfully);
            _observations.Add(ObserveSessionAsync(session));
        }
        SetStatus(_text("FileTransferLiveConnected"));
        return session;
    }

    private async Task ObserveSessionAsync(LanProductControlSession session)
    {
        var failure = await session.Completion.ConfigureAwait(false);
        lock (_state) _connected.Remove(session.SessionId);
        if (!_lifetime.IsCancellationRequested) SetStatus(failure?.Message ?? _text("FileTransferLiveDisconnected"));
    }

    private async Task ObserveListenerAsync(ClassicFileTransferListener listener)
    {
        try { await listener.Completion.ConfigureAwait(false); }
        catch (Exception failure) { _connectionsLifetime.Cancel(); SetStatus(failure.Message); }
    }

    private void ReportProgress(ClassicFileTransferProgress progress)
    {
        bool publish;
        lock (_state)
        {
            _active[progress.TransferId] = new(progress.FileName, progress.IsIncoming ? "Receiving" : "Sending",
                $"{progress.Bytes:N0} / {progress.TotalBytes:N0} B", "LAN · PQC", "");
            var now = Environment.TickCount64;
            publish = now - _lastProgress >= 100 || progress.Bytes == progress.TotalBytes;
            if (publish) _lastProgress = now;
        }
        if (publish) Publish();
    }

    private void Complete(string? transferId, string? name, ClassicFileTransferResult? result, Exception? failure)
    {
        lock (_state)
        {
            if (transferId is not null) _active.Remove(transferId);
            _status = failure?.Message ?? _text("FileTransferLiveCompleted");
            _history.Insert(0, new(name ?? _text("FileTransferLiveIncoming"),
                failure is null ? (result?.SavedPath is null ? "Sent" : "Received") : "Failed",
                result?.FileHash ?? "", result?.SavedPath ?? failure?.Message ?? _text("FileTransferLiveReceiptVerified")));
            if (_history.Count > 100) _history.RemoveRange(100, _history.Count - 100);
        }
        Publish();
    }

    private FileTransferWorkspaceSnapshot Snapshot()
    {
        lock (_state) return new(DateTimeOffset.UtcNow, _active.Values.ToArray(), _history.ToArray(),
            [new(_text("FileTransferLiveConnectionLabel"), _connected.Count.ToString(), _text("FileTransferLiveProtocol")),
             new(_text("FileTransferLiveDestinationLabel"), _destinationDirectory ?? _text("FileTransferLiveDestinationPending"), _text("FileTransferLiveReceiptVerified"))]);
    }
    private FileTransferWorkspaceActionResult Result(string key) { SetStatus(_text(key)); return new(_text(key), _text(key), ""); }
    private void SetStatus(string status) { lock (_state) _status = status; Publish(); }
    private void Publish() { var snapshot = Snapshot(); string status; lock (_state) status = _status; Changed?.Invoke(snapshot, status); }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _lifetime.Cancel();
        _connectionsLifetime.Cancel();
        await _outbound.WaitAsync();
        try
        {
            if (_listener is { } listener) { await listener.DisposeAsync(); _listener = null; }
            await _listenerObservation;
            await _workspace.DisconnectControlSessionsAsync();
            await Task.WhenAll(_observations);
            _disposed = true;
            _lifetime.Dispose();
            _connectionsLifetime.Dispose();
        }
        finally { _outbound.Release(); }
    }

    private sealed class TransferProgress(Action<ClassicFileTransferProgress> report) : IProgress<ClassicFileTransferProgress>
    { public void Report(ClassicFileTransferProgress value) => report(value); }
}
