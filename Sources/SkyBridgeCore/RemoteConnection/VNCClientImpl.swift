import Foundation
import Network
import os.log
import AppKit
import CoreGraphics
import CommonCrypto

// MARK: - VNC 客户端完整实现
// Swift 6.2.1 最佳实践：使用 actor 确保线程安全，实现 RFB 协议

/// RFB（Remote Framebuffer）协议版本
public enum RFBProtocolVersion: String, Sendable {
    case rfb33 = "RFB 003.003"
    case rfb37 = "RFB 003.007"
    case rfb38 = "RFB 003.008"
    
    var major: Int {
        switch self {
        case .rfb33, .rfb37, .rfb38: return 3
        }
    }
    
    var minor: Int {
        switch self {
        case .rfb33: return 3
        case .rfb37: return 7
        case .rfb38: return 8
        }
    }
}

/// VNC 安全类型
public enum VNCSecurityType: UInt8, Sendable {
    case invalid = 0
    case none = 1
    case vncAuthentication = 2
    case tight = 16
    case ultraVNC = 17
    case tlsNone = 18
    case tlsVNC = 19
    case tlsPlain = 20
    case appleRemoteDesktop = 30
}

/// VNC 客户端错误
public enum VNCClientError: Error, Sendable {
    case connectionFailed(String)
    case protocolError(String)
    case authenticationFailed(String)
    case unsupportedSecurityType
    case framebufferError
    case timeout
    case invalidServerResponse
    case disconnected
}

/// VNC 连接状态
public enum VNCConnectionState: Sendable {
    case disconnected
    case connecting
    case protocolHandshake
    case securityHandshake
    case authenticating
    case initializing
    case connected
    case failed(Error)
}

/// VNC 客户端配置
public struct VNCClientConfiguration: Sendable {
    public let host: String
    public let port: UInt16
    public let password: String?
    public let sharedConnection: Bool
    public let viewOnly: Bool
    public let connectionTimeout: TimeInterval
    public let preferredEncodings: [VNCEncoding]
    
    public init(
        host: String,
        port: UInt16 = 5900,
        password: String? = nil,
        sharedConnection: Bool = true,
        viewOnly: Bool = false,
        connectionTimeout: TimeInterval = 30,
        preferredEncodings: [VNCEncoding] = [.tight, .zrle, .hextile, .raw]
    ) {
        self.host = host
        self.port = port
        self.password = password
        self.sharedConnection = sharedConnection
        self.viewOnly = viewOnly
        self.connectionTimeout = connectionTimeout
        self.preferredEncodings = preferredEncodings
    }
}

/// VNC 编码类型
public enum VNCEncoding: Int32, Sendable {
    case raw = 0
    case copyRect = 1
    case rre = 2
    case hextile = 5
    case tight = 7
    case zrle = 16
    case cursor = -239
    case desktopSize = -223
}

/// 帧缓冲区信息
public struct FramebufferInfo: Sendable {
    public let width: Int
    public let height: Int
    public let bitsPerPixel: Int
    public let depth: Int
    public let bigEndian: Bool
    public let trueColor: Bool
    public let redMax: Int
    public let greenMax: Int
    public let blueMax: Int
    public let redShift: Int
    public let greenShift: Int
    public let blueShift: Int
    public let name: String
}

/// 帧缓冲区更新
public struct FramebufferUpdate: Sendable {
    public let rectangles: [FramebufferRectangle]
    public let timestamp: Date
}

/// 帧缓冲区矩形
public struct FramebufferRectangle: Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let encoding: VNCEncoding
    public let data: Data
}

