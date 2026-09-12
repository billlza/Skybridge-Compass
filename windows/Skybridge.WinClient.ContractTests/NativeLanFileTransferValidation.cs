using System.Net.Sockets;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text.Json;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.Services.FileTransfer;
using Skybridge.WinClient.Services.RemoteControl;

internal static class NativeLanFileTransferValidation
{
    [SupportedOSPlatform("windows10.0.19041")]
    internal static async Task RunAsync(string configurationPath)
    {
        var options = JsonSerializer.Deserialize<Options>(await File.ReadAllTextAsync(configurationPath))
            ?? throw new InvalidDataException("Missing native transfer validation configuration.");
        var peerMaterial = RemoteControlPairingMaterial.Parse(await File.ReadAllTextAsync(options.PairingPath));
        using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(3));
        var browser = new WindowsDiscoveryBrowserClient(new CoreDiscoveryClient(new CoreBridge()), new NativeWindowsDnsSdBrowseClient());
        var snapshot = await browser.BuildReadOnlySnapshotAsync(new(DiscoveryBrowserAction.Start,
            SkyBridgeProtocolConstants.TcpControlDnsSdService, "", "", false, 5));
        Console.WriteLine(JsonSerializer.Serialize(snapshot.Peers.Select(peer => new {
            peer.Peer.DeviceId, peer.Peer.DisplayName, peer.Peer.PublicKeyFingerprint, peer.Routes })));
        var files = snapshot.Peers.Where(peer => RemoteControlHandshakeBinding.CanonicalDeviceId(peer.Peer.DeviceId) == peerMaterial.DeviceId &&
            peer.Peer.PublicKeyFingerprint == peerMaterial.ProtocolPublicKeyFingerprint && peer.Routes.FileTransfer is not null).ToArray();
        if (files.Length != 1) throw new InvalidOperationException("Native discovery did not resolve exactly one selected file-transfer service.");
        var candidate = DiscoveryPeerRoutes.JoinFileTransferServices(files[0], snapshot.Peers);
        await using var workspace = new WindowsDeviceWorkspace();
        var stored = new SessionStore().Load();
        if (!stored.Succeeded || stored.Session?.DisplayName is not { } displayName || stored.Session.NebulaId is not { } nebulaId)
            throw new InvalidOperationException("Native validation requires the current signed-in account.");
        using var authority = await workspace.PrepareControlAuthenticationAsync(candidate,
            new RemoteControlViewerAccount(displayName, nebulaId), deadline.Token);
        await using var session = await LanProductControlSession.ConnectAsync(authority, null, deadline.Token);
        Console.WriteLine("Authenticated LAN admission completed.");
        var transferId = Guid.NewGuid().ToString("D");
        var key = session.AuthorizeFileTransfer(candidate, transferId);
        try
        {
            await using var prepared = await ClassicFileTransferSender.PrepareAsync(options.SourcePath, transferId,
                LanProductControlMessages.LocalIdentity(authority, null, DateTimeOffset.UtcNow), key, deadline.Token);
            using var client = new TcpClient();
            await client.ConnectAsync(session.RemoteAddress, candidate.Routes.FileTransfer!.Port, deadline.Token);
            var result = await ClassicFileTransferSender.SendAsync(client.GetStream(), prepared, key, null, deadline.Token);
            await File.WriteAllTextAsync(options.ReceiptPath, JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }), deadline.Token);
            Console.WriteLine("PASS native file sender received the peer's authenticated complete-file receipt.");
        }
        finally { CryptographicOperations.ZeroMemory(key); }
    }

    private sealed record Options(string PairingPath, string SourcePath, string ReceiptPath);
}
