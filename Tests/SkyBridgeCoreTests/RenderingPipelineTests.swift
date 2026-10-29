import XCTest
@testable import SkyBridgeCore

// MARK: - Ring Buffer Tests

final class DecodedFrameRingBufferTests: XCTestCase {

    // MARK: - 基本 SPSC 语义

    func testNewBufferReturnsNilOnLatestFrame() {
        let buffer = DecodedFrameRingBuffer(capacity: 3)
        XCTAssertNil(buffer.latestFrame(), "Empty buffer should return nil")
        XCTAssertFalse(buffer.hasNewFrame)
        XCTAssertEqual(buffer.skippedFrameCount, 0)
    }

    func testPushAndPullSingleFrame() {
        let buffer = DecodedFrameRingBuffer(capacity: 3)
        let frame = makeFrame(recvNs: 1000, decodeNs: 2000, bytes: 64)
        buffer.push(frame)

        XCTAssertTrue(buffer.hasNewFrame)
        let pulled = buffer.latestFrame()
        XCTAssertNotNil(pulled)
        XCTAssertEqual(pulled?.recvTimestampNs, 1000)
        XCTAssertEqual(pulled?.recvBytes, 64)
    }

    func testConsecutivePullsReturnNilWithoutNewPush() {
        let buffer = DecodedFrameRingBuffer(capacity: 3)
        buffer.push(makeFrame(recvNs: 1, decodeNs: 2, bytes: 32))

        _ = buffer.latestFrame() // consume
        XCTAssertNil(buffer.latestFrame(), "Second pull without push should return nil")
        XCTAssertFalse(buffer.hasNewFrame)
    }

    func testLatestFrameSemanticsSkipsIntermediateFrames() {
        let buffer = DecodedFrameRingBuffer(capacity: 3)
        buffer.push(makeFrame(recvNs: 100, decodeNs: 200, bytes: 10))
        buffer.push(makeFrame(recvNs: 300, decodeNs: 400, bytes: 20))
        buffer.push(makeFrame(recvNs: 500, decodeNs: 600, bytes: 30))

        let pulled = buffer.latestFrame()
        XCTAssertNotNil(pulled)
        XCTAssertEqual(pulled?.recvTimestampNs, 500, "Should return the latest frame, not oldest")
        XCTAssertEqual(pulled?.recvBytes, 30)
        XCTAssertEqual(buffer.skippedFrameCount, 2, "Two intermediate frames should be counted as skipped")
    }

    func testOverflowOverwritesOldest() {
        let buffer = DecodedFrameRingBuffer(capacity: 2)
        buffer.push(makeFrame(recvNs: 1, decodeNs: 2, bytes: 1))
        buffer.push(makeFrame(recvNs: 3, decodeNs: 4, bytes: 2))
        buffer.push(makeFrame(recvNs: 5, decodeNs: 6, bytes: 3)) // overwrites slot 0

        let pulled = buffer.latestFrame()
        XCTAssertNotNil(pulled)
        XCTAssertEqual(pulled?.recvTimestampNs, 5, "After overflow, latest frame should be the most recent push")
    }

    func testResetClearsAllState() {
        let buffer = DecodedFrameRingBuffer(capacity: 3)
        buffer.push(makeFrame(recvNs: 1, decodeNs: 2, bytes: 10))
        _ = buffer.latestFrame()

        buffer.push(makeFrame(recvNs: 3, decodeNs: 4, bytes: 20))
        buffer.push(makeFrame(recvNs: 5, decodeNs: 6, bytes: 30))

        buffer.reset()

        XCTAssertNil(buffer.latestFrame())
        XCTAssertFalse(buffer.hasNewFrame)
        XCTAssertEqual(buffer.skippedFrameCount, 0)
    }

    func testMinimumCapacityIsTwo() {
        let buffer = DecodedFrameRingBuffer(capacity: 0)
        buffer.push(makeFrame(recvNs: 1, decodeNs: 2, bytes: 1))
        buffer.push(makeFrame(recvNs: 3, decodeNs: 4, bytes: 2))
        let pulled = buffer.latestFrame()
        XCTAssertNotNil(pulled, "Buffer with capacity 0 should clamp to 2 and still work")
    }

    // MARK: - 高频吞吐

