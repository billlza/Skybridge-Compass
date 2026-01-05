import Foundation
import Network
import OSLog
import SystemConfiguration

/// 设备名称解析器 - 基于用户论文的多平台设备识别策略
@MainActor
public class DeviceNameResolver: ObservableObject {
    
    private let logger = Logger(subsystem: "com.skybridge.discovery", category: "DeviceNameResolver")
    private var mdnsBrowsers: [NWBrowser] = []
    private var deviceInfoCache: [String: DeviceInfo] = [:]
    
 // 🔧 性能优化：DNS 查询并发控制（已优化参数以提高响应速度）
    private let dnsQuerySemaphore = DispatchSemaphore(value: 10) // 最多10个并发DNS查询（提高并发）
    private let dnsQueryTimeout: TimeInterval = 3.0 // 3秒超时（放宽以确保查询完成）
    private var dnsQueryCache: [String: (hostname: String?, timestamp: Date)] = [:]
    private let dnsCacheExpiration: TimeInterval = 180 // 3分钟缓存（缩短以更快刷新）
    
    public init() {}
    
 /// 设备信息结构体
    public struct DeviceInfo: Sendable {
        public let hostname: String
        public let deviceType: String
        public let osVersion: String?
        public let manufacturer: String?
        public let model: String?
        public let capabilities: [String]
        public let icon: String
        public let displayName: String
        public let lastUpdated: Date
        
        public init(hostname: String, deviceType: String, osVersion: String? = nil, 
                   manufacturer: String? = nil, model: String? = nil, capabilities: [String] = [],
                   icon: String = "questionmark.circle", displayName: String? = nil) {
            self.hostname = hostname
            self.deviceType = deviceType
            self.osVersion = osVersion
            self.manufacturer = manufacturer
            self.model = model
            self.capabilities = capabilities
            self.icon = icon
            self.displayName = displayName ?? hostname
            self.lastUpdated = Date()
        }
    }
    
 /// 解析设备信息的主要方法 - 基于用户论文的多重数据源策略
    public func resolveDeviceInfo(for ipAddress: String) async -> DeviceInfo? {
 // 检查缓存
        if let cachedInfo = deviceInfoCache[ipAddress] {
            return cachedInfo
        }
        
 // 多重数据源并行查询策略
        async let mdnsResult = performMDNSQuery(for: ipAddress)
        async let reverseDNSResult = performReverseDNSLookup(ipAddress)
        async let snmpResult = performSNMPQuery(for: ipAddress)
        
 // 等待所有查询完成
        let results = await (mdnsResult, reverseDNSResult, snmpResult)
        
 // 优先使用mDNS结果，然后是SNMP，最后是反向DNS
        var finalResult: DeviceInfo?
        
        if let mdnsInfo = results.0 {
            finalResult = mdnsInfo
        } else if let snmpInfo = results.2 {
            finalResult = snmpInfo
        } else if let hostname = results.1 {
 // 使用增强的设备类型检测
            let enhancedInfo = enhanceDeviceTypeFromName(hostname)
            finalResult = DeviceInfo(
                hostname: hostname,
                deviceType: enhancedInfo.deviceType.isEmpty ? determineDeviceType(from: hostname) : enhancedInfo.deviceType,
                manufacturer: enhancedInfo.brand,
                icon: getIconForDeviceType(enhancedInfo.deviceType.isEmpty ? determineDeviceType(from: hostname) : enhancedInfo.deviceType)
            )
        }
        
 // 如果所有方法都失败，创建默认设备信息
        if finalResult == nil {
            let defaultName = generateDefaultDeviceName(for: ipAddress, hostname: nil)
            let enhancedInfo = enhanceDeviceTypeFromName(defaultName)
            finalResult = DeviceInfo(
                hostname: defaultName,
                deviceType: enhancedInfo.deviceType.isEmpty ? "未知设备" : enhancedInfo.deviceType,
                manufacturer: enhancedInfo.brand,
                icon: "questionmark.circle"
            )
        }
        
 // 缓存结果
        if let result = finalResult {
            deviceInfoCache[ipAddress] = result
        }
        
        return finalResult
    }
    
