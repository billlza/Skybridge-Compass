using System.Text.Json;
using Skybridge.WinClient.Services.RemoteControl;
using Skybridge.WinClient.ViewModels;

internal static class RemoteControlHostAccessTests
{
    internal static IReadOnlyList<(string Name, Func<Task> Run)> Cases { get; } =
    [
        ("host access capacity includes authentication and stale UI actions cannot replace sessions", Admission),
        ("host access requires explicit approval and observer input is rejected", Approval),
        ("host handoff releases old input before publishing fresh grants", Handoff),
        ("host handoff waits for an in-flight HID commit without rejecting the local action", HandoffDuringInput),
        ("host approval waits for an in-flight HID commit and remains cancellable", ApprovalDuringInput),
        ("host failed release blocks every new input grant until exact cleanup", FailedRelease),
        ("host input cleanup failure still permits explicit viewing-only approval", ViewingAfterReleaseFailure),
        ("host failed grant publication never commits input ownership", FailedPublication),
        ("host failed revocation retires only the participant whose receipt delivery failed", FailedRevocation),
        ("host input waits behind grant publication until the local commit completes", PublicationOrdering),
        ("host stale revocation completion cannot overlap or retire a newer handoff", RemovedOwnerDuringHandoff),
        ("host legacy connections cannot coexist with managed viewers", LegacyExclusion),
        ("host access wire matches version roles revisions and immutable input leases", Wire),
        ("host session UI commands retain exact session identity and role boundaries", SessionRow)
    ];

    private sealed class Peer
    {
        internal readonly RemoteControlHostAccessCoordinator Coordinator;
        internal readonly Guid Id;
        internal readonly List<string> Events;
        internal readonly string Name;
        internal bool FailRelease;
        internal Func<RemoteControlAccess, Task>? BeforePublish;
        internal int DisconnectCount;
        internal int AppliedInputCount;
        internal Task? Approval;

        internal Peer(RemoteControlHostAccessCoordinator coordinator, string name, List<string>? events = null)
        {
            Coordinator = coordinator;
            Name = name;
            Events = events ?? [];
            Id = coordinator.Reserve(() => DisconnectCount++);
            coordinator.Authenticate(Id, "device-" + name, name);
        }

        internal void Request(bool managed = true) => Approval = Coordinator.RequestApprovalAsync(Id, managed,
            new RemoteControlHostAccessOperations(_ =>
            {
                Events.Add("release:" + Name);
                return FailRelease ? Task.FromException(new IOException("Input release failed")) : Task.CompletedTask;
            }, async (access, _) =>
            {
                Events.Add($"publish:{Name}:{access.Role}");
                if (BeforePublish is not null) await BeforePublish(access);
            }), default);

        internal async Task Approve(bool input)
        {
            await Coordinator.ApproveAsync(Id, input, default);
            await (Approval ?? throw new InvalidOperationException("Approval was not requested"));
            Coordinator.MarkReady(Id);
        }

        internal Task<bool> Input(Guid? lease) => Coordinator.ApplyInputAsync(Id, lease, () => AppliedInputCount++, default);
        internal RemoteControlAccess Access => Coordinator.AccessForReceipt(Id) ?? throw new InvalidOperationException("Expected managed access");
    }

    private static async Task Admission()
    {
        var coordinator = new RemoteControlHostAccessCoordinator();
        var first = new Peer(coordinator, "first");
        var second = new Peer(coordinator, "second");
        Throws<RemoteControlHostCapacityException>(() => coordinator.Reserve(() => { }));
        Require(coordinator.Snapshot.Count == 2 && coordinator.Snapshot.All(row => row.Phase == RemoteControlHostSessionPhase.Authenticating), "Pending authentication did not reserve capacity.");
        coordinator.Retire(first.Id);
        var replacement = new Peer(coordinator, "first");
        await ThrowsAsync<InvalidOperationException>(() => coordinator.ApproveAsync(first.Id, true, default));
        Throws<InvalidOperationException>(() => coordinator.Disconnect(first.Id));
        Require(replacement.Id != first.Id && coordinator.Snapshot.Any(row => row.Id == replacement.Id) && second.DisconnectCount == 0, "A stale action reached a replacement session.");
        coordinator.Retire(replacement.Id);
        coordinator.Retire(second.Id);
    }

    private static async Task Approval()
    {
        var coordinator = new RemoteControlHostAccessCoordinator();
        var peer = new Peer(coordinator, "viewer");
        peer.Request();
        Require(peer.Approval?.IsCompleted == false, "Authentication silently approved screen access.");
        Throws<InvalidOperationException>(() => coordinator.AccessForReceipt(peer.Id));
        Require(!await peer.Input(Guid.NewGuid()) && peer.AppliedInputCount == 0, "Pending approval allowed desktop input.");
        await peer.Approve(false);
        Require(peer.Access.Role == "observer" && peer.Access.Lease is null, "Viewing approval issued input authority.");
        Require(!await peer.Input(null) && !await peer.Input(Guid.NewGuid()), "An observer injected input.");
        coordinator.Retire(peer.Id);
    }