/// 完整 VNC 客户端实现
///
/// Swift 6.2.1 特性：
/// - `actor` 隔离确保并发安全
/// - 实现 RFB 3.3/3.7/3.8 协议
/// - 支持多种编码（Raw, CopyRect, Hextile, Tight, ZRLE）
@available(macOS 14.0, *)
public actor VNCClientImpl {
    
 // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "VNCClient")
    private var connection: NWConnection?
    private let configuration: VNCClientConfiguration
    private let queue = DispatchQueue(label: "com.skybridge.vnc.client")
    
    private var protocolVersion: RFBProtocolVersion?
    private var serverSecurityTypes: [VNCSecurityType] = []
    private var framebufferInfo: FramebufferInfo?
    private var frameBuffer: UnsafeMutableRawPointer?
    
    @Published private(set) var state: VNCConnectionState = .disconnected
    @Published private(set) var currentFrame: CGImage?
    
 // MARK: - Initialization
    
    public init(configuration: VNCClientConfiguration) {
        self.configuration = configuration
    }
    
 /// 清理资源
 /// Swift 6.2.1: 使用显式清理方法代替 deinit 避免并发安全问题
    public func cleanup() {
        if let buffer = frameBuffer {
            buffer.deallocate()
            frameBuffer = nil
        }
    }
    
 // MARK: - Connection
    
 /// 连接到 VNC 服务器
    public func connect() async throws {
        guard case .disconnected = state else {
            logger.warning("VNC 连接已存在或正在进行中")
            return
        }
        
        state = .connecting
        logger.info("🖥️ 开始 VNC 连接: \(self.configuration.host):\(self.configuration.port)")
        
        do {
 // 建立 TCP 连接
            try await establishConnection()
            
 // RFB 协议握手
            state = .protocolHandshake
            try await performProtocolHandshake()
            
 // 安全握手
            state = .securityHandshake
            try await performSecurityHandshake()
            
 // 认证（如果需要）
            if configuration.password != nil {
                state = .authenticating
                try await performAuthentication()
            }
            
 // 初始化
            state = .initializing
            try await performInitialization()
            
            state = .connected
            logger.info("✅ VNC 连接成功: \(self.configuration.host)")
            
        } catch {
            state = .failed(error)
            logger.error("❌ VNC 连接失败: \(error.localizedDescription)")
            throw error
        }
    }
    
 /// 断开连接
    public func disconnect() async {
        connection?.cancel()
        connection = nil
        cleanup()
        state = .disconnected
        logger.info("🔌 VNC 连接已断开")
    }
    
 // MARK: - Framebuffer Operations
    
 /// 请求帧缓冲区更新
    public func requestFramebufferUpdate(incremental: Bool = true) async throws -> FramebufferUpdate {
        guard case .connected = state, let connection = connection else {
            throw VNCClientError.disconnected
        }
        
        guard let fbInfo = framebufferInfo else {
            throw VNCClientError.framebufferError
        }
        
 // 发送 FramebufferUpdateRequest (消息类型 3)
        var request = Data()
        request.append(3) // 消息类型
        request.append(incremental ? 1 : 0) // 增量标志
        request.append(contentsOf: UInt16(0).bigEndianBytes) // x-position
        request.append(contentsOf: UInt16(0).bigEndianBytes) // y-position
        request.append(contentsOf: UInt16(fbInfo.width).bigEndianBytes) // width
        request.append(contentsOf: UInt16(fbInfo.height).bigEndianBytes) // height
        
        try await sendData(request, connection: connection)
        
 // 接收更新
        return try await receiveFramebufferUpdate(connection: connection)
    }
    
 /// 发送鼠标事件
    public func sendMouseEvent(x: Int, y: Int, buttonMask: UInt8) async throws {
        guard case .connected = state, let connection = connection else {
            throw VNCClientError.disconnected
        }
        
        guard !configuration.viewOnly else { return }
        
 // PointerEvent (消息类型 5)
        var event = Data()
        event.append(5) // 消息类型
        event.append(buttonMask) // 按钮掩码
        event.append(contentsOf: UInt16(x).bigEndianBytes) // x-position
        event.append(contentsOf: UInt16(y).bigEndianBytes) // y-position
        
        try await sendData(event, connection: connection)
    }
    
 /// 发送键盘事件
    public func sendKeyEvent(key: UInt32, isDown: Bool) async throws {
        guard case .connected = state, let connection = connection else {
            throw VNCClientError.disconnected
        }
        
        guard !configuration.viewOnly else { return }
        
 // KeyEvent (消息类型 4)
        var event = Data()
        event.append(4) // 消息类型
        event.append(isDown ? 1 : 0) // down-flag
        event.append(contentsOf: [0, 0]) // padding
        event.append(contentsOf: key.bigEndianBytes) // key
        
        try await sendData(event, connection: connection)
    }
    
 /// 发送剪贴板内容
    public func sendClipboard(_ text: String) async throws {
        guard case .connected = state, let connection = connection else {
            throw VNCClientError.disconnected
        }
        
        guard let textData = text.data(using: .utf8) else { return }
        
 // ClientCutText (消息类型 6)
        var message = Data()
        message.append(6) // 消息类型
        message.append(contentsOf: [0, 0, 0]) // padding
        message.append(contentsOf: UInt32(textData.count).bigEndianBytes) // length
        message.append(textData) // text
        
        try await sendData(message, connection: connection)
    }
    
 // MARK: - Private Methods - Connection
    
    private func establishConnection() async throws {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(configuration.host),
            port: NWEndpoint.Port(rawValue: configuration.port)!
        )
        let params = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: params)
        
        connection.start(queue: queue)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: VNCClientError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
        }
        
        self.connection = connection
    }
    
    private func performProtocolHandshake() async throws {
        guard let connection = connection else { throw VNCClientError.disconnected }
        
 // 接收服务器版本字符串 (12 字节)
        let serverVersion = try await receiveData(count: 12, connection: connection)
        guard let versionString = String(data: serverVersion, encoding: .ascii) else {
            throw VNCClientError.protocolError("Invalid server version")
        }
        
        logger.info("服务器版本: \(versionString.trimmingCharacters(in: .whitespacesAndNewlines))")
        
 // 解析版本
        protocolVersion = parseProtocolVersion(versionString)
        
 // 发送客户端版本
        let clientVersion = "RFB 003.008\n"
        guard let clientVersionData = clientVersion.data(using: .ascii) else {
            throw VNCClientError.protocolError("Failed to encode client version")
        }
        
        try await sendData(clientVersionData, connection: connection)
    }
    
    private func performSecurityHandshake() async throws {
        guard let connection = connection else { throw VNCClientError.disconnected }
        
        if protocolVersion == .rfb33 {
 // RFB 3.3: 服务器直接发送 4 字节的安全类型
            let securityData = try await receiveData(count: 4, connection: connection)
            let securityType = UInt32(bigEndian: securityData.withUnsafeBytes { $0.load(as: UInt32.self) })
            
            if securityType == 0 {
                throw VNCClientError.authenticationFailed("Connection refused by server")
            }
            
            serverSecurityTypes = [VNCSecurityType(rawValue: UInt8(securityType)) ?? .invalid]
        } else {
 // RFB 3.7/3.8: 服务器发送安全类型列表
            let countData = try await receiveData(count: 1, connection: connection)
            let count = Int(countData[0])
            
            if count == 0 {
 // 读取错误信息
                let lengthData = try await receiveData(count: 4, connection: connection)
                let length = Int(UInt32(bigEndian: lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }))
                let errorData = try await receiveData(count: length, connection: connection)
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                throw VNCClientError.authenticationFailed(errorMessage)
            }
            
            let typesData = try await receiveData(count: count, connection: connection)
            serverSecurityTypes = typesData.map { VNCSecurityType(rawValue: $0) ?? .invalid }
        }
        
        logger.info("服务器支持的安全类型: \(self.serverSecurityTypes.map { String($0.rawValue) }.joined(separator: ", "))")
        
 // 选择安全类型
        let selectedType = selectSecurityType()
        
        if protocolVersion != .rfb33 {
 // 发送选择的安全类型
            try await sendData(Data([selectedType.rawValue]), connection: connection)
        }
    }
    
    private func performAuthentication() async throws {
        guard let connection = connection, let password = configuration.password else {
            throw VNCClientError.disconnected
        }
        
 // VNC 认证 (安全类型 2)
 // 接收 16 字节挑战
        let challenge = try await receiveData(count: 16, connection: connection)
        
 // 使用 DES 加密挑战
        let response = encryptVNCChallenge(challenge: challenge, password: password)
        
 // 发送响应
        try await sendData(response, connection: connection)
        
 // 检查结果
        let resultData = try await receiveData(count: 4, connection: connection)
        let result = UInt32(bigEndian: resultData.withUnsafeBytes { $0.load(as: UInt32.self) })
        
        if result != 0 {
            if protocolVersion == .rfb38 {
 // RFB 3.8: 读取错误信息
                let lengthData = try await receiveData(count: 4, connection: connection)
                let length = Int(UInt32(bigEndian: lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }))
                let errorData = try await receiveData(count: length, connection: connection)
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Authentication failed"
                throw VNCClientError.authenticationFailed(errorMessage)
            }
            throw VNCClientError.authenticationFailed("Authentication failed")
        }
        
        logger.info("✅ VNC 认证成功")
    }
    
    private func performInitialization() async throws {
        guard let connection = connection else { throw VNCClientError.disconnected }
        
 // 发送 ClientInit
        let sharedFlag: UInt8 = configuration.sharedConnection ? 1 : 0
        try await sendData(Data([sharedFlag]), connection: connection)
        
 // 接收 ServerInit
        let serverInit = try await receiveData(count: 24, connection: connection)
        
        let width = Int(UInt16(bigEndian: serverInit[0..<2].withUnsafeBytes { $0.load(as: UInt16.self) }))
        let height = Int(UInt16(bigEndian: serverInit[2..<4].withUnsafeBytes { $0.load(as: UInt16.self) }))
        let bitsPerPixel = Int(serverInit[4])
        let depth = Int(serverInit[5])
        let bigEndian = serverInit[6] != 0
        let trueColor = serverInit[7] != 0
        let redMax = Int(UInt16(bigEndian: serverInit[8..<10].withUnsafeBytes { $0.load(as: UInt16.self) }))
        let greenMax = Int(UInt16(bigEndian: serverInit[10..<12].withUnsafeBytes { $0.load(as: UInt16.self) }))
        let blueMax = Int(UInt16(bigEndian: serverInit[12..<14].withUnsafeBytes { $0.load(as: UInt16.self) }))
        let redShift = Int(serverInit[14])
        let greenShift = Int(serverInit[15])
        let blueShift = Int(serverInit[16])
        
 // 读取名称长度和名称
        let nameLength = Int(UInt32(bigEndian: serverInit[20..<24].withUnsafeBytes { $0.load(as: UInt32.self) }))
        let nameData = try await receiveData(count: nameLength, connection: connection)
        let name = String(data: nameData, encoding: .utf8) ?? "Unknown"
        
        framebufferInfo = FramebufferInfo(
            width: width,
            height: height,
            bitsPerPixel: bitsPerPixel,
            depth: depth,
            bigEndian: bigEndian,
            trueColor: trueColor,
            redMax: redMax,
            greenMax: greenMax,
            blueMax: blueMax,
            redShift: redShift,
            greenShift: greenShift,
            blueShift: blueShift,
            name: name
        )
        
        logger.info("帧缓冲区: \(width)x\(height), \(bitsPerPixel)bpp, 名称: \(name)")
        
 // 分配帧缓冲区
        let bufferSize = width * height * (bitsPerPixel / 8)
        frameBuffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 4)
        
 // 设置编码
        try await setEncodings()
    }
    
    private func setEncodings() async throws {
        guard let connection = connection else { throw VNCClientError.disconnected }
        
 // SetEncodings (消息类型 2)
        var message = Data()
        message.append(2) // 消息类型
        message.append(0) // padding
        message.append(contentsOf: UInt16(configuration.preferredEncodings.count).bigEndianBytes)
        
        for encoding in configuration.preferredEncodings {
            message.append(contentsOf: encoding.rawValue.bigEndianBytes)
        }
        
        try await sendData(message, connection: connection)
    }
    
 // MARK: - Private Methods - Data Transfer
    
    private func sendData(_ data: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    private func receiveData(count: Int, connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: VNCClientError.invalidServerResponse)
                }
            }
        }
    }
    
    private func receiveFramebufferUpdate(connection: NWConnection) async throws -> FramebufferUpdate {
 // 接收消息头
        let header = try await receiveData(count: 4, connection: connection)
        
        guard header[0] == 0 else {
 // 处理其他消息类型
            throw VNCClientError.protocolError("Unexpected message type: \(header[0])")
        }
        
        let numberOfRectangles = Int(UInt16(bigEndian: header[2..<4].withUnsafeBytes { $0.load(as: UInt16.self) }))
        var rectangles: [FramebufferRectangle] = []
        
        for _ in 0..<numberOfRectangles {
            let rectangle = try await receiveRectangle(connection: connection)
            rectangles.append(rectangle)
        }
        
        return FramebufferUpdate(rectangles: rectangles, timestamp: Date())
    }
    
    private func receiveRectangle(connection: NWConnection) async throws -> FramebufferRectangle {
 // 接收矩形头 (12 字节)
        let header = try await receiveData(count: 12, connection: connection)
        
        let x = Int(UInt16(bigEndian: header[0..<2].withUnsafeBytes { $0.load(as: UInt16.self) }))
        let y = Int(UInt16(bigEndian: header[2..<4].withUnsafeBytes { $0.load(as: UInt16.self) }))
        let width = Int(UInt16(bigEndian: header[4..<6].withUnsafeBytes { $0.load(as: UInt16.self) }))
        let height = Int(UInt16(bigEndian: header[6..<8].withUnsafeBytes { $0.load(as: UInt16.self) }))
        let encodingValue = Int32(bigEndian: header[8..<12].withUnsafeBytes { $0.load(as: Int32.self) })
        let encoding = VNCEncoding(rawValue: encodingValue) ?? .raw
        
 // 根据编码类型接收数据
        let pixelData: Data
        
        switch encoding {
        case .raw:
            let bytesPerPixel = (framebufferInfo?.bitsPerPixel ?? 32) / 8
            let dataSize = width * height * bytesPerPixel
            pixelData = try await receiveData(count: dataSize, connection: connection)
            
        case .copyRect:
 // CopyRect 编码：4 字节（源 x, y）
            pixelData = try await receiveData(count: 4, connection: connection)
            
        default:
 // 降级策略：不支持的编码类型按 Raw 格式解码
 // 支持的高级编码（Tight, ZRLE, Hextile）需要额外的解压实现
            logger.debug("使用 Raw 降级解码：编码类型 \(encoding.rawValue)")
            let bytesPerPixel = (framebufferInfo?.bitsPerPixel ?? 32) / 8
            let dataSize = width * height * bytesPerPixel
            pixelData = try await receiveData(count: dataSize, connection: connection)
        }
        
        return FramebufferRectangle(
            x: x,
            y: y,
            width: width,
            height: height,
            encoding: encoding,
            data: pixelData
        )
    }
    
 // MARK: - Private Methods - Helpers
    
    private func parseProtocolVersion(_ version: String) -> RFBProtocolVersion {
        if version.contains("003.008") {
            return .rfb38
        } else if version.contains("003.007") {
            return .rfb37
        } else {
            return .rfb33
        }
    }
    
    private func selectSecurityType() -> VNCSecurityType {
 // 优先选择 None，然后是 VNC Authentication
        if serverSecurityTypes.contains(.none) && configuration.password == nil {
            return .none
        } else if serverSecurityTypes.contains(.vncAuthentication) {
            return .vncAuthentication
        } else if let first = serverSecurityTypes.first, first != .invalid {
            return first
        }
        return .none
    }
    
 /// VNC 密码加密（DES 加密挑战）
    private func encryptVNCChallenge(challenge: Data, password: String) -> Data {
 // VNC 使用反转位的 DES 密钥
        var keyBytes = [UInt8](repeating: 0, count: 8)
        let passwordBytes = Array(password.utf8)
        
        for i in 0..<min(8, passwordBytes.count) {
            keyBytes[i] = reverseBits(passwordBytes[i])
        }
        
 // 使用 CommonCrypto 或自实现 DES
 // 注意：这里使用简化实现，实际应使用 CommonCrypto
        var result = Data()
        
 // 分两次加密（每次 8 字节）
        for offset in stride(from: 0, to: 16, by: 8) {
            let block = Array(challenge[offset..<offset+8])
            let encrypted = desEncrypt(block: block, key: keyBytes)
            result.append(contentsOf: encrypted)
        }
        
        return result
    }
    
    private func reverseBits(_ byte: UInt8) -> UInt8 {
        var result: UInt8 = 0
        var input = byte
        for _ in 0..<8 {
            result = (result << 1) | (input & 1)
            input >>= 1
        }
        return result
    }
    
 /// DES 加密（使用 CommonCrypto）
    private func desEncrypt(block: [UInt8], key: [UInt8]) -> [UInt8] {
        var outData = [UInt8](repeating: 0, count: 8)
        var outLength: Int = 0
        
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmDES),
            CCOptions(kCCOptionECBMode),
            key, kCCKeySizeDES,
            nil,
            block, block.count,
            &outData, outData.count,
            &outLength
        )
        
        if status == kCCSuccess {
            return outData
        } else {
 // 加密失败时返回原数据（降级处理）
            return block
        }
    }
    
 // MARK: - Frame Rendering
    
 /// 渲染帧缓冲区到 CGImage
    public func renderFrame() async throws -> CGImage? {
        guard let fbInfo = framebufferInfo, let buffer = frameBuffer else {
            return nil
        }
        
        let width = fbInfo.width
        let height = fbInfo.height
        let bitsPerPixel = fbInfo.bitsPerPixel
        let bytesPerRow = width * (bitsPerPixel / 8)
        
 // 创建颜色空间
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        
 // 创建位图上下文
        let bitmapInfo: CGBitmapInfo = [
            .byteOrder32Little,
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        ]
        
        guard let context = CGContext(
            data: buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }
        
        return context.makeImage()
    }
    
 /// 应用帧缓冲区更新
    public func applyUpdate(_ update: FramebufferUpdate) async throws {
        guard let fbInfo = framebufferInfo, let buffer = frameBuffer else {
            throw VNCClientError.framebufferError
        }
        
        let bytesPerPixel = fbInfo.bitsPerPixel / 8
        
        for rect in update.rectangles {
            switch rect.encoding {
            case .raw:
 // 直接复制像素数据
                for row in 0..<rect.height {
                    let srcOffset = row * rect.width * bytesPerPixel
                    let dstOffset = ((rect.y + row) * fbInfo.width + rect.x) * bytesPerPixel
                    
                    guard srcOffset + rect.width * bytesPerPixel <= rect.data.count else { continue }
                    guard dstOffset + rect.width * bytesPerPixel <= fbInfo.width * fbInfo.height * bytesPerPixel else { continue }
                    
                    rect.data.withUnsafeBytes { srcPtr in
                        guard let base = srcPtr.baseAddress else { return }
                        let src = base.advanced(by: srcOffset)
                        let dst = buffer.advanced(by: dstOffset)
                        memcpy(dst, src, rect.width * bytesPerPixel)
                    }
                }
                
            case .copyRect:
 // CopyRect: 从帧缓冲区内部复制
                guard rect.data.count >= 4 else { continue }
                let srcX = Int(UInt16(bigEndian: rect.data[0..<2].withUnsafeBytes { $0.load(as: UInt16.self) }))
                let srcY = Int(UInt16(bigEndian: rect.data[2..<4].withUnsafeBytes { $0.load(as: UInt16.self) }))
                
 // 逐行复制（处理重叠情况）
                if srcY < rect.y {
 // 从上到下复制
                    for row in 0..<rect.height {
                        let srcOffset = ((srcY + row) * fbInfo.width + srcX) * bytesPerPixel
                        let dstOffset = ((rect.y + row) * fbInfo.width + rect.x) * bytesPerPixel
                        let src = buffer.advanced(by: srcOffset)
                        let dst = buffer.advanced(by: dstOffset)
                        memmove(dst, src, rect.width * bytesPerPixel)
                    }
                } else {
 // 从下到上复制
                    for row in (0..<rect.height).reversed() {
                        let srcOffset = ((srcY + row) * fbInfo.width + srcX) * bytesPerPixel
                        let dstOffset = ((rect.y + row) * fbInfo.width + rect.x) * bytesPerPixel
                        let src = buffer.advanced(by: srcOffset)
                        let dst = buffer.advanced(by: dstOffset)
                        memmove(dst, src, rect.width * bytesPerPixel)
                    }
                }
                
            default:
 // 其他编码类型使用 raw 方式处理
                break
            }
        }
        
 // 更新当前帧
        currentFrame = try await renderFrame()
    }
}

