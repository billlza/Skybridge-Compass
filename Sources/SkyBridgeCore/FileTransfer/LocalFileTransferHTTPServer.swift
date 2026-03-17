import Foundation
import Network
import UniformTypeIdentifiers

final class LocalFileTransferHTTPServer: @unchecked Sendable {
    private final class StartState: @unchecked Sendable {
        var finished = false
    }

    struct AccessGrant: Sendable {
        let token: String
        let expiresAt: Date
    }

    struct Callbacks: Sendable {
        let activeLinkCount: @Sendable () async -> Int
        let lookupLink: @Sendable (String) async -> TransferLink?
        let authorizePassword: @Sendable (String, String) async -> AccessGrant?
        let validateAccessToken: @Sendable (String, String) async -> Bool
        let recordDownload: @Sendable (String) async -> Void
    }

    private struct HTTPRequest: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data

        var cookies: [String: String] {
            Self.parseCookies(from: headers["cookie"] ?? "")
        }

        var formFields: [String: String] {
            guard let contentType = headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  contentType.caseInsensitiveCompare("application/x-www-form-urlencoded") == .orderedSame,
                  let bodyString = String(data: body, encoding: .utf8) else {
                return [:]
            }
            return Self.parseForm(bodyString)
        }

        private static func parseCookies(from raw: String) -> [String: String] {
            raw
                .split(separator: ";")
                .map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
                .reduce(into: [String: String]()) { result, parts in
                    guard parts.count == 2 else { return }
                    result[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
                }
        }

        private static func parseForm(_ raw: String) -> [String: String] {
            raw
                .split(separator: "&")
                .map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
                .reduce(into: [String: String]()) { result, parts in
                    guard let key = parts.first?.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { return }
                    let value = parts.count > 1
                        ? parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
                        : ""
                    result[key] = value
                }
        }
    }

    private struct HTTPResponse {
        enum Body {
            case data(Data)
            case file(url: URL, offset: Int64, length: Int64, cleanupURL: URL?)
        }

        let header: Data
        let body: Body
        let onHeaderSent: (@Sendable () async -> Void)?
    }

    private let callbacks: Callbacks
    private let accessCookieName = "SkyBridgeLinkAccess"
    private let queue = DispatchQueue(label: "local.file.transfer.http", qos: .userInitiated)

    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

    init(callbacks: Callbacks) {
        self.callbacks = callbacks
    }

    func start(port: UInt16) async throws {
        guard listener == nil else { return }

        let nwPort = try NWEndpoint.Port.validated(port)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let startState = StartState()
            listener.stateUpdateHandler = { state in
                guard !startState.finished else { return }
                switch state {
                case .ready:
                    startState.finished = true
                    continuation.resume()
                case .failed(let error):
                    startState.finished = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: self.queue)
        }

        self.listener = listener
    }

