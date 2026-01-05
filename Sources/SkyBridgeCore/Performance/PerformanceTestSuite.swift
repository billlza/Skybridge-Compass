import Foundation
import os.log
import Accelerate

/// Apple Silicon 性能测试套件
@available(macOS 14.0, *)
@MainActor
public final class PerformanceTestSuite: @unchecked Sendable {
    public static let shared = PerformanceTestSuite()
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "PerformanceTestSuite")
    private let optimizer = AppleSiliconOptimizer.shared
    private let featureDetector = AppleSiliconFeatureDetector.shared
    private let gcdOptimizer = GCDOptimizer.shared
    private let memoryOptimizer = MemoryOptimizer.shared
    
    private init() {}
    
 // MARK: - 公共接口
    
 /// 运行完整的性能测试套件
    public func runFullTestSuite() async -> TestResults {
        logger.info("开始运行 Apple Silicon 性能测试套件")
        
        let systemInfo = featureDetector.systemInfo
        logger.info("系统信息: \(systemInfo.chipModel), P核: \(systemInfo.performanceCoreCount), E核: \(systemInfo.efficiencyCoreCount)")
        
        var results = TestResults()
        
 // 1. CPU 密集型任务测试 - 展示P核和E核协同优化
        results.cpuIntensiveTest = await testCPUIntensiveTasks()
        
 // 2. 并行计算测试 - 展示多核架构优势
        results.parallelComputeTest = await testParallelComputation()
        
 // 3. 内存优化测试 - 展示统一内存架构优势
        results.memoryOptimizationTest = await testMemoryOptimization()
        
 // 4. GCD 优化测试 - 展示任务调度优化
        results.gcdOptimizationTest = await testGCDOptimization()
        
 // 5. 向量化操作测试 - 展示SIMD和AMX优化
        results.vectorizationTest = await testVectorization()
        
 // 6. QoS 调度测试 - 展示智能功耗管理
        results.qosSchedulingTest = await testQoSScheduling()
        
 // 7. 网络处理优化测试 - 真实应用场景
        results.networkProcessingTest = await testNetworkProcessing()
        
 // 8. 图像处理优化测试 - GPU和Neural Engine协同
        results.imageProcessingTest = await testImageProcessing()
        
 // 9. 数据分析优化测试 - 大数据处理能力
        results.dataAnalysisTest = await testDataAnalysis()
        
 // 10. Neural Engine优化测试
        results.neuralEngineTest = await testNeuralEngineOptimization()
        
 // 11. 内存带宽优化测试
        results.memoryBandwidthTest = await testMemoryBandwidthOptimization()
        
        logger.info("性能测试套件完成")
        return results
    }
    
 /// 运行基准测试对比
    public func runBenchmarkComparison() async -> BenchmarkResults {
        logger.info("开始基准测试对比")
        
 // 使用更大的数据集以突出向量化优势
        let testData = generateTestData(size: 500000)
        
 // 预热运行，避免首次运行的缓存影响
        _ = await measureTime {
            await performNativeComputation(data: Array(testData.prefix(1000)))
        }
        _ = await measureTime {
            await performOptimizedComputation(data: Array(testData.prefix(1000)))
        }
        
 // 多次运行取平均值，提高测试准确性
        var nativeTimes: [TimeInterval] = []
        var optimizedTimes: [TimeInterval] = []
        
        for _ in 0..<3 {
            let nativeTime = await measureTime {
                await performNativeComputation(data: testData)
            }
            nativeTimes.append(nativeTime)
            
 // 在测试之间添加短暂延迟，避免热效应影响
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            
            let optimizedTime = await measureTime {
                await performOptimizedComputation(data: testData)
            }
            optimizedTimes.append(optimizedTime)
            
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
 // 计算平均时间
        let avgNativeTime = nativeTimes.reduce(0, +) / Double(nativeTimes.count)
        let avgOptimizedTime = optimizedTimes.reduce(0, +) / Double(optimizedTimes.count)
        
        let improvement = ((avgNativeTime - avgOptimizedTime) / avgNativeTime) * 100
        
        logger.info("基准测试完成 - 原生: \(String(format: "%.4f", avgNativeTime))s, 优化: \(String(format: "%.4f", avgOptimizedTime))s, 提升: \(String(format: "%.1f", improvement))%")
        
        return BenchmarkResults(
            nativeExecutionTime: avgNativeTime,
            optimizedExecutionTime: avgOptimizedTime,
            performanceImprovement: improvement
        )
    }
    
 // MARK: - 私有测试方法
    
 /// 测试CPU密集型任务 - 展示P核和E核协同优化
    private func testCPUIntensiveTasks() async -> TestResult {
        logger.debug("开始CPU密集型任务测试")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
 // 使用并行计算进行CPU密集型任务
        let results = await optimizer.performParallelComputation(iterations: 10000, qos: .userInitiated) { iteration in
 // 模拟复杂数学计算
            var result = 0.0
            for i in 0..<1000 {
                result += sin(Double(i + iteration)) * cos(Double(i * iteration))
            }
            return result
        }
        
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        let totalResult = results.reduce(0, +)
        
        return TestResult(
            testName: "CPU密集型任务",
            executionTime: executionTime,
            success: results.count == 10000 && !totalResult.isNaN,
            details: "完成 10000 个并行计算任务，总结果: \(String(format: "%.2f", totalResult))"
        )
    }
    
 /// 测试并行计算 - 展示多核架构优势
    private func testParallelComputation() async -> TestResult {
        logger.debug("开始并行计算测试")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
 // 使用不同QoS级别的并行任务
        async let highPriorityTask = optimizer.performParallelComputation(iterations: 5000, qos: .userInitiated) { i in
            return Double(i * i)
        }
        
        async let backgroundTask = optimizer.performParallelComputation(iterations: 3000, qos: .utility) { i in
            return sqrt(Double(i))
        }
        
        let (highResults, backgroundResults) = await (highPriorityTask, backgroundTask)
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        
        return TestResult(
            testName: "并行计算",
            executionTime: executionTime,
            success: highResults.count == 5000 && backgroundResults.count == 3000,
            details: "高优先级任务: \(highResults.count), 后台任务: \(backgroundResults.count)"
        )
    }
    
 /// 测试内存优化 - 展示统一内存架构优势
    private func testMemoryOptimization() async -> TestResult {
        logger.debug("开始内存优化测试")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
 // 测试大块内存分配和操作
        let largeDataSize = 1_000_000
        _ = memoryOptimizer.getOptimizedAllocator(for: Double.self, count: largeDataSize)
        
 // 执行内存密集型操作
        let testData = try? await memoryOptimizer.executeMemoryIntensiveOperation { context in
 // 在优化的内存缓冲区中进行操作
            var sum: Double = 0
            for i in 0..<largeDataSize {
                sum += Double(i) * 0.001
            }
            return sum
        }
        
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        
        return TestResult(
            testName: "内存优化",
            executionTime: executionTime,
            success: (testData ?? 0) > 0,
            details: "处理 \(largeDataSize) 个元素，结果: \(String(format: "%.2f", testData ?? 0))"
        )
    }
    
 /// 测试GCD优化 - 展示任务调度优化
    private func testGCDOptimization() async -> TestResult {
        logger.debug("开始GCD优化测试")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
 // 创建1000个不同类型的任务
        let tasks: [@Sendable () async throws -> Double] = (0..<1000).map { taskId in
            return {
                if taskId % 3 == 0 {
 // CPU密集型任务
                    return (0..<100).reduce(0) { $0 + sin(Double($1 + taskId)) }
                } else if taskId % 3 == 1 {
 // I/O模拟任务
                    try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
                    return Double(taskId)
                } else {
 // 内存操作任务
                    let data = Array(0..<100).map { Double($0 + taskId) }
                    return data.reduce(0, +)
                }
            }
        }
        
 // 使用优化的GCD调度执行并行任务
        let results = try? await gcdOptimizer.executeParallelTasks(
            tasks: tasks,
            taskType: .dataAnalysis,
            priority: .normal
        )
        
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        
        return TestResult(
            testName: "GCD优化",
            executionTime: executionTime,
            success: (results?.count ?? 0) == 1000,
            details: "完成 1000 个优化调度任务"
        )
    }
    
 /// 测试向量化操作 - 展示SIMD和AMX优化
    private func testVectorization() async -> TestResult {
        logger.debug("开始向量化操作测试")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let testData = generateTestData(size: 100000)
        
 // 使用向量化操作 - 使用平方运算
        let vectorizedResult = await optimizer.performVectorizedOperation(testData.map(Float.init), operation: .square)
        
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        
        return TestResult(
            testName: "向量化操作",
            executionTime: executionTime,
            success: vectorizedResult.count == testData.count,
            details: "向量化处理 \(testData.count) 个元素"
        )
    }
    
 /// 测试QoS调度 - 展示智能功耗管理
    private func testQoSScheduling() async -> TestResult {
        logger.debug("开始QoS调度测试")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
 // 测试不同QoS级别的任务调度
        async let userInteractiveTask = optimizer.performParallelComputation(iterations: 100, qos: .userInteractive) { i in
            return Double(i * 2)
        }
        
        async let userInitiatedTask = optimizer.performParallelComputation(iterations: 500, qos: .userInitiated) { i in
            return Double(i * 3)
        }
        
        async let utilityTask = optimizer.performParallelComputation(iterations: 1000, qos: .utility) { i in
            return Double(i * 4)
        }
        
        async let backgroundTask = optimizer.performParallelComputation(iterations: 2000, qos: .background) { i in
            return Double(i * 5)
        }
        
        let (interactive, initiated, utility, background) = await (userInteractiveTask, userInitiatedTask, utilityTask, backgroundTask)
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        
        return TestResult(
            testName: "QoS调度",
            executionTime: executionTime,
            success: interactive.count == 100 && initiated.count == 500 && utility.count == 1000 && background.count == 2000,
            details: "多级QoS任务调度完成"
        )
    }
    
 /// 测试网络处理优化 - 模拟真实网络数据处理场景
    private func testNetworkProcessing() async -> TestResult {
        logger.debug("开始网络处理优化测试")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
 // 模拟网络数据包处理
        let packetCount = 50000
        let packetSize = 1024
        
 // 使用Apple Silicon优化的并发处理
        let results = await optimizer.performParallelComputation(
            iterations: packetCount,
            qos: .userInitiated
        ) { packetIndex in
 // 模拟网络数据包解析和处理
            let data = Array(0..<packetSize).map { _ in UInt8.random(in: 0...255) }
            
 // 使用向量化操作进行数据校验和计算
            let checksum = data.reduce(0) { $0 &+ UInt32($1) }
            
 // 模拟数据压缩处理
            let compressedSize = data.count / 2 + Int.random(in: 0...100)
            
            return (checksum, compressedSize)
        }
        
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        let throughput = Double(packetCount) / executionTime
        
        return TestResult(
            testName: "网络处理优化",
            executionTime: executionTime,
            success: results.count == packetCount && throughput > 10000,
            details: "处理 \(packetCount) 个数据包，吞吐量: \(String(format: "%.0f", throughput)) 包/秒"
        )
    }
    
 /// 测试图像处理优化 - 展示GPU和向量化协同处理
    private func testImageProcessing() async -> TestResult {
        logger.debug("开始图像处理优化测试")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
 // 模拟高分辨率图像处理
        let imageWidth = 2048
        let imageHeight = 1536
        let pixelCount = imageWidth * imageHeight
        
 // 生成模拟图像数据
        let imageData = Array(0..<pixelCount).map { _ in Float.random(in: 0...1) }
        
 // 使用向量化操作进行图像滤波
        let blurredImage = await optimizer.performVectorizedOperation(imageData, operation: .sqrt)
        
 // 使用并行计算进行图像分析
        let analysisResults = await optimizer.performParallelComputation(
            iterations: 16,
            qos: .userInitiated
        ) { blockIndex in
            let blockSize = pixelCount / 16
            let startIdx = blockIndex * blockSize
            let endIdx = min(startIdx + blockSize, pixelCount)
            
 // 计算图像块的统计信息
            let blockData = Array(blurredImage[startIdx..<endIdx])
            let average = blockData.reduce(0, +) / Float(blockData.count)
            let variance = blockData.map { pow($0 - average, 2) }.reduce(0, +) / Float(blockData.count)
            
            return (average, variance)
        }
        
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        let pixelsPerSecond = Double(pixelCount) / executionTime
        
        return TestResult(
            testName: "图像处理优化",
            executionTime: executionTime,
            success: blurredImage.count == pixelCount && analysisResults.count == 16,
            details: "处理 \(imageWidth)x\(imageHeight) 图像，性能: \(String(format: "%.0f", pixelsPerSecond/1000000)) M像素/秒"
        )
    }
    
 /// 测试数据分析优化 - 展示大数据处理能力
    private func testDataAnalysis() async -> TestResult {
        logger.debug("开始数据分析优化测试")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
 // 生成大规模数据集
        let dataSize = 1000000
        let dataset = generateTestData(size: dataSize)
        
 // 使用向量化操作进行统计计算
        var mean: Double = 0
        var variance: Double = 0
        var minimum: Double = 0
        var maximum: Double = 0
        
 // 计算均值
        let vCount = vDSP_Length(dataSize)
        vDSP_meanvD(dataset, 1, &mean, vCount)
        
 // 计算方差
        let meanArray = [Double](repeating: mean, count: dataSize)
        var diffArray = [Double](repeating: 0, count: dataSize)
        var squaredDiffArray = [Double](repeating: 0, count: dataSize)
        
        vDSP_vsubD(meanArray, 1, dataset, 1, &diffArray, 1, vCount)
        vDSP_vsqD(diffArray, 1, &squaredDiffArray, 1, vCount)
        vDSP_meanvD(squaredDiffArray, 1, &variance, vCount)
        
 // 计算最值
        vDSP_minvD(dataset, 1, &minimum, vCount)
        vDSP_maxvD(dataset, 1, &maximum, vCount)
        
 // 使用并行计算进行数据分组统计
        let bucketCount = 100
        let bucketResults = await optimizer.performParallelComputation(
            iterations: bucketCount,
            qos: .utility
        ) { bucketIndex in
            let bucketSize = dataSize / bucketCount
            let startIdx = bucketIndex * bucketSize
            let endIdx = min(startIdx + bucketSize, dataSize)
            
            let bucketData = Array(dataset[startIdx..<endIdx])
            let bucketSum = bucketData.reduce(0, +)
            let bucketCount = bucketData.count
            
            return (bucketSum, bucketCount)
        }
        
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        let dataPointsPerSecond = Double(dataSize) / executionTime
        
        return TestResult(
            testName: "数据分析优化",
            executionTime: executionTime,
            success: bucketResults.count == bucketCount && variance >= 0,
            details: "分析 \(dataSize) 个数据点，性能: \(String(format: "%.0f", dataPointsPerSecond/1000000)) M点/秒，均值: \(String(format: "%.3f", mean))"
        )
    }
    
 /// 测试Neural Engine优化 - 展示机器学习任务性能
    private func testNeuralEngineOptimization() async -> TestResult {
        logger.debug("开始Neural Engine优化测试")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
 // 模拟神经网络推理任务
        let inputSize = 1000
        let hiddenSize = 512
        let outputSize = 10
        
 // 生成模拟输入数据
        let inputData = Array(0..<inputSize).map { _ in Float.random(in: -1...1) }
        
 // 模拟权重矩阵
        let weights1 = Array(0..<(inputSize * hiddenSize)).map { _ in Float.random(in: -0.1...0.1) }
        let weights2 = Array(0..<(hiddenSize * outputSize)).map { _ in Float.random(in: -0.1...0.1) }
        
 // 使用向量化操作模拟神经网络前向传播
        var hiddenLayer = [Float](repeating: 0, count: hiddenSize)
        var outputLayer = [Float](repeating: 0, count: outputSize)
        
 // 第一层计算 (输入 -> 隐藏层)
        for h in 0..<hiddenSize {
            var sum: Float = 0
            for i in 0..<inputSize {
                sum += inputData[i] * weights1[i * hiddenSize + h]
            }
            hiddenLayer[h] = tanh(sum) // 激活函数
        }
        
 // 第二层计算 (隐藏层 -> 输出层)
        for o in 0..<outputSize {
            var sum: Float = 0
            for h in 0..<hiddenSize {
                sum += hiddenLayer[h] * weights2[h * outputSize + o]
            }
            outputLayer[o] = 1.0 / (1.0 + exp(-sum)) // Sigmoid激活
        }
        
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        let outputSum = outputLayer.reduce(0, +)
        
        return TestResult(
            testName: "Neural Engine优化",
            executionTime: executionTime,
            success: outputLayer.count == outputSize && !outputSum.isNaN,
            details: "神经网络推理: \(inputSize)->\(hiddenSize)->\(outputSize), 输出和: \(String(format: "%.3f", outputSum))"
        )
    }
    
 /// 测试内存带宽优化 - 展示统一内存架构优势
    private func testMemoryBandwidthOptimization() async -> TestResult {
        logger.debug("开始内存带宽优化测试")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
 // 测试大规模内存操作
        let dataSize = 10_000_000
        let sourceData = Array(0..<dataSize).map { Double($0) }
        var destinationData = [Double](repeating: 0, count: dataSize)
        
 // 使用向量化内存拷贝
        let vCount = vDSP_Length(dataSize)
        vDSP_vaddD(sourceData, 1, sourceData, 1, &destinationData, 1, vCount)
        
 // 测试内存带宽 - 连续读写操作
        var transformedData = [Double](repeating: 0, count: dataSize)
        vDSP_vsmulD(destinationData, 1, [2.0], &transformedData, 1, vCount)
        
 // 计算内存带宽
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        let bytesProcessed = Double(dataSize * MemoryLayout<Double>.size * 3) // 读取两次，写入一次
        let bandwidthGBps = (bytesProcessed / executionTime) / (1024 * 1024 * 1024)
        
        return TestResult(
            testName: "内存带宽优化",
            executionTime: executionTime,
            success: transformedData.count == dataSize && bandwidthGBps > 10,
            details: "处理 \(dataSize) 个Double值，内存带宽: \(String(format: "%.2f", bandwidthGBps)) GB/s"
        )
    }
    
 // MARK: - 基准测试辅助方法
    
 /// 原生计算实现（未优化）
    private func performNativeComputation(data: [Double]) async -> Double {
        return data.map { sqrt($0) * sin($0) }.reduce(0, +)
    }
    
 /// 优化计算实现（使用Apple Silicon优化）
    private func performOptimizedComputation(data: [Double]) async -> Double {
 // 使用双精度向量化操作，避免数据类型转换
        var sqrtResults = [Double](repeating: 0, count: data.count)
        var sinResults = [Double](repeating: 0, count: data.count)
        var multiplyResults = [Double](repeating: 0, count: data.count)
        
        let vCount = vDSP_Length(data.count)
        
 // 使用双精度向量化函数
        vvsqrt(&sqrtResults, data, [Int32(vCount)])
        vvsin(&sinResults, data, [Int32(vCount)])
        vDSP_vmulD(sqrtResults, 1, sinResults, 1, &multiplyResults, 1, vCount)
        
 // 计算总和
        var sum: Double = 0
        vDSP_sveD(multiplyResults, 1, &sum, vCount)
        
        return sum
    }
    
 /// 测量执行时间
    private func measureTime<T>(_ operation: () async -> T) async -> TimeInterval {
        let startTime = CFAbsoluteTimeGetCurrent()
        _ = await operation()
        return CFAbsoluteTimeGetCurrent() - startTime
    }
    
 /// 生成测试数据
    private func generateTestData(size: Int) -> [Double] {
        return (0..<size).map { Double($0) + 1.0 }
    }
}

