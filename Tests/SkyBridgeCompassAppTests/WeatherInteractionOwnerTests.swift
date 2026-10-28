import Combine
import XCTest
@testable import SkyBridgeCompassApp

@MainActor
final class WeatherInteractionOwnerTests: XCTestCase {
    func testWeatherPublicationsReachRendererWithoutInvalidatingScreenOwner() async {
        let owner = WeatherInteractionOwner()
        // Let the controller's existing startup task run, then stop its clock so
        // this regression exercises a deterministic real controller publication.
        await Task.yield()
        owner.manager.stop()

        var screenInvalidations = 0
        var rendererInvalidations = 0
        let screenSubscription = owner.objectWillChange.sink { screenInvalidations += 1 }
        let rendererSubscription = owner.manager.objectWillChange.sink { rendererInvalidations += 1 }

        withExtendedLifetime((screenSubscription, rendererSubscription)) {
            owner.manager.resetDisperseState()
        }

        XCTAssertGreaterThan(rendererInvalidations, 0, "The weather renderer must still receive interaction updates.")
        XCTAssertEqual(screenInvalidations, 0, "Frame publications must not rebuild the login form or navigation tree.")
        XCTAssertEqual(owner.manager.globalOpacity, 1)
        XCTAssertEqual(owner.manager.disperseEnergy, 0)
    }
}
