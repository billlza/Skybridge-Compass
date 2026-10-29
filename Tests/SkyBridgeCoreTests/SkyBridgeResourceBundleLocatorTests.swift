import XCTest
@testable import SkyBridgeCore

/// Regression tests for the non-trapping SwiftPM resource bundle resolver.
///
/// Background: the SwiftPM-generated `Bundle.module` accessor calls
/// `fatalError` when the `<Package>_<Target>.bundle` directory is missing from
/// its two hardcoded probe locations, which crashed the packaged app at launch
/// on zh-Hans systems. `SkyBridgeResourceBundleLocator` must NEVER trap: a
/// missing bundle degrades to `Bundle.main` (English/key fallback), it never
/// takes down the process.
final class SkyBridgeResourceBundleLocatorTests: XCTestCase {

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("locator-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    // MARK: - Pure search behaviour

    func testResolveFindsBundleStagedInCandidateDirectory() throws {
        // Mirrors the packaged-app layout: Contents/Resources contains
        // SkyBridgeCompassApp_SkyBridgeCore.bundle.
        let stagedBundle = temporaryDirectory.appendingPathComponent(
            "SkyBridgeCompassApp_SkyBridgeCore.bundle",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: stagedBundle, withIntermediateDirectories: true)

        let resolved = SkyBridgeResourceBundleLocator.resolve(
            targetName: "SkyBridgeCore",
            in: [temporaryDirectory]
        )

        let resolvedURL = try XCTUnwrap(resolved?.bundleURL.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(
            resolvedURL.path,
            stagedBundle.standardizedFileURL.resolvingSymlinksInPath().path,
            "resolver must find a <Package>_<Target>.bundle staged in a candidate directory"
        )
    }

    func testResolvePrefersEarlierCandidateDirectory() throws {
        let firstDirectory = temporaryDirectory.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = temporaryDirectory.appendingPathComponent("second", isDirectory: true)
        for directory in [firstDirectory, secondDirectory] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(
                    "SkyBridgeCompassApp_SkyBridgeCore.bundle",
                    isDirectory: true
                ),
                withIntermediateDirectories: true
            )
        }

        let resolved = SkyBridgeResourceBundleLocator.resolve(
            targetName: "SkyBridgeCore",
            in: [firstDirectory, secondDirectory]
        )

        let resolvedURL = try XCTUnwrap(resolved?.bundleURL.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertTrue(
            resolvedURL.path.hasPrefix(
                firstDirectory.standardizedFileURL.resolvingSymlinksInPath().path
            ),
            "resolver must honour candidate-directory priority order"
        )
    }

    func testResolveReturnsNilInsteadOfTrappingWhenBundleIsMissing() {
        // The critical regression case: no bundle anywhere. The SwiftPM
        // accessor would fatalError here; the locator must simply return nil.
        let resolved = SkyBridgeResourceBundleLocator.resolve(
            targetName: "SkyBridgeCore",
            in: [temporaryDirectory]
        )
        XCTAssertNil(resolved)
    }

    func testResolveIgnoresPlainFileMasqueradingAsBundle() throws {
        let impostor = temporaryDirectory.appendingPathComponent(
            "SkyBridgeCompassApp_SkyBridgeCore.bundle",
            isDirectory: false
        )
        try Data().write(to: impostor)

        let resolved = SkyBridgeResourceBundleLocator.resolve(
            targetName: "SkyBridgeCore",
            in: [temporaryDirectory]
        )
        XCTAssertNil(resolved, "a plain file must not be treated as a resource bundle")
    }

    // MARK: - Public accessor fallback semantics

    func testBundleForUnknownTargetFallsBackToMainWithoutTrapping() {
        // Launch must never die on a missing bundle: worst case is .main.
        let bundle = SkyBridgeResourceBundleLocator.bundle(
            forTarget: "TargetThatDoesNotExist\(UUID().uuidString.prefix(8))"
        )
        XCTAssertEqual(bundle, Bundle.main)
    }

    func testCoreAccessorNeverTrapsAndPrefersRealModuleBundle() {
        // Touching the cached accessor must never crash. Under `swift test`
        // the real SkyBridgeCompassApp_SkyBridgeCore.bundle sits next to the
        // .xctest bundle, so resolution should normally succeed; Bundle.main
        // remains the accepted degraded fallback.
        let core = SkyBridgeResourceBundleLocator.core
        let isRealModuleBundle =
            core.bundleURL.lastPathComponent == "SkyBridgeCompassApp_SkyBridgeCore.bundle"
        XCTAssertTrue(
            isRealModuleBundle || core == Bundle.main,
            "core accessor must resolve the module bundle or degrade to Bundle.main, got \(core.bundleURL.path)"
        )
    }

    func testAppAccessorNeverTraps() {
        let app = SkyBridgeResourceBundleLocator.app
        let isRealModuleBundle =
            app.bundleURL.lastPathComponent == "SkyBridgeCompassApp_SkyBridgeCompassApp.bundle"
        XCTAssertTrue(
            isRealModuleBundle || app == Bundle.main,
            "app accessor must resolve the module bundle or degrade to Bundle.main, got \(app.bundleURL.path)"
        )
    }

    // MARK: - Gate contract

    func testGateMarkerLiteralIsStable() {
        // Scripts/verify_app_resource_bundles.sh greps the packaged executable
        // for this literal to prove the non-trapping resolver shipped.
        XCTAssertEqual(SkyBridgeResourceBundleLocator.gateMarker, "SkyBridgeResourceBundleLocator/v1")
    }

    func testCandidateDirectoriesIncludeMainBundleLocationsAndAreUnique() {
        let candidates = SkyBridgeResourceBundleLocator.defaultCandidateDirectories()
        XCTAssertFalse(candidates.isEmpty)

        let paths = candidates.map(\.path)
        XCTAssertEqual(paths.count, Set(paths).count, "candidate directories must be de-duplicated")

        if let resourcePath = Bundle.main.resourceURL?.standardizedFileURL.path {
            XCTAssertTrue(
                paths.contains(resourcePath),
                "packaged-app Contents/Resources must be probed"
            )
        }
        XCTAssertTrue(
            paths.contains(Bundle.main.bundleURL.standardizedFileURL.path),
            "swift build executable-adjacent layout must be probed"
        )
    }
}
