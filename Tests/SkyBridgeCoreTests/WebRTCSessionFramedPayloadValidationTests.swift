import Testing
@testable import SkyBridgeCore

@Suite("WebRTCSession Framed Payload Validation Tests")
struct WebRTCSessionFramedPayloadValidationTests {
    @Test("非法分块大小返回错误而不是触发 precondition 崩溃")
    func invalidChunkSizeThrowsTypedError() throws {
        do {
            _ = try WebRTCSession.validateFramedPayloadParameters(
                payloadByteCount: 128,
                maxChunkBytes: 0
            )
            Issue.record("应当抛出 invalidChunkSize 错误")
        } catch let error as WebRTCSession.WebRTCError {
            switch error {
            case .invalidChunkSize(let value):
                #expect(value == 0)
            default:
                Issue.record("错误类型不正确: \(error)")
            }
        } catch {
            Issue.record("未预期的错误类型: \(error)")
        }
    }

    @Test("超出 4 GiB 的分帧负载被拒绝而不是在长度转换时崩溃")
    func oversizedPayloadThrowsTypedError() throws {
        do {
            _ = try WebRTCSession.validateFramedPayloadParameters(
                payloadByteCount: Int(UInt32.max) + 1,
                maxChunkBytes: 8 * 1024
            )
            Issue.record("应当抛出 framedPayloadTooLarge 错误")
        } catch let error as WebRTCSession.WebRTCError {
            switch error {
            case .framedPayloadTooLarge(let value):
                #expect(value == Int(UInt32.max) + 1)
            default:
                Issue.record("错误类型不正确: \(error)")
            }
        } catch {
            Issue.record("未预期的错误类型: \(error)")
        }
    }
}
