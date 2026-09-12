using System;
using System.Buffers.Binary;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

/// <summary>Shared MessageA/MessageB/FIN1 state machine. It does not own the carrier or install product runtimes.</summary>
public sealed class ProductHandshakeCore
{
    private readonly IProductHandshakeCryptoProvider _cryptoProvider;
    private readonly TimeSpan _messageTimeout;

    public ProductHandshakeCore(IProductHandshakeCryptoProvider cryptoProvider, TimeSpan? messageTimeout = null)
    {
        _cryptoProvider = cryptoProvider ?? throw new ArgumentNullException(nameof(cryptoProvider));
        _messageTimeout = messageTimeout ?? TimeSpan.FromSeconds(30);
        if (_messageTimeout <= TimeSpan.Zero) { throw new ArgumentOutOfRangeException(nameof(messageTimeout)); }
    }

    public async Task<AuthenticatedProductHandshake> StartInitiatorAsync(
        IProductHandshakeTransport transport, ProductHandshakePeerContext peer,
        CancellationToken cancellationToken = default)
    {
        ValidateArguments(transport, peer);
        var messageA = await _cryptoProvider.CreateInitiatorMessageAAsync(peer, cancellationToken).ConfigureAwait(false);
        ArgumentNullException.ThrowIfNull(messageA);
        var transcriptA = SHA256.HashData(messageA.EncodeWithoutSignature());
        var secretPending = true;
        try
        {
            ValidateMessageA(messageA);
            var frameA = messageA.Encode();
            await SendAsync(transport, frameA, "MessageA", cancellationToken).ConfigureAwait(false);
            var frameB = await ReadAsync(transport, "MessageB", cancellationToken).ConfigureAwait(false);
            var messageB = DecodeMessageB(frameB);
            ValidateIdentity(messageB.IdentityPublicKey.Span, peer, "MessageB");
            ValidateSelection(messageA, messageB);
            using var secret = await _cryptoProvider.OpenResponderMessageBAsync(
                peer, messageA, transcriptA, messageB, cancellationToken).ConfigureAwait(false);
            secretPending = false;
            {
                using var keys = ProductHandshakeKeyDerivation.Derive(
                    secret.Bytes.Span, messageB.SelectedSuiteWireId, transcriptA,
                    SHA256.HashData(messageB.EncodeWithoutSignature()), messageA.ClientNonce.Span,
                    messageB.ServerNonce.Span, ProductHandshakeRole.Initiator);
                var peerFinished = DecodeFinished(await ReadAsync(transport, "responder Finished", cancellationToken).ConfigureAwait(false));
                if (!ProductHandshakeKeyDerivation.VerifyFinished(peerFinished, keys, ProductHandshakeRole.Responder))
                {
                    throw new ProductHandshakeException("Product handshake responder Finished MAC verification failed.");
                }
                await SendAsync(transport, ProductHandshakeKeyDerivation.CreateFinished(keys).Encode(),
                    "initiator Finished", cancellationToken).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();
                return new AuthenticatedProductHandshake(keys, messageB.SelectedSuiteWireId, frameA, frameB);
            }
        }
        finally
        {
            if (secretPending) { _cryptoProvider.AbortInitiatorSecret(transcriptA); }
        }
    }

    public async Task<AuthenticatedProductHandshake> AcceptResponderAsync(
        IProductHandshakeTransport transport, ProductHandshakePeerContext peer,
        ReadOnlyMemory<byte> initialMessageA = default, CancellationToken cancellationToken = default)
    {
        ValidateArguments(transport, peer);
        cancellationToken.ThrowIfCancellationRequested();
        var frameA = initialMessageA.IsEmpty
            ? await ReadAsync(transport, "MessageA", cancellationToken).ConfigureAwait(false)
            : initialMessageA.ToArray();
        RejectPreAuthenticationEnvelope(frameA, "MessageA");
        var messageA = DecodeMessageA(frameA);
        ValidateMessageA(messageA);
        ValidateIdentity(messageA.IdentityPublicKey.Span, peer, "MessageA");
        var transcriptA = SHA256.HashData(messageA.EncodeWithoutSignature());
        using var material = await _cryptoProvider.CreateResponderMessageBAsync(
            peer, messageA, transcriptA, cancellationToken).ConfigureAwait(false);
        ArgumentNullException.ThrowIfNull(material);
        var messageB = material.MessageB;
        ValidateSelection(messageA, messageB);
        var frameB = messageB.Encode();
        using var keys = ProductHandshakeKeyDerivation.Derive(
            material.SharedSecret.Span, messageB.SelectedSuiteWireId, transcriptA,
            SHA256.HashData(messageB.EncodeWithoutSignature()), messageA.ClientNonce.Span,
            messageB.ServerNonce.Span, ProductHandshakeRole.Responder);
        await SendAsync(transport, frameB, "MessageB", cancellationToken).ConfigureAwait(false);
        await SendAsync(transport, ProductHandshakeKeyDerivation.CreateFinished(keys).Encode(),
            "responder Finished", cancellationToken).ConfigureAwait(false);
        var peerFinished = DecodeFinished(await ReadAsync(transport, "initiator Finished", cancellationToken).ConfigureAwait(false));
        if (!ProductHandshakeKeyDerivation.VerifyFinished(peerFinished, keys, ProductHandshakeRole.Initiator))
        {
            throw new ProductHandshakeException("Product handshake initiator Finished MAC verification failed.");
        }
        cancellationToken.ThrowIfCancellationRequested();
        return new AuthenticatedProductHandshake(keys, messageB.SelectedSuiteWireId, frameA, frameB);
    }

