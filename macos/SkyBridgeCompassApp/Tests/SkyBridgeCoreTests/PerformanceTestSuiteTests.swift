import XCTest
@testable import SkyBridgeCore

/// Apple Silicon 性能测试套件的单元测试
@available(macOS 14.0, *)
final class PerformanceTestSuiteTests: XCTestCase {
    
    private var testSuite: PerformanceTestSuite!
    
    override func setUp() {
        super.setUp()
        testSuite = PerformanceTestSuite.shared
    }
    
    override func tearDown() {
        testSuite = nil
        super.tearDown()
    }
    
    // MARK: - 基本功能测试
    
    /// 测试性能测试套件的初始化
    func testPerformanceTestSuiteInitialization() {
        XCTAssertNotNil(testSuite, "性能测试套件应该能够正确初始化")
    }
    
    /// 测试完整测试套件的运行
    func testRunFullTestSuite() async {
        let results = await testSuite.runFullTestSuite()
        
        // 验证所有测试都已运行
        XCTAssertNotNil(results.cpuIntensiveTest, "CPU密集型任务测试应该已运行")
        XCTAssertNotNil(results.parallelComputeTest, "并行计算测试应该已运行")
        XCTAssertNotNil(results.memoryOptimizationTest, "内存优化测试应该已运行")
        XCTAssertNotNil(results.gcdOptimizationTest, "GCD优化测试应该已运行")
        XCTAssertNotNil(results.vectorizationTest, "向量化操作测试应该已运行")
        XCTAssertNotNil(results.qosSchedulingTest, "QoS调度测试应该已运行")
        XCTAssertNotNil(results.networkProcessingTest, "网络处理优化测试应该已运行")
        XCTAssertNotNil(results.imageProcessingTest, "图像处理优化测试应该已运行")
        XCTAssertNotNil(results.dataAnalysisTest, "数据分析优化测试应该已运行")
        XCTAssertNotNil(results.neuralEngineTest, "Neural Engine优化测试应该已运行")
        XCTAssertNotNil(results.memoryBandwidthTest, "内存带宽优化测试应该已运行")
        
        // 验证测试结果的基本属性
        let allResults = results.allResults
        XCTAssertEqual(allResults.count, 11, "应该有11个测试结果")
        
        for result in allResults {
            XCTAssertFalse(result.testName.isEmpty, "测试名称不应为空")
            XCTAssertGreaterThanOrEqual(result.executionTime, 0, "执行时间应该大于等于0")
            XCTAssertFalse(result.details.isEmpty, "测试详情不应为空")
        }
        
        // 验证成功率计算
        let successRate = results.successRate
        XCTAssertGreaterThanOrEqual(successRate, 0, "成功率应该大于等于0")
        XCTAssertLessThanOrEqual(successRate, 100, "成功率应该小于等于100")
        
        // 验证平均执行时间计算
        let avgTime = results.averageExecutionTime
        XCTAssertGreaterThanOrEqual(avgTime, 0, "平均执行时间应该大于等于0")
    }
    
    /// 测试基准测试对比
    func testRunBenchmarkComparison() async {
        let benchmarkResults = await testSuite.runBenchmarkComparison()
        
        // 验证基准测试结果
        XCTAssertGreaterThan(benchmarkResults.nativeExecutionTime, 0, "原生执行时间应该大于0")
        XCTAssertGreaterThan(benchmarkResults.optimizedExecutionTime, 0, "优化执行时间应该大于0")
        
        // 验证性能提升计算是合理的
        let improvement = benchmarkResults.performanceImprovement
        XCTAssertGreaterThan(improvement, -200, "性能提升不应该小于-200%")
        XCTAssertLessThan(improvement, 1000, "性能提升不应该大于1000%")
    }
    
    // MARK: - 性能测试
    
    /// 测试CPU密集型任务的性能
    func testCPUIntensiveTaskPerformance() async {
        let results = await testSuite.runFullTestSuite()
        
        // 验证CPU密集型任务测试结果
        guard let cpuTest = results.cpuIntensiveTest else {
            XCTFail("CPU密集型任务测试结果不应为空")
            return
        }
        
        XCTAssertTrue(cpuTest.success, "CPU密集型任务应该成功执行")
        XCTAssertLessThan(cpuTest.executionTime, 10.0, "CPU密集型任务执行时间应该在合理范围内")
        XCTAssertFalse(cpuTest.testName.isEmpty, "测试名称不应为空")
        XCTAssertFalse(cpuTest.details.isEmpty, "测试详情不应为空")
    }
    
