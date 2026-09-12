using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.Services.RemoteControl;
using PolicyScope = QPeriaptProductContractTests.PolicyScope;
using ContractAssert = QPeriaptProductContractTests;

internal static class QPeriaptSchema1ReupgradeTests
{
    internal static async Task RunAsync(string legacyOwnerAssembly)
    {
        if (!OperatingSystem.IsWindows() || !MLDsa.IsSupported || !MLKem.IsSupported)
        { throw new PlatformNotSupportedException("Re-upgrade tests require real Windows DPAPI and native PQC."); }
        if (!Path.IsPathFullyQualified(legacyOwnerAssembly) || !File.Exists(legacyOwnerAssembly))
        { throw new InvalidOperationException("The explicitly frozen legacy identity-owner assembly is required."); }
        await RecoverAfterLegacyPairingAsync(legacyOwnerAssembly);
        await RejectConflictingPreimagesAsync(legacyOwnerAssembly);
    }

    private static async Task RecoverAfterLegacyPairingAsync(string legacyOwnerAssembly)
    {
        using var fixture = await ReupgradeFixture.CreateAsync(legacyOwnerAssembly);
        ContractAssert.Require(!File.Exists(fixture.SnapshotPath), "The new schema 1 snapshot already existed before controlled termination.");
        await QPeriaptWindowsProductTests.TerminateBeforeIdentityCommitAsync(fixture.Scope.Path);
        fixture.RequirePrimaryAndHeadUnchanged();
        ContractAssert.Require(fixture.OriginalAnchor.AsSpan().SequenceEqual(File.ReadAllBytes(fixture.AnchorPath)), "Re-upgrade replaced its original anchor.");
        fixture.RequireSnapshot();
        var snapshotCreated = File.GetCreationTimeUtc(fixture.SnapshotPath);
        using (var resumed = await RemoteControlIdentityStore.LoadOrCreateAsync(fixture.Scope.Path, "Resumed re-upgrade"))
        { fixture.RequireMigratedOwner(resumed); }
        fixture.RequireSnapshot();
        ContractAssert.Require(snapshotCreated == File.GetCreationTimeUtc(fixture.SnapshotPath), "Interrupted retry replaced the immutable snapshot.");
        File.WriteAllBytes(fixture.PrimaryPath, fixture.UpdatedPrimary);
        using (var repeated = await RemoteControlIdentityStore.LoadOrCreateAsync(fixture.Scope.Path, "Repeat exact preimage"))
        { fixture.RequireMigratedOwner(repeated); }
        ContractAssert.Require(snapshotCreated == File.GetCreationTimeUtc(fixture.SnapshotPath), "The same preimage was not idempotent.");
        ContractAssert.Require(Directory.GetFiles(fixture.Scope.Path, "remote-control-identity.schema1.*.bin").Length == 1, "An exact retry created additional history snapshots.");
        Console.WriteLine("PASS legacy-owner pairing survives re-upgrade, snapshot commit termination and idempotent retry");
    }

