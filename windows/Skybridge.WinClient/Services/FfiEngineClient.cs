using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public sealed class FfiEngineClient : IEngineClient, IDisposable
{
    private const string ClientId = "skybridge-windows-client";
    private const ulong HeartbeatIntervalMs = 1_000;

    private readonly object _disposeLock = new();
    private readonly SemaphoreSlim _mutex = new(1, 1);
    private nint _handle;
    private bool _disposed;
    private EngineConnectionState _state = EngineConnectionState.Disconnected;

    static FfiEngineClient()
    {
        SkybridgeNativeLibraryResolver.Register();
    }

    public EngineConnectionState State => _state;

    public event EventHandler<EngineConnectionState>? ConnectionStateChanged;

    public async Task ConnectAsync(ConnectionLaunchRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        request.Plan.ValidateForLaunch(request.PairingMaterial);
        if (!request.Plan.IsLiveAdapterReady)
        {
            throw new NotSupportedException("Connection launch requires a live Windows transport adapter; the current request is preflight-only.");
        }

        ThrowIfDisposed();
        await _mutex.WaitAsync();
        try
        {
            ThrowIfDisposed();
            if (_state != EngineConnectionState.Disconnected)
            {
                return;
            }

            EnsureHandle();
            SetState(EngineConnectionState.Connecting);
            IPeerPublicKeyProvider peerPublicKeyProvider = request.PairingMaterial.ToPeerPublicKeyProvider();
            var peerPublicKey = await peerPublicKeyProvider.GetPeerPublicKeyAsync();
            if (peerPublicKey is null || peerPublicKey.Length == 0)
            {
                throw new InvalidOperationException("Cannot connect without a peer public key from pairing.");
            }

            var clientId = Encoding.UTF8.GetBytes(ClientId);
            var transportBindingDigest = (byte[])request.Plan.TransportBindingDigest.Clone();
            var adapterBinding = Encoding.UTF8.GetBytes(request.Plan.AdapterBinding);
            var localEndpoint = Encoding.UTF8.GetBytes(request.Plan.LocalEndpoint);
            var remoteEndpoint = Encoding.UTF8.GetBytes(request.Plan.RemoteEndpoint);
            var selectedCandidatePair = Encoding.UTF8.GetBytes(request.Plan.SelectedCandidatePair);
            var relayId = string.IsNullOrEmpty(request.Plan.RelayId)
                ? Array.Empty<byte>()
                : Encoding.UTF8.GetBytes(request.Plan.RelayId);
            var nativeChannelMappings = BuildNativeChannelMappings(request.Plan.ChannelMappings);

            var pinnedHandles = new List<GCHandle>();
            try
            {
                var config = new NativeSessionConfig
                {
                    ClientIdPtr = PinArray(clientId, pinnedHandles),
                    ClientIdLen = (nuint)clientId.Length,
                    HeartbeatIntervalMs = HeartbeatIntervalMs,
                    PeerPublicKeyPtr = PinArray(peerPublicKey, pinnedHandles),
                    PeerPublicKeyLen = (nuint)peerPublicKey.Length,
                    Transport = request.Plan.TransportKind,
                    TransportAudit = request.Plan.TransportAudit,
                    RelayRequired = ToFlag(request.Plan.RelayRequired),
                    RelayAllowed = ToFlag(request.Plan.RelayAllowed),
                    SelectedSuite = request.Plan.SelectedSuite,
                    SelectedSuiteWireId = request.Plan.SelectedSuiteWireId,
                    SuiteAudit = request.Plan.SuiteAudit,
                    Sbp2Enabled = ToFlag(request.Plan.Sbp2Enabled),
                    Sbp2FixedPayloadLen = request.Plan.Sbp2FixedPayloadLen,
                    FrameHeaderLen = request.Plan.FrameHeaderLen,
                    TransportBindingDigestPtr = PinArray(transportBindingDigest, pinnedHandles),
                    TransportBindingDigestLen = (nuint)transportBindingDigest.Length,
                    AdapterKind = request.Plan.AdapterKind,
                    IsLiveAdapterReady = ToFlag(request.Plan.IsLiveAdapterReady),
                    AdapterBindingPtr = PinArray(adapterBinding, pinnedHandles),
                    AdapterBindingLen = (nuint)adapterBinding.Length,
                    LocalEndpointPtr = PinArray(localEndpoint, pinnedHandles),
                    LocalEndpointLen = (nuint)localEndpoint.Length,
                    RemoteEndpointPtr = PinArray(remoteEndpoint, pinnedHandles),
                    RemoteEndpointLen = (nuint)remoteEndpoint.Length,
                    SelectedCandidatePairPtr = PinArray(selectedCandidatePair, pinnedHandles),
                    SelectedCandidatePairLen = (nuint)selectedCandidatePair.Length,
                    RelayIdPtr = PinArray(relayId, pinnedHandles),
                    RelayIdLen = (nuint)relayId.Length,
                    TimestampWindowMs = request.Plan.TimestampWindowMs,
                    ChannelMappingsPtr = PinArray(nativeChannelMappings, pinnedHandles),
                    ChannelMappingCount = (nuint)nativeChannelMappings.Length
                };
                var result = NativeMethods.EngineConnect(_handle, config);
                ThrowOnError(result, "connect");
            }
            catch
            {
                SetState(EngineConnectionState.Disconnected);
                throw;
            }
            finally
            {
                foreach (var handle in pinnedHandles)
                {
                    if (handle.IsAllocated)
                    {
                        handle.Free();
                    }
                }
            }

            RefreshStateFromCore();
        }
        finally
        {
            _mutex.Release();
        }
    }

    public async Task<byte[]> GetLocalPublicKeyAsync()
    {
        ThrowIfDisposed();
        await _mutex.WaitAsync();
        try
        {
            ThrowIfDisposed();
            EnsureHandle();
            return ReadLocalPublicKey();
        }
        finally
        {
            _mutex.Release();
        }
    }

    public async Task DisconnectAsync()
    {
        ThrowIfDisposed();
        await _mutex.WaitAsync();
        try
        {
            ThrowIfDisposed();
            if (_state == EngineConnectionState.Disconnected || _handle == nint.Zero)
            {
                return;
            }

            SetState(EngineConnectionState.ShuttingDown);
            ThrowOnError(NativeMethods.EngineDisconnect(_handle), "disconnect");
            RefreshStateFromCore();
        }
        finally
        {
            _mutex.Release();
        }
    }

    public async Task SendHeartbeatAsync()
    {
        ThrowIfDisposed();
        await _mutex.WaitAsync();
        try
        {
            ThrowIfDisposed();
            if (_handle == nint.Zero)
            {
                throw new InvalidOperationException("Cannot send heartbeat before the FFI engine is created.");
            }

            ThrowOnError(NativeMethods.EngineSendHeartbeat(_handle), "heartbeat");
            RefreshStateFromCore();
        }
        finally
        {
            _mutex.Release();
        }
    }

    public void Dispose()
    {
        lock (_disposeLock)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
        }

        SkybridgeErrorCode disconnectError = SkybridgeErrorCode.Ok;
        _mutex.Wait();
        try
        {
            if (_handle != nint.Zero)
            {
                if (_state != EngineConnectionState.Disconnected)
                {
                    disconnectError = NativeMethods.EngineDisconnect(_handle);
                    _state = EngineConnectionState.Disconnected;
                }

                NativeMethods.EngineFree(_handle);
                _handle = nint.Zero;
            }
        }
        finally
        {
            _mutex.Release();
            _mutex.Dispose();
        }

        GC.SuppressFinalize(this);
        ThrowOnError(disconnectError, "dispose_disconnect");
    }

    private void EnsureHandle()
    {
        if (_handle != nint.Zero)
        {
            return;
        }

        _handle = NativeMethods.EngineNew();
        if (_handle == nint.Zero)
        {
            throw new InvalidOperationException("skybridge_core returned a null engine handle.");
        }
    }

    private byte[] ReadLocalPublicKey()
    {
        ThrowOnError(NativeMethods.EngineLocalPublicKey(_handle, out var buffer), "local_public_key");
        if (buffer.DataPtr == nint.Zero || buffer.DataLen == 0)
        {
            throw new InvalidOperationException("skybridge_core returned an empty local public key.");
        }

        if (buffer.DataLen > (nuint)int.MaxValue)
        {
            throw new InvalidOperationException("skybridge_core returned a public key larger than this client can marshal.");
        }

        var data = new byte[(int)buffer.DataLen];
        Marshal.Copy(buffer.DataPtr, data, 0, data.Length);
        return data;
    }

    private void RefreshStateFromCore()
    {
        SetState(NativeMethods.EngineState(_handle) switch
        {
            NativeSessionState.Connecting => EngineConnectionState.Connecting,
            NativeSessionState.Connected => EngineConnectionState.Connected,
            NativeSessionState.Reconnecting => EngineConnectionState.Reconnecting,
            NativeSessionState.ShuttingDown => EngineConnectionState.ShuttingDown,
            _ => EngineConnectionState.Disconnected
        });
    }

    private void SetState(EngineConnectionState newState)
    {
        if (_state == newState)
        {
            return;
        }

        _state = newState;
        ConnectionStateChanged?.Invoke(this, newState);
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(FfiEngineClient));
        }
    }

    private static void ThrowOnError(SkybridgeErrorCode code, string operation)
    {
        if (code != SkybridgeErrorCode.Ok)
        {
            throw new InvalidOperationException($"skybridge_core {operation} failed: {code}");
        }
    }

    private static NativeChannelMapping[] BuildNativeChannelMappings(
        IReadOnlyList<ChannelMapping> mappings)
    {
        var nativeMappings = new NativeChannelMapping[mappings.Count];
        for (var index = 0; index < mappings.Count; index++)
        {
            var mapping = mappings[index];
            nativeMappings[index] = new NativeChannelMapping
            {
                Channel = mapping.Channel,
                Reliability = mapping.Reliability,
                MaxRetransmits = mapping.MaxRetransmits,
                BindingKind = mapping.BindingKind,
                HeadOfLineIsolated = ToFlag(mapping.HeadOfLineIsolated)
            };
        }

        return nativeMappings;
    }

    private static nint PinArray<T>(T[] values, List<GCHandle> handles)
        where T : struct
    {
        if (values.Length == 0)
        {
            return nint.Zero;
        }

        var handle = GCHandle.Alloc(values, GCHandleType.Pinned);
        handles.Add(handle);
        return handle.AddrOfPinnedObject();
    }

    private static byte ToFlag(bool value) => value ? (byte)1 : (byte)0;

    private static class NativeMethods
    {
        [DllImport("skybridge_core", EntryPoint = "skybridge_engine_new")]
        public static extern nint EngineNew();

        [DllImport("skybridge_core", EntryPoint = "skybridge_engine_free")]
        public static extern void EngineFree(nint handle);

        [DllImport("skybridge_core", EntryPoint = "skybridge_engine_local_public_key")]
        public static extern SkybridgeErrorCode EngineLocalPublicKey(nint handle, out NativeBuffer buffer);

        [DllImport("skybridge_core", EntryPoint = "skybridge_engine_connect")]
        public static extern SkybridgeErrorCode EngineConnect(nint handle, NativeSessionConfig config);

        [DllImport("skybridge_core", EntryPoint = "skybridge_engine_send_heartbeat")]
        public static extern SkybridgeErrorCode EngineSendHeartbeat(nint handle);

        [DllImport("skybridge_core", EntryPoint = "skybridge_engine_disconnect")]
        public static extern SkybridgeErrorCode EngineDisconnect(nint handle);

        [DllImport("skybridge_core", EntryPoint = "skybridge_engine_state")]
        public static extern NativeSessionState EngineState(nint handle);
    }
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativeBuffer
{
    public nint DataPtr;
    public nuint DataLen;
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativeSessionConfig
{
    public nint ClientIdPtr;
    public nuint ClientIdLen;
    public ulong HeartbeatIntervalMs;
    public nint PeerPublicKeyPtr;
    public nuint PeerPublicKeyLen;
    public CoreTransportKind Transport;
    public CoreTransportAuditCode TransportAudit;
    public byte RelayRequired;
    public byte RelayAllowed;
    public CoreCryptoSuiteKind SelectedSuite;
    public ushort SelectedSuiteWireId;
    public CoreCryptoSuiteAuditCode SuiteAudit;
    public byte Sbp2Enabled;
    public nuint Sbp2FixedPayloadLen;
    public nuint FrameHeaderLen;
    public nint TransportBindingDigestPtr;
    public nuint TransportBindingDigestLen;
    public ConnectionLaunchAdapterKind AdapterKind;
    public byte IsLiveAdapterReady;
    public nint AdapterBindingPtr;
    public nuint AdapterBindingLen;
    public nint LocalEndpointPtr;
    public nuint LocalEndpointLen;
    public nint RemoteEndpointPtr;
    public nuint RemoteEndpointLen;
    public nint SelectedCandidatePairPtr;
    public nuint SelectedCandidatePairLen;
    public nint RelayIdPtr;
    public nuint RelayIdLen;
    public ulong TimestampWindowMs;
    public nint ChannelMappingsPtr;
    public nuint ChannelMappingCount;
}

internal enum NativeSessionState
{
    Disconnected = 0,
    Connecting = 1,
    Connected = 2,
    Reconnecting = 3,
    ShuttingDown = 4
}

public interface IPeerPublicKeyProvider
{
    Task<byte[]> GetPeerPublicKeyAsync();
}

public sealed class StaticPeerPublicKeyProvider : IPeerPublicKeyProvider
{
    private readonly byte[] _peerPublicKey;

    public StaticPeerPublicKeyProvider(byte[] peerPublicKey)
    {
        _peerPublicKey = peerPublicKey?.Length > 0
            ? (byte[])peerPublicKey.Clone()
            : throw new ArgumentException("Peer public key must not be empty.", nameof(peerPublicKey));
    }

    public Task<byte[]> GetPeerPublicKeyAsync()
    {
        return Task.FromResult((byte[])_peerPublicKey.Clone());
    }
}
