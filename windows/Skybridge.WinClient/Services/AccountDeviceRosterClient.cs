using System.Net;
using System.Net.Http;
using System.Text.Json;

namespace Skybridge.WinClient.Services;

internal sealed record AccountDeviceEntry(string DeviceId, string DeviceName, string Status,
    string Algorithm, string Fingerprint, string? Platform, string? Model, string? OsVersion,
    string? AppVersion, long? LastSeenAt, bool Online, bool IsCaller)
{
    internal string Identity => DeviceId + "/" + Algorithm + "/" + Fingerprint;
}
internal sealed record AccountDeviceRosterSnapshot(long GeneratedAt, string CallerDeviceId, bool Truncated,
    IReadOnlyList<AccountDeviceEntry> Devices);
internal sealed record AccountDeviceMetadata(string DeviceName, string? DeviceModel, string OsVersion, string[] LanAddresses);
internal interface IAccountDeviceRosterClient
{
    Task<AccountDeviceRosterSnapshot> RefreshAsync(AccountDeviceAuthentication auth, CurrentPathProtocolIdentityBinding binding,
        AccountDeviceMetadata metadata, CancellationToken cancellationToken);
}

// Use the same bounded signaling HTTP path as all other current-path requests.
// No direct table query: the service overlays only exact registered identities
// with live presence and authorizes the tenant/user from the verified bearer.
internal sealed class AccountDeviceRosterClient(HttpClient httpClient) : IAccountDeviceRosterClient
{
    public async Task<AccountDeviceRosterSnapshot> RefreshAsync(AccountDeviceAuthentication auth,
        CurrentPathProtocolIdentityBinding binding, AccountDeviceMetadata metadata, CancellationToken cancellationToken)
    {
        var client = new CurrentPathSignalServerClient(httpClient, new CurrentPathSignalServerClientOptions(
            bearerTokenProvider: _ => Task.FromResult(auth.AccessToken), tenantIdProvider: _ => Task.FromResult(auth.TenantId),
            clientVersion: "1.0.2"));
        await client.PublishAccountPresenceAsync(binding, metadata, cancellationToken).ConfigureAwait(false);
        AccountDeviceRosterSnapshot snapshot;
        bool enrollmentAttempted = false;
        try { snapshot = await client.ListAccountDevicesAsync(binding, cancellationToken).ConfigureAwait(false); }
        catch (CurrentPathSignalServerException error) when (AccountDeviceWire.ErrorCode(error) == "device_not_registered")
        {
            enrollmentAttempted = true;
            await client.RegisterAccountDeviceAsync(auth, binding, metadata.DeviceName, cancellationToken).ConfigureAwait(false);
            await client.PublishAccountPresenceAsync(binding, metadata, cancellationToken).ConfigureAwait(false);
            snapshot = await client.ListAccountDevicesAsync(binding, cancellationToken).ConfigureAwait(false);
        }
        // The service may admit a read before enrollment. Only a complete EMPTY
        // registry may bootstrap itself; an existing account needs trusted approval.
        if (!enrollmentAttempted && !snapshot.Truncated && snapshot.Devices.Count == 0)
        {
            await client.RegisterAccountDeviceAsync(auth, binding, metadata.DeviceName, cancellationToken).ConfigureAwait(false);
            await client.PublishAccountPresenceAsync(binding, metadata, cancellationToken).ConfigureAwait(false);
            snapshot = await client.ListAccountDevicesAsync(binding, cancellationToken).ConfigureAwait(false);
        }
        return snapshot;
    }
}

