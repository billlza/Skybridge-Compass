using System;
using System.Buffers.Binary;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Skybridge.WinClient.Services;

internal sealed record ProductSecureEnvelopeFormat(uint Magic, string SessionDomain, string TranscriptDomain, byte MaxPacketType, int MaxPayloadBytes)
{
    internal static readonly ProductSecureEnvelopeFormat WebRtc = new(0x5342_5743,
        "SkyBridge-WebRTC-App-Session-v1|", "SkyBridge-WebRTC-App-Transcript-v1|", 5, int.MaxValue - 68);
    internal static readonly ProductSecureEnvelopeFormat RemoteControl = new(0x5342_5243,
        "SkyBridge-RemoteControl-Session-v1|", "SkyBridge-RemoteControl-Transcript-v1|", 3, 8_000_000);
}

public sealed class ProductSecureEnvelopeException : Exception
{
    public ProductSecureEnvelopeException(string message) : base(message) { }
    public ProductSecureEnvelopeException(string message, Exception innerException) : base(message, innerException) { }
}

internal sealed record ProductSecureEnvelopeHeader(byte PacketType, byte Direction, ulong SessionHash,
    ulong TranscriptPrefix, uint Epoch, ulong Counter, uint PayloadLength, byte[] Nonce);

internal sealed record ProductSecureOpenedPayload(ProductSecureEnvelopeHeader Header, byte[] Payload);

/// <summary>One AES-GCM envelope implementation with explicit, closed wire profiles for SBWC and SBRC.</summary>
internal static class ProductSecureEnvelope
{
    internal const int HeaderLength = 52;
    internal const int TagLength = 16;

    internal static byte[] Seal(ReadOnlySpan<byte> plaintext, ReadOnlySpan<byte> sendKey,
        ProductHandshakeRole role, string sessionId, ReadOnlySpan<byte> transcriptHash,
        byte packetType, ulong counter, ProductSecureEnvelopeFormat format)
    {
        if (counter == 0) { throw new ProductSecureEnvelopeException("Secure envelope invalid counter=0."); }
        if (packetType == 0 || packetType > format.MaxPacketType)
        { throw new ProductSecureEnvelopeException($"Unsupported secure envelope packetType={packetType}."); }
        if (plaintext.Length > format.MaxPayloadBytes)
        { throw new ProductSecureEnvelopeException("Secure envelope payload exceeds the wire limit."); }
        var nonce = RandomNumberGenerator.GetBytes(12);
        var packet = new byte[checked(HeaderLength + plaintext.Length + TagLength)];
        var header = packet.AsSpan(0, HeaderLength);
        BinaryPrimitives.WriteUInt32BigEndian(header, format.Magic);
        header[4] = 1;
        header[5] = HeaderLength;
        header[6] = packetType;
        header[7] = SendDirection(role);
        BinaryPrimitives.WriteUInt64BigEndian(header[8..], SessionHash(sessionId, format));
        BinaryPrimitives.WriteUInt64BigEndian(header[16..], TranscriptPrefix(transcriptHash, format));
        BinaryPrimitives.WriteUInt32BigEndian(header[24..], 0);
        BinaryPrimitives.WriteUInt64BigEndian(header[28..], counter);
        BinaryPrimitives.WriteUInt32BigEndian(header[36..], checked((uint)plaintext.Length));
        nonce.CopyTo(header[40..]);
        using var aes = new AesGcm(sendKey, TagLength);
        aes.Encrypt(nonce, plaintext, packet.AsSpan(HeaderLength, plaintext.Length), packet.AsSpan(HeaderLength + plaintext.Length), header);
        return packet;
    }

