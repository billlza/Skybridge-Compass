using System;
using System.Buffers.Binary;
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
    public WebRtcAppControlBootstrapOptions(
        TimeSpan timeout,
        int maxQueuedInboundMessages = 8,
        WebRtcAppControlPayloadFormat payloadFormat = WebRtcAppControlPayloadFormat.SkybridgeSecureEnvelopeV1)
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

        if (!Enum.IsDefined(typeof(WebRtcAppControlPayloadFormat), payloadFormat))
        {
            throw new InvalidOperationException("Unsupported WebRTC AppControl payload format.");
        }

        Timeout = timeout;
        MaxQueuedInboundMessages = maxQueuedInboundMessages;
        PayloadFormat = payloadFormat;
    }

    public static WebRtcAppControlBootstrapOptions Default { get; } = new(TimeSpan.FromSeconds(10));

    public TimeSpan Timeout { get; }

    public int MaxQueuedInboundMessages { get; }

    public WebRtcAppControlPayloadFormat PayloadFormat { get; }
}

public sealed record WebRtcAppControlBootstrapResult(
    string SessionId,
    ulong PingId,
    ulong? OutboundCounter,
    ulong? InboundCounter,
    ulong? SessionHash,
    ulong? TranscriptPrefix,
    string ReceivedMessageKind,
    string PayloadFormat);

public sealed record WebRtcAppControlResponderResult(
    string SessionId,
    ulong PingId,
    ulong? OutboundCounter,
    ulong? InboundCounter,
    ulong? SessionHash,
    ulong? TranscriptPrefix,
    string ReceivedMessageKind,
    string SentMessageKind,
    string PayloadFormat);

internal static class WebRtcAppControlBootstrapPayloadPolicy
{
    public const int MaxJsonPayloadBytes = 1024;

    public static void RequireJsonPayloadWithinLimit(ReadOnlySpan<byte> payload, string context)
    {
        if (payload.Length > MaxJsonPayloadBytes)
        {
            throw new WebRtcAppControlBootstrapException(
                $"{context} JSON AppMessage payload exceeded {MaxJsonPayloadBytes} bytes.");
        }
    }
}

public interface IWebRtcAppControlBootstrapClient
{
    Task<WebRtcAppControlBootstrapResult> ExchangePingAsync(
        LiveWebRtcProductControlContext establishedContext,
        ushort suiteWireId,
        CancellationToken cancellationToken = default);
}

public interface IWebRtcAppControlResponderHost
{
    Task<WebRtcAppControlResponderResult> AnswerPingAsync(
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
        var plaintext = BuildPingPayload(pingId);
        var sealedPayload = SealAppControlPayload(plaintext, keys);

        await using var inbox = new WebRtcProductControlMessageInbox(
            establishedContext.ControlPlane,
            _options.MaxQueuedInboundMessages,
            "WebRTC AppControl bootstrap",
            message => new WebRtcAppControlBootstrapException(message));

        await establishedContext.ControlPlane
            .SendAsync(sealedPayload.Ciphertext, cancellationToken)
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
            sealedPayload.Counter,
            opened.Counter,
            opened.SessionHash,
            opened.TranscriptPrefix,
            messageKind,
            WebRtcAppControlPayloadFormats.Label(_options.PayloadFormat));
    }

    private OpenedAppControlPayload OpenAndRecordAppControl(
        ReadOnlySpan<byte> ciphertext,
        WebRtcAppSecureSessionKeys keys)
    {
        try
        {
            if (_options.PayloadFormat == WebRtcAppControlPayloadFormat.AppleLegacyAesGcmCombined)
            {
                return new OpenedAppControlPayload(
                    WebRtcControlChannelCodec.DecryptAppleLegacyAppPayload(ciphertext, keys),
                    Counter: null,
                    SessionHash: null,
                    TranscriptPrefix: null);
            }

            var opened = WebRtcControlChannelCodec.DecryptAppPayload(
                    ciphertext,
                    keys,
                    new[] { WebRtcAppSecurePacketType.AppControl });
            _replayWindow.ValidateAndRecord(opened);
            return new OpenedAppControlPayload(
                opened.Payload,
                opened.Counter,
                opened.SessionHash,
                opened.TranscriptPrefix);
        }
        catch (Exception ex) when (ex is WebRtcAppSecureEnvelopeException or WebRtcAppSecureReplayException)
        {
            throw new WebRtcAppControlBootstrapException(
                "WebRTC AppControl bootstrap failed to authenticate inbound AppControl payload.",
                ex);
        }
    }

    private SealedAppControlPayload SealAppControlPayload(
        ReadOnlySpan<byte> plaintext,
        WebRtcAppSecureSessionKeys keys)
    {
        if (_options.PayloadFormat == WebRtcAppControlPayloadFormat.AppleLegacyAesGcmCombined)
        {
            return new SealedAppControlPayload(
                WebRtcControlChannelCodec.EncryptAppleLegacyAppPayload(plaintext, keys),
                Counter: null);
        }

        var outboundCounter = NextOutboundCounter();
        return new SealedAppControlPayload(
            WebRtcControlChannelCodec.EncryptAppPayload(
                plaintext,
                keys,
                WebRtcAppSecurePacketType.AppControl,
                outboundCounter),
            outboundCounter);
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
        WebRtcAppControlBootstrapPayloadPolicy.RequireJsonPayloadWithinLimit(
            payload,
            "WebRTC AppControl bootstrap");
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
        try { return ProductControlTrafficPadding.Unwrap(frame); }
        catch (InvalidDataException error)
        {
            throw new WebRtcAppControlBootstrapException(
                "WebRTC AppControl bootstrap received malformed SBP2 traffic padding.", error);
        }
    }

}

