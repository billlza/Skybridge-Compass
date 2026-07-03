using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public sealed class WebRtcProductPqcHandshakeCryptoProviderOptions
{
    private readonly byte[] _localMlDsa65PrivateKey;

    public WebRtcProductPqcHandshakeCryptoProviderOptions(
        ReadOnlyMemory<byte> localMlDsa65PrivateKey,
        ReadOnlyMemory<byte> peerMlKem768PublicKey,
        string platformVersion = "windows-dotnet-pqc",
        string providerType = "liboqs",
        WebRtcProductHandshakePolicy? policy = null,
        int maxPendingHandshakes = 4)
    {
        if (localMlDsa65PrivateKey.IsEmpty)
        {
            throw new InvalidOperationException("WebRTC product PQC provider requires a local ML-DSA-65 private key.");
        }

        if (peerMlKem768PublicKey.Length != MLKemAlgorithm.MLKem768.EncapsulationKeySizeInBytes)
        {
            throw new InvalidOperationException(
                $"WebRTC product PQC provider peer ML-KEM-768 public key must be {MLKemAlgorithm.MLKem768.EncapsulationKeySizeInBytes} bytes.");
        }

        if (maxPendingHandshakes is < 1 or > 8)
        {
            throw new InvalidOperationException(
                "WebRTC product PQC provider max pending handshakes must be between 1 and 8.");
        }

        _localMlDsa65PrivateKey = localMlDsa65PrivateKey.ToArray();
        PeerMlKem768PublicKey = peerMlKem768PublicKey.ToArray();
        PlatformVersion = string.IsNullOrWhiteSpace(platformVersion)
            ? throw new InvalidOperationException("WebRTC product PQC provider platformVersion must not be empty.")
            : platformVersion.Trim();
        ProviderType = string.IsNullOrWhiteSpace(providerType)
            ? throw new InvalidOperationException("WebRTC product PQC provider providerType must not be empty.")
            : providerType.Trim();
        Policy = policy ?? new WebRtcProductHandshakePolicy(
            requirePqc: true,
            allowClassicFallback: false,
            minimumTier: "nativePQC",
            requireSecureEnclavePoP: false);
        MaxPendingHandshakes = maxPendingHandshakes;
    }

    public ReadOnlyMemory<byte> LocalMlDsa65PrivateKey => _localMlDsa65PrivateKey;

    public ReadOnlyMemory<byte> PeerMlKem768PublicKey { get; }

    public string PlatformVersion { get; }

    public string ProviderType { get; }

    public WebRtcProductHandshakePolicy Policy { get; }

    public int MaxPendingHandshakes { get; }

    internal void ClearLocalMlDsa65PrivateKey() =>
        CryptographicOperations.ZeroMemory(_localMlDsa65PrivateKey);
}

public sealed class WebRtcProductPqcHandshakeCryptoProvider : IWebRtcProductHandshakeCryptoProvider, IDisposable
{
    private static readonly byte[] EmptyMldsaContext = Array.Empty<byte>();
    private static readonly byte[] PlaceholderSignature = { 0x01 };
    private static readonly byte[] HandshakePayloadInfo = Encoding.ASCII.GetBytes("handshake-payload");

    private readonly MLDsa _identitySigner;
    private readonly object _signingGate = new();
    private readonly object _pendingGate = new();
    private readonly byte[] _localIdentityPublicKeyWire;
    private readonly byte[] _peerMlKem768PublicKey;
    private readonly WebRtcProductHandshakePolicy _policy;
    private readonly string _platformVersion;
    private readonly string _providerType;
    private readonly int _maxPendingHandshakes;
    private readonly Dictionary<string, PendingInitiatorSecret> _pendingSecrets = new(StringComparer.Ordinal);
    private bool _disposed;

