import Foundation
import XCTest

/// 会话级容器的拆除清单目前是手工维护的，而且维护在**两个地方**：
/// `cleanupWebRTCSession(sessionID:)` 按会话删除，`disconnect()` 整体清空。
/// 新增一个 `...BySessionId` 字典时只改其中一处，另一处就会静默泄漏该会话的状态，
/// 编译器不会报，运行时也不会报。`webrtcBoundSessionConsumerGatesBySessionId` 就这么漏过一次。
///
/// 这个测试把"两份清单必须等价"变成一条会失败的断言。等每会话状态收敛成单一容器之后，
/// 本测试连同它守护的重复清单一起删除。
final class CrossNetworkSessionTeardownParityTests: XCTestCase {
    private func managerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
            ),
            encoding: .utf8
        )
    }

    /// 取出 `func <name>(` 起始的函数体（按大括号配平）。
    private func functionBody(named name: String, in source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("func \(name)(") }) else {
            throw XCTSkip("找不到 \(name)，该测试的锚点已失效，需要重新指向")
        }
        var depth = 0
        var started = false
        for index in start..<lines.count {
            for character in lines[index] {
                if character == "{" {
                    depth += 1
                    started = true
                } else if character == "}" {
                    depth -= 1
                }
            }
            if started && depth == 0 {
                return lines[start...index].joined(separator: "\n")
            }
        }
        XCTFail("\(name) 的大括号没有配平")
        return ""
    }

    private func matches(_ pattern: String, in text: String, group: Int = 1) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var found = Set<String>()
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range(at: group), in: text) else { continue }
            found.insert(String(text[r]))
        }
        return found
    }

    func testDisconnectClearsEveryContainerThatPerSessionCleanupClears() throws {
        let source = try managerSource()
        let cleanup = try functionBody(named: "cleanupWebRTCSession", in: source)
        let disconnect = try functionBody(named: "disconnect", in: source)

        let identifier = "([A-Za-z_][A-Za-z0-9_]*)"
        var perSession = matches("\\b\(identifier)\\.removeValue\\(forKey: sessionID\\)", in: cleanup)
        perSession.formUnion(matches("\\b\(identifier)\\.remove\\(sessionID\\)", in: cleanup))
        XCTAssertGreaterThan(
            perSession.count, 20,
            "解析失败而不是真的只有这么少容器：锚点或写法变了，先修测试再谈通过"
        )

        let clearedOnDisconnect = matches("\\b\(identifier)\\.removeAll\\(\\)", in: disconnect)
        let leaked = perSession.subtracting(clearedOnDisconnect).sorted()

        XCTAssertEqual(
            leaked, [],
            """
            这些会话级容器在 cleanupWebRTCSession 里按会话清理，但 disconnect() 没有清空，\
            完整断开后它们的内容会残留：\(leaked.joined(separator: ", "))
            """
        )
    }

    /// 反向守卫：`disconnect()` 不调用 `cleanupWebRTCSession`，两份清单的等价性没有任何结构性保证。
    /// 一旦有人把 disconnect 改成复用 cleanup（那才是根本解法），本测试与上面那条应当一并删除。
    func testTeardownDuplicationIsStillTheKnownShape() throws {
        let source = try managerSource()
        let disconnect = try functionBody(named: "disconnect", in: source)
        XCTAssertFalse(
            disconnect.contains("cleanupWebRTCSession("),
            "disconnect() 现在复用了按会话拆除路径，重复清单已消失，请删除本文件的两条测试"
        )
    }
}