public sealed class WebRtcAppControlResponderHost : IWebRtcAppControlResponderHost
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

    public WebRtcAppControlResponderHost(
        WebRtcProductSecureSessionStore sessionStore,
        WebRtcAppControlBootstrapOptions? options = null)
    {
        _sessionStore = sessionStore ?? throw new ArgumentNullException(nameof(sessionStore));
        _options = options ?? WebRtcAppControlBootstrapOptions.Default;
    }

    public async Task<WebRtcAppControlResponderResult> AnswerPingAsync(
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
                "WebRTC AppControl responder requires a connected product-control plane.");
        }

        await using var inbox = new WebRtcProductControlMessageInbox(
            establishedContext.ControlPlane,
            _options.MaxQueuedInboundMessages,
            "WebRTC AppControl responder",
            message => new WebRtcAppControlBootstrapException(message));

        var inboundFrame = await inbox
            .ReadAsync("AppControl ping", _options.Timeout, cancellationToken)
            .ConfigureAwait(false);
        var unwrapped = UnwrapTrafficPaddingIfNeeded(inboundFrame);
        var opened = OpenAndRecordAppControl(unwrapped, keys);
        var pingId = RequirePing(opened.Payload);

        var plaintext = BuildPongPayload(pingId);
        var sealedPayload = SealAppControlPayload(plaintext, keys);
        await establishedContext.ControlPlane
            .SendAsync(sealedPayload.Ciphertext, cancellationToken)
            .ConfigureAwait(false);

        return new WebRtcAppControlResponderResult(
            keys.SessionId,
            pingId,
            sealedPayload.Counter,
            opened.Counter,
            opened.SessionHash,
            opened.TranscriptPrefix,
            ReceivedMessageKind: "ping",
            SentMessageKind: "pong",
            PayloadFormat: WebRtcAppControlPayloadFormats.Label(_options.PayloadFormat));
    }

    private OpenedAppControlPayload OpenAndRecordAppControl(
        ReadOnlySpan<byte> ciphertext,
        WebRtcAppSecureSessionKeys keys)
    {
        try
        {
            if (_options.PayloadFormat == WebRtcAppControlPayloadFormat.AppleLegacyAesGcmCombined)
            {
                return new OpenedAppControlPayload(
                    WebRtcControlChannelCodec.DecryptAppleLegacyAppPayload(ciphertext, keys),
                    Counter: null,
                    SessionHash: null,
                    TranscriptPrefix: null);
            }

            var opened = WebRtcControlChannelCodec.DecryptAppPayload(
                    ciphertext,
                    keys,
                    new[] { WebRtcAppSecurePacketType.AppControl });
            _replayWindow.ValidateAndRecord(opened);
            return new OpenedAppControlPayload(
                opened.Payload,
                opened.Counter,
                opened.SessionHash,
                opened.TranscriptPrefix);
        }
        catch (Exception ex) when (ex is WebRtcAppSecureEnvelopeException or WebRtcAppSecureReplayException)
        {
            throw new WebRtcAppControlBootstrapException(
                "WebRTC AppControl responder failed to authenticate inbound AppControl payload.",
                ex);
        }
    }

    private SealedAppControlPayload SealAppControlPayload(
        ReadOnlySpan<byte> plaintext,
        WebRtcAppSecureSessionKeys keys)
    {
        if (_options.PayloadFormat == WebRtcAppControlPayloadFormat.AppleLegacyAesGcmCombined)
        {
            return new SealedAppControlPayload(
                WebRtcControlChannelCodec.EncryptAppleLegacyAppPayload(plaintext, keys),
                Counter: null);
        }

        var outboundCounter = NextOutboundCounter();
        return new SealedAppControlPayload(
            WebRtcControlChannelCodec.EncryptAppPayload(
                plaintext,
                keys,
                WebRtcAppSecurePacketType.AppControl,
                outboundCounter),
            outboundCounter);
    }

    private static WebRtcAppSecureRole ExpectedRole(LiveWebRtcProductControlContext context) =>
        context.Role switch
        {
            "answer" => WebRtcAppSecureRole.Responder,
            _ => throw new WebRtcAppControlBootstrapException(
                $"Unsupported WebRTC product-control role '{context.Role}' for AppControl responder.")
        };

    private ulong NextOutboundCounter()
    {
        lock (_counterGate)
        {
            if (_nextOutboundCounter == ulong.MaxValue)
            {
                throw new WebRtcAppControlBootstrapException(
                    "WebRTC AppControl responder outbound counter exhausted.");
            }

            return _nextOutboundCounter++;
        }
    }

    private static ulong RequirePing(ReadOnlySpan<byte> payload)
    {
        WebRtcAppControlBootstrapPayloadPolicy.RequireJsonPayloadWithinLimit(
            payload,
            "WebRTC AppControl responder");
        try
        {
            using var document = JsonDocument.Parse(payload.ToArray());
            if (document.RootElement.ValueKind != JsonValueKind.Object ||
                !document.RootElement.TryGetProperty("ping", out var ping) ||
                ping.ValueKind != JsonValueKind.Object ||
                !ping.TryGetProperty("id", out var idElement) ||
                idElement.ValueKind != JsonValueKind.Number ||
                !idElement.TryGetUInt64(out var pingId) ||
                pingId == 0)
            {
                throw new WebRtcAppControlBootstrapException(
                    "WebRTC AppControl responder expected a JSON AppMessage ping payload.");
            }

            return pingId;
        }
        catch (JsonException ex)
        {
            throw new WebRtcAppControlBootstrapException(
                "WebRTC AppControl responder received malformed JSON AppMessage payload.",
                ex);
        }
    }

    private static byte[] BuildPongPayload(ulong pingId)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, JsonWriterOptions))
        {
            writer.WriteStartObject();
            writer.WriteStartObject("pong");
            writer.WriteNumber("id", pingId);
            writer.WriteEndObject();
            writer.WriteEndObject();
        }

        return stream.ToArray();
    }

    private static byte[] UnwrapTrafficPaddingIfNeeded(byte[] frame)
    {
        try { return ProductControlTrafficPadding.Unwrap(frame); }
        catch (InvalidDataException error)
        {
            throw new WebRtcAppControlBootstrapException(
                "WebRTC AppControl responder received malformed SBP2 traffic padding.", error);
        }
    }
}

internal sealed record OpenedAppControlPayload(
    byte[] Payload,
    ulong? Counter,
    ulong? SessionHash,
    ulong? TranscriptPrefix);

internal sealed record SealedAppControlPayload(byte[] Ciphertext, ulong? Counter);

internal static class WebRtcAppControlPayloadFormats
{
    public static string Label(WebRtcAppControlPayloadFormat payloadFormat) =>
        payloadFormat switch
        {
            WebRtcAppControlPayloadFormat.SkybridgeSecureEnvelopeV1 => "SkybridgeSecureEnvelopeV1",
            WebRtcAppControlPayloadFormat.AppleLegacyAesGcmCombined => "AppleLegacyAesGcmCombined",
            _ => payloadFormat.ToString()
        };
}
