using System;
using System.Buffers.Binary;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Skybridge.WinClient.Services;

public sealed class RealtimeMediaPacketKeys : IDisposable
{
    private readonly byte[] _key;
    private readonly byte[] _nonceSalt;
    private bool _disposed;

    internal RealtimeMediaPacketKeys(ReadOnlySpan<byte> material, byte direction, ulong sessionHash, ulong transcriptPrefix)
    {
        if (material.Length != 36) { throw new InvalidDataException("Realtime media key material must contain 36 bytes."); }
        _key = material[..32].ToArray();
        _nonceSalt = material[32..].ToArray();
        Direction = direction;
        SessionHash = sessionHash;
        TranscriptPrefix = transcriptPrefix;
    }

    public ReadOnlyMemory<byte> Key { get { ObjectDisposedException.ThrowIf(_disposed, this); return _key; } }
    public ReadOnlyMemory<byte> NonceSalt { get { ObjectDisposedException.ThrowIf(_disposed, this); return _nonceSalt; } }
    public byte Direction { get; }
    public ulong SessionHash { get; }
    public ulong TranscriptPrefix { get; }
    public uint Epoch => 0;

    public void Dispose()
    {
        if (_disposed) { return; }
        CryptographicOperations.ZeroMemory(_key);
        CryptographicOperations.ZeroMemory(_nonceSalt);
        _disposed = true;
    }
}

public sealed record RealtimeMediaOpenedPacket(byte[] Payload, uint StreamId, ulong Sequence,
    ulong TimestampSamples, ushort Flags, ulong NonceCounter);

/// <summary>The pqc-media-v1 audio transport uses the current SBMA wire version 2.</summary>
public static class RealtimeMediaPacketCodec
{
    public const uint Magic = 0x5342_4d41;
    public const byte Version = 2;
    public const int HeaderLength = 61;
    public const int TagLength = 16;
    public const int MaximumPayloadBytes = 1100;

    public static RealtimeMediaPacketKeys DeriveSendKeys(ProductSessionKeys keys) => DeriveKeys(keys, sending: true);
    public static RealtimeMediaPacketKeys DeriveReceiveKeys(ProductSessionKeys keys) => DeriveKeys(keys, sending: false);

    private static RealtimeMediaPacketKeys DeriveKeys(ProductSessionKeys keys, bool sending)
    {
        ArgumentNullException.ThrowIfNull(keys);
        var direction = (byte)((keys.Role == ProductHandshakeRole.Initiator) == sending ? 1 : 2);
        var label = Encoding.UTF8.GetBytes("skybridge-media-v1\0" + keys.SessionId + "\0");
        var info = new byte[label.Length + 6];
        label.CopyTo(info, 0);
        info[label.Length] = direction;
        // The separator and big-endian epoch 0 occupy the remaining five bytes.
        var material = ProductHandshakeKeyDerivation.HkdfSha256(
            sending ? keys.SendKey.Span : keys.ReceiveKey.Span, keys.TranscriptHash.Span, info, 36);
        try
        {
            using var transcript = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            transcript.AppendData("SkyBridge-Media-Transcript-v1|"u8);
            transcript.AppendData(keys.TranscriptHash.Span);
            return new RealtimeMediaPacketKeys(material, direction,
                BinaryPrimitives.ReadUInt64BigEndian(SHA256.HashData(Encoding.UTF8.GetBytes(keys.SessionId))),
                BinaryPrimitives.ReadUInt64BigEndian(transcript.GetHashAndReset()));
        }
        finally { CryptographicOperations.ZeroMemory(material); }
    }

    public static byte[] Seal(ReadOnlySpan<byte> payload, RealtimeMediaPacketKeys keys, ulong sequence,
        ulong timestampSamples, ulong nonceCounter, ushort flags = 1, uint streamId = 1)
    {
        ArgumentNullException.ThrowIfNull(keys);
        if (payload.IsEmpty || payload.Length > MaximumPayloadBytes)
        { throw new ProductSecureEnvelopeException("Realtime media Opus payload must contain 1..1100 bytes."); }
        if (nonceCounter == 0 || streamId == 0)
        { throw new ProductSecureEnvelopeException("Realtime media nonce counter and stream ID must be positive."); }
        var packet = new byte[HeaderLength + payload.Length + TagLength];
        var header = packet.AsSpan(0, HeaderLength);
        BinaryPrimitives.WriteUInt32BigEndian(header, Magic);
        header[4] = Version;
        header[5] = HeaderLength;
        BinaryPrimitives.WriteUInt16BigEndian(header[6..], flags);
        header[8] = keys.Direction;
        BinaryPrimitives.WriteUInt64BigEndian(header[9..], keys.TranscriptPrefix);
        BinaryPrimitives.WriteUInt64BigEndian(header[17..], keys.SessionHash);
        BinaryPrimitives.WriteUInt32BigEndian(header[25..], streamId);
        BinaryPrimitives.WriteUInt64BigEndian(header[29..], sequence);
        BinaryPrimitives.WriteUInt64BigEndian(header[37..], timestampSamples);
        BinaryPrimitives.WriteUInt32BigEndian(header[45..], keys.Epoch);
        BinaryPrimitives.WriteUInt64BigEndian(header[49..], nonceCounter);
        BinaryPrimitives.WriteUInt32BigEndian(header[57..], checked((uint)payload.Length));
        Span<byte> nonce = stackalloc byte[12];
        keys.NonceSalt.Span.CopyTo(nonce);
        BinaryPrimitives.WriteUInt64BigEndian(nonce[4..], nonceCounter);
        using var aes = new AesGcm(keys.Key.Span, TagLength);
        aes.Encrypt(nonce, payload, packet.AsSpan(HeaderLength, payload.Length), packet.AsSpan(HeaderLength + payload.Length), header);
        return packet;
    }