public sealed partial class CurrentPathSignalServerClient
{
    private IReadOnlyDictionary<string, string> AccountVersionHeaders => new Dictionary<string, string>
    {
        ["X-SkyBridge-Client-Version"] = _options.ClientVersion,
        ["X-SkyBridge-Protocol-Version"] = _options.ProtocolVersion
    };
    internal async Task PublishAccountPresenceAsync(CurrentPathProtocolIdentityBinding binding, AccountDeviceMetadata metadata, CancellationToken ct)
    {
        var response = await PerformJsonRequestAsync<JsonElement>("/api/presence/register", HttpMethod.Post, new
        {
            deviceId = binding.DeviceId,
            protocolSigningAlgorithm = binding.ProtocolSigningAlgorithmWireName,
            protocolPublicKeyFingerprint = binding.ProtocolPublicKeyFingerprint,
            clientVersion = _options.ClientVersion,
            protocolVersion = _options.ProtocolVersion,
            deviceName = metadata.DeviceName,
            platform = "windows",
            deviceModel = metadata.DeviceModel,
            osVersion = metadata.OsVersion,
            lanAddresses = metadata.LanAddresses,
            capabilities = new[] { "file_transfer", "remote_desktop" }
        }, true, AccountVersionHeaders, ct).ConfigureAwait(false);
        if (!AccountDeviceWire.Boolean(response, "online") || AccountDeviceWire.Integer(response, "ttlMs") != 90_000
            || AccountDeviceWire.Integer(response, "expiresAt") <= 0)
            throw new InvalidDataException("Presence response is invalid.");
        bool persisted = AccountDeviceWire.Boolean(response, "persisted");
        string reason = AccountDeviceWire.Text(response, "persistReason");
        if (!persisted && reason is not ("throttled" or "device_not_active"))
            throw new CurrentPathSignalServerException(reason == "registry_not_configured" ? reason : "registry_unavailable", HttpStatusCode.ServiceUnavailable);
    }

    internal async Task RegisterAccountDeviceAsync(AccountDeviceAuthentication auth, CurrentPathProtocolIdentityBinding binding, string name, CancellationToken ct)
    {
        var response = await PerformJsonRequestAsync<JsonElement>("/api/devices/register-current", HttpMethod.Post, new
        {
            deviceId = binding.DeviceId,
            protocolSigningAlgorithm = binding.ProtocolSigningAlgorithmWireName,
            protocolPublicKeyFingerprint = binding.ProtocolPublicKeyFingerprint,
            deviceName = name,
            clientVersion = _options.ClientVersion,
            protocolVersion = _options.ProtocolVersion
        }, true, AccountVersionHeaders, ct).ConfigureAwait(false);
        var row = AccountDeviceWire.Member(response, "device");
        if (!AccountDeviceWire.Boolean(response, "registered") || AccountDeviceWire.Text(row, "tenant_id") != auth.TenantId
            || AccountDeviceWire.Text(row, "user_id") != auth.Subject || AccountDeviceWire.Text(row, "device_id") != binding.DeviceId
            || AccountDeviceWire.Text(row, "protocol_signing_algorithm") != binding.ProtocolSigningAlgorithmWireName
            || AccountDeviceWire.Text(row, "protocol_public_key_fingerprint") != binding.ProtocolPublicKeyFingerprint
            || AccountDeviceWire.Text(row, "status") != "active")
            throw new InvalidDataException("Device enrollment changed the authenticated account or protocol identity.");
    }

