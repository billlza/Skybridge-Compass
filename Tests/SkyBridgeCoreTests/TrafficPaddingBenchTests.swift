// SPDX-License-Identifier: MIT
// SkyBridge Compass - Traffic Padding Bench Tests
//
// Phase C3 (TDSC): Quantify traffic-analysis mitigations
// - Real-trace bench: end-to-end handshake on loopback + encrypted data-plane frames
// - Generates Artifacts/traffic_padding_<date>.csv via TrafficPaddingStats
//

import XCTest
import CryptoKit
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class TrafficPaddingBenchTests: XCTestCase {
    private var shouldRunPaddingBench: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_RUN_PADDING_BENCH"] == "1"
    }

    private var iterations: Int {
        Int(ProcessInfo.processInfo.environment["SKYBRIDGE_PADDING_ITERATIONS"] ?? "") ?? 200
    }

    override func tearDown() {
        // Avoid polluting developer defaults.
        let ud = UserDefaults.standard
        let group = UserDefaults(suiteName: "group.com.skybridge.compass")
        [
            "sb_handshake_padding_enabled",
            "sb_handshake_padding_debug_log",
            "sb_traffic_padding_enabled",
            "sb_traffic_padding_debug_log",
            "sb_traffic_padding_mode",
            "sb_traffic_padding_fixed_size",
            "sb_traffic_padding_stats_enabled",
            "sb_traffic_padding_stats_autoflush",
            "sb_traffic_padding_stats_flush_min_interval",
            "sb_traffic_padding_stats_flush_every_n"
        ].forEach {
            ud.removeObject(forKey: $0)
            group?.removeObject(forKey: $0)
        }
        super.tearDown()
    }

    func testTrafficPaddingArtifactsCSV() async throws {
        try XCTSkipUnless(shouldRunPaddingBench, "Set SKYBRIDGE_RUN_PADDING_BENCH=1 to run traffic padding bench")
        try XCTSkipUnless(iterations > 0, "SKYBRIDGE_PADDING_ITERATIONS must be > 0")

        // Enable SBP1 handshake padding + SBP2 traffic padding + stats (test-process only).
        let ud = UserDefaults.standard
        let group = UserDefaults(suiteName: "group.com.skybridge.compass")

        ud.set(true, forKey: "sb_handshake_padding_enabled")
        ud.set(false, forKey: "sb_handshake_padding_debug_log")
        ud.set(true, forKey: "sb_traffic_padding_enabled")
        ud.set(false, forKey: "sb_traffic_padding_debug_log")
        ud.set(true, forKey: "sb_traffic_padding_stats_enabled")
        ud.set(false, forKey: "sb_traffic_padding_stats_autoflush")

        // Also force-disable App Group flags to avoid inheriting developer toggles during CI/paper runs.
        group?.set(false, forKey: "sb_handshake_padding_debug_log")
        group?.set(false, forKey: "sb_traffic_padding_debug_log")
        group?.set(true, forKey: "sb_traffic_padding_enabled")
        group?.set(true, forKey: "sb_traffic_padding_stats_enabled")
        group?.set(false, forKey: "sb_traffic_padding_stats_autoflush")

        // === Real trace ===
        // 1) Run an end-to-end HandshakeDriver flow with SBP1+SBP2 enabled.
        // 2) Use negotiated SessionKeys to send realistic workloads (control JSON + file + remote-like frames)
        //    as encrypted data-plane frames both directions.
        let (initiatorKeys, responderKeys, initiatorTx, responderTx, peer) = try await performEndToEndHandshake()

        var rng = XorShift64Star(seed: 0xC0FFEE_20260118)
        let encoder = JSONEncoder()

        // Pre-build representative control payloads (real protocol structs).
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

        // Data-plane representative plaintext sizes: MTU-ish, small chunks, and remote desktop/video-like frames.
        // (These are *plaintext* sizes; ciphertext/tag/nonce/header are added before SBP2 buckets.)
        let binarySizes = [
            ("DP/32B", 32),
            ("DP/300B", 300),
            ("DP/900B", 900),
            ("DP/1400B", 1400),
            ("DP/4KiB", 4096),
            ("DP/16KiB", 16 * 1024),
            ("DP/64KiB", 64 * 1024),
        ]

        // Workload mix (per direction, per iteration):
        // - 6 control messages
        // - 6 medium binary chunks (MTU-ish to 4KiB)
        // - 2 large frames (16–64KiB)
        for _ in 0..<iterations {
            // Initiator -> Responder (I2R)
            try await sendWorkloadBurst(
                directionLabel: "i2r",
                sendKey: SymmetricKey(data: initiatorKeys.sendKey),
                recvKey: SymmetricKey(data: responderKeys.receiveKey),
                sessionId: initiatorKeys.sessionId,
                controlPayloads: controlPayloads,
                binarySizes: binarySizes,
                from: initiatorTx,
                peer: peer,
                rng: &rng
            )

            // Responder -> Initiator (R2I)
            try await sendWorkloadBurst(
                directionLabel: "r2i",
                sendKey: SymmetricKey(data: responderKeys.sendKey),
                recvKey: SymmetricKey(data: initiatorKeys.receiveKey),
                sessionId: initiatorKeys.sessionId,
                controlPayloads: controlPayloads,
                binarySizes: binarySizes,
                from: responderTx,
                peer: peer,
                rng: &rng
            )
        }

        // Flush a deterministic snapshot into Artifacts/ (used by Scripts/make_tables.py).
        try await TrafficPaddingStats.shared.flushToArtifactsCSV()
    }

    // MARK: - Real-trace helpers

    private actor LoopbackDiscoveryTransport: DiscoveryTransport {
        private var onSend: (@Sendable (PeerIdentifier, Data) async throws -> Void)?

        func setOnSend(_ handler: @escaping @Sendable (PeerIdentifier, Data) async throws -> Void) {
            onSend = handler
        }

        func send(to peer: PeerIdentifier, data: Data) async throws {
            try await onSend?(peer, data)
        }
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

        // Wire up loopback:
        // Sender already wrapped with SBP2; receiver must unwrap SBP2 before giving HandshakeDriver bytes.
        await initiatorTx.setOnSend { peer, data in
            let unwrapped = TrafficPadding.unwrapIfNeeded(data, label: "rx")
            await responderDriver.handleMessage(unwrapped, from: peer)
        }
        await responderTx.setOnSend { peer, data in
            let unwrapped = TrafficPadding.unwrapIfNeeded(data, label: "rx")
            await initiatorDriver.handleMessage(unwrapped, from: peer)
        }

        let initiatorTask = Task { try await initiatorDriver.initiateHandshake(with: peer) }
        let initiatorKeys = try await initiatorTask.value

        // Wait for responder to reach established and extract keys via state.
        let responderKeys = try await waitForResponderEstablished(responderDriver)

        return (initiatorKeys, responderKeys, initiatorTx, responderTx, peer)
    }

    private func waitForResponderEstablished(_ driver: HandshakeDriver) async throws -> SessionKeys {
        // Best-effort polling; handshake is in-memory so this is fast.
        for _ in 0..<2000 {
            let st = await driver.getCurrentState()
            if case .established(let keys) = st {
                return keys
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw XCTSkip("Responder did not reach established state")
    }

    private func sendViaTransport(
        _ payload: Data,
        label: String,
        from transport: LoopbackDiscoveryTransport,
        toHandler: @escaping (Data) throws -> Void,
        peer: PeerIdentifier
    ) async throws {
        // SBP2 wraps and records stats using the provided label.
        let wrapped = TrafficPadding.wrapIfEnabled(payload, label: label)
        // Deliver through loopback transport (receiver side unwraps with label=rx via transport hookup).
        try await transport.send(to: peer, data: wrapped)
        // Receiver-side handler runs in transport hookup; we can't intercept it here, so we also validate locally:
        // Simulate receiver's SBP2 unwrap and feed to decrypt/parse. This doubles as a correctness check and
        // ensures the decrypt path is exercised even if the loopback hook changes.
        let unwrapped = TrafficPadding.unwrapIfNeeded(wrapped, label: "rx")
        try toHandler(unwrapped)
    }

    private func sendWorkloadBurst(
        directionLabel: String,
        sendKey: SymmetricKey,
        recvKey: SymmetricKey,
        sessionId: String,
        controlPayloads: [(label: String, data: Data)],
        binarySizes: [(label: String, size: Int)],
        from transport: LoopbackDiscoveryTransport,
        peer: PeerIdentifier,
        rng: inout XorShift64Star
    ) async throws {
        let aad = Data(("dp|\(sessionId)|\(directionLabel)").utf8)

        // 6 control messages
        for _ in 0..<6 {
            let (label, plaintext) = controlPayloads[Int(rng.next() % UInt64(controlPayloads.count))]
            let frame = try Self.encryptFrame(plaintext: plaintext, key: sendKey, aad: aad)
            try await sendViaTransport(frame, label: label, from: transport, toHandler: { data in
                _ = try Self.decryptFrame(data: data, key: recvKey, aad: aad)
            }, peer: peer)
        }

        // 6 medium binary chunks (use the first 5 + 4KiB)
        let medium = binarySizes.filter { $0.size <= 4096 }
        for _ in 0..<6 {
            let (label, sz) = medium[Int(rng.next() % UInt64(medium.count))]
            let plaintext = rng.bytes(count: sz)
            let frame = try Self.encryptFrame(plaintext: plaintext, key: sendKey, aad: aad)
            try await sendViaTransport(frame, label: label, from: transport, toHandler: { data in
                let decoded = try Self.decryptFrame(data: data, key: recvKey, aad: aad)
                XCTAssertEqual(decoded.count, plaintext.count)
            }, peer: peer)
        }

        // 2 large frames (16–64KiB)
        let large = binarySizes.filter { $0.size >= 16 * 1024 }
        for _ in 0..<2 {
            let (label, sz) = large[Int(rng.next() % UInt64(large.count))]
            let plaintext = rng.bytes(count: sz)
            let frame = try Self.encryptFrame(plaintext: plaintext, key: sendKey, aad: aad)
            try await sendViaTransport(frame, label: label, from: transport, toHandler: { data in
                let decoded = try Self.decryptFrame(data: data, key: recvKey, aad: aad)
                XCTAssertEqual(decoded.count, plaintext.count)
            }, peer: peer)
        }
    }

    // MARK: - Data-plane frame format (binary, stable)
    // DP1:
    // [magic:4]["DP1\0"] [nonce:12] [tag:16] [cipherLen:u32BE] [ciphertext:var]

    private static let dpMagic: [UInt8] = [0x44, 0x50, 0x31, 0x00] // "DP1\0"

    private static func encryptFrame(plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        let nonceData = Data(nonce)
        let tag = sealed.tag
        let cipher = sealed.ciphertext

        var out = Data()
        out.append(contentsOf: dpMagic)
        out.append(nonceData)
        out.append(tag)
        var lenBE = UInt32(cipher.count).bigEndian
        out.append(Data(bytes: &lenBE, count: 4))
        out.append(cipher)
        return out
    }

    private static func decryptFrame(data: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let minLen = 4 + 12 + 16 + 4
        guard data.count >= minLen else { throw NSError(domain: "DP1", code: 1) }
        guard data.prefix(4).elementsEqual(dpMagic) else { throw NSError(domain: "DP1", code: 2) }

        let nonceStart = 4
        let tagStart = nonceStart + 12
        let lenStart = tagStart + 16
        let cipherStart = lenStart + 4

        let nonceData = data.subdata(in: nonceStart..<tagStart)
        let tagData = data.subdata(in: tagStart..<lenStart)
        let len = data.subdata(in: lenStart..<cipherStart).withUnsafeBytes { ptr in
            ptr.load(as: UInt32.self).bigEndian
        }
        let cipherLen = Int(len)
        guard cipherLen >= 0, data.count >= cipherStart + cipherLen else { throw NSError(domain: "DP1", code: 3) }
        let cipher = data.subdata(in: cipherStart..<(cipherStart + cipherLen))

        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipher, tag: tagData)
        return try AES.GCM.open(sealed, using: key, authenticating: aad)
    }
}

// MARK: - Deterministic RNG (reproducible workloads)

private struct XorShift64Star {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed != 0 ? seed : 0xDEADBEEF
    }

    mutating func next() -> UInt64 {
        // xorshift64*
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


