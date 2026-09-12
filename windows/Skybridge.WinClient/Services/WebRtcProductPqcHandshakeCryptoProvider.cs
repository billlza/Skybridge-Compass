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
    private readonly byte[] _localMlKem768DecapsulationKey;
    private readonly byte[] _localQPeriaptPrivateKey;

    public WebRtcProductPqcHandshakeCryptoProviderOptions(
        ReadOnlyMemory<byte> localMlDsa65PrivateKey,
        ReadOnlyMemory<byte> peerMlKem768PublicKey,
        ReadOnlyMemory<byte> localMlKem768DecapsulationKey = default,
        string platformVersion = "windows-dotnet-pqc",
        string providerType = "liboqs",
        WebRtcProductHandshakePolicy? policy = null,
        int maxPendingHandshakes = 4,
        ReadOnlyMemory<byte> initiatorExtensionsRaw = default,
        ushort initiatorSuiteWireId = WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65)
        : this(localMlDsa65PrivateKey, peerMlKem768PublicKey, localMlKem768DecapsulationKey, platformVersion,
            providerType, policy, maxPendingHandshakes, initiatorExtensionsRaw, initiatorSuiteWireId, null, default, default)
    { }

    internal WebRtcProductPqcHandshakeCryptoProviderOptions(ReadOnlyMemory<byte> signingKey,
        ReadOnlyMemory<byte> peerLegacyKey, ReadOnlyMemory<byte> localLegacyKey, QPeriaptRuntimeSession session,
        ReadOnlyMemory<byte> peerQKey, ReadOnlyMemory<byte> localQKey, ReadOnlyMemory<byte> extensions = default,
        ushort initiatorSuite = WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65)
        : this(signingKey, peerLegacyKey, localLegacyKey, QPeriaptPeerPlatform.LocalVersion(), "liboqs", null,
            4, extensions, initiatorSuite, session, peerQKey, localQKey)
    { }

    private WebRtcProductPqcHandshakeCryptoProviderOptions(ReadOnlyMemory<byte> localMlDsa65PrivateKey,
        ReadOnlyMemory<byte> peerMlKem768PublicKey, ReadOnlyMemory<byte> localMlKem768DecapsulationKey,
        string platformVersion, string providerType, WebRtcProductHandshakePolicy? policy, int maxPendingHandshakes,
        ReadOnlyMemory<byte> initiatorExtensionsRaw, ushort initiatorSuiteWireId,
        QPeriaptRuntimeSession? qSession, ReadOnlyMemory<byte> peerQKey, ReadOnlyMemory<byte> localQKey)
    {
        if (localMlDsa65PrivateKey.IsEmpty)
        {
            throw new InvalidOperationException("Product PQC provider requires a local ML-DSA-65 private key.");
        }

        if (peerMlKem768PublicKey.IsEmpty && localMlKem768DecapsulationKey.IsEmpty && peerQKey.IsEmpty && localQKey.IsEmpty)
        {
            throw new InvalidOperationException(
                "Product PQC provider requires a peer ML-KEM-768 public key for initiator mode or a local ML-KEM-768 decapsulation key for responder mode.");
        }

        if (!peerMlKem768PublicKey.IsEmpty &&
            peerMlKem768PublicKey.Length != MLKemAlgorithm.MLKem768.EncapsulationKeySizeInBytes)
        {
            throw new InvalidOperationException(
                $"Product PQC provider peer ML-KEM-768 public key must be {MLKemAlgorithm.MLKem768.EncapsulationKeySizeInBytes} bytes.");
        }

        if (!localMlKem768DecapsulationKey.IsEmpty &&
            localMlKem768DecapsulationKey.Length != MLKemAlgorithm.MLKem768.DecapsulationKeySizeInBytes)
        {
            throw new InvalidOperationException(
                $"Product PQC provider local ML-KEM-768 decapsulation key must be {MLKemAlgorithm.MLKem768.DecapsulationKeySizeInBytes} bytes.");
        }

        if (maxPendingHandshakes is < 1 or > 8)
        {
            throw new InvalidOperationException(
                "Product PQC provider max pending handshakes must be between 1 and 8.");
        }

        if (initiatorSuiteWireId is not (WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65 or
            WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65ForwardSecure or WebRtcProductHandshakeCodec.SuiteQPeriaptPolicyBound))
            throw new ArgumentOutOfRangeException(nameof(initiatorSuiteWireId), "Unsupported product PQC initiator suite.");

        if ((!peerQKey.IsEmpty && peerQKey.Length != QPeriaptKeyEncoding.PublicLength) ||
            (!localQKey.IsEmpty && localQKey.Length != QPeriaptKeyEncoding.PrivateLength) ||
            ((!peerQKey.IsEmpty || !localQKey.IsEmpty) && qSession is null) ||
            (initiatorSuiteWireId == WebRtcProductHandshakeCodec.SuiteQPeriaptPolicyBound && (qSession is null || peerQKey.IsEmpty)))
        { throw new ArgumentException("Policy-bound handshake options require a verified runtime session and exact Q key material."); }
        PlatformVersion = string.IsNullOrWhiteSpace(platformVersion)
            ? throw new InvalidOperationException("Product PQC provider platformVersion must not be empty.")
            : platformVersion.Trim();
        ProviderType = string.IsNullOrWhiteSpace(providerType)
            ? throw new InvalidOperationException("Product PQC provider providerType must not be empty.")
            : providerType.Trim();
        Policy = policy ?? new WebRtcProductHandshakePolicy(
            requirePqc: true,
            allowClassicFallback: false,
            minimumTier: initiatorSuiteWireId == WebRtcProductHandshakeCodec.SuiteQPeriaptPolicyBound ? "qperiaptPQC" : "nativePQC",
            requireSecureEnclavePoP: false);
        MaxPendingHandshakes = maxPendingHandshakes;
        if (initiatorExtensionsRaw.Length > 1024)
        {
            throw new InvalidOperationException("Product handshake initiator extensions exceed the supported size.");
        }
        InitiatorExtensionsRaw = initiatorExtensionsRaw.ToArray();
        InitiatorSuiteWireId = initiatorSuiteWireId;
        _ = new WebRtcProductCryptoCapabilities([], [], [], [], false, PlatformVersion, ProviderType);
        QSession = qSession;
        PeerQPublicKey = peerQKey.ToArray();
        _localQPeriaptPrivateKey = localQKey.ToArray();
        _localMlDsa65PrivateKey = localMlDsa65PrivateKey.ToArray();
        PeerMlKem768PublicKey = peerMlKem768PublicKey.ToArray();
        _localMlKem768DecapsulationKey = localMlKem768DecapsulationKey.ToArray();
    }

    public ReadOnlyMemory<byte> LocalMlDsa65PrivateKey => _localMlDsa65PrivateKey;

    public ReadOnlyMemory<byte> PeerMlKem768PublicKey { get; }

    public ReadOnlyMemory<byte> LocalMlKem768DecapsulationKey => _localMlKem768DecapsulationKey;

    public string PlatformVersion { get; }

    public string ProviderType { get; }

    public WebRtcProductHandshakePolicy Policy { get; }

    public int MaxPendingHandshakes { get; }

    public ReadOnlyMemory<byte> InitiatorExtensionsRaw { get; }
    public ushort InitiatorSuiteWireId { get; }

    internal QPeriaptRuntimeSession? QSession { get; }
    internal ReadOnlyMemory<byte> PeerQPublicKey { get; }
    internal ReadOnlyMemory<byte> LocalQPrivateKey => _localQPeriaptPrivateKey;

    internal void ClearLocalSecrets()
    {
        CryptographicOperations.ZeroMemory(_localQPeriaptPrivateKey);
        CryptographicOperations.ZeroMemory(_localMlDsa65PrivateKey);
        CryptographicOperations.ZeroMemory(_localMlKem768DecapsulationKey);
    }
}

