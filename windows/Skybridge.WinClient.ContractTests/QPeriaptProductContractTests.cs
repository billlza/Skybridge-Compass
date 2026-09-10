using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text.Json;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.Services.RemoteControl;

internal static class QPeriaptProductContractTests
{
    internal static readonly (string Name, Func<Task> Run)[] ManagedCases =
    [
        ("Q ABI2 session keys and Finished match the Apple golden vector", () => Run(SessionKdfGolden)),
        ("policy-bound context matches the Apple and Ubuntu golden digest", () => Run(ContextGolden)),
        ("policy-bound platform metadata matches the shared contract", () => Run(PlatformContract)),
        ("policy-bound pairing preserves legacy identity and rejects conflicts", () => Run(PairingContract)),
        ("policy head CAS rejects stale state and preserves failed commits", () => Run(StateTransactions)),
        ("competing policy stores cannot both commit the same expected head", ConcurrentStateTransactions)
    ];

    internal static readonly (string Name, Func<Task> Run)[] NativeCases =
    [
        ("production policy resumes a committed head before identity migration", () => Run(ProductionEnrollmentRecovery)),
        ("production policy rejects missing enrolled head and rollback", () => Run(ProductionEnrollmentRejection)),
        ("policy-bound expanded keys preserve ABI material and context binding", () => Run(ExpandedNativeKeys)),
        ("definite policy commit is not hidden by late cancellation", () => Run(DefiniteCommitCancellation))
    ];

