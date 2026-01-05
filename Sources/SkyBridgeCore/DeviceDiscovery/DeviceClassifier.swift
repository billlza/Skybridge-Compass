import Foundation
import Network

// 设备模型已在同一模块中，无需导入

/// 设备分类器 - 智能识别设备类型
public class DeviceClassifier {
    
 /// 设备类型枚举
    public enum DeviceType: String, CaseIterable, Sendable {
        case computer = "计算机"
        case camera = "摄像头"
        case router = "路由器"
        case printer = "打印机"
        case speaker = "音响"
        case tv = "电视"
        case nas = "网络存储"
        case iot = "物联网设备"
        case unknown = "未知设备"
        
 /// 设备类型图标
        public var icon: String {
            switch self {
            case .computer:
                return "desktopcomputer"
            case .camera:
                return "video"
            case .router:
                return "wifi.router"
            case .printer:
                return "printer"
            case .speaker:
                return "speaker.wave.2"
            case .tv:
                return "tv"
            case .nas:
                return "externaldrive.connected.to.line.below"
            case .iot:
                return "sensor"
            case .unknown:
                return "questionmark.circle"
            }
        }
        
 /// 是否为可连接的计算设备
        public var isConnectable: Bool {
            switch self {
            case .computer, .nas:
                return true
            case .camera, .router, .printer, .speaker, .tv, .iot, .unknown:
                return false
            }
        }
        
 /// 设备类型颜色
        public var color: String {
            switch self {
            case .computer:
                return "blue"
            case .camera:
                return "red"
            case .router:
                return "orange"
            case .printer:
                return "purple"
            case .speaker:
                return "green"
            case .tv:
                return "indigo"
            case .nas:
                return "cyan"
            case .iot:
                return "yellow"
            case .unknown:
                return "gray"
            }
        }
    }

    
    
 /// 设备制造商数据库
    private static let manufacturerDatabase: [String: (type: DeviceType, keywords: [String])] = [
 // 摄像头制造商
        "海康威视": (.camera, ["hikvision", "ds-", "ipc-", "nvr-"]),
        "大华": (.camera, ["dahua", "dh-", "ipc-", "nvr-"]),
        "宇视": (.camera, ["uniview", "ipc-"]),
        "萤石": (.camera, ["ezviz", "cs-"]),
        "小米": (.camera, ["xiaomi", "mijia", "camera"]),
        "华为": (.camera, ["huawei", "camera"]),
        
 // 路由器制造商
        "华硕": (.router, ["asus", "rt-", "ax-"]),
        "网件": (.router, ["netgear", "r6", "r7", "r8", "ax"]),
        "领势": (.router, ["linksys", "ea", "mr"]),
        "腾达": (.router, ["tenda", "ac"]),
        "水星": (.router, ["mercury", "mw"]),
        "迅捷": (.router, ["fast", "fw"]),
        "小米路由器": (.router, ["mi router", "redmi router"]),
        
 // 打印机制造商
        "惠普": (.printer, ["hp", "laserjet", "deskjet", "officejet"]),
        "佳能": (.printer, ["canon", "pixma", "imageclass"]),
        "爱普生": (.printer, ["epson", "workforce", "expression"]),
        "兄弟": (.printer, ["brother", "dcp-", "mfc-"]),
        "联想": (.printer, ["lenovo", "lj"]),
        
 // 音响设备
        "苹果": (.speaker, ["apple", "homepod", "airpods"]),
        "小爱": (.speaker, ["xiaoai", "mi speaker"]),
        "天猫精灵": (.speaker, ["tmall genie"]),
        "小度": (.speaker, ["xiaodu"]),
        
 // 电视设备
        "小米电视": (.tv, ["mi tv", "xiaomi tv"]),
        "华为智慧屏": (.tv, ["huawei smart screen"]),
        "海信": (.tv, ["hisense"]),
        "TCL": (.tv, ["tcl"]),
        
 // NAS设备
        "群晖": (.nas, ["synology", "diskstation"]),
        "威联通": (.nas, ["qnap", "ts-"]),
        "海康威视NAS": (.nas, ["hikvision nas"]),
        
 // 物联网设备
        "米家": (.iot, ["mijia", "xiaomi iot"]),
        "华为HiLink": (.iot, ["hilink"]),
        "天猫精灵IoT": (.iot, ["tmall iot"])
    ]
    
 /// 端口到设备类型的映射表
    private static let portServiceMapping: [Int: DeviceType] = [
 // SSH和远程桌面服务
        22: .computer,        // SSH
        3389: .computer,      // RDP
        5900: .computer,      // VNC
        
 // 摄像头相关端口
        554: .camera,         // RTSP摄像头
        8000: .camera,        // 海康威视默认端口
        37777: .camera,       // 大华摄像头
        
 // 打印机服务
        515: .printer,        // LPD打印服务
        631: .printer,        // IPP打印服务
        9100: .printer,       // HP JetDirect
        
 // NAS和存储设备
        5000: .nas,           // Synology DSM
        8080: .nas,           // QNAP管理界面
        139: .nas,            // NetBIOS
        445: .nas,            // SMB
        
 // 路由器和网络设备
        443: .router,         // HTTPS管理界面
        23: .router,          // Telnet
        53: .router,          // DNS服务
        67: .router,          // DHCP服务
        
 // IoT设备
        1883: .iot,           // MQTT
        8883: .iot,           // MQTT over SSL
        5683: .iot,           // CoAP
        1900: .iot            // UPnP设备
    ]
    
