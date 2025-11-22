using System;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public sealed class DummyEngineClient : IEngineClient
{
    private readonly SemaphoreSlim _mutex = new(1, 1);
    private EngineConnectionState _state = EngineConnectionState.Disconnected;

    public EngineConnectionState State => _state;

    public event EventHandler<EngineConnectionState>? ConnectionStateChanged;

    public async Task ConnectAsync()
    {
        await _mutex.WaitAsync();
        try
        {
            if (_state != EngineConnectionState.Disconnected)
            {
                return;
            }

            SetState(EngineConnectionState.Connecting);
        }
        finally
        {
            _mutex.Release();
        }

        await Task.Delay(TimeSpan.FromMilliseconds(150));

        await _mutex.WaitAsync();
        try
        {
            SetState(EngineConnectionState.Connected);
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
            if (_state == EngineConnectionState.Disconnected)
            {
                return;
            }

            SetState(EngineConnectionState.ShuttingDown);
        }
        finally
        {
            _mutex.Release();
        }

        await Task.Delay(TimeSpan.FromMilliseconds(100));

        await _mutex.WaitAsync();
        try
        {
            SetState(EngineConnectionState.Disconnected);
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
            if (_state != EngineConnectionState.Connected)
            {
                throw new InvalidOperationException("Cannot send heartbeat when not connected.");
            }
        }
        finally
        {
            _mutex.Release();
        }

        await Task.Delay(TimeSpan.FromMilliseconds(50));
    }

    private void SetState(EngineConnectionState newState)
    {
        _state = newState;
        ConnectionStateChanged?.Invoke(this, newState);
    }
}
