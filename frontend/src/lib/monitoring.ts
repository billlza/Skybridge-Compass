/**
 * 服务器性能监控工具
 * 用于检测 CPU 使用率异常和潜在的 DoS 攻击
 */

interface HealthMetrics {
  timestamp: number;
  requestCount: number;
  avgResponseTime: number;
  errorRate: number;
}

class ServerMonitor {
  private metrics: HealthMetrics[] = [];
  private requestCount = 0;
  private errorCount = 0;
  private responseTimes: number[] = [];
  private readonly maxMetricsHistory = 60; // 保留60个采样点

  // 记录请求
  recordRequest(responseTime: number, isError: boolean = false) {
    this.requestCount++;
    this.responseTimes.push(responseTime);
    if (isError) this.errorCount++;
  }

  // 采样当前指标
  sample(): HealthMetrics {
    const avgResponseTime = this.responseTimes.length > 0
      ? this.responseTimes.reduce((a, b) => a + b, 0) / this.responseTimes.length
      : 0;

    const metrics: HealthMetrics = {
      timestamp: Date.now(),
      requestCount: this.requestCount,
      avgResponseTime,
      errorRate: this.requestCount > 0 ? this.errorCount / this.requestCount : 0,
    };

    this.metrics.push(metrics);
    if (this.metrics.length > this.maxMetricsHistory) {
      this.metrics.shift();
    }

    // 重置计数器
    this.requestCount = 0;
    this.errorCount = 0;
    this.responseTimes = [];

    return metrics;
  }

  // 检测异常
  detectAnomaly(): { isAnomaly: boolean; reason?: string } {
    if (this.metrics.length < 5) {
      return { isAnomaly: false };
    }

    const recent = this.metrics.slice(-5);
    const avgRequests = recent.reduce((a, b) => a + b.requestCount, 0) / recent.length;
    const avgResponseTime = recent.reduce((a, b) => a + b.avgResponseTime, 0) / recent.length;

    // 请求量突增检测 (超过平均值3倍)
    const latestRequests = this.metrics[this.metrics.length - 1].requestCount;
    if (latestRequests > avgRequests * 3 && avgRequests > 10) {
      return { isAnomaly: true, reason: `请求量异常: ${latestRequests} (平均: ${avgRequests.toFixed(0)})` };
    }

    // 响应时间异常检测 (超过2秒)
    if (avgResponseTime > 2000) {
      return { isAnomaly: true, reason: `响应时间过长: ${avgResponseTime.toFixed(0)}ms` };
    }

    // 错误率异常检测 (超过10%)
    const latestErrorRate = this.metrics[this.metrics.length - 1].errorRate;
    if (latestErrorRate > 0.1) {
      return { isAnomaly: true, reason: `错误率过高: ${(latestErrorRate * 100).toFixed(1)}%` };
    }

    return { isAnomaly: false };
  }

  // 获取健康状态
  getHealthStatus(): 'healthy' | 'warning' | 'critical' {
    const anomaly = this.detectAnomaly();
    if (!anomaly.isAnomaly) return 'healthy';
    
    const recent = this.metrics.slice(-3);
    const criticalCount = recent.filter(m => m.errorRate > 0.2 || m.avgResponseTime > 5000).length;
    
    return criticalCount >= 2 ? 'critical' : 'warning';
  }

  // 获取监控报告
  getReport() {
    return {
      status: this.getHealthStatus(),
      anomaly: this.detectAnomaly(),
      recentMetrics: this.metrics.slice(-10),
    };
  }
}

// 单例导出
export const serverMonitor = new ServerMonitor();
