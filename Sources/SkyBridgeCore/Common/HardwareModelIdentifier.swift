import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 本机硬件型号标识（`hw.model`，例如 "Mac16,7"）。
///
/// 仓库里曾有多份私有的 `sysctlbyname("hw.model")` 拷贝；身份、iCloud 设备链、CloudKit 与账号设备心跳
/// 现在都走这一份。不可用时返回 nil，绝不伪造型号。
public enum HardwareModelIdentifier {
    public static func current() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        let terminator = buffer.firstIndex(of: 0) ?? buffer.count
        let model = String(decoding: buffer[..<terminator], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? nil : model
    }
}
