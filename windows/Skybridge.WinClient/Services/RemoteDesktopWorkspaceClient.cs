using System;
using System.Collections.Generic;
using System.Text;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface IRemoteDesktopWorkspaceClient
{
    string BuildPendingStatus();

    string BuildCompletedStatus(RemoteDesktopWorkspaceSnapshot snapshot);

    string BuildCompletedStatusMessage();

    Task<RemoteDesktopWorkspaceSnapshot> BuildReadOnlySnapshotAsync(
        string bitrateProfile,
        string framerateProfile);
}

public sealed class RemoteDesktopWorkspaceClient : IRemoteDesktopWorkspaceClient
{
    private readonly CoreBridge _coreBridge;

    public RemoteDesktopWorkspaceClient(CoreBridge coreBridge)
    {
        _coreBridge = coreBridge ?? throw new ArgumentNullException(nameof(coreBridge));
    }

    public string BuildPendingStatus() => DefaultPendingStatus;

    public string BuildCompletedStatus(RemoteDesktopWorkspaceSnapshot snapshot) =>
        BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() => DefaultCompletedStatusMessage;

    public static string DefaultPendingStatus { get; } = "Refreshing...";

    public static string DefaultCompletedStatusMessage { get; } = "Remote desktop workspace updated";

    public static string BuildDefaultCompletedStatus(RemoteDesktopWorkspaceSnapshot snapshot) =>
        $"Snapshot {snapshot.CapturedAt:HH:mm:ss} UTC";

    public async Task<RemoteDesktopWorkspaceSnapshot> BuildReadOnlySnapshotAsync(
        string bitrateProfile,
        string framerateProfile)
    {
        var local = PeerCapabilities.Windows();
        var remote = PeerCapabilities.Apple();
        var plan = await _coreBridge.PlanConnectionAsync(
            local,
            remote,
            NetworkPath.CrossNatPath(),
            CryptoProviderCapabilities.ResearchAll(),
            new ushort[] { 0x0001, 0x0101, 0x1001 },
            CryptoSuitePolicy.Compatibility(),
            TrafficPaddingPlan.Sbp2Fixed(1024));
        var realtime = await _coreBridge.MapChannelAsync(plan.Transport.Kind, CoreChannelKind.Realtime);
        var telemetry = await _coreBridge.MapChannelAsync(plan.Transport.Kind, CoreChannelKind.Telemetry);
        var control = await _coreBridge.MapChannelAsync(plan.Transport.Kind, CoreChannelKind.Control);
        var frame = await _coreBridge.EncodeSbp2FrameAsync(
            CoreChannelKind.Realtime,
            1,
            Encoding.UTF8.GetBytes("remote-desktop-frame:preview"),
            64);
        var metadata = await _coreBridge.DecodeFrameMetadataAsync(frame);

        var sessions = new List<RemoteDesktopSessionItem>
        {
            new(
                "Desk Mac Preview",
                "Ready",
                plan.Transport.Kind.ToString(),
                $"quality={bitrateProfile}; fps={framerateProfile}",
                "Input, display capture, and disconnect remain disabled until live transport is wired."),
            new(
                "Recent iPad",
                "Recent",
                "Recommended via Device Discovery",
                "Reconnect source only",
                "Pairing must provide a verified peer key before a real session starts.")
        };

        var facts = new List<RemoteDesktopControlFact>
        {
            new("Connection mode", "Auto", plan.Transport.AuditCode.ToString()),
            new("Realtime channel", realtime.BindingKind.ToString(), $"reliability={realtime.Reliability}; HOL isolated={realtime.HeadOfLineIsolated}"),
            new("Telemetry channel", telemetry.BindingKind.ToString(), $"reliability={telemetry.Reliability}; HOL isolated={telemetry.HeadOfLineIsolated}"),
            new("Control channel", control.BindingKind.ToString(), $"reliability={control.Reliability}; HOL isolated={control.HeadOfLineIsolated}"),
            new("Quality", bitrateProfile, $"framerate={framerateProfile}"),
            new("Frame envelope", $"{metadata.FrameHeaderLen} byte header", $"sbp2={metadata.IsSbp2Padded}; encoded={metadata.EncodedLen}; decoded={metadata.DecodedPayloadLen}"),
            new("Performance overlay", "read-only", "latency and bandwidth placeholders until video metrics are wired")
        };

        return new RemoteDesktopWorkspaceSnapshot(DateTimeOffset.UtcNow, sessions, facts);
    }
}

public sealed record RemoteDesktopWorkspaceSnapshot(
    DateTimeOffset CapturedAt,
    IReadOnlyList<RemoteDesktopSessionItem> Sessions,
    IReadOnlyList<RemoteDesktopControlFact> ControlFacts);

public sealed record RemoteDesktopSessionItem(
    string TargetName,
    string State,
    string Transport,
    string Quality,
    string Detail);

public sealed record RemoteDesktopControlFact(
    string Label,
    string Value,
    string Detail);
