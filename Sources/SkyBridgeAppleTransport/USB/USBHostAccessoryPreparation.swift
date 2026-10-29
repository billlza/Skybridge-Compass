#if os(macOS)
import CSkyBridgeUSBHost
import Foundation
import os

public enum USBHostAccessoryError: Error, Equatable, Sendable { case invalidNonce, missingAuthorizationFailure, profileMismatch }

public struct USBHostAccessoryReceipt: Sendable {
    public let deviceRegistryID: UInt64
    public let operationStarted: Bool
    public let protocolVersion: UInt16
    /// Requested application framing, not Android's AOA protocol version or an authentication result.
    public let requestedLinkProfile: USBHostMultiplexConnection.LinkProfile?
    public let identificationAttempted: UInt8
    public let identificationCompleted: UInt8
    public let startRequested: Bool
    public let startCompletionConfirmed: Bool
    public let referencesReleased: Bool
    public let operationFailure: USBHostFailure?
    public let cleanupFailure: USBHostFailure?
}

public struct USBHostAccessoryPreparationFailure: Error, Sendable {
    public let receipt: USBHostAccessoryReceipt
    /// Includes captured attempt revocation or cancellation; no error is made into
    /// a successful start merely because request 53 happened to finish first.
    public let cause: (any Error)?
}

protocol USBHostAccessoryDriver: Sendable {
    /// One dedicated worker owns every native call and cleanup. On unconfirmed
    /// cleanup this driver must retain its handles; cancellation never touches them.
    func run(registryID: UInt64, mode: USBHostAccessoryPreparation.Mode,
             authorize: @escaping @Sendable () -> Bool) -> USBHostAccessoryReceipt
}

/// One selected physical generation. Query never changes mode; start requests
/// the Android product accessory with a fresh nonce. The caller retains this
/// owner until closeAndAwait confirms worker exit and native reference release.
/// Even a completed start is only a request receipt: re-enumeration, USB data,
/// signed MAIN identity, account grants and playback are separate boundaries.
public final class USBHostAccessoryPreparation: Sendable {
    public enum Mode: Sendable {
        case query
        case start(attachmentNonce: UUID, linkProfile: USBHostMultiplexConnection.LinkProfile = .rawYamuxV1)
        var attachmentNonce: UUID? { if case .start(let nonce, _) = self { nonce } else { nil } }
        var linkProfile: USBHostMultiplexConnection.LinkProfile? {
            if case .start(_, let profile) = self { profile } else { nil }
        }
        var nativeProfile: SBUSBLinkProfile {
            switch linkProfile {
            case .none: SB_USB_LINK_QUERY_ONLY
            case .rawYamuxV1: SB_USB_LINK_RAW_YAMUX_V1
            case .epochV2: SB_USB_LINK_EPOCH_V2
            }
        }
    }
    private let core: USBAccessoryWorker
    private let worker = USBHostThread()

    public convenience init(deviceRegistryID: UInt64, mode: Mode,
                            requireAttemptCurrent: @escaping @Sendable () throws -> Void) throws {
        guard deviceRegistryID != 0 else { throw USBHostByteError.invalidRegistryEntry }
        if let nonce = mode.attachmentNonce, nonce == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) {
            throw USBHostAccessoryError.invalidNonce
        }
        self.init(deviceRegistryID: deviceRegistryID, mode: mode, authority: requireAttemptCurrent,
                  factory: { try USBAccessoryNativeDriver() })
    }

    init(deviceRegistryID: UInt64, mode: Mode, authority: @escaping @Sendable () throws -> Void,
         factory: @escaping @Sendable () throws -> any USBHostAccessoryDriver) {
        core = USBAccessoryWorker(registryID: deviceRegistryID, mode: mode, authority: authority, factory: factory)
    }
    deinit { core.cancel() }
    public var receipt: USBHostAccessoryReceipt? { core.receipt }
    public var workerExited: Bool { core.hasStarted ? worker.isFinished : true }

    public func run() async throws -> USBHostAccessoryReceipt {
        defer { withExtendedLifetime(self) {} }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard core.begin(continuation) else { return }
                let core = core
                worker.start(name: "SkyBridge USB accessory startup") { core.perform() }
            }
        } onCancel: { [core] in core.cancel() }
    }

    /// Bounded, in-memory retirement. It cannot block behind an OS acquisition,
    /// request or release. The native worker reports the actual outcome afterward.
    public func cancel() { core.cancel() }

    public func closeAndAwait(timeout: Duration = .seconds(2)) async throws {
        defer { withExtendedLifetime(self) {} }
        guard timeout > .zero && timeout <= .seconds(60) else { throw USBHostByteError.invalidTimeout }
        core.cancel()
        let core = core, worker = worker
        let observer = Task.detached {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while core.hasStarted && !worker.isFinished {
                guard ContinuousClock.now < deadline else { throw USBHostByteError.cleanupUnconfirmed }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard !core.hasStarted || core.receipt?.referencesReleased == true else { throw USBHostByteError.cleanupUnconfirmed }
            if let failure = core.receipt?.cleanupFailure { throw failure }
        }
        try await observer.value
    }
}

