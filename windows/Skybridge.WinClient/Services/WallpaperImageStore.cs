using System;
using System.IO;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Windows.Graphics.Imaging;
using Windows.Storage;

namespace Skybridge.WinClient.Services;

public sealed record WallpaperPixels(int Width, int Height, byte[] Rgba);

internal static class WallpaperImageStore
{
    private const long MaximumFileBytes = 64L * 1024 * 1024;
    private const uint MaximumDecodedSide = 4096;

    public static async Task<WallpaperPixels> DecodeAsync(string path, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var info = new FileInfo(path);
        if (info.Length is <= 0 or > MaximumFileBytes) throw new InvalidDataException("Wallpaper image must be smaller than 64 MB.");
        var file = await StorageFile.GetFileFromPathAsync(path).AsTask(cancellationToken);
        using var stream = await file.OpenReadAsync().AsTask(cancellationToken);
        var decoder = await BitmapDecoder.CreateAsync(stream).AsTask(cancellationToken);
        if (decoder.OrientedPixelWidth == 0 || decoder.OrientedPixelHeight == 0
            || (ulong)decoder.OrientedPixelWidth * decoder.OrientedPixelHeight > 128UL * 1024 * 1024)
            throw new InvalidDataException("Wallpaper dimensions are unsupported.");
        var scale = Math.Min(1.0, (double)MaximumDecodedSide / Math.Max(decoder.OrientedPixelWidth, decoder.OrientedPixelHeight));
        uint width = Math.Max(1, (uint)Math.Round(decoder.OrientedPixelWidth * scale));
        uint height = Math.Max(1, (uint)Math.Round(decoder.OrientedPixelHeight * scale));
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Rgba8, BitmapAlphaMode.Straight,
            new BitmapTransform { ScaledWidth = width, ScaledHeight = height, InterpolationMode = BitmapInterpolationMode.Fant },
            ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb).AsTask(cancellationToken);
        var pixels = new byte[checked(bitmap.PixelWidth * bitmap.PixelHeight * 4)];
        bitmap.CopyToBuffer(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(pixels));
        cancellationToken.ThrowIfCancellationRequested();
        return new(bitmap.PixelWidth, bitmap.PixelHeight, pixels);
    }

    public static async Task<string> ImportAsync(string path, CancellationToken cancellationToken)
    {
        // Validate before choosing this file. Keep an app-owned immutable copy so
        // moving or deleting the original picture cannot break the next launch.
        await DecodeAsync(path, cancellationToken);
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SkyBridge", "wallpapers");
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            await using (var input = File.OpenRead(path))
            await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, useAsync: true))
            {
                if (input.Length is <= 0 or > MaximumFileBytes) throw new InvalidDataException("Wallpaper image size changed during import.");
                await input.CopyToAsync(output, cancellationToken);
                await output.FlushAsync(cancellationToken);
            }
            // Validate the exact copied bytes, not a possibly changed source path.
            await DecodeAsync(temporary, cancellationToken);
            await using var copied = File.OpenRead(temporary);
            var hash = Convert.ToHexString(await SHA256.HashDataAsync(copied, cancellationToken));
            await copied.DisposeAsync();
            var destination = Path.Combine(directory, hash + Path.GetExtension(path).ToLowerInvariant());
            if (!File.Exists(destination)) File.Move(temporary, destination);
            else
            {
                await using var existing = File.OpenRead(destination);
                if (Convert.ToHexString(await SHA256.HashDataAsync(existing, cancellationToken)) != hash)
                    throw new InvalidDataException("The saved wallpaper does not match its content hash.");
            }
            return destination;
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}
