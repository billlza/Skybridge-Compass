using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.ExceptionServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public enum WebRtcProductControlSecureSessionState
{
    TransportOnly,
    Established
}

public sealed record LiveWebRtcProductControlContext(
    IWebRtcProductControlPlane ControlPlane,
    string PeerDeviceId,
    string PeerPublicKeyFingerprint,
    string Role,
    string TransportProfile,
    string DataChannelLabel,
    string AdapterBinding,
    string LocalEndpoint,
    string RemoteEndpoint,
    string SelectedCandidatePair,
    string TransportBindingDigestHex,
    ulong TimestampWindowMs,
    WebRtcProductControlSecureSessionState SecureSessionState);

public sealed class WebRtcProductControlTransportOptions
{
    public WebRtcProductControlTransportOptions(
        bool asAnswerer,
        int preferredIpcPort,
        ulong timestampWindowMs)
    {
        if (preferredIpcPort is < 0 or > 65535)
        {
            throw new InvalidOperationException(
                "WebRTC product-control preferred IPC port must be 0 for an OS-assigned port, or a TCP port in the range 1-65535.");
        }

        if (timestampWindowMs == 0)
        {
            throw new InvalidOperationException("WebRTC product-control transport requires a non-zero timestamp window.");
        }

        AsAnswerer = asAnswerer;
        PreferredIpcPort = preferredIpcPort;
        TimestampWindowMs = timestampWindowMs;
    }

    public bool AsAnswerer { get; }

    public int PreferredIpcPort { get; }

    public ulong TimestampWindowMs { get; }
}

public interface IWebRtcProductControlSessionConnector
{
    Task<WebRtcHelperSession> ConnectAsync(
        WebRtcHelperProductControlSessionRequest sessionRequest,
        WindowsTransportAdapterRequest adapterRequest,
        CancellationToken cancellationToken = default);
}

public sealed class WebRtcProductControlFileSessionConnector : IWebRtcProductControlSessionConnector
{
    private readonly IWebRtcHelperLaunchClient _helperLaunchClient;

    public WebRtcProductControlFileSessionConnector(IWebRtcHelperLaunchClient helperLaunchClient)
    {
        _helperLaunchClient = helperLaunchClient ?? throw new ArgumentNullException(nameof(helperLaunchClient));
    }

    public Task<WebRtcHelperSession> ConnectAsync(
        WebRtcHelperProductControlSessionRequest sessionRequest,
        WindowsTransportAdapterRequest adapterRequest,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(sessionRequest);
        ArgumentNullException.ThrowIfNull(adapterRequest);
        return _helperLaunchClient.LaunchProductControlSessionAsync(sessionRequest, cancellationToken);
    }
}

public sealed class WebRtcProductControlTransportProvider : IAsyncDisposable
{
    public const string TransportProfile = "mac-product-control-v1";
    public const string DataChannelLabel = "skybridge";

    private readonly IWebRtcProductControlSessionConnector _sessionConnector;
    private readonly WebRtcProductControlTransportOptions _options;
    private readonly SemaphoreSlim _mutex = new(1, 1);
    private ActiveTransport? _activeTransport;
    private bool _disposed;

    public WebRtcProductControlTransportProvider(
        IWebRtcHelperLaunchClient helperLaunchClient,
        WebRtcProductControlTransportOptions options)
        : this(new WebRtcProductControlFileSessionConnector(helperLaunchClient), options)
    {
    }

    public WebRtcProductControlTransportProvider(
        IWebRtcProductControlSessionConnector sessionConnector,
        WebRtcProductControlTransportOptions options)
    {
        _sessionConnector = sessionConnector ?? throw new ArgumentNullException(nameof(sessionConnector));
        _options = options ?? throw new ArgumentNullException(nameof(options));
    }

