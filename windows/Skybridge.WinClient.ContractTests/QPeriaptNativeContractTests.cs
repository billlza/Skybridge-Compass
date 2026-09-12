using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Skybridge.WinClient.Services;

internal static class QPeriaptNativeContractTests
{
    private const string RootKeySha256 = "98cad7b47b290e8559c9d8fc1985266647830ac1d5168f24a28ad74f04ac75db";
    private const string PolicyDigestSha3_256 = "eb583259f4fd8c19ae720e0d92bcc13bad1870e337151f2c1afe180a557111c6";

    internal static readonly (string Name, Func<Task> Run)[] Cases =
    [
        ("Q ABI 2 metadata resolves through the real Core library", MetadataAsync),
        ("Q production public policy pin and exact trusted head are enforced", () => Run(PolicyAuthority)),
        ("Q policy native statuses preserve output and alias contracts", () => Run(PolicyErrorContract)),
        ("Q key generation preserves native output and alias contracts", () => Run(KeyGenerationErrorContract)),
        ("Q native key exchange binds exact application context", () => Run(ContextBoundRoundTrip)),
        ("Q encapsulation rejects component lengths and invalid public shares", () => Run(EncapsulationErrorContract)),
        ("Q decapsulation checks all six component extents", () => Run(DecapsulationErrorContract)),
        ("Q native result retirement and cancellation erase secret buffers", () => Run(ResultOwnership)),
        ("Q cancelled operations and disposed key owners reject publication", () => Run(CancelledAdmission)),
        ("Q independent native key exchanges complete concurrently", ConcurrentRoundTripsAsync)
    ];

    private static async Task MetadataAsync()
    {
        QPeriaptNativeClient.VerifyRuntime();
        Require(CoreBridge.QPeriaptAbiVersion() == 2, "ABI version must be 2.");
        Require(await new CoreBridge().InitializeAsync(), "Core initialization must include actual Q metadata admission.");
    }

    private static void PolicyAuthority()
    {
        var policy = LoadPolicy();
        var decision = Resolve(policy);
        Require(decision.PolicyVersion == 1, "Production fixture policy version must be 1.");
        Require(decision.CopyPolicyDigestSha3_256().AsSpan().SequenceEqual(Convert.FromHexString(PolicyDigestSha3_256)),
            "The ABI trusted head must contain SHA3-256 of the exact policy bytes.");
        var state = decision.CopyTrustedState();
        Require(state.Length == 36 && BinaryPrimitives.ReadUInt32BigEndian(state) == 1, "Trusted head encoding must be exact.");
        Require(Resolve(policy, state).CopyEncoded().AsSpan().SequenceEqual(decision.CopyEncoded()), "Same trusted head must be accepted.");
        BinaryPrimitives.WriteUInt32BigEndian(state, 2);
        ExpectNative("q_periapt_decision_from_signed_policy", -3, "ERR_POLICY", () => Resolve(policy, state));
        state = decision.CopyTrustedState();
        state[^1] ^= 1;
        ExpectNative("q_periapt_decision_from_signed_policy", -3, "ERR_POLICY", () => Resolve(policy, state));
        var wrongPin = Convert.FromHexString(RootKeySha256);
        wrongPin[0] ^= 1;
        Throws<CryptographicException>(() => QPeriaptNativeClient.ResolvePolicy(
            policy.Policy, policy.Signature, policy.Key, wrongPin, []));
        var badSignature = (byte[])policy.Signature.Clone();
        badSignature[0] ^= 1;
        ExpectNative("q_periapt_decision_from_signed_policy", -3, "ERR_POLICY", () => QPeriaptNativeClient.ResolvePolicy(
            policy.Policy, badSignature, policy.Key, Convert.FromHexString(RootKeySha256), []));
        var encodedCopy = decision.CopyEncoded();
        Array.Clear(encodedCopy);
        Require(decision.PolicyVersion == 1 && decision.CopyEncoded()[0] == 1, "Returned copies cannot mutate the decision.");
        Throws<CryptographicException>(() => new QPeriaptPolicyDecision(encodedCopy));
        Throws<ArgumentException>(() => Resolve(policy, new byte[4]));
    }

