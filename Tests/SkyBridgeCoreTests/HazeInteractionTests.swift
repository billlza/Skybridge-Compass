import Foundation
import Testing
@testable import SkyBridgeCore

@MainActor
struct HazeInteractionTests {
    @Test func mouseWaveStillDispersesRecoversAndResets() async throws {
        let manager = InteractiveClearManager()
        defer { manager.stop() }
        let startupDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !manager.isStarted && ContinuousClock.now < startupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(manager.isStarted)
        manager.resetDisperseState()

        let now = Date().timeIntervalSince1970
        manager.mouseTracker.trail = (0..<4).map { index in
            MouseTrailPoint(position: CGPoint(x: CGFloat(index) * 120, y: 200),
                            timestamp: now - 0.12 + Double(index) * 0.03, velocity: 2000)
        }
        manager.handleMouseMove(CGPoint(x: 480, y: 200))
        #expect(manager.disperseEnergy == 35)
        #expect(!manager.clearZones.isEmpty)

        let fadeDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while manager.globalOpacity >= 0.98 && ContinuousClock.now < fadeDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(manager.globalOpacity < 0.98)
        #expect(manager.disperseEnergy > 0 && manager.disperseEnergy < 35,
                "The original update loop must recover energy after the mouse stops")

        manager.resetDisperseState()
        #expect(manager.globalOpacity == 1)
        #expect(manager.disperseEnergy == 0)
        #expect(manager.clearZones.isEmpty)
    }
}
