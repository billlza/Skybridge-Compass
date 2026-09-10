namespace Skybridge.WinClient.Services.RemoteControl;

[Flags]
internal enum WindowsRemoteModifiers { None = 0, Shift = 1, Control = 2, Alt = 4, Command = 8 }
internal enum WindowsRemoteMouseButton { Left, Right, Middle, Extra1, Extra2 }
internal readonly record struct WindowsScanKey(ushort ScanCode, bool Extended = false);
internal readonly record struct WindowsDesktopBounds(int Left, int Top, int Width, int Height);

internal static class WindowsRemoteInputPolicy
{
    /// <summary>Maps Apple's physical virtual-key positions to Windows set-1 scan codes.</summary>
    private static readonly IReadOnlyDictionary<ushort, WindowsScanKey> PhysicalKeys = new Dictionary<ushort, WindowsScanKey>
    {
        [0x00] = new(0x1e), [0x01] = new(0x1f), [0x02] = new(0x20), [0x03] = new(0x21),
        [0x04] = new(0x23), [0x05] = new(0x22), [0x06] = new(0x2c), [0x07] = new(0x2d),
        [0x08] = new(0x2e), [0x09] = new(0x2f), [0x0a] = new(0x56), [0x0b] = new(0x30),
        [0x0c] = new(0x10), [0x0d] = new(0x11), [0x0e] = new(0x12), [0x0f] = new(0x13),
        [0x10] = new(0x15), [0x11] = new(0x14), [0x12] = new(0x02), [0x13] = new(0x03),
        [0x14] = new(0x04), [0x15] = new(0x05), [0x16] = new(0x07), [0x17] = new(0x06),
        [0x18] = new(0x0d), [0x19] = new(0x0a), [0x1a] = new(0x08), [0x1b] = new(0x0c),
        [0x1c] = new(0x09), [0x1d] = new(0x0b), [0x1e] = new(0x1b), [0x1f] = new(0x18),
        [0x20] = new(0x16), [0x21] = new(0x1a), [0x22] = new(0x17), [0x23] = new(0x19),
        [0x24] = new(0x1c), [0x25] = new(0x26), [0x26] = new(0x24), [0x27] = new(0x28),
        [0x28] = new(0x25), [0x29] = new(0x27), [0x2a] = new(0x2b), [0x2b] = new(0x33),
        [0x2c] = new(0x35), [0x2d] = new(0x31), [0x2e] = new(0x32), [0x2f] = new(0x34),
        [0x30] = new(0x0f), [0x31] = new(0x39), [0x32] = new(0x29), [0x33] = new(0x0e),
        [0x34] = new(0x1c, true), [0x35] = new(0x01),
        [0x36] = new(0x5c, true), [0x37] = new(0x5b, true),
        [0x38] = new(0x2a), [0x39] = new(0x3a), [0x3a] = new(0x38), [0x3b] = new(0x1d),
        [0x3c] = new(0x36), [0x3d] = new(0x38, true), [0x3e] = new(0x1d, true),
        [0x40] = new(0x68), // F17
        [0x41] = new(0x53), [0x43] = new(0x37), [0x45] = new(0x4e), [0x47] = new(0x45, true),
        [0x48] = new(0x30, true), [0x49] = new(0x2e, true), [0x4a] = new(0x20, true), // volume up/down/mute
        [0x4b] = new(0x35, true), [0x4c] = new(0x1c, true), [0x4e] = new(0x4a),
        [0x4f] = new(0x69), [0x50] = new(0x6a), // F18, F19
        [0x51] = new(0x59), // keypad equals
        [0x52] = new(0x52), [0x53] = new(0x4f), [0x54] = new(0x50), [0x55] = new(0x51),
        [0x56] = new(0x4b), [0x57] = new(0x4c), [0x58] = new(0x4d), [0x59] = new(0x47),
        [0x5a] = new(0x6b), [0x5b] = new(0x48), [0x5c] = new(0x49), // F20, keypad8/9
        [0x5d] = new(0x7d), [0x5e] = new(0x73), [0x5f] = new(0x7e), // JIS Yen, underscore, keypad comma
        [0x60] = new(0x3f), [0x61] = new(0x40), [0x62] = new(0x41), [0x63] = new(0x3d),
        [0x64] = new(0x42), [0x65] = new(0x43), [0x66] = new(0x7b), // JIS Eisu
        [0x67] = new(0x57), [0x68] = new(0x70), [0x69] = new(0x64), // F11, JIS Kana, F13
        [0x6a] = new(0x67), [0x6b] = new(0x65), [0x6d] = new(0x44), // F16, F14, F10
        [0x6e] = new(0x5d, true), // context menu
        [0x6f] = new(0x58), [0x71] = new(0x66), // F12, F15
        [0x72] = new(0x52, true), [0x73] = new(0x47, true), [0x74] = new(0x49, true),
        [0x75] = new(0x53, true), [0x76] = new(0x3e), [0x77] = new(0x4f, true),
        [0x78] = new(0x3c), [0x79] = new(0x51, true), [0x7a] = new(0x3b),
        [0x7b] = new(0x4b, true), [0x7c] = new(0x4d, true), [0x7d] = new(0x50, true), [0x7e] = new(0x48, true),
    };
    private static readonly IReadOnlyDictionary<WindowsScanKey, ushort> MacKeys = PhysicalKeys
        .Where(item => item.Key != 0x34) // The keypad Enter alias uses its canonical 0x4c position when sending.
        .ToDictionary(item => item.Value, item => item.Key);

