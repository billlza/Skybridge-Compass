using System.Text.Json;
using System.Text.Json.Serialization;

namespace Skybridge.WebRtcHelper;

// The WebRTC proof contract. Property names are the exact camelCase keys that
// BOTH validators accept: the Rust WebRtcProofDocument
// (core/skybridge-core/src/webrtc_proof.rs, #[serde(rename_all = "camelCase")])
// and the C# WindowsVerifiedWebRtcDataChannelProof
// (Services/WindowsTransportAdapterClient.cs).
internal sealed class ProofDocument
{
    [JsonPropertyName("helperName")] public string HelperName { get; init; } = "skybridge-webrtc-helper";
    [JsonPropertyName("peerDeviceId")] public string PeerDeviceId { get; init; } = "";
    [JsonPropertyName("peerPublicKeyFingerprint")] public string PeerPublicKeyFingerprint { get; init; } = "";
    [JsonPropertyName("dataChannelOpen")] public bool DataChannelOpen { get; init; }
    [JsonPropertyName("sbf1EchoVerified")] public bool Sbf1EchoVerified { get; init; }
    [JsonPropertyName("sbf1FrameMagic")] public string Sbf1FrameMagic { get; init; } = "SBF1";
    [JsonPropertyName("adapterBinding")] public string AdapterBinding { get; init; } = "";
    [JsonPropertyName("localEndpoint")] public string LocalEndpoint { get; init; } = "";
    [JsonPropertyName("remoteEndpoint")] public string RemoteEndpoint { get; init; } = "";
    [JsonPropertyName("selectedCandidatePair")] public string SelectedCandidatePair { get; init; } = "";
    [JsonPropertyName("transportSecretFingerprintHex")] public string TransportSecretFingerprintHex { get; init; } = "";
    [JsonPropertyName("capabilityDigestHex")] public string CapabilityDigestHex { get; init; } = "";

    [JsonPropertyName("relayId")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? RelayId { get; init; }

    [JsonPropertyName("timestampWindowMs")] public ulong TimestampWindowMs { get; init; }
    [JsonPropertyName("capturedAtUnixMs")] public long CapturedAtUnixMs { get; init; }

    public static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
}
