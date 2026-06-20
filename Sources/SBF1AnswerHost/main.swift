//
//  main.swift
//  SBF1AnswerHost
//
//  Bridge-A ANSWERER HARNESS: a runnable, self-contained WebRTC answerer that
//  speaks the SBF1 interop frame format over a raw WebRTC DataChannel.
//
//  Intended live test:
//    Windows helper `--mode session-offer` (runs on this same Mac) writes an
//    offer.json; this harness reads it, builds a `WebRTCSession(role: .answerer)`
//    over loopback host candidates, writes an answer.json the Windows helper
//    consumes, then logs + echoes every inbound SBF1 frame verbatim.
//
//  SAFETY / SCOPE:
//  - ADDITIVE ONLY. This executable reuses public `SkyBridgeCore` surface
//    (`WebRTCSession`, `SBF1Frame`, `SBF1Channel`, `SBF1Flags`). It does NOT
//    touch the Apple↔Apple P2P / PQC handshake path.
//  - No STUN/TURN server is required — both peers are on one machine, so ICE
//    resolves via host candidates. A loopback STUN URL is supplied purely to
//    satisfy `WebRTCSession.buildIceServers()` (which refuses an empty ICE set);
//    it does not need to be reachable for loopback connectivity.
//
//  Offer / answer JSON schema (Windows helper):
//    { "type": "offer"|"answer",
//      "sdp": "...",
//      "candidates": [
//        { "candidate": "...", "sdpMid": "0", "sdpMLineIndex": 0,
//          "usernameFragment": "..." } ] }
//

import Foundation
import SkyBridgeCore
import SkyBridgeProtocolCore

// MARK: - Wire schema (matches the Windows helper)

private struct SignalingCandidate: Codable {
    var candidate: String
    var sdpMid: String?
    var sdpMLineIndex: Int32?
    var usernameFragment: String?
}

private struct SignalingDescription: Codable {
    var type: String
    var sdp: String
    var candidates: [SignalingCandidate]
}

// MARK: - Thread-safe collector for the locally-produced answer + candidates

/// The `WebRTCSession` callbacks are `@Sendable` and fire on the session's
/// internal callback queue. This small lock-guarded box is the single place the
/// answer SDP and gathered local candidates are accumulated, so the main flow
/// can poll/read them without data races.
private final class AnswerCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _answerSDP: String?
    private var _candidates: [SignalingCandidate] = []
    private var _dataChannelOpen = false

    func storeAnswer(_ sdp: String) {
        lock.lock(); defer { lock.unlock() }
        // The session may emit the answer twice: once right after
        // setLocalDescription, then again (fully gathered) on ICE-complete.
        // Always keep the latest — the gathered one is a superset.
        _answerSDP = sdp
    }

    func appendCandidate(_ candidate: SignalingCandidate) {
        lock.lock(); defer { lock.unlock() }
        // De-dup on the candidate line (gathering can repeat under continual mode).
        if _candidates.contains(where: { $0.candidate == candidate.candidate }) { return }
        _candidates.append(candidate)
    }

    func markDataChannelOpen() {
        lock.lock(); defer { lock.unlock() }
        _dataChannelOpen = true
    }

    var answerSDP: String? {
        lock.lock(); defer { lock.unlock() }
        return _answerSDP
    }

    var candidates: [SignalingCandidate] {
        lock.lock(); defer { lock.unlock() }
        return _candidates
    }

    var snapshot: (answer: String?, candidates: [SignalingCandidate], open: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (_answerSDP, _candidates, _dataChannelOpen)
    }
}

// MARK: - Per-channel SBF1 reassembly (mirrors SBF1ChannelState semantics)

/// SBF1ChannelState is `internal` to SkyBridgeCore, so the harness keeps its own
/// tiny reassembler with the same contract: accumulate per channel until an
/// `endOfMessage` frame, then return the full logical message. Lock-guarded so it
/// is safe to capture in the session's `@Sendable` `onData` callback.
private final class HarnessReassembler: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [SBF1Channel: Data] = [:]

    func accumulate(_ frame: SBF1Frame) -> Data? {
        lock.lock(); defer { lock.unlock() }
        var buffer = buffers[frame.channel] ?? Data()
        buffer.append(frame.payload)
        if buffer.count > SBF1Frame.maxPayloadBytes {
            buffers[frame.channel] = nil
            return nil
        }
        if frame.flags.contains(.endOfMessage) {
            buffers[frame.channel] = nil
            return buffer
        }
        buffers[frame.channel] = buffer
        return nil
    }
}

// MARK: - Logging

private func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] \(message)")
    fflush(stdout)
}

// MARK: - Argument parsing

private func stringFlag(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
    return args[i + 1]
}

private func intFlag(_ name: String, in args: [String]) -> Int? {
    guard let raw = stringFlag(name, in: args) else { return nil }
    return Int(raw)
}

// MARK: - Atomic file write (temp + rename)

private func writeJSONAtomic<T: Encodable>(_ value: T, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    let finalURL = URL(fileURLWithPath: path)
    let tmpURL = finalURL.deletingLastPathComponent()
        .appendingPathComponent(".\(finalURL.lastPathComponent).tmp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: finalURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: tmpURL, options: .atomic)
    // Replace any existing answer.json in place.
    if FileManager.default.fileExists(atPath: finalURL.path) {
        _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tmpURL)
    } else {
        try FileManager.default.moveItem(at: tmpURL, to: finalURL)
    }
}

// MARK: - Entry point

