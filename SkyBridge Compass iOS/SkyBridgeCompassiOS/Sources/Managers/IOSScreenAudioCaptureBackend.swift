import Foundation
import CoreMedia

#if canImport(ScreenCaptureKit) && os(iOS)
import ScreenCaptureKit
import os

/// One system selection and one native owner. Only Sendable results/identifiers
/// cross from the Objective-C observer callbacks to the main actor.
@available(iOS 27.0, *)
@MainActor
final class IOSScreenAudioCaptureBackend: NSObject, IOSAudioCaptureBackend, SCContentSharingPickerObserver {
    let ingress: IOSAudioCaptureIngress
    var didStop: (@MainActor (any Error) -> Void)?
    nonisolated private let native: IOSScreenAudioNativeOwner
    nonisolated private let pickerID: ObjectIdentifier
    private var ownsPicker = false
    private var previousConfiguration: SCContentSharingPickerConfiguration?
    private var selection: (@MainActor (Result<Void, Error>) -> Void)?
    private var prepareCalled = false
    private var closed = false

    init(profile: IOSScreenCaptureAudioProfile, maximumTimestampDeviation: CMTime = .zero,
         limits: IOSAudioCaptureIngress.Limits = .init()) throws {
        let ingress = try IOSAudioCaptureIngress(profile: profile, admission: .awaitingReceiver,
            maximumTimestampDeviation: maximumTimestampDeviation, limits: limits)
        self.ingress = ingress
        native = IOSScreenAudioNativeOwner(profile: profile, ingress: ingress)
        pickerID = ObjectIdentifier(SCContentSharingPicker.shared)
        super.init()
        native.setStopHandler { [weak self] error in
            Task { @MainActor in self?.didStop?(error) }
        }
    }

    func prepare(completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard !prepareCalled, !closed else { completion(.failure(IOSAudioCaptureError.alreadyStarted)); return }
        prepareCalled = true
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else { completion(.failure(IOSAudioCaptureError.unavailable)); return }
        guard !picker.isActive else { completion(.failure(IOSAudioCaptureError.busy)); return }
        do { try native.armSelection() } catch { completion(.failure(error)); return }
        previousConfiguration = picker.defaultConfiguration
        var config = SCContentSharingPickerConfiguration()
        config.showsMicrophoneControl = false; config.showsCameraControl = false
        selection = completion; ownsPicker = true
        picker.defaultConfiguration = config; picker.add(self); picker.isActive = true
        picker.present()
    }

    func start(completion: @escaping @MainActor (Result<Void, Error>) -> Void) { native.start(completion: completion) }
    func stop(completion: @escaping @MainActor (Result<Void, Error>) -> Void) { native.stop(completion: completion) }

