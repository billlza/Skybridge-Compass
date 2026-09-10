using System.Text.Json;
using System.Text.Json.Serialization;
using Skybridge.WinClient.Services.RemoteControl;

namespace Skybridge.WinClient.Services;

internal sealed record LanKemPublicKey(ushort SuiteWireId, byte[] PublicKey);
internal sealed record LanProtocolPublicKey(string ProtocolSigningAlgorithm, byte[] PublicKey);
internal sealed record LanProductIdentity(
    string DeviceId, LanKemPublicKey[] KemPublicKeys, double SentAt,
    LanProtocolPublicKey[]? ProtocolIdentityPublicKeys = null,
    string? DeviceName = null, string? ModelName = null, string? Platform = null, string? OsVersion = null,
    string? Chip = null, string? AccountDisplayName = null, string? NebulaId = null,
    string[]? RemoteVideoFormats = null, string[]? Capabilities = null,
    ushort? FileTransferPort = null, ushort? RemoteControlPort = null);
internal sealed record LanProductHeartbeat(double SentAt, string? DeviceId = null, string[]? Capabilities = null,
    ushort? FileTransferPort = null, ushort? RemoteControlPort = null);
internal sealed record LanProductPing(ulong Id);
internal sealed record LanPeerDisconnecting(double SentAt, string? DeviceId = null, string? Reason = null);

internal enum LanControlMessageKind { Identity, Heartbeat, Ping, Pong, Disconnecting }
internal sealed record LanControlMessage(LanControlMessageKind Kind, JsonElement Payload);

/// <summary>The existing single-discriminator AppMessage JSON used by compatible LAN peers.</summary>
internal static class LanProductControlMessages
{
    internal const int MaximumFrameBytes = 1024 * 1024;
    private static readonly DateTimeOffset SwiftReferenceDate = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        AllowDuplicateProperties = false,
        RespectNullableAnnotations = true,
        RespectRequiredConstructorParameters = true,
        MaxDepth = 16
    };

    internal static double Timestamp(DateTimeOffset now) => (now - SwiftReferenceDate).TotalSeconds;

    internal static byte[] Encode<T>(LanControlMessageKind kind, T payload)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WritePropertyName(Name(kind));
            JsonSerializer.Serialize(writer, payload, Json);
            writer.WriteEndObject();
        }
        if (stream.Length > MaximumFrameBytes - 36) throw new InvalidDataException("AppMessage exceeds its authenticated frame limit.");
        return stream.ToArray();
    }

    internal static LanControlMessage Decode(ReadOnlySpan<byte> bytes)
    {
        if (bytes.IsEmpty || bytes.Length > MaximumFrameBytes) throw new InvalidDataException("Invalid AppMessage length.");
        using var document = JsonSerializer.Deserialize<JsonDocument>(bytes, Json)
            ?? throw new InvalidDataException("AppMessage cannot be null.");
        if (document.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException("AppMessage must be an object.");
        var properties = document.RootElement.EnumerateObject();
        if (!properties.MoveNext()) throw new InvalidDataException("AppMessage has no discriminator.");
        var message = properties.Current;
        if (properties.MoveNext() || message.Value.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("AppMessage must contain exactly one object discriminator.");
        var kind = message.Name switch
        {
            "pairingIdentityExchange" => LanControlMessageKind.Identity,
            "heartbeat" => LanControlMessageKind.Heartbeat,
            "ping" => LanControlMessageKind.Ping,
            "pong" => LanControlMessageKind.Pong,
            "peerDisconnecting" => LanControlMessageKind.Disconnecting,
            _ => throw new InvalidDataException($"Unnegotiated AppMessage kind: {message.Name}.")
        };
        return new(kind, message.Value.Clone());
    }

    internal static T Payload<T>(LanControlMessage message) => message.Payload.Deserialize<T>(Json)
        ?? throw new InvalidDataException("AppMessage payload cannot be null.");

    internal static LanProductIdentity LocalIdentity(ProductPeerAuthentication authority, ushort? fileTransferPort,
        DateTimeOffset now) => new(
            authority.LocalPairing.DeviceId,
            [new(0x0101, authority.LocalPairing.MlKem768PublicKey.ToArray())], Timestamp(now),
            [new(authority.LocalPairing.ProtocolSigningAlgorithm, authority.LocalPairing.ProtocolPublicKey.ToArray())],
            DeviceName: authority.LocalPairing.DeviceName, Platform: "Windows", OsVersion: Environment.OSVersion.VersionString,
            AccountDisplayName: authority.LocalIdentity.AccountDisplayName, NebulaId: authority.LocalIdentity.NebulaId,
            Capabilities: ["file_transfer"], FileTransferPort: fileTransferPort);

    internal static void ValidateIdentity(LanProductIdentity identity, ProductHandshakePeerContext expected)
    {
        if (RemoteControlHandshakeBinding.CanonicalDeviceId(identity.DeviceId) != expected.PeerDeviceId ||
            !double.IsFinite(identity.SentAt) || identity.KemPublicKeys.Length is < 1 or > 8 ||
            identity.ProtocolIdentityPublicKeys is not { Length: >= 1 and <= 8 } signingKeys)
            throw new InvalidDataException("Authenticated AppMessage identity does not match the expected peer.");
        if (identity.KemPublicKeys.Any(key => key is null) || signingKeys.Any(key => key is null))
            throw new InvalidDataException("AppMessage identity key arrays cannot contain null values.");
        var matching = signingKeys.Where(key => key.ProtocolSigningAlgorithm == "ML-DSA-65")
            .Select(key => new WebRtcProductProtocolIdentityPublicKey(WebRtcProductSignatureAlgorithm.MlDsa65, key.PublicKey).AuthoritativeFingerprint)
            .ToArray();
        if (matching.Length != 1 || matching[0] != expected.PeerPublicKeyFingerprint)
            throw new InvalidDataException("AppMessage protocol public key conflicts with the paired identity.");
        if (!identity.KemPublicKeys.Any(key => key.SuiteWireId is 0x0101 or 0x0102 && key.PublicKey.Length == 1184))
            throw new InvalidDataException("The peer did not publish its existing ML-KEM-768 identity material.");
        if (identity.FileTransferPort is 0 || identity.RemoteControlPort is 0 || identity.Capabilities is { Length: > 64 })
            throw new InvalidDataException("The peer published invalid service capabilities.");
    }

    private static string Name(LanControlMessageKind kind) => kind switch
    {
        LanControlMessageKind.Identity => "pairingIdentityExchange",
        LanControlMessageKind.Heartbeat => "heartbeat",
        LanControlMessageKind.Ping => "ping",
        LanControlMessageKind.Pong => "pong",
        LanControlMessageKind.Disconnecting => "peerDisconnecting",
        _ => throw new ArgumentOutOfRangeException(nameof(kind))
    };
}
