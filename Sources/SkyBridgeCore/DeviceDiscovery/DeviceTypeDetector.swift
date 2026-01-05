import Foundation
import Network
import OSLog

/// 设备类型检测器 - 智能识别设备类型和制造商
@MainActor
public class DeviceTypeDetector: ObservableObject {
    
 // MARK: - 私有属性
    private let logger = Logger(subsystem: "com.skybridge.discovery", category: "DeviceTypeDetector")
    
 // MARK: - 数据结构
    
 /// 详细设备信息
    public struct DetailedDeviceInfo {
        public let deviceType: DeviceType
        public let manufacturer: Manufacturer
        public let model: String?
        public let osVersion: String?
        public let capabilities: [String]
        public let icon: String
        public let displayName: String
        
        public init(deviceType: DeviceType, manufacturer: Manufacturer, model: String? = nil,
                   osVersion: String? = nil, capabilities: [String] = [], icon: String, displayName: String) {
            self.deviceType = deviceType
            self.manufacturer = manufacturer
            self.model = model
            self.osVersion = osVersion
            self.capabilities = capabilities
            self.icon = icon
            self.displayName = displayName
        }
    }
    
 /// 设备类型枚举
    public enum DeviceType: String, CaseIterable {
        case iPhone = "iPhone"
        case iPad = "iPad"
        case mac = "Mac"
        case appleTV = "Apple TV"
        case appleWatch = "Apple Watch"
        case androidPhone = "Android手机"
        case androidTablet = "Android平板"
        case windowsPC = "Windows电脑"
        case linuxPC = "Linux电脑"
        case router = "路由器"
        case printer = "打印机"
        case camera = "摄像头"
        case nas = "存储设备"
        case smartTV = "智能电视"
        case speaker = "音响设备"
        case iotDevice = "物联网设备"
        case gameConsole = "游戏主机"
        case unknown = "未知设备"
        
        public var displayName: String {
            return rawValue
        }
        
        public var icon: String {
            switch self {
            case .iPhone: return "iphone"
            case .iPad: return "ipad"
            case .mac: return "desktopcomputer"
            case .appleTV: return "appletv"
            case .appleWatch: return "applewatch"
            case .androidPhone: return "smartphone"
            case .androidTablet: return "tablet"
            case .windowsPC: return "pc"
            case .linuxPC: return "terminal"
            case .router: return "wifi.router"
            case .printer: return "printer"
            case .camera: return "camera"
            case .nas: return "externaldrive"
            case .smartTV: return "tv"
            case .speaker: return "speaker.wave.2"
            case .iotDevice: return "sensor"
            case .gameConsole: return "gamecontroller"
            case .unknown: return "questionmark.circle"
            }
        }
    }
    
 /// 制造商枚举
    public enum Manufacturer: String, CaseIterable {
        case apple = "Apple"
        case google = "Google"
        case samsung = "Samsung"
        case microsoft = "Microsoft"
        case huawei = "华为"
        case xiaomi = "小米"
        case oppo = "OPPO"
        case vivo = "vivo"
        case oneplus = "OnePlus"
        case sony = "Sony"
        case lg = "LG"
        case dell = "Dell"
        case hp = "HP"
        case lenovo = "联想"
        case asus = "华硕"
        case tplink = "TP-Link"
        case netgear = "NETGEAR"
        case linksys = "Linksys"
        case canon = "Canon"
        case epson = "Epson"
        case synology = "群晖"
        case qnap = "威联通"
        case unknown = "未知"
        
        public var displayName: String {
            return rawValue
        }
    }
    
 // MARK: - 公共方法
    
