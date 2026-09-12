using System.Net;
using System.Net.Sockets;
using System.Runtime.Versioning;

namespace Skybridge.WinClient.Services.RemoteControl;

internal enum WindowsRemoteControlHostState { Stopped, Listening, Authenticating, Connected, Failed }
internal sealed record WindowsRemoteControlHostStatus(
    WindowsRemoteControlHostState State, string Message, string? PeerDeviceId = null,
    long FramesSent = 0, long AudioPacketsSent = 0,
    IReadOnlyList<RemoteControlHostSessionStatus>? Sessions = null, long Revision = 0);

/// <summary>The user-enabled LAN host. Only one controller owns the shared Windows desktop at a time.</summary>
[SupportedOSPlatform("windows10.0.19041")]
internal sealed class WindowsRemoteControlHost : IAsyncDisposable
{
    private readonly RemoteControlIdentityStore _identity;
    private readonly SemaphoreSlim _lifecycle = new(1, 1);
    private CancellationTokenSource? _lifetime;
    private TcpListener? _listener;
    private WindowsRemoteControlAdvertisement? _advertisement;
    private sealed class PeerEntry(Guid id, CancellationTokenSource cancellation)
    {
        internal readonly Guid Id = id;
        internal readonly CancellationTokenSource Cancellation = cancellation;
        internal Task Worker = Task.CompletedTask;
        internal RemoteControlHostSession? PendingCleanup;
    }
    private readonly object _peersGate = new();
    private readonly object _statusGate = new();
    private long _statusRevision;
    private readonly Dictionary<Guid, PeerEntry> _peers = [];
    private readonly RemoteControlHostAccessCoordinator _access = new();
    private string _lastFailure = "";
    private WindowsRemoteControlHostStatus _status = new(WindowsRemoteControlHostState.Stopped, "");
    private bool _disposed;
    private int? _localPort;
    private bool _completionObserved;

    internal WindowsRemoteControlHost(RemoteControlIdentityStore identity)
    {
        _identity = identity;
        _access.Changed += _ => RefreshSessionStatus();
    }
    public event Action<WindowsRemoteControlHostStatus>? StatusChanged;
    public WindowsRemoteControlHostStatus CurrentStatus => Volatile.Read(ref _status);
    public Task Completion { get; private set; } = Task.CompletedTask;
    public int? LocalPort => _localPort;
    public bool IsEnabled => _lifetime is not null;

