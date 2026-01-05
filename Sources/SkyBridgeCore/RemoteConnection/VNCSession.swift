import Foundation
import Network
import os.log
// 注意：本文件位于 SkyBridgeCore 模块，无需导入自身模块

/// VNC(RFB) 会话实现（基础版）
/// 中文说明：实现 RFB 3.8 的无认证握手、Raw 编码帧缓冲更新解析，并将整帧以 BGRA32 发布到 RemoteTextureFeed。
@MainActor
public final class VNCSession: ObservableObject {
    public let host: String
    public let port: UInt16
    public let textureFeed = RemoteTextureFeed()

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "VNCSession")
    private let queue = DispatchQueue(label: "com.skybridge.vnc.session")
    private var connection: NWConnection?
    private var framebufferWidth: Int = 0
    private var framebufferHeight: Int = 0
    private var renderer = RemoteFrameRenderer()
    private var framebuffer: Data = Data()
    private var running = false
    private var currentButtonMask: UInt8 = 0
    private enum VNCError: Error { case invalidFrameSize }

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
 // 将渲染器输出绑定到纹理发布器
        renderer.frameHandler = { [weak self] texture in
            guard let self else { return }
            Task { @MainActor in
                self.textureFeed.update(texture: texture)
            }
        }
    }

 /// 启动 VNC 会话
    public func start() async throws {
        guard !running else { return }
        running = true
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn
        conn.start(queue: queue)

        try await waitReady(conn)

 // 版本协商
        let serverVersion = try await recvExact(count: 12)
        guard let verStr = String(data: serverVersion, encoding: .ascii), verStr.hasPrefix("RFB ") else {
            throw CocoaError(.featureUnsupported)
        }
 // 使用 RFB 3.8
        try await send(bytes: Array("RFB 003.008\n".utf8))

 // 安全类型
        let secCountData = try await recvExact(count: 1)
        let secCount = Int(secCountData[0])
        guard secCount > 0 else {
 // 读取错误原因
            let reasonLenData = try await recvExact(count: 4)
            let len = Int(UInt32(bigEndian: reasonLenData.withUnsafeBytes { $0.load(as: UInt32.self) }))
            let reason = try await recvExact(count: len)
            let msg = String(data: reason, encoding: .utf8) ?? "未知错误"
            throw NSError(domain: "VNC", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let types = try await recvExact(count: secCount)
        guard types.contains(1) else { throw CocoaError(.featureUnsupported) } // 1 = None
        try await send(bytes: [UInt8(1)])

 // SecurityResult
        let secResult = try await recvExact(count: 4)
        let secStatus = UInt32(bigEndian: secResult.withUnsafeBytes { $0.load(as: UInt32.self) })
        guard secStatus == 0 else { throw CocoaError(.fileReadUnknown) }

 // ClientInit(shared = 1)
        try await send(bytes: [UInt8(1)])

 // ServerInit
        let serverInit = try await recvExact(count: 24) // 2+2 + 16 + 4(partial name len)
        let w = Int(UInt16(bigEndian: serverInit.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self) }))
        let h = Int(UInt16(bigEndian: serverInit.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self) }))
        framebufferWidth = w
        framebufferHeight = h
 // 剩余读取：像素格式已获取，继续读取 name-length 与 name
        let nameLen = Int(UInt32(bigEndian: serverInit.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }))
        let nameData = try await recvExact(count: nameLen)
        let name = String(data: nameData, encoding: .utf8) ?? "VNC Server"
        logger.info("VNC 服务器: \(name) \(w)x\(h)")

 // 设置像素格式：BGRA32, little-endian, true-color 8bits
        var pf: [UInt8] = []
        pf.append(contentsOf: [32, 24, 0, 1]) // bpp=32, depth=24, bigEndian=0, trueColor=1
        pf.append(contentsOf: withUnsafeBytes(of: UInt16(255).bigEndian, Array.init)) // redMax
        pf.append(contentsOf: withUnsafeBytes(of: UInt16(255).bigEndian, Array.init)) // greenMax
        pf.append(contentsOf: withUnsafeBytes(of: UInt16(255).bigEndian, Array.init)) // blueMax
        pf.append(contentsOf: [16, 8, 0]) // redShift=16, greenShift=8, blueShift=0
        pf.append(contentsOf: [0, 0, 0]) // padding
        var setPixelFormat: [UInt8] = [0, 0, 0] // message-type=0, padding
        setPixelFormat.append(contentsOf: pf)
        try await send(bytes: setPixelFormat)

 // 设置编码：Raw
        var setEnc: [UInt8] = [2, 0]
        setEnc.append(contentsOf: withUnsafeBytes(of: UInt16(2).bigEndian, Array.init)) // 2 encodings
        setEnc.append(contentsOf: withUnsafeBytes(of: Int32(0).bigEndian, Array.init)) // RAW
        setEnc.append(contentsOf: withUnsafeBytes(of: Int32(1).bigEndian, Array.init)) // CopyRect
        try await send(bytes: setEnc)

 // 初次请求全屏更新
        try await requestUpdate(incremental: false, x: 0, y: 0, w: UInt16(w), h: UInt16(h))

 // 接收更新循环
        while running {
            let mtype = try await recvExact(count: 1)[0]
            if mtype == 0 { // FramebufferUpdate
                let rectCountData = try await recvExact(count: 1) // padding
                _ = rectCountData
                let rcData = try await recvExact(count: 2)
                let rectCount = Int(UInt16(bigEndian: rcData.withUnsafeBytes { $0.load(as: UInt16.self) }))
                guard w > 0, h > 0 else {
                    logger.error("收到异常 VNC 帧尺寸 w=\(w), h=\(h)")
                    throw VNCError.invalidFrameSize
                }
                var frame = framebuffer
                if frame.count != w * h * 4 { frame = Data(count: w * h * 4) }
                for _ in 0..<rectCount {
                    let head = try await recvExact(count: 12)
                    let rx = Int(UInt16(bigEndian: head.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self) }))
                    let ry = Int(UInt16(bigEndian: head.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self) }))
                    let rw = Int(UInt16(bigEndian: head.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) }))
                    let rh = Int(UInt16(bigEndian: head.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }))
                    let enc = Int32(bigEndian: head.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Int32.self) })
                    if enc == 0 { // RAW
                        let byteCount = rw * rh * 4
                        let rectData = try await recvExact(count: byteCount)
 // 边界检查，避免越界写入
                        guard rw > 0, rh > 0, rx >= 0, ry >= 0, rx + rw <= w, ry + rh <= h else {
                            logger.error("收到异常 rect 尺寸/位置 rw=\(rw), rh=\(rh), rx=\(rx), ry=\(ry), 帧=\(w)x\(h)")
                            continue
                        }
 // 拷贝到整帧缓冲
                        frame.withUnsafeMutableBytes { dstPtr in
                            rectData.withUnsafeBytes { srcPtr in
                                guard let dstBase = dstPtr.baseAddress, let srcBase = srcPtr.baseAddress else {
                                    logger.error("VNC 帧缓冲区 baseAddress 为 nil")
                                    return
                                }
                                for row in 0..<rh {
                                    let dstOffset = ((ry + row) * w + rx) * 4
                                    let srcOffset = row * rw * 4
                                    let dst = dstBase.advanced(by: dstOffset)
                                    let src = srcBase.advanced(by: srcOffset)
                                    memcpy(dst, src, rw * 4)
                                }
                            }
                        }
                    } else if enc == 1 { // CopyRect
                        let extra = try await recvExact(count: 4)
                        let srcX = Int(UInt16(bigEndian: extra.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self) }))
                        let srcY = Int(UInt16(bigEndian: extra.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self) }))
 // 边界检查
                        guard rw > 0, rh > 0, rx >= 0, ry >= 0, srcX >= 0, srcY >= 0,
                              rx + rw <= w, ry + rh <= h, srcX + rw <= w, srcY + rh <= h else {
                            logger.error("CopyRect 越界: src=(\(srcX),\(srcY)) size=\(rw)x\(rh) dst=(\(rx),\(ry)) 帧=\(w)x\(h)")
                            continue
                        }
 // 逐行拷贝
                        frame.withUnsafeMutableBytes { bufPtr in
                            guard let base = bufPtr.baseAddress else {
                                logger.error("VNC 帧缓冲区 baseAddress 为 nil")
                                return
                            }
                            for row in 0..<rh {
                                let dstOffset = ((ry + row) * w + rx) * 4
                                let srcOffset = ((srcY + row) * w + srcX) * 4
                                let dst = base.advanced(by: dstOffset)
                                let src = base.advanced(by: srcOffset)
                                memmove(dst, src, rw * 4)
                            }
                        }
                    } else {
 // 其他编码暂不支持：跳过或丢弃
                        logger.warning("未支持的编码: \(enc)")
                        break
                    }
                }
                framebuffer = frame
                let metrics = renderer.processFrame(data: frame, width: w, height: h, stride: w * 4, type: .bgra)
                logger.debug("VNC 帧：bw=\(String(format: "%.1f", metrics.bandwidthMbps))Mbps, lat=\(Int(metrics.latencyMilliseconds))ms")
 // 请求增量更新
                try await requestUpdate(incremental: true, x: 0, y: 0, w: UInt16(w), h: UInt16(h))
            } else {
 // 跳过未知消息
                logger.debug("VNC 未知消息类型: \(mtype)")
            }
        }
    }

    public func stop() {
        running = false
        connection?.cancel()
        connection = nil
    }

 // MARK: - 私有方法

    private func waitReady(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: cont.resume()
                case .failed(let err): cont.resume(throwing: err)
                case .cancelled: cont.resume(throwing: CancellationError())
                default: break
                }
            }
        }
    }

    private func send(bytes: [UInt8]) async throws {
        guard let conn = connection else { throw CocoaError(.fileNoSuchFile) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(bytes), completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    private func recvExact(count: Int) async throws -> Data {
        guard let conn = connection else { throw CocoaError(.fileNoSuchFile) }
        var buffer = Data()
        while buffer.count < count {
            let chunk = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: count - buffer.count) { data, _, _, err in
                    if let err { cont.resume(throwing: err) }
                    else { cont.resume(returning: data ?? Data()) }
                }
            }
            if chunk.isEmpty { throw CocoaError(.fileReadUnknown) }
            buffer.append(chunk)
        }
        return buffer
    }

    private func requestUpdate(incremental: Bool, x: UInt16, y: UInt16, w: UInt16, h: UInt16) async throws {
        var msg: [UInt8] = [3, incremental ? 1 : 0]
        msg.append(contentsOf: withUnsafeBytes(of: x.bigEndian, Array.init))
        msg.append(contentsOf: withUnsafeBytes(of: y.bigEndian, Array.init))
        msg.append(contentsOf: withUnsafeBytes(of: w.bigEndian, Array.init))
        msg.append(contentsOf: withUnsafeBytes(of: h.bigEndian, Array.init))
        try await send(bytes: msg)
    }

 // MARK: - 输入事件

    public func sendPointerEvent(x: Int, y: Int, eventType: String, button: Int) async {
 // RFB PointerEvent: [5, buttonMask, x(2 BE), y(2 BE)]
        var mask = currentButtonMask
        switch eventType {
        case "leftMouseDown": mask |= 1
        case "leftMouseUp": mask &= ~1
        case "rightMouseDown": mask |= 4
        case "rightMouseUp": mask &= ~4
        case "mouseMoved": break
        case "scrollUp": mask = 8
        case "scrollDown": mask = 16
        default: break
        }
        currentButtonMask = mask
        var msg: [UInt8] = [5, mask]
        msg.append(contentsOf: withUnsafeBytes(of: UInt16(x).bigEndian, Array.init))
        msg.append(contentsOf: withUnsafeBytes(of: UInt16(y).bigEndian, Array.init))
        try? await send(bytes: msg)
    }

    public func sendKeyEvent(down: Bool, keyCode: UInt32) async {
 // RFB KeyEvent: [4, down-flag, padding(2), key(4 BE)]
        var msg: [UInt8] = [4, down ? 1 : 0, 0, 0]
        msg.append(contentsOf: withUnsafeBytes(of: keyCode.bigEndian, Array.init))
        try? await send(bytes: msg)
    }
}
