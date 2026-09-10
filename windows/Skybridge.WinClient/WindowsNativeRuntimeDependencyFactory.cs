using System;
using System.Buffers;
using System.Buffers.Text;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
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
    private const string WebRtcSessionTransportAdapterMode = "webrtc-session";
    private const string WebRtcProductControlTransportAdapterMode = "webrtc-product-control";
    private const string MsQuicTransportAdapterMode = "msquic";
    private const string WebRtcProductSmokeVariable = "SKYBRIDGE_WINDOWS_WEBRTC_PRODUCT_SMOKE";
    private const string WebRtcProductHandshakeTimeoutVariable = "SKYBRIDGE_WINDOWS_WEBRTC_PRODUCT_HANDSHAKE_TIMEOUT_SECONDS";
    private const string WebRtcProductMldsa65PrivateKeyBase64PathVariable = "SKYBRIDGE_WINDOWS_WEBRTC_PRODUCT_MLDSA65_PRIVATE_KEY_BASE64_PATH";
    private const string WebRtcProductPeerMlKem768PublicKeyBase64PathVariable = "SKYBRIDGE_WINDOWS_WEBRTC_PRODUCT_PEER_MLKEM768_PUBLIC_KEY_BASE64_PATH";
    private const string WebRtcProductLocalMlKem768DecapsulationKeyBase64PathVariable = "SKYBRIDGE_WINDOWS_WEBRTC_PRODUCT_LOCAL_MLKEM768_DECAPSULATION_KEY_BASE64_PATH";
    private const string WebRtcProductLocalMlKem768PublicKeyBase64PathVariable = "SKYBRIDGE_WINDOWS_WEBRTC_PRODUCT_LOCAL_MLKEM768_PUBLIC_KEY_BASE64_PATH";
    private const string ControlSmokeMode = "control";
    private const string SettingsSystemPreferencesVariable = "SKYBRIDGE_WINDOWS_SETTINGS_SYSTEM_PREFERENCES";
    private const string EnabledMode = "enabled";

    public static bool IsNativeRuntimeRequested()
    {
        var mode = Environment.GetEnvironmentVariable(RuntimeModeVariable);
        if (string.IsNullOrWhiteSpace(mode))
        {
            return OperatingSystem.IsWindows();
        }
        if (!string.Equals(mode, NativeRuntimeMode, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"Unsupported Windows runtime mode: {mode}");
        }
        return true;
    }

    public static SessionViewModelDependencies CreateFromEnvironment(IFileTransferWorkspaceClient? fileTransferClient = null)
    {
        var coreBridge = new CoreBridge();
        var discoveryClient = new CoreDiscoveryClient(coreBridge);
        var transportAdapterClient = CreateTransportAdapterFromEnvironment();
        IEngineClient engineClient = new FfiEngineClient();
        IProductSessionActionGateClient productSessionActionGateClient = new ProductSessionActionGateClient();
        if (transportAdapterClient is WebRtcSessionTransportAdapterClient sessionTransportAdapterClient)
        {
            engineClient = new WebRtcSessionEngineClient(
                engineClient,
                sessionTransportAdapterClient,
                CreateWebRtcSessionRuntimeConsumersFromEnvironment());
        }
        else if (transportAdapterClient is WebRtcProductControlTransportAdapterClient productControlTransportAdapterClient)
        {
            var secureSessionStore = new WebRtcProductSecureSessionStore();
            var authenticatedRouteBindingStore = new WebRtcAuthenticatedRouteBindingStore(secureSessionStore);
            productSessionActionGateClient = new ProductSessionActionGateClient(authenticatedRouteBindingStore);
            engineClient = new WebRtcProductControlEngineClient(
                engineClient,
                productControlTransportAdapterClient,
                CreateWebRtcProductControlRuntimeConsumersFromEnvironment(
                    secureSessionStore,
                    authenticatedRouteBindingStore));
        }

        return new SessionViewModelDependencies(
            engineClient,
            discoveryClient,
            CreateDiscoveryBrowserClientFromEnvironment(discoveryClient),
            new DeviceDiscoveryInputDefaultsClient(),
            new ManualConnectionClient(),
            new CrossNetworkConnectionClient(),
            new PairingMaterialClient(),
            new ConnectionPreflightClient(coreBridge, transportAdapterClient),
            new CoreDiagnosticsClient(coreBridge),
            fileTransferClient ?? new UnavailableFileTransferWorkspaceClient(),
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
            new WorkspaceCommandStateClient(),
            productSessionActionGateClient);
    }

    public static ISettingsWorkspaceClient CreateSettingsWorkspaceClientFromEnvironment() =>
        IsEnabled(SettingsSystemPreferencesVariable)
            ? new SettingsWorkspaceClient(new WindowsSystemPreferencesLauncher())
            : new SettingsWorkspaceClient();

    private static WindowsDiscoveryBrowserClient CreateDiscoveryBrowserClientFromEnvironment(
        IDiscoveryClient discoveryClient) =>
        IsNativeRuntimeRequested()
            ? new WindowsDiscoveryBrowserClient(discoveryClient, new NativeWindowsDnsSdBrowseClient())
            : new WindowsDiscoveryBrowserClient(discoveryClient);

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

        if (string.Equals(mode, WebRtcSessionTransportAdapterMode, StringComparison.OrdinalIgnoreCase))
        {
            return new WebRtcSessionTransportAdapterClient(
                new WebRtcHelperLaunchClient(CreateWebRtcHelperLaunchOptions(WebRtcSessionTransportAdapterMode)),
                new WebRtcSessionTransportAdapterOptions(
                    ReadWebRtcSessionAsAnswerer(WebRtcSessionTransportAdapterMode),
                    ReadWebRtcSessionPreferredIpcPort(),
                    ReadTimestampWindowMs()));
        }

        if (string.Equals(mode, WebRtcProductControlTransportAdapterMode, StringComparison.OrdinalIgnoreCase))
        {
            return new WebRtcProductControlTransportAdapterClient(
                new WebRtcProductControlTransportProvider(
                    new WebRtcHelperLaunchClient(CreateWebRtcHelperLaunchOptions(WebRtcProductControlTransportAdapterMode)),
                    new WebRtcProductControlTransportOptions(
                        ReadWebRtcSessionAsAnswerer(WebRtcProductControlTransportAdapterMode),
                        ReadWebRtcSessionPreferredIpcPort(),
                        ReadTimestampWindowMs())));
        }

        if (string.Equals(mode, MsQuicTransportAdapterMode, StringComparison.OrdinalIgnoreCase))
        {
            return CreateMsQuicTransportAdapterFromEnvironment();
        }

        throw new InvalidOperationException("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER must be external, webrtc-verified, webrtc-session, webrtc-product-control, or msquic when set.");
    }

    private static IReadOnlyList<IWebRtcSessionRuntimeConsumer> CreateWebRtcSessionRuntimeConsumersFromEnvironment()
    {
        var mode = Environment.GetEnvironmentVariable(WebRtcProductSmokeVariable);
        if (string.IsNullOrWhiteSpace(mode))
        {
            return Array.Empty<IWebRtcSessionRuntimeConsumer>();
        }

        if (string.Equals(mode, ControlSmokeMode, StringComparison.OrdinalIgnoreCase))
        {
            return new IWebRtcSessionRuntimeConsumer[]
            {
                new WebRtcControlSmokeClient(
                    new WebRtcControlSmokeOptions(
                        ReadWebRtcProductSmokeTimeout(),
                        Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_PRODUCT_SMOKE_EVIDENCE_PATH")))
            };
        }

        throw new InvalidOperationException(
            $"{WebRtcProductSmokeVariable} must be '{ControlSmokeMode}' when set.");
    }

    private static IReadOnlyList<IWebRtcProductControlRuntimeConsumer> CreateWebRtcProductControlRuntimeConsumersFromEnvironment(
        WebRtcProductSecureSessionStore secureSessionStore,
        WebRtcAuthenticatedRouteBindingStore authenticatedRouteBindingStore)
    {
        ArgumentNullException.ThrowIfNull(secureSessionStore);
        ArgumentNullException.ThrowIfNull(authenticatedRouteBindingStore);
        var mode = Environment.GetEnvironmentVariable(WebRtcProductSmokeVariable);
        if (!string.IsNullOrWhiteSpace(mode))
        {
            throw new InvalidOperationException(
                $"{WebRtcProductSmokeVariable} is only supported when {TransportAdapterVariable}=webrtc-session " +
                "or in the RuntimeSmoke product-control profile; raw product-control smoke must not run inside the WinClient product composition.");
        }

        var asAnswerer = ReadWebRtcSessionAsAnswerer(WebRtcProductControlTransportAdapterMode);
        var handshakeTimeout = ReadWebRtcProductHandshakeTimeout();
        var cryptoProvider = CreateWebRtcProductPqcHandshakeCryptoProvider(asAnswerer);
        try
        {
            var handshakeDriver = new WebRtcProductHandshakeDriver(
                cryptoProvider,
                secureSessionStore,
                new WebRtcProductHandshakeDriverOptions(handshakeTimeout));
            var secureSessionConsumer = new WebRtcProductSecureSessionRuntimeConsumer(
                new WebRtcProductHandshakeSessionEstablisher(handshakeDriver, cryptoProvider),
                secureSessionStore,
                new IWebRtcProductControlRuntimeConsumer[] { authenticatedRouteBindingStore });
            return new IWebRtcProductControlRuntimeConsumer[] { secureSessionConsumer };
        }
        catch
        {
            cryptoProvider.Dispose();
            throw;
        }
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

    private static IWindowsTransportAdapterClient CreateMsQuicTransportAdapterFromEnvironment()
    {
        var role = Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_MSQUIC_ROLE");
        if (string.IsNullOrWhiteSpace(role) || string.Equals(role, "dial", StringComparison.OrdinalIgnoreCase))
        {
            return new WindowsNativeMsQuicTransportAdapterClient(
                new WindowsNativeMsQuicTransportAdapterOptions(
                    // Optional, not required: the dial target normally comes from the DNS-SD control
                    // route discovery resolved for the selected peer. Setting this variable pins the
                    // target instead, which is how the harness dials a peer it never discovered.
                    Optional("SKYBRIDGE_WINDOWS_MSQUIC_PEER_ENDPOINT"),
                    ReadTimestampWindowMs()));
        }

        if (string.Equals(role, "listen", StringComparison.OrdinalIgnoreCase))
        {
            return new WindowsNativeMsQuicListenerTransportAdapterClient(
                new WindowsNativeMsQuicListenerTransportAdapterOptions(
                    Required("SKYBRIDGE_WINDOWS_MSQUIC_LISTEN_ENDPOINT", MsQuicTransportAdapterMode),
                    ReadTimestampWindowMs(),
                    ReadMsQuicAcceptTimeoutMs()));
        }

        throw new InvalidOperationException("SKYBRIDGE_WINDOWS_MSQUIC_ROLE must be dial or listen when SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER=msquic.");
    }

    private static WebRtcHelperLaunchOptions CreateWebRtcHelperLaunchOptions(string mode)
    {
        return new WebRtcHelperLaunchOptions(
            ReadWebRtcHelperPath(),
            ReadWebRtcSignalingDirectory(),
            proofFileName: Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_PROOF_FILE"),
            offerFileName: Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_OFFER_FILE"),
            answerFileName: Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_ANSWER_FILE"),
            iceServersCsv: ReadWebRtcIceServersCsv(),
            bindAddress: Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_BIND_ADDRESS"),
            includeAllIceInterfaceAddresses: IsEnabled("SKYBRIDGE_WINDOWS_WEBRTC_ICE_INCLUDE_ALL_INTERFACES"),
            launchTimeout: ReadWebRtcLaunchTimeout(mode));
    }

    private static string ReadWebRtcHelperPath()
    {
        var raw = Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_HELPER_PATH");
        if (!string.IsNullOrWhiteSpace(raw))
        {
            return raw;
        }

        return Path.Combine(
            AppContext.BaseDirectory,
            OperatingSystem.IsWindows() ? "Skybridge.WebRtcHelper.exe" : "Skybridge.WebRtcHelper");
    }

    private static string ReadWebRtcSignalingDirectory()
    {
        var raw = Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_SIGNALING_DIR");
        return string.IsNullOrWhiteSpace(raw)
            ? Path.Combine(AppContext.BaseDirectory, "webrtc-signaling")
            : raw;
    }

    private static string? ReadWebRtcIceServersCsv()
    {
        var raw = Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_ICE_SERVERS");
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        if (raw.Contains("|", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("SKYBRIDGE_WINDOWS_WEBRTC_ICE_SERVERS must not include TURN credentials; use LAN/STUN-only until a credential file/channel is wired.");
        }

        return raw.Trim();
    }

    private static TimeSpan ReadWebRtcLaunchTimeout(string mode)
    {
        var raw = Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_LAUNCH_TIMEOUT_SECONDS");
        if (string.IsNullOrWhiteSpace(raw))
        {
            return TimeSpan.FromSeconds(200);
        }

        if (int.TryParse(raw, out var seconds) && seconds > 0)
        {
            return TimeSpan.FromSeconds(seconds);
        }

        throw new InvalidOperationException($"SKYBRIDGE_WINDOWS_WEBRTC_LAUNCH_TIMEOUT_SECONDS must be a positive integer when SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER={mode}.");
    }

    private static TimeSpan ReadWebRtcProductSmokeTimeout()
    {
        var raw = Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_PRODUCT_SMOKE_TIMEOUT_SECONDS");
        if (string.IsNullOrWhiteSpace(raw))
        {
            return TimeSpan.FromSeconds(30);
        }

        if (int.TryParse(raw, out var seconds) && seconds > 0)
        {
            return TimeSpan.FromSeconds(seconds);
        }

        throw new InvalidOperationException("SKYBRIDGE_WINDOWS_WEBRTC_PRODUCT_SMOKE_TIMEOUT_SECONDS must be a positive integer.");
    }

    private static TimeSpan ReadWebRtcProductHandshakeTimeout()
    {
        var raw = Environment.GetEnvironmentVariable(WebRtcProductHandshakeTimeoutVariable);
        if (string.IsNullOrWhiteSpace(raw))
        {
            return TimeSpan.FromSeconds(30);
        }

        if (int.TryParse(raw, out var seconds) && seconds > 0)
        {
            return TimeSpan.FromSeconds(seconds);
        }

        throw new InvalidOperationException($"{WebRtcProductHandshakeTimeoutVariable} must be a positive integer.");
    }

    private static bool ReadWebRtcSessionAsAnswerer(string mode)
    {
        var raw = Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_SESSION_ROLE");
        if (string.IsNullOrWhiteSpace(raw) || string.Equals(raw, "offer", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (string.Equals(raw, "answer", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        throw new InvalidOperationException($"SKYBRIDGE_WINDOWS_WEBRTC_SESSION_ROLE must be offer or answer when SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER={mode}.");
    }

    private static int ReadWebRtcSessionPreferredIpcPort()
    {
        var raw = Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_SESSION_IPC_PORT");
        if (string.IsNullOrWhiteSpace(raw))
        {
            return 0;
        }

        if (int.TryParse(raw, out var value) && value is >= 0 and <= 65535)
        {
            return value;
        }

        throw new InvalidOperationException("SKYBRIDGE_WINDOWS_WEBRTC_SESSION_IPC_PORT must be 0 for an OS-assigned port, or a TCP port in the range 1-65535.");
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

    /// <summary>
    /// Reads a variable that has a non-environment source of truth. Returns <c>null</c> when it is
    /// unset or blank so the caller can fall back to that source; contrast with <see cref="Required"/>,
    /// which is for inputs the environment is the only supplier of.
    /// </summary>
    private static string? Optional(string variable)
    {
        var value = Environment.GetEnvironmentVariable(variable);
        return string.IsNullOrWhiteSpace(value) ? null : value;
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

    private static WebRtcProductPqcHandshakeCryptoProvider CreateWebRtcProductPqcHandshakeCryptoProvider(
        bool asAnswerer)
    {
        var privateKeyBytes = RequiredBase64FileBytes(
            WebRtcProductMldsa65PrivateKeyBase64PathVariable,
            WebRtcProductControlTransportAdapterMode,
            "ML-DSA-65 private key");
        var peerMlKem768PublicKey = asAnswerer
            ? Array.Empty<byte>()
            : RequiredBase64FileBytes(
                WebRtcProductPeerMlKem768PublicKeyBase64PathVariable,
                WebRtcProductControlTransportAdapterMode,
                "peer ML-KEM-768 public key");
        var localMlKem768DecapsulationKey = asAnswerer
            ? RequiredBase64FileBytes(
                WebRtcProductLocalMlKem768DecapsulationKeyBase64PathVariable,
                WebRtcProductControlTransportAdapterMode,
                "local ML-KEM-768 decapsulation key")
            : Array.Empty<byte>();
        var localMlKem768PublicKey = asAnswerer
            ? RequiredBase64FileBytes(
                WebRtcProductLocalMlKem768PublicKeyBase64PathVariable,
                WebRtcProductControlTransportAdapterMode,
                "local ML-KEM-768 public key")
            : Array.Empty<byte>();

        try
        {
            ValidateMldsa65PrivateKeyLength(privateKeyBytes, WebRtcProductMldsa65PrivateKeyBase64PathVariable);
            if (!asAnswerer)
            {
                ValidateMlKem768PublicKeyLength(
                    peerMlKem768PublicKey,
                    WebRtcProductPeerMlKem768PublicKeyBase64PathVariable);
            }
            else
            {
                ValidateMlKem768DecapsulationKeyLength(
                    localMlKem768DecapsulationKey,
                    WebRtcProductLocalMlKem768DecapsulationKeyBase64PathVariable);
                ValidateMlKem768PublicKeyLength(
                    localMlKem768PublicKey,
                    WebRtcProductLocalMlKem768PublicKeyBase64PathVariable);
                VerifyMlKem768KeyPair(localMlKem768PublicKey, localMlKem768DecapsulationKey);
            }

            return new WebRtcProductPqcHandshakeCryptoProvider(
                new WebRtcProductPqcHandshakeCryptoProviderOptions(
                    privateKeyBytes,
                    peerMlKem768PublicKey,
                    localMlKem768DecapsulationKey));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(privateKeyBytes);
            if (localMlKem768DecapsulationKey.Length > 0)
            {
                CryptographicOperations.ZeroMemory(localMlKem768DecapsulationKey);
            }

            if (localMlKem768PublicKey.Length > 0)
            {
                CryptographicOperations.ZeroMemory(localMlKem768PublicKey);
            }
        }
    }

    private static byte[] RequiredBase64FileBytes(string variable, string mode, string label)
    {
        var path = Required(variable, mode);
        var encoded = File.ReadAllBytes(Path.GetFullPath(path));
        try
        {
            var encodedPayload = TrimAsciiWhitespace(encoded);
            if (encodedPayload.IsEmpty)
            {
                throw new InvalidOperationException($"{variable} must point to a non-empty base64-encoded {label} file.");
            }

            var decoded = new byte[checked((encodedPayload.Length / 4 * 3) + 3)];
            var status = Base64.DecodeFromUtf8(
                encodedPayload,
                decoded,
                out var consumed,
                out var written,
                isFinalBlock: true);
            if (status != OperationStatus.Done || consumed != encodedPayload.Length)
            {
                CryptographicOperations.ZeroMemory(decoded);
                throw new InvalidOperationException($"{variable} must point to a valid base64-encoded {label} file.");
            }

            var exact = new byte[written];
            Buffer.BlockCopy(decoded, 0, exact, 0, written);
            CryptographicOperations.ZeroMemory(decoded);
            return exact;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(encoded);
        }
    }

    private static ReadOnlySpan<byte> TrimAsciiWhitespace(byte[] value)
    {
        var start = 0;
        var end = value.Length;
        while (start < end && IsAsciiWhitespace(value[start]))
        {
            start++;
        }

        while (end > start && IsAsciiWhitespace(value[end - 1]))
        {
            end--;
        }

        return value.AsSpan(start, end - start);
    }

    private static bool IsAsciiWhitespace(byte value) =>
        value is (byte)' ' or (byte)'\t' or (byte)'\r' or (byte)'\n';

    private static void ValidateMldsa65PrivateKeyLength(byte[] value, string variable)
    {
        if (value.Length == MLDsaAlgorithm.MLDsa65.PrivateSeedSizeInBytes ||
            value.Length == MLDsaAlgorithm.MLDsa65.PrivateKeySizeInBytes)
        {
            return;
        }

        throw new InvalidOperationException(
            $"{variable} must decode to a {MLDsaAlgorithm.MLDsa65.PrivateSeedSizeInBytes}-byte ML-DSA-65 private seed " +
            $"or {MLDsaAlgorithm.MLDsa65.PrivateKeySizeInBytes}-byte ML-DSA-65 private key.");
    }

    private static void ValidateMlKem768PublicKeyLength(byte[] value, string variable)
    {
        if (value.Length == MLKemAlgorithm.MLKem768.EncapsulationKeySizeInBytes)
        {
            return;
        }

        throw new InvalidOperationException(
            $"{variable} must decode to a {MLKemAlgorithm.MLKem768.EncapsulationKeySizeInBytes}-byte ML-KEM-768 public key.");
    }

    private static void ValidateMlKem768DecapsulationKeyLength(byte[] value, string variable)
    {
        if (value.Length == MLKemAlgorithm.MLKem768.DecapsulationKeySizeInBytes)
        {
            return;
        }

        throw new InvalidOperationException(
            $"{variable} must decode to a {MLKemAlgorithm.MLKem768.DecapsulationKeySizeInBytes}-byte ML-KEM-768 decapsulation key.");
    }

    private static void VerifyMlKem768KeyPair(
        ReadOnlySpan<byte> encapsulationKey,
        ReadOnlySpan<byte> decapsulationKey)
    {
        if (!MLKem.IsSupported)
        {
            throw new PlatformNotSupportedException(
                "WebRTC product-control answerer secure session requires .NET ML-KEM support.");
        }

        byte[]? ciphertext = null;
        byte[]? sharedSecretFromEncapsulation = null;
        byte[]? sharedSecretFromDecapsulation = null;
        try
        {
            using var publicKem = MLKem.ImportEncapsulationKey(MLKemAlgorithm.MLKem768, encapsulationKey);
            using var privateKem = MLKem.ImportDecapsulationKey(MLKemAlgorithm.MLKem768, decapsulationKey);
            publicKem.Encapsulate(out ciphertext, out sharedSecretFromEncapsulation);
            sharedSecretFromDecapsulation = privateKem.Decapsulate(ciphertext);
            if (!CryptographicOperations.FixedTimeEquals(
                    sharedSecretFromEncapsulation,
                    sharedSecretFromDecapsulation))
            {
                throw new InvalidOperationException(
                    "WebRTC product-control local ML-KEM-768 public key does not match the decapsulation key.");
            }
        }
        finally
        {
            if (ciphertext is not null)
            {
                CryptographicOperations.ZeroMemory(ciphertext);
            }

            if (sharedSecretFromEncapsulation is not null)
            {
                CryptographicOperations.ZeroMemory(sharedSecretFromEncapsulation);
            }

            if (sharedSecretFromDecapsulation is not null)
            {
                CryptographicOperations.ZeroMemory(sharedSecretFromDecapsulation);
            }
        }
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
