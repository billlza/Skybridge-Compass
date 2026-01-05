import Foundation
import IOKit
import IOKit.usb
import OSLog

/// USB 设备发现管理器
///
/// 功能：
/// - 扫描所有连接的 USB 设备
/// - 识别 iPhone、iPad、Android 设备等
/// - 提供设备详细信息（型号、序列号、连接类型）
@MainActor
public class USBDeviceDiscoveryManager: ObservableObject, Sendable {
    
 // MARK: - 发布属性
    
    @Published public var usbDevices: [USBDevice] = []
    @Published public var isScanning = false
    
 // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "com.skybridge.usb", category: "USBDeviceDiscovery")
    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    
 // MARK: - 初始化
    
    public init() {
        logger.info("USB 设备发现管理器初始化")
    }
    
 // deinit 会自动清理资源，无需手动处理
    
 // MARK: - 生命周期管理
    
 /// 启动USB设备发现管理器
    public func start() async {
        logger.info("启动USB设备发现管理器")
        startMonitoring()
        scanUSBDevices()
    }
    
 /// 停止USB设备发现管理器
    public func stop() {
        logger.info("停止USB设备发现管理器")
        stopMonitoring()
        cleanup()
    }
    
 /// 清理资源
    public func cleanup() {
 // 清理设备列表
        usbDevices.removeAll()
        
 // 重置状态
        isScanning = false
        
        logger.info("USB设备发现管理器资源已清理")
    }
    
 // MARK: - 公开方法
    
 /// 扫描所有 USB 设备
    public func scanUSBDevices() {
        logger.info("开始扫描 USB 设备")
        isScanning = true
        
        Task.detached(priority: .userInitiated) { [weak self] in
            let devices = await self?.performUSBScan() ?? []
            
            await MainActor.run { [weak self] in
                self?.usbDevices = devices
                self?.isScanning = false
                self?.logger.info("USB 扫描完成，发现 \(devices.count) 台设备")
            }
        }
    }
    
 /// 开始监控 USB 设备插拔
    public func startMonitoring() {
        logger.info("开始监控 USB 设备插拔")
        
 // 创建通知端口
        notificationPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notificationPort = notificationPort else {
            logger.error("无法创建 IONotificationPort")
            return
        }
        
        let runLoopSource = IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
        
 // 匹配 USB 设备
        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName)
        
 // 监听设备插入
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(
            notificationPort,
            kIOFirstMatchNotification,
            matchingDict,
            deviceAdded,
            selfPtr,
            &addedIterator
        )
        
 // 消费初始迭代器
        deviceAdded(refcon: selfPtr, iterator: addedIterator)
        
 // 监听设备移除
        let matchingDict2 = IOServiceMatching(kIOUSBDeviceClassName)
        IOServiceAddMatchingNotification(
            notificationPort,
            kIOTerminatedNotification,
            matchingDict2,
            deviceRemoved,
            selfPtr,
            &removedIterator
        )
        
 // 消费初始迭代器
        deviceRemoved(refcon: selfPtr, iterator: removedIterator)
        
 // 初始扫描
        scanUSBDevices()
    }
    
 /// 停止监控
    public func stopMonitoring() {
        logger.info("停止监控 USB 设备")
        
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        
        if let notificationPort = notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
    }
    
 // MARK: - 私有方法
    
    private func performUSBScan() async -> [USBDevice] {
        var devices: [USBDevice] = []
        
 // 获取 USB 设备迭代器
        var iterator: io_iterator_t = 0
        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName)
        
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
        guard result == KERN_SUCCESS else {
            logger.error("无法获取 USB 设备列表: \(result)")
            return devices
        }
        
        defer {
            IOObjectRelease(iterator)
        }
        
 // 遍历所有 USB 设备
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            
            if let usbDevice = extractUSBDeviceInfo(from: device) {
                devices.append(usbDevice)
            }
        }
        
        return devices
    }
    
    private func extractUSBDeviceInfo(from ioDevice: io_service_t) -> USBDevice? {
 // 读取设备属性
        guard let props = getDeviceProperties(ioDevice) else {
            return nil
        }
        
 // 提取关键信息
        let vendorID = props["idVendor"] as? Int ?? 0
        let productID = props["idProduct"] as? Int ?? 0
        let vendorName = props["USB Vendor Name"] as? String
        let productName = props["USB Product Name"] as? String
        let serialNumber = props["USB Serial Number"] as? String
        let locationID = props["locationID"] as? Int ?? 0
        
 // 识别设备类型
        let deviceType = identifyDeviceType(vendorID: vendorID, productID: productID, productName: productName)
        
 // 生成设备名称
        let name = generateDeviceName(
            vendorName: vendorName,
            productName: productName,
            deviceType: deviceType
        )
        
        return USBDevice(
            id: "\(vendorID)-\(productID)-\(locationID)",
            name: name,
            vendorID: vendorID,
            productID: productID,
            vendorName: vendorName,
            productName: productName,
            serialNumber: serialNumber,
            deviceType: deviceType,
            locationID: locationID
        )
    }
    
    private func getDeviceProperties(_ device: io_service_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(device, &properties, kCFAllocatorDefault, 0)
        
        guard result == KERN_SUCCESS, let props = properties?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        
        return props
    }
    
    private func identifyDeviceType(vendorID: Int, productID: Int, productName: String?) -> USBDeviceType {
 // Apple 设备
        if vendorID == 0x05AC { // Apple Inc.
            if let name = productName?.lowercased() {
                if name.contains("iphone") {
                    return .iPhone
                } else if name.contains("ipad") {
                    return .iPad
                } else if name.contains("ipod") {
                    return .iPod
                }
            }
            return .appleDevice
        }
        
 // Android 设备（常见厂商）
        let androidVendors = [
            0x18D1, // Google
            0x04E8, // Samsung
            0x2717, // Xiaomi
            0x2A45, // Meizu
            0x2D95, // OnePlus
            0x19D2, // ZTE
            0x12D1  // Huawei
        ]
        
        if androidVendors.contains(vendorID) {
            return .androidDevice
        }
        
 // 存储设备
        if let name = productName?.lowercased() {
            if name.contains("disk") || name.contains("storage") || name.contains("flash") {
                return .storage
            }
            
            if name.contains("keyboard") {
                return .keyboard
            }
            
            if name.contains("mouse") {
                return .mouse
            }
            
            if name.contains("camera") || name.contains("webcam") {
                return .camera
            }
            
            if name.contains("audio") || name.contains("headphone") || name.contains("speaker") {
                return .audio
            }
        }
        
        return .unknown
    }
    
    private func generateDeviceName(vendorName: String?, productName: String?, deviceType: USBDeviceType) -> String {
 // 优先使用产品名称
        if let productName = productName, !productName.isEmpty {
            return productName
        }
        
 // 使用厂商名称
        if let vendorName = vendorName, !vendorName.isEmpty {
            return "\(vendorName) 设备"
        }
        
 // 使用设备类型
        switch deviceType {
        case .iPhone:
            return "iPhone"
        case .iPad:
            return "iPad"
        case .iPod:
            return "iPod"
        case .appleDevice:
            return "Apple 设备"
        case .androidDevice:
            return "Android 设备"
        case .storage:
            return "存储设备"
        case .keyboard:
            return "键盘"
        case .mouse:
            return "鼠标"
        case .camera:
            return "摄像头"
        case .audio:
            return "音频设备"
        case .unknown:
            return "USB 设备"
        }
    }
}

