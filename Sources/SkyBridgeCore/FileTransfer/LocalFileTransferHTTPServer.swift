import CryptoKit
import Foundation
import Network
import UniformTypeIdentifiers
import os.lock

final class LocalFileTransferHTTPServer: @unchecked Sendable {
    typealias TestingStartHook = @Sendable () async -> Void

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
        let issueAccessGrant: @Sendable (String, String) async -> AccessGrant?
        let validateAccessToken: @Sendable (String, String, String) async -> Bool
        let recordDownload: @Sendable (String) async -> Void
    }

    private struct HTTPRequest: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
        let clientAddress: String

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

    private struct UnlockAttemptState: Sendable {
        var failedAttempts: [Date] = []
        var blockedUntil: Date?
    }

    private struct UnlockChallenge: Sendable {
        let linkID: String
        let clientAddress: String
        let expiresAt: Date
    }

    private struct SecurityState: Sendable {
        var unlockAttempts: [String: UnlockAttemptState] = [:]
        var challenges: [String: UnlockChallenge] = [:]
    }

    private let callbacks: Callbacks
    private let accessCookieName = "SkyBridgeLinkAccess"
    private let queue = DispatchQueue(label: "local.file.transfer.http", qos: .userInitiated)
    private let unlockAttemptWindow: TimeInterval = 5 * 60
    private let unlockAttemptLimit = 5
    private let unlockBlockDuration: TimeInterval = 10 * 60
    private let unlockChallengeTTL: TimeInterval = 5 * 60
    private let securityState = OSAllocatedUnfairLock(initialState: SecurityState())

    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

    private static let testingDelay = OSAllocatedUnfairLock(initialState: UInt64(0))
    private static let testingStartHookStorage = OSAllocatedUnfairLock(initialState: TestingStartHook?.none)

    static var testingStartDelayNanos: UInt64 {
        get { testingDelay.withLock { $0 } }
        set { testingDelay.withLock { $0 = newValue } }
    }

    static var testingStartHook: TestingStartHook? {
        get { testingStartHookStorage.withLock { $0 } }
        set { testingStartHookStorage.withLock { $0 = newValue } }
    }

    init(callbacks: Callbacks) {
        self.callbacks = callbacks
    }

    func start(port: UInt16) async throws {
        guard listener == nil else { return }

        if let testingStartHook = Self.testingStartHook {
            await testingStartHook()
        }

        let startDelay = Self.testingStartDelayNanos
        if startDelay > 0 {
            try await Task.sleep(nanoseconds: startDelay)
        }

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
        let clientAddress = remoteAddress(for: connection.endpoint)
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
        receiveRequest(on: connection, clientAddress: clientAddress)
    }

    private func receiveRequest(on connection: NWConnection, clientAddress: String) {
        receiveRequest(on: connection, accumulated: Data(), clientAddress: clientAddress)
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data, clientAddress: String) {
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
                    let response = await self.route(data: combined, clientAddress: clientAddress)
                    await self.send(response: response, on: connection)
                }
                return
            }

            if isComplete {
                Task {
                    let response = await self.route(data: combined, clientAddress: clientAddress)
                    await self.send(response: response, on: connection)
                }
                return
            }

            self.receiveRequest(on: connection, accumulated: combined, clientAddress: clientAddress)
        }
    }

    private func route(data: Data, clientAddress: String) async -> HTTPResponse {
        guard let request = parseRequest(data, clientAddress: clientAddress) else {
            return makeTextResponse(statusCode: 400, body: "Bad Request")
        }

        if request.method == "GET", request.path == "/status" {
            guard isLoopbackAddress(request.clientAddress) else {
                return makeTextResponse(statusCode: 403, body: "Forbidden")
            }
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
            return makeUnlockPage(for: link, request: request, statusCode: 200, errorMessage: nil, autoSubmit: true)
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

        cleanupExpiredSecurityState()

        if let blockedUntil = blockedUntil(for: linkID, clientAddress: request.clientAddress) {
            return makeUnlockPage(
                for: link,
                request: request,
                statusCode: 429,
                errorMessage: "尝试次数过多，请稍后再试。",
                autoSubmit: false,
                retryAfter: blockedUntil.timeIntervalSinceNow
            )
        }

        let challenge = request.formFields["challenge"] ?? ""
        let proof = request.formFields["proof"] ?? ""
        let requiredPassword = link.password ?? ""

        guard !challenge.isEmpty, !proof.isEmpty else {
            return makeUnlockPage(
                for: link,
                request: request,
                statusCode: 400,
                errorMessage: "当前浏览器未完成安全握手，请刷新后重试。",
                autoSubmit: false
            )
        }

        guard consumeChallenge(challenge, for: linkID, clientAddress: request.clientAddress) else {
            return makeUnlockPage(
                for: link,
                request: request,
                statusCode: 400,
                errorMessage: "本次解锁会话已过期，请重新尝试。",
                autoSubmit: false
            )
        }

        let expectedProof = unlockProof(linkID: linkID, challenge: challenge, secret: requiredPassword)
        guard secureCompare(proof, expectedProof) else {
            if let blockedUntil = registerUnlockFailure(for: linkID, clientAddress: request.clientAddress) {
                return makeUnlockPage(
                    for: link,
                    request: request,
                    statusCode: 429,
                    errorMessage: "尝试次数过多，请稍后再试。",
                    autoSubmit: false,
                    retryAfter: blockedUntil.timeIntervalSinceNow
                )
            }
            return makeUnlockPage(
                for: link,
                request: request,
                statusCode: 401,
                errorMessage: "安全访问码错误，请重试。",
                autoSubmit: false
            )
        }

        clearUnlockFailures(for: linkID, clientAddress: request.clientAddress)
        guard let grant = await callbacks.issueAccessGrant(linkID, request.clientAddress) else {
            return makeTextResponse(statusCode: 500, body: "Unable to authorize")
        }

        let cookie = "\(accessCookieName)=\(grant.token); Path=/link/\(urlPathEscape(linkID)); HttpOnly; SameSite=Strict; Max-Age=\(max(1, Int(grant.expiresAt.timeIntervalSinceNow.rounded(.down))))"
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
        if let token = request.cookies[accessCookieName],
           await callbacks.validateAccessToken(linkID, token, request.clientAddress) {
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

    private func parseRequest(_ data: Data, clientAddress: String) -> HTTPRequest? {
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
            body: Data(bodyPart.utf8),
            clientAddress: clientAddress
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

    private func makeUnlockPage(
        for link: TransferLink,
        request: HTTPRequest,
        statusCode: Int,
        errorMessage: String?,
        autoSubmit: Bool,
        retryAfter: TimeInterval? = nil
    ) -> HTTPResponse {
        let challenge = beginChallenge(for: link.id, clientAddress: request.clientAddress)
        let nonce = base64URLRandom(bytes: 18)
        let html = unlockHTML(
            for: link,
            challenge: challenge,
            errorMessage: errorMessage,
            scriptNonce: nonce,
            autoSubmit: autoSubmit
        )
        var extraHeaders: [(String, String)] = []
        if let retryAfter {
            extraHeaders.append(("Retry-After", String(max(1, Int(retryAfter.rounded(.up))))))
        }
        return makeHTMLResponse(
            statusCode: statusCode,
            pageType: "unlock",
            html: html,
            contentSecurityPolicy: unlockContentSecurityPolicy(scriptNonce: nonce),
            extraHeaders: extraHeaders
        )
    }

    private func blockedUntil(for linkID: String, clientAddress: String) -> Date? {
        let now = Date()
        return securityState.withLock { state in
            cleanupExpiredSecurityState(now: now, state: &state)
            return state.unlockAttempts[unlockAttemptKey(linkID: linkID, clientAddress: clientAddress)]?.blockedUntil
        }
    }

    private func registerUnlockFailure(for linkID: String, clientAddress: String) -> Date? {
        let now = Date()
        return securityState.withLock { state in
            cleanupExpiredSecurityState(now: now, state: &state)
            let key = unlockAttemptKey(linkID: linkID, clientAddress: clientAddress)
            var attemptState = state.unlockAttempts[key] ?? UnlockAttemptState()
            attemptState.failedAttempts = attemptState.failedAttempts.filter { now.timeIntervalSince($0) <= unlockAttemptWindow }
            attemptState.failedAttempts.append(now)
            if attemptState.failedAttempts.count >= unlockAttemptLimit {
                attemptState.blockedUntil = now.addingTimeInterval(unlockBlockDuration)
                attemptState.failedAttempts.removeAll()
            }
            state.unlockAttempts[key] = attemptState
            return attemptState.blockedUntil
        }
    }

    private func clearUnlockFailures(for linkID: String, clientAddress: String) {
        _ = securityState.withLock { state in
            state.unlockAttempts.removeValue(forKey: unlockAttemptKey(linkID: linkID, clientAddress: clientAddress))
        }
    }

    private func beginChallenge(for linkID: String, clientAddress: String) -> String {
        let now = Date()
        let challenge = base64URLRandom(bytes: 18)
        securityState.withLock { state in
            cleanupExpiredSecurityState(now: now, state: &state)
            state.challenges[challenge] = UnlockChallenge(
                linkID: linkID,
                clientAddress: clientAddress,
                expiresAt: now.addingTimeInterval(unlockChallengeTTL)
            )
        }
        return challenge
    }

    private func consumeChallenge(_ challenge: String, for linkID: String, clientAddress: String) -> Bool {
        let now = Date()
        return securityState.withLock { state in
            cleanupExpiredSecurityState(now: now, state: &state)
            guard let stored = state.challenges.removeValue(forKey: challenge) else {
                return false
            }
            return stored.linkID == linkID && stored.clientAddress == clientAddress && stored.expiresAt > now
        }
    }

    private func cleanupExpiredSecurityState() {
        let now = Date()
        securityState.withLock { state in
            cleanupExpiredSecurityState(now: now, state: &state)
        }
    }

    private func cleanupExpiredSecurityState(now: Date, state: inout SecurityState) {
        state.challenges = state.challenges.filter { $0.value.expiresAt > now }
        state.unlockAttempts = state.unlockAttempts.reduce(into: [String: UnlockAttemptState]()) { result, item in
            var value = item.value
            value.failedAttempts = value.failedAttempts.filter { now.timeIntervalSince($0) <= unlockAttemptWindow }
            if let blockedUntil = value.blockedUntil, blockedUntil <= now {
                value.blockedUntil = nil
            }
            if !value.failedAttempts.isEmpty || value.blockedUntil != nil {
                result[item.key] = value
            }
        }
    }

    private func unlockAttemptKey(linkID: String, clientAddress: String) -> String {
        "\(linkID)|\(clientAddress)"
    }

    private func unlockProof(linkID: String, challenge: String, secret: String) -> String {
        let payload = "\(linkID):\(challenge):\(secret)"
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func secureCompare(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        return zip(lhsBytes, rhsBytes).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func unlockContentSecurityPolicy(scriptNonce: String) -> String {
        "default-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'; script-src 'nonce-\(scriptNonce)'; style-src 'unsafe-inline'"
    }

    private func unlockHTML(
        for link: TransferLink,
        challenge: String,
        errorMessage: String?,
        scriptNonce: String,
        autoSubmit: Bool
    ) -> String {
        let message = errorMessage.map { "<p class=\"error\">\(escapeHTML($0))</p>" } ?? ""
        let safeLinkID = escapeHTML(link.id)
        let safeChallenge = escapeHTML(challenge)
        let autoSubmitValue = autoSubmit ? "true" : "false"
        let script = """
        (() => {
            const form = document.getElementById('unlock-form');
            const passwordInput = document.getElementById('password');
            const proofInput = document.getElementById('proof');
            const challengeInput = document.getElementById('challenge');
            const status = document.getElementById('unlock-status');
            const submitButton = document.getElementById('unlock-submit');
            const linkId = form.dataset.linkId;
            const storageKey = `skybridge-transfer-unlock:${linkId}`;

            function readSecretFromHash() {
                const rawHash = window.location.hash.startsWith('#') ? window.location.hash.slice(1) : window.location.hash;
                const params = new URLSearchParams(rawHash);
                return params.get('unlock') || '';
            }

            function toHex(buffer) {
                return Array.from(new Uint8Array(buffer)).map(value => value.toString(16).padStart(2, '0')).join('');
            }

            async function createProof(secret) {
                const payload = `${linkId}:${challengeInput.value}:${secret}`;
                const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(payload));
                return toHex(digest);
            }

            async function submitSecurely(secret) {
                proofInput.value = await createProof(secret);
                passwordInput.value = '';
                submitButton.disabled = true;
                form.submit();
            }

            const fragmentSecret = readSecretFromHash();
            if (fragmentSecret) {
                sessionStorage.setItem(storageKey, fragmentSecret);
                history.replaceState({}, document.title, window.location.pathname);
            }

            const storedSecret = fragmentSecret || sessionStorage.getItem(storageKey) || '';
            if (storedSecret && !passwordInput.value) {
                passwordInput.value = storedSecret;
            }

            form.addEventListener('submit', async event => {
                event.preventDefault();
                const secret = passwordInput.value.trim();
                if (!secret) {
                    status.textContent = '请输入安全访问码';
                    return;
                }

                try {
                    status.textContent = '正在进行安全握手...';
                    await submitSecurely(secret);
                } catch {
                    submitButton.disabled = false;
                    status.textContent = '安全握手失败，请点击按钮重试。';
                }
            });

            if (form.dataset.autoSubmit === 'true' && storedSecret) {
                status.textContent = '检测到安全访问码，正在自动解锁...';
                form.requestSubmit();
            }
        })();
        """
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
                <p>此链接启用了安全访问码保护。通过二维码或完整链接打开时会自动解锁。</p>
                \(message)
                <form id="unlock-form" method="post" action="/link/\(urlPathEscape(link.id))/unlock" data-link-id="\(safeLinkID)" data-auto-submit="\(autoSubmitValue)">
                    <label for="password">访问密码</label>
                    <input id="password" name="password" type="password" autocomplete="off" spellcheck="false" />
                    <input id="challenge" name="challenge" type="hidden" value="\(safeChallenge)" />
                    <input id="proof" name="proof" type="hidden" value="" />
                    <button id="unlock-submit" type="submit">解锁链接</button>
                </form>
                <p id="unlock-status" class="meta">为保护安全，访问码不会以明文形式通过网络发送。</p>
                <div class="meta">
                    <p>过期时间：\(escapeHTML(formatDate(link.expiresAt)))</p>
                    <p>剩余下载次数：\(link.remainingDownloads)</p>
                </div>
            </div>
            <script nonce="\(escapeHTML(scriptNonce))">\(script)</script>
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

    private func makeHTMLResponse(
        statusCode: Int,
        pageType: String,
        html: String,
        contentSecurityPolicy: String? = nil,
        extraHeaders: [(String, String)] = []
    ) -> HTTPResponse {
        makeResponse(
            statusCode: statusCode,
            body: .data(Data(html.utf8)),
            contentType: "text/html; charset=utf-8",
            extraHeaders: [("X-SkyBridge-Transfer-Page", pageType)] + extraHeaders,
            contentSecurityPolicy: contentSecurityPolicy
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
        onHeaderSent: (@Sendable () async -> Void)? = nil,
        contentSecurityPolicy: String? = nil
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
        headers.append(("X-Frame-Options", "DENY"))
        headers.append(("Cross-Origin-Resource-Policy", "same-origin"))
        headers.append(("Cross-Origin-Opener-Policy", "same-origin"))
        headers.append(("Permissions-Policy", "camera=(), microphone=(), geolocation=(), usb=()"))
        headers.append(("Content-Security-Policy", contentSecurityPolicy ?? "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'; style-src 'unsafe-inline'; img-src 'self' data:"))
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
        case 429: return "Too Many Requests"
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

    private func remoteAddress(for endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            return String(describing: host)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .lowercased()
        default:
            return "unknown"
        }
    }

    private func isLoopbackAddress(_ address: String) -> Bool {
        let normalized = address.lowercased()
        return normalized == "::1"
            || normalized == "0:0:0:0:0:0:0:1"
            || normalized == "localhost"
            || normalized.hasPrefix("127.")
    }

    private func base64URLRandom(bytes: Int) -> String {
        Data((0..<bytes).map { _ in UInt8.random(in: 0...255) })
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
