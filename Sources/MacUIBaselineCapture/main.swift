import AppKit
import Foundation
import SwiftUI

private let captureSize = CGSize(width: 1200, height: 800)

struct CaptureManifest: Decodable {
    let captures: [CaptureSpec]
}

struct CaptureSpec: Decodable, Hashable {
    let id: String
    let page: String
    let state: String
    let theme: String
    let locale: String
    let critical: Bool
}

@MainActor
@main
struct MacUIBaselineCapture {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var manifestPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "docs/mac-baseline/ui-baseline/capture-manifest.json")
        var outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "docs/mac-baseline/ui-baseline/screenshots/mac")
        var requestedIDs = Set<String>()

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--manifest":
                index += 1
                manifestPath = URL(fileURLWithPath: arguments[index])
            case "--out-dir":
                index += 1
                outputDir = URL(fileURLWithPath: arguments[index])
            case "--capture-id":
                index += 1
                requestedIDs.insert(arguments[index])
            default:
                break
            }
            index += 1
        }

        let data = try Data(contentsOf: manifestPath)
        let manifest = try JSONDecoder().decode(CaptureManifest.self, from: data)
        let captures = manifest.captures.filter { requestedIDs.isEmpty || requestedIDs.contains($0.id) }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        for capture in captures {
            let outputURL = outputDir.appending(path: "\(capture.id).png")
            let image = renderImage(for: capture)
            try image.pngWrite(to: outputURL)
            print("wrote \(outputURL.path)")
        }
    }

    @MainActor
    private static func renderImage(for capture: CaptureSpec) -> NSImage {
        let root = BaselineCaptureView(capture: capture)
            .frame(width: captureSize.width, height: captureSize.height)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(origin: .zero, size: captureSize)
        hostingView.layoutSubtreeIfNeeded()

        let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
            ?? NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(captureSize.width),
                pixelsHigh: Int(captureSize.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )!
        rep.size = captureSize
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)

        let image = NSImage(size: captureSize)
        image.addRepresentation(rep)
        return image
    }
}

private extension NSImage {
    func pngWrite(to url: URL) throws {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }
}

private struct BaselineCaptureView: View {
    let capture: CaptureSpec

    private var darkMode: Bool { capture.theme.lowercased() == "dark" }

    var body: some View {
        Group {
            switch capture.page {
            case "Login":
                loginScene
            default:
                shellScene
            }
        }
        .frame(width: captureSize.width, height: captureSize.height)
    }

    private var shellScene: some View {
        ZStack {
            LinearGradient(
                colors: darkMode
                    ? [Color(red: 0.23, green: 0.31, blue: 0.47), Color(red: 0.43, green: 0.53, blue: 0.70), Color(red: 0.77, green: 0.81, blue: 0.89)]
                    : [Color(red: 0.89, green: 0.92, blue: 0.98), Color(red: 0.80, green: 0.85, blue: 0.93), Color(red: 0.73, green: 0.79, blue: 0.90)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white.opacity(darkMode ? 0.16 : 0.42))
                .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.16), lineWidth: 1))
                .padding(26)