    private static async Task RejectConflictingPreimagesAsync(string legacyOwnerAssembly)
    {
        using var fixture = await ReupgradeFixture.CreateAsync(legacyOwnerAssembly);
        var corrupted = (byte[])fixture.OriginalAnchor.Clone(); corrupted[^1] ^= 0x20;
        await fixture.RejectAnchorAsync<CryptographicException>(corrupted, "corrupt encrypted anchor");
        await fixture.RejectAnchorAsync<InvalidDataException>(RewriteAnchor(fixture.OriginalAnchor,
            document => document with { SchemaVersion = 99 }), "unknown anchor schema");
        await fixture.RejectAnchorAsync<InvalidDataException>(RewriteAnchor(fixture.OriginalAnchor,
            document => document with { DeviceId = "id:" + Guid.NewGuid().ToString("D") }), "different device identity");
        await fixture.RejectAnchorAsync<InvalidDataException>(RewriteAnchor(fixture.OriginalAnchor,
            document => document with { TrustedMaterials = [.. document.TrustedMaterials, document.TrustedMaterials[0]] }), "duplicate archived trust");
        using (var foreign = new PolicyScope())
        {
            await RunLegacyImportAsync(legacyOwnerAssembly, foreign.Path, fixture.FirstPeer);
            var foreignBytes = File.ReadAllBytes(Path.Combine(foreign.Path, "remote-control-identity.bin"));
            await fixture.RejectAnchorAsync<InvalidDataException>(RewriteAnchor(foreignBytes,
                document => document with { DeviceId = fixture.LocalIdentity.DeviceId }), "different signing and legacy KEM keys");
        }
        File.WriteAllBytes(fixture.SnapshotPath, [1, 2, 3]);
        await ThrowsOwnerAsync<IOException>(() => RemoteControlIdentityStore.LoadOrCreateAsync(fixture.Scope.Path, "Conflicting target"));
        fixture.RequirePrimaryAndHeadUnchanged();
        ContractAssert.Require(File.ReadAllBytes(fixture.SnapshotPath).AsSpan().SequenceEqual(new byte[] { 1, 2, 3 }), "Conflicting snapshot bytes were overwritten.");
        File.Delete(fixture.SnapshotPath);
        Directory.CreateDirectory(fixture.SnapshotPath);
        try
        {
            var rejected = false;
            try { using var unexpected = await RemoteControlIdentityStore.LoadOrCreateAsync(fixture.Scope.Path, "Unwritable target"); }
            catch (Exception failure) when (failure is IOException or UnauthorizedAccessException) { rejected = true; }
            ContractAssert.Require(rejected, "A directory was accepted as an immutable snapshot file.");
            fixture.RequirePrimaryAndHeadUnchanged();
            ContractAssert.Require(Directory.Exists(fixture.SnapshotPath), "The conflicting directory was modified.");
            ContractAssert.Require(Directory.GetFiles(fixture.Scope.Path, "*.tmp").Length == 0, "Rejected snapshot write left staging files.");
        }
        finally { Directory.Delete(fixture.SnapshotPath); }
        var failedCommitter = new QPeriaptProductContractTests.ControllableCommitter { FailBeforeCommit = true };
        await ThrowsOwnerAsync<IOException>(() => RemoteControlIdentityStore.LoadOrCreateAsync(fixture.Scope.Path, "Fail identity rename",
            new DpapiSessionProtector(), failedCommitter));
        fixture.RequirePrimaryAndHeadUnchanged();
        fixture.RequireSnapshot();
        ContractAssert.Require(Directory.GetFiles(fixture.Scope.Path, "*.tmp").Length == 0, "Rejected identity commit left staging files.");
        using (var resumed = await RemoteControlIdentityStore.LoadOrCreateAsync(fixture.Scope.Path, "Resume failed write"))
        { fixture.RequireMigratedOwner(resumed); }
        Console.WriteLine("PASS corrupt, unknown, foreign and conflicting preimages fail without replacing primary, anchor or head");
    }

