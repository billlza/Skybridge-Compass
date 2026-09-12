using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface IWebRtcProductSecureSessionEstablisher
{
    Task<LiveWebRtcProductControlContext> EstablishAsync(
        LiveWebRtcProductControlContext transportContext,
        CancellationToken cancellationToken = default);
}

public sealed class WebRtcProductSecureSessionRuntimeConsumer :
    IWebRtcProductControlRuntimeConsumer,
    IWebRtcProductControlEstablishedSessionAuthority,
    IDisposable
{
    private readonly IWebRtcProductSecureSessionEstablisher _establisher;
    private readonly WebRtcProductSecureSessionStore _sessionStore;
    private readonly IReadOnlyList<IWebRtcProductControlRuntimeConsumer> _establishedConsumers;
    private readonly List<IDisposable> _pendingDependencyDisposals = new();
    private readonly object _gate = new();
    private ActiveSecureSessionRuntime? _active;
    private bool _starting;
    private bool _stopping;
    private bool _disposing;
    private bool _globalSessionStoreClearPending = true;
    private int _disposeRequested;
    private int _disposeCompleted;

    public WebRtcProductSecureSessionRuntimeConsumer(
        IWebRtcProductSecureSessionEstablisher establisher,
        WebRtcProductSecureSessionStore sessionStore,
        IReadOnlyList<IWebRtcProductControlRuntimeConsumer>? establishedConsumers = null)
    {
        _establisher = establisher ?? throw new ArgumentNullException(nameof(establisher));
        _sessionStore = sessionStore ?? throw new ArgumentNullException(nameof(sessionStore));
        _establishedConsumers = establishedConsumers ?? Array.Empty<IWebRtcProductControlRuntimeConsumer>();

        AddPendingDependencyDisposal(establisher as IDisposable);
        foreach (var consumer in _establishedConsumers)
        {
            AddPendingDependencyDisposal(consumer as IDisposable);
        }
    }

    public async Task<WebRtcProductControlRuntimeLease> StartAsync(
        LiveWebRtcProductControlContext context,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposeRequested();
        ArgumentNullException.ThrowIfNull(context);
        if (context.SecureSessionState != WebRtcProductControlSecureSessionState.TransportOnly)
        {
            throw new InvalidOperationException(
                "WebRTC product-control secure session runtime must start from a TransportOnly context.");
        }

        var lease = WebRtcProductControlRuntimeLease.Create();
        lock (_gate)
        {
            ThrowIfDisposeRequested();
            if (_starting || _stopping || _disposing || _active is not null)
            {
                throw new InvalidOperationException("WebRTC product-control secure session runtime is already active.");
            }

            _starting = true;
        }

        LiveWebRtcProductControlContext? establishedContext = null;
        var startedConsumers = new List<StartedRuntimeConsumer>();
        try
        {
            establishedContext = await _establisher
                .EstablishAsync(context, cancellationToken)
                .ConfigureAwait(false);
            ArgumentNullException.ThrowIfNull(establishedContext);
            if (establishedContext.SecureSessionState != WebRtcProductControlSecureSessionState.Established)
            {
                throw new InvalidOperationException(
                    "WebRTC product-control secure session establisher returned a non-Established context.");
            }

            if (establishedContext.SessionIncarnation is not { } sessionIncarnation)
            {
                throw new InvalidOperationException(
                    "WebRTC product-control secure session establisher returned an Established context without a session-incarnation owner.");
            }

            sessionIncarnation.RequireValid();

            foreach (var consumer in _establishedConsumers)
            {
                var consumerLease = await consumer
                    .StartAsync(establishedContext, cancellationToken)
                    .ConfigureAwait(false);
                consumerLease.RequireValid();
                startedConsumers.Add(new StartedRuntimeConsumer(consumer, consumerLease));
            }

            lock (_gate)
            {
                ThrowIfDisposeRequested();
                _active = new ActiveSecureSessionRuntime(
                    lease,
                    establishedContext,
                    startedConsumers);
                _starting = false;
            }

            return lease;
        }
        catch (Exception ex)
        {
            ActiveSecureSessionRuntime? unpublishedOwner = establishedContext is null
                ? null
                : new ActiveSecureSessionRuntime(
                    lease,
                    establishedContext,
                    startedConsumers);
            var cleanupErrors = unpublishedOwner is null
                ? new List<Exception>()
                : await unpublishedOwner
                    .StopPendingAsync(_sessionStore)
                    .ConfigureAwait(false);

            lock (_gate)
            {
                _starting = false;
                if (cleanupErrors.Count > 0 &&
                    unpublishedOwner?.HasPendingCleanup == true &&
                    _active is null)
                {
                    _active = unpublishedOwner;
                }
            }

            if (cleanupErrors.Count > 0)
            {
                cleanupErrors.Insert(0, ex);
                throw new AggregateException(
                    "WebRTC product-control secure session runtime start failed and cleanup also reported errors. Dispose the runtime to retry its retained unpublished owners.",
                    cleanupErrors);
            }

            throw;
        }
    }

    public async Task StopAsync(
        WebRtcProductControlRuntimeLease lease,
        CancellationToken cancellationToken = default)
    {
        lease.RequireValid();
        if (Volatile.Read(ref _disposeCompleted) != 0)
        {
            return;
        }

        ThrowIfDisposeRequested();
        cancellationToken.ThrowIfCancellationRequested();
        ActiveSecureSessionRuntime? active;
        lock (_gate)
        {
            if (Volatile.Read(ref _disposeCompleted) != 0)
            {
                return;
            }

            ThrowIfDisposeRequested();
            if (_active is null || _active.Lease != lease)
            {
                return;
            }

            if (_stopping || _disposing)
            {
                throw new InvalidOperationException(
                    "WebRTC product-control secure session cleanup is already in progress.");
            }

            active = _active;
            _stopping = true;
        }

        List<Exception> stopErrors;
        try
        {
            stopErrors = await active
                .StopPendingAsync(_sessionStore)
                .ConfigureAwait(false);
        }
        finally
        {
            lock (_gate)
            {
                _stopping = false;
            }
        }

        lock (_gate)
        {
            if (stopErrors.Count == 0 &&
                !active.HasPendingCleanup &&
                ReferenceEquals(_active, active))
            {
                _active = null;
            }
        }

        if (stopErrors.Count > 0)
        {
            throw new AggregateException(
                "One or more established WebRTC product-control runtime owners failed to stop.",
                stopErrors);
        }
    }

    LiveWebRtcProductControlContext IWebRtcProductControlEstablishedSessionAuthority.RequireEstablishedContext(
        WebRtcProductControlRuntimeLease lease)
    {
        ThrowIfDisposeRequested();
        lease.RequireValid();
        lock (_gate)
        {
            ThrowIfDisposeRequested();
            if (_active is null || _active.Lease != lease)
            {
                throw new InvalidOperationException(
                    "WebRTC product-control established-session authority does not own the supplied runtime lease.");
            }

            if (_active.EstablishedContext.SecureSessionState !=
                WebRtcProductControlSecureSessionState.Established)
            {
                throw new InvalidOperationException(
                    "WebRTC product-control runtime cannot publish authority for a non-Established session.");
            }

            if (_active.EstablishedContext.SessionIncarnation is not { } incarnation)
            {
                throw new InvalidOperationException(
                    "WebRTC product-control runtime cannot publish authority without an exact session incarnation.");
            }

            incarnation.RequireValid();
            return _active.EstablishedContext;
        }
    }

    public void Dispose()
    {
        if (Volatile.Read(ref _disposeCompleted) != 0)
        {
            return;
        }

        Interlocked.Exchange(ref _disposeRequested, 1);
        ActiveSecureSessionRuntime? active;
        lock (_gate)
        {
            if (Volatile.Read(ref _disposeCompleted) != 0)
            {
                return;
            }

            if (_starting || _stopping || _disposing)
            {
                throw new InvalidOperationException(
                    "WebRTC product-control secure session runtime disposal is blocked by an in-flight lifecycle operation. Retry Dispose after that operation finishes.");
            }

            _disposing = true;
            active = _active;
        }

        var cleanupErrors = new List<Exception>();
        try
        {
            if (active is not null)
            {
                try
                {
                    cleanupErrors.AddRange(
                        active.StopPendingAsync(_sessionStore).GetAwaiter().GetResult());
                }
                catch (Exception ex)
                {
                    cleanupErrors.Add(ex);
                }

                lock (_gate)
                {
                    if (cleanupErrors.Count == 0 &&
                        !active.HasPendingCleanup &&
                        ReferenceEquals(_active, active))
                    {
                        _active = null;
                    }
                }
            }

            if (cleanupErrors.Count == 0)
            {
                ClearGlobalSessionStore(cleanupErrors);
                DisposePendingDependencies(cleanupErrors);
            }

            lock (_gate)
            {
                if (cleanupErrors.Count == 0 &&
                    _active is null &&
                    !_globalSessionStoreClearPending &&
                    _pendingDependencyDisposals.Count == 0)
                {
                    Volatile.Write(ref _disposeCompleted, 1);
                }
            }
        }
        finally
        {
            lock (_gate)
            {
                _disposing = false;
            }
        }

        if (cleanupErrors.Count > 0)
        {
            throw new AggregateException(
                "WebRTC product-control secure session runtime disposal reported one or more retained cleanup owners. Retry Dispose to continue exact-owner cleanup.",
                cleanupErrors);
        }
    }

    private void ClearGlobalSessionStore(ICollection<Exception> errors)
    {
        if (!_globalSessionStoreClearPending)
        {
            return;
        }

        try
        {
            _sessionStore.ClearAllForGlobalShutdown();
            _globalSessionStoreClearPending = false;
        }
        catch (Exception ex)
        {
            errors.Add(ex);
        }
    }

    private void DisposePendingDependencies(ICollection<Exception> errors)
    {
        for (var index = _pendingDependencyDisposals.Count - 1; index >= 0; index--)
        {
            try
            {
                _pendingDependencyDisposals[index].Dispose();
                _pendingDependencyDisposals.RemoveAt(index);
            }
            catch (Exception ex)
            {
                errors.Add(ex);
            }
        }
    }

    private void AddPendingDependencyDisposal(IDisposable? dependency)
    {
        if (dependency is null)
        {
            return;
        }

        foreach (var existing in _pendingDependencyDisposals)
        {
            if (ReferenceEquals(existing, dependency))
            {
                return;
            }
        }

        _pendingDependencyDisposals.Add(dependency);
    }

    private void ThrowIfDisposeRequested()
    {
        if (Volatile.Read(ref _disposeRequested) != 0)
        {
            throw new ObjectDisposedException(nameof(WebRtcProductSecureSessionRuntimeConsumer));
        }
    }

    private sealed record StartedRuntimeConsumer(
        IWebRtcProductControlRuntimeConsumer Consumer,
        WebRtcProductControlRuntimeLease Lease);

    private sealed class ActiveSecureSessionRuntime
    {
        private readonly List<StartedRuntimeConsumer> _pendingConsumers;
        private bool _sessionStoreClearPending = true;

        public ActiveSecureSessionRuntime(
            WebRtcProductControlRuntimeLease lease,
            LiveWebRtcProductControlContext establishedContext,
            IReadOnlyCollection<StartedRuntimeConsumer> startedConsumers)
        {
            Lease = lease;
            EstablishedContext = establishedContext ?? throw new ArgumentNullException(nameof(establishedContext));
            _pendingConsumers = new List<StartedRuntimeConsumer>(startedConsumers);
        }

        public WebRtcProductControlRuntimeLease Lease { get; }

        public LiveWebRtcProductControlContext EstablishedContext { get; }

        public bool HasPendingCleanup =>
            _pendingConsumers.Count > 0 || _sessionStoreClearPending;

        public async Task<List<Exception>> StopPendingAsync(
            WebRtcProductSecureSessionStore sessionStore)
        {
            ArgumentNullException.ThrowIfNull(sessionStore);
            var errors = new List<Exception>();
            for (var index = _pendingConsumers.Count - 1; index >= 0; index--)
            {
                try
                {
                    await _pendingConsumers[index].Consumer
                        .StopAsync(_pendingConsumers[index].Lease)
                        .ConfigureAwait(false);
                    _pendingConsumers.RemoveAt(index);
                }
                catch (Exception ex)
                {
                    errors.Add(ex);
                }
            }

            if (_pendingConsumers.Count == 0 && _sessionStoreClearPending)
            {
                try
                {
                    sessionStore.Clear(EstablishedContext);
                    _sessionStoreClearPending = false;
                }
                catch (Exception ex)
                {
                    errors.Add(ex);
                }
            }

            return errors;
        }
    }
}
