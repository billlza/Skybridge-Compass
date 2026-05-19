import CryptoKit
import Darwin
import Foundation
import Network

enum CrossNetworkConnectionRuntimeSupport {
    static func deviceFingerprint(
        localizedName: String? = Host.current().localizedName,
        hostName: String = ProcessInfo.processInfo.hostName
    ) -> String {
        let deviceInfo = "\(localizedName ?? "")\(hostName)"
        let hash = SHA256.hash(data: Data(deviceInfo.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined().prefix(16).uppercased()
    }

    static func localIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return addresses
        }
        defer { freeifaddrs(ifaddr) }

        var current: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let ptr = current {
            let interface = ptr.pointee
            current = interface.ifa_next
            guard let addressPtr = interface.ifa_addr,
                  let name = decodeOptionalCString(interface.ifa_name) else { continue }
            let addrFamily = addressPtr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        addressPtr,
                        socklen_t(addressPtr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    let address = String(
                        decoding: hostname.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                        as: UTF8.self
                    )
                    if shouldIncludeLocalIPv4Address(interfaceName: name, address: address) {
                        addresses.append(address)
                    }
                }
            }
        }

        return addresses
    }

    static func shouldIncludeLocalIPv4Address(interfaceName: String, address: String) -> Bool {
        (interfaceName.hasPrefix("en") || interfaceName.hasPrefix("bridge"))
            && !address.isEmpty
            && !address.hasPrefix("127.")
    }

    static func waitForConnection(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            final class ResumeState: @unchecked Sendable {
                let lock = NSLock()
                var didResume = false
            }
            let resumeState = ResumeState()
            connection.stateUpdateHandler = { state in
                let completion: Result<Void, Error>?
                resumeState.lock.lock()
                switch state {
                case .ready:
                    guard !resumeState.didResume else {
                        resumeState.lock.unlock()
                        return
                    }
                    resumeState.didResume = true
                    completion = .success(())
                case .failed(let error):
                    guard !resumeState.didResume else {
                        resumeState.lock.unlock()
                        return
                    }
                    resumeState.didResume = true
                    completion = .failure(error)
                default:
                    completion = nil
                }
                resumeState.lock.unlock()
                guard let completion else { return }
                connection.stateUpdateHandler = nil
                switch completion {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
