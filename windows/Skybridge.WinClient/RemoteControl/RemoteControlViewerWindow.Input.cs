using System.Threading.Channels;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Skybridge.WinClient.Services.RemoteControl;
using Windows.System;
using CoreVirtualKeyStates = Windows.UI.Core.CoreVirtualKeyStates;

namespace Skybridge.WinClient.RemoteControl;

public sealed partial class RemoteControlViewerWindow
{
    private Channel<InputCommand>? _inputs;
    private Task _inputPump = Task.CompletedTask;
    private Exception? _inputFailure;
    private RemoteControlAccess? _inputGrant;
    private readonly HashSet<ushort> _pressedKeys = [];
    private bool _leftPressed, _rightPressed, _presenting;
    private double _pointerX, _pointerY;
    private readonly RemotePointerMotionFilter _pointerMotion = new();
    private int _wheelRemainder;

    private void AttachInput()
    {
        InputSurface.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(OnRemoteKeyDown), true);
        InputSurface.AddHandler(UIElement.KeyUpEvent, new KeyEventHandler(OnRemoteKeyUp), true);
        InputSurface.PointerPressed += OnRemotePointerPressed;
        InputSurface.PointerReleased += OnRemotePointerReleased;
        InputSurface.PointerMoved += OnRemotePointerMoved;
        InputSurface.PointerWheelChanged += OnRemotePointerWheel;
        InputSurface.PointerCaptureLost += OnInputPointerCaptureLost;
        InputSurface.LostFocus += OnInputLostFocus;
        Activated += OnViewerActivated;
    }

    private void StartInput(WindowsRemoteControlViewer connection, CancellationToken token)
    {
        _inputFailure = null;
        _inputGrant = null;
        ClearInputState();
        var queue = Channel.CreateBounded<InputCommand>(new BoundedChannelOptions(128)
        { SingleReader = true, SingleWriter = true, FullMode = BoundedChannelFullMode.Wait });
        _inputs = queue;
        _inputPump = PumpInputAsync(connection, queue, token);
    }

    private async Task PumpInputAsync(WindowsRemoteControlViewer connection, Channel<InputCommand> queue, CancellationToken token)
    {
        try
        {
            await foreach (var command in queue.Reader.ReadAllAsync(token))
            {
                try { await command.SendAsync(connection, token); }
                catch (RemoteControlViewerInputAuthorityChangedException)
                {
                    // A host-approved handoff retires queued events from the previous lease.
                }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception failure)
        {
            if (_connection == connection)
            {
                _inputFailure = failure;
                _connectionLifetime?.Cancel();
            }
        }
    }

    private RemoteControlAccess? CurrentInputAccess => _presenting && _connection?.Access is { AllowsInput: true } access ? access : null;
    private static double InputTime => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000d;

    private void Enqueue(InputCommand command)
    {
        if (_inputs is null || _connectionLifetime is not { IsCancellationRequested: false } lifetime) return;
        if (!_inputs.Writer.TryWrite(command))
        {
            _inputFailure = new InvalidOperationException("The remote input queue exceeded its 128-event limit; the session was stopped to release held input.");
            lifetime.Cancel();
        }
    }

    private void OnRemoteKeyDown(object sender, KeyRoutedEventArgs args) => HandleKey(args, true);
    private void OnRemoteKeyUp(object sender, KeyRoutedEventArgs args) => HandleKey(args, false);
    private void HandleKey(KeyRoutedEventArgs args, bool down)
    {
        if (CurrentInputAccess is not { } access || args.KeyStatus.ScanCode > ushort.MaxValue ||
            !WindowsRemoteInputPolicy.TryMapWindowsKey(new((ushort)args.KeyStatus.ScanCode, args.KeyStatus.IsExtendedKey), out var key)) return;
        SynchronizeModifiers(access, key);
        if (down) _pressedKeys.Add(key);
        else if (!_pressedKeys.Remove(key)) return;
        Enqueue(new KeyInput(access, new(down ? "keyDown" : "keyUp", key, InputTime)));
        args.Handled = true;
    }

    private void SynchronizeModifiers(RemoteControlAccess access, ushort currentKey)
    {
        ReadOnlySpan<(VirtualKey Virtual, ushort Mac)> modifiers =
        [
            (VirtualKey.LeftShift, 0x38), (VirtualKey.RightShift, 0x3c),
            (VirtualKey.LeftControl, 0x3b), (VirtualKey.RightControl, 0x3e),
            (VirtualKey.LeftMenu, 0x3a), (VirtualKey.RightMenu, 0x3d),
            (VirtualKey.LeftWindows, 0x37), (VirtualKey.RightWindows, 0x36)
        ];
        foreach (var modifier in modifiers)
        {
            if (modifier.Mac == currentKey) continue;
            var down = (InputKeyboardSource.GetKeyStateForCurrentThread(modifier.Virtual) & CoreVirtualKeyStates.Down) != 0;
            var changed = down ? _pressedKeys.Add(modifier.Mac) : _pressedKeys.Remove(modifier.Mac);
            if (changed) Enqueue(new KeyInput(access, new(down ? "keyDown" : "keyUp", modifier.Mac, InputTime)));
        }
    }

    private bool ReadPointer(PointerRoutedEventArgs args, bool clamp)
    {
        if (_connection is null) return false;
        var (width, height) = _connection.VideoDimensions;
        if (width <= 0 || height <= 0 || InputSurface.ActualWidth <= 0 || InputSurface.ActualHeight <= 0) return false;
        var point = args.GetCurrentPoint(InputSurface).Position;
        var mapped = WindowsRemoteInputPolicy.MapViewerPointer(point.X, point.Y,
            InputSurface.ActualWidth, InputSurface.ActualHeight, width, height, clamp);
        if (mapped is not { } pixel) return false;
        _pointerX = pixel.X;
        _pointerY = pixel.Y;
        return true;
    }

    private void Pointer(RemoteControlAccess access, string type)
    {
        if (type != "mouseMoved") _pointerMotion.Reset();
        Enqueue(new PointerInput(access, new(type, _pointerX, _pointerY, InputTime, null)));
    }

    private void OnRemotePointerPressed(object sender, PointerRoutedEventArgs args)
    {
        if (CurrentInputAccess is not { } access || !ReadPointer(args, false)) return;
        if (!InputSurface.Focus(FocusState.Programmatic))
        {
            _inputFailure = new InvalidOperationException("The remote input surface could not receive keyboard focus.");
            _connectionLifetime?.Cancel();
            return;
        }
        var properties = args.GetCurrentPoint(InputSurface).Properties;
        if (properties.IsLeftButtonPressed && !_leftPressed) { _leftPressed = true; Pointer(access, "leftMouseDown"); }
        if (properties.IsRightButtonPressed && !_rightPressed) { _rightPressed = true; Pointer(access, "rightMouseDown"); }
        if (_leftPressed || _rightPressed) InputSurface.CapturePointer(args.Pointer);
        args.Handled = true;
    }

    private void OnRemotePointerReleased(object sender, PointerRoutedEventArgs args)
    {
        if (CurrentInputAccess is not { } access || !ReadPointer(args, true)) return;
        var properties = args.GetCurrentPoint(InputSurface).Properties;
        if (_leftPressed && !properties.IsLeftButtonPressed) { _leftPressed = false; Pointer(access, "leftMouseUp"); }
        if (_rightPressed && !properties.IsRightButtonPressed) { _rightPressed = false; Pointer(access, "rightMouseUp"); }
        if (!_leftPressed && !_rightPressed) InputSurface.ReleasePointerCapture(args.Pointer);
        args.Handled = true;
    }

    private void OnRemotePointerMoved(object sender, PointerRoutedEventArgs args)
    {
        if (CurrentInputAccess is not { } access || !ReadPointer(args, _leftPressed || _rightPressed)) return;
        if (!_pointerMotion.Accept(args.Pointer.PointerId, _pointerX, _pointerY)) return;
        Pointer(access, "mouseMoved");
        args.Handled = true;
    }

    private void OnRemotePointerWheel(object sender, PointerRoutedEventArgs args)
    {
        if (CurrentInputAccess is not { } access || !ReadPointer(args, false)) return;
        var delta = args.GetCurrentPoint(InputSurface).Properties.MouseWheelDelta;
        if (args.GetCurrentPoint(InputSurface).Properties.IsHorizontalMouseWheel) return;
        var steps = Math.DivRem(_wheelRemainder + delta, 120, out _wheelRemainder);
        for (var count = 0; count < Math.Abs(steps); count++) Pointer(access, steps > 0 ? "scrollUp" : "scrollDown");
        args.Handled = true;
    }

    private void OnViewerActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated) ReleaseInput();
    }
    private void OnInputLostFocus(object sender, RoutedEventArgs args) => ReleaseInput();
    private void OnInputPointerCaptureLost(object sender, PointerRoutedEventArgs args)
    {
        if (CurrentInputAccess is { } access)
        {
            if (_leftPressed) Pointer(access, "leftMouseUp");
            if (_rightPressed) Pointer(access, "rightMouseUp");
        }
        _leftPressed = false;
        _rightPressed = false;
    }
    private void ReleaseInput()
    {
        if (CurrentInputAccess is { } access)
        {
            foreach (var key in _pressedKeys) Enqueue(new KeyInput(access, new("keyUp", key, InputTime)));
            if (_leftPressed) Pointer(access, "leftMouseUp");
            if (_rightPressed) Pointer(access, "rightMouseUp");
        }
        ClearInputState();
    }
    private void ClearInputState() { _pressedKeys.Clear(); _leftPressed = false; _rightPressed = false; _wheelRemainder = 0; _pointerMotion.Reset(); }

    private abstract record InputCommand(RemoteControlAccess Access)
    {
        internal abstract Task SendAsync(WindowsRemoteControlViewer connection, CancellationToken token);
    }
    private sealed record KeyInput(RemoteControlAccess Grant, RemoteKeyEvent Event) : InputCommand(Grant)
    {
        internal override Task SendAsync(WindowsRemoteControlViewer connection, CancellationToken token) => connection.SendInputAsync("keyboardEvent", Event, Grant, token);
    }
    private sealed record PointerInput(RemoteControlAccess Grant, RemotePointerEvent Event) : InputCommand(Grant)
    {
        internal override Task SendAsync(WindowsRemoteControlViewer connection, CancellationToken token) => connection.SendInputAsync("mouseEvent", Event, Grant, token);
    }
}
