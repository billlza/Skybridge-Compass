using System.Buffers.Binary;
using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Skybridge.WinClient.Services.FileTransfer;

internal sealed record ClassicFileMetadata(
    string TransferId, string FileName, long FileSize, string FileHash, int ChunkSize,
    int SecurityVersion, byte[]? MetadataAuthTag = null, string? Compression = null,
    string? SenderDeviceId = null, string? SenderDeviceName = null, string? SenderPlatform = null,
    string? SenderOSVersion = null, string? SenderModelName = null, string? SenderChip = null);

internal sealed record ClassicFileChunk(int Index, byte[] Data, int Size, byte[] Nonce, byte[] AuthenticationTag);

internal sealed record ClassicFileReceipt(
    string TransferId, bool Success, long ReceivedBytes, int SecurityVersion,
    string? FileHash = null, string? Error = null, byte[]? AuthTag = null);

/// <summary>The existing Apple LAN file-transfer v2 contract, including its named authentication transcripts.</summary>
internal static class ClassicFileTransferWire
{
    internal const int SecurityVersion = 2;
    internal const long MaximumFileBytes = 2L * 1024 * 1024 * 1024;
    internal const int MinimumChunkBytes = 64 * 1024;
    internal const int MaximumChunkBytes = 512 * 1024;
    internal const int MaximumMessageBytes = 1024 * 1024;
    private static readonly UTF8Encoding Utf8 = new(false, true);
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        RespectNullableAnnotations = true,
        RespectRequiredConstructorParameters = true,
        AllowDuplicateProperties = false,
        MaxDepth = 8
    };

    internal static byte[] Encode<T>(T payload)
    {
        var encoded = JsonSerializer.SerializeToUtf8Bytes(payload, Json);
        if (encoded.Length > MaximumMessageBytes) throw new InvalidDataException("File-transfer payload exceeds its wire limit.");
        return encoded;
    }

    internal static T Decode<T>(ReadOnlySpan<byte> bytes)
    {
        if (bytes.IsEmpty || bytes.Length > MaximumMessageBytes) throw new InvalidDataException("Invalid file-transfer payload length.");
        return JsonSerializer.Deserialize<T>(bytes, Json) ?? throw new InvalidDataException("File-transfer payload cannot be null.");
    }

    internal static byte[] DeriveTransferKey(ProductSessionKeys keys, string transferId)
    {
        ArgumentNullException.ThrowIfNull(keys);
        ValidateTransferId(transferId);
        var material = new byte[64];
        var sendFirst = keys.SendKey.Span.SequenceCompareTo(keys.ReceiveKey.Span) <= 0;
        (sendFirst ? keys.SendKey : keys.ReceiveKey).Span.CopyTo(material);
        (sendFirst ? keys.ReceiveKey : keys.SendKey).Span.CopyTo(material.AsSpan(32));
        try
        {
            return ProductHandshakeKeyDerivation.HkdfSha256(material,
                "skybridge-classic-file-transfer-v1"u8, Utf8.GetBytes(transferId), 32);
        }
        finally { CryptographicOperations.ZeroMemory(material); }
    }

    internal static ClassicFileMetadata Authenticate(ClassicFileMetadata metadata, ReadOnlySpan<byte> key)
    {
        ValidateMetadata(metadata);
        RequireKey(key);
        return metadata with { MetadataAuthTag = HMACSHA256.HashData(key, MetadataTranscript(metadata)) };
    }

    internal static void Verify(ClassicFileMetadata metadata, ReadOnlySpan<byte> key)
    {
        ValidateMetadata(metadata);
        RequireAuthentication(metadata.MetadataAuthTag, MetadataTranscript(metadata), key);
    }

    internal static ClassicFileReceipt Authenticate(ClassicFileReceipt receipt, ReadOnlySpan<byte> key)
    {
        ValidateReceipt(receipt);
        RequireKey(key);
        return receipt with { AuthTag = HMACSHA256.HashData(key, ReceiptTranscript(receipt)) };
    }

    internal static void Verify(ClassicFileReceipt receipt, ClassicFileMetadata expected, ReadOnlySpan<byte> key)
    {
        ValidateReceipt(receipt);
        RequireAuthentication(receipt.AuthTag, ReceiptTranscript(receipt), key);
        if (receipt.TransferId != expected.TransferId) throw new InvalidDataException("The file receipt belongs to another transfer.");
        if (receipt.ReceivedBytes > expected.FileSize) throw new InvalidDataException("The file receipt exceeds the admitted file size.");
        if (receipt.Success && (receipt.ReceivedBytes != expected.FileSize || receipt.FileHash != expected.FileHash || receipt.Error is not null))
            throw new InvalidDataException("The receiver did not confirm the complete expected file.");
    }

    internal static ClassicFileChunk SealChunk(int index, ReadOnlySpan<byte> plaintext, ReadOnlySpan<byte> key)
    {
        RequireKey(key);
        if (index is < 0 or >= 65536 || plaintext.IsEmpty || plaintext.Length > MaximumChunkBytes)
            throw new InvalidDataException("Invalid file chunk index or size.");
        var nonce = RandomNumberGenerator.GetBytes(12);
        var encrypted = new byte[plaintext.Length];
        var tag = new byte[16];
        using var aes = new AesGcm(key, 16);
        aes.Encrypt(nonce, plaintext, encrypted, tag);
        return new(index, encrypted, plaintext.Length, nonce, tag);
    }

    internal static byte[] OpenChunk(ClassicFileChunk chunk, int expectedIndex, long remainingBytes,
        int negotiatedChunkBytes, ReadOnlySpan<byte> key, string? compression = null)
    {
        RequireKey(key);
        if (negotiatedChunkBytes is < MinimumChunkBytes or > MaximumChunkBytes || remainingBytes <= 0 ||
            expectedIndex is < 0 or >= 65536 || chunk.Index != expectedIndex ||
            chunk.Size <= 0 || chunk.Size > Math.Min(remainingBytes, negotiatedChunkBytes) ||
            chunk.Data.Length is < 1 or > MaximumMessageBytes || chunk.Nonce.Length != 12 || chunk.AuthenticationTag.Length != 16)
            throw new InvalidDataException("File chunk does not match the admitted transfer.");
        var plaintext = new byte[chunk.Data.Length];
        try
        {
            using var aes = new AesGcm(key, 16);
            aes.Decrypt(chunk.Nonce, chunk.Data, chunk.AuthenticationTag, plaintext);
            if (compression is null)
            {
                if (plaintext.Length != chunk.Size) throw new InvalidDataException("Decoded file chunk length differs from its declared size.");
                return plaintext;
            }
            if (compression != "zlib") throw new InvalidDataException("Unsupported file compression.");
            try { return DecompressChunk(plaintext, chunk.Size); }
            finally { CryptographicOperations.ZeroMemory(plaintext); }
        }
        catch
        {
            CryptographicOperations.ZeroMemory(plaintext);
            throw;
        }
    }

    private static byte[] DecompressChunk(byte[] payload, int expectedBytes)
    {
        using var input = new MemoryStream(payload, writable: false);
        // The established Apple "zlib" wire mode uses NSData / COMPRESSION_ZLIB:
        // raw RFC 1951 DEFLATE, without an RFC 1950 zlib header or checksum.
        using var inflater = new DeflateStream(input, CompressionMode.Decompress);
        var output = new byte[expectedBytes];
        try
        {
            inflater.ReadExactly(output);
            if (inflater.ReadByte() != -1) throw new InvalidDataException("Compressed file chunk exceeds its declared output size.");
            return output;
        }
        catch
        {
            CryptographicOperations.ZeroMemory(output);
            throw;
        }
    }

    internal static void ValidateMetadata(ClassicFileMetadata value)
    {
        ArgumentNullException.ThrowIfNull(value);
        ValidateVersion(value.SecurityVersion);
        ValidateTransferId(value.TransferId);
        ValidateVisible(value.FileName, 255);
        if (string.IsNullOrWhiteSpace(value.FileName) || value.FileName.Trim() != value.FileName ||
            value.FileName is "." or ".." || value.FileName.Contains('/') || value.FileName.Contains('\\'))
            throw new InvalidDataException("The file name must be a single visible name.");
        if (value.FileSize is < 0 or > MaximumFileBytes || value.ChunkSize is < MinimumChunkBytes or > MaximumChunkBytes)
            throw new InvalidDataException("The file size or negotiated chunk size is outside the protocol limits.");
        ValidateHash(value.FileHash);
        if (value.Compression is not (null or "zlib")) throw new InvalidDataException("Unsupported file compression.");
        foreach (var field in new[] { value.SenderDeviceId, value.SenderDeviceName, value.SenderPlatform,
            value.SenderOSVersion, value.SenderModelName, value.SenderChip }) ValidateVisible(field, 256);
    }

    internal static void ValidateTransferId(string value)
    {
        if (value.Length is < 1 or > 128 || value.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('-' or '_')))
            throw new InvalidDataException("Invalid file-transfer identifier.");
    }

    internal static void ValidateHash(string value)
    {
        if (value.Length != 64 || value.Any(c => c is not (>= '0' and <= '9') and not (>= 'a' and <= 'f')))
            throw new InvalidDataException("A file digest must be a lowercase SHA-256 value.");
    }

    private static void ValidateReceipt(ClassicFileReceipt value)
    {
        ArgumentNullException.ThrowIfNull(value);
        ValidateVersion(value.SecurityVersion);
        ValidateTransferId(value.TransferId);
        if (value.ReceivedBytes is < 0 or > MaximumFileBytes) throw new InvalidDataException("Invalid file receipt byte count.");
        if (value.FileHash is not null) ValidateHash(value.FileHash);
        ValidateVisible(value.Error, 1024);
    }

    private static void ValidateVisible(string? value, int maximumBytes)
    {
        if (value is null) return;
        if (Utf8.GetByteCount(value) > maximumBytes || value.EnumerateRunes().Any(r =>
            Rune.GetUnicodeCategory(r) is UnicodeCategory.Control or UnicodeCategory.Format ||
            r.Value is 0x061c or 0x200e or 0x200f or (>= 0x202a and <= 0x202e) or
                0x2044 or (>= 0x2066 and <= 0x2069) or 0x2215 or 0x29f5 or 0x29f8 or 0x29f9 or 0xfe68 or 0xff0f or 0xff3c))
            throw new InvalidDataException("File-transfer display metadata contains an unsafe or excessive value.");
    }

    private static void ValidateVersion(int version)
    {
        if (version != SecurityVersion) throw new InvalidDataException("Unsupported file-transfer security version.");
    }

    private static void RequireKey(ReadOnlySpan<byte> key)
    {
        if (key.Length != 32) throw new CryptographicException("The file-transfer key must come from an established product session.");
    }

    private static void RequireAuthentication(byte[]? received, byte[] transcript, ReadOnlySpan<byte> key)
    {
        RequireKey(key);
        var expected = HMACSHA256.HashData(key, transcript);
        if (received is not { Length: 32 } || !CryptographicOperations.FixedTimeEquals(received, expected))
            throw new CryptographicException("File-transfer authentication failed.");
    }

    internal static byte[] MetadataTranscript(ClassicFileMetadata m) => Transcript(1, m.SecurityVersion,
    [
        ("transfer_id", m.TransferId), ("file_name", m.FileName), ("file_size", m.FileSize.ToString(CultureInfo.InvariantCulture)),
        ("file_hash", m.FileHash), ("chunk_size", m.ChunkSize.ToString(CultureInfo.InvariantCulture)), ("compression", m.Compression),
        ("sender_device_id", m.SenderDeviceId), ("sender_device_name", m.SenderDeviceName), ("sender_platform", m.SenderPlatform),
        ("sender_os_version", m.SenderOSVersion), ("sender_model_name", m.SenderModelName), ("sender_chip", m.SenderChip)
    ]);

    internal static byte[] ReceiptTranscript(ClassicFileReceipt r) => Transcript(2, r.SecurityVersion,
    [
        ("transfer_id", r.TransferId), ("success", r.Success ? "1" : "0"),
        ("received_bytes", r.ReceivedBytes.ToString(CultureInfo.InvariantCulture)), ("file_hash", r.FileHash), ("error", r.Error)
    ]);

    private static byte[] Transcript(byte purpose, int version, (string Name, string? Value)[] fields)
    {
        ValidateVersion(version);
        using var stream = new MemoryStream();
        stream.Write("SkyBridgeClassicTransfer\0"u8);
        stream.WriteByte(purpose);
        Span<byte> integer = stackalloc byte[8];
        BinaryPrimitives.WriteUInt32BigEndian(integer, checked((uint)version)); stream.Write(integer[..4]);
        BinaryPrimitives.WriteUInt16BigEndian(integer, checked((ushort)fields.Length)); stream.Write(integer[..2]);
        foreach (var (name, value) in fields)
        {
            var label = Utf8.GetBytes(name);
            BinaryPrimitives.WriteUInt16BigEndian(integer, checked((ushort)label.Length)); stream.Write(integer[..2]);
            stream.Write(label);
            stream.WriteByte(value is null ? (byte)0 : (byte)1);
            var bytes = value is null ? [] : Utf8.GetBytes(value);
            BinaryPrimitives.WriteUInt64BigEndian(integer, checked((ulong)bytes.Length)); stream.Write(integer);
            stream.Write(bytes);
        }
        return stream.ToArray();
    }
}
