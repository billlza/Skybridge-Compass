import Foundation

/// Product-platform metadata admitted for Q-Periapt ABI2 pairing and handshakes.
/// Native capability, authenticated policy, and protocol identity remain separate
/// mandatory checks; a platform string alone never enables Q-Periapt.
public enum QPeriaptPeerPlatformPolicy {
    public static func isPeerAppPlatformEligible(
        platform: String?,
        osVersion: String?
    ) -> Bool {
        guard let platform, let osVersion,
              let family = Family(platform: platform),
              !osVersion.isEmpty else { return false }
        let version = osVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let completeVersion: String
        if version.first?.isASCII == true, version.first?.isNumber == true {
            guard family != .android else { return false }
            completeVersion = "\(family.capabilityName) \(version)"
        } else {
            completeVersion = version
        }
        return eligibleFamily(in: completeVersion) == family
    }

    public static func isPeerHandshakePlatformVersionEligible(_ version: String?) -> Bool {
        guard let version else { return false }
        return eligibleFamily(in: version) != nil
    }

    private static func eligibleFamily(in value: String) -> Family? {
        guard value.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        let words = value.lowercased().split(whereSeparator: \.isWhitespace)
        guard let first = words.first else { return nil }
        let family: Family
        let versionIndex: Int
        if first == "mac", words.count >= 2, words[1] == "os" {
            family = .macOS
            versionIndex = 2
        } else {
            guard let parsed = Family(platform: String(first)) else { return nil }
            family = parsed
            versionIndex = 1
        }
        guard words.indices.contains(versionIndex) else { return nil }
        let version = words[versionIndex]
        switch family {
        case .iOS, .macOS:
            guard words.count == versionIndex + 1,
                  let components = appleVersion(version),
                  components[0] >= 26 else { return nil }
        case .android:
            guard let components = appleVersion(version), components[0] >= 16,
                  words.count > versionIndex + 1 else { return nil }
            var apiClause = words[(versionIndex + 1)...].joined(separator: " ")
            if apiClause.hasPrefix("("), apiClause.hasSuffix(")") {
                apiClause.removeFirst()
                apiClause.removeLast()
                apiClause = apiClause.trimmingCharacters(in: .whitespaces)
            }
            guard apiClause.hasPrefix("api"),
                  let api = number(
                    apiClause.dropFirst(3).trimmingCharacters(in: .whitespaces),
                    maximumDigits: 3,
                    allowsLeadingZeroes: true
                  ), api >= 36 else { return nil }
        case .ubuntu:
            guard words.count == versionIndex + 1, isSupportedUbuntuVersion(version) else { return nil }
        case .windows:
            guard words.count == versionIndex + 1, isSupportedWindowsVersion(version) else { return nil }
        }
        return family
    }

    private static func appleVersion(_ value: Substring) -> [Int]? {
        let components = value.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return nil }
        var result: [Int] = []
        for component in components {
            guard let parsed = number(component, maximumDigits: 3, allowsLeadingZeroes: true) else {
                return nil
            }
            result.append(parsed)
        }
        return result
    }

    private static func isSupportedUbuntuVersion(_ value: Substring) -> Bool {
        let components = value.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false)
        guard (2...3).contains(components.count), components[1].count == 2,
              let major = number(components[0], maximumDigits: 3),
              let month = number(components[1], maximumDigits: 2, allowsLeadingZeroes: true),
              (1...12).contains(month),
              major > 24 || (major == 24 && month >= 4) else { return false }
        return components.count == 2 || number(components[2], maximumDigits: 3) != nil
    }

    private static func isSupportedWindowsVersion(_ value: Substring) -> Bool {
        let components = value.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false)
        guard components.count == 3, components[0] == "10", components[1] == "0",
              let build = number(components[2], maximumDigits: 10),
              build >= 19_041, build <= Int(Int32.max) else { return false }
        return true
    }

    private static func number<S: StringProtocol>(
        _ value: S,
        maximumDigits: Int,
        allowsLeadingZeroes: Bool = false
    ) -> Int? {
        guard !value.isEmpty, value.utf8.count <= maximumDigits,
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              allowsLeadingZeroes || value.count == 1 || value.first != "0" else { return nil }
        return Int(value)
    }

    private enum Family: Equatable {
        case iOS
        case macOS
        case android
        case ubuntu
        case windows

        init?(platform: String) {
            switch platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "ios": self = .iOS
            case "macos", "mac os": self = .macOS
            case "android": self = .android
            case "ubuntu": self = .ubuntu
            case "windows": self = .windows
            default: return nil
            }
        }

        var capabilityName: String {
            switch self {
            case .iOS: return "iOS"
            case .macOS: return "macOS"
            case .android: return "Android"
            case .ubuntu: return "Ubuntu"
            case .windows: return "Windows"
            }
        }
    }
}
