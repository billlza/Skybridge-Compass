using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Skybridge.WinClient.Services.RemoteControl;

/// <summary>Public protocol identity and KEM material shared through an explicit user pairing action.</summary>
public sealed class RemoteControlPairingMaterial
{
    private const int MaximumJsonCharacters = 32_768;
    private readonly byte[] _protocolPublicKey;
    private readonly byte[] _kemPublicKey;
    private readonly byte[] _qPublicKey;

    private RemoteControlPairingMaterial(string deviceId, string deviceName,
        ReadOnlySpan<byte> protocolPublicKey, ReadOnlySpan<byte> kemPublicKey, ReadOnlySpan<byte> qPublicKey = default)
    {
        DeviceId = RemoteControlHandshakeBinding.CanonicalDeviceId(deviceId);
        ArgumentException.ThrowIfNullOrWhiteSpace(deviceName);
        var name = deviceName.Trim();
        if (name.Length > 128 || name.Any(char.IsControl))
        { throw new InvalidDataException("Pairing device name must contain at most 128 printable characters."); }
        DeviceName = name;
        var identity = new WebRtcProductProtocolIdentityPublicKey(WebRtcProductSignatureAlgorithm.MlDsa65, protocolPublicKey.ToArray());
        if ((!kemPublicKey.IsEmpty && kemPublicKey.Length != 1184) ||
            (!qPublicKey.IsEmpty && qPublicKey.Length != QPeriaptKeyEncoding.PublicLength) ||
            (kemPublicKey.IsEmpty && qPublicKey.IsEmpty))
        { throw new InvalidDataException("Pairing requires a 1184-byte ML-KEM key, a 1216-byte Q-Periapt key, or both."); }
        _protocolPublicKey = identity.PublicKey.ToArray();
        _kemPublicKey = kemPublicKey.ToArray();
        _qPublicKey = qPublicKey.ToArray();
        ProtocolPublicKeyFingerprint = identity.AuthoritativeFingerprint;
    }

    public string DeviceId { get; }
    public string DeviceName { get; }
    public string ProtocolSigningAlgorithm => "ML-DSA-65";
    public string ProtocolPublicKeyFingerprint { get; }
    public ReadOnlyMemory<byte> ProtocolPublicKey => _protocolPublicKey.ToArray();
    public ReadOnlyMemory<byte> MlKem768PublicKey => _kemPublicKey.ToArray();
    public ReadOnlyMemory<byte> QPeriaptPublicKey => _qPublicKey.ToArray();
    public bool HasQPeriaptKey => _qPublicKey.Length != 0;
    public byte[] IdentityPublicKeyWire => new WebRtcProductProtocolIdentityPublicKey(
        WebRtcProductSignatureAlgorithm.MlDsa65, _protocolPublicKey).Encode();

    public static RemoteControlPairingMaterial Create(string deviceId, string deviceName,
        ReadOnlySpan<byte> protocolPublicKey, ReadOnlySpan<byte> mlKem768PublicKey) =>
        new(deviceId, deviceName, protocolPublicKey, mlKem768PublicKey);

    internal static RemoteControlPairingMaterial CreatePolicyBound(string deviceId, string name,
        ReadOnlySpan<byte> protocolKey, ReadOnlySpan<byte> legacyKemKey, ReadOnlySpan<byte> qKey) =>
        new(deviceId, name, protocolKey, legacyKemKey, qKey);

    internal bool CanAddPolicyBoundKey(RemoteControlPairingMaterial replacement) =>
        !HasQPeriaptKey && replacement.HasQPeriaptKey && DeviceId == replacement.DeviceId &&
        ProtocolPublicKeyFingerprint == replacement.ProtocolPublicKeyFingerprint &&
        _protocolPublicKey.AsSpan().SequenceEqual(replacement._protocolPublicKey) &&
        _kemPublicKey.AsSpan().SequenceEqual(replacement._kemPublicKey);

    /// <summary>protocolPublicKey is the raw ML-DSA-65 public key; its algorithm is explicit, and the fingerprint is recomputed.</summary>
    public string ToJson() => JsonSerializer.Serialize(new
    {
        schemaVersion = 1,
        deviceId = DeviceId,
        name = DeviceName,
        protocolSigningAlgorithm = ProtocolSigningAlgorithm,
        protocolPublicKey = _protocolPublicKey,
        protocolPublicKeyFingerprint = ProtocolPublicKeyFingerprint,
        kemPublicKeys = ExportKemKeys()
    }, new JsonSerializerOptions { WriteIndented = true });