    func close() throws {
        if closed { return }
        // No public picker-dismissal completion exists. Await its real callback
        // before releasing the shared picker, including after caller timeout.
        guard selection == nil else { throw IOSAudioCaptureError.cleanupPending }
        try native.close()
        if ownsPicker {
            let picker = SCContentSharingPicker.shared
            picker.remove(self); picker.isActive = false
            if let previousConfiguration { picker.defaultConfiguration = previousConfiguration }
            ownsPicker = false; previousConfiguration = nil
        }
        didStop = nil; closed = true
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        guard ObjectIdentifier(picker) == pickerID,
              let result = native.select(filter, updatingExistingStream: stream != nil) else { return }
        Task { @MainActor [weak self] in self?.selected(result) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        guard ObjectIdentifier(picker) == pickerID, native.endSelection() else { return }
        let error: IOSAudioCaptureError = stream == nil ? .cancelled : .unexpectedSelection
        Task { @MainActor [weak self] in self?.selected(.failure(error)) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        guard native.endSelection() else { return }
        Task { @MainActor [weak self] in self?.selected(.failure(error)) }
    }

    private func selected(_ result: Result<Void, Error>) {
        let completion = selection; selection = nil
        completion?(result)
    }
}

/// Audited Objective-C boundary: SCContentFilter is consumed synchronously on
/// its callback stack to create one private SCStream. The filter is never saved
/// or sent to a Task. Every later access to that stream is serialized by this
/// same lock; a native object never escapes it. Only Sendable results may leave
/// withNativeState. This uses the SDK's synchronous withLockUnchecked API because
/// the Objective-C callback input is not Sendable, not an unchecked conformance
/// for that input or a relaxation of the application's Swift concurrency checks.
@available(iOS 27.0, *)
private final class IOSScreenAudioNativeOwner: Sendable {
    private enum Selection { case idle, waiting, resolved }
    private struct State {
        var selection = Selection.idle
        var stream: SCStream?
        var output: IOSScreenAudioOutput?
        var attached = false
        var startAttempted = false
        var startPending = false
        var stopPending = false
        var closed = false
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let stopped = OSAllocatedUnfairLock<(@Sendable (any Error) -> Void)?>(initialState: nil)
    private let profile: IOSScreenCaptureAudioProfile
    private let ingress: IOSAudioCaptureIngress
    private let queue = DispatchQueue(label: "com.skybridge.audio.capture", qos: .userInitiated)

    init(profile: IOSScreenCaptureAudioProfile, ingress: IOSAudioCaptureIngress) {
        self.profile = profile; self.ingress = ingress
    }
    private func withNativeState<R: Sendable>(_ body: (inout State) throws -> R) rethrows -> R {
        try state.withLockUnchecked(body)
    }
    @MainActor func setStopHandler(_ handler: @escaping @Sendable (any Error) -> Void) {
        stopped.withLock { $0 = handler }
    }
    @MainActor func armSelection() throws {
        try withNativeState {
            guard $0.selection == .idle, !$0.closed else { throw IOSAudioCaptureError.alreadyStarted }
            $0.selection = .waiting
        }
    }
    func endSelection() -> Bool {
        withNativeState {
            guard $0.selection == .waiting, !$0.closed else { return false }
            $0.selection = .resolved
            return true
        }
    }
    func select(_ filter: SCContentFilter, updatingExistingStream: Bool) -> Result<Void, Error>? {
        withNativeState { value in
            guard value.selection == .waiting, !value.closed else { return nil }
            value.selection = .resolved
            do {
                guard !updatingExistingStream, !filter.isMicrophoneEnabled, !filter.isCameraEnabled else {
                    throw IOSAudioCaptureError.unexpectedSelection
                }
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.sampleRate = Int(profile.sampleRate); config.channelCount = Int(profile.channels)
                config.excludesCurrentProcessAudio = false
                let output = IOSScreenAudioOutput(ingress: ingress, queue: queue) { [stopped] error in
                    let handler = stopped.withLock { $0 }
                    handler?(error)
                }
                let stream = SCStream(filter: filter, configuration: config, delegate: output)
                value.stream = stream; value.output = output
                try ingress.bind(ObjectIdentifier(stream))
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
                value.attached = true
                return .success(())
            } catch { return .failure(error) }
        }
    }
    @MainActor func start(completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        do {
            try withNativeState { value in
                guard !value.closed, !value.startAttempted, value.attached, let stream = value.stream else {
                    throw IOSAudioCaptureError.invalidState
                }
                value.startAttempted = true; value.startPending = true
                stream.startCapture { [weak self] error in
                    Task { @MainActor in
                        self?.withNativeState { $0.startPending = false }
                        if let error { completion(.failure(error)) } else { completion(.success(())) }
                    }
                }
            }
        } catch { completion(.failure(error)) }
    }
    @MainActor func stop(completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        do {
            try withNativeState { value in
                guard !value.closed, !value.startPending, !value.stopPending, let stream = value.stream else {
                    throw IOSAudioCaptureError.invalidState
                }
                value.stopPending = true
                let finished: @Sendable (Error?) -> Void = { [weak self, queue, ingress] error in
                    // Native stop has settled; finish prior serial callbacks before
                    // closing input and publishing the receipt to the main actor.
                    queue.async {
                        if error == nil { ingress.seal() }
                        Task { @MainActor in
                            self?.withNativeState { $0.stopPending = false }
                            if let error { completion(.failure(error)) } else { completion(.success(())) }
                        }
                    }
                }
                // No start remains in flight; inspect this exact native stream.
                if !stream.isCapturing { finished(nil) }
                else { stream.stopCapture(completionHandler: finished) }
            }
        } catch { completion(.failure(error)) }
    }
    @MainActor func close() throws {
        try withNativeState { value in
            if value.closed { return }
            guard value.selection != .waiting, !value.startPending, !value.stopPending,
                  value.stream?.isCapturing != true else { throw IOSAudioCaptureError.cleanupPending }
            if value.attached {
                guard let stream = value.stream, let output = value.output else { throw IOSAudioCaptureError.invalidState }
                try stream.removeStreamOutput(output, type: .audio)
                value.attached = false
            }
            value.stream = nil; value.output = nil; value.closed = true
        }
        stopped.withLock { $0 = nil }
    }
}

@available(iOS 27.0, *)
private final class IOSScreenAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    private let ingress: IOSAudioCaptureIngress
    private let queue: DispatchQueue
    private let stopped: @Sendable (any Error) -> Void
    init(ingress: IOSAudioCaptureIngress, queue: DispatchQueue, stopped: @escaping @Sendable (any Error) -> Void) {
        self.ingress = ingress; self.queue = queue; self.stopped = stopped
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        ingress.receive(sampleBuffer, from: ObjectIdentifier(stream))
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let owner = ObjectIdentifier(stream)
        guard ingress.belongs(to: owner) else { return }
        queue.async { [ingress, stopped] in
            if ingress.reportNativeStop(error, from: owner) { stopped(error) }
        }
    }
}
#endif

extension IOSAudioCaptureSourceOwner {
    static var systemScreenCaptureAvailability: IOSSystemAudioCaptureAvailability {
        guard #available(iOS 27.0, *) else { return .requiresNewerSystem }
        #if canImport(ScreenCaptureKit) && os(iOS)
        return SCContentSharingPicker.shared.isAvailable ? .available : .systemUnavailable
        #else
        return .systemUnavailable
        #endif
    }

    /// Explicitly unavailable without platform and runtime support. It does not ask
    /// permission or start recording until prepare/start are separately called.
    func makeScreenCapture(profile: IOSScreenCaptureAudioProfile,
                           maximumTimestampDeviation: CMTime = .zero) throws -> IOSAudioCaptureSource {
        guard current == nil || current?.phase == .closed else { throw IOSAudioCaptureError.busy }
        // Recheck at the effect boundary, even if a displayed snapshot was
        // available. The backend checks again before presenting the system UI.
        guard screenCaptureAvailability == .available else { throw IOSAudioCaptureError.unavailable }
        #if canImport(ScreenCaptureKit) && os(iOS)
        if #available(iOS 27.0, *) {
            return try make(backend: IOSScreenAudioCaptureBackend(profile: profile,
                maximumTimestampDeviation: maximumTimestampDeviation))
        }
        #endif
        throw IOSAudioCaptureError.unavailable
    }
}
