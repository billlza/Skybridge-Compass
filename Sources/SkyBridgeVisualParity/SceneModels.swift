import Foundation

public struct CaptureManifest: Decodable, Hashable {
    public let captures: [CaptureSpec]
}

public struct CaptureSpec: Decodable, Hashable {
    public let id: String
    public let page: String
    public let state: String
    public let theme: String
    public let locale: String
    public let critical: Bool
}

public struct VisualThemeState: Codable, Hashable {
    public let themeID: String
    public let accentHex: String
    public let glassOpacity: Double
    public let backgroundIntensity: Double
    public let weatherCondition: String
    public let windSpeed: Double
    public let hazeOpacity: Double
    public let animationEnabled: Bool
    public let fixedTimestamp: String
}

public struct StatusChipState: Codable, Hashable {
    public let text: String
    public let systemImage: String?
    public let tone: String
}

public struct MetricCardState: Codable, Hashable {
    public let title: String
    public let value: String
    public let accentHex: String
    public let systemImage: String
    public let emphasis: Bool
}

public struct ListRowState: Codable, Hashable {
    public let title: String
    public let subtitle: String
    public let badge: String?
    public let badgeTone: String?
}

public struct ShellSceneState: Codable, Hashable {
    public let captureID: String
    public let pageID: String
    public let pageTitle: String
    public let scenarioState: String
    public let locale: String
    public let darkMode: Bool
    public let theme: VisualThemeState
    public let headerStatus: String
    public let headerTone: String
    public let sidebarTitle: String
    public let sidebarSubtitle: String
    public let sidebarPrimaryChip: String
    public let sidebarSecondaryChip: String
    public let topBarChips: [StatusChipState]
    public let metricCards: [MetricCardState]
    public let primaryRows: [ListRowState]
    public let secondaryRows: [ListRowState]
    public let overlayTitle: String?
    public let overlayMessage: String?
}

public enum MacBaselineSceneFactory {
    public static func makeScene(for capture: CaptureSpec) -> ShellSceneState {
        let isDark = capture.theme.lowercased() == "dark"
        let pageID = pageIdentifier(for: capture.page)
        let title = pageTitle(for: capture.page)
        let themeID = isDark ? "classic" : "light-login"
        let headerTone = isDark ? (capture.state.lowercased().contains("connected") ? "success" : "warning") : "neutral"
        let overlay = overlay(for: capture.id)

        return ShellSceneState(
            captureID: capture.id,
            pageID: pageID,
            pageTitle: title,
            scenarioState: capture.state,
            locale: capture.locale,
            darkMode: isDark,
            theme: VisualThemeState(
                themeID: themeID,
                accentHex: "#D93072EF",
                glassOpacity: VisualParityTokenSet.Materials.defaultGlassOpacity,
                backgroundIntensity: VisualParityTokenSet.Materials.defaultBackgroundIntensity,
                weatherCondition: capture.page == "Dashboard" ? "clear" : "stable",
                windSpeed: capture.page == "Dashboard" ? 10 : 0,
                hazeOpacity: capture.page == "Dashboard" ? 0 : 0,
                animationEnabled: true,
                fixedTimestamp: "2026-04-11T12:00:00Z"
            ),
            headerStatus: headerStatus(for: capture.page, state: capture.state),
            headerTone: headerTone,
            sidebarTitle: "SkyBridge Compass",
            sidebarSubtitle: isDark ? "Cross-platform continuity" : "Select sign-in method",
            sidebarPrimaryChip: isDark ? "X-Wing preferred" : "Trusted identity",
            sidebarSecondaryChip: isDark ? trustedChip(for: capture.state) : "Windows Hello aware",
            topBarChips: topBarChips(for: capture.page, state: capture.state),
            metricCards: metricCards(for: capture.page, state: capture.state),
            primaryRows: primaryRows(for: capture.page, state: capture.state),
            secondaryRows: secondaryRows(for: capture.page, state: capture.state),
            overlayTitle: overlay?.0,
            overlayMessage: overlay?.1
        )
    }

    private static func pageIdentifier(for page: String) -> String {
        switch page {
        case "Dashboard", "Tray/Notifications":
            return "dashboard"
        case "Devices":
            return "devices"
        case "USB":
            return "usb"
        case "Transfers":
            return "transfers"
        case "Remote":
            return "remote"
        case "Monitor":
            return "monitor"
        case "Settings":
            return "settings"
        case "Login":
            return "login"
        default:
            return "dashboard"
        }
    }

    private static func pageTitle(for page: String) -> String {
        switch page {
        case "Dashboard", "Tray/Notifications":
            return "Main Console"
        case "Devices":
            return "Device Discovery"
        case "USB":
            return "USB Management"
        case "Transfers":
            return "File Transfer"
        case "Remote":
            return "Remote Desktop"
        case "Monitor":
            return "System Monitor"
        case "Settings":
            return "Settings"
        case "Login":
            return "SkyBridge Compass"
        default:
            return page
        }
    }

    private static func headerStatus(for page: String, state: String) -> String {
        switch page {
        case "Dashboard":
            return state.contains("Connected")
                ? "Connected to MacBook Pro • Streaming 2560×1600 @ 60 fps"
                : "Disconnected"
        case "Devices":
            return state == "Empty" ? "No peers discovered" : "Trusted peers available"
        case "USB":
            return "Attached device inventory"
        case "Transfers":
            return state == "Empty" ? "Transfer queue idle" : "Quantum transfer in progress"
        case "Remote":
            return "Verified active sessions"
        case "Monitor":
            return "Telemetry stable"
        case "Settings":
            return "Preferences synchronized"
        case "Login":
            return "Select sign-in method"
        default:
            return state
        }
    }

