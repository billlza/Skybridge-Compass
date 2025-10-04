#!/bin/bash
echo "=== Windows 应用性能测试 ==="

# 检查可执行文件
EXECUTABLE=""
for build_dir in build/windows-*; do
    if [ -d "$build_dir" ] && [ -f "$build_dir/bin/MyWinUI3App.exe" ]; then
        EXECUTABLE="$build_dir/bin/MyWinUI3App.exe"
        break
    fi
done

if [ -z "$EXECUTABLE" ]; then
    echo "❌ 未找到可执行文件"
    echo "请先运行 './scripts/build-windows.sh' 构建项目"
    exit 1
fi

echo "✅ 找到可执行文件: $EXECUTABLE"

# 创建测试目录
TEST_DIR="performance-tests"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# 创建性能测试程序
cat > performance_test.cpp << 'CPPEOF'
#include <iostream>
#include <chrono>
#include <thread>
#include <vector>
#include <random>
#include <algorithm>
#include <immintrin.h>
#include <windows.h>

class PerformanceTest {
private:
    std::chrono::high_resolution_clock::time_point m_startTime;
    std::string m_testName;
    
public:
    PerformanceTest(const std::string& testName) : m_testName(testName) {
        m_startTime = std::chrono::high_resolution_clock::now();
        std::cout << "开始测试: " << m_testName << std::endl;
    }
    
    ~PerformanceTest() {
        auto endTime = std::chrono::high_resolution_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(endTime - m_startTime);
        std::cout << "测试完成: " << m_testName << " - 耗时: " << duration.count() << "ms" << std::endl;
    }
};

// CPU 基准测试
void TestCPUPerformance() {
    PerformanceTest test("CPU 性能测试");
    
    const size_t arraySize = 10000000;
    std::vector<float> a(arraySize), b(arraySize), c(arraySize);
    
    // 初始化数据
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_real_distribution<float> dis(0.0f, 1.0f);
    
    for (size_t i = 0; i < arraySize; ++i) {
        a[i] = dis(gen);
        b[i] = dis(gen);
    }
    
    // 测试标量运算
    auto start = std::chrono::high_resolution_clock::now();
    for (size_t i = 0; i < arraySize; ++i) {
        c[i] = a[i] + b[i] * 2.0f;
    }
    auto end = std::chrono::high_resolution_clock::now();
    auto scalarTime = std::chrono::duration_cast<std::chrono::microseconds>(end - start);
    
    // 测试向量化运算 (AVX2)
    start = std::chrono::high_resolution_clock::now();
    for (size_t i = 0; i < arraySize; i += 8) {
        __m256 va = _mm256_load_ps(&a[i]);
        __m256 vb = _mm256_load_ps(&b[i]);
        __m256 vc = _mm256_fmadd_ps(vb, _mm256_set1_ps(2.0f), va);
        _mm256_store_ps(&c[i], vc);
    }
    end = std::chrono::high_resolution_clock::now();
    auto vectorTime = std::chrono::duration_cast<std::chrono::microseconds>(end - start);
    
    std::cout << "标量运算时间: " << scalarTime.count() << "μs" << std::endl;
    std::cout << "向量化运算时间: " << vectorTime.count() << "μs" << std::endl;
    std::cout << "加速比: " << static_cast<double>(scalarTime.count()) / vectorTime.count() << "x" << std::endl;
}

// 内存性能测试
void TestMemoryPerformance() {
    PerformanceTest test("内存性能测试");
    
    const size_t bufferSize = 100 * 1024 * 1024; // 100MB
    std::vector<uint8_t> buffer(bufferSize);
    
    // 测试顺序写入
    auto start = std::chrono::high_resolution_clock::now();
    for (size_t i = 0; i < bufferSize; ++i) {
        buffer[i] = static_cast<uint8_t>(i & 0xFF);
    }
    auto end = std::chrono::high_resolution_clock::now();
    auto writeTime = std::chrono::duration_cast<std::chrono::milliseconds>(end - start);
    
    // 测试顺序读取
    volatile uint8_t sum = 0;
    start = std::chrono::high_resolution_clock::now();
    for (size_t i = 0; i < bufferSize; ++i) {
        sum += buffer[i];
    }
    end = std::chrono::high_resolution_clock::now();
    auto readTime = std::chrono::duration_cast<std::chrono::milliseconds>(end - start);
    
    // 测试随机访问
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<size_t> dis(0, bufferSize - 1);
    
    start = std::chrono::high_resolution_clock::now();
    for (size_t i = 0; i < 1000000; ++i) {
        size_t index = dis(gen);
        sum += buffer[index];
    }
    end = std::chrono::high_resolution_clock::now();
    auto randomTime = std::chrono::duration_cast<std::chrono::milliseconds>(end - start);
    
    std::cout << "顺序写入时间: " << writeTime.count() << "ms" << std::endl;
    std::cout << "顺序读取时间: " << readTime.count() << "ms" << std::endl;
    std::cout << "随机访问时间: " << randomTime.count() << "ms" << std::endl;
    std::cout << "内存带宽: " << (bufferSize * 2) / (writeTime.count() + readTime.count()) / 1024 / 1024 << " MB/s" << std::endl;
}