    private async Task<byte[]> ReadAsync(IProductHandshakeTransport transport, string expected, CancellationToken cancellationToken)
    {
        using var deadline = new CancellationTokenSource(_messageTimeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        try
        {
            var frame = (await transport.ReadAsync(linked.Token).ConfigureAwait(false)).ToArray();
            linked.Token.ThrowIfCancellationRequested();
            RejectPreAuthenticationEnvelope(frame, expected);
            return frame;
        }
        catch (OperationCanceledException) when (deadline.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException($"Product handshake timed out waiting for {expected} after {_messageTimeout.TotalSeconds:F0}s.");
        }
    }

    private async Task SendAsync(IProductHandshakeTransport transport, byte[] frame, string name, CancellationToken cancellationToken)
    {
        using var deadline = new CancellationTokenSource(_messageTimeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        try
        {
            await transport.SendAsync(frame, linked.Token).ConfigureAwait(false);
            linked.Token.ThrowIfCancellationRequested();
        }
        catch (OperationCanceledException) when (deadline.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException($"Product handshake timed out sending {name} after {_messageTimeout.TotalSeconds:F0}s.");
        }
    }

    private static void ValidateArguments(IProductHandshakeTransport transport, ProductHandshakePeerContext peer)
    {
        ArgumentNullException.ThrowIfNull(transport);
        ArgumentNullException.ThrowIfNull(peer);
        ArgumentException.ThrowIfNullOrWhiteSpace(peer.PeerDeviceId);
        if (peer.PeerPublicKeyFingerprint.Length != 64 ||
            peer.PeerPublicKeyFingerprint.Any(value => !((value >= '0' && value <= '9') || (value >= 'a' && value <= 'f'))))
        {
            throw new ProductHandshakeException("Product handshake requires a canonical trusted protocol fingerprint.");
        }
    }

    private static void ValidateMessageA(WebRtcProductHandshakeMessageA message)
    {
        if (message.SupportedSuiteWireIds.Count == 0 || message.KeyShares.Count == 0)
        {
            throw new ProductHandshakeException("Product handshake MessageA must contain supported suites and key shares.");
        }
    }

    private static void ValidateSelection(WebRtcProductHandshakeMessageA messageA, WebRtcProductHandshakeMessageB messageB)
    {
        if (!messageA.SupportedSuiteWireIds.Contains(messageB.SelectedSuiteWireId))
        {
            throw new ProductHandshakeException("Product handshake responder selected a suite that was not offered in MessageA.");
        }
        var classic = messageB.SelectedSuiteWireId is WebRtcProductHandshakeCodec.SuiteX25519Ed25519 or WebRtcProductHandshakeCodec.SuiteP256Ecdsa;
        if (classic && (messageA.Policy.RequirePqc || (!messageA.Policy.AllowClassicFallback && messageA.Policy.MinimumTier != "classic")))
        {
            throw new ProductHandshakeException("Product handshake responder selected a classic suite while classic fallback is disabled.");
        }
    }

    private static void ValidateIdentity(ReadOnlySpan<byte> publicKey, ProductHandshakePeerContext peer, string message)
    {
        try
        {
            var identity = WebRtcProductProtocolIdentityPublicKey.DecodeWithLegacyFallback(publicKey);
            if (!string.Equals(identity.AuthoritativeFingerprint, peer.PeerPublicKeyFingerprint, StringComparison.Ordinal))
            {
                throw new ProductHandshakeException($"Product handshake {message} identity public key fingerprint does not match the trusted peer authoritative fingerprint.");
            }
        }
        catch (WebRtcProductHandshakeCodecException ex)
        {
            throw new ProductHandshakeException($"Product handshake {message} protocol identity is invalid.", ex);
        }
    }

    private static WebRtcProductHandshakeMessageA DecodeMessageA(byte[] frame)
    {
        try { return WebRtcProductHandshakeCodec.DecodeMessageA(frame); }
        catch (Exception ex) when (ex is WebRtcProductHandshakeCodecException or InvalidDataException)
        { throw new ProductHandshakeException("Product handshake failed to decode initiator MessageA.", ex); }
    }

    private static WebRtcProductHandshakeMessageB DecodeMessageB(byte[] frame)
    {
        try { return WebRtcProductHandshakeCodec.DecodeMessageB(frame); }
        catch (Exception ex) when (ex is WebRtcProductHandshakeCodecException or InvalidDataException)
        { throw new ProductHandshakeException("Product handshake failed to decode responder MessageB.", ex); }
    }

    private static WebRtcProductHandshakeFinished DecodeFinished(byte[] frame)
    {
        try { return WebRtcProductHandshakeCodec.DecodeFinished(frame); }
        catch (Exception ex) when (ex is WebRtcProductHandshakeCodecException or InvalidDataException)
        { throw new ProductHandshakeException("Product handshake failed to decode Finished.", ex); }
    }

    private static void RejectPreAuthenticationEnvelope(ReadOnlySpan<byte> frame, string expected)
    {
        if (frame.Length >= 4 && BinaryPrimitives.ReadUInt32BigEndian(frame[..4]) is 0x5342_5743 or 0x5342_5243)
        {
            var name = BinaryPrimitives.ReadUInt32BigEndian(frame[..4]) == 0x5342_5743 ? "SBWC" : "SBRC";
            throw new ProductHandshakeException($"Product handshake received an {name} envelope while waiting for {expected}.");
        }
    }
}