    public static RealtimeMediaOpenedPacket Open(ReadOnlySpan<byte> packet, RealtimeMediaPacketKeys keys, uint expectedStreamId = 1)
    {
        ArgumentNullException.ThrowIfNull(keys);
        if (packet.Length < HeaderLength + TagLength || BinaryPrimitives.ReadUInt32BigEndian(packet) != Magic ||
            packet[4] != Version || packet[5] != HeaderLength)
        { throw new ProductSecureEnvelopeException("Malformed or unsupported realtime media header."); }
        var length = BinaryPrimitives.ReadUInt32BigEndian(packet[57..]);
        if (length > MaximumPayloadBytes || packet.Length - HeaderLength - TagLength != (long)length)
        { throw new ProductSecureEnvelopeException("Malformed realtime media payload length."); }
        if (packet[8] != keys.Direction || BinaryPrimitives.ReadUInt64BigEndian(packet[9..]) != keys.TranscriptPrefix ||
            BinaryPrimitives.ReadUInt64BigEndian(packet[17..]) != keys.SessionHash ||
            BinaryPrimitives.ReadUInt32BigEndian(packet[25..]) != expectedStreamId ||
            BinaryPrimitives.ReadUInt32BigEndian(packet[45..]) != keys.Epoch)
        { throw new ProductSecureEnvelopeException("Realtime media direction, session, transcript, stream or epoch binding mismatch."); }
        var sequence = BinaryPrimitives.ReadUInt64BigEndian(packet[29..]);
        var counter = BinaryPrimitives.ReadUInt64BigEndian(packet[49..]);
        if (counter == 0) { throw new ProductSecureEnvelopeException("Realtime media nonce counter must be positive."); }
        Span<byte> nonce = stackalloc byte[12];
        keys.NonceSalt.Span.CopyTo(nonce);
        BinaryPrimitives.WriteUInt64BigEndian(nonce[4..], counter);
        var plaintext = new byte[(int)length];
        try
        {
            using var aes = new AesGcm(keys.Key.Span, TagLength);
            aes.Decrypt(nonce, packet.Slice(HeaderLength, plaintext.Length), packet[^TagLength..], plaintext, packet[..HeaderLength]);
            return new RealtimeMediaOpenedPacket(plaintext, expectedStreamId, sequence,
                BinaryPrimitives.ReadUInt64BigEndian(packet[37..]), BinaryPrimitives.ReadUInt16BigEndian(packet[6..]), counter);
        }
        catch (CryptographicException ex)
        {
            CryptographicOperations.ZeroMemory(plaintext);
            throw new ProductSecureEnvelopeException("Realtime media authentication failed.", ex);
        }
    }
}

/// <summary>Keep this sender alive for the authenticated session while audio capture is paused or recreated.</summary>
public sealed class RealtimeMediaPacketSender : IDisposable
{
    private readonly object _gate = new();
    private readonly RealtimeMediaPacketKeys _keys;
    private ulong _counter;
    private bool _disposed;

    public RealtimeMediaPacketSender(ProductSessionKeys keys) { _keys = RealtimeMediaPacketCodec.DeriveSendKeys(keys); }

    public byte[] SealNext(ReadOnlySpan<byte> opusPayload, ulong timestampSamples, ushort flags)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_counter == ulong.MaxValue)
            { throw new ProductSecureEnvelopeException("Realtime media nonce counter is exhausted; reauthenticate the session."); }
            var next = ++_counter;
            return RealtimeMediaPacketCodec.Seal(opusPayload, _keys, next - 1, timestampSamples, next, flags);
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) { return; }
            _keys.Dispose();
            _disposed = true;
        }
    }
}