    public async Task<LiveWebRtcProductControlContext> PrepareAsync(
        WindowsTransportAdapterRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        ValidateRequest(request);

        await _mutex.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            if (_activeTransport is not null)
            {
                if (_activeTransport.Matches(request) && _activeTransport.IsLive)
                {
                    return _activeTransport.Context;
                }

                await DisposeActiveTransportAsync().ConfigureAwait(false);
            }

            WebRtcHelperSession? helperSession = null;
            WebRtcProductControlPlaneClient? controlPlaneClient = null;
            try
            {
                helperSession = await _sessionConnector
                    .ConnectAsync(
                        new WebRtcHelperProductControlSessionRequest(
                            _options.AsAnswerer,
                            _options.PreferredIpcPort),
                        request,
                        cancellationToken)
                    .ConfigureAwait(false);

                controlPlaneClient = new WebRtcProductControlPlaneClient(
                    helperSession.IpcPort,
                    ipcAuthToken: helperSession.RequireProductControlIpcAuthToken());
                await controlPlaneClient.StartAsync(cancellationToken).ConfigureAwait(false);

                var context = BuildContext(request, helperSession, controlPlaneClient);
                _activeTransport = new ActiveTransport(
                    request.PairingMaterial.DeviceId,
                    request.PairingMaterial.PublicKeyFingerprint,
                    helperSession,
                    controlPlaneClient,
                    context);
                helperSession = null;
                controlPlaneClient = null;
                return context;
            }
            finally
            {
                if (controlPlaneClient is not null)
                {
                    await controlPlaneClient.DisposeAsync().ConfigureAwait(false);
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

    public LiveWebRtcProductControlContext RequireLiveTransport(
        string peerDeviceId,
        string peerPublicKeyFingerprint)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(peerDeviceId);
        ArgumentException.ThrowIfNullOrWhiteSpace(peerPublicKeyFingerprint);
        var active = _activeTransport;
        if (active is null)
        {
            throw new InvalidOperationException("WebRTC product-control transport is not live.");
        }

        if (!active.Matches(peerDeviceId, peerPublicKeyFingerprint))
        {
            throw new InvalidOperationException("WebRTC product-control transport identity does not match the requested peer.");
        }

        if (!active.IsLive)
        {
            throw new InvalidOperationException("WebRTC product-control transport is no longer live; refusing to use a closed helper session.");
        }

        return active.Context;
    }

    public async Task DisposeTransportAsync()
    {
        await _mutex.WaitAsync().ConfigureAwait(false);
        try
        {
            await DisposeActiveTransportAsync().ConfigureAwait(false);
        }
        finally
        {
            _mutex.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        await _mutex.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            await DisposeActiveTransportAsync().ConfigureAwait(false);
        }
        finally
        {
            _mutex.Release();
        }
    }

    private LiveWebRtcProductControlContext BuildContext(
        WindowsTransportAdapterRequest request,
        WebRtcHelperSession helperSession,
        IWebRtcProductControlPlane controlPlane)
    {
        var role = _options.AsAnswerer ? "answer" : "offer";
        var localSignalPath = _options.AsAnswerer ? helperSession.AnswerPath : helperSession.OfferPath;
        var remoteSignalPath = _options.AsAnswerer ? helperSession.OfferPath : helperSession.AnswerPath;
        var localSignal = WebRtcSignalDocument.Read(localSignalPath, _options.AsAnswerer ? "answer" : "offer");
        var remoteSignal = WebRtcSignalDocument.Read(remoteSignalPath, _options.AsAnswerer ? "offer" : "answer");
        var localEndpoint = localSignal.FirstEndpoint();
        var remoteEndpoint = remoteSignal.FirstEndpoint();
        var localFingerprint = localSignal.Fingerprint();
        var remoteFingerprint = remoteSignal.Fingerprint();
        var selectedCandidatePair =
            $"webrtc/dtls/sctp/{localSignal.FirstCandidateLabel()}-{remoteSignal.FirstCandidateLabel()}/{DataChannelLabel}";
        var adapterBinding =
            $"{TransportProfile}/{role}/datachannel={DataChannelLabel}/ipc=127.0.0.1:{helperSession.IpcPort}";
        var bindingDigest = Sha256Hex(
            "skybridge-webrtc-product-control:"
            + $"profile={TransportProfile};role={role};label={DataChannelLabel};"
            + $"localFingerprint={localFingerprint};remoteFingerprint={remoteFingerprint};"
            + $"localEndpoint={localEndpoint};remoteEndpoint={remoteEndpoint};"
            + $"peer={request.PairingMaterial.DeviceId};fingerprint={request.PairingMaterial.PublicKeyFingerprint}");

        return new LiveWebRtcProductControlContext(
            controlPlane,
            request.PairingMaterial.DeviceId,
            request.PairingMaterial.PublicKeyFingerprint,
            role,
            TransportProfile,
            DataChannelLabel,
            adapterBinding,
            localEndpoint,
            remoteEndpoint,
            selectedCandidatePair,
            bindingDigest,
            _options.TimestampWindowMs,
            WebRtcProductControlSecureSessionState.TransportOnly);
    }

    private async Task DisposeActiveTransportAsync()
    {
        var active = _activeTransport;
        _activeTransport = null;
        if (active is null)
        {
            return;
        }

        await active.ControlPlaneClient.DisposeAsync().ConfigureAwait(false);
        await active.HelperSession.DisposeAsync().ConfigureAwait(false);
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(WebRtcProductControlTransportProvider));
        }
    }

