import CryptoKit
import Foundation
import XCTest
@testable import SkyBridgeCore

@MainActor
final class TransferLinkSecurityTests: XCTestCase {
    private let manager = TransferLinkManager.shared
    private var createdLinkIDs: [String] = []
    private var temporaryFiles: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        createdLinkIDs.removeAll()
        temporaryFiles.removeAll()
        LocalFileTransferHTTPServer.testingStartDelayNanos = 0
        await manager.cleanup()
    }

    override func tearDown() async throws {
        for linkID in createdLinkIDs {
            await manager.deleteLink(linkID)
        }
        for fileURL in temporaryFiles {
            try? FileManager.default.removeItem(at: fileURL)
        }
        await manager.cleanup()
        LocalFileTransferHTTPServer.testingStartDelayNanos = 0
        createdLinkIDs.removeAll()
        temporaryFiles.removeAll()
        try await super.tearDown()
    }

    func testCreateTransferLinkDefaultsToPasswordProtection() async throws {
        let fileURL = try makeTemporaryFile(named: "default-protection.txt", contents: "secret")
        let link = try await manager.createTransferLink(for: [fileURL])
        createdLinkIDs.append(link.id)

        XCTAssertNotNil(link.password)
        XCTAssertTrue(link.password?.count ?? 0 >= 20)
        XCTAssertTrue(link.shareUrl.contains("#unlock="))

        let shareURL = try XCTUnwrap(URL(string: link.shareUrl))
        XCTAssertEqual(shareURL.scheme, "http")
        XCTAssertNotEqual(shareURL.port, 8888)
        XCTAssertEqual(manager.currentServerPort, UInt16(shareURL.port ?? 0))
    }

    func testUnlockFlowUsesChallengeProofAndReturnsCookieBoundSession() async throws {
        let fileURL = try makeTemporaryFile(named: "protected-download.txt", contents: "classified")
        let link = try await manager.createTransferLink(for: [fileURL])
        createdLinkIDs.append(link.id)
        let password = try XCTUnwrap(link.password)
        let baseURL = try XCTUnwrap(manager.loopbackBaseURL)

        let previewURL = baseURL.appending(path: "link").appending(path: link.id)
        let (previewData, previewResponse) = try await URLSession.shared.data(from: previewURL)
        let previewHTTP = try XCTUnwrap(previewResponse as? HTTPURLResponse)
        XCTAssertEqual(previewHTTP.statusCode, 200)

        let previewHTML = try XCTUnwrap(String(data: previewData, encoding: .utf8))
        let challenge = try XCTUnwrap(extractInputValue(named: "challenge", from: previewHTML))
        XCTAssertTrue(previewHTML.contains("解锁链接"))

        var unlockRequest = URLRequest(url: baseURL.appending(path: "link").appending(path: link.id).appending(path: "unlock"))
        unlockRequest.httpMethod = "POST"
        unlockRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let proof = unlockProof(linkID: link.id, challenge: challenge, password: password)
        unlockRequest.httpBody = "challenge=\(challenge)&proof=\(proof)&password=".data(using: .utf8)

        let noRedirect = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { noRedirect.invalidateAndCancel() }
        let (_, unlockResponse) = try await noRedirect.data(for: unlockRequest)
        let unlockHTTP = try XCTUnwrap(unlockResponse as? HTTPURLResponse)
        XCTAssertEqual(unlockHTTP.statusCode, 303)
        let setCookie = try XCTUnwrap(unlockHTTP.value(forHTTPHeaderField: "Set-Cookie"))
        XCTAssertTrue(setCookie.contains("SameSite=Strict"))

        let cookieValue = String(setCookie.split(separator: ";", maxSplits: 1).first ?? "")
        var downloadRequest = URLRequest(url: baseURL.appending(path: "link").appending(path: link.id).appending(path: "download").appending(path: "0"))
        downloadRequest.setValue(cookieValue, forHTTPHeaderField: "Cookie")

        let (downloadData, downloadResponse) = try await URLSession.shared.data(for: downloadRequest)
        let downloadHTTP = try XCTUnwrap(downloadResponse as? HTTPURLResponse)
        XCTAssertEqual(downloadHTTP.statusCode, 200)
        XCTAssertEqual(String(data: downloadData, encoding: .utf8), "classified")
    }

    func testConcurrentStartWaitsForSharedStartupTask() async throws {
        LocalFileTransferHTTPServer.testingStartDelayNanos = 150_000_000
        defer { LocalFileTransferHTTPServer.testingStartDelayNanos = 0 }
        let manager = self.manager

        async let first: Void = manager.start()
        async let second: Void = manager.start()
        _ = try await (first, second)

        XCTAssertTrue(manager.isServerRunning)
        XCTAssertNotNil(manager.currentServerPort)
    }

    func testUnlockRateLimitBlocksRepeatedBadProofs() async throws {
        let fileURL = try makeTemporaryFile(named: "rate-limit.txt", contents: "blocked")
        let link = try await manager.createTransferLink(for: [fileURL])
        createdLinkIDs.append(link.id)
        let baseURL = try XCTUnwrap(manager.loopbackBaseURL)

        let previewURL = baseURL.appending(path: "link").appending(path: link.id)
        let (previewData, _) = try await URLSession.shared.data(from: previewURL)
        let previewHTML = try XCTUnwrap(String(data: previewData, encoding: .utf8))
        let initialChallenge = try XCTUnwrap(extractInputValue(named: "challenge", from: previewHTML))

        let noRedirect = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { noRedirect.invalidateAndCancel() }

        for attempt in 0..<4 {
            var unlockRequest = URLRequest(url: baseURL.appending(path: "link").appending(path: link.id).appending(path: "unlock"))
            unlockRequest.httpMethod = "POST"
            unlockRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let challenge: String
            if attempt == 0 {
                challenge = initialChallenge
            } else {
                let refreshedChallenge = try await freshChallenge(baseURL: baseURL, linkID: link.id)
                challenge = try XCTUnwrap(refreshedChallenge)
            }
            unlockRequest.httpBody = "challenge=\(challenge)&proof=bad-proof-\(attempt)&password=".data(using: .utf8)
            let (_, response) = try await noRedirect.data(for: unlockRequest)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 401)
        }

        var blockedRequest = URLRequest(url: baseURL.appending(path: "link").appending(path: link.id).appending(path: "unlock"))
        blockedRequest.httpMethod = "POST"
        blockedRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let refreshedBlockedChallenge = try await freshChallenge(baseURL: baseURL, linkID: link.id)
        let blockedChallenge = try XCTUnwrap(refreshedBlockedChallenge)
        blockedRequest.httpBody = "challenge=\(blockedChallenge)&proof=still-bad&password=".data(using: .utf8)

        let (_, blockedResponse) = try await noRedirect.data(for: blockedRequest)
        let blockedHTTP = try XCTUnwrap(blockedResponse as? HTTPURLResponse)
        XCTAssertEqual(blockedHTTP.statusCode, 429)
        XCTAssertNotNil(blockedHTTP.value(forHTTPHeaderField: "Retry-After"))
    }

    private func makeTemporaryFile(named name: String, contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-transfer-link-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let fileURL = url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: fileURL, options: .atomic)
        temporaryFiles.append(fileURL)
        return fileURL
    }

    private func extractInputValue(named name: String, from html: String) -> String? {
        let marker = "name=\"\(name)\""
        guard let nameRange = html.range(of: marker) else { return nil }
        let valueSearchRange = nameRange.upperBound..<html.endIndex
        guard let valueRange = html.range(of: "value=\"", range: valueSearchRange) else { return nil }
        let start = valueRange.upperBound
        guard let end = html[start...].firstIndex(of: "\"") else { return nil }
        return String(html[start..<end])
    }

    private func unlockProof(linkID: String, challenge: String, password: String) -> String {
        let payload = "\(linkID):\(challenge):\(password)"
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func freshChallenge(baseURL: URL, linkID: String) async throws -> String? {
        let previewURL = baseURL.appending(path: "link").appending(path: linkID)
        let (data, _) = try await URLSession.shared.data(from: previewURL)
        guard let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        return extractInputValue(named: "challenge", from: html)
    }
}

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