// MARK: - C 回调函数

private func deviceAdded(refcon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let refcon = refcon else { return }
    
    let manager = Unmanaged<USBDeviceDiscoveryManager>.fromOpaque(refcon).takeUnretainedValue()
    
 // 消费迭代器
    while case let device = IOIteratorNext(iterator), device != 0 {
        IOObjectRelease(device)
    }
    
 // 触发重新扫描（显式切回主线程；弱引用避免悬垂对象）
    DispatchQueue.main.async { [weak manager] in
        manager?.scanUSBDevices()
    }
}

private func deviceRemoved(refcon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let refcon = refcon else { return }
    
    let manager = Unmanaged<USBDeviceDiscoveryManager>.fromOpaque(refcon).takeUnretainedValue()
    
 // 消费迭代器
    while case let device = IOIteratorNext(iterator), device != 0 {
        IOObjectRelease(device)
    }
    
 // 触发重新扫描（显式切回主线程；弱引用避免悬垂对象）
    DispatchQueue.main.async { [weak manager] in
        manager?.scanUSBDevices()
    }
}

// MARK: - 数据模型

/// USB 设备信息
public struct USBDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let vendorID: Int
    public let productID: Int
    public let vendorName: String?
    public let productName: String?
    public let serialNumber: String?
    public let deviceType: USBDeviceType
    public let locationID: Int
    
 /// 设备描述
    public var description: String {
        var parts: [String] = []
        
        if let vendorName = vendorName {
            parts.append("厂商: \(vendorName)")
        }
        
        if let serialNumber = serialNumber {
            parts.append("序列号: \(serialNumber)")
        }
        
        parts.append("VID: \(String(format: "0x%04X", vendorID))")
        parts.append("PID: \(String(format: "0x%04X", productID))")
        
        return parts.joined(separator: " | ")
    }
}

/// USB 设备类型
public enum USBDeviceType: String, Codable, Sendable {
    case iPhone
    case iPad
    case iPod
    case appleDevice
    case androidDevice
    case storage
    case keyboard
    case mouse
    case camera
    case audio
    case unknown
    
 /// 图标名称
    public var iconName: String {
        switch self {
        case .iPhone:
            return "iphone"
        case .iPad:
            return "ipad"
        case .iPod:
            return "ipod"
        case .appleDevice:
            return "apple.logo"
        case .androidDevice:
            return "antenna.radiowaves.left.and.right"
        case .storage:
            return "externaldrive"
        case .keyboard:
            return "keyboard"
        case .mouse:
            return "computermouse"
        case .camera:
            return "camera"
        case .audio:
            return "hifispeaker"
        case .unknown:
            return "cable.connector"
        }
    }
    
 /// 设备类型描述
    public var displayName: String {
        switch self {
        case .iPhone:
            return "iPhone"
        case .iPad:
            return "iPad"
        case .iPod:
            return "iPod"
        case .appleDevice:
            return "Apple 设备"
        case .androidDevice:
            return "Android 设备"
        case .storage:
            return "存储设备"
        case .keyboard:
            return "键盘"
        case .mouse:
            return "鼠标"
        case .camera:
            return "摄像头"
        case .audio:
            return "音频设备"
        case .unknown:
            return "USB 设备"
        }
    }
}