    private static async Task RunLegacyImportAsync(string legacyOwnerAssembly, string directory, RemoteControlPairingMaterial peer)
    {
        File.WriteAllText(Path.Combine(directory, "migration-test-owner"), "isolated-native-contract");
        var pairingPath = Path.Combine(directory, "legacy-peer-import-" + Guid.NewGuid().ToString("N") + ".json");
        File.WriteAllText(pairingPath, peer.ToJson());
        using var child = new Process();
        child.StartInfo.FileName = Environment.ProcessPath ?? throw new InvalidOperationException("The native .NET host path is missing.");
        if (!Path.GetFileNameWithoutExtension(child.StartInfo.FileName).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
        { throw new InvalidOperationException("Launch the legacy-owner migration profile with the explicit dotnet host."); }
        child.StartInfo.ArgumentList.Add(legacyOwnerAssembly);
        child.StartInfo.ArgumentList.Add("--legacy-schema1-import");
        child.StartInfo.ArgumentList.Add(directory);
        child.StartInfo.ArgumentList.Add(pairingPath);
        child.StartInfo.UseShellExecute = false; child.StartInfo.CreateNoWindow = true;
        child.StartInfo.RedirectStandardOutput = true; child.StartInfo.RedirectStandardError = true;
        ContractAssert.Require(child.Start(), "The real legacy-owner process did not start.");
        var started = child.StartTime.ToUniversalTime();
        var output = child.StandardOutput.ReadToEndAsync(); var error = child.StandardError.ReadToEndAsync();
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        try
        {
            await child.WaitForExitAsync(deadline.Token);
            var text = await output; var diagnostic = await error;
            ContractAssert.Require(child.ExitCode == 0 && string.IsNullOrWhiteSpace(diagnostic), "The real legacy owner failed: " + diagnostic);
            using var receipt = JsonDocument.Parse(text);
            ContractAssert.Require(receipt.RootElement.GetProperty("imported").GetBoolean(), "The legacy owner did not persist the new explicit pairing.");
            Console.WriteLine("LEGACY_SCHEMA1_CHILD " + JsonSerializer.Serialize(new
            { pid = child.Id, start_time_utc = started, exited = child.HasExited, exit_code = child.ExitCode, trusted_count = receipt.RootElement.GetProperty("trusted_count").GetInt32() }));
        }
        finally
        {
            if (!child.HasExited) { child.Kill(entireProcessTree: true); await child.WaitForExitAsync(); }
        }
    }

    private static RemoteControlPairingMaterial NewPeer(string name)
    {
        using var signer = MLDsa.GenerateKey(MLDsaAlgorithm.MLDsa65);
        using var kem = MLKem.GenerateKey(MLKemAlgorithm.MLKem768);
        return RemoteControlPairingMaterial.Create("id:" + Guid.NewGuid().ToString("D"), name,
            signer.ExportMLDsaPublicKey(), kem.ExportEncapsulationKey());
    }

    private static byte[] RewriteAnchor(byte[] encrypted, Func<LegacyDocument, LegacyDocument> rewrite)
    {
        var protector = new DpapiSessionProtector(); var plaintext = protector.Unprotect(encrypted);
        LegacyDocument? document = null; byte[]? encoded = null;
        try
        {
            document = JsonSerializer.Deserialize<LegacyDocument>(plaintext) ?? throw new InvalidDataException("No fixture identity.");
            encoded = JsonSerializer.SerializeToUtf8Bytes(rewrite(document));
            return protector.Protect(encoded);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
            if (encoded is not null) { CryptographicOperations.ZeroMemory(encoded); }
            if (document is not null) { CryptographicOperations.ZeroMemory(document.SigningPrivateKey); CryptographicOperations.ZeroMemory(document.KemDecapsulationKey); }
        }
    }

    private static async Task ThrowsOwnerAsync<T>(Func<Task<RemoteControlIdentityStore>> operation) where T : Exception
    {
        try { using var unexpected = await operation(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private sealed record LegacyDocument(int SchemaVersion, string DeviceId, string DeviceName,
        byte[] SigningPrivateKey, byte[] KemDecapsulationKey, string[] TrustedMaterials);

    private sealed class ReupgradeFixture : IDisposable
    {
        internal PolicyScope Scope { get; } = new();
        internal RemoteControlPairingMaterial FirstPeer { get; } = NewPeer("Earlier peer");
        private RemoteControlPairingMaterial AddedPeer { get; } = NewPeer("Peer added by old owner");
        internal string PrimaryPath => Path.Combine(Scope.Path, "remote-control-identity.bin");
        internal string AnchorPath => Path.Combine(Scope.Path, RemoteControlIdentityStore.Schema1BackupName);
        internal string SnapshotPath => Path.Combine(Scope.Path, $"remote-control-identity.schema1.{Convert.ToHexStringLower(SHA256.HashData(UpdatedPrimary))}.bin");
        internal byte[] OriginalAnchor { get; private set; } = [];
        internal byte[] UpdatedPrimary { get; private set; } = [];
        private byte[] OriginalHead { get; set; } = [];
        private RemoteControlPairingMaterial? _localIdentity;
        internal RemoteControlPairingMaterial LocalIdentity => _localIdentity ?? throw new InvalidOperationException("The migration fixture has not been initialized.");

        internal static async Task<ReupgradeFixture> CreateAsync(string legacyOwnerAssembly)
        {
            var fixture = new ReupgradeFixture();
            try
            {
                await RunLegacyImportAsync(legacyOwnerAssembly, fixture.Scope.Path, fixture.FirstPeer);
                fixture.OriginalAnchor = File.ReadAllBytes(fixture.PrimaryPath);
                using (var upgraded = await RemoteControlIdentityStore.LoadOrCreateAsync(fixture.Scope.Path, "First upgrade"))
                { fixture._localIdentity = upgraded.PublicMaterial; }
                fixture.OriginalHead = File.ReadAllBytes(Path.Combine(fixture.Scope.Path, QPeriaptTrustedStateStore.FileName));
                File.WriteAllBytes(fixture.PrimaryPath, fixture.OriginalAnchor);
                await RunLegacyImportAsync(legacyOwnerAssembly, fixture.Scope.Path, fixture.AddedPeer);
                fixture.UpdatedPrimary = File.ReadAllBytes(fixture.PrimaryPath);
                ContractAssert.Require(!fixture.OriginalAnchor.AsSpan().SequenceEqual(fixture.UpdatedPrimary), "The old owner did not update schema 1 after rollback.");
                fixture.RequirePrimaryAndHeadUnchanged();
                return fixture;
            }
            catch { fixture.Dispose(); throw; }
        }

        internal void RequirePrimaryAndHeadUnchanged()
        {
            ContractAssert.Require(UpdatedPrimary.AsSpan().SequenceEqual(File.ReadAllBytes(PrimaryPath)), "A failed migration replaced the valid schema 1 primary.");
            ContractAssert.Require(OriginalHead.AsSpan().SequenceEqual(File.ReadAllBytes(Path.Combine(Scope.Path, QPeriaptTrustedStateStore.FileName))), "Re-upgrade changed the committed policy head.");
        }

        internal void RequireSnapshot()
        {
            ContractAssert.Require(OriginalAnchor.AsSpan().SequenceEqual(File.ReadAllBytes(AnchorPath)), "The immutable original anchor was replaced.");
            ContractAssert.Require(UpdatedPrimary.AsSpan().SequenceEqual(File.ReadAllBytes(SnapshotPath)), "The latest full schema 1 preimage was not retained.");
            ContractAssert.Require((File.GetAttributes(SnapshotPath) & FileAttributes.ReadOnly) != 0, "The completed snapshot is not read-only.");
        }

        internal void RequireMigratedOwner(RemoteControlIdentityStore owner)
        {
            ContractAssert.Require(owner.PolicyEnrollmentMode == QPeriaptEnrollmentMode.Existing && owner.PublicMaterial.HasQPeriaptKey,
                "Re-upgrade lost the existing enrollment or Q key.");
            ContractAssert.Require(owner.PublicMaterial.DeviceId == LocalIdentity.DeviceId && owner.PublicMaterial.ProtocolPublicKey.Span.SequenceEqual(LocalIdentity.ProtocolPublicKey.Span) &&
                owner.PublicMaterial.MlKem768PublicKey.Span.SequenceEqual(LocalIdentity.MlKem768PublicKey.Span), "Re-upgrade replaced the original local authority.");
            ContractAssert.Require(owner.TrustedMaterials.Count == 2 && owner.TrustedMaterials.Any(peer => peer.HasSameAuthority(FirstPeer)) && owner.TrustedMaterials.Any(peer => peer.HasSameAuthority(AddedPeer)),
                "Re-upgrade did not retain exactly the current primary's peer permissions.");
            ContractAssert.Require(OriginalHead.AsSpan().SequenceEqual(File.ReadAllBytes(Path.Combine(Scope.Path, QPeriaptTrustedStateStore.FileName))), "Re-upgrade moved the existing policy head.");
        }

        internal async Task RejectAnchorAsync<T>(byte[] replacement, string reason) where T : Exception
        {
            File.SetAttributes(AnchorPath, FileAttributes.Normal); File.WriteAllBytes(AnchorPath, replacement); File.SetAttributes(AnchorPath, FileAttributes.ReadOnly);
            try
            {
                await ThrowsOwnerAsync<T>(() => RemoteControlIdentityStore.LoadOrCreateAsync(Scope.Path, reason));
                RequirePrimaryAndHeadUnchanged();
                ContractAssert.Require(replacement.AsSpan().SequenceEqual(File.ReadAllBytes(AnchorPath)), "Rejected anchor bytes were changed.");
                ContractAssert.Require(!File.Exists(SnapshotPath), "An invalid anchor caused a new history snapshot.");
            }
            finally { File.SetAttributes(AnchorPath, FileAttributes.Normal); File.WriteAllBytes(AnchorPath, OriginalAnchor); File.SetAttributes(AnchorPath, FileAttributes.ReadOnly); }
        }
        public void Dispose() => Scope.Dispose();
    }
}
