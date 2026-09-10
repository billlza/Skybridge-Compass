using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Skybridge.WinClient.Services;

internal enum QPeriaptEnrollmentMode { Existing, AuthorizedFirst }

/// <summary>A verified policy identity. Construction follows the durable trusted-head commit.</summary>
internal sealed class QPeriaptRuntimeSession
{
    private QPeriaptRuntimeSession(QPeriaptPolicyDecision decision, QPeriaptEnrollmentMode enrollmentMode)
    {
        Decision = decision;
        EnrollmentMode = enrollmentMode;
        AuthProfile = $"q-periapt-abi2-policy-v1/{QPeriaptProductionPolicy.RootKeyPinHex}/" +
            $"{Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(QPeriaptProductionPolicy.RootIdentifier)))}/" +
            $"{decision.PolicyVersion.ToString(CultureInfo.InvariantCulture)}/{Convert.ToHexStringLower(decision.CopyPolicyDigestSha3_256())}";
    }

    internal QPeriaptPolicyDecision Decision { get; }
    internal QPeriaptEnrollmentMode EnrollmentMode { get; }
    internal string AuthProfile { get; }

    internal static QPeriaptRuntimeSession Prepare(QPeriaptTrustedStateStore store,
        bool identityAlreadyEnrolled, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(store);
        cancellationToken.ThrowIfCancellationRequested();
        var previous = store.Load();
        if (identityAlreadyEnrolled && previous is null)
        { throw new InvalidDataException("The enrolled identity has no trusted Q-Periapt policy head; re-enrollment is not permitted."); }
        // A policy commit can precede an interrupted identity migration. Resume that
        // enrollment even while the primary identity still has schema 1.
        var mode = previous is null ? QPeriaptEnrollmentMode.AuthorizedFirst : QPeriaptEnrollmentMode.Existing;
        var decision = QPeriaptProductionPolicy.Resolve(previous ?? [], cancellationToken);
        if (!store.CompareAndSwap(previous, decision.CopyTrustedState(), cancellationToken))
        { throw new IOException("The trusted Q-Periapt policy head changed during verification."); }
        // The CAS is definite. Do not report cancellation as if it had not committed.
        var session = new QPeriaptRuntimeSession(decision, mode);
        using var keys = QPeriaptNativeClient.GenerateKeyPair(decision);
        QPeriaptKeyEncoding.Verify(session, keys);
        return session;
    }
}

internal static class QPeriaptProductionPolicy
{
    internal const string RootIdentifier = "skybridge/qperiapt/production-root/v1";
    // This pin is independent of the embedded policy resource.
    internal const string RootKeyPinHex = "98cad7b47b290e8559c9d8fc1985266647830ac1d5168f24a28ad74f04ac75db";
    private const string ResourceName = "Skybridge.QPeriapt.ProductionTrustRoot.json";

    internal static QPeriaptPolicyDecision Resolve(byte[] previous, CancellationToken cancellationToken)
    {
        var material = ReadMaterial();
        var decision = QPeriaptNativeClient.ResolvePolicy(Encoding.UTF8.GetBytes(material.PolicyToml),
            Convert.FromHexString(material.DetachedSignatureHex), Convert.FromHexString(material.VerificationKeyHex),
            Convert.FromHexString(RootKeyPinHex), previous, cancellationToken);
        if (decision.PolicyVersion != material.PolicyVersion ||
            !decision.CopyPolicyDigestSha3_256().AsSpan().SequenceEqual(Convert.FromHexString(material.PolicyDigestHex)))
        { throw new CryptographicException("The verified policy identity does not match the embedded production declaration."); }
        return decision;
    }

    private static PolicyMaterial ReadMaterial()
    {
        using var stream = typeof(QPeriaptProductionPolicy).Assembly.GetManifestResourceStream(ResourceName)
            ?? throw new InvalidDataException("The embedded production Q-Periapt policy is missing.");
        var material = JsonSerializer.Deserialize<PolicyMaterial>(stream)
            ?? throw new InvalidDataException("The embedded production Q-Periapt policy is empty.");
        if (material.SchemaVersion != 1 || material.Algorithm != "ML-DSA-65" ||
            material.RootIdentifier != RootIdentifier || material.RootKeyPinHex != RootKeyPinHex || material.PolicyVersion == 0)
        { throw new InvalidDataException("The embedded Q-Periapt policy does not identify the production root."); }
        return material;
    }

    private sealed class PolicyMaterial
    {
        [JsonPropertyName("schema_version")] public required int SchemaVersion { get; init; }
        [JsonPropertyName("algorithm")] public required string Algorithm { get; init; }
        [JsonPropertyName("trust_root_identifier")] public required string RootIdentifier { get; init; }
        [JsonPropertyName("policy_toml")] public required string PolicyToml { get; init; }
        [JsonPropertyName("policy_version")] public required uint PolicyVersion { get; init; }
        // The schema 1 field has a historical name; the ABI decision contains SHA3-256.
        [JsonPropertyName("policy_digest_sha256_hex")] public required string PolicyDigestHex { get; init; }
        [JsonPropertyName("detached_signature_hex")] public required string DetachedSignatureHex { get; init; }
        [JsonPropertyName("verification_key_hex")] public required string VerificationKeyHex { get; init; }
        [JsonPropertyName("verification_key_sha256_pin_hex")] public required string RootKeyPinHex { get; init; }
    }
}