@main
struct SBF1AnswerHost {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())

        guard let offerInPath = stringFlag("--offer-in", in: args),
              let answerOutPath = stringFlag("--answer-out", in: args) else {
            log("usage: SBF1AnswerHost --offer-in <path> --answer-out <path> [--hold-seconds <n=30>]")
            exit(2)
        }
        let holdSeconds = intFlag("--hold-seconds", in: args) ?? 30

        log("[answer] boot offer-in=\(offerInPath) answer-out=\(answerOutPath) hold-seconds=\(holdSeconds)")

        // 1) Read the offer JSON written by the Windows helper.
        let offer: SignalingDescription
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: offerInPath))
            offer = try JSONDecoder().decode(SignalingDescription.self, from: data)
        } catch {
            log("[answer] FATAL failed to read/parse offer-in: \(error.localizedDescription)")
            exit(1)
        }
        guard offer.type.lowercased() == "offer", !offer.sdp.isEmpty else {
            log("[answer] FATAL offer-in is not a non-empty offer (type=\(offer.type))")
            exit(1)
        }
        log("[answer] loaded offer sdpBytes=\(offer.sdp.utf8.count) remoteCandidates=\(offer.candidates.count)")

        // 2) Build the answerer session over loopback host candidates.
        let collector = AnswerCollector()
        let reassembler = HarnessReassembler()

        let ice = SkyBridgeICEConfiguration(
            stunURL: "stun:127.0.0.1:3478", // satisfies buildIceServers(); host candidates carry loopback
            turnURLs: [],
            turnUsername: "",
            turnPassword: ""
        )
        let session = WebRTCSession(
            sessionId: "sbf1-answer-\(UUID().uuidString.prefix(8))",
            localDeviceId: "sbf1-answer-host",
            role: .answerer,
            ice: ice
        )

        // 3) Wire callbacks BEFORE start().
        session.onLocalAnswer = { sdp in
            collector.storeAnswer(sdp)
            log("[answer] local answer ready sdpBytes=\(sdp.utf8.count)")
        }
        session.onLocalICECandidate = { payload in
            guard let candidate = payload.candidate, !candidate.isEmpty else { return }
            collector.appendCandidate(
                SignalingCandidate(
                    candidate: candidate,
                    sdpMid: payload.sdpMid,
                    sdpMLineIndex: payload.sdpMLineIndex,
                    usernameFragment: nil // WebRTCSession Payload does not carry ufrag; it is embedded in the candidate line + SDP
                )
            )
        }
        session.onReady = {
            collector.markDataChannelOpen()
            log("[answer] DataChannel open")
        }
        session.onData = { data in
            guard let frame = try? SBF1Frame.decode(data) else {
                log("[answer] recv non-SBF1 bytes=\(data.count) (ignored)")
                return
            }
            log("[answer] recv channel=\(frame.channel) seq=\(frame.sequence) len=\(frame.payload.count) eom=\(frame.flags.contains(.endOfMessage))")

            let assembled = reassembler.accumulate(frame)
            if let assembled {
                log("[answer] reassembled channel=\(frame.channel) bytes=\(assembled.count)")
            }

            // Echo the raw frame back verbatim.
            do {
                try session.send(SBF1Frame.encode(frame))
            } catch {
                log("[answer] echo failed channel=\(frame.channel) seq=\(frame.sequence) error=\(error.localizedDescription)")
            }
        }
        session.onDisconnected = { reason in
            log("[answer] disconnected reason=\(reason)")
        }
        session.onTrace = { line in
            log("[answer] trace \(line)")
        }

        // 4) start() must run BEFORE setRemoteOffer (setRemoteOffer needs the
        //    PeerConnection, which start() creates). The answerer's createAnswer()
        //    fires internally once the remote offer is applied.
        do {
            try session.start()
        } catch {
            log("[answer] FATAL session.start() failed: \(error.localizedDescription)")
            exit(1)
        }
        log("[answer] session started role=answerer")

        session.setRemoteOffer(offer.sdp)
        for candidate in offer.candidates {
            session.addRemoteICECandidate(
                candidate: candidate.candidate,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: candidate.sdpMLineIndex
            )
        }
        log("[answer] applied remote offer + \(offer.candidates.count) remote candidates")

        // 5) Wait until the answer SDP exists AND at least one local candidate is
        //    gathered (poll up to ~10s; loopback host candidates appear fast).
        let gatherDeadline = Date().addingTimeInterval(10)
        while Date() < gatherDeadline {
            let snap = collector.snapshot
            if snap.answer != nil, !snap.candidates.isEmpty {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard let answerSDP = collector.answerSDP else {
            log("[answer] FATAL no local answer SDP was produced within timeout")
            exit(1)
        }
        let gatheredCandidates = collector.candidates
        if gatheredCandidates.isEmpty {
            log("[answer] WARNING wrote answer with 0 local candidates (host candidate gather may still be in flight)")
        }

        // 6) Write answer.json in the helper schema (atomic temp + rename).
        let answer = SignalingDescription(
            type: "answer",
            sdp: answerSDP,
            candidates: gatheredCandidates
        )
        do {
            try writeJSONAtomic(answer, to: answerOutPath)
            log("[answer] wrote answer.json sdpBytes=\(answerSDP.utf8.count) localCandidates=\(gatheredCandidates.count) path=\(answerOutPath)")
        } catch {
            log("[answer] FATAL failed to write answer-out: \(error.localizedDescription)")
            exit(1)
        }

        // 7) Hold open, logging frames as they arrive/echo, then exit cleanly.
        log("[answer] holding for \(holdSeconds)s, echoing inbound SBF1 frames")
        let holdDeadline = Date().addingTimeInterval(TimeInterval(holdSeconds))
        while Date() < holdDeadline {
            try? await Task.sleep(for: .milliseconds(250))
        }

        session.close()
        log("[answer] hold complete; session closed; exiting 0")
        exit(0)
    }
}