    private static void SessionKdfGolden()
    {
        using var json = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "q-abi2-session-kdf-v1.json")));
        var vector = json.RootElement;
        var inputs = vector.GetProperty("inputs");
        byte[] Input(string name) => Convert.FromHexString(inputs.GetProperty(name).GetString() ?? throw new InvalidDataException("Test input must be a string."));
        byte[] Expected(string name) => Convert.FromHexString(vector.GetProperty(name).GetString() ?? throw new InvalidDataException("Expected test output must be a string."));
        foreach (var role in new[] { ProductHandshakeRole.Initiator, ProductHandshakeRole.Responder })
        {
            var initiator = role == ProductHandshakeRole.Initiator;
            using var keys = ProductHandshakeKeyDerivation.Derive(Input("shared_secret"),
                WebRtcProductHandshakeCodec.SuiteQPeriaptPolicyBound, Input("transcript_a"), Input("transcript_b"),
                Input("client_nonce"), Input("server_nonce"), role);
            Require(keys.TranscriptHash.Span.SequenceEqual(Expected("transcript_hash")), "Q transcript differs from the independent vector.");
            Require(keys.SendKey.Span.SequenceEqual(Expected(initiator ? "i2r_key" : "r2i_key")), "Q send key differs from the Apple key schedule.");
            Require(keys.ReceiveKey.Span.SequenceEqual(Expected(initiator ? "r2i_key" : "i2r_key")), "Q receive key differs from the Apple key schedule.");
            var sent = ProductHandshakeKeyDerivation.CreateFinished(keys);
            Require(sent.Mac.Span.SequenceEqual(Expected(initiator ? "i2r_finished_mac" : "r2i_finished_mac")), "Q Finished differs from Apple.");
            var peerRole = initiator ? ProductHandshakeRole.Responder : ProductHandshakeRole.Initiator;
            var peerDirection = initiator ? WebRtcProductHandshakeFinishedDirection.ResponderToInitiator : WebRtcProductHandshakeFinishedDirection.InitiatorToResponder;
            var peerMac = Expected(initiator ? "r2i_finished_mac" : "i2r_finished_mac");
            Require(ProductHandshakeKeyDerivation.VerifyFinished(new(peerDirection, peerMac), keys, peerRole), "Apple Finished must verify.");
            Require(!ProductHandshakeKeyDerivation.VerifyFinished(new(peerDirection, peerMac), keys, role), "Reflected Finished must fail.");
            peerMac[31] ^= 1;
            Require(!ProductHandshakeKeyDerivation.VerifyFinished(new(peerDirection, peerMac), keys, peerRole), "Tampered Finished must fail.");
        }
    }

    private static void ContextGolden()
    {
        var nonce = Enumerable.Repeat((byte)0x11, 32).ToArray();
        var recipient = Enumerable.Repeat((byte)0x22, 1216).ToArray();
        var identity = Enumerable.Repeat((byte)0x33, 1952).ToArray();
        var policy = new WebRtcProductHandshakePolicy(true, false, "qperiaptPQC", false);
        var capabilities = new WebRtcProductCryptoCapabilities([QPeriaptPeerPlatform.KemCapability], ["ML-DSA-65"],
            ["q-periapt-abi2-policy-v1/2/test-digest"], ["AES-256-GCM"], true, "macOS 26.0", QPeriaptPeerPlatform.ProviderType);
        ushort[] suites = [0x0012, 0x0101];
        byte[] Context(byte version, byte[] clientNonce, byte[] recipientKey, byte[] signingKey, byte[] extensions) =>
            QPeriaptHandshakeContext.Encode(version, clientNonce, recipientKey, policy, suites, capabilities, signingKey, extensions);
        var baseline = Context(1, nonce, recipient, identity, [1, 2, 3]);
        Require(Convert.ToHexStringLower(SHA256.HashData(baseline)) == "9cdf97efe7d030b4f96cbbbd01f4f7681a3b2991e00159c361105a61948cc14f",
            "Context differs from the fixed current Apple/iOS/Ubuntu protocol vector.");
        Require(!baseline.AsSpan().SequenceEqual(Context(2, nonce, recipient, identity, [1, 2, 3])), "Protocol version must be bound.");
        foreach (var input in new[] { nonce, recipient, identity })
        {
            input[0] ^= 1;
            Require(!baseline.AsSpan().SequenceEqual(Context(1, nonce, recipient, identity, [1, 2, 3])), "Security input must be bound.");
            input[0] ^= 1;
        }
        Require(!baseline.AsSpan().SequenceEqual(Context(1, nonce, recipient, identity, [1, 2, 4])), "Extensions must be bound.");
        Throws<WebRtcProductHandshakeCodecException>(() => QPeriaptHandshakeContext.Encode(1, nonce, recipient, policy,
            [0x0012, 0x0012], capabilities, identity, []));
        Throws<WebRtcProductHandshakeCodecException>(() => QPeriaptHandshakeContext.Encode(1, nonce, recipient, policy,
            [0x0012, 0x0011], capabilities, identity, []));
        Throws<WebRtcProductHandshakeCodecException>(() => Context(1, nonce, new byte[1215], identity, []));
        Throws<WebRtcProductHandshakeCodecException>(() => Context(1, nonce, recipient, identity, new byte[65536]));
        Require(WebRtcProductHandshakeCodec.ExpectedKeyShareLength(0x0012) == 1120 &&
            WebRtcProductHandshakeCodec.ExpectedResponderShareLength(0x0012) == 0 &&
            !WebRtcProductHandshakeCodec.RequiresV2EphemeralContribution([0x0012]) &&
            WebRtcProductHandshakeCodec.RequiresV2EphemeralContribution([0x0102]), "Q and FS wire compositions must remain distinct.");
    }

    private static void PlatformContract()
    {
        using var json = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "qperiapt-peer-platform-contract.json")));
        Require(json.RootElement.GetProperty("native_admission_required").GetBoolean(), "Metadata vectors must retain the native admission boundary.");
        var mismatches = new List<string>();
        foreach (var item in json.RootElement.GetProperty("handshake").EnumerateArray())
        {
            var version = item.GetProperty("version").GetString();
            if (QPeriaptPeerPlatform.IsEligible(version) != item.GetProperty("eligible").GetBoolean())
            { mismatches.Add(JsonSerializer.Serialize(version)); }
        }
        Require(mismatches.Count == 0, "Platform contract differs for: " + string.Join(", ", mismatches));
    }

    private static void PairingContract()
    {
        const string id = "id:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
        var legacy = RemoteControlPairingMaterial.Create(id, "Peer", new byte[1952], new byte[1184]);
        var upgraded = RemoteControlPairingMaterial.CreatePolicyBound(id, "Peer", new byte[1952], new byte[1184], new byte[1216]);
        var decoded = RemoteControlPairingMaterial.Parse(upgraded.ToJson());
        Require(decoded.HasQPeriaptKey && decoded.QPeriaptPublicKey.Length == 1216 && decoded.MlKem768PublicKey.Length == 1184,
            "Both KEM identities must survive shared pairing JSON.");
        Require(legacy.CanAddPolicyBoundKey(decoded) && !decoded.CanAddPolicyBoundKey(legacy), "Only an additive authorized Q upgrade is eligible.");
        var differentLegacy = new byte[1184]; differentLegacy[0] = 1;
        Require(!legacy.CanAddPolicyBoundKey(RemoteControlPairingMaterial.CreatePolicyBound(id, "Peer", new byte[1952], differentLegacy, new byte[1216])),
            "Adding Q cannot replace the old KEM authority.");
        Require(legacy.ProtocolPublicKeyFingerprint == upgraded.ProtocolPublicKeyFingerprint && !legacy.HasSameAuthority(upgraded),
            "A Q addition keeps signing authority but still requires an explicit trust update.");
        Throws<InvalidDataException>(() => RemoteControlPairingMaterial.Parse(upgraded.ToJson().Replace("\"suiteWireId\": 257", "\"suiteWireId\": 18")));
        Throws<InvalidDataException>(() => RemoteControlPairingMaterial.CreatePolicyBound(id, "Peer", new byte[1952], [], new byte[1215]));
        var qOnly = RemoteControlPairingMaterial.CreatePolicyBound(id, "Peer", new byte[1952], [], new byte[1216]);
        Require(RemoteControlPairingMaterial.Parse(qOnly.ToJson()).MlKem768PublicKey.IsEmpty, "A Q-only key cannot invent legacy material.");
    }

    private static void StateTransactions()
    {
        using var scope = new PolicyScope();
        var committer = new ControllableCommitter();
        var store = scope.Store(committer);
        var first = Head(1, 0x11); var second = Head(2, 0x22);
        Require(store.Load() is null && store.CompareAndSwap(null, first), "First CAS must commit from absent state.");
        var before = File.ReadAllBytes(Path.Combine(scope.Path, QPeriaptTrustedStateStore.FileName));
        Require(!store.CompareAndSwap(null, second), "Stale absence cannot overwrite a committed head.");
        committer.FailBeforeCommit = true;
        Throws<IOException>(() => store.CompareAndSwap(first, second));
        Require(before.AsSpan().SequenceEqual(File.ReadAllBytes(Path.Combine(scope.Path, QPeriaptTrustedStateStore.FileName))), "Failed commit changed prior head bytes.");
        Require(Directory.GetFiles(scope.Path, "*.tmp").Length == 0, "Failed CAS left its live staging file.");
        committer.FailBeforeCommit = false;
        Require(store.CompareAndSwap(first, second) && (store.Load() ?? throw new InvalidOperationException("Missing committed policy head.")).AsSpan().SequenceEqual(second), "Valid replacement CAS did not commit.");
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        Throws<OperationCanceledException>(() => store.CompareAndSwap(second, Head(3, 0x33), cancellation.Token));
        using (new FileStream(System.IO.Path.Combine(scope.Path, ".q-periapt-trusted-state.lock"), FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        { Throws<IOException>(() => store.Load()); }
        var damaged = File.ReadAllBytes(Path.Combine(scope.Path, QPeriaptTrustedStateStore.FileName)); damaged[4] ^= 1;
        File.WriteAllBytes(Path.Combine(scope.Path, QPeriaptTrustedStateStore.FileName), damaged);
        Throws<InvalidDataException>(() => store.Load());
        Require(damaged.AsSpan().SequenceEqual(File.ReadAllBytes(Path.Combine(scope.Path, QPeriaptTrustedStateStore.FileName))), "Corrupt state must remain available for diagnosis.");
    }

    private static void ProductionEnrollmentRecovery()
    {
        using var scope = new PolicyScope();
        var primary = Path.Combine(scope.Path, "remote-control-identity.bin");
        byte[] original = [4, 2, 3, 1]; File.WriteAllBytes(primary, original);
        var first = QPeriaptRuntimeSession.Prepare(scope.Store(), identityAlreadyEnrolled: false);
        Require(first.EnrollmentMode == QPeriaptEnrollmentMode.AuthorizedFirst, "Fresh policy did not use the authorized first-enrollment boundary.");
        var head = scope.Store().Load() ?? throw new InvalidOperationException("No durable policy head.");
        var resumed = QPeriaptRuntimeSession.Prepare(scope.Store(), identityAlreadyEnrolled: false);
        Require(resumed.EnrollmentMode == QPeriaptEnrollmentMode.Existing, "An interrupted schema 1 migration must resume the existing policy enrollment.");
        Require(head.AsSpan().SequenceEqual(scope.Store().Load()) && original.AsSpan().SequenceEqual(File.ReadAllBytes(primary)),
            "Policy recovery must preserve the existing head and original identity primary.");
        Require(resumed.AuthProfile == first.AuthProfile && resumed.AuthProfile.EndsWith("/1/eb583259f4fd8c19ae720e0d92bcc13bad1870e337151f2c1afe180a557111c6", StringComparison.Ordinal),
            "Production auth profile must preserve the native SHA3-256 policy identity.");
    }

    private static async Task ConcurrentStateTransactions()
    {
        using var scope = new PolicyScope();
        var initial = Head(1, 0x11);
        Require(scope.Store().CompareAndSwap(null, initial), "Could not establish the expected policy head.");
        using var enteredCommit = new ManualResetEventSlim();
        using var releaseCommit = new ManualResetEventSlim();
        var committer = new ControllableCommitter
        {
            BeforeCommit = () =>
        {
            enteredCommit.Set();
            Require(releaseCommit.Wait(TimeSpan.FromSeconds(10)), "The competing policy writer did not release the commit boundary.");
        }
        };
        var winner = Task.Run(() => scope.Store(committer).CompareAndSwap(initial, Head(2, 0x22)));
        var contender = Task.Run(() =>
        {
            try
            {
                Require(enteredCommit.Wait(TimeSpan.FromSeconds(10)), "The first policy writer did not reach the commit boundary.");
                // This real CAS runs while the other store owns its exclusive lease.
                // The OS-specific sharing error is an observable failure, not a stale-CAS result.
                Throws<IOException>(() => scope.Store().CompareAndSwap(initial, Head(2, 0x33)));
            }
            finally { releaseCommit.Set(); }
        });
        await Task.WhenAll(winner, contender);
        Require(await winner, "The exclusive policy writer did not commit.");
        Require(!scope.Store().CompareAndSwap(initial, Head(2, 0x33)), "A stale writer committed after the exclusive lease was released.");
        var actual = scope.Store().Load() ?? throw new InvalidOperationException("The competing CAS lost its committed head.");
        Require(actual.AsSpan().SequenceEqual(Head(2, 0x22)), "Stored head does not match the winning CAS.");
    }

    private static void ProductionEnrollmentRejection()
    {
        using var scope = new PolicyScope();
        Throws<InvalidDataException>(() => QPeriaptRuntimeSession.Prepare(scope.Store(), identityAlreadyEnrolled: true));
        Require(!File.Exists(Path.Combine(scope.Path, QPeriaptTrustedStateStore.FileName)), "Missing existing enrollment was silently recreated.");
        Require(scope.Store().CompareAndSwap(null, Head(2, 0x77)), "Could not install the later policy test head.");
        Throws<QPeriaptNativeException>(() => QPeriaptRuntimeSession.Prepare(scope.Store(), identityAlreadyEnrolled: true));
        Require((scope.Store().Load() ?? throw new InvalidOperationException("Missing committed policy head.")).AsSpan().SequenceEqual(Head(2, 0x77)), "Rejected rollback changed the durable head.");
    }

    private static void ExpandedNativeKeys()
    {
        using var scope = new PolicyScope();
        var session = QPeriaptRuntimeSession.Prepare(scope.Store(), false);
        using var original = QPeriaptNativeClient.GenerateKeyPair(session.Decision);
        var expanded = QPeriaptKeyEncoding.ExportPrivate(original);
        try
        {
            using var restored = QPeriaptKeyEncoding.Import(session, expanded);
            var publicKey = QPeriaptKeyEncoding.ExportPublic(restored);
            Require(expanded.Length == 3648 && publicKey.Length == 1216 && publicKey.AsSpan().SequenceEqual(QPeriaptKeyEncoding.ExportPublic(original)),
                "Expanded key storage changed the shared public-key layout.");
            using var encapsulated = QPeriaptNativeClient.Encapsulate(session.Decision, publicKey.AsSpan(0, 1184), publicKey.AsSpan(1184), "context-a"u8);
            using var wrong = QPeriaptNativeClient.Decapsulate(session.Decision, restored, encapsulated.CiphertextPq.Span, encapsulated.CiphertextTraditional.Span, "context-b"u8);
            Require(!CryptographicOperations.FixedTimeEquals(encapsulated.Secret.Bytes.Span, wrong.Bytes.Span), "Changed context reproduced the same secret.");
            restored.Dispose();
            Throws<ObjectDisposedException>(() => QPeriaptKeyEncoding.ExportPrivate(restored));
        }
        finally { CryptographicOperations.ZeroMemory(expanded); }
    }

    private static void DefiniteCommitCancellation()
    {
        using var scope = new PolicyScope();
        using var cancellation = new CancellationTokenSource();
        var committer = new ControllableCommitter { AfterCommit = cancellation.Cancel };
        var session = QPeriaptRuntimeSession.Prepare(scope.Store(committer), false, cancellation.Token);
        Require(cancellation.IsCancellationRequested && session.Decision.CopyTrustedState().AsSpan().SequenceEqual(scope.Store().Load()),
            "A definite policy commit must be returned accurately despite late cancellation.");
    }

    private static byte[] Head(uint version, byte digest)
    { var bytes = Enumerable.Repeat(digest, 36).ToArray(); BinaryPrimitives.WriteUInt32BigEndian(bytes, version); return bytes; }
    private static Task Run(Action action) { action(); return Task.CompletedTask; }
    internal static void Require(bool condition, string message) { if (!condition) { throw new InvalidOperationException(message); } }
    internal static T Throws<T>(Action action) where T : Exception
    { try { action(); } catch (T error) { return error; } throw new InvalidOperationException($"Expected {typeof(T).Name}."); }

    internal sealed class PolicyScope : IDisposable
    {
        internal string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "skybridge-policy-contract-" + Guid.NewGuid().ToString("N"));
        internal PolicyScope() { Directory.CreateDirectory(Path); }
        internal QPeriaptTrustedStateStore Store(ISessionFileCommitter? committer = null) => new(Path, new BufferProtector(), committer ?? AtomicSessionFileCommitter.Instance);
        public void Dispose()
        {
            foreach (var file in Directory.GetFiles(Path, "*", SearchOption.AllDirectories)) { File.SetAttributes(file, FileAttributes.Normal); }
            Directory.Delete(Path, recursive: true);
        }
    }
    internal sealed class BufferProtector : ISessionProtector
    { public byte[] Protect(byte[] value) => (byte[])value.Clone(); public byte[] Unprotect(byte[] value) => (byte[])value.Clone(); }
    internal sealed class ControllableCommitter : ISessionFileCommitter
    {
        internal bool FailBeforeCommit { get; set; }
        internal Action? BeforeCommit { get; init; }
        internal Action? AfterCommit { get; init; }
        public void Commit(string temporaryPath, string destinationPath)
        {
            if (FailBeforeCommit) { throw new IOException("Injected failure before atomic commit."); }
            BeforeCommit?.Invoke();
            AtomicSessionFileCommitter.Instance.Commit(temporaryPath, destinationPath);
            AfterCommit?.Invoke();
        }
    }
}
