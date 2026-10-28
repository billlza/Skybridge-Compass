#if DEBUG || SKYBRIDGE_TESTING
import CryptoKit
import Foundation
import SkyBridgeAppleTransport
import SkyBridgeProtocolCore

/// An explicit development action on the real app runtime. This does not create
/// account evidence, connect a peer, approve playback, or change crypto policy.
@available(iOS 17.0, *)
@MainActor
final class LocalAudioFileSmokeHarness {
    static let shared = LocalAudioFileSmokeHarness()
    private var didStart = false
    // Keep owners alive when native cleanup is unconfirmed.
    private var source: IOSPreparedAudioFile?
    private var sender: IOSOriginalFileSendSession?
    private var connection: IOSAudioFileConnection?
    private var bluetoothSender: IOSOpusFileSendSession?

    struct Configuration {
        let runID: UUID
        let deviceID: String
        let fingerprint: String
        let bluetoothSeconds: Int
        let bluetoothBitrate: UInt32

        init(environment: [String: String]) throws {
            guard let run = environment["SKYBRIDGE_AUDIO_SMOKE_RUN_ID"],
                  let runID = UUID(uuidString: run), runID.uuidString.lowercased() == run,
                  runID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
                  let device = environment["SKYBRIDGE_AUDIO_SMOKE_TARGET_DEVICE_ID"],
                  let deviceID = UUID(uuidString: device), deviceID.uuidString == device,
                  let fingerprint = environment["SKYBRIDGE_AUDIO_SMOKE_TARGET_FINGERPRINT"],
                  fingerprint.utf8.count == 64,
                  fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw Failure.invalidConfiguration
            }
            self.runID = runID; self.deviceID = deviceID.uuidString; self.fingerprint = fingerprint
            if let raw = environment["SKYBRIDGE_AUDIO_SMOKE_BLUETOOTH_SECONDS"] {
                guard let seconds = Int(raw), [1, 60, 600].contains(seconds), String(seconds) == raw else {
                    throw Failure.invalidConfiguration
                }
                bluetoothSeconds = seconds
            } else { bluetoothSeconds = 1 }
            if let raw = environment["SKYBRIDGE_AUDIO_SMOKE_BLUETOOTH_BITRATE"] {
                guard let bitrate = UInt32(raw), [128_000, 192_000, 256_000].contains(bitrate), String(bitrate) == raw else {
                    throw Failure.invalidConfiguration
                }
                bluetoothBitrate = bitrate
            } else { bluetoothBitrate = IOSOpusFileSource.defaultBluetoothBitrate }
        }

