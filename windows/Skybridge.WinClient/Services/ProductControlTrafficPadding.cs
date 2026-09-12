using System.Buffers.Binary;

namespace Skybridge.WinClient.Services;

/// <summary>SBP2 framing used by the established product-control adapters.</summary>
internal static class ProductControlTrafficPadding
{
    internal static byte[] Unwrap(byte[] frame)
    {
        if (frame.Length < 4 || !frame.AsSpan(0, 4).SequenceEqual("SBP2"u8)) return frame;
        if (frame.Length < 8) throw new InvalidDataException("Truncated SBP2 control header.");
        var actualLength = BinaryPrimitives.ReadUInt32BigEndian(frame.AsSpan(4, 4));
        if (actualLength > frame.Length - 8) throw new InvalidDataException("SBP2 control payload exceeds its frame.");
        return frame.AsSpan(8, checked((int)actualLength)).ToArray();
    }

    internal static byte[] Wrap(ReadOnlySpan<byte> payload)
    {
        var frame = new byte[checked(payload.Length + 8)];
        "SBP2"u8.CopyTo(frame);
        BinaryPrimitives.WriteUInt32BigEndian(frame.AsSpan(4), checked((uint)payload.Length));
        payload.CopyTo(frame.AsSpan(8));
        return frame;
    }
}
