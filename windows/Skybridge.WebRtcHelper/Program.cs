// SkyBridge WebRTC DataChannel helper.
//
// Completes a real WebRTC DataChannel, sends a Core SBF1 frame, verifies the
// echo, and writes the proof JSON that core/skybridge-core/src/webrtc_proof.rs
// validates and Services/WindowsTransportAdapterClient.cs consumes. SkyBridge
// Core stays the authority; this is plumbing + proof emission only.
//
// Modes:
//   --mode loopback   (default) two in-process peers + echo responder; proves
//                      the whole DataChannel + SBF1-echo + proof pipeline with
//                      zero external dependencies.
//   --mode offer      offerer against a SEPARATE peer process; SDP+candidates
//                      exchanged via JSON files (--offer-out / --answer-in).
//                      Emits the proof. This is the Windows side of a live run.
//   --mode answer     answerer (echoes the SBF1 frame) for the peer side; reads
//                      --offer-in, writes --answer-out. This is what the Mac (or
//                      a second box) runs. Same cross-platform binary.
//   --mode session-offer / --mode session-answer
//                      THE DATA PLANE. Same offer/answer signaling as above, but
//                      after the DataChannel opens the helper does NOT send one
//                      frame and exit. It opens a loopback TCP IPC (127.0.0.1,
//                      --ipc-port or OS-chosen) speaking the SAME SBF1 framing and
//                      runs a continuous bidirectional pump: SBF1 frames from the
//                      local app are forwarded onto the DataChannel and frames
//                      from the peer are forwarded back to the app. Multi-channel
//                      (Control/File/Clipboard/Telemetry/Realtime) by virtue of
//                      the SBF1 channel byte. This is what clipboard/file/RD build
//                      on. See SessionTransport.cs for the framing + pump.
//
// The helper NEVER emits AppleNative binding — always WebRtcDataChannel /
// WebRtcInterop (Apple<->Apple stays on the Apple native path).

using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using SIPSorcery.Net;
using Skybridge.WebRtcHelper;

internal static class Program
{
    private const byte ChannelControl = 1;
    private const ushort FlagEndOfMessage = 0x0002;

