using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;

namespace Skybridge.WinClient.Services.RemoteControl;

/// <summary>Checks the current process's desktop without switching sessions or elevating privileges.</summary>
[SupportedOSPlatform("windows10.0.19041")]
internal static class WindowsInteractiveDesktop
{
    public static void RequireAvailable()
    {
        if (!OperatingSystem.IsWindows())
            throw Unavailable("Desktop access requires Windows.");

        using var process = Process.GetCurrentProcess();
        if (process.SessionId == 0)
            throw Unavailable("Desktop capture and input require an interactive user session; this process is in session 0.");

        if (!Native.WTSQuerySessionInformation(IntPtr.Zero, process.SessionId, 8, out var state, out var stateBytes))
            throw Unavailable("Unable to query the current Windows session.", new Win32Exception(Marshal.GetLastWin32Error()));
        try
        {
            if (stateBytes != sizeof(int) || Marshal.ReadInt32(state) != 0)
                throw Unavailable("The Windows user session is not connected and active.");
        }
        finally { Native.WTSFreeMemory(state); }

        var station = Native.GetProcessWindowStation();
        if (station == IntPtr.Zero ||
            !Native.GetUserObjectFlags(station, 1, out var flags, Marshal.SizeOf<Native.UserObjectFlags>(), out _))
            throw Unavailable("Unable to inspect the current window station.", new Win32Exception(Marshal.GetLastWin32Error()));
        if ((flags.Flags & 1) == 0)
            throw Unavailable("The process is attached to a noninteractive Windows window station.");

        var desktop = Native.OpenInputDesktop(0, false, 0x0001);
        if (desktop == IntPtr.Zero)
            throw Unavailable("The input desktop is locked, protected, or unavailable.", new Win32Exception(Marshal.GetLastWin32Error()));
        try
        {
            var name = new StringBuilder(256);
            if (!Native.GetUserObjectName(desktop, 2, name, name.Capacity * sizeof(char), out _))
                throw Unavailable("Unable to inspect the input desktop.", new Win32Exception(Marshal.GetLastWin32Error()));
            if (!string.Equals(name.ToString(), "Default", StringComparison.OrdinalIgnoreCase))
                throw Unavailable("Input and capture are suspended on a locked or protected Windows desktop.");
        }
        finally
        {
            if (!Native.CloseDesktop(desktop))
                throw Unavailable("Failed to release the input desktop handle.", new Win32Exception(Marshal.GetLastWin32Error()));
        }
    }

    private static WindowsDesktopException Unavailable(string message, Exception? inner = null) =>
        new(WindowsDesktopFailure.InteractiveDesktopUnavailable, message, inner);

    private static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        internal struct UserObjectFlags
        {
            internal int Inherit;
            internal int Reserved;
            internal uint Flags;
        }

        [DllImport("wtsapi32.dll", EntryPoint = "WTSQuerySessionInformationW", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool WTSQuerySessionInformation(IntPtr server, int sessionId, int informationClass, out IntPtr buffer, out int bytes);
        [DllImport("wtsapi32.dll")]
        internal static extern void WTSFreeMemory(IntPtr memory);
        [DllImport("user32.dll", SetLastError = true)]
        internal static extern IntPtr GetProcessWindowStation();
        [DllImport("user32.dll", EntryPoint = "GetUserObjectInformationW", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetUserObjectFlags(IntPtr handle, int index, out UserObjectFlags flags, int length, out int needed);
        [DllImport("user32.dll", EntryPoint = "GetUserObjectInformationW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetUserObjectName(IntPtr handle, int index, StringBuilder name, int length, out int needed);
        [DllImport("user32.dll", SetLastError = true)]
        internal static extern IntPtr OpenInputDesktop(uint flags, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint access);
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CloseDesktop(IntPtr desktop);
    }
}

/// <summary>A synchronous, thread-bound physical-pixel scope; never changes process-wide DPI policy.</summary>
[SupportedOSPlatform("windows10.0.19041")]
internal ref struct WindowsDesktopDpiScope
{
    private IntPtr _previous;
    private readonly int _threadId;
    private WindowsDesktopDpiScope(IntPtr previous)
    {
        _previous = previous;
        _threadId = Environment.CurrentManagedThreadId;
    }

    internal static WindowsDesktopDpiScope Enter()
    {
        var previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        if (previous == IntPtr.Zero)
            throw new WindowsDesktopException(WindowsDesktopFailure.DisplayConfigurationChanged,
                "Unable to read physical desktop coordinates with per-monitor DPI awareness.", new Win32Exception(Marshal.GetLastWin32Error()));
        return new(previous);
    }

    public void Dispose()
    {
        if (_previous == IntPtr.Zero) return;
        if (_threadId != Environment.CurrentManagedThreadId)
            throw new InvalidOperationException("A desktop DPI coordinate scope must end on the thread that entered it.");
        if (SetThreadDpiAwarenessContext(_previous) == IntPtr.Zero)
            throw new WindowsDesktopException(WindowsDesktopFailure.DisplayConfigurationChanged,
                "Failed to restore the desktop thread's DPI context.", new Win32Exception(Marshal.GetLastWin32Error()));
        _previous = IntPtr.Zero;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
}
