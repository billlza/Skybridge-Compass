using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface IWindowsTransportAdapterClient
{
    Task<WindowsTransportAdapterSnapshot> PrepareAsync(WindowsTransportAdapterRequest request);
}

public sealed class PendingWindowsTransportAdapterClient : IWindowsTransportAdapterClient
{
    public Task<WindowsTransportAdapterSnapshot> PrepareAsync(WindowsTransportAdapterRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        var adapterKind = ConnectionPreflightPlan.ResolveAdapterKind(request.TransportKind);
        if (adapterKind == ConnectionLaunchAdapterKind.AppleNative)
        {
            throw new InvalidOperationException("Windows transport adapter must not select AppleNative; Apple-to-Apple remains on the Apple native path.");
        }

        var localEndpoint = "windows-preflight.local:443";
        var remoteEndpoint = $"{EndpointToken(request.PairingMaterial.DeviceId)}.skybridge-preflight.local:443";
        var selectedCandidatePair = $"{request.TransportKind}/preflight-candidate";
        var relayId = request.RelayRequired ? "preflight-relay" : null;
        var facts = new[]
        {
            new ConnectionPreflightFact(
                "Windows adapter",
                "pending",
                "No WebRTC, MsQuic, relay, or TCP adapter has supplied live endpoint, candidate, exporter, or relay binding material.")
        };

        return Task.FromResult(new WindowsTransportAdapterSnapshot(
            adapterKind,
            IsLiveAdapterReady: false,
            AdapterBinding: "adapter pending",
            localEndpoint,
            remoteEndpoint,
            selectedCandidatePair,
            PreflightTransportSecretFingerprint(request.PairingMaterial),
            relayId,
            10_000,
            CapabilityDigest(request),
            facts));
    }

    private static byte[] PreflightTransportSecretFingerprint(PairingMaterial pairingMaterial) =>
        SHA256.HashData(Encoding.UTF8.GetBytes($"preflight transport placeholder:{pairingMaterial.PublicKeyFingerprint}"));

    private static byte[] CapabilityDigest(WindowsTransportAdapterRequest request)
    {
        var material =
            $"local={FormatCapabilities(request.LocalCapabilities)};remote={FormatCapabilities(request.RemoteCapabilities)};peer={request.DiscoveredPeer.DeviceId};fingerprint={request.PairingMaterial.PublicKeyFingerprint};sameLan={request.NetworkPath.SameLan};crossNat={request.NetworkPath.CrossNat}";
        return SHA256.HashData(Encoding.UTF8.GetBytes(material));
    }

    private static string FormatCapabilities(PeerCapabilities capabilities) =>
        $"{capabilities.Platform},{capabilities.SupportsAppleNative},{capabilities.SupportsMsQuic},{capabilities.SupportsSkyBridgeIceMsQuic},{capabilities.SupportsWebRtcDataChannel},{capabilities.SupportsTcpFallback},{capabilities.SupportsRelay}";

    private static string EndpointToken(string value)
    {
        var builder = new StringBuilder(value.Length);
        foreach (var ch in value)
        {
            var isAsciiLetter = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
            var isAsciiDigit = ch >= '0' && ch <= '9';
            builder.Append(isAsciiLetter || isAsciiDigit || ch == '-' ? ch : '-');
        }

        return builder.Length == 0 ? "peer" : builder.ToString();
    }
}

public sealed class ExternalWindowsTransportAdapterClient : IWindowsTransportAdapterClient
{
    private readonly WindowsExternalTransportAdapterOptions _options;

    public ExternalWindowsTransportAdapterClient(WindowsExternalTransportAdapterOptions options)
    {
        _options = options ?? throw new ArgumentNullException(nameof(options));
    }

