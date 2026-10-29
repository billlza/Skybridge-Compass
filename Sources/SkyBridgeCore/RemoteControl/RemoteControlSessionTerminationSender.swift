#if os(macOS)
import Foundation
import Network
import SkyBridgeProtocolCore

/// Uses only the retired peer's existing authenticated pump; it never looks up a replacement.
enum RemoteControlSessionTerminationSender {
    static func send(reason: RemoteDesktopSessionTermination.Reason, over connection: NWConnection,
                     pump: RemoteControlOutboundFramePump, deadlineAt: ContinuousClock.Instant) async throws {
        guard ContinuousClock.now < deadlineAt else { connection.cancel(); throw CancellationError() }
        let deadline = Task {
            do { try await ContinuousClock().sleep(until: deadlineAt); connection.cancel() }
            catch is CancellationError { return }
            catch { connection.cancel() }
        }
        defer { deadline.cancel() }
        await pump.close()
        guard ContinuousClock.now < deadlineAt else { connection.cancel(); throw CancellationError() }
        // Receipt comes from the writer, after any already-sent ACK commits.
        guard let termination = try await pump.committedSessionTermination(reason: reason) else { return }
        guard ContinuousClock.now < deadlineAt else { connection.cancel(); throw CancellationError() }
        try await pump.sendControlPayload(termination, type: .sessionEnded)
        guard ContinuousClock.now < deadlineAt else { throw CancellationError() }
    }
}
#endif