    public WebRtcProductPqcHandshakeCryptoProvider(WebRtcProductPqcHandshakeCryptoProviderOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        EnsurePlatformSupport();
        try
        {
            _identitySigner = ImportIdentitySigner(options.LocalMlDsa65PrivateKey.Span);
        }
        finally
        {
            options.ClearLocalMlDsa65PrivateKey();
        }

        var localIdentity = new WebRtcProductProtocolIdentityPublicKey(
            WebRtcProductSignatureAlgorithm.MlDsa65,
            _identitySigner.ExportMLDsaPublicKey());
        _localIdentityPublicKeyWire = localIdentity.Encode();
        _peerMlKem768PublicKey = options.PeerMlKem768PublicKey.ToArray();
        _policy = options.Policy;
        _platformVersion = options.PlatformVersion;
        _providerType = options.ProviderType;

        // Mac's wire enum currently has no ".NET-PQC" value. Use the existing
        // cross-platform PQC providerType so Mac decoders accept the capabilities;
        // this should collapse to an explicit Windows/.NET enum once the shared
        // protocol contract grows that value.
        _ = new WebRtcProductCryptoCapabilities(
            supportedKem: new[] { "ML-KEM-768" },
            supportedSignature: new[] { "ML-DSA-65" },
            supportedAuthProfiles: new[] { "PQC" },
            supportedAead: new[] { "AES-256-GCM" },
            pqcAvailable: true,
            platformVersion: _platformVersion,
            providerType: _providerType);
        _maxPendingHandshakes = options.MaxPendingHandshakes;
    }

    public ValueTask<WebRtcProductHandshakeMessageA> CreateInitiatorMessageAAsync(
        LiveWebRtcProductControlContext context,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(context);
        cancellationToken.ThrowIfCancellationRequested();
        ThrowIfDisposed();

        var keyShare = new byte[MLKemAlgorithm.MLKem768.CiphertextSizeInBytes];
        var sharedSecret = new byte[MLKemAlgorithm.MLKem768.SharedSecretSizeInBytes];
        try
        {
            using (var peerKem = MLKem.ImportEncapsulationKey(
                MLKemAlgorithm.MLKem768,
                _peerMlKem768PublicKey))
            {
                peerKem.Encapsulate(keyShare, sharedSecret);
            }

            var clientNonce = RandomNumberGenerator.GetBytes(WebRtcProductHandshakeCodec.NonceLength);
            var unsignedMessageA = BuildMessageA(keyShare, clientNonce, PlaceholderSignature);
            var signature = Sign(unsignedMessageA.SignaturePreimage());
            var messageA = BuildMessageA(keyShare, clientNonce, signature);
            var transcriptHashA = SHA256.HashData(messageA.EncodeWithoutSignature());
            AddPendingSecret(transcriptHashA, keyShare, sharedSecret);
            return ValueTask.FromResult(messageA);
        }
        catch (Exception ex) when (ex is CryptographicException or WebRtcProductHandshakeCodecException)
        {
            throw new WebRtcProductHandshakeDriverException(
                $"WebRTC product PQC provider failed to create initiator MessageA: {ex.Message}",
                ex);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(sharedSecret);
            CryptographicOperations.ZeroMemory(keyShare);
        }
    }

