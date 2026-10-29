import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PSessionHandoffOperationTests: XCTestCase {
    func testCompletionBeforeInstallationIsDeliveredExactlyOnce() async throws {
        let operation = P2PSessionHandoffOperation()
        operation.succeed()
        operation.fail(P2PSessionHandoffError.invalidated)

        try await withCheckedThrowingContinuation { continuation in
            operation.install(continuation)
        }
    }

    func testDuplicateInstallationFailsNewContinuationAndPreservesOwner() async throws {
        let operation = P2PSessionHandoffOperation()
        let installed = expectation(description: "first continuation installed")
        let first = Task {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                installed.fulfill()
            }
        }
        await fulfillment(of: [installed], timeout: 1)

        do {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
            }
            XCTFail("A second continuation must not replace the first owner")
        } catch let error as P2PSessionHandoffError {
            XCTAssertEqual(error, .duplicateContinuationInstallation)
        } catch {
            XCTFail("Unexpected duplicate-installation error: \(error)")
        }

        operation.succeed()
        try await first.value
    }

    func testInstalledContinuationReceivesInvalidation() async throws {
        let operation = P2PSessionHandoffOperation()
        let installed = expectation(description: "continuation installed")
        let waiter = Task {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                installed.fulfill()
            }
        }
        await fulfillment(of: [installed], timeout: 1)
        operation.fail(P2PSessionHandoffError.invalidated)

        do {
            try await waiter.value
            XCTFail("Invalidation must fail the installed continuation")
        } catch let error as P2PSessionHandoffError {
            XCTAssertEqual(error, .invalidated)
        } catch {
            XCTFail("Unexpected invalidation error: \(error)")
        }
    }
}
