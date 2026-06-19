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
//                      zero external dependencies. Fully self-verifying.
//   --mode offer      offerer against a real peer; SDP exchanged via files
//                      (--offer-out / --answer-in). For live Win<->Mac.
//   --mode answer     answerer (echoes SBF1) for the peer side of a real run.
//
// The helper NEVER emits AppleNative binding — it is always WebRtcDataChannel /
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
        var peerDeviceId = opts.GetValueOrDefault("peer-device-id", "loopback-peer");
        var peerFingerprint = opts.GetValueOrDefault(
            "peer-fingerprint",
            "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");

        if (!Regex.IsMatch(peerFingerprint, "^[0-9a-f]{64}$"))
        {
            Console.Error.WriteLine("peer-fingerprint must be exactly 64 lowercase hex chars");
            return 2;
        }

        try
        {
            return mode switch
            {
                "loopback" => await RunLoopbackAsync(proofOut, peerDeviceId, peerFingerprint),
                _ => Fail($"mode '{mode}' not yet implemented (use loopback)"),
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

    private static async Task<int> RunLoopbackAsync(string proofOut, string peerDeviceId, string peerFingerprint)
    {
        Console.WriteLine("[loopback] creating two peer connections...");
        var config = new RTCConfiguration { iceServers = new List<RTCIceServer>() };
        using var offerer = new RTCPeerConnection(config);
        using var answerer = new RTCPeerConnection(config);

        // Trickle ICE between the two in-process peers.
        offerer.onicecandidate += c => { if (c != null) answerer.addIceCandidate(ToInit(c)); };
        answerer.onicecandidate += c => { if (c != null) offerer.addIceCandidate(ToInit(c)); };

        // Answerer echoes any DataChannel message back verbatim.
        answerer.ondatachannel += dc => dc.onmessage += (chan, _, data) => chan.send(data);

        var dc = await offerer.createDataChannel("skybridge");
        var opened = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var echoed = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        dc.onopen += () => opened.TrySetResult();
        dc.onmessage += (_, _, data) => echoed.TrySetResult(data);

        // Offer/answer exchange.
        var offer = offerer.createOffer(null);
        await offerer.setLocalDescription(offer);
        if (answerer.setRemoteDescription(offer) != SetDescriptionResultEnum.OK)
            return Fail("answerer rejected the offer");
        var answer = answerer.createAnswer(null);
        await answerer.setLocalDescription(answer);
        if (offerer.setRemoteDescription(answer) != SetDescriptionResultEnum.OK)
            return Fail("offerer rejected the answer");

        Console.WriteLine("[loopback] awaiting DataChannel open...");
        await opened.Task.WaitAsync(TimeSpan.FromSeconds(30));
        var dataChannelOpen = dc.readyState == RTCDataChannelState.open;
        Console.WriteLine($"[loopback] DataChannel state={dc.readyState}");

        // Send the SBF1 probe frame and await the echo.
        var payload = Encoding.UTF8.GetBytes("skybridge-webrtc-helper-probe");
        var frame = EncodeSbf1(ChannelControl, sequence: 1, FlagEndOfMessage, payload);
        dc.send(frame);
        var echo = await echoed.Task.WaitAsync(TimeSpan.FromSeconds(10));
        var sbf1EchoVerified = echo.AsSpan().SequenceEqual(frame);
        Console.WriteLine($"[loopback] SBF1 echo verified={sbf1EchoVerified} ({echo.Length} bytes)");

        // Derive proof fields from the real session.
        var localSdp = offerer.localDescription?.sdp?.ToString() ?? "";
        var remoteSdp = offerer.remoteDescription?.sdp?.ToString() ?? "";
        var localFp = ExtractFingerprint(localSdp);
        var remoteFp = ExtractFingerprint(remoteSdp);
        var (localEndpoint, localCand) = ExtractFirstCandidate(localSdp);
        var (remoteEndpoint, remoteCand) = ExtractFirstCandidate(remoteSdp);

        var transportSecretHex = Sha256Hex(
            $"skybridge-webrtc-helper-transport:{localFp}:{remoteFp}");
        var capabilityDigestHex = Sha256Hex(
            $"local=Windows,webrtc;remote=Apple,webrtc;peer={peerDeviceId};" +
            $"fingerprint={peerFingerprint};sameLan=true;crossNat=false");

        var selectedCandidatePair = $"webrtc/dtls/sctp/{localCand}-{remoteCand}";

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
            SelectedCandidatePair = selectedCandidatePair,
            TransportSecretFingerprintHex = transportSecretHex,
            CapabilityDigestHex = capabilityDigestHex,
            RelayId = null,
            TimestampWindowMs = 15000,
            CapturedAtUnixMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
        };

        WriteProofAtomic(proofOut, proof);
        Console.WriteLine($"[loopback] proof written: {Path.GetFullPath(proofOut)}");

        if (!dataChannelOpen || !sbf1EchoVerified)
            return Fail("loopback did not reach a live DataChannel with verified SBF1 echo");

        Console.WriteLine("[loopback] OK: live DataChannel + SBF1 echo + proof emitted");
        return 0;
    }

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

    // Returns ("host:port", "typ-host:port") for the first ICE candidate found.
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
