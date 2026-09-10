using System.Security.Cryptography;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.Services.FileTransfer;

internal static class ClassicFileTransferWireTests
{
    internal static IReadOnlyList<(string Name, Func<Task> Run)> Cases { get; } =
    [
        ("classic transfer matches Apple v2 transcripts and shared key derivation", GoldenContracts),
        ("classic metadata rejects tampering duplicate fields and unsafe names", MetadataBoundaries),
        ("classic chunks retain authenticated bytes and enforce ordering", ChunkBoundaries),
        ("classic receipts require the expected authenticated final file", ReceiptBoundaries),
        ("classic framing preserves ordered messages and rejects truncation before success", FrameBoundaries)
    ];
    private sealed record Golden(string MetadataTranscriptHex, string ReceiptTranscriptHex, string TransferKeyHex,
        string MetadataAuthTagHex, string RawDeflateHex, string PlainHex);
    private static ClassicFileMetadata Metadata() => new("t", "f", 0, new string('a', 64), 65536, 2);
    private static void Require(bool value, string reason) { if (!value) throw new InvalidOperationException(reason); }
    private static void Throws<T>(Action action) where T : Exception
    {
        try { action(); } catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private static Task GoldenContracts()
    {
        var vector = JsonSerializer.Deserialize<Golden>(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory,
            "Fixtures", "classic-file-transfer-v2.json")), new JsonSerializerOptions(JsonSerializerDefaults.Web))
            ?? throw new InvalidDataException("Missing classic transfer fixture.");
        using var initiator = new ProductSessionKeys(ProductHandshakeRole.Initiator, "fixture", new byte[32],
            Enumerable.Range(0, 32).Select(i => (byte)i).ToArray(), Enumerable.Range(32, 32).Select(i => (byte)i).ToArray());
        using var responder = new ProductSessionKeys(ProductHandshakeRole.Responder, "fixture", initiator.TranscriptHash,
            initiator.ReceiveKey, initiator.SendKey);
        var key = ClassicFileTransferWire.DeriveTransferKey(initiator, "t");
        Require(Convert.ToHexStringLower(key) == vector.TransferKeyHex &&
            key.SequenceEqual(ClassicFileTransferWire.DeriveTransferKey(responder, "t")), "Transfer key direction or domain changed.");
        Require(!key.SequenceEqual(ClassicFileTransferWire.DeriveTransferKey(initiator, "other")), "Distinct transfers reused a key.");
        Require(Convert.ToHexStringLower(ClassicFileTransferWire.MetadataTranscript(Metadata())) == vector.MetadataTranscriptHex,
            "Metadata transcript differs from the Apple v2 vector.");
        Require(Convert.ToHexStringLower(ClassicFileTransferWire.ReceiptTranscript(new("t", true, 0, 2))) == vector.ReceiptTranscriptHex,
            "Receipt transcript differs from the Apple v2 vector.");
        var tag = ClassicFileTransferWire.Authenticate(Metadata(), key).MetadataAuthTag
            ?? throw new InvalidOperationException("Metadata signing did not return a tag.");
        Require(Convert.ToHexStringLower(tag) == vector.MetadataAuthTagHex, "Metadata HMAC differs from the independent vector.");
        return Task.CompletedTask;
    }

    private static Task MetadataBoundaries()
    {
        var key = new byte[32];
        var signed = ClassicFileTransferWire.Authenticate(Metadata(), key);
        ClassicFileTransferWire.Verify(ClassicFileTransferWire.Decode<ClassicFileMetadata>(ClassicFileTransferWire.Encode(signed)), key);
        Throws<CryptographicException>(() => ClassicFileTransferWire.Verify(signed with { FileName = "changed" }, key));
        Throws<CryptographicException>(() => ClassicFileTransferWire.Verify(signed with { SenderDeviceName = "" }, key));
        Throws<CryptographicException>(() => ClassicFileTransferWire.Verify(signed with { MetadataAuthTag = null }, key));
        var json = "{\"transferId\":\"t\",\"fileName\":\"f\",\"fileSize\":0,\"fileHash\":\"" + new string('a',64) + "\",\"chunkSize\":65536,\"securityVersion\":2}";
        ClassicFileTransferWire.ValidateMetadata(ClassicFileTransferWire.Decode<ClassicFileMetadata>(Encoding.UTF8.GetBytes(json)));
        Throws<JsonException>(() => ClassicFileTransferWire.Decode<ClassicFileMetadata>(Encoding.UTF8.GetBytes(json.Replace("\"fileSize\":0,", ""))));
        Throws<JsonException>(() => ClassicFileTransferWire.Decode<ClassicFileMetadata>(Encoding.UTF8.GetBytes(json.Replace("\"fileSize\":0", "\"fileSize\":0,\"fileSize\":1"))));
        foreach (var name in new[] { "../f", "a/b", "a\\b", "a\u2044b", "a\u2215b", "a\uff0fb", "a\u202eb", "f\n", ".", "..", new string('x', 256) })
            Throws<InvalidDataException>(() => ClassicFileTransferWire.ValidateMetadata(Metadata() with { FileName = name }));
        foreach (var value in new[] { Metadata() with { SecurityVersion = 1 }, Metadata() with { FileSize = -1 },
            Metadata() with { FileSize = ClassicFileTransferWire.MaximumFileBytes + 1 }, Metadata() with { ChunkSize = 65535 },
            Metadata() with { FileHash = new string('A', 64) }, Metadata() with { Compression = "unknown" } })
            Throws<InvalidDataException>(() => ClassicFileTransferWire.ValidateMetadata(value));
        return Task.CompletedTask;
    }

    private static Task ChunkBoundaries()
    {
        var key = new byte[32];
        var input = Enumerable.Range(0, 257).Select(i => (byte)i).ToArray();
        var chunk = ClassicFileTransferWire.SealChunk(0, input, key);
        Require(ClassicFileTransferWire.OpenChunk(chunk, 0, 1024, 65536, key).SequenceEqual(input), "A valid short chunk changed its bytes.");
        Throws<InvalidDataException>(() => ClassicFileTransferWire.OpenChunk(chunk, 1, 1024, 65536, key));
        Throws<InvalidDataException>(() => ClassicFileTransferWire.OpenChunk(chunk, 0, 256, 65536, key));
        Throws<InvalidDataException>(() => ClassicFileTransferWire.OpenChunk(chunk with { Size = 0 }, 0, 1024, 65536, key));
        Throws<InvalidDataException>(() => ClassicFileTransferWire.OpenChunk(chunk with { Size = 256 }, 0, 1024, 65536, key));
        var altered = chunk.Data.ToArray(); altered[0] ^= 1;
        Throws<CryptographicException>(() => ClassicFileTransferWire.OpenChunk(chunk with { Data = altered }, 0, 1024, 65536, key));
        Throws<InvalidDataException>(() => ClassicFileTransferWire.OpenChunk(chunk with { Nonce = new byte[11] }, 0, 1024, 65536, key));
        var apple = JsonSerializer.Deserialize<Golden>(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory,
            "Fixtures", "classic-file-transfer-v2.json")), new JsonSerializerOptions(JsonSerializerDefaults.Web))
            ?? throw new InvalidDataException("Missing Apple compression fixture.");
        Require(Convert.FromHexString(apple.PlainHex).SequenceEqual(input), "The independent Apple fixture changed its expected bytes.");
        var compressedChunk = ClassicFileTransferWire.SealChunk(0, Convert.FromHexString(apple.RawDeflateHex), key) with { Size = input.Length };
        Require(ClassicFileTransferWire.OpenChunk(compressedChunk, 0, 1024, 65536, key, "zlib").SequenceEqual(input),
            "The Apple raw-DEFLATE chunk did not decode to the declared bytes.");
        Throws<InvalidDataException>(() => ClassicFileTransferWire.OpenChunk(compressedChunk with { Size = 256 }, 0, 1024, 65536, key, "zlib"));
        Throws<EndOfStreamException>(() => ClassicFileTransferWire.OpenChunk(compressedChunk with { Size = 258 }, 0, 1024, 65536, key, "zlib"));
        using var wrapped = new MemoryStream();
        using (var encoder = new ZLibStream(wrapped, CompressionLevel.Fastest, leaveOpen: true)) encoder.Write(input);
        var wrappedChunk = ClassicFileTransferWire.SealChunk(0, wrapped.ToArray(), key) with { Size = input.Length };
        Throws<InvalidDataException>(() => ClassicFileTransferWire.OpenChunk(wrappedChunk, 0, 1024, 65536, key, "zlib"));
        return Task.CompletedTask;
    }

    private static Task ReceiptBoundaries()
    {
        var key = new byte[32];
        var metadata = Metadata();
        var receipt = ClassicFileTransferWire.Authenticate(new ClassicFileReceipt("t", true, 0, 2, metadata.FileHash), key);
        ClassicFileTransferWire.Verify(receipt, metadata, key);
        Throws<CryptographicException>(() => ClassicFileTransferWire.Verify(receipt with { ReceivedBytes = 1 }, metadata, key));
        foreach (var changed in new[] { receipt with { TransferId = "other" }, receipt with { FileHash = null },
            receipt with { ReceivedBytes = 1 }, receipt with { Error = "not committed" } })
            Throws<InvalidDataException>(() => ClassicFileTransferWire.Verify(ClassicFileTransferWire.Authenticate(changed, key), metadata, key));
        var refusal = ClassicFileTransferWire.Authenticate(new ClassicFileReceipt("t", false, 0, 2, Error: "Declined"), key);
        ClassicFileTransferWire.Verify(refusal, metadata, key);
        Require(!refusal.Success, "An authenticated refusal became success.");
        return Task.CompletedTask;
    }

    private static async Task FrameBoundaries()
    {
        using var wire = new MemoryStream();
        await ClassicFileTransferFrames.WriteAsync(wire, ClassicFileFrameType.Metadata, new byte[] { 1, 2, 3 }, default);
        await ClassicFileTransferFrames.WriteAsync(wire, ClassicFileFrameType.Complete, ReadOnlyMemory<byte>.Empty, default);
        var bytes = wire.ToArray();
        Require(bytes.Take(8).SequenceEqual(new byte[] { 0, 0, 0, 1, 0, 0, 0, 3 }), "Classic frame header endianness changed.");
        wire.Position = 0;
        var first = await ClassicFileTransferFrames.ReadAsync(wire, default);
        var second = await ClassicFileTransferFrames.ReadAsync(wire, default);
        Require(first.Type == ClassicFileFrameType.Metadata && first.Payload.SequenceEqual(new byte[] { 1, 2, 3 }) &&
            second.Type == ClassicFileFrameType.Complete && second.Payload.Length == 0 && wire.Position == wire.Length,
            "Coalesced classic frames changed boundaries or content.");
        foreach (var truncated in new[] { bytes[..4], bytes[..10] })
        {
            using var input = new MemoryStream(truncated);
            await ThrowsAsync<EndOfStreamException>(() => ClassicFileTransferFrames.ReadAsync(input, default));
        }
        foreach (var malformed in new[] {
            new byte[] { 0, 0, 0, 1, 0, 0, 0, 0 }, new byte[] { 0, 0, 0, 3, 0, 0, 0, 1 },
            new byte[] { 0, 0, 0, 9, 0, 0, 0, 1 }, new byte[] { 0, 0, 0, 2, 0x7f, 0xff, 0xff, 0xff } })
        {
            using var input = new MemoryStream(malformed);
            await ThrowsAsync<InvalidDataException>(() => ClassicFileTransferFrames.ReadAsync(input, default));
            Require(input.Position == 8, "Invalid length or kind was not rejected at the header boundary.");
        }
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        wire.Position = 0;
        await ThrowsAsync<OperationCanceledException>(() => ClassicFileTransferFrames.ReadAsync(wire, cancelled.Token));
    }

    private static async Task ThrowsAsync<T>(Func<Task> operation) where T : Exception
    {
        try { await operation(); } catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }
}
