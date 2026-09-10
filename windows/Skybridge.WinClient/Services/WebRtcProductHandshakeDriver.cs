using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public sealed class WebRtcProductHandshakeDriverException : InvalidOperationException
{
    public WebRtcProductHandshakeDriverException(string message)
        : base(message)
    {
    }

    public WebRtcProductHandshakeDriverException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed class WebRtcProductHandshakeDriverOptions
{
    public WebRtcProductHandshakeDriverOptions(TimeSpan messageTimeout, int maxQueuedInboundMessages = 4)
    {
        if (messageTimeout <= TimeSpan.Zero)
        {
            throw new InvalidOperationException("WebRTC product handshake message timeout must be positive.");
        }

        if (maxQueuedInboundMessages is < 1 or > 16)
        {
            throw new InvalidOperationException(
                "WebRTC product handshake inbound queue capacity must be between 1 and 16 messages.");
        }

        MessageTimeout = messageTimeout;
        MaxQueuedInboundMessages = maxQueuedInboundMessages;
    }

    public static WebRtcProductHandshakeDriverOptions Default { get; } = new(TimeSpan.FromSeconds(30));

    public TimeSpan MessageTimeout { get; }

    public int MaxQueuedInboundMessages { get; }
}

public sealed class UnavailableWebRtcProductHandshakeCryptoProvider : IProductHandshakeCryptoProvider
{
    public ValueTask<WebRtcProductHandshakeMessageA> CreateInitiatorMessageAAsync(
        ProductHandshakePeerContext context,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(context);
        _ = cancellationToken;
        throw new WebRtcProductHandshakeDriverException(
            "WebRTC product handshake crypto provider is unavailable. "
            + "Refusing to send MessageA without real identity signing and key agreement.");
    }

    public ValueTask<ProductHandshakeSharedSecret> OpenResponderMessageBAsync(
        ProductHandshakePeerContext context,
        WebRtcProductHandshakeMessageA messageA,
        ReadOnlyMemory<byte> transcriptHashA,
        WebRtcProductHandshakeMessageB messageB,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(messageA);
        ArgumentNullException.ThrowIfNull(messageB);
        _ = transcriptHashA;
        _ = cancellationToken;
        throw new WebRtcProductHandshakeDriverException(
            "WebRTC product handshake crypto provider is unavailable. "
            + "Refusing to open MessageB or install SBWC session keys.");
    }

    public ValueTask<WebRtcProductHandshakeResponderMaterial> CreateResponderMessageBAsync(
        ProductHandshakePeerContext context,
        WebRtcProductHandshakeMessageA messageA,
        ReadOnlyMemory<byte> transcriptHashA,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(messageA);
        _ = transcriptHashA;
        _ = cancellationToken;
        throw new WebRtcProductHandshakeDriverException(
            "WebRTC product handshake crypto provider is unavailable. "
            + "Refusing to create responder MessageB or install SBWC session keys.");
    }

    public void AbortInitiatorSecret(ReadOnlyMemory<byte> transcriptHashA)
    {
        if (transcriptHashA.Length != WebRtcProductHandshakeCodec.TranscriptHashLength)
        {
            throw new WebRtcProductHandshakeDriverException(
                "WebRTC product handshake crypto provider abort requires a 32-byte transcriptHashA.");
        }
    }
}

public sealed record WebRtcProductHandshakeInitiatorResult(
    LiveWebRtcProductControlContext EstablishedContext,
    ushort SelectedSuiteWireId,
    string SessionId,
    int MessageABytes,
    string MessageASha256,
    int MessageBBytes,
    string MessageBSha256,
    ulong SessionHash,
    ulong TranscriptPrefix,
    bool ResponderIdentityFingerprintVerified,
    bool ResponderSignatureVerified,
    bool ResponderFinishedVerified,
    bool InitiatorFinishedSent);

public sealed record WebRtcProductHandshakeResponderResult(
    LiveWebRtcProductControlContext EstablishedContext,
    ushort SelectedSuiteWireId,
    string SessionId,
    int MessageABytes,
    string MessageASha256,
    int MessageBBytes,
    string MessageBSha256,
    ulong SessionHash,
    ulong TranscriptPrefix,
    bool InitiatorIdentityFingerprintVerified,
    bool InitiatorSignatureVerified,
    bool ResponderFinishedSent,
    bool InitiatorFinishedVerified);

public sealed class WebRtcProductHandshakeDriver
{
    private readonly ProductHandshakeCore _handshake;
    private readonly WebRtcProductSecureSessionStore _sessionStore;
    private readonly WebRtcProductHandshakeDriverOptions _options;

    public WebRtcProductHandshakeDriver(IProductHandshakeCryptoProvider cryptoProvider,
        WebRtcProductSecureSessionStore sessionStore, WebRtcProductHandshakeDriverOptions? options = null)
    {
        _sessionStore = sessionStore ?? throw new ArgumentNullException(nameof(sessionStore));
        _options = options ?? WebRtcProductHandshakeDriverOptions.Default;
        _handshake = new ProductHandshakeCore(cryptoProvider, _options.MessageTimeout);
    }

    public async Task<LiveWebRtcProductControlContext> StartInitiatorAsync(
        LiveWebRtcProductControlContext transportContext, CancellationToken cancellationToken = default) =>
        (await StartInitiatorWithResultAsync(transportContext, cancellationToken).ConfigureAwait(false)).EstablishedContext;

    public async Task<LiveWebRtcProductControlContext> StartResponderAsync(
        LiveWebRtcProductControlContext transportContext, CancellationToken cancellationToken = default) =>
        (await StartResponderWithResultAsync(transportContext, cancellationToken).ConfigureAwait(false)).EstablishedContext;

    public async Task<WebRtcProductHandshakeInitiatorResult> StartInitiatorWithResultAsync(
        LiveWebRtcProductControlContext transportContext, CancellationToken cancellationToken = default)
    {
        ValidateTransportContext(transportContext);
        await using var transport = new ProductControlMessageInbox(transportContext.ControlPlane, _options.MaxQueuedInboundMessages);
        try
        {
            using var result = await _handshake.StartInitiatorAsync(transport, PeerContext(transportContext), cancellationToken).ConfigureAwait(false);
            using var keys = WebRtcProductHandshakeSessionKeys.ToWebRtcKeys(result.Keys);
            var established = _sessionStore.InstallEstablishedSession(transportContext, keys, result.SuiteWireId);
            return new WebRtcProductHandshakeInitiatorResult(established, result.SuiteWireId, keys.SessionId,
                result.MessageABytes, result.MessageASha256, result.MessageBBytes, result.MessageBSha256,
                WebRtcAppSecureEnvelope.SessionIdHash(keys.SessionId), WebRtcAppSecureEnvelope.TranscriptPrefix(keys.TranscriptHash.Span),
                ResponderIdentityFingerprintVerified: true, ResponderSignatureVerified: true,
                ResponderFinishedVerified: true, InitiatorFinishedSent: true);
        }
        catch (ProductHandshakeException ex) { throw new WebRtcProductHandshakeDriverException(ex.Message, ex); }
    }

    public async Task<WebRtcProductHandshakeResponderResult> StartResponderWithResultAsync(
        LiveWebRtcProductControlContext transportContext, CancellationToken cancellationToken = default)
    {
        ValidateTransportContext(transportContext);
        await using var transport = new ProductControlMessageInbox(transportContext.ControlPlane, _options.MaxQueuedInboundMessages);
        try
        {
            using var result = await _handshake.AcceptResponderAsync(transport, PeerContext(transportContext),
                cancellationToken: cancellationToken).ConfigureAwait(false);
            using var keys = WebRtcProductHandshakeSessionKeys.ToWebRtcKeys(result.Keys);
            var established = _sessionStore.InstallEstablishedSession(transportContext, keys, result.SuiteWireId);
            return new WebRtcProductHandshakeResponderResult(established, result.SuiteWireId, keys.SessionId,
                result.MessageABytes, result.MessageASha256, result.MessageBBytes, result.MessageBSha256,
                WebRtcAppSecureEnvelope.SessionIdHash(keys.SessionId), WebRtcAppSecureEnvelope.TranscriptPrefix(keys.TranscriptHash.Span),
                InitiatorIdentityFingerprintVerified: true, InitiatorSignatureVerified: true,
                ResponderFinishedSent: true, InitiatorFinishedVerified: true);
        }
        catch (ProductHandshakeException ex) { throw new WebRtcProductHandshakeDriverException(ex.Message, ex); }
    }

    private static ProductHandshakePeerContext PeerContext(LiveWebRtcProductControlContext context) =>
        new(context.PeerDeviceId, context.PeerPublicKeyFingerprint);

    private static void ValidateTransportContext(LiveWebRtcProductControlContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        if (context.SecureSessionState != WebRtcProductControlSecureSessionState.TransportOnly)
        {
            throw new WebRtcProductHandshakeDriverException("WebRTC product handshake must start from a TransportOnly product-control context.");
        }
        if (!context.ControlPlane.IsConnected)
        {
            throw new WebRtcProductHandshakeDriverException("WebRTC product handshake requires a connected product-control plane.");
        }
    }

    private sealed class ProductControlMessageInbox : IProductHandshakeTransport, IAsyncDisposable
    {
        private readonly IWebRtcProductControlPlane _controlPlane;
        private readonly Queue<byte[]> _messages = new();
        private readonly SemaphoreSlim _signal = new(0);
        private readonly object _gate = new();
        private readonly int _maxQueuedMessages;
        private Exception? _failure;
        private bool _disposed;

        public ProductControlMessageInbox(IWebRtcProductControlPlane controlPlane, int maxQueuedMessages)
        {
            _controlPlane = controlPlane ?? throw new ArgumentNullException(nameof(controlPlane));
            _maxQueuedMessages = maxQueuedMessages;
            _controlPlane.MessageReceived += OnMessageReceived;
        }

        public Task SendAsync(ReadOnlyMemory<byte> frame, CancellationToken cancellationToken = default) =>
            _controlPlane.SendAsync(frame, cancellationToken);

        public async Task<ReadOnlyMemory<byte>> ReadAsync(CancellationToken cancellationToken = default)
        {
            await _signal.WaitAsync(cancellationToken).ConfigureAwait(false);
            lock (_gate)
            {
                if (_failure is not null) { throw _failure; }
                if (_messages.Count == 0)
                {
                    throw new WebRtcProductHandshakeDriverException("WebRTC product handshake inbox signaled without frame bytes.");
                }
                return _messages.Dequeue();
            }
        }

        public ValueTask DisposeAsync()
        {
            lock (_gate)
            {
                if (_disposed)
                {
                    return ValueTask.CompletedTask;
                }

                _disposed = true;
                _messages.Clear();
                _failure = null;
            }

            _controlPlane.MessageReceived -= OnMessageReceived;
            _signal.Dispose();
            return ValueTask.CompletedTask;
        }

        private void OnMessageReceived(byte[] message)
        {
            ArgumentNullException.ThrowIfNull(message);
            lock (_gate)
            {
                if (_disposed)
                {
                    return;
                }

                if (_failure is not null)
                {
                    return;
                }

                if (_messages.Count >= _maxQueuedMessages)
                {
                    _failure = new WebRtcProductHandshakeDriverException(
                        $"WebRTC product handshake inbound queue exceeded {_maxQueuedMessages} messages before the driver could process them.");
                }
                else
                {
                    _messages.Enqueue(message.ToArray());
                }
                _signal.Release();
            }
        }
    }
}
