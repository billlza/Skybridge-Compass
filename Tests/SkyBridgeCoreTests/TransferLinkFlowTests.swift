import CryptoKit
import Foundation
import XCTest
@testable import SkyBridgeCore

@MainActor
final class TransferLinkFlowTests: XCTestCase {
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private let manager = TransferLinkManager.shared
    private let scanner = QRCodeScannerManager.shared

    private var createdLinkIDs: [String] = []
    private var temporaryFiles: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        createdLinkIDs.removeAll()
        temporaryFiles.removeAll()
        LocalFileTransferHTTPServer.testingStartDelayNanos = 0
        scanner.cleanup()
        try await manager.start()
        try await waitForHTTPServerReady()
    }

    override func tearDown() async throws {
        for linkID in createdLinkIDs {
            await manager.deleteLink(linkID)
        }
        for fileURL in temporaryFiles {
            try? FileManager.default.removeItem(at: fileURL)
        }
        await manager.stop()
        scanner.cleanup()
        LocalFileTransferHTTPServer.testingStartDelayNanos = 0
        createdLinkIDs.removeAll()
        temporaryFiles.removeAll()
        try await super.tearDown()
    }

    func testShareURLShouldBeReachableByPeerDevicesAndProtectedByDefault() async throws {
        let fileURL = try makeTemporaryFile(named: "transfer-link-peer.txt", contents: "peer reachable")
        let link = try await manager.createTransferLink(for: [fileURL])
        createdLinkIDs.append(link.id)

        let shareURL = try XCTUnwrap(link.shareURL)
        let password = try XCTUnwrap(link.password)

        XCTAssertNotEqual(
            shareURL.host,
            "localhost",
            "跨设备分享链接不应该固定指向 localhost，否则接收端扫码会回环到自己机器。"
        )
        XCTAssertNotEqual(shareURL.port, 8888, "发布版不应继续固定使用弱默认端口。")
        XCTAssertEqual(password.split(separator: "-").count, 5)
        XCTAssertTrue(password.count >= 24)
        XCTAssertEqual(URLComponents(url: shareURL, resolvingAgainstBaseURL: false)?.fragment?.hasPrefix("unlock="), true)
    }

    func testDefaultProtectedLinkShouldUnlockWithChallengeProofAndAllowDownload() async throws {
        let fileURL = try makeTemporaryFile(named: "transfer-link-download.txt", contents: "download me")
        let link = try await manager.createTransferLink(for: [fileURL])
        createdLinkIDs.append(link.id)

        let cookieHeader = try await performSecureUnlock(for: link, secret: try XCTUnwrap(link.password))

        var downloadRequest = URLRequest(url: try loopbackURL(for: link, path: "/link/\(link.id)/download/0"))
        downloadRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (downloadData, downloadResponse) = try await URLSession.shared.data(for: downloadRequest)
        let downloadHTTPResponse = try XCTUnwrap(downloadResponse as? HTTPURLResponse)

        XCTAssertEqual(downloadHTTPResponse.statusCode, 200)
        XCTAssertEqual(String(data: downloadData, encoding: .utf8), "download me")
    }

    func testPreviewPageShouldNotConsumeDownloadQuota() async throws {
        let fileURL = try makeTemporaryFile(named: "transfer-link-preview.txt", contents: "preview only")
        let link = try await manager.createTransferLink(for: [fileURL], maxDownloads: 1, requiresPassword: false)
        createdLinkIDs.append(link.id)

        let previewURL = try loopbackURL(for: link)
        let (_, response) = try await URLSession.shared.data(from: previewURL)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        let refreshedLink = await manager.getLink(by: link.id)
        let refreshed = try XCTUnwrap(refreshedLink)
        XCTAssertEqual(refreshed.currentDownloads, 0)
        XCTAssertTrue(refreshed.isActive)
    }

    func testScannerShouldRejectHostMismatchedTransferLink() async throws {
        let fileURL = try makeTemporaryFile(named: "transfer-link-host-check.txt", contents: "host check")
        let link = try await manager.createTransferLink(for: [fileURL])
        createdLinkIDs.append(link.id)
        scanner.prepareForPresentation()

        var components = try XCTUnwrap(URLComponents(string: link.shareUrl))
        components.host = "203.0.113.10"
        let tamperedURL = try XCTUnwrap(components.url)

        let accepted = await scanner.handleTransferLink(tamperedURL.absoluteString)

        XCTAssertFalse(
            accepted,
            "扫描器不应该把指向其它主机的传输链接当作本地有效链接。"
        )
    }

    func testPreviewPageShouldEscapeFileNamesInHTML() async throws {
        let fileURL = try makeTemporaryFile(named: "evil&name<test>.txt", contents: "escape me")
        let link = try await manager.createTransferLink(for: [fileURL], requiresPassword: false)
        createdLinkIDs.append(link.id)

        let previewURL = try loopbackURL(for: link)
        let (data, response) = try await URLSession.shared.data(from: previewURL)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        let html = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(html.contains("evil&name<test>.txt"))
        XCTAssertTrue(html.contains("evil&amp;name&lt;test&gt;.txt"))
    }

    func testLegacyDownloadRouteStillWorks() async throws {
        let fileURL = try makeTemporaryFile(named: "legacy-download.txt", contents: "legacy route")
        let link = try await manager.createTransferLink(for: [fileURL], requiresPassword: false)
        createdLinkIDs.append(link.id)

        let legacyURL = try loopbackURL(for: link, path: "/download/\(link.id)/\(fileURL.lastPathComponent)")
        let (data, response) = try await URLSession.shared.data(from: legacyURL)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "legacy route")
    }

    func testPreviewPageIncludesSecurityHeadersAndMarkers() async throws {
        let fileURL = try makeTemporaryFile(named: "headers.txt", contents: "headers")
        let link = try await manager.createTransferLink(for: [fileURL], requiresPassword: false)
        createdLinkIDs.append(link.id)

        let previewURL = try loopbackURL(for: link)
        let (_, response) = try await URLSession.shared.data(from: previewURL)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "X-SkyBridge-Transfer"), "v1")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "X-SkyBridge-Transfer-Page"), "preview")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Pragma"), "no-cache")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Referrer-Policy"), "no-referrer")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "X-Frame-Options"), "DENY")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Cross-Origin-Resource-Policy"), "same-origin")
    }

    func testAccessQueryParameterShouldNotAuthorizeDownload() async throws {
        let fileURL = try makeTemporaryFile(named: "query-token.txt", contents: "query token")
        let link = try await manager.createTransferLink(for: [fileURL])
        createdLinkIDs.append(link.id)

        let cookieHeader = try await performSecureUnlock(for: link, secret: try XCTUnwrap(link.password))
        let accessToken = try extractAccessToken(from: cookieHeader)

        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let queryDownloadURL = try loopbackURL(
            for: link,
            path: "/link/\(link.id)/download/0",
            queryItems: [URLQueryItem(name: "access", value: accessToken)]
        )

        let (_, response) = try await session.data(from: queryDownloadURL)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 303)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Location"), "/link/\(link.id)")
    }

    func testUnlockShouldThrottleRepeatedInvalidProofs() async throws {
        let fileURL = try makeTemporaryFile(named: "throttle.txt", contents: "throttle")
        let link = try await manager.createTransferLink(for: [fileURL])
        createdLinkIDs.append(link.id)

        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        for attempt in 1...5 {
            let unlockPage = try await fetchUnlockPageHTML(for: link)
            let challenge = try extractInputValue(named: "challenge", from: unlockPage)
            let badProof = makeUnlockProof(linkID: link.id, challenge: challenge, secret: "WRONG-WRONG-WRONG-WRONG-WRONG")
            let unlockRequest = try makeUnlockRequest(for: link, challenge: challenge, proof: badProof)

            let (data, response) = try await session.data(for: unlockRequest)
            let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
            let html = try XCTUnwrap(String(data: data, encoding: .utf8))

            if attempt < 5 {
                XCTAssertEqual(httpResponse.statusCode, 401)
            } else {
                XCTAssertEqual(httpResponse.statusCode, 429)
                XCTAssertNotNil(httpResponse.value(forHTTPHeaderField: "Retry-After"))
                XCTAssertTrue(html.contains("尝试次数过多"))
            }
        }
    }

    func testConcurrentStartupWaitsForSingleServerReadyState() async throws {
        await manager.stop()
        LocalFileTransferHTTPServer.testingStartDelayNanos = 400_000_000
        defer { LocalFileTransferHTTPServer.testingStartDelayNanos = 0 }

        let firstStart = Task { @MainActor in
            try await self.manager.start()
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let secondStartedAt = Date()
        try await manager.start()
        let secondElapsed = Date().timeIntervalSince(secondStartedAt)
        try await firstStart.value

        XCTAssertGreaterThanOrEqual(
            secondElapsed,
            0.25,
            "当 server 还在 starting 时，后续调用必须等待 ready，而不是提前返回伪成功。"
        )
        try await waitForHTTPServerReady()
    }

    func testScannerAcceptsProtectedLinkUnlockPageMarker() async throws {
        let fileURL = try makeTemporaryFile(named: "scanner-protected.txt", contents: "scanner")
        let link = try await manager.createTransferLink(for: [fileURL])
        createdLinkIDs.append(link.id)
        scanner.prepareForPresentation()

        let accepted = await scanner.handleTransferLink(link.shareUrl)

        XCTAssertTrue(accepted)
    }

    private func performSecureUnlock(for link: TransferLink, secret: String) async throws -> String {
        let unlockPage = try await fetchUnlockPageHTML(for: link)
        let challenge = try extractInputValue(named: "challenge", from: unlockPage)
        let proof = makeUnlockProof(linkID: link.id, challenge: challenge, secret: secret)
        let unlockRequest = try makeUnlockRequest(for: link, challenge: challenge, proof: proof)

        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (_, response) = try await session.data(for: unlockRequest)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 303)

        let setCookie = try XCTUnwrap(httpResponse.value(forHTTPHeaderField: "Set-Cookie"))
        XCTAssertTrue(setCookie.contains("HttpOnly"))
        XCTAssertTrue(setCookie.contains("SameSite=Strict"))
        XCTAssertTrue(setCookie.contains("Path=/link/\(link.id)"))

        return String(setCookie.split(separator: ";", maxSplits: 1).first ?? "")
    }

    private func fetchUnlockPageHTML(for link: TransferLink) async throws -> String {
        let previewURL = try loopbackURL(for: link)
        let (pageData, pageResponse) = try await URLSession.shared.data(from: previewURL)
        let pageHTTPResponse = try XCTUnwrap(pageResponse as? HTTPURLResponse)
        XCTAssertEqual(pageHTTPResponse.statusCode, 200)
        XCTAssertEqual(pageHTTPResponse.value(forHTTPHeaderField: "X-SkyBridge-Transfer-Page"), "unlock")
        return try XCTUnwrap(String(data: pageData, encoding: .utf8))
    }

    private func makeUnlockRequest(for link: TransferLink, challenge: String, proof: String) throws -> URLRequest {
        var unlockRequest = URLRequest(url: try loopbackURL(for: link, path: "/link/\(link.id)/unlock"))
        unlockRequest.httpMethod = "POST"
        unlockRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        unlockRequest.httpBody = formBody([
            "challenge": challenge,
            "proof": proof
        ])
        return unlockRequest
    }

    private func makeTemporaryFile(named name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkyBridgeTransferLinkFlowTests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try contents.data(using: .utf8).map {
            try $0.write(to: fileURL, options: .atomic)
        }
        temporaryFiles.append(fileURL)
        return fileURL
    }

    private func loopbackURL(
        for link: TransferLink,
        path: String? = nil,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        var components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(link.shareURL), resolvingAgainstBaseURL: false))
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.fragment = nil
        if let path {
            components.path = path
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return try XCTUnwrap(components.url)
    }

    private func waitForHTTPServerReady() async throws {
        let baseURL = try XCTUnwrap(manager.loopbackBaseURL)
        let statusURL = baseURL.appendingPathComponent("status")
        var lastError: Error?

        for _ in 0..<20 {
            do {
                let (_, response) = try await URLSession.shared.data(from: statusURL)
                let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
                if httpResponse.statusCode == 200 {
                    return
                }
            } catch {
                lastError = error
            }

            try await Task.sleep(nanoseconds: 100_000_000)
        }

        if let lastError {
            throw lastError
        }

        XCTFail("Transfer link HTTP server did not become ready in time.")
    }

    private func extractInputValue(named name: String, from html: String) throws -> String {
        let marker = "name=\"\(name)\""
        let nameRange = try XCTUnwrap(html.range(of: marker))
        let valueSearchRange = nameRange.upperBound..<html.endIndex
        let valueRange = try XCTUnwrap(html.range(of: "value=\"", range: valueSearchRange))
        let start = valueRange.upperBound
        let end = try XCTUnwrap(html[start...].firstIndex(of: "\""))
        return String(html[start..<end])
    }

    private func formBody(_ fields: [String: String]) -> Data {
        let body = fields.map { key, value in
            "\(formEncode(key))=\(formEncode(value))"
        }
        .sorted()
        .joined(separator: "&")
        return Data(body.utf8)
    }

    private func formEncode(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._*"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func makeUnlockProof(linkID: String, challenge: String, secret: String) -> String {
        let payload = "\(linkID):\(challenge):\(secret)"
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func extractAccessToken(from cookieHeader: String) throws -> String {
        let cookiePair = try XCTUnwrap(cookieHeader.split(separator: ";", maxSplits: 1).first)
        let components = cookiePair.split(separator: "=", maxSplits: 1)
        XCTAssertEqual(components.first, "SkyBridgeLinkAccess")
        return String(try XCTUnwrap(components.last))
    }
}
