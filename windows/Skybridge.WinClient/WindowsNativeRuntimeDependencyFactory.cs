using System;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.ViewModels;

namespace Skybridge.WinClient;

internal static class WindowsNativeRuntimeDependencyFactory
{
    private const string RuntimeModeVariable = "SKYBRIDGE_WINDOWS_RUNTIME";
    private const string NativeRuntimeMode = "native";
    private const string TransportAdapterVariable = "SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER";
    private const string ExternalTransportAdapterMode = "external";
    private const string VerifiedWebRtcTransportAdapterMode = "webrtc-verified";
    private const string VerifiedWebRtcLaunchTransportAdapterMode = "webrtc-verified-launch";
    private const string MsQuicTransportAdapterMode = "msquic";
    private const string MsQuicRoleVariable = "SKYBRIDGE_WINDOWS_MSQUIC_ROLE";
    private const string MsQuicDialRole = "dial";
    private const string MsQuicListenRole = "listen";
    private const string SessionDataPlaneVariable = "SKYBRIDGE_WINDOWS_SESSION_DATA_PLANE";
    private const string WebRtcHelperSessionDataPlaneMode = "webrtc-helper";
    private const string WebRtcSessionRoleVariable = "SKYBRIDGE_WINDOWS_WEBRTC_SESSION_ROLE";
    private const string WebRtcSessionOfferRole = "offer";
    private const string WebRtcSessionAnswerRole = "answer";
    private const string WebRtcSessionIpcPortVariable = "SKYBRIDGE_WINDOWS_WEBRTC_SESSION_IPC_PORT";
    private const string ClipboardSyncVariable = "SKYBRIDGE_WINDOWS_CLIPBOARD_SYNC";
    private const string ClipboardImagesVariable = "SKYBRIDGE_WINDOWS_CLIPBOARD_IMAGES";
    private const string SettingsSystemPreferencesVariable = "SKYBRIDGE_WINDOWS_SETTINGS_SYSTEM_PREFERENCES";
    private const string EnabledMode = "enabled";
    private const string DisabledMode = "disabled";

    public static bool IsNativeRuntimeRequested() =>
        string.Equals(
            Environment.GetEnvironmentVariable(RuntimeModeVariable),
            NativeRuntimeMode,
            StringComparison.OrdinalIgnoreCase);

    public static SessionViewModelDependencies CreateFromEnvironment()
    {
        var coreBridge = new CoreBridge();
        var discoveryClient = new CoreDiscoveryClient(coreBridge);
        var connectionPreflightClient = CreateConnectionPreflightClientFromEnvironment(coreBridge);

        return new SessionViewModelDependencies(
            CreateEngineClientFromEnvironment(),
            discoveryClient,
            new WindowsDiscoveryBrowserClient(discoveryClient, new NativeWindowsDnsSdBrowseClient()),
            new DeviceDiscoveryInputDefaultsClient(),
            new ManualConnectionClient(),
            new CrossNetworkConnectionClient(),
            new PairingMaterialClient(),
            connectionPreflightClient,
            new CoreDiagnosticsClient(coreBridge),
            new FileTransferWorkspaceClient(coreBridge),
            new RemoteDesktopWorkspaceClient(coreBridge),
            new RemoteDesktopProfileCatalogClient(),
            new SystemMonitorWorkspaceClient(),
            new UsbManagementWorkspaceClient(),
            CreateSettingsWorkspaceClientFromEnvironment(),
            new DashboardMetricsClient(),
            new WeatherClient(),
            new TopBarStatusClient(),
            new ConnectionWorkspaceStateClient(),
            new WorkspaceActionCatalogClient(),
            new WorkspaceErrorStatusClient(),
            new SessionStatusClient(),
            new FeatureCatalogClient(),
            new SessionCommandStateClient(),
            new WorkspaceCommandStateClient());
    }

    private static IEngineClient CreateEngineClientFromEnvironment()
    {
        var engineClient = CreateBaseEngineClient();
        var mode = Environment.GetEnvironmentVariable(SessionDataPlaneVariable);
        if (string.IsNullOrWhiteSpace(mode))
        {
            return engineClient;
        }

        if (string.Equals(mode, WebRtcHelperSessionDataPlaneMode, StringComparison.OrdinalIgnoreCase))
        {
            return new WebRtcSessionEngineClient(
                engineClient,
                new WebRtcHelperLaunchClient(CreateWebRtcHelperLaunchOptionsFromEnvironment()),
                CreateWebRtcSessionEngineOptionsFromEnvironment());
        }

        throw new InvalidOperationException("SKYBRIDGE_WINDOWS_SESSION_DATA_PLANE must be webrtc-helper when set.");
    }