            HStack(spacing: 0) {
                sidebar
                VStack(spacing: 16) {
                    topBar
                    ScrollView(.vertical, showsIndicators: false) {
                        pageContent
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                    }
                }
            }
            .padding(34)
        }
        .overlay(alignment: .center) {
            overlayPrompt
        }
    }

    private var loginScene: some View {
        ZStack {
            LinearGradient(
                colors: [Color.white, Color(red: 0.94, green: 0.96, blue: 0.99)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                logoHeader(subtitle: "Select sign-in method")
                VStack(spacing: 16) {
                    HStack(spacing: 0) {
                        segmented("Email", selected: true)
                        segmented("Phone", selected: false)
                    }
                    field("Email")
                    field("Password", icon: "eye.fill")
                    primaryButton("Sign in with Email")
                    Text("Create Account")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.72))
                    Divider()
                    primaryButton("Sign in with Apple")
                    if capture.state == "Error" {
                        Text("Verification failed. Re-check your Nebula ID or one-time sign-in code.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.red.opacity(0.82))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(22)
                .frame(width: 354)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.white.opacity(0.88))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.black.opacity(0.06), lineWidth: 1))
                        .shadow(color: .black.opacity(0.08), radius: 20, x: 0, y: 12)
                )
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                brandBadge(size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SkyBridge Compass")
                        .font(.system(size: 15, weight: .bold))
                    Text("Next-Gen Cross-Platform Connection Experience")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                    Text("Lza的MacBook Pro • Apple M1 Max")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.46))
                }
            }
            .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(sidebarItems, id: \.title) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.icon)
                            .frame(width: 18)
                        Text(item.title)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(item.selected ? 0.98 : 0.78))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(item.selected ? Color.blue.opacity(0.82) : .clear)
                    )
                }
            }

            Spacer()

            HStack(spacing: 10) {
                Circle()
                    .fill(Color.orange.opacity(0.95))
                    .frame(width: 34, height: 34)
                    .overlay(Text("月").font(.system(size: 14, weight: .bold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 2) {
                    Text("月濯星河")
                        .font(.system(size: 13, weight: .semibold))
                    Text("ID: 9f8f8208…cf62")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.46))
                }
                Spacer()
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
        }
        .padding(18)
        .frame(width: 246)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.18, green: 0.22, blue: 0.34).opacity(0.94))
        )
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            brandBadge(size: 22)
            Text(headerTitle)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Circle().fill(headerDotColor).frame(width: 7, height: 7)
            Text(headerStatus)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.74))
            Spacer().frame(width: 10)
            statusChip("120 FPS")
            statusChip(systemName: "bell")
            statusChip(systemName: "wifi")
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.28, green: 0.38, blue: 0.58).opacity(0.55))
        )
    }

    @ViewBuilder
    private var pageContent: some View {
        switch capture.page {
        case "Dashboard":
            dashboardPage
        case "Devices":
            devicesPage
        case "Transfers":
            transfersPage
        case "Settings":
            settingsPage
        case "Tray/Notifications":
            dashboardPage
        case "USB":
            usbPage
        case "Remote":
            remotePage
        case "Monitor":
            monitorPage
        default:
            dashboardPage
        }
    }

    private var dashboardPage: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                metricCard("Online Devices", value: capture.state.contains("Connected") ? "4" : "2", color: .blue, icon: "desktopcomputer")
                metricCard("Active Sessions", value: capture.state.contains("Connected") ? "1" : "0", color: .green, icon: "display")
                metricCard("Transfer Tasks", value: capture.state.contains("Connected") ? "2" : "0", color: .orange, icon: "folder")
                metricCard("System Status", value: "Excellent", color: .green, icon: "checkmark.circle.fill", emphasis: true)
            }

            ambientHero

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    glassPanel(title: "Discover Devices", trailing: capture.state.contains("Connected") ? "Scanning…" : "Scanning…") {
                        VStack(spacing: 14) {
                            HStack {
                                Text("Compatibility / More Devices")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.64))
                                Spacer()
                                roundedControl("Extended…", width: 94)
                                roundedControl("Manual Co…", width: 92)
                                roundedSearch("Search", width: 112)
                            }
                            if capture.state.contains("Connected") || capture.state.contains("Discovering") {
                                ForEach(["Lza的MacBook Pro", "iPhone 16 Pro", "Ubuntu Studio"], id: \.self) { name in
                                    HStack {
                                        Image(systemName: "desktopcomputer")
                                            .foregroundStyle(.white.opacity(0.92))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(name).font(.system(size: 14, weight: .semibold))
                                            Text("Unknown IP")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.46))
                                        }
                                        Spacer()
                                        Circle().fill(Color.red.opacity(0.9)).frame(width: 7, height: 7)
                                    }
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.18)))
                                }
                            }
                        }
                    }

                    glassPanel(title: "Cross-Network Connection", trailing: nil) {
                        HStack(spacing: 14) {
                            compactCard("My Connection Code", headline: "QW9P7Z")
                            compactCard("Enter Connection Code", headline: "AB12CD")
                        }
                    }
                }

                glassPanel(title: "Remote Sessions", trailing: nil) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.28))
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 54, weight: .light))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .frame(width: 382, height: 310)
                }
                .frame(width: 400)
            }
        }
    }

    private var devicesPage: some View {
        glassPanel(title: "Trusted Devices", trailing: capture.state) {
            VStack(spacing: 12) {
                if capture.state == "Empty" {
                    emptyPlaceholder("No Devices Found", subtitle: "Check your network connection")
                } else {
                    ForEach(["MacBook Pro", "iPhone 16 Pro", "Ubuntu Studio", "iPad Pro"], id: \.self) { device in
                        rowCard(title: device, subtitle: "Trusted • cross-network ready", badge: "Online")
                    }
                }
            }
        }
    }

    private var transfersPage: some View {
        glassPanel(title: "Transfer Queue", trailing: capture.state) {
            VStack(spacing: 12) {
                if capture.state == "Empty" {
                    emptyPlaceholder("No Transfers", subtitle: "Completed and in-progress jobs appear here")
                } else {
                    transferRow("ProductLaunchDeck.pdf", progress: 0.68, status: "27 / 42 MB")
                    transferRow("4K-Demo-Reel.mov", progress: 1.0, status: "Completed")
                    transferRow("ResearchDataset.zip", progress: 0.24, status: "Syncing")
                }
            }
        }
    }

    private var settingsPage: some View {
        VStack(spacing: 16) {
            glassPanel(title: "Preferences", trailing: capture.state) {
                VStack(spacing: 12) {
                    settingsRow("Appearance", value: "Adaptive glass")
                    settingsRow("Cross-network transport", value: "WebRTC preferred")
                    settingsRow("Clipboard policy", value: "Trusted peers only")
                }
            }
            glassPanel(title: "Account", trailing: nil) {
                VStack(spacing: 12) {
                    HStack {
                        Circle()
                            .fill(Color.cyan.opacity(0.85))
                            .frame(width: 38, height: 38)
                            .overlay(Text("G").font(.system(size: 18, weight: .bold)).foregroundStyle(.white))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Not Signed In").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            Text("Sign in from the Login page to sync settings and profile")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.58))
                        }
                        Spacer()
                        Text("Sign In")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.blue.opacity(0.82)))
                    }
                    settingsRow("Sync Status", value: "Last synced: just now")
                }
            }
            if capture.state.contains("Security") {
                glassPanel(title: "Security", trailing: nil) {
                    VStack(spacing: 12) {
                        settingsRow("Post-quantum policy", value: "Require PQC")
                        settingsRow("Trusted KEM cache", value: "3 peers")
                        settingsRow("Fallback cooldown", value: "Enabled")
                    }
                }
            }
        }
    }

    private var usbPage: some View {
        glassPanel(title: "USB Inventory", trailing: "Attached device inventory") {
            VStack(spacing: 12) {
                rowCard(title: "iPhone 16 Pro", subtitle: "USB-C • File transfer + trust sync", badge: "Attached")
                rowCard(title: "iPad Pro", subtitle: "USB 3.2 • Remote desktop relay", badge: "Ready")
                rowCard(title: "Nebula Secure Key", subtitle: "Hardware-backed auth token", badge: "Secure")
            }
        }
    }

    private var remotePage: some View {
        VStack(spacing: 16) {
            glassPanel(title: "Trusted Active Sessions", trailing: "1 active") {
                HStack(spacing: 12) {
                    remoteSessionCard(
                        title: "MacBook Pro",
                        subtitle: "WebRTC + verified input",
                        latency: "18 ms",
                        bandwidth: "82 Mbps",
                        accent: .green
                    )
                    compactCard("Transport", headline: "Verified input")
                    compactCard("Latency", headline: "18 ms")
                }
            }
            glassPanel(title: "Preview", trailing: "Verified live") {
                VStack(spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("MacBook Pro")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                            Text("Streaming with verified input")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.58))
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            previewBadge("60 FPS")
                            previewBadge("Secure")
                        }
                    }

                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.22))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Streaming with verified input")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.84))
                            Text("Cross-network relay stable • low-latency pointer sync")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.56))
                        }
                        .padding(22)
                    }
                    .frame(height: 360)
                }
            }
        }
    }

    private var monitorPage: some View {
        glassPanel(title: "Live Snapshot", trailing: "Active monitoring") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    compactMetricChip("CPU", value: "42%", color: .orange, icon: "cpu")
                    compactMetricChip("Memory", value: "68%", color: .blue, icon: "memorychip")
                    compactMetricChip("Bandwidth", value: "128 Mb/s", color: .green, icon: "network")
                    compactMetricChip("Thermal", value: "57°C", color: .pink, icon: "thermometer")
                }

                VStack(alignment: .leading, spacing: 14) {
                    monitorBar("Remote stream FPS stable above 58 fps", value: 0.82, color: .green)
                    monitorBar("No thermal throttling detected", value: 0.58, color: .blue)
                    monitorBar("Transfer queue healthy • zero retries", value: 0.74, color: .orange)
                }

                HStack(spacing: 12) {
                    previewBadge("Overall health · Excellent")
                    previewBadge("Load · 24%")
                    previewBadge("Cooling · Nominal")
                }
            }
        }
    }

    @ViewBuilder
    private var overlayPrompt: some View {
        switch capture.id {
        case "UI-CAP-011":
            modalPrompt(title: "Incoming Transfer", message: "MacBook Pro wants to send ProductLaunchDeck.pdf (42 MB).")
        case "UI-CAP-012":
            modalPrompt(title: "Remote Control Request", message: "iPad Pro wants to control this Mac. Verified fingerprint matches trusted peer.")
        default:
            EmptyView()
        }
    }

    private var ambientHero: some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "location.fill").foregroundStyle(.white.opacity(0.7))
                    Text("Mong Kok").font(.system(size: 20, weight: .bold))
                }
                Text("Clear")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.74))
            }
            Spacer()
            Text("22°")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.white)
            Spacer()
            HStack(spacing: 24) {
                heroMetric("Humidity", value: "51%")
                heroMetric("Visibility", value: "24 km")
                heroMetric("Wind", value: "10 km/h")
            }
        }
        .padding(24)
        .frame(height: 164)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(darkMode ? 0.16 : 0.30))
        )
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private func logoHeader(subtitle: String) -> some View {
        VStack(spacing: 12) {
            brandBadge(size: 72)
            Text("SkyBridge Compass")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.black.opacity(0.78))
            Text(subtitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.black.opacity(0.42))
        }
    }

    private func segmented(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.black.opacity(selected ? 0.78 : 0.55))
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(selected ? 0.16 : 0.08)))
    }

    private func field(_ placeholder: String, icon: String? = nil) -> some View {
        HStack {
            Text(placeholder)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.black.opacity(0.36))
            Spacer()
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(.black.opacity(0.46))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.08)))
    }

    private func primaryButton(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.86)))
    }

    private func brandBadge(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.94), Color.blue.opacity(0.26)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "globe.asia.australia.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(
                    LinearGradient(colors: [.brown, .blue, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.28).stroke(Color.blue.opacity(0.35), lineWidth: 1))
    }

    private func statusChip(_ title: String? = nil, systemName: String? = nil) -> some View {
        Group {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            } else if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(8)
            }
        }
        .foregroundStyle(.white.opacity(0.82))
        .background(Capsule().fill(Color.black.opacity(0.16)))
    }

    private func metricCard(_ title: String, value: String, color: Color, icon: String, emphasis: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color.opacity(0.95))
            Spacer()
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
            Text(value)
                .font(.system(size: emphasis ? 22 : 24, weight: .bold))
                .foregroundStyle(emphasis ? color.opacity(0.95) : .white)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(darkMode ? 0.14 : 0.26)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.10), lineWidth: 1))
    }

    private func glassPanel<Content: View>(title: String, trailing: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            content()
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 22).fill(.white.opacity(darkMode ? 0.13 : 0.24)))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.10), lineWidth: 1))
    }

    private func compactCard(_ title: String, headline: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.84))
            Text(headline)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.blue.opacity(0.96))
            Text("Mirrors the Apple smart-code flow.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.54))
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.16)))
    }

    private func roundedControl(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.76))
            .frame(width: width, height: 30)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private func roundedSearch(_ title: String, width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
            Text(title)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.62))
        .frame(width: width, height: 30)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private func rowCard(title: String, subtitle: String, badge: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.54))
            }
            Spacer()
            Text(badge)
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.green.opacity(0.18)))
                .foregroundStyle(Color.green.opacity(0.95))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.14)))
    }

    private func transferRow(_ title: String, progress: Double, status: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Text(status).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.62))
            }
            ProgressView(value: progress)
                .tint(progress >= 1 ? .green : .blue)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.14)))
    }

    private func settingsRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            Text(value).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.62))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.14)))
    }

    private func emptyPlaceholder(_ title: String, subtitle: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.white.opacity(0.42))
            Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.84))
            Text(subtitle).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.54))
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.14)))
    }

    private func modalPrompt(title: String, message: String) -> some View {
        ZStack {
            Color.black.opacity(0.16).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 20, weight: .bold))
                Text(message).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.black.opacity(0.62))
                HStack {
                    Spacer()
                    Text("Allow")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.blue.opacity(0.88)))
                }
            }
            .padding(22)
            .frame(width: 420)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(.white.opacity(0.94))
                    .shadow(color: .black.opacity(0.12), radius: 20, x: 0, y: 12)
            )
        }
    }

    private func monitorBar(_ title: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.84))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(color.opacity(0.85)).frame(width: proxy.size.width * value)
                }
            }
            .frame(height: 12)
        }
    }

    private func remoteSessionCard(title: String, subtitle: String, latency: String, bandwidth: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer()
                previewBadge("Connected")
            }

            HStack(spacing: 12) {
                compactMetricChip("Latency", value: latency, color: accent, icon: "waveform.path.ecg")
                compactMetricChip("Bandwidth", value: bandwidth, color: .blue, icon: "arrow.left.arrow.right")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func previewBadge(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.16)))
    }

    private func compactMetricChip(_ title: String, value: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color.opacity(0.95))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.58))
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(color.opacity(0.12)))
    }

    private func heroMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.56))
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.86))
        }
    }

    private var sidebarItems: [(title: String, icon: String, selected: Bool)] {
        let selectedPage = capture.page == "Tray/Notifications" ? "Dashboard" : capture.page
        return [
            ("Main Console", "house.fill", selectedPage == "Dashboard"),
            ("Device Discovery", "magnifyingglass", selectedPage == "Devices"),
            ("USB Management", "cable.connector", selectedPage == "USB"),
            ("File Transfer (Quantum Communication)", "folder", selectedPage == "Transfers"),
            ("Remote Desktop (Quantum Communication)", "display", selectedPage == "Remote"),
            ("System Monitor", "speedometer", selectedPage == "Monitor"),
            ("Settings", "gearshape", selectedPage == "Settings")
        ]
    }

    private var headerTitle: String {
        if capture.page == "Dashboard" || capture.page == "Tray/Notifications" {
            return "Main Console"
        }
        return capture.page == "Monitor" ? "System Monitor" : capture.page
    }

    private var headerStatus: String {
        switch capture.page {
        case "Dashboard":
            return capture.state.contains("Connected") ? "Connected to MacBook Pro • Streaming 2560×1600 @ 60 fps" : "Disconnected"
        case "Devices":
            return capture.state == "Empty" ? "No peers discovered" : "Trusted peers available"
        case "Transfers":
            return capture.state == "Empty" ? "Transfer queue idle" : "Quantum transfer in progress"
        case "Settings":
            return "Preferences synchronized"
        case "USB":
            return "USB bridge ready"
        case "Remote":
            return "Verified active sessions"
        case "Monitor":
            return "Telemetry stable"
        default:
            return "Disconnected"
        }
    }

    private var headerDotColor: Color {
        capture.page == "Dashboard" && capture.state.contains("Connected") ? .green : .orange
    }
}
