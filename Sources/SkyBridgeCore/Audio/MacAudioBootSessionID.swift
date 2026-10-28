import Foundation
import Darwin

enum MacAudioBootSessionID {
    enum Failure: Error { case unavailable(Int32), invalidValue }

    /// This Mac-only kernel UUID survives process restart and changes on reboot.
    /// No wall-time reconstruction or iOS sysctl assumption is permitted here.
    static func read() throws -> UUID {
        var buffer = [CChar](repeating: 0, count: 64)
        var size = buffer.count
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
            throw Failure.unavailable(errno)
        }
        guard size == 37, buffer[36] == 0,
              let value = UUID(uuidString: String(decoding: buffer.prefix(36).map { UInt8(bitPattern: $0) }, as: UTF8.self)),
              value != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw Failure.invalidValue
        }
        return value
    }
}
