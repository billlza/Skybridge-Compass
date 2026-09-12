using System;
using System.Collections.Generic;
using System.Runtime.ExceptionServices;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

/// <summary>
/// Narrow transport boundary used by the WebRTC session engine lifecycle.
/// Implementations own the live session context and its asynchronous teardown.
/// </summary>
internal interface IWebRtcSessionEngineTransport : IAsyncDisposable
{
    Task<OwnedWebRtcSessionContext> ClaimLiveSessionAsync(ConnectionLaunchRequest request);

    Task DisposeSessionAsync(WebRtcSessionTransportLease lease);
}

internal sealed record OwnedWebRtcSessionContext(
    WebRtcSessionTransportLease Lease,
    LiveWebRtcSessionContext Context);

internal readonly record struct WebRtcSessionTransportLease
{
    private WebRtcSessionTransportLease(Guid ownerId)
    {
        OwnerId = ownerId;
    }

    public Guid OwnerId { get; }

    public static WebRtcSessionTransportLease Create() => new(Guid.NewGuid());

    public void RequireValid()
    {
        if (OwnerId == Guid.Empty)
        {
            throw new InvalidOperationException(
                "WebRTC session transport lease owner must not be empty.");
        }
    }
}

/// <summary>
/// Serializes WebRTC session engine lifecycle operations and binds every started
/// runtime consumer to the exact successful connect operation that owns it.
/// </summary>
public sealed partial class WebRtcSessionEngineClient : IEngineClient, IDisposable
{
    private readonly IEngineClient _inner;
    private readonly IWebRtcSessionEngineTransport _sessionTransport;
    private readonly IReadOnlyList<IWebRtcSessionRuntimeConsumer> _runtimeConsumers;
    private readonly SemaphoreSlim _lifecycleMutex = new(1, 1);
    private ActiveRuntime? _activeRuntime;
    private bool _lifecycleFaulted;
    private int _disposeRequested;

    internal WebRtcSessionEngineClient(
        IEngineClient inner,
        IWebRtcSessionEngineTransport sessionTransport,
        IReadOnlyList<IWebRtcSessionRuntimeConsumer>? runtimeConsumers = null)
    {
        _inner = inner ?? throw new ArgumentNullException(nameof(inner));
        _sessionTransport = sessionTransport ?? throw new ArgumentNullException(nameof(sessionTransport));
        _runtimeConsumers = runtimeConsumers ?? Array.Empty<IWebRtcSessionRuntimeConsumer>();
        _inner.ConnectionStateChanged += OnInnerConnectionStateChanged;
    }

    public EngineConnectionState State => _inner.State;

    public event EventHandler<EngineConnectionState>? ConnectionStateChanged;

    public async Task ConnectAsync(ConnectionLaunchRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        ThrowIfDisposeRequested();
        await _lifecycleMutex.WaitAsync().ConfigureAwait(false);
        try
        {
            ThrowIfDisposeRequested();
            ThrowIfLifecycleFaulted();
            if (_activeRuntime is not null)
            {
                throw new InvalidOperationException(
                    "WebRTC session engine already owns an active runtime. Disconnect it before reconnecting.");
            }

            var operationOwner = EngineLifecycleOperationOwner.Create();
            var startedConsumers = new List<StartedRuntimeConsumer>();
            OwnedWebRtcSessionContext? ownedSession = null;
            try
            {
                ownedSession = await _sessionTransport
                    .ClaimLiveSessionAsync(request)
                    .ConfigureAwait(false);
                ownedSession.Lease.RequireValid();
                await _inner.ConnectAsync(request).ConfigureAwait(false);
                foreach (var consumer in _runtimeConsumers)
                {
                    var lease = await consumer
                        .StartAsync(ownedSession.Context, request)
                        .ConfigureAwait(false);
                    lease.RequireValid();
                    startedConsumers.Add(new StartedRuntimeConsumer(operationOwner, consumer, lease));
                }

                ThrowIfDisposeRequested();
                _activeRuntime = new ActiveRuntime(
                    operationOwner,
                    ownedSession.Lease,
                    startedConsumers.ToArray());
            }
            catch (Exception ex)
            {
                var cleanupErrors = await StopStartedConsumersAsync(operationOwner, startedConsumers).ConfigureAwait(false);
                await CaptureCleanupErrorAsync(_inner.DisconnectAsync, cleanupErrors).ConfigureAwait(false);
                if (ownedSession is not null)
                {
                    await CaptureCleanupErrorAsync(
                            () => _sessionTransport.DisposeSessionAsync(ownedSession.Lease),
                            cleanupErrors)
                        .ConfigureAwait(false);
                }

                if (cleanupErrors.Count > 0)
                {
                    _lifecycleFaulted = true;
                    if (ownedSession is not null)
                    {
                        _activeRuntime = new ActiveRuntime(
                            operationOwner,
                            ownedSession.Lease,
                            startedConsumers.ToArray());
                    }

                    cleanupErrors.Insert(0, ex);
                    throw new AggregateException(
                        "WebRTC session engine connect failed and cleanup also reported errors.",
                        cleanupErrors);
                }

                ExceptionDispatchInfo.Capture(ex).Throw();
                throw;
            }
        }
        finally
        {
            _lifecycleMutex.Release();
        }
    }