 /// 分类设备
 /// - Parameter device: 待分类的设备
 /// - Returns: 设备类型
    public static func classifyDevice(_ device: DiscoveredDevice) -> DeviceType {
        let deviceName = device.name.lowercased()
        
 // 1. 首先通过设备名称中的制造商信息进行分类
        for (manufacturer, info) in manufacturerDatabase {
            if deviceName.contains(manufacturer.lowercased()) {
                return info.type
            }
            
 // 检查关键词匹配
            for keyword in info.keywords {
                if deviceName.contains(keyword.lowercased()) {
                    return info.type
                }
            }
        }
        
 // 2. 通过端口信息进行分类
        for (_, port) in device.portMap {
            if let deviceType = portServiceMapping[port] {
                return deviceType
            }
        }
        
 // 3. 通过服务类型进行分类
        for service in device.services {
            let serviceType = classifyByService(service)
            if serviceType != DeviceType.unknown {
                return serviceType
            }
        }
        
 // 4. 通过设备名称模式匹配
        let nameType = classifyByNamePattern(deviceName)
        if nameType != DeviceType.unknown {
            return nameType
        }
        
 // 5. 默认情况：如果包含常见计算机关键词，则认为是计算机
        let computerKeywords = ["macbook", "imac", "pc", "desktop", "laptop", "workstation", "server"]
        for keyword in computerKeywords {
            if deviceName.contains(keyword) {
                return .computer
            }
        }
        
        return DeviceType.unknown
    }
    
 /// 通过服务类型分类
    private static func classifyByService(_ service: String) -> DeviceType {
        let serviceLower = service.lowercased()
        
        if serviceLower.contains("http") || serviceLower.contains("rtsp") {
            return .camera
        } else if serviceLower.contains("ipp") || serviceLower.contains("printer") {
            return .printer
        } else if serviceLower.contains("airplay") || serviceLower.contains("raop") {
            return .speaker
        } else if serviceLower.contains("smb") || serviceLower.contains("afp") {
            return .nas
        } else if serviceLower.contains("ssh") || serviceLower.contains("vnc") || serviceLower.contains("rdp") {
            return .computer
        }
        
        return DeviceType.unknown
    }
    
 /// 根据设备名称模式进行分类
    private static func classifyByNamePattern(_ name: String) -> DeviceType {
 // 摄像头常见命名模式
        let cameraPatterns = [
            "camera", "cam-", "ipc-", "nvr-", "dvr-", "ds-", "dh-", "cs-"
        ]
        
 // 路由器常见命名模式
        let routerPatterns = [
            "router", "rt-", "ax-", "ac-", "n-", "wifi", "wireless"
        ]
        
 // 打印机常见命名模式
        let printerPatterns = [
            "printer", "print", "laserjet", "deskjet", "pixma", "workforce"
        ]
        
 // 检查摄像头模式
        for pattern in cameraPatterns {
            if name.contains(pattern) {
                return .camera
            }
        }
        
 // 检查路由器模式
        for pattern in routerPatterns {
            if name.contains(pattern) {
                return .router
            }
        }
        
 // 检查打印机模式
        for pattern in printerPatterns {
            if name.contains(pattern) {
                return .printer
            }
        }
        
        return DeviceType.unknown
    }
    
 /// 获取设备分类建议
 /// - Parameter device: 设备信息
 /// 获取设备分类建议和置信度
    public static func getClassificationSuggestion(_ device: DiscoveredDevice) -> (type: DeviceType, confidence: Double) {
        let deviceType = classifyDevice(device)
        
 // 计算置信度
        var confidence: Double = 0.5 // 基础置信度
        
        let deviceName = device.name.lowercased()
        
 // 如果匹配到制造商，提高置信度
        for (manufacturer, _) in manufacturerDatabase {
            if deviceName.contains(manufacturer.lowercased()) {
                confidence = 0.9
                break
            }
        }
        
 // 如果匹配到特定端口，提高置信度
        for (_, port) in device.portMap {
            if portServiceMapping[port] != nil {
                confidence = max(confidence, 0.8)
            }
        }
        
        return (type: deviceType, confidence: confidence)
    }
}

// 为设备类型增加 Codable 支持，未知值降级为 .unknown，避免新增枚举值导致解码失败。
extension DeviceClassifier.DeviceType: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = DeviceClassifier.DeviceType(rawValue: raw) ?? .unknown
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

/// 扩展DiscoveredDevice以支持设备分类
extension DiscoveredDevice {
 /// 设备类型
    public var deviceType: DeviceClassifier.DeviceType {
        return DeviceClassifier.classifyDevice(self)
    }
    
 /// 是否为可连接设备
    public var isConnectable: Bool {
        return deviceType.isConnectable
    }
    
 /// 设备分类置信度
    public var classificationConfidence: Double {
        return DeviceClassifier.getClassificationSuggestion(self).confidence
    }
}
