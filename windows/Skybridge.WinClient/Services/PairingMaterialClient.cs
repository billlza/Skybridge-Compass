using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface IPairingMaterialClient
{
    Task<PairingMaterialSnapshot> BuildReadOnlySnapshotAsync(
        string connectionCode,
        string? expectedPublicKeyFingerprint);
}

public sealed class PairingMaterialClient : IPairingMaterialClient
{
    private const string Prefix = "skybridge-pair:v1";

    public Task<PairingMaterialSnapshot> BuildReadOnlySnapshotAsync(
        string connectionCode,
        string? expectedPublicKeyFingerprint)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionCode);

        var fields = ParseFields(connectionCode);
        var deviceId = Required(fields, "deviceId");
        var encodedPublicKey = Required(fields, "pubKey");
        var declaredFingerprint = Required(fields, "pubKeyFP");
        if (!IsLowerHexFingerprint(declaredFingerprint))
        {
            throw new InvalidOperationException("Pairing code pubKeyFP must be 64 lowercase hex characters.");
        }

        var peerPublicKey = DecodeBase64Url(encodedPublicKey);
        if (peerPublicKey.Length == 0)
        {
            throw new InvalidOperationException("Pairing code peer public key must not be empty.");
        }

        var calculatedFingerprint = FormatHex(SHA256.HashData(peerPublicKey));
        if (!string.Equals(calculatedFingerprint, declaredFingerprint, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Pairing code public key does not match pubKeyFP.");
        }

        var verifiedAgainstDiscovery = false;
        if (!string.IsNullOrWhiteSpace(expectedPublicKeyFingerprint))
        {
            if (!IsLowerHexFingerprint(expectedPublicKeyFingerprint))
            {
                throw new InvalidOperationException("Discovery pubKeyFP must be 64 lowercase hex characters.");
            }

            if (!string.Equals(
                expectedPublicKeyFingerprint,
                declaredFingerprint,
                StringComparison.Ordinal))
            {
                throw new InvalidOperationException("Pairing code pubKeyFP does not match the discovered peer fingerprint.");
            }

            verifiedAgainstDiscovery = true;
        }

        var material = new PairingMaterial(
            deviceId,
            fields.GetValueOrDefault("name", deviceId),
            fields.GetValueOrDefault("platform", "unknown"),
            declaredFingerprint,
            peerPublicKey,
            verifiedAgainstDiscovery,
            "manual connection code");

        return Task.FromResult(new PairingMaterialSnapshot(
            material,
            new List<PairingFact>
            {
                new("Device", material.DeviceId, $"{material.DisplayName} / {material.PlatformLabel}"),
                new("Public key fingerprint", material.PublicKeyFingerprint, "Verified against connection-code public key bytes."),
                new(
                    "Discovery fingerprint",
                    material.VerifiedAgainstDiscoveryFingerprint ? "matched" : "not provided",
                    "Discovery pubKeyFP is verification input only; it is never used as the peer public key."),
                new("Peer key provider", "available", "Pairing material can create IPeerPublicKeyProvider for FfiEngineClient when native DLL deployment is explicit."),
                new("Source", material.Source, "Manual validation only; no connection attempt is started.")
            }));
    }

    private static Dictionary<string, string> ParseFields(string connectionCode)
    {
        var parts = connectionCode.Trim().Split(';', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0 || !string.Equals(parts[0], Prefix, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Pairing code must start with skybridge-pair:v1.");
        }

        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 1; index < parts.Length; index++)
        {
            var separator = parts[index].IndexOf('=');
            if (separator <= 0 || separator == parts[index].Length - 1)
            {
                throw new InvalidOperationException("Pairing code contains a malformed key/value field.");
            }

            var key = parts[index][..separator];
            var value = parts[index][(separator + 1)..];
            fields[key] = Uri.UnescapeDataString(value);
        }

        return fields;
    }

    private static string Required(IReadOnlyDictionary<string, string> fields, string key)
    {
        if (!fields.TryGetValue(key, out var value) || string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException($"Pairing code missing required field: {key}.");
        }

        return value;
    }

    private static byte[] DecodeBase64Url(string value)
    {
        var normalized = value.Trim().Replace('-', '+').Replace('_', '/');
        normalized = normalized.PadRight(
            normalized.Length + ((4 - normalized.Length % 4) % 4),
            '=');

        try
        {
            return Convert.FromBase64String(normalized);
        }
        catch (FormatException ex)
        {
            throw new InvalidOperationException("Pairing code pubKey is not valid base64/base64url.", ex);
        }
    }

    private static bool IsLowerHexFingerprint(string value)
    {
        if (value.Length != 64)
        {
            return false;
        }

        foreach (var ch in value)
        {
            if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')))
            {
                return false;
            }
        }

        return true;
    }

    private static string FormatHex(byte[] bytes)
    {
        var builder = new StringBuilder(bytes.Length * 2);
        foreach (var value in bytes)
        {
            builder.Append(value.ToString("x2"));
        }

        return builder.ToString();
    }
}

public sealed record PairingMaterialSnapshot(
    PairingMaterial Material,
    IReadOnlyList<PairingFact> Facts);

public sealed record PairingFact(
    string Label,
    string Value,
    string Detail);

public sealed record PairingMaterial(
    string DeviceId,
    string DisplayName,
    string PlatformLabel,
    string PublicKeyFingerprint,
    byte[] PeerPublicKey,
    bool VerifiedAgainstDiscoveryFingerprint,
    string Source)
{
    public IPeerPublicKeyProvider ToPeerPublicKeyProvider() =>
        new StaticPeerPublicKeyProvider(PeerPublicKey);
}
