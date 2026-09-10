using System;
using System.Collections.Generic;
using System.IO;
using System.Net.WebSockets;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

/// <summary>
/// Bridges the helper's local offer/answer JSON files to current-path WebSocket signaling. This
/// class does not launch the helper and does not prove product AppControl readiness; it only owns
/// the SDP/ICE exchange needed before the product-control helper can expose its raw IPC port.
/// </summary>
public sealed class CurrentPathWebRtcHelperSignalingBridge
{
    public async Task<CurrentPathWebRtcHelperSignalingBridgeResult> ExchangeOffererAsync(
        CurrentPathWebSocketSignalingClient signalingClient,
        CurrentPathWebRtcHelperSignalingBridgeOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(signalingClient);
        ArgumentNullException.ThrowIfNull(options);
        RequireBound(signalingClient);

        var localOffer = await WaitForSignalDocumentAsync(
                options.LocalSignalPath,
                "offer",
                options.SignalFileTimeout,
                cancellationToken)
            .ConfigureAwait(false);

        await SendEnvelopeAsync(
                signalingClient,
                options,
                CurrentPathWebRtcSignalingMessageType.Join,
                payload: null,
                cancellationToken)
            .ConfigureAwait(false);
        await SendEnvelopeAsync(
                signalingClient,
                options,
                CurrentPathWebRtcSignalingMessageType.Offer,
                new CurrentPathWebRtcSignalingPayload(sdp: localOffer.Sdp),
                cancellationToken)
            .ConfigureAwait(false);

        foreach (var candidate in localOffer.Candidates)
        {
            await SendEnvelopeAsync(
                    signalingClient,
                    options,
                    CurrentPathWebRtcSignalingMessageType.IceCandidate,
                    new CurrentPathWebRtcSignalingPayload(
                        candidate: candidate.Candidate,
                        sdpMid: candidate.SdpMid,
                        sdpMLineIndex: candidate.SdpMLineIndex,
                        usernameFragment: candidate.UsernameFragment),
                    cancellationToken)
                .ConfigureAwait(false);
        }

        var remoteCandidates = new List<WebRtcSignalDocument.SignalCandidate>();
        var remoteAnswer = await ReceiveRemoteAnswerAsync(
                signalingClient,
                options,
                remoteCandidates,
                cancellationToken)
            .ConfigureAwait(false);

        WebRtcSignalDocument.RequireFingerprint(remoteAnswer.Payload!.Sdp!, options.RemoteSignalPath);
        WebRtcSignalDocument.Write(
            options.RemoteSignalPath,
            "answer",
            remoteAnswer.Payload!.Sdp!,
            remoteCandidates);

        return new CurrentPathWebRtcHelperSignalingBridgeResult(
            localOffer.Candidates.Length,
            remoteCandidates.Count,
            remoteAnswer.From,
            options.RemoteSignalPath);
    }

