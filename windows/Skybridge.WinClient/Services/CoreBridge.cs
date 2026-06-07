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
    InvalidInput = 200
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
