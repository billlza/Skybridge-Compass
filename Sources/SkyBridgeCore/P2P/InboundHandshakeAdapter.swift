import Foundation

public struct InboundSOABinding: Sendable {
    public let expectedRemotePeerId: Data?
    public let pairKey: Data?
    public let usedAuthenticatedInitiator: Bool

    public init(expectedRemotePeerId: Data?, pairKey: Data?, usedAuthenticatedInitiator: Bool) {
        self.expectedRemotePeerId = expectedRemotePeerId
        self.pairKey = pairKey
        self.usedAuthenticatedInitiator = usedAuthenticatedInitiator
    }
}

public enum InboundHandshakeAdapter {
    public static func bindSOAState(
        from messageA: HandshakeMessageA,
        localPeerId: Data
    ) -> InboundSOABinding {
        guard let soa = messageA.soaExtension else {
            return InboundSOABinding(
                expectedRemotePeerId: nil,
                pairKey: nil,
                usedAuthenticatedInitiator: false
            )
        }
        let pairKey = PeerSessionArbiter.pairKey(
            localPeerId: localPeerId,
            remotePeerId: soa.initiatorPeerId
        )
        return InboundSOABinding(
            expectedRemotePeerId: soa.initiatorPeerId,
            pairKey: pairKey,
            usedAuthenticatedInitiator: true
        )
    }
}