    public ValueTask<ReadOnlyMemory<byte>> OpenResponderMessageBAsync(
        LiveWebRtcProductControlContext context,
        WebRtcProductHandshakeMessageA messageA,
        ReadOnlyMemory<byte> transcriptHashA,
        WebRtcProductHandshakeMessageB messageB,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(messageA);
        ArgumentNullException.ThrowIfNull(messageB);
        cancellationToken.ThrowIfCancellationRequested();
        ThrowIfDisposed();

        if (transcriptHashA.Length != WebRtcProductHandshakeCodec.TranscriptHashLength)
        {
            throw new WebRtcProductHandshakeDriverException(
                "WebRTC product PQC provider requires a 32-byte transcriptHashA.");
        }

        var pending = TakePendingSecret(transcriptHashA.Span);
        byte[]? plaintext = null;
        byte[]? payloadKey = null;
        try
        {
            ValidateSelectedSuite(messageA, messageB, pending);
            var responderIdentity = WebRtcProductProtocolIdentityPublicKey.DecodeWithLegacyFallback(
                messageB.IdentityPublicKey.Span);
            ValidateResponderIdentity(context, responderIdentity);
            VerifyResponderSignature(responderIdentity, transcriptHashA.Span, messageB);

            payloadKey = WebRtcProductHandshakeSessionKeys.HkdfSha256(
                pending.SharedSecret,
                transcriptHashA.Span,
                HandshakePayloadInfo,
                outputLength: 32);
            plaintext = OpenResponderPayload(messageB.EncryptedPayload, payloadKey);
            var responderCapabilities = WebRtcProductCryptoCapabilities.Decode(plaintext);
            ValidateResponderCapabilities(responderCapabilities);
            return ValueTask.FromResult<ReadOnlyMemory<byte>>(pending.SharedSecret.ToArray());
        }
        catch (Exception ex) when (ex is CryptographicException or WebRtcProductHandshakeCodecException)
        {
            throw new WebRtcProductHandshakeDriverException(
                $"WebRTC product PQC provider failed to authenticate or open responder MessageB: {ex.Message}",
                ex);
        }
        finally
        {
            pending.Dispose();
            if (payloadKey is not null)
            {
                CryptographicOperations.ZeroMemory(payloadKey);
            }

            if (plaintext is not null)
            {
                CryptographicOperations.ZeroMemory(plaintext);
            }
        }
    }

    public void Dispose()
    {
        lock (_pendingGate)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            foreach (var pending in _pendingSecrets.Values)
            {
                pending.Dispose();
            }

            _pendingSecrets.Clear();
        }

