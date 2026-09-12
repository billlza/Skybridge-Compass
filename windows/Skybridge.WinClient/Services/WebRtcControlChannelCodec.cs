using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace Skybridge.WinClient.Services;

public enum WebRtcAppSecurePacketType : byte
{
    AppControl = 1,
    FileTransfer = 2,
    RemoteControl = 3,
    RemoteDesktop = 4,
    RemoteDesktopAudio = 5,
}

public enum WebRtcAppSecureRole
{
    Initiator,
    Responder,
}

public enum WebRtcAppControlPayloadFormat
{
    SkybridgeSecureEnvelopeV1,
    AppleLegacyAesGcmCombined,
}

public sealed class WebRtcAppSecureSessionKeys : IDisposable
{
    private readonly byte[] _transcriptHash;
    private readonly byte[] _sendKey;
    private readonly byte[] _receiveKey;
    private bool _disposed;

    public WebRtcAppSecureSessionKeys(
        WebRtcAppSecureRole role,
        string sessionId,
        ReadOnlyMemory<byte> transcriptHash,
        ReadOnlyMemory<byte> sendKey,
        ReadOnlyMemory<byte> receiveKey)
    {
        if (string.IsNullOrWhiteSpace(sessionId))
        {
            throw new InvalidDataException("WebRTC secure session id must not be empty.");
        }

        Role = role;
        SessionId = sessionId.Trim();
        _transcriptHash = RequireBytes(transcriptHash, 32, "WebRTC secure transcript hash");
        _sendKey = RequireBytes(sendKey, 32, "WebRTC secure send key");
        _receiveKey = RequireBytes(receiveKey, 32, "WebRTC secure receive key");
    }

    public WebRtcAppSecureRole Role { get; }

    public string SessionId { get; }

    public ReadOnlyMemory<byte> TranscriptHash => _transcriptHash;

    public ReadOnlyMemory<byte> SendKey => _sendKey;

    public ReadOnlyMemory<byte> ReceiveKey => _receiveKey;

    public WebRtcAppSecureSessionKeys Clone() =>
        new(Role, SessionId, TranscriptHash, SendKey, ReceiveKey);

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        CryptographicOperations.ZeroMemory(_transcriptHash);
        CryptographicOperations.ZeroMemory(_sendKey);
        CryptographicOperations.ZeroMemory(_receiveKey);
        _disposed = true;
    }

    private static byte[] RequireBytes(ReadOnlyMemory<byte> value, int expectedLength, string label)
    {
        if (value.Length != expectedLength)
        {
            throw new InvalidDataException($"{label} must be exactly {expectedLength} bytes.");
        }

        return value.ToArray();
    }
}

public sealed record WebRtcAppSecureOpenedPayload(
    WebRtcAppSecurePacketType PacketType,
    byte Direction,
    ulong SessionHash,
    ulong TranscriptPrefix,
    uint Epoch,
    ulong Counter,
    byte[] Payload);

public enum WebRtcAppSecureReplayRejectionReason
{
    DuplicateCounter,
    CounterOutsideWindow,
}

public sealed class WebRtcAppSecureEnvelopeException : Exception
{
    public WebRtcAppSecureEnvelopeException(string message)
        : base(message)
    {
    }

    public WebRtcAppSecureEnvelopeException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed class WebRtcAppSecureReplayException : Exception
{
    public WebRtcAppSecureReplayException(
        WebRtcAppSecurePacketType packetType,
        ulong counter,
        ulong highestCounter,
        WebRtcAppSecureReplayRejectionReason reason)
        : base(
            $"WebRTC secure envelope replay detected packetType={(byte)packetType} counter={counter} highestCounter={highestCounter} reason={FormatReason(reason)}")
    {
        PacketType = packetType;
        Counter = counter;
        HighestCounter = highestCounter;
        Reason = reason;
    }

    public WebRtcAppSecurePacketType PacketType { get; }

    public ulong Counter { get; }

    public ulong HighestCounter { get; }

    public WebRtcAppSecureReplayRejectionReason Reason { get; }

    private static string FormatReason(WebRtcAppSecureReplayRejectionReason reason) =>
        reason switch
        {
            WebRtcAppSecureReplayRejectionReason.DuplicateCounter => "duplicate-counter",
            WebRtcAppSecureReplayRejectionReason.CounterOutsideWindow => "counter-outside-window",
            _ => reason.ToString()
        };
}

public sealed class WebRtcAppSecureReplayWindow
{
    private const ulong WindowSize = 1024;

    private readonly Dictionary<ReplayScope, ReplayLane> _lanes = new();