 /// 检测设备类型和详细信息
 /// - Parameters:
 /// - hostname: 设备主机名
 /// - ipAddress: 设备IP地址
 /// - macAddress: MAC地址（可选）
 /// - openPorts: 开放端口列表
 /// - Returns: 详细设备信息
    public func detectDeviceInfo(hostname: String?, ipAddress: String, 
                                macAddress: String? = nil, openPorts: [Int] = []) -> DetailedDeviceInfo {
        
 // 处理bogon主机名的特殊情况
        if hostname == "bogon" || hostname?.isEmpty == true {
            return detectDeviceByAlternativeMethods(ipAddress: ipAddress, macAddress: macAddress, openPorts: openPorts)
        }
        
        guard let hostname = hostname?.lowercased() else {
            return createUnknownDevice(ipAddress: ipAddress)
        }
        
        let lowercaseHostname = hostname
        
 // 1. 基于主机名的设备类型检测
        if let deviceInfo = detectByHostname(lowercaseHostname) {
            logger.info("通过主机名检测到设备: \(deviceInfo.displayName)")
            return deviceInfo
        }
        
 // 2. 基于MAC地址的制造商检测
        var manufacturer = Manufacturer.unknown
        if let mac = macAddress {
            manufacturer = detectManufacturerByMAC(mac)
        }
        
 // 3. 基于开放端口的服务检测
        let detectedServices = detectServicesByPorts(openPorts)
        let deviceType = inferDeviceTypeFromServices(detectedServices)
        
 // 4. 基于IP地址模式的推断
        let ipBasedType = inferDeviceTypeFromIP(ipAddress)
        
 // 5. 综合判断
        let finalDeviceType = deviceType != .unknown ? deviceType : ipBasedType
        let capabilities = detectedServices + inferCapabilities(from: finalDeviceType)
        
        let deviceInfo = DetailedDeviceInfo(
            deviceType: finalDeviceType,
            manufacturer: manufacturer,
            model: extractModelFromHostname(hostname),
            capabilities: capabilities,
            icon: finalDeviceType.icon,
            displayName: generateDisplayName(deviceType: finalDeviceType, manufacturer: manufacturer, hostname: hostname)
        )
        
        logger.info("检测到设备: \(deviceInfo.displayName) (\(deviceInfo.deviceType.displayName))")
        return deviceInfo
    }
    
 // MARK: - 私有方法
    
 /// 基于主机名检测设备类型
    private func detectByHostname(_ hostname: String) -> DetailedDeviceInfo? {
 // Apple设备检测
        if hostname.contains("iphone") {
            return DetailedDeviceInfo(
                deviceType: .iPhone,
                manufacturer: .apple,
                model: extractiPhoneModel(hostname),
                capabilities: ["AirDrop", "AirPlay", "Handoff"],
                icon: DeviceType.iPhone.icon,
                displayName: extractiPhoneModel(hostname) ?? "iPhone"
            )
        }
        
        if hostname.contains("ipad") {
            return DetailedDeviceInfo(
                deviceType: .iPad,
                manufacturer: .apple,
                model: extractiPadModel(hostname),
                capabilities: ["AirDrop", "AirPlay", "Handoff", "Apple Pencil"],
                icon: DeviceType.iPad.icon,
                displayName: extractiPadModel(hostname) ?? "iPad"
            )
        }
        
        if hostname.contains("macbook") || hostname.contains("imac") || hostname.contains("mac-mini") {
            return DetailedDeviceInfo(
                deviceType: .mac,
                manufacturer: .apple,
                model: extractMacModel(hostname),
                capabilities: ["AirDrop", "AirPlay", "Handoff", "Continuity"],
                icon: DeviceType.mac.icon,
                displayName: extractMacModel(hostname) ?? "Mac"
            )
        }
        
        if hostname.contains("apple-tv") || hostname.contains("appletv") {
            return DetailedDeviceInfo(
                deviceType: .appleTV,
                manufacturer: .apple,
                capabilities: ["AirPlay", "HomeKit"],
                icon: DeviceType.appleTV.icon,
                displayName: "Apple TV"
            )
        }
        
 // Android设备检测
        if hostname.contains("android") {
            let isTablet = hostname.contains("tablet") || hostname.contains("pad")
            return DetailedDeviceInfo(
                deviceType: isTablet ? .androidTablet : .androidPhone,
                manufacturer: detectAndroidManufacturer(hostname),
                capabilities: ["Google Cast", "Android Beam"],
                icon: isTablet ? DeviceType.androidTablet.icon : DeviceType.androidPhone.icon,
                displayName: isTablet ? "Android平板" : "Android手机"
            )
        }
        
 // Windows设备检测
        if hostname.contains("desktop") || hostname.contains("pc") || hostname.contains("windows") {
            return DetailedDeviceInfo(
                deviceType: .windowsPC,
                manufacturer: .microsoft,
                capabilities: ["SMB", "RDP"],
                icon: DeviceType.windowsPC.icon,
                displayName: "Windows电脑"
            )
        }
        
 // Linux设备检测
        if hostname.contains("ubuntu") || hostname.contains("linux") || hostname.contains("debian") {
            return DetailedDeviceInfo(
                deviceType: .linuxPC,
                manufacturer: .unknown,
                capabilities: ["SSH", "SFTP"],
                icon: DeviceType.linuxPC.icon,
                displayName: "Linux设备"
            )
        }
        
 // 路由器检测
        if hostname.contains("router") || hostname.contains("gateway") || hostname.contains("openwrt") {
            return DetailedDeviceInfo(
                deviceType: .router,
                manufacturer: detectRouterManufacturer(hostname),
                capabilities: ["DHCP", "DNS", "WiFi"],
                icon: DeviceType.router.icon,
                displayName: "路由器"
            )
        }
        
 // 打印机检测
        if hostname.contains("printer") || hostname.contains("canon") || hostname.contains("epson") || hostname.contains("hp") {
            return DetailedDeviceInfo(
                deviceType: .printer,
                manufacturer: detectPrinterManufacturer(hostname),
                capabilities: ["IPP", "AirPrint"],
                icon: DeviceType.printer.icon,
                displayName: "打印机"
            )
        }
        
        return nil
    }
    
