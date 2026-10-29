import Combine
import SkyBridgeCore

/// Retains the interaction controller for a screen without observing its frame updates.
/// Weather views observe the controller directly; typing, navigation and layout must
/// not be invalidated by its opacity/particle publications.
@MainActor
final class WeatherInteractionOwner: ObservableObject {
    let manager = InteractiveClearManager()
}
