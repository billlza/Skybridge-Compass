namespace Skybridge.WinClient.Services;

public interface ISessionProtector
{
    byte[] Protect(byte[] bytes);

    byte[] Unprotect(byte[] bytes);
}

internal interface ISessionFileCommitter
{
    void Commit(string temporaryPath, string destinationPath);
}

internal sealed class AtomicSessionFileCommitter : ISessionFileCommitter
{
    public static AtomicSessionFileCommitter Instance { get; } = new();

    private AtomicSessionFileCommitter()
    {
    }

    public void Commit(string temporaryPath, string destinationPath) =>
        // The temporary file is deliberately in the destination directory, so overwrite is a
        // same-volume atomic rename and never requires deleting the prior committed session first.
        File.Move(temporaryPath, destinationPath, overwrite: true);
}
