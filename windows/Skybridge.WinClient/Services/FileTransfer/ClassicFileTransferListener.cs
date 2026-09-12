using System.Net;
using System.Net.Sockets;
using System.Runtime.Versioning;
using System.Security.Cryptography;

namespace Skybridge.WinClient.Services.FileTransfer;

/// <summary>Bounded receiver for peers admitted by the application's existing device-session owner.</summary>
[SupportedOSPlatform("windows10.0.19041")]
internal sealed class ClassicFileTransferListener : IAsyncDisposable
{
    private readonly WindowsDeviceWorkspace _workspace;
    private readonly string _destination;
    private readonly Func<ClassicFileMetadata, string, CancellationToken, Task<bool>> _approve;
    private readonly IProgress<ClassicFileTransferProgress> _progress;
    private readonly Action<ClassicFileMetadata?, ClassicFileTransferResult?, Exception?> _completed;
    private readonly TcpListener _listener = new(IPAddress.IPv6Any, 0);
    private readonly CancellationTokenSource _lifetime;
    private readonly Task _run;

    internal ClassicFileTransferListener(WindowsDeviceWorkspace workspace, string destination,
        Func<ClassicFileMetadata, string, CancellationToken, Task<bool>> approve, IProgress<ClassicFileTransferProgress> progress,
        Action<ClassicFileMetadata?, ClassicFileTransferResult?, Exception?> completed, CancellationToken cancellationToken)
    {
        _workspace = workspace; _destination = destination; _approve = approve; _progress = progress; _completed = completed;
        _lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        try
        {
            _listener.Server.DualMode = true;
            _listener.Start(4);
            Port = checked((ushort)((IPEndPoint)_listener.LocalEndpoint).Port);
            _run = RunAsync();
        }
        catch { _listener.Stop(); _lifetime.Dispose(); throw; }
    }

    internal ushort Port { get; }
    internal Task Completion => _run;

    private async Task RunAsync()
    {
        var workers = new List<Task>(2);
        try
        {
            while (true)
            {
                if (workers.Count == 2)
                {
                    var finished = await Task.WhenAny(workers).ConfigureAwait(false);
                    await finished.ConfigureAwait(false);
                    workers.Remove(finished);
                }
                var client = await _listener.AcceptTcpClientAsync(_lifetime.Token).ConfigureAwait(false);
                workers.Add(ReceiveOneAsync(client));
            }
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
        finally
        {
            _lifetime.Cancel();
            _listener.Stop();
            await Task.WhenAll(workers).ConfigureAwait(false);
        }
    }

    private async Task ReceiveOneAsync(TcpClient client)
    {
        using (client)
        {
            ClassicFileMetadata? metadata = null;
            try
            {
                var stream = client.GetStream();
                var first = await ClassicFileTransferOperation.ReadAsync(stream, TimeSpan.FromSeconds(5), _lifetime.Token).ConfigureAwait(false);
                if (first.Type != ClassicFileFrameType.Metadata) throw new InvalidDataException("A new file connection must start with metadata.");
                metadata = ClassicFileTransferWire.Decode<ClassicFileMetadata>(first.Payload);
                ClassicFileTransferWire.ValidateMetadata(metadata);
                var address = (client.Client.RemoteEndPoint as IPEndPoint)?.Address
                    ?? throw new IOException("The incoming file connection has no IP endpoint.");
                var session = _workspace.RequireIncomingControlSession(metadata.SenderDeviceId
                    ?? throw new InvalidDataException("The incoming file has no authenticated sender identity."));
                var key = session.AuthorizeIncomingTransfer(metadata, address);
                using var operation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token, session.Lifetime);
                try
                {
                    using var approval = CancellationTokenSource.CreateLinkedTokenSource(operation.Token);
                    approval.CancelAfter(TimeSpan.FromSeconds(45));
                    var accepted = await _approve(metadata, _destination, approval.Token).ConfigureAwait(false);
                    if (!accepted)
                    {
                        await ClassicFileTransferOperation.SendReceiptAsync(stream,
                            new(metadata.TransferId, false, 0, 2, Error: "The receiver declined this file."), key, operation.Token).ConfigureAwait(false);
                        throw new ClassicFileTransferRejectedException("The incoming file was declined.");
                    }
                    using var power = WindowsPowerKeepAwake.Arm();
                    var result = await ClassicFileTransferReceiver.ReceiveAsync(stream, metadata, key,
                        _destination, _progress, operation.Token).ConfigureAwait(false);
                    _completed(metadata, result, null);
                }
                finally { CryptographicOperations.ZeroMemory(key); }
            }
            catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
            catch (Exception failure) { _completed(metadata, null, failure); }
        }
    }

    public async ValueTask DisposeAsync()
    {
        _lifetime.Cancel();
        try { await _run.ConfigureAwait(false); }
        finally { _listener.Stop(); _lifetime.Dispose(); }
    }
}
