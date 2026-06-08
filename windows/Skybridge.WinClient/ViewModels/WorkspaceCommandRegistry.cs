using System;
using System.Collections.Generic;
using System.Windows.Input;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

public sealed class WorkspaceCommandRegistry
{
    private readonly IReadOnlyDictionary<WorkspaceActionCommandId, ICommand> _commandsById;

    private WorkspaceCommandRegistry(IReadOnlyList<WorkspaceCommandRegistration> registrations)
    {
        var commandsById = new Dictionary<WorkspaceActionCommandId, ICommand>();
        var refreshableCommands = new List<ICommand>();

        foreach (var registration in registrations)
        {
            if (!commandsById.TryAdd(registration.CommandId, registration.Command))
            {
                throw new InvalidOperationException($"Duplicate workspace command registration: {registration.CommandId}");
            }

            if (registration.IsRefreshable)
            {
                refreshableCommands.Add(registration.Command);
            }
        }

        _commandsById = commandsById;
        RefreshableCommands = refreshableCommands;
    }

    public IReadOnlyList<ICommand> RefreshableCommands { get; }

    public static WorkspaceCommandRegistry Create(params WorkspaceCommandRegistration[] registrations) =>
        new(registrations);

    public ICommand? Resolve(WorkspaceActionCommandId commandId) =>
        commandId == WorkspaceActionCommandId.None
            ? null
            : _commandsById.TryGetValue(commandId, out var command)
                ? command
                : null;
}

public sealed record WorkspaceCommandRegistration(
    WorkspaceActionCommandId CommandId,
    ICommand Command,
    bool IsRefreshable = true);