    public void ValidateAndRecord(WebRtcAppSecureOpenedPayload openedPayload)
    {
        ArgumentNullException.ThrowIfNull(openedPayload);
        if (openedPayload.Counter == 0)
        {
            throw new WebRtcAppSecureEnvelopeException("WebRTC secure envelope invalid counter=0.");
        }

        var scope = new ReplayScope(
            openedPayload.PacketType,
            openedPayload.Direction,
            openedPayload.SessionHash,
            openedPayload.TranscriptPrefix,
            openedPayload.Epoch);
        if (!_lanes.TryGetValue(scope, out var lane))
        {
            lane = new ReplayLane();
        }

        var highestCounter = lane.HighestCounter;
        if (openedPayload.Counter > highestCounter)
        {
            lane.HighestCounter = openedPayload.Counter;
            lane.RecordedCounters.Add(openedPayload.Counter);
            PruneRecordedCounters(lane);
            _lanes[scope] = lane;
            return;
        }

        var counterDistance = highestCounter - openedPayload.Counter;
        if (counterDistance >= WindowSize)
        {
            throw new WebRtcAppSecureReplayException(
                openedPayload.PacketType,
                openedPayload.Counter,
                highestCounter,
                WebRtcAppSecureReplayRejectionReason.CounterOutsideWindow);
        }

        if (lane.RecordedCounters.Contains(openedPayload.Counter))
        {
            throw new WebRtcAppSecureReplayException(
                openedPayload.PacketType,
                openedPayload.Counter,
                highestCounter,
                WebRtcAppSecureReplayRejectionReason.DuplicateCounter);
        }

        lane.RecordedCounters.Add(openedPayload.Counter);
        _lanes[scope] = lane;
    }

    private static void PruneRecordedCounters(ReplayLane lane)
    {
        var minimumCounterToKeep = lane.HighestCounter > WindowSize
            ? lane.HighestCounter - WindowSize + 1
            : 1;
        lane.RecordedCounters.RemoveWhere(counter => counter < minimumCounterToKeep);
    }

    private readonly record struct ReplayScope(
        WebRtcAppSecurePacketType PacketType,
        byte Direction,
        ulong SessionHash,
        ulong TranscriptPrefix,
        uint Epoch);

    private sealed class ReplayLane
    {
        public ulong HighestCounter { get; set; }

        public HashSet<ulong> RecordedCounters { get; } = new();
    }
}

public static class WebRtcAppSecureEnvelope
{
    public const int HeaderLength = ProductSecureEnvelope.HeaderLength;
    public const int TagLength = ProductSecureEnvelope.TagLength;
    public const int OverheadBytes = HeaderLength + TagLength;
    public const uint Magic = 0x5342_5743;
    public const byte Version = 1;
    public const uint Epoch = 0;
    public const byte DirectionInitiatorToResponder = 1;
    public const byte DirectionResponderToInitiator = 2;

    public static byte[] Seal(ReadOnlySpan<byte> plaintext, WebRtcAppSecureSessionKeys keys,
        WebRtcAppSecurePacketType packetType, ulong counter)
    {
        ArgumentNullException.ThrowIfNull(keys);
        try
        {
            return ProductSecureEnvelope.Seal(plaintext, keys.SendKey.Span, Role(keys), keys.SessionId,
                keys.TranscriptHash.Span, (byte)packetType, counter, ProductSecureEnvelopeFormat.WebRtc);
        }
        catch (ProductSecureEnvelopeException ex) { throw new WebRtcAppSecureEnvelopeException(ex.Message, ex); }
    }

    public static WebRtcAppSecureOpenedPayload Open(ReadOnlySpan<byte> packet, WebRtcAppSecureSessionKeys keys,
        IEnumerable<WebRtcAppSecurePacketType> allowedPacketTypes)
    {
        ArgumentNullException.ThrowIfNull(keys);
        ArgumentNullException.ThrowIfNull(allowedPacketTypes);
        try
        {
            var opened = ProductSecureEnvelope.Open(packet, keys.ReceiveKey.Span, Role(keys), keys.SessionId,
                keys.TranscriptHash.Span, allowedPacketTypes.Select(type => (byte)type).ToArray(), ProductSecureEnvelopeFormat.WebRtc);
            return new WebRtcAppSecureOpenedPayload((WebRtcAppSecurePacketType)opened.Header.PacketType,
                opened.Header.Direction, opened.Header.SessionHash, opened.Header.TranscriptPrefix,
                opened.Header.Epoch, opened.Header.Counter, opened.Payload);
        }
        catch (ProductSecureEnvelopeException ex) { throw new WebRtcAppSecureEnvelopeException(ex.Message, ex); }
    }

    public static ParsedHeader ParseHeader(ReadOnlySpan<byte> packet)
    {
        try
        {
            var header = ProductSecureEnvelope.ParseHeader(packet, ProductSecureEnvelopeFormat.WebRtc);
            return new ParsedHeader((WebRtcAppSecurePacketType)header.PacketType, header.Direction,
                header.SessionHash, header.TranscriptPrefix, header.Epoch, header.Counter, header.PayloadLength, header.Nonce);
        }
        catch (ProductSecureEnvelopeException ex) { throw new WebRtcAppSecureEnvelopeException(ex.Message, ex); }
    }

