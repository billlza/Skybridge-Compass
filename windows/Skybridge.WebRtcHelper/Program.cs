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
//                      the SBF1 channel byte. This remains a helper smoke profile,
//                      not the Mac product WebRTC control protocol.
//   --mode session-echo
//                      App-side verifier for a helper session IPC. Connects to a
//                      session helper loopback port, echoes SBF1 frames back to
//                      that same port, then exits after --count frames.
//   --mode product-control-offer / --mode product-control-answer
//                      MAC PRODUCT CONTROL TRANSPORT SHELL. Same file signaling,
//                      but the WebRTC wire is the Mac product control channel:
//                      DataChannel label "skybridge" and raw 4-byte-length-framed
//                      control chunks on the local loopback IPC. No SBF1 and no
//                      fake protocol fallback. This is the transport boundary that
//                      a real handshake/SBWC implementation plugs into.
//   --mode product-control-driver / --mode product-control-echo
//                      Test-only loopback peers for the raw product-control IPC.
//
// The helper NEVER emits AppleNative binding — always WebRtcDataChannel /
// WebRtcInterop (Apple<->Apple stays on the Apple native path).
// Offer proofs record --network-path same-lan|cross-nat in their capability
// transcript; Core still owns transport selection and launch binding.

using System.Buffers.Binary;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using SIPSorcery.Net;
using Skybridge.WebRtcHelper;

internal sealed record NetworkPathTranscript(string Name, bool SameLan, bool CrossNat);

