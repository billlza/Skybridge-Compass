namespace Skybridge.WinClient.Services.RemoteControl;

internal enum RemoteControlHostSessionPhase { Authenticating, AwaitingApproval, Preparing, Viewing, Controlling, Disconnecting, Failed }

internal sealed record RemoteControlHostSessionStatus(
    Guid Id, string DeviceName, string DeviceId, RemoteControlHostSessionPhase Phase,
    bool SupportsSharedAccess, string Error = "", long FramesSent = 0, long AudioPacketsSent = 0);

internal sealed record RemoteControlHostAccessOperations(
    Func<CancellationToken, Task> ReleaseInput,
    Func<RemoteControlAccess, CancellationToken, Task> PublishAccess);

internal sealed class RemoteControlHostCapacityException()
    : InvalidOperationException("Two controller connections already occupy this desktop. Disconnect one before connecting another.");

/// <summary>One bounded admission and input authority for the shared Windows desktop.</summary>
internal sealed class RemoteControlHostAccessCoordinator
{
    internal const int ConcurrentSessionLimit = 2;
    private sealed class Entry(Guid id, Action disconnect)
    {
        internal readonly Guid Id = id;
        internal readonly Action Disconnect = disconnect;
        internal readonly TaskCompletionSource Approval = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal RemoteControlHostSessionStatus Status = new(id, "", "", RemoteControlHostSessionPhase.Authenticating, false);
        internal bool? Managed;
        internal RemoteControlHostAccessOperations? Operations;
        internal RemoteControlAccess? Access;
    }

    private readonly object _gate = new();
    private readonly SemaphoreSlim _transitions = new(1, 1);
    private int _handoffInProgress;
    private readonly Dictionary<Guid, Entry> _entries = [];
    private Guid? _inputOwner;
    private readonly HashSet<Guid> _releaseBlockedOwners = [];
    public event Action<IReadOnlyList<RemoteControlHostSessionStatus>>? Changed;

    internal IReadOnlyList<RemoteControlHostSessionStatus> Snapshot
    {
        get { lock (_gate) return _entries.Values.Select(entry => entry.Status).ToArray(); }
    }

    internal Guid Reserve(Action disconnect)
    {
        ArgumentNullException.ThrowIfNull(disconnect);
        Guid id;
        lock (_gate)
        {
            if (_entries.Count >= ConcurrentSessionLimit)
                throw new RemoteControlHostCapacityException();
            id = Guid.NewGuid();
            _entries.Add(id, new Entry(id, disconnect));
        }
        PublishSnapshot();
        return id;
    }

    internal void Authenticate(Guid id, string deviceId, string deviceName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(deviceId);
        ArgumentException.ThrowIfNullOrWhiteSpace(deviceName);
        lock (_gate)
        {
            var entry = Require(id);
            if (entry.Status.Phase != RemoteControlHostSessionPhase.Authenticating)
                throw new InvalidOperationException("The session identity is already bound.");
            entry.Status = entry.Status with { DeviceId = deviceId, DeviceName = deviceName };
        }
        PublishSnapshot();
    }

    internal async Task RequestApprovalAsync(Guid id, bool managed, RemoteControlHostAccessOperations operations, CancellationToken cancellationToken)
    {
        Entry entry;
        lock (_gate)
        {
            entry = Require(id);
            if (entry.Managed is { } existing)
            {
                if (existing != managed) throw new InvalidDataException("Remote-control access negotiation cannot change within a session.");
            }
            else
            {
                if (entry.Status.DeviceId.Length == 0) throw new InvalidOperationException("Controller approval requires an authenticated identity.");
                if (_entries.Values.Any(other => other.Id != id && other.Managed is { } otherManaged && (!managed || !otherManaged)))
                    throw new NotSupportedException("A legacy controller requires exclusive desktop access. Disconnect the other session first.");
                entry.Managed = managed;
                entry.Operations = operations;
                entry.Status = entry.Status with { Phase = RemoteControlHostSessionPhase.AwaitingApproval, SupportsSharedAccess = managed };
            }
        }
        PublishSnapshot();
        await entry.Approval.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
    }