    private static async Task Handoff()
    {
        var coordinator = new RemoteControlHostAccessCoordinator();
        var events = new List<string>();
        var first = new Peer(coordinator, "first", events);
        var second = new Peer(coordinator, "second", events);
        first.Request(); second.Request();
        await first.Approve(true); await second.Approve(false);
        var firstLease = first.Access.Lease;
        Require(await first.Input(firstLease), "The approved controller could not inject.");
        await coordinator.TransferInputAsync(second.Id, default);
        var secondLease = second.Access.Lease;
        Require(events.SequenceEqual(["release:first", "publish:first:observer", "publish:second:controller"]), "Input handoff published a grant before release and revocation.");
        Require(secondLease is not null && secondLease != firstLease && !await first.Input(firstLease) && await second.Input(secondLease), "Handoff retained old input authority or shared a lease.");
        await coordinator.TransferInputAsync(first.Id, default);
        Require(first.Access.Lease != firstLease && !await first.Input(firstLease) && await first.Input(first.Access.Lease), "A regrant revived an old input lease.");
        coordinator.Retire(first.Id); coordinator.Retire(second.Id);
    }

    private static async Task HandoffDuringInput()
    {
        var coordinator = new RemoteControlHostAccessCoordinator();
        var first = new Peer(coordinator, "first");
        var second = new Peer(coordinator, "second");
        first.Request(); second.Request();
        await first.Approve(true); await second.Approve(false);
        var originalLease = first.Access.Lease;
        await WithBlockedInputAsync(first, async finishInput =>
        {
            var handoff = coordinator.TransferInputAsync(second.Id, default);
            Require(!handoff.IsCompleted, "Ordinary HID input falsely rejected the host's input handoff.");
            await ThrowsAsync<InvalidOperationException>(() => coordinator.TransferInputAsync(second.Id, default));
            finishInput();
            await handoff.WaitAsync(TimeSpan.FromSeconds(2));
        });
        Require(second.Access.Lease != originalLease && await second.Input(second.Access.Lease) && !await first.Input(originalLease),
            "The handoff did not commit the new exclusive grant after input completed.");
        coordinator.Retire(first.Id); coordinator.Retire(second.Id);
    }

    private static async Task ApprovalDuringInput()
    {
        var coordinator = new RemoteControlHostAccessCoordinator();
        var first = new Peer(coordinator, "first");
        var second = new Peer(coordinator, "second");
        first.Request(); second.Request();
        await first.Approve(true);
        await WithBlockedInputAsync(first, async finishInput =>
        {
            using var cancellation = new CancellationTokenSource();
            var canceledApproval = coordinator.ApproveAsync(second.Id, false, cancellation.Token);
            Require(!canceledApproval.IsCompleted, "Ordinary HID input falsely rejected viewing approval.");
            cancellation.Cancel();
            await ThrowsAsync<OperationCanceledException>(() => canceledApproval);
            var approval = second.Approve(false);
            Require(!approval.IsCompleted, "Canceled approval retained its transaction or bypassed the input commit barrier.");
            finishInput();
            await approval.WaitAsync(TimeSpan.FromSeconds(2));
        });
        Require(second.Access.Role == "observer" && await first.Input(first.Access.Lease),
            "Viewing approval changed input ownership or failed after its earlier wait was canceled.");
        coordinator.Retire(first.Id); coordinator.Retire(second.Id);
    }

    private static async Task WithBlockedInputAsync(Peer controller, Func<Action, Task> action)
    {
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var finish = new ManualResetEventSlim();
        var lease = controller.Access.Lease;
        var input = Task.Run(() => controller.Coordinator.ApplyInputAsync(controller.Id, lease, () =>
        {
            entered.TrySetResult();
            if (!finish.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException("The test did not release its in-flight HID operation.");
        }, default));
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
            await action(finish.Set);
        }
        finally
        {
            finish.Set();
            Require(await input, "The original authorized HID operation did not finish.");
        }
    }

