using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Skybridge.WinClient.Services;

/// <summary>Owns a power request for one active operation, independent of its continuation thread.</summary>
public static class WindowsPowerKeepAwake
{
    /// <summary>Keep the system awake until disposal. Desktop capture also requires an active display.</summary>
    public static IDisposable Arm(bool keepDisplayAwake = false) => Arm(
        keepDisplayAwake ? "SkyBridge remote desktop session" : "SkyBridge file transfer", keepDisplayAwake);

    internal static IDisposable Arm(string reason, bool keepDisplayAwake)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(reason);
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("Power requests require Windows.");

        var scope = new Scope(CreateRequest(reason));
        try
        {
            scope.Start(keepDisplayAwake);
            return scope;
        }
        catch (Exception startFailure)
        {
            try { scope.Dispose(); }
            catch (Exception cleanupFailure) { throw new AggregateException("Power request creation and rollback failed.", startFailure, cleanupFailure); }
            throw;
        }
    }

    private static SafeFileHandle CreateRequest(string reason)
    {
        var text = Marshal.StringToHGlobalUni(reason);
        try
        {
            var context = new ReasonContext { Flags = 1, Reason = new ReasonUnion { SimpleReasonString = text } };
            var handle = PowerCreateRequest(ref context);
            if (!handle.IsInvalid) return handle;
            var error = new Win32Exception(Marshal.GetLastPInvokeError(), "Windows could not create the power request.");
            handle.Dispose();
            throw error;
        }
        finally { Marshal.FreeHGlobal(text); }
    }

    private sealed class Scope(SafeFileHandle handle) : IDisposable
    {
        private SafeFileHandle? _handle = handle;
        private bool _systemActive;
        private bool _displayActive;

        internal void Start(bool displayRequired)
        {
            var request = _handle ?? throw new ObjectDisposedException(nameof(Scope));
            Require(PowerSetRequest(request, PowerRequestType.SystemRequired), "keep the system awake");
            _systemActive = true;
            if (displayRequired)
            {
                Require(PowerSetRequest(request, PowerRequestType.DisplayRequired), "keep the shared display awake");
                _displayActive = true;
            }
        }

        public void Dispose()
        {
            var request = Interlocked.Exchange(ref _handle, null);
            if (request is null) return;
            var failures = new List<Exception>();
            try
            {
                if (_displayActive && !PowerClearRequest(request, PowerRequestType.DisplayRequired))
                    failures.Add(new Win32Exception(Marshal.GetLastPInvokeError(), "Windows could not release the display power request."));
                if (_systemActive && !PowerClearRequest(request, PowerRequestType.SystemRequired))
                    failures.Add(new Win32Exception(Marshal.GetLastPInvokeError(), "Windows could not release the system power request."));
            }
            finally { request.Dispose(); }
            if (failures.Count > 0) throw new AggregateException("Power request cleanup failed.", failures);
        }
    }

    private static void Require(bool success, string operation)
    {
        if (!success) throw new Win32Exception(Marshal.GetLastPInvokeError(), $"Windows could not {operation}.");
    }

    private enum PowerRequestType { DisplayRequired, SystemRequired }

    [StructLayout(LayoutKind.Sequential)]
    private struct ReasonContext
    {
        public uint Version;
        public uint Flags;
        public ReasonUnion Reason;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct ReasonUnion
    {
        [FieldOffset(0)] public nint SimpleReasonString;
        [FieldOffset(0)] public DetailedReason Detailed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DetailedReason
    {
        public nint Module;
        public uint ResourceId;
        public uint StringCount;
        public nint Strings;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeFileHandle PowerCreateRequest(ref ReasonContext context);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PowerSetRequest(SafeFileHandle request, PowerRequestType type);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PowerClearRequest(SafeFileHandle request, PowerRequestType type);
}
