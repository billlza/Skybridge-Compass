using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public sealed class WebRtcAuthenticatedRouteBindingStoreException : InvalidOperationException
{
    public WebRtcAuthenticatedRouteBindingStoreException(string message)
        : base(message)
    {
    }

    public WebRtcAuthenticatedRouteBindingStoreException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed class WebRtcAuthenticatedRouteBindingStoreOptions
{
    public WebRtcAuthenticatedRouteBindingStoreOptions(
        TimeSpan establishedSessionTtl,
        TimeSpan maxFutureClockSkew,
        int maxBindingsPerSession = 8)
    {
        if (establishedSessionTtl <= TimeSpan.Zero)
        {
            throw new InvalidOperationException("Authenticated route-binding session TTL must be positive.");
        }

        if (maxFutureClockSkew < TimeSpan.Zero)
        {
            throw new InvalidOperationException("Authenticated route-binding clock skew must not be negative.");
        }

        if (maxBindingsPerSession is < 1 or > 32)
        {
            throw new InvalidOperationException("Authenticated route-binding capacity must be between 1 and 32.");
        }

        EstablishedSessionTtl = establishedSessionTtl;
        MaxFutureClockSkew = maxFutureClockSkew;
        MaxBindingsPerSession = maxBindingsPerSession;
    }

    public static WebRtcAuthenticatedRouteBindingStoreOptions Default { get; } =
        new(TimeSpan.FromMinutes(5), TimeSpan.FromMinutes(2));

    public TimeSpan EstablishedSessionTtl { get; }

    public TimeSpan MaxFutureClockSkew { get; }

    public int MaxBindingsPerSession { get; }
}

public sealed class WebRtcAuthenticatedRouteBindingStore :
    IWebRtcProductControlRuntimeConsumer,
    IProductControlSessionSnapshotClient
{
    private static readonly DateTimeOffset SwiftReferenceDate =
        new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);
    private const int MaxJsonPayloadBytes = 1024;

    private readonly IWebRtcAppSessionKeyProvider _sessionKeyProvider;
    private readonly WebRtcAuthenticatedRouteBindingStoreOptions _options;
    private readonly object _gate = new();
    private ActiveRouteBindingSession? _active;
    private Exception? _lastFailure;

    public WebRtcAuthenticatedRouteBindingStore(
        IWebRtcAppSessionKeyProvider sessionKeyProvider,
        WebRtcAuthenticatedRouteBindingStoreOptions? options = null)
    {
        _sessionKeyProvider = sessionKeyProvider ?? throw new ArgumentNullException(nameof(sessionKeyProvider));
        _options = options ?? WebRtcAuthenticatedRouteBindingStoreOptions.Default;
    }

    public Task<WebRtcProductControlRuntimeLease> StartAsync(
        LiveWebRtcProductControlContext context,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(context);
        cancellationToken.ThrowIfCancellationRequested();
        if (context.SecureSessionState != WebRtcProductControlSecureSessionState.Established)
        {
            throw new WebRtcAuthenticatedRouteBindingStoreException(
                "Authenticated route-binding consumer requires an Established product-control SBWC session.");
        }
        var keys = _sessionKeyProvider.RequireEstablishedKeys(context);
        var lease = WebRtcProductControlRuntimeLease.Create();
        var active = new ActiveRouteBindingSession(
            lease,
            context,
            keys,
            DateTimeOffset.UtcNow.Add(_options.EstablishedSessionTtl));
        active.SetMessageHandler(message => OnMessageReceived(active, message));
        lock (_gate)
        {
            ClearActiveLocked();
            _lastFailure = null;
            _active = active;
            context.ControlPlane.MessageReceived += active.MessageHandler;
        }

        return Task.FromResult(lease);
    }

    public Task StopAsync(
        WebRtcProductControlRuntimeLease lease,
        CancellationToken cancellationToken = default)
    {
        lease.RequireValid();
        cancellationToken.ThrowIfCancellationRequested();
        lock (_gate)
        {
            if (_active is not null && _active.Lease == lease)
            {
                ClearActiveLocked();
            }
        }

        return Task.CompletedTask;
    }

    public ProductControlSessionSnapshotResult Capture(
        DiscoveryBrowserPeerCandidate candidate,
        DateTimeOffset nowUtc)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        lock (_gate)
        {
            if (_active is null)
            {
                return new(
                    null,
                    ProductControlSessionSnapshotUnavailableReason.NoEstablishedSession,
                    _lastFailure is null
                        ? "No established product-control route-binding session is active."
                        : $"Authenticated route-binding session is unavailable after fail-closed error: {_lastFailure.GetType().Name}.");
            }

            if (_active.SessionExpiresAtUtc <= nowUtc)
            {
                return new(
                    null,
                    ProductControlSessionSnapshotUnavailableReason.NoEstablishedSession,
                    "The established product-control route-binding session expired.");
            }

            return new(
                new EstablishedProductControlSessionSnapshot(
                    _active.Keys.SessionId,
                    _active.Context.PeerDeviceId,
                    _active.Context.PeerPublicKeyFingerprint,
                    WebRtcProductControlSecureSessionState.Established.ToString(),
                    _active.SessionExpiresAtUtc)
                {
                    AuthenticatedRouteBindings = _active.Bindings.ToArray()
                },
                null,
                $"Established product-control route-binding session with {_active.Bindings.Count} authenticated routes.");
        }
    }

    private void OnMessageReceived(
        ActiveRouteBindingSession expectedOwner,
        byte[] message)
    {
        ArgumentNullException.ThrowIfNull(message);
        lock (_gate)
        {
            if (!ReferenceEquals(_active, expectedOwner))
            {
                return;
            }

            var active = expectedOwner;
            try
            {
                if (!TryOpenRouteBindingPayload(message, active, out var opened))
                {
                    return;
                }

                var decoded = WebRtcAuthenticatedRouteBindingCodec.Decode(opened.Payload);
                var binding = ValidateAndProject(decoded, opened, active);
                InstallBinding(active, binding);
            }
            catch (Exception ex) when (
                ex is WebRtcAuthenticatedRouteBindingException
                    or WebRtcAuthenticatedRouteBindingStoreException
                    or WebRtcAppSecureEnvelopeException
                    or WebRtcAppSecureReplayException
                    or JsonException)
            {
                FailClosedLocked(active, ex);
            }
        }
    }

    private bool TryOpenRouteBindingPayload(
        byte[] message,
        ActiveRouteBindingSession active,
        out WebRtcAppSecureOpenedPayload opened)
    {
        opened = default!;
        if (!IsSbwcFrame(message.AsSpan()))
        {
            return false;
        }

        var header = WebRtcAppSecureEnvelope.ParseHeader(message.AsSpan());
        if (header.PacketType != WebRtcAppSecurePacketType.AppControl)
        {
            return false;
        }

        opened = WebRtcControlChannelCodec.DecryptAppPayload(
            message,
            active.Keys,
            new[] { WebRtcAppSecurePacketType.AppControl });
        active.ReplayWindow.ValidateAndRecord(opened);
        if (!ContainsRouteBindingMessage(opened.Payload))
        {
            return false;
        }

        return true;
    }

    private static bool ContainsRouteBindingMessage(byte[] payload)
    {
        if (payload.Length > MaxJsonPayloadBytes)
        {
            throw new WebRtcAuthenticatedRouteBindingStoreException(
                $"Authenticated route-binding JSON AppControl payload exceeded {MaxJsonPayloadBytes} bytes.");
        }

        using var document = JsonDocument.Parse(payload);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new WebRtcAuthenticatedRouteBindingStoreException(
                "Authenticated route-binding AppControl payload must be a JSON object.");
        }

        return root.TryGetProperty(WebRtcAuthenticatedRouteBindingCodec.MessageType, out _);
    }

    private AuthenticatedProductRouteBinding ValidateAndProject(
        WebRtcAuthenticatedRouteBindingPayload payload,
        WebRtcAppSecureOpenedPayload opened,
        ActiveRouteBindingSession active)
    {
        if (!string.Equals(payload.LocalDeviceId, active.Context.PeerDeviceId, StringComparison.Ordinal))
        {
            throw new WebRtcAuthenticatedRouteBindingStoreException(
                "Authenticated route-binding localDeviceId does not match the established peer device id.");
        }

        if (!string.Equals(
            payload.RouteAuthorityProtocolPublicKeyFingerprint,
            active.Context.PeerPublicKeyFingerprint,
            StringComparison.Ordinal))
        {
            throw new WebRtcAuthenticatedRouteBindingStoreException(
                "Authenticated route-binding authority fingerprint does not match the established peer fingerprint.");
        }

        if (string.IsNullOrWhiteSpace(active.Context.LocalDeviceId))
        {
            throw new WebRtcAuthenticatedRouteBindingStoreException(
                "Authenticated route-binding consumer requires the local receiver device id.");
        }

        if (!IsLowerHex(active.Context.LocalPublicKeyFingerprint, 64))
        {
            throw new WebRtcAuthenticatedRouteBindingStoreException(
                "Authenticated route-binding consumer requires the local receiver protocol fingerprint.");
        }

        if (!string.Equals(payload.RemoteDeviceId, active.Context.LocalDeviceId, StringComparison.Ordinal))
        {
            throw new WebRtcAuthenticatedRouteBindingStoreException(
                "Authenticated route-binding receiver device id does not match the local product-control authority.");
        }

        if (!string.Equals(
            payload.RemoteProtocolPublicKeyFingerprint,
            active.Context.LocalPublicKeyFingerprint,
            StringComparison.Ordinal))
        {
            throw new WebRtcAuthenticatedRouteBindingStoreException(
                "Authenticated route-binding receiver fingerprint does not match the local product-control authority.");
        }

        if (!string.Equals(payload.SessionHashHex, LowerHex16(opened.SessionHash), StringComparison.Ordinal))
        {
            throw new WebRtcAuthenticatedRouteBindingStoreException(
                "Authenticated route-binding sessionHashHex does not match the SBWC session header.");
        }

        if (!string.Equals(payload.TranscriptPrefixHex, LowerHex16(opened.TranscriptPrefix), StringComparison.Ordinal))
        {
            throw new WebRtcAuthenticatedRouteBindingStoreException(
                "Authenticated route-binding transcriptPrefixHex does not match the SBWC session header.");
        }

        var now = DateTimeOffset.UtcNow;
        var sentAt = SwiftDateSecondsToUtc(payload.SentAt);
        var expiresAt = SwiftDateSecondsToUtc(payload.ExpiresAt);
        if (sentAt > now.Add(_options.MaxFutureClockSkew))
        {
            throw new WebRtcAuthenticatedRouteBindingStoreException(
                "Authenticated route-binding sentAt is too far in the future.");
        }

        if (expiresAt <= now)
        {
            throw new WebRtcAuthenticatedRouteBindingStoreException(
                "Authenticated route-binding is already expired.");
        }

        var kind = payload.Kind switch
        {
            "fileTransfer" => ProductSessionActionKind.FileTransfer,
            "remoteDesktop" => ProductSessionActionKind.RemoteDesktop,
            _ => throw new WebRtcAuthenticatedRouteBindingStoreException(
                "Authenticated route-binding kind is unsupported.")
        };
        RequireServiceMatchesKind(kind, payload.ServiceType);

        return new AuthenticatedProductRouteBinding(
            kind,
            payload.ServiceType,
            payload.HostName,
            payload.Port,
            payload.InstanceName,
            payload.EndpointProvenance,
            expiresAt);
    }

    private void InstallBinding(
        ActiveRouteBindingSession active,
        AuthenticatedProductRouteBinding binding)
    {
        for (var index = active.Bindings.Count - 1; index >= 0; index--)
        {
            var existing = active.Bindings[index];
            if (existing.Kind == binding.Kind &&
                string.Equals(existing.Service, binding.Service, StringComparison.Ordinal) &&
                string.Equals(existing.InstanceName, binding.InstanceName, StringComparison.Ordinal) &&
                string.Equals(existing.HostName, binding.HostName, StringComparison.Ordinal) &&
                existing.Port == binding.Port)
            {
                active.Bindings.RemoveAt(index);
            }
        }

        if (active.Bindings.Count >= _options.MaxBindingsPerSession)
        {
            throw new WebRtcAuthenticatedRouteBindingStoreException(
                "Authenticated route-binding session exceeded its route capacity.");
        }

        active.Bindings.Add(binding);
    }

    private void FailClosedLocked(ActiveRouteBindingSession active, Exception ex)
    {
        _lastFailure = ex;
        if (ReferenceEquals(_active, active))
        {
            ClearActiveLocked();
        }
    }

    private void ClearActiveLocked()
    {
        if (_active is null)
        {
            return;
        }

        _active.Context.ControlPlane.MessageReceived -= _active.MessageHandler;
        _active.Dispose();
        _active = null;
    }

    private static void RequireServiceMatchesKind(ProductSessionActionKind kind, string serviceType)
    {
        var expected = kind switch
        {
            ProductSessionActionKind.FileTransfer => SkyBridgeProtocolConstants.FileTransferDnsSdService,
            ProductSessionActionKind.RemoteDesktop => SkyBridgeProtocolConstants.RemoteDesktopDnsSdService,
            _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "Unknown product action kind.")
        };
        if (!string.Equals(serviceType, expected, StringComparison.Ordinal))
        {
            throw new WebRtcAuthenticatedRouteBindingStoreException(
                "Authenticated route-binding serviceType does not match its action kind.");
        }
    }

    private static bool IsSbwcFrame(ReadOnlySpan<byte> message) =>
        message.Length >= 4 && BinaryPrimitives.ReadUInt32BigEndian(message[..4]) == WebRtcAppSecureEnvelope.Magic;

    private static string LowerHex16(ulong value) =>
        value.ToString("x16", CultureInfo.InvariantCulture);

    private static bool IsLowerHex(string value, int length) =>
        value.Length == length && value.All(static current => current is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static DateTimeOffset SwiftDateSecondsToUtc(double seconds)
    {
        if (double.IsNaN(seconds) || double.IsInfinity(seconds))
        {
            throw new WebRtcAuthenticatedRouteBindingStoreException(
                "Authenticated route-binding timestamp must be finite.");
        }

        try
        {
            return SwiftReferenceDate.AddSeconds(seconds);
        }
        catch (ArgumentOutOfRangeException ex)
        {
            throw new WebRtcAuthenticatedRouteBindingStoreException(
                "Authenticated route-binding timestamp is outside the supported UTC range.",
                ex);
        }
    }

    private sealed class ActiveRouteBindingSession : IDisposable
    {
        public ActiveRouteBindingSession(
            WebRtcProductControlRuntimeLease lease,
            LiveWebRtcProductControlContext context,
            WebRtcAppSecureSessionKeys keys,
            DateTimeOffset sessionExpiresAtUtc)
        {
            Lease = lease;
            Context = context;
            Keys = keys;
            SessionExpiresAtUtc = sessionExpiresAtUtc;
        }

        public WebRtcProductControlRuntimeLease Lease { get; }

        public LiveWebRtcProductControlContext Context { get; }

        public WebRtcAppSecureSessionKeys Keys { get; }

        public DateTimeOffset SessionExpiresAtUtc { get; }

        public List<AuthenticatedProductRouteBinding> Bindings { get; } = new();

        public WebRtcAppSecureReplayWindow ReplayWindow { get; } = new();

        public Action<byte[]> MessageHandler { get; private set; } =
            _ => throw new InvalidOperationException(
                "Authenticated route-binding message handler was used before owner binding.");

        public void SetMessageHandler(Action<byte[]> messageHandler)
        {
            ArgumentNullException.ThrowIfNull(messageHandler);
            MessageHandler = messageHandler;
        }

        public void Dispose() => Keys.Dispose();
    }
}
