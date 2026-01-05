import SwiftUI
import CoreImage.CIFilterBuiltins
import Network
import SkyBridgeCore // 导入核心模块以使用统一的 UTF8 C 字符串解码工具

/// QR码分享视图 - 符合macOS设计规范的文件传输二维码界面
/// 采用Apple官方认证的macOS SwiftUI最佳实践
struct QRCodeSharingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var qrCodeImage: NSImage?
    @State private var serverURL: String = ""
    @State private var isServerRunning = false
    @State private var connectionCode: String = ""
    @StateObject private var server = HTTPFileTransferServer()
    @State private var accessToken: String = ""
    
    let selectedFiles: [URL]
    
    var body: some View {
        VStack(spacing: 0) {
 // macOS风格的标题栏区域
            macOSTitleBar
            
 // 主内容区域 - 使用macOS标准布局
            ScrollView {
                VStack(spacing: 24) {
 // 二维码展示区域 - macOS风格卡片
                    qrCodeCard
                    
 // 连接信息卡片
                    connectionInfoCard
                    
 // 文件列表卡片
                    if !selectedFiles.isEmpty {
                        fileListCard
                    }
                }
                .padding(20)
            }
            
 // macOS风格的底部操作栏
            macOSBottomBar
        }
        .frame(minWidth: 480, minHeight: 600)
        .background(.ultraThinMaterial)
        .onAppear {
            generateConnectionInfo()
        }
    }
    
 // MARK: - macOS风格组件
    
 /// macOS风格标题栏
    private var macOSTitleBar: some View {
        HStack {
 // 左侧图标和标题
            HStack(spacing: 12) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizationManager.shared.localizedString("qrcode.title"))
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    Text(LocalizationManager.shared.localizedString("qrcode.subtitle"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
 // 右侧关闭按钮 - macOS风格
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(LocalizationManager.shared.localizedString("action.closeWindow"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.thickMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
    
 /// 二维码卡片 - macOS风格
    private var qrCodeCard: some View {
        VStack(spacing: 20) {
 // 二维码显示区域
            ZStack {
 // 背景卡片
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThickMaterial)
                    .frame(width: 280, height: 280)
                    .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
                
                if let qrImage = qrCodeImage {
                    VStack(spacing: 16) {
 // 二维码图像
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 220, height: 220)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                        
 // 状态指示器
                        HStack(spacing: 8) {
                            Circle()
                                .fill(isServerRunning ? .green : .orange)
                                .frame(width: 8, height: 8)
                            
                            Text(isServerRunning ? LocalizationManager.shared.localizedString("qrcode.status.running") : LocalizationManager.shared.localizedString("qrcode.status.ready"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
 // 加载状态
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        
                        Text(LocalizationManager.shared.localizedString("qrcode.generating"))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
 // 使用说明 - macOS风格
            VStack(spacing: 8) {
                Text(LocalizationManager.shared.localizedString("qrcode.instruction.title"))
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(LocalizationManager.shared.localizedString("qrcode.instruction.subtitle"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        )
    }
    
 /// 连接信息卡片 - macOS风格
    private var connectionInfoCard: some View {
        VStack(alignment: .leading, spacing: 16) {
 // 卡片标题
            HStack {
                Image(systemName: "network")
                    .foregroundColor(.blue)
                    .font(.title3)
                
                Text(LocalizationManager.shared.localizedString("qrcode.connectionInfo"))
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            
            VStack(spacing: 12) {
 // 服务器地址
                if !serverURL.isEmpty {
                    macOSInfoRow(
                        title: LocalizationManager.shared.localizedString("qrcode.serverAddress"),
                        value: serverURL,
                        icon: "globe",
                        isMonospaced: true
                    )
                }
                
 // 连接码
                if !connectionCode.isEmpty {
                    macOSInfoRow(
                        title: LocalizationManager.shared.localizedString("qrcode.connectionCode"),
                        value: connectionCode,
                        icon: "key.fill",
                        isMonospaced: true,
                        isHighlighted: true
                    )
                }
                
 // 服务状态
                macOSInfoRow(
                    title: LocalizationManager.shared.localizedString("qrcode.serviceStatus"),
                    value: isServerRunning ? LocalizationManager.shared.localizedString("status.running") : LocalizationManager.shared.localizedString("status.stopped"),
                    icon: isServerRunning ? "checkmark.circle.fill" : "xmark.circle.fill",
                    statusColor: isServerRunning ? .green : .red
                )
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        )
    }
    
 /// 文件列表卡片 - macOS风格
    private var fileListCard: some View {
        VStack(alignment: .leading, spacing: 16) {
 // 卡片标题
            HStack {
                Image(systemName: "doc.on.doc")
                    .foregroundColor(.orange)
                    .font(.title3)
                
                Text(LocalizationManager.shared.localizedString("qrcode.pendingFiles"))
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Text(String(format: LocalizationManager.shared.localizedString("common.files.count"), selectedFiles.count))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
 // 文件列表
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(selectedFiles, id: \.self) { file in
                        macOSFileRow(file: file)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        )
    }
    
 /// macOS风格底部操作栏
    private var macOSBottomBar: some View {
        HStack {
 // 左侧信息
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                
                Text(LocalizationManager.shared.localizedString("qrcode.networkHint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
 // 右侧操作按钮
            HStack(spacing: 12) {
                Button(LocalizationManager.shared.localizedString("action.cancel")) {
                    stopServer()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                Button(isServerRunning ? LocalizationManager.shared.localizedString("action.stopServer") : LocalizationManager.shared.localizedString("action.startServer")) {
                    if isServerRunning {
                        stopServer()
                    } else {
                        startServer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.thickMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }
    
 // MARK: - 辅助视图组件
    
 /// macOS风格信息行
    private func macOSInfoRow(
        title: String,
        value: String,
        icon: String,
        isMonospaced: Bool = false,
        isHighlighted: Bool = false,
        statusColor: Color? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(statusColor ?? .accentColor)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(value)
                    .font(isMonospaced ? .system(.subheadline, design: .monospaced) : .subheadline)
                    .fontWeight(isHighlighted ? .semibold : .regular)
                    .foregroundColor(isHighlighted ? .accentColor : .primary)
            }
            
            Spacer()
            
 // 复制按钮
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }) {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(LocalizationManager.shared.localizedString("action.copyToClipboard"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
    
 /// macOS风格文件行
    private func macOSFileRow(file: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconForFile(file))
                .foregroundColor(.accentColor)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(file.lastPathComponent)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                Text(formatFileSize(file))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
    
 // MARK: - 私有方法
    
 /// 生成连接信息和二维码
    private func generateConnectionInfo() {
 // 生成连接码 - 6位随机数字
        connectionCode = String(format: "%06d", Int.random(in: 100000...999999))
 // 生成一次性令牌
        accessToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        
 // 获取本机IP地址
        let ipAddress = getLocalIPAddress()
        serverURL = "http://\(ipAddress):8080"
        
 // 生成二维码内容
        let qrContent = """
        {
            "type": "file_transfer",
            "server": "\(serverURL)",
            "code": "\(connectionCode)",
            "token": "\(accessToken)",
            "files": \(selectedFiles.count)
        }
        """
        
 // 生成二维码图像
        generateQRCode(from: qrContent)
    }
    
 /// 生成二维码图像
    private func generateQRCode(from string: String) {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        
        guard let data = string.data(using: .utf8) else { return }
        
        filter.message = data
        filter.correctionLevel = "M"
        
        if let outputImage = filter.outputImage {
 // 放大二维码以提高清晰度
            let transform = CGAffineTransform(scaleX: 10, y: 10)
            let scaledImage = outputImage.transformed(by: transform)
            
            if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
                qrCodeImage = NSImage(cgImage: cgImage, size: NSSize(width: 220, height: 220))
            }
        }
    }
    
 /// 启动文件传输服务器
    private func startServer() {
        guard !isServerRunning else { return }
        let ip = getLocalIPAddress()
        let port: UInt16 = 8080
        server.start(host: ip, port: port, files: selectedFiles, code: connectionCode, token: accessToken)
        serverURL = "http://\(ip):\(port)?token=\(accessToken)"
        isServerRunning = true
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "SkyBridgeCompassApp", category: "ui").debug("文件传输服务器已启动: \(serverURL)")
    }
    
 /// 停止文件传输服务器
    private func stopServer() {
        guard isServerRunning else { return }
        server.stop()
        isServerRunning = false
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "SkyBridgeCompassApp", category: "ui").debug("文件传输服务器已停止")
    }
    
 /// 获取本机IP地址
    private func getLocalIPAddress() -> String {
        var address = "127.0.0.1"
        
 // 获取所有网络接口
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return address }
        guard let firstAddr = ifaddr else { return address }
        
 // 遍历网络接口
        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            
 // 检查接口族
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                
 // 检查接口名称（使用统一 UTF8 解码，替代已弃用的 String(cString:)）
                let name = decodeCString(interface.ifa_name)
                if name == "en0" || name == "en1" || name.hasPrefix("wlan") {
                    
 // 获取IP地址
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, socklen_t(0), NI_NUMERICHOST)
                                        let end = hostname.firstIndex(of: 0) ?? hostname.count
                    let hostBytes = hostname[..<end].map { UInt8(bitPattern: $0) }
                    address = String(decoding: hostBytes, as: UTF8.self)
                    break
                }
            }
        }
        
        freeifaddrs(ifaddr)
        return address
    }
    
 /// 获取文件图标
    private func iconForFile(_ file: URL) -> String {
        let pathExtension = file.pathExtension.lowercased()
        
        switch pathExtension {
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "svg":
            return "photo"
        case "mp4", "mov", "avi", "mkv", "wmv", "flv":
            return "video"
        case "mp3", "wav", "aac", "flac", "m4a":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "doc", "docx":
            return "doc.text"
        case "xls", "xlsx":
            return "tablecells"
        case "ppt", "pptx":
            return "rectangle.on.rectangle"
        case "zip", "rar", "7z", "tar", "gz":
            return "archivebox"
        case "txt", "rtf":
            return "doc.plaintext"
        default:
            return "doc"
        }
    }
    
 /// 格式化文件大小
    private func formatFileSize(_ file: URL) -> String {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            if let fileSize = attributes[.size] as? Int64 {
                return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            }
        } catch {
            SkyBridgeLogger.ui.error("获取文件大小失败: \(error.localizedDescription, privacy: .private)")
        }
        return "未知大小"
    }
}

// MARK: - 简易HTTP文件传输服务器

final class HTTPFileTransferServer: ObservableObject, @unchecked Sendable {
    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
    private var files: [URL] = []
    private var code: String = ""
    private var token: String = ""
    private var logs: [String] = []
    
    func start(host: String, port: UInt16, files: [URL], code: String, token: String) {
        self.files = files
        self.code = code
        self.token = token
        do {
            let nwPort = NWEndpoint.Port(rawValue: port)!
            let parameters = NWParameters.tcp
            let listener = try NWListener(using: parameters, on: nwPort)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
            log("Server started on :\(port)")
        } catch {
            SkyBridgeLogger.ui.error("❌ 启动HTTP服务器失败: \(error.localizedDescription, privacy: .private)")
            log("Start failed: \(error.localizedDescription)")
        }
    }
    
    func stop() {
        activeConnections.forEach { $0.cancel() }
        activeConnections.removeAll()
        listener?.cancel()
        listener = nil
    }
    
    private func handleConnection(_ connection: NWConnection) {
        activeConnections.append(connection)
        connection.stateUpdateHandler = { state in
            if case .failed(let err) = state { SkyBridgeLogger.ui.error("连接失败: \(String(describing: err), privacy: .private)") }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(on: connection)
    }
    
    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, error == nil {
                let request = String(decoding: data, as: UTF8.self)
                let response = self.route(request: request)
                self.send(response: response, on: connection)
            } else {
                connection.cancel()
            }
        }
    }
    
    private func send(response: Data, on connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func route(request: String) -> Data {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            return httpResponse(400, body: "Bad Request")
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return httpResponse(400, body: "Bad Request") }
        let pathWithQuery = String(parts[1])
        let urlParts = pathWithQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(urlParts.first ?? "/")
        let query = urlParts.count > 1 ? String(urlParts[1]) : ""
        var queryItems = Self.parseQuery(query)
 // 从首行无token时尝试从 Host: 后续行中解析（兜底）
 // 校验 token
        if path != "/" {
            if queryItems["token"] == nil {
 // 尝试从Referer中解析
                if let refererLine = lines.first(where: { $0.lowercased().hasPrefix("referer:") }) {
                    let ref = refererLine.split(separator: " ", maxSplits: 1).dropFirst().joined(separator: " ")
                    if let refQuery = ref.split(separator: "?").dropFirst().first {
                        let refItems = Self.parseQuery(String(refQuery))
                        for (k,v) in refItems { queryItems[k] = v }
                    }
                }
            }
            guard queryItems["token"] == token else { return httpResponse(403, body: "Forbidden") }
        }
        
 // 解析 Range 头
        let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }
        let rangeValue = rangeHeader?.split(separator: " ", maxSplits: 1).dropFirst().joined(separator: " ")
        
        if path == "/" { return indexHTML() }
        if path == "/download" {
 // 简单的连接码校验（可选）
            if let c = queryItems["code"], c != code { return httpResponse(403, body: "Forbidden") }
            guard let indexStr = queryItems["i"], let idx = Int(indexStr), files.indices.contains(idx) else {
                return httpResponse(404, body: "Not Found")
            }
            return serveFile(files[idx], range: rangeValue)
        }
        if path == "/bundle.zip" {
            if let c = queryItems["code"], c != code { return httpResponse(403, body: "Forbidden") }
            return serveZip(files: files)
        }
        return httpResponse(404, body: "Not Found")
    }
    
    private func indexHTML() -> Data {
        let list = files.enumerated().map { (i, url) in
            "<li><a href=\"/download?i=\(i)&code=\(code)&token=\(token)\">\(url.lastPathComponent)</a></li>"
        }.joined(separator: "\n")
        let html = """
        <html><head><meta charset='utf-8'><title>文件传输</title></head>
        <body>
        <h3>连接码: \(code)</h3>
        <p><a href=\"/bundle.zip?code=\(code)&token=\(token)\">下载全部（zip）</a></p>
        <ul>\(list)</ul>
        </body></html>
        """
        return httpResponse(200, body: html, contentType: "text/html; charset=utf-8")
    }
    
    private func serveFile(_ url: URL, range: String?) -> Data {
        guard let fileData = try? Data(contentsOf: url) else {
            return httpResponse(500, body: "Failed to read file")
        }
        let mime = mimeType(for: url)
 // 处理 Range：bytes=start-
        if let range, range.lowercased().hasPrefix("bytes=") {
            let spec = range.replacingOccurrences(of: "bytes=", with: "")
            if let startStr = spec.split(separator: "-").first, let start = Int(startStr), start < fileData.count {
                let slice = fileData[start...]
                return httpResponse(206, bodyData: Data(slice), contentType: mime, totalLength: fileData.count, rangeStart: start)
            }
        }
        return httpResponse(200, bodyData: fileData, contentType: mime)
    }
    
    private func serveZip(files: [URL]) -> Data {
 // 使用系统zip创建临时包
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bundle_\(UUID().uuidString).zip")
        let process = Process()
        process.launchPath = "/usr/bin/zip"
        process.arguments = ["-j", temp.path] + files.map { $0.path }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0, let data = try? Data(contentsOf: temp) {
                return httpResponse(200, bodyData: data, contentType: "application/zip")
            } else {
                let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "zip failed"
                log("zip error: \(err)")
                return httpResponse(500, body: "Zip failed")
            }
        } catch {
            log("zip exception: \(error.localizedDescription)")
            return httpResponse(500, body: "Zip exception")
        }
    }
    
    private func httpResponse(_ code: Int, body: String, contentType: String = "text/plain; charset=utf-8") -> Data {
        let bodyData = Data(body.utf8)
        return httpResponse(code, bodyData: bodyData, contentType: contentType)
    }
    
    private func httpResponse(_ code: Int, bodyData: Data, contentType: String, totalLength: Int? = nil, rangeStart: Int? = nil) -> Data {
        let status = (code == 200) ? "OK" : (code == 404 ? "Not Found" : (code == 403 ? "Forbidden" : "Error"))
        var headers = "HTTP/1.1 \(code) \(status)\r\n"
        headers += "Content-Type: \(contentType)\r\n"
        headers += "Content-Length: \(bodyData.count)\r\n"
        headers += "Accept-Ranges: bytes\r\n"
        if code == 206, let totalLength, let rangeStart {
            headers += "Content-Range: bytes \(rangeStart)-\(rangeStart + bodyData.count - 1)/\(totalLength)\r\n"
        }
        headers += "Connection: close\r\n\r\n"
        var data = Data(headers.utf8)
        data.append(bodyData)
        return data
    }
    
    private static func parseQuery(_ q: String) -> [String: String] {
        var dict: [String: String] = [:]
        for part in q.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                dict[String(kv[0])] = String(kv[1])
            }
        }
        return dict
    }
    
    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }
    
    private func log(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        logs.append("[\(ts)] \(msg)")
        if logs.count > 200 { logs.removeFirst() }
    }
}
import OSLog
