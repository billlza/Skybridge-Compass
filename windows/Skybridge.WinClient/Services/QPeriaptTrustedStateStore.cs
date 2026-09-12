using System.Security.Cryptography;
using System.Text;

namespace Skybridge.WinClient.Services;

/// <summary>Policy rollback state is separate from identity migration backups.</summary>
internal sealed class QPeriaptTrustedStateStore(string directory, ISessionProtector protector, ISessionFileCommitter committer)
{
    internal const string FileName = "q-periapt-trusted-state.bin";
    private const int EnvelopeLength = 4 + 32 + 32 + QPeriaptNativeClient.TrustedStateLength;
    private readonly string _directory = Path.GetFullPath(directory);
    private readonly ISessionProtector _protector = protector ?? throw new ArgumentNullException(nameof(protector));
    private readonly ISessionFileCommitter _committer = committer ?? throw new ArgumentNullException(nameof(committer));

    internal byte[]? Load()
    {
        using var lease = AcquireLease();
        return ReadHead();
    }

    internal bool CompareAndSwap(byte[]? expected, byte[] replacement, CancellationToken cancellationToken = default)
    {
        if (expected is not null && expected.Length != QPeriaptNativeClient.TrustedStateLength)
        { throw new ArgumentException("Expected policy head must contain 36 bytes.", nameof(expected)); }
        if (replacement.Length != QPeriaptNativeClient.TrustedStateLength)
        { throw new ArgumentException("Replacement policy head must contain 36 bytes.", nameof(replacement)); }
        cancellationToken.ThrowIfCancellationRequested();
        using var lease = AcquireLease();
        var current = ReadHead();
        if ((current is null) != (expected is null) || (current is not null && !current.AsSpan().SequenceEqual(expected)))
        { return false; }
        if (current is not null && current.AsSpan().SequenceEqual(replacement)) { return true; }
        var plaintext = new byte[EnvelopeLength];
        "QPH1"u8.CopyTo(plaintext);
        Convert.FromHexString(QPeriaptProductionPolicy.RootKeyPinHex).CopyTo(plaintext, 4);
        SHA256.HashData(Encoding.UTF8.GetBytes(QPeriaptProductionPolicy.RootIdentifier)).CopyTo(plaintext, 36);
        replacement.CopyTo(plaintext, 68);
        byte[]? encrypted = null;
        string? temporary = null;
        try
        {
            encrypted = _protector.Protect(plaintext);
            if (encrypted.Length is <= 0 or > 65_536) { throw new InvalidDataException("Protected policy head has an invalid size."); }
            temporary = Path.Combine(_directory, $".q-periapt-trusted-state.{Guid.NewGuid():N}.tmp");
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            { output.Write(encrypted); output.Flush(flushToDisk: true); }
            cancellationToken.ThrowIfCancellationRequested();
            _committer.Commit(temporary, Path.Combine(_directory, FileName));
            temporary = null;
            return true;
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or CryptographicException or OperationCanceledException)
        {
            if (temporary is not null)
            {
                try { File.Delete(temporary); }
                catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException)
                { throw new AggregateException("Policy commit and temporary-file cleanup failed.", failure, cleanup); }
            }
            throw;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
            if (encrypted is not null) { CryptographicOperations.ZeroMemory(encrypted); }
        }
    }

    private FileStream AcquireLease()
    {
        RejectLink(_directory);
        var lockPath = Path.Combine(_directory, ".q-periapt-trusted-state.lock");
        RejectLinkIfPresent(lockPath);
        return new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    }

    private byte[]? ReadHead()
    {
        var path = Path.Combine(_directory, FileName);
        RejectLinkIfPresent(path);
        byte[] encrypted;
        try
        {
            using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (input.Length is <= 0 or > 65_536) { throw new InvalidDataException("Stored policy head has an invalid size."); }
            encrypted = new byte[(int)input.Length]; input.ReadExactly(encrypted);
        }
        catch (FileNotFoundException) { return null; }
        byte[]? plaintext = null;
        try
        {
            plaintext = _protector.Unprotect(encrypted);
            if (plaintext.Length != EnvelopeLength || !plaintext.AsSpan(0, 4).SequenceEqual("QPH1"u8) ||
                !plaintext.AsSpan(4, 32).SequenceEqual(Convert.FromHexString(QPeriaptProductionPolicy.RootKeyPinHex)) ||
                !plaintext.AsSpan(36, 32).SequenceEqual(SHA256.HashData(Encoding.UTF8.GetBytes(QPeriaptProductionPolicy.RootIdentifier))))
            { throw new InvalidDataException("Stored policy head has a different format or production root."); }
            return plaintext.AsSpan(68, QPeriaptNativeClient.TrustedStateLength).ToArray();
        }
        finally
        {
            CryptographicOperations.ZeroMemory(encrypted);
            if (plaintext is not null) { CryptographicOperations.ZeroMemory(plaintext); }
        }
    }

    private static void RejectLinkIfPresent(string path)
    {
        try { RejectLink(path); }
        catch (FileNotFoundException) { return; }
    }

    private static void RejectLink(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        { throw new IOException("Q-Periapt policy storage must not use filesystem links."); }
    }
}