    public async Task DisconnectAsync()
    {
        ThrowIfDisposeRequested();
        await _lifecycleMutex.WaitAsync().ConfigureAwait(false);
        try
        {
            ThrowIfDisposeRequested();
            var activeRuntime = _activeRuntime;
            if (activeRuntime is null)
            {
                if (_lifecycleFaulted)
                {
                    var recoveryErrors = new List<Exception>();
                    await CaptureCleanupErrorAsync(_inner.DisconnectAsync, recoveryErrors).ConfigureAwait(false);
                    ThrowIfCleanupFailed(
                        "WebRTC session engine recovery disconnect reported one or more cleanup errors.",
                        recoveryErrors);
                    _lifecycleFaulted = false;
                }

                return;
            }

            _activeRuntime = null;
            var cleanupErrors = await StopStartedConsumersAsync(
                    activeRuntime.OperationOwner,
                    activeRuntime.StartedConsumers)
                .ConfigureAwait(false);
            await CaptureCleanupErrorAsync(_inner.DisconnectAsync, cleanupErrors).ConfigureAwait(false);
            await CaptureCleanupErrorAsync(
                    () => _sessionTransport.DisposeSessionAsync(activeRuntime.TransportLease),
                    cleanupErrors)
                .ConfigureAwait(false);
            if (cleanupErrors.Count > 0)
            {
                _activeRuntime = activeRuntime;
                _lifecycleFaulted = true;
            }
            else
            {
                _lifecycleFaulted = false;
            }

            ThrowIfCleanupFailed(
                "WebRTC session engine disconnect reported one or more cleanup errors.",
                cleanupErrors);
        }
        finally
        {
            _lifecycleMutex.Release();
        }
    }

    public async Task SendHeartbeatAsync()
    {
        ThrowIfDisposeRequested();
        await _lifecycleMutex.WaitAsync().ConfigureAwait(false);
        try
        {
            ThrowIfDisposeRequested();
            ThrowIfLifecycleFaulted();
            await _inner.SendHeartbeatAsync().ConfigureAwait(false);
        }
        finally
        {
            _lifecycleMutex.Release();
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposeRequested, 1) != 0)
        {
            return;
        }

        _lifecycleMutex.Wait();
        try
        {
            _inner.ConnectionStateChanged -= OnInnerConnectionStateChanged;
            var activeRuntime = _activeRuntime;
            _activeRuntime = null;
            var cleanupErrors = activeRuntime is null
                ? new List<Exception>()
                : StopStartedConsumersAsync(
                        activeRuntime.OperationOwner,
                        activeRuntime.StartedConsumers)
                    .GetAwaiter()
                    .GetResult();

            if (_inner is IDisposable disposable)
            {
                CaptureCleanupError(disposable.Dispose, cleanupErrors);
            }

            CaptureCleanupError(
                () => _sessionTransport.DisposeAsync().AsTask().GetAwaiter().GetResult(),
                cleanupErrors);
            foreach (var consumer in _runtimeConsumers)
            {
                if (consumer is IDisposable disposableConsumer)
                {
                    CaptureCleanupError(disposableConsumer.Dispose, cleanupErrors);
                }
            }

            ThrowIfCleanupFailed(
                "WebRTC session engine disposal reported one or more cleanup errors.",
                cleanupErrors);
        }
        finally
        {
            _lifecycleMutex.Release();
        }
    }

    private void OnInnerConnectionStateChanged(object? sender, EngineConnectionState state) =>
        ConnectionStateChanged?.Invoke(this, state);

    private void ThrowIfDisposeRequested()
    {
        if (Volatile.Read(ref _disposeRequested) != 0)
        {
            throw new ObjectDisposedException(nameof(WebRtcSessionEngineClient));
        }
    }

    private void ThrowIfLifecycleFaulted()
    {
        if (_lifecycleFaulted)
        {
            throw new InvalidOperationException(
                "WebRTC session engine has unresolved cleanup ownership. Disconnect again to retry cleanup or dispose the engine before reconnecting.");
        }
    }

    private static async Task<List<Exception>> StopStartedConsumersAsync(
        EngineLifecycleOperationOwner operationOwner,
        IReadOnlyList<StartedRuntimeConsumer> startedConsumers)
    {
        var errors = new List<Exception>();
        for (var index = startedConsumers.Count - 1; index >= 0; index--)
        {
            if (startedConsumers[index].OperationOwner != operationOwner)
            {
                errors.Add(new InvalidOperationException(
                    "Refusing to stop a WebRTC session runtime consumer owned by a different connect operation."));
                continue;
            }

            try
            {
                await startedConsumers[index].Consumer
                    .StopAsync(startedConsumers[index].Lease)
                    .ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                errors.Add(ex);
            }
        }

        return errors;
    }

    private static async Task CaptureCleanupErrorAsync(
        Func<Task> cleanup,
        ICollection<Exception> errors)
    {
        try
        {
            await cleanup().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            errors.Add(ex);
        }
    }

    private static void CaptureCleanupError(Action cleanup, ICollection<Exception> errors)
    {
        try
        {
            cleanup();
        }
        catch (Exception ex)
        {
            errors.Add(ex);
        }
    }

    private static void ThrowIfCleanupFailed(string message, IReadOnlyCollection<Exception> errors)
    {
        if (errors.Count > 0)
        {
            throw new AggregateException(message, errors);
        }
    }

    private sealed record ActiveRuntime(
        EngineLifecycleOperationOwner OperationOwner,
        WebRtcSessionTransportLease TransportLease,
        IReadOnlyList<StartedRuntimeConsumer> StartedConsumers);

    private sealed record StartedRuntimeConsumer(
        EngineLifecycleOperationOwner OperationOwner,
        IWebRtcSessionRuntimeConsumer Consumer,
        WebRtcSessionRuntimeLease Lease);

    private readonly record struct EngineLifecycleOperationOwner(Guid Value)
    {
        public static EngineLifecycleOperationOwner Create() => new(Guid.NewGuid());
    }
}
