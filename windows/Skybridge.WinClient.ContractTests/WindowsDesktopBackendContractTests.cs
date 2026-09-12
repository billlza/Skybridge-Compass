using System.Buffers;
using Skybridge.WinClient.Services.RemoteControl;

internal static class WindowsDesktopBackendContractTests
{
    internal static IReadOnlyList<(string Name, Func<Task> Run)> Cases { get; } =
    [
        ("desktop input maps Mac physical keys and distinct modifiers", Run(TestKeyMappings)),
        ("desktop input preserves held modifiers and releases in reverse order", Run(TestInputOwnership)),
        ("desktop input never releases a locally held key", Run(TestLocallyHeldKey)),
        ("desktop input translates the Mac Fn layer without stranding keys", Run(TestFunctionLayer)),
        ("desktop input tracks partial native delivery for cleanup", Run(TestPartialTextDelivery)),
        ("desktop input retries only failed releases", Run(TestReleaseFailure)),
        ("desktop input rejects a locked desktop before sending", Run(TestLockedDesktop)),
        ("desktop input validates UTF16 before native side effects", Run(TestTextValidation)),
        ("desktop pointer maps negative-origin displays in physical coordinates", Run(TestPointerMapping)),
        ("desktop pointer rejects nonfinite coordinates and stale display bounds", Run(TestInvalidPointer)),
        ("desktop pixels rotate portrait and flipped outputs", Run(TestRotations)),
        ("desktop pointer composition handles color masks and clipping", Run(TestPointerComposition)),
        ("desktop scaled pointer preserves physical position and color samples", Run(TestScaledColorPointer)),
        ("desktop scaled pointer preserves masked and monochrome operations", Run(TestScaledPointerMasks)),
        ("desktop scaled pointer clips extreme coordinates and validates dimensions", Run(TestScaledPointerBounds)),
        ("desktop H264 IDR carries SPS and PPS exactly once", Run(TestH264Configuration)),
        ("desktop H264 rejects malformed access units and missing configuration", Run(TestInvalidH264)),
        ("desktop encoder configuration validates dimensions frame rate and bitrate", Run(TestEncoderOptions)),
        ("desktop frame disposal invalidates owned pixel access", Run(TestFrameOwnership))
    ];