// 多线程性能测试
void TestThreadingPerformance() {
    PerformanceTest test("多线程性能测试");
    
    const int numThreads = std::thread::hardware_concurrency();
    const size_t workSize = 10000000;
    
    std::cout << "使用线程数: " << numThreads << std::endl;
    
    // 单线程测试
    auto start = std::chrono::high_resolution_clock::now();
    volatile long long sum = 0;
    for (size_t i = 0; i < workSize; ++i) {
        sum += i * i;
    }
    auto end = std::chrono::high_resolution_clock::now();
    auto singleThreadTime = std::chrono::duration_cast<std::chrono::milliseconds>(end - start);
    
    // 多线程测试
    start = std::chrono::high_resolution_clock::now();
    std::vector<std::thread> threads;
    std::vector<long long> results(numThreads, 0);
    
    for (int t = 0; t < numThreads; ++t) {
        threads.emplace_back([&results, t, numThreads, workSize]() {
            size_t start = (workSize * t) / numThreads;
            size_t end = (workSize * (t + 1)) / numThreads;
            for (size_t i = start; i < end; ++i) {
                results[t] += i * i;
            }
        });
    }
    
    for (auto& thread : threads) {
        thread.join();
    }
    
    long long totalSum = 0;
    for (long long result : results) {
        totalSum += result;
    }
    
    end = std::chrono::high_resolution_clock::now();
    auto multiThreadTime = std::chrono::duration_cast<std::chrono::milliseconds>(end - start);
    
    std::cout << "单线程时间: " << singleThreadTime.count() << "ms" << std::endl;
    std::cout << "多线程时间: " << multiThreadTime.count() << "ms" << std::endl;
    std::cout << "加速比: " << static_cast<double>(singleThreadTime.count()) / multiThreadTime.count() << "x" << std::endl;
}

// 系统信息
void PrintSystemInfo() {
    std::cout << "=== 系统信息 ===" << std::endl;
    
    // CPU 信息
    SYSTEM_INFO sysInfo;
    GetSystemInfo(&sysInfo);
    std::cout << "CPU 核心数: " << sysInfo.dwNumberOfProcessors << std::endl;
    
    // 内存信息
    MEMORYSTATUSEX memInfo;
    memInfo.dwLength = sizeof(memInfo);
    GlobalMemoryStatusEx(&memInfo);
    std::cout << "总内存: " << memInfo.ullTotalPhys / 1024 / 1024 << " MB" << std::endl;
    std::cout << "可用内存: " << memInfo.ullAvailPhys / 1024 / 1024 << " MB" << std::endl;
    
    // 操作系统信息
    OSVERSIONINFOEX osInfo;
    osInfo.dwOSVersionInfoSize = sizeof(osInfo);
    GetVersionEx(reinterpret_cast<OSVERSIONINFO*>(&osInfo));
    std::cout << "操作系统: Windows " << osInfo.dwMajorVersion << "." << osInfo.dwMinorVersion << std::endl;
    
    std::cout << std::endl;
}

int main() {
    std::cout << "=== Windows 应用性能测试 ===" << std::endl;
    std::cout << "测试时间: " << std::chrono::system_clock::now().time_since_epoch().count() << std::endl;
    std::cout << std::endl;
    
    PrintSystemInfo();
    
    TestCPUPerformance();
    std::cout << std::endl;
    
    TestMemoryPerformance();
    std::cout << std::endl;
    
    TestThreadingPerformance();
    std::cout << std::endl;
    
    std::cout << "=== 性能测试完成 ===" << std::endl;
    return 0;
}
CPPEOF

# 编译性能测试程序
echo "🔨 编译性能测试程序..."
x86_64-w64-mingw32-g++ -O3 -march=native -mtune=native -std=c++20 \
    -static-libgcc -static-libstdc++ \
    performance_test.cpp -o performance_test.exe

if [ $? -ne 0 ]; then
    echo "❌ 性能测试程序编译失败"
    exit 1
fi

echo "✅ 性能测试程序编译完成"

# 运行性能测试
echo "🚀 运行性能测试..."
echo "注意: 在 CodeX 环境中，Windows 可执行文件无法直接运行"
echo "性能测试程序已编译，可以在 Windows 环境中运行"

# 生成测试报告
echo "📋 生成测试报告..."
cat > performance-report.txt << 'REPORTEOF'
# Windows 应用性能测试报告

## 测试环境
- 测试时间: $(date)
- 可执行文件: $EXECUTABLE
- 测试程序: performance_test.exe

## 测试项目
1. CPU 性能测试
   - 标量运算 vs 向量化运算 (AVX2)
   - 浮点运算性能
   - SIMD 加速比

2. 内存性能测试
   - 顺序读写性能
   - 随机访问性能
   - 内存带宽测试

3. 多线程性能测试
   - 单线程 vs 多线程
   - 线程扩展性
   - 并行加速比

## 测试结果
- 测试程序已编译完成
- 需要在 Windows 环境中运行
- 结果将显示在控制台

## 性能优化建议
1. 启用 SIMD 指令集
2. 优化内存访问模式
3. 合理使用多线程
4. 减少内存分配
5. 使用缓存友好的数据结构

## 下一步
1. 在 Windows 环境中运行性能测试
2. 分析性能瓶颈
3. 优化关键代码路径
4. 重新测试验证改进
REPORTEOF

echo "📄 性能测试报告已生成: performance-report.txt"

# 返回项目根目录
cd ..

echo ""
echo "=== 性能测试准备完成 ==="
echo "🎯 性能测试程序已编译"
echo ""
echo "测试文件:"
echo "  可执行文件: $EXECUTABLE"
echo "  测试程序: performance-tests/performance_test.exe"
echo "  测试报告: performance-tests/performance-report.txt"
echo ""
echo "下一步:"
echo "  1. 将测试程序复制到 Windows 环境"
echo "  2. 在 Windows 中运行性能测试"
echo "  3. 分析测试结果并优化性能"
