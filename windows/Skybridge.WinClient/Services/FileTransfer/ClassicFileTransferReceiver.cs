using System.Security.Cryptography;

namespace Skybridge.WinClient.Services.FileTransfer;

internal static class ClassicFileTransferReceiver
{
    internal static async Task<ClassicFileTransferResult> ReceiveAsync(Stream network, ClassicFileMetadata metadata,
        ReadOnlyMemory<byte> key, string destinationDirectory, IProgress<ClassicFileTransferProgress>? progress,
        CancellationToken cancellationToken)
    {
        ClassicFileTransferWire.Verify(metadata, key.Span);
        string? partial = null;
        string? savedPath = null;
        long received = 0;
        try
        {
            ValidateWindowsFileName(metadata.FileName);
            var root = Path.GetFullPath(destinationDirectory);
            if (!Directory.Exists(root)) throw new DirectoryNotFoundException("The selected receive folder no longer exists.");
            for (var directory = new DirectoryInfo(root); directory is not null; directory = directory.Parent)
                if ((directory.Attributes & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("The receive folder must not traverse a redirected directory.");
            partial = Path.Combine(root, $".skybridge-{Guid.NewGuid():N}.part");
            using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            await using (var output = new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                var index = 0;
                while (received < metadata.FileSize)
                {
                    var frame = await ClassicFileTransferOperation.ReadAsync(network, TimeSpan.FromSeconds(30), cancellationToken).ConfigureAwait(false);
                    if (frame.Type != ClassicFileFrameType.Chunk) throw new InvalidDataException("The sender ended before the declared file size.");
                    var plaintext = ClassicFileTransferWire.OpenChunk(ClassicFileTransferWire.Decode<ClassicFileChunk>(frame.Payload),
                        index++, metadata.FileSize - received, metadata.ChunkSize, key.Span, metadata.Compression);
                    try
                    {
                        await output.WriteAsync(plaintext, cancellationToken).ConfigureAwait(false);
                        digest.AppendData(plaintext);
                        received += plaintext.Length;
                        progress?.Report(new(metadata.TransferId, metadata.FileName, received, metadata.FileSize, true));
                    }
                    finally { CryptographicOperations.ZeroMemory(plaintext); }
                }
                var complete = await ClassicFileTransferOperation.ReadAsync(network, TimeSpan.FromSeconds(30), cancellationToken).ConfigureAwait(false);
                if (complete.Type != ClassicFileFrameType.Complete) throw new InvalidDataException("The sender did not finish the declared file.");
                if (ClassicFileTransferOperation.Hash(digest.GetHashAndReset()) != metadata.FileHash)
                    throw new InvalidDataException("The received file differs from the authenticated file digest.");
                await output.FlushAsync(cancellationToken).ConfigureAwait(false);
                output.Flush(flushToDisk: true);
            }
            cancellationToken.ThrowIfCancellationRequested();
            savedPath = CommitWithoutOverwrite(partial, root, metadata.FileName);
            await ClassicFileTransferOperation.SendReceiptAsync(network,
                new(metadata.TransferId, true, received, 2, metadata.FileHash), key, cancellationToken).ConfigureAwait(false);
            return new(metadata.TransferId, metadata.FileName, received, metadata.FileHash, savedPath);
        }
        catch (Exception failure)
        {
            // A failed receipt after commit must preserve the user's completed file.
            // Before commit, remove only the private staging file owned by this operation.
            try { if (savedPath is null && partial is not null && File.Exists(partial)) File.Delete(partial); }
            catch (Exception cleanup) { throw new AggregateException("Receive failed and its partial file could not be removed.", failure, cleanup); }
            if (savedPath is not null) throw new IOException("The file was saved, but its receipt could not be delivered: " + savedPath, failure);
            if (!cancellationToken.IsCancellationRequested)
            {
                try
                {
                    await ClassicFileTransferOperation.SendReceiptAsync(network,
                        new(metadata.TransferId, false, received, 2, Error: "The receiver could not validate and save the complete file."),
                        key, cancellationToken).ConfigureAwait(false);
                }
                catch (Exception receiptFailure) { throw new AggregateException("Receive and failure-receipt delivery failed.", failure, receiptFailure); }
            }
            throw;
        }
    }

    internal static void ValidateWindowsFileName(string name)
    {
        if (name.EndsWith('.') || name.EndsWith(' ') || name.IndexOfAny(['<', '>', ':', '"', '|', '?', '*']) >= 0)
            throw new InvalidDataException("The file name cannot be represented safely on Windows.");
        var stem = name.Split('.')[0].TrimEnd(' ').ToUpperInvariant();
        if (stem is "CON" or "PRN" or "AUX" or "NUL" or "CONIN$" or "CONOUT$" ||
            (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) &&
                (stem[3] is >= '0' and <= '9' or '¹' or '²' or '³')))
            throw new InvalidDataException("The file name is reserved by Windows.");
    }

    private static string CommitWithoutOverwrite(string partial, string root, string fileName)
    {
        for (var index = 0; index < 1000; index++)
        {
            var name = index == 0 ? fileName : $"{Path.GetFileNameWithoutExtension(fileName)} ({index}){Path.GetExtension(fileName)}";
            var destination = Path.Combine(root, name);
            try { File.Move(partial, destination, overwrite: false); return destination; }
            catch (IOException) when (File.Exists(destination) || Directory.Exists(destination)) { }
        }
        throw new IOException("The receive folder contains too many files with the same name.");
    }
}