    func testHighFrequencyPushPull() {
        let buffer = DecodedFrameRingBuffer(capacity: 3)
        let iterations = 10_000
        for i in 0..<iterations {
            buffer.push(makeFrame(recvNs: UInt64(i), decodeNs: UInt64(i + 1), bytes: i % 256))
        }
        let pulled = buffer.latestFrame()
        XCTAssertNotNil(pulled)
        XCTAssertEqual(pulled?.recvTimestampNs, UInt64(iterations - 1))
    }

    // MARK: - Helper

    private func makeFrame(recvNs: UInt64, decodeNs: UInt64, bytes: Int) -> DecodedFrameRingBuffer.BufferedFrame {
        // 创建最小 CVPixelBuffer 用于测试
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        return DecodedFrameRingBuffer.BufferedFrame(
            pixelBuffer: pixelBuffer!,
            recvTimestampNs: recvNs,
            decodeTimestampNs: decodeNs,
            recvBytes: bytes
        )
    }
}

// MARK: - Rendering Mode Controller Tests

final class RenderingModeControllerTests: XCTestCase {

    // MARK: - 初始状态

    func testInitialModeIsStable() {
        let controller = RenderingModeController()
        XCTAssertEqual(controller.currentMode, .stable)
        XCTAssertEqual(controller.userRequestedMode, .stable)
        XCTAssertFalse(controller.isProbationActive)
    }

    // MARK: - 降级方向单向性

    func testUpgradeToFluidEntersProbation() {
        let controller = RenderingModeController()
        let result = controller.requestMode(.fluid)
        XCTAssertEqual(result, .fluid)
        XCTAssertEqual(controller.currentMode, .fluid)
        XCTAssertTrue(controller.isProbationActive)
    }

    func testUpgradeToReferenceEntersProbation() {
        let controller = RenderingModeController()
        let result = controller.requestMode(.reference)
        XCTAssertEqual(result, .reference)
        XCTAssertTrue(controller.isProbationActive)
    }

    func testDowngradeFromFluidToStableIsImmediate() {
        let controller = RenderingModeController()
        controller.requestMode(.fluid)
        let result = controller.requestMode(.stable)
        XCTAssertEqual(result, .stable)
        XCTAssertEqual(controller.currentMode, .stable)
        XCTAssertFalse(controller.isProbationActive)
    }

    func testUpgradeAfterDowngradeIsDeniedWithinSameStream() {
        let controller = RenderingModeController()
        controller.requestMode(.fluid)
        controller.requestMode(.stable) // downgrade
        let result = controller.requestMode(.fluid) // try to upgrade again
        XCTAssertEqual(result, .stable, "Should not allow upgrade after downgrade in same stream")
        XCTAssertEqual(controller.currentMode, .stable)
    }

    func testResetForNewStreamAllowsUpgradeAgain() {
        let controller = RenderingModeController()
        controller.requestMode(.fluid)
        controller.requestMode(.stable)
        controller.resetForNewStream()
        let result = controller.requestMode(.fluid)
        XCTAssertEqual(result, .fluid, "After new stream reset, upgrade should be allowed")
    }

    // MARK: - Probation 失败

    func testProbationFailureTriggersDegradation() {
        let controller = RenderingModeController(probationMaxFailures: 2)
        controller.requestMode(.fluid)
        XCTAssertTrue(controller.isProbationActive)

        controller.reportProbationFrameFailure()
        controller.reportProbationFrameFailure()
        controller.reportProbationFrameFailure() // exceeds max
        XCTAssertEqual(controller.currentMode, .stable, "Should degrade after exceeding max failures")
        XCTAssertFalse(controller.isProbationActive)
    }

    // MARK: - 自动降级

    func testAutoDegradationFromReference() {
        let controller = RenderingModeController()
        controller.requestMode(.reference)
        controller.triggerAutoDegradation(reason: "thermal_serious")
        XCTAssertEqual(controller.currentMode, .fluid, "Reference should degrade to Fluid")
    }

    func testAutoDegradationFromFluid() {
        let controller = RenderingModeController()
        controller.requestMode(.fluid)
        controller.triggerAutoDegradation(reason: "freeze_detected")
        XCTAssertEqual(controller.currentMode, .stable, "Fluid should degrade to Stable")
    }

    func testAutoDegradationFromStableIsNoop() {
        let controller = RenderingModeController()
        controller.triggerAutoDegradation(reason: "whatever")
        XCTAssertEqual(controller.currentMode, .stable, "Stable cannot degrade further")
    }

    // MARK: - 模式变化回调

