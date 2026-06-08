using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public sealed class FfiEngineClient : IEngineClient, IDisposable
{
    private const string ClientId = "skybridge-windows-client";
    private const ulong HeartbeatIntervalMs = 1_000;

    private readonly SemaphoreSlim _mutex = new(1, 1);
    private nint _handle;
    private bool _disposed;
    private EngineConnectionState _state = EngineConnectionState.Disconnected;

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

            var clientIdHandle = GCHandle.Alloc(clientId, GCHandleType.Pinned);
            var peerKeyHandle = GCHandle.Alloc(peerPublicKey, GCHandleType.Pinned);
            try
            {
                var config = new NativeSessionConfig
                {
                    ClientIdPtr = clientIdHandle.AddrOfPinnedObject(),
                    ClientIdLen = (nuint)clientId.Length,
                    HeartbeatIntervalMs = HeartbeatIntervalMs,
                    PeerPublicKeyPtr = peerKeyHandle.AddrOfPinnedObject(),
                    PeerPublicKeyLen = (nuint)peerPublicKey.Length
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
                peerKeyHandle.Free();
                clientIdHandle.Free();
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
        if (_disposed)
        {
            return;
        }

        if (_handle != nint.Zero)
        {
            NativeMethods.EngineFree(_handle);
            _handle = nint.Zero;
        }

        _mutex.Dispose();
        _disposed = true;
        GC.SuppressFinalize(this);
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
