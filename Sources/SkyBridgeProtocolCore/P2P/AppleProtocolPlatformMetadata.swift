import Foundation

/// Stable wire metadata. Localized OS display text must never enter version admission checks.
public enum AppleProtocolPlatformMetadata {
    public static func operatingSystemVersion(
        _ version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