    private static void ValidateRequest(WindowsTransportAdapterRequest request)
    {
        if (request.TransportKind != CoreTransportKind.WebRtcDataChannel)
        {
            throw new InvalidOperationException("WebRTC product-control transport requires Core-selected WebRtcDataChannel transport.");
        }

        if (request.TransportAudit != CoreTransportAuditCode.WebRtcInterop)
        {
            throw new InvalidOperationException("WebRTC product-control transport requires WebRtcInterop transport audit.");
        }

        if (!string.Equals(request.DiscoveredPeer.DeviceId, request.PairingMaterial.DeviceId, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("WebRTC product-control peer identity does not match pairing material.");
        }

        if (!string.Equals(
            request.DiscoveredPeer.PublicKeyFingerprint,
            request.PairingMaterial.PublicKeyFingerprint,
            StringComparison.Ordinal))
        {
            throw new InvalidOperationException("WebRTC product-control discovered fingerprint does not match pairing material.");
        }

        if (!IsLowerHexFingerprint(request.PairingMaterial.PublicKeyFingerprint))
        {
            throw new InvalidOperationException("WebRTC product-control requires a 64 lowercase hex peer public key fingerprint.");
        }
    }

    private static string Sha256Hex(string material) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(material))).ToLowerInvariant();

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

    private sealed class ActiveTransport
    {
        public ActiveTransport(
            string peerDeviceId,
            string peerPublicKeyFingerprint,
            WebRtcHelperSession helperSession,
            WebRtcProductControlPlaneClient controlPlaneClient,
            LiveWebRtcProductControlContext context)
        {
            PeerDeviceId = peerDeviceId;
            PeerPublicKeyFingerprint = peerPublicKeyFingerprint;
            HelperSession = helperSession;
            ControlPlaneClient = controlPlaneClient;
            Context = context;
        }

        public string PeerDeviceId { get; }

        public string PeerPublicKeyFingerprint { get; }

        public WebRtcHelperSession HelperSession { get; }

        public WebRtcProductControlPlaneClient ControlPlaneClient { get; }

        public LiveWebRtcProductControlContext Context { get; }

        public bool IsLive => HelperSession.IsRunning && ControlPlaneClient.IsConnected;

        public bool Matches(WindowsTransportAdapterRequest request) =>
            Matches(request.PairingMaterial.DeviceId, request.PairingMaterial.PublicKeyFingerprint);

        public bool Matches(string peerDeviceId, string peerPublicKeyFingerprint) =>
            string.Equals(PeerDeviceId, peerDeviceId, StringComparison.Ordinal) &&
            string.Equals(PeerPublicKeyFingerprint, peerPublicKeyFingerprint, StringComparison.Ordinal);
    }
}

public sealed class WebRtcProductControlTransportAdapterClient : IWindowsTransportAdapterClient, IAsyncDisposable
{
    private readonly WebRtcProductControlTransportProvider _transportProvider;

    public WebRtcProductControlTransportAdapterClient(WebRtcProductControlTransportProvider transportProvider)
    {
        _transportProvider = transportProvider ?? throw new ArgumentNullException(nameof(transportProvider));
    }