    private static void PolicyErrorContract()
    {
        var policy = LoadPolicy();
        foreach (var delta in new[] { -1, 1 })
        {
            var output = Filled(40);
            Require(CoreBridge.QPeriaptResolvePolicy(policy.Policy, Resize(policy.Signature, delta), policy.Key, [], output) == -3,
                "Signature length mismatch must remain ERR_POLICY.");
            RequireZero(output, "Policy signature failure must clear a valid decision output.");
            Array.Fill(output, (byte)0xA5);
            Require(CoreBridge.QPeriaptResolvePolicy(policy.Policy, policy.Signature, Resize(policy.Key, delta), [], output) == -3,
                "Verification key length mismatch must remain ERR_POLICY.");
            RequireZero(output, "Policy key failure must clear a valid decision output.");
        }
        var invalidStateOutput = Filled(40);
        Require(CoreBridge.QPeriaptResolvePolicy(policy.Policy, policy.Signature, policy.Key, new byte[4], invalidStateOutput) == -2,
            "Legacy four-byte state must be ERR_LENGTH.");
        RequireZero(invalidStateOutput, "Invalid trusted state must clear the decision.");
        var shortOutput = Filled(39);
        Require(CoreBridge.QPeriaptResolvePolicy(policy.Policy, policy.Signature, policy.Key, [], shortOutput) == -2,
            "Invalid decision output extent must be ERR_LENGTH.");
        RequireFilled(shortOutput, "Invalid output extent must remain untouched.");
        var alias = (byte[])policy.Policy.Clone();
        Require(CoreBridge.QPeriaptResolvePolicy(alias, policy.Signature, policy.Key, [], alias) == -7,
            "The CLR boundary must preserve array identity for native alias rejection.");
        Require(alias.AsSpan().SequenceEqual(policy.Policy), "Policy alias rejection must not modify shared input/output bytes.");
    }

    private static void KeyGenerationErrorContract()
    {
        var decision = Resolve(LoadPolicy());
        var privatePq = Filled(2400);
        var publicPq = Filled(1184);
        var privateTraditional = Filled(32);
        var publicTraditional = Filled(32);
        try
        {
            Require(CoreBridge.QPeriaptGenerateKeyPair(new byte[40], privatePq, publicPq, privateTraditional, publicTraditional) == -3,
                "Invalid fixed-suite decision must be ERR_POLICY.");
            foreach (var output in new[] { privatePq, publicPq, privateTraditional, publicTraditional })
            {
                RequireZero(output, "Policy rejection must clear every valid key output.");
                Array.Fill(output, (byte)0xA5);
            }
            Require(CoreBridge.QPeriaptGenerateKeyPair(decision.CopyEncoded(), privatePq, publicPq, privateTraditional, privateTraditional) == -7,
                "Overlapping key outputs must be ERR_ALIASING.");
            foreach (var output in new[] { privatePq, publicPq, privateTraditional })
            {
                RequireFilled(output, "Alias rejection must not change any key output.");
            }
            var shortPrivate = Filled(2399);
            try
            {
                Require(CoreBridge.QPeriaptGenerateKeyPair(decision.CopyEncoded(), shortPrivate, publicPq, privateTraditional, publicTraditional) == -2,
                    "Invalid key output extent must be ERR_LENGTH.");
                RequireFilled(shortPrivate, "Invalid private-key output extent must remain untouched.");
            }
            finally { CryptographicOperations.ZeroMemory(shortPrivate); }
        }
        finally
        {
            foreach (var output in new[] { privatePq, publicPq, privateTraditional, publicTraditional })
            {
                CryptographicOperations.ZeroMemory(output);
            }
        }
    }

    private static void ContextBoundRoundTrip()
    {
        var decision = Resolve(LoadPolicy());
        using var keys = QPeriaptNativeClient.GenerateKeyPair(decision);
        foreach (var context in new[] { Array.Empty<byte>(), Encoding.UTF8.GetBytes("skybridge/core/native-contract/v1"), new byte[65536] })
        {
            using var encapsulated = QPeriaptNativeClient.Encapsulate(decision, keys.CopyPublicPq(), keys.CopyPublicTraditional(), context);
            using var opened = QPeriaptNativeClient.Decapsulate(decision, keys, encapsulated.CiphertextPq.Span,
                encapsulated.CiphertextTraditional.Span, context);
            Require(CryptographicOperations.FixedTimeEquals(encapsulated.Secret.Bytes.Span, opened.Bytes.Span), "Native secrets must agree.");
            using var differentContext = QPeriaptNativeClient.Decapsulate(decision, keys, encapsulated.CiphertextPq.Span,
                encapsulated.CiphertextTraditional.Span, "different-context"u8);
            Require(!CryptographicOperations.FixedTimeEquals(encapsulated.Secret.Bytes.Span, differentContext.Bytes.Span),
                "Wrong context changes the derived secret; the later product Finished check owns authentication failure.");
        }
    }