        _identitySigner.Dispose();
        CryptographicOperations.ZeroMemory(_localIdentityPublicKeyWire);
        CryptographicOperations.ZeroMemory(_peerMlKem768PublicKey);
    }

    private WebRtcProductHandshakeMessageA BuildMessageA(
        ReadOnlySpan<byte> keyShare,
        ReadOnlySpan<byte> clientNonce,
        ReadOnlySpan<byte> signature)
    {
        return new WebRtcProductHandshakeMessageA(
            supportedSuiteWireIds: new[] { WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65 },
            keyShares: new[]
            {
                new WebRtcProductHandshakeKeyShare(
                    WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65,
                    keyShare.ToArray())
            },
            clientNonce: clientNonce.ToArray(),
            capabilities: new WebRtcProductCryptoCapabilities(
                supportedKem: new[] { "ML-KEM-768" },
                supportedSignature: new[] { "ML-DSA-65" },
                supportedAuthProfiles: new[] { "PQC" },
                supportedAead: new[] { "AES-256-GCM" },
                pqcAvailable: true,
                platformVersion: _platformVersion,
                providerType: _providerType),
            policy: _policy,
            identityPublicKey: _localIdentityPublicKeyWire,
            extensionsRaw: Array.Empty<byte>(),
            signature: signature.ToArray());
    }

    private byte[] Sign(byte[] dataToSign)
    {
        lock (_signingGate)
        {
            return _identitySigner.SignData(dataToSign, EmptyMldsaContext);
        }
    }

    private void AddPendingSecret(
        ReadOnlySpan<byte> transcriptHashA,
        ReadOnlySpan<byte> keyShare,
        ReadOnlySpan<byte> sharedSecret)
    {
        var key = FingerprintKey(transcriptHashA);
        var pending = new PendingInitiatorSecret(keyShare, sharedSecret);
        lock (_pendingGate)
        {
            ThrowIfDisposed();
            if (_pendingSecrets.Count >= _maxPendingHandshakes)
            {
                pending.Dispose();
                throw new WebRtcProductHandshakeDriverException(
                    "WebRTC product PQC provider pending handshake capacity is exhausted.");
            }

            if (_pendingSecrets.ContainsKey(key))
            {
                pending.Dispose();
                throw new WebRtcProductHandshakeDriverException(
                    "WebRTC product PQC provider detected a duplicate transcriptHashA.");
            }

            _pendingSecrets.Add(key, pending);
        }
    }

    private PendingInitiatorSecret TakePendingSecret(ReadOnlySpan<byte> transcriptHashA)
    {
        var key = FingerprintKey(transcriptHashA);
        lock (_pendingGate)
        {
            ThrowIfDisposed();
            if (!_pendingSecrets.Remove(key, out var pending))
            {
                throw new WebRtcProductHandshakeDriverException(
                    "WebRTC product PQC provider has no pending initiator secret for transcriptHashA.");
            }

            return pending;
        }
    }

    private static void ValidateSelectedSuite(
        WebRtcProductHandshakeMessageA messageA,
        WebRtcProductHandshakeMessageB messageB,
        PendingInitiatorSecret pending)
    {
        if (messageB.SelectedSuiteWireId != WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65)
        {
            throw new WebRtcProductHandshakeCodecException(
                "WebRTC product PQC provider only supports ML-KEM-768 + ML-DSA-65.");
        }

        if (!messageA.Policy.RequirePqc || messageA.Policy.AllowClassicFallback)
        {
            throw new WebRtcProductHandshakeCodecException(
                "WebRTC product PQC provider MessageA policy must require PQC without classic fallback.");
        }

        if (!messageB.ResponderShare.IsEmpty || !messageB.EncryptedPayload.EncapsulatedKey.IsEmpty)
        {
            throw new WebRtcProductHandshakeCodecException(
                "ML-KEM-768 static PQC MessageB must not carry a responder share or HPKE encapsulated key.");
        }

        ReadOnlyMemory<byte>? offeredKeyShare = null;
        foreach (var keyShare in messageA.KeyShares)
        {
            if (keyShare.SuiteWireId == WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65)
            {
                offeredKeyShare = keyShare.ShareBytes;
                break;
            }
        }

        if (!offeredKeyShare.HasValue ||
            !CryptographicOperations.FixedTimeEquals(offeredKeyShare.Value.Span, pending.KeyShare))
        {
            throw new WebRtcProductHandshakeCodecException(
                "WebRTC product PQC provider MessageA keyShare does not match the pending KEM ciphertext.");
        }
    }

    private static void ValidateResponderIdentity(
        LiveWebRtcProductControlContext context,
        WebRtcProductProtocolIdentityPublicKey responderIdentity)
    {
        if (responderIdentity.Algorithm != WebRtcProductSignatureAlgorithm.MlDsa65)
        {
            throw new WebRtcProductHandshakeCodecException(
                "WebRTC product PQC provider requires responder protocol identity algorithm ML-DSA-65.");
        }

        if (!string.Equals(
                responderIdentity.AuthoritativeFingerprint,
                context.PeerPublicKeyFingerprint,
                StringComparison.Ordinal))
        {
            throw new WebRtcProductHandshakeCodecException(
                "WebRTC product PQC provider responder authoritative fingerprint mismatch.");
        }
    }

    private static void VerifyResponderSignature(
        WebRtcProductProtocolIdentityPublicKey responderIdentity,
        ReadOnlySpan<byte> transcriptHashA,
        WebRtcProductHandshakeMessageB messageB)
    {
        using var verifier = MLDsa.ImportMLDsaPublicKey(
            MLDsaAlgorithm.MLDsa65,
            responderIdentity.PublicKey.Span);
        var signaturePreimage = messageB.SignaturePreimage(transcriptHashA);
        if (!verifier.VerifyData(signaturePreimage, messageB.Signature.Span, EmptyMldsaContext))
        {
            throw new WebRtcProductHandshakeCodecException(
                "WebRTC product PQC provider responder MessageB ML-DSA signature verification failed.");
        }
    }

    private static byte[] OpenResponderPayload(
        WebRtcProductHpkeSealedBox sealedBox,
        ReadOnlySpan<byte> payloadKey)
    {
        if (sealedBox.Nonce.Length != WebRtcProductHandshakeCodec.HpkeNonceLength ||
            sealedBox.Tag.Length != WebRtcProductHandshakeCodec.HpkeTagLength)
        {
            throw new WebRtcProductHandshakeCodecException(
                "WebRTC product PQC provider MessageB payload must use AES-256-GCM nonce and tag lengths.");
        }

        var plaintext = new byte[sealedBox.Ciphertext.Length];
        using var aes = new AesGcm(payloadKey, WebRtcProductHandshakeCodec.HpkeTagLength);
        aes.Decrypt(
            sealedBox.Nonce.Span,
            sealedBox.Ciphertext.Span,
            sealedBox.Tag.Span,
            plaintext);
        return plaintext;
    }

    private static void ValidateResponderCapabilities(WebRtcProductCryptoCapabilities capabilities)
    {
        if (!capabilities.PqcAvailable ||
            !Contains(capabilities.SupportedKem, "ML-KEM-768") ||
            !Contains(capabilities.SupportedSignature, "ML-DSA-65") ||
            !Contains(capabilities.SupportedAead, "AES-256-GCM"))
        {
            throw new WebRtcProductHandshakeCodecException(
                "WebRTC product PQC responder capabilities do not contain the negotiated PQC algorithms.");
        }
    }

    private static bool Contains(IReadOnlyList<string> values, string expected)
    {
        for (var index = 0; index < values.Count; index++)
        {
            if (string.Equals(values[index], expected, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    private static MLDsa ImportIdentitySigner(ReadOnlySpan<byte> keyBytes)
    {
        if (keyBytes.Length == MLDsaAlgorithm.MLDsa65.PrivateSeedSizeInBytes)
        {
            return MLDsa.ImportMLDsaPrivateSeed(MLDsaAlgorithm.MLDsa65, keyBytes);
        }

        if (keyBytes.Length == MLDsaAlgorithm.MLDsa65.PrivateKeySizeInBytes)
        {
            return MLDsa.ImportMLDsaPrivateKey(MLDsaAlgorithm.MLDsa65, keyBytes);
        }

        throw new InvalidOperationException(
            $"WebRTC product PQC provider local ML-DSA-65 private key must be {MLDsaAlgorithm.MLDsa65.PrivateSeedSizeInBytes} byte seed or {MLDsaAlgorithm.MLDsa65.PrivateKeySizeInBytes} byte private key.");
    }

    private static void EnsurePlatformSupport()
    {
        if (!MLKem.IsSupported)
        {
            throw new PlatformNotSupportedException("The current platform does not support ML-KEM.");
        }

        if (!MLDsa.IsSupported)
        {
            throw new PlatformNotSupportedException("The current platform does not support ML-DSA.");
        }
    }

    private static string FingerprintKey(ReadOnlySpan<byte> transcriptHashA)
    {
        if (transcriptHashA.Length != WebRtcProductHandshakeCodec.TranscriptHashLength)
        {
            throw new WebRtcProductHandshakeDriverException(
                "WebRTC product PQC provider transcriptHashA key must be exactly 32 bytes.");
        }

        return Convert.ToHexString(transcriptHashA).ToLowerInvariant();
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(WebRtcProductPqcHandshakeCryptoProvider));
        }
    }

    private sealed class PendingInitiatorSecret : IDisposable
    {
        public PendingInitiatorSecret(ReadOnlySpan<byte> keyShare, ReadOnlySpan<byte> sharedSecret)
        {
            KeyShare = keyShare.ToArray();
            SharedSecret = sharedSecret.ToArray();
        }

        public byte[] KeyShare { get; }

        public byte[] SharedSecret { get; }

        public void Dispose()
        {
            CryptographicOperations.ZeroMemory(KeyShare);
            CryptographicOperations.ZeroMemory(SharedSecret);
        }
    }
}
