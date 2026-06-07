using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

/// <summary>
/// Bridges the WinUI client with the Rust core via FFI.
/// </summary>
public sealed class CoreBridge
{
    public Task<bool> InitializeAsync()
    {
        return Task.Run(() =>
        {
            try
            {
                var handle = NativeMethods.EngineNew();
                if (handle == nint.Zero)
                {
                    return false;
                }

                NativeMethods.EngineFree(handle);
                return true;
            }
            catch (DllNotFoundException)
            {
                return false;
            }
        });
    }

    public Task<TransportSelection> SelectTransportAsync(
        PeerCapabilities local,
        PeerCapabilities remote,
        NetworkPath path)
    {
        return Task.Run(() =>
        {
            var result = NativeMethods.SelectTransport(
                local.ToNative(),
                remote.ToNative(),
                path.ToNative(),
                out var selection);

            if (result != SkybridgeErrorCode.Ok)
            {
                throw new InvalidOperationException($"Transport selection failed: {result}");
            }

            return TransportSelection.FromNative(selection);
        });
    }

    public Task<ChannelMapping> MapChannelAsync(CoreTransportKind transport, CoreChannelKind channel)
    {
        return Task.Run(() =>
        {
            var result = NativeMethods.MapChannel(transport, channel, out var mapping);
            if (result != SkybridgeErrorCode.Ok)
            {
                throw new InvalidOperationException($"Channel mapping failed: {result}");
            }

            return ChannelMapping.FromNative(mapping);
        });
    }

    public Task<ConnectionPlan> PlanConnectionAsync(
        PeerCapabilities local,
        PeerCapabilities remote,
        NetworkPath path,
        CryptoProviderCapabilities localCrypto,
        ushort[] remoteSuiteWireIds,
        CryptoSuitePolicy suitePolicy,
        TrafficPaddingPlan trafficPadding)
    {
        return Task.Run(() =>
        {
            remoteSuiteWireIds ??= Array.Empty<ushort>();
            var result = NativeMethods.PlanConnection(
                local.ToNative(),
                remote.ToNative(),
                path.ToNative(),
                localCrypto.ToNative(),
                remoteSuiteWireIds,
                (nuint)remoteSuiteWireIds.Length,
                suitePolicy.ToNative(),
                trafficPadding.ToNative(),
                out var plan);

            if (result != SkybridgeErrorCode.Ok)
            {
                throw new InvalidOperationException($"Connection planning failed: {result}");
            }

            return ConnectionPlan.FromNative(plan);
        });
    }

    private static class NativeMethods
    {
        [DllImport("skybridge_core", EntryPoint = "skybridge_engine_new")]
        public static extern nint EngineNew();

        [DllImport("skybridge_core", EntryPoint = "skybridge_engine_free")]
        public static extern void EngineFree(nint handle);

        [DllImport("skybridge_core", EntryPoint = "skybridge_select_transport")]
        public static extern SkybridgeErrorCode SelectTransport(
            NativePeerCapabilities local,
            NativePeerCapabilities remote,
            NativeNetworkPath path,
            out NativeTransportSelection selection);

        [DllImport("skybridge_core", EntryPoint = "skybridge_map_channel")]
        public static extern SkybridgeErrorCode MapChannel(
            CoreTransportKind transport,
            CoreChannelKind channel,
            out NativeChannelMapping mapping);

        [DllImport("skybridge_core", EntryPoint = "skybridge_plan_connection")]
        public static extern SkybridgeErrorCode PlanConnection(
            NativePeerCapabilities local,
            NativePeerCapabilities remote,
            NativeNetworkPath path,
            NativeCryptoProviderCapabilities localCrypto,
            [In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 5)] ushort[] remoteSuiteWireIds,
            nuint remoteSuiteWireIdsLen,
            NativeCryptoSuitePolicy suitePolicy,
            NativeTrafficPaddingPlan trafficPadding,
            out NativeConnectionPlan plan);
    }
}

public enum CorePeerPlatform
{
    Unknown = 0,
    Apple = 1,
    Windows = 2
}

public enum CoreTransportKind
{
    Unsupported = 0,
    AppleNative = 1,
    WindowsNativeMsQuic = 2,
    SkyBridgeIceMsQuic = 3,
    WebRtcDataChannel = 4,
    Relay = 5,
    TcpFallback = 6
}

public enum CoreTransportAuditCode
{
    UnsupportedNoCompatibleTransport = 0,
    AppleNativeDefault = 1,
    WindowsNativeMsQuicSameLan = 2,
    WindowsSkyBridgeIceMsQuic = 3,
    WebRtcInterop = 4,
    TcpFallbackSameLan = 5,
    RelayFallback = 6
}

public enum CoreChannelKind
{
    Control = 1,
    File = 2,
    Clipboard = 3,
    Telemetry = 4,
    Realtime = 5
}

public enum CoreReliabilityKind
{
    ReliableOrdered = 1,
    ReliableUnordered = 2,
    PartialReliable = 3,
    Unreliable = 4
}

