using System.Buffers.Binary;
using System.Net.Sockets;

namespace Skybridge.WinClient.Services;

/// <summary>One ordered framed channel whose reader spans handshake and control phases.</summary>
internal sealed class TcpProductControlTransport : IProductHandshakeTransport, IAsyncDisposable
{
    private readonly TcpClient _client;
    private readonly NetworkStream _stream;
    private readonly SemaphoreSlim _sendGate = new(1, 1);
    private readonly CancellationTokenSource _lifetime = new();
    private readonly object _stateGate = new();
    private readonly TaskCompletionSource _drained = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TimeSpan _sendTimeout;
    private readonly int _maximumInboundFrameBytes;
    private readonly int _maximumOutboundFrameBytes;
    private bool _closed;
    private bool _disposed;
    private int _operations;
    private Exception? _terminalFailure;

    public TcpProductControlTransport(TcpClient client, int maximumInboundFrameBytes,
        int maximumOutboundFrameBytes, TimeSpan? sendTimeout = null)
    {
        ArgumentNullException.ThrowIfNull(client);
        if (maximumInboundFrameBytes <= 0)
            throw new ArgumentOutOfRangeException(nameof(maximumInboundFrameBytes));
        if (maximumOutboundFrameBytes <= 0)
            throw new ArgumentOutOfRangeException(nameof(maximumOutboundFrameBytes));
        _maximumInboundFrameBytes = maximumInboundFrameBytes;
        _maximumOutboundFrameBytes = maximumOutboundFrameBytes;
        _sendTimeout = sendTimeout ?? TimeSpan.FromSeconds(5);
        if (_sendTimeout <= TimeSpan.Zero || _sendTimeout > TimeSpan.FromMinutes(1))
            throw new ArgumentOutOfRangeException(nameof(sendTimeout));
        _client = client;
        try
        {
            client.NoDelay = true;
            // Static desktops can leave the control channel idle. Bound loss of
            // a vanished peer through TCP liveness without adding protocol traffic.
            client.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
            client.Client.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveTime, 10);
            client.Client.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveInterval, 3);
            client.Client.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveRetryCount, 3);
            _stream = client.GetStream();
        }
        catch
        {
            client.Dispose();
            _sendGate.Dispose();
            _lifetime.Dispose();
            throw;
        }
    }

    public async Task<ReadOnlyMemory<byte>> ReadAsync(CancellationToken cancellationToken)
    {
        using var linked = BeginOperation(cancellationToken);
        try
        {
            var header = new byte[4];
            await _stream.ReadExactlyAsync(header, linked.Token).ConfigureAwait(false);
            var length = BinaryPrimitives.ReadUInt32BigEndian(header);
            if (length == 0 || length > _maximumInboundFrameBytes)
                throw new InvalidDataException("Remote-control frame length exceeds the inbound limit.");
            var payload = new byte[checked((int)length)];
            await _stream.ReadExactlyAsync(payload, linked.Token).ConfigureAwait(false);
            return payload;
        }
        catch (Exception readFailure) when (readFailure is OperationCanceledException or IOException or ObjectDisposedException &&
            !cancellationToken.IsCancellationRequested && Volatile.Read(ref _terminalFailure) is { } sendFailure)
        {
            throw new AggregateException("Remote-control send failed and its reader was interrupted.", sendFailure, readFailure);
        }
        finally { EndOperation(); }
    }

    public async Task SendAsync(ReadOnlyMemory<byte> frame, CancellationToken cancellationToken)
    {
        if (frame.IsEmpty || frame.Length > _maximumOutboundFrameBytes)
            throw new InvalidDataException("Remote-control frame exceeds the outbound limit.");
        using var deadline = BeginOperation(cancellationToken);
        deadline.CancelAfter(_sendTimeout);
        var entered = false;
        var writeStarted = false;
        var phase = "waiting for the previous frame";
        try
        {
            await _sendGate.WaitAsync(deadline.Token).ConfigureAwait(false);
            entered = true;
            var header = new byte[4];
            BinaryPrimitives.WriteUInt32BigEndian(header, checked((uint)frame.Length));
            phase = "writing the frame prefix";
            writeStarted = true;
            await _stream.WriteAsync(header, deadline.Token).ConfigureAwait(false);
            phase = "writing the frame body";
            await _stream.WriteAsync(frame, deadline.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException failure) when (!cancellationToken.IsCancellationRequested && !_lifetime.IsCancellationRequested)
        {
            var timeout = new TimeoutException(
                $"Remote-control send timed out after {_sendTimeout.TotalSeconds:F1}s while {phase} ({frame.Length} bytes).", failure);
            if (writeStarted) Close(timeout);
            throw timeout;
        }
        catch (Exception failure)
        {
            // Once a prefix or body may have been sent, the framing boundary is
            // uncertain. Retire the exact transport instead of retrying a frame.
            // Cancellation while waiting for the writer has not touched the wire.
            if (writeStarted) Close(failure);
            throw;
        }
        finally
        {
            if (entered) _sendGate.Release();
            EndOperation();
        }
    }

    private CancellationTokenSource BeginOperation(CancellationToken cancellationToken)
    {
        lock (_stateGate)
        {
            if (_closed) throw new IOException("The remote-control transport is closed.");
            var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _lifetime.Token);
            _operations++;
            return linked;
        }
    }

    private void EndOperation()
    {
        lock (_stateGate)
        {
            _operations--;
            if (_closed && _operations == 0) _drained.TrySetResult();
        }
    }

    public void Close() => Close(null);

    private void Close(Exception? failure)
    {
        lock (_stateGate)
        {
            if (_closed) return;
            Volatile.Write(ref _terminalFailure, failure);
            _closed = true;
            _lifetime.Cancel();
            _client.Dispose();
            if (_operations == 0) _drained.TrySetResult();
        }
    }

    public async ValueTask DisposeAsync()
    {
        Close();
        await _drained.Task.ConfigureAwait(false);
        lock (_stateGate)
        {
            if (_disposed) return;
            _disposed = true;
            _sendGate.Dispose();
            _lifetime.Dispose();
        }
    }
}