    public Task<WindowsTransportAdapterSnapshot> PrepareAsync(WindowsTransportAdapterRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        var adapterKind = ConnectionPreflightPlan.ResolveAdapterKind(request.TransportKind);
        if (adapterKind == ConnectionLaunchAdapterKind.AppleNative)
        {
            throw new InvalidOperationException("Windows external adapter must not select AppleNative; Apple-to-Apple remains on the Apple native path.");
        }

        if (_options.AdapterKind != ConnectionLaunchAdapterKind.None
            && _options.AdapterKind != adapterKind)
        {
            throw new InvalidOperationException("External Windows transport adapter kind must match the Core-selected transport.");
        }

        var facts = new[]
        {
            new ConnectionPreflightFact(
                "Windows adapter",
                "external verified",
                "Explicit runtime adapter binding material was supplied outside the UI and is ready for the Core handshake transcript.")
        };

        return Task.FromResult(new WindowsTransportAdapterSnapshot(
            adapterKind,
            IsLiveAdapterReady: true,
            _options.AdapterBinding,
            _options.LocalEndpoint,
            _options.RemoteEndpoint,
            _options.SelectedCandidatePair,
            (byte[])_options.TransportSecretFingerprint.Clone(),
            _options.RelayId,
            _options.TimestampWindowMs,
            (byte[])_options.CapabilityDigest.Clone(),
            facts));
    }
}

public sealed class VerifiedWebRtcDataChannelTransportAdapterClient : IWindowsTransportAdapterClient
{
    private static readonly JsonSerializerOptions ProofJsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private readonly WindowsVerifiedWebRtcDataChannelOptions _options;

    public VerifiedWebRtcDataChannelTransportAdapterClient(WindowsVerifiedWebRtcDataChannelOptions options)
    {
        _options = options ?? throw new ArgumentNullException(nameof(options));
    }

    public Task<WindowsTransportAdapterSnapshot> PrepareAsync(WindowsTransportAdapterRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        var adapterKind = ConnectionPreflightPlan.ResolveAdapterKind(request.TransportKind);
        if (adapterKind == ConnectionLaunchAdapterKind.AppleNative)
        {
            throw new InvalidOperationException("Windows verified WebRTC adapter must not select AppleNative; Apple-to-Apple remains on the Apple native path.");
        }

        if (adapterKind != ConnectionLaunchAdapterKind.WebRtcDataChannel)
        {
            throw new InvalidOperationException("Windows verified WebRTC adapter requires the Core-selected transport to be WebRtcDataChannel.");
        }

        if (request.TransportAudit != CoreTransportAuditCode.WebRtcInterop)
        {
            throw new InvalidOperationException("Windows verified WebRTC adapter requires the Core transport audit to be WebRtcInterop.");
        }

        var proof = ReadProof(_options.ProofPath);
        ValidateProofIdentity(proof, request);
        ValidateProofFreshness(proof);

        var transportSecretFingerprint = ParseLowerHex32(
            proof.TransportSecretFingerprintHex,
            "verified WebRTC transport secret fingerprint");
        var capabilityDigest = ParseLowerHex32(
            proof.CapabilityDigestHex,
            "verified WebRTC capability digest");
        var relayId = string.IsNullOrWhiteSpace(proof.RelayId) ? null : proof.RelayId.Trim();
        var helperName = string.IsNullOrWhiteSpace(proof.HelperName)
            ? "webrtc-helper"
            : proof.HelperName.Trim();
        var adapterBinding = proof.AdapterBinding!.Trim();
        var localEndpoint = proof.LocalEndpoint!.Trim();
        var remoteEndpoint = proof.RemoteEndpoint!.Trim();
        var selectedCandidatePair = proof.SelectedCandidatePair!.Trim();

        var facts = new[]
        {
            new ConnectionPreflightFact(
                "Windows WebRTC adapter",
                "helper proof verified",
                $"{helperName} opened a WebRTC DataChannel and echoed an SBF1 frame before binding material was accepted."),
            new ConnectionPreflightFact(
                "WebRTC proof",
                "fresh",
                $"captured_at_unix_ms={proof.CapturedAtUnixMs}; max_age_ms={_options.MaxProofAgeMs}; proof={_options.ProofPath}")
        };

        return Task.FromResult(new WindowsTransportAdapterSnapshot(
            ConnectionLaunchAdapterKind.WebRtcDataChannel,
            IsLiveAdapterReady: true,
            adapterBinding,
            localEndpoint,
            remoteEndpoint,
            selectedCandidatePair,
            transportSecretFingerprint,
            relayId,
            proof.TimestampWindowMs,
            capabilityDigest,
            facts));
    }

