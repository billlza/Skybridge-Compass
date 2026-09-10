using System;
using System.Collections.Generic;
using System.Runtime.ExceptionServices;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

/// <summary>
/// Narrow exact-owner transport boundary used by the product-control engine lifecycle.
/// Implementations retain the claimed transport until the matching lease releases it.
/// </summary>
internal interface IWebRtcProductControlEngineTransport : IAsyncDisposable
{
    Task<OwnedWebRtcProductControlContext> ClaimLiveTransportAsync(
        ConnectionLaunchRequest request);

    Task DisposeTransportAsync(WebRtcProductControlTransportLease lease);
}

internal sealed record OwnedWebRtcProductControlContext(
    WebRtcProductControlTransportLease Lease,
    LiveWebRtcProductControlContext Context);

internal readonly record struct WebRtcProductControlTransportLease
{
    private WebRtcProductControlTransportLease(Guid ownerId)
    {
        OwnerId = ownerId;
    }

    public Guid OwnerId { get; }

    public static WebRtcProductControlTransportLease Create() => new(Guid.NewGuid());

    public void RequireValid()
    {
        if (OwnerId == Guid.Empty)
        {
            throw new InvalidOperationException(
                "WebRTC product-control transport lease owner must not be empty.");
        }
    }
}

/// <summary>
/// Single-incarnation claim gate shared by the product-control provider and tests.
/// It prevents ownerless teardown or replacement of a transport claimed by an engine.
/// </summary>
internal sealed class WebRtcProductControlTransportClaim
{
    private WebRtcProductControlTransportLease? _engineLease;

    public bool IsClaimedByEngine => _engineLease is not null;

    public WebRtcProductControlTransportLease ClaimForEngine()
    {
        if (_engineLease is not null)
        {
            throw new InvalidOperationException(
                "WebRTC product-control transport is already claimed by an engine operation.");
        }

        var lease = WebRtcProductControlTransportLease.Create();
        _engineLease = lease;
        return lease;
    }

    public void RequireUnclaimedForReplacement()
    {
        if (_engineLease is not null)
        {
            throw new InvalidOperationException(
                "WebRTC product-control transport is owned by an active engine operation; disconnect it before preparing a replacement transport.");
        }
    }

    public void RequireUnclaimedForOwnerlessTeardown()
    {
        if (_engineLease is not null)
        {
            throw new InvalidOperationException(
                "WebRTC product-control transport is owned by an active engine operation; only its exact lease may release it.");
        }
    }

    public bool IsOwnedBy(WebRtcProductControlTransportLease lease) =>
        _engineLease == lease;
}

/// <summary>
/// Serializes product-control engine lifecycle operations. The wrapper publishes
/// Connected only after the raw transport, inner engine, every runtime consumer,
/// and one exact Established secure-session authority all agree on the same binding.
/// </summary>
public sealed partial class WebRtcProductControlEngineClient : IEngineClient, IDisposable
{
    private readonly IEngineClient _inner;
    private readonly IWebRtcProductControlEngineTransport _transportAdapter;
    private readonly IReadOnlyList<IWebRtcProductControlRuntimeConsumer> _runtimeConsumers;
    private readonly SemaphoreSlim _lifecycleMutex = new(1, 1);
    private ActiveRuntime? _activeRuntime;
    private bool _lifecycleFaulted;
    private int _state = (int)EngineConnectionState.Disconnected;
    private int _disposeRequested;
    private int _disposeCompleted;

    internal WebRtcProductControlEngineClient(
        IEngineClient inner,
        IWebRtcProductControlEngineTransport transportAdapter,
        IReadOnlyList<IWebRtcProductControlRuntimeConsumer>? runtimeConsumers = null)
    {
        _inner = inner ?? throw new ArgumentNullException(nameof(inner));
        _transportAdapter = transportAdapter ?? throw new ArgumentNullException(nameof(transportAdapter));
        _runtimeConsumers = runtimeConsumers ?? Array.Empty<IWebRtcProductControlRuntimeConsumer>();
    }

