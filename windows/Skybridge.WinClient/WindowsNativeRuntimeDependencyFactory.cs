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
    private const string MsQuicTransportAdapterMode = "msquic";
    private const string MsQuicRoleVariable = "SKYBRIDGE_WINDOWS_MSQUIC_ROLE";
    private const string MsQuicDialRole = "dial";
    private const string MsQuicListenRole = "listen";
    private const string SettingsSystemPreferencesVariable = "SKYBRIDGE_WINDOWS_SETTINGS_SYSTEM_PREFERENCES";
    private const string EnabledMode = "enabled";

    public static bool IsNativeRuntimeRequested() =>
        string.Equals(
            Environment.GetEnvironmentVariable(RuntimeModeVariable),
            NativeRuntimeMode,
            StringComparison.OrdinalIgnoreCase);

    public static SessionViewModelDependencies CreateFromEnvironment()
    {
        var coreBridge = new CoreBridge();
        var discoveryClient = new CoreDiscoveryClient(coreBridge);
        var transportAdapterClient = CreateTransportAdapterFromEnvironment();

        return new SessionViewModelDependencies(
            new FfiEngineClient(),
            discoveryClient,
            new WindowsDiscoveryBrowserClient(discoveryClient, new NativeWindowsDnsSdBrowseClient()),
            new DeviceDiscoveryInputDefaultsClient(),
            new ManualConnectionClient(),
            new CrossNetworkConnectionClient(),
            new PairingMaterialClient(),
            new ConnectionPreflightClient(coreBridge, transportAdapterClient),
            new CoreDiagnosticsClient(coreBridge),
            new FileTransferWorkspaceClient(coreBridge),
            new RemoteDesktopWorkspaceClient(coreBridge),
            new RemoteDesktopProfileCatalogClient(),
            new SystemMonitorWorkspaceClient(),
            new UsbManagementWorkspaceClient(),
            CreateSettingsWorkspaceClientFromEnvironment(),
            new DashboardMetricsClient(),
            new TopBarStatusClient(),
            new ConnectionWorkspaceStateClient(),
            new WorkspaceActionCatalogClient(),
            new WorkspaceErrorStatusClient(),
            new SessionStatusClient(),
            new FeatureCatalogClient(),
            new SessionCommandStateClient(),
            new WorkspaceCommandStateClient());
    }

    public static ISettingsWorkspaceClient CreateSettingsWorkspaceClientFromEnvironment() =>
        IsEnabled(SettingsSystemPreferencesVariable)
            ? new SettingsWorkspaceClient(new WindowsSystemPreferencesLauncher())
            : new SettingsWorkspaceClient();

    private static IWindowsTransportAdapterClient CreateTransportAdapterFromEnvironment()
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
