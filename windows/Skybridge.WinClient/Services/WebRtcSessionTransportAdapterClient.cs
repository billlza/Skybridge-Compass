using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.ExceptionServices;
using System.Security.Cryptography;
using System.Text;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

/// <summary>
/// Owns a persistent WebRTC helper session plus the app-side loopback data-plane client.
/// Unlike <see cref="VerifiedWebRtcDataChannelTransportAdapterClient"/>, this is not a
/// proof-file reader: it starts the helper in session mode and only marks the adapter live
/// after the helper reports an IPC port and <see cref="SkyBridgeDataPlaneClient"/> connects.
/// </summary>
public sealed class WebRtcSessionTransportAdapterClient : IWindowsTransportAdapterClient, IWebRtcSessionDataPlaneProvider, IAsyncDisposable
{
    private readonly IWebRtcHelperLaunchClient _helperLaunchClient;
    private readonly WebRtcSessionTransportAdapterOptions _options;
    private readonly SemaphoreSlim _mutex = new(1, 1);
    private ActiveSession? _activeSession;
    private bool _disposed;

    public WebRtcSessionTransportAdapterClient(
        IWebRtcHelperLaunchClient helperLaunchClient,
        WebRtcSessionTransportAdapterOptions options)
    {
        _helperLaunchClient = helperLaunchClient ?? throw new ArgumentNullException(nameof(helperLaunchClient));
        _options = options ?? throw new ArgumentNullException(nameof(options));
    }

    public async Task<WindowsTransportAdapterSnapshot> PrepareAsync(WindowsTransportAdapterRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        ThrowIfDisposed();
        ValidateRequest(request);

        await _mutex.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_activeSession is not null)
            {
                if (_activeSession.Matches(request) && _activeSession.IsLive)
                {
                    return _activeSession.Snapshot;
                }

                await DisposeActiveSessionAsync().ConfigureAwait(false);
            }