    public async Task<CurrentPathWebRtcHelperSignalingBridgeResult> ExchangeAnswererAsync(
        CurrentPathWebSocketSignalingClient signalingClient,
        CurrentPathWebRtcHelperSignalingBridgeOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(signalingClient);
        ArgumentNullException.ThrowIfNull(options);
        RequireBound(signalingClient);

        await SendEnvelopeAsync(
                signalingClient,
                options,
                CurrentPathWebRtcSignalingMessageType.Join,
                payload: null,
                cancellationToken)
            .ConfigureAwait(false);

        var remoteCandidates = new List<WebRtcSignalDocument.SignalCandidate>();
        var remoteOffer = await ReceiveRemoteOfferAsync(
                signalingClient,
                options,
                remoteCandidates,
                cancellationToken)
            .ConfigureAwait(false);

        WebRtcSignalDocument.RequireFingerprint(remoteOffer.Payload!.Sdp!, options.RemoteSignalPath);
        WebRtcSignalDocument.Write(
            options.RemoteSignalPath,
            "offer",
            remoteOffer.Payload!.Sdp!,
            remoteCandidates);

        var localAnswer = await WaitForSignalDocumentAsync(
                options.LocalSignalPath,
                "answer",
                options.SignalFileTimeout,
                cancellationToken)
            .ConfigureAwait(false);

        await SendEnvelopeAsync(
                signalingClient,
                options,
                CurrentPathWebRtcSignalingMessageType.Answer,
                new CurrentPathWebRtcSignalingPayload(sdp: localAnswer.Sdp),
                cancellationToken)
            .ConfigureAwait(false);

        foreach (var candidate in localAnswer.Candidates)
        {
            await SendEnvelopeAsync(
                    signalingClient,
                    options,
                    CurrentPathWebRtcSignalingMessageType.IceCandidate,
                    new CurrentPathWebRtcSignalingPayload(
                        candidate: candidate.Candidate,
                        sdpMid: candidate.SdpMid,
                        sdpMLineIndex: candidate.SdpMLineIndex,
                        usernameFragment: candidate.UsernameFragment),
                    cancellationToken)
                .ConfigureAwait(false);
        }

        return new CurrentPathWebRtcHelperSignalingBridgeResult(
            localAnswer.Candidates.Length,
            remoteCandidates.Count,
            remoteOffer.From,
            options.RemoteSignalPath);
    }

    public async Task<int> RelayRemoteIceCandidatesUntilAsync(
        CurrentPathWebSocketSignalingClient signalingClient,
        CurrentPathWebRtcHelperSignalingBridgeOptions options,
        string expectedRemoteSignalType,
        Task readyTask,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(signalingClient);
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(readyTask);
        RequireBound(signalingClient);
        if (!string.Equals(expectedRemoteSignalType, "offer", StringComparison.Ordinal) &&
            !string.Equals(expectedRemoteSignalType, "answer", StringComparison.Ordinal))
        {
            throw new InvalidDataException("Current-path helper signaling bridge can relay ICE only for offer or answer signal files.");
        }

        var remoteSignal = WebRtcSignalDocument.Read(options.RemoteSignalPath, expectedRemoteSignalType);
        var remoteCandidates = new List<WebRtcSignalDocument.SignalCandidate>(remoteSignal.Candidates);
        var remoteCandidateKeys = new HashSet<string>(
            remoteCandidates.Select(RemoteIceCandidateKey),
            StringComparer.Ordinal);
        var relayedCandidates = 0;
        while (!readyTask.IsCompleted)
        {
            using var receiveCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            var receiveTask = signalingClient.ReceiveNextAsync(receiveCancellation.Token);
            var completedTask = await Task.WhenAny(readyTask, receiveTask).ConfigureAwait(false);
            if (completedTask == readyTask)
            {
                receiveCancellation.Cancel();
                await ObserveReceiveAfterReadyAsync(receiveTask, receiveCancellation.Token).ConfigureAwait(false);
                break;
            }

            var inbound = await receiveTask.ConfigureAwait(false);
            if (inbound.Kind == CurrentPathSignalingInboundMessageKind.ServerFrame)
            {
                continue;
            }

            if (!TryReadExpectedRemoteEnvelope(inbound, options, out var envelope))
            {
                continue;
            }

            switch (envelope.Type)
            {
                case CurrentPathWebRtcSignalingMessageType.Join:
                    continue;
                case CurrentPathWebRtcSignalingMessageType.IceCandidate:
                    if (!AddRemoteCandidate(remoteCandidates, remoteCandidateKeys, envelope, options))
                    {
                        continue;
                    }

                    WebRtcSignalDocument.Write(
                        options.RemoteSignalPath,
                        expectedRemoteSignalType,
                        remoteSignal.Sdp,
                        remoteCandidates);
                    relayedCandidates++;
                    continue;
                case CurrentPathWebRtcSignalingMessageType.Offer:
                case CurrentPathWebRtcSignalingMessageType.Answer:
                case CurrentPathWebRtcSignalingMessageType.Leave:
                default:
                    throw new InvalidDataException(
                        $"Current-path helper signaling bridge received unexpected {envelope.Type} while relaying ICE candidates.");
            }
        }

        await readyTask.ConfigureAwait(false);
        return relayedCandidates;
    }