    public static RemoteControlPairingMaterial Parse(string json)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(json);
        if (json.Length > MaximumJsonCharacters) { throw new InvalidDataException("Pairing material exceeds the supported size."); }
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 8 });
        var root = document.RootElement;
        RequireFields(root, "schemaVersion", "deviceId", "name", "protocolSigningAlgorithm", "protocolPublicKey", "protocolPublicKeyFingerprint", "kemPublicKeys");
        if (root.GetProperty("schemaVersion").ValueKind != JsonValueKind.Number ||
            !root.GetProperty("schemaVersion").TryGetInt32(out var version) || version != 1 ||
            RequireString(root, "protocolSigningAlgorithm") != "ML-DSA-65")
        { throw new InvalidDataException("Pairing material requires schema version 1 and ML-DSA-65."); }
        var kemKeys = root.GetProperty("kemPublicKeys");
        if (kemKeys.ValueKind != JsonValueKind.Array || kemKeys.GetArrayLength() is < 1 or > 2)
        { throw new InvalidDataException("Pairing material must contain one or two distinct supported KEM keys."); }
        byte[] legacyKey = [], qKey = [];
        var suites = new HashSet<ushort>();
        byte[] publicKey;
        try
        {
            publicKey = Convert.FromBase64String(RequireString(root, "protocolPublicKey"));
            foreach (var kem in kemKeys.EnumerateArray())
            {
                RequireFields(kem, "suiteWireId", "publicKey");
                if (kem.GetProperty("suiteWireId").ValueKind != JsonValueKind.Number ||
                    !kem.GetProperty("suiteWireId").TryGetUInt16(out var suite) ||
                    suite is not (WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65 or WebRtcProductHandshakeCodec.SuiteQPeriaptPolicyBound) ||
                    !suites.Add(suite))
                { throw new InvalidDataException("Pairing KEM suites must be unique 0x0101 or 0x0012 identities."); }
                var key = Convert.FromBase64String(RequireString(kem, "publicKey"));
                if (suite == WebRtcProductHandshakeCodec.SuiteQPeriaptPolicyBound) { qKey = key; }
                else { legacyKey = key; }
            }
        }
        catch (FormatException ex) { throw new InvalidDataException("Pairing public keys are not valid base64.", ex); }
        var material = CreatePolicyBound(RequireString(root, "deviceId"), RequireString(root, "name"), publicKey, legacyKey, qKey);
        if (!string.Equals(material.ProtocolPublicKeyFingerprint, RequireString(root, "protocolPublicKeyFingerprint"), StringComparison.Ordinal))
        { throw new InvalidDataException("Pairing protocol fingerprint does not match its algorithm and public key."); }
        return material;
    }

    internal bool HasSameAuthority(RemoteControlPairingMaterial other) =>
        DeviceId == other.DeviceId && ProtocolPublicKeyFingerprint == other.ProtocolPublicKeyFingerprint &&
        _protocolPublicKey.AsSpan().SequenceEqual(other._protocolPublicKey) && _kemPublicKey.AsSpan().SequenceEqual(other._kemPublicKey) &&
        _qPublicKey.AsSpan().SequenceEqual(other._qPublicKey);

    private IReadOnlyList<KemKey> ExportKemKeys()
    {
        var result = new List<KemKey>(2);
        if (HasQPeriaptKey) { result.Add(new(WebRtcProductHandshakeCodec.SuiteQPeriaptPolicyBound, _qPublicKey)); }
        if (_kemPublicKey.Length != 0) { result.Add(new(WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65, _kemPublicKey)); }
        return result;
    }

    private sealed record KemKey([property: JsonPropertyName("suiteWireId")] ushort Suite,
        [property: JsonPropertyName("publicKey")] byte[] PublicKey);

    private static string RequireString(JsonElement element, string name)
    {
        var value = element.GetProperty(name);
        if (value.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(value.GetString()))
        { throw new InvalidDataException($"Pairing {name} must be a nonempty string."); }
        return value.GetString()!;
    }

    private static void RequireFields(JsonElement element, params string[] fields)
    {
        if (element.ValueKind != JsonValueKind.Object) { throw new InvalidDataException("Pairing material must contain an object."); }
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
        {
            if (!names.Add(property.Name) || !fields.Contains(property.Name, StringComparer.Ordinal))
            { throw new InvalidDataException("Pairing material contains duplicate or unsupported fields."); }
        }
        if (names.Count != fields.Length) { throw new InvalidDataException("Pairing material is missing required fields."); }
    }
}
