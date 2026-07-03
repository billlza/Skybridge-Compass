using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public sealed class WebRtcAppControlBootstrapException : InvalidOperationException
{
    public WebRtcAppControlBootstrapException(string message)
        : base(message)
    {
    }

    public WebRtcAppControlBootstrapException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed class WebRtcAppControlBootstrapOptions
{
    public WebRtcAppControlBootstrapOptions(TimeSpan timeout, int maxQueuedInboundMessages = 8)
    {
        if (timeout <= TimeSpan.Zero)
        {
            throw new InvalidOperationException("WebRTC AppControl bootstrap timeout must be positive.");
        }

        if (maxQueuedInboundMessages is < 1 or > 32)
        {
            throw new InvalidOperationException(
                "WebRTC AppControl bootstrap inbound queue capacity must be between 1 and 32 messages.");
        }

        Timeout = timeout;
        MaxQueuedInboundMessages = maxQueuedInboundMessages;
    }

    public static WebRtcAppControlBootstrapOptions Default { get; } = new(TimeSpan.FromSeconds(10));

    public TimeSpan Timeout { get; }

    public int MaxQueuedInboundMessages { get; }
}

public sealed record WebRtcAppControlBootstrapResult(
    string SessionId,
    ulong PingId,
    ulong OutboundCounter,
    ulong InboundCounter,
    ulong SessionHash,
    ulong TranscriptPrefix,
    string ReceivedMessageKind);

public interface IWebRtcAppControlBootstrapClient
{
    Task<WebRtcAppControlBootstrapResult> ExchangePingAsync(
        LiveWebRtcProductControlContext establishedContext,
        ushort suiteWireId,
        CancellationToken cancellationToken = default);
}

public sealed class WebRtcAppControlBootstrapClient : IWebRtcAppControlBootstrapClient
{
    private static readonly JsonWriterOptions JsonWriterOptions = new()
    {
        Indented = false
    };

    private readonly WebRtcProductSecureSessionStore _sessionStore;
    private readonly WebRtcAppControlBootstrapOptions _options;
    private readonly WebRtcAppSecureReplayWindow _replayWindow = new();
    private readonly object _counterGate = new();
    private ulong _nextOutboundCounter = 1;

    public WebRtcAppControlBootstrapClient(
        WebRtcProductSecureSessionStore sessionStore,
        WebRtcAppControlBootstrapOptions? options = null)
    {
        _sessionStore = sessionStore ?? throw new ArgumentNullException(nameof(sessionStore));
        _options = options ?? WebRtcAppControlBootstrapOptions.Default;
    }

    public async Task<WebRtcAppControlBootstrapResult> ExchangePingAsync(
        LiveWebRtcProductControlContext establishedContext,
        ushort suiteWireId,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(establishedContext);
        WebRtcProductHandshakeCodec.RequireKnownSuite(suiteWireId);

        using var keys = _sessionStore.RequireEstablishedKeys(
            establishedContext,
            suiteWireId,
            ExpectedRole(establishedContext));
        if (!establishedContext.ControlPlane.IsConnected)
        {
            throw new WebRtcAppControlBootstrapException(
                "WebRTC AppControl bootstrap requires a connected product-control plane.");
        }

        var pingId = RandomPingId();
        var outboundCounter = NextOutboundCounter();
        var plaintext = BuildPingPayload(pingId);
        var ciphertext = WebRtcControlChannelCodec.EncryptAppPayload(
            plaintext,
            keys,
            WebRtcAppSecurePacketType.AppControl,
            outboundCounter);

        await using var inbox = new AppControlMessageInbox(
            establishedContext.ControlPlane,
            _options.MaxQueuedInboundMessages);

        await establishedContext.ControlPlane
            .SendAsync(ciphertext, cancellationToken)
            .ConfigureAwait(false);

        var inboundFrame = await inbox
            .ReadAsync("AppControl pong", _options.Timeout, cancellationToken)
            .ConfigureAwait(false);
        var unwrapped = UnwrapTrafficPaddingIfNeeded(inboundFrame);
        var opened = OpenAndRecordAppControl(unwrapped, keys);
        var messageKind = RequirePong(opened.Payload, pingId);
        return new WebRtcAppControlBootstrapResult(
            keys.SessionId,
            pingId,
            outboundCounter,
            opened.Counter,
            opened.SessionHash,
            opened.TranscriptPrefix,
            messageKind);
    }

    private WebRtcAppSecureOpenedPayload OpenAndRecordAppControl(
        ReadOnlySpan<byte> ciphertext,
        WebRtcAppSecureSessionKeys keys)
    {
        try
        {
            var opened = WebRtcControlChannelCodec.DecryptAppPayload(
                ciphertext,
                keys,
                new[] { WebRtcAppSecurePacketType.AppControl });
            _replayWindow.ValidateAndRecord(opened);
            return opened;
        }
        catch (Exception ex) when (ex is WebRtcAppSecureEnvelopeException or WebRtcAppSecureReplayException)
        {
            throw new WebRtcAppControlBootstrapException(
                "WebRTC AppControl bootstrap failed to authenticate inbound AppControl payload.",
                ex);
        }
    }

    private static WebRtcAppSecureRole ExpectedRole(LiveWebRtcProductControlContext context) =>
        context.Role switch
        {
            "offer" => WebRtcAppSecureRole.Initiator,
            "answer" => WebRtcAppSecureRole.Responder,
            _ => throw new WebRtcAppControlBootstrapException(
                $"Unsupported WebRTC product-control role '{context.Role}' for AppControl bootstrap.")
        };

    private ulong NextOutboundCounter()
    {
        lock (_counterGate)
        {
            if (_nextOutboundCounter == ulong.MaxValue)
            {
                throw new WebRtcAppControlBootstrapException(
                    "WebRTC AppControl bootstrap outbound counter exhausted.");
            }

            return _nextOutboundCounter++;
        }
    }

    private static ulong RandomPingId()
    {
        Span<byte> bytes = stackalloc byte[8];
        RandomNumberGenerator.Fill(bytes);
        var value = BinaryPrimitives.ReadUInt64BigEndian(bytes);
        return value == 0 ? 1 : value;
    }

    private static byte[] BuildPingPayload(ulong pingId)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, JsonWriterOptions))
        {
            writer.WriteStartObject();
            writer.WriteStartObject("ping");
            writer.WriteNumber("id", pingId);
            writer.WriteEndObject();
            writer.WriteEndObject();
        }

        return stream.ToArray();
    }

    private static string RequirePong(ReadOnlySpan<byte> payload, ulong expectedPingId)
    {
        try
        {
            using var document = JsonDocument.Parse(payload.ToArray());
            if (document.RootElement.ValueKind != JsonValueKind.Object ||
                !document.RootElement.TryGetProperty("pong", out var pong) ||
                pong.ValueKind != JsonValueKind.Object ||
                !pong.TryGetProperty("id", out var idElement) ||
                idElement.ValueKind != JsonValueKind.Number ||
                !idElement.TryGetUInt64(out var actualId))
            {
                throw new WebRtcAppControlBootstrapException(
                    "WebRTC AppControl bootstrap expected a JSON AppMessage pong payload.");
            }

            if (actualId != expectedPingId)
            {
                throw new WebRtcAppControlBootstrapException(
                    "WebRTC AppControl bootstrap pong id does not match the outbound ping id.");
            }

            return "pong";
        }
        catch (JsonException ex)
        {
            throw new WebRtcAppControlBootstrapException(
                "WebRTC AppControl bootstrap received malformed JSON AppMessage payload.",
                ex);
        }
    }

    private static byte[] UnwrapTrafficPaddingIfNeeded(byte[] frame)
    {
        if (frame.Length < 8 ||
            frame[0] != 0x53 ||
            frame[1] != 0x42 ||
            frame[2] != 0x50 ||
            frame[3] != 0x32)
        {
            return frame;
        }

        var actualLength = BinaryPrimitives.ReadUInt32BigEndian(frame.AsSpan(4, 4));
        if (actualLength > frame.Length - 8)
        {
            throw new WebRtcAppControlBootstrapException(
                "WebRTC AppControl bootstrap received malformed SBP2 traffic padding.");
        }

        return frame.AsSpan(8, checked((int)actualLength)).ToArray();
    }

    private sealed class AppControlMessageInbox : IAsyncDisposable
    {
        private readonly IWebRtcProductControlPlane _controlPlane;
        private readonly Queue<byte[]> _messages = new();
        private readonly SemaphoreSlim _signal = new(0);
        private readonly object _gate = new();
        private readonly int _maxQueuedMessages;
        private Exception? _failure;
        private bool _disposed;

        public AppControlMessageInbox(IWebRtcProductControlPlane controlPlane, int maxQueuedMessages)
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
                    $"WebRTC AppControl bootstrap timed out waiting for {expectedMessage} after {timeout.TotalSeconds:F0}s.");
            }

            lock (_gate)
            {
                if (_failure is not null)
                {
                    throw _failure;
                }

                if (_messages.Count == 0)
                {
                    throw new WebRtcAppControlBootstrapException(
                        $"WebRTC AppControl bootstrap inbox signaled without {expectedMessage} bytes.");
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
                if (_disposed || _failure is not null)
                {
                    return;
                }

                if (_messages.Count >= _maxQueuedMessages)
                {
                    _failure = new WebRtcAppControlBootstrapException(
                        $"WebRTC AppControl bootstrap inbound queue exceeded {_maxQueuedMessages} messages before the client could process them.");
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