    private WindowsVerifiedWebRtcDataChannelProof ReadProof(string proofPath)
    {
        if (!File.Exists(proofPath))
        {
            throw new InvalidOperationException($"Windows verified WebRTC adapter proof file does not exist: {proofPath}");
        }

        var proof = JsonSerializer.Deserialize<WindowsVerifiedWebRtcDataChannelProof>(
            File.ReadAllText(proofPath),
            ProofJsonOptions);
        if (proof is null)
        {
            throw new InvalidOperationException("Windows verified WebRTC adapter proof file is empty or invalid JSON.");
        }

        return proof;
    }

    private void ValidateProofIdentity(
        WindowsVerifiedWebRtcDataChannelProof proof,
        WindowsTransportAdapterRequest request)
    {
        if (!string.Equals(proof.PeerDeviceId, request.PairingMaterial.DeviceId, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Windows verified WebRTC adapter proof peer does not match pairing material.");
        }

        if (!string.Equals(
            proof.PeerPublicKeyFingerprint,
            request.PairingMaterial.PublicKeyFingerprint,
            StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Windows verified WebRTC adapter proof fingerprint does not match pairing material.");
        }

        if (!proof.DataChannelOpen)
        {
            throw new InvalidOperationException("Windows verified WebRTC adapter proof must confirm the DataChannel opened.");
        }

        if (!proof.Sbf1EchoVerified)
        {
            throw new InvalidOperationException("Windows verified WebRTC adapter proof must confirm an SBF1 echo frame.");
        }

        if (!string.Equals(proof.Sbf1FrameMagic, "SBF1", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Windows verified WebRTC adapter proof must carry SBF1 frame magic.");
        }

        RequireText(proof.AdapterBinding, "adapter binding");
        RequireText(proof.LocalEndpoint, "local endpoint");
        RequireText(proof.RemoteEndpoint, "remote endpoint");
        RequireText(proof.SelectedCandidatePair, "selected candidate pair");
        if (proof.TimestampWindowMs == 0)
        {
            throw new InvalidOperationException("Windows verified WebRTC adapter proof requires a non-zero timestamp window.");
        }
    }

    private void ValidateProofFreshness(WindowsVerifiedWebRtcDataChannelProof proof)
    {
        if (proof.CapturedAtUnixMs <= 0)
        {
            throw new InvalidOperationException("Windows verified WebRTC adapter proof requires capturedAtUnixMs.");
        }

        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var age = now - proof.CapturedAtUnixMs;
        if (age < 0 || (ulong)age > _options.MaxProofAgeMs)
        {
            throw new InvalidOperationException("Windows verified WebRTC adapter proof is stale or from the future.");
        }
    }

    private static void RequireText(string? value, string label)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException($"Windows verified WebRTC adapter proof requires a {label}.");
        }
    }

    private static byte[] ParseLowerHex32(string? raw, string label)
    {
        if (string.IsNullOrWhiteSpace(raw) || raw.Length != 64)
        {
            throw new InvalidOperationException($"Windows {label} must be 64 lowercase hex characters.");
        }

        var bytes = new byte[32];
        for (var index = 0; index < bytes.Length; index++)
        {
            var high = FromLowerHex(raw[index * 2], label);
            var low = FromLowerHex(raw[index * 2 + 1], label);
            bytes[index] = (byte)((high << 4) | low);
        }

        return bytes;
    }

    private static int FromLowerHex(char value, string label)
    {
        if (value is >= '0' and <= '9')
        {
            return value - '0';
        }

        if (value is >= 'a' and <= 'f')
        {
            return value - 'a' + 10;
        }

        throw new InvalidOperationException($"Windows {label} must be 64 lowercase hex characters.");
    }
}

public sealed class WindowsVerifiedWebRtcDataChannelOptions
{
    public WindowsVerifiedWebRtcDataChannelOptions(string proofPath, ulong maxProofAgeMs)
    {
        if (string.IsNullOrWhiteSpace(proofPath))
        {
            throw new InvalidOperationException("Windows verified WebRTC adapter requires a proof file path.");
        }

        if (maxProofAgeMs == 0)
        {
            throw new InvalidOperationException("Windows verified WebRTC adapter requires a non-zero proof max age.");
        }

        ProofPath = proofPath.Trim();
        MaxProofAgeMs = maxProofAgeMs;
    }