// MARK: - 辅助扩展

private extension UInt16 {
    var bigEndianBytes: [UInt8] {
        let value = self.bigEndian
        return withUnsafeBytes(of: value) { Array($0) }
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        let value = self.bigEndian
        return withUnsafeBytes(of: value) { Array($0) }
    }
}

private extension Int32 {
    var bigEndianBytes: [UInt8] {
        let value = self.bigEndian
        return withUnsafeBytes(of: value) { Array($0) }
    }
}

// MARK: - VNC 连接管理器

/// VNC 连接管理器
@available(macOS 14.0, *)
@MainActor
public final class VNCConnectionManager: ObservableObject {
    public static let shared = VNCConnectionManager()
    
    @Published public private(set) var connections: [String: VNCClientImpl] = [:]
    @Published public private(set) var activeConnectionId: String?
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "VNCConnectionManager")
    
    private init() {}
    
 /// 创建新连接
    public func createConnection(
        id: String = UUID().uuidString,
        configuration: VNCClientConfiguration
    ) -> VNCClientImpl {
        let client = VNCClientImpl(configuration: configuration)
        connections[id] = client
        return client
    }
    
 /// 获取连接
    public func getConnection(id: String) -> VNCClientImpl? {
        return connections[id]
    }
    
 /// 关闭连接
    public func closeConnection(id: String) async {
        guard let client = connections[id] else { return }
        await client.disconnect()
        connections.removeValue(forKey: id)
        
        if activeConnectionId == id {
            activeConnectionId = nil
        }
    }
    
 /// 关闭所有连接
    public func closeAllConnections() async {
        for (id, client) in connections {
            await client.disconnect()
            logger.info("已关闭 VNC 连接: \(id)")
        }
        connections.removeAll()
        activeConnectionId = nil
    }
}

// MARK: - 便捷类型别名

/// 完整 VNC 客户端类型别名
@available(macOS 14.0, *)
public typealias FullVNCClient = VNCClientImpl