internal sealed record NominatedCandidatePair(
    string LocalEndpoint,
    string LocalType,
    string RemoteEndpoint,
    string RemoteType)
{
    public static NominatedCandidatePair From(RTCIceCandidate localCandidate, RTCIceCandidate remoteCandidate)
    {
        return new NominatedCandidatePair(
            EndpointFor(localCandidate),
            CandidateTypeFor(localCandidate),
            EndpointFor(remoteCandidate),
            CandidateTypeFor(remoteCandidate));
    }

    public string ToTranscript(NetworkPathTranscript networkPath) =>
        $"webrtc/dtls/sctp/local={LocalType}:{LocalEndpoint};remote={RemoteType}:{RemoteEndpoint};path={networkPath.Name}";

    private static string EndpointFor(RTCIceCandidate candidate)
    {
        var address = candidate.address?.ToString();
        if (string.IsNullOrWhiteSpace(address))
        {
            throw new InvalidOperationException("Nominated ICE candidate is missing an address.");
        }

        if (candidate.port == 0)
        {
            throw new InvalidOperationException("Nominated ICE candidate is missing a port.");
        }

        return address.Contains(':', StringComparison.Ordinal) ? $"[{address}]:{candidate.port}" : $"{address}:{candidate.port}";
    }

    private static string CandidateTypeFor(RTCIceCandidate candidate) =>
        candidate.type.ToString().ToLowerInvariant();
}

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
                "session-echo" => await SessionEcho.RunAsync(opts),
                "product-control-offer" => await RunProductControlOfferAsync(opts),
                "product-control-answer" => await RunProductControlAnswerAsync(opts),
                "product-control-driver" => await ProductControlDriver.RunAsync(opts),
                "product-control-echo" => await ProductControlEcho.RunAsync(opts),
                _ => Fail($"unknown mode '{mode}' (use loopback|offer|answer|session-offer|session-answer|session-driver|session-echo|product-control-offer|product-control-answer|product-control-driver|product-control-echo)"),
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

    private static RTCConfiguration NewConfig() => ConfigWithIce("", null);

    // Builds a config with unauthenticated STUN URLs from --ice-servers and
    // authenticated TURN/STUN entries from a local credentials JSON file. TURN
    // credentials must never be passed on argv because process lists and logs can
    // expose them.
    private static RTCConfiguration ConfigWithIce(string csv, Dictionary<string, string>? opts)
    {
        var servers = new List<RTCIceServer>();
        foreach (var raw in csv.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            if (raw.Contains('|', StringComparison.Ordinal) || raw.Contains(';', StringComparison.Ordinal))
            {
                throw new ArgumentException("--ice-servers must not include inline TURN credentials; use LAN/STUN-only until a credential file/channel is wired.");
            }

            var uri = ValidateIceServerUri(raw);
            if (IsTurnUri(uri))
            {
                throw new ArgumentException("--ice-servers must not include TURN URLs without a credential file; use --ice-server-credentials.");
            }

            servers.Add(new RTCIceServer { urls = raw });
        }

        if (opts is not null && opts.TryGetValue("ice-server-credentials", out var credentialsPath) && !string.IsNullOrWhiteSpace(credentialsPath))
        {
            servers.AddRange(ReadIceServerCredentials(credentialsPath));
        }

        var config = new RTCConfiguration { iceServers = servers };
        ApplyLocalIceOptions(config, opts);
        return config;
    }

    private static Uri ValidateIceServerUri(string raw)
    {
        if (!Uri.TryCreate(raw, UriKind.Absolute, out var uri))
        {
            throw new ArgumentException("--ice-servers must contain absolute stun:, stuns:, turn:, or turns: URIs.");
        }

        if (uri.Scheme is not ("stun" or "stuns" or "turn" or "turns"))
        {
            throw new ArgumentException("--ice-servers supports only stun:, stuns:, turn:, or turns: URIs.");
        }

        if (!string.IsNullOrEmpty(uri.UserInfo) ||
            !string.IsNullOrEmpty(uri.Query) ||
            !string.IsNullOrEmpty(uri.Fragment))
        {
            throw new ArgumentException("--ice-servers must not include URI userinfo, query, or fragment credentials; use LAN/STUN-only until a secure TURN credential channel is wired.");
        }

        return uri;
    }

    private static bool IsTurnUri(Uri uri) => uri.Scheme is "turn" or "turns";

    private static List<RTCIceServer> ReadIceServerCredentials(string path)
    {
        var resolvedPath = Path.GetFullPath(path);
        var info = new FileInfo(resolvedPath);
        if (!info.Exists)
        {
            throw new ArgumentException($"--ice-server-credentials file does not exist: {resolvedPath}");
        }

        if (info.Length is <= 0 or > 65536)
        {
            throw new ArgumentException("--ice-server-credentials must be a non-empty JSON file no larger than 64 KiB.");
        }

        using var document = JsonDocument.Parse(File.ReadAllText(resolvedPath));
        if (document.RootElement.ValueKind != JsonValueKind.Object ||
            !document.RootElement.TryGetProperty("iceServers", out var iceServers) ||
            iceServers.ValueKind != JsonValueKind.Array)
        {
            throw new ArgumentException("--ice-server-credentials must be a JSON object with an iceServers array.");
        }

        var servers = new List<RTCIceServer>();
        foreach (var entry in iceServers.EnumerateArray())
        {
            if (entry.ValueKind != JsonValueKind.Object)
            {
                throw new ArgumentException("--ice-server-credentials iceServers entries must be JSON objects.");
            }

            var urls = ReadIceServerUrls(entry);
            var username = ReadOptionalJsonString(entry, "username");
            var credential = ReadOptionalJsonString(entry, "credential");
            var credentialType = ReadOptionalJsonString(entry, "credentialType");
            if (!string.IsNullOrWhiteSpace(credentialType) && !string.Equals(credentialType, "password", StringComparison.Ordinal))
            {
                throw new ArgumentException("--ice-server-credentials supports only credentialType=password.");
            }

            foreach (var url in urls)
            {
                if (url.Contains('|', StringComparison.Ordinal) || url.Contains(';', StringComparison.Ordinal))
                {
                    throw new ArgumentException("--ice-server-credentials URLs must not include inline TURN credentials.");
                }

                var uri = ValidateIceServerUri(url);
                if (IsTurnUri(uri) && (string.IsNullOrWhiteSpace(username) || string.IsNullOrWhiteSpace(credential)))
                {
                    throw new ArgumentException("--ice-server-credentials TURN entries require non-empty username and credential fields.");
                }

                servers.Add(new RTCIceServer
                {
                    urls = url,
                    username = username,
                    credential = credential,
                    credentialType = RTCIceCredentialType.password,
                });
            }
        }

        if (servers.Count == 0)
        {
            throw new ArgumentException("--ice-server-credentials must contain at least one ICE server.");
        }

        return servers;
    }

    private static List<string> ReadIceServerUrls(JsonElement entry)
    {
        if (!entry.TryGetProperty("urls", out var urls))
        {
            throw new ArgumentException("--ice-server-credentials entries require urls.");
        }

        if (urls.ValueKind == JsonValueKind.String)
        {
            var value = urls.GetString();
            if (string.IsNullOrWhiteSpace(value))
            {
                throw new ArgumentException("--ice-server-credentials urls must not be empty.");
            }

            return [value];
        }

        if (urls.ValueKind != JsonValueKind.Array)
        {
            throw new ArgumentException("--ice-server-credentials urls must be a string or array of strings.");
        }

        var values = new List<string>();
        foreach (var url in urls.EnumerateArray())
        {
            if (url.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(url.GetString()))
            {
                throw new ArgumentException("--ice-server-credentials urls array must contain non-empty strings.");
            }

            values.Add(url.GetString()!);
        }

        if (values.Count == 0)
        {
            throw new ArgumentException("--ice-server-credentials urls array must not be empty.");
        }

        return values;
    }

    private static string ReadOptionalJsonString(JsonElement entry, string propertyName)
    {
        if (!entry.TryGetProperty(propertyName, out var property))
        {
            return "";
        }

        if (property.ValueKind != JsonValueKind.String)
        {
            throw new ArgumentException($"--ice-server-credentials {propertyName} must be a string.");
        }

        return property.GetString() ?? "";
    }

    private static void ApplyLocalIceOptions(RTCConfiguration config, Dictionary<string, string>? opts)
    {
        if (opts is null)
        {
            return;
        }

        if (opts.TryGetValue("bind-address", out var bindAddress) && !string.IsNullOrWhiteSpace(bindAddress))
        {
            if (!IPAddress.TryParse(bindAddress, out var parsed))
            {
                throw new ArgumentException("--bind-address must be a valid IP address.");
            }

            if (IPAddress.IsLoopback(parsed) || IPAddress.Any.Equals(parsed) || IPAddress.IPv6Any.Equals(parsed))
            {
                throw new ArgumentException("--bind-address must be a concrete non-loopback local interface address.");
            }

            config.X_BindAddress = parsed;
        }

        if (opts.TryGetValue("ice-include-all-interfaces", out var includeAllInterfaces) &&
            IsEnabled(includeAllInterfaces))
        {
            config.X_ICEIncludeAllInterfaceAddresses = true;
        }
    }

    private static bool IsEnabled(string value) =>
        string.Equals(value, "1", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(value, "true", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(value, "yes", StringComparison.OrdinalIgnoreCase);

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

    private static NetworkPathTranscript GetNetworkPathTranscript(Dictionary<string, string>? opts)
    {
        var value = opts?.GetValueOrDefault("network-path", "same-lan") ?? "same-lan";
        return value switch
        {
            "same-lan" => new NetworkPathTranscript("same-lan", SameLan: true, CrossNat: false),
            "cross-nat" => new NetworkPathTranscript("cross-nat", SameLan: false, CrossNat: true),
            _ => throw new ArgumentException("--network-path must be 'same-lan' or 'cross-nat'."),
        };
    }

    private static string FormatBool(bool value) => value ? "true" : "false";

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

        return await CompleteOffererAsync(
            offerer,
            dc,
            opened,
            echoed,
            proofOut,
            peerDeviceId,
            peerFingerprint,
            "loopback",
            GetNetworkPathTranscript(null));
    }

    // ------------------------------------------------------------------- offer
    private static async Task<int> RunOfferAsync(
        Dictionary<string, string> opts, string proofOut, string peerDeviceId, string peerFingerprint)
    {
        var networkPath = GetNetworkPathTranscript(opts);
        var offerOut = opts.GetValueOrDefault("offer-out", "offer.json");
        var answerIn = opts.GetValueOrDefault("answer-in", "answer.json");
        Console.WriteLine("[offer] creating peer connection...");
        using var pc = new RTCPeerConnection(ConfigWithIce(opts.GetValueOrDefault("ice-servers", ""), opts));
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

        return await CompleteOffererAsync(
            pc,
            dc,
            opened,
            echoed,
            proofOut,
            peerDeviceId,
            peerFingerprint,
            "offer",
            networkPath);
    }

    // ------------------------------------------------------------------ answer
    private static async Task<int> RunAnswerAsync(Dictionary<string, string> opts)
    {
        var offerIn = opts.GetValueOrDefault("offer-in", "offer.json");
        var answerOut = opts.GetValueOrDefault("answer-out", "answer.json");
        var holdSeconds = int.TryParse(opts.GetValueOrDefault("hold-seconds", "60"), out var h) ? h : 60;
        Console.WriteLine($"[answer] waiting for offer at {offerIn} ...");
        var off = await Signal.WaitReadAsync(offerIn, TimeSpan.FromSeconds(180));

        using var pc = new RTCPeerConnection(ConfigWithIce(opts.GetValueOrDefault("ice-servers", ""), opts));
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
        var holdSeconds = int.TryParse(opts.GetValueOrDefault("hold-seconds", "0"), out var h) ? h : 0;

        Console.WriteLine("[session-offer] creating peer connection...");
        using var pc = new RTCPeerConnection(ConfigWithIce(opts.GetValueOrDefault("ice-servers", ""), opts));
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

        return await PumpUntilDoneAsync(dc, ipcPort, portOut, holdSeconds, "session-offer");
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
        var holdSeconds = int.TryParse(opts.GetValueOrDefault("hold-seconds", "0"), out var h) ? h : 0;

        Console.WriteLine($"[session-answer] waiting for offer at {offerIn} ...");
        var off = await Signal.WaitReadAsync(offerIn, TimeSpan.FromSeconds(180));

        using var pc = new RTCPeerConnection(ConfigWithIce(opts.GetValueOrDefault("ice-servers", ""), opts));
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

        return await PumpUntilDoneAsync(channel, ipcPort, portOut, holdSeconds, "session-answer");
    }

    // ------------------------------------------------------ product-control-offer
    // The Mac product control transport shell. It deliberately does not speak
    // SBF1: each local IPC message is forwarded as one raw DataChannel message on
    // label "skybridge", matching the Mac product control channel boundary.
    private static async Task<int> RunProductControlOfferAsync(Dictionary<string, string> opts)
    {
        var offerOut = opts.GetValueOrDefault("offer-out", "offer.json");
        var answerIn = opts.GetValueOrDefault("answer-in", "answer.json");
        var ipcPort = ParsePort(opts.GetValueOrDefault("ipc-port", "0"));
        var portOut = opts.GetValueOrDefault("ipc-port-out", "");
        var holdSeconds = int.TryParse(opts.GetValueOrDefault("hold-seconds", "0"), out var h) ? h : 0;
        var ipcAuthToken = ReadProductControlIpcAuthToken(opts);

        try
        {
            Console.WriteLine("[product-control-offer] creating peer connection...");
            using var pc = new RTCPeerConnection(ConfigWithIce(opts.GetValueOrDefault("ice-servers", ""), opts));
            var cands = new List<Cand>();
            pc.onicecandidate += c => { if (c != null) cands.Add(Cand.From(c)); };

            var dc = await pc.createDataChannel(ProductControlTransport.DataChannelLabel);
            var opened = NewTcs();
            dc.onopen += () => opened.TrySetResult();

            var offer = pc.createOffer(null);
            await pc.setLocalDescription(offer);
            await WaitIceGatheringAsync(pc, TimeSpan.FromSeconds(8));
            Signal.Write(offerOut, "offer", offer.sdp, cands);
            Console.WriteLine($"[product-control-offer] wrote offer -> {Path.GetFullPath(offerOut)}; waiting for answer at {answerIn} ...");

            var ans = await Signal.WaitReadAsync(answerIn, TimeSpan.FromSeconds(180));
            if (pc.setRemoteDescription(new RTCSessionDescriptionInit { type = RTCSdpType.answer, sdp = ans.Sdp }) != SetDescriptionResultEnum.OK)
                return Fail("product-control-offer rejected the peer answer");
            foreach (var c in ans.Candidates) pc.addIceCandidate(c.ToInit());

            Console.WriteLine("[product-control-offer] awaiting DataChannel open...");
            await opened.Task.WaitAsync(TimeSpan.FromSeconds(60));
            Console.WriteLine($"[product-control-offer] DataChannel state={dc.readyState}");
            if (dc.readyState != RTCDataChannelState.open)
                return Fail("product-control-offer: DataChannel did not open");

            return await PumpProductControlUntilDoneAsync(dc, ipcPort, portOut, holdSeconds, "product-control-offer", ipcAuthToken);
        }
        finally
        {
            ZeroAuthToken(ipcAuthToken);
        }
    }

    // ----------------------------------------------------- product-control-answer
    private static async Task<int> RunProductControlAnswerAsync(Dictionary<string, string> opts)
    {
        var offerIn = opts.GetValueOrDefault("offer-in", "offer.json");
        var answerOut = opts.GetValueOrDefault("answer-out", "answer.json");
        var ipcPort = ParsePort(opts.GetValueOrDefault("ipc-port", "0"));
        var portOut = opts.GetValueOrDefault("ipc-port-out", "");
        var holdSeconds = int.TryParse(opts.GetValueOrDefault("hold-seconds", "0"), out var h) ? h : 0;
        var ipcAuthToken = ReadProductControlIpcAuthToken(opts);

        try
        {
            Console.WriteLine($"[product-control-answer] waiting for offer at {offerIn} ...");
            var off = await Signal.WaitReadAsync(offerIn, TimeSpan.FromSeconds(180));

            using var pc = new RTCPeerConnection(ConfigWithIce(opts.GetValueOrDefault("ice-servers", ""), opts));
            var cands = new List<Cand>();
            pc.onicecandidate += c => { if (c != null) cands.Add(Cand.From(c)); };

            var opened = NewTcs<RTCDataChannel>();
            pc.ondatachannel += dc =>
            {
                Console.WriteLine($"[product-control-answer] datachannel '{dc.label}' offered");
                if (!string.Equals(dc.label, ProductControlTransport.DataChannelLabel, StringComparison.Ordinal))
                {
                    opened.TrySetException(new InvalidOperationException(
                        $"product-control-answer rejects DataChannel label '{dc.label}'; expected '{ProductControlTransport.DataChannelLabel}'."));
                    return;
                }

                dc.onopen += () => opened.TrySetResult(dc);
                if (dc.readyState == RTCDataChannelState.open) opened.TrySetResult(dc);
            };

            if (pc.setRemoteDescription(new RTCSessionDescriptionInit { type = RTCSdpType.offer, sdp = off.Sdp }) != SetDescriptionResultEnum.OK)
                return Fail("product-control-answer rejected the peer offer");
            foreach (var c in off.Candidates) pc.addIceCandidate(c.ToInit());

            var answer = pc.createAnswer(null);
            await pc.setLocalDescription(answer);
            await WaitIceGatheringAsync(pc, TimeSpan.FromSeconds(8));
            Signal.Write(answerOut, "answer", answer.sdp, cands);
            Console.WriteLine($"[product-control-answer] wrote answer -> {Path.GetFullPath(answerOut)}; awaiting DataChannel open...");

            var channel = await opened.Task.WaitAsync(TimeSpan.FromSeconds(60));
            Console.WriteLine($"[product-control-answer] DataChannel state={channel.readyState}");
            if (channel.readyState != RTCDataChannelState.open)
                return Fail("product-control-answer: DataChannel did not open");

            return await PumpProductControlUntilDoneAsync(channel, ipcPort, portOut, holdSeconds, "product-control-answer", ipcAuthToken);
        }
        finally
        {
            ZeroAuthToken(ipcAuthToken);
        }
    }

    // Shared session tail: write the bound IPC port (so the launcher can connect
    // deterministically), run the bidirectional SBF1 pump, and stop on
    // DataChannel/app close or after --hold-seconds (if > 0). hold-seconds<=0
    // means run until the channel/app closes (production behavior).
    private static async Task<int> PumpUntilDoneAsync(
        RTCDataChannel dc, int ipcPort, string portOutPath, int holdSeconds, string tag)
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
                catch (IOException ex)
                {
                    Console.Error.WriteLine($"[{tag}] could not write ipc-port-out: {ex.Message}");
                }
            }
        }

        try
        {
            await SessionTransport.RunSessionAsync(dc, ipcPort, ReportPort, tag, cts.Token);
        }
        catch (OperationCanceledException)
        {
            Console.WriteLine($"[{tag}] hold window elapsed; closing data plane");
        }

        Console.WriteLine($"[{tag}] data plane ended");
        return 0;
    }

    private static async Task<int> PumpProductControlUntilDoneAsync(
        RTCDataChannel dc, int ipcPort, string portOutPath, int holdSeconds, string tag, byte[]? ipcAuthToken)
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
                catch (IOException ex)
                {
                    Console.Error.WriteLine($"[{tag}] could not write ipc-port-out: {ex.Message}");
                }
            }
        }

        try
        {
            await ProductControlTransport.RunSessionAsync(dc, ipcPort, ReportPort, tag, ipcAuthToken, cts.Token);
        }
        catch (OperationCanceledException)
        {
            Console.WriteLine($"[{tag}] hold window elapsed; closing product control transport");
        }

        Console.WriteLine($"[{tag}] product control transport ended");
        return 0;
    }

    private static int ParsePort(string raw)
    {
        if (int.TryParse(raw, out var p) && p is >= 0 and <= 65535)
        {
            return p;
        }

        throw new ArgumentException("--ipc-port must be 0 for an OS-chosen port, or a TCP port in the range 1-65535.");
    }

    private static byte[]? ReadProductControlIpcAuthToken(Dictionary<string, string> opts)
    {
        var envName = opts.GetValueOrDefault("ipc-auth-token-env", "");
        if (string.IsNullOrWhiteSpace(envName))
        {
            return null;
        }

        envName = envName.Trim();
        if (envName.Any(ch => !(char.IsLetterOrDigit(ch) || ch == '_')))
        {
            throw new ArgumentException("--ipc-auth-token-env must name an environment variable using letters, digits, or underscores.");
        }

        var encoded = Environment.GetEnvironmentVariable(envName);
        if (string.IsNullOrWhiteSpace(encoded))
        {
            throw new ArgumentException("Environment variable named by --ipc-auth-token-env is missing or empty.");
        }

        try
        {
            return ProductControlTransport.DecodeIpcAuthTokenFromBase64(
                encoded.Trim(),
                "product-control IPC authentication token");
        }
        finally
        {
            Environment.SetEnvironmentVariable(envName, null);
        }
    }

    private static void ZeroAuthToken(byte[]? token)
    {
        if (token is not null)
        {
            CryptographicOperations.ZeroMemory(token);
        }
    }

    // Shared offerer tail: await open, send SBF1, verify echo, derive fields, emit proof.
    private static async Task<int> CompleteOffererAsync(
        RTCPeerConnection pc, RTCDataChannel dc, TaskCompletionSource opened, TaskCompletionSource<byte[]> echoed,
        string proofOut,
        string peerDeviceId,
        string peerFingerprint,
        string tag,
        NetworkPathTranscript networkPath)
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

        var nominatedPair = await WaitForNominatedCandidatePairAsync(pc, TimeSpan.FromSeconds(5));
        var localSdp = pc.localDescription?.sdp?.ToString() ?? "";
        var remoteSdp = pc.remoteDescription?.sdp?.ToString() ?? "";
        var localFp = ExtractFingerprint(localSdp);
        var remoteFp = ExtractFingerprint(remoteSdp);

        var proof = new ProofDocument
        {
            HelperName = "skybridge-webrtc-helper",
            PeerDeviceId = peerDeviceId,
            PeerPublicKeyFingerprint = peerFingerprint,
            DataChannelOpen = dataChannelOpen,
            Sbf1EchoVerified = sbf1EchoVerified,
            Sbf1FrameMagic = "SBF1",
            AdapterBinding = "verified webrtc datachannel helper",
            LocalEndpoint = nominatedPair.LocalEndpoint,
            RemoteEndpoint = nominatedPair.RemoteEndpoint,
            SelectedCandidatePair = nominatedPair.ToTranscript(networkPath),
            TransportSecretFingerprintHex = Sha256Hex($"skybridge-webrtc-helper-transport:{localFp}:{remoteFp}"),
            CapabilityDigestHex = Sha256Hex(
                $"local=Windows,webrtc;remote=Apple,webrtc;peer={peerDeviceId};" +
                $"fingerprint={peerFingerprint};sameLan={FormatBool(networkPath.SameLan)};crossNat={FormatBool(networkPath.CrossNat)}"),
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

    private static async Task<NominatedCandidatePair> WaitForNominatedCandidatePairAsync(
        RTCPeerConnection pc,
        TimeSpan timeout)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        do
        {
            var nominatedEntry = pc.GetRtpChannel()?.NominatedEntry;
            if (nominatedEntry is not null)
            {
                return NominatedCandidatePair.From(nominatedEntry.LocalCandidate, nominatedEntry.RemoteCandidate);
            }

            await Task.Delay(TimeSpan.FromMilliseconds(100));
        }
        while (DateTimeOffset.UtcNow < deadline);

        throw new InvalidOperationException(
            "WebRTC helper reached DataChannel echo but could not read the nominated ICE candidate pair.");
    }

    private static string Sha256Hex(string material) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(material))).ToLowerInvariant();

    private static void WriteProofAtomic(string path, ProofDocument proof)
    {
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