    public static WindowsScanKey MapMacKey(ushort keyCode) => PhysicalKeys.TryGetValue(keyCode, out var key)
        ? key : throw new WindowsDesktopException(WindowsDesktopFailure.InputRejected,
            $"Mac key code 0x{keyCode:x4} has no supported Windows physical-key mapping.");

    public static bool TryMapWindowsKey(WindowsScanKey key, out ushort macKeyCode) => MacKeys.TryGetValue(key, out macKeyCode);

    /// <summary>Maps a uniformly fitted viewer surface to the protocol's visible-frame pixels.</summary>
    /// <returns>Null only when a new pointer action falls outside the displayed image.</returns>
    public static (double X, double Y)? MapViewerPointer(double x, double y,
        double surfaceWidth, double surfaceHeight, int frameWidth, int frameHeight, bool clamp)
    {
        if (!double.IsFinite(x) || !double.IsFinite(y) || !double.IsFinite(surfaceWidth) ||
            !double.IsFinite(surfaceHeight) || surfaceWidth <= 0 || surfaceHeight <= 0 ||
            frameWidth < 2 || frameHeight < 2)
            throw new ArgumentOutOfRangeException(nameof(surfaceWidth), "Viewer pointer mapping requires finite coordinates and positive geometry.");
        var scale = Math.Min(surfaceWidth / frameWidth, surfaceHeight / frameHeight);
        var frameX = (x - (surfaceWidth - frameWidth * scale) / 2) / scale;
        var frameY = (y - (surfaceHeight - frameHeight * scale) / 2) / scale;
        if (!clamp && (frameX < 0 || frameY < 0 || frameX > frameWidth || frameY > frameHeight)) return null;
        return (Math.Clamp(frameX, 0, frameWidth - 1d), Math.Clamp(frameY, 0, frameHeight - 1d));
    }

    public static (int X, int Y) MapPointer(
        double normalizedX, double normalizedY, WindowsDesktopDisplay display, WindowsDesktopBounds desktop)
    {
        if (!double.IsFinite(normalizedX) || !double.IsFinite(normalizedY) ||
            normalizedX is < 0 or > 1 || normalizedY is < 0 or > 1)
            throw new ArgumentOutOfRangeException(nameof(normalizedX), "Pointer coordinates must be finite and normalized to [0,1].");
        if (display.Width < 1 || display.Height < 1 || desktop.Width < 2 || desktop.Height < 2 ||
            display.Left < desktop.Left || display.Top < desktop.Top ||
            (long)display.Left + display.Width > (long)desktop.Left + desktop.Width ||
            (long)display.Top + display.Height > (long)desktop.Top + desktop.Height)
            throw new WindowsDesktopException(WindowsDesktopFailure.DisplayConfigurationChanged,
                "The selected display no longer fits the current physical virtual desktop.");
        var x = display.Left + normalizedX * (display.Width - 1L) - desktop.Left;
        var y = display.Top + normalizedY * (display.Height - 1L) - desktop.Top;
        return ((int)Math.Round(x * 65535 / (desktop.Width - 1L)),
            (int)Math.Round(y * 65535 / (desktop.Height - 1L)));
    }

    public static void RequireValidText(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (text.Length is < 1 or > 4096)
            throw new ArgumentOutOfRangeException(nameof(text), "A text event must contain between 1 and 4096 UTF-16 code units.");
        for (var index = 0; index < text.Length; index++)
        {
            var value = text[index];
            if (value == '\0') throw new ArgumentException("Text input cannot contain NUL.", nameof(text));
            if (!char.IsSurrogate(value)) continue;
            if (!char.IsHighSurrogate(value) || index + 1 == text.Length || !char.IsLowSurrogate(text[++index]))
                throw new ArgumentException("Text input must contain valid UTF-16.", nameof(text));
        }
    }
}