    private static async Task FailedRelease()
    {
        var coordinator = new RemoteControlHostAccessCoordinator();
        var first = new Peer(coordinator, "first");
        var second = new Peer(coordinator, "second");
        first.Request(); second.Request();
        await first.Approve(true); await second.Approve(false);
        var oldLease = first.Access.Lease;
        first.FailRelease = true;
        await ThrowsAsync<IOException>(() => coordinator.TransferInputAsync(second.Id, default));
        Require(!await first.Input(oldLease) && !await second.Input(Guid.NewGuid()), "A failed release left an input grant usable.");
        await ThrowsAsync<InvalidOperationException>(() => coordinator.TransferInputAsync(second.Id, default));
        Require(second.Access.Role == "observer" && second.Events.Count == 0, "A failed release still published the target grant.");
        coordinator.Retire(first.Id, new IOException("Cleanup pending"));
        Require(coordinator.Snapshot.Count == 2, "Failed native cleanup released admission capacity.");
        coordinator.Retire(first.Id);
        await coordinator.TransferInputAsync(second.Id, default);
        Require(await second.Input(second.Access.Lease), "Exact cleanup did not unblock input handoff.");
        coordinator.Retire(second.Id);
    }

    private static async Task FailedPublication()
    {
        var coordinator = new RemoteControlHostAccessCoordinator();
        var peer = new Peer(coordinator, "viewer");
        peer.Request(); await peer.Approve(false);
        Guid? proposedLease = null;
        peer.BeforePublish = access =>
        {
            proposedLease = access.Lease;
            throw new IOException("Control receipt transport failed");
        };
        await ThrowsAsync<IOException>(() => coordinator.TransferInputAsync(peer.Id, default));
        Require(peer.Access.Role == "observer" && !await peer.Input(proposedLease) && peer.DisconnectCount == 1,
            "Failed grant publication committed input authority or kept the uncertain incarnation alive.");
        await ThrowsAsync<InvalidOperationException>(() => coordinator.TransferInputAsync(peer.Id, default));
        Require(coordinator.Snapshot.Single().Phase == RemoteControlHostSessionPhase.Disconnecting,
            "A failed delivery allowed the same session to reuse its revision with another lease.");
        coordinator.Retire(peer.Id);
    }

    private static async Task FailedRevocation()
    {
        var coordinator = new RemoteControlHostAccessCoordinator();
        var first = new Peer(coordinator, "first");
        var second = new Peer(coordinator, "second");
        first.Request(); second.Request();
        await first.Approve(true); await second.Approve(false);
        first.BeforePublish = _ => Task.FromException(new IOException("Revocation delivery failed"));
        await ThrowsAsync<IOException>(() => coordinator.TransferInputAsync(second.Id, default));
        Require(first.DisconnectCount == 1 && second.DisconnectCount == 0 && second.Access.Role == "observer",
            "Failed revocation disconnected the untouched viewing session or retained uncertain old authority.");
        coordinator.Retire(first.Id);
        await coordinator.TransferInputAsync(second.Id, default);
        Require(await second.Input(second.Access.Lease), "An unrelated viewing session could not receive a later explicit grant.");
        coordinator.Retire(second.Id);
    }

    private static async Task ViewingAfterReleaseFailure()
    {
        var coordinator = new RemoteControlHostAccessCoordinator();
        var first = new Peer(coordinator, "first");
        var second = new Peer(coordinator, "second");
        first.Request(); second.Request();
        await first.Approve(true);
        first.FailRelease = true;
        await ThrowsAsync<IOException>(() => coordinator.ApproveAsync(second.Id, true, default));
        await second.Approve(false);
        Require(second.Access.Role == "observer" && !await second.Input(Guid.NewGuid()),
            "An input cleanup failure either prevented safe viewing or granted desktop input.");
        coordinator.Retire(first.Id); coordinator.Retire(second.Id);
    }

    private static async Task PublicationOrdering()
    {
        var coordinator = new RemoteControlHostAccessCoordinator();
        var peer = new Peer(coordinator, "viewer");
        peer.Request(); await peer.Approve(false);
        var published = new TaskCompletionSource<RemoteControlAccess>(TaskCreationOptions.RunContinuationsAsynchronously);
        var completeSend = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        peer.BeforePublish = access => { published.TrySetResult(access); return completeSend.Task; };
        var transfer = coordinator.TransferInputAsync(peer.Id, default);
        var grant = await published.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var input = peer.Input(grant.Lease);
        Require(!input.IsCompleted && peer.AppliedInputCount == 0, "Input raced ahead of the local grant commit.");
        completeSend.SetResult();
        await transfer;
        Require(await input && peer.AppliedInputCount == 1, "Input arriving immediately after receipt was lost during local publication.");
        coordinator.Retire(peer.Id);
    }

    private static async Task LegacyExclusion()
    {
        foreach (var firstManaged in new[] { true, false })
        {
            var coordinator = new RemoteControlHostAccessCoordinator();
            var first = new Peer(coordinator, "first");
            var second = new Peer(coordinator, "second");
            first.Request(firstManaged);
            second.Request(!firstManaged);
            await ThrowsAsync<NotSupportedException>(() => second.Approval!);
            await first.Approve(true);
            if (!firstManaged)
            {
                Require(coordinator.AccessForReceipt(first.Id) is null && await first.Input(null) && !await first.Input(Guid.NewGuid()), "Legacy exclusive authority changed wire semantics.");
            }
            coordinator.Retire(first.Id); coordinator.Retire(second.Id);
        }
    }

