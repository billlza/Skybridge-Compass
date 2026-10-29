import Foundation

final class RemoteControlSecureEnvelopeSendSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionId: String?
    private var counter: UInt64 = 0

    func resetIfSessionChanged(sessionId nextSessionId: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard sessionId != nextSessionId else { return }
        sessionId = nextSessionId
        counter = 0
    }

    func reset(sessionId nextSessionId: String? = nil) {
        lock.lock()
        sessionId = nextSessionId
        counter = 0
        lock.unlock()
    }

    func nextCounter(for keys: SessionKeys) throws -> UInt64 {
        try nextCounter(sessionId: keys.sessionId)
    }

    func nextCounter(sessionId nextSessionId: String) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        if sessionId != nextSessionId {
            sessionId = nextSessionId
            counter = 0
        }

        guard counter < UInt64.max else {
            throw RemoteControlError.handshakeInitializationFailed("secure envelope counter exhausted")
        }
        counter += 1
        return counter
    }
}
