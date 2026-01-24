import SwiftUI
import Combine
import SkyBridgeCore

/// Manages the state of the background canvas (Starry/DeepSpace/Aurora)
/// based on weather activity and user interaction.
///
/// Logic:
/// 1. If Real-time Weather is OFF (nil), background is always visible (Awake).
/// 2. If Real-time Weather is ON:
/// - Default state: Background stays visible; we prefer FPS throttling over hiding to avoid a "gray/dead" UI.
/// - User Interaction (Mouse Move): Background Wakes Up (Fade In).
/// - No Interaction for `idleThreshold`: Background Fades Out (5s) and Sleeps.
@MainActor
public class BackgroundControlManager: ObservableObject {
    public static let shared = BackgroundControlManager()

 // MARK: - Published States

 /// Current opacity of the background canvas (0.0 to 1.0)
    @Published public var backgroundOpacity: Double = 1.0

 /// Whether the background animation loop should be running
    @Published public var isPaused: Bool = false

 /// Current FPS throttling level for power saving
    public enum ThrottleLevel {
        case none       // Full FPS
        case medium     // Reduced FPS (e.g. 30)
        case max        // Minimum FPS (e.g. 15)
    }
    @Published public var throttleLevel: ThrottleLevel = .none

 // MARK: - Configuration

    private let fadeDuration: TimeInterval = 5.0
    private let idleThreshold: TimeInterval = 3.0 // Time before starting fade out or throttling
    private let fadeInDuration: TimeInterval = 0.5
    private let throttleStepDuration: TimeInterval = 5.0 // Time between throttle steps

 // MARK: - Internal State

    private var weatherManager = WeatherIntegrationManager.shared
    private var idleTimer: Timer?
    private var fadeTimer: Timer?
    private var throttleTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private var isWeatherActive: Bool {
        return weatherManager.currentWeather != nil
    }

    private init() {
        setupSubscriptions()
    }

 /// Calculate effective FPS based on current throttling level and base performance mode
    public func getEffectiveFPS(base: Double) -> Double {
        switch throttleLevel {
        case .none:
            return base
        case .medium:
            return min(base, 30.0)
        case .max:
            return min(base, 15.0)
        }
    }

    private func setupSubscriptions() {
 // Monitor Weather Status
        weatherManager.$currentWeather
            .receive(on: RunLoop.main)
            .sink { [weak self] weather in
                self?.handleWeatherChange(hasWeather: weather != nil)
            }
            .store(in: &cancellables)

 // Monitor Mouse Interaction
        NotificationCenter.default.publisher(for: GlobalMouseTracker.mouseMovedNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleInteraction()
            }
            .store(in: &cancellables)
    }

 // MARK: - Logic Handlers

    private func handleWeatherChange(hasWeather: Bool) {
        if !hasWeather {
 // Weather OFF: Always Awake, but check for idle
            wakeUp(immediate: false)
            startIdleTimer()
        } else {
            // Weather ON: keep background visible; use throttling for power saving instead of fading to 0.
            wakeUp(immediate: false)
            startIdleTimer()
        }
    }

    private func handleInteraction() {
 // If sleeping, fading out, or throttled, Wake Up!
        wakeUp()

 // Reset Idle Timer
        startIdleTimer()
    }

    private func startIdleTimer() {
        cancelTimers()

        idleTimer = Timer.scheduledTimer(withTimeInterval: idleThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleIdleTimeout()
            }
        }
    }

    private func handleIdleTimeout() {
        // ✅ Always prefer throttling over fading-out-to-black.
        // Background fading to 0 makes the UI look "灰败/死灰" because only glass layers remain.
        // Throttling keeps the theme background visible while saving power.
        startThrottling()
    }

    private func cancelTimers() {
        idleTimer?.invalidate()
        idleTimer = nil

        throttleTimer?.invalidate()
        throttleTimer = nil
    }

 // MARK: - State Transitions

    private func wakeUp(immediate: Bool = false) {
 // Cancel any pending fade out or throttling
        fadeTimer?.invalidate()
        fadeTimer = nil
        cancelTimers()

 // Reset throttling
        if throttleLevel != .none {
            withAnimation {
                throttleLevel = .none
            }
        }

 // Enable rendering
        if isPaused {
            isPaused = false
        }

 // Animate Opacity to 1.0
        if immediate {
            backgroundOpacity = 1.0
        } else {
            withAnimation(.easeOut(duration: fadeInDuration)) {
                backgroundOpacity = 1.0
            }
        }
    }

    private func startFadeOut() {
 // Animate Opacity to 0.0 over 5 seconds
        withAnimation(.linear(duration: fadeDuration)) {
            backgroundOpacity = 0.0
        }

 // After fade completes, pause rendering to save CPU
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: fadeDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
 // Only pause if we are still effectively transparent (user didn't wake up in middle)
                if self?.backgroundOpacity ?? 1.0 < 0.01 {
                    self?.isPaused = true
                }
            }
        }
    }

    private func startThrottling() {
 // Step 1: Drop to Medium
        withAnimation {
            throttleLevel = .medium
        }

 // Schedule Step 2: Drop to Max (Low FPS)
        throttleTimer = Timer.scheduledTimer(withTimeInterval: throttleStepDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                withAnimation {
                    self?.throttleLevel = .max
                }
            }
        }
    }
}