public sealed partial class WebRtcProductPqcHandshakeCryptoProvider : IProductHandshakeCryptoProvider, IDisposable
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
    private readonly byte[] _initiatorExtensionsRaw;
    private readonly ushort _initiatorSuiteWireId;
    private readonly Dictionary<string, PendingInitiatorSecret> _pendingSecrets = new(StringComparer.Ordinal);
    private readonly byte[] _localMlKem768DecapsulationKey;
    private bool _disposed;

    public WebRtcProductPqcHandshakeCryptoProvider(WebRtcProductPqcHandshakeCryptoProviderOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        _qSession = options.QSession;
        _peerQPublicKey = options.PeerQPublicKey.ToArray();
        MLDsa? createdSigner = null;
        try
        {
            EnsurePlatformSupport();
            createdSigner = ImportIdentitySigner(options.LocalMlDsa65PrivateKey.Span);
            if (!options.LocalQPrivateKey.IsEmpty)
            { _localQKey = QPeriaptKeyEncoding.Import(RequireQSession(), options.LocalQPrivateKey.Span); }
            _identitySigner = createdSigner;
            _localMlKem768DecapsulationKey = options.LocalMlKem768DecapsulationKey.ToArray();
        }
        catch { createdSigner?.Dispose(); _localQKey?.Dispose(); throw; }
        finally
        {
            options.ClearLocalSecrets();
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
        _initiatorExtensionsRaw = options.InitiatorExtensionsRaw.ToArray();
        _initiatorSuiteWireId = options.InitiatorSuiteWireId;
    }

    public ValueTask<WebRtcProductHandshakeMessageA> CreateInitiatorMessageAAsync(
        ProductHandshakePeerContext context,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(context);
        cancellationToken.ThrowIfCancellationRequested();
        ThrowIfDisposed();

        if (_initiatorSuiteWireId == WebRtcProductHandshakeCodec.SuiteQPeriaptPolicyBound)
        {
            try { return CreatePolicyBoundMessageA(cancellationToken); }
            catch (Exception ex) when (ex is CryptographicException or WebRtcProductHandshakeCodecException)
            { throw new ProductHandshakeException($"Product PQC provider failed to create policy-bound MessageA: {ex.Message}", ex); }
        }

        if (_peerMlKem768PublicKey.Length != MLKemAlgorithm.MLKem768.EncapsulationKeySizeInBytes)
        {
            throw new ProductHandshakeException(
                "Product PQC provider initiator mode requires a peer ML-KEM-768 public key.");
        }

        var keyShare = new byte[MLKemAlgorithm.MLKem768.CiphertextSizeInBytes];
        var sharedSecret = new byte[MLKemAlgorithm.MLKem768.SharedSecretSizeInBytes];
        PendingInitiatorSecret? pending = null;
        try
        {
            using (var peerKem = MLKem.ImportEncapsulationKey(
                MLKemAlgorithm.MLKem768,
                _peerMlKem768PublicKey))
            {
                peerKem.Encapsulate(keyShare, sharedSecret);
            }

            pending = new PendingInitiatorSecret(keyShare, sharedSecret, _initiatorSuiteWireId);
            var clientNonce = RandomNumberGenerator.GetBytes(WebRtcProductHandshakeCodec.NonceLength);
            var contribution = pending.Contribution?.PublicKey ?? Array.Empty<byte>();
            var unsignedMessageA = BuildMessageA(keyShare, clientNonce, PlaceholderSignature, contribution);
            var signature = Sign(unsignedMessageA.SignaturePreimage());
            var messageA = BuildMessageA(keyShare, clientNonce, signature, contribution);
            var transcriptHashA = SHA256.HashData(messageA.EncodeWithoutSignature());
            AddPendingSecret(transcriptHashA, pending);
            pending = null; // The transcript-indexed pending store now owns its private contribution.
            return ValueTask.FromResult(messageA);
        }
        catch (Exception ex) when (ex is CryptographicException or WebRtcProductHandshakeCodecException)
        {
            throw new ProductHandshakeException(
                $"Product PQC provider failed to create initiator MessageA: {ex.Message}",
                ex);
        }
        finally
        {
            pending?.Dispose();
            CryptographicOperations.ZeroMemory(sharedSecret);
            CryptographicOperations.ZeroMemory(keyShare);
        }
    }

    public ValueTask<WebRtcProductHandshakeResponderMaterial> CreateResponderMessageBAsync(
        ProductHandshakePeerContext context,
        WebRtcProductHandshakeMessageA messageA,
        ReadOnlyMemory<byte> transcriptHashA,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(messageA);
        cancellationToken.ThrowIfCancellationRequested();
        ThrowIfDisposed();

        if (transcriptHashA.Length != WebRtcProductHandshakeCodec.TranscriptHashLength)
        {
            throw new ProductHandshakeException(
                "Product PQC provider requires a 32-byte transcriptHashA.");
        }

        if (_localMlKem768DecapsulationKey.Length != MLKemAlgorithm.MLKem768.DecapsulationKeySizeInBytes && _localQKey is null)
        {
            throw new ProductHandshakeException(
                "Product PQC provider responder mode requires a local ML-KEM-768 decapsulation key.");
        }

        var keyShare = Array.Empty<byte>();
        var sharedSecret = Array.Empty<byte>();
        byte[]? payload = null;
        byte[]? payloadKey = null;
        byte[]? ciphertext = null;
        byte[]? tag = null;
        try
        {
            var selectedSuite = ValidateInitiatorMessageA(context, messageA);
            keyShare = RequirePqcKeyShare(messageA, selectedSuite);
            if (selectedSuite == WebRtcProductHandshakeCodec.SuiteQPeriaptPolicyBound)
            { sharedSecret = DecapsulatePolicyBoundMessageA(messageA, keyShare, cancellationToken); }
            else
            {
                using var localKem = MLKem.ImportDecapsulationKey(MLKemAlgorithm.MLKem768, _localMlKem768DecapsulationKey);
                sharedSecret = localKem.Decapsulate(keyShare);
            }

            var responderShare = Array.Empty<byte>();
            if (selectedSuite == WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65ForwardSecure)
            {
                using var contribution = new ProductForwardSecretContribution();
                var ephemeralSecret = contribution.Derive(messageA.InitiatorContribution.Span);
                try
                {
                    var composed = ProductForwardSecretContribution.Compose(sharedSecret, ephemeralSecret,
                        transcriptHashA.Span, selectedSuite);
                    CryptographicOperations.ZeroMemory(sharedSecret);
                    sharedSecret = composed;
                    responderShare = contribution.PublicKey;
                }
                finally { CryptographicOperations.ZeroMemory(ephemeralSecret); }
            }

            payload = CreateCapabilities(selectedSuite).Encode();
            payloadKey = ProductHandshakeKeyDerivation.HkdfSha256(
                sharedSecret,
                transcriptHashA.Span,
                HandshakePayloadInfo,
                outputLength: 32);
            var nonce = RandomNumberGenerator.GetBytes(WebRtcProductHandshakeCodec.HpkeNonceLength);
            ciphertext = new byte[payload.Length];
            tag = new byte[WebRtcProductHandshakeCodec.HpkeTagLength];
            using (var aes = new AesGcm(payloadKey, WebRtcProductHandshakeCodec.HpkeTagLength))
            {
                aes.Encrypt(nonce, payload, ciphertext, tag);
            }

            var sealedBox = new WebRtcProductHpkeSealedBox(
                selectedSuite,
                Array.Empty<byte>(),
                nonce,
                ciphertext,
                tag);
            var serverNonce = RandomNumberGenerator.GetBytes(WebRtcProductHandshakeCodec.NonceLength);
            var unsignedMessageB = new WebRtcProductHandshakeMessageB(
                selectedSuiteWireId: selectedSuite,
                responderShare: responderShare,
                serverNonce: serverNonce,
                encryptedPayload: sealedBox,
                identityPublicKey: _localIdentityPublicKeyWire,
                signature: PlaceholderSignature);
            var signature = Sign(unsignedMessageB.SignaturePreimage(transcriptHashA.Span));
            var messageB = new WebRtcProductHandshakeMessageB(
                selectedSuiteWireId: unsignedMessageB.SelectedSuiteWireId,
                responderShare: unsignedMessageB.ResponderShare,
                serverNonce: unsignedMessageB.ServerNonce,
                encryptedPayload: unsignedMessageB.EncryptedPayload,
                identityPublicKey: unsignedMessageB.IdentityPublicKey,
                signature: signature);
            return ValueTask.FromResult(
                new WebRtcProductHandshakeResponderMaterial(messageB, sharedSecret));
        }
        catch (Exception ex) when (ex is CryptographicException or WebRtcProductHandshakeCodecException)
        {
            throw new ProductHandshakeException(
                $"Product PQC provider failed to authenticate MessageA or create responder MessageB: {ex.Message}",
                ex);
        }
        finally
        {
            if (keyShare.Length > 0)
            {
                CryptographicOperations.ZeroMemory(keyShare);
            }

            if (sharedSecret.Length > 0)
            {
                CryptographicOperations.ZeroMemory(sharedSecret);
            }

            if (payload is not null)
            {
                CryptographicOperations.ZeroMemory(payload);
            }

            if (payloadKey is not null)
            {
                CryptographicOperations.ZeroMemory(payloadKey);
            }

            if (ciphertext is not null)
            {
                CryptographicOperations.ZeroMemory(ciphertext);
            }

            if (tag is not null)
            {
                CryptographicOperations.ZeroMemory(tag);
            }
        }
    }

    public ValueTask<ProductHandshakeSharedSecret> OpenResponderMessageBAsync(
        ProductHandshakePeerContext context,
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
            throw new ProductHandshakeException(
                "Product PQC provider requires a 32-byte transcriptHashA.");
        }

        var pending = TakePendingSecret(transcriptHashA.Span);
        byte[]? plaintext = null;
        byte[]? payloadKey = null;
        byte[]? composedSecret = null;
        try
        {
            ValidateSelectedSuite(messageA, messageB, pending);
            var responderIdentity = WebRtcProductProtocolIdentityPublicKey.DecodeWithLegacyFallback(
                messageB.IdentityPublicKey.Span);
            ValidateResponderIdentity(context, responderIdentity);
            VerifyResponderSignature(responderIdentity, transcriptHashA.Span, messageB);

            if (pending.Contribution is { } contribution)
            {
                var ephemeral = contribution.Derive(messageB.ResponderShare.Span);
                try { composedSecret = ProductForwardSecretContribution.Compose(pending.SharedSecret, ephemeral, transcriptHashA.Span, pending.Suite); }
                finally { CryptographicOperations.ZeroMemory(ephemeral); }
            }
            var secret = composedSecret ?? pending.SharedSecret;

            payloadKey = ProductHandshakeKeyDerivation.HkdfSha256(
                secret,
                transcriptHashA.Span,
                HandshakePayloadInfo,
                outputLength: 32);
            plaintext = OpenResponderPayload(messageB.EncryptedPayload, payloadKey);
            var responderCapabilities = WebRtcProductCryptoCapabilities.Decode(plaintext);
            ValidateResponderCapabilities(responderCapabilities, pending.Suite);
            return ValueTask.FromResult(new ProductHandshakeSharedSecret(secret));
        }
        catch (Exception ex) when (ex is CryptographicException or WebRtcProductHandshakeCodecException)
        {
            throw new ProductHandshakeException(
                $"Product PQC provider failed to authenticate or open responder MessageB: {ex.Message}",
                ex);
        }
        finally
        {
            pending.Dispose();
            if (composedSecret is not null) CryptographicOperations.ZeroMemory(composedSecret);
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

    public void AbortInitiatorSecret(ReadOnlyMemory<byte> transcriptHashA)
    {
        if (transcriptHashA.Length != WebRtcProductHandshakeCodec.TranscriptHashLength)
        {
            throw new ProductHandshakeException(
                "Product PQC provider abort requires a 32-byte transcriptHashA.");
        }

        var key = FingerprintKey(transcriptHashA.Span);
        lock (_pendingGate)
        {
            ThrowIfDisposed();
            if (_pendingSecrets.Remove(key, out var pending))
            {
                pending.Dispose();
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
        CryptographicOperations.ZeroMemory(_localMlKem768DecapsulationKey);
        _localQKey?.Dispose();
    }

    private WebRtcProductHandshakeMessageA BuildMessageA(
        ReadOnlySpan<byte> keyShare,
        ReadOnlySpan<byte> clientNonce,
        ReadOnlySpan<byte> signature,
        ReadOnlyMemory<byte> contribution)
    {
        return new WebRtcProductHandshakeMessageA(
            supportedSuiteWireIds: new[] { _initiatorSuiteWireId },
            keyShares: new[]
            {
                new WebRtcProductHandshakeKeyShare(
                    _initiatorSuiteWireId,
                    keyShare.ToArray())
            },
            clientNonce: clientNonce.ToArray(),
            capabilities: CreateCapabilities(_initiatorSuiteWireId),
            policy: _policy,
            identityPublicKey: _localIdentityPublicKeyWire,
            extensionsRaw: _initiatorExtensionsRaw,
            signature: signature.ToArray(),
            initiatorContribution: contribution);
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
        PendingInitiatorSecret pending)
    {
        var key = FingerprintKey(transcriptHashA);
        lock (_pendingGate)
        {
            ThrowIfDisposed();
            if (_pendingSecrets.Count >= _maxPendingHandshakes)
            {
                throw new ProductHandshakeException(
                    "Product PQC provider pending handshake capacity is exhausted.");
            }

            if (_pendingSecrets.ContainsKey(key))
            {
                throw new ProductHandshakeException(
                    "Product PQC provider detected a duplicate transcriptHashA.");
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
                throw new ProductHandshakeException(
                    "Product PQC provider has no pending initiator secret for transcriptHashA.");
            }

            return pending;
        }
    }

    private static void ValidateSelectedSuite(
        WebRtcProductHandshakeMessageA messageA,
        WebRtcProductHandshakeMessageB messageB,
        PendingInitiatorSecret pending)
    {
        if (messageB.SelectedSuiteWireId != pending.Suite ||
            messageA.SupportedSuiteWireIds.Count != 1 || messageA.SupportedSuiteWireIds[0] != pending.Suite)
        {
            throw new WebRtcProductHandshakeCodecException(
                "The responder changed the required product PQC suite.");
        }

        if (!messageA.Policy.RequirePqc || messageA.Policy.AllowClassicFallback)
        {
            throw new WebRtcProductHandshakeCodecException(
                "Product PQC provider MessageA policy must require PQC without classic fallback.");
        }

        var expectedContributionLength = pending.Contribution is null ? 0 : 32;
        if (messageB.ResponderShare.Length != expectedContributionLength ||
            !messageB.EncryptedPayload.EncapsulatedKey.IsEmpty ||
            messageB.EncryptedPayload.SuiteWireId != pending.Suite)
        {
            throw new WebRtcProductHandshakeCodecException(
                "The responder's contribution or payload suite does not match the pending PQC handshake.");
        }

        if (!messageA.InitiatorContribution.Span.SequenceEqual(pending.Contribution?.PublicKey ?? Array.Empty<byte>()))
            throw new WebRtcProductHandshakeCodecException("MessageA changed the pending ephemeral contribution.");

        ReadOnlyMemory<byte>? offeredKeyShare = null;
        foreach (var keyShare in messageA.KeyShares)
        {
            if (keyShare.SuiteWireId == pending.Suite)
            {
                offeredKeyShare = keyShare.ShareBytes;
                break;
            }
        }

        if (!offeredKeyShare.HasValue ||
            !CryptographicOperations.FixedTimeEquals(offeredKeyShare.Value.Span, pending.KeyShare))
        {
            throw new WebRtcProductHandshakeCodecException(
                "Product PQC provider MessageA keyShare does not match the pending KEM ciphertext.");
        }
    }

    private static void ValidateResponderIdentity(
        ProductHandshakePeerContext context,
        WebRtcProductProtocolIdentityPublicKey responderIdentity)
    {
        if (responderIdentity.Algorithm != WebRtcProductSignatureAlgorithm.MlDsa65)
        {
            throw new WebRtcProductHandshakeCodecException(
                "Product PQC provider requires responder protocol identity algorithm ML-DSA-65.");
        }

        if (!string.Equals(
                responderIdentity.AuthoritativeFingerprint,
                context.PeerPublicKeyFingerprint,
                StringComparison.Ordinal))
        {
            throw new WebRtcProductHandshakeCodecException(
                "Product PQC provider responder authoritative fingerprint mismatch.");
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
                "Product PQC provider responder MessageB ML-DSA signature verification failed.");
        }
    }

    private ushort ValidateInitiatorMessageA(
        ProductHandshakePeerContext context,
        WebRtcProductHandshakeMessageA messageA)
    {
        var selectedSuite = messageA.SupportedSuiteWireIds.Contains(WebRtcProductHandshakeCodec.SuiteQPeriaptPolicyBound)
            ? WebRtcProductHandshakeCodec.SuiteQPeriaptPolicyBound
            : messageA.SupportedSuiteWireIds.Contains(WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65ForwardSecure)
                ? WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65ForwardSecure
                : WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65;
        if (selectedSuite == WebRtcProductHandshakeCodec.SuiteQPeriaptPolicyBound)
        {
            if (_localQKey is null) { throw new WebRtcProductHandshakeCodecException("No enrolled Q-Periapt responder identity is available."); }
            RequirePolicyBoundPolicy(messageA.Policy);
            QPeriaptPeerPlatform.RequireCapabilities(messageA.Capabilities, RequireQSession());
        }
        if (!messageA.SupportedSuiteWireIds.Contains(selectedSuite))
        {
            throw new WebRtcProductHandshakeCodecException(
                "Product PQC provider requires ML-KEM-768 + ML-DSA-65, with the v2 ephemeral contribution when offered.");
        }

        if (!messageA.Policy.RequirePqc || messageA.Policy.AllowClassicFallback)
        {
            throw new WebRtcProductHandshakeCodecException(
                "Product PQC provider responder mode requires MessageA policy to require PQC without classic fallback.");
        }

        var initiatorIdentity = WebRtcProductProtocolIdentityPublicKey.DecodeWithLegacyFallback(
            messageA.IdentityPublicKey.Span);
        if (initiatorIdentity.Algorithm != WebRtcProductSignatureAlgorithm.MlDsa65)
        {
            throw new WebRtcProductHandshakeCodecException(
                "Product PQC provider requires initiator protocol identity algorithm ML-DSA-65.");
        }

        if (!string.Equals(
                initiatorIdentity.AuthoritativeFingerprint,
                context.PeerPublicKeyFingerprint,
                StringComparison.Ordinal))
        {
            throw new WebRtcProductHandshakeCodecException(
                "Product PQC provider initiator authoritative fingerprint mismatch.");
        }

        using var verifier = MLDsa.ImportMLDsaPublicKey(
            MLDsaAlgorithm.MLDsa65,
            initiatorIdentity.PublicKey.Span);
        if (!verifier.VerifyData(messageA.SignaturePreimage(), messageA.Signature.Span, EmptyMldsaContext))
        {
            throw new WebRtcProductHandshakeCodecException(
                "Product PQC provider initiator MessageA ML-DSA signature verification failed.");
        }

        var initiatorCapabilities = messageA.Capabilities;
        if (!initiatorCapabilities.PqcAvailable ||
            !Contains(initiatorCapabilities.SupportedKem, selectedSuite == WebRtcProductHandshakeCodec.SuiteQPeriaptPolicyBound ? QPeriaptPeerPlatform.KemCapability : "ML-KEM-768") ||
            !Contains(initiatorCapabilities.SupportedSignature, "ML-DSA-65") ||
            !Contains(initiatorCapabilities.SupportedAead, "AES-256-GCM"))
        {
            throw new WebRtcProductHandshakeCodecException(
                "Product PQC initiator capabilities do not contain the negotiated PQC algorithms.");
        }
        return selectedSuite;
    }

    private static byte[] RequirePqcKeyShare(WebRtcProductHandshakeMessageA messageA, ushort selectedSuite = WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65)
    {
        foreach (var keyShare in messageA.KeyShares)
        {
            if (keyShare.SuiteWireId == selectedSuite)
            {
                return keyShare.ShareBytes.ToArray();
            }
        }

        throw new WebRtcProductHandshakeCodecException(
            "Product PQC provider expected a ML-KEM-768 MessageA keyShare.");
    }

    private static byte[] OpenResponderPayload(
        WebRtcProductHpkeSealedBox sealedBox,
        ReadOnlySpan<byte> payloadKey)
    {
        if (sealedBox.Nonce.Length != WebRtcProductHandshakeCodec.HpkeNonceLength ||
            sealedBox.Tag.Length != WebRtcProductHandshakeCodec.HpkeTagLength)
        {
            throw new WebRtcProductHandshakeCodecException(
                "Product PQC provider MessageB payload must use AES-256-GCM nonce and tag lengths.");
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

    private void ValidateResponderCapabilities(WebRtcProductCryptoCapabilities capabilities, ushort suite)
    {
        if (suite == WebRtcProductHandshakeCodec.SuiteQPeriaptPolicyBound)
        { QPeriaptPeerPlatform.RequireCapabilities(capabilities, RequireQSession()); return; }
        if (!capabilities.PqcAvailable ||
            !Contains(capabilities.SupportedKem, "ML-KEM-768") ||
            !Contains(capabilities.SupportedSignature, "ML-DSA-65") ||
            !Contains(capabilities.SupportedAead, "AES-256-GCM"))
        {
            throw new WebRtcProductHandshakeCodecException(
                "Product PQC responder capabilities do not contain the negotiated PQC algorithms.");
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
            $"Product PQC provider local ML-DSA-65 private key must be {MLDsaAlgorithm.MLDsa65.PrivateSeedSizeInBytes} byte seed or {MLDsaAlgorithm.MLDsa65.PrivateKeySizeInBytes} byte private key.");
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
            throw new ProductHandshakeException(
                "Product PQC provider transcriptHashA key must be exactly 32 bytes.");
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
        public PendingInitiatorSecret(ReadOnlySpan<byte> keyShare, ReadOnlySpan<byte> sharedSecret, ushort suite)
        {
            Suite = suite;
            KeyShare = keyShare.ToArray();
            SharedSecret = sharedSecret.ToArray();
            try
            {
                Contribution = suite == WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65ForwardSecure
                    ? new ProductForwardSecretContribution() : null;
            }
            catch { Dispose(); throw; }
        }

        public ushort Suite { get; }
        public ProductForwardSecretContribution? Contribution { get; }
        public byte[] KeyShare { get; }

        public byte[] SharedSecret { get; }

        public void Dispose()
        {
            Contribution?.Dispose();
            CryptographicOperations.ZeroMemory(KeyShare);
            CryptographicOperations.ZeroMemory(SharedSecret);
        }
    }
}
