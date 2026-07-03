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

public interface IWebRtcProductHandshakeCryptoProvider
{
    ValueTask<WebRtcProductHandshakeMessageA> CreateInitiatorMessageAAsync(
        LiveWebRtcProductControlContext context,
        CancellationToken cancellationToken = default);

    ValueTask<ReadOnlyMemory<byte>> OpenResponderMessageBAsync(
        LiveWebRtcProductControlContext context,
        WebRtcProductHandshakeMessageA messageA,
        ReadOnlyMemory<byte> transcriptHashA,
        WebRtcProductHandshakeMessageB messageB,
        CancellationToken cancellationToken = default);
}

public sealed class UnavailableWebRtcProductHandshakeCryptoProvider : IWebRtcProductHandshakeCryptoProvider
{
    public ValueTask<WebRtcProductHandshakeMessageA> CreateInitiatorMessageAAsync(
        LiveWebRtcProductControlContext context,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(context);
        _ = cancellationToken;
        throw new WebRtcProductHandshakeDriverException(
            "WebRTC product handshake crypto provider is unavailable. "
            + "Refusing to send MessageA without real identity signing and key agreement.");
    }

    public ValueTask<ReadOnlyMemory<byte>> OpenResponderMessageBAsync(
        LiveWebRtcProductControlContext context,
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

public sealed class WebRtcProductHandshakeDriver
{
    private readonly IWebRtcProductHandshakeCryptoProvider _cryptoProvider;
    private readonly WebRtcProductSecureSessionStore _sessionStore;
    private readonly WebRtcProductHandshakeDriverOptions _options;

    public WebRtcProductHandshakeDriver(
        IWebRtcProductHandshakeCryptoProvider cryptoProvider,
        WebRtcProductSecureSessionStore sessionStore,
        WebRtcProductHandshakeDriverOptions? options = null)
    {
        _cryptoProvider = cryptoProvider ?? throw new ArgumentNullException(nameof(cryptoProvider));
        _sessionStore = sessionStore ?? throw new ArgumentNullException(nameof(sessionStore));
        _options = options ?? WebRtcProductHandshakeDriverOptions.Default;
    }

    public async Task<LiveWebRtcProductControlContext> StartInitiatorAsync(
        LiveWebRtcProductControlContext transportContext,
        CancellationToken cancellationToken = default)
    {
        var result = await StartInitiatorWithResultAsync(transportContext, cancellationToken)
            .ConfigureAwait(false);
        return result.EstablishedContext;
    }

    public async Task<WebRtcProductHandshakeInitiatorResult> StartInitiatorWithResultAsync(
        LiveWebRtcProductControlContext transportContext,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(transportContext);
        ValidateTransportContext(transportContext);

        var messageA = await _cryptoProvider
            .CreateInitiatorMessageAAsync(transportContext, cancellationToken)
            .ConfigureAwait(false);
        ArgumentNullException.ThrowIfNull(messageA);
        ValidateMessageA(messageA);

        var messageAFrame = messageA.Encode();
        var messageASha256 = Sha256Hex(messageAFrame);
        var transcriptHashA = SHA256.HashData(messageA.EncodeWithoutSignature());
        await using var inbox = new ProductControlMessageInbox(
            transportContext.ControlPlane,
            _options.MaxQueuedInboundMessages);

        await transportContext.ControlPlane
            .SendAsync(messageAFrame, cancellationToken)
            .ConfigureAwait(false);

        var messageBFrame = await inbox
            .ReadAsync("MessageB", _options.MessageTimeout, cancellationToken)
            .ConfigureAwait(false);
        var messageBSha256 = Sha256Hex(messageBFrame);
        RejectSecureEnvelopeBeforeEstablished(messageBFrame.AsSpan(), "MessageB");
        var messageB = DecodeMessageB(messageBFrame);
        ValidateResponderIdentity(transportContext, messageB);
        ValidateResponderSelection(messageA, messageB);

        byte[] sharedSecret = Array.Empty<byte>();
        try
        {
            sharedSecret = (await _cryptoProvider
                    .OpenResponderMessageBAsync(
                        transportContext,
                        messageA,
                        transcriptHashA,
                        messageB,
                        cancellationToken)
                    .ConfigureAwait(false))
                .ToArray();
            RequireSharedSecret(sharedSecret);

            var transcriptHashB = SHA256.HashData(messageB.EncodeWithoutSignature());
            var keys = WebRtcProductHandshakeSessionKeys.Derive(
                sharedSecret,
                messageB.SelectedSuiteWireId,
                transcriptHashA,
                transcriptHashB,
                messageA.ClientNonce.Span,
                messageB.ServerNonce.Span,
                WebRtcAppSecureRole.Initiator);
            try
            {
                var responderFinishedFrame = await inbox
                    .ReadAsync("responder Finished", _options.MessageTimeout, cancellationToken)
                    .ConfigureAwait(false);
                RejectSecureEnvelopeBeforeEstablished(responderFinishedFrame.AsSpan(), "responder Finished");
                var responderFinished = DecodeFinished(responderFinishedFrame);
                if (!WebRtcProductHandshakeSessionKeys.VerifyFinished(
                        responderFinished,
                        keys,
                        WebRtcAppSecureRole.Responder))
                {
                    throw new WebRtcProductHandshakeDriverException(
                        "WebRTC product handshake responder Finished MAC verification failed.");
                }

                var initiatorFinished = WebRtcProductHandshakeSessionKeys.CreateFinished(keys);
                await transportContext.ControlPlane
                    .SendAsync(initiatorFinished.Encode(), cancellationToken)
                    .ConfigureAwait(false);

                var establishedContext = _sessionStore.InstallEstablishedSession(
                    transportContext,
                    keys,
                    messageB.SelectedSuiteWireId);
                return new WebRtcProductHandshakeInitiatorResult(
                    establishedContext,
                    messageB.SelectedSuiteWireId,
                    keys.SessionId,
                    messageAFrame.Length,
                    messageASha256,
                    messageBFrame.Length,
                    messageBSha256,
                    WebRtcAppSecureEnvelope.SessionIdHash(keys.SessionId),
                    WebRtcAppSecureEnvelope.TranscriptPrefix(keys.TranscriptHash.Span),
                    ResponderIdentityFingerprintVerified: true,
                    ResponderSignatureVerified: true,
                    ResponderFinishedVerified: true,
                    InitiatorFinishedSent: true);
            }
            finally
            {
                keys.Dispose();
            }
        }
        finally
        {
            if (sharedSecret.Length > 0)
            {
                CryptographicOperations.ZeroMemory(sharedSecret);
            }
        }
    }

    private static void ValidateTransportContext(LiveWebRtcProductControlContext transportContext)
    {
        if (transportContext.SecureSessionState != WebRtcProductControlSecureSessionState.TransportOnly)
        {
            throw new WebRtcProductHandshakeDriverException(
                "WebRTC product handshake must start from a TransportOnly product-control context.");
        }

        if (!transportContext.ControlPlane.IsConnected)
        {
            throw new WebRtcProductHandshakeDriverException(
                "WebRTC product handshake requires a connected product-control plane.");
        }
    }

    private static void ValidateMessageA(WebRtcProductHandshakeMessageA messageA)
    {
        if (messageA.SupportedSuiteWireIds.Count == 0)
        {
            throw new WebRtcProductHandshakeDriverException(
                "WebRTC product handshake provider created MessageA without supported suites.");
        }

        if (messageA.KeyShares.Count == 0)
        {
            throw new WebRtcProductHandshakeDriverException(
                "WebRTC product handshake provider created MessageA without key shares.");
        }
    }

    private static void ValidateResponderSelection(
        WebRtcProductHandshakeMessageA messageA,
        WebRtcProductHandshakeMessageB messageB)
    {
        if (!messageA.SupportedSuiteWireIds.Contains(messageB.SelectedSuiteWireId))
        {
            throw new WebRtcProductHandshakeDriverException(
                "WebRTC product handshake responder selected a suite that was not offered in MessageA.");
        }

        if (messageA.Policy.RequirePqc && IsClassicSuite(messageB.SelectedSuiteWireId))
        {
            throw new WebRtcProductHandshakeDriverException(
                "WebRTC product handshake responder selected a classic suite while MessageA requires PQC.");
        }

        if (!messageA.Policy.AllowClassicFallback &&
            !string.Equals(messageA.Policy.MinimumTier, "classic", StringComparison.Ordinal) &&
            IsClassicSuite(messageB.SelectedSuiteWireId))
        {
            throw new WebRtcProductHandshakeDriverException(
                "WebRTC product handshake responder selected a classic suite while classic fallback is disabled.");
        }
    }

    private static void ValidateResponderIdentity(
        LiveWebRtcProductControlContext transportContext,
        WebRtcProductHandshakeMessageB messageB)
    {
        string actualFingerprint;
        try
        {
            var identity = WebRtcProductProtocolIdentityPublicKey.DecodeWithLegacyFallback(
                messageB.IdentityPublicKey.Span);
            actualFingerprint = identity.AuthoritativeFingerprint;
        }
        catch (WebRtcProductHandshakeCodecException ex)
        {
            throw new WebRtcProductHandshakeDriverException(
                "WebRTC product handshake MessageB identity public key could not be decoded as a protocol identity.",
                ex);
        }

        if (!string.Equals(actualFingerprint, transportContext.PeerPublicKeyFingerprint, StringComparison.Ordinal))
        {
            throw new WebRtcProductHandshakeDriverException(
                "WebRTC product handshake MessageB identity public key fingerprint does not match the paired peer authoritative fingerprint.");
        }
    }

    private static bool IsClassicSuite(ushort suiteWireId) =>
        suiteWireId is WebRtcProductHandshakeCodec.SuiteX25519Ed25519
            or WebRtcProductHandshakeCodec.SuiteP256Ecdsa;

    private static string Sha256Hex(ReadOnlySpan<byte> value) =>
        Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();

    private static void RequireSharedSecret(ReadOnlySpan<byte> sharedSecret)
    {
        if (sharedSecret.Length != WebRtcProductHandshakeSessionKeys.SharedSecretLength)
        {
            throw new WebRtcProductHandshakeDriverException(
                $"WebRTC product handshake provider returned a shared secret with length {sharedSecret.Length}; expected {WebRtcProductHandshakeSessionKeys.SharedSecretLength}.");
        }
    }

    private static WebRtcProductHandshakeMessageB DecodeMessageB(byte[] frame)
    {
        try
        {
            return WebRtcProductHandshakeCodec.DecodeMessageB(frame);
        }
        catch (Exception ex) when (ex is WebRtcProductHandshakeCodecException or InvalidDataException)
        {
            throw new WebRtcProductHandshakeDriverException(
                "WebRTC product handshake failed to decode responder MessageB.",
                ex);
        }
    }

    private static WebRtcProductHandshakeFinished DecodeFinished(byte[] frame)
    {
        try
        {
            return WebRtcProductHandshakeCodec.DecodeFinished(frame);
        }
        catch (Exception ex) when (ex is WebRtcProductHandshakeCodecException or InvalidDataException)
        {
            throw new WebRtcProductHandshakeDriverException(
                "WebRTC product handshake failed to decode responder Finished.",
                ex);
        }
    }

    private static void RejectSecureEnvelopeBeforeEstablished(ReadOnlySpan<byte> frame, string expectedFrame)
    {
        if (WebRtcControlChannelCodec.IsLikelySecureEnvelope(frame))
        {
            throw new WebRtcProductHandshakeDriverException(
                $"WebRTC product handshake received an SBWC envelope while waiting for {expectedFrame}; refusing AppControl before session establishment.");
        }
    }

    private sealed class ProductControlMessageInbox : IAsyncDisposable
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

        public async Task<byte[]> ReadAsync(
            string expectedMessage,
            TimeSpan timeout,
            CancellationToken cancellationToken)
        {
            using var timeoutCts = new CancellationTokenSource(timeout);
            using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
            try
            {
                await _signal.WaitAsync(linkedCts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            {
                throw new TimeoutException(
                    $"WebRTC product handshake timed out waiting for {expectedMessage} after {timeout.TotalSeconds:F0}s.");
            }

            lock (_gate)
            {
                if (_failure is not null)
                {
                    throw _failure;
                }

                if (_messages.Count == 0)
                {
                    throw new WebRtcProductHandshakeDriverException(
                        $"WebRTC product handshake inbox signaled without {expectedMessage} bytes.");
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
            }

            _signal.Release();
        }
    }
}
