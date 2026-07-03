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
    public const int HeaderLength = 52;
    public const int TagLength = 16;
    public const int OverheadBytes = HeaderLength + TagLength;
    public const uint Magic = 0x5342_5743; // "SBWC"
    public const byte Version = 1;
    public const uint Epoch = 0;
    public const byte DirectionInitiatorToResponder = 1;
    public const byte DirectionResponderToInitiator = 2;

    public static byte[] Seal(
        ReadOnlySpan<byte> plaintext,
        WebRtcAppSecureSessionKeys keys,
        WebRtcAppSecurePacketType packetType,
        ulong counter)
    {
        ArgumentNullException.ThrowIfNull(keys);
        if (counter == 0)
        {
            throw new WebRtcAppSecureEnvelopeException("WebRTC secure envelope invalid counter=0.");
        }

        var nonce = RandomNumberGenerator.GetBytes(12);
        var header = new byte[HeaderLength];
        WriteHeader(
            header,
            packetType,
            SendDirection(keys),
            SessionIdHash(keys.SessionId),
            TranscriptPrefix(keys.TranscriptHash.Span),
            Epoch,
            counter,
            checked((uint)plaintext.Length),
            nonce);

        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[TagLength];
        var sendKey = keys.SendKey.ToArray();
        try
        {
            using var aes = new AesGcm(sendKey, TagLength);
            aes.Encrypt(nonce, plaintext, ciphertext, tag, header);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(sendKey);
        }

        var output = new byte[HeaderLength + ciphertext.Length + TagLength];
        header.CopyTo(output, 0);
        ciphertext.CopyTo(output, HeaderLength);
        tag.CopyTo(output, HeaderLength + ciphertext.Length);
        return output;
    }

    public static WebRtcAppSecureOpenedPayload Open(
        ReadOnlySpan<byte> packet,
        WebRtcAppSecureSessionKeys keys,
        IEnumerable<WebRtcAppSecurePacketType> allowedPacketTypes)
    {
        ArgumentNullException.ThrowIfNull(keys);
        ArgumentNullException.ThrowIfNull(allowedPacketTypes);
        var allowed = allowedPacketTypes.ToHashSet();
        if (allowed.Count == 0)
        {
            throw new WebRtcAppSecureEnvelopeException("WebRTC secure envelope requires at least one allowed packet type.");
        }

        var parsed = ParseHeader(packet);
        if (!allowed.Contains(parsed.PacketType))
        {
            throw new WebRtcAppSecureEnvelopeException(
                $"WebRTC secure envelope packetType mismatch expected={string.Join(",", allowed.Select(value => ((byte)value).ToString()).OrderBy(value => value, StringComparer.Ordinal))} actual={(byte)parsed.PacketType}.");
        }

        var expectedDirection = ReceiveDirection(keys);
        if (parsed.Direction != expectedDirection)
        {
            throw new WebRtcAppSecureEnvelopeException(
                $"WebRTC secure envelope direction mismatch expected={expectedDirection} actual={parsed.Direction}.");
        }

        var expectedSessionHash = SessionIdHash(keys.SessionId);
        if (parsed.SessionHash != expectedSessionHash)
        {
            throw new WebRtcAppSecureEnvelopeException(
                $"WebRTC secure envelope session mismatch expected={expectedSessionHash} actual={parsed.SessionHash}.");
        }

        var expectedTranscriptPrefix = TranscriptPrefix(keys.TranscriptHash.Span);
        if (parsed.TranscriptPrefix != expectedTranscriptPrefix)
        {
            throw new WebRtcAppSecureEnvelopeException(
                $"WebRTC secure envelope transcript mismatch expected={expectedTranscriptPrefix} actual={parsed.TranscriptPrefix}.");
        }

        if (parsed.Epoch != Epoch)
        {
            throw new WebRtcAppSecureEnvelopeException(
                $"WebRTC secure envelope epoch mismatch expected={Epoch} actual={parsed.Epoch}.");
        }

        if (parsed.Counter == 0)
        {
            throw new WebRtcAppSecureEnvelopeException("WebRTC secure envelope invalid counter=0.");
        }

        if (parsed.PayloadLength > int.MaxValue)
        {
            throw new WebRtcAppSecureEnvelopeException("malformed WebRTC secure envelope.");
        }

        var payloadLength = (int)parsed.PayloadLength;
        var ciphertext = packet.Slice(HeaderLength, payloadLength);
        var tag = packet.Slice(HeaderLength + payloadLength, TagLength);
        var plaintext = new byte[parsed.PayloadLength];
        var receiveKey = keys.ReceiveKey.ToArray();
        try
        {
            using var aes = new AesGcm(receiveKey, TagLength);
            aes.Decrypt(parsed.Nonce, ciphertext, tag, plaintext, packet[..HeaderLength]);
        }
        catch (CryptographicException ex)
        {
            throw new WebRtcAppSecureEnvelopeException(
                $"WebRTC secure envelope authentication failed packetType={(byte)parsed.PacketType} counter={parsed.Counter}.",
                ex);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(receiveKey);
        }

        return new WebRtcAppSecureOpenedPayload(
            parsed.PacketType,
            parsed.Direction,
            parsed.SessionHash,
            parsed.TranscriptPrefix,
            parsed.Epoch,
            parsed.Counter,
            plaintext);
    }

    public static ParsedHeader ParseHeader(ReadOnlySpan<byte> packet)
    {
        if (packet.Length < HeaderLength + TagLength)
        {
            throw new WebRtcAppSecureEnvelopeException("malformed WebRTC secure envelope.");
        }

        var magic = BinaryPrimitives.ReadUInt32BigEndian(packet[..4]);
        if (magic != Magic)
        {
            throw new WebRtcAppSecureEnvelopeException($"unsupported WebRTC secure envelope magic={magic}.");
        }

        var version = packet[4];
        if (version != Version)
        {
            throw new WebRtcAppSecureEnvelopeException($"unsupported WebRTC secure envelope version={version}.");
        }

        var headerLength = packet[5];
        if (headerLength != HeaderLength)
        {
            throw new WebRtcAppSecureEnvelopeException("malformed WebRTC secure envelope.");
        }

        var packetTypeRaw = packet[6];
        if (!Enum.IsDefined(typeof(WebRtcAppSecurePacketType), packetTypeRaw))
        {
            throw new WebRtcAppSecureEnvelopeException(
                $"unsupported WebRTC secure envelope packetType={packetTypeRaw}.");
        }

        var payloadLength = BinaryPrimitives.ReadUInt32BigEndian(packet.Slice(36, 4));
        if (payloadLength > int.MaxValue)
        {
            throw new WebRtcAppSecureEnvelopeException("malformed WebRTC secure envelope.");
        }

        var expectedLength = HeaderLength + (int)payloadLength + TagLength;
        if (packet.Length != expectedLength)
        {
            throw new WebRtcAppSecureEnvelopeException("malformed WebRTC secure envelope.");
        }

        return new ParsedHeader(
            (WebRtcAppSecurePacketType)packetTypeRaw,
            packet[7],
            BinaryPrimitives.ReadUInt64BigEndian(packet.Slice(8, 8)),
            BinaryPrimitives.ReadUInt64BigEndian(packet.Slice(16, 8)),
            BinaryPrimitives.ReadUInt32BigEndian(packet.Slice(24, 4)),
            BinaryPrimitives.ReadUInt64BigEndian(packet.Slice(28, 8)),
            payloadLength,
            packet.Slice(40, 12).ToArray());
    }

    public static ulong SessionIdHash(string sessionId)
    {
        if (string.IsNullOrWhiteSpace(sessionId))
        {
            throw new InvalidDataException("WebRTC secure session id must not be empty.");
        }

        var material = Encoding.UTF8.GetBytes("SkyBridge-WebRTC-App-Session-v1|" + sessionId.Trim());
        return FirstUInt64(SHA256.HashData(material));
    }

    public static ulong TranscriptPrefix(ReadOnlySpan<byte> transcriptHash)
    {
        if (transcriptHash.Length == 0)
        {
            throw new InvalidDataException("WebRTC secure transcript hash must not be empty.");
        }

        var prefix = Encoding.UTF8.GetBytes("SkyBridge-WebRTC-App-Transcript-v1|");
        var material = new byte[prefix.Length + transcriptHash.Length];
        prefix.CopyTo(material, 0);
        transcriptHash.CopyTo(material.AsSpan(prefix.Length));
        return FirstUInt64(SHA256.HashData(material));
    }

    private static void WriteHeader(
        Span<byte> header,
        WebRtcAppSecurePacketType packetType,
        byte direction,
        ulong sessionHash,
        ulong transcriptPrefix,
        uint epoch,
        ulong counter,
        uint plaintextLength,
        ReadOnlySpan<byte> nonce)
    {
        if (header.Length != HeaderLength)
        {
            throw new ArgumentException("SBWC header buffer has the wrong length.", nameof(header));
        }

        if (nonce.Length != 12)
        {
            throw new ArgumentException("AES-GCM nonce must be exactly 12 bytes.", nameof(nonce));
        }

        BinaryPrimitives.WriteUInt32BigEndian(header[..4], Magic);
        header[4] = Version;
        header[5] = HeaderLength;
        header[6] = (byte)packetType;
        header[7] = direction;
        BinaryPrimitives.WriteUInt64BigEndian(header.Slice(8, 8), sessionHash);
        BinaryPrimitives.WriteUInt64BigEndian(header.Slice(16, 8), transcriptPrefix);
        BinaryPrimitives.WriteUInt32BigEndian(header.Slice(24, 4), epoch);
        BinaryPrimitives.WriteUInt64BigEndian(header.Slice(28, 8), counter);
        BinaryPrimitives.WriteUInt32BigEndian(header.Slice(36, 4), plaintextLength);
        nonce.CopyTo(header.Slice(40, 12));
    }

    private static byte SendDirection(WebRtcAppSecureSessionKeys keys) =>
        keys.Role == WebRtcAppSecureRole.Initiator
            ? DirectionInitiatorToResponder
            : DirectionResponderToInitiator;

    private static byte ReceiveDirection(WebRtcAppSecureSessionKeys keys) =>
        keys.Role == WebRtcAppSecureRole.Initiator
            ? DirectionResponderToInitiator
            : DirectionInitiatorToResponder;

    private static ulong FirstUInt64(ReadOnlySpan<byte> digest) =>
        BinaryPrimitives.ReadUInt64BigEndian(digest[..8]);

    public sealed record ParsedHeader(
        WebRtcAppSecurePacketType PacketType,
        byte Direction,
        ulong SessionHash,
        ulong TranscriptPrefix,
        uint Epoch,
        ulong Counter,
        uint PayloadLength,
        byte[] Nonce);
}

public static class WebRtcControlChannelCodec
{
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

    public static bool IsLikelySecureEnvelope(ReadOnlySpan<byte> packet) =>
        packet.Length >= WebRtcAppSecureEnvelope.OverheadBytes &&
        BinaryPrimitives.ReadUInt32BigEndian(packet[..4]) == WebRtcAppSecureEnvelope.Magic &&
        packet[4] == WebRtcAppSecureEnvelope.Version &&
        packet[5] == WebRtcAppSecureEnvelope.HeaderLength;
}