    private static void RequireBound(CurrentPathWebSocketSignalingClient signalingClient)
    {
        if (!signalingClient.IsBound)
        {
            throw new InvalidOperationException("Current-path helper signaling bridge requires a bound WebSocket client.");
        }
    }

    private static async Task SendEnvelopeAsync(
        CurrentPathWebSocketSignalingClient signalingClient,
        CurrentPathWebRtcHelperSignalingBridgeOptions options,
        CurrentPathWebRtcSignalingMessageType type,
        CurrentPathWebRtcSignalingPayload? payload,
        CancellationToken cancellationToken)
    {
        await signalingClient.SendAsync(
                new CurrentPathWebRtcSignalingEnvelope(
                    options.SessionId,
                    options.LocalDeviceId,
                    options.RemoteDeviceId,
                    type,
                    payload),
                cancellationToken)
            .ConfigureAwait(false);
    }

    private static async Task<CurrentPathWebRtcSignalingEnvelope> ReceiveRemoteAnswerAsync(
        CurrentPathWebSocketSignalingClient signalingClient,
        CurrentPathWebRtcHelperSignalingBridgeOptions options,
        List<WebRtcSignalDocument.SignalCandidate> remoteCandidates,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(options.RemoteSignalTimeout);

        while (true)
        {
            CurrentPathSignalingInboundMessage inbound;
            try
            {
                inbound = await signalingClient.ReceiveNextAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (timeout.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            {
                throw new TimeoutException(
                    $"Current-path helper signaling bridge did not receive an answer within {options.RemoteSignalTimeout.TotalSeconds:F0}s.");
            }

            if (inbound.Kind == CurrentPathSignalingInboundMessageKind.ServerFrame)
            {
                continue;
            }

            if (!TryReadExpectedRemoteEnvelope(inbound, options, out var envelope))
            {
                continue;
            }

            switch (envelope.Type)
            {
                case CurrentPathWebRtcSignalingMessageType.Join:
                    continue;
                case CurrentPathWebRtcSignalingMessageType.IceCandidate:
                    AddRemoteCandidate(remoteCandidates, null, envelope, options);
                    continue;
                case CurrentPathWebRtcSignalingMessageType.Answer:
                    return envelope;
                case CurrentPathWebRtcSignalingMessageType.Offer:
                case CurrentPathWebRtcSignalingMessageType.Leave:
                default:
                    throw new InvalidDataException(
                        $"Current-path helper signaling bridge received unexpected {envelope.Type} while waiting for answer.");
            }
        }
    }

    private static async Task<CurrentPathWebRtcSignalingEnvelope> ReceiveRemoteOfferAsync(
        CurrentPathWebSocketSignalingClient signalingClient,
        CurrentPathWebRtcHelperSignalingBridgeOptions options,
        List<WebRtcSignalDocument.SignalCandidate> remoteCandidates,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(options.RemoteSignalTimeout);

        CurrentPathWebRtcSignalingEnvelope? remoteOffer = null;
        while (true)
        {
            CurrentPathSignalingInboundMessage inbound;
            try
            {
                inbound = await signalingClient.ReceiveNextAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (timeout.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            {
                throw new TimeoutException(
                    $"Current-path helper signaling bridge did not receive an offer within {options.RemoteSignalTimeout.TotalSeconds:F0}s.");
            }

            if (inbound.Kind == CurrentPathSignalingInboundMessageKind.ServerFrame)
            {
                continue;
            }

            if (!TryReadExpectedRemoteEnvelope(inbound, options, out var envelope))
            {
                continue;
            }

            switch (envelope.Type)
            {
                case CurrentPathWebRtcSignalingMessageType.Join:
                    continue;
                case CurrentPathWebRtcSignalingMessageType.IceCandidate:
                    AddRemoteCandidate(remoteCandidates, null, envelope, options);
                    continue;
                case CurrentPathWebRtcSignalingMessageType.Offer:
                    if (remoteOffer is not null)
                    {
                        throw new InvalidDataException(
                            "Current-path helper signaling bridge received more than one offer.");
                    }

                    remoteOffer = envelope;
                    return remoteOffer;
                case CurrentPathWebRtcSignalingMessageType.Answer:
                case CurrentPathWebRtcSignalingMessageType.Leave:
                default:
                    throw new InvalidDataException(
                        $"Current-path helper signaling bridge received unexpected {envelope.Type} while waiting for offer.");
            }
        }
    }

    private static bool TryReadExpectedRemoteEnvelope(
        CurrentPathSignalingInboundMessage inbound,
        CurrentPathWebRtcHelperSignalingBridgeOptions options,
        out CurrentPathWebRtcSignalingEnvelope envelope)
    {
        if (inbound.Envelope is not { } decoded)
        {
            throw new InvalidDataException("Current-path helper signaling bridge received a non-envelope message.");
        }

        if (string.Equals(decoded.From, options.LocalDeviceId, StringComparison.Ordinal))
        {
            envelope = decoded;
            return false;
        }

        if (!string.Equals(decoded.From, options.RemoteDeviceId, StringComparison.Ordinal))
        {
            throw new InvalidDataException("Current-path helper signaling bridge received an envelope from an unexpected peer.");
        }

        if (decoded.To is not null &&
            !string.Equals(decoded.To, options.LocalDeviceId, StringComparison.Ordinal))
        {
            throw new InvalidDataException("Current-path helper signaling bridge received an envelope addressed to another device.");
        }

        envelope = decoded;
        return true;
    }

    private static bool AddRemoteCandidate(
        List<WebRtcSignalDocument.SignalCandidate> remoteCandidates,
        HashSet<string>? remoteCandidateKeys,
        CurrentPathWebRtcSignalingEnvelope envelope,
        CurrentPathWebRtcHelperSignalingBridgeOptions options)
    {
        var payload = envelope.Payload
            ?? throw new InvalidDataException("Current-path remote ICE envelope is missing payload.");
        if (string.IsNullOrWhiteSpace(payload.Candidate))
        {
            throw new InvalidDataException("Current-path remote ICE envelope is missing candidate.");
        }

        if (payload.SdpMLineIndex is < 0 or > ushort.MaxValue)
        {
            throw new InvalidDataException("Current-path remote ICE m-line index is outside the helper range.");
        }

        var candidate = new WebRtcSignalDocument.SignalCandidate
        {
            Candidate = payload.Candidate,
            SdpMid = payload.SdpMid,
            SdpMLineIndex = (ushort)(payload.SdpMLineIndex ?? 0),
            UsernameFragment = payload.UsernameFragment
        };
        var candidateKey = RemoteIceCandidateKey(candidate);
        if (remoteCandidateKeys is not null && !remoteCandidateKeys.Add(candidateKey))
        {
            return false;
        }

        if (remoteCandidates.Count >= options.MaxRemoteIceCandidates)
        {
            throw new InvalidDataException(
                $"Current-path helper signaling bridge received more than {options.MaxRemoteIceCandidates} remote ICE candidates.");
        }

        remoteCandidates.Add(candidate);
        return true;
    }

    private static string RemoteIceCandidateKey(WebRtcSignalDocument.SignalCandidate candidate) =>
        string.Join(
            '\u001f',
            candidate.Candidate,
            candidate.SdpMid ?? "",
            candidate.SdpMLineIndex.ToString(),
            candidate.UsernameFragment ?? "");

    private static async Task<WebRtcSignalDocument> WaitForSignalDocumentAsync(
        string path,
        string expectedType,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        Exception? lastTransientReadError = null;
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (File.Exists(path))
            {
                try
                {
                    return WebRtcSignalDocument.Read(path, expectedType);
                }
                catch (Exception ex) when (ex is JsonException or IOException)
                {
                    lastTransientReadError = ex;
                }
            }

            await Task.Delay(TimeSpan.FromMilliseconds(250), cancellationToken).ConfigureAwait(false);
        }

        throw new TimeoutException(
            lastTransientReadError is null
                ? $"Current-path helper signaling bridge did not find a valid {expectedType} signal at '{path}' within {timeout.TotalSeconds:F0}s."
                : $"Current-path helper signaling bridge did not find a valid {expectedType} signal at '{path}' within {timeout.TotalSeconds:F0}s; last transient read error was {lastTransientReadError.GetType().Name}: {lastTransientReadError.Message}",
            lastTransientReadError);
    }

    private static async Task ObserveReceiveAfterReadyAsync(
        Task receiveTask,
        CancellationToken receiveCancellationToken)
    {
        try
        {
            await receiveTask.ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (receiveCancellationToken.IsCancellationRequested)
        {
            return;
        }
        catch (Exception ex) when (IsExpectedReceiveCleanupException(ex))
        {
            return;
        }
    }

    private static bool IsExpectedReceiveCleanupException(Exception ex) =>
        ex is CurrentPathWebSocketSignalingException
        {
            FailureClass: CurrentPathSignalingFailureClass.TransientNetwork
        } or
            IOException or
            ObjectDisposedException or
            WebSocketException;
}

public sealed class CurrentPathWebRtcHelperSignalingBridgeOptions
{
    private static readonly TimeSpan DefaultSignalFileTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan DefaultRemoteSignalTimeout = TimeSpan.FromSeconds(120);

    public CurrentPathWebRtcHelperSignalingBridgeOptions(
        string sessionId,
        string localDeviceId,
        string remoteDeviceId,
        string localSignalPath,
        string remoteSignalPath,
        TimeSpan? signalFileTimeout = null,
        TimeSpan? remoteSignalTimeout = null,
        int maxRemoteIceCandidates = 128)
    {
        SessionId = CurrentPathWebRtcSignalingEnvelope.ValidateSessionId(sessionId);
        LocalDeviceId = CurrentPathProtocolIdentityBinding.NormalizeDeviceId(localDeviceId);
        RemoteDeviceId = CurrentPathProtocolIdentityBinding.NormalizeDeviceId(remoteDeviceId);
        ArgumentException.ThrowIfNullOrWhiteSpace(localSignalPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(remoteSignalPath);
        LocalSignalPath = localSignalPath;
        RemoteSignalPath = remoteSignalPath;
        SignalFileTimeout = signalFileTimeout ?? DefaultSignalFileTimeout;
        RemoteSignalTimeout = remoteSignalTimeout ?? DefaultRemoteSignalTimeout;
        if (SignalFileTimeout <= TimeSpan.Zero)
        {
            throw new InvalidDataException("Current-path helper signaling bridge signal file timeout must be positive.");
        }

        if (RemoteSignalTimeout <= TimeSpan.Zero)
        {
            throw new InvalidDataException("Current-path helper signaling bridge remote signal timeout must be positive.");
        }

        if (maxRemoteIceCandidates is < 0 or > 256)
        {
            throw new InvalidDataException("Current-path helper signaling bridge remote ICE candidate limit must be between 0 and 256.");
        }

        MaxRemoteIceCandidates = maxRemoteIceCandidates;
    }

    public string SessionId { get; }

    public string LocalDeviceId { get; }

    public string RemoteDeviceId { get; }

    public string LocalSignalPath { get; }

    public string RemoteSignalPath { get; }

    public TimeSpan SignalFileTimeout { get; }

    public TimeSpan RemoteSignalTimeout { get; }

    public int MaxRemoteIceCandidates { get; }
}

public sealed record CurrentPathWebRtcHelperSignalingBridgeResult(
    int LocalCandidateCount,
    int RemoteCandidateCount,
    string RemoteDeviceId,
    string WroteRemoteSignalPath);
