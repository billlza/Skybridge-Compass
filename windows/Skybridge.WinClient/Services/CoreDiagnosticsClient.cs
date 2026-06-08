using System;
using System.Collections.Generic;
using System.Text;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface ICoreDiagnosticsClient
{
    string BuildInitialStatus();

    string BuildPendingStatus();

    string BuildCompletedStatus(CoreDiagnosticsSnapshot snapshot);

    string BuildCompletedStatusMessage();

    Task<CoreDiagnosticsSnapshot> BuildInteropSnapshotAsync();
}

public sealed class CoreDiagnosticsClient : ICoreDiagnosticsClient
{
    private readonly CoreBridge _coreBridge;

    public CoreDiagnosticsClient(CoreBridge coreBridge)
    {
        _coreBridge = coreBridge ?? throw new ArgumentNullException(nameof(coreBridge));
    }

    public string BuildPendingStatus() => DefaultPendingStatus;

    public string BuildInitialStatus() => DefaultInitialStatus;

    public string BuildCompletedStatus(CoreDiagnosticsSnapshot snapshot) =>
        BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() => DefaultCompletedStatusMessage;

    public static string DefaultInitialStatus { get; } = "Ready";

    public static string DefaultPendingStatus { get; } = "Running...";

    public static string DefaultCompletedStatusMessage { get; } = "Core diagnostics updated";

    public static string BuildDefaultCompletedStatus(CoreDiagnosticsSnapshot snapshot) =>
        $"Snapshot {snapshot.CapturedAt:HH:mm:ss} UTC";

    public async Task<CoreDiagnosticsSnapshot> BuildInteropSnapshotAsync()
    {
        var local = PeerCapabilities.Windows();
        var remote = PeerCapabilities.Apple();
        var path = NetworkPath.CrossNatPath();
        var crypto = CryptoProviderCapabilities.ResearchAll();
        var remoteSuites = new ushort[] { 0x1001, 0x0101, 0x0001 };
        var suitePolicy = CryptoSuitePolicy.Compatibility();
        var padding = TrafficPaddingPlan.Sbp2Fixed(512);

        var plan = await _coreBridge.PlanConnectionAsync(
            local,
            remote,
            path,
            crypto,
            remoteSuites,
            suitePolicy,
            padding);
        var bindingDigest = await _coreBridge.ComputeTransportBindingDigestAsync(
            new TransportBindingMaterial(
                plan.Transport.Kind,
                "windows-diagnostic.local:443",
                "apple-diagnostic.local:443",
                "webrtc/host-udp",
                Encoding.UTF8.GetBytes("diagnostic-transport-secret-fingerprint"),
                null,
                10_000,
                Encoding.UTF8.GetBytes("windows,apple,webrtc,tcp")));
        var realtime = await _coreBridge.MapChannelAsync(plan.Transport.Kind, CoreChannelKind.Realtime);
        var frame = await _coreBridge.EncodeSbp2FrameAsync(
            CoreChannelKind.Control,
            1,
            Encoding.UTF8.GetBytes("diagnostic"),
            32);
        var frameMetadata = await _coreBridge.DecodeFrameMetadataAsync(frame);
        var payload = await _coreBridge.DecodeFramePayloadAsync(frame);

        var facts = new List<CoreDiagnosticFact>
        {
            new("Interop path", $"{local.Platform} -> {remote.Platform}", "Windows-to-Apple cross-NAT diagnostic plan"),
            new("Transport", plan.Transport.Kind.ToString(), plan.Transport.AuditCode.ToString()),
            new("Transport binding digest", FormatHex(bindingDigest), "diagnostic-only binding material; live adapters must provide endpoint, candidate, exporter, relay, timestamp, and capability inputs"),
            new("Selected suite", plan.SelectedSuite.ToString(), $"wire=0x{plan.SelectedSuiteWireId:x4}; audit={plan.SuiteAudit}"),
            new("SBP2", plan.Sbp2Enabled ? "enabled" : "disabled", $"fixed_payload_len={plan.Sbp2FixedPayloadLen}"),
            new("Frame header", $"{plan.FrameHeaderLen} bytes", "Core SBF1 envelope"),
            new("Realtime binding", realtime.BindingKind.ToString(), $"reliability={realtime.Reliability}; HOL isolated={realtime.HeadOfLineIsolated}"),
            new("Frame flags", $"0x{frameMetadata.Flags:x4}", $"sbp2={frameMetadata.IsSbp2Padded}; eom={frameMetadata.IsEndOfMessage}"),
            new("Payload roundtrip", $"{payload.Length} bytes", $"encoded={frameMetadata.EncodedLen}; decoded={frameMetadata.DecodedPayloadLen}")
        };

        return new CoreDiagnosticsSnapshot(DateTimeOffset.UtcNow, facts);
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

public sealed record CoreDiagnosticsSnapshot(
    DateTimeOffset CapturedAt,
    IReadOnlyList<CoreDiagnosticFact> Facts);

public sealed record CoreDiagnosticFact(
    string Label,
    string Value,
    string Detail);
