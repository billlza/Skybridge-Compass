using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Skybridge.WinClient.Services.RemoteControl;

internal enum WindowsInputKind { ScanKey, UnicodeKey, MouseButton, Pointer, VerticalWheel, HorizontalWheel }
internal readonly record struct WindowsInputCommand(
    WindowsInputKind Kind, int Code = 0, bool Extended = false, bool Down = false, int X = 0, int Y = 0)
{
    public WindowsInputCommand Release() => this with { Down = false };
    public bool IsHeldControl => Kind is WindowsInputKind.ScanKey or WindowsInputKind.UnicodeKey or WindowsInputKind.MouseButton;
}
internal readonly record struct WindowsInputDelivery(uint Inserted, int NativeError);
internal interface IWindowsInputPlatform
{
    void RequireDesktop();
    WindowsDesktopBounds GetDesktopBounds();
    bool IsAlreadyDown(WindowsInputCommand command);
    WindowsInputDelivery Send(WindowsInputCommand[] commands);
}
internal interface IWindowsRemoteInput : IDisposable
{
    void MovePointer(double normalizedX, double normalizedY);
    void SetMouseButton(WindowsRemoteMouseButton button, bool down);
    void Scroll(int horizontalWheelDelta, int verticalWheelDelta);
    void SetKey(ushort macKeyCode, bool down, WindowsRemoteModifiers modifiers = WindowsRemoteModifiers.None);
    void TypeText(string text);
    void ReleaseAll();
}

/// <summary>Serial input ownership for one authenticated host session.</summary>
internal sealed class WindowsRemoteInput : IWindowsRemoteInput
{
    private readonly WindowsDesktopDisplay _display;
    private readonly IWindowsInputPlatform _platform;
    private readonly List<WindowsInputCommand> _held = new();
    private readonly Dictionary<ushort, WindowsScanKey> _keyBindings = new();
    private readonly object _gate = new();
    private bool _functionLayer;
    private bool _disposed;

    public WindowsRemoteInput(WindowsDesktopDisplay display) : this(display, CreateNativePlatform(display)) { }
    internal WindowsRemoteInput(WindowsDesktopDisplay display, IWindowsInputPlatform platform)
    {
        _display = display ?? throw new ArgumentNullException(nameof(display));
        _platform = platform ?? throw new ArgumentNullException(nameof(platform));
        _platform.RequireDesktop();
    }

    public void MovePointer(double normalizedX, double normalizedY)
    {
        lock (_gate)
        {
            RequireReady();
            var point = WindowsRemoteInputPolicy.MapPointer(normalizedX, normalizedY, _display, _platform.GetDesktopBounds());
            Inject([new(WindowsInputKind.Pointer, X: point.X, Y: point.Y)]);
        }
    }

    public void SetMouseButton(WindowsRemoteMouseButton button, bool down)
    {
        if (!Enum.IsDefined(button)) throw new ArgumentOutOfRangeException(nameof(button));
        lock (_gate)
        {
            RequireReady();
            SetControl(new(WindowsInputKind.MouseButton, (int)button, Down: down));
        }
    }

    public void Scroll(int horizontalWheelDelta, int verticalWheelDelta)
    {
        if (horizontalWheelDelta is < -12000 or > 12000 || verticalWheelDelta is < -12000 or > 12000)
            throw new ArgumentOutOfRangeException(nameof(verticalWheelDelta), "One scroll event cannot exceed 100 wheel detents.");
        lock (_gate)
        {
            RequireReady();
            var commands = new List<WindowsInputCommand>(2);
            if (horizontalWheelDelta != 0) commands.Add(new(WindowsInputKind.HorizontalWheel, horizontalWheelDelta));
            if (verticalWheelDelta != 0) commands.Add(new(WindowsInputKind.VerticalWheel, verticalWheelDelta));
            if (commands.Count > 0) Inject(commands.ToArray());
        }
    }