            WebRtcHelperSession? helperSession = null;
            SkyBridgeDataPlaneClient? dataPlaneClient = null;
            try
            {
                helperSession = await _helperLaunchClient
                    .LaunchSessionAsync(
                        new WebRtcHelperSessionRequest(_options.AsAnswerer, _options.PreferredIpcPort))
                    .ConfigureAwait(false);

                dataPlaneClient = new SkyBridgeDataPlaneClient(
                    helperSession.IpcPort,
                    autoReconnect: false);
                await dataPlaneClient.StartAsync().ConfigureAwait(false);

                var snapshot = BuildSnapshot(request, helperSession);
                _activeSession = new ActiveSession(
                    request.PairingMaterial.DeviceId,
                    request.PairingMaterial.PublicKeyFingerprint,
                    helperSession,
                    dataPlaneClient,
                    snapshot);
                helperSession = null;
                dataPlaneClient = null;
                return snapshot;
            }
            finally
            {
                if (dataPlaneClient is not null)
                {
                    await dataPlaneClient.DisposeAsync().ConfigureAwait(false);
                }

                if (helperSession is not null)
                {
                    await helperSession.DisposeAsync().ConfigureAwait(false);
                }
            }
        }
        finally
        {
            _mutex.Release();
        }
    }

    public async Task DisposeSessionAsync()
    {
        await _mutex.WaitAsync().ConfigureAwait(false);
        try
        {
            await DisposeActiveSessionAsync().ConfigureAwait(false);
        }
        finally
        {
            _mutex.Release();
        }
    }

    public void RequireLiveSessionFor(ConnectionLaunchRequest request)
    {
        _ = RequireActiveSessionFor(request);
    }

    public LiveWebRtcSessionContext RequireLiveSession(ConnectionLaunchRequest request)
    {
        var active = RequireActiveSessionFor(request);
        return new LiveWebRtcSessionContext(
            active.DataPlaneClient,
            active.PeerDeviceId,
            active.PeerPublicKeyFingerprint,
            ToHex(active.Snapshot.TransportSecretFingerprint),
            active.Snapshot.AdapterBinding,
            active.Snapshot.LocalEndpoint,
            active.Snapshot.RemoteEndpoint,
            active.Snapshot.SelectedCandidatePair,
            active.Snapshot.TimestampWindowMs,
            request.Plan.ChannelMappings.ToArray());
    }

    private ActiveSession RequireActiveSessionFor(ConnectionLaunchRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        var active = _activeSession;
        if (active is null)
        {
            throw new InvalidOperationException("WebRTC session transport is not live; run preflight before launching the engine.");
        }

        if (!active.Matches(request.PairingMaterial.DeviceId, request.PairingMaterial.PublicKeyFingerprint))
        {
            throw new InvalidOperationException("WebRTC session transport identity does not match the launch request.");
        }

        if (!active.IsLive)
        {
            throw new InvalidOperationException("WebRTC session transport is no longer live; refusing to launch against a closed helper session.");
        }

        if (request.Plan.AdapterKind != ConnectionLaunchAdapterKind.WebRtcDataChannel ||
            request.Plan.TransportKind != CoreTransportKind.WebRtcDataChannel ||
            request.Plan.TransportAudit != CoreTransportAuditCode.WebRtcInterop ||
            !request.Plan.IsLiveAdapterReady)
        {
            throw new InvalidOperationException("WebRTC session engine requires a live WebRtcDataChannel/WebRtcInterop launch plan.");
        }

        if (!string.Equals(request.Plan.AdapterBinding, active.Snapshot.AdapterBinding, StringComparison.Ordinal) ||
            !string.Equals(request.Plan.SelectedCandidatePair, active.Snapshot.SelectedCandidatePair, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("WebRTC session launch plan does not match the active helper session binding.");
        }

        return active;
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        await DisposeSessionAsync().ConfigureAwait(false);
        _mutex.Dispose();
        _disposed = true;
    }

    private static void ValidateRequest(WindowsTransportAdapterRequest request)
    {
        var adapterKind = ConnectionPreflightPlan.ResolveAdapterKind(request.TransportKind);
        if (adapterKind == ConnectionLaunchAdapterKind.AppleNative)
        {
            throw new InvalidOperationException("Windows WebRTC session adapter must not select AppleNative; Apple-to-Apple remains on the Apple native path.");
        }

        if (adapterKind != ConnectionLaunchAdapterKind.WebRtcDataChannel)
        {
            throw new InvalidOperationException("Windows WebRTC session adapter requires the Core-selected transport to be WebRtcDataChannel.");
        }

        if (request.TransportAudit != CoreTransportAuditCode.WebRtcInterop)
        {
            throw new InvalidOperationException("Windows WebRTC session adapter requires the Core transport audit to be WebRtcInterop.");
        }

        if (!string.Equals(request.DiscoveredPeer.DeviceId, request.PairingMaterial.DeviceId, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("WebRTC session peer identity does not match pairing material.");
        }

        if (!string.Equals(
            request.DiscoveredPeer.PublicKeyFingerprint,
            request.PairingMaterial.PublicKeyFingerprint,
            StringComparison.Ordinal))
        {
            throw new InvalidOperationException("WebRTC session discovered fingerprint does not match pairing material.");
        }

        if (!IsLowerHexFingerprint(request.PairingMaterial.PublicKeyFingerprint))
        {
            throw new InvalidOperationException("WebRTC session requires a 64 lowercase hex peer public key fingerprint.");
        }
    }

    private WindowsTransportAdapterSnapshot BuildSnapshot(
        WindowsTransportAdapterRequest request,
        WebRtcHelperSession helperSession)
    {
        var localSignalPath = _options.AsAnswerer ? helperSession.AnswerPath : helperSession.OfferPath;
        var remoteSignalPath = _options.AsAnswerer ? helperSession.OfferPath : helperSession.AnswerPath;
        var localSignal = WebRtcSignalDocument.Read(localSignalPath, _options.AsAnswerer ? "answer" : "offer");
        var remoteSignal = WebRtcSignalDocument.Read(remoteSignalPath, _options.AsAnswerer ? "offer" : "answer");
        var localEndpoint = localSignal.FirstEndpoint();
        var remoteEndpoint = remoteSignal.FirstEndpoint();
        var localFingerprint = localSignal.Fingerprint();
        var remoteFingerprint = remoteSignal.Fingerprint();
        var selectedCandidatePair =
            $"webrtc/dtls/sctp/{localSignal.FirstCandidateLabel()}-{remoteSignal.FirstCandidateLabel()}";
        var transportSecretFingerprint = Sha256(
            "skybridge-webrtc-session-transport:"
            + $"{localFingerprint}:{remoteFingerprint}:"
            + $"{localEndpoint}:{remoteEndpoint}:"
            + request.PairingMaterial.PublicKeyFingerprint);

        var facts = new[]
        {
            new ConnectionPreflightFact(
                "Windows WebRTC session",
                "live data-plane",
                $"helper session role={(_options.AsAnswerer ? "answer" : "offer")} ipc=127.0.0.1:{helperSession.IpcPort}; signaling={Path.GetDirectoryName(localSignalPath)}"),
            new ConnectionPreflightFact(
                "WebRTC session binding",
                "dtls-sctp",
                $"{localEndpoint} -> {remoteEndpoint}; candidate={selectedCandidatePair}")
        };

        return new WindowsTransportAdapterSnapshot(
            ConnectionLaunchAdapterKind.WebRtcDataChannel,
            IsLiveAdapterReady: true,
            "verified webrtc datachannel session helper",
            localEndpoint,
            remoteEndpoint,
            selectedCandidatePair,
            transportSecretFingerprint,
            null,
            _options.TimestampWindowMs,
            CapabilityDigest(request, _options.AsAnswerer),
            facts);
    }

    private async Task DisposeActiveSessionAsync()
    {
        var active = _activeSession;
        _activeSession = null;
        if (active is null)
        {
            return;
        }

        await active.DataPlaneClient.DisposeAsync().ConfigureAwait(false);
        await active.HelperSession.DisposeAsync().ConfigureAwait(false);
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(WebRtcSessionTransportAdapterClient));
        }
    }

    private static byte[] CapabilityDigest(WindowsTransportAdapterRequest request, bool asAnswerer)
    {
        var material =
            $"local={FormatCapabilities(request.LocalCapabilities)};"
            + $"remote={FormatCapabilities(request.RemoteCapabilities)};"
            + $"peer={request.DiscoveredPeer.DeviceId};"
            + $"fingerprint={request.PairingMaterial.PublicKeyFingerprint};"
            + $"sameLan={request.NetworkPath.SameLan};"
            + $"crossNat={request.NetworkPath.CrossNat};"
            + "transport=WebRtcDataChannel;"
            + $"role={(asAnswerer ? "answer" : "offer")}";
        return Sha256(material);
    }

    private static string FormatCapabilities(PeerCapabilities capabilities) =>
        $"{capabilities.Platform},{capabilities.SupportsAppleNative},{capabilities.SupportsMsQuic},"
        + $"{capabilities.SupportsSkyBridgeIceMsQuic},{capabilities.SupportsWebRtcDataChannel},"
        + $"{capabilities.SupportsTcpFallback},{capabilities.SupportsRelay}";

    private static byte[] Sha256(string material) =>
        SHA256.HashData(Encoding.UTF8.GetBytes(material));

    private static string ToHex(byte[] bytes) =>
        Convert.ToHexString(bytes).ToLowerInvariant();

    private static bool IsLowerHexFingerprint(string value)
    {
        if (value.Length != 64)
        {
            return false;
        }

        foreach (var ch in value)
        {
            if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')))
            {
                return false;
            }
        }

        return true;
    }

    private sealed class ActiveSession
    {
        public ActiveSession(
            string peerDeviceId,
            string peerPublicKeyFingerprint,
            WebRtcHelperSession helperSession,
            SkyBridgeDataPlaneClient dataPlaneClient,
            WindowsTransportAdapterSnapshot snapshot)
        {
            PeerDeviceId = peerDeviceId;
            PeerPublicKeyFingerprint = peerPublicKeyFingerprint;
            HelperSession = helperSession;
            DataPlaneClient = dataPlaneClient;
            Snapshot = snapshot;
        }

        public string PeerDeviceId { get; }

        public string PeerPublicKeyFingerprint { get; }

        public WebRtcHelperSession HelperSession { get; }

        public SkyBridgeDataPlaneClient DataPlaneClient { get; }

        public WindowsTransportAdapterSnapshot Snapshot { get; }

        public bool IsLive => HelperSession.IsRunning && DataPlaneClient.IsConnected;

        public bool Matches(WindowsTransportAdapterRequest request) =>
            Matches(request.PairingMaterial.DeviceId, request.PairingMaterial.PublicKeyFingerprint);

        public bool Matches(string peerDeviceId, string peerPublicKeyFingerprint) =>
            string.Equals(PeerDeviceId, peerDeviceId, StringComparison.Ordinal) &&
            string.Equals(PeerPublicKeyFingerprint, peerPublicKeyFingerprint, StringComparison.Ordinal);
    }

}

