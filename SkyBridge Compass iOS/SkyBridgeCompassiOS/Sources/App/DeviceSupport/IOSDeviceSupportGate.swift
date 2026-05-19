import Foundation

#if os(iOS)
import Darwin

struct UnsupportedIOSDevice: Equatable {
    let modelIdentifier: String
    let displayName: String
}

enum IOSDeviceSupportGate {
    // Keep the App Store plist gate broad (A12 floor), then explicitly block the
    // last pre-2020 A12/A12X devices that still slip through.
    private static let blockedModelIdentifiers: Set<String> = [
        "iPhone11,2", // iPhone XS
        "iPhone11,4", // iPhone XS Max (China)
        "iPhone11,6", // iPhone XS Max
        "iPhone11,8", // iPhone XR
        "iPad8,1", // iPad Pro 11-inch (2018) Wi-Fi
        "iPad8,2", // iPad Pro 11-inch (2018) Wi-Fi + Cellular
        "iPad8,3", // iPad Pro 11-inch (2018) Wi-Fi
        "iPad8,4", // iPad Pro 11-inch (2018) Wi-Fi + Cellular
        "iPad8,5", // iPad Pro 12.9-inch (3rd gen, 2018) Wi-Fi
        "iPad8,6", // iPad Pro 12.9-inch (3rd gen, 2018) Wi-Fi + Cellular
        "iPad8,7", // iPad Pro 12.9-inch (3rd gen, 2018) Wi-Fi
        "iPad8,8", // iPad Pro 12.9-inch (3rd gen, 2018) Wi-Fi + Cellular
        "iPad11,1", // iPad mini (5th gen, 2019) Wi-Fi
        "iPad11,2", // iPad mini (5th gen, 2019) Wi-Fi + Cellular
        "iPad11,3", // iPad Air (3rd gen, 2019) Wi-Fi
        "iPad11,4" // iPad Air (3rd gen, 2019) Wi-Fi + Cellular
    ]

    static func currentUnsupportedDevice(processInfo: ProcessInfo = .processInfo) -> UnsupportedIOSDevice? {
        guard let modelIdentifier = currentModelIdentifier(processInfo: processInfo) else {
            return nil
        }
        return unsupportedDevice(forModelIdentifier: modelIdentifier)
    }

    static func unsupportedDevice(forModelIdentifier modelIdentifier: String) -> UnsupportedIOSDevice? {
        let normalized = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard blockedModelIdentifiers.contains(normalized) else {
            return nil
        }
        return UnsupportedIOSDevice(
            modelIdentifier: normalized,
            displayName: displayName(forModelIdentifier: normalized)
        )
    }

    static func isSupported(modelIdentifier: String) -> Bool {
        unsupportedDevice(forModelIdentifier: modelIdentifier) == nil
    }

    private static func currentModelIdentifier(processInfo: ProcessInfo) -> String? {
        #if targetEnvironment(simulator)
        if let simulatorModel = processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !simulatorModel.isEmpty {
            return simulatorModel
        }
        #endif

        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else {
            return nil
        }

        let identifier = withUnsafePointer(to: &systemInfo.machine) { machinePtr in
            machinePtr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }

        return identifier.isEmpty ? nil : identifier
    }

    private static func displayName(forModelIdentifier modelIdentifier: String) -> String {
        switch modelIdentifier {
        case "iPhone11,2": return "iPhone XS"
        case "iPhone11,4", "iPhone11,6": return "iPhone XS Max"
        case "iPhone11,8": return "iPhone XR"
        case "iPad8,1", "iPad8,2", "iPad8,3", "iPad8,4":
            return "iPad Pro 11-inch (2018)"
        case "iPad8,5", "iPad8,6", "iPad8,7", "iPad8,8":
            return "iPad Pro 12.9-inch (3rd generation)"
        case "iPad11,1", "iPad11,2":
            return "iPad mini (5th generation)"
        case "iPad11,3", "iPad11,4":
            return "iPad Air (3rd generation)"
        default:
            return modelIdentifier
        }
    }
}
#endif