    private static async Task RemovedOwnerDuringHandoff()
    {
        var coordinator = new RemoteControlHostAccessCoordinator();
        var first = new Peer(coordinator, "first");
        var second = new Peer(coordinator, "second");
        first.Request(); second.Request();
        await first.Approve(true); await second.Approve(false);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        first.BeforePublish = _ => { entered.SetResult(); return finish.Task; };
        var oldHandoff = coordinator.TransferInputAsync(second.Id, default);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        coordinator.Retire(first.Id);
        await ThrowsAsync<InvalidOperationException>(() => coordinator.TransferInputAsync(second.Id, default));
        Require(second.Access.Role == "observer" && second.DisconnectCount == 0, "Removing the old owner released the still-running handoff transaction.");
        finish.SetException(new IOException("Old revocation transport failed"));
        await ThrowsAsync<IOException>(() => oldHandoff);
        await coordinator.TransferInputAsync(second.Id, default);
        Require(await second.Input(second.Access.Lease) && second.DisconnectCount == 0, "Old handoff cleanup retired the unrelated surviving viewer.");
        coordinator.Retire(second.Id);
    }

    private static Task Wire()
    {
        var lease = Guid.NewGuid();
        var grant = new RemoteControlAccess(1, 7, "controller", lease);
        grant.Validate();
        var encoded = RemoteControlWire.EncodeMessage("controlAccess", grant);
        var envelope = RemoteControlWire.Decode<RemoteControlMessage>(encoded);
        var decoded = RemoteControlWire.Decode<RemoteControlAccess>(envelope.Payload);
        Require(envelope.Type == "controlAccess" && decoded == grant, "Control access wire changed its role, revision or lease.");
        using var json = JsonDocument.Parse(envelope.Payload);
        Require(json.RootElement.GetProperty("version").GetInt32() == 1 && json.RootElement.GetProperty("revision").GetUInt64() == 7 && json.RootElement.GetProperty("role").GetString() == "controller", "Access field casing differs from the Swift contract.");
        var input = RemoteControlWire.Decode<RemoteControlMessage>(RemoteControlWire.EncodeMessage("keyboardEvent", new RemoteKeyEvent("keyDown", 0, 1), lease));
        Require(input.InputControlLease == lease, "Input lost its immutable grant lease.");
        foreach (var invalid in new[] { grant with { Version = 2 }, grant with { Revision = 0 }, grant with { Revision = ulong.MaxValue }, grant with { Role = "other" }, grant with { Lease = Guid.Empty }, grant with { Role = "observer" }, grant with { Role = "observer", Lease = Guid.Empty } })
            Throws<InvalidDataException>(invalid.Validate);
        return Task.CompletedTask;
    }

    private static Task SessionRow()
    {
        var id = Guid.NewGuid();
        var calls = new List<(Guid, bool)>();
        var row = new RemoteControlHostSessionViewModel(new(id, "Viewer", "device", RemoteControlHostSessionPhase.AwaitingApproval, true),
            key => key, () => false,
            (session, input) => { calls.Add((session, input)); return Task.CompletedTask; },
            _ => Task.CompletedTask, _ => Task.CompletedTask);
        Require(row.ApproveViewingCommand.CanExecute(null) && row.ApproveControlCommand.CanExecute(null) && !row.TransferInputCommand.CanExecute(null), "Pending UI command gates do not match the role.");
        row.ApproveViewingCommand.Execute(null);
        Require(calls.SequenceEqual([(id, false)]), "UI approval changed the reviewed session identity or grant mode.");
        row.Apply(new(id, "Viewer", "device", RemoteControlHostSessionPhase.Viewing, true));
        Require(!row.ApproveViewingCommand.CanExecute(null) && row.TransferInputCommand.CanExecute(null), "Observer UI cannot request explicit input handoff.");
        var invalidations = 0;
        row.PropertyChanged += (_, _) => invalidations++;
        row.TransferInputCommand.CanExecuteChanged += (_, _) => invalidations++;
        row.Apply(new(id, "Viewer", "device", RemoteControlHostSessionPhase.Viewing, true, FramesSent: 30, AudioPacketsSent: 10));
        Require(invalidations == 0, "Media counters repeatedly invalidated unchanged security controls.");
        Throws<InvalidOperationException>(() => row.Apply(new(Guid.NewGuid(), "Other", "other", RemoteControlHostSessionPhase.Controlling, true)));
        return Task.CompletedTask;
    }

    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static T Throws<T>(Action action) where T : Exception
    {
        try { action(); } catch (T error) { return error; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }
    private static async Task<T> ThrowsAsync<T>(Func<Task> action) where T : Exception
    {
        try { await action(); } catch (T error) { return error; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }
}