private final class USBAccessoryWorker: Sendable {
    private struct State: Sendable {
        var started = false
        var cancelled = false
        var authorityFailure: (any Error)?
        var receipt: USBHostAccessoryReceipt?
        var continuation: CheckedContinuation<USBHostAccessoryReceipt, any Error>?
        // Keep unconfirmed native resources owned after the worker returns.
        var driver: (any USBHostAccessoryDriver)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let registryID: UInt64
    private let mode: USBHostAccessoryPreparation.Mode
    private let authority: @Sendable () throws -> Void
    private let factory: @Sendable () throws -> any USBHostAccessoryDriver
    init(registryID: UInt64, mode: USBHostAccessoryPreparation.Mode,
         authority: @escaping @Sendable () throws -> Void, factory: @escaping @Sendable () throws -> any USBHostAccessoryDriver) {
        self.registryID = registryID; self.mode = mode; self.authority = authority; self.factory = factory
    }
    var hasStarted: Bool { state.withLock { $0.started } }
    var receipt: USBHostAccessoryReceipt? { state.withLock { $0.receipt } }
    func cancel() { state.withLock { if $0.receipt == nil { $0.cancelled = true } } }
    func begin(_ continuation: CheckedContinuation<USBHostAccessoryReceipt, any Error>) -> Bool {
        let failure: (any Error)? = state.withLock { value in
            if value.started { return USBHostByteError.alreadyStarted }
            if value.cancelled { return CancellationError() }
            value.started = true; value.continuation = continuation; return nil
        }
        if let failure { continuation.resume(throwing: failure); return false }
        return true
    }
    private func authorize() -> Bool {
        do {
            if state.withLock({ $0.cancelled }) { throw CancellationError() }
            try authority()
            if state.withLock({ $0.cancelled }) { throw CancellationError() }
            return true
        } catch {
            state.withLock { if $0.authorityFailure == nil { $0.authorityFailure = error } }
            return false
        }
    }
    func perform() {
        let receipt: USBHostAccessoryReceipt
        do {
            guard authorize() else { throw state.withLock { $0.authorityFailure ?? USBHostAccessoryError.missingAuthorizationFailure } }
            let driver = try factory()
            state.withLock { $0.driver = driver }
            receipt = driver.run(registryID: registryID, mode: mode, authorize: { [self] in authorize() })
            if receipt.requestedLinkProfile != mode.linkProfile {
                state.withLock { if $0.authorityFailure == nil { $0.authorityFailure = USBHostAccessoryError.profileMismatch } }
            }
        } catch {
            state.withLock { if $0.authorityFailure == nil { $0.authorityFailure = error } }
            receipt = USBHostAccessoryReceipt(deviceRegistryID: registryID, operationStarted: false, protocolVersion: 0,
                requestedLinkProfile: mode.linkProfile,
                identificationAttempted: 0, identificationCompleted: 0, startRequested: false, startCompletionConfirmed: false,
                referencesReleased: true, operationFailure: nil, cleanupFailure: nil)
        }
        let (continuation, failure) = state.withLock { value in
            if value.cancelled && value.authorityFailure == nil { value.authorityFailure = CancellationError() }
            value.receipt = receipt
            if receipt.referencesReleased { value.driver = nil }
            let continuation = value.continuation; value.continuation = nil
            return (continuation, value.authorityFailure)
        }
        if failure != nil || receipt.operationFailure != nil || receipt.cleanupFailure != nil || !receipt.referencesReleased {
            continuation?.resume(throwing: USBHostAccessoryPreparationFailure(receipt: receipt, cause: failure))
        } else { continuation?.resume(returning: receipt) }
    }
}

private final class USBAccessoryAuthorization: Sendable {
    let check: @Sendable () -> Bool
    init(_ check: @escaping @Sendable () -> Bool) { self.check = check }
}

private final class USBAccessoryNativeDriver: USBHostAccessoryDriver {
    private let pointer: OSAllocatedUnfairLock<OpaquePointer?>
    init() throws {
        var result = SBUSBResult()
        guard let handle = SBAOACreate(&result), result.status == SB_USB_OK else { throw USBHostFailure(result) }
        pointer = OSAllocatedUnfairLock(uncheckedState: handle)
    }
    func run(registryID: UInt64, mode: USBHostAccessoryPreparation.Mode,
             authorize: @escaping @Sendable () -> Bool) -> USBHostAccessoryReceipt {
        // Only the dedicated worker enters this lock. Cancellation touches the Swift
        // attempt state instead, so an OS release cannot block logical retirement.
        pointer.withLock { handle in
            guard let current = handle else {
                return USBHostAccessoryReceipt(deviceRegistryID: registryID, operationStarted: false, protocolVersion: 0,
                    requestedLinkProfile: mode.linkProfile,
                    identificationAttempted: 0, identificationCompleted: 0, startRequested: false, startCompletionConfirmed: false,
                    referencesReleased: true, operationFailure: USBHostFailure(SBUSBResult(status: SB_USB_ALREADY_STARTED,
                        phase: SB_USB_PHASE_ACCESSORY_QUERY, domain: SB_USB_DOMAIN_NONE, nativeCode: 0, bytesTransferred: 0, byteCountKnown: false)), cleanupFailure: nil)
            }
            let authorization = USBAccessoryAuthorization(authorize)
            let context = Unmanaged.passUnretained(authorization).toOpaque()
            let check: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { context in
                guard let context else { return false }
                return Unmanaged<USBAccessoryAuthorization>.fromOpaque(context).takeUnretainedValue().check()
            }
            let result: SBUSBResult
            if let nonce = mode.attachmentNonce {
                result = nonce.uuidString.lowercased().withCString {
                    SBAOARunWithProfile(current, registryID, $0, 36, mode.nativeProfile, check, context)
                }
            } else { result = SBAOARunWithProfile(current, registryID, nil, 0, mode.nativeProfile, check, context) }
            withExtendedLifetime(authorization) {}
            let close = SBAOATryClose(current)
            let snapshot = SBAOAGetSnapshot(current)
            var cleanup = close
            if snapshot.ownedReferencesReleased {
                let destroyed = SBAOADestroy(&handle)
                if destroyed.status != SB_USB_OK { cleanup = destroyed }
            }
            return USBHostAccessoryReceipt(deviceRegistryID: registryID, operationStarted: snapshot.started,
                protocolVersion: snapshot.protocolVersion, requestedLinkProfile: mode.linkProfile,
                identificationAttempted: snapshot.identificationAttempted,
                identificationCompleted: snapshot.identificationCompleted, startRequested: snapshot.startRequested,
                startCompletionConfirmed: snapshot.startCompletionConfirmed, referencesReleased: handle == nil,
                operationFailure: result.status != SB_USB_OK ? USBHostFailure(result) :
                    snapshot.requestedLinkProfile == mode.nativeProfile ? nil : USBHostFailure(SBUSBResult(
                        status: SB_USB_BAD_RESPONSE, phase: SB_USB_PHASE_ACCESSORY_IDENTIFICATION,
                        domain: SB_USB_DOMAIN_NONE, nativeCode: 0, bytesTransferred: 0, byteCountKnown: false)),
                cleanupFailure: cleanup.status == SB_USB_OK ? nil : USBHostFailure(cleanup))
        }
    }
}
#endif
