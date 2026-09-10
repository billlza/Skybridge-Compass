using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

internal sealed class WebRtcProductControlMessageInbox : IAsyncDisposable
{
    private readonly IWebRtcProductControlPlane _controlPlane;
    private readonly Queue<byte[]> _messages = new();
    private readonly SemaphoreSlim _signal = new(0);
    private readonly object _gate = new();
    private readonly int _maxQueuedMessages;
    private readonly string _componentName;
    private readonly Func<string, Exception> _failureFactory;
    private Exception? _failure;
    private bool _disposed;

    public WebRtcProductControlMessageInbox(
        IWebRtcProductControlPlane controlPlane,
        int maxQueuedMessages,
        string componentName,
        Func<string, Exception> failureFactory)
    {
        if (maxQueuedMessages is < 1 or > 32)
        {
            throw new ArgumentOutOfRangeException(
                nameof(maxQueuedMessages),
                maxQueuedMessages,
                "WebRTC product-control inbox capacity must be between 1 and 32 messages.");
        }

        _controlPlane = controlPlane ?? throw new ArgumentNullException(nameof(controlPlane));
        _componentName = string.IsNullOrWhiteSpace(componentName)
            ? throw new ArgumentException("WebRTC product-control inbox component name must not be empty.", nameof(componentName))
            : componentName.Trim();
        _failureFactory = failureFactory ?? throw new ArgumentNullException(nameof(failureFactory));
        _maxQueuedMessages = maxQueuedMessages;
        _controlPlane.MessageReceived += OnMessageReceived;
    }

    public async Task<byte[]> ReadAsync(
        string expectedMessage,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(expectedMessage))
        {
            throw new ArgumentException("Expected WebRTC product-control message label must not be empty.", nameof(expectedMessage));
        }

        if (timeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(timeout), timeout, "WebRTC product-control inbox timeout must be positive.");
        }

        using var timeoutCts = new CancellationTokenSource(timeout);
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
        try
        {
            await _signal.WaitAsync(linkedCts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException(
                $"{_componentName} timed out waiting for {expectedMessage} after {timeout.TotalSeconds:F0}s.");
        }

        lock (_gate)
        {
            if (_failure is not null)
            {
                throw _failure;
            }

            if (_messages.Count == 0)
            {
                throw _failureFactory(
                    $"{_componentName} inbox signaled without {expectedMessage} bytes.");
            }

            return _messages.Dequeue();
        }
    }

    public ValueTask DisposeAsync()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return ValueTask.CompletedTask;
            }

            _disposed = true;
            _messages.Clear();
            _failure = null;
        }

        _controlPlane.MessageReceived -= OnMessageReceived;
        _signal.Dispose();
        return ValueTask.CompletedTask;
    }

    private void OnMessageReceived(byte[] message)
    {
        ArgumentNullException.ThrowIfNull(message);
        lock (_gate)
        {
            if (_disposed || _failure is not null)
            {
                return;
            }

            if (_messages.Count >= _maxQueuedMessages)
            {
                _failure = _failureFactory(
                    $"{_componentName} inbound queue exceeded {_maxQueuedMessages} messages before the client could process them.");
            }
            else
            {
                _messages.Enqueue(message.ToArray());
            }
        }

        _signal.Release();
    }
}
