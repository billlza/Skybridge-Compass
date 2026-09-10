using System;
using System.IO;
using System.Runtime.ExceptionServices;
using System.Text;
using System.Threading;

namespace Skybridge.WinClient.Services;

internal static class WebRtcArtifactFileWriter
{
    private static readonly UTF8Encoding Utf8NoBom = new(false);

    public static void WriteUtf8TextAtomically(string path, string contents)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new ArgumentException("Artifact output path must not be empty.", nameof(path));
        }

        var fullPath = Path.GetFullPath(path);
        var parent = Path.GetDirectoryName(fullPath);
        if (!string.IsNullOrWhiteSpace(parent))
        {
            AssertNoWindowsReparsePointAncestors(parent, "Artifact output directory");
            Directory.CreateDirectory(parent);
            AssertNoWindowsReparsePointAncestors(parent, "Artifact output directory");
        }

        AssertNoWindowsReparsePoint(fullPath, "Artifact output file");

        var tempPath = fullPath + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            using (var stream = new FileStream(tempPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                using (var writer = new StreamWriter(stream, Utf8NoBom, bufferSize: 4096, leaveOpen: true))
                {
                    writer.Write(contents);
                }

                stream.Flush(flushToDisk: true);
            }

            MoveReplacingWithRetry(tempPath, fullPath);
        }
        catch (Exception writeError)
        {
            DeleteTempAfterFailure(tempPath, writeError);
            ExceptionDispatchInfo.Capture(writeError).Throw();
            throw;
        }
    }

    private static void MoveReplacingWithRetry(string sourcePath, string destinationPath)
    {
        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(2);
        while (true)
        {
            AssertNoWindowsReparsePoint(destinationPath, "Artifact output file");
            try
            {
                File.Move(sourcePath, destinationPath, overwrite: true);
                return;
            }
            catch (IOException) when (DateTimeOffset.UtcNow < deadline)
            {
                Thread.Sleep(TimeSpan.FromMilliseconds(50));
            }
        }
    }

    private static void AssertNoWindowsReparsePointAncestors(string path, string label)
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var current = Path.GetFullPath(path);
        while (!string.IsNullOrWhiteSpace(current))
        {
            if (Directory.Exists(current) || File.Exists(current))
            {
                AssertNoWindowsReparsePoint(current, label);
            }

            var parent = Path.GetDirectoryName(current);
            if (string.IsNullOrWhiteSpace(parent) || string.Equals(parent, current, StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            current = parent;
        }
    }

    private static void AssertNoWindowsReparsePoint(string path, string label)
    {
        if (!OperatingSystem.IsWindows() || (!Directory.Exists(path) && !File.Exists(path)))
        {
            return;
        }

        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidOperationException($"{label} must not be a reparse point: {path}");
        }
    }

    private static void DeleteTempAfterFailure(string tempPath, Exception writeError)
    {
        try
        {
            if (File.Exists(tempPath))
            {
                File.Delete(tempPath);
            }
        }
        catch (Exception cleanupError) when (cleanupError is IOException or UnauthorizedAccessException)
        {
            throw new IOException(
                $"Artifact write failed and temporary artifact cleanup also failed: {tempPath}",
                new AggregateException(writeError, cleanupError));
        }
    }
}
