using System;
using System.Collections.Generic;
using System.Runtime.ExceptionServices;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

/// <summary>
/// Retains ownership of each asynchronous WebRTC session resource until that
/// exact resource reports successful teardown. A failed resource remains
/// pending for an explicit cleanup retry; resources already released are not
/// disposed a second time.
/// </summary>
internal sealed class WebRtcSessionResourceOwner
{
    private IAsyncDisposable? _dataPlane;
    private IAsyncDisposable? _helperSession;

    public WebRtcSessionResourceOwner(
        IAsyncDisposable dataPlane,
        IAsyncDisposable helperSession)
    {
        _dataPlane = dataPlane ?? throw new ArgumentNullException(nameof(dataPlane));
        _helperSession = helperSession ?? throw new ArgumentNullException(nameof(helperSession));
    }

    public bool HasPendingResources => _dataPlane is not null || _helperSession is not null;

    public async Task DisposePendingAsync()
    {
        List<Exception>? errors = null;

        var dataPlane = _dataPlane;
        if (dataPlane is not null)
        {
            try
            {
                await dataPlane.DisposeAsync().ConfigureAwait(false);
                _dataPlane = null;
            }
            catch (Exception ex)
            {
                errors = new List<Exception> { ex };
            }
        }

        var helperSession = _helperSession;
        if (helperSession is not null)
        {
            try
            {
                await helperSession.DisposeAsync().ConfigureAwait(false);
                _helperSession = null;
            }
            catch (Exception ex)
            {
                errors ??= new List<Exception>();
                errors.Add(ex);
            }
        }

        if (errors is null)
        {
            return;
        }

        if (errors.Count == 1)
        {
            ExceptionDispatchInfo.Capture(errors[0]).Throw();
        }

        throw new AggregateException(
            "WebRTC session transport resource teardown reported multiple errors.",
            errors);
    }
}