    func testModeChangedCallbackFires() {
        let controller = RenderingModeController()
        var callbackFired = false
        var fromMode: RenderingMode?
        var toMode: RenderingMode?
        var changeReason: String?

        controller.onModeChanged = { from, to, reason in
            callbackFired = true
            fromMode = from
            toMode = to
            changeReason = reason
        }

        controller.requestMode(.fluid)

        XCTAssertTrue(callbackFired)
        XCTAssertEqual(fromMode, .stable)
        XCTAssertEqual(toMode, .fluid)
        XCTAssertNotNil(changeReason)
    }

    // MARK: - 级联降级 Reference → Fluid → Stable

    func testCascadeDegradation() {
        let controller = RenderingModeController()
        controller.requestMode(.reference)
        XCTAssertEqual(controller.currentMode, .reference)

        controller.triggerAutoDegradation(reason: "step1")
        XCTAssertEqual(controller.currentMode, .fluid)

        controller.triggerAutoDegradation(reason: "step2")
        XCTAssertEqual(controller.currentMode, .stable)

        controller.triggerAutoDegradation(reason: "step3")
        XCTAssertEqual(controller.currentMode, .stable, "Already at bottom")
    }
}

// MARK: - Health Monitor Tests

final class RendererHealthMonitorTests: XCTestCase {

    func testInitialState() {
        let monitor = RendererHealthMonitor()
        XCTAssertEqual(monitor.presentedFrameCount, 0)
        XCTAssertEqual(monitor.droppedFrameCount, 0)
        XCTAssertEqual(monitor.degradationCount, 0)
        XCTAssertFalse(monitor.isFrozen)
    }

    func testRecordPresentedFrameIncrementsCount() {
        let monitor = RendererHealthMonitor()
        monitor.recordPresentedFrame(latencyNs: 16_000_000, recvBytes: 1024)
        monitor.recordPresentedFrame(latencyNs: 15_000_000, recvBytes: 2048)
        XCTAssertEqual(monitor.presentedFrameCount, 2)
    }

    func testRecordDroppedFrameIncrementsCount() {
        let monitor = RendererHealthMonitor()
        monitor.recordDroppedFrame(reason: .decodeFailed)
        monitor.recordDroppedFrame(reason: .textureCreationFailed)
        XCTAssertEqual(monitor.droppedFrameCount, 2)
    }

    func testRecordDegradation() {
        let monitor = RendererHealthMonitor()
        monitor.recordDegradation(from: "fluid", to: "stable", reason: "thermal")
        XCTAssertEqual(monitor.degradationCount, 1)
    }

    func testSnapshotContainsCorrectData() {
        let monitor = RendererHealthMonitor()
        for _ in 0..<10 {
            monitor.recordPresentedFrame(latencyNs: 16_000_000, recvBytes: 1000)
        }
        monitor.recordDroppedFrame(reason: .decodeFailed)

        let snapshot = monitor.snapshot(currentMode: "fluid")
        XCTAssertEqual(snapshot.presentedFrameCount, 10)
        XCTAssertEqual(snapshot.droppedFrameCount, 1)
        XCTAssertEqual(snapshot.currentMode, "fluid")
        XCTAssertEqual(snapshot.totalRecvBytes, 10_000)
    }

    func testDropRate() {
        let snapshot = RendererTelemetrySnapshot(
            presentedFrameCount: 90,
            droppedFrameCount: 10,
            totalRecvBytes: 0,
            latencyP50Ns: 0,
            latencyP95Ns: 0,
            latencyP99Ns: 0,
            averageFPS: 0,
            degradationEvents: [],
            currentMode: "stable",
            uptimeSeconds: 1.0
        )
        XCTAssertEqual(snapshot.dropRate, 0.1, accuracy: 0.01)
    }

    func testResetClearsAllState() {
        let monitor = RendererHealthMonitor()
        monitor.recordPresentedFrame(latencyNs: 16_000_000, recvBytes: 1024)
        monitor.recordDroppedFrame(reason: .decodeFailed)
        monitor.recordDegradation(from: "fluid", to: "stable", reason: "test")

        monitor.reset()

        XCTAssertEqual(monitor.presentedFrameCount, 0)
        XCTAssertEqual(monitor.droppedFrameCount, 0)
        XCTAssertEqual(monitor.degradationCount, 0)
    }