    func stop() {
        activeConnections.values.forEach { $0.cancel() }
        activeConnections.removeAll()
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        activeConnections[identifier] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.activeConnections.removeValue(forKey: identifier)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil, let data, !data.isEmpty else {
                connection.cancel()
                return
            }

            var combined = accumulated
            combined.append(data)

            if self.isCompleteHTTPRequest(combined) {
                Task {
                    let response = await self.route(data: combined)
                    await self.send(response: response, on: connection)
                }
                return
            }

            if isComplete {
                Task {
                    let response = await self.route(data: combined)
                    await self.send(response: response, on: connection)
                }
                return
            }

            self.receiveRequest(on: connection, accumulated: combined)
        }
    }

    private func route(data: Data) async -> HTTPResponse {
        guard let request = parseRequest(data) else {
            return makeTextResponse(statusCode: 400, body: "Bad Request")
        }

        if request.method == "GET", request.path == "/status" {
            let activeLinks = await callbacks.activeLinkCount()
            let payload = [
                "server": "SkyBridge Transfer Link Server",
                "version": "2.0.0",
                "active_links": activeLinks,
                "uptime": Int(Date().timeIntervalSince1970)
            ] as [String: Any]
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
            return makeResponse(
                statusCode: 200,
                body: .data(data),
                contentType: "application/json; charset=utf-8"
            )
        }

        if request.method == "GET", let route = parsePrimaryRoute(path: request.path) {
            switch route {
            case .preview(let linkID):
                return await previewResponse(for: linkID, request: request)
            case .download(let linkID, let index):
                return await downloadResponse(for: linkID, index: index, request: request)
            case .bundle(let linkID):
                return await bundleResponse(for: linkID, request: request)
            case .unlock:
                return makeTextResponse(statusCode: 405, body: "Method Not Allowed")
            }
        }

        if request.method == "POST", let route = parsePrimaryRoute(path: request.path), case .unlock(let linkID) = route {
            return await unlockResponse(for: linkID, request: request)
        }

        if request.method == "GET", let legacy = parseLegacyRoute(request: request) {
            switch legacy {
            case .download(let linkID, let index):
                return await downloadResponse(for: linkID, index: index, request: request)
            case .bundle(let linkID):
                return await bundleResponse(for: linkID, request: request)
            }
        }

        return makeTextResponse(statusCode: 404, body: "Not Found")
    }

    private enum PrimaryRoute {
        case preview(linkID: String)
        case unlock(linkID: String)
        case download(linkID: String, index: Int)
        case bundle(linkID: String)
    }

    private enum LegacyRoute {
        case download(linkID: String, index: Int)
        case bundle(linkID: String)
    }

    private func parsePrimaryRoute(path: String) -> PrimaryRoute? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts.first == "link" else { return nil }
        let linkID = parts[1]
        if parts.count == 2 {
            return .preview(linkID: linkID)
        }
        if parts.count == 3, parts[2] == "unlock" {
            return .unlock(linkID: linkID)
        }
        if parts.count == 3, parts[2] == "bundle" {
            return .bundle(linkID: linkID)
        }
        if parts.count == 4, parts[2] == "download", let index = Int(parts[3]) {
            return .download(linkID: linkID, index: index)
        }
        return nil
    }

    private func parseLegacyRoute(request: HTTPRequest) -> LegacyRoute? {
        let parts = request.path.split(separator: "/").map(String.init)
        if parts.count >= 3, parts.first == "download" {
            let linkID = parts[1]
            let requestedName = parts[2].removingPercentEncoding ?? parts[2]
            return .download(linkID: linkID, index: legacyIndex(for: linkID, requestedName: requestedName))
        }
        if request.path == "/download" {
            guard let linkID = request.query["linkId"] ?? request.query["code"],
                  let indexRaw = request.query["i"],
                  let index = Int(indexRaw) else {
                return nil
            }
            return .download(linkID: linkID, index: index)
        }
        if request.path == "/bundle.zip",
           let linkID = request.query["linkId"] ?? request.query["code"] {
            return .bundle(linkID: linkID)
        }
        return nil
    }

    private func legacyIndex(for linkID: String, requestedName: String) -> Int {
        _ = linkID
        _ = requestedName
        return -1
    }

    private func previewResponse(for linkID: String, request: HTTPRequest) async -> HTTPResponse {
        guard let link = await callbacks.lookupLink(linkID), link.isActive, !link.isExpired else {
            return makeTextResponse(statusCode: 404, body: "Link not found")
        }

        if link.password != nil, !(await isAuthorized(request: request, linkID: linkID)) {
            let html = unlockHTML(for: link, errorMessage: nil)
            return makeHTMLResponse(statusCode: 200, pageType: "unlock", html: html)
        }

        let html = previewHTML(for: link)
        return makeHTMLResponse(statusCode: 200, pageType: "preview", html: html)
    }

    private func unlockResponse(for linkID: String, request: HTTPRequest) async -> HTTPResponse {
        guard let link = await callbacks.lookupLink(linkID), link.isActive, !link.isExpired else {
            return makeTextResponse(statusCode: 404, body: "Link not found")
        }

        guard link.password != nil else {
            return redirectResponse(location: "/link/\(urlPathEscape(linkID))", cookie: nil)
        }

        let password = request.formFields["password"] ?? ""
        guard let grant = await callbacks.authorizePassword(linkID, password) else {
            let html = unlockHTML(for: link, errorMessage: "密码错误或链接无效，请重试。")
            return makeHTMLResponse(statusCode: 401, pageType: "unlock", html: html)
        }

        let cookie = "\(accessCookieName)=\(grant.token); Path=/link/\(urlPathEscape(linkID)); HttpOnly; SameSite=Lax; Max-Age=\(max(1, Int(grant.expiresAt.timeIntervalSinceNow.rounded(.down))))"
        return redirectResponse(location: "/link/\(urlPathEscape(linkID))", cookie: cookie)
    }

    private func downloadResponse(for linkID: String, index: Int, request: HTTPRequest) async -> HTTPResponse {
        guard let link = await callbacks.lookupLink(linkID), link.isActive, !link.isExpired else {
            return makeTextResponse(statusCode: 404, body: "Link not found")
        }
        guard await isAuthorized(request: request, linkID: linkID, requiresPassword: link.password != nil) else {
            if link.password != nil {
                return redirectResponse(location: "/link/\(urlPathEscape(linkID))", cookie: nil)
            }
            return makeTextResponse(statusCode: 403, body: "Forbidden")
        }

        let resolvedIndex: Int
        if index >= 0 {
            resolvedIndex = index
        } else if let fileIndex = link.files.firstIndex(where: { $0.lastPathComponent == ((request.path.split(separator: "/").last).map(String.init) ?? "") }) {
            resolvedIndex = fileIndex
        } else {
            return makeTextResponse(statusCode: 404, body: "Not Found")
        }

        guard link.files.indices.contains(resolvedIndex) else {
            return makeTextResponse(statusCode: 404, body: "Not Found")
        }

        return fileResponse(for: link.files[resolvedIndex], linkID: linkID, rangeHeader: request.headers["range"])
    }

    private func bundleResponse(for linkID: String, request: HTTPRequest) async -> HTTPResponse {
        guard let link = await callbacks.lookupLink(linkID), link.isActive, !link.isExpired else {
            return makeTextResponse(statusCode: 404, body: "Link not found")
        }
        guard await isAuthorized(request: request, linkID: linkID, requiresPassword: link.password != nil) else {
            if link.password != nil {
                return redirectResponse(location: "/link/\(urlPathEscape(linkID))", cookie: nil)
            }
            return makeTextResponse(statusCode: 403, body: "Forbidden")
        }

        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bundle_\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-j", temp.path] + link.files.map(\.path)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: temp.path),
                  let fileSize = attributes[.size] as? NSNumber else {
                try? FileManager.default.removeItem(at: temp)
                return makeTextResponse(statusCode: 500, body: "Zip failed")
            }

            return streamedFileResponse(
                url: temp,
                mime: "application/zip",
                totalLength: fileSize.int64Value,
                offset: 0,
                length: fileSize.int64Value,
                contentRange: nil,
                cleanupURL: temp,
                downloadFilename: "\(linkID).zip",
                linkID: linkID
            )
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return makeTextResponse(statusCode: 500, body: "Zip failed")
        }
    }

    private func fileResponse(for url: URL, linkID: String, rangeHeader: String?) -> HTTPResponse {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return makeTextResponse(statusCode: 500, body: "Failed to stat file")
        }

        let totalLength = fileSize.int64Value
        let mime = mimeType(for: url)
        var offset: Int64 = 0
        var length: Int64 = totalLength
        var contentRange: String?

        if let rangeHeader, let parsed = parseByteRange(rangeHeader, totalLength: totalLength) {
            offset = parsed.offset
            length = parsed.length
            contentRange = parsed.contentRange
        }

        return streamedFileResponse(
            url: url,
            mime: mime,
            totalLength: totalLength,
            offset: offset,
            length: length,
            contentRange: contentRange,
            cleanupURL: nil,
            downloadFilename: url.lastPathComponent,
            linkID: linkID
        )
    }

    private func streamedFileResponse(
        url: URL,
        mime: String,
        totalLength: Int64,
        offset: Int64,
        length: Int64,
        contentRange: String?,
        cleanupURL: URL?,
        downloadFilename: String,
        linkID: String
    ) -> HTTPResponse {
        var extraHeaders: [(String, String)] = [
            ("Accept-Ranges", "bytes"),
            ("Content-Disposition", contentDisposition(for: downloadFilename))
        ]
        if let contentRange {
            extraHeaders.append(("Content-Range", contentRange))
        }

        let statusCode = contentRange == nil ? 200 : 206
        return makeResponse(
            statusCode: statusCode,
            body: .file(url: url, offset: offset, length: length, cleanupURL: cleanupURL),
            contentType: mime,
            contentLength: Int(length),
            extraHeaders: extraHeaders,
            onHeaderSent: { [callbacks] in
                await callbacks.recordDownload(linkID)
            }
        )
    }

    private func isAuthorized(request: HTTPRequest, linkID: String, requiresPassword: Bool = true) async -> Bool {
        guard requiresPassword else { return true }
        if let token = request.cookies[accessCookieName], await callbacks.validateAccessToken(linkID, token) {
            return true
        }
        if let token = request.query["access"], await callbacks.validateAccessToken(linkID, token) {
            return true
        }
        return false
    }

    private func send(response: HTTPResponse, on connection: NWConnection) async {
        do {
            try await sendData(response.header, on: connection)
            if let onHeaderSent = response.onHeaderSent {
                await onHeaderSent()
            }

            switch response.body {
            case .data(let data):
                if !data.isEmpty {
                    try await sendData(data, on: connection)
                }
                connection.cancel()
            case .file(let url, let offset, let length, let cleanupURL):
                defer {
                    if let cleanupURL {
                        try? FileManager.default.removeItem(at: cleanupURL)
                    }
                    connection.cancel()
                }
                try await streamFile(url: url, offset: offset, length: length, on: connection)
            }
        } catch {
            connection.cancel()
        }
    }

    private func sendData(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func streamFile(url: URL, offset: Int64, length: Int64, on connection: NWConnection) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))

        var remaining = length
        while remaining > 0 {
            let chunkSize = Int(min(remaining, 64 * 1024))
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            remaining -= Int64(chunk.count)
            try await sendData(chunk, on: connection)
        }
    }

    private func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let raw = String(data: data, encoding: .utf8),
              let separatorRange = raw.range(of: "\r\n\r\n") else {
            return nil
        }

        let headerPart = String(raw[..<separatorRange.lowerBound])
        let bodyPart = String(raw[separatorRange.upperBound...])
        let lines = headerPart.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestLineParts = requestLine.split(separator: " ")
        guard requestLineParts.count >= 2 else { return nil }

        let method = String(requestLineParts[0]).uppercased()
        let target = String(requestLineParts[1])
        let parsedURL = URLComponents(string: target)
        let path = parsedURL?.path ?? target
        let queryItems = parsedURL?.queryItems?.reduce(into: [String: String]()) { result, item in
            result[item.name] = item.value ?? ""
        } ?? [:]

        let headers = lines.dropFirst().reduce(into: [String: String]()) { result, line in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            result[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }

        return HTTPRequest(
            method: method,
            path: path,
            query: queryItems,
            headers: headers,
            body: Data(bodyPart.utf8)
        )
    }

    private func isCompleteHTTPRequest(_ data: Data) -> Bool {
        guard let raw = String(data: data, encoding: .utf8),
              let separatorRange = raw.range(of: "\r\n\r\n") else {
            return false
        }

        let headerPart = String(raw[..<separatorRange.lowerBound])
        let bodyPart = String(raw[separatorRange.upperBound...])
        let headers = headerPart.components(separatedBy: "\r\n").dropFirst()
        let contentLength = headers
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { line in
                line.split(separator: ":", maxSplits: 1).last.map(String.init)?
                    .trimmingCharacters(in: .whitespaces)
            }
            .flatMap(Int.init) ?? 0

        return bodyPart.utf8.count >= contentLength
    }

    private func unlockHTML(for link: TransferLink, errorMessage: String?) -> String {
        let message = errorMessage.map { "<p class=\"error\">\(escapeHTML($0))</p>" } ?? ""
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <meta name="skybridge-transfer" content="v1">
            <title>SkyBridge 文件传输</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; margin: 0; padding: 32px 16px; background: #f5f5f7; color: #1d1d1f; }
                .card { max-width: 420px; margin: 0 auto; background: white; border-radius: 16px; padding: 24px; box-shadow: 0 12px 40px rgba(0, 0, 0, 0.08); }
                h1 { margin-top: 0; font-size: 24px; }
                p { color: #666; }
                label { display: block; margin: 16px 0 8px; font-size: 14px; font-weight: 600; }
                input { width: 100%; box-sizing: border-box; padding: 12px; border-radius: 10px; border: 1px solid #d0d0d7; }
                button { width: 100%; margin-top: 16px; padding: 12px; border-radius: 10px; border: none; background: #007aff; color: white; font-weight: 600; }
                .meta { margin-top: 16px; font-size: 13px; color: #666; }
                .error { color: #c62828; font-weight: 600; }
            </style>
        </head>
        <body>
            <div class="card">
                <h1>文件传输受保护</h1>
                <p>此链接需要密码后才能查看和下载文件。</p>
                \(message)
                <form method="post" action="/link/\(urlPathEscape(link.id))/unlock">
                    <label for="password">访问密码</label>
                    <input id="password" name="password" type="password" autocomplete="off" />
                    <button type="submit">解锁链接</button>
                </form>
                <div class="meta">
                    <p>过期时间：\(escapeHTML(formatDate(link.expiresAt)))</p>
                    <p>剩余下载次数：\(link.remainingDownloads)</p>
                </div>
            </div>
        </body>
        </html>
        """
    }

    private func previewHTML(for link: TransferLink) -> String {
        let fileList = link.files.enumerated().map { index, fileURL in
            let name = escapeHTML(fileURL.lastPathComponent)
            let encodedIndex = String(index)
            let size = escapeHTML(formatFileSize(fileURL))
            return """
            <li class="file-item">
                <div class="file-info">
                    <span class="file-name">\(name)</span>
                    <span class="file-size">\(size)</span>
                </div>
                <a class="download-btn" href="/link/\(urlPathEscape(link.id))/download/\(encodedIndex)">下载</a>
            </li>
            """
        }.joined()

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <meta name="skybridge-transfer" content="v1">
            <title>SkyBridge 文件传输</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; margin: 0; padding: 20px; background: #f5f5f7; }
                .container { max-width: 680px; margin: 0 auto; background: white; border-radius: 16px; padding: 28px; box-shadow: 0 12px 40px rgba(0, 0, 0, 0.08); }
                h1 { margin-top: 0; font-size: 28px; color: #1d1d1f; }
                p { color: #666; }
                ul { list-style: none; padding: 0; margin: 0; }
                .file-item { display: flex; justify-content: space-between; gap: 16px; align-items: center; padding: 14px 0; border-bottom: 1px solid #ececf1; }
                .file-item:last-child { border-bottom: none; }
                .file-info { display: flex; flex-direction: column; gap: 4px; }
                .file-name { font-weight: 600; color: #1d1d1f; }
                .file-size { font-size: 13px; color: #666; }
                .download-btn, .bundle-btn { background: #007aff; color: white; padding: 10px 16px; border-radius: 10px; text-decoration: none; }
                .meta { margin-top: 20px; font-size: 14px; color: #666; }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>文件传输</h1>
                <p>此页面由 SkyBridge Compass Pro 生成。</p>
                <p><a class="bundle-btn" href="/link/\(urlPathEscape(link.id))/bundle">下载全部（zip）</a></p>
                <ul>\(fileList)</ul>
                <div class="meta">
                    <p>过期时间：\(escapeHTML(formatDate(link.expiresAt)))</p>
                    <p>剩余下载次数：\(link.remainingDownloads)</p>
                </div>
            </div>
        </body>
        </html>
        """
    }

    private func makeHTMLResponse(statusCode: Int, pageType: String, html: String) -> HTTPResponse {
        makeResponse(
            statusCode: statusCode,
            body: .data(Data(html.utf8)),
            contentType: "text/html; charset=utf-8",
            extraHeaders: [("X-SkyBridge-Transfer-Page", pageType)]
        )
    }

    private func makeTextResponse(statusCode: Int, body: String) -> HTTPResponse {
        makeResponse(statusCode: statusCode, body: .data(Data(body.utf8)), contentType: "text/plain; charset=utf-8")
    }

    private func redirectResponse(location: String, cookie: String?) -> HTTPResponse {
        var extraHeaders = [("Location", location)]
        if let cookie {
            extraHeaders.append(("Set-Cookie", cookie))
        }
        return makeResponse(statusCode: 303, body: .data(Data()), contentType: "text/plain; charset=utf-8", extraHeaders: extraHeaders)
    }

    private func makeResponse(
        statusCode: Int,
        body: HTTPResponse.Body,
        contentType: String,
        contentLength: Int? = nil,
        extraHeaders: [(String, String)] = [],
        onHeaderSent: (@Sendable () async -> Void)? = nil
    ) -> HTTPResponse {
        let bodyLength: Int
        switch body {
        case .data(let data):
            bodyLength = contentLength ?? data.count
        case .file(_, _, let length, _):
            bodyLength = contentLength ?? Int(length)
        }

        var headers = [(String, String)]()
        headers.append(("Content-Type", contentType))
        headers.append(("Content-Length", String(bodyLength)))
        headers.append(("Connection", "close"))
        headers.append(("Cache-Control", "no-store"))
        headers.append(("Pragma", "no-cache"))
        headers.append(("X-Content-Type-Options", "nosniff"))
        headers.append(("Referrer-Policy", "no-referrer"))
        headers.append(("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:"))
        headers.append(("X-SkyBridge-Transfer", "v1"))
        headers.append(contentsOf: extraHeaders)

        let header = buildHeader(statusCode: statusCode, headers: headers)
        return HTTPResponse(header: header, body: body, onHeaderSent: onHeaderSent)
    }

    private func buildHeader(statusCode: Int, headers: [(String, String)]) -> Data {
        var text = "HTTP/1.1 \(statusCode) \(reasonPhrase(for: statusCode))\r\n"
        for (key, value) in headers {
            text += "\(key): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }

    private func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 303: return "See Other"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }

    private func parseByteRange(_ raw: String, totalLength: Int64) -> (offset: Int64, length: Int64, contentRange: String)? {
        let value = raw.replacingOccurrences(of: "Range:", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = String(value.dropFirst("bytes=".count))
        let parts = spec.split(separator: "-", maxSplits: 1).map(String.init)
        guard let start = parts.first.flatMap({ Int64($0) }), start >= 0, start < totalLength else { return nil }
        let end = parts.count > 1 ? min((Int64(parts[1]) ?? (totalLength - 1)), totalLength - 1) : (totalLength - 1)
        guard end >= start else { return nil }
        let length = end - start + 1
        return (start, length, "bytes \(start)-\(end)/\(totalLength)")
    }

    private func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private func contentDisposition(for filename: String) -> String {
        let escaped = filename.replacingOccurrences(of: "\"", with: "\\\"")
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? escaped
        return "attachment; filename=\"\(escaped)\"; filename*=UTF-8''\(encoded)"
    }

    private func urlPathEscape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func formatFileSize(_ url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }
}