 /// 基于MAC地址检测制造商
    private func detectManufacturerByMAC(_ macAddress: String) -> Manufacturer {
        let oui = String(macAddress.prefix(8)).uppercased()
        
 // Apple OUI前缀
        let appleOUIs = ["00:03:93", "00:05:02", "00:0A:27", "00:0A:95", "00:0D:93", "00:11:24", "00:14:51", "00:16:CB", "00:17:F2", "00:19:E3", "00:1B:63", "00:1C:B3", "00:1E:C2", "00:21:E9", "00:22:41", "00:23:12", "00:23:DF", "00:24:36", "00:25:00", "00:25:4B", "00:25:BC", "00:26:08", "00:26:4A", "00:26:B0", "00:26:BB", "04:0C:CE", "04:15:52", "04:1E:64", "04:54:53", "04:69:F8", "04:DB:56", "04:E5:36", "08:00:07", "08:74:02", "0C:3E:9F", "0C:4D:E9", "0C:74:C2", "10:40:F3", "10:9A:DD", "10:DD:B1", "14:10:9F", "14:7D:DA", "14:BD:61", "18:34:51", "18:AF:61", "1C:1A:C0", "1C:AB:A7", "20:78:F0", "20:AB:37", "24:A0:74", "24:AB:81", "28:37:37", "28:6A:BA", "28:A0:2B", "28:CF:DA", "28:E0:2C", "2C:1F:23", "2C:B4:3A", "30:90:AB", "34:15:9E", "34:36:3B", "34:A3:95", "38:C9:86", "3C:15:C2", "3C:2E:F9", "40:B3:95", "40:CB:C0", "44:00:10", "44:4C:0C", "48:43:7C", "48:74:6E", "4C:3C:16", "4C:7C:5F", "4C:8D:79", "50:EA:D6", "54:26:96", "54:72:4F", "58:55:CA", "5C:59:48", "5C:95:AE", "5C:F9:38", "60:03:08", "60:33:4B", "60:C5:47", "60:F4:45", "64:20:0C", "64:B9:E8", "68:AB:1E", "68:D9:3C", "6C:40:08", "6C:72:20", "6C:94:66", "70:11:24", "70:56:81", "70:73:CB", "70:CD:60", "74:E2:F5", "78:31:C1", "78:4F:43", "78:CA:39", "7C:6D:62", "7C:C3:A1", "7C:D1:C3", "80:BE:05", "80:E6:50", "84:38:35", "84:85:06", "84:FC:FE", "88:1F:A1", "88:53:2E", "8C:58:77", "8C:7C:92", "90:27:E4", "90:72:40", "94:E6:F7", "98:03:D8", "9C:04:EB", "9C:20:7B", "9C:84:BF", "A0:99:9B", "A4:5E:60", "A4:B1:97", "A8:20:66", "A8:51:AB", "A8:88:08", "A8:96:75", "AC:1F:74", "AC:29:3A", "AC:3C:0B", "AC:61:EA", "AC:87:A3", "B0:65:BD", "B4:18:D1", "B4:F0:AB", "B8:09:8A", "B8:17:C2", "B8:53:AC", "B8:C7:5D", "B8:E8:56", "BC:52:B7", "BC:67:1C", "BC:92:6B", "C0:9A:D0", "C4:2C:03", "C8:2A:14", "C8:33:4B", "C8:B5:B7", "CC:08:8D", "CC:25:EF", "CC:29:F5", "D0:23:DB", "D0:81:7A", "D4:9A:20", "D8:30:62", "D8:A2:5E", "DC:2B:2A", "DC:37:45", "DC:56:E7", "DC:86:D8", "DC:A9:04", "E0:AC:CB", "E0:B9:BA", "E4:25:E7", "E4:8B:7F", "E4:CE:8F", "E8:06:88", "E8:80:2E", "EC:35:86", "F0:18:98", "F0:B4:79", "F0:DB:E2", "F4:0F:24", "F4:37:B7", "F4:F1:5A", "F8:1E:DF", "F8:27:93", "F8:4F:AD", "FC:25:3F", "FC:E9:98"]
        
        for appleOUI in appleOUIs {
            if oui.hasPrefix(appleOUI) {
                return .apple
            }
        }
        
 // Samsung OUI前缀
        let samsungOUIs = ["00:07:AB", "00:12:FB", "00:15:99", "00:16:32", "00:17:C9", "00:1A:8A", "00:1B:98", "00:1D:25", "00:1E:7D", "00:21:19", "00:23:39", "00:24:54", "00:26:37", "34:BE:00", "38:AA:3C", "3C:5A:B4", "40:4E:36", "44:5E:F3", "48:5A:3F", "4C:3A:4D", "50:32:37", "54:88:0E", "58:C3:8B", "5C:0A:5B", "60:6B:BD", "64:B3:10", "68:EB:C5", "6C:2F:2C", "70:F9:27", "74:45:CE", "78:1F:DB", "7C:1C:4E", "80:57:19", "84:25:3F", "88:32:9B", "8C:77:12", "90:18:7C", "94:51:03", "98:52:3D", "9C:02:98", "A0:0B:BA", "A4:EB:D3", "A8:F2:74", "AC:36:13", "B0:EC:71", "B4:62:93", "B8:5E:7B", "BC:20:A4", "C0:BD:D1", "C4:73:1E", "C8:19:F7", "CC:07:AB", "D0:22:BE", "D4:87:D8", "D8:90:E8", "DC:71:96", "E0:DB:10", "E4:40:E2", "E8:50:8B", "EC:1F:72", "F0:25:B7", "F4:09:D8", "F8:04:2E", "FC:A6:21"]
        
        for samsungOUI in samsungOUIs {
            if oui.hasPrefix(samsungOUI) {
                return .samsung
            }
        }
        
 // 其他制造商的OUI检测可以继续添加...
        
        return .unknown
    }
    