    public async Task<WindowsTransportAdapterSnapshot> PrepareAsync(WindowsTransportAdapterRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var context = await _transportProvider.PrepareAsync(request).ConfigureAwait(false);
        var facts = new[]
        {
            new ConnectionPreflightFact(
                "Windows WebRTC product-control transport",
                "live raw control plane",
                $"{context.TransportProfile} role={context.Role}; datachannel={context.DataChannelLabel}; {context.LocalEndpoint} -> {context.RemoteEndpoint}"),
            new ConnectionPreflightFact(
                "WebRTC product-control evidence boundary",
                "TransportOnly",
                "Live helper transport is ready for product-control bytes; this is not Mac product app handshake, SBWC session keys, or AppControl proof.")
        };

        return new WindowsTransportAdapterSnapshot(
            ConnectionLaunchAdapterKind.WebRtcDataChannel,
            IsLiveAdapterReady: true,
            context.AdapterBinding,
            context.LocalEndpoint,
            context.RemoteEndpoint,
            context.SelectedCandidatePair,
            ParseLowerHex32(context.TransportBindingDigestHex, "WebRTC product-control transport binding digest"),
            null,
            context.TimestampWindowMs,
            CapabilityDigest(request, context),
            facts);
    }

    public void RequireLiveTransportFor(ConnectionLaunchRequest request)
    {
        _ = RequireLiveTransport(request);
    }

    public LiveWebRtcProductControlContext RequireLiveTransport(ConnectionLaunchRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        request.Plan.ValidateForLaunch(request.PairingMaterial);
        var context = _transportProvider.RequireLiveTransport(
            request.PairingMaterial.DeviceId,
            request.PairingMaterial.PublicKeyFingerprint);
        ValidatePlanMatchesContext(request.Plan, context);
        return context;
    }

    public Task DisposeTransportAsync() => _transportProvider.DisposeTransportAsync();

    public ValueTask DisposeAsync() => _transportProvider.DisposeAsync();

    private static void ValidatePlanMatchesContext(
        ConnectionPreflightPlan plan,
        LiveWebRtcProductControlContext context)
    {
        if (plan.AdapterKind != ConnectionLaunchAdapterKind.WebRtcDataChannel ||
            plan.TransportKind != CoreTransportKind.WebRtcDataChannel ||
            plan.TransportAudit != CoreTransportAuditCode.WebRtcInterop ||
            !plan.IsLiveAdapterReady)
        {
            throw new InvalidOperationException(
                "WebRTC product-control engine requires a live WebRtcDataChannel/WebRtcInterop launch plan.");
        }

        if (!string.Equals(plan.AdapterBinding, context.AdapterBinding, StringComparison.Ordinal) ||
            !string.Equals(plan.LocalEndpoint, context.LocalEndpoint, StringComparison.Ordinal) ||
            !string.Equals(plan.RemoteEndpoint, context.RemoteEndpoint, StringComparison.Ordinal) ||
            !string.Equals(plan.SelectedCandidatePair, context.SelectedCandidatePair, StringComparison.Ordinal) ||
            plan.TimestampWindowMs != context.TimestampWindowMs)
        {
            throw new InvalidOperationException(
                "WebRTC product-control launch plan does not match the active transport binding.");
        }
    }

    private static byte[] CapabilityDigest(
        WindowsTransportAdapterRequest request,
        LiveWebRtcProductControlContext context)
    {
        var material =
            $"local={FormatCapabilities(request.LocalCapabilities)};"
            + $"remote={FormatCapabilities(request.RemoteCapabilities)};"
            + $"peer={request.DiscoveredPeer.DeviceId};"
            + $"fingerprint={request.PairingMaterial.PublicKeyFingerprint};"
            + $"sameLan={request.NetworkPath.SameLan};"
            + $"crossNat={request.NetworkPath.CrossNat};"
            + $"transport=WebRtcDataChannel;"
            + $"profile={context.TransportProfile};"
            + $"role={context.Role};"
            + $"label={context.DataChannelLabel}";
        return SHA256.HashData(Encoding.UTF8.GetBytes(material));
    }

    private static string FormatCapabilities(PeerCapabilities capabilities) =>
        $"{capabilities.Platform},{capabilities.SupportsAppleNative},{capabilities.SupportsMsQuic},"
        + $"{capabilities.SupportsSkyBridgeIceMsQuic},{capabilities.SupportsWebRtcDataChannel},"
        + $"{capabilities.SupportsTcpFallback},{capabilities.SupportsRelay}";

