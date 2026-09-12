using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Vortice.MediaFoundation;

namespace Skybridge.WinClient.Services.RemoteControl;

/// <summary>The small CodecAPI/activation surface absent from the Vortice MF package.</summary>
[SupportedOSPlatform("windows10.0.19041")]
internal static class WindowsMediaFoundationInterop
{
    internal static readonly Guid H264EncoderClass = new("6ca50344-051a-4ded-9779-a43305165e35");
    internal static readonly Guid VideoProcessorClass = new("88753b26-5b24-49bd-b2e7-0c445c78c982");
    internal static readonly Guid LowLatency = new("9c27891a-ed7a-40e1-88e8-b22727a024ee");
    internal static readonly Guid MeanBitrate = new("f7222374-2144-4815-b550-a37f8e12ee52");
    internal static readonly Guid ForceKeyFrame = new("398c1b98-8353-475a-9ef2-8f265d260345");
    internal static readonly Guid BPictureCount = new("8d390aac-dc5c-4200-b57f-814d04babab2");
    internal static readonly Guid GopSize = new("95f31b26-95a4-41aa-9303-246a7fc6eef1");
    internal static readonly Guid RateControlMode = new("1c0608e9-370c-4710-8a58-cb6181c42423");
    internal static readonly Guid DisableFrameRateConversion = new("2c0afa19-7a97-4d5a-9ee8-16d4fc518d8c");
    internal static readonly Guid CallerAllocatesOutput = new("04a2cabc-0cab-40b1-a1b9-75bc3658f000");

    internal static IMFTransform CreateTransform(Guid classId)
    {
        var interfaceId = typeof(IMFTransform).GUID;
        Marshal.ThrowExceptionForHR(CoCreateInstance(in classId, IntPtr.Zero, 1, in interfaceId, out var pointer));
        return new IMFTransform(pointer);
    }

    internal static void InitializeApartment() => Marshal.ThrowExceptionForHR(CoInitializeEx(IntPtr.Zero, 0));
    internal static void UninitializeApartment() => CoUninitialize();

    // CodecAPI defines its value as VARIANT. The object-marshalled value is limited
    // to uint and bool here; no application data is dispatched through COM reflection.
    internal static void SetCodecValue(IMFTransform transform, Guid property, uint value) => SetCodecVariant(transform, property, value);
    internal static void SetCodecValue(IMFTransform transform, Guid property, bool value) => SetCodecVariant(transform, property, value);
    private static void SetCodecVariant(IMFTransform transform, Guid property, object value)
    {
        var wrapper = Marshal.GetObjectForIUnknown(transform.NativePointer);
        try
        {
            var codec = (ICodecControl)wrapper;
            Marshal.ThrowExceptionForHR(codec.SetValue(in property, ref value));
        }
        finally { Marshal.ReleaseComObject(wrapper); }
    }

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern int CoCreateInstance(in Guid classId, IntPtr outer, uint context, in Guid interfaceId, out IntPtr result);
    [DllImport("ole32.dll", ExactSpelling = true)] private static extern int CoInitializeEx(IntPtr reserved, uint flags);
    [DllImport("ole32.dll", ExactSpelling = true)] private static extern void CoUninitialize();

    [ComImport, Guid("901db4c7-31ce-41a2-85dc-8fa0bf41b8da"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ICodecControl
    {
        [PreserveSig] int IsSupported(in Guid property);
        [PreserveSig] int IsModifiable(in Guid property);
        [PreserveSig] int GetParameterRange(in Guid property,
            [MarshalAs(UnmanagedType.Struct)] out object minimum,
            [MarshalAs(UnmanagedType.Struct)] out object maximum,
            [MarshalAs(UnmanagedType.Struct)] out object step);
        [PreserveSig] int GetParameterValues(in Guid property, out IntPtr values, out uint count);
        [PreserveSig] int GetDefaultValue(in Guid property, [MarshalAs(UnmanagedType.Struct)] out object value);
        [PreserveSig] int GetValue(in Guid property, [MarshalAs(UnmanagedType.Struct)] out object value);
        [PreserveSig] int SetValue(in Guid property, [MarshalAs(UnmanagedType.Struct)] ref object value);
    }
}
