import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

public enum LocalDevicePresentation {
    public struct Snapshot: Sendable, Equatable {
        public let deviceName: String?
        public let modelName: String?
        public let platformName: String
        public let osVersion: String
    }

    public static func current(
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) -> Snapshot {
        #if os(macOS)
        return Snapshot(
            deviceName: Host.current().localizedName,
            modelName: "Mac",
            platformName: "macOS",
            osVersion: osVersion
        )
        #elseif os(iOS)
        let rawName = currentUIKitDeviceName()
        let model = currentAppleMobileModelName()
        let platform = currentUIKitUserInterfaceIdiom() == .pad ? "iPadOS" : "iOS"
        return Snapshot(
            deviceName: displayDeviceName(rawDeviceName: rawName, modelName: model, platformName: platform),
            modelName: model,
            platformName: platform,
            osVersion: osVersion
        )
        #else
        return Snapshot(
            deviceName: nil,
            modelName: nil,
            platformName: "unknown",
            osVersion: osVersion
        )
        #endif
    }

    public static func displayDeviceName(
        rawDeviceName: String?,
        modelName: String?,
        platformName: String
    ) -> String? {
        if let raw = sanitizedDisplayNameCandidate(rawDeviceName),
           !isGenericAppleSystemDeviceName(raw, platformName: platformName) {
            return raw
        }

        let model = modelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !model.isEmpty, !isIdentifierLikeDisplayName(model) {
            return model
        }

        if platformName.localizedCaseInsensitiveContains("ipad") {
            return "iPad"
        }
        if platformName.localizedCaseInsensitiveContains("ios") {
            return "iPhone"
        }
        return nil
    }

    public static func sanitizedDisplayNameCandidate(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !isIdentifierLikeDisplayName(value) else {
            return nil
        }
        return value
    }

    public static func isGenericAppleSystemDeviceName(
        _ raw: String,
        platformName: String
    ) -> Bool {
        let normalized = normalizedNameToken(raw)
        if platformName.localizedCaseInsensitiveContains("ipad") {
            return normalized == "ipad"
                || normalized == "iosdevice"
                || normalized == "appledevice"
        }
        if platformName.localizedCaseInsensitiveContains("ios")
            || platformName.localizedCaseInsensitiveContains("iphone") {
            return normalized == "iphone"
                || normalized == "ipodtouch"
                || normalized == "iosdevice"
                || normalized == "appledevice"
        }
        return normalized == "unknown"
            || normalized == "unknowndevice"
            || normalized == "appledevice"
    }

    public static func isIdentifierLikeDisplayName(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let lowercased = value.lowercased()

        if lowercased.hasPrefix("id:")
            || lowercased.hasPrefix("fp:")
            || lowercased.hasPrefix("peer:")
            || lowercased.hasPrefix("host:")
            || lowercased.hasPrefix("ip:")
            || lowercased.hasPrefix("serial:")
            || lowercased.hasPrefix("mac:")
            || lowercased.hasPrefix("bonjour:")
            || lowercased.hasPrefix("recent:")
            || lowercased.hasPrefix("cross-network:")
            || lowercased.hasPrefix("webrtc-") {
            return true
        }

        if value.range(
            of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }

        if value.range(of: "^[0-9A-Fa-f]{24,128}$", options: .regularExpression) != nil {
            return true
        }

        if value.count >= 32,
           value.range(of: "^[A-Za-z0-9+/=_-]+$", options: .regularExpression) != nil,
           appleDeviceFamilyToken(value) == nil {
            return true
        }

        if IPv4Address(value) != nil || IPv6Address(value) != nil {
            return true
        }

        return false
    }

    private static func appleDeviceFamilyToken(_ raw: String) -> String? {
        let normalized = normalizedNameToken(raw)
        if normalized.contains("ipad") || normalized.contains("ipados") {
            return "ipad"
        }
        if normalized.contains("iphone") || normalized.contains("ios") {
            return "iphone"
        }
        if normalized.contains("macbook")
            || normalized.contains("imac")
            || normalized.contains("macos")
            || normalized == "mac"
            || normalized.hasPrefix("macmini")
            || normalized.hasPrefix("macstudio")
            || normalized.hasPrefix("macpro") {
            return "mac"
        }
        return nil
    }

    private static func normalizedNameToken(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    #if os(iOS)
    private static func currentAppleMobileModelName() -> String {
        let identifier = currentModelIdentifier()
        switch identifier {
        case "iPhone17,1":
            return "iPhone 16 Pro"
        case "iPhone17,2":
            return "iPhone 16 Pro Max"
        case "iPhone17,3":
            return "iPhone 16"
        case "iPhone17,4":
            return "iPhone 16 Plus"
        case "iPad16,3", "iPad16,4":
            return "iPad Pro 11-inch (M4)"
        default:
            return identifier.isEmpty ? currentUIKitModelName() : identifier
        }
    }

    private static func currentModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
                String(cString: ptr)
            }
        }
    }

    private static func currentUIKitUserInterfaceIdiom() -> UIUserInterfaceIdiom {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                UIDevice.current.userInterfaceIdiom
            }
        }
        return DispatchQueue.main.sync {
            UIDevice.current.userInterfaceIdiom
        }
    }

    private static func currentUIKitDeviceName() -> String {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                UIDevice.current.name
            }
        }
        return DispatchQueue.main.sync {
            UIDevice.current.name
        }
    }

    private static func currentUIKitModelName() -> String {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                UIDevice.current.model
            }
        }
        return DispatchQueue.main.sync {
            UIDevice.current.model
        }
    }

    #endif
}
