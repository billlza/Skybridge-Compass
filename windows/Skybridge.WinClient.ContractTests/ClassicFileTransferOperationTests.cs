using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.IO.Compression;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.Services.FileTransfer;

internal static class ClassicFileTransferOperationTests
{
    internal static IReadOnlyList<(string Name, Func<Task> Run)> Cases { get; } =
    [
        ("classic file workers commit exact disk bytes and authenticated receipts including empty files", RoundTrip),
        ("classic receiver rejects a changed whole file and removes its partial output", BadDigest),
        ("classic receiver cancellation retires its partial output without overwriting files", Cancellation),
        ("classic Windows file names reject device paths and alternate streams", FileNames),
        ("classic receiver returns an authenticated rejection before creating an unsafe file", RejectedDestination),
        ("selected folder archive preserves nested entries and cancels before file creation", FolderArchive)
    ];
    private static readonly byte[] Key = Enumerable.Repeat((byte)42, 32).ToArray();
    private static readonly LanProductIdentity Identity = new("id:fixture-device", [new(0x0101, new byte[1184])], 1,
        DeviceName: "Fixture", Platform: "Windows");
    private static void Require(bool value, string reason) { if (!value) throw new InvalidOperationException(reason); }

    private static async Task RoundTrip()
    {
        foreach (var size in new[] { 0, 1024 * 1024 + 17 })
        {
            await using var fixture = await Fixture.Connect();
            var bytes = RandomNumberGenerator.GetBytes(size);
            var source = Path.Combine(fixture.Root, "content.bin");
            await File.WriteAllBytesAsync(source, bytes, fixture.Token);
            var existing = Path.Combine(fixture.Destination, "content.bin");
            await File.WriteAllTextAsync(existing, "keep existing", fixture.Token);
            await using var prepared = await ClassicFileTransferSender.PrepareAsync(source, "roundtrip", Identity, Key, fixture.Token);
            var sending = ClassicFileTransferSender.SendAsync(fixture.Send, prepared, Key, null, fixture.Token);
            var metadata = await fixture.Metadata();
            var received = await ClassicFileTransferReceiver.ReceiveAsync(fixture.Receive, metadata, Key, fixture.Destination, null, fixture.Token);
            var sent = await sending;
            Require(received.SavedPath == Path.Combine(fixture.Destination, "content (1).bin") && sent.Bytes == size && received.Bytes == size,
                "Transfer completion did not preserve collision naming or full byte count.");
            Require((await File.ReadAllBytesAsync(received.SavedPath!, fixture.Token)).SequenceEqual(bytes) &&
                sent.FileHash == Convert.ToHexStringLower(SHA256.HashData(bytes)) &&
                await File.ReadAllTextAsync(existing, fixture.Token) == "keep existing",
                "Committed content, receipt digest or existing file changed.");
            Require(Directory.GetFiles(fixture.Destination, "*.part").Length == 0, "A committed transfer leaked its partial file.");
        }
    }

    private static async Task BadDigest()
    {
        await using var fixture = await Fixture.Connect();
        var metadata = ClassicFileTransferWire.Authenticate(new ClassicFileMetadata("bad-digest", "bad.bin", 3,
            new string('a', 64), 65536, 2), Key);
        await ClassicFileTransferFrames.WriteAsync(fixture.Send, ClassicFileFrameType.Chunk,
            ClassicFileTransferWire.Encode(ClassicFileTransferWire.SealChunk(0, new byte[] { 1, 2, 3 }, Key)), fixture.Token);
        await ClassicFileTransferFrames.WriteAsync(fixture.Send, ClassicFileFrameType.Complete, ReadOnlyMemory<byte>.Empty, fixture.Token);
        try
        {
            await ClassicFileTransferReceiver.ReceiveAsync(fixture.Receive, metadata, Key, fixture.Destination, null, fixture.Token);
            throw new Exception("A changed file was committed.");
        }
        catch (InvalidDataException) { }
        var frame = await ClassicFileTransferFrames.ReadAsync(fixture.Send, fixture.Token);
        var receipt = ClassicFileTransferWire.Decode<ClassicFileReceipt>(frame.Payload);
        ClassicFileTransferWire.Verify(receipt, metadata, Key);
        Require(!receipt.Success && receipt.ReceivedBytes == 3 && Directory.GetFileSystemEntries(fixture.Destination).Length == 0,
            "Digest failure became success or retained unverified data.");
    }

    private static async Task Cancellation()
    {
        await using var fixture = await Fixture.Connect();
        var metadata = ClassicFileTransferWire.Authenticate(new ClassicFileMetadata("cancelled", "cancel.bin", 1,
            new string('b', 64), 65536, 2), Key);
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(fixture.Token);
        var receiving = ClassicFileTransferReceiver.ReceiveAsync(fixture.Receive, metadata, Key, fixture.Destination, null, cancellation.Token);
        cancellation.Cancel();
        try { await receiving; throw new Exception("Cancelled transfer succeeded."); }
        catch (OperationCanceledException) { }
        Require(Directory.GetFileSystemEntries(fixture.Destination).Length == 0, "Cancelled receive leaked a partial file.");
    }