 /// 基于开放端口检测服务
    private func detectServicesByPorts(_ ports: [Int]) -> [String] {
        var services: [String] = []
        
        for port in ports {
            switch port {
            case 22:
                services.append("SSH")
            case 23:
                services.append("Telnet")
            case 53:
                services.append("DNS")
            case 80:
                services.append("HTTP")
            case 443:
                services.append("HTTPS")
            case 445:
                services.append("SMB")
            case 548:
                services.append("AFP")
            case 631:
                services.append("IPP")
            case 993:
                services.append("IMAPS")
            case 3389:
                services.append("RDP")
            case 5000:
                services.append("UPnP")
            case 5353:
                services.append("mDNS")
            case 5900:
                services.append("VNC")
            case 8080:
                services.append("HTTP-Alt")
            case 8443:
                services.append("HTTPS-Alt")
            default:
                break
            }
        }
        
        return services
    }
    
 /// 从服务推断设备类型
    private func inferDeviceTypeFromServices(_ services: [String]) -> DeviceType {
        if services.contains("RDP") {
            return .windowsPC
        }
        if services.contains("SSH") && services.contains("HTTP") {
            return .linuxPC
        }
        if services.contains("AFP") {
            return .mac
        }
        if services.contains("IPP") || services.contains("AirPrint") {
            return .printer
        }
        if services.contains("UPnP") && services.contains("HTTP") {
            return .router
        }
        
        return .unknown
    }
    
 /// 从IP地址推断设备类型
    private func inferDeviceTypeFromIP(_ ipAddress: String) -> DeviceType {
 // 基于IP地址范围的简单推断
        if ipAddress.hasPrefix("192.168.1.1") || ipAddress.hasPrefix("192.168.0.1") {
            return .router
        }
        
        return .unknown
    }
    
 /// 从设备类型推断能力
    private func inferCapabilities(from deviceType: DeviceType) -> [String] {
        switch deviceType {
        case .iPhone, .iPad:
            return ["AirDrop", "AirPlay", "Handoff"]
        case .mac:
            return ["AirDrop", "AirPlay", "Handoff", "Continuity"]
        case .appleTV:
            return ["AirPlay", "HomeKit"]
        case .androidPhone, .androidTablet:
            return ["Google Cast", "Android Beam"]
        case .windowsPC:
            return ["SMB", "RDP"]
        case .linuxPC:
            return ["SSH", "SFTP"]
        case .router:
            return ["DHCP", "DNS", "WiFi"]
        case .printer:
            return ["IPP", "AirPrint"]
        default:
            return []
        }
    }
    
