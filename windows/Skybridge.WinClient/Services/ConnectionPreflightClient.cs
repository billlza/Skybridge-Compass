using System;
using System.Collections.Generic;
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
    private readonly IWindowsTransportAdapterClient _transportAdapterClient;

    public ConnectionPreflightClient(CoreBridge coreBridge)
        : this(coreBridge, new PendingWindowsTransportAdapterClient())
    {
    }

    public ConnectionPreflightClient(
        CoreBridge coreBridge,
        IWindowsTransportAdapterClient transportAdapterClient)
    {
        _coreBridge = coreBridge ?? throw new ArgumentNullException(nameof(coreBridge));
        _transportAdapterClient = transportAdapterClient ?? throw new ArgumentNullException(nameof(transportAdapterClient));
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
        var path = SelectPreflightPath(discoveredPeer);
        var plan = await _coreBridge.PlanConnectionAsync(
            local,
            remote,
            path,
            CryptoProviderCapabilities.ResearchAll(),
            new ushort[] { 0x0001, 0x0101, 0x1001 },
            CryptoSuitePolicy.Compatibility(),
            TrafficPaddingPlan.Sbp2Fixed(512));
        var channelMappings = CoreChannelMappingResolver.RequireAll(plan.ChannelMappings);
        var control = CoreChannelMappingResolver.Require(channelMappings, CoreChannelKind.Control);
        var file = CoreChannelMappingResolver.Require(channelMappings, CoreChannelKind.File);
        var clipboard = CoreChannelMappingResolver.Require(channelMappings, CoreChannelKind.Clipboard);
        var telemetry = CoreChannelMappingResolver.Require(channelMappings, CoreChannelKind.Telemetry);
        var realtime = CoreChannelMappingResolver.Require(channelMappings, CoreChannelKind.Realtime);
        var adapterSnapshot = await _transportAdapterClient.PrepareAsync(
            new WindowsTransportAdapterRequest(
                discoveredPeer,
                pairingMaterial,
                plan.Transport.Kind,
                plan.Transport.AuditCode,
                plan.Transport.RelayRequired,
                plan.Transport.RelayAllowed,
                local,
                remote,
                path));
        var bindingDigest = await _coreBridge.ComputeTransportBindingDigestAsync(
            adapterSnapshot.BuildTransportBindingMaterial(plan.Transport.Kind));
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
            channelMappings,
            bindingDigest,
            adapterSnapshot.AdapterKind,
            adapterSnapshot.IsLiveAdapterReady,
            adapterSnapshot.AdapterBinding,
            adapterSnapshot.LocalEndpoint,
            adapterSnapshot.RemoteEndpoint,
            adapterSnapshot.SelectedCandidatePair,
            adapterSnapshot.RelayId,
            adapterSnapshot.TimestampWindowMs);

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
                adapterSnapshot.IsLiveAdapterReady
                    ? "Live adapter binding material is ready for the handshake transcript."
                    : "Preflight-only binding material; live adapters must replace endpoint, candidate, exporter, relay, timestamp, and capability inputs before the handshake transcript."),
            new(
                "Adapter binding",
                adapterSnapshot.AdapterBinding,
                $"{adapterSnapshot.LocalEndpoint} -> {adapterSnapshot.RemoteEndpoint}; candidate={adapterSnapshot.SelectedCandidatePair}; relay={adapterSnapshot.RelayId ?? "none"}; window={adapterSnapshot.TimestampWindowMs}ms"),
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
                $"clipboard={clipboard.BindingKind}; telemetry={telemetry.BindingKind}/{telemetry.Reliability}; realtime={realtime.BindingKind}/{realtime.Reliability}"),
            new(
                "Peer key provider",
                provider.GetType().Name,
                "No connection attempt is started; FfiEngineClient launch still requires live Windows adapter readiness.")
        };
        facts.AddRange(adapterSnapshot.Facts);

        return new ConnectionPreflightSnapshot(DateTimeOffset.UtcNow, launchPlan, facts);
    }

    private static NetworkPath SelectPreflightPath(DiscoveredPeer discoveredPeer) =>
        discoveredPeer.Platform == CorePeerPlatform.Windows
            ? NetworkPath.SameLanPath()
            : NetworkPath.CrossNatPath();

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