    public async Task StartAsync(IPAddress localAddress, uint interfaceIndex, CancellationToken cancellationToken = default)
    {
        await _lifecycle.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_lifetime is not null) throw new InvalidOperationException("The LAN host is already enabled.");
            if (_identity.TrustedPeers.Count == 0) throw new InvalidOperationException("Import a trusted controller before enabling desktop access.");
            WindowsInteractiveDesktop.RequireAvailable();
            var listener = new TcpListener(localAddress, 0);
            var advertisement = new WindowsRemoteControlAdvertisement();
            _listener = listener;
            _advertisement = advertisement;
            _lifetime = new CancellationTokenSource();
            _completionObserved = false;
            Completion = Task.CompletedTask;
            _lastFailure = "";
            try
            {
                listener.Start(4);
                var port = ((IPEndPoint)listener.LocalEndpoint).Port;
                var material = _identity.PublicMaterial;
                var hostName = WindowsDnsSdAdvertisementBackend.GetLocalHostName();
                var properties = new Dictionary<string, string>(StringComparer.Ordinal)
                {
                    ["deviceId"] = material.DeviceId,
                    ["version"] = "2",
                    ["platform"] = "windows",
                    ["osVersion"] = QPeriaptPeerPlatform.LocalVersion(),
                    ["pubKeyFP"] = material.ProtocolPublicKeyFingerprint
                };
                var options = new WindowsRemoteControlAdvertisementOptions(
                    material.DeviceName, hostName, localAddress, port, interfaceIndex, properties);
                await advertisement.StartAsync(listener, options, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception startupFailure)
            {
                listener.Stop();
                _listener = null;
                try
                {
                    await advertisement.DisposeAsync().ConfigureAwait(false);
                    _advertisement = null;
                    _lifetime.Dispose();
                    _lifetime = null;
                }
                catch (Exception cleanupFailure)
                {
                    throw new AggregateException("LAN host startup failed and its advertisement still requires cleanup.", startupFailure, cleanupFailure);
                }
                throw;
            }
            _localPort = ((IPEndPoint)listener.LocalEndpoint).Port;
            SetStatus(new(WindowsRemoteControlHostState.Listening, ""));
            Completion = AcceptConnectionsAsync(listener, _lifetime.Token);
        }
        finally { _lifecycle.Release(); }
    }

    private async Task AcceptConnectionsAsync(TcpListener listener, CancellationToken cancellationToken)
    {
        try
        {
            while (true)
            {
                var client = await listener.AcceptTcpClientAsync(cancellationToken).ConfigureAwait(false);
                var peerCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                Guid id;
                try
                {
                    id = _access.Reserve(() => { peerCancellation.Cancel(); client.Dispose(); });
                }
                catch (RemoteControlHostCapacityException)
                {
                    peerCancellation.Dispose();
                    client.Dispose();
                    continue;
                }
                var entry = new PeerEntry(id, peerCancellation);
                lock (_peersGate) _peers.Add(id, entry);
                entry.Worker = Task.Run(() => HandlePeerAsync(entry, client), CancellationToken.None);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (SocketException) when (cancellationToken.IsCancellationRequested) { }
        catch (Exception failure)
        {
            Volatile.Write(ref _lastFailure, failure.Message);
            RefreshSessionStatus();
            throw;
        }
        finally
        {
            Task[] workers;
            lock (_peersGate) workers = _peers.Values.Select(entry => entry.Worker).ToArray();
            await Task.WhenAll(workers).ConfigureAwait(false);
        }
    }

    private async Task HandlePeerAsync(PeerEntry entry, TcpClient client)
    {
        TcpProductControlTransport transport;
        try { transport = new TcpProductControlTransport(client, RemoteControlWire.MaximumInboundFrameBytes, RemoteControlWire.MaximumOutboundFrameBytes); }
        catch (Exception failure)
        {
            if (!entry.Cancellation.IsCancellationRequested)
                Volatile.Write(ref _lastFailure, failure.Message);
            client.Dispose();
            _access.Retire(entry.Id);
            lock (_peersGate) _peers.Remove(entry.Id);
            entry.Cancellation.Dispose();
            RefreshSessionStatus();
            return;
        }
        await using var ownedTransport = transport;
        var cancellationToken = entry.Cancellation.Token;
        RemoteControlHostSession? session = null;
        Exception? cleanupFailure = null;
        var phase = "initial-frame";
        var sessionStartedAt = System.Diagnostics.Stopwatch.GetTimestamp();
        try
        {
            Volatile.Write(ref _lastFailure, "");
            RefreshSessionStatus();
            using var initialDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            initialDeadline.CancelAfter(TimeSpan.FromSeconds(5));
            var firstFrame = await transport.ReadAsync(initialDeadline.Token).ConfigureAwait(false);
            var candidate = RemoteControlHandshakeBinding.ValidateAndResolveMessageA(firstFrame, _identity.PublicMaterial.DeviceId, _identity.TrustedPeers);
            phase = "handshake";
            using var crypto = _identity.CreateCryptoProvider();
            using var handshake = await new ProductHandshakeCore(crypto, TimeSpan.FromSeconds(20))
                .AcceptResponderAsync(transport, candidate.Peer, candidate.MessageAFrame, cancellationToken).ConfigureAwait(false);
            var peerId = candidate.Peer.PeerDeviceId;
            var material = _identity.TrustedMaterials.Single(peer => peer.DeviceId == peerId);
            _access.Authenticate(entry.Id, peerId, material.DeviceName);
            var endpoint = client.Client.RemoteEndPoint as IPEndPoint
                ?? throw new InvalidDataException("The remote-control socket has no IP peer endpoint.");
            session = new RemoteControlHostSession(transport, handshake.Keys, endpoint.Address,
                (configuration, video, audio) => new WindowsRemoteControlStream(configuration, video, audio),
                (frames, packets) => _access.ReportCounters(entry.Id, frames, packets), _access, entry.Id);
            phase = "desktop-stream";
            await session.RunAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (EndOfStreamException)
        {
            WindowsRuntimeLog.Write(WindowsLogLevel.Info, "RemoteControlHost",
                $"Peer closed its connection; session={entry.Id:D}; phase={phase}; elapsed={System.Diagnostics.Stopwatch.GetElapsedTime(sessionStartedAt).TotalSeconds:F1}s.");
        }
        catch (Exception failure)
        {
            // The exact peer boundary reports an actual failure without ending
            // independent viewers or discarding native cleanup ownership.
            Volatile.Write(ref _lastFailure, failure.Message);
            WindowsRuntimeLog.Write(WindowsLogLevel.Error, "RemoteControlHost",
                $"Session failed; session={entry.Id:D}; phase={phase}; elapsed={System.Diagnostics.Stopwatch.GetElapsedTime(sessionStartedAt).TotalSeconds:F1}s; failure={failure.GetType().Name}; hresult=0x{failure.HResult:x8}; detail={failure.Message}");
            RefreshSessionStatus();
        }
        finally
        {
            _access.Disconnect(entry.Id);
            transport.Close();
            if (session is not null)
            {
                try { await session.DisposeAsync().ConfigureAwait(false); }
                catch (Exception failure)
                {
                    cleanupFailure = failure;
                    entry.PendingCleanup = session;
                    Volatile.Write(ref _lastFailure,
                        "Desktop cleanup is pending. Restore the interactive desktop and stop sharing again. " + failure.Message);
                }
            }
            _access.Retire(entry.Id, cleanupFailure);
            if (cleanupFailure is null)
            {
                lock (_peersGate) _peers.Remove(entry.Id);
                entry.Cancellation.Dispose();
            }
        }
    }

    internal Task ApproveSessionAsync(Guid id, bool allowInput, CancellationToken cancellationToken) =>
        _access.ApproveAsync(id, allowInput, cancellationToken);

    internal Task TransferInputAsync(Guid id, CancellationToken cancellationToken) =>
        _access.TransferInputAsync(id, cancellationToken);

    internal void DisconnectSession(Guid id) => _access.Disconnect(id);

    private void RefreshSessionStatus()
    {
        WindowsRemoteControlHostStatus status;
        lock (_statusGate)
        {
            var sessions = _access.Snapshot;
            var failure = Volatile.Read(ref _lastFailure);
            var state = failure.Length > 0 || sessions.Any(session => session.Phase == RemoteControlHostSessionPhase.Failed)
                ? WindowsRemoteControlHostState.Failed
                : sessions.Any(session => session.Phase is RemoteControlHostSessionPhase.Viewing or RemoteControlHostSessionPhase.Controlling)
                    ? WindowsRemoteControlHostState.Connected
                    : sessions.Count > 0 ? WindowsRemoteControlHostState.Authenticating : WindowsRemoteControlHostState.Listening;
            status = new(state, failure, FramesSent: sessions.Sum(session => session.FramesSent),
                AudioPacketsSent: sessions.Sum(session => session.AudioPacketsSent), Sessions: sessions, Revision: ++_statusRevision);
            Volatile.Write(ref _status, status);
        }
        StatusChanged?.Invoke(status);
    }

    private void SetStatus(WindowsRemoteControlHostStatus status)
    {
        lock (_statusGate)
        {
            status = status with { Revision = ++_statusRevision };
            Volatile.Write(ref _status, status);
        }
        StatusChanged?.Invoke(status);
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        await _lifecycle.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var lifetime = _lifetime;
            if (lifetime is null) return;
            var failures = new List<Exception>();
            await lifetime.CancelAsync().ConfigureAwait(false);
            _listener?.Stop();
            _localPort = null;
            if (!_completionObserved)
            {
                try { await Completion.ConfigureAwait(false); }
                catch (Exception failure) { failures.Add(failure); }
                finally { _completionObserved = true; }
            }
            try
            {
                PeerEntry[] pending;
                lock (_peersGate) pending = _peers.Values.ToArray();
                foreach (var entry in pending)
                {
                    try
                    {
                        if (entry.PendingCleanup is not null)
                            await entry.PendingCleanup.DisposeAsync().ConfigureAwait(false);
                        _access.Retire(entry.Id);
                        lock (_peersGate) _peers.Remove(entry.Id);
                        entry.Cancellation.Dispose();
                    }
                    catch (Exception failure) { failures.Add(failure); }
                }
            }
            catch (Exception failure) { failures.Add(failure); }
            try
            {
                if (_advertisement is not null) await _advertisement.DisposeAsync().ConfigureAwait(false);
                _advertisement = null;
            }
            catch (Exception failure) { failures.Add(failure); }
            _listener = null;
            if (failures.Count > 0)
            {
                var failure = new AggregateException("The LAN host could not release all resources cleanly.", failures);
                SetStatus(new(WindowsRemoteControlHostState.Failed, failure.Message));
                throw failure;
            }
            _lifetime = null;
            lifetime.Dispose();
            SetStatus(new(WindowsRemoteControlHostState.Stopped, ""));
        }
        finally { _lifecycle.Release(); }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        await StopAsync().ConfigureAwait(false);
        _disposed = true;
        _lifecycle.Dispose();
    }
}