 /// 生成显示名称
    private func generateDisplayName(deviceType: DeviceType, manufacturer: Manufacturer, hostname: String) -> String {
        if manufacturer != .unknown && manufacturer != .apple {
            return "\(manufacturer.displayName) \(deviceType.displayName)"
        }
        
 // 尝试从主机名提取更友好的名称
        if !hostname.isEmpty && hostname != "未知设备" {
            return hostname
        }
        
        return deviceType.displayName
    }
    
 // MARK: - 模型提取方法
    
    private func extractiPhoneModel(_ hostname: String) -> String? {
        if hostname.contains("iphone-15") { return "iPhone 15" }
        if hostname.contains("iphone-14") { return "iPhone 14" }
        if hostname.contains("iphone-13") { return "iPhone 13" }
        if hostname.contains("iphone-12") { return "iPhone 12" }
        if hostname.contains("iphone-11") { return "iPhone 11" }
        if hostname.contains("iphone-x") { return "iPhone X" }
        return "iPhone"
    }
    
    private func extractiPadModel(_ hostname: String) -> String? {
        if hostname.contains("ipad-pro") { return "iPad Pro" }
        if hostname.contains("ipad-air") { return "iPad Air" }
        if hostname.contains("ipad-mini") { return "iPad mini" }
        return "iPad"
    }
    
    private func extractMacModel(_ hostname: String) -> String? {
        if hostname.contains("macbook-pro") { return "MacBook Pro" }
        if hostname.contains("macbook-air") { return "MacBook Air" }
        if hostname.contains("imac") { return "iMac" }
        if hostname.contains("mac-mini") { return "Mac mini" }
        if hostname.contains("mac-studio") { return "Mac Studio" }
        if hostname.contains("mac-pro") { return "Mac Pro" }
        return "Mac"
    }
    
    private func extractModelFromHostname(_ hostname: String) -> String? {
 // 通用模型提取逻辑
        let components = hostname.components(separatedBy: "-")
        if components.count > 1 {
            return components.dropFirst().joined(separator: " ").capitalized
        }
        return nil
    }
    
    private func detectAndroidManufacturer(_ hostname: String) -> Manufacturer {
        if hostname.contains("samsung") { return .samsung }
        if hostname.contains("huawei") { return .huawei }
        if hostname.contains("xiaomi") { return .xiaomi }
        if hostname.contains("oppo") { return .oppo }
        if hostname.contains("vivo") { return .vivo }
        if hostname.contains("oneplus") { return .oneplus }
        return .google
    }
    
    private func detectRouterManufacturer(_ hostname: String) -> Manufacturer {
        if hostname.contains("tplink") || hostname.contains("tp-link") { return .tplink }
        if hostname.contains("netgear") { return .netgear }
        if hostname.contains("linksys") { return .linksys }
        return .unknown
    }
    
    private func detectPrinterManufacturer(_ hostname: String) -> Manufacturer {
        if hostname.contains("canon") { return .canon }
        if hostname.contains("epson") { return .epson }
        if hostname.contains("hp") { return .hp }
        return .unknown
    }
    
 /// 通过替代方法检测bogon设备
    private func detectDeviceByAlternativeMethods(ipAddress: String, macAddress: String?, openPorts: [Int]) -> DetailedDeviceInfo {
 // 1. 优先通过MAC地址检测制造商
        if let macAddress = macAddress {
            let manufacturer = detectManufacturerByMAC(macAddress)
            if manufacturer == .apple {
 // 通过开放端口进一步判断Apple设备类型
                return detectAppleDeviceByPorts(ipAddress: ipAddress, openPorts: openPorts, macAddress: macAddress)
            }
        }
        
 // 2. 通过开放端口检测设备类型
        let detectedType = detectDeviceTypeByPorts(openPorts)
        
 // 3. 如果是移动设备端口特征，可能是iPad/iPhone
        if openPorts.contains(62078) || openPorts.contains(5353) { // AirPlay/Bonjour端口
            return DetailedDeviceInfo(
                deviceType: .iPhone, // 默认为iPhone，实际可能是iPad
                manufacturer: .apple,
                model: "iOS设备",
                capabilities: ["AirDrop", "AirPlay", "Handoff"],
                icon: DeviceType.iPhone.icon,
                displayName: "Apple移动设备"
            )
        }
        
        let manufacturer = macAddress.map { detectManufacturerByMAC($0) } ?? .unknown
        return DetailedDeviceInfo(
            deviceType: detectedType,
            manufacturer: manufacturer,
            model: nil,
            capabilities: detectCapabilitiesByPorts(openPorts),
            icon: detectedType.icon,
            displayName: generateDisplayNameForUnknown(ipAddress: ipAddress, deviceType: detectedType)
        )
    }
    
