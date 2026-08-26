import Combine
import Foundation

/// App-owned navigation coordinator backing `crossnet.navigate`.
///
/// The coordinator is deliberately String-typed over the `crossnet-control/1`
/// wire vocabulary rather than over any UI enum, so the single implementation
/// lives in SkyBridgeCore where it is testable, and each app maps the wire
/// destinations onto its own navigation items — the same shared-core rule the
/// discovery stack follows, with no per-platform fork.
///
/// Honesty model: an operator request only sets `requestedDestination`. The
/// view that owns the real selection observes the request, applies it, and
/// calls ``confirmPresented(_:)`` from its own selection change — including
/// changes the user makes by hand. `presentedDestination` is therefore the
/// UI's own testimony, and ``awaitPresentation(of:timeout:)`` refuses to
/// report a navigation the UI never confirmed (view unmounted, request
/// superseded, destination rejected).
@MainActor
public final class OperatorNavigationCoordinator: ObservableObject {
    public static let shared = OperatorNavigationCoordinator()

    /// The destination an operator asked for, in wire vocabulary.
    @Published public private(set) var requestedDestination: String?
    /// The destination the UI last confirmed actually presenting.
    @Published public private(set) var presentedDestination: String?

    public init() {}

    /// Records an operator navigation request for the owning view to apply.
    public func requestNavigation(to destination: String) {
        requestedDestination = destination
    }

    /// Called by the owning view whenever its real selection changes — for
    /// operator-requested changes and user-made changes alike.
    public func confirmPresented(_ destination: String) {
        presentedDestination = destination
        if requestedDestination == destination {
            requestedDestination = nil
        }
    }

    /// Waits until the UI confirms presenting `destination`.
    ///
    /// Returns `false` on timeout — the fail-closed answer when no view is
    /// mounted to apply the request or the request was superseded.
    public func awaitPresentation(
        of destination: String,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if presentedDestination == destination, requestedDestination == nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return presentedDestination == destination && requestedDestination == nil
    }
}
