import XCTest

@testable import SkyBridgeCore

private enum P2PStartupLifecycleTestError: Error {
  case expectedFailure
}

private actor P2PStartupLifecycleTestGate {
  private var entryCount = 0
  private var isReleased = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func enterAndWait() async {
    entryCount += 1
    guard !isReleased else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func waitUntilEntered(_ expectedCount: Int) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while entryCount < expectedCount, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return entryCount >= expectedCount
  }

  func release() {
    isReleased = true
    let pending = waiters
    waiters.removeAll(keepingCapacity: false)
    for waiter in pending {
      waiter.resume()
    }
  }
}

private actor P2PStartupLifecycleEntryProbe {
  private var hasEntered = false

  func markEntered() {
    hasEntered = true
  }

  func waitUntilEntered() async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while !hasEntered, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return hasEntered
  }
}

@MainActor
private final class P2PStartupLifecycleTestProbe {
  var operationCount = 0
  var commitCount = 0
  var rollbackCount = 0
  var willStopCount = 0
  var stopCount = 0
}

@MainActor
final class P2PStartupLifecycleTests: XCTestCase {
  func testConcurrentStartsAwaitOneOperationAndOneCommit() async throws {
    let lifecycle = P2PStartupLifecycle()
    let gate = P2PStartupLifecycleTestGate()
    let probe = P2PStartupLifecycleTestProbe()

    let first = Task { @MainActor in
      try await lifecycle.ensureStarted(
        operation: {
          probe.operationCount += 1
          await gate.enterAndWait()
        },
        commit: {
          probe.commitCount += 1
        },
        rollback: {
          probe.rollbackCount += 1
        }
      )
    }
    let firstEntered = await gate.waitUntilEntered(1)
    XCTAssertTrue(firstEntered)

    let second = Task { @MainActor in
      try await lifecycle.ensureStarted(
        operation: {
          probe.operationCount += 1
        },
        commit: {
          probe.commitCount += 1
        },
        rollback: {
          probe.rollbackCount += 1
        }
      )
    }
    await Task.yield()

    XCTAssertEqual(probe.operationCount, 1)
    XCTAssertEqual(probe.commitCount, 0)
    XCTAssertEqual(lifecycle.state, .starting)

    await gate.release()
    try await first.value
    try await second.value

    XCTAssertEqual(probe.operationCount, 1)
    XCTAssertEqual(probe.commitCount, 1)
    XCTAssertEqual(probe.rollbackCount, 0)
    XCTAssertEqual(lifecycle.state, .running)
  }

  func testStartupFailureRollsBackAndReturnsToIdle() async {
    let lifecycle = P2PStartupLifecycle()
    let probe = P2PStartupLifecycleTestProbe()

    do {
      try await lifecycle.ensureStarted(
        operation: {
          probe.operationCount += 1
          throw P2PStartupLifecycleTestError.expectedFailure
        },
        commit: {
          probe.commitCount += 1
        },
        rollback: {
          probe.rollbackCount += 1
        }
      )
      XCTFail("Expected startup failure")
    } catch P2PStartupLifecycleTestError.expectedFailure {
      // Expected exact failure propagation.
    } catch {
      XCTFail("Unexpected startup error: \(error)")
    }

    XCTAssertEqual(probe.operationCount, 1)
    XCTAssertEqual(probe.commitCount, 0)
    XCTAssertEqual(probe.rollbackCount, 1)
    XCTAssertEqual(lifecycle.state, .idle)
  }

  func testStopDuringStartCancelsRollbackAndPreventsLateCommit() async {
    let lifecycle = P2PStartupLifecycle()
    let entryProbe = P2PStartupLifecycleEntryProbe()
    let probe = P2PStartupLifecycleTestProbe()

    let startup = Task { @MainActor in
      try await lifecycle.ensureStarted(
        operation: {
          probe.operationCount += 1
          await entryProbe.markEntered()
          try await Task.sleep(for: .seconds(60))
        },
        commit: {
          probe.commitCount += 1
        },
        rollback: {
          probe.rollbackCount += 1
        }
      )
    }
    let startupEntered = await entryProbe.waitUntilEntered()
    XCTAssertTrue(startupEntered)

    let stopError = await lifecycle.stop(
      willStop: {
        probe.willStopCount += 1
      },
      operation: {
        probe.stopCount += 1
      }
    )

    XCTAssertNil(stopError)
    do {
      try await startup.value
      XCTFail("A superseded startup must not return success")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Unexpected cancellation result: \(error)")
    }
    XCTAssertEqual(probe.commitCount, 0)
    XCTAssertEqual(probe.rollbackCount, 1)
    XCTAssertEqual(probe.willStopCount, 1)
    XCTAssertEqual(probe.stopCount, 1)
    XCTAssertEqual(lifecycle.state, .idle)
  }

  func testFreshStartSucceedsAfterPreviousFailure() async throws {
    let lifecycle = P2PStartupLifecycle()
    let probe = P2PStartupLifecycleTestProbe()

    do {
      try await lifecycle.ensureStarted(
        operation: {
          probe.operationCount += 1
          throw P2PStartupLifecycleTestError.expectedFailure
        },
        commit: {
          probe.commitCount += 1
        },
        rollback: {
          probe.rollbackCount += 1
        }
      )
      XCTFail("Expected first startup to fail")
    } catch P2PStartupLifecycleTestError.expectedFailure {
      // Expected.
    }

    try await lifecycle.ensureStarted(
      operation: {
        probe.operationCount += 1
      },
      commit: {
        probe.commitCount += 1
      },
      rollback: {
        probe.rollbackCount += 1
      }
    )

    XCTAssertEqual(probe.operationCount, 2)
    XCTAssertEqual(probe.commitCount, 1)
    XCTAssertEqual(probe.rollbackCount, 1)
    XCTAssertEqual(lifecycle.state, .running)
  }

  func testFreshStartSucceedsAfterCompletedStop() async throws {
    let lifecycle = P2PStartupLifecycle()
    let probe = P2PStartupLifecycleTestProbe()

    try await lifecycle.ensureStarted(
      operation: {
        probe.operationCount += 1
      },
      commit: {
        probe.commitCount += 1
      },
      rollback: {
        probe.rollbackCount += 1
      }
    )
    let stopError = await lifecycle.stop(
      willStop: {
        probe.willStopCount += 1
      },
      operation: {
        probe.stopCount += 1
      }
    )
    XCTAssertNil(stopError)

    try await lifecycle.ensureStarted(
      operation: {
        probe.operationCount += 1
      },
      commit: {
        probe.commitCount += 1
      },
      rollback: {
        probe.rollbackCount += 1
      }
    )

    XCTAssertEqual(probe.operationCount, 2)
    XCTAssertEqual(probe.commitCount, 2)
    XCTAssertEqual(probe.rollbackCount, 0)
    XCTAssertEqual(probe.willStopCount, 1)
    XCTAssertEqual(probe.stopCount, 1)
    XCTAssertEqual(lifecycle.state, .running)
  }
}
