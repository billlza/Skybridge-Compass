using System.Buffers.Binary;
using System.Security.Cryptography;

namespace Skybridge.WinClient.Services;

/// <summary>
/// The fixed ABI 2 primitive boundary. Policy enrollment, trusted-head persistence,
/// peer identity and handshake negotiation remain with their product owners.
/// Native calls are synchronous; cancellation discards their result, not their execution.
/// </summary>
internal static class QPeriaptNativeClient
{
    internal const int DecisionLength = 40;
    internal const int TrustedStateLength = 36;
    internal const int PolicySignatureLength = 3309;
    internal const int VerificationKeyLength = 1952;
    internal const int PrivatePqLength = 2400;
    internal const int PublicPqLength = 1184;
    internal const int CiphertextPqLength = 1088;
    internal const int TraditionalLength = 32;
    internal const int SecretLength = 32;
    internal const int MaximumContextLength = 65536;
    private const int MaximumPolicyLength = 65536;
    internal static void VerifyRuntime() => CoreBridge.VerifyQPeriaptRuntime();

    internal static QPeriaptPolicyDecision ResolvePolicy(
        ReadOnlySpan<byte> policy, ReadOnlySpan<byte> signature, ReadOnlySpan<byte> verificationKey,
        ReadOnlySpan<byte> pinnedVerificationKeySha256, ReadOnlySpan<byte> previousTrustedState,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (policy.IsEmpty || policy.Length > MaximumPolicyLength)
        {
            throw new ArgumentException("Signed policy must contain 1 through 65536 bytes.", nameof(policy));
        }
        RequireLength(signature, PolicySignatureLength, nameof(signature));
        RequireLength(verificationKey, VerificationKeyLength, nameof(verificationKey));
        RequireLength(pinnedVerificationKeySha256, 32, nameof(pinnedVerificationKeySha256));
        if (previousTrustedState.Length is not 0 and not TrustedStateLength)
        {
            throw new ArgumentException("Trusted policy state must be empty or 36 bytes.", nameof(previousTrustedState));
        }
        VerifyRuntime();
        var key = verificationKey.ToArray();
        var pin = pinnedVerificationKeySha256.ToArray();
        if (!CryptographicOperations.FixedTimeEquals(SHA256.HashData(key), pin))
        {
            throw new CryptographicException("Policy verification key does not match the independently provisioned trust root.");
        }
        var decision = new byte[DecisionLength];
        try
        {
            CheckStatus(CoreBridge.QPeriaptResolvePolicy(
                policy.ToArray(), signature.ToArray(), key, previousTrustedState.ToArray(), decision),
                "q_periapt_decision_from_signed_policy");
            cancellationToken.ThrowIfCancellationRequested();
            return new QPeriaptPolicyDecision(decision);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(decision);
        }
    }

    internal static QPeriaptKeyPair GenerateKeyPair(QPeriaptPolicyDecision decision,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(decision);
        cancellationToken.ThrowIfCancellationRequested();
        VerifyRuntime();
        byte[] privatePq = [], publicPq = [], privateTraditional = [], publicTraditional = [];
        var transferred = false;
        try
        {
            privatePq = new byte[PrivatePqLength];
            publicPq = new byte[PublicPqLength];
            privateTraditional = new byte[TraditionalLength];
            publicTraditional = new byte[TraditionalLength];
            CheckStatus(CoreBridge.QPeriaptGenerateKeyPair(decision.CopyEncoded(),
                privatePq, publicPq, privateTraditional, publicTraditional), "q_periapt_generate_keypair");
            cancellationToken.ThrowIfCancellationRequested();
            var result = new QPeriaptKeyPair(privatePq, publicPq, privateTraditional, publicTraditional);
            transferred = true;
            return result;
        }
        finally
        {
            if (!transferred)
            {
                CryptographicOperations.ZeroMemory(privatePq);
                CryptographicOperations.ZeroMemory(publicPq);
                CryptographicOperations.ZeroMemory(privateTraditional);
                CryptographicOperations.ZeroMemory(publicTraditional);
            }
        }
    }