    internal async Task ApproveAsync(Guid id, bool allowInput, CancellationToken cancellationToken)
    {
        await BeginHandoffAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            Entry target;
            Entry? previous;
            lock (_gate)
            {
                target = Require(id);
                if (target.Status.Phase != RemoteControlHostSessionPhase.AwaitingApproval)
                    throw new InvalidOperationException("This exact session is no longer awaiting approval.");
                if (target.Managed == false && !allowInput)
                    throw new NotSupportedException("This legacy controller cannot present a viewing-only session.");
                previous = allowInput ? ResolveInputOwner() : null;
                if (previous?.Status.Phase == RemoteControlHostSessionPhase.Preparing)
                    throw new InvalidOperationException("Wait for the current controller's initial stream to finish preparing.");
            }
            if (allowInput) await RevokePreviousInputAsync(previous, cancellationToken).ConfigureAwait(false);
            lock (_gate)
            {
                RequireCurrent(target);
                if (allowInput && _releaseBlockedOwners.Count > 0) throw new InvalidOperationException("An earlier controller's input release still requires cleanup.");
                target.Access = NextAccess(target, allowInput);
                if (allowInput) _inputOwner = id;
                target.Status = target.Status with { Phase = RemoteControlHostSessionPhase.Preparing };
                target.Approval.TrySetResult();
            }
            PublishSnapshot();
        }
        finally { FinishHandoff(); }
    }

    internal async Task TransferInputAsync(Guid id, CancellationToken cancellationToken)
    {
        await BeginHandoffAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            Entry target;
            Entry? previous;
            lock (_gate)
            {
                target = Require(id);
                if (target.Managed != true || target.Status.Phase != RemoteControlHostSessionPhase.Viewing)
                    throw new InvalidOperationException("Only an approved viewing session can receive input control.");
                previous = ResolveInputOwner();
                if (previous?.Status.Phase == RemoteControlHostSessionPhase.Preparing)
                    throw new InvalidOperationException("Wait for the initial desktop stream to finish preparing.");
            }
            await RevokePreviousInputAsync(previous, cancellationToken).ConfigureAwait(false);
            RemoteControlAccess grant;
            lock (_gate)
            {
                RequireCurrent(target);
                grant = NextAccess(target, true);
            }
            await PublishAccessAsync(target, grant, cancellationToken).ConfigureAwait(false);
            lock (_gate)
            {
                RequireCurrent(target);
                if (_releaseBlockedOwners.Count > 0) throw new InvalidOperationException("Input cleanup is still pending.");
                target.Access = grant;
                _inputOwner = id;
                target.Status = target.Status with { Phase = RemoteControlHostSessionPhase.Controlling };
            }
            PublishSnapshot();
        }
        finally { FinishHandoff(); }
    }

    private async Task BeginHandoffAsync(CancellationToken cancellationToken)
    {
        // Ordinary HID commits share the barrier but do not own a handoff.
        // Retiring a participant must not clear this transaction before cleanup.
        if (Interlocked.CompareExchange(ref _handoffInProgress, 1, 0) != 0)
            throw new InvalidOperationException("An input handoff is already in progress.");
        try
        {
            if (!await _transitions.WaitAsync(TimeSpan.FromSeconds(5), cancellationToken).ConfigureAwait(false))
                throw new TimeoutException("The current desktop input operation did not finish within five seconds.");
        }
        catch
        {
            Volatile.Write(ref _handoffInProgress, 0);
            throw;
        }
    }

    private void FinishHandoff()
    {
        _transitions.Release();
        Volatile.Write(ref _handoffInProgress, 0);
    }

    private async Task RevokePreviousInputAsync(Entry? previous, CancellationToken cancellationToken)
    {
        RemoteControlAccess revocation;
        lock (_gate)
        {
            if (_releaseBlockedOwners.Count > 0) throw new InvalidOperationException("Restore the desktop and finish pending input cleanup before transferring control.");
            if (previous is null) return;
            RequireCurrent(previous);
            _inputOwner = null;
            _releaseBlockedOwners.Add(previous.Id);
            revocation = NextAccess(previous, false);
            previous.Access = revocation;
            previous.Status = previous.Status with { Phase = RemoteControlHostSessionPhase.Viewing };
        }
        PublishSnapshot();
        await RequireOperations(previous).ReleaseInput(cancellationToken).ConfigureAwait(false);
        lock (_gate)
        {
            _releaseBlockedOwners.Remove(previous.Id);
            RequireCurrent(previous);
        }
        if (previous.Managed == true)
            await PublishAccessAsync(previous, revocation, cancellationToken).ConfigureAwait(false);
    }

    private async Task PublishAccessAsync(Entry entry, RemoteControlAccess access, CancellationToken cancellationToken)
    {
        try { await RequireOperations(entry).PublishAccess(access, cancellationToken).ConfigureAwait(false); }
        catch (Exception failure)
        {
            // Delivery may have completed before its await failed. This exact
            // incarnation cannot safely retry the same revision with a new lease.
            Action? disconnect;
            lock (_gate)
            {
                disconnect = _entries.TryGetValue(entry.Id, out var current) && ReferenceEquals(current, entry)
                    ? PrepareDisconnect(entry, "Control access delivery failed. " + failure.Message) : null;
            }
            try { disconnect?.Invoke(); }
            catch (Exception cleanupFailure)
            {
                throw new AggregateException("Control access delivery and session disconnection both failed.", failure, cleanupFailure);
            }
            finally { PublishSnapshot(); }
            throw;
        }
    }

    internal RemoteControlAccess? AccessForReceipt(Guid id)
    {
        lock (_gate)
        {
            var entry = Require(id);
            if (entry.Access is null) throw new InvalidOperationException("The controller has not been approved.");
            return entry.Managed == true ? entry.Access : null;
        }
    }

    internal async Task<bool> ApplyInputAsync(Guid id, Guid? lease, Action apply, CancellationToken cancellationToken)
    {
        // A receipt can reach the viewer before its send await resumes locally.
        // Keep received input behind the same handoff barrier until grant commit.
        await _transitions.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            lock (_gate)
            {
                var entry = Require(id);
                if (_inputOwner != id || _releaseBlockedOwners.Count > 0 ||
                    entry.Status.Phase != RemoteControlHostSessionPhase.Controlling || entry.Access?.AllowsInput != true ||
                    (entry.Managed == true ? entry.Access.Lease != lease : lease is not null)) return false;
                apply();
                return true;
            }
        }
        finally { _transitions.Release(); }
    }

    internal void MarkReady(Guid id)
    {
        lock (_gate)
        {
            var entry = Require(id);
            entry.Status = entry.Status with { Phase = _inputOwner == id ? RemoteControlHostSessionPhase.Controlling : RemoteControlHostSessionPhase.Viewing };
        }
        PublishSnapshot();
    }

    internal void ReportCounters(Guid id, long frames, long audio)
    {
        lock (_gate)
        {
            if (!_entries.TryGetValue(id, out var entry)) return;
            entry.Status = entry.Status with { FramesSent = frames, AudioPacketsSent = audio };
        }
        PublishSnapshot();
    }

    internal void Disconnect(Guid id)
    {
        Action? disconnect;
        lock (_gate) disconnect = PrepareDisconnect(Require(id));
        disconnect?.Invoke();
        PublishSnapshot();
    }

    private Action? PrepareDisconnect(Entry entry, string error = "")
    {
        if (entry.Status.Phase is RemoteControlHostSessionPhase.Disconnecting or RemoteControlHostSessionPhase.Failed) return null;
        if (_inputOwner == entry.Id) { _inputOwner = null; _releaseBlockedOwners.Add(entry.Id); }
        entry.Status = entry.Status with { Phase = RemoteControlHostSessionPhase.Disconnecting, Error = error };
        entry.Approval.TrySetCanceled();
        return entry.Disconnect;
    }

    internal void Retire(Guid id, Exception? cleanupFailure = null)
    {
        lock (_gate)
        {
            if (!_entries.TryGetValue(id, out var entry)) return;
            if (_inputOwner == id) _inputOwner = null;
            entry.Approval.TrySetCanceled();
            if (cleanupFailure is null)
            {
                _entries.Remove(id);
                _releaseBlockedOwners.Remove(id);
            }
            else
            {
                _releaseBlockedOwners.Add(id);
                entry.Status = entry.Status with { Phase = RemoteControlHostSessionPhase.Failed, Error = cleanupFailure.Message };
            }
        }
        PublishSnapshot();
    }

    private Entry? ResolveInputOwner() => _inputOwner is { } id ? Require(id) : null;
    private Entry Require(Guid id) => _entries.TryGetValue(id, out var entry)
        ? entry : throw new InvalidOperationException("The controller session has ended.");
    private void RequireCurrent(Entry entry)
    {
        if (!ReferenceEquals(Require(entry.Id), entry) || entry.Status.Phase is RemoteControlHostSessionPhase.Disconnecting or RemoteControlHostSessionPhase.Failed)
            throw new InvalidOperationException("The controller session has been retired.");
    }
    private static RemoteControlHostAccessOperations RequireOperations(Entry entry) => entry.Operations
        ?? throw new InvalidOperationException("The authenticated session has no control operations.");
    private static RemoteControlAccess NextAccess(Entry entry, bool allowsInput)
    {
        var access = new RemoteControlAccess(RemoteControlAccess.CurrentVersion, checked((entry.Access?.Revision ?? 0) + 1),
            allowsInput ? "controller" : "observer", allowsInput ? Guid.NewGuid() : null);
        access.Validate();
        return access;
    }
    private void PublishSnapshot() => Changed?.Invoke(Snapshot);
}
