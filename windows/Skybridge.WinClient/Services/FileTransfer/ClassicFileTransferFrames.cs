using System.Buffers.Binary;

namespace Skybridge.WinClient.Services.FileTransfer;

internal enum ClassicFileFrameType : uint { Metadata = 1, Chunk = 2, Complete = 3, Receipt = 4 }
internal sealed record ClassicFileFrame(ClassicFileFrameType Type, byte[] Payload);

/// <summary>Framing for one ordered classic file-transfer connection; its transaction owns the stream and cancellation.</summary>
internal static class ClassicFileTransferFrames
{
    internal static async Task<ClassicFileFrame> ReadAsync(Stream stream, CancellationToken cancellationToken)
    {
        var header = new byte[8];
        await stream.ReadExactlyAsync(header, cancellationToken).ConfigureAwait(false);
        var type = (ClassicFileFrameType)BinaryPrimitives.ReadUInt32BigEndian(header);
        var length = BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(4));
        ValidateHeader(type, length);
        var payload = new byte[checked((int)length)];
        await stream.ReadExactlyAsync(payload, cancellationToken).ConfigureAwait(false);
        return new(type, payload);
    }

    internal static async Task WriteAsync(Stream stream, ClassicFileFrameType type, ReadOnlyMemory<byte> payload,
        CancellationToken cancellationToken)
    {
        ValidateHeader(type, checked((uint)payload.Length));
        var header = new byte[8];
        BinaryPrimitives.WriteUInt32BigEndian(header, (uint)type);
        BinaryPrimitives.WriteUInt32BigEndian(header.AsSpan(4), checked((uint)payload.Length));
        await stream.WriteAsync(header, cancellationToken).ConfigureAwait(false);
        if (!payload.IsEmpty) await stream.WriteAsync(payload, cancellationToken).ConfigureAwait(false);
    }

    private static void ValidateHeader(ClassicFileFrameType type, uint length)
    {
        if (type is not (ClassicFileFrameType.Metadata or ClassicFileFrameType.Chunk or ClassicFileFrameType.Complete or ClassicFileFrameType.Receipt))
            throw new InvalidDataException("Unsupported classic file-transfer frame type.");
        if (length > ClassicFileTransferWire.MaximumMessageBytes || (type == ClassicFileFrameType.Complete ? length != 0 : length == 0))
            throw new InvalidDataException("Invalid classic file-transfer frame length.");
    }
}