    private static void EncapsulationErrorContract()
    {
        var decision = Resolve(LoadPolicy());
        using var keys = QPeriaptNativeClient.GenerateKeyPair(decision);
        var publicPq = keys.CopyPublicPq();
        var publicTraditional = keys.CopyPublicTraditional();
        foreach (var delta in new[] { -1, 1 })
        {
            RequireEncapsulationFailure(decision, Resize(publicPq, delta), publicTraditional, [], -2);
            RequireEncapsulationFailure(decision, publicPq, Resize(publicTraditional, delta), [], -2);
        }
        RequireEncapsulationFailure(decision, publicPq, publicTraditional, new byte[65537], -2);
        RequireEncapsulationFailure(decision, publicPq, new byte[32], [], -6);
        var ciphertextPq = Filled(1088);
        var alias = Filled(32);
        try
        {
            Require(CoreBridge.QPeriaptEncapsulate(decision.CopyEncoded(), publicPq, publicTraditional, [], ciphertextPq, alias, alias) == -7,
                "Ciphertext/secret overlap must be ERR_ALIASING.");
            RequireFilled(alias, "Aliased secret output must remain untouched.");
            RequireFilled(ciphertextPq, "Alias rejection must not write other ciphertext outputs.");
        }
        finally { CryptographicOperations.ZeroMemory(alias); }
    }

    private static void DecapsulationErrorContract()
    {
        var decision = Resolve(LoadPolicy());
        using var keys = QPeriaptNativeClient.GenerateKeyPair(decision);
        using var encapsulated = QPeriaptNativeClient.Encapsulate(decision, keys.CopyPublicPq(), keys.CopyPublicTraditional(), []);
        using var captured = keys.Capture();
        var components = new[] { captured.PrivatePq, encapsulated.CiphertextPq.ToArray(), captured.PublicPq,
            captured.PrivateTraditional, encapsulated.CiphertextTraditional.ToArray(), captured.PublicTraditional };
        for (var component = 0; component < components.Length; component++)
        {
            foreach (var delta in new[] { -1, 1 })
            {
                var altered = Resize(components[component], delta);
                var inputs = (byte[][])components.Clone();
                inputs[component] = altered;
                var output = Filled(32);
                try
                {
                    Require(RawDecapsulate(decision, inputs, [], output) == -2, "Each incorrect KEM component extent must be ERR_LENGTH.");
                    RequireZero(output, "Component error must clear the valid secret output.");
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(altered);
                    CryptographicOperations.ZeroMemory(output);
                }
            }
        }
        var savedPrivate = (byte[])captured.PrivateTraditional.Clone();
        try
        {
            Require(RawDecapsulate(decision, components, [], captured.PrivateTraditional) == -7, "Private-key/secret overlap must be ERR_ALIASING.");
            Require(CryptographicOperations.FixedTimeEquals(savedPrivate, captured.PrivateTraditional), "Alias rejection must preserve the private key.");
        }
        finally { CryptographicOperations.ZeroMemory(savedPrivate); }
    }

