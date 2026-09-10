using System.IO.Compression;

namespace Skybridge.WinClient.Services.FileTransfer;

/// <summary>Packages an explicitly selected folder as one ordinary transfer, without following links.</summary>
internal static class FileTransferFolderArchive
{
    internal static async Task<string> CreateAsync(string folder, string stagingDirectory, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var root = new DirectoryInfo(Path.GetFullPath(folder));
        if (!root.Exists || (root.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new IOException("The selected folder is missing or redirected.");
        Directory.CreateDirectory(stagingDirectory);
        var destination = Path.Combine(stagingDirectory, root.Name + ".zip");
        var paths = new Stack<DirectoryInfo>(); paths.Push(root);
        long total = 0;
        var count = 0;
        await using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None,
            64 * 1024, FileOptions.Asynchronous);
        using var archive = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true);
        while (paths.Count > 0)
        {
            foreach (var item in paths.Pop().EnumerateFileSystemInfos())
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (++count > 65536) throw new IOException("The selected folder contains more than 65,536 entries.");
                if ((item.Attributes & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("The selected folder contains a link or redirected entry: " + item.Name);
                var relative = Path.GetRelativePath(root.FullName, item.FullName).Replace('\\', '/');
                if (item is DirectoryInfo directory) { archive.CreateEntry(relative + "/"); paths.Push(directory); continue; }
                await using var input = new FileStream(item.FullName, FileMode.Open, FileAccess.Read, FileShare.Read,
                    64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
                var length = input.Length;
                total = checked(total + length);
                if (total > ClassicFileTransferWire.MaximumFileBytes) throw new IOException("The selected folder exceeds the supported 2 GiB limit.");
                var entry = archive.CreateEntry(relative, CompressionLevel.Fastest);
                await using var entryStream = entry.Open();
                await input.CopyToAsync(entryStream, cancellationToken).ConfigureAwait(false);
                if (input.Position != length || input.Length != length) throw new IOException("A selected folder file changed while it was packaged.");
            }
        }
        return destination;
    }
}
