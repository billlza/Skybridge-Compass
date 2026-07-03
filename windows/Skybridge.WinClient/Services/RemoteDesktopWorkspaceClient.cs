using System;
using System.Collections.Generic;
using System.Text;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface IRemoteDesktopWorkspaceClient
{
    string BuildInitialStatus();

    string BuildPendingStatus();

    string BuildCompletedStatus(RemoteDesktopWorkspaceSnapshot snapshot);

    string BuildCompletedStatusMessage();

    bool CanStartRecommendedSession();

    bool CanStartAdvancedSession();

    bool CanShowPerformanceOverlay();

    bool CanApplyQuality();

    bool CanOpenSettings();

    bool CanEnterFullScreen();

    bool CanDisconnectSession();

    string BuildRecommendedConnectPendingStatus();

    string BuildAdvancedConnectPendingStatus();

    string BuildNearFieldPendingStatus();

    string BuildAdvancedConnectModeStatus();

    string BuildPerformanceOverlayPendingStatus();

    string BuildQualityPendingStatus();

    string BuildSettingsPendingStatus();

    string BuildFullScreenPendingStatus();

    string BuildDisconnectSessionPendingStatus();

    Task<RemoteDesktopWorkspaceSnapshot> BuildReadOnlySnapshotAsync(
        string bitrateProfile,
        string framerateProfile);

    Task<RemoteDesktopWorkspaceActionResult> BuildRecommendedConnectActionAsync();

    Task<RemoteDesktopWorkspaceActionResult> BuildAdvancedConnectActionAsync();

    Task<RemoteDesktopWorkspaceActionResult> BuildPerformanceOverlayActionAsync();

    Task<RemoteDesktopWorkspaceActionResult> BuildQualityActionAsync(
        string bitrateProfile,
        string framerateProfile);

    Task<RemoteDesktopWorkspaceActionResult> BuildSettingsActionAsync();

    Task<RemoteDesktopWorkspaceActionResult> BuildFullScreenActionAsync();

    Task<RemoteDesktopWorkspaceActionResult> BuildDisconnectSessionActionAsync();
}

public interface IRemoteDesktopControlPanelClient
{
    RemoteDesktopControlPanelSnapshot BuildSnapshot();

    bool CanShowPerformanceOverlay();

    bool CanApplyQuality();

    bool CanOpenSettings();

    RemoteDesktopWorkspaceActionResult ShowPerformanceOverlay();

    RemoteDesktopWorkspaceActionResult ApplyQuality(
        string bitrateProfile,
        string framerateProfile);

    RemoteDesktopWorkspaceActionResult OpenSettings();
}

public sealed class InMemoryRemoteDesktopControlPanelClient : IRemoteDesktopControlPanelClient
{
    private readonly object _sync = new();
    private bool _isPerformanceOverlayVisible;
    private bool _isSettingsPanelOpen;
    private string _appliedBitrateProfile = "Medium";
    private string _appliedFramerateProfile = "Fps60";

    public RemoteDesktopControlPanelSnapshot BuildSnapshot()
    {
        lock (_sync)
        {
            return new(
                _isPerformanceOverlayVisible,
                _appliedBitrateProfile,
                _appliedFramerateProfile,
                _isSettingsPanelOpen);
        }
    }

    public bool CanShowPerformanceOverlay() => true;

    public bool CanApplyQuality() => true;

    public bool CanOpenSettings() => true;

    public RemoteDesktopWorkspaceActionResult ShowPerformanceOverlay()
    {
        lock (_sync)
        {
            _isPerformanceOverlayVisible = true;
        }

        return RemoteDesktopWorkspaceClient.BuildPerformanceOverlayReadyActionResult();
    }

    public RemoteDesktopWorkspaceActionResult ApplyQuality(
        string bitrateProfile,
        string framerateProfile)
    {
        var bitrate = NormalizeProfile(bitrateProfile, "Medium");
        var framerate = NormalizeProfile(framerateProfile, "Fps60");
        lock (_sync)
        {
            _appliedBitrateProfile = bitrate;
            _appliedFramerateProfile = framerate;
        }

        return RemoteDesktopWorkspaceClient.BuildQualityAppliedActionResult(bitrate, framerate);
    }

    public RemoteDesktopWorkspaceActionResult OpenSettings()
    {
        lock (_sync)
        {
            _isSettingsPanelOpen = true;
        }

        return RemoteDesktopWorkspaceClient.BuildSettingsReadyActionResult();
    }

    private static string NormalizeProfile(string value, string fallback)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return fallback;
        }

        return value.Trim();
    }
}

