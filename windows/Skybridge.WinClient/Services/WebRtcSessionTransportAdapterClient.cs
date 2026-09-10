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
    private bool _disposeRequested;
    private bool _disposeCompleted;

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
            ThrowIfDisposed();
            if (_activeSession is not null)
            {
                if (_activeSession.Matches(request) && _activeSession.IsLive)
                {
                    return _activeSession.Snapshot;
                }

                if (_activeSession.IsClaimedByEngine)
                {
                    throw new InvalidOperationException(
                        "WebRTC session transport is owned by an active engine operation; disconnect it before preparing a replacement session.");
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
                await DisposeSessionResourcesAsync(dataPlaneClient, helperSession).ConfigureAwait(false);
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
            ThrowIfDisposed();
            if (_activeSession?.IsClaimedByEngine == true)
            {
                throw new InvalidOperationException(
                    "WebRTC session transport is owned by an active engine operation; only its exact lease may release it.");
            }

            await DisposeActiveSessionAsync().ConfigureAwait(false);
        }
        finally
        {
            _mutex.Release();
        }
    }

    internal async Task<OwnedWebRtcSessionContext> ClaimLiveSessionAsync(
        ConnectionLaunchRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        await _mutex.WaitAsync().ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            var active = RequireActiveSessionFor(request);
            var lease = active.ClaimForEngine();
            return new OwnedWebRtcSessionContext(
                lease,
                BuildLiveSessionContext(active, request));
        }
        finally
        {
            _mutex.Release();
        }
    }

    internal async Task DisposeSessionAsync(WebRtcSessionTransportLease lease)
    {
        lease.RequireValid();
        await _mutex.WaitAsync().ConfigureAwait(false);
        try
        {
            var active = _activeSession;
            if (active is null || !active.IsOwnedBy(lease))
            {
                return;
            }

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
        return BuildLiveSessionContext(active, request);
    }

    private static LiveWebRtcSessionContext BuildLiveSessionContext(
        ActiveSession active,
        ConnectionLaunchRequest request)
    {
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
            !string.Equals(request.Plan.LocalEndpoint, active.Snapshot.LocalEndpoint, StringComparison.Ordinal) ||
            !string.Equals(request.Plan.RemoteEndpoint, active.Snapshot.RemoteEndpoint, StringComparison.Ordinal) ||
            !string.Equals(request.Plan.SelectedCandidatePair, active.Snapshot.SelectedCandidatePair, StringComparison.Ordinal) ||
            !string.Equals(request.Plan.RelayId, active.Snapshot.RelayId, StringComparison.Ordinal) ||
            request.Plan.TimestampWindowMs != active.Snapshot.TimestampWindowMs)
        {
            throw new InvalidOperationException("WebRTC session launch plan does not match the active helper session binding.");
        }

        return active;
    }

    public async ValueTask DisposeAsync()
    {
        await _mutex.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_disposeCompleted)
            {
                return;
            }

            _disposeRequested = true;
            await DisposeActiveSessionAsync().ConfigureAwait(false);
            _disposeCompleted = true;
        }
        finally
        {
            _mutex.Release();
        }
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
        var sessionIncarnation = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        var adapterBinding =
            $"webrtc-session/v1/incarnation={sessionIncarnation};"
            + $"role={(_options.AsAnswerer ? "answer" : "offer")};"
            + $"ipc=127.0.0.1:{helperSession.IpcPort}";
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
                $"{localEndpoint} -> {remoteEndpoint}; candidate={selectedCandidatePair}; incarnation={sessionIncarnation}")
        };

        return new WindowsTransportAdapterSnapshot(
            ConnectionLaunchAdapterKind.WebRtcDataChannel,
            IsLiveAdapterReady: true,
            adapterBinding,
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
        if (active is null)
        {
            return;
        }

        await active.Resources.DisposePendingAsync().ConfigureAwait(false);
        _activeSession = null;
    }

    private static async Task DisposeSessionResourcesAsync(
        SkyBridgeDataPlaneClient? dataPlaneClient,
        WebRtcHelperSession? helperSession)
    {
        List<Exception>? errors = null;
        if (dataPlaneClient is not null)
        {
            try
            {
                await dataPlaneClient.DisposeAsync().ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                errors = new List<Exception> { ex };
            }
        }

        if (helperSession is not null)
        {
            try
            {
                await helperSession.DisposeAsync().ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                errors ??= new List<Exception>();
                errors.Add(ex);
            }
        }

        if (errors is null)
        {
            return;
        }

        if (errors.Count == 1)
        {
            ExceptionDispatchInfo.Capture(errors[0]).Throw();
        }

        throw new AggregateException(
            "WebRTC session transport resource teardown reported multiple errors.",
            errors);
    }

    private void ThrowIfDisposed()
    {
        if (_disposeRequested)
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
            Resources = new WebRtcSessionResourceOwner(dataPlaneClient, helperSession);
        }

        public string PeerDeviceId { get; }

        public string PeerPublicKeyFingerprint { get; }

        public WebRtcHelperSession HelperSession { get; }

        public SkyBridgeDataPlaneClient DataPlaneClient { get; }

        public WindowsTransportAdapterSnapshot Snapshot { get; }

        public WebRtcSessionResourceOwner Resources { get; }

        public bool IsLive => HelperSession.IsRunning && DataPlaneClient.IsConnected;

        public bool IsClaimedByEngine => EngineLease is not null;

        private WebRtcSessionTransportLease? EngineLease { get; set; }

        public WebRtcSessionTransportLease ClaimForEngine()
        {
            if (EngineLease is not null)
            {
                throw new InvalidOperationException(
                    "WebRTC session transport is already claimed by an engine operation.");
            }

            var lease = WebRtcSessionTransportLease.Create();
            EngineLease = lease;
            return lease;
        }

        public bool IsOwnedBy(WebRtcSessionTransportLease lease) => EngineLease == lease;

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

public sealed partial class WebRtcSessionEngineClient
{
    public WebRtcSessionEngineClient(
        IEngineClient inner,
        WebRtcSessionTransportAdapterClient sessionAdapter,
        IReadOnlyList<IWebRtcSessionRuntimeConsumer>? runtimeConsumers = null)
        : this(inner, new SessionEngineTransportBoundary(sessionAdapter), runtimeConsumers)
    {
    }

    private sealed class SessionEngineTransportBoundary : IWebRtcSessionEngineTransport
    {
        private readonly WebRtcSessionTransportAdapterClient _sessionAdapter;

        public SessionEngineTransportBoundary(WebRtcSessionTransportAdapterClient sessionAdapter)
        {
            _sessionAdapter = sessionAdapter ?? throw new ArgumentNullException(nameof(sessionAdapter));
        }

        public Task<OwnedWebRtcSessionContext> ClaimLiveSessionAsync(ConnectionLaunchRequest request) =>
            _sessionAdapter.ClaimLiveSessionAsync(request);

        public Task DisposeSessionAsync(WebRtcSessionTransportLease lease) =>
            _sessionAdapter.DisposeSessionAsync(lease);

        public ValueTask DisposeAsync() => _sessionAdapter.DisposeAsync();
    }
}