    private static byte[] ParseLowerHex32(string raw, string label)
    {
        if (raw.Length != 64)
        {
            throw new InvalidOperationException($"{label} must be 64 lowercase hex characters.");
        }

        var bytes = new byte[32];
        for (var index = 0; index < bytes.Length; index++)
        {
            var high = FromLowerHex(raw[index * 2], label);
            var low = FromLowerHex(raw[index * 2 + 1], label);
            bytes[index] = (byte)((high << 4) | low);
        }

        return bytes;
    }

    private static int FromLowerHex(char value, string label)
    {
        if (value is >= '0' and <= '9')
        {
            return value - '0';
        }

        if (value is >= 'a' and <= 'f')
        {
            return value - 'a' + 10;
        }

        throw new InvalidOperationException($"{label} must be 64 lowercase hex characters.");
    }
}

public sealed class WebRtcProductControlEngineClient : IEngineClient, IDisposable
{
    private readonly IEngineClient _inner;
    private readonly WebRtcProductControlTransportAdapterClient _transportAdapter;
    private readonly IReadOnlyList<IWebRtcProductControlRuntimeConsumer> _runtimeConsumers;
    private readonly List<IWebRtcProductControlRuntimeConsumer> _startedConsumers = new();

    public WebRtcProductControlEngineClient(
        IEngineClient inner,
        WebRtcProductControlTransportAdapterClient transportAdapter,
        IReadOnlyList<IWebRtcProductControlRuntimeConsumer>? runtimeConsumers = null)
    {
        _inner = inner ?? throw new ArgumentNullException(nameof(inner));
        _transportAdapter = transportAdapter ?? throw new ArgumentNullException(nameof(transportAdapter));
        _runtimeConsumers = runtimeConsumers ?? Array.Empty<IWebRtcProductControlRuntimeConsumer>();
        _inner.ConnectionStateChanged += OnInnerConnectionStateChanged;
    }

    public EngineConnectionState State => _inner.State;

    public event EventHandler<EngineConnectionState>? ConnectionStateChanged;