 /// 执行反向DNS查询（带超时和并发控制）
 /// 🔧 性能优化：添加超时机制、并发限制和缓存
    private func performReverseDNSLookup(_ ipAddress: String) async -> String? {
 // 检查缓存
        if let cached = dnsQueryCache[ipAddress] {
            let age = Date().timeIntervalSince(cached.timestamp)
            if age < dnsCacheExpiration {
                logger.debug("📦 DNS缓存命中: \(ipAddress)")
                return cached.hostname
            }
        }
        
        logger.debug("🔍 开始DNS反向查询: \(ipAddress)")
        
 // 使用 超时机制
        let result = await withTaskGroup(of: String?.self) { group in
 // 添加 DNS 查询任务
            group.addTask {
                return await self.performDNSQueryWithSemaphore(ipAddress)
            }
            
 // 添加超时任务
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(self.dnsQueryTimeout * 1_000_000_000))
                return nil // 超时返回 nil
            }
            
 // 返回第一个完成的结果
            if let firstResult = await group.next() {
                group.cancelAll()
                return firstResult
            }
            return nil
        }
        
 // 更新缓存
        dnsQueryCache[ipAddress] = (hostname: result, timestamp: Date())
        
        if result == nil {
            logger.debug("⏱️ DNS查询超时或失败: \(ipAddress)")
        } else {
            logger.debug("✅ DNS查询成功: \(ipAddress) -> \(result ?? "nil")")
        }
        
        return result
    }
    
 /// 使用信号量控制的DNS查询
    private func performDNSQueryWithSemaphore(_ ipAddress: String) async -> String? {
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue.global(qos: .utility) // 降低优先级
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                
 // 获取信号量（限制并发）
                self.dnsQuerySemaphore.wait()
                
                defer {
 // 释放信号量
                    self.dnsQuerySemaphore.signal()
                }
                
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(ipAddress, nil, &hints, &result)
                
                defer {
                    if let result = result {
                        freeaddrinfo(result)
                    }
                }
                
                if status == 0, let addr = result {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let status = getnameinfo(addr.pointee.ai_addr, addr.pointee.ai_addrlen,
                                           &hostname, socklen_t(hostname.count),
                                           nil, 0, NI_NAMEREQD)
                    
                    if status == 0 {
                        let bytes = Data(bytes: hostname, count: hostname.count)
                        let trimmed = bytes.prefix { $0 != 0 }
                        let hostnameString = String(decoding: trimmed, as: UTF8.self)
                        continuation.resume(returning: hostnameString.isEmpty ? nil : hostnameString)
                    } else {
                        continuation.resume(returning: nil)
                    }
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
 /// 执行增强的mDNS查询 - 基于用户论文的Apple设备优先策略
    private func performMDNSQuery(for ipAddress: String) async -> DeviceInfo? {
 // 基于用户论文的增强服务类型列表，优先查询Apple设备专用服务
        let enhancedServiceTypes = [
            "_companion-link._tcp",      // Apple设备连接服务 - 最可靠的Apple设备标识
            "_apple-mobdev2._tcp",       // Apple移动设备服务
            "_airplay._tcp",             // AirPlay服务
            "_raop._tcp",                // 远程音频输出协议
            "_homekit._tcp",             // HomeKit设备
            "_device-info._tcp",         // 设备信息服务
            "_http._tcp",                // HTTP服务
            "_https._tcp",               // HTTPS服务
            "_ssh._tcp",                 // SSH服务
            "_smb._tcp",                 // SMB文件共享
            "_afpovertcp._tcp",          // Apple文件协议
            "_printer._tcp",             // 打印机服务
            "_ipp._tcp",                 // Internet打印协议
            "_scanner._tcp",             // 扫描仪服务
            "_workstation._tcp"          // 工作站服务
        ]
        
 // 智能并发策略：优先查询Apple服务
        let appleServices = Array(enhancedServiceTypes.prefix(5))
        let otherServices = Array(enhancedServiceTypes.dropFirst(5))
        
 // 首先查询Apple专用服务
        for serviceType in appleServices {
            if let result = await queryServiceTypeEnhanced(serviceType, targetIP: ipAddress) {
                return result
            }
        }
        
 // 然后并行查询其他服务
        return await withTaskGroup(of: DeviceInfo?.self) { group in
            for serviceType in otherServices {
                group.addTask {
                    await self.queryServiceTypeEnhanced(serviceType, targetIP: ipAddress)
                }
            }
            
            for await result in group {
                if let deviceInfo = result {
                    return deviceInfo
                }
            }
            return nil
        }
    }
    
 /// 增强的服务类型查询方法
    private func queryServiceTypeEnhanced(_ serviceType: String, targetIP: String) async -> DeviceInfo? {
        return await withCheckedContinuation { continuation in
            let continuationBox = ContinuationBox(continuation)
            
 // 使用2025年最佳配置的NWParameters
            let parameters = NWParameters()
            parameters.includePeerToPeer = true
            parameters.allowLocalEndpointReuse = true
            
 // 设置更宽松的网络接口选择
            if #available(macOS 12.0, *) {
                parameters.requiredInterfaceType = .other
            }
            
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)
            
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    self.logger.error("mDNS浏览器失败: \(error.localizedDescription)")
                    if continuationBox.tryResume(with: nil) {
                        browser.cancel()
                    }
                default:
                    break
                }
            }
            
            browser.browseResultsChangedHandler = { results, changes in
                Task {
                    for result in results {
 // 使用增强的IP匹配逻辑
                        if await self.isMatchingDeviceByIP(result: result, targetIP: targetIP) {
                            if let deviceInfo = await self.processDiscoveryResultEnhanced(result, targetIP: targetIP, serviceType: serviceType) {
                                if continuationBox.tryResume(with: deviceInfo) {
                                    browser.cancel()
                                    return
                                }
                            }
                        }
                    }
                }
            }
            
            browser.start(queue: .global(qos: .userInitiated))
            
 // 使用 .sleep 实现超时，并可与上层取消协同
            Task {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if continuationBox.tryResume(with: nil) {
                    browser.cancel()
                }
            }
        }
    }
    
 /// 线程安全的Continuation包装器
    private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
        private var continuation: CheckedContinuation<T, Never>?
        private let lock = NSLock()
        
        init(_ continuation: CheckedContinuation<T, Never>) {
            self.continuation = continuation
        }
        
        func tryResume(with value: T) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            
            if let continuation = self.continuation {
                self.continuation = nil
                continuation.resume(returning: value)
                return true
            }
            return false
        }
    }
    
 /// 增强的发现结果处理方法
    private func processDiscoveryResultEnhanced(_ result: NWBrowser.Result, targetIP: String, serviceType: String) async -> DeviceInfo? {
        let serviceName = result.endpoint.debugDescription
        let realDeviceName = extractRealDeviceName(from: serviceName)
        let deviceType = determineDeviceTypeFromService(serviceType: serviceType, serviceName: serviceName)
        
 // 基于用户论文的设备信息提取策略
        let (parsedType, manufacturer, model) = parseAppleDeviceInfo(name: realDeviceName)
        let finalDeviceType = parsedType.isEmpty ? deviceType : parsedType
        
        return DeviceInfo(
            hostname: realDeviceName,
            deviceType: finalDeviceType,
            manufacturer: manufacturer,
            model: model,
            capabilities: extractCapabilities(from: serviceType),
            icon: getIconForDeviceType(finalDeviceType),
            displayName: realDeviceName
        )
    }
    
 /// 从服务名称中提取真实设备名称 - 基于用户论文的Apple设备命名格式解析
    private nonisolated func extractRealDeviceName(from serviceName: String) -> String {
 // 移除常见的服务前缀和后缀
        var cleanName = serviceName
            .replacingOccurrences(of: "._tcp.local.", with: "")
            .replacingOccurrences(of: "._udp.local.", with: "")
            .replacingOccurrences(of: ".local", with: "")
            .replacingOccurrences(of: "._tcp", with: "")
            .replacingOccurrences(of: "._udp", with: "")
        
 // 处理URL编码
        if let decodedName = cleanName.removingPercentEncoding {
            cleanName = decodedName
        }
        
 // 尝试解析Apple设备标准命名格式
        if let appleDeviceName = parseAppleDeviceNameFormat(cleanName) {
            return appleDeviceName
        }
        
 // 尝试提取用户设备名称
        if let userDeviceName = extractUserDeviceName(from: cleanName) {
            return userDeviceName
        }
        
 // 处理无意义的名称
        let meaninglessNames = ["localhost", "bogon", "unknown", "device", "host"]
        if meaninglessNames.contains(cleanName.lowercased()) || cleanName.isEmpty {
            return "未知设备"
        }
        
        return cleanName
    }
    
 /// 解析Apple设备标准命名格式 - 基于用户论文的命名规则
    private nonisolated func parseAppleDeviceNameFormat(_ name: String) -> String? {
 // Apple设备命名格式：用户名's 设备类型 型号
 // 例如：Ziang's iPhone 16 Pro, John's MacBook Pro
        let patterns = [
            #"^(.+)'s\s+(iPhone|iPad|Mac|MacBook|Apple\s*TV|HomePod|Apple\s*Watch)\s*(.*)$"#,
            #"^(.+)的\s*(iPhone|iPad|Mac|MacBook|Apple\s*TV|HomePod|Apple\s*Watch)\s*(.*)$"#,
            #"^(.+)\s+(iPhone|iPad|Mac|MacBook|Apple\s*TV|HomePod|Apple\s*Watch)\s*(.*)$"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: name.utf16.count)
                if let match = regex.firstMatch(in: name, options: [], range: range) {
                    let userName = (name as NSString).substring(with: match.range(at: 1))
                    let deviceType = (name as NSString).substring(with: match.range(at: 2))
                    let model = match.numberOfRanges > 3 ? (name as NSString).substring(with: match.range(at: 3)) : ""
                    
                    if !model.isEmpty {
                        return "\(userName)的\(deviceType) \(model)".trimmingCharacters(in: .whitespaces)
                    } else {
                        return "\(userName)的\(deviceType)".trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }
        
        return nil
    }
    
 /// 从设备名称中提取用户信息
    private nonisolated func extractUserDeviceName(from name: String) -> String? {
 // 处理包含用户信息的设备名称
        let userPatterns = [
            #"^(.+)-iPhone$"#,
            #"^(.+)-iPad$"#,
            #"^(.+)-Mac$"#,
            #"^(.+)iPhone$"#,
            #"^(.+)iPad$"#,
            #"^(.+)Mac$"#
        ]
        
        for pattern in userPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: name.utf16.count)
                if let match = regex.firstMatch(in: name, options: [], range: range) {
                    let userName = (name as NSString).substring(with: match.range(at: 1))
                    return userName.trimmingCharacters(in: .whitespaces)
                }
            }
        }
        
        return nil
    }
    
 /// 根据服务类型确定设备类型 - 基于用户论文的智能识别
    private nonisolated func determineDeviceTypeFromService(serviceType: String, serviceName: String) -> String {
        let lowerServiceName = serviceName.lowercased()
        
 // 基于用户论文的多平台设备识别策略
        switch serviceType {
        case "_companion-link._tcp":
 // Apple设备连接服务 - 最可靠的Apple设备标识
            if lowerServiceName.contains("iphone") {
                return "iPhone"
            } else if lowerServiceName.contains("ipad") {
                return "iPad"
            } else if lowerServiceName.contains("mac") || lowerServiceName.contains("macbook") {
                return "Mac"
            } else if lowerServiceName.contains("watch") {
                return "Apple Watch"
            }
            return "Apple设备"
            
        case "_apple-mobdev2._tcp":
 // Apple移动设备服务
            return "Apple移动设备"
            
        case "_airplay._tcp", "_raop._tcp":
            if lowerServiceName.contains("appletv") {
                return "Apple TV"
            } else if lowerServiceName.contains("homepod") {
                return "HomePod"
            } else if lowerServiceName.contains("iphone") {
                return "iPhone"
            } else if lowerServiceName.contains("ipad") {
                return "iPad"
            } else if lowerServiceName.contains("mac") {
                return "Mac"
            }
            return "AirPlay设备"
            
        case "_homekit._tcp":
            return "HomeKit设备"
            
        case "_printer._tcp", "_ipp._tcp":
            return "打印机"
            
        case "_scanner._tcp":
            return "扫描仪"
            
        case "_smb._tcp", "_afpovertcp._tcp":
            if lowerServiceName.contains("nas") || lowerServiceName.contains("synology") || lowerServiceName.contains("qnap") {
                return "NAS存储"
            } else if lowerServiceName.contains("mac") || lowerServiceName.contains("apple") {
                return "Mac文件共享"
            }
            return "文件服务器"
            
        case "_ssh._tcp":
            if lowerServiceName.contains("raspberry") || lowerServiceName.contains("pi") {
                return "树莓派"
            } else if lowerServiceName.contains("linux") {
                return "Linux服务器"
            } else if lowerServiceName.contains("android") {
                return "Android设备"
            } else if lowerServiceName.contains("mac") {
                return "Mac"
            }
            return "SSH服务器"
            
        case "_http._tcp", "_https._tcp":
            if lowerServiceName.contains("router") || lowerServiceName.contains("gateway") {
                return "路由器"
            } else if lowerServiceName.contains("camera") || lowerServiceName.contains("webcam") {
                return "网络摄像头"
            } else if lowerServiceName.contains("android") {
                return "Android设备"
            } else if lowerServiceName.contains("windows") {
                return "Windows设备"
            }
            return "Web服务器"
            
        case "_workstation._tcp":
            if lowerServiceName.contains("windows") {
                return "Windows工作站"
            } else if lowerServiceName.contains("mac") {
                return "Mac工作站"
            }
            return "工作站"
            
        case "_device-info._tcp":
 // 设备信息服务通常包含更详细的设备类型信息
            return parseDeviceTypeFromDeviceInfo(serviceName)
            
        default:
 // 通用设备类型推断
            return inferDeviceTypeFromName(serviceName)
        }
    }
    
 /// 根据设备名称推断设备类型和品牌
    nonisolated private func enhanceDeviceTypeFromName(_ deviceName: String) -> (deviceType: String, brand: String?) {
        let lowercaseName = deviceName.lowercased()
        
 // HP设备识别
        if lowercaseName.hasPrefix("hp") {
            if lowercaseName.contains("laserjet") || lowercaseName.contains("deskjet") || 
               lowercaseName.contains("officejet") || lowercaseName.contains("envy") ||
               lowercaseName.contains("photosmart") {
                return ("HP打印机", "HP")
            }
            return ("HP网络设备", "HP")
        }
        
 // Canon设备识别
        if lowercaseName.hasPrefix("canon") || lowercaseName.contains("pixma") || 
           lowercaseName.contains("imageclass") {
            return ("Canon打印机", "Canon")
        }
        
 // Epson设备识别
        if lowercaseName.hasPrefix("epson") || lowercaseName.contains("workforce") ||
           lowercaseName.contains("expression") {
            return ("Epson打印机", "Epson")
        }
        
 // Brother设备识别
        if lowercaseName.hasPrefix("brother") || lowercaseName.contains("mfc") ||
           lowercaseName.contains("dcp") || lowercaseName.contains("hl-") {
            return ("Brother打印机", "Brother")
        }
        
 // Apple设备识别
        if lowercaseName.contains("iphone") {
            return ("iPhone", "Apple")
        } else if lowercaseName.contains("ipad") {
            return ("iPad", "Apple")
        } else if lowercaseName.contains("macbook") {
            return ("MacBook", "Apple")
        } else if lowercaseName.contains("imac") {
            return ("iMac", "Apple")
        } else if lowercaseName.contains("apple") {
            return ("Apple设备", "Apple")
        }
        
 // 路由器和网络设备识别
        if lowercaseName.contains("router") || lowercaseName.contains("gateway") ||
           lowercaseName.contains("netgear") || lowercaseName.contains("linksys") ||
           lowercaseName.contains("dlink") || lowercaseName.contains("tplink") ||
           lowercaseName.contains("asus") {
            return ("路由器", nil)
        }
        
 // Samsung设备识别
        if lowercaseName.contains("samsung") {
            return ("Samsung设备", "Samsung")
        }
        
 // LG设备识别
        if lowercaseName.contains("lg") {
            return ("LG设备", "LG")
        }
        
 // Sony设备识别
        if lowercaseName.contains("sony") {
            return ("Sony设备", "Sony")
        }
        
 // 通过设备名称模式识别
        if lowercaseName.contains("printer") {
            return ("打印机", nil)
        } else if lowercaseName.contains("server") {
            return ("服务器", nil)
        } else if lowercaseName.contains("nas") {
            return ("网络存储", nil)
        } else if lowercaseName.contains("camera") || lowercaseName.contains("cam") {
            return ("网络摄像头", nil)
        } else if lowercaseName.contains("tv") || lowercaseName.contains("smart") {
            return ("智能电视", nil)
        }
        
        return ("网络设备", nil)
    }
    
 /// 从设备信息服务中解析设备类型
    private nonisolated func parseDeviceTypeFromDeviceInfo(_ serviceName: String) -> String {
        let lowerName = serviceName.lowercased()
        
        if lowerName.contains("iphone") {
            return "iPhone"
        } else if lowerName.contains("ipad") {
            return "iPad"
        } else if lowerName.contains("mac") {
            return "Mac"
        } else if lowerName.contains("android") {
            return "Android设备"
        } else if lowerName.contains("windows") {
            return "Windows设备"
        } else if lowerName.contains("linux") {
            return "Linux设备"
        }
        
        return "智能设备"
    }
    
 /// 从设备名称推断设备类型
    private nonisolated func inferDeviceTypeFromName(_ serviceName: String) -> String {
        let lowerName = serviceName.lowercased()
        
 // Apple设备
        if lowerName.contains("iphone") {
            return "iPhone"
        } else if lowerName.contains("ipad") {
            return "iPad"
        } else if lowerName.contains("mac") || lowerName.contains("macbook") {
            return "Mac"
        } else if lowerName.contains("appletv") {
            return "Apple TV"
        } else if lowerName.contains("homepod") {
            return "HomePod"
        }
        
 // Android设备
        else if lowerName.contains("android") || lowerName.contains("samsung") || 
                lowerName.contains("xiaomi") || lowerName.contains("huawei") {
            return "Android设备"
        }
        
 // Windows设备
        else if lowerName.contains("windows") || lowerName.contains("pc") || 
                lowerName.contains("microsoft") {
            return "Windows设备"
        }
        
 // 网络设备
        else if lowerName.contains("router") || lowerName.contains("gateway") {
            return "路由器"
        } else if lowerName.contains("switch") {
            return "网络交换机"
        }
        
 // IoT设备
        else if lowerName.contains("camera") {
            return "网络摄像头"
        } else if lowerName.contains("speaker") {
            return "智能音箱"
        } else if lowerName.contains("tv") {
            return "智能电视"
        }
        
        return "网络设备"
    }
    
 /// 执行SNMP查询
    private func performSNMPQuery(for ipAddress: String) async -> DeviceInfo? {
        return await withCheckedContinuation { continuation in
            let continuationBox = ContinuationBox(continuation)
            
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/snmpget")
            task.arguments = ["-v2c", "-c", "public", ipAddress, "1.3.6.1.2.1.1.5.0"]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            
            do {
                try task.run()
                
                DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                    if task.isRunning {
                        task.terminate()
                        _ = continuationBox.tryResume(with: nil)
                    }
                }
                
                task.terminationHandler = { _ in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    
                    if let hostname = self.parseSNMPOutput(output) {
                        let deviceInfo = DeviceInfo(
                            hostname: hostname,
                            deviceType: self.determineDeviceType(from: hostname),
                            icon: self.getIconForDeviceType(self.determineDeviceType(from: hostname))
                        )
                        _ = continuationBox.tryResume(with: deviceInfo)
                    } else {
                        _ = continuationBox.tryResume(with: nil)
                    }
                }
            } catch {
                _ = continuationBox.tryResume(with: nil)
            }
        }
    }
    
 /// 增强的IP匹配逻辑
    private func isMatchingDeviceByIP(result: NWBrowser.Result, targetIP: String) async -> Bool {
 // 直接从服务名称中提取IP信息
        let serviceName = result.endpoint.debugDescription
        if serviceName.contains(targetIP) {
            return true
        }
        
 // 使用增强的服务IP解析
        return await resolveServiceIPEnhanced(result: result, targetIP: targetIP)
    }
    
 /// 增强的服务IP解析
    private func resolveServiceIPEnhanced(result: NWBrowser.Result, targetIP: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            let continuationBox = ContinuationBox(continuation)

            let rawConnection = NWConnection(to: result.endpoint, using: .tcp)
            let managed = SkyBridgeConnection(
                connection: rawConnection,
                queue: .global(qos: .utility)
            )

            managed.onStateUpdate { state in
                switch state {
                case .ready:
                    if let endpoint = managed.remoteEndpoint {
                        switch endpoint {
                        case .hostPort(let host, _):
                            let resolvedIP = "\(host)"
                            let matches = resolvedIP == targetIP
                            if continuationBox.tryResume(with: matches) {
                                managed.cancel()
                            }
                        default:
                            if continuationBox.tryResume(with: false) {
                                managed.cancel()
                            }
                        }
                    } else {
                        if continuationBox.tryResume(with: false) {
                            managed.cancel()
                        }
                    }
                case .failed(_):
                    if continuationBox.tryResume(with: false) {
                        managed.cancel()
                    }
                default:
                    break
                }
            }

            managed.start()
            
 // 设置超时
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
                if continuationBox.tryResume(with: false) {
                    managed.cancel()
                }
            }
        }
    }
    
 /// 获取设备类型对应的图标
    private nonisolated func getIconForDeviceType(_ deviceType: String) -> String {
        switch deviceType.lowercased() {
        case let type where type.contains("iphone"):
            return "iphone"
        case let type where type.contains("ipad"):
            return "ipad"
        case let type where type.contains("mac"):
            return "desktopcomputer"
        case let type where type.contains("apple tv"):
            return "appletv"
        case let type where type.contains("homepod"):
            return "homepod"
        case let type where type.contains("apple watch"):
            return "applewatch"
        case let type where type.contains("android"):
            return "smartphone"
        case let type where type.contains("windows"):
            return "pc"
        case let type where type.contains("打印机"):
            return "printer"
        case let type where type.contains("路由器"):
            return "wifi.router"
        case let type where type.contains("摄像头"):
            return "camera"
        case let type where type.contains("nas"):
            return "externaldrive"
        default:
            return "questionmark.circle"
        }
    }
    
 /// 从服务类型中提取设备能力
    private nonisolated func extractCapabilities(from serviceType: String) -> [String] {
        switch serviceType {
        case "_airplay._tcp":
            return ["AirPlay", "音频流", "视频流"]
        case "_printer._tcp", "_ipp._tcp":
            return ["打印"]
        case "_scanner._tcp":
            return ["扫描"]
        case "_smb._tcp", "_afpovertcp._tcp":
            return ["文件共享"]
        case "_ssh._tcp":
            return ["远程访问", "命令行"]
        case "_http._tcp", "_https._tcp":
            return ["Web服务"]
        case "_homekit._tcp":
            return ["HomeKit", "智能家居"]
        default:
            return []
        }
    }
    
 /// 解析Apple设备信息
    private nonisolated func parseAppleDeviceInfo(name: String) -> (deviceType: String, manufacturer: String?, model: String?) {
        let lowerName = name.lowercased()
        
        if lowerName.contains("iphone") {
            return ("iPhone", "Apple", extractiPhoneModel(from: name))
        } else if lowerName.contains("ipad") {
            return ("iPad", "Apple", extractiPadModel(from: name))
        } else if lowerName.contains("mac") {
            return ("Mac", "Apple", extractMacModel(from: name))
        }
        
        return ("", nil, nil)
    }
    
 /// 提取iPhone型号
    private nonisolated func extractiPhoneModel(from name: String) -> String? {
        let patterns = [
            #"iPhone\s*(\d+)\s*(Pro|Plus|Mini)?"#,
            #"iPhone\s*(SE|XR|XS|X)"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: name.utf16.count)
                if let match = regex.firstMatch(in: name, options: [], range: range) {
                    return (name as NSString).substring(with: match.range)
                }
            }
        }
        
        return nil
    }
    
 /// 提取iPad型号
    private nonisolated func extractiPadModel(from name: String) -> String? {
        let patterns = [
            #"iPad\s*(Pro|Air|Mini)?\s*(\d+)?"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: name.utf16.count)
                if let match = regex.firstMatch(in: name, options: [], range: range) {
                    return (name as NSString).substring(with: match.range)
                }
            }
        }
        
        return nil
    }
    
 /// 提取Mac型号
    private nonisolated func extractMacModel(from name: String) -> String? {
        let patterns = [
            #"MacBook\s*(Pro|Air)?"#,
            #"iMac\s*(Pro)?"#,
            #"Mac\s*(Pro|Mini|Studio)?"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: name.utf16.count)
                if let match = regex.firstMatch(in: name, options: [], range: range) {
                    return (name as NSString).substring(with: match.range)
                }
            }
        }
        
        return nil
    }
    
 /// 确定设备类型
    private nonisolated func determineDeviceType(from name: String) -> String {
        let lowerName = name.lowercased()
        
        if lowerName.contains("iphone") {
            return "iPhone"
        } else if lowerName.contains("ipad") {
            return "iPad"
        } else if lowerName.contains("mac") {
            return "Mac"
        } else if lowerName.contains("android") {
            return "Android设备"
        } else if lowerName.contains("windows") {
            return "Windows设备"
        } else if lowerName.contains("router") {
            return "路由器"
        } else if lowerName.contains("printer") {
            return "打印机"
        }
        
        return "网络设备"
    }
    
 /// 解析SNMP输出
    private nonisolated func parseSNMPOutput(_ output: String) -> String? {
 // 解析SNMP响应中的设备名称
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("STRING:") {
                let components = line.components(separatedBy: "STRING:")
                if components.count > 1 {
                    let hostname = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\"", with: "")
                    if !hostname.isEmpty {
                        return hostname
                    }
                }
            }
        }
        return nil
    }
    
 /// 生成默认设备名称
    private nonisolated func generateDefaultDeviceName(for ipAddress: String, hostname: String?) -> String {
        if let hostname = hostname, !hostname.isEmpty {
            return hostname
        }
        
 // 根据IP地址生成友好的设备名称
        let components = ipAddress.components(separatedBy: ".")
        if components.count == 4 {
            return "设备-\(components[2]).\(components[3])"
        }
        
        return "未知设备-\(ipAddress.suffix(6))"
    }
    
 /// 清除缓存
    public func clearCache() {
        deviceInfoCache.removeAll()
    }
    
 /// 获取缓存统计信息
    public func getCacheStats() -> (count: Int, oldestEntry: Date?) {
        let count = deviceInfoCache.count
        let oldestEntry = deviceInfoCache.values.map { $0.lastUpdated }.min()
        return (count, oldestEntry)
    }
}
