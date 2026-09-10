using System;
using System.IO;
using Concentus;
using Concentus.Enums;

namespace Skybridge.WinClient.Services.RemoteControl;

internal sealed record WindowsPcmAudioFrame(short[] Samples, ulong TimestampSamples, bool Discontinuity);

internal sealed class WindowsOpusAudioEncoder : IDisposable
{
    public const int SampleRate = 48_000;
    public const int Channels = 2;
    public const int SamplesPerChannel = 960;
    public const int InterleavedSamples = SamplesPerChannel * Channels;
    public const int MaxPacketBytes = 1100;
    private readonly IOpusEncoder _encoder;

    public WindowsOpusAudioEncoder(string mode)
    {
        ValidateMode(mode);
        _encoder = OpusCodecFactory.CreateEncoder(SampleRate, Channels, OpusApplication.OPUS_APPLICATION_AUDIO);
        try
        {
            _encoder.Bitrate = mode == "low-latency" ? 128_000 : 224_000;
            _encoder.Complexity = mode == "low-latency" ? 7 : 10;
            _encoder.UseVBR = true;
            _encoder.UseConstrainedVBR = true;
            _encoder.UseInbandFEC = true;
            _encoder.UseDTX = false;
        }
        catch
        {
            _encoder.Dispose();
            throw;
        }
    }

    public static void ValidateMode(string mode)
    {
        if (mode is not "low-latency" and not "high-fidelity")
        {
            throw new ArgumentException("Remote audio mode must be low-latency or high-fidelity.", nameof(mode));
        }
    }

    public WindowsOpusAudioFrame Encode(WindowsPcmAudioFrame frame)
    {
        ArgumentNullException.ThrowIfNull(frame);
        if (frame.Samples.Length != InterleavedSamples)
        {
            throw new InvalidDataException("A remote audio PCM frame must contain exactly 20 ms of 48 kHz stereo samples.");
        }

        var buffer = new byte[MaxPacketBytes];
        var length = _encoder.Encode(frame.Samples, SamplesPerChannel, buffer, buffer.Length);
        if (length is <= 0 or > MaxPacketBytes)
        {
            throw new InvalidDataException("The Opus encoder returned a packet outside the negotiated media payload limit.");
        }

        return new WindowsOpusAudioFrame(buffer.AsSpan(0, length).ToArray(), frame.TimestampSamples, SamplesPerChannel, frame.Discontinuity);
    }

    public void Dispose() => _encoder.Dispose();
}

/// <summary>Combines actual WASAPI samples without synthesizing missing audio.</summary>
internal sealed class WindowsPcmAudioPacketizer
{
    private readonly short[] _pending = new short[WindowsOpusAudioEncoder.InterleavedSamples];
    private int _filled;
    private ulong _nextTimestamp;
    private bool _discontinuity;

    public void Append(ReadOnlySpan<short> samples, bool discontinuity, Action<WindowsPcmAudioFrame> onFrame)
    {
        ArgumentNullException.ThrowIfNull(onFrame);
        if (samples.Length % WindowsOpusAudioEncoder.Channels != 0)
        {
            throw new InvalidDataException("A WASAPI packet contains an incomplete stereo sample.");
        }

        if (discontinuity)
        {
            _nextTimestamp = checked(_nextTimestamp + (ulong)(_filled / WindowsOpusAudioEncoder.Channels));
            _filled = 0;
            _discontinuity = true;
        }

        while (!samples.IsEmpty)
        {
            var take = Math.Min(samples.Length, _pending.Length - _filled);
            samples[..take].CopyTo(_pending.AsSpan(_filled));
            _filled += take;
            samples = samples[take..];
            if (_filled != _pending.Length)
            {
                continue;
            }

            onFrame(new WindowsPcmAudioFrame((short[])_pending.Clone(), _nextTimestamp, _discontinuity));
            _nextTimestamp = checked(_nextTimestamp + WindowsOpusAudioEncoder.SamplesPerChannel);
            _filled = 0;
            _discontinuity = false;
        }
    }
}
