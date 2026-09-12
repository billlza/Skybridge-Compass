using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text.Json;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.Services.FileTransfer;

internal static class LanProductControlSessionTests
{
    internal static IReadOnlyList<(string Name, Func<Task> Run)> Cases { get; } =
    [
        ("LAN AppMessage retains Apple dates and rejects ambiguous or mismatched identities", MessageContract),
        ("LAN encrypted admission gates exact file routes and retires with its connection", Admission),
        ("LAN encrypted admission rejects a different peer protocol identity", WrongIdentity)
    ];
    private const string PeerId = "id:11111111-2222-3333-4444-555555555555";
    private static readonly byte[] PublicKey = Enumerable.Repeat((byte)23, 1952).ToArray();
    private static readonly string Fingerprint = new WebRtcProductProtocolIdentityPublicKey(
        WebRtcProductSignatureAlgorithm.MlDsa65, PublicKey).AuthoritativeFingerprint;
    private static readonly ProductHandshakePeerContext Peer = new(PeerId, Fingerprint);
    private static LanProductIdentity Identity() => new(PeerId, [new(0x0101, new byte[1184])], 100,
        [new("ML-DSA-65", PublicKey)], Capabilities: ["file_transfer"], FileTransferPort: 8080);
    private static void Require(bool value, string reason) { if (!value) throw new InvalidOperationException(reason); }
    private static void Throws<T>(Action action) where T : Exception
    {
        try { action(); } catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private static Task MessageContract()
    {
        Require(LanProductControlMessages.Timestamp(new DateTimeOffset(2001, 1, 1, 0, 0, 0, TimeSpan.Zero)) == 0,
            "AppMessage dates must use the Swift reference date.");
        var encoded = LanProductControlMessages.Encode(LanControlMessageKind.Identity, Identity());
        LanProductControlMessages.ValidateIdentity(LanProductControlMessages.Payload<LanProductIdentity>(
            LanProductControlMessages.Decode(encoded)), Peer);
        Throws<InvalidDataException>(() => LanProductControlMessages.Decode("{\"ping\":{\"id\":1},\"pong\":{\"id\":1}}"u8));
        Throws<JsonException>(() => LanProductControlMessages.Payload<LanProductPing>(
            LanProductControlMessages.Decode("{\"ping\":{\"id\":1,\"id\":2}}"u8)));
        Throws<InvalidDataException>(() => LanProductControlMessages.ValidateIdentity(Identity() with { DeviceId = "id:different-device" }, Peer));
        Throws<InvalidDataException>(() => LanProductControlMessages.ValidateIdentity(Identity() with { KemPublicKeys = [null!] }, Peer));
        foreach (var malformed in new[] { "SBP2"u8.ToArray(), new byte[] { 83, 66, 80, 50, 0, 0, 0, 1 } })
            Throws<InvalidDataException>(() => ProductControlTrafficPadding.Unwrap(malformed));
        Require(ProductControlTrafficPadding.Unwrap(ProductControlTrafficPadding.Wrap(encoded)).SequenceEqual(encoded),
            "SBP2 changed the authenticated payload.");
        return Task.CompletedTask;
    }

    private static async Task Admission()
    {
        await using var fixture = await Fixture.Connect();
        Require(!fixture.Session.IsReady, "TCP and keys alone must not admit file transfer.");
        Throws<InvalidOperationException>(() => fixture.Session.AuthorizeFileTransfer(fixture.Candidate, "transfer"));
        var admission = fixture.Session.CompleteAdmissionAsync(fixture.Token);
        Require((await fixture.Read()).Kind == LanControlMessageKind.Identity, "Local identity did not precede the admission ping.");
        var ping = LanProductControlMessages.Payload<LanProductPing>(await fixture.Read());
        await fixture.Send(LanControlMessageKind.Identity, Identity());
        Require(!fixture.Session.IsReady, "Identity alone admitted a transfer before peer approval committed.");
        await fixture.Send(LanControlMessageKind.Pong, ping);
        await admission;
        var key = fixture.Session.AuthorizeFileTransfer(fixture.Candidate, "transfer");
        Require(key.SequenceEqual(ClassicFileTransferWire.DeriveTransferKey(fixture.Keys, "transfer")), "The file used different session keys.");
        var metadata = ClassicFileTransferWire.Authenticate(new ClassicFileMetadata("transfer", "f", 0,
            Convert.ToHexStringLower(SHA256.HashData([])), 65536, 2, SenderDeviceId: PeerId), key);
        Require(fixture.Session.AuthorizeIncomingTransfer(metadata, IPAddress.Loopback).SequenceEqual(key),
            "The same authenticated peer could not use the reverse transfer direction.");
        Throws<InvalidDataException>(() => fixture.Session.AuthorizeIncomingTransfer(metadata, IPAddress.Parse("127.0.0.2")));
        Throws<CryptographicException>(() => fixture.Session.AuthorizeIncomingTransfer(metadata with { FileName = "tampered" }, IPAddress.Loopback));
        Throws<InvalidDataException>(() => fixture.Session.AuthorizeFileTransfer(fixture.Candidate with {
            Routes = fixture.Candidate.Routes with { FileTransfer = fixture.Candidate.Routes.FileTransfer! with { Port = 8081 } }
        }, "transfer"));
        try { await fixture.Session.CompleteAdmissionAsync(fixture.Token); throw new Exception("Admission ran twice."); }
        catch (InvalidOperationException) { }
        fixture.Remote.Close();
        Require(await fixture.Session.Completion.WaitAsync(fixture.Token) is not null && !fixture.Session.IsReady,
            "A disconnected control session retained file authority or hid its failure.");
        Throws<InvalidOperationException>(() => fixture.Session.AuthorizeFileTransfer(fixture.Candidate, "transfer"));
    }

    private static async Task WrongIdentity()
    {
        await using var fixture = await Fixture.Connect();
        var admission = fixture.Session.CompleteAdmissionAsync(fixture.Token);
        _ = await fixture.Read(); _ = await fixture.Read();
        await fixture.Send(LanControlMessageKind.Identity, Identity() with { DeviceId = "id:unrelated-device" });
        try { await admission; throw new Exception("A different identity was admitted."); }
        catch (IOException error) { Require(error.InnerException is InvalidDataException, "Identity rejection lost its cause."); }
        Require(!fixture.Session.IsReady, "Failed admission retained transfer authority.");
    }

    private sealed class Fixture : IAsyncDisposable
    {
        private readonly CancellationTokenSource _deadline = new(TimeSpan.FromSeconds(10));
        private readonly WebRtcAppSecureSessionKeys _remoteKeys;
        internal ProductSessionKeys Keys { get; } = new(ProductHandshakeRole.Initiator, "fixture", new byte[32],
            Enumerable.Repeat((byte)1, 32).ToArray(), Enumerable.Repeat((byte)2, 32).ToArray());
        internal TcpProductControlTransport Remote { get; }
        internal LanProductControlSession Session { get; }
        internal CancellationToken Token => _deadline.Token;
        internal DiscoveryBrowserPeerCandidate Candidate { get; }
        private Fixture(TcpClient local, TcpClient remote)
        {
            Remote = new(remote, 1024 * 1024, 1024 * 1024);
            var control = new DiscoveryPeerEndpoint(SkyBridgeProtocolConstants.TcpControlDnsSdService,
                "fixture.local", 9000, "fixture._skybridge._tcp.local", "resolved-dns-sd-endpoint");
            Candidate = new(new(CoreDiscoveryServiceKind.FileTransfer, PeerId, "Fixture", CorePeerPlatform.Apple,
                "macOS", Fingerprint, "file_transfer", "1", PeerCapabilities.Apple()), "", "") {
                Routes = new(control, new(SkyBridgeProtocolConstants.FileTransferDnsSdService, "fixture.local", 8080,
                    "fixture._skybridge-xfer._tcp.local", "resolved-dns-sd-endpoint"), null)
            };
            Session = new(new(local, 1024 * 1024, 1024 * 1024), Keys, Peer, Identity(), control, IPAddress.Loopback, Token);
            using var reversed = new ProductSessionKeys(ProductHandshakeRole.Responder, Keys.SessionId, Keys.TranscriptHash, Keys.ReceiveKey, Keys.SendKey);
            _remoteKeys = WebRtcProductHandshakeSessionKeys.ToWebRtcKeys(reversed);
        }
        internal static async Task<Fixture> Connect()
        {
            using var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            var local = new TcpClient();
            await local.ConnectAsync((IPEndPoint)listener.LocalEndpoint);
            var remote = await listener.AcceptTcpClientAsync();
            return new(local, remote);
        }
        internal async Task<LanControlMessage> Read() => LanProductControlMessages.Decode(
            WebRtcControlChannelCodec.DecryptAppleLegacyAppPayload(ProductControlTrafficPadding.Unwrap((await Remote.ReadAsync(Token)).ToArray()), _remoteKeys));
        internal Task Send<T>(LanControlMessageKind kind, T payload) => Remote.SendAsync(ProductControlTrafficPadding.Wrap(
            WebRtcControlChannelCodec.EncryptAppleLegacyAppPayload(LanProductControlMessages.Encode(kind, payload), _remoteKeys)), Token);
        public async ValueTask DisposeAsync()
        {
            await Session.DisposeAsync(); await Remote.DisposeAsync();
            _remoteKeys.Dispose(); Keys.Dispose(); _deadline.Dispose();
        }
    }
}
