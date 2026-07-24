import Foundation

struct H264ParameterSetPair: Equatable, Sendable {
    let sequenceParameterSet: Data
    let pictureParameterSet: Data
}

/// Stages H.264 parameter-set changes until an IDR arrives with an explicitly complete pair.
/// This prevents a new SPS from being combined with a stale PPS during resolution/profile changes.
struct H264ParameterSetTransitionState: Sendable {
    private(set) var activePair: H264ParameterSetPair?
    private(set) var pendingSequenceParameterSet: Data?
    private(set) var pendingPictureParameterSet: Data?

    mutating func stage(
        sequenceParameterSet: Data?,
        pictureParameterSet: Data?
    ) {
        if let sequenceParameterSet,
           sequenceParameterSet != activePair?.sequenceParameterSet {
            pendingSequenceParameterSet = sequenceParameterSet
        }
        if let pictureParameterSet,
           pictureParameterSet != activePair?.pictureParameterSet {
            pendingPictureParameterSet = pictureParameterSet
        }
    }

    func candidateForIDR(
        carriesSequenceParameterSet: Bool,
        carriesPictureParameterSet: Bool,
        containsIDR: Bool
    ) -> H264ParameterSetPair? {
        guard containsIDR else { return nil }
        let accessUnitCarriesCompletePair = carriesSequenceParameterSet
            && carriesPictureParameterSet
        let hasCompleteStagedPair = pendingSequenceParameterSet != nil
            && pendingPictureParameterSet != nil
        guard accessUnitCarriesCompletePair || hasCompleteStagedPair,
              let sequenceParameterSet = pendingSequenceParameterSet
                ?? activePair?.sequenceParameterSet,
              let pictureParameterSet = pendingPictureParameterSet
                ?? activePair?.pictureParameterSet else {
            return nil
        }
        let candidate = H264ParameterSetPair(
            sequenceParameterSet: sequenceParameterSet,
            pictureParameterSet: pictureParameterSet
        )
        return candidate == activePair ? nil : candidate
    }

    mutating func commit(_ pair: H264ParameterSetPair) {
        activePair = pair
        pendingSequenceParameterSet = nil
        pendingPictureParameterSet = nil
    }

    mutating func reset() {
        activePair = nil
        pendingSequenceParameterSet = nil
        pendingPictureParameterSet = nil
    }
}
