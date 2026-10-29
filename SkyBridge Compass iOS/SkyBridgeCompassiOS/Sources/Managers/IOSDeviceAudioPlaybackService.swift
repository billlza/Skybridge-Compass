import Foundation
import Combine
import SkyBridgeProtocolCore

enum IOSAudioPlaybackSource: Hashable, Sendable { case originalFile, systemCapture, bluetoothFile }

struct IOSAudioPlaybackTarget: Equatable {
    let deviceID: String
    let name: String
    let identity: AudioProtocolIdentity
    /// A presentation snapshot only. The current channel independently checks
    /// the receiver's authenticated capability before sending an Offer.
    let sources: Set<IOSAudioPlaybackSource>
}

extension IOSAudioPlaybackTarget {
    init?(deviceID: String, name: String, peer: IOSAudioPeerSnapshot) {
        var sources: Set<IOSAudioPlaybackSource> = []
        let fileRouteReady = peer.capabilities.contains(AudioStreamingWire.usbFileReceiveCapability)
            ? peer.capabilities.contains("classic_approval_v1") : (peer.filePort.map { $0 > 0 } ?? false)
        if peer.capabilities.contains(AudioStreamingWire.fileReceiveCapability), fileRouteReady { sources.insert(.originalFile) }
        if peer.capabilities.contains(AudioStreamingWire.captureReceiveCapability) { sources.insert(.systemCapture) }
        if peer.capabilities.contains(AudioStreamingWire.opusReceiveCapability),
           peer.capabilities.contains(AudioStreamingWire.bluetoothAttachmentCapability) { sources.insert(.bluetoothFile) }
        guard !sources.isEmpty else { return nil }
        self.init(deviceID: deviceID, name: name, identity: peer.identity, sources: sources)
    }
}

enum IOSDeviceAudioPlaybackError: Error, Equatable { case busy, cleanupPending, targetChanged, unsupportedSource }

/// Owned by the existing P2P manager, not by a sheet. Dismissing a view cannot
/// release a still-running file worker or an unconfirmed native close.
@MainActor
final class IOSDeviceAudioPlaybackService: ObservableObject {
    @Published private(set) var operation: IOSOriginalFileSendSession?
    @Published private(set) var captureOperation: IOSCaptureSendSession?
    @Published private(set) var bluetoothOperation: IOSOpusFileSendSession?
    @Published private(set) var target: IOSAudioPlaybackTarget?
    @Published private(set) var fileName: String?
    @Published private(set) var isRunning = false
    @Published private(set) var cleanupPending = false
    @Published private(set) var isClosing = false
    @Published private(set) var lastError: (any Error)?
    @Published private(set) var backgroundState: IOSAudioBackgroundState = .foregroundOnly
    @Published private(set) var backgroundFailure: (any Error)?
    private var task: Task<Void, Never>?
    private var backgroundExecution: IOSAudioBackgroundExecution?
    private var backgroundObservation: AnyCancellable?
    private var fileProgressObservation: AnyCancellable?
    private var captureObservation: AnyCancellable?
    private var sourceObservation: AnyCancellable?
    // Holds native resources even if channel creation fails before a sender exists.
    private let captureSources: IOSAudioCaptureSourceOwner
    var captureSource: IOSAudioCaptureSource? { captureSources.current }
    var systemCaptureAvailability: IOSSystemAudioCaptureAvailability { captureSources.screenCaptureAvailability }
    var isPresentationLocked: Bool {
        isRunning || isClosing || cleanupPending || (captureSource != nil && captureSource?.phase != .closed)
    }
    private let makeSession: @MainActor (IOSPreparedAudioFile, IOSAudioChannel) -> IOSOriginalFileSendSession
    private let makeBackgroundExecution: @MainActor () throws -> IOSAudioBackgroundExecution?
    private let makeCaptureSession: @MainActor (IOSAudioCaptureSource, IOSAudioChannel) -> IOSCaptureSendSession
    private let makeBluetoothSession: @MainActor (URL, IOSAudioChannel) throws -> IOSOpusFileSendSession

