using System;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Skybridge.WinClient.ViewModels;

// =====================================================================================
//  AvatarUrlToImageSourceConverter — turns the signed-in user's avatar_url string into a
//  BitmapImage the account block's Ellipse ImageBrush binds to. Returns null for any
//  empty/invalid/non-http(s) URL so the accent-glyph fallback (the person glyph) shows
//  through instead of a broken-image box.
//
//  Only http/https URLs are accepted: this avoids handing the ImageBrush a file:// or other
//  scheme that could read off-disk, and matches the Mac (remote profile avatar only). A
//  malformed URL never throws — it degrades to null (glyph fallback).
// =====================================================================================

public sealed class AvatarUrlToImageSourceConverter : IValueConverter
{
    public object? Convert(object value, Type targetType, object parameter, string language)
    {
        var url = value as string;
        if (string.IsNullOrWhiteSpace(url))
        {
            return null;
        }

        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri))
        {
            return null;
        }

        // http/https only — reject file://, data:, etc.
        if (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps)
        {
            return null;
        }

        try
        {
            return new BitmapImage(uri);
        }
        catch (Exception)
        {
            return null;
        }
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