    private static IEngineClient CreateBaseEngineClient() => new FfiEngineClient();

    public static ISettingsWorkspaceClient CreateSettingsWorkspaceClientFromEnvironment() =>
        IsEnabled(SettingsSystemPreferencesVariable)
            ? new SettingsWorkspaceClient(new WindowsSystemPreferencesLauncher())
            : new SettingsWorkspaceClient();

    // Picks the connection-preflight client from the transport-adapter env mode.
    //
    //  - webrtc-verified-launch  -> the in-session launcher path: each connect first launches the
    //                               WebRtcHelper offerer to produce a FRESH proof bound to the real
    //                               paired identity, then runs the standard preflight against a
    //                               runtime verified adapter over that fresh proof. This closes the
    //                               env-at-startup vs. 60s freshness-window gap.
    //  - everything else         -> the back-compat env path: the adapter (incl. webrtc-verified
    //                               reading a pre-existing proof file at SKYBRIDGE_WINDOWS_WEBRTC_PROOF_PATH)
    //                               is resolved once at startup, exactly as before.
    private static IConnectionPreflightClient CreateConnectionPreflightClientFromEnvironment(CoreBridge coreBridge)
    {
        var mode = Environment.GetEnvironmentVariable(TransportAdapterVariable);
        if (string.Equals(mode, VerifiedWebRtcLaunchTransportAdapterMode, StringComparison.OrdinalIgnoreCase))
        {
            return new LaunchingWebRtcVerifiedPreflightClient(
                coreBridge,
                new WebRtcHelperLaunchClient(CreateWebRtcHelperLaunchOptionsFromEnvironment()),
                ReadWebRtcProofMaxAgeMs());
        }

        // Keep the explicit `transportAdapterClient` local: verify-windows-ffi-client.ps1
        // asserts the literal factory signal "ConnectionPreflightClient(coreBridge, transportAdapterClient)".
        var transportAdapterClient = CreateTransportAdapterFromEnvironment(coreBridge);
        return new ConnectionPreflightClient(coreBridge, transportAdapterClient);
    }

    private static WebRtcHelperLaunchOptions CreateWebRtcHelperLaunchOptionsFromEnvironment() =>
        new(
            ResolveWebRtcHelperExecutablePath(),
            ResolveWebRtcSignalingDirectory(),
            Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_PROOF_FILE_NAME"),
            Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_OFFER_FILE_NAME"),
            Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_ANSWER_FILE_NAME"),
            Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_ICE_SERVERS"),
            ReadWebRtcHelperLaunchTimeout());

    private static WebRtcSessionEngineOptions CreateWebRtcSessionEngineOptionsFromEnvironment() =>
        new(
            ReadWebRtcSessionAsAnswerer(),
            ReadWebRtcSessionIpcPort(),
            IsEnabled(ClipboardSyncVariable),
            !IsDisabled(ClipboardImagesVariable));

    private static string ResolveWebRtcHelperExecutablePath()
    {
        var configured = Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_HELPER_PATH");
        if (!string.IsNullOrWhiteSpace(configured))
        {
            return configured.Trim();
        }

        // Default: the helper exe sitting next to the app.
        return System.IO.Path.Combine(AppContext.BaseDirectory, "Skybridge.WebRtcHelper.exe");
    }

    private static string ResolveWebRtcSignalingDirectory()
    {
        var configured = Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_SIGNALING_DIR");
        if (!string.IsNullOrWhiteSpace(configured))
        {
            return configured.Trim();
        }

        return System.IO.Path.Combine(AppContext.BaseDirectory, "webrtc-signaling");
    }

    private static TimeSpan? ReadWebRtcHelperLaunchTimeout()
    {
        var raw = Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_LAUNCH_TIMEOUT_MS");
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        if (ulong.TryParse(raw, out var value) && value > 0)
        {
            return TimeSpan.FromMilliseconds(value);
        }

        throw new InvalidOperationException("SKYBRIDGE_WINDOWS_WEBRTC_LAUNCH_TIMEOUT_MS must be a positive unsigned integer.");
    }