    private static Func<Task> Run(Action test) => () => { test(); return Task.CompletedTask; };
    private static WindowsDesktopDisplay Display => new("0000000000000001:0", "Display", 0, 0, 1920, 1080, true);
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static T Throws<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T expected) { return expected; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private static void TestKeyMappings()
    {
        Require(WindowsRemoteInputPolicy.MapMacKey(0) == new WindowsScanKey(0x1e), "Mac A must use Windows physical A position.");
        Require(WindowsRemoteInputPolicy.MapMacKey(0x24) == new WindowsScanKey(0x1c), "Main return must be nonextended.");
        Require(WindowsRemoteInputPolicy.MapMacKey(0x4c) == new WindowsScanKey(0x1c, true), "Keypad enter must remain extended.");
        Require(WindowsRemoteInputPolicy.MapMacKey(0x3b) == new WindowsScanKey(0x1d), "Left Control mapping mismatch.");
        Require(WindowsRemoteInputPolicy.MapMacKey(0x3e) == new WindowsScanKey(0x1d, true), "Right Control mapping mismatch.");
        Require(WindowsRemoteInputPolicy.MapMacKey(0x37) == new WindowsScanKey(0x5b, true), "Command must map to the Windows key.");
        Require(WindowsRemoteInputPolicy.MapMacKey(0x7e) == new WindowsScanKey(0x48, true), "Up arrow must remain extended.");
        Require(WindowsRemoteInputPolicy.MapMacKey(0x5a) == new WindowsScanKey(0x6b), "F20 mapping mismatch.");
        Require(WindowsRemoteInputPolicy.MapMacKey(0x5d) == new WindowsScanKey(0x7d), "JIS Yen mapping mismatch.");
        Throws<WindowsDesktopException>(() => WindowsRemoteInputPolicy.MapMacKey(0xffff));
        Throws<WindowsDesktopException>(() => WindowsRemoteInputPolicy.MapMacKey(0x3f));
    }

    private static void TestInputOwnership()
    {
        var platform = new RecordingInputPlatform();
        using var input = new WindowsRemoteInput(Display, platform);
        input.SetKey(0x37, true);
        input.SetKey(0, true, WindowsRemoteModifiers.None);
        input.SetKey(0, true);
        input.SetMouseButton(WindowsRemoteMouseButton.Left, true);
        Require(platform.Delivered.Count == 4 && platform.Delivered.All(command => command.Down), "An ordinary key event must not clear held modifiers.");
        input.ReleaseAll();
        var releases = platform.Delivered.Skip(4).ToArray();
        Require(releases.Length == 3, "Repeated down must not create duplicate ownership.");
        Require(releases[0].Kind == WindowsInputKind.MouseButton && releases[1].Code == 0x1e && releases[2].Code == 0x5b,
            "Held input must release in reverse successful-down order.");
        Require(releases.All(command => !command.Down), "Cleanup must contain only key/button releases.");
        input.SetKey(0, false);
        input.ReleaseAll();
        Require(platform.Delivered.Count == 7, "A stale keyUp or repeated release must be harmless.");
    }

    private static void TestLocallyHeldKey()
    {
        var platform = new RecordingInputPlatform { LocalDown = true };
        using var input = new WindowsRemoteInput(Display, platform);
        input.SetKey(0x38, true);
        input.SetKey(0x38, false);
        input.ReleaseAll();
        Require(platform.Delivered.Count == 0, "A remote session must not own or release a key already held locally.");
    }

    private static void TestFunctionLayer()
    {
        var platform = new RecordingInputPlatform();
        using var input = new WindowsRemoteInput(Display, platform);
        input.SetKey(0x3f, true);
        input.SetKey(0x33, true);
        input.SetKey(0x3f, false);
        input.SetKey(0x33, false);
        Require(platform.Delivered.Count == 2 && platform.Delivered.All(command => command.Code == 0x53 && command.Extended),
            "Fn release before Delete release must still release the same resolved Windows scan code.");
        input.SetKey(0x3f, true);
        input.SetKey(0x7a, true); input.SetKey(0x7a, false);
        input.ReleaseAll();
        input.SetKey(0x33, true); input.SetKey(0x33, false);
        Require(platform.Delivered[2].Code == 0x3b && platform.Delivered[4].Code == 0x0e,
            "Fn must preserve F1 while cleanup resets its navigation layer.");
    }

    private static void TestPartialTextDelivery()
    {
        var platform = new RecordingInputPlatform { NextInserted = 1 };
        using var input = new WindowsRemoteInput(Display, platform);
        var failure = Throws<WindowsDesktopException>(() => input.TypeText("A"));
        Require(failure.Failure == WindowsDesktopFailure.InputRejected, "Partial SendInput must surface as input failure.");
        Require(platform.Delivered.Count == 1 && platform.Delivered[0].Down, "The native delivered prefix must be retained.");
        input.ReleaseAll();
        Require(platform.Delivered.Count == 2 && !platform.Delivered[1].Down && platform.Delivered[1].Code == 'A',
            "Cleanup must release the Unicode key left down by partial native delivery.");
    }

    private static void TestReleaseFailure()
    {
        var platform = new RecordingInputPlatform();
        using var input = new WindowsRemoteInput(Display, platform);
        input.SetKey(0x38, true); input.SetKey(0, true);
        platform.NextInserted = 0;
        Throws<AggregateException>(input.ReleaseAll);
        Require(platform.Delivered.Count == 3 && platform.Delivered[2].Code == 0x2a, "Other releases must continue after one native failure.");
        input.ReleaseAll();
        Require(platform.Delivered.Count == 4 && platform.Delivered[3].Code == 0x1e && !platform.Delivered[3].Down,
            "Only the failed A release should remain for retry.");
    }

    private static void TestLockedDesktop()
    {
        var platform = new RecordingInputPlatform();
        var input = new WindowsRemoteInput(Display, platform);
        input.SetKey(0, true);
        platform.Available = false;
        Throws<WindowsDesktopException>(() => input.SetKey(1, true));
        Throws<WindowsDesktopException>(input.Dispose);
        Require(platform.Delivered.Count == 1, "A protected desktop must receive no injected events.");
        platform.Available = true;
        input.Dispose();
        Require(platform.Delivered.Count == 2 && !platform.Delivered[1].Down, "Failed dispose must retain exact input ownership for retry.");
        input.Dispose();
    }

    private static void TestTextValidation()
    {
        var platform = new RecordingInputPlatform();
        using var input = new WindowsRemoteInput(Display, platform);
        Throws<ArgumentException>(() => input.TypeText("\ud800"));
        Throws<ArgumentException>(() => input.TypeText("\udc00"));
        Throws<ArgumentException>(() => input.TypeText("x\0y"));
        Throws<ArgumentOutOfRangeException>(() => input.TypeText(new string('a', 4097)));
        Require(platform.Delivered.Count == 0, "Invalid text must fail before native input.");
        input.TypeText("中\U0001f310");
        Require(platform.Delivered.Count == 6 && platform.Delivered[2].Code == 0xd83c && platform.Delivered[4].Code == 0xdf10,
            "Supplementary Unicode input must preserve both UTF-16 surrogate units.");
    }

    private static void TestPointerMapping()
    {
        var display = new WindowsDesktopDisplay("id", "left", -1920, -200, 1920, 1080, false);
        var desktop = new WindowsDesktopBounds(-1920, -200, 3840, 1280);
        Require(WindowsRemoteInputPolicy.MapPointer(0, 0, display, desktop) == (0, 0), "Negative-origin monitor top-left must map to virtual top-left.");
        var far = WindowsRemoteInputPolicy.MapPointer(1, 1, display, desktop);
        Require(far.X == (int)Math.Round(1919 * 65535d / 3839) && far.Y == (int)Math.Round(1079 * 65535d / 1279),
            "Display endpoints must use physical pixels and the full virtual desktop, independent of DPI.");
    }

    private static void TestInvalidPointer()
    {
        var desktop = new WindowsDesktopBounds(0, 0, 1920, 1080);
        foreach (var invalid in new[] { double.NaN, double.PositiveInfinity, -0.01, 1.01 })
            Throws<ArgumentOutOfRangeException>(() => WindowsRemoteInputPolicy.MapPointer(invalid, 0, Display, desktop));
        Throws<WindowsDesktopException>(() => WindowsRemoteInputPolicy.MapPointer(0, 0, Display, desktop with { Width = 100 }));
    }

    private static byte[] Pixels(params byte[] values) => values.SelectMany(value => new[] { value, value, value, (byte)255 }).ToArray();
    private static void TestRotations()
    {
        var source = Pixels(1, 2, 3, 4, 5, 6);
        var output = new byte[source.Length];
        WindowsDesktopPixels.RotateBgra(source, 2, 3, WindowsDesktopRotation.Clockwise90, output);
        Require(output.SequenceEqual(Pixels(5, 3, 1, 6, 4, 2)), "90-degree rotation geometry is incorrect.");
        WindowsDesktopPixels.RotateBgra(source, 2, 3, WindowsDesktopRotation.Clockwise180, output);
        Require(output.SequenceEqual(Pixels(6, 5, 4, 3, 2, 1)), "180-degree rotation geometry is incorrect.");
        WindowsDesktopPixels.RotateBgra(source, 2, 3, WindowsDesktopRotation.Clockwise270, output);
        Require(output.SequenceEqual(Pixels(2, 4, 6, 1, 3, 5)), "270-degree rotation geometry is incorrect.");
    }

    private static void TestPointerComposition()
    {
        var pixels = Pixels(10, 20);
        var mono = new WindowsDesktopPointerShape(WindowsDesktopPointerKind.Monochrome, 2, 2, 1, [0x80, 0xc0]);
        WindowsDesktopPixels.CompositePointer(pixels, 2, 1, mono, 0, 0);
        Require(pixels.SequenceEqual(Pixels(245, 255)), "Monochrome AND/XOR pointer masks are incorrect.");
        pixels = Pixels(10, 20);
        var masked = new WindowsDesktopPointerShape(WindowsDesktopPointerKind.MaskedColor, 2, 1, 8, [30, 30, 30, 0, 15, 15, 15, 255]);
        WindowsDesktopPixels.CompositePointer(pixels, 2, 1, masked, -1, 0);
        Require(pixels.SequenceEqual(Pixels(5, 20)), "Masked pointer clipping or XOR composition is incorrect.");
        pixels = Pixels(20);
        var color = new WindowsDesktopPointerShape(WindowsDesktopPointerKind.Color, 1, 1, 4, [100, 100, 100, 128]);
        WindowsDesktopPixels.CompositePointer(pixels, 1, 1, color, 0, 0);
        Require(pixels.SequenceEqual(Pixels(60)), "Color pointer alpha composition is incorrect.");
    }

    private static void TestScaledColorPointer()
    {
        var pixels = Pixels(10, 10, 10, 10, 10, 10, 10, 10);
        var color = new WindowsDesktopPointerShape(WindowsDesktopPointerKind.Color, 4, 2, 16,
            Pixels(0, 10, 20, 30, 40, 50, 60, 70));
        WindowsDesktopPixels.CompositePointer(pixels, 4, 2, color, 2, 0, 8, 4);
        Require(pixels.SequenceEqual(Pixels(10, 50, 70, 10, 10, 10, 10, 10)),
            "A half-size frame must scale the physical pointer position and nearest shape samples together.");
    }

    private static void TestScaledPointerMasks()
    {
        var pixels = Pixels(10, 20);
        var maskedPixels = Pixels(0, 0, 0, 0, 0, 30, 0, 15);
        maskedPixels[5 * 4 + 3] = 0;
        var masked = new WindowsDesktopPointerShape(WindowsDesktopPointerKind.MaskedColor, 4, 2, 16, maskedPixels);
        WindowsDesktopPixels.CompositePointer(pixels, 2, 1, masked, 0, 0, 4, 2);
        Require(pixels.SequenceEqual(Pixels(30, 27)), "Scaled masked color must preserve replacement and XOR semantics.");
        pixels = Pixels(10, 20);
        var mono = new WindowsDesktopPointerShape(WindowsDesktopPointerKind.Monochrome, 4, 4, 1, [0xf0, 0xf0, 0x50, 0x50]);
        WindowsDesktopPixels.CompositePointer(pixels, 2, 1, mono, -2, 0, 4, 2);
        Require(pixels.SequenceEqual(Pixels(245, 20)), "Scaled monochrome masks must retain negative-origin clipping and AND/XOR semantics.");
    }

    private static void TestScaledPointerBounds()
    {
        var shape = new WindowsDesktopPointerShape(WindowsDesktopPointerKind.Color, 1, 1, 4, Pixels(100));
        var pixels = Pixels(10);
        WindowsDesktopPixels.CompositePointer(pixels, 1, 1, shape, int.MaxValue, int.MinValue, 4096, 4096);
        Require(pixels.SequenceEqual(Pixels(10)), "An off-screen cursor must not overflow coordinates or affect output.");
        WindowsDesktopPixels.CompositePointer(pixels, 1, 1, shape, 2, 2, 4096, 4096);
        Require(pixels.SequenceEqual(Pixels(100)), "A visible subpixel pointer footprint must retain a sample.");
        Throws<ArgumentException>(() => WindowsDesktopPixels.CompositePointer(pixels, 1, 1, shape, 0, 0, 0, 1));
        Throws<ArgumentException>(() => WindowsDesktopPixels.CompositePointer(pixels, 1, 1, shape, 0, 0, 1));
    }

    private static void TestH264Configuration()
    {
        byte[] headers = [0, 0, 0, 1, 0x67, 0x42, 0, 0, 1, 0x68, 0xce];
        byte[] picture = [0, 0, 0, 1, 0x65, 0x12];
        var prepared = WindowsH264AccessUnit.Prepare(picture, headers, out var keyFrame);
        Require(keyFrame, "IDR must be recognized from actual NAL type.");
        Require(WindowsH264AccessUnit.Parse(prepared).Select(unit => unit.Type).SequenceEqual(new[] { 7, 8, 5 }),
            "Each IDR must start with SPS and PPS.");
        var unchanged = WindowsH264AccessUnit.Prepare(prepared, headers, out _);
        Require(unchanged.SequenceEqual(prepared), "Existing in-band decoder configuration must not be duplicated.");
        byte[] predicted = [0, 0, 1, 0x61, 0x55];
        Require(WindowsH264AccessUnit.Prepare(predicted, [], out var predictedKey).SequenceEqual(predicted) && !predictedKey,
            "Predicted frames must remain predicted and not require redundant parameter sets.");
    }

    private static void TestInvalidH264()
    {
        Throws<WindowsDesktopException>(() => WindowsH264AccessUnit.Prepare([0, 0, 0, 1, 0x65, 1], [], out _));
        Throws<WindowsDesktopException>(() => WindowsH264AccessUnit.Parse([0, 0, 0, 1]));
        Throws<WindowsDesktopException>(() => WindowsH264AccessUnit.Parse([0, 0, 0, 2, 0x65, 1]));
        Throws<WindowsDesktopException>(() => WindowsH264AccessUnit.Parse([0, 0, 1, 0xe5, 1]));
    }

    private static void TestEncoderOptions()
    {
        new WindowsDesktopEncodingOptions(1280, 720, 2, 256000).RequireValid();
        Throws<ArgumentOutOfRangeException>(() => new WindowsDesktopEncodingOptions(1279, 720, 2, 256000).RequireValid());
        Throws<ArgumentOutOfRangeException>(() => new WindowsDesktopEncodingOptions(8192, 8192, 60, 8000000).RequireValid());
        Throws<ArgumentOutOfRangeException>(() => new WindowsDesktopEncodingOptions(1280, 720, 0, 256000).RequireValid());
        Throws<ArgumentOutOfRangeException>(() => new WindowsDesktopEncodingOptions(1280, 720, 60, 1).RequireValid());
    }

    private static void TestFrameOwnership()
    {
        var frame = new WindowsDesktopFrame(ArrayPool<byte>.Shared.Rent(16), 2, 2, 10, 1_700_000_000, false);
        Require(frame.BgraPixels.Length == 16 && frame.Stride == 8, "A frame must expose only its owned image extent.");
        frame.Dispose(); frame.Dispose();
        Throws<ObjectDisposedException>(() => { _ = frame.BgraPixels; });
    }

    private sealed class RecordingInputPlatform : IWindowsInputPlatform
    {
        internal bool Available { get; set; } = true;
        internal bool LocalDown { get; set; }
        internal uint? NextInserted { get; set; }
        internal List<WindowsInputCommand> Delivered { get; } = new();
        public void RequireDesktop()
        {
            if (!Available) throw new WindowsDesktopException(WindowsDesktopFailure.InteractiveDesktopUnavailable, "Locked test desktop.");
        }
        public WindowsDesktopBounds GetDesktopBounds() => new(0, 0, 1920, 1080);
        public bool IsAlreadyDown(WindowsInputCommand command) => LocalDown;
        public WindowsInputDelivery Send(WindowsInputCommand[] commands)
        {
            var inserted = NextInserted ?? (uint)commands.Length;
            NextInserted = null;
            Delivered.AddRange(commands.Take((int)inserted));
            return new(inserted, inserted == commands.Length ? 0 : 5);
        }
    }
}