    private static Task FileNames()
    {
        foreach (var name in new[] { "CON", "con.txt", "CON .txt", "LPT1.zip", "COM¹", "NUL", "a:b", "a?b", "file.", "file " })
        {
            try { ClassicFileTransferReceiver.ValidateWindowsFileName(name); throw new Exception("Unsafe Windows name was accepted: " + name); }
            catch (InvalidDataException) { }
        }
        ClassicFileTransferReceiver.ValidateWindowsFileName("合同 2026.zip");
        return Task.CompletedTask;
    }

    private static async Task RejectedDestination()
    {
        await using var fixture = await Fixture.Connect();
        var metadata = ClassicFileTransferWire.Authenticate(new ClassicFileMetadata("rejected-name", "NUL.txt", 0,
            Convert.ToHexStringLower(SHA256.HashData([])), 65536, 2), Key);
        try
        {
            await ClassicFileTransferReceiver.ReceiveAsync(fixture.Receive, metadata, Key, fixture.Destination, null, fixture.Token);
            throw new Exception("The receiver accepted a Windows device name.");
        }
        catch (InvalidDataException) { }
        var frame = await ClassicFileTransferFrames.ReadAsync(fixture.Send, fixture.Token);
        var receipt = ClassicFileTransferWire.Decode<ClassicFileReceipt>(frame.Payload);
        ClassicFileTransferWire.Verify(receipt, metadata, Key);
        Require(!receipt.Success && receipt.ReceivedBytes == 0 && Directory.GetFileSystemEntries(fixture.Destination).Length == 0,
            "Destination rejection lost its authenticated negative receipt or created a file.");
    }

    private static async Task FolderArchive()
    {
        await using var fixture = await Fixture.Connect();
        var selected = Path.Combine(fixture.Root, "selected-folder");
        Directory.CreateDirectory(Path.Combine(selected, "empty"));
        Directory.CreateDirectory(Path.Combine(selected, "nested"));
        await File.WriteAllTextAsync(Path.Combine(selected, "nested", "合同.txt"), "folder contents", fixture.Token);
        var archivePath = await FileTransferFolderArchive.CreateAsync(selected, Path.Combine(fixture.Root, "staging"), fixture.Token);
        using (var archive = ZipFile.OpenRead(archivePath))
        {
            Require(archive.GetEntry("empty/") is not null, "Empty folder was lost in the archive.");
            var entry = archive.GetEntry("nested/合同.txt") ?? throw new Exception("Nested Unicode file name changed.");
            using var reader = new StreamReader(entry.Open());
            Require(await reader.ReadToEndAsync(fixture.Token) == "folder contents", "Folder archive changed file contents.");
        }
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        var cancelled = Path.Combine(fixture.Root, "cancelled-staging");
        try { await FileTransferFolderArchive.CreateAsync(selected, cancelled, cancellation.Token); throw new Exception("Cancelled packaging succeeded."); }
        catch (OperationCanceledException) { }
        Require(!Directory.Exists(cancelled), "Cancelled packaging created staging output.");
    }

    private sealed class Fixture : IAsyncDisposable
    {
        internal string Root { get; } = Path.Combine(AppContext.BaseDirectory, "file-transfer-test-" + Guid.NewGuid().ToString("N"));
        internal string Destination => Path.Combine(Root, "received");
        private readonly CancellationTokenSource _deadline = new(TimeSpan.FromSeconds(20));
        private readonly TcpClient _sender, _receiver;
        internal NetworkStream Send => _sender.GetStream();
        internal NetworkStream Receive => _receiver.GetStream();
        internal CancellationToken Token => _deadline.Token;
        private Fixture(TcpClient sender, TcpClient receiver)
        { _sender = sender; _receiver = receiver; Directory.CreateDirectory(Destination); }
        internal static async Task<Fixture> Connect()
        {
            using var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
            var sender = new TcpClient(); await sender.ConnectAsync((IPEndPoint)listener.LocalEndpoint);
            return new(sender, await listener.AcceptTcpClientAsync());
        }
        internal async Task<ClassicFileMetadata> Metadata()
        {
            var frame = await ClassicFileTransferFrames.ReadAsync(Receive, Token);
            Require(frame.Type == ClassicFileFrameType.Metadata, "Transfer did not start with metadata.");
            return ClassicFileTransferWire.Decode<ClassicFileMetadata>(frame.Payload);
        }
        public ValueTask DisposeAsync()
        { _sender.Dispose(); _receiver.Dispose(); _deadline.Dispose(); Directory.Delete(Root, true); return ValueTask.CompletedTask; }
    }
}