    private static void ResultOwnership()
    {
        var decision = Resolve(LoadPolicy());
        using var keys = QPeriaptNativeClient.GenerateKeyPair(decision);
        using var encapsulated = QPeriaptNativeClient.Encapsulate(decision, keys.CopyPublicPq(), keys.CopyPublicTraditional(), []);
        using var captured = keys.Capture();
        var components = new[] { captured.PrivatePq, encapsulated.CiphertextPq.ToArray(), captured.PublicPq,
            captured.PrivateTraditional, encapsulated.CiphertextTraditional.ToArray(), captured.PublicTraditional };
        var nativeSecret = Filled(32);
        try
        {
            Require(RawDecapsulate(decision, components, [], nativeSecret) == 0, "A real native result must exist before retirement.");
            Require(CryptographicOperations.FixedTimeEquals(nativeSecret, encapsulated.Secret.Bytes.Span), "The pending native secret must be correct.");
            keys.Dispose();
            Throws<ObjectDisposedException>(() => keys.CommitSecret(nativeSecret, default));
            RequireZero(nativeSecret, "A late result from a retired owner must be erased.");
            Throws<ObjectDisposedException>(() => keys.Capture());
            Require(RawDecapsulate(decision, components, [], nativeSecret) == 0, "Owned snapshots stay valid independently of the retired owner.");
            using var cancelled = new CancellationTokenSource();
            cancelled.Cancel();
            Throws<OperationCanceledException>(() => QPeriaptNativeClient.TakeSecret(nativeSecret, cancelled.Token));
            RequireZero(nativeSecret, "Cancellation at the actual secret handoff must erase the native result.");
            Require(RawDecapsulate(decision, components, [], nativeSecret) == 0, "A fresh native output must be available for ownership transfer.");
            using var accepted = QPeriaptNativeClient.TakeSecret(nativeSecret, default);
            RequireZero(nativeSecret, "Successful handoff must erase the borrowed native buffer.");
            var acceptedBorrow = accepted.Bytes;
            accepted.Dispose();
            RequireZero(acceptedBorrow.Span, "Disposing the existing product secret owner must erase its allocation.");
            Throws<ObjectDisposedException>(() => _ = accepted.Bytes);
            var snapshotPrivate = captured.PrivatePq;
            captured.Dispose();
            RequireZero(snapshotPrivate, "Disposing a private-key snapshot must erase its bytes.");
        }
        finally { CryptographicOperations.ZeroMemory(nativeSecret); }
    }

    private static void CancelledAdmission()
    {
        var policy = LoadPolicy();
        var decision = Resolve(policy);
        using var keys = QPeriaptNativeClient.GenerateKeyPair(decision);
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        Throws<OperationCanceledException>(() => QPeriaptNativeClient.ResolvePolicy(policy.Policy, policy.Signature,
            policy.Key, Convert.FromHexString(RootKeySha256), [], cancelled.Token));
        Throws<OperationCanceledException>(() => { using var unexpected = QPeriaptNativeClient.GenerateKeyPair(decision, cancelled.Token); });
        Throws<OperationCanceledException>(() => { using var unexpected = QPeriaptNativeClient.Encapsulate(
            decision, keys.CopyPublicPq(), keys.CopyPublicTraditional(), [], cancelled.Token); });
        Throws<OperationCanceledException>(() => { using var unexpected = QPeriaptNativeClient.Decapsulate(
            decision, keys, new byte[1088], new byte[32], [], cancelled.Token); });
        keys.Dispose();
        Throws<ObjectDisposedException>(() => { using var unexpected = QPeriaptNativeClient.Decapsulate(decision, keys, new byte[1088], new byte[32], []); });
    }

    private static Task ConcurrentRoundTripsAsync()
    {
        var decision = Resolve(LoadPolicy());
        return Task.WhenAll(Enumerable.Range(0, 4).Select(index => Task.Run(() =>
        {
            using var keys = QPeriaptNativeClient.GenerateKeyPair(decision);
            var context = Encoding.UTF8.GetBytes($"independent-native-call/{index}");
            using var encapsulated = QPeriaptNativeClient.Encapsulate(decision, keys.CopyPublicPq(), keys.CopyPublicTraditional(), context);
            using var opened = QPeriaptNativeClient.Decapsulate(decision, keys, encapsulated.CiphertextPq.Span,
                encapsulated.CiphertextTraditional.Span, context);
            Require(CryptographicOperations.FixedTimeEquals(encapsulated.Secret.Bytes.Span, opened.Bytes.Span), "Independent concurrent calls must keep their own buffers.");
        })));
    }

