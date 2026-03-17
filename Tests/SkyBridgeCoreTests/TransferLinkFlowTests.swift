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
        createdLinkIDs.removeAll()
        temporaryFiles.removeAll()
        try await super.tearDown()
    }

    func testShareURLShouldBeReachableByPeerDevices() async throws {
        let fileURL = try makeTemporaryFile(named: "transfer-link-peer.txt", contents: "peer reachable")
        let link = try await manager.createTransferLink(for: [fileURL])
        createdLinkIDs.append(link.id)

        let shareURL = try XCTUnwrap(URL(string: link.shareUrl))

        XCTAssertNotEqual(
            shareURL.host,
            "localhost",
            "跨设备分享链接不应该固定指向 localhost，否则接收端扫码会回环到自己机器。"
        )
    }

    func testDownloadEndpointShouldServeSharedFile() async throws {
        let fileURL = try makeTemporaryFile(named: "transfer-link-download.txt", contents: "download me")
        let link = try await manager.createTransferLink(for: [fileURL])
        createdLinkIDs.append(link.id)

        let pageURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8888/link/\(link.id)"))
        let (pageData, pageResponse) = try await URLSession.shared.data(from: pageURL)
        let pageHTTPResponse = try XCTUnwrap(pageResponse as? HTTPURLResponse)
        XCTAssertEqual(pageHTTPResponse.statusCode, 200)

        let pageHTML = try XCTUnwrap(String(data: pageData, encoding: .utf8))
        XCTAssertTrue(pageHTML.contains("/link/\(link.id)/download/0"))

        let downloadURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8888/link/\(link.id)/download/0"))
        let (downloadData, downloadResponse) = try await URLSession.shared.data(from: downloadURL)
        let downloadHTTPResponse = try XCTUnwrap(downloadResponse as? HTTPURLResponse)

        XCTAssertEqual(
            downloadHTTPResponse.statusCode,
            200,
            "下载按钮指向的端点应该真正返回文件内容，而不是 404。"
        )
        XCTAssertEqual(String(data: downloadData, encoding: .utf8), "download me")
    }

    func testPreviewPageShouldNotConsumeDownloadQuota() async throws {
        let fileURL = try makeTemporaryFile(named: "transfer-link-preview.txt", contents: "preview only")
        let link = try await manager.createTransferLink(for: [fileURL], maxDownloads: 1)
        createdLinkIDs.append(link.id)

        let previewURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8888/link/\(link.id)"))
        let (_, response) = try await URLSession.shared.data(from: previewURL)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        let refreshedLink = await manager.getLink(by: link.id)
        let refreshed = try XCTUnwrap(refreshedLink)
        XCTAssertEqual(
            refreshed.currentDownloads,
            0,
            "查看文件列表页不应该直接消耗下载次数。"
        )
        XCTAssertTrue(
            refreshed.isActive,
            "仅打开预览页后，链接仍应保持可下载状态。"
        )
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
        let link = try await manager.createTransferLink(for: [fileURL])
        createdLinkIDs.append(link.id)

        let previewURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8888/link/\(link.id)"))
        let (data, response) = try await URLSession.shared.data(from: previewURL)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        let html = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(
            html.contains("evil&name<test>.txt"),
            "文件名进入 HTML 时应该先转义，避免破坏页面结构或注入内容。"
        )
        XCTAssertTrue(html.contains("evil&amp;name&lt;test&gt;.txt"))
    }

    func testLegacyDownloadRouteStillWorks() async throws {
        let fileURL = try makeTemporaryFile(named: "legacy-download.txt", contents: "legacy route")
        let link = try await manager.createTransferLink(for: [fileURL])
        createdLinkIDs.append(link.id)

        let legacyURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8888/download/\(link.id)/\(fileURL.lastPathComponent)"))
        let (data, response) = try await URLSession.shared.data(from: legacyURL)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "legacy route")
    }

    func testPreviewPageIncludesSecurityHeadersAndMarkers() async throws {
        let fileURL = try makeTemporaryFile(named: "headers.txt", contents: "headers")
        let link = try await manager.createTransferLink(for: [fileURL])
        createdLinkIDs.append(link.id)

        let previewURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8888/link/\(link.id)"))
        let (_, response) = try await URLSession.shared.data(from: previewURL)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "X-SkyBridge-Transfer"), "v1")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "X-SkyBridge-Transfer-Page"), "preview")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Pragma"), "no-cache")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Referrer-Policy"), "no-referrer")
        XCTAssertEqual(
            httpResponse.value(forHTTPHeaderField: "Content-Security-Policy"),
            "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:"
        )
    }

    func testProtectedLinkUnlockSetsCookieAndAllowsDownload() async throws {
        let fileURL = try makeTemporaryFile(named: "protected.txt", contents: "locked")
        let link = try await manager.createTransferLink(for: [fileURL], requiresPassword: true)
        createdLinkIDs.append(link.id)
        let password = try XCTUnwrap(link.password)

        let previewURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8888/link/\(link.id)"))
        let (_, initialResponse) = try await URLSession.shared.data(from: previewURL)
        let initialHTTPResponse = try XCTUnwrap(initialResponse as? HTTPURLResponse)
        XCTAssertEqual(initialHTTPResponse.statusCode, 200)
        XCTAssertEqual(initialHTTPResponse.value(forHTTPHeaderField: "X-SkyBridge-Transfer-Page"), "unlock")

        var unlockRequest = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:8888/link/\(link.id)/unlock")))
        unlockRequest.httpMethod = "POST"
        unlockRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        unlockRequest.httpBody = "password=\(password)".data(using: .utf8)

        let noRedirectSession = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { noRedirectSession.invalidateAndCancel() }

        let (_, unlockResponse) = try await noRedirectSession.data(for: unlockRequest)
        let unlockHTTPResponse = try XCTUnwrap(unlockResponse as? HTTPURLResponse)
        XCTAssertEqual(unlockHTTPResponse.statusCode, 303)

        let setCookie = try XCTUnwrap(unlockHTTPResponse.value(forHTTPHeaderField: "Set-Cookie"))
        XCTAssertTrue(setCookie.contains("HttpOnly"))
        XCTAssertTrue(setCookie.contains("SameSite=Lax"))
        XCTAssertTrue(setCookie.contains("Path=/link/\(link.id)"))

        let cookieHeader = String(setCookie.split(separator: ";", maxSplits: 1).first ?? "")
        var downloadRequest = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:8888/link/\(link.id)/download/0")))
        downloadRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (downloadData, downloadResponse) = try await URLSession.shared.data(for: downloadRequest)
        let downloadHTTPResponse = try XCTUnwrap(downloadResponse as? HTTPURLResponse)

        XCTAssertEqual(downloadHTTPResponse.statusCode, 200)
        XCTAssertEqual(String(data: downloadData, encoding: .utf8), "locked")
    }

    func testScannerAcceptsProtectedLinkUnlockPageMarker() async throws {
        let fileURL = try makeTemporaryFile(named: "scanner-protected.txt", contents: "scanner")
        let link = try await manager.createTransferLink(for: [fileURL], requiresPassword: true)
        createdLinkIDs.append(link.id)
        scanner.prepareForPresentation()

        let accepted = await scanner.handleTransferLink(link.shareUrl)

        XCTAssertTrue(accepted)
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

    private func waitForHTTPServerReady() async throws {
        let statusURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8888/status"))
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
}
