using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace Skybridge.WinClient.Services;

public sealed record RemoteControlTrustedPeer(
    string DeviceId, string ProtocolPublicKeyFingerprint, IReadOnlyList<string>? KnownDeviceIds = null);

/// <summary>A trusted lookup candidate; authentication still requires the shared handshake's signature and Finished checks.</summary>
public sealed record RemoteControlHandshakeCandidate(
    ProductHandshakePeerContext Peer, ReadOnlyMemory<byte> MessageAFrame, RemoteControlHandshakeSoa Soa);

public sealed class RemoteControlHandshakeSoa
{
    public const ushort ExtensionType = 1;
    public const byte Version = 1;
    public const int ValueLength = 81;

    public RemoteControlHandshakeSoa(ReadOnlyMemory<byte> initiatorPeerId,
        ReadOnlyMemory<byte> targetPeerId, ReadOnlyMemory<byte> attemptId)
    {
        if (initiatorPeerId.Length != 32 || targetPeerId.Length != 32 || attemptId.Length != 16)
        {
            throw new InvalidDataException("SOA requires 32-byte initiator and target identities and a 16-byte attempt ID.");
        }
        InitiatorPeerId = initiatorPeerId.ToArray();
        TargetPeerId = targetPeerId.ToArray();
        AttemptId = attemptId.ToArray();
    }

    public ReadOnlyMemory<byte> InitiatorPeerId { get; }
    public ReadOnlyMemory<byte> TargetPeerId { get; }
    public ReadOnlyMemory<byte> AttemptId { get; }

    public byte[] EncodeTlv()
    {
        var encoded = new byte[4 + ValueLength];
        BinaryPrimitives.WriteUInt16LittleEndian(encoded, ExtensionType);
        BinaryPrimitives.WriteUInt16LittleEndian(encoded.AsSpan(2), ValueLength);
        encoded[4] = Version;
        InitiatorPeerId.Span.CopyTo(encoded.AsSpan(5));
        TargetPeerId.Span.CopyTo(encoded.AsSpan(37));
        AttemptId.Span.CopyTo(encoded.AsSpan(69));
        return encoded;
    }

    public static RemoteControlHandshakeSoa RequireFromExtensions(ReadOnlySpan<byte> extensions)
    {
        RemoteControlHandshakeSoa? soa = null;
        while (!extensions.IsEmpty)
        {
            if (extensions.Length < 4) { throw new InvalidDataException("Truncated handshake extension header."); }
            var type = BinaryPrimitives.ReadUInt16LittleEndian(extensions);
            var length = BinaryPrimitives.ReadUInt16LittleEndian(extensions[2..]);
            extensions = extensions[4..];
            if (length > extensions.Length) { throw new InvalidDataException("Truncated handshake extension value."); }
            if (type == ExtensionType)
            {
                if (soa is not null) { throw new InvalidDataException("Duplicate remote-control SOA extension."); }
                if (length != ValueLength || extensions[0] != Version)
                {
                    throw new InvalidDataException("Unsupported remote-control SOA version or length.");
                }
                soa = new RemoteControlHandshakeSoa(extensions.Slice(1, 32).ToArray(),
                    extensions.Slice(33, 32).ToArray(), extensions.Slice(65, 16).ToArray());
            }
            extensions = extensions[length..];
        }
        return soa ?? throw new InvalidDataException("LAN remote control requires an authenticated SOA identity binding.");
    }
}

public static class RemoteControlHandshakeBinding
{
    public static RemoteControlHandshakeCandidate ValidateAndResolveMessageA(
        ReadOnlyMemory<byte> frame, string localDeviceId, IReadOnlyCollection<RemoteControlTrustedPeer> trustedPeers)
    {
        ArgumentNullException.ThrowIfNull(trustedPeers);
        var messageA = WebRtcProductHandshakeCodec.DecodeMessageA(frame.Span);
        var soa = RemoteControlHandshakeSoa.RequireFromExtensions(messageA.ExtensionsRaw.Span);
        if (!soa.TargetPeerId.Span.SequenceEqual(PeerId(localDeviceId)))
        {
            throw new InvalidDataException("Remote-control SOA targets a different local identity.");
        }
        var matches = new List<RemoteControlTrustedPeer>();
        foreach (var peer in trustedPeers)
        {
            if (soa.InitiatorPeerId.Span.SequenceEqual(PeerId(peer.DeviceId)) ||
                (peer.KnownDeviceIds is not null && peer.KnownDeviceIds.Any(alias => soa.InitiatorPeerId.Span.SequenceEqual(PeerId(alias)))))
            {
                matches.Add(peer);
            }
        }
        if (matches.Count == 0) { throw new InvalidDataException("Remote-control initiator has no trusted protocol identity."); }
        var canonicalPeers = matches.Select(peer => CanonicalDeviceId(peer.DeviceId)).Distinct(StringComparer.Ordinal).ToArray();
        var pins = matches.Select(peer => peer.ProtocolPublicKeyFingerprint).Distinct(StringComparer.Ordinal).ToArray();
        if (canonicalPeers.Length != 1 || pins.Length != 1)
        {
            throw new InvalidDataException("Remote-control SOA resolves to ambiguous trusted identities or protocol fingerprints.");
        }
        var claimedIdentity = WebRtcProductProtocolIdentityPublicKey.DecodeWithLegacyFallback(messageA.IdentityPublicKey.Span);
        if (!string.Equals(claimedIdentity.AuthoritativeFingerprint, pins[0], StringComparison.Ordinal))
        {
            throw new InvalidDataException("Remote-control MessageA protocol identity conflicts with its trusted SOA peer.");
        }
        return new RemoteControlHandshakeCandidate(new ProductHandshakePeerContext(canonicalPeers[0], pins[0]), frame.ToArray(), soa);
    }

    public static byte[] PeerId(string deviceId) =>
        SHA256.HashData(Encoding.UTF8.GetBytes(CanonicalDeviceId(deviceId)[3..]));

    public static string CanonicalDeviceId(string deviceId) =>
        ProductDeviceIdentity.CanonicalDeviceId(deviceId);
}
