// SPDX-License-Identifier: MIT
// SkyBridge Compass - Traffic Padding Sensitivity Bench Tests
//
// Sensitivity Study (TDSC): Vary SBP2 bucket cap (64KiB / 128KiB / 256KiB)
// and quantify overhead–privacy tradeoff for representative workloads.
//
// Output:
//   Artifacts/traffic_padding_sensitivity_<date>.csv
//

import XCTest
import Foundation
import CryptoKit
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class TrafficPaddingSensitivityBenchTests: XCTestCase {
    private var shouldRun: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_RUN_PADDING_SENS"] == "1"
    }

    private var iterations: Int {
        Int(ProcessInfo.processInfo.environment["SKYBRIDGE_PADDING_SENS_ITERATIONS"] ?? "") ?? 80
    }

    private var artifactDate: String {
        ArtifactDate.current()
    }

    func testTrafficPaddingSensitivityStudy() async throws {
        try XCTSkipUnless(shouldRun, "Set SKYBRIDGE_RUN_PADDING_SENS=1 to run SBP2 cap sensitivity study")
        try XCTSkipUnless(iterations > 0, "SKYBRIDGE_PADDING_SENS_ITERATIONS must be > 0")

        let ud = UserDefaults.standard
        let group = UserDefaults(suiteName: "group.com.skybridge.compass")

        // Ensure padding + stats are enabled for the test process.
        ud.set(true, forKey: "sb_handshake_padding_enabled")
        ud.set(false, forKey: "sb_handshake_padding_debug_log")
        ud.set(true, forKey: "sb_traffic_padding_enabled")
        ud.set(false, forKey: "sb_traffic_padding_debug_log")
        ud.set(true, forKey: "sb_traffic_padding_stats_enabled")
        ud.set(false, forKey: "sb_traffic_padding_stats_autoflush")

        group?.set(false, forKey: "sb_handshake_padding_debug_log")
        group?.set(false, forKey: "sb_traffic_padding_debug_log")
        group?.set(true, forKey: "sb_traffic_padding_enabled")
        group?.set(true, forKey: "sb_traffic_padding_stats_enabled")
        group?.set(false, forKey: "sb_traffic_padding_stats_autoflush")

        let caps: [Int] = [65536, 131072, 262144]

        // Prepare one handshake + keys per cap run (to keep work independent and avoid state bleed).
        // Use deterministic workload seed per cap for fair comparison.
        let outputURL = URL(fileURLWithPath: "Artifacts")
            .appendingPathComponent("traffic_padding_sensitivity_\(artifactDate).csv")
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Overwrite each time for determinism.
        var lines: [String] = []
        lines.append("artifact_date,cap_bytes,label,wraps,unwraps,raw_bytes,padded_bytes,overhead_ratio,over_cap_events,over_cap_rate,unique_buckets,entropy_bits,top_bucket")

        for cap in caps {
            ud.set(cap, forKey: "sb_traffic_padding_bucket_cap_bytes")
            group?.set(cap, forKey: "sb_traffic_padding_bucket_cap_bytes")

            await TrafficPaddingStats.shared.reset()

            let (initiatorKeys, responderKeys, initiatorTx, responderTx, peer) = try await performEndToEndHandshake()

            var rng = XorShift64Star(seed: 0xC0FFEE_20260118 ^ UInt64(cap))
            let encoder = JSONEncoder()
            let controlPayloads: [(label: String, data: Data)] = [
                ("CP/heartbeat", try encoder.encode(P2PMessage.heartbeat)),
                ("CP/systemCommand", try encoder.encode(P2PMessage.systemCommand(SystemCommand(type: .screenshot, parameters: ["quality": "0.8", "format": "png"])))),
                ("CP/fileTransferRequest", try encoder.encode(P2PMessage.fileTransferRequest(
                    FileTransferRequest(
                        id: "bench-transfer",
                        fileName: "report.pdf",
                        fileSize: 12_345_678,
                        senderId: "bench-sender",
                        compressionEnabled: true,
                        encryptionEnabled: true,
                        metadata: ["mime": "application/pdf", "sha256": String(repeating: "a", count: 64)]
                    )
                ))),
            ]
            let binarySizes = [
                ("DP/32B", 32),
                ("DP/300B", 300),
                ("DP/900B", 900),
                ("DP/1400B", 1400),
                ("DP/4KiB", 4096),
                ("DP/16KiB", 16 * 1024),
            ]

            // Track "cap coverage": how often a label's framed payload exceeds the cap.
            // We define "over cap" as (payloadBytes + SBP2 headerBytes) > capBytes.
            var capCounters: [String: (wraps: Int, overCap: Int)] = [:]

            for _ in 0..<iterations {
                try await sendWorkloadBurst(
                    directionLabel: "i2r",
                    sendKey: SymmetricKey(data: initiatorKeys.sendKey),
                    recvKey: SymmetricKey(data: responderKeys.receiveKey),
                    sessionId: initiatorKeys.sessionId,
                    controlPayloads: controlPayloads,
                    binarySizes: binarySizes,
                    capBytes: cap,
                    capCounters: &capCounters,
                    from: initiatorTx,
                    peer: peer,
                    rng: &rng
                )
                try await sendWorkloadBurst(
                    directionLabel: "r2i",
                    sendKey: SymmetricKey(data: responderKeys.sendKey),
                    recvKey: SymmetricKey(data: initiatorKeys.receiveKey),
                    sessionId: initiatorKeys.sessionId,
                    controlPayloads: controlPayloads,
                    binarySizes: binarySizes,
                    capBytes: cap,
                    capCounters: &capCounters,
                    from: responderTx,
                    peer: peer,
                    rng: &rng
                )
            }

            let snapshot = await TrafficPaddingStats.shared.snapshot()
            for key in wantedLabels() {
                guard let st = snapshot[key] else { continue }
                let ratio = (st.rawBytes > 0) ? (Double(st.paddedBytes) / Double(st.rawBytes)) : 0.0
                let topBucket = topBucketSummary(st.bucketCounts)
                let uniqueBuckets = st.bucketCounts.count
                let entropy = entropyBits(st.bucketCounts)
                let c = capCounters[key] ?? (wraps: Int(st.wraps), overCap: 0)
                let wrapCount = max(0, c.wraps)
                let overCap = max(0, c.overCap)
                let overCapRate = (wrapCount > 0) ? (Double(overCap) / Double(wrapCount)) : 0.0
                lines.append([
                    artifactDate,
                    "\(cap)",
                    csvEscape(key),
                    "\(st.wraps)",
                    "\(st.unwraps)",
                    "\(st.rawBytes)",
                    "\(st.paddedBytes)",
                    String(format: "%.4f", ratio),
                    "\(overCap)",
                    String(format: "%.4f", overCapRate),
                    "\(uniqueBuckets)",
                    String(format: "%.3f", entropy),
                    csvEscape(topBucket)
                ].joined(separator: ","))
            }
        }

        try (lines.joined(separator: "\n") + "\n").write(to: outputURL, atomically: true, encoding: .utf8)
        print("🧪 TrafficPaddingSensitivity CSV: \(outputURL.path)")
    }

    private func wantedLabels() -> [String] {
        [
            "HS/MessageA", "HS/MessageB", "HS/Finished",
            "CP/heartbeat", "CP/systemCommand", "CP/fileTransferRequest",
            "DP/32B", "DP/300B", "DP/900B", "DP/1400B", "DP/4KiB", "DP/16KiB",
            "DP/rdpMix", "DP/fileMix"
        ]
    }

    private func topBucketSummary(_ m: [Int: UInt64]) -> String {
        guard !m.isEmpty else { return "-" }
        let total = m.values.reduce(0, +)
        guard total > 0 else { return "-" }
        let (size, count) = m.max(by: { $0.value < $1.value })!
        let pct = 100.0 * Double(count) / Double(total)
        return "\(size)B (\(Int(pct.rounded()))%)"
    }

    private func entropyBits(_ m: [Int: UInt64]) -> Double {
        guard !m.isEmpty else { return 0.0 }
        let total = m.values.reduce(0, +)
        guard total > 0 else { return 0.0 }
        var h: Double = 0.0
        for c in m.values {
            if c == 0 { continue }
            let p = Double(c) / Double(total)
            h -= p * log2(p)
        }
        return h
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }

    // MARK: - Harness (minimal subset; mirrors TrafficPaddingBenchTests)

    private actor LoopbackDiscoveryTransport: DiscoveryTransport {
        private var onSend: (@Sendable (PeerIdentifier, Data) async throws -> Void)?
        func setOnSend(_ handler: @escaping @Sendable (PeerIdentifier, Data) async throws -> Void) { onSend = handler }
        func send(to peer: PeerIdentifier, data: Data) async throws { try await onSend?(peer, data) }
    }

    private func performEndToEndHandshake() async throws -> (SessionKeys, SessionKeys, LoopbackDiscoveryTransport, LoopbackDiscoveryTransport, PeerIdentifier) {
        let initiatorTx = LoopbackDiscoveryTransport()
        let responderTx = LoopbackDiscoveryTransport()

        let provider = ClassicCryptoProvider()
        let offeredSuites: [CryptoSuite] = [.x25519Ed25519]
        let peer = PeerIdentifier(deviceId: "bench-peer")

        let protocolSignatureProvider = ClassicSignatureProvider()
        let initiatorKeyPair = try await provider.generateKeyPair(for: .signing)
        let responderKeyPair = try await provider.generateKeyPair(for: .signing)

        let initiatorIdentityPublicKey = encodeIdentityPublicKey(initiatorKeyPair.publicKey.bytes, algorithm: .ed25519)
        let responderIdentityPublicKey = encodeIdentityPublicKey(responderKeyPair.publicKey.bytes, algorithm: .ed25519)

        let trustProviderInitiator: any HandshakeTrustProvider = StaticTrustProvider(deviceId: peer.deviceId, fingerprint: nil)
        let trustProviderResponder: any HandshakeTrustProvider = StaticTrustProvider(deviceId: peer.deviceId, fingerprint: nil)

        let initiatorDriver = try HandshakeDriver(
            transport: initiatorTx,
            cryptoProvider: provider,
            protocolSignatureProvider: protocolSignatureProvider,
            protocolSigningKeyHandle: .softwareKey(initiatorKeyPair.privateKey.bytes),
            sigAAlgorithm: .ed25519,
            identityPublicKey: initiatorIdentityPublicKey,
            offeredSuites: offeredSuites,
            policy: .default,
            cryptoPolicy: .default,
            timeout: .seconds(10),
            trustProvider: trustProviderInitiator
        )

        let responderDriver = try HandshakeDriver(
            transport: responderTx,
            cryptoProvider: provider,
            protocolSignatureProvider: protocolSignatureProvider,
            protocolSigningKeyHandle: .softwareKey(responderKeyPair.privateKey.bytes),
            sigAAlgorithm: .ed25519,
            identityPublicKey: responderIdentityPublicKey,
            offeredSuites: offeredSuites,
            policy: .default,
            cryptoPolicy: .default,
            timeout: .seconds(10),
            trustProvider: trustProviderResponder
        )

        await initiatorTx.setOnSend { peer, data in
            let unwrapped = TrafficPadding.unwrapIfNeeded(data, label: "rx")
            await responderDriver.handleMessage(unwrapped, from: peer)
        }
        await responderTx.setOnSend { peer, data in
            let unwrapped = TrafficPadding.unwrapIfNeeded(data, label: "rx")
            await initiatorDriver.handleMessage(unwrapped, from: peer)
        }

        let initiatorKeys = try await Task { try await initiatorDriver.initiateHandshake(with: peer) }.value
        let responderKeys = try await waitForEstablished(responderDriver)
        return (initiatorKeys, responderKeys, initiatorTx, responderTx, peer)
    }

    private func waitForEstablished(_ driver: HandshakeDriver) async throws -> SessionKeys {
        for _ in 0..<2000 {
            let st = await driver.getCurrentState()
            if case .established(let keys) = st { return keys }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw XCTSkip("Responder did not reach established state")
    }

    private func sendWorkloadBurst(
        directionLabel: String,
        sendKey: SymmetricKey,
        recvKey: SymmetricKey,
        sessionId: String,
        controlPayloads: [(label: String, data: Data)],
        binarySizes: [(label: String, size: Int)],
        capBytes: Int,
        capCounters: inout [String: (wraps: Int, overCap: Int)],
        from transport: LoopbackDiscoveryTransport,
        peer: PeerIdentifier,
        rng: inout XorShift64Star
    ) async throws {
        let aad = Data(("dp|\(sessionId)|\(directionLabel)").utf8)

        for _ in 0..<6 {
            let (label, plaintext) = controlPayloads[Int(rng.next() % UInt64(controlPayloads.count))]
            let frame = try encryptFrame(plaintext: plaintext, key: sendKey, aad: aad)
            try await sendViaTransport(frame, label: label, capBytes: capBytes, capCounters: &capCounters, from: transport, peer: peer)
            _ = try decryptFrame(data: TrafficPadding.unwrapIfNeeded(TrafficPadding.wrapIfEnabled(frame, label: label), label: "rx"), key: recvKey, aad: aad)
        }

        let medium = binarySizes.filter { $0.size <= 4096 }
        for _ in 0..<6 {
            let (label, sz) = medium[Int(rng.next() % UInt64(medium.count))]
            let plaintext = rng.bytes(count: sz)
            let frame = try encryptFrame(plaintext: plaintext, key: sendKey, aad: aad)
            try await sendViaTransport(frame, label: label, capBytes: capBytes, capCounters: &capCounters, from: transport, peer: peer)
            let decoded = try decryptFrame(data: TrafficPadding.unwrapIfNeeded(TrafficPadding.wrapIfEnabled(frame, label: label), label: "rx"), key: recvKey, aad: aad)
            XCTAssertEqual(decoded.count, plaintext.count)
        }

        // Fixed mid-size (16KiB) to keep S8 table complete and comparable.
        do {
            let label = "DP/16KiB"
            let plaintext = rng.bytes(count: 16 * 1024)
            let frame = try encryptFrame(plaintext: plaintext, key: sendKey, aad: aad)
            try await sendViaTransport(frame, label: label, capBytes: capBytes, capCounters: &capCounters, from: transport, peer: peer)
            let decoded = try decryptFrame(
                data: TrafficPadding.unwrapIfNeeded(TrafficPadding.wrapIfEnabled(frame, label: label), label: "rx"),
                key: recvKey,
                aad: aad
            )
            XCTAssertEqual(decoded.count, plaintext.count)
        }

        // Large, variable-size mixes above 64KiB:
        // - rdpMix: remote-desktop-like frames (bursty, medium-large)
        // - fileMix: file-chunk-like payloads (larger, more uniform)
        //
        // These are the primary targets of the bucket-cap tradeoff study.
        let rdpSizes = [60 * 1024, 72 * 1024, 96 * 1024, 120 * 1024, 160 * 1024, 200 * 1024]
        for _ in 0..<2 {
            let sz = rdpSizes[Int(rng.next() % UInt64(rdpSizes.count))]
            let label = "DP/rdpMix"
            let plaintext = rng.bytes(count: sz)
            let frame = try encryptFrame(plaintext: plaintext, key: sendKey, aad: aad)
            try await sendViaTransport(frame, label: label, capBytes: capBytes, capCounters: &capCounters, from: transport, peer: peer)
            let decoded = try decryptFrame(
                data: TrafficPadding.unwrapIfNeeded(TrafficPadding.wrapIfEnabled(frame, label: label), label: "rx"),
                key: recvKey,
                aad: aad
            )
            XCTAssertEqual(decoded.count, plaintext.count)
        }

        let fileSizes = [64 * 1024, 96 * 1024, 128 * 1024, 160 * 1024, 192 * 1024, 224 * 1024]
        for _ in 0..<2 {
            let sz = fileSizes[Int(rng.next() % UInt64(fileSizes.count))]
            let label = "DP/fileMix"
            let plaintext = rng.bytes(count: sz)
            let frame = try encryptFrame(plaintext: plaintext, key: sendKey, aad: aad)
            try await sendViaTransport(frame, label: label, capBytes: capBytes, capCounters: &capCounters, from: transport, peer: peer)
            let decoded = try decryptFrame(
                data: TrafficPadding.unwrapIfNeeded(TrafficPadding.wrapIfEnabled(frame, label: label), label: "rx"),
                key: recvKey,
                aad: aad
            )
            XCTAssertEqual(decoded.count, plaintext.count)
        }
    }

    private func sendViaTransport(
        _ payload: Data,
        label: String,
        capBytes: Int,
        capCounters: inout [String: (wraps: Int, overCap: Int)],
        from transport: LoopbackDiscoveryTransport,
        peer: PeerIdentifier
    ) async throws {
        // SBP2 header is magic(4) + u32(actualLen)(4)
        let sbp2HeaderLen = 8
        var entry = capCounters[label] ?? (wraps: 0, overCap: 0)
        entry.wraps += 1
        if payload.count + sbp2HeaderLen > capBytes {
            entry.overCap += 1
        }
        capCounters[label] = entry

        let wrapped = TrafficPadding.wrapIfEnabled(payload, label: label)
        try await transport.send(to: peer, data: wrapped)
    }

    // DP1 frame:
    // [magic:4]["DP1\0"] [nonce:12] [tag:16] [cipherLen:u32BE] [ciphertext:var]
    private static let dpMagic: [UInt8] = [0x44, 0x50, 0x31, 0x00]

    private func encryptFrame(plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        var out = Data()
        out.append(contentsOf: Self.dpMagic)
        out.append(Data(nonce))
        out.append(sealed.tag)
        var lenBE = UInt32(sealed.ciphertext.count).bigEndian
        out.append(Data(bytes: &lenBE, count: 4))
        out.append(sealed.ciphertext)
        return out
    }

    private func decryptFrame(data: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let minLen = 4 + 12 + 16 + 4
        guard data.count >= minLen else { throw NSError(domain: "DP1", code: 1) }
        guard data.prefix(4).elementsEqual(Self.dpMagic) else { throw NSError(domain: "DP1", code: 2) }
        let nonceStart = 4
        let tagStart = nonceStart + 12
        let lenStart = tagStart + 16
        let cipherStart = lenStart + 4
        let nonceData = data.subdata(in: nonceStart..<tagStart)
        let tagData = data.subdata(in: tagStart..<lenStart)
        let len = data.subdata(in: lenStart..<cipherStart).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let cipherLen = Int(len)
        guard data.count >= cipherStart + cipherLen else { throw NSError(domain: "DP1", code: 3) }
        let cipher = data.subdata(in: cipherStart..<(cipherStart + cipherLen))
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipher, tag: tagData)
        return try AES.GCM.open(sealed, using: key, authenticating: aad)
    }
}

// MARK: - Deterministic RNG

private struct XorShift64Star {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed != 0 ? seed : 0xDEADBEEF }
    mutating func next() -> UInt64 {
        var x = state
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        state = x
        return x &* 2685821657736338717
    }
    mutating func bytes(count: Int) -> Data {
        if count <= 0 { return Data() }
        var out = Data(count: count)
        out.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            var i = 0
            while i < count {
                let v = next()
                let chunk = withUnsafeBytes(of: v.littleEndian) { Data($0) }
                let remaining = count - i
                let n = min(8, remaining)
                _ = chunk.prefix(n).withUnsafeBytes { src in
                    memcpy(base.advanced(by: i), src.baseAddress!, n)
                }
                i += n
            }
        }
        return out
    }
}


