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
        if (!string.Equals(mode, ExternalTransportAdapterMode, StringComparison.OrdinalIgnoreCase))
        {
            return new PendingWindowsTransportAdapterClient();
        }

        return new ExternalWindowsTransportAdapterClient(
            new WindowsExternalTransportAdapterOptions(
                ReadAdapterKind(),
                Required("SKYBRIDGE_WINDOWS_ADAPTER_BINDING"),
                Required("SKYBRIDGE_WINDOWS_LOCAL_ENDPOINT"),
                Required("SKYBRIDGE_WINDOWS_REMOTE_ENDPOINT"),
                Required("SKYBRIDGE_WINDOWS_SELECTED_CANDIDATE_PAIR"),
                RequiredHex32("SKYBRIDGE_WINDOWS_TRANSPORT_SECRET_FP_HEX"),
                RequiredHex32("SKYBRIDGE_WINDOWS_CAPABILITY_DIGEST_HEX"),
                Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_RELAY_ID"),
                ReadTimestampWindowMs()));
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

    private static string Required(string variable)
    {
        var value = Environment.GetEnvironmentVariable(variable);
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException($"{variable} is required when SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER=external.");
        }

        return value;
    }

    private static byte[] RequiredHex32(string variable)
    {
        var raw = Required(variable);
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