    func testFreezeDetection() {
        // 使用很短的冻屏阈值以便测试
        let monitor = RendererHealthMonitor(freezeThresholdNs: 1) // 1ns threshold

        // 记录一帧，然后等待超过阈值
        monitor.recordPresentedFrame(latencyNs: 1000, recvBytes: 100)

        // 因为 freezeThresholdNs = 1ns，任何后续检查都会超过阈值
        // (除非纳秒精度恰好为0)
        // 这是时间相关的测试，使用一个合理的阈值
        let frozenDetected = monitor.isFrozen
        XCTAssertTrue(frozenDetected, "Should detect freeze with 1ns threshold")
    }
}

// MARK: - Color Pipeline Configuration Tests

final class ColorPipelineConfigurationTests: XCTestCase {

    func testSDRPresetProperties() {
        let sdr = ColorPipelineConfiguration.sdr
        XCTAssertEqual(sdr.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(sdr.transferFunction, .sRGB)
        XCTAssertEqual(sdr.toneMappingMode, .none)
        XCTAssertFalse(sdr.enableEDR)
        XCTAssertEqual(sdr.maxEDRHeadroom, 1.0)
        XCTAssertFalse(sdr.isHDR)
        XCTAssertEqual(sdr.bytesPerPixel, 4)
    }

    func testHDRPresetProperties() {
        let hdr = ColorPipelineConfiguration.hdr
        XCTAssertEqual(hdr.pixelFormat, .rgba16Float)
        XCTAssertEqual(hdr.transferFunction, .pq)
        XCTAssertEqual(hdr.toneMappingMode, .display)
        XCTAssertTrue(hdr.enableEDR)
        XCTAssertEqual(hdr.maxEDRHeadroom, 2.0)
        XCTAssertTrue(hdr.isHDR)
        XCTAssertEqual(hdr.bytesPerPixel, 8)
    }

    func testHLGPresetProperties() {
        let hlg = ColorPipelineConfiguration.hlg
        XCTAssertEqual(hlg.pixelFormat, .rgba16Float)
        XCTAssertEqual(hlg.transferFunction, .hlg)
        XCTAssertTrue(hlg.enableEDR)
        XCTAssertTrue(hlg.isHDR)
    }

    func testWideGamutSDRPreset() {
        let wg = ColorPipelineConfiguration.wideGamutSDR
        XCTAssertEqual(wg.pixelFormat, .bgr10a2Unorm)
        XCTAssertEqual(wg.transferFunction, .sRGB)
        XCTAssertFalse(wg.enableEDR)
        XCTAssertFalse(wg.isHDR)
        XCTAssertEqual(wg.bytesPerPixel, 4)
    }

    func testMakeSourceColorSpace() {
        let sdr = ColorPipelineConfiguration.sdr
        let cs = sdr.makeSourceColorSpace()
        XCTAssertNotNil(cs, "SDR source color space should be valid")
    }

    func testMakeRenderColorSpace() {
        let hdr = ColorPipelineConfiguration.hdr
        let cs = hdr.makeRenderColorSpace()
        XCTAssertNotNil(cs, "HDR render color space should be valid")
    }

    func testIsHDRRequiresBothEDRAndNonSRGB() {
        // EDR enabled but sRGB transfer → not HDR
        let config = ColorPipelineConfiguration(
            sourceColorSpaceName: CGColorSpace.sRGB,
            renderColorSpaceName: CGColorSpace.sRGB,
            pixelFormat: .bgra8Unorm,
            transferFunction: .sRGB,
            toneMappingMode: .none,
            enableEDR: true,
            maxEDRHeadroom: 2.0
        )
        XCTAssertFalse(config.isHDR, "EDR + sRGB should not be considered HDR")
    }
}

// MARK: - Rendering Mode Priority Tests

final class RenderingModePriorityTests: XCTestCase {

    func testPriorityOrder() {
        XCTAssertLessThan(RenderingMode.stable.priority, RenderingMode.fluid.priority)
        XCTAssertLessThan(RenderingMode.fluid.priority, RenderingMode.reference.priority)
    }

    func testAllCasesExhaustivenessViaSwitch() {
        for mode in RenderingMode.allCases {
            switch mode {
            case .stable, .fluid, .reference:
                break // all covered
            }
        }
    }
}

// MARK: - Latency Percentile Calculator Tests

final class LatencyPercentileCalculatorTests: XCTestCase {

