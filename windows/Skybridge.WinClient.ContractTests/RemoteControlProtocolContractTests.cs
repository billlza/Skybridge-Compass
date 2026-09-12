using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ContractTests;

public static class RemoteControlProtocolContractTests
{
    public static async Task<int> RunAsync(string macFixturePath, bool requireNativePqc = false)
    {
        var checks = new Checks();
        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(macFixturePath).ConfigureAwait(false));
        var vector = document.RootElement;
        byte[] Bytes(string name) => Convert.FromHexString(vector.GetProperty(name).GetString()!);
        using var initiator = ProductHandshakeKeyDerivation.Derive(Bytes("sharedSecret"), 0x0101,
            Bytes("transcriptA"), Bytes("transcriptB"), Bytes("clientNonce"), Bytes("serverNonce"), ProductHandshakeRole.Initiator);
        using var responder = ProductHandshakeKeyDerivation.Derive(Bytes("sharedSecret"), 0x0101,
            Bytes("transcriptA"), Bytes("transcriptB"), Bytes("clientNonce"), Bytes("serverNonce"), ProductHandshakeRole.Responder);
        checks.That(initiator.SessionId == vector.GetProperty("sessionId").GetString(), "Swift deterministic session ID");
        checks.Equal(initiator.TranscriptHash.Span, Bytes("transcriptHash"), "Swift transcript hash");
        checks.Equal(initiator.SendKey.Span, Bytes("initiatorSendKey"), "Swift initiator key");
        checks.Equal(responder.SendKey.Span, Bytes("responderSendKey"), "Swift responder key");
        checks.Equal(ProductHandshakeKeyDerivation.CreateFinished(initiator).Encode(), Bytes("initiatorFinished"), "Swift initiator FIN1");
        checks.Equal(ProductHandshakeKeyDerivation.CreateFinished(responder).Encode(), Bytes("responderFinished"), "Swift responder FIN1");
        var finished = WebRtcProductHandshakeCodec.DecodeFinished(Bytes("responderFinished"));
        checks.That(ProductHandshakeKeyDerivation.VerifyFinished(finished, initiator, ProductHandshakeRole.Responder), "Finished verifies from peer");
        checks.That(!ProductHandshakeKeyDerivation.VerifyFinished(finished, initiator, ProductHandshakeRole.Initiator), "Finished role mismatch rejected");