    public EngineConnectionState State =>
        (EngineConnectionState)Volatile.Read(ref _state);

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
                    "WebRTC product-control engine already owns an active runtime. Disconnect it before reconnecting.");
            }

            var operationOwner = EngineLifecycleOperationOwner.Create();
            var startedConsumers = new List<StartedRuntimeConsumer>();
            OwnedWebRtcProductControlContext? ownedTransport = null;
            try
            {
                PublishState(EngineConnectionState.Connecting);
                ownedTransport = await _transportAdapter
                    .ClaimLiveTransportAsync(request)
                    .ConfigureAwait(false);
                ArgumentNullException.ThrowIfNull(ownedTransport);
                ownedTransport.Lease.RequireValid();
                RequireTransportOnlyContext(ownedTransport.Context);

                await _inner.ConnectAsync(request).ConfigureAwait(false);
                foreach (var consumer in _runtimeConsumers)
                {
                    var lease = await consumer
                        .StartAsync(ownedTransport.Context)
                        .ConfigureAwait(false);
                    lease.RequireValid();
                    startedConsumers.Add(new StartedRuntimeConsumer(operationOwner, consumer, lease));
                }

                ThrowIfDisposeRequested();
                var establishedContext = RequireEstablishedAuthority(
                    ownedTransport.Context,
                    startedConsumers);
                if (_inner.State != EngineConnectionState.Connected)
                {
                    throw new InvalidOperationException(
                        $"WebRTC product-control inner engine did not finish Connected; observed {_inner.State} after secure-session establishment.");
                }

                _activeRuntime = new ActiveRuntime(
                    operationOwner,
                    ownedTransport.Lease,
                    establishedContext,
                    startedConsumers.ToArray());
                PublishState(EngineConnectionState.Connected);
            }
            catch (Exception ex)
            {
                var cleanupErrors = await StopStartedConsumersAsync(
                        operationOwner,
                        startedConsumers)
                    .ConfigureAwait(false);
                await CaptureCleanupErrorAsync(_inner.DisconnectAsync, cleanupErrors).ConfigureAwait(false);
                if (ownedTransport is not null)
                {
                    await CaptureCleanupErrorAsync(
                            () => _transportAdapter.DisposeTransportAsync(ownedTransport.Lease),
                            cleanupErrors)
                        .ConfigureAwait(false);
                }

                if (cleanupErrors.Count > 0)
                {
                    _lifecycleFaulted = true;
                    if (ownedTransport is not null)
                    {
                        _activeRuntime = new ActiveRuntime(
                            operationOwner,
                            ownedTransport.Lease,
                            EstablishedContext: null,
                            startedConsumers.ToArray());
                    }

                    PublishState(EngineConnectionState.ShuttingDown);
                    cleanupErrors.Insert(0, ex);
                    throw new AggregateException(
                        "WebRTC product-control engine connect failed and cleanup also reported errors.",
                        cleanupErrors);
                }

                _activeRuntime = null;
                _lifecycleFaulted = false;
                PublishState(EngineConnectionState.Disconnected);
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
                if (!_lifecycleFaulted)
                {
                    PublishState(EngineConnectionState.Disconnected);
                    return;
                }

                PublishState(EngineConnectionState.ShuttingDown);
                var recoveryErrors = new List<Exception>();
                await CaptureCleanupErrorAsync(_inner.DisconnectAsync, recoveryErrors).ConfigureAwait(false);
                if (recoveryErrors.Count == 0)
                {
                    _lifecycleFaulted = false;
                    PublishState(EngineConnectionState.Disconnected);
                }

                ThrowIfCleanupFailed(
                    "WebRTC product-control engine recovery disconnect reported one or more cleanup errors.",
                    recoveryErrors);
                return;
            }

            PublishState(EngineConnectionState.ShuttingDown);
            var cleanupErrors = await StopStartedConsumersAsync(
                    activeRuntime.OperationOwner,
                    activeRuntime.StartedConsumers)
                .ConfigureAwait(false);
            await CaptureCleanupErrorAsync(_inner.DisconnectAsync, cleanupErrors).ConfigureAwait(false);
            await CaptureCleanupErrorAsync(
                    () => _transportAdapter.DisposeTransportAsync(activeRuntime.TransportLease),
                    cleanupErrors)
                .ConfigureAwait(false);
            if (cleanupErrors.Count > 0)
            {
                _lifecycleFaulted = true;
            }
            else
            {
                _activeRuntime = null;
                _lifecycleFaulted = false;
                PublishState(EngineConnectionState.Disconnected);
            }

            ThrowIfCleanupFailed(
                "WebRTC product-control engine disconnect reported one or more cleanup errors.",
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
            if (_activeRuntime?.EstablishedContext is null)
            {
                throw new InvalidOperationException(
                    "WebRTC product-control heartbeat requires an active Established session authority.");
            }

            await _inner.SendHeartbeatAsync().ConfigureAwait(false);
            switch (_inner.State)
            {
                case EngineConnectionState.Connected:
                case EngineConnectionState.Reconnecting:
                    PublishState(_inner.State);
                    break;
                default:
                    PublishState(_inner.State);
                    throw new InvalidOperationException(
                        $"WebRTC product-control heartbeat completed while the inner engine reported {_inner.State}.");
            }
        }
        finally
        {
            _lifecycleMutex.Release();
        }
    }

    public void Dispose()
    {
        if (Volatile.Read(ref _disposeCompleted) != 0)
        {
            return;
        }

        Interlocked.Exchange(ref _disposeRequested, 1);
        _lifecycleMutex.Wait();
        try
        {
            if (Volatile.Read(ref _disposeCompleted) != 0)
            {
                return;
            }

            PublishState(EngineConnectionState.ShuttingDown);
            var activeRuntime = _activeRuntime;
            var cleanupErrors = activeRuntime is null
                ? new List<Exception>()
                : StopStartedConsumersAsync(
                        activeRuntime.OperationOwner,
                        activeRuntime.StartedConsumers)
                    .GetAwaiter()
                    .GetResult();

            if (activeRuntime is not null || _lifecycleFaulted)
            {
                CaptureCleanupError(
                    () => _inner.DisconnectAsync().GetAwaiter().GetResult(),
                    cleanupErrors);
            }

            if (activeRuntime is not null)
            {
                CaptureCleanupError(
                    () => _transportAdapter
                        .DisposeTransportAsync(activeRuntime.TransportLease)
                        .GetAwaiter()
                        .GetResult(),
                    cleanupErrors);
            }

            if (_inner is IDisposable disposable)
            {
                CaptureCleanupError(disposable.Dispose, cleanupErrors);
            }

            CaptureCleanupError(
                () => _transportAdapter.DisposeAsync().AsTask().GetAwaiter().GetResult(),
                cleanupErrors);
            foreach (var consumer in _runtimeConsumers)
            {
                if (consumer is IDisposable disposableConsumer)
                {
                    CaptureCleanupError(disposableConsumer.Dispose, cleanupErrors);
                }
            }

            if (cleanupErrors.Count == 0)
            {
                _activeRuntime = null;
                _lifecycleFaulted = false;
                PublishState(EngineConnectionState.Disconnected);
                ConnectionStateChanged = null;
                Volatile.Write(ref _disposeCompleted, 1);
            }

            ThrowIfCleanupFailed(
                "WebRTC product-control engine disposal reported one or more cleanup errors.",
                cleanupErrors);
        }
        finally
        {
            _lifecycleMutex.Release();
        }
    }

    private void ThrowIfDisposeRequested()
    {
        if (Volatile.Read(ref _disposeRequested) != 0)
        {
            throw new ObjectDisposedException(nameof(WebRtcProductControlEngineClient));
        }
    }

    private void ThrowIfLifecycleFaulted()
    {
        if (_lifecycleFaulted)
        {
            throw new InvalidOperationException(
                "WebRTC product-control engine has unresolved cleanup ownership. Disconnect again to retry cleanup or dispose the engine before reconnecting.");
        }
    }

    private void PublishState(EngineConnectionState state)
    {
        var previous = (EngineConnectionState)Interlocked.Exchange(ref _state, (int)state);
        if (previous != state)
        {
            ConnectionStateChanged?.Invoke(this, state);
        }
    }

    private static void RequireTransportOnlyContext(LiveWebRtcProductControlContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        if (context.SecureSessionState != WebRtcProductControlSecureSessionState.TransportOnly)
        {
            throw new InvalidOperationException(
                "WebRTC product-control engine must claim a raw TransportOnly context before product session establishment.");
        }

        if (context.SessionIncarnation is not null)
        {
            throw new InvalidOperationException(
                "WebRTC product-control TransportOnly context must not carry a secure-session incarnation.");
        }
    }

    private static LiveWebRtcProductControlContext RequireEstablishedAuthority(
        LiveWebRtcProductControlContext transportContext,
        IReadOnlyList<StartedRuntimeConsumer> startedConsumers)
    {
        StartedRuntimeConsumer? authorityOwner = null;
        foreach (var started in startedConsumers)
        {
            if (started.Consumer is not IWebRtcProductControlEstablishedSessionAuthority)
            {
                continue;
            }

            if (authorityOwner is not null)
            {
                throw new InvalidOperationException(
                    "WebRTC product-control engine found multiple Established session authorities; refusing ambiguous product ownership.");
            }

            authorityOwner = started;
        }

        if (authorityOwner is null ||
            authorityOwner.Consumer is not IWebRtcProductControlEstablishedSessionAuthority authority)
        {
            throw new InvalidOperationException(
                "WebRTC product-control runtime consumers did not publish an Established secure-session authority.");
        }

        var establishedContext = authority.RequireEstablishedContext(authorityOwner.Lease);
        ValidateEstablishedContextMatchesTransport(transportContext, establishedContext);
        return establishedContext;
    }

    private static void ValidateEstablishedContextMatchesTransport(
        LiveWebRtcProductControlContext transportContext,
        LiveWebRtcProductControlContext establishedContext)
    {
        ArgumentNullException.ThrowIfNull(establishedContext);
        if (establishedContext.SecureSessionState != WebRtcProductControlSecureSessionState.Established)
        {
            throw new InvalidOperationException(
                "WebRTC product-control authority returned a non-Established context.");
        }

        if (establishedContext.SessionIncarnation is not { } incarnation)
        {
            throw new InvalidOperationException(
                "WebRTC product-control Established authority is missing its exact session incarnation.");
        }

        incarnation.RequireValid();
        if (!ReferenceEquals(transportContext.ControlPlane, establishedContext.ControlPlane) ||
            !string.Equals(transportContext.PeerDeviceId, establishedContext.PeerDeviceId, StringComparison.Ordinal) ||
            !string.Equals(transportContext.PeerPublicKeyFingerprint, establishedContext.PeerPublicKeyFingerprint, StringComparison.Ordinal) ||
            !string.Equals(transportContext.Role, establishedContext.Role, StringComparison.Ordinal) ||
            !string.Equals(transportContext.TransportProfile, establishedContext.TransportProfile, StringComparison.Ordinal) ||
            !string.Equals(transportContext.DataChannelLabel, establishedContext.DataChannelLabel, StringComparison.Ordinal) ||
            !string.Equals(transportContext.AdapterBinding, establishedContext.AdapterBinding, StringComparison.Ordinal) ||
            !string.Equals(transportContext.LocalEndpoint, establishedContext.LocalEndpoint, StringComparison.Ordinal) ||
            !string.Equals(transportContext.RemoteEndpoint, establishedContext.RemoteEndpoint, StringComparison.Ordinal) ||
            !string.Equals(transportContext.SelectedCandidatePair, establishedContext.SelectedCandidatePair, StringComparison.Ordinal) ||
            transportContext.LateRemoteIceCandidateRelayCount != establishedContext.LateRemoteIceCandidateRelayCount ||
            !string.Equals(transportContext.TransportBindingDigestHex, establishedContext.TransportBindingDigestHex, StringComparison.Ordinal) ||
            transportContext.TimestampWindowMs != establishedContext.TimestampWindowMs)
        {
            throw new InvalidOperationException(
                "WebRTC product-control Established authority does not match the exact claimed transport binding.");
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
                    "Refusing to stop a WebRTC product-control runtime consumer owned by a different connect operation."));
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
        WebRtcProductControlTransportLease TransportLease,
        LiveWebRtcProductControlContext? EstablishedContext,
        IReadOnlyList<StartedRuntimeConsumer> StartedConsumers);

    private sealed record StartedRuntimeConsumer(
        EngineLifecycleOperationOwner OperationOwner,
        IWebRtcProductControlRuntimeConsumer Consumer,
        WebRtcProductControlRuntimeLease Lease);

    private readonly record struct EngineLifecycleOperationOwner(Guid Value)
    {
        public static EngineLifecycleOperationOwner Create() => new(Guid.NewGuid());
    }
}
