#if os(macOS)
import Foundation
import os
import SkyBridgeAppleTransport
import SkyBridgeProtocolCore

struct AudioCaptureOutputObservation: Sendable {
    enum State: Sendable { case prepared, running, draining, completed, failed }
    let state: State
    let acceptedSourceFrames: UInt64
    let submittedSourceFrames: UInt64
    let trailingPaddingFrames: UInt32
}

/// One native output owner. The production adapter retains CoreAudioExactPcmOutput;
/// tests use an explicit substitute and cannot establish hardware playback.
protocol AudioCaptureOutput: Sendable {
    func prepare(endpointUID: String, format: AudioStreamingPCMFormat) throws -> CoreAudioExactPcmPreparedOutput
    func enqueue(_ bytes: Data, ownerID: UUID) throws
    func start(ownerID: UUID) throws
    func finishInput(ownerID: UUID, expectedSourceFrames: UInt64) throws
    func observe() throws -> AudioCaptureOutputObservation
    func close(ownerID: UUID) -> AudioOutputCleanupOutcome
}

struct AudioPlaybackReceiveReceipt: Sendable, Equatable {
    let streamID: UUID
    /// Counted PCM timebase: strict source PCM or compatible decoded Opus PCM, never an
    /// assertion that the original music file used the compatible decoder's representation.
    let format: AudioStreamingPCMFormat
    let sourceFrames: UInt64
    let trailingPaddingFrames: UInt32
    let sha256: Data
}

struct AudioPlaybackReceiveFailure: Error, Sendable {
    let reason: AudioStreamingStopReason
    let diagnostic: String
    let cleanupFailures: [String]
    /// Source metadata, not output admission. Present only after the corresponding source checks.
    let sourceFormat: AudioStreamingPCMFormat?
    let outputIssue: AudioPlaybackOutputIssue?
}

