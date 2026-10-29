import Foundation
@testable import SkyBridgeCore

enum PolicyDecisionTestVectors {
    static let localProviderAvailability: [(apple: Bool, liboqs: Bool)] = [
        (apple: true, liboqs: true),
        (apple: true, liboqs: false),
        (apple: false, liboqs: true),
        (apple: false, liboqs: false)
    ]

    static func allInputs() -> [PolicyDecisionInput] {
        var out: [PolicyDecisionInput] = []
        for policy in PolicyMode.allCases {
            for peerVisibility in PeerCapabilityVisibility.allCases {
                for availability in localProviderAvailability {
                    for compileFlag in [false, true] {
                        for trust in TrustStoreState.allCases {
                            for lifecycle in BootstrapRekeyState.allCases {
                                out.append(
                                    PolicyDecisionInput(
                                        policy: policy,
                                        peer_capability_visibility: peerVisibility,
                                        local_has_apple_provider: availability.apple,
                                        local_has_liboqs_provider: availability.liboqs,
                                        compile_time_has_apple_pqc_sdk: compileFlag,
                                        trust_store_state: trust,
                                        bootstrap_rekey_state: lifecycle
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }
        return out
    }
}
