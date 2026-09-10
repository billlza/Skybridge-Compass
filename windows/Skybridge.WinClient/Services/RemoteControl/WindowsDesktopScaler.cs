using System.Runtime.Versioning;
using SharpGen.Runtime;
using Vortice;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace Skybridge.WinClient.Services.RemoteControl;

/// <summary>Rotates and scales a duplication surface on its existing D3D11 device.</summary>
[SupportedOSPlatform("windows10.0.19041")]
internal sealed class WindowsDesktopScaler : IDisposable
{
    private readonly ID3D11VideoDevice _device;
    private readonly ID3D11VideoContext _context;
    private readonly ID3D11VideoProcessorEnumerator _enumerator;
    private readonly ID3D11VideoProcessor _processor;
    private readonly ID3D11Texture2D _output;
    private readonly ID3D11VideoProcessorOutputView _outputView;
    private bool _disposed;

    internal WindowsDesktopScaler(ID3D11Device device, ID3D11DeviceContext context,
        int inputWidth, int inputHeight, WindowsDesktopRotation rotation, int outputWidth, int outputHeight)
    {
        ID3D11VideoDevice? videoDevice = null;
        ID3D11VideoContext? videoContext = null;
        ID3D11VideoProcessorEnumerator? enumerator = null;
        ID3D11VideoProcessor? processor = null;
        ID3D11Texture2D? output = null;
        ID3D11VideoProcessorOutputView? outputView = null;
        try
        {
            try
            {
                videoDevice = device.QueryInterface<ID3D11VideoDevice>();
                videoContext = context.QueryInterface<ID3D11VideoContext>();
            }
            catch (SharpGenException failure) when (failure.ResultCode.Code == unchecked((int)0x80004002))
            {
                throw Unavailable("The display adapter does not expose D3D11 video processing.", failure);
            }
            enumerator = videoDevice.CreateVideoProcessorEnumerator(new VideoProcessorContentDescription
            {
                InputFrameFormat = VideoFrameFormat.Progressive,
                InputFrameRate = new Rational(30, 1), OutputFrameRate = new Rational(30, 1),
                InputWidth = checked((uint)inputWidth), InputHeight = checked((uint)inputHeight),
                OutputWidth = checked((uint)outputWidth), OutputHeight = checked((uint)outputHeight),
                Usage = VideoUsage.OptimalSpeed
            });
            var format = enumerator.CheckVideoProcessorFormat(Format.B8G8R8A8_UNorm);
            if ((format & (VideoProcessorFormatSupport.Input | VideoProcessorFormatSupport.Output)) !=
                (VideoProcessorFormatSupport.Input | VideoProcessorFormatSupport.Output))
                throw Unavailable("The display adapter cannot scale BGRA desktop surfaces with D3D11 video processing.");
            var capabilities = enumerator.VideoProcessorCaps;
            if (capabilities.MaxInputStreams == 0 || capabilities.MaxStreamStates == 0)
                throw Unavailable("The display adapter exposes no usable video processing stream.");
            if (rotation != WindowsDesktopRotation.Identity && (capabilities.FeatureCaps & VideoProcessorFeatureCaps.Rotation) == 0)
                throw Unavailable("The display adapter cannot rotate the selected desktop with GPU video processing.");
            uint? processorIndex = null;
            for (uint index = 0; index < capabilities.RateConversionCapsCount; index++)
            {
                var rate = enumerator.GetVideoProcessorRateConversionCaps(index);
                if (rate.PastFrames == 0 && rate.FutureFrames == 0) { processorIndex = index; break; }
            }
            if (processorIndex is null)
                throw Unavailable("The display adapter has no video processor that can operate without buffered reference frames.");
            processor = videoDevice.CreateVideoProcessor(enumerator, processorIndex.Value);
            output = device.CreateTexture2D(new Texture2DDescription
            {
                Width = checked((uint)outputWidth), Height = checked((uint)outputHeight), MipLevels = 1, ArraySize = 1,
                Format = Format.B8G8R8A8_UNorm, SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Default, BindFlags = BindFlags.RenderTarget
            });
            outputView = videoDevice.CreateVideoProcessorOutputView(output, enumerator, new VideoProcessorOutputViewDescription
            {
                ViewDimension = VideoProcessorOutputViewDimension.Texture2D
            });
            var colorSpace = new VideoProcessorColorSpace { Usage = 1, RGB_Range = 0, YCbCr_Matrix = 1 };
            videoContext.VideoProcessorSetStreamFrameFormat(processor, 0, VideoFrameFormat.Progressive);
            videoContext.VideoProcessorSetStreamAutoProcessingMode(processor, 0, false);
            videoContext.VideoProcessorSetStreamColorSpace(processor, 0, colorSpace);
            videoContext.VideoProcessorSetOutputColorSpace(processor, colorSpace);
            videoContext.VideoProcessorSetStreamOutputRate(processor, 0, VideoProcessorOutputRate.Normal, false, null);
            videoContext.VideoProcessorSetStreamSourceRect(processor, 0, true, new RawRect(0, 0, inputWidth, inputHeight));
            videoContext.VideoProcessorSetStreamDestRect(processor, 0, true, new RawRect(0, 0, outputWidth, outputHeight));
            videoContext.VideoProcessorSetOutputTargetRect(processor, true, new RawRect(0, 0, outputWidth, outputHeight));
            if (rotation != WindowsDesktopRotation.Identity)
                videoContext.VideoProcessorSetStreamRotation(processor, 0, true, rotation switch
                {
                    WindowsDesktopRotation.Clockwise90 => VideoProcessorRotation.Rotation90,
                    WindowsDesktopRotation.Clockwise180 => VideoProcessorRotation.Rotation180,
                    WindowsDesktopRotation.Clockwise270 => VideoProcessorRotation.Rotation270,
                    _ => throw new ArgumentOutOfRangeException(nameof(rotation))
                });
            _device = videoDevice; _context = videoContext; _enumerator = enumerator; _processor = processor;
            _output = output; _outputView = outputView;
        }
        catch
        {
            outputView?.Dispose(); output?.Dispose(); processor?.Dispose(); enumerator?.Dispose();
            videoContext?.Dispose(); videoDevice?.Dispose();
            throw;
        }
    }

    /// <returns>The borrowed target texture, valid until the next operation or disposal.</returns>
    internal ID3D11Texture2D Process(ID3D11Texture2D source)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        using var input = _device.CreateVideoProcessorInputView(source, _enumerator, new VideoProcessorInputViewDescription
        {
            ViewDimension = VideoProcessorInputViewDimension.Texture2D
        });
        _context.VideoProcessorBlt(_processor, _outputView, 0,
            [new VideoProcessorStream { Enable = true, InputSurface = input }]).CheckError();
        return _output;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _outputView.Dispose(); _output.Dispose(); _processor.Dispose(); _enumerator.Dispose();
        _context.Dispose(); _device.Dispose();
    }

    private static WindowsDesktopException Unavailable(string message, Exception? failure = null) =>
        new(WindowsDesktopFailure.CaptureScalingUnavailable, message, failure);
}
