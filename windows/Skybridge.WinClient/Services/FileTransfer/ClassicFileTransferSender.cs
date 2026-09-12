using System.Buffers;
using System.Security.Cryptography;

namespace Skybridge.WinClient.Services.FileTransfer;

internal static class ClassicFileTransferSender
{
    internal static async Task<PreparedFile> PrepareAsync(string sourcePath, string transferId,
        LanProductIdentity localIdentity, ReadOnlyMemory<byte> key, CancellationToken cancellationToken)
    {
        // Keep this descriptor for hashing and transmission. Windows denies writers
        // for its lifetime; the second digest also detects changed Unix test sources.
        var source = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read,
            64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        try
        {
            var length = source.Length;
            if (length > ClassicFileTransferWire.MaximumFileBytes)
                throw new InvalidDataException("This file exceeds the supported 2 GiB transfer limit.");
            var hash = ClassicFileTransferOperation.Hash(await SHA256.HashDataAsync(source, cancellationToken).ConfigureAwait(false));
            if (source.Position != length || source.Length != length) throw new IOException("The selected file changed during preparation.");
            source.Position = 0;
            var metadata = ClassicFileTransferWire.Authenticate(new ClassicFileMetadata(transferId, Path.GetFileName(sourcePath),
                length, hash, ClassicFileTransferWire.MaximumChunkBytes, ClassicFileTransferWire.SecurityVersion,
                SenderDeviceId: localIdentity.DeviceId, SenderDeviceName: localIdentity.DeviceName,
                SenderPlatform: localIdentity.Platform, SenderOSVersion: localIdentity.OsVersion,
                SenderModelName: localIdentity.ModelName, SenderChip: localIdentity.Chip), key.Span);
            return new(source, metadata);
        }
        catch (Exception failure)
        {
            try { await source.DisposeAsync().ConfigureAwait(false); }
            catch (Exception cleanup) { throw new AggregateException("File preparation and descriptor cleanup failed.", failure, cleanup); }
            throw;
        }
    }

    internal static async Task<ClassicFileTransferResult> SendAsync(Stream network, PreparedFile prepared,
        ReadOnlyMemory<byte> key, IProgress<ClassicFileTransferProgress>? progress, CancellationToken cancellationToken)
    {
        prepared.BeginSending();
        var source = prepared.Source;
        var metadata = prepared.Metadata;
        ClassicFileTransferWire.Verify(metadata, key.Span);
        await ClassicFileTransferOperation.WriteAsync(network, ClassicFileFrameType.Metadata,
            ClassicFileTransferWire.Encode(metadata), cancellationToken).ConfigureAwait(false);
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var receipt = ReadReceiptAsync(network, metadata, key, lifetime.Token);
        var sending = SendChunksAsync(network, source, metadata, key, progress, lifetime.Token);
        try
        {
            var first = await Task.WhenAny(sending, receipt).ConfigureAwait(false);
            await first.ConfigureAwait(false);
            await sending.ConfigureAwait(false);
            lifetime.CancelAfter(TimeSpan.FromMinutes(2));
            try { return await receipt.ConfigureAwait(false); }
            catch (OperationCanceledException failure) when (!cancellationToken.IsCancellationRequested)
            { throw new TimeoutException("The receiver did not confirm the saved file within two minutes of sending completion.", failure); }
        }
        catch (Exception failure)
        {
            lifetime.Cancel();
            var failures = new List<Exception> { failure };
            foreach (var worker in new Task[] { sending, receipt })
            {
                try { await worker.ConfigureAwait(false); }
                catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
                catch (Exception secondary) { if (!failures.Contains(secondary)) failures.Add(secondary); }
            }
            if (failures.Count > 1) throw new AggregateException("File transmission and peer receipt failed.", failures);
            throw;
        }
    }

    /// <summary>Owns the selected descriptor across hashing and sending, prepared before opening the peer's timed file connection.</summary>
    internal sealed class PreparedFile(FileStream source, ClassicFileMetadata metadata) : IAsyncDisposable
    {
        private int _sending;
        internal FileStream Source { get; } = source;
        internal void BeginSending()
        {
            if (Interlocked.Exchange(ref _sending, 1) != 0) throw new InvalidOperationException("A prepared file can be transmitted only once.");
        }
        internal ClassicFileMetadata Metadata { get; } = metadata;
        public ValueTask DisposeAsync() => Source.DisposeAsync();
    }

    private static async Task SendChunksAsync(Stream network, FileStream source, ClassicFileMetadata metadata,
        ReadOnlyMemory<byte> key, IProgress<ClassicFileTransferProgress>? progress, CancellationToken cancellationToken)
    {
        var buffer = ArrayPool<byte>.Shared.Rent(metadata.ChunkSize);
        using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        try
        {
            long sent = 0;
            var index = 0;
            while (sent < metadata.FileSize)
            {
                var count = checked((int)Math.Min(metadata.ChunkSize, metadata.FileSize - sent));
                await source.ReadExactlyAsync(buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
                digest.AppendData(buffer, 0, count);
                var chunk = ClassicFileTransferWire.SealChunk(index++, buffer.AsSpan(0, count), key.Span);
                await ClassicFileTransferOperation.WriteAsync(network, ClassicFileFrameType.Chunk,
                    ClassicFileTransferWire.Encode(chunk), cancellationToken).ConfigureAwait(false);
                sent += count;
                progress?.Report(new(metadata.TransferId, metadata.FileName, sent, metadata.FileSize, false));
            }
            if (source.Length != metadata.FileSize || ClassicFileTransferOperation.Hash(digest.GetHashAndReset()) != metadata.FileHash)
                throw new IOException("The selected file changed during transmission; completion was withheld.");
            await ClassicFileTransferOperation.WriteAsync(network, ClassicFileFrameType.Complete,
                ReadOnlyMemory<byte>.Empty, cancellationToken).ConfigureAwait(false);
        }
        finally { ArrayPool<byte>.Shared.Return(buffer, clearArray: true); }
    }

    private static async Task<ClassicFileTransferResult> ReadReceiptAsync(Stream network, ClassicFileMetadata metadata,
        ReadOnlyMemory<byte> key, CancellationToken cancellationToken)
    {
        // The peer may be waiting for its local user to accept the file. This is
        // separate from each data-frame deadline, and never substitutes for a receipt.
        var frame = await ClassicFileTransferFrames.ReadAsync(network, cancellationToken).ConfigureAwait(false);
        if (frame.Type != ClassicFileFrameType.Receipt) throw new InvalidDataException("The receiver did not send a file receipt.");
        var receipt = ClassicFileTransferWire.Decode<ClassicFileReceipt>(frame.Payload);
        ClassicFileTransferWire.Verify(receipt, metadata, key.Span);
        if (!receipt.Success) throw new ClassicFileTransferRejectedException(receipt.Error ?? "The receiver rejected this transfer.");
        return new(metadata.TransferId, metadata.FileName, receipt.ReceivedBytes, metadata.FileHash);
    }
}