    private static async Task<int> Main(string[] args)
    {
        var opts = ParseArgs(args);
        var mode = opts.GetValueOrDefault("mode", "loopback");
        var proofOut = opts.GetValueOrDefault("proof-out", "skybridge-webrtc-proof.json");
        // Placeholder identity is ONLY for the loopback self-test. For a real peer
        // (offer mode) the caller MUST supply the real paired identity, or we fail
        // closed — never silently emit a proof bound to the well-known fake peer.
        var peerDeviceId = opts.GetValueOrDefault("peer-device-id", mode == "loopback" ? "loopback-peer" : "");
        var peerFingerprint = opts.GetValueOrDefault(
            "peer-fingerprint",
            mode == "loopback"
                ? "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
                : "");

        if (mode == "offer" && string.IsNullOrWhiteSpace(peerDeviceId))
        {
            Console.Error.WriteLine("offer mode requires --peer-device-id <real paired device id>; refusing to emit a placeholder-bound proof");
            return 2;
        }

        if ((mode is "loopback" or "offer") && !Regex.IsMatch(peerFingerprint, "^[0-9a-f]{64}$"))
        {
            Console.Error.WriteLine("peer-fingerprint must be exactly 64 lowercase hex chars (offer mode: pass the real paired fingerprint, not a placeholder)");
            return 2;
        }

        try
        {
            return mode switch
            {
                "loopback" => await RunLoopbackAsync(proofOut, peerDeviceId, peerFingerprint),
                "offer" => await RunOfferAsync(opts, proofOut, peerDeviceId, peerFingerprint),
                "answer" => await RunAnswerAsync(opts),
                "session-offer" => await RunSessionOfferAsync(opts),
                "session-answer" => await RunSessionAnswerAsync(opts),
                "session-driver" => await SessionDriver.RunAsync(opts),
                _ => Fail($"unknown mode '{mode}' (use loopback|offer|answer|session-offer|session-answer|session-driver)"),
            };
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"helper failed: {ex.Message}");
            return 1;
        }
    }

    private static int Fail(string message)
    {
        Console.Error.WriteLine(message);
        return 1;
    }

    private static RTCConfiguration NewConfig() => new() { iceServers = new List<RTCIceServer>() };

    // Builds a config with STUN/TURN servers from a comma-separated --ice-servers arg
    // (e.g. "stun:stun.l.google.com:19302,turn:host:3478|user|pass"). Needed for the
    // cross-subnet Win<->Mac hop where host candidates alone won't route.
    private static RTCConfiguration ConfigWithIce(string csv)
    {
        var servers = new List<RTCIceServer>();
        foreach (var raw in csv.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var parts = raw.Split('|');
            var s = new RTCIceServer { urls = parts[0] };
            if (parts.Length >= 3) { s.username = parts[1]; s.credential = parts[2]; }
            servers.Add(s);
        }
        return new RTCConfiguration { iceServers = servers };
    }

    // --- SBF1 frame (matches core/skybridge-core/src/frame.rs:4-78, big-endian) ---
    private static byte[] EncodeSbf1(byte channelCode, ulong sequence, ushort flags, byte[] payload)
    {
        var buf = new byte[20 + payload.Length];
        buf[0] = 0x53; buf[1] = 0x42; buf[2] = 0x46; buf[3] = 0x31; // "SBF1"
        buf[4] = 1;                                                  // version
        buf[5] = channelCode;
        BinaryPrimitives.WriteUInt16BigEndian(buf.AsSpan(6, 2), flags);
        BinaryPrimitives.WriteUInt64BigEndian(buf.AsSpan(8, 8), sequence);
        BinaryPrimitives.WriteUInt32BigEndian(buf.AsSpan(16, 4), (uint)payload.Length);
        payload.CopyTo(buf.AsSpan(20));
        return buf;
    }

    // ---------------------------------------------------------------- loopback
    private static async Task<int> RunLoopbackAsync(string proofOut, string peerDeviceId, string peerFingerprint)
    {
        Console.WriteLine("[loopback] creating two peer connections...");
        using var offerer = new RTCPeerConnection(NewConfig());
        using var answerer = new RTCPeerConnection(NewConfig());

        offerer.onicecandidate += c => { if (c != null) answerer.addIceCandidate(ToInit(c)); };
        answerer.onicecandidate += c => { if (c != null) offerer.addIceCandidate(ToInit(c)); };
        answerer.ondatachannel += dc => dc.onmessage += (chan, _, data) => chan.send(data);

        var dc = await offerer.createDataChannel("skybridge");
        var opened = NewTcs();
        var echoed = NewTcs<byte[]>();
        dc.onopen += () => opened.TrySetResult();
        dc.onmessage += (_, _, data) => echoed.TrySetResult(data);

        var offer = offerer.createOffer(null);
        await offerer.setLocalDescription(offer);
        if (answerer.setRemoteDescription(offer) != SetDescriptionResultEnum.OK) return Fail("answerer rejected offer");
        var answer = answerer.createAnswer(null);
        await answerer.setLocalDescription(answer);
        if (offerer.setRemoteDescription(answer) != SetDescriptionResultEnum.OK) return Fail("offerer rejected answer");

        return await CompleteOffererAsync(offerer, dc, opened, echoed, proofOut, peerDeviceId, peerFingerprint, "loopback");
    }

    // ------------------------------------------------------------------- offer
    private static async Task<int> RunOfferAsync(
        Dictionary<string, string> opts, string proofOut, string peerDeviceId, string peerFingerprint)
    {
        var offerOut = opts.GetValueOrDefault("offer-out", "offer.json");
        var answerIn = opts.GetValueOrDefault("answer-in", "answer.json");
        Console.WriteLine("[offer] creating peer connection...");
        using var pc = new RTCPeerConnection(ConfigWithIce(opts.GetValueOrDefault("ice-servers", "")));
        var cands = new List<Cand>();
        pc.onicecandidate += c => { if (c != null) cands.Add(Cand.From(c)); };

        var dc = await pc.createDataChannel("skybridge");
        var opened = NewTcs();
        var echoed = NewTcs<byte[]>();
        dc.onopen += () => opened.TrySetResult();
        dc.onmessage += (_, _, data) => echoed.TrySetResult(data);

        var offer = pc.createOffer(null);
        await pc.setLocalDescription(offer);
        await WaitIceGatheringAsync(pc, TimeSpan.FromSeconds(8));
        Signal.Write(offerOut, "offer", offer.sdp, cands);
        Console.WriteLine($"[offer] wrote offer -> {Path.GetFullPath(offerOut)}; waiting for answer at {answerIn} ...");

        var ans = await Signal.WaitReadAsync(answerIn, TimeSpan.FromSeconds(180));
        if (pc.setRemoteDescription(new RTCSessionDescriptionInit { type = RTCSdpType.answer, sdp = ans.Sdp }) != SetDescriptionResultEnum.OK)
            return Fail("offerer rejected the peer answer");
        foreach (var c in ans.Candidates) pc.addIceCandidate(c.ToInit());

        return await CompleteOffererAsync(pc, dc, opened, echoed, proofOut, peerDeviceId, peerFingerprint, "offer");
    }

    // ------------------------------------------------------------------ answer
    private static async Task<int> RunAnswerAsync(Dictionary<string, string> opts)
    {
        var offerIn = opts.GetValueOrDefault("offer-in", "offer.json");
        var answerOut = opts.GetValueOrDefault("answer-out", "answer.json");
        var holdSeconds = int.TryParse(opts.GetValueOrDefault("hold-seconds", "60"), out var h) ? h : 60;
        Console.WriteLine($"[answer] waiting for offer at {offerIn} ...");
        var off = await Signal.WaitReadAsync(offerIn, TimeSpan.FromSeconds(180));

        using var pc = new RTCPeerConnection(ConfigWithIce(opts.GetValueOrDefault("ice-servers", "")));
        var cands = new List<Cand>();
        pc.onicecandidate += c => { if (c != null) cands.Add(Cand.From(c)); };
        // Echo every DataChannel message back verbatim (the SBF1 round-trip).
        pc.ondatachannel += dc =>
        {
            Console.WriteLine($"[answer] datachannel '{dc.label}' offered");
            dc.onmessage += (chan, _, data) =>
            {
                Console.WriteLine($"[answer] echoing {data.Length} bytes");
                chan.send(data);
            };
        };

        if (pc.setRemoteDescription(new RTCSessionDescriptionInit { type = RTCSdpType.offer, sdp = off.Sdp }) != SetDescriptionResultEnum.OK)
            return Fail("answerer rejected the peer offer");
        foreach (var c in off.Candidates) pc.addIceCandidate(c.ToInit());

        var answer = pc.createAnswer(null);
        await pc.setLocalDescription(answer);
        await WaitIceGatheringAsync(pc, TimeSpan.FromSeconds(8));
        Signal.Write(answerOut, "answer", answer.sdp, cands);
        Console.WriteLine($"[answer] wrote answer -> {Path.GetFullPath(answerOut)}; holding {holdSeconds}s to echo...");

        await Task.Delay(TimeSpan.FromSeconds(holdSeconds));
        Console.WriteLine("[answer] done");
        return 0;
    }

    // ----------------------------------------------------------- session-offer
    // The DATA PLANE offerer. Identical signaling to RunOfferAsync (offer.json /
    // answer.json + ICE), but after the DataChannel opens it hands the live
    // channel to the persistent SBF1 pump instead of sending one frame and
    // exiting. Runs until the DataChannel or the loopback app closes (or
    // --hold-seconds, if set, elapses).
    private static async Task<int> RunSessionOfferAsync(Dictionary<string, string> opts)
    {
        var offerOut = opts.GetValueOrDefault("offer-out", "offer.json");
        var answerIn = opts.GetValueOrDefault("answer-in", "answer.json");
        var ipcPort = ParsePort(opts.GetValueOrDefault("ipc-port", "0"));
        var portOut = opts.GetValueOrDefault("ipc-port-out", "");
        var ipcToken = opts.GetValueOrDefault("ipc-token", "");
        var holdSeconds = int.TryParse(opts.GetValueOrDefault("hold-seconds", "0"), out var h) ? h : 0;

        Console.WriteLine("[session-offer] creating peer connection...");
        using var pc = new RTCPeerConnection(ConfigWithIce(opts.GetValueOrDefault("ice-servers", "")));
        var cands = new List<Cand>();
        pc.onicecandidate += c => { if (c != null) cands.Add(Cand.From(c)); };

        var dc = await pc.createDataChannel("skybridge");
        var opened = NewTcs();
        dc.onopen += () => opened.TrySetResult();

        var offer = pc.createOffer(null);
        await pc.setLocalDescription(offer);
        await WaitIceGatheringAsync(pc, TimeSpan.FromSeconds(8));
        Signal.Write(offerOut, "offer", offer.sdp, cands);
        Console.WriteLine($"[session-offer] wrote offer -> {Path.GetFullPath(offerOut)}; waiting for answer at {answerIn} ...");

        var ans = await Signal.WaitReadAsync(answerIn, TimeSpan.FromSeconds(180));
        if (pc.setRemoteDescription(new RTCSessionDescriptionInit { type = RTCSdpType.answer, sdp = ans.Sdp }) != SetDescriptionResultEnum.OK)
            return Fail("session-offer rejected the peer answer");
        foreach (var c in ans.Candidates) pc.addIceCandidate(c.ToInit());

        Console.WriteLine("[session-offer] awaiting DataChannel open...");
        await opened.Task.WaitAsync(TimeSpan.FromSeconds(60));
        Console.WriteLine($"[session-offer] DataChannel state={dc.readyState}");
        if (dc.readyState != RTCDataChannelState.open)
            return Fail("session-offer: DataChannel did not open");

        return await PumpUntilDoneAsync(dc, ipcPort, portOut, holdSeconds, "session-offer", ipcToken);
    }

    // ---------------------------------------------------------- session-answer
    // The DATA PLANE answerer. Identical signaling to RunAnswerAsync, but instead
    // of echoing one frame it runs the persistent SBF1 pump over the inbound
    // DataChannel. This is the cross-platform peer side (a second box, or — once
    // the Apple core speaks the same loopback IPC — the Mac).
    private static async Task<int> RunSessionAnswerAsync(Dictionary<string, string> opts)
    {
        var offerIn = opts.GetValueOrDefault("offer-in", "offer.json");
        var answerOut = opts.GetValueOrDefault("answer-out", "answer.json");
        var ipcPort = ParsePort(opts.GetValueOrDefault("ipc-port", "0"));
        var portOut = opts.GetValueOrDefault("ipc-port-out", "");
        var ipcToken = opts.GetValueOrDefault("ipc-token", "");
        var holdSeconds = int.TryParse(opts.GetValueOrDefault("hold-seconds", "0"), out var h) ? h : 0;

        Console.WriteLine($"[session-answer] waiting for offer at {offerIn} ...");
        var off = await Signal.WaitReadAsync(offerIn, TimeSpan.FromSeconds(180));

        using var pc = new RTCPeerConnection(ConfigWithIce(opts.GetValueOrDefault("ice-servers", "")));
        var cands = new List<Cand>();
        pc.onicecandidate += c => { if (c != null) cands.Add(Cand.From(c)); };

        var opened = NewTcs<RTCDataChannel>();
        pc.ondatachannel += dc =>
        {
            Console.WriteLine($"[session-answer] datachannel '{dc.label}' offered");
            dc.onopen += () => opened.TrySetResult(dc);
            if (dc.readyState == RTCDataChannelState.open) opened.TrySetResult(dc);
        };

        if (pc.setRemoteDescription(new RTCSessionDescriptionInit { type = RTCSdpType.offer, sdp = off.Sdp }) != SetDescriptionResultEnum.OK)
            return Fail("session-answer rejected the peer offer");
        foreach (var c in off.Candidates) pc.addIceCandidate(c.ToInit());

        var answer = pc.createAnswer(null);
        await pc.setLocalDescription(answer);
        await WaitIceGatheringAsync(pc, TimeSpan.FromSeconds(8));
        Signal.Write(answerOut, "answer", answer.sdp, cands);
        Console.WriteLine($"[session-answer] wrote answer -> {Path.GetFullPath(answerOut)}; awaiting DataChannel open...");

        var channel = await opened.Task.WaitAsync(TimeSpan.FromSeconds(60));
        Console.WriteLine($"[session-answer] DataChannel state={channel.readyState}");
        if (channel.readyState != RTCDataChannelState.open)
            return Fail("session-answer: DataChannel did not open");

        return await PumpUntilDoneAsync(channel, ipcPort, portOut, holdSeconds, "session-answer", ipcToken);
    }

    // Shared session tail: write the bound IPC port (so the launcher can connect
    // deterministically), run the bidirectional SBF1 pump, and stop on
    // DataChannel/app close or after --hold-seconds (if > 0). hold-seconds<=0
    // means run until the channel/app closes (production behavior).
    private static async Task<int> PumpUntilDoneAsync(
        RTCDataChannel dc, int ipcPort, string portOutPath, int holdSeconds, string tag, string? ipcToken)
    {
        using var cts = new CancellationTokenSource();
        if (holdSeconds > 0) cts.CancelAfter(TimeSpan.FromSeconds(holdSeconds));

        void ReportPort(int port)
        {
            if (!string.IsNullOrWhiteSpace(portOutPath))
            {
                try
                {
                    var tmp = portOutPath + ".tmp";
                    File.WriteAllText(tmp, port.ToString(), new UTF8Encoding(false));
                    File.Move(tmp, portOutPath, overwrite: true);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    throw new InvalidOperationException(
                        $"[{tag}] could not write ipc-port-out '{portOutPath}': {ex.Message}", ex);
                }
            }
        }

        try
        {
            await SessionTransport.RunSessionAsync(dc, ipcPort, ReportPort, tag, cts.Token, ipcToken);
        }
        catch (OperationCanceledException)
        {
            Console.WriteLine($"[{tag}] hold window elapsed; closing data plane");
        }

        Console.WriteLine($"[{tag}] data plane ended");
        return 0;
    }

    private static int ParsePort(string raw) =>
        int.TryParse(raw, out var p) && p is >= 0 and <= 65535 ? p : 0;

    // Shared offerer tail: await open, send SBF1, verify echo, derive fields, emit proof.
    private static async Task<int> CompleteOffererAsync(
        RTCPeerConnection pc, RTCDataChannel dc, TaskCompletionSource opened, TaskCompletionSource<byte[]> echoed,
        string proofOut, string peerDeviceId, string peerFingerprint, string tag)
    {
        Console.WriteLine($"[{tag}] awaiting DataChannel open...");
        await opened.Task.WaitAsync(TimeSpan.FromSeconds(60));
        var dataChannelOpen = dc.readyState == RTCDataChannelState.open;
        Console.WriteLine($"[{tag}] DataChannel state={dc.readyState}");

        var payload = Encoding.UTF8.GetBytes("skybridge-webrtc-helper-probe");
        var frame = EncodeSbf1(ChannelControl, 1, FlagEndOfMessage, payload);
        dc.send(frame);
        var echo = await echoed.Task.WaitAsync(TimeSpan.FromSeconds(15));
        var sbf1EchoVerified = echo.AsSpan().SequenceEqual(frame);
        Console.WriteLine($"[{tag}] SBF1 echo verified={sbf1EchoVerified} ({echo.Length} bytes)");

        var localSdp = pc.localDescription?.sdp?.ToString() ?? "";
        var remoteSdp = pc.remoteDescription?.sdp?.ToString() ?? "";
        var localFp = ExtractFingerprint(localSdp);
        var remoteFp = ExtractFingerprint(remoteSdp);
        var (localEndpoint, localCand) = ExtractFirstCandidate(localSdp);
        var (remoteEndpoint, remoteCand) = ExtractFirstCandidate(remoteSdp);

        var proof = new ProofDocument
        {
            HelperName = "skybridge-webrtc-helper",
            PeerDeviceId = peerDeviceId,
            PeerPublicKeyFingerprint = peerFingerprint,
            DataChannelOpen = dataChannelOpen,
            Sbf1EchoVerified = sbf1EchoVerified,
            Sbf1FrameMagic = "SBF1",
            AdapterBinding = "verified webrtc datachannel helper",
            LocalEndpoint = string.IsNullOrWhiteSpace(localEndpoint) ? "127.0.0.1:0" : localEndpoint,
            RemoteEndpoint = string.IsNullOrWhiteSpace(remoteEndpoint) ? "127.0.0.1:0" : remoteEndpoint,
            SelectedCandidatePair = $"webrtc/dtls/sctp/{localCand}-{remoteCand}",
            TransportSecretFingerprintHex = Sha256Hex($"skybridge-webrtc-helper-transport:{localFp}:{remoteFp}"),
            CapabilityDigestHex = Sha256Hex(
                $"local=Windows,webrtc;remote=Apple,webrtc;peer={peerDeviceId};" +
                $"fingerprint={peerFingerprint};sameLan=true;crossNat=false"),
            RelayId = null,
            TimestampWindowMs = 15000,
            CapturedAtUnixMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
        };
        WriteProofAtomic(proofOut, proof);
        Console.WriteLine($"[{tag}] proof written: {Path.GetFullPath(proofOut)}");

        if (!dataChannelOpen || !sbf1EchoVerified)
            return Fail($"[{tag}] did not reach a live DataChannel with verified SBF1 echo");
        Console.WriteLine($"[{tag}] OK: live DataChannel + SBF1 echo + proof emitted");
        return 0;
    }

    // Resolves when ICE gathering completes, or after the timeout (host candidates gather fast on LAN).
    private static async Task WaitIceGatheringAsync(RTCPeerConnection pc, TimeSpan timeout)
    {
        if (pc.iceGatheringState == RTCIceGatheringState.complete) return;
        var tcs = NewTcs();
        pc.onicegatheringstatechange += state =>
        {
            if (state == RTCIceGatheringState.complete) tcs.TrySetResult();
        };
        await Task.WhenAny(tcs.Task, Task.Delay(timeout));
    }

    private static TaskCompletionSource NewTcs() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static TaskCompletionSource<T> NewTcs<T>() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    private static RTCIceCandidateInit ToInit(RTCIceCandidate c) => new()
    {
        candidate = c.candidate,
        sdpMid = c.sdpMid,
        sdpMLineIndex = c.sdpMLineIndex,
        usernameFragment = c.usernameFragment,
    };

    private static string ExtractFingerprint(string sdp)
    {
        var m = Regex.Match(sdp, @"a=fingerprint:\S+\s+([0-9A-Fa-f:]+)");
        return m.Success ? m.Groups[1].Value : "no-fingerprint";
    }

    private static (string endpoint, string label) ExtractFirstCandidate(string sdp)
    {
        var m = Regex.Match(sdp, @"a=candidate:\S+ \d+ \S+ \d+ (\S+) (\d+) typ (\S+)");
        if (!m.Success) return ("", "host");
        var endpoint = $"{m.Groups[1].Value}:{m.Groups[2].Value}";
        return (endpoint, $"{m.Groups[3].Value}-{endpoint}");
    }

    private static string Sha256Hex(string material) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(material))).ToLowerInvariant();

    private static void WriteProofAtomic(string path, ProofDocument proof)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var json = JsonSerializer.Serialize(proof, ProofDocument.JsonOptions);
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, json, new UTF8Encoding(false));
        File.Move(tmp, path, overwrite: true);
    }

    private static Dictionary<string, string> ParseArgs(string[] args)
    {
        var d = new Dictionary<string, string>();
        for (var i = 0; i < args.Length; i++)
        {
            if (!args[i].StartsWith("--")) continue;
            var key = args[i][2..];
            var val = (i + 1 < args.Length && !args[i + 1].StartsWith("--")) ? args[++i] : "true";
            d[key] = val;
        }
        return d;
    }
}