    private static func trustedChip(for state: String) -> String {
        if state.contains("Connected") {
            return "1 trusted peer"
        }
        if state.contains("Discovering") {
            return "4 discovered"
        }
        return "No trusted peers"
    }

    private static func topBarChips(for page: String, state: String) -> [StatusChipState] {
        if page == "Login" {
            return []
        }

        return [
            StatusChipState(text: page == "Dashboard" && state.contains("Connected") ? "Connected" : "Idle", systemImage: nil, tone: state.contains("Connected") ? "success" : "warning"),
            StatusChipState(text: "120 FPS", systemImage: nil, tone: "neutral"),
            StatusChipState(text: "", systemImage: "bell", tone: "neutral"),
            StatusChipState(text: "", systemImage: "wifi", tone: "neutral")
        ]
    }

    private static func metricCards(for page: String, state: String) -> [MetricCardState] {
        guard page == "Dashboard" else { return [] }

        return [
            MetricCardState(title: "Online Devices", value: state.contains("Connected") ? "4" : "2", accentHex: "#FF4D9CFF", systemImage: "desktopcomputer", emphasis: false),
            MetricCardState(title: "Active Sessions", value: state.contains("Connected") ? "1" : "0", accentHex: "#FF4DC770", systemImage: "display", emphasis: false),
            MetricCardState(title: "Transfer Tasks", value: state.contains("Connected") ? "2" : "0", accentHex: "#FFFF9A4D", systemImage: "folder", emphasis: false),
            MetricCardState(title: "System Status", value: "Excellent", accentHex: "#FF4DC770", systemImage: "checkmark.circle.fill", emphasis: true)
        ]
    }

    private static func primaryRows(for page: String, state: String) -> [ListRowState] {
        switch page {
        case "Devices":
            if state == "Empty" {
                return []
            }
            return [
                ListRowState(title: "MacBook Pro", subtitle: "Trusted • cross-network ready", badge: "Online", badgeTone: "success"),
                ListRowState(title: "iPhone 16 Pro", subtitle: "Trusted • cross-network ready", badge: "Online", badgeTone: "success"),
                ListRowState(title: "Ubuntu Studio", subtitle: "Trusted • cross-network ready", badge: "Online", badgeTone: "success"),
                ListRowState(title: "iPad Pro", subtitle: "Trusted • cross-network ready", badge: "Online", badgeTone: "success")
            ]
        case "USB":
            return [
                ListRowState(title: "iPhone 16 Pro", subtitle: "USB-C • File transfer + trust sync", badge: "Attached", badgeTone: "warning"),
                ListRowState(title: "iPad Pro", subtitle: "USB 3.2 • Remote desktop relay", badge: "Ready", badgeTone: "success"),
                ListRowState(title: "Nebula Secure Key", subtitle: "Hardware-backed auth token", badge: "Secure", badgeTone: "success")
            ]
        case "Transfers":
            if state == "Empty" {
                return []
            }
            return [
                ListRowState(title: "ProductLaunchDeck.pdf", subtitle: "27 / 42 MB", badge: "Syncing", badgeTone: "warning"),
                ListRowState(title: "4K-Demo-Reel.mov", subtitle: "Completed", badge: "Done", badgeTone: "success"),
                ListRowState(title: "ResearchDataset.zip", subtitle: "Syncing", badge: "Live", badgeTone: "warning")
            ]
        default:
            return []
        }
    }

    private static func secondaryRows(for page: String, state: String) -> [ListRowState] {
        switch page {
        case "Dashboard":
            return [
                ListRowState(title: "Control", subtitle: "Idle", badge: "0 active", badgeTone: "neutral"),
                ListRowState(title: "Inbox", subtitle: "0", badge: "Ready", badgeTone: "neutral"),
                ListRowState(title: "Runtime", subtitle: "X-Wing", badge: "Secure", badgeTone: "success")
            ]
        case "Settings":
            return [
                ListRowState(title: "Appearance", subtitle: "Adaptive glass", badge: nil, badgeTone: nil),
                ListRowState(title: "Cross-network transport", subtitle: "WebRTC preferred", badge: nil, badgeTone: nil),
                ListRowState(title: "Clipboard policy", subtitle: "Trusted peers only", badge: nil, badgeTone: nil)
            ]
        case "Monitor":
            return [
                ListRowState(title: "CPU", subtitle: "42%", badge: "Stable", badgeTone: "warning"),
                ListRowState(title: "Memory", subtitle: "68%", badge: "Healthy", badgeTone: "success"),
                ListRowState(title: "Bandwidth", subtitle: "128 Mb/s", badge: "Nominal", badgeTone: "success")
            ]
        default:
            return []
        }
    }

    private static func overlay(for captureID: String) -> (String, String)? {
        switch captureID {
        case "UI-CAP-011":
            return ("Incoming Transfer", "MacBook Pro wants to send ProductLaunchDeck.pdf (42 MB).")
        case "UI-CAP-012":
            return ("Remote Control Request", "iPad Pro wants to control this Mac. Verified fingerprint matches trusted peer.")
        default:
            return nil
        }
    }
}
