import Foundation

/// Synchronous admission boundary for ScreenCaptureKit callbacks owned by one
/// exact WebRTC screen-streaming task. The lock is intentionally held while a
/// callback publishes to its captured sink so `revoke` is a linearization
/// point: once revocation returns, that owner cannot publish another frame or
/// audio chunk.
final class WebRTCScreenCaptureCallbackLease: @unchecked Sendable {
    let ownerToken: UUID

    private let lock = NSLock()
    private var active = true

    init(ownerToken: UUID) {
        self.ownerToken = ownerToken
    }

    @discardableResult
    func withActiveOwner<Result>(
        token expectedOwnerToken: UUID,
        _ operation: () throws -> Result
    ) rethrows -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard active, ownerToken == expectedOwnerToken else {
            return nil
        }
        return try operation()
    }

    func isActive(token expectedOwnerToken: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && ownerToken == expectedOwnerToken
    }

    @discardableResult
    func revoke(token expectedOwnerToken: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active, ownerToken == expectedOwnerToken else {
            return false
        }
        active = false
        return true
    }
}
