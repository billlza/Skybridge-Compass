using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

/// <summary>
/// Bridges the WinUI client with the Rust core via FFI.
/// </summary>
public sealed class CoreBridge
{
    private const int FrameHeaderLen = 20;
    private const int Sbp2HeaderLen = 8;

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

    public Task<byte[]> ComputeTransportBindingDigestAsync(TransportBindingMaterial material)
    {
        ArgumentNullException.ThrowIfNull(material);
        ArgumentNullException.ThrowIfNull(material.LocalEndpoint);
        ArgumentNullException.ThrowIfNull(material.RemoteEndpoint);
        ArgumentNullException.ThrowIfNull(material.SelectedCandidatePair);
        ArgumentNullException.ThrowIfNull(material.TransportSecretFingerprint);
        ArgumentNullException.ThrowIfNull(material.CapabilityDigest);

        var localEndpointBytes = Encoding.UTF8.GetBytes(material.LocalEndpoint);
        var remoteEndpointBytes = Encoding.UTF8.GetBytes(material.RemoteEndpoint);
        var selectedCandidatePairBytes = Encoding.UTF8.GetBytes(material.SelectedCandidatePair);
        var relayIdBytes = string.IsNullOrEmpty(material.RelayId)
            ? Array.Empty<byte>()
            : Encoding.UTF8.GetBytes(material.RelayId);
        var transportSecretFingerprint = (byte[])material.TransportSecretFingerprint.Clone();
        var capabilityDigest = (byte[])material.CapabilityDigest.Clone();

        return Task.Run(() =>
        {
            var handles = new List<GCHandle>();

            nint Pin(byte[] bytes)
            {
                if (bytes.Length == 0)
                {
                    return nint.Zero;
                }

                var handle = GCHandle.Alloc(bytes, GCHandleType.Pinned);
                handles.Add(handle);
                return handle.AddrOfPinnedObject();
            }

            try
            {
                var result = NativeMethods.TransportBindingDigest(
                    material.Transport,
                    Pin(localEndpointBytes),
                    (nuint)localEndpointBytes.Length,
                    Pin(remoteEndpointBytes),
                    (nuint)remoteEndpointBytes.Length,
                    Pin(selectedCandidatePairBytes),
                    (nuint)selectedCandidatePairBytes.Length,
                    Pin(transportSecretFingerprint),
                    (nuint)transportSecretFingerprint.Length,
                    Pin(relayIdBytes),
                    (nuint)relayIdBytes.Length,
                    material.TimestampWindowMs,
                    Pin(capabilityDigest),
                    (nuint)capabilityDigest.Length,
                    out var nativeDigest);

                if (result != SkybridgeErrorCode.Ok)
                {
                    throw new InvalidOperationException($"Transport binding digest failed: {result}");
                }

                if (nativeDigest.Digest is null || nativeDigest.Digest.Length != 32)
                {
                    throw new InvalidOperationException("skybridge_core returned an invalid transport binding digest.");
                }

                return nativeDigest.Digest;
            }
            finally
            {
                foreach (var handle in handles)
                {
                    if (handle.IsAllocated)
                    {
                        handle.Free();
                    }
                }
            }
        });
    }

