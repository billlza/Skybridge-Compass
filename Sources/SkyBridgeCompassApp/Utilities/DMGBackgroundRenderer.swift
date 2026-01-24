import AppKit
import SwiftUI
import SkyBridgeCore

@MainActor
struct DMGBackgroundRenderConfig {
    let outputURL: URL
    let size: CGSize
    let delay: TimeInterval

    static func fromProcessInfo() -> DMGBackgroundRenderConfig? {
        let env = ProcessInfo.processInfo.environment
        guard let outputPath = env["SKYBRIDGE_DMG_BG_PATH"], !outputPath.isEmpty else {
            return nil
        }

        let sizeString = env["SKYBRIDGE_DMG_BG_SIZE"] ?? "2000x1200"
        let parts = sizeString.lowercased().split(separator: "x")
        let width = parts.first.flatMap { Double($0) } ?? 2000
        let height = parts.dropFirst().first.flatMap { Double($0) } ?? 1200
        let delay = Double(env["SKYBRIDGE_DMG_BG_DELAY"] ?? "") ?? 1.2

        return DMGBackgroundRenderConfig(
            outputURL: URL(fileURLWithPath: outputPath),
            size: CGSize(width: width, height: height),
            delay: delay
        )
    }
}

@MainActor
enum DMGBackgroundRenderer {
    static func renderAndTerminate(config: DMGBackgroundRenderConfig) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)

            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: config.size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .statusBar
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))

            let clearManager = InteractiveClearManager()
            let view = DashboardBackgroundView(hazeClearManager: clearManager)
                .environmentObject(ThemeConfiguration.shared)
                .environmentObject(WeatherIntegrationManager.shared)
                .environmentObject(WeatherEffectsSettings.shared)
                .environmentObject(SettingsManager.shared)
                .frame(width: config.size.width, height: config.size.height)
                .ignoresSafeArea()

            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = NSRect(origin: .zero, size: config.size)
            window.contentView = hostingView
            window.orderFrontRegardless()
            window.displayIfNeeded()
            hostingView.layoutSubtreeIfNeeded()

            BackgroundControlManager.shared.backgroundOpacity = 1.0
            BackgroundControlManager.shared.isPaused = false

            DispatchQueue.main.asyncAfter(deadline: .now() + config.delay) {
                // Render the view directly into a bitmap (faster, deterministic, and avoids deprecated window capture APIs).
                let bounds = hostingView.bounds
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(config.size.width),
                    pixelsHigh: Int(config.size.height),
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                ) else {
                    NSLog("DMG background render failed: bitmap rep nil")
                    NSApp.terminate(nil)
                    return
                }
                rep.size = config.size
                hostingView.cacheDisplay(in: bounds, to: rep)

                guard let data = rep.representation(using: .png, properties: [:]) else {
                    NSApp.terminate(nil)
                    return
                }

                do {
                    try data.write(to: config.outputURL, options: .atomic)
                } catch {
                    NSLog("Failed to write DMG background: \(error)")
                }

                NSApp.terminate(nil)
            }
        }
    }
}