    internal async Task<AccountDeviceRosterSnapshot> ListAccountDevicesAsync(CurrentPathProtocolIdentityBinding binding, CancellationToken ct)
    {
        string path = "/api/devices/list?deviceId=" + Uri.EscapeDataString(binding.DeviceId)
            + "&protocolSigningAlgorithm=" + Uri.EscapeDataString(binding.ProtocolSigningAlgorithmWireName)
            + "&protocolPublicKeyFingerprint=" + Uri.EscapeDataString(binding.ProtocolPublicKeyFingerprint);
        var response = await PerformJsonRequestAsync<JsonElement>(path, HttpMethod.Get, null, true, AccountVersionHeaders, ct).ConfigureAwait(false);
        long generated = AccountDeviceWire.Integer(response, "generatedAt");
        if (generated <= 0 || generated > 253402300799999L || AccountDeviceWire.Text(response, "callerDeviceId") != binding.DeviceId)
            throw new InvalidDataException("Account device snapshot caller or timestamp is invalid.");
        bool truncated = AccountDeviceWire.Boolean(response, "truncated");
        var rows = AccountDeviceWire.Member(response, "devices");
        if (rows.ValueKind != JsonValueKind.Array || rows.GetArrayLength() > 200) throw new InvalidDataException("Account device list is not a bounded array.");
        var devices = new List<AccountDeviceEntry>(); var identities = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in rows.EnumerateArray())
        {
            string id = CurrentPathProtocolIdentityBinding.NormalizeDeviceId(AccountDeviceWire.Text(row, "deviceId"));
            string algorithm = AccountDeviceWire.Text(row, "protocolSigningAlgorithm");
            _ = CurrentPathProtocolSigningAlgorithms.ParseWireName(algorithm);
            string fingerprint = AccountDeviceWire.Text(row, "protocolPublicKeyFingerprint");
            if (!CurrentPathProtocolIdentityBinding.IsLowerHex(fingerprint, 64)) throw new InvalidDataException("Invalid registered identity fingerprint.");
            bool caller = AccountDeviceWire.Boolean(row, "isCaller");
            bool exact = id == binding.DeviceId && algorithm == binding.ProtocolSigningAlgorithmWireName && fingerprint == binding.ProtocolPublicKeyFingerprint;
            if (caller != exact) throw new InvalidDataException("Caller flag does not match the complete device identity.");
            string state = AccountDeviceWire.Text(row, "status");
            if (state is not ("active" or "pending" or "frozen")) throw new InvalidDataException("Unexpected registry status.");
            var device = new AccountDeviceEntry(id, AccountDeviceWire.OptionalText(row, "deviceName") ?? id, state, algorithm, fingerprint,
                AccountDeviceWire.OptionalText(row, "platform"), AccountDeviceWire.OptionalText(row, "deviceModel"),
                AccountDeviceWire.OptionalText(row, "osVersion"), AccountDeviceWire.OptionalText(row, "appVersion"),
                AccountDeviceWire.OptionalInteger(row, "lastSeenAt"), AccountDeviceWire.Boolean(row, "online"), caller);
            if (!identities.Add(device.Identity)) throw new InvalidDataException("Duplicate registered identity row.");
            devices.Add(device);
        }
        return new(generated, binding.DeviceId, truncated, devices.AsReadOnly());
    }
}

internal static class AccountDeviceWire
{
    internal static JsonElement Member(JsonElement row, string name) => row.ValueKind == JsonValueKind.Object && row.TryGetProperty(name, out var v)
        ? v : throw new InvalidDataException("Missing account device field: " + name);
    internal static string Text(JsonElement row, string name) => OptionalText(row, name) ?? throw new InvalidDataException("Missing account device text: " + name);
    internal static string? OptionalText(JsonElement row, string name)
    {
        if (row.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Account device row must be an object.");
        if (!row.TryGetProperty(name, out var v) || v.ValueKind == JsonValueKind.Null) return null;
        if (v.ValueKind != JsonValueKind.String) throw new InvalidDataException("Invalid account device text: " + name);
        string value = v.GetString() ?? throw new InvalidDataException("Null account device text.");
        if (value.Length == 0 || value.Length > 256 || value.Any(char.IsControl)) throw new InvalidDataException("Invalid account device text: " + name);
        return value;
    }
    internal static long Integer(JsonElement row, string name) => (Member(row, name).ValueKind == JsonValueKind.Number && Member(row, name).TryGetInt64(out long v)) ? v : throw new InvalidDataException("Invalid account device integer: " + name);
    internal static long? OptionalInteger(JsonElement row, string name)
    {
        if (row.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Account device row must be an object.");
        if (!row.TryGetProperty(name, out var v) || v.ValueKind == JsonValueKind.Null) return null;
        if (v.ValueKind != JsonValueKind.Number || !v.TryGetInt64(out long value) || value <= 0 || value > 253402300799999L) throw new InvalidDataException("Invalid device timestamp.");
        return value;
    }
    internal static bool Boolean(JsonElement row, string name) => Member(row, name).ValueKind switch
    { JsonValueKind.True => true, JsonValueKind.False => false, _ => throw new InvalidDataException("Invalid account device flag: " + name) };
    internal static string? ErrorCode(CurrentPathSignalServerException error)
    {
        if (error.SanitizedBody is "registry_not_configured" or "registry_unavailable") return error.SanitizedBody;
        try
        {
            using var json = JsonDocument.Parse(error.SanitizedBody);
            foreach (string key in new[] { "code", "error" }) if (json.RootElement.TryGetProperty(key, out var code) && code.ValueKind == JsonValueKind.String) return code.GetString();
        }
        catch (JsonException) { /* A redacted non-JSON error has no trusted code. */ }
        return null;
    }
}
