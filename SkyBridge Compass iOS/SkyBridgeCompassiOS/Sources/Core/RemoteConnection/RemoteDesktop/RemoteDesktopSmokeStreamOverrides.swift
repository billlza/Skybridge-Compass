#if DEBUG || SKYBRIDGE_TESTING
import Foundation

enum RemoteDesktopSmokeStreamOverrides {
    static func requestedDimensions(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (width: Int, height: Int)? {
        guard environment["SKYBRIDGE_SMOKE_ROLE"] != nil,
              let width = positiveInteger("SKYBRIDGE_SMOKE_VIDEO_WIDTH", environment: environment),
              let height = positiveInteger("SKYBRIDGE_SMOKE_VIDEO_HEIGHT", environment: environment) else {
            return nil
        }
        return (width, height)
    }

    static func targetFrameRate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        guard environment["SKYBRIDGE_SMOKE_ROLE"] != nil,
              let fps = positiveInteger("SKYBRIDGE_SMOKE_TARGET_FPS", environment: environment) else {
            return nil
        }
        return max(1, min(fps, 120))
    }

    private static func positiveInteger(
        _ name: String,
        environment: [String: String]
    ) -> Int? {
        guard let raw = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int(raw),
              value > 0 else {
            return nil
        }
        return value
    }
}
#endif
