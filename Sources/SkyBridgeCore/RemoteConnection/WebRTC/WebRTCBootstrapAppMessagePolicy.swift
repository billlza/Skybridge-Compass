enum WebRTCBootstrapAppMessagePolicy {
    enum Admission: Equatable {
        case continueBootstrapSecurityFlow
        case consumeLivenessLocally
        case dropUntilPQCRekey
    }

    static func admission(for message: AppMessage) -> Admission {
        switch message {
        case .pairingIdentityExchange,
             .kemRefreshRequest,
             .signedKEMRefresh,
             .kemRefreshFailure,
             .protocolIdentityBindingRequest,
             .signedProtocolIdentityBinding,
             .protocolIdentityBindingConfirm,
             .signedProtocolIdentityBindingFinalAck:
            return .continueBootstrapSecurityFlow
        case .heartbeat,
             .ping,
             .pong,
             .peerDisconnecting:
            return .consumeLivenessLocally
        case .usbPeerDiscoveryRequest, .usbPeerDiscoveryResponse, .handshakeConfigurationRequest, .handshakeConfigurationResponse, .clipboard, .textMessage, .textMessageReceipt, .authenticatedRouteBinding:
            return .dropUntilPQCRekey
        }
    }
}
