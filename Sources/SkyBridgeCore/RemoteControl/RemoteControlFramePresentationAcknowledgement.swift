import Foundation
import SkyBridgeProtocolCore

/// Bounded host-side correlation for product renderer presentation receipts.
/// Entries are created only after Network.framework reports the exact frame as
/// content-processed, and are scoped to one accepted stream transaction.
struct RemoteControlFramePresentationAcknowledgementTracker: Sendable {
    // Covers the pump's bounded content-processed backlog plus normal LAN
    // decode/render latency while remaining a small, fixed memory surface.
    static let maximumPendingFrameCount = 32

    private var transaction: RemoteDesktopStreamConfigurationTransaction?
    private var negotiatedVersion: Int?
    private var pendingFrames: [RemoteControlSentFrameMetadata] = []
    private var earlyAcknowledgements: [RemoteDesktopFramePresentationAcknowledgement] = []
    private var completed = false

    var pendingFrameCount: Int { pendingFrames.count }
    var earlyAcknowledgementCount: Int { earlyAcknowledgements.count }

    mutating func begin(
        transaction: RemoteDesktopStreamConfigurationTransaction,
        negotiatedVersion: Int?
    ) {
        self.transaction = transaction
        self.negotiatedVersion = negotiatedVersion
        pendingFrames.removeAll(keepingCapacity: true)
        earlyAcknowledgements.removeAll(keepingCapacity: true)
        completed = false
    }

    mutating func recordSentFrame(
        _ metadata: RemoteControlSentFrameMetadata
    ) -> RemoteDesktopFramePresentationAcknowledgement? {
        guard !completed,
              negotiatedVersion == RemoteDesktopFramePresentationAcknowledgement.currentVersion,
              transaction == metadata.streamTransaction,
              metadata.sequenceNumber > 0,
              metadata.bytes > 0,
              metadata.width > 0,
              metadata.height > 0 else {
            return nil
        }
        if let existing = pendingFrames.firstIndex(where: {
            $0.sequenceNumber == metadata.sequenceNumber
                && $0.streamTransaction == metadata.streamTransaction
        }) {
            pendingFrames[existing] = metadata
        } else {
            pendingFrames.append(metadata)
            if pendingFrames.count > Self.maximumPendingFrameCount {
                pendingFrames.removeFirst(
                    pendingFrames.count - Self.maximumPendingFrameCount
                )
            }
        }
        guard let earlyIndex = earlyAcknowledgements.firstIndex(where: {
            $0.sequenceNumber == metadata.sequenceNumber
                && $0.streamTransaction == metadata.streamTransaction
        }) else {
            return nil
        }
        return earlyAcknowledgements.remove(at: earlyIndex)
    }

    mutating func recordAcknowledgement(
        for acknowledgement: RemoteDesktopFramePresentationAcknowledgement
    ) -> RemoteControlSentFrameMetadata? {
        guard !completed,
              acknowledgement.version
                == RemoteDesktopFramePresentationAcknowledgement.currentVersion,
              negotiatedVersion == acknowledgement.version,
              transaction == acknowledgement.streamTransaction else {
            return nil
        }
        if let matchingFrame = pendingFrames.first(where: {
            $0.sequenceNumber == acknowledgement.sequenceNumber
                && $0.streamTransaction == acknowledgement.streamTransaction
        }) {
            return matchingFrame
        }
        guard !earlyAcknowledgements.contains(acknowledgement) else { return nil }
        earlyAcknowledgements.append(acknowledgement)
        if earlyAcknowledgements.count > Self.maximumPendingFrameCount {
            earlyAcknowledgements.removeFirst(
                earlyAcknowledgements.count - Self.maximumPendingFrameCount
            )
        }
        return nil
    }

    func matchingFrame(
        for acknowledgement: RemoteDesktopFramePresentationAcknowledgement
    ) -> RemoteControlSentFrameMetadata? {
        guard !completed,
              acknowledgement.version
                == RemoteDesktopFramePresentationAcknowledgement.currentVersion,
              negotiatedVersion == acknowledgement.version,
              transaction == acknowledgement.streamTransaction else {
            return nil
        }
        return pendingFrames.first {
            $0.sequenceNumber == acknowledgement.sequenceNumber
                && $0.streamTransaction == acknowledgement.streamTransaction
        }
    }

    mutating func complete(
        acknowledgement: RemoteDesktopFramePresentationAcknowledgement
    ) -> Bool {
        guard matchingFrame(for: acknowledgement) != nil else { return false }
        completed = true
        pendingFrames.removeAll(keepingCapacity: false)
        earlyAcknowledgements.removeAll(keepingCapacity: false)
        return true
    }

    mutating func reset() {
        transaction = nil
        negotiatedVersion = nil
        pendingFrames.removeAll(keepingCapacity: false)
        earlyAcknowledgements.removeAll(keepingCapacity: false)
        completed = false
    }
}