    func testEmptyReturnsZero() {
        let calc = LatencyPercentileCalculator(maxSamples: 100)
        XCTAssertEqual(calc.percentile(0.5), 0)
        XCTAssertEqual(calc.percentile(0.99), 0)
    }

    func testSingleSample() {
        let calc = LatencyPercentileCalculator(maxSamples: 100)
        calc.record(42_000)
        XCTAssertEqual(calc.percentile(0.5), 42_000)
        XCTAssertEqual(calc.percentile(0.99), 42_000)
    }

    func testP50MedianIsCorrect() {
        let calc = LatencyPercentileCalculator(maxSamples: 100)
        for i: UInt64 in 1...100 {
            calc.record(i * 1000)
        }
        let p50 = calc.percentile(0.5)
        // 中位数应在 50_000 附近
        XCTAssertGreaterThanOrEqual(p50, 49_000)
        XCTAssertLessThanOrEqual(p50, 51_000)
    }

    func testP99HighEnd() {
        let calc = LatencyPercentileCalculator(maxSamples: 100)
        for i: UInt64 in 1...100 {
            calc.record(i * 1000)
        }
        let p99 = calc.percentile(0.99)
        XCTAssertGreaterThanOrEqual(p99, 98_000)
    }

    func testSlidingWindowDropsOldSamples() {
        let calc = LatencyPercentileCalculator(maxSamples: 10)
        for i: UInt64 in 1...20 {
            calc.record(i * 1000)
        }
        // 只保留最后 10 个样本 (11000..20000)
        let p50 = calc.percentile(0.5)
        XCTAssertGreaterThanOrEqual(p50, 14_000, "After sliding window, oldest samples should be gone")
    }

    func testResetClearsSamples() {
        let calc = LatencyPercentileCalculator(maxSamples: 100)
        calc.record(100_000)
        calc.reset()
        XCTAssertEqual(calc.percentile(0.5), 0)
    }
}

// MARK: - Telemetry Snapshot Tests

final class RendererTelemetrySnapshotTests: XCTestCase {

    func testDropRateZeroWhenNoFrames() {
        let snapshot = RendererTelemetrySnapshot(
            presentedFrameCount: 0,
            droppedFrameCount: 0,
            totalRecvBytes: 0,
            latencyP50Ns: 0,
            latencyP95Ns: 0,
            latencyP99Ns: 0,
            averageFPS: 0,
            degradationEvents: [],
            currentMode: "stable",
            uptimeSeconds: 0
        )
        XCTAssertEqual(snapshot.dropRate, 0)
    }

    func testDropRateAllDropped() {
        let snapshot = RendererTelemetrySnapshot(
            presentedFrameCount: 0,
            droppedFrameCount: 100,
            totalRecvBytes: 0,
            latencyP50Ns: 0,
            latencyP95Ns: 0,
            latencyP99Ns: 0,
            averageFPS: 0,
            degradationEvents: [],
            currentMode: "stable",
            uptimeSeconds: 1.0
        )
        XCTAssertEqual(snapshot.dropRate, 1.0)
    }
}

// MARK: - ManagedAtomic Tests

final class ManagedAtomicTests: XCTestCase {

    func testLoadStoreInt() {
        let atom = ManagedAtomic<Int>(0)
        XCTAssertEqual(atom.load(ordering: .relaxed), 0)
        atom.store(42, ordering: .relaxed)
        XCTAssertEqual(atom.load(ordering: .acquiring), 42)
    }

    func testWrappingIncrement() {
        let atom = ManagedAtomic<Int>(10)
        let old = atom.wrappingIncrement(by: 5)
        XCTAssertEqual(old, 10)
        XCTAssertEqual(atom.load(ordering: .relaxed), 15)
    }

    func testWrappingIncrementByOne() {
        let atom = ManagedAtomic<UInt64>(0)
        atom.wrappingIncrement()
        atom.wrappingIncrement()
        atom.wrappingIncrement()
        XCTAssertEqual(atom.load(ordering: .relaxed), 3)
    }

    func testExchange() {
        let atom = ManagedAtomic<Bool>(false)
        let old = atom.exchange(true, ordering: .relaxed)
        XCTAssertFalse(old)
        XCTAssertTrue(atom.load(ordering: .relaxed))
    }