    init(captureSources: IOSAudioCaptureSourceOwner = IOSAudioCaptureSourceOwner(),
         makeBackgroundExecution: @escaping @MainActor () throws -> IOSAudioBackgroundExecution? = {
             if #available(iOS 26.0, *) { return try IOSContinuedAudioTaskScheduler.makeExecution() }
             return nil // Older systems retain the explicitly presented foreground-only path.
         },
         makeBluetoothSession: @escaping @MainActor (URL, IOSAudioChannel) throws -> IOSOpusFileSendSession = {
             try IOSOpusFileSendSession(url: $0, channel: $1,
                 renewMembership: IOSAudioAccountMembershipProvider.shared.renew(for:continuing:))
         },
         makeCaptureSession: @escaping @MainActor (IOSAudioCaptureSource, IOSAudioChannel) -> IOSCaptureSendSession = {
             IOSCaptureSendSession(renewMembership: IOSAudioAccountMembershipProvider.shared.renew(for:continuing:), source: $0, channel: $1)
         },
         makeSession: @escaping @MainActor (IOSPreparedAudioFile, IOSAudioChannel) -> IOSOriginalFileSendSession = {
        IOSOriginalFileSendSession(renewMembership: IOSAudioAccountMembershipProvider.shared.renew(for:continuing:), source: $0, channel: $1)
    }) {
        self.makeSession = makeSession; self.captureSources = captureSources
        self.makeBackgroundExecution = makeBackgroundExecution
        self.makeCaptureSession = makeCaptureSession
        self.makeBluetoothSession = makeBluetoothSession
        if let source = captureSources.current { observeSource(source) }
    }

    func start(url: URL, target: IOSAudioPlaybackTarget,
               openChannel: @MainActor () throws -> IOSAudioChannel) throws {
        guard !isRunning, !isClosing else { throw IOSDeviceAudioPlaybackError.busy }
        guard captureSource == nil || captureSource?.phase == .closed else { throw IOSDeviceAudioPlaybackError.busy }
        guard !cleanupPending else { throw IOSDeviceAudioPlaybackError.cleanupPending }
        guard target.sources.contains(.originalFile) else { throw IOSDeviceAudioPlaybackError.unsupportedSource }
        let channel = try openChannel()
        let source: IOSPreparedAudioFile
        let background: IOSAudioBackgroundExecution?
        do {
            try channel.requireCurrent()
            guard channel.remoteIdentity == target.identity else { throw IOSDeviceAudioPlaybackError.targetChanged }
            background = channel.peerCapabilities.contains(AudioStreamingWire.fileOutputProgressReportCapability)
                ? try makeBackgroundExecution() : nil
            source = try IOSPreparedAudioFile(url: url)
        } catch { channel.close(); throw error }
        let operation = makeSession(source, channel)
        captureObservation = nil
        self.operation = operation; captureOperation = nil; bluetoothOperation = nil; self.target = target; fileName = source.fileName
        lastError = nil; isRunning = true
        backgroundExecution = background; backgroundObservation = nil; fileProgressObservation = nil
        backgroundState = .foregroundOnly; backgroundFailure = nil
        if let background {
            backgroundObservation = background.$state.sink { [weak self, weak background] in
                self?.backgroundState = $0; self?.backgroundFailure = background?.failure
            }
            fileProgressObservation = operation.$workProgress.sink { [weak background] in background?.update($0) }
        }
        task = Task { [weak self, operation, background] in
            var startFailure: (any Error)?
            if let background {
                do { try await background.start { [weak operation] in operation?.stop() } }
                catch { startFailure = error; operation.stop() }
            }
            let result: Result<IOSOriginalFileSendReceipt, Error>
            do { result = .success(try await operation.run()) }
            catch { result = .failure(error) }
            if let background {
                background.update(operation.workProgress)
                let success: Bool
                if case .success = result { success = !operation.cleanupPending } else { success = false }
                await background.finish(success: success)
            }
            guard let self, self.operation === operation else { return }
            if case .failure(let error) = result { self.lastError = error }
            if let startFailure { self.lastError = startFailure }
            if let error = background?.failure { self.lastError = error }
            self.backgroundFailure = background?.failure ?? startFailure
            self.fileProgressObservation = nil
            self.cleanupPending = operation.cleanupPending
            self.isRunning = false
            self.task = nil
        }
    }