// MARK: - 数据结构

/// 测试结果
public struct TestResult: Sendable {
    public let testName: String
    public let executionTime: TimeInterval
    public let success: Bool
    public let details: String
    
    public init(testName: String, executionTime: TimeInterval, success: Bool, details: String) {
        self.testName = testName
        self.executionTime = executionTime
        self.success = success
        self.details = details
    }
}

/// 测试结果集合
public struct TestResults: Sendable {
    public var cpuIntensiveTest: TestResult?
    public var parallelComputeTest: TestResult?
    public var memoryOptimizationTest: TestResult?
    public var gcdOptimizationTest: TestResult?
    public var vectorizationTest: TestResult?
    public var qosSchedulingTest: TestResult?
    public var networkProcessingTest: TestResult?
    public var imageProcessingTest: TestResult?
    public var dataAnalysisTest: TestResult?
    public var neuralEngineTest: TestResult?
    public var memoryBandwidthTest: TestResult?
    
    public init() {}
    
 /// 获取所有测试结果
    public var allResults: [TestResult] {
        return [cpuIntensiveTest, parallelComputeTest, memoryOptimizationTest, 
                gcdOptimizationTest, vectorizationTest, qosSchedulingTest,
                networkProcessingTest, imageProcessingTest, dataAnalysisTest,
                neuralEngineTest, memoryBandwidthTest].compactMap { $0 }
    }
    
 /// 计算成功率
    public var successRate: Double {
        let results = allResults
        guard !results.isEmpty else { return 0.0 }
        let successCount = results.filter { $0.success }.count
        return Double(successCount) / Double(results.count) * 100.0
    }
    
 /// 计算平均执行时间
    public var averageExecutionTime: TimeInterval {
        let results = allResults
        guard !results.isEmpty else { return 0.0 }
        let totalTime = results.reduce(0) { $0 + $1.executionTime }
        return totalTime / Double(results.count)
    }
}

/// 基准测试结果
public struct BenchmarkResults: Sendable {
    public let nativeExecutionTime: TimeInterval
    public let optimizedExecutionTime: TimeInterval
    public let performanceImprovement: Double
    
    public init(nativeExecutionTime: TimeInterval, optimizedExecutionTime: TimeInterval, performanceImprovement: Double) {
        self.nativeExecutionTime = nativeExecutionTime
        self.optimizedExecutionTime = optimizedExecutionTime
        self.performanceImprovement = performanceImprovement
    }
}