    internal static ProductSecureOpenedPayload Open(ReadOnlySpan<byte> packet, ReadOnlySpan<byte> receiveKey,
        ProductHandshakeRole role, string sessionId, ReadOnlySpan<byte> transcriptHash,
        ReadOnlySpan<byte> allowedPacketTypes, ProductSecureEnvelopeFormat format)
    {
        if (allowedPacketTypes.IsEmpty) { throw new ProductSecureEnvelopeException("Secure envelope requires at least one allowed packet type."); }
        var header = ParseHeader(packet, format);
        if (!allowedPacketTypes.Contains(header.PacketType))
        { throw new ProductSecureEnvelopeException($"Secure envelope packetType mismatch actual={header.PacketType}."); }
        if (header.Direction != (SendDirection(role) == 1 ? 2 : 1))
        { throw new ProductSecureEnvelopeException("Secure envelope direction mismatch."); }
        if (header.SessionHash != SessionHash(sessionId, format))
        { throw new ProductSecureEnvelopeException("Secure envelope session mismatch."); }
        if (header.TranscriptPrefix != TranscriptPrefix(transcriptHash, format))
        { throw new ProductSecureEnvelopeException("Secure envelope transcript mismatch."); }
        if (header.Epoch != 0) { throw new ProductSecureEnvelopeException("Secure envelope epoch mismatch."); }
        if (header.Counter == 0) { throw new ProductSecureEnvelopeException("Secure envelope invalid counter=0."); }
        var payload = new byte[(int)header.PayloadLength];
        try
        {
            using var aes = new AesGcm(receiveKey, TagLength);
            aes.Decrypt(header.Nonce, packet.Slice(HeaderLength, payload.Length), packet[^TagLength..], payload, packet[..HeaderLength]);
            return new ProductSecureOpenedPayload(header, payload);
        }
        catch (CryptographicException ex)
        {
            CryptographicOperations.ZeroMemory(payload);
            throw new ProductSecureEnvelopeException($"Secure envelope authentication failed packetType={header.PacketType} counter={header.Counter}.", ex);
        }
    }

    internal static ProductSecureEnvelopeHeader ParseHeader(ReadOnlySpan<byte> packet, ProductSecureEnvelopeFormat format)
    {
        if (packet.Length < HeaderLength + TagLength) { throw new ProductSecureEnvelopeException("Malformed secure envelope."); }
        if (BinaryPrimitives.ReadUInt32BigEndian(packet) != format.Magic) { throw new ProductSecureEnvelopeException("Unsupported secure envelope magic."); }
        if (packet[4] != 1) { throw new ProductSecureEnvelopeException("Unsupported secure envelope version."); }
        if (packet[5] != HeaderLength) { throw new ProductSecureEnvelopeException("Malformed secure envelope header length."); }
        if (packet[6] == 0 || packet[6] > format.MaxPacketType) { throw new ProductSecureEnvelopeException("Unsupported secure envelope packetType."); }
        var length = BinaryPrimitives.ReadUInt32BigEndian(packet[36..]);
        if (length > format.MaxPayloadBytes || packet.Length - HeaderLength - TagLength != (long)length)
        { throw new ProductSecureEnvelopeException("Malformed secure envelope payload length."); }
        return new ProductSecureEnvelopeHeader(packet[6], packet[7],
            BinaryPrimitives.ReadUInt64BigEndian(packet[8..]), BinaryPrimitives.ReadUInt64BigEndian(packet[16..]),
            BinaryPrimitives.ReadUInt32BigEndian(packet[24..]), BinaryPrimitives.ReadUInt64BigEndian(packet[28..]),
            length, packet.Slice(40, 12).ToArray());
    }

    internal static ulong SessionHash(string sessionId, ProductSecureEnvelopeFormat format)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionId);
        return BinaryPrimitives.ReadUInt64BigEndian(SHA256.HashData(Encoding.UTF8.GetBytes(format.SessionDomain + sessionId)));
    }

    internal static ulong TranscriptPrefix(ReadOnlySpan<byte> transcriptHash, ProductSecureEnvelopeFormat format)
    {
        if (transcriptHash.IsEmpty) { throw new InvalidDataException("Secure transcript hash must not be empty."); }
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(Encoding.UTF8.GetBytes(format.TranscriptDomain));
        hash.AppendData(transcriptHash);
        return BinaryPrimitives.ReadUInt64BigEndian(hash.GetHashAndReset());
    }

    private static byte SendDirection(ProductHandshakeRole role) => role switch
    {
        ProductHandshakeRole.Initiator => 1,
        ProductHandshakeRole.Responder => 2,
        _ => throw new ProductSecureEnvelopeException("Invalid secure envelope role.")
    };
}