public sealed class WebRtcSessionTransportAdapterOptions
{
    public WebRtcSessionTransportAdapterOptions(
        bool asAnswerer,
        int preferredIpcPort,
        ulong timestampWindowMs)
    {
        if (preferredIpcPort is < 0 or > 65535)
        {
            throw new InvalidOperationException("WebRTC session preferred IPC port must be 0 for an OS-assigned port, or a TCP port in the range 1-65535.");
        }

        if (timestampWindowMs == 0)
        {
            throw new InvalidOperationException("WebRTC session adapter requires a non-zero timestamp window.");
        }

        AsAnswerer = asAnswerer;
        PreferredIpcPort = preferredIpcPort;
        TimestampWindowMs = timestampWindowMs;
    }

    public bool AsAnswerer { get; }

    public int PreferredIpcPort { get; }

    public ulong TimestampWindowMs { get; }
}

public sealed class WebRtcSessionEngineClient : IEngineClient, IDisposable
{
    private readonly IEngineClient _inner;
    private readonly WebRtcSessionTransportAdapterClient _sessionAdapter;
    private readonly IReadOnlyList<IWebRtcSessionRuntimeConsumer> _runtimeConsumers;
    private readonly List<IWebRtcSessionRuntimeConsumer> _startedConsumers = new();