    public Task<VerifiedWebRtcSessionLaunch> VerifyWebRtcSessionLaunchAsync(
        string proofJson,
        string expectedDeviceId,
        string expectedFingerprint,
        CoreTransportKind transport,
        CoreTransportAuditCode transportAudit,
        ulong maxAgeMs)
    {
        ArgumentNullException.ThrowIfNull(proofJson);
        ArgumentNullException.ThrowIfNull(expectedDeviceId);
        ArgumentNullException.ThrowIfNull(expectedFingerprint);
        if (maxAgeMs == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maxAgeMs), "WebRTC proof max age must be greater than zero.");
        }

        var proofJsonBytes = Encoding.UTF8.GetBytes(proofJson);
        var expectedDeviceIdBytes = Encoding.UTF8.GetBytes(expectedDeviceId);
        var expectedFingerprintBytes = Encoding.UTF8.GetBytes(expectedFingerprint);

        return Task.Run(() =>
        {
            var handles = new List<GCHandle>();

            nint Pin(byte[] bytes)
            {
                if (bytes.Length == 0)
                {
                    return nint.Zero;
                }

                var handle = GCHandle.Alloc(bytes, GCHandleType.Pinned);
                handles.Add(handle);
                return handle.AddrOfPinnedObject();
            }

            try
            {
                var result = NativeMethods.VerifyWebRtcSessionLaunch(
                    Pin(proofJsonBytes),
                    (nuint)proofJsonBytes.Length,
                    Pin(expectedDeviceIdBytes),
                    (nuint)expectedDeviceIdBytes.Length,
                    Pin(expectedFingerprintBytes),
                    (nuint)expectedFingerprintBytes.Length,
                    transport,
                    transportAudit,
                    maxAgeMs,
                    out var launch);

                if (result != SkybridgeErrorCode.Ok)
                {
                    throw new InvalidOperationException($"WebRTC session launch proof failed: {result}");
                }

                return VerifiedWebRtcSessionLaunch.FromNative(launch);
            }
            finally
            {
                foreach (var handle in handles)
                {
                    if (handle.IsAllocated)
                    {
                        handle.Free();
                    }
                }
            }
        });
    }

    public Task<SignalingLifecycleSnapshot> ProjectSignalingLifecycleAsync(
        SignalingLifecycleSnapshot current,
        SignalingLifecycleEvent lifecycleEvent)
    {
        ArgumentNullException.ThrowIfNull(current);
        ArgumentNullException.ThrowIfNull(lifecycleEvent);

        return Task.Run(() =>
        {
            var result = NativeMethods.ProjectSignalingLifecycleState(
                current.ToNative(),
                lifecycleEvent.ToNative(),
                out var projected);

            if (result != SkybridgeErrorCode.Ok)
            {
                throw new InvalidOperationException($"Signaling lifecycle projection failed: {result}");
            }

            return SignalingLifecycleSnapshot.FromNative(projected);
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

    public Task<FileTransferPlannerVerdict> PlanFileTransferReadinessAsync(
        IReadOnlyList<FileTransferRouteCandidate> routeCandidates,
        string? targetPeerId,
        ulong? requiredListenerGeneration,
        CoreFileTransferManifestMode manifestMode,
        IReadOnlyList<FileTransferManifestFile> manifestFiles,
        ulong chunkSize,
        IReadOnlyList<ChannelMapping> channelMappings)
    {
        ArgumentNullException.ThrowIfNull(routeCandidates);
        ArgumentNullException.ThrowIfNull(manifestFiles);
        ArgumentNullException.ThrowIfNull(channelMappings);

        return Task.Run(() =>
        {
            var nativeRouteCandidates = new NativeFileTransferRouteCandidate[routeCandidates.Count];
            for (var index = 0; index < routeCandidates.Count; index++)
            {
                nativeRouteCandidates[index] = routeCandidates[index].ToNative();
            }

            var nativeManifestFiles = new NativeFileTransferManifestFile[manifestFiles.Count];
            for (var index = 0; index < manifestFiles.Count; index++)
            {
                nativeManifestFiles[index] = manifestFiles[index].ToNative();
            }

            var nativeChannelMappings = new NativeChannelMapping[channelMappings.Count];
            for (var index = 0; index < channelMappings.Count; index++)
            {
                nativeChannelMappings[index] = channelMappings[index].ToNative();
            }

            var targetPeerIdBytes = Encoding.UTF8.GetBytes(targetPeerId ?? "");
            var targetPeerIdHandle = targetPeerIdBytes.Length == 0
                ? default
                : GCHandle.Alloc(targetPeerIdBytes, GCHandleType.Pinned);

            try
            {
                var result = NativeMethods.PlanFileTransferReadiness(
                    nativeRouteCandidates,
                    (nuint)nativeRouteCandidates.Length,
                    targetPeerIdBytes.Length == 0 ? nint.Zero : targetPeerIdHandle.AddrOfPinnedObject(),
                    (nuint)targetPeerIdBytes.Length,
                    requiredListenerGeneration.GetValueOrDefault(),
                    requiredListenerGeneration.HasValue ? (byte)1 : (byte)0,
                    manifestMode,
                    nativeManifestFiles,
                    (nuint)nativeManifestFiles.Length,
                    chunkSize,
                    nativeChannelMappings,
                    (nuint)nativeChannelMappings.Length,
                    out var verdict);

                if (result != SkybridgeErrorCode.Ok)
                {
                    throw new InvalidOperationException($"File transfer readiness planning failed: {result}");
                }

                return FileTransferPlannerVerdict.FromNative(verdict);
            }
            finally
            {
                if (targetPeerIdHandle.IsAllocated)
                {
                    targetPeerIdHandle.Free();
                }
            }
        });
    }

    public Task<byte[]> EncodeFrameAsync(
        CoreChannelKind channel,
        ulong sequence,
        byte[] payload,
        bool endOfMessage = true)
    {
        ArgumentNullException.ThrowIfNull(payload);

        return Task.Run(() =>
        {
            var output = new byte[checked(FrameHeaderLen + payload.Length)];
            var payloadHandle = payload.Length == 0
                ? default
                : GCHandle.Alloc(payload, GCHandleType.Pinned);
            var outputHandle = GCHandle.Alloc(output, GCHandleType.Pinned);

            try
            {
                var result = NativeMethods.EncodeFrame(
                    channel,
                    sequence,
                    payload.Length == 0 ? nint.Zero : payloadHandle.AddrOfPinnedObject(),
                    (nuint)payload.Length,
                    endOfMessage ? (byte)1 : (byte)0,
                    outputHandle.AddrOfPinnedObject(),
                    (nuint)output.Length,
                    out var writtenLen);

                if (result != SkybridgeErrorCode.Ok)
                {
                    throw new InvalidOperationException($"Frame encode failed: {result}");
                }

                return SliceOutput(output, writtenLen);
            }
            finally
            {
                if (payloadHandle.IsAllocated)
                {
                    payloadHandle.Free();
                }

                outputHandle.Free();
            }
        });
    }

    public Task<byte[]> EncodeSbp2FrameAsync(
        CoreChannelKind channel,
        ulong sequence,
        byte[] payload,
        nuint paddedPayloadLen)
    {
        ArgumentNullException.ThrowIfNull(payload);
        if (paddedPayloadLen > (nuint)(int.MaxValue - FrameHeaderLen - Sbp2HeaderLen))
        {
            throw new ArgumentOutOfRangeException(nameof(paddedPayloadLen), "Padded payload is too large for this client to marshal.");
        }

        return Task.Run(() =>
        {
            var output = new byte[FrameHeaderLen + Sbp2HeaderLen + (int)paddedPayloadLen];
            var payloadHandle = payload.Length == 0
                ? default
                : GCHandle.Alloc(payload, GCHandleType.Pinned);
            var outputHandle = GCHandle.Alloc(output, GCHandleType.Pinned);

            try
            {
                var result = NativeMethods.EncodeSbp2Frame(
                    channel,
                    sequence,
                    payload.Length == 0 ? nint.Zero : payloadHandle.AddrOfPinnedObject(),
                    (nuint)payload.Length,
                    paddedPayloadLen,
                    outputHandle.AddrOfPinnedObject(),
                    (nuint)output.Length,
                    out var writtenLen);

                if (result != SkybridgeErrorCode.Ok)
                {
                    throw new InvalidOperationException($"SBP2 frame encode failed: {result}");
                }

                return SliceOutput(output, writtenLen);
            }
            finally
            {
                if (payloadHandle.IsAllocated)
                {
                    payloadHandle.Free();
                }

                outputHandle.Free();
            }
        });
    }

    public Task<FrameMetadata> DecodeFrameMetadataAsync(byte[] encodedFrame)
    {
        ArgumentNullException.ThrowIfNull(encodedFrame);

        return Task.Run(() =>
        {
            var frameHandle = encodedFrame.Length == 0
                ? default
                : GCHandle.Alloc(encodedFrame, GCHandleType.Pinned);

            try
            {
                var result = NativeMethods.DecodeFrameMetadata(
                    encodedFrame.Length == 0 ? nint.Zero : frameHandle.AddrOfPinnedObject(),
                    (nuint)encodedFrame.Length,
                    out var metadata);

                if (result != SkybridgeErrorCode.Ok)
                {
                    throw new InvalidOperationException($"Frame metadata decode failed: {result}");
                }

                return FrameMetadata.FromNative(metadata);
            }
            finally
            {
                if (frameHandle.IsAllocated)
                {
                    frameHandle.Free();
                }
            }
        });
    }

    public Task<byte[]> DecodeFramePayloadAsync(byte[] encodedFrame)
    {
        ArgumentNullException.ThrowIfNull(encodedFrame);

        return Task.Run(() =>
        {
            var output = new byte[encodedFrame.Length];
            var frameHandle = encodedFrame.Length == 0
                ? default
                : GCHandle.Alloc(encodedFrame, GCHandleType.Pinned);
            var outputHandle = output.Length == 0
                ? default
                : GCHandle.Alloc(output, GCHandleType.Pinned);

            try
            {
                var result = NativeMethods.DecodeFramePayload(
                    encodedFrame.Length == 0 ? nint.Zero : frameHandle.AddrOfPinnedObject(),
                    (nuint)encodedFrame.Length,
                    output.Length == 0 ? nint.Zero : outputHandle.AddrOfPinnedObject(),
                    (nuint)output.Length,
                    out var writtenLen);

                if (result != SkybridgeErrorCode.Ok)
                {
                    throw new InvalidOperationException($"Frame payload decode failed: {result}");
                }

                return SliceOutput(output, writtenLen);
            }
            finally
            {
                if (frameHandle.IsAllocated)
                {
                    frameHandle.Free();
                }

                if (outputHandle.IsAllocated)
                {
                    outputHandle.Free();
                }
            }
        });
    }

    public Task<DiscoveryAdvertisement> ParseDiscoveryAdvertisementAsync(string service, string txt)
    {
        ArgumentNullException.ThrowIfNull(service);
        ArgumentNullException.ThrowIfNull(txt);

        return Task.Run(() =>
        {
            var serviceBytes = Encoding.UTF8.GetBytes(service);
            var txtBytes = Encoding.UTF8.GetBytes(txt);
            var serviceHandle = serviceBytes.Length == 0
                ? default
                : GCHandle.Alloc(serviceBytes, GCHandleType.Pinned);
            var txtHandle = txtBytes.Length == 0
                ? default
                : GCHandle.Alloc(txtBytes, GCHandleType.Pinned);

            try
            {
                var result = NativeMethods.ParseDiscoveryAdvertisement(
                    serviceBytes.Length == 0 ? nint.Zero : serviceHandle.AddrOfPinnedObject(),
                    (nuint)serviceBytes.Length,
                    txtBytes.Length == 0 ? nint.Zero : txtHandle.AddrOfPinnedObject(),
                    (nuint)txtBytes.Length,
                    out var advertisement);

                if (result != SkybridgeErrorCode.Ok)
                {
                    throw new InvalidOperationException($"Discovery advertisement parse failed: {result}");
                }

                return DiscoveryAdvertisement.FromNative(advertisement);
            }
            finally
            {
                if (serviceHandle.IsAllocated)
                {
                    serviceHandle.Free();
                }

                if (txtHandle.IsAllocated)
                {
                    txtHandle.Free();
                }
            }
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

        [DllImport("skybridge_core", EntryPoint = "skybridge_transport_binding_digest")]
        public static extern SkybridgeErrorCode TransportBindingDigest(
            CoreTransportKind transport,
            nint localEndpointPtr,
            nuint localEndpointLen,
            nint remoteEndpointPtr,
            nuint remoteEndpointLen,
            nint selectedCandidatePairPtr,
            nuint selectedCandidatePairLen,
            nint transportSecretFingerprintPtr,
            nuint transportSecretFingerprintLen,
            nint relayIdPtr,
            nuint relayIdLen,
            ulong timestampWindowMs,
            nint capabilityDigestPtr,
            nuint capabilityDigestLen,
            out NativeTransportBindingDigest digest);

        [DllImport("skybridge_core", EntryPoint = "skybridge_verify_webrtc_session_launch")]
        public static extern SkybridgeErrorCode VerifyWebRtcSessionLaunch(
            nint proofJsonPtr,
            nuint proofJsonLen,
            nint expectedDeviceIdPtr,
            nuint expectedDeviceIdLen,
            nint expectedFingerprintPtr,
            nuint expectedFingerprintLen,
            CoreTransportKind transport,
            CoreTransportAuditCode transportAudit,
            ulong maxAgeMs,
            out NativeVerifiedWebRtcSessionLaunch launch);

        [DllImport("skybridge_core", EntryPoint = "skybridge_project_signaling_lifecycle_state")]
        public static extern SkybridgeErrorCode ProjectSignalingLifecycleState(
            NativeSignalingLifecycleState current,
            NativeSignalingLifecycleEvent lifecycleEvent,
            out NativeSignalingLifecycleState projected);

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

        [DllImport("skybridge_core", EntryPoint = "skybridge_plan_file_transfer_readiness")]
        public static extern SkybridgeErrorCode PlanFileTransferReadiness(
            [In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] NativeFileTransferRouteCandidate[] routeCandidates,
            nuint routeCandidateCount,
            nint targetPeerIdPtr,
            nuint targetPeerIdLen,
            ulong requiredListenerGeneration,
            byte hasRequiredListenerGeneration,
            CoreFileTransferManifestMode manifestMode,
            [In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 8)] NativeFileTransferManifestFile[] manifestFiles,
            nuint manifestFileCount,
            ulong chunkSize,
            [In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 11)] NativeChannelMapping[] channelMappings,
            nuint channelMappingCount,
            out NativeFileTransferPlannerVerdict verdict);

        [DllImport("skybridge_core", EntryPoint = "skybridge_parse_discovery_advertisement")]
        public static extern SkybridgeErrorCode ParseDiscoveryAdvertisement(
            nint servicePtr,
            nuint serviceLen,
            nint txtPtr,
            nuint txtLen,
            out NativeDiscoveryAdvertisement advertisement);

        [DllImport("skybridge_core", EntryPoint = "skybridge_encode_frame")]
        public static extern SkybridgeErrorCode EncodeFrame(
            CoreChannelKind channel,
            ulong sequence,
            nint payloadPtr,
            nuint payloadLen,
            byte endOfMessage,
            nint outFramePtr,
            nuint outFrameCapacity,
            out nuint writtenLen);

        [DllImport("skybridge_core", EntryPoint = "skybridge_encode_sbp2_frame")]
        public static extern SkybridgeErrorCode EncodeSbp2Frame(
            CoreChannelKind channel,
            ulong sequence,
            nint payloadPtr,
            nuint payloadLen,
            nuint paddedPayloadLen,
            nint outFramePtr,
            nuint outFrameCapacity,
            out nuint writtenLen);

        [DllImport("skybridge_core", EntryPoint = "skybridge_decode_frame_metadata")]
        public static extern SkybridgeErrorCode DecodeFrameMetadata(
            nint framePtr,
            nuint frameLen,
            out NativeFrameMetadata metadata);

        [DllImport("skybridge_core", EntryPoint = "skybridge_decode_frame_payload")]
        public static extern SkybridgeErrorCode DecodeFramePayload(
            nint framePtr,
            nuint frameLen,
            nint outPayloadPtr,
            nuint outPayloadCapacity,
            out nuint writtenLen);
    }

    private static byte[] SliceOutput(byte[] output, nuint writtenLen)
    {
        if (writtenLen > (nuint)output.Length)
        {
            throw new InvalidOperationException("skybridge_core wrote more bytes than the caller-provided buffer.");
        }

        if (writtenLen == (nuint)output.Length)
        {
            return output;
        }

        var result = new byte[(int)writtenLen];
        Buffer.BlockCopy(output, 0, result, 0, result.Length);
        return result;
    }
}

public enum CorePeerPlatform
{
    Unknown = 0,
    Apple = 1,
    Windows = 2
}

public enum CoreDiscoveryServiceKind
{
    Unknown = 0,
    QuicPrimary = 1,
    TcpFallback = 2
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

public enum CoreSignalingLifecyclePhase
{
    Idle = 0,
    Connecting = 1,
    SocketOpen = 2,
    Bound = 3,
    Reconnecting = 4,
    Closing = 5,
    Closed = 6,
    Failed = 7
}

public enum CoreSignalingReadiness
{
    Idle = 0,
    TransportReady = 1,
    HandshakeComplete = 2
}

public enum CoreSignalingHealth
{
    Healthy = 0,
    DegradedRecoverable = 1,
    DegradedFatal = 2
}

public enum CoreSignalingFailureClass
{
    None = 0,
    AuthBindRejected = 1,
    InvalidShardOrSessionMismatch = 2,
    TokenExpired = 3,
    ProtocolViolation = 4,
    TransientNetwork = 5,
    TransientServer = 6
}

public enum CoreSignalingLifecycleEventKind
{
    Connecting = 1,
    SocketOpen = 2,
    Bound = 3,
    Reconnecting = 4,
    Closing = 5,
    Closed = 6,
    TransportReady = 7,
    HandshakeComplete = 8,
    Failed = 9
}

public enum CoreFileTransferReadinessStatus
{
    Blocked = 0,
    IntentOnly = 1,
    Ready = 2
}

public enum CoreFileTransferReadinessCode
{
    Ok = 0,
    IntentOnlyNoFiles = 1,
    MissingRoute = 2,
    TooManyCandidates = 3,
    MissingIdentity = 4,
    TargetPeerMismatch = 5,
    UnsupportedServiceType = 6,
    InvalidHost = 7,
    RequestedPeerToPeerRoute = 8,
    UnresolvedBonjourRoute = 9,
    ResolvedPeerToPeerRoute = 10,
    InvalidPort = 11,
    RouteStalePort = 12,
    RouteProvenanceMismatch = 13,
    MissingFileChannel = 14,
    InvalidManifest = 15,
    ManifestPathRejected = 16,
    ManifestHashRejected = 17,
    ManifestTooLarge = 18,
    ByteCountOverflow = 19
}

public enum CoreFileTransferAddressClass
{
    Invalid = 0,
    BonjourService = 1,
    LinkLocal = 2,
    LanDirect = 3
}

public enum CoreFileTransferRouteSource
{
    AuthenticatedSession = 0,
    RecentAuthenticatedInboundTransfer = 1,
    ClassicSessionRegistry = 2,
    PresenceOutbound = 3,
    PresenceInbound = 4,
    Unified = 5,
    Manual = 6,
    BonjourResolved = 7,
    Unknown = 8
}

public enum CoreFileTransferPortProvenance
{
    Unknown = 0,
    ListenerTruth = 1,
    PresenceDescriptor = 2,
    PairingPayload = 3,
    HeartbeatPayload = 4,
    RegistryState = 5,
    ManualInput = 6
}

public enum CoreFileTransferManifestMode
{
    IntentOnly = 0,
    Transfer = 1
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

    internal static PeerCapabilities FromNative(NativePeerCapabilities capabilities) =>
        new(
            capabilities.Platform,
            capabilities.SupportsAppleNative != 0,
            capabilities.SupportsMsQuic != 0,
            capabilities.SupportsSkyBridgeIceMsQuic != 0,
            capabilities.SupportsWebRtcDataChannel != 0,
            capabilities.SupportsTcpFallback != 0,
            capabilities.SupportsRelay != 0);

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

public sealed record DiscoveryAdvertisement(
    CoreDiscoveryServiceKind ServiceKind,
    string DeviceId,
    string PublicKeyFingerprint,
    CorePeerPlatform Platform,
    string PlatformLabel,
    string Capabilities,
    string Name,
    string ProtocolVersion,
    PeerCapabilities PeerCapabilities)
{
    internal static DiscoveryAdvertisement FromNative(NativeDiscoveryAdvertisement advertisement) =>
        new(
            advertisement.ServiceKind,
            ReadFixedUtf8(advertisement.DeviceId, advertisement.DeviceIdLen),
            ReadFixedUtf8(
                advertisement.PublicKeyFingerprint,
                advertisement.PublicKeyFingerprintLen),
            advertisement.Platform,
            ReadFixedUtf8(advertisement.PlatformLabel, advertisement.PlatformLabelLen),
            ReadFixedUtf8(advertisement.Capabilities, advertisement.CapabilitiesLen),
            ReadFixedUtf8(advertisement.Name, advertisement.NameLen),
            ReadFixedUtf8(advertisement.ProtocolVersion, advertisement.ProtocolVersionLen),
            PeerCapabilities.FromNative(advertisement.PeerCapabilities));

    private static string ReadFixedUtf8(byte[]? buffer, nuint len)
    {
        var bytes = buffer ?? Array.Empty<byte>();
        var count = len > (nuint)bytes.Length ? bytes.Length : (int)len;
        return Encoding.UTF8.GetString(bytes, 0, count);
    }
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

public sealed record TransportBindingMaterial(
    CoreTransportKind Transport,
    string LocalEndpoint,
    string RemoteEndpoint,
    string SelectedCandidatePair,
    byte[] TransportSecretFingerprint,
    string? RelayId,
    ulong TimestampWindowMs,
    byte[] CapabilityDigest);

public sealed record VerifiedWebRtcSessionLaunch(
    string PeerDeviceId,
    string PeerPublicKeyFingerprint,
    string HelperName,
    string AdapterBinding,
    string LocalEndpoint,
    string RemoteEndpoint,
    string SelectedCandidatePair,
    string? RelayId,
    ulong TimestampWindowMs,
    long CapturedAtUnixMs,
    ulong ProofAgeMs,
    byte[] TransportSecretFingerprint,
    byte[] CapabilityDigest,
    byte[] TransportBindingDigest)
{
    internal static VerifiedWebRtcSessionLaunch FromNative(NativeVerifiedWebRtcSessionLaunch launch) =>
        new(
            ReadFixedUtf8(launch.PeerDeviceId, launch.PeerDeviceIdLen),
            ReadFixedUtf8(launch.PeerPublicKeyFingerprint, launch.PeerPublicKeyFingerprintLen),
            ReadFixedUtf8(launch.HelperName, launch.HelperNameLen),
            ReadFixedUtf8(launch.AdapterBinding, launch.AdapterBindingLen),
            ReadFixedUtf8(launch.LocalEndpoint, launch.LocalEndpointLen),
            ReadFixedUtf8(launch.RemoteEndpoint, launch.RemoteEndpointLen),
            ReadFixedUtf8(launch.SelectedCandidatePair, launch.SelectedCandidatePairLen),
            launch.RelayIdLen == 0 ? null : ReadFixedUtf8(launch.RelayId, launch.RelayIdLen),
            launch.TimestampWindowMs,
            launch.CapturedAtUnixMs,
            launch.ProofAgeMs,
            RequireBytes(launch.TransportSecretFingerprint, 32, "transport secret fingerprint"),
            RequireBytes(launch.CapabilityDigest, 32, "capability digest"),
            RequireBytes(launch.TransportBindingDigest, 32, "transport binding digest"));

    public TransportBindingMaterial BuildTransportBindingMaterial(CoreTransportKind transport)
    {
        if (transport != CoreTransportKind.WebRtcDataChannel)
        {
            throw new InvalidOperationException("Verified WebRTC session launch material can only bind WebRtcDataChannel transport.");
        }

        return new(
            transport,
            LocalEndpoint,
            RemoteEndpoint,
            SelectedCandidatePair,
            (byte[])TransportSecretFingerprint.Clone(),
            RelayId,
            TimestampWindowMs,
            (byte[])CapabilityDigest.Clone());
    }

    private static string ReadFixedUtf8(byte[]? buffer, nuint len)
    {
        var bytes = buffer ?? Array.Empty<byte>();
        var count = len > (nuint)bytes.Length ? bytes.Length : (int)len;
        return Encoding.UTF8.GetString(bytes, 0, count);
    }

    private static byte[] RequireBytes(byte[]? buffer, int expectedLength, string label)
    {
        if (buffer is null || buffer.Length != expectedLength)
        {
            throw new InvalidOperationException($"skybridge_core returned an invalid WebRTC {label}.");
        }

        return (byte[])buffer.Clone();
    }
}

public sealed record SignalingLifecycleSnapshot(
    string SessionId,
    string Backend,
    ulong Generation,
    CoreSignalingLifecyclePhase LifecyclePhase,
    CoreSignalingHealth SignalingHealth,
    CoreSignalingReadiness Readiness,
    CoreSignalingReadiness LastEstablishedReadiness,
    CoreSignalingFailureClass FailureClass,
    string? NegotiatedSuite,
    uint ReconnectAttemptCount,
    bool BusinessSendsAllowed,
    bool CanReportConnected)
{
    public static SignalingLifecycleSnapshot Idle { get; } =
        new(
            "",
            "",
            0,
            CoreSignalingLifecyclePhase.Idle,
            CoreSignalingHealth.Healthy,
            CoreSignalingReadiness.Idle,
            CoreSignalingReadiness.Idle,
            CoreSignalingFailureClass.None,
            null,
            0,
            false,
            false);

    internal NativeSignalingLifecycleState ToNative()
    {
        var sessionId = WriteFixedUtf8(SessionId, 128, out var sessionIdLen);
        var backend = WriteFixedUtf8(Backend, 128, out var backendLen);
        var negotiatedSuite = WriteFixedUtf8(NegotiatedSuite ?? "", 64, out var negotiatedSuiteLen);

        return new()
        {
            SessionId = sessionId,
            SessionIdLen = sessionIdLen,
            Backend = backend,
            BackendLen = backendLen,
            Generation = Generation,
            LifecyclePhase = LifecyclePhase,
            SignalingHealth = SignalingHealth,
            Readiness = Readiness,
            LastEstablishedReadiness = LastEstablishedReadiness,
            FailureClass = FailureClass,
            NegotiatedSuite = negotiatedSuite,
            NegotiatedSuiteLen = negotiatedSuiteLen,
            ReconnectAttemptCount = ReconnectAttemptCount,
            BusinessSendsAllowed = BusinessSendsAllowed ? (byte)1 : (byte)0,
            CanReportConnected = CanReportConnected ? (byte)1 : (byte)0
        };
    }

    internal static SignalingLifecycleSnapshot FromNative(NativeSignalingLifecycleState state) =>
        new(
            ReadFixedUtf8(state.SessionId, state.SessionIdLen),
            ReadFixedUtf8(state.Backend, state.BackendLen),
            state.Generation,
            state.LifecyclePhase,
            state.SignalingHealth,
            state.Readiness,
            state.LastEstablishedReadiness,
            state.FailureClass,
            state.NegotiatedSuiteLen == 0 ? null : ReadFixedUtf8(state.NegotiatedSuite, state.NegotiatedSuiteLen),
            state.ReconnectAttemptCount,
            state.BusinessSendsAllowed != 0,
            state.CanReportConnected != 0);

    private static byte[] WriteFixedUtf8(string value, int capacity, out nuint len)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        if (bytes.Length > capacity)
        {
            throw new InvalidOperationException($"Signaling lifecycle text exceeds {capacity} bytes.");
        }

        var buffer = new byte[capacity];
        Buffer.BlockCopy(bytes, 0, buffer, 0, bytes.Length);
        len = (nuint)bytes.Length;
        return buffer;
    }

    private static string ReadFixedUtf8(byte[]? buffer, nuint len)
    {
        var bytes = buffer ?? Array.Empty<byte>();
        var count = len > (nuint)bytes.Length ? bytes.Length : (int)len;
        return Encoding.UTF8.GetString(bytes, 0, count);
    }
}

public sealed record SignalingLifecycleEvent(
    string SessionId,
    string Backend,
    ulong Generation,
    CoreSignalingLifecycleEventKind Kind,
    CoreSignalingFailureClass FailureClass,
    string? NegotiatedSuite)
{
    internal NativeSignalingLifecycleEvent ToNative()
    {
        var sessionId = WriteFixedUtf8(SessionId, 128, out var sessionIdLen);
        var backend = WriteFixedUtf8(Backend, 128, out var backendLen);
        var negotiatedSuite = WriteFixedUtf8(NegotiatedSuite ?? "", 64, out var negotiatedSuiteLen);

        return new()
        {
            SessionId = sessionId,
            SessionIdLen = sessionIdLen,
            Backend = backend,
            BackendLen = backendLen,
            Generation = Generation,
            Kind = Kind,
            FailureClass = FailureClass,
            NegotiatedSuite = negotiatedSuite,
            NegotiatedSuiteLen = negotiatedSuiteLen
        };
    }

    private static byte[] WriteFixedUtf8(string value, int capacity, out nuint len)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        if (bytes.Length > capacity)
        {
            throw new InvalidOperationException($"Signaling lifecycle event text exceeds {capacity} bytes.");
        }

        var buffer = new byte[capacity];
        Buffer.BlockCopy(bytes, 0, buffer, 0, bytes.Length);
        len = (nuint)bytes.Length;
        return buffer;
    }
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

    internal NativeChannelMapping ToNative() =>
        new()
        {
            Channel = Channel,
            Reliability = Reliability,
            MaxRetransmits = MaxRetransmits,
            BindingKind = BindingKind,
            HeadOfLineIsolated = HeadOfLineIsolated ? (byte)1 : (byte)0
        };
}

internal static class CoreChannelMappingResolver
{
    public static IReadOnlyList<ChannelMapping> RequireAll(
        IReadOnlyList<ChannelMapping> mappings)
    {
        ArgumentNullException.ThrowIfNull(mappings);
        if (mappings.Count != 5)
        {
            throw new InvalidOperationException("Core connection plan must return all five channel mappings.");
        }

        var seenChannels = new HashSet<CoreChannelKind>();
        foreach (var mapping in mappings)
        {
            if (!seenChannels.Add(mapping.Channel))
            {
                throw new InvalidOperationException("Core connection plan returned duplicate channel mappings.");
            }
        }

        foreach (var channel in RequiredChannels)
        {
            if (!seenChannels.Contains(channel))
            {
                throw new InvalidOperationException($"Core connection plan did not return the required {channel} channel mapping.");
            }
        }

        return mappings;
    }

    public static ChannelMapping Require(
        IReadOnlyList<ChannelMapping> mappings,
        CoreChannelKind channel)
    {
        RequireAll(mappings);
        foreach (var mapping in mappings)
        {
            if (mapping.Channel == channel)
            {
                return mapping;
            }
        }

        throw new InvalidOperationException($"Core connection plan did not return the required {channel} channel mapping.");
    }

    private static readonly CoreChannelKind[] RequiredChannels =
    {
        CoreChannelKind.Control,
        CoreChannelKind.File,
        CoreChannelKind.Clipboard,
        CoreChannelKind.Telemetry,
        CoreChannelKind.Realtime
    };
}

public sealed record FileTransferRouteCandidate(
    string PeerId,
    string DeviceName,
    string RequestedHost,
    string? ResolvedHost,
    string ServiceType,
    ushort? Port,
    CoreFileTransferRouteSource RouteSource,
    CoreFileTransferPortProvenance PortProvenance,
    ulong? ListenerGeneration)
{
    internal NativeFileTransferRouteCandidate ToNative()
    {
        ArgumentNullException.ThrowIfNull(PeerId);
        ArgumentNullException.ThrowIfNull(DeviceName);
        ArgumentNullException.ThrowIfNull(RequestedHost);
        ArgumentNullException.ThrowIfNull(ServiceType);

        var peerId = CoreBridgeFixedUtf8.Write(PeerId, 128, nameof(PeerId), out var peerIdLen);
        var deviceName = CoreBridgeFixedUtf8.Write(DeviceName, 128, nameof(DeviceName), out var deviceNameLen);
        var requestedHost = CoreBridgeFixedUtf8.Write(RequestedHost, 128, nameof(RequestedHost), out var requestedHostLen);
        var resolvedHost = CoreBridgeFixedUtf8.Write(ResolvedHost ?? "", 128, nameof(ResolvedHost), out var resolvedHostLen);
        var serviceType = CoreBridgeFixedUtf8.Write(ServiceType, 64, nameof(ServiceType), out var serviceTypeLen);

        return new()
        {
            PeerId = peerId,
            PeerIdLen = peerIdLen,
            DeviceName = deviceName,
            DeviceNameLen = deviceNameLen,
            RequestedHost = requestedHost,
            RequestedHostLen = requestedHostLen,
            ResolvedHost = resolvedHost,
            ResolvedHostLen = resolvedHostLen,
            ServiceType = serviceType,
            ServiceTypeLen = serviceTypeLen,
            Port = Port.GetValueOrDefault(),
            HasPort = Port.HasValue ? (byte)1 : (byte)0,
            RouteSource = RouteSource,
            PortProvenance = PortProvenance,
            ListenerGeneration = ListenerGeneration.GetValueOrDefault(),
            HasListenerGeneration = ListenerGeneration.HasValue ? (byte)1 : (byte)0
        };
    }
}

public sealed record FileTransferManifestFile(
    string DisplayName,
    string RelativePath,
    ulong ByteLen,
    string Sha256Hex,
    string MimeType)
{
    internal NativeFileTransferManifestFile ToNative()
    {
        ArgumentNullException.ThrowIfNull(DisplayName);
        ArgumentNullException.ThrowIfNull(RelativePath);
        ArgumentNullException.ThrowIfNull(Sha256Hex);
        ArgumentNullException.ThrowIfNull(MimeType);

        var displayName = CoreBridgeFixedUtf8.Write(DisplayName, 128, nameof(DisplayName), out var displayNameLen);
        var relativePath = CoreBridgeFixedUtf8.Write(RelativePath, 256, nameof(RelativePath), out var relativePathLen);
        var sha256Hex = CoreBridgeFixedUtf8.Write(Sha256Hex, 64, nameof(Sha256Hex), out var sha256HexLen);
        var mimeType = CoreBridgeFixedUtf8.Write(MimeType, 64, nameof(MimeType), out var mimeTypeLen);

        return new()
        {
            DisplayName = displayName,
            DisplayNameLen = displayNameLen,
            RelativePath = relativePath,
            RelativePathLen = relativePathLen,
            ByteLen = ByteLen,
            Sha256Hex = sha256Hex,
            Sha256HexLen = sha256HexLen,
            MimeType = mimeType,
            MimeTypeLen = mimeTypeLen
        };
    }
}

public sealed record FileTransferPlannerVerdict(
    CoreFileTransferReadinessStatus Status,
    CoreFileTransferReadinessCode Code,
    CoreFileTransferAddressClass SelectedAddressClass,
    CoreFileTransferRouteSource SelectedRouteSource,
    string? SelectedPeerId,
    string? SelectedDeviceName,
    string? SelectedHost,
    ushort? SelectedPort,
    ulong? SelectedListenerGeneration,
    ushort ManifestVersion,
    nuint ManifestFileCount,
    ulong ManifestTotalBytes,
    ulong ManifestTotalChunks,
    ulong ManifestChunkSize,
    byte[]? ManifestDigest,
    CoreAdapterBindingKind? FileChannelBindingKind,
    bool FileChannelHeadOfLineIsolated,
    nuint FrameHeaderLen,
    string Audit)
{
    internal static FileTransferPlannerVerdict FromNative(NativeFileTransferPlannerVerdict verdict)
    {
        var selectedPeerId = ReadOptionalFixedUtf8(
            verdict.SelectedPeerId,
            verdict.SelectedPeerIdLen,
            "file transfer selected peer id");
        var selectedDeviceName = ReadOptionalFixedUtf8(
            verdict.SelectedDeviceName,
            verdict.SelectedDeviceNameLen,
            "file transfer selected device name");
        var selectedHost = ReadOptionalFixedUtf8(
            verdict.SelectedHost,
            verdict.SelectedHostLen,
            "file transfer selected host");
        var manifestDigest = verdict.HasManifestDigest == 0
            ? null
            : CoreBridgeFixedUtf8.RequireBytes(verdict.ManifestDigest, 32, "file transfer manifest digest");
        CoreAdapterBindingKind? fileChannelBinding = verdict.HasFileChannel == 0
            ? null
            : verdict.FileChannelBindingKind;

        return new(
            verdict.Status,
            verdict.Code,
            verdict.SelectedAddressClass,
            verdict.SelectedRouteSource,
            selectedPeerId,
            selectedDeviceName,
            selectedHost,
            selectedHost is null ? null : verdict.SelectedPort,
            verdict.HasSelectedListenerGeneration == 0 ? null : verdict.SelectedListenerGeneration,
            verdict.ManifestVersion,
            verdict.ManifestFileCount,
            verdict.ManifestTotalBytes,
            verdict.ManifestTotalChunks,
            verdict.ManifestChunkSize,
            manifestDigest,
            fileChannelBinding,
            verdict.FileChannelHeadOfLineIsolated != 0,
            verdict.FrameHeaderLen,
            CoreBridgeFixedUtf8.Read(verdict.Audit, verdict.AuditLen, "file transfer audit"));
    }

    private static string? ReadOptionalFixedUtf8(byte[]? buffer, nuint len, string label) =>
        len == 0 ? null : CoreBridgeFixedUtf8.Read(buffer, len, label);
}

internal static class CoreBridgeFixedUtf8
{
    public static byte[] Write(string value, int capacity, string label, out nuint len)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        if (bytes.Length > capacity)
        {
            throw new InvalidOperationException($"{label} exceeds the {capacity}-byte skybridge_core FFI field capacity.");
        }

        var buffer = new byte[capacity];
        Buffer.BlockCopy(bytes, 0, buffer, 0, bytes.Length);
        len = (nuint)bytes.Length;
        return buffer;
    }

    public static string Read(byte[]? buffer, nuint len, string label)
    {
        if (buffer is null)
        {
            if (len == 0)
            {
                return "";
            }

            throw new InvalidOperationException($"skybridge_core returned a null {label} buffer with non-zero length.");
        }

        if (len > (nuint)buffer.Length)
        {
            throw new InvalidOperationException($"skybridge_core returned a {label} length outside the fixed FFI buffer.");
        }

        return Encoding.UTF8.GetString(buffer, 0, (int)len);
    }

    public static byte[] RequireBytes(byte[]? buffer, int expectedLength, string label)
    {
        if (buffer is null || buffer.Length != expectedLength)
        {
            throw new InvalidOperationException($"skybridge_core returned an invalid {label}.");
        }

        return (byte[])buffer.Clone();
    }
}

public sealed record FrameMetadata(
    CoreChannelKind Channel,
    ulong Sequence,
    ushort Flags,
    nuint FrameHeaderLen,
    nuint EncodedLen,
    nuint PayloadLen,
    nuint DecodedPayloadLen)
{
    public bool IsSbp2Padded => (Flags & 0x0001) != 0;

    public bool IsEndOfMessage => (Flags & 0x0002) != 0;

    internal static FrameMetadata FromNative(NativeFrameMetadata metadata) =>
        new(
            metadata.Channel,
            metadata.Sequence,
            metadata.Flags,
            metadata.FrameHeaderLen,
            metadata.EncodedLen,
            metadata.PayloadLen,
            metadata.DecodedPayloadLen);
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
internal struct NativeTransportBindingDigest
{
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
    public byte[] Digest;
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativeVerifiedWebRtcSessionLaunch
{
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 64)]
    public byte[] PeerDeviceId;

    public nuint PeerDeviceIdLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 64)]
    public byte[] PeerPublicKeyFingerprint;

    public nuint PeerPublicKeyFingerprintLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)]
    public byte[] HelperName;

    public nuint HelperNameLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
    public byte[] AdapterBinding;

    public nuint AdapterBindingLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
    public byte[] LocalEndpoint;

    public nuint LocalEndpointLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
    public byte[] RemoteEndpoint;

    public nuint RemoteEndpointLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
    public byte[] SelectedCandidatePair;

    public nuint SelectedCandidatePairLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)]
    public byte[] RelayId;

    public nuint RelayIdLen;
    public ulong TimestampWindowMs;
    public long CapturedAtUnixMs;
    public ulong ProofAgeMs;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
    public byte[] TransportSecretFingerprint;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
    public byte[] CapabilityDigest;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
    public byte[] TransportBindingDigest;
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativeSignalingLifecycleState
{
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)]
    public byte[] SessionId;

    public nuint SessionIdLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)]
    public byte[] Backend;

    public nuint BackendLen;
    public ulong Generation;
    public CoreSignalingLifecyclePhase LifecyclePhase;
    public CoreSignalingHealth SignalingHealth;
    public CoreSignalingReadiness Readiness;
    public CoreSignalingReadiness LastEstablishedReadiness;
    public CoreSignalingFailureClass FailureClass;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 64)]
    public byte[] NegotiatedSuite;

    public nuint NegotiatedSuiteLen;
    public uint ReconnectAttemptCount;
    public byte BusinessSendsAllowed;
    public byte CanReportConnected;
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativeSignalingLifecycleEvent
{
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)]
    public byte[] SessionId;

    public nuint SessionIdLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)]
    public byte[] Backend;

    public nuint BackendLen;
    public ulong Generation;
    public CoreSignalingLifecycleEventKind Kind;
    public CoreSignalingFailureClass FailureClass;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 64)]
    public byte[] NegotiatedSuite;

    public nuint NegotiatedSuiteLen;
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
internal struct NativeFileTransferRouteCandidate
{
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)]
    public byte[] PeerId;

    public nuint PeerIdLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)]
    public byte[] DeviceName;

    public nuint DeviceNameLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)]
    public byte[] RequestedHost;

    public nuint RequestedHostLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)]
    public byte[] ResolvedHost;

    public nuint ResolvedHostLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 64)]
    public byte[] ServiceType;

    public nuint ServiceTypeLen;
    public ushort Port;
    public byte HasPort;
    public CoreFileTransferRouteSource RouteSource;
    public CoreFileTransferPortProvenance PortProvenance;
    public ulong ListenerGeneration;
    public byte HasListenerGeneration;
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativeFileTransferManifestFile
{
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)]
    public byte[] DisplayName;

    public nuint DisplayNameLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
    public byte[] RelativePath;

    public nuint RelativePathLen;
    public ulong ByteLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 64)]
    public byte[] Sha256Hex;

    public nuint Sha256HexLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 64)]
    public byte[] MimeType;

    public nuint MimeTypeLen;
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativeFileTransferPlannerVerdict
{
    public CoreFileTransferReadinessStatus Status;
    public CoreFileTransferReadinessCode Code;
    public CoreFileTransferAddressClass SelectedAddressClass;
    public CoreFileTransferRouteSource SelectedRouteSource;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)]
    public byte[] SelectedPeerId;

    public nuint SelectedPeerIdLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)]
    public byte[] SelectedDeviceName;

    public nuint SelectedDeviceNameLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)]
    public byte[] SelectedHost;

    public nuint SelectedHostLen;
    public ushort SelectedPort;
    public ulong SelectedListenerGeneration;
    public byte HasSelectedListenerGeneration;
    public ushort ManifestVersion;
    public nuint ManifestFileCount;
    public ulong ManifestTotalBytes;
    public ulong ManifestTotalChunks;
    public ulong ManifestChunkSize;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
    public byte[] ManifestDigest;

    public byte HasManifestDigest;
    public CoreAdapterBindingKind FileChannelBindingKind;
    public byte HasFileChannel;
    public byte FileChannelHeadOfLineIsolated;
    public nuint FrameHeaderLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
    public byte[] Audit;

    public nuint AuditLen;
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativeFrameMetadata
{
    public CoreChannelKind Channel;
    public ulong Sequence;
    public ushort Flags;
    public nuint FrameHeaderLen;
    public nuint EncodedLen;
    public nuint PayloadLen;
    public nuint DecodedPayloadLen;
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

[StructLayout(LayoutKind.Sequential)]
internal struct NativeDiscoveryAdvertisement
{
    public CoreDiscoveryServiceKind ServiceKind;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 64)]
    public byte[] DeviceId;

    public nuint DeviceIdLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 64)]
    public byte[] PublicKeyFingerprint;

    public nuint PublicKeyFingerprintLen;
    public CorePeerPlatform Platform;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
    public byte[] PlatformLabel;

    public nuint PlatformLabelLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
    public byte[] Capabilities;

    public nuint CapabilitiesLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)]
    public byte[] Name;

    public nuint NameLen;

    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
    public byte[] ProtocolVersion;

    public nuint ProtocolVersionLen;
    public NativePeerCapabilities PeerCapabilities;
}