        var control = new[] { RemoteControlSecurePacketType.Control };
        var plaintext = Bytes("plaintext");
        var swiftEnvelope = Bytes("sbrc");
        using var secure = new RemoteControlSecureSession(initiator);
        var opened = secure.Open(swiftEnvelope, control);
        checks.Equal(opened.Payload, plaintext, "Swift SBRC ciphertext opens");
        checks.That(opened.Counter == 17 && opened.Direction == 2, "Swift SBRC scope metadata");
        checks.Throws<ProductSecureEnvelopeException>(() => secure.Open(swiftEnvelope, control), "duplicate ciphertext rejected");
        var badTag = swiftEnvelope.ToArray(); badTag[^1] ^= 1;
        checks.Throws<ProductSecureEnvelopeException>(() => RemoteControlSecureEnvelope.Open(badTag, initiator, control), "SBRC tag failure");
        foreach (var offset in new[] { 0, 4, 5, 6, 7, 8, 16, 24, 28, 36, 40 })
        {
            var changed = swiftEnvelope.ToArray(); changed[offset] ^= 0x40;
            checks.Throws<ProductSecureEnvelopeException>(() => RemoteControlSecureEnvelope.Open(changed, initiator, control), $"SBRC authenticated header offset {offset}");
        }
        checks.Throws<ProductSecureEnvelopeException>(() => RemoteControlSecureEnvelope.Open(swiftEnvelope, responder, control), "reflected SBRC rejected");
        checks.Throws<ProductSecureEnvelopeException>(() => RemoteControlSecureEnvelope.Open(swiftEnvelope, initiator,
            new[] { RemoteControlSecurePacketType.Screen }), "packet permission boundary");
        using var differentSession = new ProductSessionKeys(initiator.Role, "hs-other", initiator.TranscriptHash, initiator.SendKey, initiator.ReceiveKey);
        checks.Throws<ProductSecureEnvelopeException>(() => RemoteControlSecureEnvelope.Open(swiftEnvelope, differentSession, control), "cross-session ciphertext rejected");
        using var otherTranscript = new ProductSessionKeys(initiator.Role, initiator.SessionId, new byte[32], initiator.SendKey, initiator.ReceiveKey);
        checks.Throws<ProductSecureEnvelopeException>(() => RemoteControlSecureEnvelope.Open(swiftEnvelope, otherTranscript, control), "cross-transcript ciphertext rejected");
        var high = RemoteControlSecureEnvelope.Seal(plaintext, responder, RemoteControlSecurePacketType.Control, 2048);
        secure.Open(high, control);
        checks.Throws<ProductSecureEnvelopeException>(() => secure.Open(swiftEnvelope, control), "replay outside window rejected");
        var adjacent = RemoteControlSecureEnvelope.Seal(plaintext, responder, RemoteControlSecurePacketType.Control, 2047);
        checks.Equal(secure.Open(adjacent, control).Payload, plaintext, "out-of-order in replay window accepted");
        using var sender = new RemoteControlSecureSession(responder);
        var first = sender.Seal(plaintext, RemoteControlSecurePacketType.Control);
        var second = sender.Seal(plaintext, RemoteControlSecurePacketType.Control);
        checks.That(RemoteControlSecureEnvelope.Open(first, initiator, control).Counter == 1 &&
            RemoteControlSecureEnvelope.Open(second, initiator, control).Counter == 2, "session counters increase");

        using var mediaSend = RealtimeMediaPacketCodec.DeriveSendKeys(responder);
        using var mediaReceive = RealtimeMediaPacketCodec.DeriveReceiveKeys(initiator);
        checks.Equal(mediaSend.Key.Span, Bytes("mediaSendKey"), "Swift media HKDF key");
        checks.Equal(mediaSend.NonceSalt.Span, Bytes("mediaNonceSalt"), "Swift media nonce salt");
        checks.Equal(RealtimeMediaPacketCodec.Seal(plaintext, mediaSend, 0, 960, 17), Bytes("sbma"), "Swift SBMA exact ciphertext vector");
        checks.Equal(RealtimeMediaPacketCodec.Open(Bytes("sbma"), mediaReceive).Payload, plaintext, "Swift SBMA decrypts");
        foreach (var offset in new[] { 0, 4, 5, 6, 8, 9, 17, 25, 29, 37, 45, 49, 57, 61 })
        {
            var changed = Bytes("sbma"); changed[offset] ^= 0x40;
            checks.Throws<ProductSecureEnvelopeException>(() => RealtimeMediaPacketCodec.Open(changed, mediaReceive), $"SBMA authenticated header offset {offset}");
        }
        checks.Throws<ProductSecureEnvelopeException>(() => RealtimeMediaPacketCodec.Seal(new byte[1101], mediaSend, 0, 0, 1), "SBMA size bound");
        using var persistentMedia = new RealtimeMediaPacketSender(responder);
        var beforePause = RealtimeMediaPacketCodec.Open(persistentMedia.SealNext(plaintext, 0, 1), mediaReceive);
        var afterPause = RealtimeMediaPacketCodec.Open(persistentMedia.SealNext(plaintext, 0, 2), mediaReceive);
        checks.That(beforePause.Sequence == 0 && afterPause.Sequence == 1 && afterPause.NonceCounter > beforePause.NonceCounter,
            "audio capture restart preserves session sequence and nonce");
        var keyView = mediaSend.Key; var saltView = mediaSend.NonceSalt;
        mediaSend.Dispose();
        checks.That(IsZero(keyView.Span) && IsZero(saltView.Span), "media keys zeroized");
        checks.Throws<ObjectDisposedException>(() => _ = mediaSend.Key, "disposed media keys cannot be reused");
        using var disposableKeys = initiator.Clone();
        var sessionView = disposableKeys.SendKey;
        disposableKeys.Dispose();
        checks.That(IsZero(sessionView.Span), "session key memory zeroized");
        checks.Throws<ObjectDisposedException>(() => disposableKeys.Clone(), "disposed session keys cannot be cloned");
        using var ownedSecret = new ProductHandshakeSharedSecret(Bytes("sharedSecret"));
        var secretView = ownedSecret.Bytes;
        ownedSecret.Dispose();
        checks.That(IsZero(secretView.Span), "consumed provider secret zeroized");
        VerifySoa(checks);
        var composed = ProductForwardSecretContribution.Compose(
            Enumerable.Range(0, 32).Select(value => (byte)value).ToArray(),
            Enumerable.Range(32, 32).Select(value => (byte)value).ToArray(),
            Enumerable.Repeat((byte)0xa3, 32).ToArray(), 0x0102);
        checks.Equal(composed, Convert.FromHexString("bca61c96c84d5c8db3180d65bb09427b26504f0f843635e0926724166239f06a"),
            "v2 static and ephemeral HKDF matches independent protocol vector");

