import Foundation
import XCTest

final class AppleDesignAPISourceContractTests: XCTestCase {
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func assertSource(
        _ source: String,
        containsOrdered tokens: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var searchStart = source.startIndex
        for token in tokens {
            guard let range = source.range(of: token, range: searchStart..<source.endIndex) else {
                XCTFail("Expected source token after previous match: \(token)", file: file, line: line)
                return
            }
            searchStart = range.upperBound
        }
    }

    private func productionSwiftSources() throws -> [(relativePath: String, source: String)] {
        let roots = [
            "Sources",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources",
            "SkyBridge Compass iOS/Widgets",
            "SkyBridge Compass iOS/LocalPackages",
            "Scripts"
        ]
        var sources: [(relativePath: String, source: String)] = []
        for relativeRoot in roots {
            let sourceRoot = repositoryRoot().appendingPathComponent(relativeRoot)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sourceRoot.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw NSError(
                    domain: "AppleDesignAPISourceContractTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing production source root: \(relativeRoot)"]
                )
            }
            guard let enumerator = FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw NSError(
                    domain: "AppleDesignAPISourceContractTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to enumerate production source root: \(relativeRoot)"]
                )
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relativePath = url.path.replacingOccurrences(of: repositoryRoot().path + "/", with: "")
                let source = try String(contentsOf: url, encoding: .utf8)
                sources.append((relativePath, source))
            }
        }
        XCTAssertFalse(sources.isEmpty, "OS design API source-contract scan must not pass with an empty source set.")
        return sources.sorted { $0.relativePath < $1.relativePath }
    }

    private func nonCommentMatches(
        in source: String,
        relativePath: String,
        tokens: [String]
    ) -> [String] {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else {
                    return nil
                }
                guard let token = tokens.first(where: { trimmed.contains($0) }) else {
                    return nil
                }
                return "\(relativePath):\(index + 1):\(token):\(trimmed)"
            }
    }

    func testDeploymentTargetsStayOnOldDeviceCompatibilityFloor() throws {
        let rootPackage = try readSource("Package.swift")
        let rootProject = try readSource("project.yml")
        let iOSPackage = try readSource("SkyBridge Compass iOS/Package.swift")
        let iOSProject = try readSource("SkyBridge Compass iOS/project.yml")
        let iOSInfoPlist = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Supporting Files/Info.plist")
        let os27Plan = try readSource("Docs/os27-adaptation-plan-2026-06.md")

        XCTAssertTrue(rootPackage.contains(".iOS(.v17)"))
        XCTAssertTrue(rootPackage.contains(".macOS(.v14)"))
        XCTAssertTrue(rootProject.contains("macOS: \"14.0\""))
        XCTAssertTrue(rootProject.contains("MACOSX_DEPLOYMENT_TARGET: \"14.0\""))
        XCTAssertTrue(iOSPackage.contains(".iOS(.v17)"))
        XCTAssertTrue(iOSPackage.contains(".macOS(.v14)"))
        XCTAssertTrue(iOSProject.contains("iOS: \"17.0\""))
        XCTAssertTrue(iOSInfoPlist.contains("<string>iphone-ipad-minimum-performance-a12</string>"))
        XCTAssertFalse(
            iOSInfoPlist.contains("<string>metal</string>"),
            "The iOS install gate must not silently narrow old-device compatibility beyond the documented A12 floor."
        )
        XCTAssertTrue(os27Plan.contains("macOS 14+ / iOS 17+"))
        XCTAssertTrue(os27Plan.contains("iOS 17 / A12 仍是 app-start 兼容下限"))
        XCTAssertTrue(os27Plan.contains("pre-2020 A12/A12X 设备只允许在具体能力层标记 legacy-limited"))
        XCTAssertTrue(os27Plan.contains("不得用 deployment target 提升来“获得”API"))
    }

    func testIOSLegacyA12CompatibilityDoesNotUseAppStartupUnsupportedGate() throws {
        let startupBoundaryFiles = [
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/SkyBridgeCompassApp.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/AuthenticationManager.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        ]
        let unsupportedStartupReferences = try startupBoundaryFiles.compactMap { relativePath -> String? in
            let source = try readSource(relativePath)
            guard source.contains("currentUnsupportedDevice(")
                || source.contains("UnsupportedIOSDeviceView(")
                || source.contains("startup blocked on unsupported device")
                || source.contains("bootstrap skipped on unsupported device") else {
                return nil
            }
            return relativePath
        }

        XCTAssertTrue(
            unsupportedStartupReferences.isEmpty,
            "iOS 17/A12 legacy hardware must stay app-start supported; feature-specific managers can gate narrower capabilities after startup: \(unsupportedStartupReferences.joined(separator: ", "))"
        )

        let supportGate = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/DeviceSupport/IOSDeviceSupportGate.swift")
        XCTAssertTrue(supportGate.contains("legacyPre2020A12ModelIdentifiers"))
        XCTAssertTrue(supportGate.contains("legacyLimitedDevice(forModelIdentifier:"))
        XCTAssertFalse(
            supportGate.contains("blockedModelIdentifiers"),
            "Pre-2020 A12/A12X devices must be tracked as legacy-limited capability profiles, not app-start blocked devices."
        )
    }

    func testNativeGlassDesignAPIsStayBehindCompatibilityWrappers() throws {
        let allowedNativeGlassWrappers: Set<String> = [
            "Sources/SkyBridgeCompassApp/Dashboard/TopBar/TopNavigationBarView.swift",
            "Sources/SkyBridgeCompassApp/RemoteDesktopView.swift",
            "Sources/SkyBridgeCompassApp/ThemeConfiguration.swift",
            "Sources/SkyBridgeUI/Views/SkyBridgeLiquidGlass.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Utilities/LiquidGlass.swift"
        ]
        let nativeGlassTokens = [
            ".glassEffect(",
            "GlassEffectContainer",
            "glassEffectID",
            "glassEffectUnion",
            ".buttonStyle(.glass",
            "scrollExtensionMode"
        ]
        let directNativeGlassReferences = try productionSwiftSources().flatMap { relativePath, source -> [String] in
            guard !allowedNativeGlassWrappers.contains(relativePath) else {
                return []
            }
            return nonCommentMatches(in: source, relativePath: relativePath, tokens: nativeGlassTokens)
        }

        XCTAssertTrue(
            directNativeGlassReferences.isEmpty,
            "Native Liquid Glass / OS design APIs must stay in compatibility wrappers with old-OS fallbacks: \(directNativeGlassReferences.joined(separator: ", "))"
        )

        let macWrapper = try readSource("Sources/SkyBridgeUI/Views/SkyBridgeLiquidGlass.swift")
        XCTAssertTrue(macWrapper.contains("skyBridgeLiquidGlassBackground("))
        XCTAssertTrue(macWrapper.contains("skyBridgeLiquidGlassCard("))
        XCTAssertTrue(macWrapper.contains("skyBridgeLiquidGlassCapsule("))
        XCTAssertTrue(macWrapper.contains("if #available(iOS 26.0, macOS 26.0, *)"))
        XCTAssertTrue(macWrapper.contains(".glassEffect(.regular"))
        XCTAssertTrue(macWrapper.contains("fallbackMaterial"))
        XCTAssertTrue(macWrapper.contains("fallbackColor"))

        let iOSWrapper = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Utilities/LiquidGlass.swift")
        XCTAssertTrue(iOSWrapper.contains("@available(iOS 17.0, macOS 14.0, *)"))
        XCTAssertTrue(iOSWrapper.contains("if #available(iOS 26.0, macOS 26.0, *)"))
        XCTAssertTrue(iOSWrapper.contains("liquidGlassCard("))
        XCTAssertTrue(iOSWrapper.contains("liquidGlassCapsule("))
    }

    func testMacSidebarKeepsSystemSplitViewBaseline() throws {
        let dashboard = try readSource("Sources/SkyBridgeCompassApp/Dashboard/DashboardView.swift")
        let sidebar = try readSource("Sources/SkyBridgeCompassApp/GlassSidebar.swift")
        let os27Plan = try readSource("Docs/os27-adaptation-plan-2026-06.md")

        XCTAssertTrue(dashboard.contains("NavigationSplitView {"))
        XCTAssertTrue(sidebar.contains("BrandAppIconView("))
        XCTAssertTrue(sidebar.contains("preferredResourceName: \"SidebarBrandIcon\""))
        XCTAssertTrue(sidebar.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(sidebar.contains(".frame(width: isExpanded ? 280 : 80)"))
        XCTAssertTrue(sidebar.contains("RoundedRectangle(cornerRadius: 0)"))
        XCTAssertTrue(sidebar.contains(".frame(width: 1)"))
        XCTAssertTrue(sidebar.contains(".symbolRenderingMode(.hierarchical)"))
        XCTAssertTrue(sidebar.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: isExpanded ? .leading : .center)"))
        XCTAssertFalse(
            sidebar.contains("private enum SidebarPanelMetrics")
                || sidebar.contains("SidebarPanelMetrics.cornerRadius")
                || sidebar.contains(".contentShape(RoundedRectangle(cornerRadius: SidebarPanelMetrics")
                || sidebar.contains(".clipShape(RoundedRectangle(cornerRadius: SidebarPanelMetrics"),
            "macOS 27 beta sidebar material artifacts must not be papered over by adding a second custom rounded sidebar layer."
        )
        XCTAssertTrue(sidebar.contains(".animation(.spring(response: 0.4, dampingFraction: 0.9), value: isSelected)"))
        XCTAssertTrue(sidebar.contains(".animation(.easeInOut(duration: 0.2), value: isHovered)"))
        XCTAssertFalse(
            sidebar.contains(".animation(.spring(response: 0.4, dampingFraction: 0.9), value: selectedTab)"),
            "Sidebar selection animation must stay row-local so Dashboard detail content does not flash during navigation."
        )
        XCTAssertFalse(
            sidebar.contains("withAnimation(.spring(response: 0.4, dampingFraction: 0.9))"),
            "Sidebar selection mutation must not install an animated transaction over the Dashboard detail switch."
        )
        XCTAssertFalse(
            sidebar.contains("withAnimation(.easeInOut(duration: 0.2))"),
            "Hover changes should rely on SidebarTabButton's row-local animation instead of a parent transaction."
        )
        XCTAssertTrue(os27Plan.contains("macOS 27 beta 当前观察到的侧边栏材质/黑色矩形异常按平台 beta rendering artifact 处理"))
        XCTAssertTrue(os27Plan.contains("保留 `NavigationSplitView` + `GlassSidebar` 基线"))
        XCTAssertTrue(os27Plan.contains("保留蓝底图标和顶部栏 trailing-aligned 控件"))
        XCTAssertTrue(os27Plan.contains("不得叠加第二层自定义圆角玻璃层"))
        XCTAssertTrue(os27Plan.contains("Feedback Assistant"))
    }

    func testMacTopBarStatusControlsStayTrailingAligned() throws {
        let topBar = try readSource("Sources/SkyBridgeCompassApp/Dashboard/TopBar/TopNavigationBarView.swift")

        XCTAssertTrue(topBar.contains("HStack(spacing: 12)"))
        XCTAssertTrue(topBar.contains("Spacer(minLength: 0)"))
        XCTAssertTrue(topBar.contains(".frame(maxWidth: .infinity, alignment: .trailing)"))
        XCTAssertTrue(topBar.contains("private var topBarStatusPills: some View"))
        XCTAssertTrue(topBar.contains("private var topBarActions: some View"))
        XCTAssertTrue(topBar.contains(".fixedSize(horizontal: true, vertical: false)"))
        assertSource(
            topBar,
            containsOrdered: [
                "Spacer(minLength: 0)",
                "topBarStatusPills",
                "topBarActions"
            ]
        )
        assertSource(
            topBar,
            containsOrdered: [
                "if settingsManager.showTopBarIPLocation",
                "ipLocationIndicator",
                "if settingsManager.showTopBarNetworkSpeed",
                "networkSpeedIndicator",
                "if settingsManager.showTopBarNetworkLatency",
                "networkLatencyIndicator",
                "connectionStatusIndicator",
                "if SettingsManager.shared.showRealtimeFPS",
                "fpsIndicator"
            ]
        )
        assertSource(
            topBar,
            containsOrdered: [
                "NotificationBellView()",
                "themeToggleButton"
            ]
        )
        XCTAssertFalse(
            topBar.contains(".frame(maxWidth: .infinity, alignment: .leading)")
                || topBar.contains(".frame(maxWidth: .infinity, alignment: .topLeading)")
                || topBar.contains("HStack(alignment: .leading"),
            "Top bar status controls must stay trailing-aligned instead of drifting back to the left edge."
        )
    }

    func testMacAppThemeOwnsCoreGlassSurfaces() throws {
        let themeConfiguration = try readSource("Sources/SkyBridgeCompassApp/ThemeConfiguration.swift")
        let topBar = try readSource("Sources/SkyBridgeCompassApp/Dashboard/TopBar/TopNavigationBarView.swift")
        let remoteDesktop = try readSource("Sources/SkyBridgeCompassApp/RemoteDesktopView.swift")

        XCTAssertFalse(themeConfiguration.contains("import SkyBridgeUI"))
        XCTAssertFalse(topBar.contains("import SkyBridgeUI"))
        XCTAssertFalse(remoteDesktop.contains("import SkyBridgeUI"))
        XCTAssertFalse(themeConfiguration.contains("skyBridgeLiquidGlass"))
        XCTAssertFalse(topBar.contains("skyBridgeLiquidGlass"))
        XCTAssertFalse(remoteDesktop.contains("skyBridgeLiquidGlass"))

        XCTAssertTrue(themeConfiguration.contains("struct GlassStyleModifier: ViewModifier"))
        XCTAssertTrue(topBar.contains("private struct TopBarGlassPillModifier: ViewModifier"))
        XCTAssertTrue(remoteDesktop.contains("private var sessionSidebar: some View"))
        XCTAssertTrue(themeConfiguration.contains("if #available(macOS 26.0, *)"))
        XCTAssertTrue(topBar.contains("if #available(macOS 26.0, *)"))
        XCTAssertTrue(remoteDesktop.contains("if #available(macOS 26.0, *)"))
        XCTAssertTrue(themeConfiguration.contains(".background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))"))
        XCTAssertTrue(topBar.contains(".background(themeConfiguration.cardBackgroundColor, in: Capsule())"))
        XCTAssertTrue(remoteDesktop.contains(".fill(themeConfiguration.cardBackgroundMaterial)"))
    }

    func testMacOSMenuIndicatorDesignAPIStaysInCompatibilityModifier() throws {
        let allowedMenuIndicatorWrappers: Set<String> = [
            "Sources/SkyBridgeCompassApp/Views/LiquidGlassUserArea.swift"
        ]
        let directMenuIndicatorReferences = try productionSwiftSources().flatMap { relativePath, source -> [String] in
            guard !allowedMenuIndicatorWrappers.contains(relativePath) else {
                return []
            }
            return nonCommentMatches(in: source, relativePath: relativePath, tokens: [".menuIndicator("])
        }

        XCTAssertTrue(
            directMenuIndicatorReferences.isEmpty,
            "macOS 26+ menuIndicator API must stay in a compatibility modifier with an old-OS no-op path: \(directMenuIndicatorReferences.joined(separator: ", "))"
        )

        let wrapperSource = try readSource("Sources/SkyBridgeCompassApp/Views/LiquidGlassUserArea.swift")
        XCTAssertTrue(wrapperSource.contains("MenuIndicatorHiddenModifier"))
        XCTAssertTrue(wrapperSource.contains("if #available(macOS 26.0, *)"))
        XCTAssertTrue(wrapperSource.contains("content.menuIndicator(.hidden)"))
        XCTAssertTrue(wrapperSource.contains("} else {\n            content"))
    }

    func testOS27DesignSDKSymbolsRequireExplicitCompileGateBeforeUse() throws {
        let os27DesignTokens = [
            "HAS_APPLE_OS27_DESIGN_SDK",
            "GlassEffectContainer",
            "glassEffectID",
            "glassEffectUnion",
            "scrollExtensionMode"
        ]
        let productionReferences = try productionSwiftSources().flatMap { relativePath, source in
            nonCommentMatches(in: source, relativePath: relativePath, tokens: os27DesignTokens)
        }
        let integrationFiles = [
            "Package.swift",
            "project.yml",
            "SkyBridge Compass iOS/Package.swift",
            "SkyBridge Compass iOS/project.yml",
            "SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj/project.pbxproj"
        ]
        let integrationReferences = try integrationFiles.flatMap { relativePath -> [String] in
            let source = try readSource(relativePath)
            return os27DesignTokens.compactMap { token in
                source.contains(token) ? "\(relativePath):\(token)" : nil
            }
        }

        XCTAssertTrue(
            productionReferences.isEmpty && integrationReferences.isEmpty,
            "OS27-only design SDK symbols need an explicit SDK probe, compile condition, runtime fallback, and source-contract update before production use: \((productionReferences + integrationReferences).joined(separator: ", "))"
        )
    }

    func testAppleDesignAPISourceContractRunsInOS27CompatibilityLane() throws {
        let script = try readSource("Scripts/run_os27_beta_compatibility.sh")

        XCTAssertTrue(script.contains("AppleDesignAPISourceContractTests"))
        XCTAssertTrue(
            script.contains("source_contract_filter='SkyBridgeCoreTests.(ApplePQCSDKGateSourceContractTests|AppleDesignAPISourceContractTests|AppleAIAdvisorySourceContractTests|AppleAppIntentAuthoritySourceContractTests|AIAdvisoryBoundaryTests|MetalShaderSourceCompileContractTests|AppUpdateManifestTests|QuantumCryptoManagerStrictPQCPolicyTests|P2PRedactionSourceContractTests)'"),
            "OS27 source-contract mode must run the design API guardrail before reporting source_contracts=verified."
        )
        XCTAssertTrue(
            script.contains("ApplePQCSDKGateSourceContractTests|AppleDesignAPISourceContractTests|AppleAIAdvisorySourceContractTests|AppleAppIntentAuthoritySourceContractTests|AIAdvisoryBoundaryTests|MetalShaderSourceCompileContractTests"),
            "OS27 full validation must keep the design API source contract in its filtered SwiftPM clean-log tests."
        )
    }
}
