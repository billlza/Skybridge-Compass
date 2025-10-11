import SwiftUI
import os.log
import SkyBridgeCore

/// Apple Silicon 性能测试演示界面
@available(macOS 14.0, *)
struct PerformanceTestDemoView: View {
    @State private var isRunning = false
    @State private var testResults: [String] = []
    @State private var currentTest = ""
    @State private var progress: Double = 0.0
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "PerformanceDemo")
    
    var body: some View {
        VStack(spacing: 20) {
            // 标题
            Text("Apple Silicon 性能优化演示")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding()
            
            // 系统信息
            systemInfoSection
            
            // 控制按钮
            HStack(spacing: 15) {
                Button(action: runPerformanceDemo) {
                    HStack {
                        Image(systemName: isRunning ? "stop.circle.fill" : "play.circle.fill")
                        Text(isRunning ? "停止测试" : "开始性能测试")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                
                if !testResults.isEmpty {
                    Button(action: clearResults) {
                        HStack {
                            Image(systemName: "trash")
                            Text("清除结果")
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            // 进度显示
            if isRunning {
                VStack(spacing: 10) {
                    Text("正在运行: \(currentTest)")
                        .font(.headline)
                    
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(maxWidth: 400)
                    
                    Text("\(Int(progress * 100))% 完成")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            // 测试结果
            if !testResults.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("测试结果")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        ForEach(Array(testResults.enumerated()), id: \.offset) { index, result in
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text(result)
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding()
                }
                .background(Color(.controlBackgroundColor))
                .cornerRadius(8)
                .frame(maxHeight: 300)
            }
            
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }
    
    // MARK: - 视图组件
    
    private var systemInfoSection: some View {
        let featureDetector = AppleSiliconFeatureDetector.shared
        let optimizerInfo = AppleSiliconOptimizer.shared.getSystemInfo()
        
        return VStack(alignment: .leading, spacing: 10) {
            Text("系统信息")
                .font(.title2)
                .fontWeight(.bold)
            
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("芯片型号:")
                            .fontWeight(.medium)
                        Text(optimizerInfo.cpuBrand)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("性能核心:")
                            .fontWeight(.medium)
                        Text("\(optimizerInfo.performanceCoreCount) 个")
                            .foregroundColor(.secondary)
                        
                        Spacer().frame(width: 20)
                        
                        Text("效率核心:")
                            .fontWeight(.medium)
                        Text("\(optimizerInfo.efficiencyCoreCount) 个")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("统一内存:")
                            .fontWeight(.medium)
                        Text(featureDetector.supportsUnifiedMemory ? "支持" : "不支持")
                            .foregroundColor(featureDetector.supportsUnifiedMemory ? .green : .red)
                        
                        Spacer().frame(width: 20)
                        
                        Text("Neural Engine:")
                            .fontWeight(.medium)
                        Text(featureDetector.supportsNeuralEngine ? "支持" : "不支持")
                            .foregroundColor(featureDetector.supportsNeuralEngine ? .green : .red)
                    }
                }
                
                Spacer()
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - 操作方法
    
    private func runPerformanceDemo() {
        if isRunning {
            // 停止测试
            isRunning = false
            currentTest = ""
            progress = 0.0
            return
        }
        
        Task {
            await MainActor.run {
                isRunning = true
                testResults.removeAll()
                progress = 0.0
                currentTest = "准备测试..."
            }
            
            // 运行各种性能测试
            await runCPUIntensiveTest()
            await runParallelComputationTest()
            await runMemoryOptimizationTest()
            await runVectorizationTest()
            
            await MainActor.run {
                isRunning = false
                currentTest = "测试完成"
                progress = 1.0
            }
        }
    }
    
    private func runCPUIntensiveTest() async {
        await MainActor.run {
            currentTest = "CPU密集型任务测试"
            progress = 0.25
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // 模拟CPU密集型计算
        let result = await withTaskGroup(of: Double.self) { group in
            for i in 0..<4 {
                group.addTask {
                    var sum: Double = 0
                    let start = i * 250000
                    let end = (i + 1) * 250000
                    for j in start..<end {
                        sum += sqrt(Double(j)) * sin(Double(j))
                    }
                    return sum
                }
            }
            
            var totalSum: Double = 0
            for await partialSum in group {
                totalSum += partialSum
            }
            return totalSum
        }
        
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        
        await MainActor.run {
            testResults.append("CPU密集型任务: \(String(format: "%.3f", executionTime))s, 结果: \(String(format: "%.2f", result))")
        }
    }
    
    private func runParallelComputationTest() async {
        await MainActor.run {
            currentTest = "并行计算测试"
            progress = 0.5
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let optimizer = AppleSiliconOptimizer.shared
        
        // 使用优化器进行并行计算
        let results = await optimizer.performParallelComputation(iterations: 10000) { index in
            return Double(index) * Double(index)
        }
        
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        let sum = results.reduce(0, +)
        
        await MainActor.run {
            testResults.append("并行计算: \(String(format: "%.3f", executionTime))s, 处理 \(results.count) 个任务, 总和: \(String(format: "%.0f", sum))")
        }
    }
    
    private func runMemoryOptimizationTest() async {
        await MainActor.run {
            currentTest = "内存优化测试"
            progress = 0.75
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let memoryOptimizer = MemoryOptimizer.shared
        
        do {
            // 测试大数据集处理
            let largeDataSet = Array(0..<100000).map { Double($0) }
            
            let _ = try await memoryOptimizer.processLargeDataSet(
                data: largeDataSet
            ) { data in
                return data.map { $0 * 2.0 }
            }
            
            let executionTime = CFAbsoluteTimeGetCurrent() - startTime
            
            await MainActor.run {
                testResults.append("内存优化: \(String(format: "%.3f", executionTime))s, 处理 \(largeDataSet.count) 个元素")
            }
        } catch {
            await MainActor.run {
                testResults.append("内存优化: 执行失败 - \(error.localizedDescription)")
            }
        }
    }
    
    private func runVectorizationTest() async {
        await MainActor.run {
            currentTest = "向量化操作测试"
            progress = 1.0
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let optimizer = AppleSiliconOptimizer.shared
        
        // 测试向量化操作
        let testData = Array(0..<50000).map { Float($0) }
        
        let squareResults = optimizer.performVectorizedOperation(testData, operation: VectorOperation.square)
        let sqrtResults = optimizer.performVectorizedOperation(testData, operation: VectorOperation.sqrt)
        let sinResults = optimizer.performVectorizedOperation(testData, operation: VectorOperation.sin)
        
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        
        await MainActor.run {
            testResults.append("向量化操作: \(String(format: "%.3f", executionTime))s, 执行 3 种操作，每种处理 \(testData.count) 个元素")
            testResults.append("平方运算结果数量: \(squareResults.count), 平方根运算结果数量: \(sqrtResults.count), 正弦运算结果数量: \(sinResults.count)")
        }
    }
    
    private func clearResults() {
        testResults.removeAll()
        progress = 0.0
        currentTest = ""
    }
}

// MARK: - 预览

@available(macOS 14.0, *)
#Preview {
    PerformanceTestDemoView()
        .frame(width: 800, height: 600)
}