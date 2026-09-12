using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Input;

namespace Skybridge.WinClient.ViewModels;

/// <summary>
/// The reusable async command adapter every workspace command is bound through.
///
/// Two properties of this class are load-bearing and easy to lose in a refactor:
///
///  1. <see cref="Execute"/> is <c>async void</c> and cannot be anything else —
///     <see cref="ICommand.Execute"/> returns <c>void</c>. That means an exception which
///     escapes the awaited task is re-raised on the UI SynchronizationContext with no
///     caller to catch it, and an unhandled exception there terminates the process. So
///     this method is the last line of defence for every command in the shell, and it
///     must never let one through.
///
///  2. Scoped work already gets both a busy guard and error routing from
///     <see cref="WorkspaceBusyCoordinator.RunAsync"/>, which catches, patches the owning
///     <see cref="Services.WorkspaceErrorScope"/> status, and clears busy in a finally.
///     Anything arriving in the catch below therefore escaped that path — an unscoped
///     action (navigation, top-bar) or a throw from the coordinator's own catch/finally.
///     It is a defect, not routine flow, so it is reported rather than swallowed.
/// </summary>
public sealed class AsyncRelayCommand : ICommand
{
    private readonly Func<Task> _execute;
    private readonly Func<bool>? _canExecute;

    // 0 = idle, 1 = running. Guards against the same command being fired twice
    // concurrently (double-click, or an automation pass driving the same AutomationId
    // twice) which would otherwise start two sessions / two transfers.
    private int _isExecuting;

    /// <summary>
    /// Last-resort report channel for exceptions that escaped the scoped
    /// <see cref="WorkspaceBusyCoordinator"/> path. Assigned exactly once, by
    /// <see cref="App"/> at startup, so this adapter stays free of any view-model or
    /// service dependency. Left null in tests, where the escape is asserted directly.
    /// </summary>
    internal static Action<Exception>? UnhandledErrorSink { get; set; }

    public AsyncRelayCommand(Func<Task> execute, Func<bool>? canExecute = null)
    {
        _execute = execute ?? throw new ArgumentNullException(nameof(execute));
        _canExecute = canExecute;
    }

    public event EventHandler? CanExecuteChanged;

    public bool CanExecute(object? parameter) => _canExecute?.Invoke() ?? true;

    public async void Execute(object? parameter)
    {
        // Reentrancy guard. Returning silently is correct: a second click on a command
        // that is already running is not an error, it is a no-op.
        if (Interlocked.CompareExchange(ref _isExecuting, 1, 0) != 0)
        {
            return;
        }

        try
        {
            await _execute();
        }
        catch (Exception ex)
        {
            // Never rethrow. See the class remarks: there is no caller to receive it and
            // the process dies. Reporting through the sink keeps the failure visible.
            UnhandledErrorSink?.Invoke(ex);
        }
        finally
        {
            Volatile.Write(ref _isExecuting, 0);
        }
    }

    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}