public sealed class RemoteDesktopWorkspaceClient : IRemoteDesktopWorkspaceClient
{
    private readonly CoreBridge _coreBridge;
    private readonly IRemoteDesktopControlPanelClient _controlPanelClient;

    public RemoteDesktopWorkspaceClient(CoreBridge coreBridge)
        : this(coreBridge, new InMemoryRemoteDesktopControlPanelClient())
    {
    }

    public RemoteDesktopWorkspaceClient(
        CoreBridge coreBridge,
        IRemoteDesktopControlPanelClient controlPanelClient)
    {
        _coreBridge = coreBridge ?? throw new ArgumentNullException(nameof(coreBridge));
        _controlPanelClient = controlPanelClient ?? throw new ArgumentNullException(nameof(controlPanelClient));
    }

    public string BuildPendingStatus() => DefaultPendingStatus;

    public string BuildInitialStatus() => DefaultInitialStatus;

    public string BuildCompletedStatus(RemoteDesktopWorkspaceSnapshot snapshot) =>
        BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() => DefaultCompletedStatusMessage;

    public bool CanStartRecommendedSession() => false;

    public bool CanStartAdvancedSession() => false;

    public bool CanShowPerformanceOverlay() => _controlPanelClient.CanShowPerformanceOverlay();

    public bool CanApplyQuality() => _controlPanelClient.CanApplyQuality();

    public bool CanOpenSettings() => _controlPanelClient.CanOpenSettings();

    public bool CanEnterFullScreen() => false;

    public bool CanDisconnectSession() => false;

    public string BuildRecommendedConnectPendingStatus() => DefaultRecommendedConnectPendingStatus;

    public string BuildAdvancedConnectPendingStatus() => DefaultAdvancedConnectPendingStatus;

    // Honest, fail-closed status for the Mac connectionModeSelector ".nearField" segment.
    // There is no Windows near-field capture transport (no display-capture adapter, no
    // local-mirror window pump) so this surfaces an explicit pending-adapter string in the
    // same fail-closed idiom as the connect actions above. It is NOT a transport claim and
    // NOT a fabricated state — selecting Near states plainly that no capture has started.
    public string BuildNearFieldPendingStatus() => DefaultNearFieldPendingStatus;

    // Honest status for the Mac connectionModeSelector ".farFieldRDP" segment. Far-field
    // (manual RDP/VNC/SSH) needs the operator to provide a target before any session can be
    // prepared; this restates that intent without starting a transport (fail-closed parity
    // with BuildAdvancedConnectActionAsync, which also never launches a live session).
    public string BuildAdvancedConnectModeStatus() => DefaultAdvancedConnectModeStatus;

    public string BuildPerformanceOverlayPendingStatus() => DefaultPerformanceOverlayPendingStatus;

    public string BuildQualityPendingStatus() => DefaultQualityPendingStatus;

    public string BuildSettingsPendingStatus() => DefaultSettingsPendingStatus;

    public string BuildFullScreenPendingStatus() => DefaultFullScreenPendingStatus;

    public string BuildDisconnectSessionPendingStatus() => DefaultDisconnectSessionPendingStatus;

    public static string DefaultInitialStatus { get; } = "Ready";

    public static string DefaultPendingStatus { get; } = "Refreshing...";

    public static string DefaultCompletedStatusMessage { get; } = "Remote desktop workspace updated";

    public static string DefaultRecommendedConnectPendingStatus { get; } = "Preparing recommended session...";

    public static string DefaultAdvancedConnectPendingStatus { get; } = "Preparing advanced session...";

    public static string DefaultNearFieldPendingStatus { get; } =
        "Near-field mirror pending capture adapter";

    public static string DefaultAdvancedConnectModeStatus { get; } =
        "Advanced connect: provide an RDP/VNC/SSH target to start a manual session.";

    public static string DefaultPerformanceOverlayPendingStatus { get; } = "Preparing performance overlay...";

    public static string DefaultQualityPendingStatus { get; } = "Preparing quality controls...";

    public static string DefaultSettingsPendingStatus { get; } = "Preparing remote desktop settings...";

    public static string DefaultFullScreenPendingStatus { get; } = "Preparing full screen...";

    public static string DefaultDisconnectSessionPendingStatus { get; } = "Preparing session disconnect...";

    public static string DefaultRecommendedConnectBlockedStatus { get; } = "Recommended session pending adapter";

    public static string DefaultRecommendedConnectBlockedMessage { get; } = "Remote Desktop recommended connect remains fail-closed";