    public static ulong SessionIdHash(string sessionId) =>
        ProductSecureEnvelope.SessionHash(sessionId.Trim(), ProductSecureEnvelopeFormat.WebRtc);

    public static ulong TranscriptPrefix(ReadOnlySpan<byte> transcriptHash) =>
        ProductSecureEnvelope.TranscriptPrefix(transcriptHash, ProductSecureEnvelopeFormat.WebRtc);

    private static ProductHandshakeRole Role(WebRtcAppSecureSessionKeys keys) => keys.Role switch
    {
        WebRtcAppSecureRole.Initiator => ProductHandshakeRole.Initiator,
        WebRtcAppSecureRole.Responder => ProductHandshakeRole.Responder,
        _ => throw new WebRtcAppSecureEnvelopeException("Invalid WebRTC secure role.")
    };

    public sealed record ParsedHeader(WebRtcAppSecurePacketType PacketType, byte Direction, ulong SessionHash,
        ulong TranscriptPrefix, uint Epoch, ulong Counter, uint PayloadLength, byte[] Nonce);
}

public static class WebRtcControlChannelCodec
{
    private const int AppleLegacyNonceLength = 12;
    private const int AppleLegacyTagLength = 16;

    public static byte[] EncryptAppPayload(
        ReadOnlySpan<byte> plaintext,
        WebRtcAppSecureSessionKeys keys,
        WebRtcAppSecurePacketType packetType,
        ulong counter) =>
        WebRtcAppSecureEnvelope.Seal(plaintext, keys, packetType, counter);

    public static WebRtcAppSecureOpenedPayload DecryptAppPayload(
        ReadOnlySpan<byte> ciphertext,
        WebRtcAppSecureSessionKeys keys,
        IEnumerable<WebRtcAppSecurePacketType> allowedPacketTypes) =>
        WebRtcAppSecureEnvelope.Open(ciphertext, keys, allowedPacketTypes);

    public static byte[] EncryptAppleLegacyAppPayload(
        ReadOnlySpan<byte> plaintext,
        WebRtcAppSecureSessionKeys keys)
    {
        ArgumentNullException.ThrowIfNull(keys);

        var nonce = RandomNumberGenerator.GetBytes(AppleLegacyNonceLength);
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[AppleLegacyTagLength];
        var sendKey = keys.SendKey.ToArray();
        try
        {
            using var aes = new AesGcm(sendKey, AppleLegacyTagLength);
            aes.Encrypt(nonce, plaintext, ciphertext, tag);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(sendKey);
        }

        var output = new byte[nonce.Length + ciphertext.Length + tag.Length];
        nonce.CopyTo(output, 0);
        ciphertext.CopyTo(output, nonce.Length);
        tag.CopyTo(output, nonce.Length + ciphertext.Length);
        return output;
    }

    public static byte[] DecryptAppleLegacyAppPayload(
        ReadOnlySpan<byte> packet,
        WebRtcAppSecureSessionKeys keys)
    {
        ArgumentNullException.ThrowIfNull(keys);
        if (packet.Length < AppleLegacyNonceLength + AppleLegacyTagLength)
        {
            throw new WebRtcAppSecureEnvelopeException("malformed Apple legacy AppControl AES-GCM payload.");
        }

        var nonce = packet[..AppleLegacyNonceLength];
        var ciphertextLength = packet.Length - AppleLegacyNonceLength - AppleLegacyTagLength;
        var ciphertext = packet.Slice(AppleLegacyNonceLength, ciphertextLength);
        var tag = packet.Slice(AppleLegacyNonceLength + ciphertextLength, AppleLegacyTagLength);
        var plaintext = new byte[ciphertextLength];
        var receiveKey = keys.ReceiveKey.ToArray();
        try
        {
            using var aes = new AesGcm(receiveKey, AppleLegacyTagLength);
            aes.Decrypt(nonce, ciphertext, tag, plaintext);
        }
        catch (CryptographicException ex)
        {
            throw new WebRtcAppSecureEnvelopeException(
                "Apple legacy AppControl AES-GCM authentication failed.",
                ex);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(receiveKey);
        }

        return plaintext;
    }

    public static bool IsLikelySecureEnvelope(ReadOnlySpan<byte> packet) =>
        packet.Length >= WebRtcAppSecureEnvelope.OverheadBytes &&
        BinaryPrimitives.ReadUInt32BigEndian(packet[..4]) == WebRtcAppSecureEnvelope.Magic &&
        packet[4] == WebRtcAppSecureEnvelope.Version &&
        packet[5] == WebRtcAppSecureEnvelope.HeaderLength;
}
