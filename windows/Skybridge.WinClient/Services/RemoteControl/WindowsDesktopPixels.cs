namespace Skybridge.WinClient.Services.RemoteControl;

internal enum WindowsDesktopRotation { Identity, Clockwise90, Clockwise180, Clockwise270 }
internal enum WindowsDesktopPointerKind { Monochrome = 1, Color = 2, MaskedColor = 4 }
internal sealed record WindowsDesktopPointerShape(
    WindowsDesktopPointerKind Kind, int Width, int Height, int Pitch, byte[] Pixels);

internal static class WindowsDesktopPixels
{
    public static void RotateBgra(ReadOnlySpan<byte> source, int width, int height,
        WindowsDesktopRotation rotation, Span<byte> destination)
    {
        var bytes = checked(width * height * 4);
        if (width < 1 || height < 1 || source.Length != bytes || destination.Length != bytes)
            throw new ArgumentException("Rotation requires complete BGRA source and destination images.");
        if (rotation == WindowsDesktopRotation.Identity) { source.CopyTo(destination); return; }
        if (!Enum.IsDefined(rotation)) throw new ArgumentOutOfRangeException(nameof(rotation));
        var destinationWidth = rotation == WindowsDesktopRotation.Clockwise180 ? width : height;
        for (var sourceY = 0; sourceY < height; sourceY++)
        for (var sourceX = 0; sourceX < width; sourceX++)
        {
            var (x, y) = rotation switch
            {
                WindowsDesktopRotation.Clockwise90 => (height - 1 - sourceY, sourceX),
                WindowsDesktopRotation.Clockwise180 => (width - 1 - sourceX, height - 1 - sourceY),
                WindowsDesktopRotation.Clockwise270 => (sourceY, width - 1 - sourceX),
                _ => throw new ArgumentOutOfRangeException(nameof(rotation))
            };
            source.Slice((sourceY * width + sourceX) * 4, 4)
                .CopyTo(destination.Slice((y * destinationWidth + x) * 4, 4));
        }
    }

    public static void CompositePointer(Span<byte> destination, int width, int height,
        WindowsDesktopPointerShape shape, int pointerX, int pointerY, int? coordinateWidth = null, int? coordinateHeight = null)
    {
        ArgumentNullException.ThrowIfNull(shape);
        if (width < 1 || height < 1 || destination.Length != checked(width * height * 4))
            throw new ArgumentException("Pointer composition requires a complete BGRA destination.");
        if (coordinateWidth.HasValue != coordinateHeight.HasValue || coordinateWidth is < 1 || coordinateHeight is < 1)
            throw new ArgumentException("Pointer coordinate dimensions must be positive and supplied together.");
        var monochrome = shape.Kind == WindowsDesktopPointerKind.Monochrome;
        if (!Enum.IsDefined(shape.Kind) || shape.Width is < 1 or > 1024 || shape.Height is < 1 or > 2048 ||
            shape.Pitch < (monochrome ? (shape.Width + 7) / 8 : shape.Width * 4) ||
            (monochrome && (shape.Height & 1) != 0) || (long)shape.Pitch * shape.Height > shape.Pixels.Length)
            throw new WindowsDesktopException(WindowsDesktopFailure.CaptureFailed, "DXGI returned an invalid desktop pointer shape.");
        var visibleHeight = monochrome ? shape.Height / 2 : shape.Height;
        var scaleX = width / (double)(coordinateWidth ?? width);
        var scaleY = height / (double)(coordinateHeight ?? height);
        var left = (int)Math.Clamp(Math.Floor(pointerX * scaleX), 0, width);
        var right = (int)Math.Clamp(Math.Ceiling(((double)pointerX + shape.Width) * scaleX), 0, width);
        var top = (int)Math.Clamp(Math.Floor(pointerY * scaleY), 0, height);
        var bottom = (int)Math.Clamp(Math.Ceiling(((double)pointerY + visibleHeight) * scaleY), 0, height);
        for (var targetY = top; targetY < bottom; targetY++)
        {
            var y = (int)Math.Clamp(Math.Floor((targetY + 0.5) / scaleY - pointerY), 0, visibleHeight - 1);
            for (var targetX = left; targetX < right; targetX++)
            {
                var x = (int)Math.Clamp(Math.Floor((targetX + 0.5) / scaleX - pointerX), 0, shape.Width - 1);
                var target = (targetY * width + targetX) * 4;
                if (monochrome)
                {
                    var mask = 0x80 >> (x % 8);
                    var andValue = (shape.Pixels[y * shape.Pitch + x / 8] & mask) == 0 ? 0 : 255;
                    var xorValue = (shape.Pixels[(y + visibleHeight) * shape.Pitch + x / 8] & mask) == 0 ? 0 : 255;
                    for (var channel = 0; channel < 3; channel++)
                        destination[target + channel] = (byte)((destination[target + channel] & andValue) ^ xorValue);
                }
                else
                {
                    var source = y * shape.Pitch + x * 4;
                    var alpha = shape.Pixels[source + 3];
                    if (shape.Kind == WindowsDesktopPointerKind.MaskedColor)
                    {
                        if (alpha is not 0 and not 255)
                            throw new WindowsDesktopException(WindowsDesktopFailure.CaptureFailed, "DXGI returned an invalid masked-color pointer alpha.");
                        for (var channel = 0; channel < 3; channel++)
                            destination[target + channel] = alpha == 0 ? shape.Pixels[source + channel]
                                : (byte)(destination[target + channel] ^ shape.Pixels[source + channel]);
                    }
                    else
                    {
                        for (var channel = 0; channel < 3; channel++)
                            destination[target + channel] = (byte)((shape.Pixels[source + channel] * alpha +
                                destination[target + channel] * (255 - alpha) + 127) / 255);
                    }
                }
                destination[target + 3] = 255;
            }
        }
    }
}