    public void SetKey(ushort macKeyCode, bool down, WindowsRemoteModifiers modifiers = WindowsRemoteModifiers.None)
    {
        // The Mac wire sends modifiers as independent keyDown/keyUp events. A None value
        // must never release a modifier owned by an earlier event in the same sequence.
        if (modifiers != WindowsRemoteModifiers.None)
            throw new ArgumentException("Modifier changes must arrive as explicit physical key events.", nameof(modifiers));
        lock (_gate)
        {
            RequireReady();
            // Fn belongs to the Mac keyboard's function layer, not to Windows'
            // injectable modifier set. Translate its editing/navigation combinations
            // and retain each down's resolved scan code until its matching up.
            if (macKeyCode == 0x3f) { _functionLayer = down; return; }
            var ordinary = WindowsRemoteInputPolicy.MapMacKey(macKeyCode);
            if (down)
            {
                var key = _keyBindings.TryGetValue(macKeyCode, out var existing) ? existing :
                    _functionLayer ? MapFunctionLayer(macKeyCode, ordinary) : ordinary;
                SetControl(new(WindowsInputKind.ScanKey, key.ScanCode, key.Extended, true));
                _keyBindings[macKeyCode] = key;
            }
            else if (_keyBindings.TryGetValue(macKeyCode, out var key))
            {
                SetControl(new(WindowsInputKind.ScanKey, key.ScanCode, key.Extended, false));
                _keyBindings.Remove(macKeyCode);
            }
        }
    }

    public void TypeText(string text)
    {
        WindowsRemoteInputPolicy.RequireValidText(text);
        lock (_gate)
        {
            RequireReady();
            // Bound each native batch and track the successfully injected prefix. If a
            // partial SendInput leaves a Unicode key down, ReleaseAll still owns it.
            for (var offset = 0; offset < text.Length; offset += 64)
            {
                var count = Math.Min(64, text.Length - offset);
                var commands = new WindowsInputCommand[count * 2];
                for (var index = 0; index < count; index++)
                {
                    commands[index * 2] = new(WindowsInputKind.UnicodeKey, text[offset + index], Down: true);
                    commands[index * 2 + 1] = commands[index * 2].Release();
                }
                Inject(commands);
            }
        }
    }

    public void ReleaseAll()
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            _functionLayer = false;
            if (_held.Count == 0) { _keyBindings.Clear(); return; }
            _platform.RequireDesktop();
            var pending = _held.AsEnumerable().Reverse().ToArray();
            var failures = new List<Exception>();
            foreach (var held in pending)
            {
                try { Inject([held.Release()]); }
                catch (WindowsDesktopException failure) { failures.Add(failure); }
            }
            foreach (var binding in _keyBindings.ToArray())
                if (!_held.Contains(new(WindowsInputKind.ScanKey, binding.Value.ScanCode, binding.Value.Extended, true)))
                    _keyBindings.Remove(binding.Key);
            if (failures.Count > 0)
                throw new AggregateException("Some remote input releases failed; their ownership is retained for a later release attempt.", failures);
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            ReleaseAll();
            _disposed = true;
        }
    }

    private void SetControl(WindowsInputCommand command)
    {
        var owned = _held.Contains(command with { Down = true });
        if (!command.Down && !owned) return;
        if (command.Down && !owned && _platform.IsAlreadyDown(command)) return;
        Inject([command]);
    }

    private static WindowsScanKey MapFunctionLayer(ushort macKeyCode, WindowsScanKey ordinary) => macKeyCode switch
    {
        0x24 => new(0x1c, true), // Fn + Return -> keypad Enter
        0x33 => new(0x53, true), // Fn + Backspace -> forward Delete
        0x7b => new(0x47, true), 0x7c => new(0x4f, true), // Home, End
        0x7d => new(0x51, true), 0x7e => new(0x49, true), // Page Down, Page Up
        _ => ordinary
    };

    private void Inject(WindowsInputCommand[] commands)
    {
        _platform.RequireDesktop();
        var result = _platform.Send(commands);
        if (result.Inserted > commands.Length)
            throw new WindowsDesktopException(WindowsDesktopFailure.InputRejected, "SendInput returned an invalid inserted-event count.");
        for (var index = 0; index < result.Inserted; index++)
        {
            var command = commands[index];
            if (!command.IsHeldControl) continue;
            var held = command with { Down = true };
            if (!command.Down) _held.Remove(held);
            else if (!_held.Contains(held)) _held.Add(held);
        }
        if (result.Inserted != commands.Length)
            throw new WindowsDesktopException(WindowsDesktopFailure.InputRejected,
                $"Windows accepted {result.Inserted} of {commands.Length} remote input events. Desktop access or application integrity may have blocked input.",
                result.NativeError == 0 ? null : new Win32Exception(result.NativeError));
    }

    private void RequireReady()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        _platform.RequireDesktop();
    }

    private static IWindowsInputPlatform CreateNativePlatform(WindowsDesktopDisplay display)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
            throw new PlatformNotSupportedException("Remote input requires Windows 10 version 2004 or later.");
        return new WindowsNativeInputPlatform(display);
    }
}