    private static bool ReadWebRtcSessionAsAnswerer()
    {
        var raw = Environment.GetEnvironmentVariable(WebRtcSessionRoleVariable);
        if (string.IsNullOrWhiteSpace(raw)
            || string.Equals(raw, WebRtcSessionOfferRole, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (string.Equals(raw, WebRtcSessionAnswerRole, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        throw new InvalidOperationException("SKYBRIDGE_WINDOWS_WEBRTC_SESSION_ROLE must be offer or answer when set.");
    }

    private static int ReadWebRtcSessionIpcPort()
    {
        var raw = Environment.GetEnvironmentVariable(WebRtcSessionIpcPortVariable);
        if (string.IsNullOrWhiteSpace(raw))
        {
            return 0;
        }

        if (int.TryParse(raw, out var value) && value is >= 0 and <= 65535)
        {
            return value;
        }

        throw new InvalidOperationException("SKYBRIDGE_WINDOWS_WEBRTC_SESSION_IPC_PORT must be an integer in the range 0..65535.");
    }

    private static IWindowsTransportAdapterClient CreateTransportAdapterFromEnvironment(CoreBridge coreBridge)
    {
        var mode = Environment.GetEnvironmentVariable(TransportAdapterVariable);
        if (string.IsNullOrWhiteSpace(mode))
        {
            return new PendingWindowsTransportAdapterClient();
        }

        if (string.Equals(mode, ExternalTransportAdapterMode, StringComparison.OrdinalIgnoreCase))
        {
            return new ExternalWindowsTransportAdapterClient(
                new WindowsExternalTransportAdapterOptions(
                    ReadAdapterKind(),
                    Required("SKYBRIDGE_WINDOWS_ADAPTER_BINDING", ExternalTransportAdapterMode),
                    Required("SKYBRIDGE_WINDOWS_LOCAL_ENDPOINT", ExternalTransportAdapterMode),
                    Required("SKYBRIDGE_WINDOWS_REMOTE_ENDPOINT", ExternalTransportAdapterMode),
                    Required("SKYBRIDGE_WINDOWS_SELECTED_CANDIDATE_PAIR", ExternalTransportAdapterMode),
                    RequiredHex32("SKYBRIDGE_WINDOWS_TRANSPORT_SECRET_FP_HEX", ExternalTransportAdapterMode),
                    RequiredHex32("SKYBRIDGE_WINDOWS_CAPABILITY_DIGEST_HEX", ExternalTransportAdapterMode),
                    Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_RELAY_ID"),
                    ReadTimestampWindowMs()));
        }

        if (string.Equals(mode, VerifiedWebRtcTransportAdapterMode, StringComparison.OrdinalIgnoreCase))
        {
            return new VerifiedWebRtcDataChannelTransportAdapterClient(
                coreBridge,
                new WindowsVerifiedWebRtcDataChannelOptions(
                    Required("SKYBRIDGE_WINDOWS_WEBRTC_PROOF_PATH", VerifiedWebRtcTransportAdapterMode),
                    ReadWebRtcProofMaxAgeMs()));
        }

        if (string.Equals(mode, MsQuicTransportAdapterMode, StringComparison.OrdinalIgnoreCase))
        {
            return CreateMsQuicAdapterFromEnvironment();
        }

        throw new InvalidOperationException("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER must be external, webrtc-verified, or msquic when set.");
    }

    private static IWindowsTransportAdapterClient CreateMsQuicAdapterFromEnvironment()
    {
        // Role selection closes the bidirectional Win-to-Win MsQuic path: one box dials, one box listens.
        // The role defaults to "dial" so the existing T7a dialer wiring (peer-endpoint only) keeps working
        // unchanged when SKYBRIDGE_WINDOWS_MSQUIC_ROLE is unset.
        var role = Environment.GetEnvironmentVariable(MsQuicRoleVariable);
        if (string.IsNullOrWhiteSpace(role) || string.Equals(role, MsQuicDialRole, StringComparison.OrdinalIgnoreCase))
        {
            return new WindowsNativeMsQuicTransportAdapterClient(
                new WindowsNativeMsQuicTransportAdapterOptions(
                    Required("SKYBRIDGE_WINDOWS_MSQUIC_PEER_ENDPOINT", MsQuicTransportAdapterMode),
                    ReadTimestampWindowMs()));
        }

        if (string.Equals(role, MsQuicListenRole, StringComparison.OrdinalIgnoreCase))
        {
            return new WindowsNativeMsQuicListenerTransportAdapterClient(
                new WindowsNativeMsQuicListenerTransportAdapterOptions(
                    Required("SKYBRIDGE_WINDOWS_MSQUIC_LISTEN_ENDPOINT", MsQuicTransportAdapterMode),
                    ReadTimestampWindowMs(),
                    ReadMsQuicAcceptTimeoutMs()));
        }

        throw new InvalidOperationException("SKYBRIDGE_WINDOWS_MSQUIC_ROLE must be dial or listen when SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER=msquic.");
    }

    private static ulong ReadMsQuicAcceptTimeoutMs()
    {
        var raw = Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_MSQUIC_ACCEPT_TIMEOUT_MS");
        if (string.IsNullOrWhiteSpace(raw))
        {
            return 60_000;
        }

        if (ulong.TryParse(raw, out var value) && value > 0)
        {
            return value;
        }

        throw new InvalidOperationException("SKYBRIDGE_WINDOWS_MSQUIC_ACCEPT_TIMEOUT_MS must be a positive unsigned integer.");
    }

    private static bool IsEnabled(string variable) =>
        string.Equals(
            Environment.GetEnvironmentVariable(variable),
            EnabledMode,
            StringComparison.OrdinalIgnoreCase);

    private static bool IsDisabled(string variable) =>
        string.Equals(
            Environment.GetEnvironmentVariable(variable),
            DisabledMode,
            StringComparison.OrdinalIgnoreCase);

    private static ConnectionLaunchAdapterKind ReadAdapterKind()
    {
        var raw = Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_ADAPTER_KIND");
        if (string.IsNullOrWhiteSpace(raw))
        {
            return ConnectionLaunchAdapterKind.None;
        }

        if (Enum.TryParse<ConnectionLaunchAdapterKind>(raw, ignoreCase: true, out var value))
        {
            return value;
        }

        throw new InvalidOperationException("SKYBRIDGE_WINDOWS_ADAPTER_KIND must name a ConnectionLaunchAdapterKind value.");
    }

    private static ulong ReadTimestampWindowMs()
    {
        var raw = Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_TIMESTAMP_WINDOW_MS");
        if (string.IsNullOrWhiteSpace(raw))
        {
            return 10_000;
        }

        if (ulong.TryParse(raw, out var value) && value > 0)
        {
            return value;
        }

        throw new InvalidOperationException("SKYBRIDGE_WINDOWS_TIMESTAMP_WINDOW_MS must be a positive unsigned integer.");
    }

    private static ulong ReadWebRtcProofMaxAgeMs()
    {
        var raw = Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_PROOF_MAX_AGE_MS");
        if (string.IsNullOrWhiteSpace(raw))
        {
            return 60_000;
        }

        if (ulong.TryParse(raw, out var value) && value > 0)
        {
            return value;
        }

        throw new InvalidOperationException("SKYBRIDGE_WINDOWS_WEBRTC_PROOF_MAX_AGE_MS must be a positive unsigned integer.");
    }

    private static string Required(string variable, string mode)
    {
        var value = Environment.GetEnvironmentVariable(variable);
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException($"{variable} is required when SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER={mode}.");
        }

        return value;
    }

    private static byte[] RequiredHex32(string variable, string mode)
    {
        var raw = Required(variable, mode);
        if (raw.Length != 64)
        {
            throw new InvalidOperationException($"{variable} must be 64 lowercase hex characters.");
        }

        var bytes = new byte[32];
        for (var index = 0; index < bytes.Length; index++)
        {
            var high = FromLowerHex(raw[index * 2], variable);
            var low = FromLowerHex(raw[index * 2 + 1], variable);
            bytes[index] = (byte)((high << 4) | low);
        }

        return bytes;
    }

    private static int FromLowerHex(char value, string variable)
    {
        if (value is >= '0' and <= '9')
        {
            return value - '0';
        }

        if (value is >= 'a' and <= 'f')
        {
            return value - 'a' + 10;
        }

        throw new InvalidOperationException($"{variable} must be 64 lowercase hex characters.");
    }
}