    func startBluetoothFile(url: URL, target: IOSAudioPlaybackTarget,
                            openChannel: @MainActor () throws -> IOSAudioChannel) throws {
        guard !isPresentationLocked else { throw IOSDeviceAudioPlaybackError.busy }
        guard target.sources.contains(.bluetoothFile) else { throw IOSDeviceAudioPlaybackError.unsupportedSource }
        let channel = try openChannel()
        let operation: IOSOpusFileSendSession
        let background: IOSAudioBackgroundExecution?
        do {
            try channel.requireCurrent()
            guard channel.remoteIdentity == target.identity else { throw IOSDeviceAudioPlaybackError.targetChanged }
            background = try makeBackgroundExecution()
            operation = try makeBluetoothSession(url, channel)
        } catch { channel.close(); throw error }
        captureObservation = nil; sourceObservation = nil
        self.operation = nil; captureOperation = nil; bluetoothOperation = operation
        self.target = target; fileName = operation.source.fileName; lastError = nil; isRunning = true
        backgroundExecution = background; backgroundObservation = nil; fileProgressObservation = nil
        backgroundState = .foregroundOnly; backgroundFailure = nil
        if let background {
            backgroundObservation = background.$state.sink { [weak self, weak background] in
                self?.backgroundState = $0; self?.backgroundFailure = background?.failure
            }
            fileProgressObservation = operation.$workProgress.sink { [weak background] in background?.update($0) }
        }
        task = Task { [weak self, operation, background] in
            var startFailure: (any Error)?
            if let background {
                do { try await background.start { [weak operation] in operation?.stop() } }
                catch { startFailure = error; operation.stop() }
            }
            let result: Result<IOSOpusFileSendReceipt, Error>
            do { result = .success(try await operation.run()) }
            catch { result = .failure(error) }
            if let background {
                background.update(operation.workProgress)
                let success: Bool
                if case .success = result { success = !operation.cleanupPending } else { success = false }
                await background.finish(success: success)
            }
            guard let self, self.bluetoothOperation === operation else { return }
            if case .failure(let error) = result { self.lastError = error }
            if let startFailure { self.lastError = startFailure }
            if let error = background?.failure { self.lastError = error }
            self.backgroundFailure = background?.failure ?? startFailure
            self.fileProgressObservation = nil
            self.cleanupPending = operation.cleanupPending
            self.isRunning = false; self.task = nil
        }
    }

    func makeCaptureSource(profile: IOSScreenCaptureAudioProfile) throws -> IOSAudioCaptureSource {
        guard !isRunning, !isClosing else { throw IOSDeviceAudioPlaybackError.busy }
        guard !cleanupPending else { throw IOSDeviceAudioPlaybackError.cleanupPending }
        let source = try captureSources.makeScreenCapture(profile: profile)
        captureObservation = nil
        operation = nil; captureOperation = nil; bluetoothOperation = nil; target = nil; fileName = nil; lastError = nil
        observeSource(source)
        return source
    }

    func startSystemCapture(target: IOSAudioPlaybackTarget,
                            openChannel: @MainActor () throws -> IOSAudioChannel) throws {
        guard !isPresentationLocked else { throw IOSDeviceAudioPlaybackError.busy }
        guard target.sources.contains(.systemCapture) else { throw IOSDeviceAudioPlaybackError.unsupportedSource }
        let profile = try IOSScreenCaptureAudioProfile(sampleRate: 48_000, channels: 2)
        let source = try makeCaptureSource(profile: profile)
        do { try startCapture(source: source, target: target, openChannel: openChannel) }
        catch {
            recordCaptureStartFailure(error, source: source)
            throw error
        }
    }

