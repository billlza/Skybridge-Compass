import Foundation

public struct SkyBridgeMediaReplayWindow: Sendable {
    public let windowSize: UInt64
    private var highestSequence: UInt64?
    private var acceptedSequences: Set<UInt64>

    public init(windowSize: UInt64 = 1_024) {
        self.windowSize = max(1, windowSize)
        self.highestSequence = nil
        self.acceptedSequences = []
    }

    public mutating func accept(sequence: UInt64) -> Bool {
        if let highestSequence {
            if sequence > highestSequence {
                self.highestSequence = sequence
            } else if highestSequence - sequence >= windowSize {
                return false
            }
        } else {
            highestSequence = sequence
        }
        if acceptedSequences.contains(sequence) {
            return false
        }
        acceptedSequences.insert(sequence)
        prune()
        return true
    }

    private mutating func prune() {
        guard let highestSequence else { return }
        let floor = highestSequence >= windowSize ? highestSequence - windowSize + 1 : 0
        if acceptedSequences.count <= Int(windowSize * 2) {
            acceptedSequences = acceptedSequences.filter { $0 >= floor }
        } else {
            acceptedSequences = Set(acceptedSequences.filter { $0 >= floor })
        }
    }
}
