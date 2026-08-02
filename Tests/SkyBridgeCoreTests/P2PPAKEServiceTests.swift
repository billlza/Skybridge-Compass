import Foundation
import XCTest

final class P2PPAKEServiceTests: XCTestCase {
    func testNonStandardPAKEImplementationIsCompileTimeUnavailable() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/P2P/PAKEService.swift"
        )

        XCTAssertTrue(source.contains("@available("))
        XCTAssertTrue(source.contains("unavailable,"))
        XCTAssertTrue(source.contains("public actor PAKEService {}"))
        XCTAssertTrue(source.contains("RFC 9382 SPAKE2+"))
    }

    func testRemovedPAKESurfaceContainsNoCryptographicSubstituteOrCrashPath() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/P2P/PAKEService.swift"
        )

        for forbidden in [
            "computeBlindedPoint",
            "derivePasswordScalar",
            "CCKeyDerivationPBKDF",
            "SecRandomCopyBytes",
            "fatalError(",
            "precondition(",
            "PAKEMessageA",
            "PAKEMessageB"
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    func testProductionSourcesDoNotInstantiateDisabledPAKEService() throws {
        let root = repositoryRoot
        let sourcesRoot = root.appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourcesRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )

        var violations: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard !url.path.hasSuffix("/P2P/PAKEService.swift") else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains("PAKEService(") {
                violations.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
            }
        }
        XCTAssertEqual(violations, [])
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
