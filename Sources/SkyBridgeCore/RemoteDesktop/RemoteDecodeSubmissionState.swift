import Foundation

struct RemoteDecodeSubmissionState: Equatable, Sendable {
    private(set) var inFlightCount = 0
    private(set) var isWaitingForSyncFrame = true

    mutating func begin(maximumInFlightCount: Int) -> Bool {
        guard maximumInFlightCount > 0, inFlightCount < maximumInFlightCount else {
            return false
        }
        inFlightCount += 1
        return true
    }

    mutating func complete(succeeded: Bool) {
        inFlightCount = max(0, inFlightCount - 1)
        if !succeeded {
            isWaitingForSyncFrame = true
        }
    }

    mutating func markWaitingForSyncFrame() {
        isWaitingForSyncFrame = true
    }

    mutating func clearWaitingForSyncFrame() {
        isWaitingForSyncFrame = false
    }

    mutating func reset(waitingForSyncFrame: Bool) {
        inFlightCount = 0
        isWaitingForSyncFrame = waitingForSyncFrame
    }
}