    public static string DefaultAdvancedConnectBlockedStatus { get; } = "Advanced session pending adapter";

    public static string DefaultAdvancedConnectBlockedMessage { get; } = "Remote Desktop advanced connect remains fail-closed";

    public static string DefaultPerformanceOverlayBlockedStatus { get; } = "Performance overlay pending adapter";

    public static string DefaultPerformanceOverlayBlockedMessage { get; } = "Remote Desktop performance overlay remains fail-closed";

    public static string DefaultPerformanceOverlayReadyStatus { get; } = "Performance overlay ready";

    public static string DefaultPerformanceOverlayReadyMessage { get; } =
        "Remote Desktop performance overlay state is enabled in memory only";

    public static string DefaultQualityBlockedStatus { get; } = "Quality controls pending adapter";

    public static string DefaultQualityBlockedMessage { get; } = "Remote Desktop quality application remains fail-closed";

    public static string DefaultQualityAppliedStatus { get; } = "Quality preview applied";

    public static string DefaultQualityAppliedMessage { get; } =
        "Remote Desktop quality preference is recorded in memory only";

    public static string DefaultSettingsBlockedStatus { get; } = "Remote Desktop settings pending adapter";

    public static string DefaultSettingsBlockedMessage { get; } = "Remote Desktop runtime settings remain fail-closed";

    public static string DefaultSettingsReadyStatus { get; } = "Remote Desktop settings ready";

    public static string DefaultSettingsReadyMessage { get; } =
        "Remote Desktop settings panel state is opened in memory only";

    public static string DefaultFullScreenBlockedStatus { get; } = "Full screen pending adapter";

    public static string DefaultFullScreenBlockedMessage { get; } = "Remote Desktop full screen remains fail-closed";

    public static string DefaultDisconnectSessionBlockedStatus { get; } = "Session disconnect pending adapter";

    public static string DefaultDisconnectSessionBlockedMessage { get; } = "Remote Desktop session disconnect remains fail-closed";

    public static string BuildDefaultCompletedStatus(RemoteDesktopWorkspaceSnapshot snapshot) =>
        $"Snapshot {snapshot.CapturedAt:HH:mm:ss} UTC";

    public static RemoteDesktopWorkspaceActionResult BuildDefaultRecommendedConnectActionResult() =>
        new(
            DefaultRecommendedConnectBlockedStatus,
            DefaultRecommendedConnectBlockedMessage,
            "No capture, input forwarding, transport launch, or session window was started.");

    public static RemoteDesktopWorkspaceActionResult BuildDefaultAdvancedConnectActionResult() =>
        new(
            DefaultAdvancedConnectBlockedStatus,
            DefaultAdvancedConnectBlockedMessage,
            "No endpoint picker, capture provider, input channel, or transport launch was started.");

    public static RemoteDesktopWorkspaceActionResult BuildDefaultPerformanceOverlayActionResult() =>
        new(
            DefaultPerformanceOverlayBlockedStatus,
            DefaultPerformanceOverlayBlockedMessage,
            "No overlay window, telemetry sampler, or live session metrics provider was started.");

    public static RemoteDesktopWorkspaceActionResult BuildPerformanceOverlayReadyActionResult() =>
        new(
            DefaultPerformanceOverlayReadyStatus,
            DefaultPerformanceOverlayReadyMessage,
            "No overlay window, telemetry sampler, capture provider, or live session metrics provider was started.");

    public static RemoteDesktopWorkspaceActionResult BuildDefaultQualityActionResult() =>
        new(
            DefaultQualityBlockedStatus,
            DefaultQualityBlockedMessage,
            "No encoder profile, stream bitrate, frame rate, or live transport setting was changed.");

    public static RemoteDesktopWorkspaceActionResult BuildQualityAppliedActionResult(
        string bitrateProfile,
        string framerateProfile) =>
        new(
            DefaultQualityAppliedStatus,
            DefaultQualityAppliedMessage,
            $"bitrate={bitrateProfile}; framerate={framerateProfile}; no encoder profile, stream bitrate, frame rate, or live transport setting was changed.");

    public static RemoteDesktopWorkspaceActionResult BuildDefaultSettingsActionResult() =>
        new(
            DefaultSettingsBlockedStatus,
            DefaultSettingsBlockedMessage,
            "No runtime preference, permission, or persisted setting was changed.");

    public static RemoteDesktopWorkspaceActionResult BuildSettingsReadyActionResult() =>
        new(
            DefaultSettingsReadyStatus,
            DefaultSettingsReadyMessage,
            "No runtime preference, permission prompt, Windows Settings launch, or persisted setting was changed.");

