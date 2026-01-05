import SwiftUI
import os.log

/// Apple Silicon 性能测试界面
@available(macOS 14.0, *)
public struct PerformanceTestView: View {
    @State private var isRunning = false
    @State private var testResults: TestResults?
    @State private var benchmarkResults: BenchmarkResults?
    @State private var currentTest = ""
    @State private var progress: Double = 0.0
    
    private let testSuite = PerformanceTestSuite.shared
    private let featureDetector = AppleSiliconFeatureDetector.shared
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 20) {
 // 标题和系统信息
            headerSection
            
 // 测试控制区域
            controlSection
            
 // 进度显示
            if isRunning {
                progressSection
            }
            
 // 测试结果显示
            if let results = testResults {
                resultsSection(results)
            }
            
 // 基准测试结果
            if let benchmark = benchmarkResults {
                benchmarkSection(benchmark)
            }
            
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }
    
 // MARK: - 视图组件
    
    private var headerSection: some View {
        VStack(spacing: 10) {
            Text("Apple Silicon 性能测试")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            let systemInfo = featureDetector.systemInfo
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("芯片型号:")
                        .fontWeight(.medium)
                    Text(systemInfo.chipModel)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("性能核心:")
                        .fontWeight(.medium)
                    Text("\(systemInfo.performanceCoreCount) 个")
                        .foregroundColor(.secondary)
                    
                    Spacer().frame(width: 20)
                    
                    Text("效率核心:")
                        .fontWeight(.medium)
                    Text("\(systemInfo.efficiencyCoreCount) 个")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("统一内存:")
                        .fontWeight(.medium)
                    Text(systemInfo.supportsUnifiedMemory ? "支持" : "不支持")
                        .foregroundColor(systemInfo.supportsUnifiedMemory ? .green : .red)
                    
                    Spacer().frame(width: 20)
                    
                    Text("Neural Engine:")
                        .fontWeight(.medium)
                    Text(systemInfo.supportsNeuralEngine ? "支持" : "不支持")
                        .foregroundColor(systemInfo.supportsNeuralEngine ? .green : .red)
                }
            }
            .padding()
            .background(Color(.controlBackgroundColor))
            .cornerRadius(8)
        }
    }
    
    private var controlSection: some View {
        HStack(spacing: 15) {
            Button(action: runFullTest) {
                HStack {
                    Image(systemName: "play.circle.fill")
                    Text("运行完整测试")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRunning)
            
            Button(action: runBenchmarkTest) {
                HStack {
                    Image(systemName: "speedometer")
                    Text("基准测试对比")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .disabled(isRunning)
            
            if testResults != nil || benchmarkResults != nil {
                Button(action: clearResults) {
                    HStack {
                        Image(systemName: "trash")
                        Text("清除结果")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .disabled(isRunning)
            }
        }
    }
    
    private var progressSection: some View {
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
    
    private func resultsSection(_ results: TestResults) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("测试结果")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text("成功率: \(String(format: "%.1f", results.successRate))%")
                        .foregroundColor(results.successRate > 80 ? .green : .orange)
                    Text("平均耗时: \(String(format: "%.3f", results.averageExecutionTime))s")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 10) {
                ForEach(results.allResults, id: \.testName) { result in
                    testResultCard(result)
                }
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private func testResultCard(_ result: TestResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(result.success ? .green : .red)
                
                Text(result.testName)
                    .font(.headline)
                    .lineLimit(1)
                
                Spacer()
            }
            
            Text("耗时: \(String(format: "%.3f", result.executionTime))s")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(result.details)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding()
        .background(Color(.windowBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(result.success ? Color.green.opacity(0.3) : Color.red.opacity(0.3), lineWidth: 1)
        )
    }
    
    private func benchmarkSection(_ benchmark: BenchmarkResults) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("基准测试对比")
                .font(.title2)
                .fontWeight(.bold)
            
            HStack {
                VStack(alignment: .leading) {
                    Text("原生实现")
                        .font(.headline)
                    Text("\(String(format: "%.3f", benchmark.nativeExecutionTime))s")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Image(systemName: "arrow.right")
                    .foregroundColor(.blue)
                
                VStack(alignment: .trailing) {
                    Text("优化实现")
                        .font(.headline)
                    Text("\(String(format: "%.3f", benchmark.optimizedExecutionTime))s")
                        .font(.title3)
                        .foregroundColor(.green)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            
            HStack {
                Text("性能提升:")
                    .font(.headline)
                
                Spacer()
                
                Text("\(String(format: "%.1f", benchmark.performanceImprovement))%")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(benchmark.performanceImprovement > 0 ? .green : .red)
            }
            .padding()
            .background(benchmark.performanceImprovement > 0 ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
            .cornerRadius(6)
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
    
 // MARK: - 操作方法
    
    private func runFullTest() {
        Task {
            await MainActor.run {
                isRunning = true
 // 完全清除之前的测试结果，确保界面重新渲染
                testResults = nil
                benchmarkResults = nil
                progress = 0.0
                currentTest = "准备测试..."
            }
            
 // 添加短暂延迟确保UI状态更新
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
            
            let testNames = ["CPU密集型任务", "并行计算", "内存优化", "GCD优化", "向量化操作", "QoS调度"]
            
            for (index, testName) in testNames.enumerated() {
                await MainActor.run {
                    currentTest = testName
                    progress = Double(index) / Double(testNames.count)
                }
                
 // 添加一些延迟以显示进度
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
            }
            
            let results = await testSuite.runFullTestSuite()
            
            await MainActor.run {
                testResults = results
                isRunning = false
                progress = 1.0
                currentTest = "测试完成"
            }
        }
    }
    
    private func runBenchmarkTest() {
        Task {
            await MainActor.run {
                isRunning = true
                benchmarkResults = nil
                progress = 0.0
                currentTest = "运行基准测试..."
            }
            
            let results = await testSuite.runBenchmarkComparison()
            
            await MainActor.run {
                benchmarkResults = results
                isRunning = false
                progress = 1.0
                currentTest = "基准测试完成"
            }
        }
    }
    
    private func clearResults() {
 // 完全清除所有测试结果和状态
        testResults = nil
        benchmarkResults = nil
        progress = 0.0
        currentTest = ""
        isRunning = false
    }
}

// MARK: - 预览

struct PerformanceTestView_Previews: PreviewProvider {
    static var previews: some View {
        if #available(macOS 14.0, *) {
            PerformanceTestView()
                .frame(width: 800, height: 600)
        }
    }
}