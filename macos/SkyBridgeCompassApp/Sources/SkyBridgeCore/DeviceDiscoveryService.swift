import Foundation
import Combine
import Network
import os.log

public struct DiscoveryState {
    public var devices: [DiscoveredDevice]
    public var statusDescription: String

    public init(devices: [DiscoveredDevice], statusDescription: String) {
        self.devices = devices
        self.statusDescription = statusDescription
    }
}

public final class DeviceDiscoveryService {
    private let queue = DispatchQueue(label: "skybridge.discovery")
    private let browsers: [String: NWBrowser]
    private var latestResults: [String: Set<NWBrowser.Result>] = [:]
    private let subject = CurrentValueSubject<DiscoveryState, Never>(.init(devices: [], statusDescription: "初始化扫描"))
    private let log = Logger(subsystem: "com.skybridge.compass", category: "Discovery")

    public var discoveryState: AnyPublisher<DiscoveryState, Never> {
        subject.eraseToAnyPublisher()
    }

    public init() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let bonjourTypes = ["_rdp._tcp.", "_rfb._tcp.", "_skybridge._tcp."]
        var created: [String: NWBrowser] = [:]
        for type in bonjourTypes {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: parameters)
            created[type] = browser
            latestResults[type] = []
        }
        browsers = created
    }

    public func start() async {
        subject.send(.init(devices: [], statusDescription: "正在发现局域网设备"))
        for (type, browser) in browsers {
            browser.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.log.info("Bonjour discovery ready for %{public}@", type)
                case .failed(let error):
                    self.log.error("Discovery failed: %{public}@", error.localizedDescription)
                    self.subject.send(.init(devices: [], statusDescription: "扫描失败: \(error.localizedDescription)"))
                default:
                    break
                }
            }

            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self = self else { return }
                self.latestResults[type] = Set(results)
                self.publishResults()
            }

            browser.start(queue: queue)
        }
    }

    private func publishResults() {
        let mapped: [DiscoveredDevice] = latestResults.values.flatMap { $0 }.compactMap { result in
            guard case let NWEndpoint.service(name: name, type: type, domain: _, interface: _) = result.endpoint else {
                return nil
            }

            var ipv4: String?
            var ipv6: String?
            var portMap: [String: Int] = [:]

            for endpoint in result.endpoints {
                switch endpoint {
                case let .hostPort(host: .ipv4(address), port: port):
                    ipv4 = address.debugDescription
                    portMap[type] = Int(port.rawValue)
                case let .hostPort(host: .ipv6(address), port: port):
                    ipv6 = address.debugDescription
                    portMap[type] = Int(port.rawValue)
                default:
                    break
                }
            }

            return DiscoveredDevice(
                id: UUID(),
                name: name,
                ipv4: ipv4,
                ipv6: ipv6,
                services: [type],
                portMap: portMap
            )
        }

        subject.send(
            .init(
                devices: mapped,
                statusDescription: mapped.isEmpty ? "扫描中，无设备响应" : "发现 \(mapped.count) 台真实设备"
            )
        )
    }

    public func refresh() {
        subject.send(.init(devices: [], statusDescription: "重新扫描中"))
        for (_, browser) in browsers {
            browser.cancel()
            browser.start(queue: queue)
        }
    }

    public func stop() {
        for (_, browser) in browsers {
            browser.cancel()
        }
        subject.send(.init(devices: [], statusDescription: "扫描已停止"))
    }
}