/// Actual channel consumer for one captured-PCM or original-file stream. One reader, one bounded
/// control writer and one coalescing progress poller; no alternate transport reader.
/// Approval and preparation run separately so a peer Stop can cancel a visible prompt.
actor AudioPlaybackReceiveSession {
    enum Phase: Sendable { case awaitingOffer, authorizing, awaitingApproval, receivingFile, validatingFile, connectingBluetooth, preparing, buffering, playing, finishing }
    private enum FileInput: Sendable {
        case wave(PreparedOutboundFileReadSession, AudioWavePCMMetadata)
        case flac(AudioValidatedFlacFile)
        case alac(AudioValidatedAlacFile)

        func play(output: any AudioCaptureOutput, prepared: CoreAudioExactPcmPreparedOutput, ownerID: UUID,
                  requireAuthorization: @escaping @Sendable () throws -> Void,
                  onOutputProgress: (@Sendable (UInt64) -> Void)?) async throws -> AudioFilePCMPlaybackReceipt {
            switch self {
            case let .wave(reader, metadata):
                try await AudioFilePCMPlayback.play(reader: reader, metadata: metadata, output: output,
                    prepared: prepared, ownerID: ownerID, requireAuthorization: requireAuthorization,
                    onOutputProgress: onOutputProgress)
            case .flac(let file):
                try await AudioFilePCMPlayback.play(file: file, output: output,
                    prepared: prepared, ownerID: ownerID, requireAuthorization: requireAuthorization,
                    onOutputProgress: onOutputProgress)
            case .alac(let file):
                try await AudioFilePCMPlayback.play(file: file, output: output,
                    prepared: prepared, ownerID: ownerID, requireAuthorization: requireAuthorization,
                    onOutputProgress: onOutputProgress)
            }
        }
    }
    typealias OutputFactory = @Sendable (UUID, @escaping @Sendable () -> Bool) throws -> any AudioCaptureOutput
    private enum ControlLane: Sendable, Equatable { case main, bluetooth }
    private struct Outgoing: Sendable {
        let message: AudioStreamingMessage
        let completes: AudioPlaybackReceiveReceipt?
        let lane: ControlLane
    }
    private enum Terminal {
        case completed(AudioPlaybackReceiveReceipt)
        case failed(AudioStreamingStopReason, String, outputIssue: AudioPlaybackOutputIssue?, notifyPeer: Bool)
    }
    private let channel: P2PAudioChannel
    private let selectOutput: @Sendable () async throws -> String
    private let authorize: @Sendable (P2PAudioChannel) async throws -> AudioMembershipLease
    typealias MembershipRenewal = @Sendable (P2PAudioChannel, AudioMembershipLease) async throws -> Void
    private let renewMembership: MembershipRenewal?
    private let onAuthorizationUpdate: @Sendable (AudioMembershipRenewalUpdate) async -> Void
    private let approvals: AudioPlaybackApprovalService
    private let outputFactory: OutputFactory
    private let bluetooth: AudioBluetoothPlaybackDependencies?
    private let fileTransfers: AudioOriginalFileTransferRegistry?
    private let reportFileOutputProgress: Bool
    private let fileReceiveCleanupTimeout: Duration
    private let receiveOriginalFile: AudioOriginalFileUSBReceiver.Receive
    private let onFormat: @Sendable (AudioStreamingPCMFormat) -> Void
    private let onSource: @Sendable (AudioPlaybackSource) -> Void
    private let onPhase: @Sendable (Phase) -> Void
    private var phase = Phase.awaitingOffer
    private var running = false
    private var terminal: Terminal?
    private var offer: AudioStreamingMessage?
    private var sourceFormat: AudioStreamingPCMFormat?
    private var membership: AudioMembershipLease?
    private var permission: AudioPlaybackPermission?
    private var output: (any AudioCaptureOutput)?
    private var bluetoothLink: (any AudioBluetoothPlaybackLink)?
    private var bluetoothAttachment: AudioBluetoothAttachment?
    private var bluetoothReader: Task<Void, Never>?
    private var bluetoothCleanupOutcome: AudioOutputCleanupOutcome?
    private var opusOutput: CoreAudioOpusOutput?
    private var opusPlayback: AudioOpusPlayback?
    private var opusEffect: (@Sendable () throws -> Void)?
    private var opusDecodedFormat: AudioStreamingPCMFormat?
    private var opusVerifiedDigest: Data?
    private var opusOperationInProgress = false
    private var opusTrace: AudioBluetoothReceiveTrace? = {
#if SKYBRIDGE_TESTING
        if Bundle.main.object(forInfoDictionaryKey: "SkyBridgeBluetoothAudioReceiveTraceQualification") as? Bool == true {
            return AudioBluetoothReceiveTrace()
        }
#endif
        return nil
    }()
    private var fileTransfer: AudioOriginalFileTransfer?
    private var fileCleanupOutcome: AudioOutputCleanupOutcome?
    private var fileOutputProgress: OSAllocatedUnfairLock<UInt64>?
    private var lastFileOutputProgressFrames: UInt64 = 0
    private var lastFileOutputProgressSend: ContinuousClock.Instant?
    private var usbFileReceiver: AudioOriginalFileUSBReceiver?
    private var usbFileCleanupOutcome: AudioOutputCleanupOutcome?
    private var flow: AudioCaptureReceiveFlow?
    private var prefillFrames: UInt64 = 0
    private var lastActivity = ContinuousClock.now
    private var admission: Task<Void, Never>?
    private var membershipRenewal: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var outgoing: [Outgoing] = [] // At most four controls; credits coalesce to one absolute value.
    private var lastCredit: UInt64 = 0
    private var completionQueued = false
    private var runFinished = false
    private var cleanupOutcome = AudioOutputCleanupOutcome.noOutput
    private var cleanupTask: Task<AudioOutputCleanupOutcome, Never>?

    init(channel: P2PAudioChannel, selectOutput: @escaping @Sendable () async throws -> String,
         authorize: @escaping @Sendable (P2PAudioChannel) async throws -> AudioMembershipLease,
         approvals: AudioPlaybackApprovalService, outputFactory: @escaping OutputFactory,
         fileTransfers: AudioOriginalFileTransferRegistry? = nil,
         reportFileOutputProgress: Bool = false,
         bluetooth: AudioBluetoothPlaybackDependencies? = nil,
         fileReceiveCleanupTimeout: Duration = .seconds(5),
         receiveOriginalFile: @escaping AudioOriginalFileUSBReceiver.Receive = AudioOriginalFileUSBReceiver.receiveUsingFileManager,
         renewMembership: MembershipRenewal? = nil,
         onAuthorizationUpdate: @escaping @Sendable (AudioMembershipRenewalUpdate) async -> Void = { _ in },
         onFormat: @escaping @Sendable (AudioStreamingPCMFormat) -> Void = { _ in },
         onSource: @escaping @Sendable (AudioPlaybackSource) -> Void = { _ in },
         onPhase: @escaping @Sendable (Phase) -> Void) {
        self.channel = channel; self.selectOutput = selectOutput; self.authorize = authorize
        self.approvals = approvals; self.outputFactory = outputFactory; self.onPhase = onPhase
        self.fileTransfers = fileTransfers; self.onFormat = onFormat
        self.reportFileOutputProgress = reportFileOutputProgress
        self.bluetooth = bluetooth; self.onSource = onSource
        self.fileReceiveCleanupTimeout = fileReceiveCleanupTimeout
        self.receiveOriginalFile = receiveOriginalFile
        self.renewMembership = renewMembership; self.onAuthorizationUpdate = onAuthorizationUpdate
    }

    func run() async throws -> AudioPlaybackReceiveReceipt {
        guard !running else { throw AudioCaptureReceiveError.invalidState }
        running = true
        defer { runFinished = true }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.readMessages() }
            group.addTask { await self.pollProgress() }
            _ = await group.next()
            group.cancelAll()
        }
        if terminal == nil { fail(.userStopped, diagnostic: "cancelled") }
        permission?.revoke()
        membershipRenewal?.cancel()
        admission?.cancel()
        writer?.cancel()
        bluetoothReader?.cancel()
        await fileTransfer?.cancel()
        await approvals.cancel(ownerID: channel.ownerID)
        await admission?.value
        // Admission can create the owned renewal while cleanup is awaiting it.
        membershipRenewal?.cancel()
        bluetoothReader?.cancel()
        await bluetoothReader?.value
        var cleanup: [String] = []
        let ownedChannel = channel
        let outputCleanup = await closeOwnedOutput()
        cleanup.append(contentsOf: outputCleanup.diagnostics)
        // A control write may still be settling its already-admitted frame. It must remain
        // owned, but must not retain playing output or an exclusive endpoint after Stop.
        await writer?.value
        // A noncooperative account request stays owned, but must not retain a
        // playing output or its exclusive endpoint while cancellation is joined.
        await membershipRenewal?.value
        if case let .failed(reason, _, _, notifyPeer) = terminal, notifyPeer, let offer {
            do {
                // Cleanup owns this bounded send even when the caller is cancelled.
                // The channel's existing native five-second deadline still applies.
                try await Task.detached {
                    try ownedChannel.requireCurrent()
                    try await ownedChannel.send(.init(streamID: offer.streamID, body: .stop(reason)))
                }.value
            } catch { cleanup.append("stop_delivery:" + String(reflecting: type(of: error))) }
        }
        channel.close()
        // Emit the bounded local trace only after effect revocation and native cleanup.
        // The normal product path never creates it; logging cannot hold playback open.
        if let trace = opusTrace {
            for event in trace.events {
                let text = event.diagnostic
                SkyBridgeLogger.p2p.info("Bluetooth receive trace \(text, privacy: .public)")
            }
            opusTrace = nil
        }
        guard let terminal else { throw AudioCaptureReceiveError.invalidState }
        switch terminal {
        case .completed(let receipt):
            guard outputCleanup.state == .released, outputCleanup.preservedExternalChanges.isEmpty, cleanup.isEmpty else {
                throw AudioPlaybackReceiveFailure(reason: .outputLost, diagnostic: "cleanup_failed", cleanupFailures: cleanup,
                    sourceFormat: sourceFormat, outputIssue: nil)
            }
            return receipt
        case let .failed(reason, diagnostic, outputIssue, _):
            throw AudioPlaybackReceiveFailure(reason: reason, diagnostic: diagnostic, cleanupFailures: cleanup,
                sourceFormat: sourceFormat, outputIssue: outputIssue)
        }
    }

    func stop() { fail(.userStopped, diagnostic: "local_stop") }

    func outputCleanupStatus() -> AudioOutputCleanupOutcome { cleanupOutcome }

    /// Only retries resource cleanup after the reader/admission/writer have ended. It cannot
    /// resume the stream, send controls, grant permission, or turn a prior failure into success.
    func retryOutputCleanup() async throws -> AudioOutputCleanupOutcome {
        guard runFinished else { throw AudioCaptureReceiveError.invalidState }
        permission?.revoke()
        fileCleanupOutcome = nil // Only this explicit retry may repeat a pending file close.
        bluetoothCleanupOutcome = nil
        usbFileCleanupOutcome = nil
        return await closeOwnedOutput()
    }

    private func closeOwnedOutput() async -> AudioOutputCleanupOutcome {
        if let cleanupTask { return await cleanupTask.value }
        let task = Task { await self.closeOwnedResources() }
        cleanupTask = task
        let result = await task.value
        cleanupOutcome = result
        cleanupTask = nil
        return result
    }

    private func closeOwnedResources() async -> AudioOutputCleanupOutcome {
        let owner = channel.ownerID
        let native: AudioOutputCleanupOutcome
        if let output {
            native = await Task.detached { output.close(ownerID: owner) }.value
            if native.state == .released { self.output = nil }
        } else { native = .noOutput }
        let compatible: AudioOutputCleanupOutcome
        do {
            if let opusPlayback { compatible = try await opusPlayback.close() }
            else if let opusOutput { compatible = try await Task.detached { try opusOutput.close(ownerID: owner) }.value }
            else { compatible = .noOutput }
        } catch {
            compatible = .init(state: .pending, diagnostics: ["compatible_output_close: " + String(describing: error)], preservedExternalChanges: [])
        }
        if compatible.state == .released { opusPlayback = nil; opusOutput = nil }
        bluetoothAttachment?.close()
        let link: AudioOutputCleanupOutcome
        if let bluetoothLink {
            if let previous = bluetoothCleanupOutcome { link = previous }
            else {
                do {
                    try await bluetoothLink.closeAndAwait()
                    link = .noOutput
                } catch {
                    link = .init(state: .pending, diagnostics: ["bluetooth_close: " + String(describing: error)], preservedExternalChanges: [])
                }
                bluetoothCleanupOutcome = link
            }
        } else { link = .noOutput }
        if link.state == .released { bluetoothLink = nil; bluetoothAttachment = nil }
        let file: AudioOutputCleanupOutcome
        if let fileTransfer {
            if let previous = fileCleanupOutcome { file = previous }
            else {
                file = await fileTransfer.close()
                fileCleanupOutcome = file
            }
        } else { file = .noOutput }
        if file.state == .released, fileTransfer != nil {
            await fileTransfers?.remove(ownerID: owner)
            fileTransfer = nil
            fileCleanupOutcome = nil
        }
        let usb: AudioOutputCleanupOutcome
        if let usbFileReceiver {
            if let previous = usbFileCleanupOutcome { usb = previous }
            else { usb = await usbFileReceiver.close(); usbFileCleanupOutcome = usb }
            if usb.state == .released { self.usbFileReceiver = nil }
        } else { usb = .noOutput }
        var diagnostics = cleanupOutcome.diagnostics
        for item in native.diagnostics + compatible.diagnostics + link.diagnostics + file.diagnostics + usb.diagnostics where !diagnostics.contains(item) { diagnostics.append(item) }
        var preserved = cleanupOutcome.preservedExternalChanges
        for item in native.preservedExternalChanges where !preserved.contains(item) { preserved.append(item) }
        return .init(state: native.state == .released && compatible.state == .released && link.state == .released && file.state == .released && usb.state == .released ? .released : .pending,
                     diagnostics: diagnostics, preservedExternalChanges: preserved)
    }

    private func readMessages() async {
        do {
            var iterator = channel.messages.makeAsyncIterator()
            while let message = try await iterator.next() {
                guard terminal == nil else { return }
                try await receive(message)
            }
            if terminal == nil { fail(.sessionReplaced, diagnostic: "channel_ended", notifyPeer: false) }
        } catch {
            if terminal == nil { record(error) }
        }
    }

    private func receive(_ message: AudioStreamingMessage) async throws {
        try channel.requireCurrent()
        if case .stop(let reason) = message.body {
            if let offer, offer.streamID != message.streamID { throw AudioCaptureReceiveError.wrongStream }
            fail(reason, diagnostic: "peer_stop", notifyPeer: false); return
        }
        if phase == .awaitingOffer {
            let supported: Bool
            switch message.body {
            case .captureOffer: supported = true
            case .fileOffer: supported = fileTransfers != nil
            case .opusOffer, .bufferedOpusFileOffer: supported = bluetooth != nil
            default: supported = false
            }
            guard supported else {
                offer = message
                fail(.unsupportedSource, diagnostic: "capture_offer_required"); return
            }
            offer = message; changePhase(.authorizing)
            admission = Task { await self.admit(message) }
            return
        }
        guard let offer, message.streamID == offer.streamID else { throw AudioCaptureReceiveError.wrongStream }
        if case .fileOffer = offer.body {
            guard case .usbFileRoute(let port) = message.body, phase == .receivingFile,
                  channel.usesUSBFileReturn, let fileTransfer, usbFileReceiver == nil else {
                throw AudioCaptureReceiveError.invalidState
            }
            try requireEffect()
            let receiver = AudioOriginalFileUSBReceiver(channel: channel, transfer: fileTransfer, port: port,
                receive: receiveOriginalFile)
            usbFileReceiver = receiver
            try await receiver.start()
            return
        }
        guard phase == .buffering || phase == .playing || phase == .finishing,
              let output, var flow else { throw AudioCaptureReceiveError.invalidState }
        try requireEffect()
        switch message.body {
        case let .pcmData(offset, bytes):
            try flow.validateData(streamID: message.streamID, offset: offset, bytes: bytes)
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
            while true {
                try requireEffect()
                do { try output.enqueue(bytes, ownerID: channel.ownerID); break }
                catch CoreAudioExactPcmOutputError.busy {
                    guard ContinuousClock.now < deadline else { throw CoreAudioExactPcmOutputError.busy }
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            try requireEffect()
            // Progress polling can retire prior bytes during a busy retry. Reuse that
            // current accounting, never overwrite it with the pre-await copy.
            guard var current = self.flow else { throw AudioCaptureReceiveError.invalidState }
            try current.didEnqueue(streamID: message.streamID, offset: offset, bytes: bytes)
            self.flow = current; lastActivity = .now
            let accepted = current.receivedBytes / UInt64(current.format.bytesPerFrame)
            let observed = try output.observe()
            guard observed.acceptedSourceFrames == accepted else { throw AudioCaptureReceiveError.invalidProgress }
            if phase == .buffering, accepted >= prefillFrames {
                try requireEffect(); try output.start(ownerID: channel.ownerID)
                changePhase(.playing)
            }
        case let .end(total, digest):
            let frames = try flow.verifyEnd(streamID: message.streamID, totalBytes: total, sha256: digest)
            self.flow = flow
            enqueue(.init(streamID: message.streamID, body: .contentVerified(totalBytes: total, sha256: digest)))
            changePhase(.finishing); lastActivity = .now
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
            while true {
                try requireEffect()
                do { try output.finishInput(ownerID: channel.ownerID, expectedSourceFrames: frames); break }
                catch CoreAudioExactPcmOutputError.busy {
                    guard ContinuousClock.now < deadline else { throw CoreAudioExactPcmOutputError.busy }
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
        default: throw AudioCaptureReceiveError.invalidState
        }
    }

    private func admit(_ message: AudioStreamingMessage) async {
        do {
            let source = try AudioPlaybackSource(offer: message)
            if case .capturedPCM(let format) = source,
               Int(format.bytesPerFrame) > AudioStreamingWire.maximumPCMDataBytes {
                throw AudioCaptureReceiveError.partialFrame
            }
            let membership = try await authorize(channel)
            try requirePending(message)
            self.membership = membership
            onSource(source)
            if case .capturedPCM(let format) = source { publishSourceFormat(format) }
            let endpoint: String
            do { endpoint = try await selectOutput() }
            catch {
                let issue = AudioPlaybackOutputIssue(error: error)
                fail(.unsupportedOutput, diagnostic: issue?.rawValue ?? "output_selection:" + String(reflecting: type(of: error)),
                     outputIssue: issue)
                return
            }
            try requirePending(message)
            let request = try AudioPlaybackApprovalRequest(ownerID: channel.ownerID, offer: message,
                membership: membership.evidence, outputEndpointUID: endpoint)
            changePhase(.awaitingApproval)
            let permission = try await approvals.requestApproval(request, isCurrent: { membership.isCurrent })
            do { try requirePending(message) }
            catch { permission.revoke(); throw error }
            self.permission = permission
            if case .opus = source {
                try startMembershipRenewal(membership)
                try await admitBluetooth(message, source: source, membership: membership, permission: permission, endpoint: endpoint)
                return
            }
            let owner = channel.ownerID
            let format: AudioStreamingPCMFormat
            var fileInput: FileInput?
            switch source {
            case .capturedPCM(let captured):
                format = captured
                try startMembershipRenewal(membership)
            case .originalFile:
                guard let fileTransfers else { throw AudioCaptureReceiveError.invalidState }
                let transfer = try AudioOriginalFileTransfer(channel: channel, offer: message,
                    membership: membership, permission: permission, endpoint: endpoint,
                    receiveCleanupTimeout: fileReceiveCleanupTimeout)
                fileTransfer = transfer
                // Initial consent binds the original grant during construction. Only
                // after that binding exists may fresh evidence continue this consumer.
                try startMembershipRenewal(membership)
                try await fileTransfers.register(transfer)
                try requireEffect()
                if channel.usesLogicalFileStream {
                    let receiver = AudioOriginalFileUSBReceiver(channel: channel, transfer: transfer, receive: receiveOriginalFile)
                    usbFileReceiver = receiver
                    try await receiver.start()
                    try requireEffect()
                }
                changePhase(.receivingFile)
                enqueue(.init(streamID: message.streamID, body: .accept(receiveWindowBytes: 0)))
                let artifact = try await transfer.waitForArtifact()
                try requireEffect()
                if channel.usesUSBFileReturn || channel.usesLogicalFileStream {
                    guard let usbFileReceiver else { throw AudioCaptureReceiveError.invalidState }
                    try await usbFileReceiver.waitForCompletion()
                    try requireEffect()
                }
                let reader = try await artifact.verifiedReader()
                guard reader.metadata.fileSize >= 4 else { throw AudioWavePCMFileError.truncated }
                let read: @Sendable (UInt64, Int) async throws -> Data = { offset, length in
                    try transfer.requireAuthorization()
                    let bytes = try await reader.read(offset: offset, length: length)
                    try transfer.requireAuthorization()
                    return bytes
                }
                let signature = try await read(0, 4)
                if signature == Data("fLaC".utf8) {
                    changePhase(.validatingFile)
                    let validated = try await AudioValidatedFlacFile.validate(reader: reader,
                        requireAuthorization: { try transfer.requireAuthorization() })
                    format = validated.metadata.decodedFormat; fileInput = .flac(validated)
                } else if ["RIFF", "RIFX", "RF64"].contains(where: { signature == Data($0.utf8) }) {
                    changePhase(.preparing)
                    let metadata = try await AudioWavePCMFile.inspect(fileSize: UInt64(reader.metadata.fileSize), read: read)
                    format = metadata.format; fileInput = .wave(reader, metadata)
                } else {
                    // Container inspection validates every box and track; a filename or M4A
                    // extension alone never establishes ALAC. No output opens before full EOF.
                    changePhase(.validatingFile)
                    let validated = try await AudioValidatedAlacFile.validate(reader: reader,
                        requireAuthorization: { try transfer.requireAuthorization() })
                    format = validated.metadata.decodedFormat; fileInput = .alac(validated)
                }
                try requireEffect()
            case .opus: throw AudioCaptureReceiveError.invalidState
            }
            publishSourceFormat(format)
            changePhase(.preparing)
            let output = try outputFactory(owner, {
                membership.isCurrent && permission.approves(ownerID: owner, streamID: message.streamID,
                                                            source: source, outputEndpointUID: endpoint)
            })
            self.output = output
            cleanupOutcome = .init(state: .pending, diagnostics: [], preservedExternalChanges: [])
            let prepared = try await Task.detached { try output.prepare(endpointUID: endpoint, format: format) }.value
            try requireEffect()
            guard prepared.endpointUID == endpoint, prepared.format == format else { throw AudioCaptureReceiveError.invalidState }
            if let fileInput, let fileTransfer {
                changePhase(.playing)
                enqueue(.init(streamID: message.streamID, body: .outputReady(format)))
                let observeProgress: (@Sendable (UInt64) -> Void)?
                if reportFileOutputProgress,
                   channel.peerCapabilities.contains(AudioStreamingWire.fileOutputProgressReceiveCapability) {
                    let latest = OSAllocatedUnfairLock(initialState: UInt64(0))
                    fileOutputProgress = latest
                    observeProgress = { frames in latest.withLock { $0 = frames } }
                } else { observeProgress = nil }
                let result = try await fileInput.play(output: output, prepared: prepared, ownerID: owner,
                    requireAuthorization: { try fileTransfer.requireAuthorization() },
                    onOutputProgress: observeProgress)
                try requireEffect()
                changePhase(.finishing)
                // Native completion already requires closed/restored output. Also settle the
                // private file before reporting success to the sender. A pending close stays
                // retained and is not implicitly retried by the normal failure cleanup pass.
                let fileCleanup = await fileTransfer.close()
                fileCleanupOutcome = fileCleanup
                try requireEffect()
                guard fileCleanup.state == .released, fileCleanup.diagnostics.isEmpty else {
                    throw AudioFilePCMPlaybackError.outputLost
                }
                let receipt = AudioPlaybackReceiveReceipt(streamID: message.streamID, format: format,
                    sourceFrames: result.sourceFrames, trailingPaddingFrames: result.trailingPaddingFrames,
                    sha256: fileTransfer.expectedSHA256)
                completionQueued = true
                enqueue(.init(streamID: message.streamID, body: .playbackComplete(sourceFrames: receipt.sourceFrames,
                    trailingPaddingFrames: receipt.trailingPaddingFrames)), completes: receipt)
                return
            }
            let frameBytes = Int(format.bytesPerFrame)
            let limit = min(prepared.receiveCapacityBytes, 6 * AudioStreamingWire.maximumPCMDataBytes)
            let window = limit - limit % frameBytes
            guard window > 0, prepared.minimumPrefillFrames > 0,
                  UInt64(window / frameBytes) >= UInt64(prepared.minimumPrefillFrames) else {
                throw AudioCaptureReceiveError.invalidWindow
            }
            flow = try AudioCaptureReceiveFlow(streamID: message.streamID, format: format, windowBytes: UInt32(window))
            prefillFrames = min(UInt64(window / frameBytes), max(UInt64(prepared.minimumPrefillFrames), UInt64(format.sampleRate) / 10))
            changePhase(.buffering); lastActivity = .now
            enqueue(.init(streamID: message.streamID, body: .accept(receiveWindowBytes: UInt32(window))))
            enqueue(.init(streamID: message.streamID, body: .outputReady(format)))
        } catch { if terminal == nil { record(error) } }
    }

    private func startMembershipRenewal(_ lease: AudioMembershipLease) throws {
        try Task.checkCancellation()
        try requireEffect()
        guard membershipRenewal == nil else { throw AudioCaptureReceiveError.invalidState }
        guard let renewMembership else { return } // Explicit finite/offline consumer.
        let channel = channel, observe = onAuthorizationUpdate
        membershipRenewal = Task {
            await AudioMembershipRenewal(lease: lease, renew: {
                try await renewMembership(channel, lease)
            }, observe: observe).run()
        }
    }

    private func pollProgress() async {
        do {
            while terminal == nil {
                try Task.checkCancellation()
                try await tick()
                if terminal == nil { try await Task.sleep(for: .milliseconds(10)) }
            }
        } catch { if terminal == nil { record(error) } }
    }

    private func admitBluetooth(_ message: AudioStreamingMessage, source: AudioPlaybackSource,
        membership: AudioMembershipLease, permission: AudioPlaybackPermission, endpoint: String) async throws {
        guard let bluetooth, case .opus(_, let profile) = source,
              let parameters = message.body.opusOfferParameters else { throw AudioCaptureReceiveError.invalidState }
        let owner = channel.ownerID, channel = channel
        let effect: @Sendable () throws -> Void = {
            try membership.requireEffectCurrent()
            guard permission.approves(ownerID: owner, streamID: message.streamID, source: source, outputEndpointUID: endpoint) else {
                throw AudioPlaybackApprovalError.rejected
            }
        }
        let current: @Sendable () throws -> Void = {
            try channel.requireCurrent()
            guard membership.isCurrent else { throw membership.failure ?? AudioMembershipLeaseFailure.revoked }
            try effect()
        }
        try requireEffect()
        opusEffect = effect
        let link = bluetooth.makeLink(message.streamID, current)
        bluetoothLink = link
        cleanupOutcome = .init(state: .pending, diagnostics: [], preservedExternalChanges: [])
        changePhase(.connectingBluetooth)
        let route = try await link.publish()
        try requireEffect()
        try await channel.send(.init(streamID: message.streamID, body: .bluetoothRoute(route)), requireEffectAuthorization: effect)
        try requireEffect()
        let attachment = try channel.prepareBluetoothAttachment()
        bluetoothAttachment = attachment
        try await link.establish(attachment)
        try requireEffect()
        changePhase(.preparing)
        let output = try bluetooth.makeOutput(owner, parameters.buffering, effect)
        guard output.ownerID == owner else { throw CoreAudioOpusOutputError.wrongOwner }
        opusOutput = output
        let playback = try AudioOpusPlayback(offer: message, endpointUID: endpoint, output: output, requireAuthorization: effect)
        opusPlayback = playback
        opusDecodedFormat = try .init(sampleRate: 48_000, channels: UInt16(profile.channels), encoding: .signed16,
            declaredValidBits: 16, waveChannelMask: profile.channels == 1 ? 4 : 3)
        let controls = try await playback.prepare()
        try requireEffect()
        changePhase(.buffering)
        try acceptBluetoothControls(controls)
    }

    private func readBluetoothMessages(_ link: any AudioBluetoothPlaybackLink,
        effect: @escaping @Sendable () throws -> Void) async {
        do {
            while terminal == nil {
                opusTrace?.record(.readBegin)
                let message = try await link.receive(requireEffect: effect)
                if case .opusData(let sequence, _) = message.body {
                    opusTrace?.record(.received, value: sequence)
                }
                try requireEffect()
                guard message.streamID == offer?.streamID else { throw AudioCaptureReceiveError.wrongStream }
                if case .stop(let reason) = message.body { fail(reason, diagnostic: "bluetooth_peer_stop", notifyPeer: false); return }
                // One packet may wait behind one coalesced poll. Serialize the reducer response
                // with its control publication; actor reentrancy must not reorder verified End
                // and completion controls. The native receive window remains the queue bound.
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while opusOperationInProgress {
                    try requireEffect()
                    guard ContinuousClock.now < deadline else { throw AudioStreamingChannelError.timedOut }
                    try await Task.sleep(for: .milliseconds(1))
                }
                guard let playback = opusPlayback else { throw AudioCaptureReceiveError.invalidState }
                opusOperationInProgress = true
                do {
                    opusTrace?.record(.reduceBegin)
                    let controls = try await playback.receive(message)
                    opusTrace?.record(.reduceEnd)
                    try requireEffect()
                    try acceptBluetoothControls(controls)
                    try updateBluetoothPhase()
                    lastActivity = .now
                    opusOperationInProgress = false
                } catch { opusOperationInProgress = false; throw error }
            }
        } catch { if terminal == nil { record(error) } }
    }

    private func tickBluetooth() async throws {
        guard !opusOperationInProgress, let playback = opusPlayback else { return }
        opusOperationInProgress = true
        defer { opusOperationInProgress = false }
        let controls = try await playback.poll()
        try requireEffect()
        try acceptBluetoothControls(controls)
        try updateBluetoothPhase()
    }

    private func acceptBluetoothControls(_ controls: [AudioStreamingMessage]) throws {
        guard let offer, let format = opusDecodedFormat else { throw AudioCaptureReceiveError.invalidState }
        for control in controls {
            guard control.streamID == offer.streamID else { throw AudioCaptureReceiveError.wrongStream }
            var receipt: AudioPlaybackReceiveReceipt?
            switch control.body {
            case .accept, .opusOutputReady, .credit: break
            case .contentVerified(_, let digest):
                guard opusVerifiedDigest == nil else { throw AudioCaptureReceiveError.invalidState }
                opusVerifiedDigest = digest; changePhase(.finishing)
            case .playbackComplete(let frames, let padding):
                guard let digest = opusVerifiedDigest, !completionQueued else { throw AudioCaptureReceiveError.invalidState }
                completionQueued = true
                receipt = .init(streamID: offer.streamID, format: format, sourceFrames: frames, trailingPaddingFrames: padding, sha256: digest)
            default: throw AudioCaptureReceiveError.invalidState
            }
            enqueue(control, completes: receipt, lane: .bluetooth)
        }
    }

    private func updateBluetoothPhase() throws {
        guard let output = opusOutput else { throw AudioCaptureReceiveError.invalidState }
        let value = try output.checkedSnapshot(ownerID: output.ownerID)
        opusTrace?.record(.output, value: value.acceptedSourceFrames,
                          auxiliary: value.playedSourceFrames, queued: value.pendingBuffers)
        switch value.state {
        case .prepared: break
        case .running: if phase == .buffering { changePhase(.playing) }
        case .draining, .completed:
            guard opusVerifiedDigest != nil else { throw AudioCaptureReceiveError.invalidState }
            if phase != .finishing { changePhase(.finishing) }
        default: throw AudioOpusPlaybackError.output(value)
        }
    }

    private func tick() async throws {
        try channel.requireCurrent()
        if let membership, !membership.isCurrent { throw AudioMembershipLeaseFailure.revoked }
        if let permission, !permission.isApproved { throw AudioPlaybackApprovalError.rejected }
        let age = lastActivity.duration(to: .now)
        switch phase {
        case .awaitingOffer: if age >= .seconds(10) { fail(.timedOut, diagnostic: "offer_timeout") }
        case .authorizing: if age >= .seconds(45) { fail(.timedOut, diagnostic: "account_timeout") }
        case .awaitingApproval: break // Approval service owns its precise 60-second deadline.
        case .connectingBluetooth: if age >= .seconds(55) { fail(.timedOut, diagnostic: "bluetooth_setup_timeout") }
        case .receivingFile:
            guard let fileTransfer else { throw AudioCaptureReceiveError.invalidState }
            if age >= .seconds(60), !(await fileTransfer.hasClaimedTransfer) {
                fail(.timedOut, diagnostic: "file_transfer_start_timeout")
            }
        case .preparing: if age >= .seconds(10) { fail(.timedOut, diagnostic: "prepare_timeout") }
        case .validatingFile:
            if age >= AudioValidatedFlacFile.maximumValidationTime { fail(.timedOut, diagnostic: "file_validation_timeout") }
        case .buffering, .playing, .finishing:
            if opusPlayback != nil { try await tickBluetooth(); return }
            if fileTransfer != nil {
                try publishFileOutputProgressIfReady()
                return // The file pump still owns its input/progress/drain deadlines.
            }
            guard let output, var flow, let offer else { throw AudioCaptureReceiveError.invalidState }
            try requireEffect()
            let observation = try output.observe()
            guard observation.state != .failed else { throw CoreAudioExactPcmOutputError.deviceChanged }
            guard observation.acceptedSourceFrames == flow.receivedBytes / UInt64(flow.format.bytesPerFrame) else {
                throw AudioCaptureReceiveError.invalidProgress
            }
            if let retired = try flow.retire(sourceFrames: observation.submittedSourceFrames), retired > lastCredit {
                lastCredit = retired
                enqueue(.init(streamID: offer.streamID, body: .credit(retiredBytes: retired)))
            }
            self.flow = flow
            if observation.state == .completed {
                guard phase == .finishing, let digest = flow.verifiedDigest else { throw AudioCaptureReceiveError.invalidState }
                try flow.didComplete(sourceFrames: observation.submittedSourceFrames)
                // Keep contentVerified flow until the completion write succeeds; no new data is legal.
                if !completionQueued {
                    let receipt = AudioPlaybackReceiveReceipt(streamID: offer.streamID, format: flow.format,
                        sourceFrames: observation.submittedSourceFrames, trailingPaddingFrames: observation.trailingPaddingFrames,
                        sha256: digest)
                    completionQueued = true
                    enqueue(.init(streamID: offer.streamID, body: .playbackComplete(sourceFrames: receipt.sourceFrames,
                        trailingPaddingFrames: receipt.trailingPaddingFrames)), completes: receipt)
                }
            } else if age >= .seconds(10) { fail(.timedOut, diagnostic: phase == .finishing ? "drain_timeout" : "input_timeout") }
        }
    }

    private func publishFileOutputProgressIfReady() throws {
        guard phase == .playing, !completionQueued, let fileOutputProgress, let offer,
              writer == nil, outgoing.isEmpty else { return }
        try requireEffect()
        let frames = fileOutputProgress.withLock { $0 }
        guard frames > lastFileOutputProgressFrames else { return }
        if let sent = lastFileOutputProgressSend, sent.duration(to: .now) < .seconds(1) { return }
        // Keep only the latest observation while the existing bounded writer is occupied.
        // No observer creates a task or puts progress ahead of a pending control reply.
        enqueue(.init(streamID: offer.streamID, body: .fileOutputProgress(sourceFrames: frames)))
    }

    private func enqueue(_ message: AudioStreamingMessage, completes: AudioPlaybackReceiveReceipt? = nil, lane: ControlLane = .main) {
        guard terminal == nil else { return }
        if case .fileOutputProgress = message.body {
            // The progress publisher admits only an otherwise idle control lane.
            guard writer == nil, outgoing.isEmpty else { return }
        } else {
            outgoing.removeAll { if case .fileOutputProgress = $0.message.body { return true }; return false }
        }
        if lane == .bluetooth, case .credit(let bytes) = message.body {
            opusTrace?.record(.creditQueued, value: bytes, queued: outgoing.count)
        }
        if case .credit = message.body, let index = outgoing.lastIndex(where: {
            if case .credit = $0.message.body { return $0.lane == lane }; return false
        }) { outgoing[index] = Outgoing(message: message, completes: nil, lane: lane) }
        else {
            guard outgoing.count < 4 else { fail(.queueOverflow, diagnostic: "control_queue_overflow"); return }
            outgoing.append(Outgoing(message: message, completes: completes, lane: lane))
        }
        if writer == nil { writer = Task { await self.writeControls() } }
    }

    private func writeControls() async {
        defer { writer = nil }
        do {
            while terminal == nil, !outgoing.isEmpty {
                try Task.checkCancellation(); try requireEffect()
                let item = outgoing.removeFirst()
                guard let membership, let permission else { throw AudioCaptureReceiveError.invalidState }
                if case .fileOutputProgress(let frames) = item.message.body {
                    guard phase == .playing, !completionQueued, frames > lastFileOutputProgressFrames else { continue }
                    let now = ContinuousClock.now
                    if let sent = lastFileOutputProgressSend, sent.duration(to: now) < .seconds(1) { continue }
                }
                switch item.lane {
                case .main:
                    try await channel.send(item.message, requireEffectAuthorization: {
                        try membership.requireEffectCurrent()
                        guard permission.isApproved else { throw AudioPlaybackApprovalError.rejected }
                    })
                case .bluetooth:
                    guard let link = bluetoothLink, let effect = opusEffect else { throw AudioCaptureReceiveError.invalidState }
                    if case .credit(let bytes) = item.message.body { opusTrace?.record(.creditWriteBegin, value: bytes) }
                    try await link.send(item.message, requireEffect: effect)
                    if case .credit(let bytes) = item.message.body { opusTrace?.record(.creditWriteEnd, value: bytes) }
                    try requireEffect()
                    if case .opusOutputReady = item.message.body {
                        guard bluetoothReader == nil else { throw AudioCaptureReceiveError.invalidState }
                        bluetoothReader = Task { await self.readBluetoothMessages(link, effect: effect) }
                    }
                }
                try requireEffect()
                if case .fileOutputProgress(let frames) = item.message.body {
                    lastFileOutputProgressFrames = frames
                    lastFileOutputProgressSend = .now
                }
                if let receipt = item.completes {
                    terminal = .completed(receipt)
                    membershipRenewal?.cancel()
                }
            }
        } catch { if terminal == nil { record(error) } }
    }

    private func requirePending(_ message: AudioStreamingMessage) throws {
        try Task.checkCancellation(); try channel.requireCurrent()
        guard terminal == nil, offer == message else { throw AudioPlaybackApprovalError.ownerReplaced }
    }
    private func requireEffect() throws {
        try Task.checkCancellation(); try channel.requireCurrent()
        guard terminal == nil else { throw AudioCaptureReceiveError.invalidState }
        guard let membership, membership.isCurrent else { throw AudioMembershipLeaseFailure.revoked }
        guard let permission, permission.isApproved else { throw AudioPlaybackApprovalError.rejected }
    }
    private func changePhase(_ next: Phase) { phase = next; lastActivity = .now; onPhase(next) }
    private func publishSourceFormat(_ format: AudioStreamingPCMFormat) {
        guard sourceFormat != format else { return }
        sourceFormat = format
        onFormat(format)
    }
    private func fail(_ reason: AudioStreamingStopReason, diagnostic: String,
                      outputIssue: AudioPlaybackOutputIssue? = nil, notifyPeer: Bool = true) {
        guard terminal == nil else { return }
        opusTrace?.record(.terminal)
        terminal = .failed(reason, diagnostic, outputIssue: outputIssue, notifyPeer: notifyPeer)
        permission?.revoke(); membershipRenewal?.cancel(); admission?.cancel()
    }
    private func record(_ error: Error) {
        let classified = (error as? AudioOpusPlaybackFailure)?.primary ?? error
        let reason: AudioStreamingStopReason
        switch classified {
        case is CancellationError: reason = .userStopped
        case is AudioMembershipLeaseFailure, is AudioMembershipError: reason = .accountRevoked
        case let approval as AudioPlaybackApprovalError:
            reason = approval == .timedOut ? .timedOut : .receiverDeclined
        case AudioCaptureReceiveError.contentMismatch: reason = .contentMismatch
        case AudioOpusReceiveError.contentMismatch: reason = .contentMismatch
        case AudioOpusReceiveError.windowExceeded: reason = .queueOverflow
        case is AudioOpusReceiveError, is AudioStreamingWireError: reason = .protocolViolation
        case CoreAudioOpusOutputError.timedOut, BluetoothControlStreamError.timedOut,
             BluetoothAudioListenerError.timedOut, AudioStreamingChannelError.timedOut: reason = .timedOut
        case is CoreAudioOpusOutputError, is AudioOpusPlaybackError:
            reason = phase == .preparing ? .unsupportedOutput : .outputLost
        case is BluetoothAudioListenerError, is BluetoothAudioChannelError, is BluetoothControlStreamError: reason = .sessionReplaced
        case is AudioWavePCMFileError: reason = .unsupportedSource
        case is AudioFlacMetadataError, AudioFlacDecodeError.invalidMetadata,
             AudioFlacValidationError.unsupportedDuration: reason = .unsupportedSource
        case AudioFlacValidationError.timedOut: reason = .timedOut
        case AudioFlacDecodeError.native(let status, _): reason = status == 101 ? .sourceFailed : .contentMismatch
        case is AudioFlacDecodeError, is AudioFlacValidationError: reason = .sourceFailed
        case is AudioAlacFileError, AudioAlacDecodeError.invalidMetadata,
             AudioAlacValidationError.unsupportedDuration: reason = .unsupportedSource
        case AudioAlacValidationError.timedOut: reason = .timedOut
        case let error as AudioAlacDecodeError: reason = error.isContentMismatch ? .contentMismatch : .sourceFailed
        case is AudioAlacValidationError: reason = .sourceFailed
        case is PreparedOutboundFileReadError: reason = .contentMismatch
        case is AudioOriginalFileTransferError: reason = .protocolViolation
        case AudioFilePCMPlaybackError.nonFiniteSample: reason = .unsupportedSource
        case AudioFilePCMPlaybackError.timedOut: reason = .timedOut
        case is AudioFilePCMPlaybackError: reason = .outputLost
        case is AudioCaptureReceiveError: reason = .protocolViolation
        case AudioBluetoothAttachmentError.unexpectedMessage: reason = .protocolViolation
        case is P2PAudioTransportError: reason = .sessionReplaced
        default:
            // Before admission, an unavailable account lookup is not an output-device failure.
            // The wire reason covers unavailable/expired authorization without exposing server text.
            switch phase {
            case .authorizing: reason = .accountRevoked
            case .receivingFile: reason = .sourceFailed
            case .preparing: reason = .unsupportedOutput
            case .connectingBluetooth: reason = .sessionReplaced
            default: reason = .outputLost
            }
        }
        let issue = reason == .unsupportedOutput || reason == .outputLost
            ? AudioPlaybackOutputIssue(error: classified) : nil
        let diagnostic = issue?.rawValue ?? AudioPlaybackFailureDiagnostic.label(for: classified)
        let phaseLabel = String(describing: phase)
        let sourceDescription = sourceFormat.map {
            "rate=\($0.sampleRate) channels=\($0.channels) encoding=\($0.encoding.rawValue) validBits=\($0.declaredValidBits) frameBytes=\($0.bytesPerFrame)"
        } ?? "not-yet-validated"
        let controlTransport = channel.controlTransport.rawValue
        SkyBridgeLogger.p2p.error("Audio receive failure phase=\(phaseLabel, privacy: .public) reason=\(String(describing: reason), privacy: .public) cause=\(diagnostic, privacy: .public) sourcePCM=[\(sourceDescription, privacy: .public)] controlTransport=\(controlTransport, privacy: .public)")
        fail(reason, diagnostic: diagnostic, outputIssue: issue)
    }
}
#endif
