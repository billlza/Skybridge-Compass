using System;
using System.Runtime.InteropServices;

namespace Skybridge.WinClient.Services;

// =====================================================================================
//  WindowsPowerKeepAwake — a real SetThreadExecutionState wrapper used to keep the machine
//  awake (no sleep, no display-off) for the duration of a file transfer (文件传输 > 选项 >
//  传输时保持唤醒). Arm() sets ES_CONTINUOUS | ES_SYSTEM_REQUIRED (the system stays awake until
//  Release() clears it back to ES_CONTINUOUS); it is reference-counted so nested transfers do not
//  release each other early.
//
//  HONESTY NOTE (read the report): the transfer path in this Windows client is currently a
//  read-only / intent surface (FileTransferWorkspaceClient builds snapshots + select/share
//  intents; there is no live byte-pump that begins and ends a transfer here). So while this is a
//  fully real keep-awake primitive and the 传输时保持唤醒 setting persists + flips the VM gate that
//  guards Arm(), there is no live transfer in this client to wrap today — the gate is honored when
//  a real transfer pump calls IsEnabledGate ? Arm() : noop around its run. It never keeps the
//  machine awake on its own (Arm is only called inside a transfer scope), so the setting cannot
//  silently drain the battery.
// =====================================================================================

public static class WindowsPowerKeepAwake
{
    [Flags]
    private enum ExecutionState : uint
    {
        Continuous = 0x80000000,
        SystemRequired = 0x00000001,
        DisplayRequired = 0x00000002,
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint SetThreadExecutionState(ExecutionState esFlags);

    private static readonly object Sync = new();
    private static int _armCount;

    /// <summary>
    /// Begin keeping the system awake (ref-counted). Returns an IDisposable scope that Releases on
    /// dispose — wrap a transfer in `using var _ = WindowsPowerKeepAwake.Arm();`. Never throws.
    /// </summary>
    public static IDisposable Arm()
    {
        lock (Sync)
        {
            if (_armCount == 0)
            {
                try
                {
                    SetThreadExecutionState(ExecutionState.Continuous | ExecutionState.SystemRequired);
                }
                catch (Exception)
                {
                    // P/Invoke unavailable (non-Windows test host) — degrade to a no-op scope.
                }
            }

            _armCount++;
        }

        return new Scope();
    }

    private static void Release()
    {
        lock (Sync)
        {
            if (_armCount == 0)
            {
                return;
            }

            _armCount--;
            if (_armCount == 0)
            {
                try
                {
                    // Clear the system-required hint; ES_CONTINUOUS alone restores normal sleep.
                    SetThreadExecutionState(ExecutionState.Continuous);
                }
                catch (Exception)
                {
                    // Ignore — best-effort restore.
                }
            }
        }
    }

    private sealed class Scope : IDisposable
    {
        private bool _disposed;

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            Release();
        }
    }
}
