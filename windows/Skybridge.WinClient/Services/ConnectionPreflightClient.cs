using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface IConnectionPreflightClient
{
    string BuildPendingStatus();

    Task<ConnectionPreflightSnapshot> BuildReadOnlySnapshotAsync(
        DiscoveredPeer discoveredPeer,
        PairingMaterial pairingMaterial);
}

public sealed class ConnectionPreflightClient : IConnectionPreflightClient
{
    private readonly CoreBridge _coreBridge;

    public ConnectionPreflightClient(CoreBridge coreBridge)
    {
        _coreBridge = coreBridge ?? throw new ArgumentNullException(nameof(coreBridge));
    }

    public string BuildPendingStatus() => DefaultPendingStatus;

    public static string DefaultPendingStatus { get; } = "Preparing...";

    public async Task<ConnectionPreflightSnapshot> BuildReadOnlySnapshotAsync(
        DiscoveredPeer discoveredPeer,
        PairingMaterial pairingMaterial)
    {
        ArgumentNullException.ThrowIfNull(discoveredPeer);
        ArgumentNullException.ThrowIfNull(pairingMaterial);

        if (!string.Equals(discoveredPeer.DeviceId, pairingMaterial.DeviceId, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Pairing material deviceId does not match the discovered peer.");
        }

        if (!pairingMaterial.VerifiedAgainstDiscoveryFingerprint)
        {
            throw new InvalidOperationException("Pairing material must be validated against the discovered peer before connection preflight.");
        }

        if (!string.Equals(
            discoveredPeer.PublicKeyFingerprint,
            pairingMaterial.PublicKeyFingerprint,
            StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Pairing material pubKeyFP does not match the discovered peer fingerprint.");
        }

        var local = PeerCapabilities.Windows();
        var remote = discoveredPeer.Capabilities;
        var plan = await _coreBridge.PlanConnectionAsync(
            local,
            remote,
            SelectPreflightPath(discoveredPeer),
            CryptoProviderCapabilities.ResearchAll(),
            new ushort[] { 0x0001, 0x0101, 0x1001 },
            CryptoSuitePolicy.Compatibility(),
            TrafficPaddingPlan.Sbp2Fixed(512));
        var control = await _coreBridge.MapChannelAsync(plan.Transport.Kind, CoreChannelKind.Control);
        var file = await _coreBridge.MapChannelAsync(plan.Transport.Kind, CoreChannelKind.File);
        var telemetry = await _coreBridge.MapChannelAsync(plan.Transport.Kind, CoreChannelKind.Telemetry);
        var realtime = await _coreBridge.MapChannelAsync(plan.Transport.Kind, CoreChannelKind.Realtime);
        var bindingDigest = await _coreBridge.ComputeTransportBindingDigestAsync(
            new TransportBindingMaterial(
                plan.Transport.Kind,
                "windows-preflight.local:443",
                $"{EndpointToken(pairingMaterial.DeviceId)}.skybridge-preflight.local:443",
                $"{plan.Transport.Kind}/preflight-candidate",
                PreflightTransportSecretFingerprint(pairingMaterial),
                plan.Transport.RelayRequired ? "preflight-relay" : null,
                10_000,
                CapabilityDigest(local, remote, discoveredPeer, pairingMaterial)));
        var provider = pairingMaterial.ToPeerPublicKeyProvider();
        var launchPlan = new ConnectionPreflightPlan(
            discoveredPeer.DeviceId,
            pairingMaterial.PublicKeyFingerprint,
            plan.Transport.Kind,
            plan.Transport.AuditCode,
            plan.Transport.RelayRequired,
            plan.Transport.RelayAllowed,
            plan.SelectedSuite,
            plan.SelectedSuiteWireId,
            plan.SuiteAudit,
            plan.Sbp2Enabled,
            plan.Sbp2FixedPayloadLen,
            plan.FrameHeaderLen,
            bindingDigest,
            ConnectionPreflightPlan.ResolveAdapterKind(plan.Transport.Kind),
            false,
            "adapter pending");

        var facts = new List<ConnectionPreflightFact>
        {
            new(
                "Pairing material",
                "verified",
                "Pairing-derived peer public key provider is available; discovery pubKeyFP remains verification input only."),
            new(
                "Peer",
                discoveredPeer.DeviceId,
                $"{discoveredPeer.DisplayName} / {discoveredPeer.PlatformLabel} / {discoveredPeer.ProtocolVersion}"),
            new(
                "Transport plan",
                plan.Transport.Kind.ToString(),
                $"{plan.Transport.AuditCode}; relay_required={plan.Transport.RelayRequired}; relay_allowed={plan.Transport.RelayAllowed}"),
            new(
                "Transport binding digest",
                FormatHex(bindingDigest),
                "Preflight-only binding material; live adapters must replace endpoint, candidate, exporter, relay, timestamp, and capability inputs before the handshake transcript."),
            new(
                "Selected suite",
                plan.SelectedSuite.ToString(),
                $"wire=0x{plan.SelectedSuiteWireId:x4}; audit={plan.SuiteAudit}"),
            new(
                "SBP2",
                plan.Sbp2Enabled ? "enabled" : "disabled",
                $"fixed_payload_len={plan.Sbp2FixedPayloadLen}; frame_header={plan.FrameHeaderLen} bytes"),
            new(
                "Channel map",
                $"control={control.BindingKind}; file={file.BindingKind}",
                $"telemetry={telemetry.BindingKind}/{telemetry.Reliability}; realtime={realtime.BindingKind}/{realtime.Reliability}"),
            new(
                "Peer key provider",
                provider.GetType().Name,
                "No connection attempt is started; FfiEngineClient remains behind explicit native DLL deployment.")
        };

        return new ConnectionPreflightSnapshot(DateTimeOffset.UtcNow, launchPlan, facts);
    }

    private static byte[] PreflightTransportSecretFingerprint(PairingMaterial pairingMaterial) =>
        SHA256.HashData(Encoding.UTF8.GetBytes($"preflight transport placeholder:{pairingMaterial.PublicKeyFingerprint}"));

    private static NetworkPath SelectPreflightPath(DiscoveredPeer discoveredPeer) =>
        discoveredPeer.Platform == CorePeerPlatform.Windows
            ? NetworkPath.SameLanPath()
            : NetworkPath.CrossNatPath();

    private static byte[] CapabilityDigest(
        PeerCapabilities local,
        PeerCapabilities remote,
        DiscoveredPeer discoveredPeer,
        PairingMaterial pairingMaterial)
    {
        var material =
            $"local={FormatCapabilities(local)};remote={FormatCapabilities(remote)};peer={discoveredPeer.DeviceId};fingerprint={pairingMaterial.PublicKeyFingerprint}";
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

public sealed record ConnectionPreflightSnapshot(
    DateTimeOffset CapturedAt,
    ConnectionPreflightPlan Plan,
    IReadOnlyList<ConnectionPreflightFact> Facts);

public sealed record ConnectionPreflightFact(
    string Label,
    string Value,
    string Detail);
