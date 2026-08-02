import Foundation
import OSLog

/// Which physical route actually carried an established session.
///
/// Attribution exists to prevent *fallback absorption*: a relay is always available and always
/// works, so without measurement it silently becomes the only route in use and regressions on
/// the direct paths stop being observable. Recording the route per session makes "we are on the
/// expensive path" a fact instead of an assumption.
@available(macOS 14.0, iOS 17.0, *)
public enum ConnectionTransportRoute: String, Sendable, Codable, CaseIterable {
    /// On-link session established through the LAN stack (Bonjour/QUIC control channel).
    case localDirect
    /// Peer-to-peer session whose selected candidate pair contains no relay candidate.
    ///
    /// This covers both `host` and `srflx` candidates: the current statistics read only
    /// distinguishes "relay vs not relay", so this case must not be reported as evidence of
    /// NAT traversal specifically.
    case peerToPeerDirect
    /// Session carried by TURN or the managed media relay.
    case relayed
    /// No conclusive selected candidate pair yet.
    case unknown

    public var isRelayed: Bool { self == .relayed }

    public var isDirect: Bool {
        switch self {
        case .localDirect, .peerToPeerDirect: true
        case .relayed, .unknown: false
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension ConnectionTransportRoute {
    /// Maps the WebRTC selected-candidate-pair classification onto an attribution route.
    ///
    /// `WebRTCSession.ICETransportPath.direct` only proves "no relay candidate was selected",
    /// so it maps to `peerToPeerDirect` and never to a stronger claim.
    init(_ icePath: WebRTCSession.ICETransportPath) {
        switch icePath {
        case .direct: self = .peerToPeerDirect
        case .relay: self = .relayed
        case .unknown: self = .unknown
        }
    }

    /// Maps a LAN/control-plane route source onto an attribution route.
    ///
    /// Returns `nil` for `webrtc`, which is owned by `CrossNetworkConnectionManager`'s ICE probe
    /// and keyed by session id rather than peer id. Recording it here as well would produce two
    /// rows for one logical connection, one of which could never become conclusive.
    init?(_ routeSource: ConnectionPresenceService.PresenceRouteSource) {
        switch routeSource {
        case .inbound, .outbound, .presence, .compatibility: self = .localDirect
        case .webrtc: return nil
        }
    }
}

/// A single session's route observation.
@available(macOS 14.0, iOS 17.0, *)
public struct ConnectionRouteAttribution: Sendable, Hashable {
    /// Peer id or WebRTC session id. Opaque to this type; only used for de-duplication.
    public let sessionKey: String
    public let route: ConnectionTransportRoute
    public let observedAt: Date

    public init(sessionKey: String, route: ConnectionTransportRoute, observedAt: Date = Date()) {
        self.sessionKey = sessionKey
        self.route = route
        self.observedAt = observedAt
    }
}

/// Records the route each session actually used and raises an observable signal when the
/// relayed share exceeds its budget.
///
/// Deliberately *not* a policy component: it never changes routing. Its only job is to make the
/// route distribution visible so that a degraded direct path is discovered by monitoring rather
/// than by a user report.
@available(macOS 14.0, iOS 17.0, *)
@MainActor
public final class ConnectionRouteAttributionRecorder: ObservableObject {
    public static let shared = ConnectionRouteAttributionRecorder()

    /// Rolling window size for the relayed-share budget. Small enough to react within one
    /// working session, large enough that a single relayed connection is not an alarm.
    public nonisolated static let budgetWindowSize = 20
    /// Minimum conclusive samples before the share is meaningful at all.
    public nonisolated static let budgetMinimumSampleCount = 4
    /// Relayed share above which the deployment is considered to be running on the fallback.
    public nonisolated static let relayedShareWarningThreshold = 0.5

    /// Latest observation per session, for UI and diagnostics.
    @Published public private(set) var attributionsBySessionKey: [String: ConnectionRouteAttribution] = [:]
    /// True while the relayed share is over budget. Latched state, so the warning is logged on
    /// crossing rather than on every sample.
    @Published public private(set) var isOverRelayBudget: Bool = false

    /// Conclusive routes only. `.unknown` carries no information about the distribution and
    /// would otherwise dilute the share and mask a relay-dominated deployment.
    private var recentConclusiveRoutes: [ConnectionTransportRoute] = []
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "RouteAttribution")

    init() {}

    /// Records or refines the route for a session.
    ///
    /// Refinement is expected: a WebRTC session is `.unknown` until the first successful
    /// candidate-pair probe. Only transitions are logged, so a 2 s probe loop does not produce
    /// one log line per tick.
    public func record(sessionKey: String, route: ConnectionTransportRoute) {
        let key = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            logger.error("❌ 路径归因收到空 sessionKey，已丢弃该样本")
            return
        }

        let previous = attributionsBySessionKey[key]?.route
        guard previous != route else { return }

        attributionsBySessionKey[key] = ConnectionRouteAttribution(
            sessionKey: key,
            route: route
        )

        switch route {
        case .relayed:
            // Warning level on purpose: running on the relay is a degradation of the intended
            // path, not a normal operating state, even though the session works.
            logger.warning(
                """
                ⚠️ 会话经由中继建立（非直连）: session=\(Self.redact(key), privacy: .public) \
                previous=\(previous?.rawValue ?? "-", privacy: .public)
                """
            )
        case .localDirect, .peerToPeerDirect:
            logger.info(
                """
                ✅ 会话路径归因: session=\(Self.redact(key), privacy: .public) \
                route=\(route.rawValue, privacy: .public) previous=\(previous?.rawValue ?? "-", privacy: .public)
                """
            )
        case .unknown:
            logger.debug(
                "ℹ️ 会话路径尚未确定: session=\(Self.redact(key), privacy: .public)"
            )
        }

        appendSmokeAttribution(sessionKey: key, route: route)

        guard route != .unknown else { return }
        appendConclusiveSample(route)
    }

    /// Emits a machine-readable attribution line for smoke harnesses.
    ///
    /// This is what makes a "must not be relayed" regression scenario possible: a LAN smoke run
    /// asserts that no `route=relayed` line appears. Without such a scenario the direct paths can
    /// rot unnoticed because the relay keeps every test green.
    private func appendSmokeAttribution(sessionKey: String, route: ConnectionTransportRoute) {
#if DEBUG || SKYBRIDGE_TESTING
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil else { return }
        RemoteControlSmokeStatusWriter.append(
            "route-attribution session=\(Self.redact(sessionKey)) route=\(route.rawValue)"
        )
        guard route.isRelayed,
              ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_DIRECT_ROUTE"] == "1"
        else {
            return
        }
        RemoteControlSmokeStatusWriter.append(
            "route-attribution-violation session=\(Self.redact(sessionKey)) expected=direct actual=relayed"
        )
        logger.error(
            """
            ⛔️ 冒烟场景要求直连，但会话实际走了中继: \
            session=\(Self.redact(sessionKey), privacy: .public)
            """
        )
#endif
    }

    /// Drops a finished session so a long-lived process does not accumulate stale rows.
    /// The rolling budget window intentionally keeps the sample.
    public func forget(sessionKey: String) {
        attributionsBySessionKey.removeValue(
            forKey: sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Share of conclusive samples that were relayed, or `nil` while under the minimum sample
    /// count. `nil` means "not enough evidence", which callers must not treat as "healthy".
    public var relayedShare: Double? {
        Self.relayedShare(in: recentConclusiveRoutes)
    }

    public var conclusiveSampleCount: Int { recentConclusiveRoutes.count }

    private func appendConclusiveSample(_ route: ConnectionTransportRoute) {
        recentConclusiveRoutes.append(route)
        if recentConclusiveRoutes.count > Self.budgetWindowSize {
            recentConclusiveRoutes.removeFirst(
                recentConclusiveRoutes.count - Self.budgetWindowSize
            )
        }

        let overBudget = Self.isOverRelayBudget(recentConclusiveRoutes)
        guard overBudget != isOverRelayBudget else { return }
        isOverRelayBudget = overBudget

        if overBudget {
            let share = Self.relayedShare(in: recentConclusiveRoutes) ?? 0
            logger.error(
                """
                ⛔️ 中继占比超出预算: share=\(Int(share * 100), privacy: .public)% \
                samples=\(self.recentConclusiveRoutes.count, privacy: .public) \
                threshold=\(Int(Self.relayedShareWarningThreshold * 100), privacy: .public)% \
                —— 直连路径可能已退化，请检查而不是继续依赖中继
                """
            )
        } else {
            logger.info("✅ 中继占比已回落至预算内")
        }
    }

    // MARK: - Pure evaluation (unit-testable without a recorder instance)

    public nonisolated static func relayedShare(
        in routes: [ConnectionTransportRoute]
    ) -> Double? {
        let conclusive = routes.filter { $0 != .unknown }
        guard conclusive.count >= budgetMinimumSampleCount else { return nil }
        let relayed = conclusive.filter(\.isRelayed).count
        return Double(relayed) / Double(conclusive.count)
    }

    public nonisolated static func isOverRelayBudget(
        _ routes: [ConnectionTransportRoute]
    ) -> Bool {
        guard let share = relayedShare(in: routes) else { return false }
        return share > relayedShareWarningThreshold
    }

    /// Session keys can embed peer names or addresses. Reuses the existing digest-based session
    /// reference so log lines stay correlatable across samples without exposing the identifier;
    /// `SkyBridgeDiagnosticRedaction.stableIdentifierLabel` returns a constant and therefore
    /// cannot distinguish sessions.
    private nonisolated static func redact(_ sessionKey: String) -> String {
        CrossnetControlSessionRef.redacted(sessionKey)
    }
}
