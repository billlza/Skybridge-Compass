using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading.Channels;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.Services.RemoteControl;
using PolicyScope = QPeriaptProductContractTests.PolicyScope;

internal static class QPeriaptWindowsProductTests
{
    internal static async Task RunAsync()
    {
        RequireWindows();
        await InterruptedIdentityMigrationAsync();
        await ProductHandshakeAsync();
    }

    internal static async Task StopBeforeIdentityCommitAsync(string directory)
    {
        RequireWindows();
        if (!Path.GetFileName(directory).StartsWith("skybridge-policy-contract-", StringComparison.Ordinal) ||
            File.ReadAllText(Path.Combine(directory, "migration-test-owner")) != "isolated-native-contract")
        { throw new InvalidOperationException("The termination fixture requires its isolated test directory."); }
        using var identity = await RemoteControlIdentityStore.LoadOrCreateAsync(directory, "Interrupted upgrade",
            new DpapiSessionProtector(), new StopAtIdentityCommitter());
        throw new InvalidOperationException("The migration fixture did not reach its termination boundary.");
    }

    private static async Task InterruptedIdentityMigrationAsync()
    {
        using var scope = new PolicyScope();
        var peer = RemoteControlPairingMaterial.Create("id:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "Existing peer", new byte[1952], new byte[1184]);
        var original = WriteSchema1(scope.Path, peer);
        await TerminateBeforeIdentityCommitAsync(scope.Path);
        var primaryPath = Path.Combine(scope.Path, "remote-control-identity.bin");
        QPeriaptProductContractTests.Require(original.ProtectedBytes.AsSpan().SequenceEqual(File.ReadAllBytes(primaryPath)), "Terminated migration changed the old primary identity.");
        QPeriaptProductContractTests.Require(original.ProtectedBytes.AsSpan().SequenceEqual(File.ReadAllBytes(Path.Combine(scope.Path, RemoteControlIdentityStore.Schema1BackupName))), "Migration preimage was partial or different.");
        var policyStore = new QPeriaptTrustedStateStore(scope.Path, new DpapiSessionProtector(), AtomicSessionFileCommitter.Instance);
        var committedHead = policyStore.Load() ?? throw new InvalidOperationException("The child did not commit a durable policy head.");
        using (var resumed = await RemoteControlIdentityStore.LoadOrCreateAsync(scope.Path, "Resume upgrade"))
        {
            QPeriaptProductContractTests.Require(resumed.PolicyEnrollmentMode == QPeriaptEnrollmentMode.Existing, "Crash recovery repeated first enrollment.");
            QPeriaptProductContractTests.Require(resumed.PublicMaterial.DeviceId == original.Material.DeviceId &&
                resumed.PublicMaterial.ProtocolPublicKeyFingerprint == original.Material.ProtocolPublicKeyFingerprint &&
                resumed.PublicMaterial.MlKem768PublicKey.Span.SequenceEqual(original.Material.MlKem768PublicKey.Span), "Migration replaced the established identity or legacy KEM.");
            QPeriaptProductContractTests.Require(resumed.PublicMaterial.HasQPeriaptKey && resumed.TrustedMaterials.Count == 1 && resumed.TrustedMaterials[0].HasSameAuthority(peer),
                "Migration lost peer permissions or did not commit the Q identity.");
            var qPeer = RemoteControlPairingMaterial.CreatePolicyBound(peer.DeviceId, peer.DeviceName, peer.ProtocolPublicKey.Span,
                peer.MlKem768PublicKey.Span, new byte[1216]);
            QPeriaptProductContractTests.Require(await resumed.ImportTrustedPeerAsync(qPeer) && resumed.TrustedMaterials[0].HasQPeriaptKey,
                "Explicit additive Q pairing import did not commit.");
            QPeriaptProductContractTests.Require(!await resumed.ImportTrustedPeerAsync(qPeer), "Repeated authorized pairing import is not idempotent.");
        }
        QPeriaptProductContractTests.Require(committedHead.AsSpan().SequenceEqual(policyStore.Load()), "Identity migration or explicit import changed the existing policy head.");
        // Restoring the old identity is an explicit rollback operation; the independent
        // monotonic policy head survives it and makes any later upgrade an existing enrollment.
        File.WriteAllBytes(primaryPath, original.ProtectedBytes);
        using (var upgradedAgain = await RemoteControlIdentityStore.LoadOrCreateAsync(scope.Path, "Reapply upgrade"))
        { QPeriaptProductContractTests.Require(upgradedAgain.PolicyEnrollmentMode == QPeriaptEnrollmentMode.Existing, "Identity rollback erased policy enrollment."); }
        var schema2 = File.ReadAllBytes(primaryPath);
        File.Delete(Path.Combine(scope.Path, QPeriaptTrustedStateStore.FileName));
        await ThrowsAsync<InvalidDataException>(() => RemoteControlIdentityStore.LoadOrCreateAsync(scope.Path, "Missing head"));
        QPeriaptProductContractTests.Require(schema2.AsSpan().SequenceEqual(File.ReadAllBytes(primaryPath)), "Missing schema 2 head changed the primary identity.");
        var corrupt = (byte[])schema2.Clone(); corrupt[^1] ^= 0x20; File.WriteAllBytes(primaryPath, corrupt);
        await ThrowsAsync<CryptographicException>(() => RemoteControlIdentityStore.LoadOrCreateAsync(scope.Path, "Corrupt schema 2"));
        QPeriaptProductContractTests.Require(corrupt.AsSpan().SequenceEqual(File.ReadAllBytes(primaryPath)), "Corrupt schema 2 was replaced using the schema 1 preimage.");
    }

    internal static async Task TerminateBeforeIdentityCommitAsync(string directory)
    {
        File.WriteAllText(Path.Combine(directory, "migration-test-owner"), "isolated-native-contract");
        using var child = new Process();
        child.StartInfo.FileName = Environment.ProcessPath ?? throw new InvalidOperationException("The native test executable path is missing.");
        if (Path.GetFileNameWithoutExtension(child.StartInfo.FileName).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
        { child.StartInfo.ArgumentList.Add(Assembly.GetExecutingAssembly().Location); }
        child.StartInfo.ArgumentList.Add("--policybound-migration-stop-before-identity");
        child.StartInfo.ArgumentList.Add(directory);
        child.StartInfo.UseShellExecute = false;
        child.StartInfo.CreateNoWindow = true;
        child.StartInfo.RedirectStandardOutput = true;
        child.StartInfo.RedirectStandardError = true;
        QPeriaptProductContractTests.Require(child.Start(), "The native migration child did not start.");
        var started = child.StartTime.ToUniversalTime();
        var stdout = child.StandardOutput.ReadToEndAsync();
        var stderr = child.StandardError.ReadToEndAsync();
        var marker = Path.Combine(directory, "policy-head-committed-before-identity");
        try
        {
            var deadline = Stopwatch.StartNew();
            while (!File.Exists(marker) && !child.HasExited && deadline.Elapsed < TimeSpan.FromSeconds(30))
            { await Task.Delay(25); }
            if (!File.Exists(marker))
            {
                if (!child.HasExited) { child.Kill(entireProcessTree: true); await child.WaitForExitAsync(); }
                throw new InvalidOperationException("The migration child did not reach the durable-head boundary: " + await stderr);
            }
            child.Kill(entireProcessTree: true);
            await child.WaitForExitAsync();
            QPeriaptProductContractTests.Require(string.IsNullOrWhiteSpace(await stdout), "The controlled migration child reported unexpected output.");
            QPeriaptProductContractTests.Require(string.IsNullOrWhiteSpace(await stderr), "The controlled migration child reported an unrelated error.");
            Console.WriteLine("POLICY_MIGRATION_CHILD " + JsonSerializer.Serialize(new
            { pid = child.Id, start_time_utc = started, exited = child.HasExited, exit_code = child.ExitCode, termination_boundary = "head committed; identity rename not performed" }));
        }
        finally
        {
            if (!child.HasExited) { child.Kill(entireProcessTree: true); await child.WaitForExitAsync(); }
        }
    }

    private static async Task ProductHandshakeAsync()
    {
        using var firstScope = new PolicyScope(); using var secondScope = new PolicyScope();
        using var first = await RemoteControlIdentityStore.LoadOrCreateAsync(firstScope.Path, "First Q peer");
        using var second = await RemoteControlIdentityStore.LoadOrCreateAsync(secondScope.Path, "Second Q peer");
        QPeriaptProductContractTests.Require(await first.ImportTrustedPeerAsync(second.PublicMaterial) && await second.ImportTrustedPeerAsync(first.PublicMaterial), "Native Q peers were not explicitly paired.");
        await HandshakeDirectionAsync(first, second);
        await HandshakeDirectionAsync(second, first);
    }

    private static async Task HandshakeDirectionAsync(RemoteControlIdentityStore initiator, RemoteControlIdentityStore responder)
    {
        using var firstProvider = initiator.CreateInitiatorCryptoProvider(responder.PublicMaterial.DeviceId, responder.PublicMaterial.ProtocolPublicKeyFingerprint);
        using var secondProvider = responder.CreateCryptoProvider();
        var forward = Channel.CreateBounded<ReadOnlyMemory<byte>>(4); var reverse = Channel.CreateBounded<ReadOnlyMemory<byte>>(4);
        var firstTransport = new FramedQueue(reverse.Reader, forward.Writer); var secondTransport = new FramedQueue(forward.Reader, reverse.Writer);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var firstTask = new ProductHandshakeCore(firstProvider).StartInitiatorAsync(firstTransport,
            new(responder.PublicMaterial.DeviceId, responder.PublicMaterial.ProtocolPublicKeyFingerprint), deadline.Token);
        var secondTask = new ProductHandshakeCore(secondProvider).AcceptResponderAsync(secondTransport,
            new(initiator.PublicMaterial.DeviceId, initiator.PublicMaterial.ProtocolPublicKeyFingerprint), cancellationToken: deadline.Token);
        var results = await Task.WhenAll(firstTask, secondTask);
        using var first = results[0]; using var second = results[1];
        QPeriaptProductContractTests.Require(first.SuiteWireId == 0x0012 && second.SuiteWireId == 0x0012 && first.Keys.SessionId == second.Keys.SessionId,
            "The actual product providers did not complete one matching Q session.");
        QPeriaptProductContractTests.Require(first.Keys.SendKey.Span.SequenceEqual(second.Keys.ReceiveKey.Span) && first.Keys.ReceiveKey.Span.SequenceEqual(second.Keys.SendKey.Span),
            "Completed Q Finished exchanges produced different directional keys.");
        var messageA = WebRtcProductHandshakeCodec.DecodeMessageA(firstTransport.Sent[0]);
        var messageB = WebRtcProductHandshakeCodec.DecodeMessageB(secondTransport.Sent[0]);
        QPeriaptProductContractTests.Require(messageA.SupportedSuiteWireIds.SequenceEqual(new ushort[] { 0x0012 }) && messageA.InitiatorContribution.IsEmpty &&
            messageB.ResponderShare.IsEmpty && messageA.KeyShares.Single().ShareBytes.Length == 1120,
            "Q must remain v1-single and must not advertise the 0x0102 forward-secret contribution.");
        QPeriaptProductContractTests.Require(firstTransport.Sent.Count == 2 && secondTransport.Sent.Count == 2, "A completed product Q handshake must exchange both Finished frames.");
    }

    private static LegacyIdentity WriteSchema1(string directory, RemoteControlPairingMaterial peer)
    {
        using var signing = MLDsa.GenerateKey(MLDsaAlgorithm.MLDsa65); using var kem = MLKem.GenerateKey(MLKemAlgorithm.MLKem768);
        var signingPrivate = signing.ExportMLDsaPrivateKey(); var kemPrivate = kem.ExportDecapsulationKey();
        var material = RemoteControlPairingMaterial.Create("id:" + Guid.NewGuid().ToString("D"), "Legacy identity", signing.ExportMLDsaPublicKey(), kem.ExportEncapsulationKey());
        byte[]? plaintext = null;
        try
        {
            plaintext = JsonSerializer.SerializeToUtf8Bytes(new
            {
                SchemaVersion = 1,
                material.DeviceId,
                DeviceName = material.DeviceName,
                SigningPrivateKey = signingPrivate,
                KemDecapsulationKey = kemPrivate,
                TrustedMaterials = new[] { peer.ToJson() }
            });
            var protectedBytes = new DpapiSessionProtector().Protect(plaintext);
            File.WriteAllBytes(Path.Combine(directory, "remote-control-identity.bin"), protectedBytes);
            return new(material, protectedBytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(signingPrivate); CryptographicOperations.ZeroMemory(kemPrivate);
            if (plaintext is not null) { CryptographicOperations.ZeroMemory(plaintext); }
        }
    }

    private static async Task ThrowsAsync<T>(Func<Task<RemoteControlIdentityStore>> action) where T : Exception
    {
        try { using var unexpected = await action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }
    private static void RequireWindows()
    { if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041) || !MLDsa.IsSupported || !MLKem.IsSupported) { throw new PlatformNotSupportedException("Native policy-bound product tests require Windows, DPAPI and native PQC."); } }
    private sealed record LegacyIdentity(RemoteControlPairingMaterial Material, byte[] ProtectedBytes);
    private sealed class StopAtIdentityCommitter : ISessionFileCommitter
    {
        public void Commit(string temporaryPath, string destinationPath)
        {
            if (Path.GetFileName(destinationPath) == "remote-control-identity.bin")
            {
                File.WriteAllText(Path.Combine(Path.GetDirectoryName(destinationPath) ?? throw new InvalidOperationException("No test directory."), "policy-head-committed-before-identity"), "ready");
                Thread.Sleep(TimeSpan.FromSeconds(45));
                throw new InvalidOperationException("Controlled termination did not occur.");
            }
            AtomicSessionFileCommitter.Instance.Commit(temporaryPath, destinationPath);
        }
    }
    private sealed class FramedQueue(ChannelReader<ReadOnlyMemory<byte>> reader, ChannelWriter<ReadOnlyMemory<byte>> writer) : IProductHandshakeTransport
    {
        internal List<byte[]> Sent { get; } = [];
        public async Task SendAsync(ReadOnlyMemory<byte> frame, CancellationToken cancellationToken = default)
        { var copy = frame.ToArray(); Sent.Add(copy); await writer.WriteAsync(copy, cancellationToken); }
        public async Task<ReadOnlyMemory<byte>> ReadAsync(CancellationToken cancellationToken = default) => await reader.ReadAsync(cancellationToken);
    }
}
