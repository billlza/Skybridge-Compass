import Combine
import Foundation
import Testing
@testable import SkyBridgeWeatherRendering

struct WeatherFrameRateCounterTests {
    @Test(arguments: [15, 30, 60])
    func countsOnlyPresentedFramesOverRealElapsedTime(fps: Int) {
        let counter = PresentedFrameRateCounter(startingAt: 100)
        for frame in 1...fps {
            counter.recordPresentation(at: 100 + Double(frame) / Double(fps))
            counter.recordPresentation(at: 0) // A submitted but dropped drawable.
        }
        #expect(counter.sample(at: 100.99) == nil)
        #expect(counter.sample(at: 101) == fps)
        #expect(counter.sample(at: 102) == 0, "An active renderer that presents nothing must not retain its old FPS")
    }

    @Test func delayedSamplingUsesElapsedTimeAndRejectsInvalidPresentationTimes() {
        let counter = PresentedFrameRateCounter(startingAt: 100)
        for frame in 1...60 { counter.recordPresentation(at: 100 + Double(frame) / 30) }
        for invalid in [Double.nan, .infinity, -.infinity, -1, 0] {
            counter.recordPresentation(at: invalid)
        }
        #expect(counter.sample(at: .nan) == nil)
        #expect(counter.sample(at: 99) == nil)
        #expect(counter.sample(at: 102) == 30)
        #expect(counter.sample(at: 102) == nil)
    }

    @Test func concurrentPresentationCallbacksDoNotLoseFrames() async {
        let counter = PresentedFrameRateCounter(startingAt: 100)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<15 { counter.recordPresentation(at: 100.5) }
                }
            }
        }
        #expect(counter.sample(at: 101) == 60)
    }
}

@MainActor
struct WeatherFrameRateMonitorTests {
    @Test func pauseAndDetachClearNumbersWithoutWaitingForAnotherFrame() async {
        let monitor = WeatherFrameRateMonitor()
        let source = monitor.beginSource(isAnimating: true)
        await settle()
        #expect(monitor.reading == .measuring)
        monitor.update(.framesPerSecond(30), source: source)
        await settle()
        #expect(monitor.reading == .framesPerSecond(30))
        monitor.update(.paused, source: source)
        await settle()
        #expect(monitor.reading == .paused)
        monitor.endSource(source)
        await settle()
        #expect(monitor.reading == .unavailable)
    }

    @Test func retiringSourceCannotOverwriteOrDetachReplacement() async {
        let monitor = WeatherFrameRateMonitor()
        let old = monitor.beginSource(isAnimating: true)
        monitor.update(.framesPerSecond(60), source: old)
        let current = monitor.beginSource(isAnimating: false)
        monitor.update(.framesPerSecond(120), source: old)
        monitor.update(.measuring, source: old)
        monitor.endSource(old)
        await settle()
        #expect(monitor.reading == .paused)
        monitor.update(.framesPerSecond(30), source: current)
        await settle()
        #expect(monitor.reading == .framesPerSecond(30))
    }

    @Test func publicationsCoalesceAndIdenticalReadingsDoNotInvalidateViews() async {
        let monitor = WeatherFrameRateMonitor()
        var readings: [WeatherFrameRateReading] = []
        let subscription = monitor.$reading.sink { readings.append($0) }
        let source = monitor.beginSource(isAnimating: true)
        monitor.update(.framesPerSecond(30), source: source)
        await settle()
        for _ in 0..<120 { monitor.update(.framesPerSecond(30), source: source) }
        await settle()
        #expect(readings == [.unavailable, .framesPerSecond(30)])
        withExtendedLifetime(subscription) {}
    }

    private func settle() async {
        // The monitor defers publication out of representable view updates.
        await Task.yield()
        await Task.yield()
    }
}