        if (!MLDsa.IsSupported || !MLKem.IsSupported)
        {
            if (requireNativePqc) { throw new PlatformNotSupportedException("Native ML-DSA/ML-KEM is required for this verification run."); }
            var options = new WebRtcProductPqcHandshakeCryptoProviderOptions(new byte[32], new byte[1184]);
            checks.Throws<PlatformNotSupportedException>(() => new WebRtcProductPqcHandshakeCryptoProvider(options), "unsupported native provider fails closed");
            checks.That(IsZero(options.LocalMlDsa65PrivateKey.Span), "unsupported provider clears consumed options");
        }
        else { await VerifyNativeHandshakeAsync(checks).ConfigureAwait(false); }
        return checks.Count;
    }

    private static void VerifySoa(Checks checks)
    {
        const string local = "id:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
        const string remote = "id:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
        var soa = new RemoteControlHandshakeSoa(RemoteControlHandshakeBinding.PeerId(remote), RemoteControlHandshakeBinding.PeerId(local), new byte[16]);
        var identity = new WebRtcProductProtocolIdentityPublicKey(WebRtcProductSignatureAlgorithm.Ed25519, Enumerable.Range(0, 32).Select(value => (byte)value).ToArray());
        var message = new WebRtcProductHandshakeMessageA(new ushort[] { 0x1001 },
            new[] { new WebRtcProductHandshakeKeyShare(0x1001, new byte[32]) }, new byte[32],
            new WebRtcProductCryptoCapabilities(new[] { "X25519" }, new[] { "Ed25519" }, new[] { "classic" }, new[] { "AES-256-GCM" }, false, "test", "CryptoKit-Classic"),
            WebRtcProductHandshakePolicy.Default, identity.Encode(), soa.EncodeTlv(), new byte[64]);
        var peers = new[] { new RemoteControlTrustedPeer(remote, identity.AuthoritativeFingerprint) };
        checks.That(message.SecureEnclaveSignature is null, "absent Secure Enclave proof is not encoded as an empty proof");
        var candidate = RemoteControlHandshakeBinding.ValidateAndResolveMessageA(message.Encode(), local, peers);
        checks.That(candidate.Peer.PeerDeviceId == remote, "SOA resolves stable authority");
        checks.Equal(RemoteControlHandshakeBinding.PeerId(local.ToUpperInvariant()), RemoteControlHandshakeBinding.PeerId(local[3..]), "SOA ID normalization");
        checks.Throws<InvalidDataException>(() => RemoteControlHandshakeBinding.ValidateAndResolveMessageA(message.Encode(), remote, peers), "SOA wrong target rejected");
        checks.Throws<InvalidDataException>(() => RemoteControlHandshakeBinding.ValidateAndResolveMessageA(message.Encode(), local, Array.Empty<RemoteControlTrustedPeer>()), "SOA unknown peer rejected");
        checks.Throws<InvalidDataException>(() => RemoteControlHandshakeBinding.ValidateAndResolveMessageA(message.Encode(), local,
            new[] { peers[0], new RemoteControlTrustedPeer(remote, new string('a', 64)) }), "SOA conflicting pins rejected");
        checks.Throws<InvalidDataException>(() => RemoteControlHandshakeSoa.RequireFromExtensions(Array.Empty<byte>()), "SOA missing rejected");
        checks.Throws<InvalidDataException>(() => RemoteControlHandshakeSoa.RequireFromExtensions(soa.EncodeTlv().Concat(soa.EncodeTlv()).ToArray()), "SOA duplicate rejected");
        var wrongVersion = soa.EncodeTlv(); wrongVersion[4] = 2;
        checks.Throws<InvalidDataException>(() => RemoteControlHandshakeSoa.RequireFromExtensions(wrongVersion), "SOA unsupported version rejected");
        checks.Throws<InvalidDataException>(() => RemoteControlHandshakeBinding.PeerId("192.168.0.103"), "route is not identity");
    }

    private static async Task VerifyNativeHandshakeAsync(Checks checks)
    {
        using var initiatorSigner = MLDsa.GenerateKey(MLDsaAlgorithm.MLDsa65);
        using var responderSigner = MLDsa.GenerateKey(MLDsaAlgorithm.MLDsa65);
        using var kem = MLKem.GenerateKey(MLKemAlgorithm.MLKem768);
        var initiatorPrivate = initiatorSigner.ExportMLDsaPrivateKey();
        var responderPrivate = responderSigner.ExportMLDsaPrivateKey();
        var decapsulation = kem.ExportDecapsulationKey();
        try
        {
            const string initiatorId = "id:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
            const string responderId = "id:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
            var soa = new RemoteControlHandshakeSoa(RemoteControlHandshakeBinding.PeerId(initiatorId),
                RemoteControlHandshakeBinding.PeerId(responderId), RandomNumberGenerator.GetBytes(16));
            using var initiatorCrypto = new WebRtcProductPqcHandshakeCryptoProvider(new WebRtcProductPqcHandshakeCryptoProviderOptions(
                initiatorPrivate, kem.ExportEncapsulationKey(), initiatorExtensionsRaw: soa.EncodeTlv()));
            using var responderCrypto = new WebRtcProductPqcHandshakeCryptoProvider(new WebRtcProductPqcHandshakeCryptoProviderOptions(
                responderPrivate, ReadOnlyMemory<byte>.Empty, decapsulation));
            var initiatorPin = new WebRtcProductProtocolIdentityPublicKey(WebRtcProductSignatureAlgorithm.MlDsa65, initiatorSigner.ExportMLDsaPublicKey()).AuthoritativeFingerprint;
            var responderPin = new WebRtcProductProtocolIdentityPublicKey(WebRtcProductSignatureAlgorithm.MlDsa65, responderSigner.ExportMLDsaPublicKey()).AuthoritativeFingerprint;
            await VerifyForwardSecureInitiatorAsync(checks, initiatorPrivate, responderCrypto, responderSigner,
                kem, initiatorPin, responderPin, soa).ConfigureAwait(false);
            await VerifyForwardSecureResponderAsync(checks, initiatorCrypto, responderCrypto, initiatorSigner,
                responderSigner, kem, initiatorPin, responderPin).ConfigureAwait(false);
            var (left, right) = TestTransport.Pair();
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var start = new ProductHandshakeCore(initiatorCrypto).StartInitiatorAsync(left, new ProductHandshakePeerContext(responderId, responderPin), deadline.Token);
            var first = await right.ReadAsync(deadline.Token).ConfigureAwait(false);
            var candidate = RemoteControlHandshakeBinding.ValidateAndResolveMessageA(first, responderId,
                new[] { new RemoteControlTrustedPeer(initiatorId, initiatorPin) });
            var accept = new ProductHandshakeCore(responderCrypto).AcceptResponderAsync(right, candidate.Peer, candidate.MessageAFrame, deadline.Token);
            using var initiator = await start.ConfigureAwait(false);
            var nextFrame = Encoding.UTF8.GetBytes("next ordered application frame");
            await left.SendAsync(nextFrame, deadline.Token).ConfigureAwait(false);
            using var responder = await accept.ConfigureAwait(false);
            checks.Equal(initiator.Keys.SendKey.Span, responder.Keys.ReceiveKey.Span, "real .NET PQC handshake key symmetry");
            checks.That(initiator.Keys.SessionId == responder.Keys.SessionId, "real .NET PQC shared session ID");
            checks.Equal((await right.ReadAsync(deadline.Token).ConfigureAwait(false)).Span, nextFrame, "FIN1 and first application frame handoff preserves bytes");
            var (badLeft, badRight) = TestTransport.Pair(tamperFinished: true);
            var badStart = new ProductHandshakeCore(initiatorCrypto).StartInitiatorAsync(badLeft, new ProductHandshakePeerContext(responderId, responderPin), deadline.Token);
            var badAccept = new ProductHandshakeCore(responderCrypto).AcceptResponderAsync(badRight, new ProductHandshakePeerContext(initiatorId, initiatorPin), cancellationToken: deadline.Token);
            using var badInitiator = await badStart.ConfigureAwait(false);
            await checks.ThrowsAsync<ProductHandshakeException>(async () => { using var result = await badAccept.ConfigureAwait(false); }, "real .NET tampered FIN1 rejects establishment").ConfigureAwait(false);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(initiatorPrivate);
            CryptographicOperations.ZeroMemory(responderPrivate);
            CryptographicOperations.ZeroMemory(decapsulation);
        }
    }

    private static async Task VerifyForwardSecureInitiatorAsync(Checks checks, byte[] initiatorPrivate,
        WebRtcProductPqcHandshakeCryptoProvider responderCrypto, MLDsa responderSigner, MLKem kem,
        string initiatorPin, string responderPin, RemoteControlHandshakeSoa soa)
    {
        using var crypto = new WebRtcProductPqcHandshakeCryptoProvider(new WebRtcProductPqcHandshakeCryptoProviderOptions(
            initiatorPrivate, kem.ExportEncapsulationKey(), initiatorExtensionsRaw: soa.EncodeTlv(),
            maxPendingHandshakes: 1, initiatorSuiteWireId: WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65ForwardSecure));
        var responderPeer = new ProductHandshakePeerContext("responder", responderPin);
        var initiatorPeer = new ProductHandshakePeerContext("initiator", initiatorPin);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var (left, right) = TestTransport.Pair();
        var start = new ProductHandshakeCore(crypto).StartInitiatorAsync(left, responderPeer, deadline.Token);
        var accept = new ProductHandshakeCore(responderCrypto).AcceptResponderAsync(right, initiatorPeer, cancellationToken: deadline.Token);
        using var initiated = await start.ConfigureAwait(false);
        using var accepted = await accept.ConfigureAwait(false);
        checks.Equal(initiated.Keys.SendKey.Span, accepted.Keys.ReceiveKey.Span, "v2 initiator and responder derive matching keys");
        checks.Equal(initiated.Keys.ReceiveKey.Span, accepted.Keys.SendKey.Span, "v2 reverse key symmetry");

        foreach (var downgrade in new[] { false, true })
        {
            var messageA = await crypto.CreateInitiatorMessageAAsync(responderPeer, deadline.Token);
            checks.That(messageA.SupportedSuiteWireIds.SequenceEqual(new ushort[] { 0x0102 }) && messageA.InitiatorContribution.Length == 32,
                "forward-secure initiation offers only its required suite and one ephemeral contribution");
            var transcript = SHA256.HashData(messageA.EncodeWithoutSignature());
            using var material = await responderCrypto.CreateResponderMessageBAsync(initiatorPeer, messageA, transcript, deadline.Token);
            var original = material.MessageB;
            var suite = downgrade ? (ushort)0x0101 : (ushort)0x0102;
            var box = new WebRtcProductHpkeSealedBox(suite, original.EncryptedPayload.EncapsulatedKey,
                original.EncryptedPayload.Nonce, original.EncryptedPayload.Ciphertext, original.EncryptedPayload.Tag);
            WebRtcProductHandshakeMessageB Message(byte[] signature) => new(suite,
                downgrade ? Array.Empty<byte>() : new byte[32], original.ServerNonce, box, original.IdentityPublicKey, signature);
            var unsigned = Message(new byte[] { 1 });
            var invalid = Message(responderSigner.SignData(unsigned.SignaturePreimage(transcript)));
            await checks.ThrowsAsync<ProductHandshakeException>(async () =>
            {
                using var secret = await crypto.OpenResponderMessageBAsync(responderPeer, messageA, transcript, invalid, deadline.Token);
            }, downgrade ? "a signed static-suite downgrade is rejected" : "a signed zero X25519 responder contribution is rejected");
            // A failure must release the one pending private contribution, so another attempt fits.
            var next = await crypto.CreateInitiatorMessageAAsync(responderPeer, deadline.Token);
            crypto.AbortInitiatorSecret(SHA256.HashData(next.EncodeWithoutSignature()));
        }
    }

    private static async Task VerifyForwardSecureResponderAsync(Checks checks,
        WebRtcProductPqcHandshakeCryptoProvider initiatorCrypto, WebRtcProductPqcHandshakeCryptoProvider responderCrypto,
        MLDsa initiatorSigner, MLDsa responderSigner, MLKem kem, string initiatorPin, string responderPin)
    {
        var template = await initiatorCrypto.CreateInitiatorMessageAAsync(new ProductHandshakePeerContext("responder", responderPin));
        var templateHash = SHA256.HashData(template.EncodeWithoutSignature());
        var staticSecret = kem.Decapsulate(template.KeyShares.Single().ShareBytes.ToArray());
        using var contribution = new ProductForwardSecretContribution();
        try
        {
            WebRtcProductHandshakeMessageA Message(byte[] publicContribution, byte[] signature) => new(
                new ushort[] { 0x0102 },
                new[] { new WebRtcProductHandshakeKeyShare(0x0102, template.KeyShares.Single().ShareBytes) },
                template.ClientNonce, template.Capabilities, template.Policy, template.IdentityPublicKey,
                template.ExtensionsRaw, signature, initiatorContribution: publicContribution);
            var unsigned = Message(contribution.PublicKey, new byte[] { 1 });
            var messageA = Message(contribution.PublicKey, initiatorSigner.SignData(unsigned.SignaturePreimage()));
            var transcriptA = SHA256.HashData(messageA.EncodeWithoutSignature());
            var (left, right) = TestTransport.Pair();
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var accept = new ProductHandshakeCore(responderCrypto).AcceptResponderAsync(right,
                new ProductHandshakePeerContext("initiator", initiatorPin), messageA.Encode(), deadline.Token);
            var messageB = WebRtcProductHandshakeCodec.DecodeMessageB((await left.ReadAsync(deadline.Token)).Span);
            checks.That(messageB.SelectedSuiteWireId == 0x0102 && messageB.ResponderShare.Length == 32,
                "v2-only offer selects forward security and carries a responder contribution");
            checks.That(responderSigner.VerifyData(messageB.SignaturePreimage(transcriptA), messageB.Signature.Span),
                "v2 MessageB signature authenticates the ephemeral share");
            var ephemeralSecret = contribution.Derive(messageB.ResponderShare.Span);
            var composed = ProductForwardSecretContribution.Compose(staticSecret, ephemeralSecret, transcriptA, 0x0102);
            try
            {
                using var initiatorKeys = ProductHandshakeKeyDerivation.Derive(composed, 0x0102, transcriptA,
                    SHA256.HashData(messageB.EncodeWithoutSignature()), messageA.ClientNonce.Span,
                    messageB.ServerNonce.Span, ProductHandshakeRole.Initiator);
                var finished = WebRtcProductHandshakeCodec.DecodeFinished((await left.ReadAsync(deadline.Token)).Span);
                checks.That(ProductHandshakeKeyDerivation.VerifyFinished(finished, initiatorKeys, ProductHandshakeRole.Responder),
                    "v2 responder Finished binds both contributions");
                await left.SendAsync(ProductHandshakeKeyDerivation.CreateFinished(initiatorKeys).Encode(), deadline.Token);
                using var established = await accept;
                checks.Equal(established.Keys.ReceiveKey.Span, initiatorKeys.SendKey.Span, "v2 real native handshake establishes symmetric keys");
            }
            finally
            {
                CryptographicOperations.ZeroMemory(ephemeralSecret);
                CryptographicOperations.ZeroMemory(composed);
            }
            var lowOrderUnsigned = Message(new byte[32], new byte[] { 1 });
            var lowOrder = Message(new byte[32], initiatorSigner.SignData(lowOrderUnsigned.SignaturePreimage()));
            await checks.ThrowsAsync<ProductHandshakeException>(async () =>
            {
                using var rejected = await responderCrypto.CreateResponderMessageBAsync(new ProductHandshakePeerContext("initiator", initiatorPin),
                    lowOrder, SHA256.HashData(lowOrder.EncodeWithoutSignature()));
            }, "authenticated low-order v2 contribution is rejected");
        }
        finally
        {
            initiatorCrypto.AbortInitiatorSecret(templateHash);
            CryptographicOperations.ZeroMemory(staticSecret);
        }
    }

    private static bool IsZero(ReadOnlySpan<byte> bytes) { foreach (var value in bytes) { if (value != 0) { return false; } } return true; }

    private sealed class Checks
    {
        public int Count { get; private set; }
        public void That(bool condition, string name) { if (!condition) { throw new InvalidOperationException(name); } Count++; }
        public void Equal(ReadOnlySpan<byte> actual, ReadOnlySpan<byte> expected, string name) => That(actual.SequenceEqual(expected), name);
        public void Throws<T>(Action action, string name) where T : Exception
        {
            try { action(); } catch (T) { Count++; return; }
            throw new InvalidOperationException(name + ": expected " + typeof(T).Name);
        }
        public async Task ThrowsAsync<T>(Func<Task> action, string name) where T : Exception
        {
            try { await action().ConfigureAwait(false); } catch (T) { Count++; return; }
            throw new InvalidOperationException(name + ": expected " + typeof(T).Name);
        }
    }

    private sealed class TestTransport(ChannelReader<ReadOnlyMemory<byte>> incoming, ChannelWriter<ReadOnlyMemory<byte>> outgoing,
        bool tamperFinished) : IProductHandshakeTransport
    {
        public Task<ReadOnlyMemory<byte>> ReadAsync(CancellationToken cancellationToken = default) => incoming.ReadAsync(cancellationToken).AsTask();
        public Task SendAsync(ReadOnlyMemory<byte> frame, CancellationToken cancellationToken = default)
        {
            var owned = frame.ToArray();
            if (tamperFinished && owned.AsSpan().StartsWith("FIN1"u8)) { owned[^1] ^= 1; }
            return outgoing.WriteAsync(owned, cancellationToken).AsTask();
        }
        public static (TestTransport Left, TestTransport Right) Pair(bool tamperFinished = false)
        {
            var first = Channel.CreateBounded<ReadOnlyMemory<byte>>(8);
            var second = Channel.CreateBounded<ReadOnlyMemory<byte>>(8);
            return (new TestTransport(first.Reader, second.Writer, tamperFinished), new TestTransport(second.Reader, first.Writer, false));
        }
    }
}