    func startCapture(source: IOSAudioCaptureSource, target: IOSAudioPlaybackTarget,
                      openChannel: @MainActor () throws -> IOSAudioChannel) throws {
        guard !isRunning, !isClosing else { throw IOSDeviceAudioPlaybackError.busy }
        guard !cleanupPending else { throw IOSDeviceAudioPlaybackError.cleanupPending }
        guard captureSource === source, source.phase == .idle || source.phase == .prepared else {
            throw IOSDeviceAudioPlaybackError.targetChanged
        }
        try source.requireUnclaimedForSending()
        guard target.sources.contains(.systemCapture) else { throw IOSDeviceAudioPlaybackError.unsupportedSource }
        let channel: IOSAudioChannel
        do { channel = try openChannel() }
        catch { recordCaptureStartFailure(error, source: source); throw error }
        do {
            try channel.requireCurrent()
            guard channel.remoteIdentity == target.identity else { throw IOSDeviceAudioPlaybackError.targetChanged }
        } catch { channel.close(); recordCaptureStartFailure(error, source: source); throw error }
        let operation = makeCaptureSession(source, channel)
        self.operation = nil; bluetoothOperation = nil; captureOperation = operation; self.target = target; fileName = nil
        lastError = nil; isRunning = true
        captureObservation = operation.objectWillChange.sink { [weak self, weak operation] in
            Task { @MainActor in
                guard let self, let operation, self.captureOperation === operation, !self.isRunning else { return }
                if self.cleanupPending != operation.cleanupPending { self.cleanupPending = operation.cleanupPending }
            }
        }
        task = Task { [weak self, operation] in
            let result: Result<IOSCaptureSendReceipt, Error>
            do { result = .success(try await operation.run()) } catch { result = .failure(error) }
            guard let self, self.captureOperation === operation else { return }
            if case .failure(let error) = result { self.lastError = error }
            self.cleanupPending = operation.cleanupPending
            self.isRunning = false; self.task = nil
        }
    }

    func finishCapture() { captureOperation?.finishCapture() }

    /// Native capture and a specifically requested finite file task own their
    /// execution lifetimes. A system grant is required for either file transport.
    func didEnterBackground() {
        let hasFiniteFile = operation != nil || bluetoothOperation != nil
        if captureOperation == nil, !(hasFiniteFile && backgroundExecution?.preservesBackgroundWork == true) { stop() }
    }

    func presentationDidDisappear(isBackground: Bool) {
        if isBackground { didEnterBackground() } else { stop() }
    }

    private func observeSource(_ source: IOSAudioCaptureSource) {
        cleanupPending = source.cleanupPending
        sourceObservation = source.objectWillChange.sink { [weak self, weak source] in
            Task { @MainActor in
                guard let self, let source, self.captureSource === source else { return }
                if self.captureOperation == nil { self.cleanupPending = source.cleanupPending }
                self.objectWillChange.send()
            }
        }
    }

    private func recordCaptureStartFailure(_ error: any Error, source: IOSAudioCaptureSource) {
        source.cancel(error)
        lastError = error; cleanupPending = source.cleanupPending
    }

    func stop() {
        backgroundExecution?.cancel()
        operation?.stop(); captureOperation?.cancel(); bluetoothOperation?.stop()
        if captureOperation == nil { captureSource?.cancel() }
    }

    func stopAndWait() async {
        stop()
        await task?.value
        if captureOperation == nil, let source = captureSource, source.phase != .closed {
            do { try await source.stop() } catch { lastError = error }
            cleanupPending = source.cleanupPending
        }
    }

    func retryCleanup() async throws {
        guard !isClosing else { throw IOSDeviceAudioPlaybackError.busy }
        guard !isRunning, cleanupPending else { throw IOSDeviceAudioPlaybackError.cleanupPending }
        isClosing = true
        // A late native close can release ownership even when the attempt reports
        // an earlier timeout. Always publish the actual ownership state, and keep
        // the selected operation fixed until this attempt has fully returned.
        if let bluetoothOperation {
            defer { cleanupPending = bluetoothOperation.cleanupPending; isClosing = false }
            try await bluetoothOperation.retryCleanup()
        } else if let captureOperation {
            defer { cleanupPending = captureOperation.cleanupPending; isClosing = false }
            try await captureOperation.retryCleanup()
        } else if let operation {
            defer { cleanupPending = operation.cleanupPending; isClosing = false }
            try await operation.retryCleanup()
        } else if let source = captureSource {
            defer { cleanupPending = source.cleanupPending; isClosing = false }
            if source.phase != .closed { try await source.retryCleanup() }
        } else {
            isClosing = false
            throw IOSDeviceAudioPlaybackError.cleanupPending
        }
    }
}