[SupportedOSPlatform("windows10.0.19041")]
internal sealed class WindowsNativeInputPlatform : IWindowsInputPlatform
{
    private readonly WindowsDesktopDisplay _display;
    internal WindowsNativeInputPlatform(WindowsDesktopDisplay display) => _display = display ?? throw new ArgumentNullException(nameof(display));
    public void RequireDesktop() => WindowsInteractiveDesktop.RequireAvailable();

    public WindowsDesktopBounds GetDesktopBounds()
    {
        using var coordinates = WindowsDesktopDpiScope.Enter();
        var center = new Native.Point { X = checked(_display.Left + _display.Width / 2), Y = checked(_display.Top + _display.Height / 2) };
        var monitor = Native.MonitorFromPoint(center, 0);
        var info = new Native.MonitorInfo { Size = Marshal.SizeOf<Native.MonitorInfo>(), DeviceName = string.Empty };
        if (monitor == IntPtr.Zero || !Native.GetMonitorInfo(monitor, ref info))
            throw new WindowsDesktopException(WindowsDesktopFailure.DisplayConfigurationChanged, "The selected input display is no longer attached.");
        if (!string.Equals(info.DeviceName, _display.Name, StringComparison.OrdinalIgnoreCase) ||
            info.Monitor.Left != _display.Left || info.Monitor.Top != _display.Top ||
            info.Monitor.Right - info.Monitor.Left != _display.Width || info.Monitor.Bottom - info.Monitor.Top != _display.Height)
            throw new WindowsDesktopException(WindowsDesktopFailure.DisplayConfigurationChanged,
                "The input display moved or changed size; refresh the stream before sending more pointer input.");
        return new(Native.GetSystemMetrics(76), Native.GetSystemMetrics(77), Native.GetSystemMetrics(78), Native.GetSystemMetrics(79));
    }

    public bool IsAlreadyDown(WindowsInputCommand command)
    {
        uint virtualKey;
        if (command.Kind == WindowsInputKind.MouseButton)
        {
            virtualKey = (WindowsRemoteMouseButton)command.Code switch
            {
                WindowsRemoteMouseButton.Left => 1, WindowsRemoteMouseButton.Right => 2,
                WindowsRemoteMouseButton.Middle => 4, WindowsRemoteMouseButton.Extra1 => 5, WindowsRemoteMouseButton.Extra2 => 6,
                _ => throw new ArgumentOutOfRangeException(nameof(command))
            };
        }
        else if (command.Kind == WindowsInputKind.ScanKey)
        {
            var window = Native.GetForegroundWindow();
            var thread = Native.GetWindowThreadProcessId(window, out _);
            virtualKey = Native.MapVirtualKeyEx((uint)command.Code | (command.Extended ? 0xe000u : 0), 3, Native.GetKeyboardLayout(thread));
            if (virtualKey == 0)
                throw new WindowsDesktopException(WindowsDesktopFailure.InputRejected,
                    $"The active Windows keyboard layout cannot map physical scan code 0x{command.Code:x2}.");
        }
        else return false;
        return (Native.GetAsyncKeyState((int)virtualKey) & 0x8000) != 0;
    }

