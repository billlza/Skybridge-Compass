using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services.RemoteControl;

/// <summary>Owns the host identity and explicitly imported authorities. DPAPI protects private keys and the authorization list together.</summary>
public sealed partial class RemoteControlIdentityStore : IDisposable
{
    private const int MaximumStoredBytes = 1_048_576;
    private const int MaximumTrustedPeers = 64;
    private static readonly JsonSerializerOptions PersistenceJson = new()
    {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        RespectRequiredConstructorParameters = true
    };
    private readonly object _gate = new();
    private readonly string _directory;
    private readonly string _path;
    private readonly FileStream _fileLease;
    private readonly ISessionProtector _protector;
    private readonly ISessionFileCommitter _committer;
    private readonly byte[] _signingPrivateKey;
    private readonly byte[] _kemDecapsulationKey;
    private readonly List<RemoteControlPairingMaterial> _trusted;
    private bool _disposed;

    private RemoteControlIdentityStore(string directory, FileStream fileLease, ISessionProtector protector,
        ISessionFileCommitter committer, IdentityDocument document)
    {
        _directory = directory;
        _path = Path.Combine(directory, "remote-control-identity.bin");
        _fileLease = fileLease;
        _protector = protector;
        _committer = committer;
        _signingPrivateKey = document.SigningPrivateKey;
        _kemDecapsulationKey = document.KemDecapsulationKey;
        PublicMaterial = ValidateLocalIdentity(document.DeviceId, document.DeviceName, _signingPrivateKey, _kemDecapsulationKey);
        _trusted = ReadTrustedMaterials(document, PublicMaterial);
    }

    private static List<RemoteControlPairingMaterial> ReadTrustedMaterials(IdentityDocument document, RemoteControlPairingMaterial local)
    {
        var trusted = new List<RemoteControlPairingMaterial>();
        if (document.TrustedMaterials.Length > MaximumTrustedPeers)
        { throw new InvalidDataException("Stored remote-control trust exceeds the peer limit."); }
        foreach (var json in document.TrustedMaterials)
        {
            var material = RemoteControlPairingMaterial.Parse(json);
            if (CheckImport(material, local, trusted)) { trusted.Add(material); }
            else { throw new InvalidDataException("Stored remote-control trust contains duplicate records."); }
        }
        return trusted;
    }

    public RemoteControlPairingMaterial PublicMaterial { get; private set; }

    public IReadOnlyList<RemoteControlPairingMaterial> TrustedMaterials
    {
        get { lock (_gate) { ThrowIfDisposed(); return _trusted.ToArray(); } }
    }

    public IReadOnlyCollection<RemoteControlTrustedPeer> TrustedPeers
    {
        get
        {
            lock (_gate)
            {
                ThrowIfDisposed();
                return _trusted.Select(peer => new RemoteControlTrustedPeer(peer.DeviceId, peer.ProtocolPublicKeyFingerprint)).ToArray();
            }
        }
    }

    public static Task<RemoteControlIdentityStore> LoadOrCreateAsync(string stateDirectory, string displayName,
        CancellationToken cancellationToken = default, ISessionProtector? protector = null) =>
        LoadOrCreateAsync(stateDirectory, displayName, protector ?? new DpapiSessionProtector(),
            AtomicSessionFileCommitter.Instance, cancellationToken);

    internal static Task<RemoteControlIdentityStore> LoadOrCreateAsync(string stateDirectory, string displayName,
        ISessionProtector protector, ISessionFileCommitter committer, CancellationToken cancellationToken = default) =>
        Task.Run(() => LoadOrCreate(stateDirectory, displayName, protector, committer, cancellationToken), cancellationToken);