    public string ProofPath { get; }

    public ulong MaxProofAgeMs { get; }
}

public sealed class WindowsVerifiedWebRtcDataChannelProof
{
    public string? HelperName { get; set; }

    public string? PeerDeviceId { get; set; }

    public string? PeerPublicKeyFingerprint { get; set; }

    public bool DataChannelOpen { get; set; }

    public bool Sbf1EchoVerified { get; set; }

    public string? Sbf1FrameMagic { get; set; }

    public string? AdapterBinding { get; set; }

    public string? LocalEndpoint { get; set; }

    public string? RemoteEndpoint { get; set; }

    public string? SelectedCandidatePair { get; set; }

    public string? TransportSecretFingerprintHex { get; set; }

    public string? CapabilityDigestHex { get; set; }

    public string? RelayId { get; set; }

    public ulong TimestampWindowMs { get; set; }

    public long CapturedAtUnixMs { get; set; }
}

public sealed class WindowsExternalTransportAdapterOptions
{
    public WindowsExternalTransportAdapterOptions(
        ConnectionLaunchAdapterKind adapterKind,
        string adapterBinding,
        string localEndpoint,
        string remoteEndpoint,
        string selectedCandidatePair,
        byte[] transportSecretFingerprint,
        byte[] capabilityDigest,
        string? relayId,
        ulong timestampWindowMs)
    {
        if (adapterKind == ConnectionLaunchAdapterKind.AppleNative)
        {
            throw new InvalidOperationException("Windows external adapter must not select AppleNative; Apple-to-Apple remains on the Apple native path.");
        }

        if (string.IsNullOrWhiteSpace(adapterBinding))
        {
            throw new InvalidOperationException("External Windows transport adapter requires an adapter binding description.");
        }

        if (string.IsNullOrWhiteSpace(localEndpoint))
        {
            throw new InvalidOperationException("External Windows transport adapter requires a local endpoint.");
        }

        if (string.IsNullOrWhiteSpace(remoteEndpoint))
        {
            throw new InvalidOperationException("External Windows transport adapter requires a remote endpoint.");
        }

        if (string.IsNullOrWhiteSpace(selectedCandidatePair))
        {
            throw new InvalidOperationException("External Windows transport adapter requires a selected candidate pair.");
        }

        if (timestampWindowMs == 0)
        {
            throw new InvalidOperationException("External Windows transport adapter requires a non-zero timestamp window.");
        }

        ValidateDigest(transportSecretFingerprint, "transport secret fingerprint");
        ValidateDigest(capabilityDigest, "capability digest");

        AdapterKind = adapterKind;
        AdapterBinding = adapterBinding.Trim();
        LocalEndpoint = localEndpoint.Trim();
        RemoteEndpoint = remoteEndpoint.Trim();
        SelectedCandidatePair = selectedCandidatePair.Trim();
        TransportSecretFingerprint = (byte[])transportSecretFingerprint.Clone();
        CapabilityDigest = (byte[])capabilityDigest.Clone();
        RelayId = string.IsNullOrWhiteSpace(relayId) ? null : relayId.Trim();
        TimestampWindowMs = timestampWindowMs;
    }