    private static int RawDecapsulate(QPeriaptPolicyDecision decision, byte[][] parts, byte[] context, byte[] output) =>
        CoreBridge.QPeriaptDecapsulate(decision.CopyEncoded(), parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], context, output);

    private static void RequireEncapsulationFailure(QPeriaptPolicyDecision decision, byte[] publicPq, byte[] publicTraditional, byte[] context, int expectedCode)
    {
        var ciphertextPq = Filled(1088);
        var ciphertextTraditional = Filled(32);
        var secret = Filled(32);
        try
        {
            Require(CoreBridge.QPeriaptEncapsulate(decision.CopyEncoded(), publicPq, publicTraditional, context,
                ciphertextPq, ciphertextTraditional, secret) == expectedCode, "Encapsulation must preserve the exact native status.");
            RequireZero(ciphertextPq, "Failed encapsulation must clear PQ ciphertext.");
            RequireZero(ciphertextTraditional, "Failed encapsulation must clear traditional ciphertext.");
            RequireZero(secret, "Failed encapsulation must clear the secret.");
        }
        finally { CryptographicOperations.ZeroMemory(secret); }
    }

    private static QPeriaptPolicyDecision Resolve(PolicyInputs inputs, byte[]? previousState = null) =>
        QPeriaptNativeClient.ResolvePolicy(inputs.Policy, inputs.Signature, inputs.Key, Convert.FromHexString(RootKeySha256), previousState ?? []);

    private static PolicyInputs LoadPolicy()
    {
        var fixture = JsonSerializer.Deserialize<ProductionPolicyFixture>(File.ReadAllText(
            Path.Combine(AppContext.BaseDirectory, "Fixtures", "qperiapt-production-trust-root.json")))
            ?? throw new InvalidDataException("The production public-policy fixture is missing.");
        Require(fixture.SchemaVersion == 1 && fixture.PolicyVersion == 1 && fixture.TrustRootIdentifier == "skybridge/qperiapt/production-root/v1",
            "The selected fixture must identify the existing production root.");
        Require(fixture.PolicyStateDigestSha3_256Hex == PolicyDigestSha3_256, "The legacy schema field must map explicitly to SHA3-256.");
        var key = Convert.FromHexString(fixture.VerificationKeyHex);
        Require(CryptographicOperations.FixedTimeEquals(SHA256.HashData(key), Convert.FromHexString(RootKeySha256)),
            "The independently compiled pin must match the production verification key.");
        return new PolicyInputs(Encoding.UTF8.GetBytes(fixture.PolicyToml), Convert.FromHexString(fixture.DetachedSignatureHex), key);
    }

    private sealed record PolicyInputs(byte[] Policy, byte[] Signature, byte[] Key);

    private sealed class ProductionPolicyFixture
    {
        [JsonPropertyName("schema_version")] public int SchemaVersion { get; init; }
        [JsonPropertyName("trust_root_identifier")] public required string TrustRootIdentifier { get; init; }
        [JsonPropertyName("policy_toml")] public required string PolicyToml { get; init; }
        [JsonPropertyName("policy_version")] public uint PolicyVersion { get; init; }
        // Schema 1 used a misleading historical wire name. The signed bytes and
        // trust root are unchanged; ABI 2 defines this state digest as SHA3-256.
        [JsonPropertyName("policy_digest_sha256_hex")] public required string PolicyStateDigestSha3_256Hex { get; init; }
        [JsonPropertyName("detached_signature_hex")] public required string DetachedSignatureHex { get; init; }
        [JsonPropertyName("verification_key_hex")] public required string VerificationKeyHex { get; init; }
    }

    private static void ExpectNative(string operation, int code, string status, Action action)
    {
        var error = Throws<QPeriaptNativeException>(action);
        Require(error.Operation == operation && error.StatusCode == code && error.StatusName == status, "Native failure must preserve operation, code and status name.");
    }

    private static T Throws<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T error) { return error; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private static Task Run(Action action) { action(); return Task.CompletedTask; }
    private static byte[] Filled(int length) { var bytes = new byte[length]; Array.Fill(bytes, (byte)0xA5); return bytes; }
    private static byte[] Resize(byte[] bytes, int delta) { var result = new byte[bytes.Length + delta]; bytes.AsSpan(0, Math.Min(bytes.Length, result.Length)).CopyTo(result); return result; }
    private static void RequireZero(ReadOnlySpan<byte> bytes, string message) => Require(!bytes.ContainsAnyExcept((byte)0), message);
    private static void RequireFilled(ReadOnlySpan<byte> bytes, string message) => Require(!bytes.ContainsAnyExcept((byte)0xA5), message);
    private static void Require(bool condition, string message) { if (!condition) { throw new InvalidOperationException(message); } }
}
