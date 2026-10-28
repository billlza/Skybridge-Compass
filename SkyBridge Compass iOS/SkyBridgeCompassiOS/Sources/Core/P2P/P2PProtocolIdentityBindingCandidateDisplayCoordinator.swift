import Foundation

/// Owns only the informational PIB v3 comparison display, never an approval or a trust write.
/// The transcript store remains authoritative; a verified confirm claims this display before
/// the existing approval flow starts. The first short connection ending is expected in PIB v3.
@MainActor
final class P2PProtocolIdentityBindingCandidateDisplayCoordinator {
    struct Candidate: Equatable, Sendable {
        let transactionId: UUID
        let requestHashHex: String
        let candidateHashHex: String
        let sasTranscriptHashHex: String
        let requesterDeviceId: String
        let requesterFingerprint: String
        let verificationCode: String
        let expiresAt: Date
    }

    struct Presentation: Equatable, Sendable {
        let id: UUID
        let candidate: Candidate
    }

    enum Failure: Error, Equatable {
        case busy
        case expired
        case transcriptMismatch
        case noCurrentCandidate
    }

    private enum Phase { case candidate, confirming }
    private var phase: Phase?
    private(set) var current: Presentation?
    private var expiryTask: Task<Void, Never>?

    deinit { expiryTask?.cancel() }

    /// Reserve before sending, without blocking the candidate response on the operator.
    /// A transcript replay cannot recreate a dismissed, failed or already consumed display.
    func prepare(
        _ candidate: Candidate,
        isReplay: Bool,
        hasPendingApproval: Bool,
        now: Date = Date()
    ) throws -> Presentation? {
        guard candidate.expiresAt > now else { throw Failure.expired }
        if let current {
            guard current.candidate.transactionId == candidate.transactionId else { throw Failure.busy }
            guard current.candidate == candidate else { throw Failure.transcriptMismatch }
            return current
        }
        guard !isReplay else { return nil }
        guard !hasPendingApproval else { throw Failure.busy }
        let presentation = Presentation(id: UUID(), candidate: candidate)
        current = presentation
        phase = .candidate
        return presentation
    }

    func displayAfterSend(id: UUID, now: Date = Date()) -> Presentation? {
        guard let current, current.id == id, phase == .candidate,
              current.candidate.expiresAt > now else { return nil }
        return current
    }

    /// Called only after the existing store and requester signature admit the confirm.
    func beginConfirmation(
        transactionId: UUID,
        requestHashHex: String,
        candidateHashHex: String,
        sasTranscriptHashHex: String,
        now: Date = Date()
    ) throws -> Presentation {
        guard let current, phase == .candidate else { throw Failure.noCurrentCandidate }
        guard current.candidate.transactionId == transactionId,
              current.candidate.requestHashHex == requestHashHex,
              current.candidate.candidateHashHex == candidateHashHex,
              current.candidate.sasTranscriptHashHex == sasTranscriptHashHex else {
            throw Failure.transcriptMismatch
        }
        guard current.candidate.expiresAt > now else { throw Failure.expired }
        expiryTask?.cancel()
        expiryTask = nil
        phase = .confirming
        return current
    }

    @discardableResult
    func dismissCandidate(id: UUID) -> Bool {
        guard phase == .candidate else { return false }
        return finish(id: id)
    }

    @discardableResult
    func finish(id: UUID) -> Bool {
        guard current?.id == id else { return false }
        expiryTask?.cancel()
        expiryTask = nil
        current = nil
        phase = nil
        return true
    }

    @discardableResult
    func expire(id: UUID, now: Date = Date()) -> Bool {
        guard let current, current.id == id, phase == .candidate,
              current.candidate.expiresAt <= now else { return false }
        return finish(id: id)
    }

    func scheduleExpiry(
        for presentation: Presentation,
        onExpiry: @escaping @MainActor (UUID) -> Void
    ) {
        guard current?.id == presentation.id, phase == .candidate, expiryTask == nil else { return }
        let delay = max(0, presentation.candidate.expiresAt.timeIntervalSinceNow)
        expiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch is CancellationError {
                return
            } catch {
                // A timer failure cannot leave a candidate display usable indefinitely.
                guard let self, self.dismissCandidate(id: presentation.id) else { return }
                onExpiry(presentation.id)
                return
            }
            guard let self, self.expire(id: presentation.id) else { return }
            onExpiry(presentation.id)
        }
    }
}
