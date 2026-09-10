using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;

namespace Skybridge.WinClient.Services;

public enum RemoteControlSecurePacketType : byte
{
    Control = 1,
    Screen = 2,
    Audio = 3
}

public sealed record RemoteControlSecureOpenedPayload(RemoteControlSecurePacketType PacketType,
    byte Direction, ulong SessionHash, ulong TranscriptPrefix, uint Epoch, ulong Counter, byte[] Payload);

public static class RemoteControlSecureEnvelope
{
    public const uint Magic = 0x5342_5243;
    public const int HeaderLength = 52;
    public const int TagLength = 16;
    public const int OverheadBytes = HeaderLength + TagLength;
    public const int MaximumPayloadBytes = 8_000_000;

    public static byte[] Seal(ReadOnlySpan<byte> payload, ProductSessionKeys keys,
        RemoteControlSecurePacketType packetType, ulong counter) =>
        ProductSecureEnvelope.Seal(payload, keys.SendKey.Span, keys.Role, keys.SessionId,
            keys.TranscriptHash.Span, (byte)packetType, counter, ProductSecureEnvelopeFormat.RemoteControl);

    public static RemoteControlSecureOpenedPayload Open(ReadOnlySpan<byte> packet, ProductSessionKeys keys,
        IReadOnlyCollection<RemoteControlSecurePacketType> allowedPacketTypes)
    {
        ArgumentNullException.ThrowIfNull(keys);
        ArgumentNullException.ThrowIfNull(allowedPacketTypes);
        var opened = ProductSecureEnvelope.Open(packet, keys.ReceiveKey.Span, keys.Role, keys.SessionId,
            keys.TranscriptHash.Span, allowedPacketTypes.Select(type => (byte)type).ToArray(), ProductSecureEnvelopeFormat.RemoteControl);
        return new RemoteControlSecureOpenedPayload((RemoteControlSecurePacketType)opened.Header.PacketType,
            opened.Header.Direction, opened.Header.SessionHash, opened.Header.TranscriptPrefix,
            opened.Header.Epoch, opened.Header.Counter, opened.Payload);
    }

    public static ulong SessionIdHash(string sessionId) =>
        ProductSecureEnvelope.SessionHash(sessionId, ProductSecureEnvelopeFormat.RemoteControl);

    public static ulong TranscriptPrefix(ReadOnlySpan<byte> transcriptHash) =>
        ProductSecureEnvelope.TranscriptPrefix(transcriptHash, ProductSecureEnvelopeFormat.RemoteControl);
}

/// <summary>Owns counters and replay state for exactly one authenticated LAN session. Never share it between sockets.</summary>
public sealed class RemoteControlSecureSession : IDisposable
{
    private readonly object _gate = new();
    private readonly ProductSessionKeys _keys;
    private readonly ulong[] _sendCounters = new ulong[3];
    private readonly RemoteControlCounterWindow[] _receiveWindows =
        { new(), new(), new() };
    private bool _disposed;

    public RemoteControlSecureSession(ProductSessionKeys keys) { _keys = keys.Clone(); }

    public byte[] Seal(ReadOnlySpan<byte> payload, RemoteControlSecurePacketType packetType)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var lane = Lane(packetType);
            if (_sendCounters[lane] == ulong.MaxValue)
            { throw new ProductSecureEnvelopeException("Remote-control envelope counter is exhausted; reauthenticate the session."); }
            var counter = ++_sendCounters[lane];
            return RemoteControlSecureEnvelope.Seal(payload, _keys, packetType, counter);
        }
    }

    public RemoteControlSecureOpenedPayload Open(ReadOnlySpan<byte> packet, IReadOnlyCollection<RemoteControlSecurePacketType> allowedPacketTypes)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var opened = RemoteControlSecureEnvelope.Open(packet, _keys, allowedPacketTypes);
            try { _receiveWindows[Lane(opened.PacketType)].ValidateAndRecord(opened.Counter); }
            catch (ProductSecureEnvelopeException)
            {
                CryptographicOperations.ZeroMemory(opened.Payload);
                throw;
            }
            return opened;
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

    private static int Lane(RemoteControlSecurePacketType packetType) => packetType switch
    {
        RemoteControlSecurePacketType.Control => 0,
        RemoteControlSecurePacketType.Screen => 1,
        RemoteControlSecurePacketType.Audio => 2,
        _ => throw new ProductSecureEnvelopeException("Unsupported remote-control packet type.")
    };
}

internal sealed class RemoteControlCounterWindow
{
    private const ulong Capacity = 1024;
    private readonly HashSet<ulong> _accepted = new();
    private ulong _highest;

    internal void ValidateAndRecord(ulong counter)
    {
        if (counter == 0) { throw new ProductSecureEnvelopeException("Remote-control replay counter must be positive."); }
        if (counter <= _highest && _highest - counter >= Capacity)
        { throw new ProductSecureEnvelopeException("Remote-control replay rejected: counter-outside-window."); }
        if (!_accepted.Add(counter))
        { throw new ProductSecureEnvelopeException("Remote-control replay rejected: duplicate-counter."); }
        if (counter > _highest)
        {
            _highest = counter;
            var minimum = _highest >= Capacity ? _highest - Capacity + 1 : 1;
            _accepted.RemoveWhere(value => value < minimum);
        }
    }
}
