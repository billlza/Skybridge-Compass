using System.Security.Cryptography;

namespace Skybridge.WinClient.Services;

public sealed partial class WebRtcProductPqcHandshakeCryptoProvider
{
    private readonly QPeriaptRuntimeSession? _qSession;
    private readonly byte[] _peerQPublicKey;
    private readonly QPeriaptKeyPair? _localQKey;

    private QPeriaptRuntimeSession RequireQSession() => _qSession
        ?? throw new ProductHandshakeException("The policy-bound product handshake has no authenticated runtime session.");

    private WebRtcProductCryptoCapabilities CreateCapabilities(ushort suite) =>
        suite == WebRtcProductHandshakeCodec.SuiteQPeriaptPolicyBound
            ? new([QPeriaptPeerPlatform.KemCapability], ["ML-DSA-65"], [RequireQSession().AuthProfile],
                ["AES-256-GCM"], true, _platformVersion, QPeriaptPeerPlatform.ProviderType)
            : new(["ML-KEM-768"], ["ML-DSA-65"], ["PQC"], ["AES-256-GCM"], true, _platformVersion, _providerType);

    private ValueTask<WebRtcProductHandshakeMessageA> CreatePolicyBoundMessageA(CancellationToken cancellationToken)
    {
        var session = RequireQSession();
        RequirePolicyBoundPolicy(_policy);
        var nonce = RandomNumberGenerator.GetBytes(WebRtcProductHandshakeCodec.NonceLength);
        var context = QPeriaptHandshakeContext.Encode(1, nonce, _peerQPublicKey, _policy,
            [_initiatorSuiteWireId], CreateCapabilities(_initiatorSuiteWireId), _localIdentityPublicKeyWire, _initiatorExtensionsRaw);
        PendingInitiatorSecret? pending = null;
        try
        {
            using var encapsulation = QPeriaptNativeClient.Encapsulate(session.Decision,
                _peerQPublicKey.AsSpan(0, 1184), _peerQPublicKey.AsSpan(1184, 32), context, cancellationToken);
            var ciphertext = new byte[QPeriaptKeyEncoding.CiphertextLength];
            encapsulation.CiphertextPq.Span.CopyTo(ciphertext);
            encapsulation.CiphertextTraditional.Span.CopyTo(ciphertext.AsSpan(1088));
            pending = new PendingInitiatorSecret(ciphertext, encapsulation.Secret.Bytes.Span, _initiatorSuiteWireId);
            var unsigned = BuildMessageA(ciphertext, nonce, PlaceholderSignature, ReadOnlyMemory<byte>.Empty);
            var message = BuildMessageA(ciphertext, nonce, Sign(unsigned.SignaturePreimage()), ReadOnlyMemory<byte>.Empty);
            cancellationToken.ThrowIfCancellationRequested();
            AddPendingSecret(SHA256.HashData(message.EncodeWithoutSignature()), pending);
            pending = null;
            return ValueTask.FromResult(message);
        }
        finally
        {
            pending?.Dispose();
            CryptographicOperations.ZeroMemory(context);
        }
    }

    private byte[] DecapsulatePolicyBoundMessageA(WebRtcProductHandshakeMessageA message,
        byte[] ciphertext, CancellationToken cancellationToken)
    {
        var session = RequireQSession();
        var keys = _localQKey ?? throw new ProductHandshakeException("The Q-Periapt responder identity is unavailable.");
        var context = QPeriaptHandshakeContext.Encode(message.Version, message.ClientNonce.Span,
            QPeriaptKeyEncoding.ExportPublic(keys), message.Policy, message.SupportedSuiteWireIds,
            message.Capabilities, message.IdentityPublicKey.Span, message.ExtensionsRaw.Span);
        try
        {
            using var recovered = QPeriaptNativeClient.Decapsulate(session.Decision, keys,
                ciphertext.AsSpan(0, 1088), ciphertext.AsSpan(1088, 32), context, cancellationToken);
            return recovered.Bytes.ToArray();
        }
        finally { CryptographicOperations.ZeroMemory(context); }
    }

    private static void RequirePolicyBoundPolicy(WebRtcProductHandshakePolicy policy)
    {
        if (!policy.RequirePqc || policy.AllowClassicFallback || policy.MinimumTier != "qperiaptPQC" || policy.RequireSecureEnclavePoP)
        { throw new WebRtcProductHandshakeCodecException("Q-Periapt requires its policy-bound PQC tier without fallback or unsupported Secure Enclave proof."); }
    }
}