    public ConnectionLaunchAdapterKind AdapterKind { get; }

    public string AdapterBinding { get; }

    public string LocalEndpoint { get; }

    public string RemoteEndpoint { get; }

    public string SelectedCandidatePair { get; }

    public byte[] TransportSecretFingerprint { get; }

    public byte[] CapabilityDigest { get; }

    public string? RelayId { get; }

    public ulong TimestampWindowMs { get; }

    private static void ValidateDigest(byte[] value, string label)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (value.Length != 32)
        {
            throw new InvalidOperationException($"External Windows transport adapter {label} must be 32 bytes.");
        }
    }
}

public sealed record WindowsTransportAdapterRequest(
    DiscoveredPeer DiscoveredPeer,
    PairingMaterial PairingMaterial,
    CoreTransportKind TransportKind,
    CoreTransportAuditCode TransportAudit,
    bool RelayRequired,
    bool RelayAllowed,
    PeerCapabilities LocalCapabilities,
    PeerCapabilities RemoteCapabilities,
    NetworkPath NetworkPath);

public sealed record WindowsTransportAdapterSnapshot(
    ConnectionLaunchAdapterKind AdapterKind,
    bool IsLiveAdapterReady,
    string AdapterBinding,
    string LocalEndpoint,
    string RemoteEndpoint,
    string SelectedCandidatePair,
    byte[] TransportSecretFingerprint,
    string? RelayId,
    ulong TimestampWindowMs,
    byte[] CapabilityDigest,
    IReadOnlyList<ConnectionPreflightFact> Facts)
{
    public TransportBindingMaterial BuildTransportBindingMaterial(CoreTransportKind transportKind)
    {
        ArgumentNullException.ThrowIfNull(TransportSecretFingerprint);
        ArgumentNullException.ThrowIfNull(CapabilityDigest);

        if (AdapterKind == ConnectionLaunchAdapterKind.None)
        {
            throw new InvalidOperationException("Windows transport adapter must resolve a concrete adapter kind before binding.");
        }

        if (transportKind == CoreTransportKind.AppleNative
            || AdapterKind == ConnectionLaunchAdapterKind.AppleNative)
        {
            throw new InvalidOperationException("Windows transport adapter must not select AppleNative; Apple-to-Apple remains on the Apple native path.");
        }

        if (string.IsNullOrWhiteSpace(AdapterBinding))
        {
            throw new InvalidOperationException("Windows transport adapter must describe its adapter binding.");
        }

        if (string.IsNullOrWhiteSpace(LocalEndpoint))
        {
            throw new InvalidOperationException("Windows transport adapter must provide a local endpoint.");
        }

        if (string.IsNullOrWhiteSpace(RemoteEndpoint))
        {
            throw new InvalidOperationException("Windows transport adapter must provide a remote endpoint.");
        }

        if (string.IsNullOrWhiteSpace(SelectedCandidatePair))
        {
            throw new InvalidOperationException("Windows transport adapter must provide a selected candidate pair.");
        }

        if (TransportSecretFingerprint.Length != 32)
        {
            throw new InvalidOperationException("Windows transport adapter must provide a 32-byte transport secret fingerprint.");
        }

        if (CapabilityDigest.Length != 32)
        {
            throw new InvalidOperationException("Windows transport adapter must provide a 32-byte capability digest.");
        }

        return new TransportBindingMaterial(
            transportKind,
            LocalEndpoint,
            RemoteEndpoint,
            SelectedCandidatePair,
            TransportSecretFingerprint,
            RelayId,
            TimestampWindowMs,
            CapabilityDigest);
    }
}