    private static RemoteControlIdentityStore LoadOrCreate(string stateDirectory, string displayName,
        ISessionProtector protector, ISessionFileCommitter committer, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(stateDirectory);
        ArgumentException.ThrowIfNullOrWhiteSpace(displayName);
        ArgumentNullException.ThrowIfNull(protector);
        ArgumentNullException.ThrowIfNull(committer);
        RequireNativePqc();
        cancellationToken.ThrowIfCancellationRequested();
        var directory = Path.GetFullPath(stateDirectory);
        Directory.CreateDirectory(directory);
        RejectLink(directory);
        var lockPath = Path.Combine(directory, ".remote-control-identity.lock");
        RejectLinkIfPresent(lockPath);
        var lease = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        IdentityDocument? document = null;
        byte[] protectedPreimage = [];
        var transferred = false;
        try
        {
            var path = Path.Combine(directory, "remote-control-identity.bin");
            RejectLinkIfPresent(path);
            var created = false;
            try { document = ReadDocument(path, protector, out protectedPreimage); }
            catch (FileNotFoundException)
            {
                cancellationToken.ThrowIfCancellationRequested();
                document = CreateDocument(displayName);
                created = true;
            }
            ValidateDocumentSchema(document);
            cancellationToken.ThrowIfCancellationRequested();
            var store = new RemoteControlIdentityStore(directory, lease, protector, committer, document);
            try
            {
                store.PreparePolicyBoundIdentity(document, created, protectedPreimage, cancellationToken);
                transferred = true;
                return store;
            }
            catch
            {
                store.Dispose();
                throw;
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(protectedPreimage);
            if (document?.QPeriaptPrivateKey is not null) { CryptographicOperations.ZeroMemory(document.QPeriaptPrivateKey); }
            if (!transferred)
            {
                lease.Dispose();
                if (document?.SigningPrivateKey is not null) { CryptographicOperations.ZeroMemory(document.SigningPrivateKey); }
                if (document?.KemDecapsulationKey is not null) { CryptographicOperations.ZeroMemory(document.KemDecapsulationKey); }
            }
        }
    }

    public WebRtcProductPqcHandshakeCryptoProvider CreateCryptoProvider()
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            var session = RequirePolicySession();
            var expanded = QPeriaptKeyEncoding.ExportPrivate(RequirePolicyKey());
            try
            {
                return new WebRtcProductPqcHandshakeCryptoProvider(new WebRtcProductPqcHandshakeCryptoProviderOptions(
                    _signingPrivateKey, ReadOnlyMemory<byte>.Empty, _kemDecapsulationKey, session,
                    ReadOnlyMemory<byte>.Empty, expanded));
            }
            finally { CryptographicOperations.ZeroMemory(expanded); }
        }
    }

    internal WebRtcProductPqcHandshakeCryptoProvider CreateInitiatorCryptoProvider(string peerDeviceId, string fingerprint)
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            var canonical = RemoteControlHandshakeBinding.CanonicalDeviceId(peerDeviceId);
            var peer = _trusted.SingleOrDefault(item => item.DeviceId == canonical &&
                item.ProtocolPublicKeyFingerprint == fingerprint)
                ?? throw new InvalidOperationException("The selected device does not match a paired protocol identity.");
            var soa = new RemoteControlHandshakeSoa(RemoteControlHandshakeBinding.PeerId(PublicMaterial.DeviceId),
                RemoteControlHandshakeBinding.PeerId(peer.DeviceId), RandomNumberGenerator.GetBytes(16));
            if (peer.HasQPeriaptKey)
            {
                return new WebRtcProductPqcHandshakeCryptoProvider(new WebRtcProductPqcHandshakeCryptoProviderOptions(
                    _signingPrivateKey, peer.MlKem768PublicKey, ReadOnlyMemory<byte>.Empty, RequirePolicySession(),
                    peer.QPeriaptPublicKey, ReadOnlyMemory<byte>.Empty, soa.EncodeTlv(), WebRtcProductHandshakeCodec.SuiteQPeriaptPolicyBound));
            }
            return new WebRtcProductPqcHandshakeCryptoProvider(new WebRtcProductPqcHandshakeCryptoProviderOptions(
                _signingPrivateKey, peer.MlKem768PublicKey, initiatorExtensionsRaw: soa.EncodeTlv(),
                initiatorSuiteWireId: WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65ForwardSecure));
        }
    }

    /// <summary>Must be invoked only for an explicit user import. The returned change is published after durable commit.</summary>
    public Task<bool> ImportTrustedPeerAsync(RemoteControlPairingMaterial material, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(material);
        return Task.Run(() =>
        {
            lock (_gate)
            {
                ThrowIfDisposed();
                cancellationToken.ThrowIfCancellationRequested();
                var upgradeIndex = _trusted.FindIndex(peer => peer.CanAddPolicyBoundKey(material));
                if (upgradeIndex >= 0)
                {
                    var upgraded = new List<RemoteControlPairingMaterial>(_trusted);
                    upgraded[upgradeIndex] = material;
                    Persist(upgraded, cancellationToken);
                    _trusted[upgradeIndex] = material;
                    return true;
                }
                if (!CheckImport(material)) { return false; }
                if (_trusted.Count >= MaximumTrustedPeers) { throw new InvalidOperationException("The remote-control trusted peer limit is reached."); }
                var replacement = new List<RemoteControlPairingMaterial>(_trusted) { material };
                Persist(replacement, cancellationToken);
                _trusted.Add(material);
                return true;
            }
        }, cancellationToken);
    }

    private bool CheckImport(RemoteControlPairingMaterial material) => CheckImport(material, PublicMaterial, _trusted);

    private static bool CheckImport(RemoteControlPairingMaterial material, RemoteControlPairingMaterial local,
        IReadOnlyCollection<RemoteControlPairingMaterial> trusted)
    {
        if (material.DeviceId == local.DeviceId || material.ProtocolPublicKeyFingerprint == local.ProtocolPublicKeyFingerprint)
        { throw new InvalidDataException("The local host identity cannot authorize itself as a remote controller."); }
        foreach (var existing in trusted)
        {
            if (existing.DeviceId == material.DeviceId || existing.ProtocolPublicKeyFingerprint == material.ProtocolPublicKeyFingerprint)
            {
                if (existing.HasSameAuthority(material)) { return false; }
                throw new InvalidDataException("Pairing material conflicts with an already trusted device identity or public key.");
            }
        }
        return true;
    }

    private void Persist(IReadOnlyCollection<RemoteControlPairingMaterial> trusted, CancellationToken cancellationToken)
    {
        var expanded = QPeriaptKeyEncoding.ExportPrivate(RequirePolicyKey());
        var document = new IdentityDocument(2, PublicMaterial.DeviceId, PublicMaterial.DeviceName,
            _signingPrivateKey, _kemDecapsulationKey, trusted.Select(peer => peer.ToJson()).ToArray(), expanded, true);
        byte[] plaintext;
        try { plaintext = JsonSerializer.SerializeToUtf8Bytes(document, PersistenceJson); }
        finally { CryptographicOperations.ZeroMemory(expanded); }
        byte[]? encrypted = null;
        string? temporaryPath = null;
        try
        {
            encrypted = _protector.Protect(plaintext);
            if (encrypted.Length == 0 || encrypted.Length > MaximumStoredBytes)
            { throw new InvalidDataException("Protected remote-control identity exceeds the stored size limit."); }
            cancellationToken.ThrowIfCancellationRequested();
            temporaryPath = Path.Combine(_directory, $".remote-control-identity.{Guid.NewGuid():N}.tmp");
            using (var output = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                4096, FileOptions.WriteThrough))
            {
                output.Write(encrypted);
                output.Flush(flushToDisk: true);
            }
            cancellationToken.ThrowIfCancellationRequested();
            _committer.Commit(temporaryPath, _path);
            temporaryPath = null;
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or CryptographicException or OperationCanceledException)
        {
            if (temporaryPath is not null)
            {
                try { File.Delete(temporaryPath); }
                catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException)
                { throw new AggregateException("Remote-control identity commit and temporary-file cleanup failed.", failure, cleanup); }
            }
            throw;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
            if (encrypted is not null) { CryptographicOperations.ZeroMemory(encrypted); }
        }
    }

    private static IdentityDocument ReadDocument(string path, ISessionProtector protector, out byte[] protectedPreimage)
    {
        protectedPreimage = [];
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length is <= 0 or > MaximumStoredBytes) { throw new InvalidDataException("Stored remote-control identity has an invalid size."); }
        var encrypted = new byte[(int)stream.Length];
        stream.ReadExactly(encrypted);
        byte[]? plaintext = null;
        try
        {
            plaintext = protector.Unprotect(encrypted);
            if (plaintext.Length is <= 0 or > MaximumStoredBytes) { throw new InvalidDataException("Unprotected remote-control identity has an invalid size."); }
            var document = JsonSerializer.Deserialize<IdentityDocument>(plaintext, PersistenceJson)
                ?? throw new InvalidDataException("Stored remote-control identity is empty.");
            protectedPreimage = (byte[])encrypted.Clone();
            return document;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(encrypted);
            if (plaintext is not null) { CryptographicOperations.ZeroMemory(plaintext); }
        }
    }

    private static IdentityDocument CreateDocument(string displayName)
    {
        using var signing = MLDsa.GenerateKey(MLDsaAlgorithm.MLDsa65);
        using var kem = MLKem.GenerateKey(MLKemAlgorithm.MLKem768);
        return new IdentityDocument(1, "id:" + Guid.NewGuid().ToString("D"), displayName,
            signing.ExportMLDsaPrivateKey(), kem.ExportDecapsulationKey(), []);
    }

    private static RemoteControlPairingMaterial ValidateLocalIdentity(string deviceId, string deviceName,
        byte[] signingPrivateKey, byte[] kemDecapsulationKey)
    {
        using var signer = MLDsa.ImportMLDsaPrivateKey(MLDsaAlgorithm.MLDsa65, signingPrivateKey);
        using var kem = MLKem.ImportDecapsulationKey(MLKemAlgorithm.MLKem768, kemDecapsulationKey);
        var publicSigningKey = signer.ExportMLDsaPublicKey();
        var publicKemKey = kem.ExportEncapsulationKey();
        using var verifier = MLDsa.ImportMLDsaPublicKey(MLDsaAlgorithm.MLDsa65, publicSigningKey);
        var challenge = "SkyBridge-Identity-Storage-Check"u8.ToArray();
        var signature = signer.SignData(challenge);
        if (!verifier.VerifyData(challenge, signature))
        { throw new CryptographicException("Stored protocol signing identity does not verify its own public key."); }
        using var encapsulator = MLKem.ImportEncapsulationKey(MLKemAlgorithm.MLKem768, publicKemKey);
        encapsulator.Encapsulate(out var ciphertext, out var secret);
        byte[]? recovered = null;
        try
        {
            recovered = kem.Decapsulate(ciphertext);
            if (!CryptographicOperations.FixedTimeEquals(secret, recovered))
            { throw new CryptographicException("Stored KEM identity does not match its public key."); }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(secret);
            if (recovered is not null) { CryptographicOperations.ZeroMemory(recovered); }
        }
        return RemoteControlPairingMaterial.Create(deviceId, deviceName, publicSigningKey, publicKemKey);
    }

    private static void RequireNativePqc()
    {
        if (!MLDsa.IsSupported || !MLKem.IsSupported)
        { throw new PlatformNotSupportedException("Remote-control identity requires native ML-DSA-65 and ML-KEM-768 support."); }
    }

    private static void RejectLinkIfPresent(string path)
    {
        try { RejectLink(path); }
        catch (FileNotFoundException) { return; }
    }

    private static void RejectLink(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        { throw new IOException("Remote-control identity storage must not use a filesystem link."); }
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) { return; }
            CryptographicOperations.ZeroMemory(_signingPrivateKey);
            CryptographicOperations.ZeroMemory(_kemDecapsulationKey);
            _qKey?.Dispose();
            _disposed = true;
            _fileLease.Dispose();
        }
    }

    private sealed record IdentityDocument(int SchemaVersion, string DeviceId, string DeviceName,
        byte[] SigningPrivateKey, byte[] KemDecapsulationKey, string[] TrustedMaterials,
        byte[]? QPeriaptPrivateKey = null, bool QPeriaptEnrolled = false);
}