    /// 测试并行计算的性能
    func testParallelComputationPerformance() async {
        let results = await testSuite.runFullTestSuite()
        
        // 验证并行计算测试结果
        guard let parallelTest = results.parallelComputeTest else {
            XCTFail("并行计算测试结果不应为空")
            return
        }
        
        XCTAssertTrue(parallelTest.success, "并行计算应该成功执行")
        XCTAssertLessThan(parallelTest.executionTime, 5.0, "并行计算执行时间应该在合理范围内")
        XCTAssertFalse(parallelTest.testName.isEmpty, "测试名称不应为空")
        XCTAssertFalse(parallelTest.details.isEmpty, "测试详情不应为空")
    }
    
    /// 测试内存优化的性能
    func testMemoryOptimizationPerformance() async {
        let results = await testSuite.runFullTestSuite()
        
        // 验证内存优化测试结果
        guard let memoryTest = results.memoryOptimizationTest else {
            XCTFail("内存优化测试结果不应为空")
            return
        }
        
        XCTAssertTrue(memoryTest.success, "内存优化应该成功执行")
        XCTAssertLessThan(memoryTest.executionTime, 5.0, "内存优化执行时间应该在合理范围内")
        XCTAssertFalse(memoryTest.testName.isEmpty, "测试名称不应为空")
        XCTAssertFalse(memoryTest.details.isEmpty, "测试详情不应为空")
    }
    
    // MARK: - 边界条件测试
    
    /// 测试空测试结果的处理
    func testEmptyTestResults() {
        let emptyResults = TestResults()
        
        XCTAssertEqual(emptyResults.allResults.count, 0, "空测试结果应该没有任何结果")
        XCTAssertEqual(emptyResults.successRate, 0.0, "空测试结果的成功率应该为0")
        XCTAssertEqual(emptyResults.averageExecutionTime, 0.0, "空测试结果的平均执行时间应该为0")
    }
    
    /// 测试单个测试结果的创建
    func testSingleTestResult() {
        let testResult = TestResult(
            testName: "测试任务",
            executionTime: 1.5,
            success: true,
            details: "测试详情"
        )
        
        XCTAssertEqual(testResult.testName, "测试任务")
        XCTAssertEqual(testResult.executionTime, 1.5, accuracy: 0.001)
        XCTAssertTrue(testResult.success)
        XCTAssertEqual(testResult.details, "测试详情")
    }
    
    /// 测试基准测试结果的创建
    func testBenchmarkResultsCreation() {
        let benchmarkResults = BenchmarkResults(
            nativeExecutionTime: 2.0,
            optimizedExecutionTime: 1.0,
            performanceImprovement: 50.0
        )
        
        XCTAssertEqual(benchmarkResults.nativeExecutionTime, 2.0, accuracy: 0.001)
        XCTAssertEqual(benchmarkResults.optimizedExecutionTime, 1.0, accuracy: 0.001)
        XCTAssertEqual(benchmarkResults.performanceImprovement, 50.0, accuracy: 0.001)
    }
    
    // MARK: - 集成测试
    
    /// 测试完整的测试流程
    func testCompleteTestFlow() async {
        // 运行完整测试套件
        let fullResults = await testSuite.runFullTestSuite()
        
        // 验证所有测试都成功运行
        XCTAssertGreaterThan(fullResults.allResults.count, 0, "应该有测试结果")
        
        // 运行基准测试
        let benchmarkResults = await testSuite.runBenchmarkComparison()
        
        // 验证基准测试结果
        XCTAssertGreaterThan(benchmarkResults.nativeExecutionTime, 0, "原生执行时间应该大于0")
        XCTAssertGreaterThan(benchmarkResults.optimizedExecutionTime, 0, "优化执行时间应该大于0")
        
        // 验证整体性能
        let successRate = fullResults.successRate
        XCTAssertGreaterThan(successRate, 30.0, "成功率应该大于30%")
    }
}