public enum CoreAdapterBindingKind
{
    AppleStream = 1,
    AppleDatagram = 2,
    MsQuicStream = 3,
    MsQuicDatagram = 4,
    WebRtcDataChannel = 5,
    RelayStream = 6,
    TcpStream = 7
}

public enum CoreCryptoSuiteKind
{
    Unknown = 0,
    XWingHybrid = 1,
    MlKem768MlDsa65 = 2,
    X25519Ed25519 = 3,
    P256Ecdsa = 4
}

public enum CoreCryptoSuiteAuditCode
{
    None = 0,
    HybridPqcPreferred = 1,
    PurePqcPreferred = 2,
    ClassicPolicyFallback = 3,
    LegacyPolicyFallback = 4
}

public sealed record PeerCapabilities(
    CorePeerPlatform Platform,
    bool SupportsAppleNative,
    bool SupportsMsQuic,
    bool SupportsSkyBridgeIceMsQuic,
    bool SupportsWebRtcDataChannel,
    bool SupportsTcpFallback,
    bool SupportsRelay)
{
    public static PeerCapabilities Apple() =>
        new(CorePeerPlatform.Apple, true, false, false, true, true, true);

    public static PeerCapabilities Windows() =>
        new(CorePeerPlatform.Windows, false, true, false, true, true, true);

    internal NativePeerCapabilities ToNative() =>
        new()
        {
            Platform = Platform,
            SupportsAppleNative = ToFlag(SupportsAppleNative),
            SupportsMsQuic = ToFlag(SupportsMsQuic),
            SupportsSkyBridgeIceMsQuic = ToFlag(SupportsSkyBridgeIceMsQuic),
            SupportsWebRtcDataChannel = ToFlag(SupportsWebRtcDataChannel),
            SupportsTcpFallback = ToFlag(SupportsTcpFallback),
            SupportsRelay = ToFlag(SupportsRelay)
        };

    private static byte ToFlag(bool value) => value ? (byte)1 : (byte)0;
}

public sealed record NetworkPath(bool SameLan, bool CrossNat)
{
    public static NetworkPath SameLanPath() => new(true, false);

    public static NetworkPath CrossNatPath() => new(false, true);

    internal NativeNetworkPath ToNative() =>
        new()
        {
            SameLan = SameLan ? (byte)1 : (byte)0,
            CrossNat = CrossNat ? (byte)1 : (byte)0
        };
}

public sealed record TransportSelection(
    CoreTransportKind Kind,
    CoreTransportAuditCode AuditCode,
    byte Priority,
    bool RelayRequired,
    bool RelayAllowed)
{
    internal static TransportSelection FromNative(NativeTransportSelection selection) =>
        new(
            selection.Kind,
            selection.AuditCode,
            selection.Priority,
            selection.RelayRequired != 0,
            selection.RelayAllowed != 0);
}

public sealed record ChannelMapping(
    CoreChannelKind Channel,
    CoreReliabilityKind Reliability,
    ushort MaxRetransmits,
    CoreAdapterBindingKind BindingKind,
    bool HeadOfLineIsolated)
{
    internal static ChannelMapping FromNative(NativeChannelMapping mapping) =>
        new(
            mapping.Channel,
            mapping.Reliability,
            mapping.MaxRetransmits,
            mapping.BindingKind,
            mapping.HeadOfLineIsolated != 0);
}

public sealed record CryptoProviderCapabilities(
    bool SupportsXWingHybrid,
    bool SupportsMlKem768MlDsa65,
    bool SupportsX25519Ed25519,
    bool SupportsP256Ecdsa)
{
    public static CryptoProviderCapabilities ResearchAll() => new(true, true, true, true);

    public static CryptoProviderCapabilities CurrentP256() => new(false, false, false, true);

    internal NativeCryptoProviderCapabilities ToNative() =>
        new()
        {
            SupportsXWingHybrid = ToFlag(SupportsXWingHybrid),
            SupportsMlKem768MlDsa65 = ToFlag(SupportsMlKem768MlDsa65),
            SupportsX25519Ed25519 = ToFlag(SupportsX25519Ed25519),
            SupportsP256Ecdsa = ToFlag(SupportsP256Ecdsa)
        };

    private static byte ToFlag(bool value) => value ? (byte)1 : (byte)0;
}

public sealed record CryptoSuitePolicy(
    bool AllowClassicFallback,
    bool AllowLegacyP256,
    bool TimeoutObserved)
{
    public static CryptoSuitePolicy StrictPqc() => new(false, false, false);

    public static CryptoSuitePolicy Compatibility() => new(true, false, false);

    internal NativeCryptoSuitePolicy ToNative() =>
        new()
        {
            AllowClassicFallback = AllowClassicFallback ? (byte)1 : (byte)0,
            AllowLegacyP256 = AllowLegacyP256 ? (byte)1 : (byte)0,
            TimeoutObserved = TimeoutObserved ? (byte)1 : (byte)0
        };
}

public sealed record TrafficPaddingPlan(bool Sbp2Enabled, nuint FixedPayloadLen)
{
    public static TrafficPaddingPlan Disabled() => new(false, 0);

    public static TrafficPaddingPlan Sbp2Fixed(nuint fixedPayloadLen) => new(true, fixedPayloadLen);