    public WindowsInputDelivery Send(WindowsInputCommand[] commands)
    {
        var native = commands.Select(ToNative).ToArray();
        Marshal.SetLastPInvokeError(0);
        var inserted = Native.SendInput((uint)native.Length, native, Marshal.SizeOf<Native.Input>());
        return new(inserted, Marshal.GetLastPInvokeError());
    }

    private static Native.Input ToNative(WindowsInputCommand command)
    {
        if (command.Kind is WindowsInputKind.ScanKey or WindowsInputKind.UnicodeKey)
            return new Native.Input
            {
                Type = 1,
                Data = new Native.InputUnion { Keyboard = new Native.KeyboardInput
                {
                    ScanCode = checked((ushort)command.Code),
                    Flags = (command.Kind == WindowsInputKind.UnicodeKey ? 4u : 8u) |
                        (command.Extended ? 1u : 0u) | (command.Down ? 0u : 2u)
                } }
            };
        var mouse = new Native.MouseInput();
        switch (command.Kind)
        {
            case WindowsInputKind.Pointer: mouse.X = command.X; mouse.Y = command.Y; mouse.Flags = 0x8000 | 0x4000 | 1; break;
            case WindowsInputKind.VerticalWheel: mouse.Flags = 0x0800; mouse.Data = unchecked((uint)command.Code); break;
            case WindowsInputKind.HorizontalWheel: mouse.Flags = 0x1000; mouse.Data = unchecked((uint)command.Code); break;
            case WindowsInputKind.MouseButton:
                (mouse.Flags, mouse.Data) = (WindowsRemoteMouseButton)command.Code switch
                {
                    WindowsRemoteMouseButton.Left => (command.Down ? 0x0002u : 0x0004u, 0u),
                    WindowsRemoteMouseButton.Right => (command.Down ? 0x0008u : 0x0010u, 0u),
                    WindowsRemoteMouseButton.Middle => (command.Down ? 0x0020u : 0x0040u, 0u),
                    WindowsRemoteMouseButton.Extra1 => (command.Down ? 0x0080u : 0x0100u, 1u),
                    WindowsRemoteMouseButton.Extra2 => (command.Down ? 0x0080u : 0x0100u, 2u),
                    _ => throw new ArgumentOutOfRangeException(nameof(command))
                }; break;
            default: throw new ArgumentOutOfRangeException(nameof(command));
        }
        return new Native.Input { Data = new Native.InputUnion { Mouse = mouse } };
    }

    private static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        internal struct Input { internal uint Type; internal InputUnion Data; }
        [StructLayout(LayoutKind.Explicit)]
        internal struct InputUnion
        {
            [FieldOffset(0)] internal MouseInput Mouse;
            [FieldOffset(0)] internal KeyboardInput Keyboard;
        }
        [StructLayout(LayoutKind.Sequential)]
        internal struct MouseInput { internal int X, Y; internal uint Data, Flags, Time; internal nuint ExtraInfo; }
        [StructLayout(LayoutKind.Sequential)]
        internal struct KeyboardInput { internal ushort VirtualKey, ScanCode; internal uint Flags, Time; internal nuint ExtraInfo; }
        [DllImport("user32.dll", SetLastError = true)]
        internal static extern uint SendInput(uint count, [In] Input[] inputs, int size);
        [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int virtualKey);
        [DllImport("user32.dll")] internal static extern int GetSystemMetrics(int index);
        [StructLayout(LayoutKind.Sequential)] internal struct Point { internal int X, Y; }
        [StructLayout(LayoutKind.Sequential)] internal struct Rect { internal int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct MonitorInfo
        {
            internal int Size;
            internal Rect Monitor, Work;
            internal uint Flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] internal string DeviceName;
        }
        [DllImport("user32.dll")] internal static extern IntPtr MonitorFromPoint(Point point, uint flags);
        [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
        [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll")] internal static extern IntPtr GetKeyboardLayout(uint threadId);
        [DllImport("user32.dll", EntryPoint = "MapVirtualKeyExW")] internal static extern uint MapVirtualKeyEx(uint code, uint mapType, IntPtr layout);
    }
}