    public async Task ConnectAsync(ConnectionLaunchRequest request)
    {
        _transportAdapter.RequireLiveTransportFor(request);
        try
        {
            await _inner.ConnectAsync(request).ConfigureAwait(false);
            var context = _transportAdapter.RequireLiveTransport(request);
            foreach (var consumer in _runtimeConsumers)
            {
                await consumer.StartAsync(context).ConfigureAwait(false);
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
                await _transportAdapter.DisposeTransportAsync().ConfigureAwait(false);
            }
            catch (Exception cleanupEx)
            {
                cleanupErrors.Add(cleanupEx);
            }

            if (cleanupErrors.Count > 0)
            {
                cleanupErrors.Insert(0, ex);
                throw new AggregateException(
                    "WebRTC product-control engine connect failed and cleanup also reported errors.",
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
            await _transportAdapter.DisposeTransportAsync().ConfigureAwait(false);
        }

        if (stopErrors.Count > 0)
        {
            throw new AggregateException("One or more WebRTC product-control runtime consumers failed to stop.", stopErrors);
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

        _transportAdapter.DisposeAsync().AsTask().GetAwaiter().GetResult();
        if (stopErrors.Count > 0)
        {
            throw new AggregateException("One or more WebRTC product-control runtime consumers failed to stop.", stopErrors);
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

public interface IWebRtcAppSessionKeyProvider
{
    WebRtcAppSecureSessionKeys RequireEstablishedKeys(LiveWebRtcProductControlContext context);
}

public sealed class WebRtcAppSessionKeysUnavailableException : InvalidOperationException
{
    public WebRtcAppSessionKeysUnavailableException(string message)
        : base(message)
    {
    }
}

public sealed class UnavailableWebRtcAppSessionKeyProvider : IWebRtcAppSessionKeyProvider
{
    public WebRtcAppSecureSessionKeys RequireEstablishedKeys(LiveWebRtcProductControlContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        throw new WebRtcAppSessionKeysUnavailableException(
            "WebRTC product-control secure session keys are not established. "
            + "Run the Mac-compatible MessageA/MessageB/FIN1 handshake before sending SBWC business payloads.");
    }
}

public interface IWebRtcProductControlRuntimeConsumer
{
    Task StartAsync(
        LiveWebRtcProductControlContext context,
        CancellationToken cancellationToken = default);

    Task StopAsync(CancellationToken cancellationToken = default);
}

public sealed class WebRtcProductControlSmokeOptions
{
    public WebRtcProductControlSmokeOptions(TimeSpan timeout, string? evidencePath = null)
    {
        if (timeout <= TimeSpan.Zero)
        {
            throw new InvalidOperationException("WebRTC product-control smoke timeout must be positive.");
        }

        Timeout = timeout;
        EvidencePath = string.IsNullOrWhiteSpace(evidencePath) ? null : Path.GetFullPath(evidencePath);
    }

    public TimeSpan Timeout { get; }

    public string? EvidencePath { get; }
}

public sealed class WebRtcProductControlSmokeClient : IWebRtcProductControlRuntimeConsumer
{
    private static readonly JsonSerializerOptions EvidenceJsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true
    };

    private readonly WebRtcProductControlSmokeOptions _options;
    private readonly object _gate = new();
    private TaskCompletionSource<byte[]>? _ack;
    private byte[]? _probePayload;
    private IWebRtcProductControlPlane? _subscribedControlPlane;
    private bool _subscribed;

    public WebRtcProductControlSmokeClient(WebRtcProductControlSmokeOptions options)
    {
        _options = options ?? throw new ArgumentNullException(nameof(options));
    }

    public async Task StartAsync(
        LiveWebRtcProductControlContext context,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(context);

        if (context.SecureSessionState != WebRtcProductControlSecureSessionState.TransportOnly)
        {
            throw new InvalidOperationException(
                "WebRTC product-control raw smoke must only run before secure SBWC session establishment.");
        }

        if (!context.ControlPlane.IsConnected)
        {
            throw new InvalidOperationException("WebRTC product-control smoke requires a connected raw control plane.");
        }

        var nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        var sentAt = DateTimeOffset.UtcNow;
        var payloadText =
            "skybridge-product-control-smoke:v1;"
            + $"nonce={nonce};"
            + $"peer={context.PeerDeviceId};"
            + $"profile={context.TransportProfile};"
            + $"binding={context.AdapterBinding}";
        var payload = Encoding.UTF8.GetBytes(payloadText);
        var ack = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);

        lock (_gate)
        {
            if (_subscribed)
            {
                throw new InvalidOperationException("WebRTC product-control smoke is already running.");
            }

            _ack = ack;
            _probePayload = payload;
            _subscribedControlPlane = context.ControlPlane;
            context.ControlPlane.MessageReceived += OnMessageReceived;
            _subscribed = true;
        }

        try
        {
            await context.ControlPlane.SendAsync(payload, cancellationToken).ConfigureAwait(false);
            var receivedPayload = await WaitForAckAsync(ack, cancellationToken).ConfigureAwait(false);
            var receivedAt = DateTimeOffset.UtcNow;
            WriteEvidence(context, payload, receivedPayload, nonce, sentAt, receivedAt);
        }
        finally
        {
            await StopAsync(cancellationToken).ConfigureAwait(false);
        }
    }

    public Task StopAsync(CancellationToken cancellationToken = default)
    {
        _ = cancellationToken;
        IWebRtcProductControlPlane? controlPlane;
        lock (_gate)
        {
            if (!_subscribed)
            {
                return Task.CompletedTask;
            }

            controlPlane = _subscribedControlPlane;
            _ack = null;
            _probePayload = null;
            _subscribedControlPlane = null;
            _subscribed = false;
        }

        if (controlPlane is not null)
        {
            controlPlane.MessageReceived -= OnMessageReceived;
        }

        return Task.CompletedTask;
    }

    private async Task<byte[]> WaitForAckAsync(
        TaskCompletionSource<byte[]> ack,
        CancellationToken cancellationToken)
    {
        var delay = Task.Delay(_options.Timeout, cancellationToken);
        var completed = await Task.WhenAny(ack.Task, delay).ConfigureAwait(false);
        if (completed == ack.Task)
        {
            return await ack.Task.ConfigureAwait(false);
        }

        cancellationToken.ThrowIfCancellationRequested();
        throw new TimeoutException(
            $"WebRTC product-control smoke did not receive its echoed raw control chunk within {_options.Timeout.TotalSeconds:F0}s.");
    }

    private void OnMessageReceived(byte[] payload)
    {
        TaskCompletionSource<byte[]>? ack;
        byte[]? expected;
        lock (_gate)
        {
            ack = _ack;
            expected = _probePayload;
        }

        if (ack is null || expected is null)
        {
            return;
        }

        if (!payload.AsSpan().SequenceEqual(expected))
        {
            ack.TrySetException(new InvalidDataException(
                "WebRTC product-control smoke received a raw control chunk with a mismatched nonce or payload."));
            return;
        }

        ack.TrySetResult(payload);
    }

    private void WriteEvidence(
        LiveWebRtcProductControlContext context,
        byte[] sentPayload,
        byte[] receivedPayload,
        string nonce,
        DateTimeOffset sentAt,
        DateTimeOffset receivedAt)
    {
        if (_options.EvidencePath is null)
        {
            return;
        }

        var parent = Path.GetDirectoryName(_options.EvidencePath);
        if (!string.IsNullOrWhiteSpace(parent))
        {
            Directory.CreateDirectory(parent);
        }

        var evidence = new WebRtcProductControlSmokeEvidence(
            FactoryMode: "webrtc-product-control",
            RuntimeProfile: WebRtcProductControlTransportProvider.TransportProfile,
            Consumer: nameof(WebRtcProductControlSmokeClient),
            ProductControlTransportProfile: context.TransportProfile,
            SecureSessionState: context.SecureSessionState.ToString(),
            DataChannelLabel: context.DataChannelLabel,
            Role: context.Role,
            PeerDeviceId: context.PeerDeviceId,
            PeerPublicKeyFingerprint: context.PeerPublicKeyFingerprint,
            AdapterBinding: context.AdapterBinding,
            LocalEndpoint: context.LocalEndpoint,
            RemoteEndpoint: context.RemoteEndpoint,
            SelectedCandidatePair: context.SelectedCandidatePair,
            TransportBindingDigestHex: context.TransportBindingDigestHex,
            TimestampWindowMs: context.TimestampWindowMs,
            NonceHex: nonce,
            SentPayloadSha256Hex: Sha256Hex(sentPayload),
            ReceivedPayloadSha256Hex: Sha256Hex(receivedPayload),
            ProductSendCount: 1,
            ProductReceiveCount: 1,
            SentAtUnixMs: sentAt.ToUnixTimeMilliseconds(),
            ReceivedAtUnixMs: receivedAt.ToUnixTimeMilliseconds(),
            Scope: "Windows WinClient service runtime over raw mac-product-control-v1 helper transport; this proves WebRTC/DataChannel/IPC liveness only, not Mac product app handshake, SBWC session keys, or product signaling.");

        var json = JsonSerializer.Serialize(evidence, EvidenceJsonOptions);
        var tmp = _options.EvidencePath + ".tmp";
        File.WriteAllText(tmp, json, new UTF8Encoding(false));
        File.Move(tmp, _options.EvidencePath, overwrite: true);
    }

    private static string Sha256Hex(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private sealed record WebRtcProductControlSmokeEvidence(
        string FactoryMode,
        string RuntimeProfile,
        string Consumer,
        string ProductControlTransportProfile,
        string SecureSessionState,
        string DataChannelLabel,
        string Role,
        string PeerDeviceId,
        string PeerPublicKeyFingerprint,
        string AdapterBinding,
        string LocalEndpoint,
        string RemoteEndpoint,
        string SelectedCandidatePair,
        string TransportBindingDigestHex,
        ulong TimestampWindowMs,
        string NonceHex,
        string SentPayloadSha256Hex,
        string ReceivedPayloadSha256Hex,
        int ProductSendCount,
        int ProductReceiveCount,
        long SentAtUnixMs,
        long ReceivedAtUnixMs,
        string Scope);
}