    internal NativeTrafficPaddingPlan ToNative() =>
        new()
        {
            Sbp2Enabled = Sbp2Enabled ? (byte)1 : (byte)0,
            FixedPayloadLen = FixedPayloadLen
        };
}

public sealed record OfferedCryptoSuite(CoreCryptoSuiteKind Suite, ushort WireId);

public sealed record ConnectionPlan(
    TransportSelection Transport,
    CoreCryptoSuiteKind SelectedSuite,
    ushort SelectedSuiteWireId,
    CoreCryptoSuiteAuditCode SuiteAudit,
    IReadOnlyList<OfferedCryptoSuite> OfferedSuites,
    IReadOnlyList<ChannelMapping> ChannelMappings,
    bool Sbp2Enabled,
    nuint Sbp2FixedPayloadLen,
    nuint FrameHeaderLen)
{
    internal static ConnectionPlan FromNative(NativeConnectionPlan plan)
    {
        var nativeOfferedSuites = plan.OfferedSuites ?? Array.Empty<CoreCryptoSuiteKind>();
        var nativeOfferedWireIds = plan.OfferedSuiteWireIds ?? Array.Empty<ushort>();
        var offeredCount = ClampCount(plan.OfferedSuiteCount, 4);
        offeredCount = Math.Min(offeredCount, Math.Min(nativeOfferedSuites.Length, nativeOfferedWireIds.Length));
        var offered = new List<OfferedCryptoSuite>(offeredCount);
        for (var index = 0; index < offeredCount; index++)
        {
            offered.Add(new OfferedCryptoSuite(
                nativeOfferedSuites[index],
                nativeOfferedWireIds[index]));
        }

        var nativeChannelMappings = plan.ChannelMappings ?? Array.Empty<NativeChannelMapping>();
        var channelCount = ClampCount(plan.ChannelMappingCount, 5);
        channelCount = Math.Min(channelCount, nativeChannelMappings.Length);
        var channels = new List<ChannelMapping>(channelCount);
        for (var index = 0; index < channelCount; index++)
        {
            channels.Add(ChannelMapping.FromNative(nativeChannelMappings[index]));
        }

        return new ConnectionPlan(
            TransportSelection.FromNative(plan.Transport),
            plan.SelectedSuite,
            plan.SelectedSuiteWireId,
            plan.SuiteAudit,
            offered,
            channels,
            plan.Sbp2Enabled != 0,
            plan.Sbp2FixedPayloadLen,
            plan.FrameHeaderLen);
    }

    private static int ClampCount(nuint count, int max) => count > (nuint)max ? max : (int)count;
}

internal enum SkybridgeErrorCode
{
    Ok = 0,
    NullHandle = 1,
    InvalidState = 2,
    MissingConfig = 3,
    RateLimited = 4,
    AlreadyInitialized = 5,
    SessionError = 100,
    StreamError = 101,
    CryptoError = 102,
    InvalidInput = 200,
    UnsupportedTransport = 201,
    NoMutualCryptoSuite = 202,
    UnknownCryptoSuite = 203,
    TimeoutCannotDowngrade = 204
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativePeerCapabilities
{
    public CorePeerPlatform Platform;
    public byte SupportsAppleNative;
    public byte SupportsMsQuic;
    public byte SupportsSkyBridgeIceMsQuic;
    public byte SupportsWebRtcDataChannel;
    public byte SupportsTcpFallback;
    public byte SupportsRelay;
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativeNetworkPath
{
    public byte SameLan;
    public byte CrossNat;
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativeTransportSelection
{
    public CoreTransportKind Kind;
    public CoreTransportAuditCode AuditCode;
    public byte Priority;
    public byte RelayRequired;
    public byte RelayAllowed;
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativeChannelMapping
{
    public CoreChannelKind Channel;
    public CoreReliabilityKind Reliability;
    public ushort MaxRetransmits;
    public CoreAdapterBindingKind BindingKind;
    public byte HeadOfLineIsolated;
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativeCryptoProviderCapabilities
{
    public byte SupportsXWingHybrid;
    public byte SupportsMlKem768MlDsa65;
    public byte SupportsX25519Ed25519;
    public byte SupportsP256Ecdsa;
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativeCryptoSuitePolicy
{
    public byte AllowClassicFallback;
    public byte AllowLegacyP256;
    public byte TimeoutObserved;
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativeTrafficPaddingPlan
{
    public byte Sbp2Enabled;
    public nuint FixedPayloadLen;
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativeConnectionPlan
{
    public NativeTransportSelection Transport;
    public CoreCryptoSuiteKind SelectedSuite;
    public ushort SelectedSuiteWireId;
    public CoreCryptoSuiteAuditCode SuiteAudit;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4)]
    public CoreCryptoSuiteKind[] OfferedSuites;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4)]
    public ushort[] OfferedSuiteWireIds;

    public nuint OfferedSuiteCount;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 5)]
    public NativeChannelMapping[] ChannelMappings;

    public nuint ChannelMappingCount;
    public byte Sbp2Enabled;
    public nuint Sbp2FixedPayloadLen;
    public nuint FrameHeaderLen;
}