 /// 检测Apple设备类型（通过端口）
    private func detectAppleDeviceByPorts(ipAddress: String, openPorts: [Int], macAddress: String) -> DetailedDeviceInfo {
 // Mac设备通常开放SSH(22)、VNC(5900)、Screen Sharing(5900)等端口
        if openPorts.contains(22) || openPorts.contains(5900) || openPorts.contains(548) {
            return DetailedDeviceInfo(
                deviceType: .mac,
                manufacturer: .apple,
                model: "Mac",
                capabilities: ["AirDrop", "AirPlay", "Handoff", "Screen Sharing"],
                icon: DeviceType.mac.icon,
                displayName: "Mac设备"
            )
        }
        
 // Apple TV通常开放AirPlay端口
        if openPorts.contains(7000) || openPorts.contains(7001) {
            return DetailedDeviceInfo(
                deviceType: .appleTV,
                manufacturer: .apple,
                model: "Apple TV",
                capabilities: ["AirPlay", "HomeKit"],
                icon: DeviceType.appleTV.icon,
                displayName: "Apple TV"
            )
        }
        
 // iOS设备（iPhone/iPad）通常开放iTunes同步端口
        if openPorts.contains(62078) || openPorts.contains(5353) {
            return DetailedDeviceInfo(
                deviceType: .iPhone, // 可能是iPad，但默认显示为iPhone
                manufacturer: .apple,
                model: "iOS设备",
                capabilities: ["AirDrop", "AirPlay", "Handoff"],
                icon: DeviceType.iPhone.icon,
                displayName: "iPhone/iPad"
            )
        }
        
 // 默认Apple设备
        return DetailedDeviceInfo(
            deviceType: .iPhone,
            manufacturer: .apple,
            model: "Apple设备",
            capabilities: ["AirDrop", "AirPlay"],
            icon: DeviceType.iPhone.icon,
            displayName: "Apple设备"
        )
    }
    
 /// 通过端口检测设备类型
    private func detectDeviceTypeByPorts(_ ports: [Int]) -> DeviceType {
 // 路由器端口
        if ports.contains(53) || ports.contains(67) || ports.contains(68) {
            return .router
        }
        
 // 打印机端口
        if ports.contains(631) || ports.contains(9100) {
            return .printer
        }
        
 // Web服务器（使用NAS设备类型）
        if ports.contains(80) || ports.contains(443) {
            return .nas
        }
        
 // SSH服务器（可能是Linux/Unix）
        if ports.contains(22) {
            return .linuxPC
        }
        
        return .unknown
    }
    
 /// 通过端口检测设备能力
    private func detectCapabilitiesByPorts(_ ports: [Int]) -> [String] {
        var capabilities: [String] = []
        
        if ports.contains(22) { capabilities.append("SSH") }
        if ports.contains(80) || ports.contains(443) { capabilities.append("Web服务") }
        if ports.contains(53) { capabilities.append("DNS") }
        if ports.contains(631) { capabilities.append("打印服务") }
        if ports.contains(5353) { capabilities.append("Bonjour") }
        if ports.contains(62078) { capabilities.append("iTunes同步") }
        
        return capabilities
    }
    
 /// 为未知设备生成显示名称
    private func generateDisplayNameForUnknown(ipAddress: String, deviceType: DeviceType) -> String {
        let components = ipAddress.split(separator: ".")
        if components.count == 4 {
            return "\(deviceType.displayName)-\(components[2]).\(components[3])"
        }
        return deviceType.displayName
    }
    
 /// 创建未知设备信息
    private func createUnknownDevice(ipAddress: String) -> DetailedDeviceInfo {
        return DetailedDeviceInfo(
            deviceType: .unknown,
            manufacturer: .unknown,
            model: nil,
            capabilities: [],
            icon: DeviceType.unknown.icon,
            displayName: generateDisplayNameForUnknown(ipAddress: ipAddress, deviceType: .unknown)
        )
    }
}
