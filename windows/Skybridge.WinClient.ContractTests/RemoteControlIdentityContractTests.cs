using System;
using System.IO;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.Services.RemoteControl;

namespace Skybridge.WinClient.ContractTests;

public static class RemoteControlIdentityContractTests
{
    public static async Task<int> RunAsync(bool requireNativePqc = false)
    {
        var count = 0;
        void Require(bool condition, string name) { if (!condition) { throw new InvalidOperationException(name); } count++; }
        void Reject<T>(Action action, string name) where T : Exception
        {
            try { action(); } catch (T) { count++; return; }
            throw new InvalidOperationException(name + ": expected " + typeof(T).Name);
        }
        async Task RejectAsync<T>(Func<Task> action, string name) where T : Exception
        {
            try { await action().ConfigureAwait(false); } catch (T) { count++; return; }
            throw new InvalidOperationException(name + ": expected " + typeof(T).Name);
        }
        const string peerId = "id:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
        var peer = RemoteControlPairingMaterial.Create(peerId, "Controller", new byte[1952], new byte[1184]);
        var json = peer.ToJson();
        var parsed = RemoteControlPairingMaterial.Parse(json);
        Require(parsed.DeviceId == peerId && parsed.ProtocolPublicKeyFingerprint == peer.ProtocolPublicKeyFingerprint, "pairing round trip preserves authority");
        Require(parsed.IdentityPublicKeyWire.Length == 1956, "pairing exports algorithm-tagged identity wire");
        Require(WebRtcProductProtocolIdentityPublicKey.DecodeWithLegacyFallback(parsed.IdentityPublicKeyWire).SecureEnclavePublicKey is null,
            "absent Secure Enclave key stays absent on the wire");
        Reject<InvalidDataException>(() => RemoteControlPairingMaterial.Parse(json.Replace(peer.ProtocolPublicKeyFingerprint, new string('a', 64))), "tampered fingerprint");
        Reject<InvalidDataException>(() => RemoteControlPairingMaterial.Parse(json.Replace("ML-DSA-65", "Ed25519")), "unsupported algorithm");
        Reject<InvalidDataException>(() => RemoteControlPairingMaterial.Parse(json.Replace("\"schemaVersion\": 1", "\"schemaVersion\": \"1\"")), "schema field type");
        Reject<InvalidDataException>(() => RemoteControlPairingMaterial.Parse(json.Replace("257", "258")), "unsupported KEM suite");
        Reject<InvalidDataException>(() => RemoteControlPairingMaterial.Parse(json.Replace("\"schemaVersion\": 1", "\"schemaVersion\": 1, \"schemaVersion\": 1")), "duplicate JSON field");
        Reject<InvalidDataException>(() => RemoteControlPairingMaterial.Parse(json.Replace("\"schemaVersion\": 1", "\"unknown\": true, \"schemaVersion\": 1")), "unknown JSON field");
        Reject<InvalidDataException>(() => RemoteControlPairingMaterial.Create("192.168.0.103", "Peer", new byte[1952], new byte[1184]), "address cannot be authority");
        Reject<InvalidDataException>(() => RemoteControlPairingMaterial.Create(peerId, "Peer\nInjected", new byte[1952], new byte[1184]), "control characters in name");
        Reject<WebRtcProductHandshakeCodecException>(() => RemoteControlPairingMaterial.Create(peerId, "Peer", new byte[32], new byte[1184]), "wrong protocol public key length");
        Reject<InvalidDataException>(() => RemoteControlPairingMaterial.Create(peerId, "Peer", new byte[1952], new byte[32]), "wrong KEM public key length");

        if (!MLDsa.IsSupported || !MLKem.IsSupported || !OperatingSystem.IsWindows())
        {
            if (requireNativePqc) { throw new PlatformNotSupportedException("Identity persistence acceptance requires Windows DPAPI and native PQC."); }
            await RejectAsync<PlatformNotSupportedException>(async () =>
            {
                using var store = await RemoteControlIdentityStore.LoadOrCreateAsync(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N")), "Unsupported").ConfigureAwait(false);
            }, "unsupported identity provider fails closed").ConfigureAwait(false);
            return count;
        }

        var directory = Path.Combine(Path.GetTempPath(), "skybridge-remote-identity-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var protector = new RecordingProtector();
            var committer = new SwitchableCommitter();
            string localId;
            string localFingerprint;
            using (var store = await RemoteControlIdentityStore.LoadOrCreateAsync(directory, "Windows test host", protector, committer).ConfigureAwait(false))
            {
                localId = store.PublicMaterial.DeviceId;
                localFingerprint = store.PublicMaterial.ProtocolPublicKeyFingerprint;
                Require(store.TrustedPeers.Count == 0, "new identity authorizes no peers");
                Require(protector.LastPlaintext is not null && AllZero(protector.LastPlaintext), "serialized private identity cleared after protection");
                using var provider = store.CreateCryptoProvider();
                Require(await store.ImportTrustedPeerAsync(peer).ConfigureAwait(false), "explicit import commits a peer");
                Require(!await store.ImportTrustedPeerAsync(parsed).ConfigureAwait(false), "equivalent import is idempotent");
                Require(store.TrustedPeers.Count == 1, "one committed authority visible");
                var differentPublic = new byte[1952]; differentPublic[0] = 1;
                var conflicting = RemoteControlPairingMaterial.Create(peerId, "Conflict", differentPublic, new byte[1184]);
                await RejectAsync<InvalidDataException>(() => store.ImportTrustedPeerAsync(conflicting), "same device cannot replace protocol key").ConfigureAwait(false);
                var alias = RemoteControlPairingMaterial.Create("id:cccccccc-cccc-cccc-cccc-cccccccccccc", "Alias", new byte[1952], new byte[1184]);
                await RejectAsync<InvalidDataException>(() => store.ImportTrustedPeerAsync(alias), "same key cannot impersonate another device").ConfigureAwait(false);
                var differentKem = new byte[1184]; differentKem[0] = 1;
                var kemConflict = RemoteControlPairingMaterial.Create(peerId, "Conflict", new byte[1952], differentKem);
                await RejectAsync<InvalidDataException>(() => store.ImportTrustedPeerAsync(kemConflict), "same authority cannot silently replace KEM key").ConfigureAwait(false);
                var newPeer = RemoteControlPairingMaterial.Create("id:dddddddd-dddd-dddd-dddd-dddddddddddd", "Second", differentPublic, new byte[1184]);
                var priorBytes = await File.ReadAllBytesAsync(Path.Combine(directory, "remote-control-identity.bin")).ConfigureAwait(false);
                committer.FailNext = true;
                await RejectAsync<IOException>(() => store.ImportTrustedPeerAsync(newPeer), "failed atomic commit is visible").ConfigureAwait(false);
                Require(store.TrustedPeers.Count == 1, "failed commit does not publish authorization");
                var afterFailedCommit = await File.ReadAllBytesAsync(Path.Combine(directory, "remote-control-identity.bin")).ConfigureAwait(false);
                Require(priorBytes.AsSpan().SequenceEqual(afterFailedCommit), "failed commit preserves previous ciphertext");
                Require(Directory.GetFiles(directory, "*.tmp").Length == 0, "failed ciphertext staging is cleaned");
                using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
                await RejectAsync<OperationCanceledException>(() => store.ImportTrustedPeerAsync(newPeer, cancelled.Token), "cancelled import does not commit").ConfigureAwait(false);
                await RejectAsync<IOException>(async () =>
                {
                    using var competing = await RemoteControlIdentityStore.LoadOrCreateAsync(directory, "Other", protector: protector).ConfigureAwait(false);
                }, "concurrent process owner cannot overwrite identity").ConfigureAwait(false);
            }
            using (var reopened = await RemoteControlIdentityStore.LoadOrCreateAsync(directory, "Windows test host", protector: protector).ConfigureAwait(false))
            {
                Require(reopened.PublicMaterial.DeviceId == localId && reopened.PublicMaterial.ProtocolPublicKeyFingerprint == localFingerprint,
                    "restart preserves real protocol identity");
                Require(reopened.TrustedPeers.Count == 1, "restart preserves committed peer and excludes failed import");
                Require(protector.LastUnprotected is not null && AllZero(protector.LastUnprotected), "unprotected identity buffer cleared after loading");
            }
            var path = Path.Combine(directory, "remote-control-identity.bin");
            var damaged = await File.ReadAllBytesAsync(path).ConfigureAwait(false); damaged[^1] ^= 0x40;
            await File.WriteAllBytesAsync(path, damaged).ConfigureAwait(false);
            await RejectAsync<CryptographicException>(async () =>
            {
                using var corrupt = await RemoteControlIdentityStore.LoadOrCreateAsync(directory, "Must not regenerate").ConfigureAwait(false);
            }, "DPAPI corruption cannot regenerate a new identity").ConfigureAwait(false);
            var afterCorruptLoad = await File.ReadAllBytesAsync(path).ConfigureAwait(false);
            Require(damaged.AsSpan().SequenceEqual(afterCorruptLoad), "corrupt stored candidate preserved");
        }
        finally { Directory.Delete(directory, recursive: true); }
        return count;
    }

    private static bool AllZero(ReadOnlySpan<byte> bytes) { foreach (var value in bytes) { if (value != 0) { return false; } } return true; }

    private sealed class RecordingProtector : ISessionProtector
    {
        private readonly DpapiSessionProtector _inner = new();
        public byte[]? LastPlaintext { get; private set; }
        public byte[]? LastUnprotected { get; private set; }
        public byte[] Protect(byte[] bytes) { LastPlaintext = bytes; return _inner.Protect(bytes); }
        public byte[] Unprotect(byte[] bytes) { LastUnprotected = _inner.Unprotect(bytes); return LastUnprotected; }
    }

    private sealed class SwitchableCommitter : ISessionFileCommitter
    {
        public bool FailNext { get; set; }
        public void Commit(string temporaryPath, string destinationPath)
        {
            if (FailNext) { FailNext = false; throw new IOException("Injected commit failure before rename."); }
            AtomicSessionFileCommitter.Instance.Commit(temporaryPath, destinationPath);
        }
    }
}