    public static RemoteDesktopWorkspaceActionResult BuildDefaultFullScreenActionResult() =>
        new(
            DefaultFullScreenBlockedStatus,
            DefaultFullScreenBlockedMessage,
            "No remote desktop window was created, resized, or moved.");

    public static RemoteDesktopWorkspaceActionResult BuildDefaultDisconnectSessionActionResult() =>
        new(
            DefaultDisconnectSessionBlockedStatus,
            DefaultDisconnectSessionBlockedMessage,
            "No live session, transport, or remote peer was disconnected.");

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
        var channelMappings = CoreChannelMappingResolver.RequireAll(plan.ChannelMappings);
        var realtime = CoreChannelMappingResolver.Require(channelMappings, CoreChannelKind.Realtime);
        var telemetry = CoreChannelMappingResolver.Require(channelMappings, CoreChannelKind.Telemetry);
        var control = CoreChannelMappingResolver.Require(channelMappings, CoreChannelKind.Control);
        var frame = await _coreBridge.EncodeSbp2FrameAsync(
            CoreChannelKind.Realtime,
            1,
            Encoding.UTF8.GetBytes("remote-desktop-frame:preview"),
            64);
        var metadata = await _coreBridge.DecodeFrameMetadataAsync(frame);
        var controlPanel = _controlPanelClient.BuildSnapshot();

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
            new("Core channel map", $"{channelMappings.Count} channels", "control/file/clipboard/telemetry/realtime from the connection plan"),
            new("Realtime channel", realtime.BindingKind.ToString(), $"reliability={realtime.Reliability}; HOL isolated={realtime.HeadOfLineIsolated}"),
            new("Telemetry channel", telemetry.BindingKind.ToString(), $"reliability={telemetry.Reliability}; HOL isolated={telemetry.HeadOfLineIsolated}"),
            new("Control channel", control.BindingKind.ToString(), $"reliability={control.Reliability}; HOL isolated={control.HeadOfLineIsolated}"),
            new("Quality", bitrateProfile, $"framerate={framerateProfile}; applied={controlPanel.AppliedBitrateProfile}/{controlPanel.AppliedFramerateProfile}"),
            new("Frame envelope", $"{metadata.FrameHeaderLen} byte header", $"sbp2={metadata.IsSbp2Padded}; encoded={metadata.EncodedLen}; decoded={metadata.DecodedPayloadLen}"),
            new("Performance overlay", controlPanel.IsPerformanceOverlayVisible ? "visible" : "read-only", "in-memory control state only; no overlay window or telemetry sampler is started"),
            new("Settings panel", controlPanel.IsSettingsPanelOpen ? "open" : "closed", "in-memory control state only; no runtime preferences are changed")
        };

        return new RemoteDesktopWorkspaceSnapshot(DateTimeOffset.UtcNow, sessions, facts);
    }

    public Task<RemoteDesktopWorkspaceActionResult> BuildRecommendedConnectActionAsync() =>
        Task.FromResult(BuildDefaultRecommendedConnectActionResult());

    public Task<RemoteDesktopWorkspaceActionResult> BuildAdvancedConnectActionAsync() =>
        Task.FromResult(BuildDefaultAdvancedConnectActionResult());

    public Task<RemoteDesktopWorkspaceActionResult> BuildPerformanceOverlayActionAsync() =>
        Task.FromResult(_controlPanelClient.ShowPerformanceOverlay());

    public Task<RemoteDesktopWorkspaceActionResult> BuildQualityActionAsync(
        string bitrateProfile,
        string framerateProfile) =>
        Task.FromResult(_controlPanelClient.ApplyQuality(bitrateProfile, framerateProfile));

    public Task<RemoteDesktopWorkspaceActionResult> BuildSettingsActionAsync() =>
        Task.FromResult(_controlPanelClient.OpenSettings());

    public Task<RemoteDesktopWorkspaceActionResult> BuildFullScreenActionAsync() =>
        Task.FromResult(BuildDefaultFullScreenActionResult());

    public Task<RemoteDesktopWorkspaceActionResult> BuildDisconnectSessionActionAsync() =>
        Task.FromResult(BuildDefaultDisconnectSessionActionResult());
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

public sealed record RemoteDesktopControlPanelSnapshot(
    bool IsPerformanceOverlayVisible,
    string AppliedBitrateProfile,
    string AppliedFramerateProfile,
    bool IsSettingsPanelOpen);

public sealed record RemoteDesktopWorkspaceActionResult(
    string Status,
    string Message,
    string Detail);
