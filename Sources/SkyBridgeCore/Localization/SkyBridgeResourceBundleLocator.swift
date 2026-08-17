import Foundation

/// Non-trapping resolver for SwiftPM `<Package>_<Target>.bundle` resource bundles.
///
/// Why this exists: the `swift build` code generation for `Bundle.module` only
/// probes two locations — `<Bundle.main.bundleURL>/<Package>_<Target>.bundle`
/// (the `.app` ROOT, which is never a valid staging location for a packaged
/// macOS app whose resource bundles live under `Contents/Resources`) and the
/// absolute build-machine scratch path baked in at compile time (for release
/// packaging that is `/tmp/skybridge-swiftpm-release-<arch>/...`, see
/// `Scripts/package_app.sh`). When both probes miss — i.e. on every end-user
/// machine where the build scratch directory does not exist — the generated
/// accessor calls `fatalError("could not load resource bundle: ...")`, which
/// took down the whole app at the first localization lookup (a 100% launch
/// crash for zh-Hans users, SIGTRAP inside the `NSBundle.module` one-time
/// initializer).
///
/// This locator probes every realistic staging location and NEVER traps: when
/// no module bundle can be found it logs once and falls back to `Bundle.main`,
/// so callers degrade to English/key-name lookups instead of crashing. Launch
/// must never die on a missing localization or shader bundle.
public enum SkyBridgeResourceBundleLocator {
    /// Marker literal asserted by the release packaging gate
    /// (`Scripts/verify_app_resource_bundles.sh`) via `strings` to prove the
    /// shipped executable contains this non-trapping resolver.
    /// Do not rename without updating that script.
    public static let gateMarker = "SkyBridgeResourceBundleLocator/v1"

    /// SwiftPM package names used to derive `<Package>_<Target>.bundle`
    /// directory names. `SkyBridgeCompassApp` is the root package's `name:` in
    /// `Package.swift`. If the package is ever renamed, append the new name
    /// here (keep the old ones) so mixed-generation bundles keep resolving.
    static let packageNames = ["SkyBridgeCompassApp"]

    /// Resource bundle for the `SkyBridgeCore` target. Never traps.
    public static let core: Bundle = bundle(forTarget: "SkyBridgeCore")

    /// Resource bundle for the `SkyBridgeCompassApp` executable target.
    /// Never traps.
    public static let app: Bundle = bundle(forTarget: "SkyBridgeCompassApp")

    /// Resolves the resource bundle for `targetName`, falling back to
    /// `Bundle.main` when no candidate location contains it.
    public static func bundle(forTarget targetName: String) -> Bundle {
        if let resolved = resolve(targetName: targetName, in: defaultCandidateDirectories()) {
            return resolved
        }
        // Intentional soft failure: the packaged app also stages
        // en/ja/zh-Hans.lproj and default.metallib at the top level of
        // Contents/Resources, so `Bundle.main` remains a usable degraded
        // source. The interpolated marker keeps the gate literal alive in the
        // shipped binary.
        NSLog(
            "%@",
            "\(gateMarker): module bundle for target \(targetName) not found; falling back to Bundle.main"
        )
        return .main
    }

    /// Pure search step, separated for unit testing: returns the first
    /// `<Package>_<Target>.bundle` directory found under `candidateDirectories`.
    static func resolve(targetName: String, in candidateDirectories: [URL]) -> Bundle? {
        let fileManager = FileManager.default
        for directory in candidateDirectories {
            for packageName in packageNames {
                let bundleURL = directory.appendingPathComponent(
                    "\(packageName)_\(targetName).bundle",
                    isDirectory: true
                )
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory),
                      isDirectory.boolValue,
                      let bundle = Bundle(url: bundleURL) else {
                    continue
                }
                return bundle
            }
        }
        return nil
    }

    /// Candidate directories covering every supported launch layout, most
    /// specific first.
    static func defaultCandidateDirectories() -> [URL] {
        var candidates: [URL] = []
        var seenPaths = Set<String>()

        func append(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            guard seenPaths.insert(standardized.path).inserted else { return }
            candidates.append(standardized)
        }

        let hostBundle = Bundle(for: BundleLocatorToken.self)

        // 1. Packaged .app: Contents/Resources — the canonical staging
        //    location used by Scripts/package_app.sh.
        append(Bundle.main.resourceURL)
        // 2. Resources of the bundle hosting this module (framework builds,
        //    XCTest bundles, SwiftUI previews).
        append(hostBundle.resourceURL)
        // 3. `swift build` layout: bundles sit next to the executable — this
        //    is the location probed by the SwiftPM-generated accessor.
        append(Bundle.main.bundleURL)
        append(hostBundle.bundleURL)
        // 4. `swift test` layout: bundles sit next to the `.xctest` bundle in
        //    the build directory.
        append(hostBundle.bundleURL.deletingLastPathComponent())
        // 5. Directory containing the running executable (CLI tools and
        //    helper binaries linking SkyBridgeCore).
        append(Bundle.main.executableURL?.deletingLastPathComponent())

        return candidates
    }
}

/// Class token so `Bundle(for:)` can identify the binary hosting this module.
private final class BundleLocatorToken {}