    func testExchangeInt() {
        let atom = ManagedAtomic<Int>(99)
        let old = atom.exchange(0, ordering: .acquiringAndReleasing)
        XCTAssertEqual(old, 99)
        XCTAssertEqual(atom.load(ordering: .relaxed), 0)
    }
}

// MARK: - Soak / Stress Tests

final class RenderingPipelineSoakTests: XCTestCase {

    /// Ring buffer 并发安全: 模拟生产者/消费者并行
    func testRingBufferConcurrentPushPull() {
        let buffer = DecodedFrameRingBuffer(capacity: 3)
        let pushCount = 5_000
        let expectation = XCTestExpectation(description: "Concurrent push/pull completes")

        // 生产者线程
        DispatchQueue.global(qos: .userInitiated).async {
            for i in 0..<pushCount {
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &pb)
                let frame = DecodedFrameRingBuffer.BufferedFrame(
                    pixelBuffer: pb!,
                    recvTimestampNs: UInt64(i),
                    decodeTimestampNs: UInt64(i + 1),
                    recvBytes: 64
                )
                buffer.push(frame)
            }
        }

        // 消费者线程
        DispatchQueue.global(qos: .userInitiated).async {
            var totalPulled = 0
            // 消费者持续拉帧直到收到预期数量或超时
            let deadline = DispatchTime.now() + .seconds(5)
            while DispatchTime.now() < deadline {
                if let _ = buffer.latestFrame() {
                    totalPulled += 1
                }
                if totalPulled > 0 && !buffer.hasNewFrame {
                    // 短暂等待更多帧
                    usleep(100)
                }
            }
            // 只要不崩溃就算通过——SPSC 安全性验证
            XCTAssertGreaterThan(totalPulled, 0, "Consumer should have pulled at least some frames")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
    }

    /// 模式控制器压力测试: 快速连续切换不应崩溃或死锁
    func testModeControllerRapidTransitions() {
        let controller = RenderingModeController(probationMaxFailures: 1)
        let modes: [RenderingMode] = [.stable, .fluid, .reference]

        for _ in 0..<1000 {
            let mode = modes.randomElement()!
            controller.requestMode(mode)
            if Bool.random() {
                controller.reportProbationFrameSuccess()
            } else {
                controller.reportProbationFrameFailure()
            }
            if Bool.random() {
                controller.triggerAutoDegradation(reason: "stress_test")
            }
        }

        // 不崩溃即通过
        let mode = controller.currentMode
        XCTAssertTrue(RenderingMode.allCases.contains(mode))
    }

    /// Health monitor 高频记录不应崩溃
    func testHealthMonitorHighFrequency() {
        let monitor = RendererHealthMonitor()

        DispatchQueue.concurrentPerform(iterations: 10_000) { i in
            if i % 3 == 0 {
                monitor.recordDroppedFrame(reason: .decodeFailed)
            } else {
                monitor.recordPresentedFrame(latencyNs: UInt64(i * 1000), recvBytes: i % 4096)
            }
        }

        let snapshot = monitor.snapshot(currentMode: "stable")
        let total = snapshot.presentedFrameCount + snapshot.droppedFrameCount
        XCTAssertEqual(total, 10_000, "All frames should be accounted for")
    }

    /// 降级事件记录上限（不泄漏内存）
    func testDegradationEventCap() {
        let monitor = RendererHealthMonitor()
        for i in 0..<200 {
            monitor.recordDegradation(from: "fluid", to: "stable", reason: "event_\(i)")
        }
        let snapshot = monitor.snapshot(currentMode: "stable")
        XCTAssertLessThanOrEqual(snapshot.degradationEvents.count, 50, "Should cap at 50 events")
    }
}

// MARK: - Transfer Function / Tone Mapping Enum Tests

final class TransferFunctionTests: XCTestCase {

    func testAllCasesRawValues() {
        XCTAssertEqual(TransferFunction.sRGB.rawValue, "sRGB")
        XCTAssertEqual(TransferFunction.pq.rawValue, "PQ")
        XCTAssertEqual(TransferFunction.hlg.rawValue, "HLG")
        XCTAssertEqual(TransferFunction.linear.rawValue, "Linear")
    }

    func testToneMappingModeRawValues() {
        XCTAssertEqual(ToneMappingMode.none.rawValue, "none")
        XCTAssertEqual(ToneMappingMode.reinhard.rawValue, "reinhard")
        XCTAssertEqual(ToneMappingMode.aces.rawValue, "aces")
        XCTAssertEqual(ToneMappingMode.display.rawValue, "display")
    }
}