    internal static QPeriaptEncapsulation Encapsulate(QPeriaptPolicyDecision decision,
        ReadOnlySpan<byte> publicPq, ReadOnlySpan<byte> publicTraditional, ReadOnlySpan<byte> applicationContext,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(decision);
        cancellationToken.ThrowIfCancellationRequested();
        RequireLength(publicPq, PublicPqLength, nameof(publicPq));
        RequireLength(publicTraditional, TraditionalLength, nameof(publicTraditional));
        RequireContext(applicationContext);
        VerifyRuntime();
        var context = applicationContext.ToArray();
        byte[] ciphertextPq = [], ciphertextTraditional = [], secret = [];
        ProductHandshakeSharedSecret? ownedSecret = null;
        try
        {
            ciphertextPq = new byte[CiphertextPqLength];
            ciphertextTraditional = new byte[TraditionalLength];
            secret = new byte[SecretLength];
            CheckStatus(CoreBridge.QPeriaptEncapsulate(decision.CopyEncoded(),
                publicPq.ToArray(), publicTraditional.ToArray(), context, ciphertextPq, ciphertextTraditional, secret),
                "q_periapt_encapsulate");
            ownedSecret = TakeSecret(secret, cancellationToken);
            var result = new QPeriaptEncapsulation(ciphertextPq, ciphertextTraditional, ownedSecret);
            ownedSecret = null;
            return result;
        }
        finally
        {
            ownedSecret?.Dispose();
            CryptographicOperations.ZeroMemory(secret);
            CryptographicOperations.ZeroMemory(context);
        }
    }

    internal static ProductHandshakeSharedSecret Decapsulate(QPeriaptPolicyDecision decision,
        QPeriaptKeyPair keyPair, ReadOnlySpan<byte> ciphertextPq, ReadOnlySpan<byte> ciphertextTraditional,
        ReadOnlySpan<byte> applicationContext, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(decision);
        ArgumentNullException.ThrowIfNull(keyPair);
        cancellationToken.ThrowIfCancellationRequested();
        RequireLength(ciphertextPq, CiphertextPqLength, nameof(ciphertextPq));
        RequireLength(ciphertextTraditional, TraditionalLength, nameof(ciphertextTraditional));
        RequireContext(applicationContext);
        VerifyRuntime();
        using var keys = keyPair.Capture();
        var context = applicationContext.ToArray();
        byte[] secret = [];
        try
        {
            secret = new byte[SecretLength];
            CheckStatus(CoreBridge.QPeriaptDecapsulate(decision.CopyEncoded(), keys.PrivatePq,
                ciphertextPq.ToArray(), keys.PublicPq, keys.PrivateTraditional, ciphertextTraditional.ToArray(),
                keys.PublicTraditional, context, secret), "q_periapt_decapsulate");
            // A retired key owner cannot publish a late result. Only this short commit
            // holds its gate; native computation and cancellation waits never do.
            return keyPair.CommitSecret(secret, cancellationToken);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(secret);
            CryptographicOperations.ZeroMemory(context);
        }
    }

    internal static ProductHandshakeSharedSecret TakeSecret(byte[] nativeOutput, CancellationToken cancellationToken)
    {
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            return new ProductHandshakeSharedSecret(nativeOutput);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(nativeOutput);
        }
    }

    internal static void CheckStatus(int code, string operation)
    {
        if (code == 0) { return; }
        var expectedName = CoreBridge.QPeriaptStatusText(code);
        throw new QPeriaptNativeException(operation, code, expectedName);
    }

    private static void RequireLength(ReadOnlySpan<byte> value, int length, string parameter)
    {
        if (value.Length != length) { throw new ArgumentException($"Expected exactly {length} bytes.", parameter); }
    }

    private static void RequireContext(ReadOnlySpan<byte> context)
    {
        if (context.Length > MaximumContextLength)
        {
            throw new ArgumentException("Application context cannot exceed 65536 bytes.", nameof(context));
        }
    }
}

/// <summary>A copied, authenticated ABI 2 value, not a native handle or product session authority.</summary>
internal sealed class QPeriaptPolicyDecision
{
    private readonly byte[] _encoded;

    internal QPeriaptPolicyDecision(ReadOnlySpan<byte> encoded)
    {
        if (encoded.Length != QPeriaptNativeClient.DecisionLength ||
            !encoded[..4].SequenceEqual<byte>([1, 1, 2, 1]) || BinaryPrimitives.ReadUInt32BigEndian(encoded[4..8]) == 0)
        {
            throw new CryptographicException("Native Q-Periapt returned an invalid fixed-suite policy decision.");
        }
        _encoded = encoded.ToArray();
    }