    public WebRtcSessionEngineClient(
        IEngineClient inner,
        WebRtcSessionTransportAdapterClient sessionAdapter,
        IReadOnlyList<IWebRtcSessionRuntimeConsumer>? runtimeConsumers = null)
    {
        _inner = inner ?? throw new ArgumentNullException(nameof(inner));
        _sessionAdapter = sessionAdapter ?? throw new ArgumentNullException(nameof(sessionAdapter));
        _runtimeConsumers = runtimeConsumers ?? Array.Empty<IWebRtcSessionRuntimeConsumer>();
        _inner.ConnectionStateChanged += OnInnerConnectionStateChanged;
    }

    public EngineConnectionState State => _inner.State;

    public event EventHandler<EngineConnectionState>? ConnectionStateChanged;

    public async Task ConnectAsync(ConnectionLaunchRequest request)
    {
        _sessionAdapter.RequireLiveSessionFor(request);
        try
        {
            await _inner.ConnectAsync(request).ConfigureAwait(false);
            var context = _sessionAdapter.RequireLiveSession(request);
            foreach (var consumer in _runtimeConsumers)
            {
                await consumer.StartAsync(context, request).ConfigureAwait(false);
                _startedConsumers.Add(consumer);
            }
        }
        catch (Exception ex)
        {
            var cleanupErrors = new List<Exception>();
            cleanupErrors.AddRange(await StopStartedConsumersAsync().ConfigureAwait(false));
            try
            {
                await _inner.DisconnectAsync().ConfigureAwait(false);
            }
            catch (Exception cleanupEx)
            {
                cleanupErrors.Add(cleanupEx);
            }

            try
            {
                await _sessionAdapter.DisposeSessionAsync().ConfigureAwait(false);
            }
            catch (Exception cleanupEx)
            {
                cleanupErrors.Add(cleanupEx);
            }

            if (cleanupErrors.Count > 0)
            {
                cleanupErrors.Insert(0, ex);
                throw new AggregateException(
                    "WebRTC session engine connect failed and cleanup also reported errors.",
                    cleanupErrors);
            }

            ExceptionDispatchInfo.Capture(ex).Throw();
            throw;
        }
    }

    public async Task DisconnectAsync()
    {
        var stopErrors = await StopStartedConsumersAsync().ConfigureAwait(false);
        try
        {
            await _inner.DisconnectAsync().ConfigureAwait(false);
        }
        finally
        {
            await _sessionAdapter.DisposeSessionAsync().ConfigureAwait(false);
        }

        if (stopErrors.Count > 0)
        {
            throw new AggregateException("One or more WebRTC session runtime consumers failed to stop.", stopErrors);
        }
    }

    public Task SendHeartbeatAsync() => _inner.SendHeartbeatAsync();

    public void Dispose()
    {
        _inner.ConnectionStateChanged -= OnInnerConnectionStateChanged;
        var stopErrors = StopStartedConsumersAsync().GetAwaiter().GetResult();
        if (_inner is IDisposable disposable)
        {
            disposable.Dispose();
        }

        _sessionAdapter.DisposeAsync().AsTask().GetAwaiter().GetResult();
        if (stopErrors.Count > 0)
        {
            throw new AggregateException("One or more WebRTC session runtime consumers failed to stop.", stopErrors);
        }
    }

    private void OnInnerConnectionStateChanged(object? sender, EngineConnectionState state) =>
        ConnectionStateChanged?.Invoke(this, state);

    private async Task<IReadOnlyList<Exception>> StopStartedConsumersAsync()
    {
        var errors = new List<Exception>();
        for (var index = _startedConsumers.Count - 1; index >= 0; index--)
        {
            try
            {
                await _startedConsumers[index].StopAsync().ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                errors.Add(ex);
            }
        }

        _startedConsumers.Clear();
        return errors;
    }
}