        var basename: String { "usb-audio-\(runID.uuidString.lowercased())" }
    }

    enum Failure: Error { case invalidConfiguration, fixtureRuntime, targetUnavailable, wrongTarget, wrongRoute, invalidReceipt }

    func startIfNeeded() async {
        let environment = ProcessInfo.processInfo.environment
        let role = environment["SKYBRIDGE_SMOKE_ROLE"]
        guard role == "ios-usb-original-audio" || role == "ios-audio-availability" ||
              role == "ios-bluetooth-file-audio", !didStart else { return }
        didStart = true
        defer { SkyBridgeDiagnosticTrace.flush() }
        let configuration: Configuration
        let reporter: SmokeStatusReporter
        let sampleURL: URL
        do {
            guard !SkyBridgeRuntimeEnvironment.isUITesting,
                  !SkyBridgeRuntimeEnvironment.shouldSkipInteractiveStartup else { throw Failure.fixtureRuntime }
            configuration = try Configuration(environment: environment)
            let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            let basename = role == "ios-bluetooth-file-audio"
                ? "bluetooth-audio-\(configuration.runID.uuidString.lowercased())" : configuration.basename
            reporter = SmokeStatusReporter(statusURL: caches.appendingPathComponent(basename + ".log"))
            try reporter.reset()
            sampleURL = caches.appendingPathComponent(basename + ".wav")
        } catch {
            SkyBridgeLogger.shared.error("USB audio qualification configuration rejected")
            return
        }

        if role == "ios-audio-availability" {
            let availability = IOSAudioCaptureSourceOwner.systemScreenCaptureAvailability
            let backgroundModes = Bundle.main.infoDictionary?["UIBackgroundModes"] as? [String] ?? []
            reporter.append("native_capture_availability state=\(availability.rawValue) backgroundModeDeclared=\(backgroundModes.contains("screen-capture") ? 1 : 0) captureStarted=0 pickerPresented=0")
            return
        }
        if role == "ios-bluetooth-file-audio" {
            await runBluetoothFile(configuration, reporter: reporter, sampleURL: sampleURL)
            return
        }
        reporter.append("boot scope=real_account_and_existing_usb_session run=\(configuration.runID.uuidString.lowercased())")
        let manager = P2PConnectionManager.instance
        var opened: IOSAudioChannel?
        var sampleCreated = false
        do {
            let deadline = ContinuousClock.now + .seconds(90)
            var target: IOSAudioPlaybackTarget?
            var previousReadiness: String?
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                let readiness = manager.audioPlaybackReadinessDiagnostic(for: configuration.deviceID)
                if readiness != previousReadiness {
                    reporter.append("target_readiness " + readiness)
                    previousReadiness = readiness
                }
                if let candidate = manager.audioPlaybackTarget(for: configuration.deviceID, name: "USB audio qualification") {
                    guard candidate.identity.fingerprint == configuration.fingerprint,
                          candidate.identity.deviceID == configuration.deviceID else { throw Failure.wrongTarget }
                    if candidate.sources.contains(.originalFile) { target = candidate; break }
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard target != nil else { throw Failure.targetUnavailable }
            let channel = try manager.openAudioChannel(for: configuration.deviceID,
                requiringRemoteProtocolFingerprint: configuration.fingerprint)
            opened = channel
            guard channel.fileRoute == .usbReturn else { throw Failure.wrongRoute }
            reporter.append("channel_opened route=usb_return peer=\(channel.remoteIdentity.deviceID) fingerprint=\(channel.remoteIdentity.fingerprint)")

            let bytes = Self.sampleWave()
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            try bytes.write(to: sampleURL, options: .withoutOverwriting)
            sampleCreated = true
            let source = try IOSPreparedAudioFile(url: sampleURL)
            self.source = source
            let connection = IOSAudioFileConnection(); self.connection = connection
            var options = IOSOriginalFileSendSession.Options()
            options.acceptanceTimeout = .seconds(90); options.transferTimeout = .seconds(45)
            let sender = IOSOriginalFileSendSession(renewMembership: IOSAudioAccountMembershipProvider.shared.renew(for:continuing:), source: source, channel: channel, connection: connection,
                options: options, transfer: { source, channel, connection, authorize, progress in
                    reporter.append("file_transfer_started route=usb_return")
                    let receipt = try await FileTransferManager.instance.sendPreparedAudioFile(source,
                        channel: channel, connectionOwner: connection, requireEffectAuthorization: authorize,
                        progress: progress)
                    guard receipt.success, receipt.receivedBytes == bytes.count, receipt.fileHash == digest else {
                        throw Failure.invalidReceipt
                    }
                    reporter.append("file_receipt_verified bytes=\(receipt.receivedBytes) sha256=\(digest) transfer=\(receipt.transferId)")
                    return receipt
                })
            self.sender = sender
            reporter.append("source bytes=\(bytes.count) sha256=\(digest) rate=48000 channels=2 encoding=signed24 validBits=24 frames=48000 peak=240_of_8388607")
            let receipt = try await sender.run()
            reporter.append("playback_peer_report frames=\(receipt.sourceFrames) padding=\(receipt.trailingPaddingFrames) rate=\(receipt.format.sampleRate) encoding=\(receipt.format.encoding.rawValue)")
        } catch let failure as IOSOriginalFileSendFailure {
            reporter.append("stopped reason=\(failure.reason) diagnostic=\(AudioPlaybackFailureDiagnostic.label(for: failure.underlying)) cleanupFailures=\(failure.cleanupFailures.count)")
        } catch {
            let diagnostic = (error as? Failure).map { String(describing: $0) }
                ?? AudioPlaybackFailureDiagnostic.label(for: error)
            reporter.append("failed diagnostic=\(diagnostic)")
            opened?.close()
        }

        // Sender.run owns normal cleanup. Pre-sender failure still closes the
        // exact source it created; cleanup failure remains visible and retained.
        if sender == nil, let source {
            do { try await source.close() }
            catch { reporter.append("source_cleanup_failed diagnostic=\(AudioPlaybackFailureDiagnostic.label(for: error))") }
        }
        let sourceClosed = await source?.isClosed ?? true
        let connectionClosed = connection?.isClosed ?? true
        reporter.append("finished sourceClosed=\(sourceClosed ? 1 : 0) fileConnectionClosed=\(connectionClosed ? 1 : 0) cleanupPending=\(sender?.cleanupPending == true ? 1 : 0)")
        if sourceClosed && connectionClosed {
            source = nil; sender = nil; connection = nil
            if sampleCreated {
                do { try FileManager.default.removeItem(at: sampleURL) }
                catch { reporter.append("sample_cleanup_failed diagnostic=\(AudioPlaybackFailureDiagnostic.label(for: error))") }
            }
        }
    }

    /// Bounded real-product qualification. The only synthetic input is a quiet
    /// finite quiet file (at most ten minutes). Registry evidence, pairing, route, radio and receiver
    /// approval/output all use the product implementations without substitutes.
    private func runBluetoothFile(_ configuration: Configuration, reporter: SmokeStatusReporter, sampleURL: URL) async {
        reporter.append("boot scope=real_account_existing_parent_native_bluetooth run=\(configuration.runID.uuidString.lowercased())")
        let manager = P2PConnectionManager.instance
        var opened: IOSAudioChannel?
        var sampleCreated = false
        var observer: Task<Void, Never>?
        do {
            let deadline = ContinuousClock.now + .seconds(90)
            var target: IOSAudioPlaybackTarget?
            var previous: String?
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                let readiness = manager.audioPlaybackReadinessDiagnostic(for: configuration.deviceID)
                if readiness != previous { reporter.append("target_readiness " + readiness); previous = readiness }
                if let candidate = manager.audioPlaybackTarget(for: configuration.deviceID, name: "Bluetooth audio qualification") {
                    guard candidate.identity.deviceID == configuration.deviceID,
                          candidate.identity.fingerprint == configuration.fingerprint else { throw Failure.wrongTarget }
                    if candidate.sources.contains(.bluetoothFile) { target = candidate; break }
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard target != nil else { throw Failure.targetUnavailable }
            let channel = try manager.openAudioChannel(for: configuration.deviceID,
                requiringRemoteProtocolFingerprint: configuration.fingerprint)
            opened = channel
            reporter.append("channel_opened peer=\(channel.remoteIdentity.deviceID) fingerprint=\(channel.remoteIdentity.fingerprint) media=bluetooth_opus")
            // Fixture storage is released before streaming; it is not the sender's packet queue.
            let fixture = try Self.writeBluetoothSampleWave(seconds: configuration.bluetoothSeconds, to: sampleURL)
            sampleCreated = true
            var options = IOSOpusFileSendSession.Options()
            options.recordsTiming = true
            let sender = try IOSOpusFileSendSession(url: sampleURL, channel: channel,
                renewMembership: IOSAudioAccountMembershipProvider.shared.renew(for:continuing:),
                bitrate: configuration.bluetoothBitrate, options: options)
            bluetoothSender = sender
            observer = Task { @MainActor in
                var phase: IOSOpusFileSendSession.Phase?
                var timingAt = ContinuousClock.now
                do {
                    while !Task.isCancelled {
                        if phase != sender.phase {
                            phase = sender.phase
                            reporter.append("sender_phase value=\(sender.phase) sentBytes=\(sender.sentBytes)")
                        }
                        if timingAt.duration(to: .now) >= .seconds(1) {
                            reporter.append("sender_timing " + sender.timingDiagnostic)
                            timingAt = .now
                        }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                } catch is CancellationError { return }
                catch { reporter.append("observer_failed diagnostic=\(AudioPlaybackFailureDiagnostic.label(for: error))") }
            }
            let frames = UInt64(configuration.bluetoothSeconds) * 48_000
            reporter.append("source frames=\(frames) rate=48000 channels=2 encoding=signed24 validBits=24 peak=240_of_8388607 fileBytes=\(fixture.bytes) opusBitrate=\(configuration.bluetoothBitrate) sha256=\(fixture.sha256)")
            let receipt = try await sender.run()
            guard receipt.sourceFrames == frames, receipt.transmittedFormat.channels == 2,
                  receipt.transmittedFormat.sampleRate == 48_000, receipt.transmittedFormat.bitrate == configuration.bluetoothBitrate else {
                throw Failure.invalidReceipt
            }
            reporter.append("playback_peer_report frames=\(receipt.sourceFrames) packets=\(receipt.packetCount) encodedBytes=\(receipt.encodedBytes) padding=\(receipt.trailingPaddingFrames) sha256=\(receipt.sha256.map { String(format: "%02x", $0) }.joined())")
        } catch let failure as IOSOpusFileSendFailure {
            reporter.append("stopped reason=\(failure.reason) diagnostic=\(Self.bluetoothDiagnostic(failure.underlying)) cleanupFailures=\(failure.cleanupFailures.count)")
        } catch {
            let diagnostic = (error as? Failure).map { String(describing: $0) } ?? Self.bluetoothDiagnostic(error)
            reporter.append("failed diagnostic=\(diagnostic)")
            opened?.close()
        }
        observer?.cancel(); await observer?.value
        if let bluetoothSender { reporter.append("final_sender_timing " + bluetoothSender.timingDiagnostic) }
        reporter.append("final_target_readiness " + manager.audioPlaybackReadinessDiagnostic(for: configuration.deviceID))
        let snapshot = await bluetoothSender?.source.snapshot()
        let pending = bluetoothSender?.cleanupPending == true
        reporter.append("finished senderCreated=\(bluetoothSender == nil ? 0 : 1) sourceVerified=\(snapshot?.sourceVerified == true ? 1 : 0) sourceReleased=\(snapshot?.resourcesReleased == true ? 1 : 0) cleanupPending=\(pending ? 1 : 0) maximumQueuedPackets=\(snapshot?.maximumQueuedPackets ?? 0)")
        if !pending, bluetoothSender == nil || snapshot?.resourcesReleased == true {
            bluetoothSender = nil
            if sampleCreated {
                do { try FileManager.default.removeItem(at: sampleURL) }
                catch { reporter.append("sample_cleanup_failed diagnostic=\(AudioPlaybackFailureDiagnostic.label(for: error))") }
            }
        }
    }

    /// Only local enum diagnostics; never stringify account/server error bodies.
    private static func bluetoothDiagnostic(_ error: any Error) -> String {
        if let failure = error as? BluetoothAudioNativeFailure { return failure.diagnosticLabel }
        if let failure = error as? BluetoothControlStreamError { return "bluetooth.stream.\(failure)" }
        if let error = error as? BluetoothAudioConnectorError {
            switch error {
            case .unavailable(let state): return "bluetooth.state.\(state)"
            case .timedOut: return "bluetooth.connect_timed_out"
            case .cleanupFailed(let primary, let cleanup):
                return "bluetooth.cleanup_failed.primary.\(String(reflecting: type(of: primary))).cleanup.\(String(reflecting: type(of: cleanup)))"
            default: return "bluetooth.\(error)"
            }
        }
        return AudioPlaybackFailureDiagnostic.label(for: error)
    }

    /// One second of deterministic integer PCM at less than -90 dBFS, with
    /// 100 ms fades. No user media or microphone content enters this fixture.
    static func sampleWave() -> Data {
        var bytes = Data()
        func u16(_ value: UInt16) { bytes.append(UInt8(truncatingIfNeeded: value)); bytes.append(UInt8(truncatingIfNeeded: value >> 8)) }
        func u32(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) } }
        bytes.append(contentsOf: "RIFF".utf8); u32(60 + 288_000)
        bytes.append(contentsOf: "WAVEfmt ".utf8); u32(40); u16(0xfffe); u16(2)
        u32(48_000); u32(288_000); u16(6); u16(24); u16(22); u16(24); u32(3)
        bytes.append(contentsOf: [1, 0, 0, 0, 0, 0, 16, 0, 128, 0, 0, 170, 0, 56, 155, 113])
        bytes.append(contentsOf: "data".utf8); u32(288_000)
        for frame in 0..<48_000 {
            let phase = frame % 96
            let triangle = phase < 48 ? phase - 24 : 72 - phase
            let envelope = min(4_800, frame, 47_999 - frame)
            let sample = triangle * 10 * envelope / 4_800
            for channel in [sample, -sample] {
                let value = UInt32(bitPattern: Int32(channel))
                for shift in [0, 8, 16] { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
            }
        }
        return bytes
    }

    static func bluetoothSampleWave(seconds: Int) throws -> Data {
        guard [1, 60, 600].contains(seconds) else { throw Failure.invalidConfiguration }
        let unit = sampleWave()
        var bytes = Data(unit.prefix(68))
        bytes.reserveCapacity(68 + 288_000 * seconds)
        for _ in 0..<seconds { bytes.append(unit.dropFirst(68)) }
        for (offset, value) in [(4, UInt32(bytes.count - 8)), (64, UInt32(bytes.count - 68))] {
            let encoded = (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
            bytes.replaceSubrange(offset..<(offset + 4), with: encoded)
        }
        return bytes
    }

    static func writeBluetoothSampleWave(seconds: Int, to url: URL) throws -> (bytes: Int, sha256: String) {
        let data = try bluetoothSampleWave(seconds: seconds)
        try data.write(to: url, options: .withoutOverwriting)
        return (data.count, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}
#endif