    internal uint PolicyVersion => BinaryPrimitives.ReadUInt32BigEndian(_encoded.AsSpan(4, 4));
    internal byte[] CopyTrustedState() => _encoded.AsSpan(4).ToArray();
    internal byte[] CopyPolicyDigestSha3_256() => _encoded.AsSpan(8).ToArray();
    internal byte[] CopyEncoded() => (byte[])_encoded.Clone();
}

/// <summary>Owns one key pair. Dispose revokes new snapshots and any late result publication.</summary>
internal sealed class QPeriaptKeyPair : IDisposable
{
    private readonly object _gate = new();
    private readonly KeyMaterial _material;
    private bool _disposed;

    internal QPeriaptKeyPair(byte[] privatePq, byte[] publicPq, byte[] privateTraditional, byte[] publicTraditional)
    {
        _material = new KeyMaterial(privatePq, publicPq, privateTraditional, publicTraditional);
    }

    internal byte[] CopyPublicPq() { lock (_gate) { ThrowIfDisposed(); return (byte[])_material.PublicPq.Clone(); } }
    internal byte[] CopyPublicTraditional() { lock (_gate) { ThrowIfDisposed(); return (byte[])_material.PublicTraditional.Clone(); } }

    internal KeyMaterial Capture()
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            byte[] privatePq = [], publicPq = [], privateTraditional = [], publicTraditional = [];
            try
            {
                privatePq = (byte[])_material.PrivatePq.Clone();
                publicPq = (byte[])_material.PublicPq.Clone();
                privateTraditional = (byte[])_material.PrivateTraditional.Clone();
                publicTraditional = (byte[])_material.PublicTraditional.Clone();
                return new KeyMaterial(privatePq, publicPq, privateTraditional, publicTraditional);
            }
            catch
            {
                CryptographicOperations.ZeroMemory(privatePq);
                CryptographicOperations.ZeroMemory(publicPq);
                CryptographicOperations.ZeroMemory(privateTraditional);
                CryptographicOperations.ZeroMemory(publicTraditional);
                throw;
            }
        }
    }

    internal ProductHandshakeSharedSecret CommitSecret(byte[] secret, CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            try
            {
                ThrowIfDisposed();
                return QPeriaptNativeClient.TakeSecret(secret, cancellationToken);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(secret);
            }
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) { return; }
            _disposed = true;
            _material.Dispose();
        }
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    internal sealed class KeyMaterial(byte[] privatePq, byte[] publicPq, byte[] privateTraditional, byte[] publicTraditional) : IDisposable
    {
        internal byte[] PrivatePq { get; } = privatePq;
        internal byte[] PublicPq { get; } = publicPq;
        internal byte[] PrivateTraditional { get; } = privateTraditional;
        internal byte[] PublicTraditional { get; } = publicTraditional;

        public void Dispose()
        {
            CryptographicOperations.ZeroMemory(PrivatePq);
            CryptographicOperations.ZeroMemory(PublicPq);
            CryptographicOperations.ZeroMemory(PrivateTraditional);
            CryptographicOperations.ZeroMemory(PublicTraditional);
        }
    }
}

internal sealed class QPeriaptEncapsulation(byte[] ciphertextPq, byte[] ciphertextTraditional,
    ProductHandshakeSharedSecret secret) : IDisposable
{
    private bool _disposed;
    internal ReadOnlyMemory<byte> CiphertextPq { get { ThrowIfDisposed(); return ciphertextPq; } }
    internal ReadOnlyMemory<byte> CiphertextTraditional { get { ThrowIfDisposed(); return ciphertextTraditional; } }
    internal ProductHandshakeSharedSecret Secret { get { ThrowIfDisposed(); return secret; } }

    public void Dispose()
    {
        if (_disposed) { return; }
        _disposed = true;
        secret.Dispose();
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);
}

internal sealed class QPeriaptNativeException(string operation, int statusCode, string statusName)
    : CryptographicException($"{operation} failed: {statusName} ({statusCode}).")
{
    internal string Operation { get; } = operation;
    internal int StatusCode { get; } = statusCode;
    internal string StatusName { get; } = statusName;
}
