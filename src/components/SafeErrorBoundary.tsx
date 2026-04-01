/**
 * SafeErrorBoundary - 多层DOM错误捕获和恢复组件
 * 提供系统级的错误恢复机制，即使发生DOM错误也不会完全崩溃
 */
import React, { Component, ErrorInfo } from 'react';

interface SafeErrorBoundaryState {
  hasError: boolean;
  error: Error | null;
  errorInfo: ErrorInfo | null;
  retryCount: number;
  lastErrorTime: number;
}

interface SafeErrorBoundaryProps {
  children: React.ReactNode;
  fallback?: React.ComponentType<{ 
    error: Error | null;
    resetError: () => void;
    retryCount: number;
  }>;
  maxRetries?: number;
  resetTimeWindow?: number; // 重置错误计数的时间窗口（毫秒）
}

class SafeErrorBoundary extends Component<SafeErrorBoundaryProps, SafeErrorBoundaryState> {
  private resetTimeoutId: NodeJS.Timeout | null = null;

  constructor(props: SafeErrorBoundaryProps) {
    super(props);
    this.state = {
      hasError: false,
      error: null,
      errorInfo: null,
      retryCount: 0,
      lastErrorTime: 0
    };
  }

  static getDerivedStateFromError(error: Error): Partial<SafeErrorBoundaryState> {
    const now = Date.now();
    return {
      hasError: true,
      error,
      lastErrorTime: now
    };
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    console.error('SafeErrorBoundary caught error:', {
      error: error.message,
      stack: error.stack,
      componentStack: errorInfo.componentStack
    });

    // 检查是否是DOM相关错误
    const isDOMError = this.isDOMRelatedError(error);
    if (isDOMError) {
      console.error('DOM-related error detected:', error.message);
      this.handleDOMError(error);
    }

    this.setState(prevState => ({
      errorInfo,
      retryCount: prevState.retryCount + 1
    }));

    // 设置自动重置定时器
    this.scheduleErrorReset();
  }

  private isDOMRelatedError(error: Error): boolean {
    const domErrorPatterns = [
      /removeChild/i,
      /appendChild/i,
      /insertBefore/i,
      /replaceChild/i,
      /cannot read prop.*of null/i,
      /cannot read prop.*of undefined/i,
      /node.*not.*child/i,
      /failed to execute.*on.*node/i
    ];

    return domErrorPatterns.some(pattern => 
      pattern.test(error.message) || pattern.test(error.stack || '')
    );
  }

  private handleDOMError(error: Error) {
    // DOM错误的特殊处理
    try {
      // 尝试清理可能的DOM状态
      this.cleanupPotentialDOMIssues();
    } catch (cleanupError) {
      console.warn('DOM cleanup failed:', cleanupError);
    }
  }

  private cleanupPotentialDOMIssues() {
    // 移除可能的悬空事件监听器
    try {
      const forms = document.querySelectorAll('form');
      forms.forEach(form => {
        // 移除可能的悬空事件
        (form as any).onsubmit = null;
      });
    } catch (error) {
      console.warn('Form cleanup failed:', error);
    }

    // 清理可能的定时器
    try {
      // 清理高ID的定时器（可能是悬空的）
      for (let i = 1; i < 1000; i++) {
        clearTimeout(i);
      }
    } catch (error) {
      console.warn('Timer cleanup failed:', error);
    }
  }

  private scheduleErrorReset() {
    const { resetTimeWindow = 10000 } = this.props;
    
    if (this.resetTimeoutId) {
      clearTimeout(this.resetTimeoutId);
    }

    this.resetTimeoutId = setTimeout(() => {
      this.setState({
        retryCount: 0
      });
    }, resetTimeWindow);
  }

  private resetError = () => {
    this.setState({
      hasError: false,
      error: null,
      errorInfo: null
    });

    if (this.resetTimeoutId) {
      clearTimeout(this.resetTimeoutId);
      this.resetTimeoutId = null;
    }
  };

  private reloadPage = () => {
    window.location.reload();
  };

  componentWillUnmount() {
    if (this.resetTimeoutId) {
      clearTimeout(this.resetTimeoutId);
    }
  }

  render() {
    const { hasError, error, retryCount } = this.state;
    const { fallback: Fallback, maxRetries = 3 } = this.props;

    if (hasError) {
      // 如果提供了自定义fallback组件
      if (Fallback) {
        return <Fallback error={error} resetError={this.resetError} retryCount={retryCount} />;
      }

      // 默认错误界面
      return (
        <div className="min-h-screen bg-black flex items-center justify-center p-4">
          <div className="bg-red-900/20 border border-red-500/30 rounded-lg p-6 max-w-2xl w-full">
            <h2 className="text-red-400 text-xl font-semibold mb-4">
              应用遇到了问题
            </h2>
            <p className="text-gray-300 mb-4">
              抱歉，页面遇到了一个错误。这可能是临时问题。
            </p>
            
            <div className="flex gap-4 mb-4">
              <button 
                onClick={this.resetError}
                className="bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg"
                disabled={retryCount >= maxRetries}
              >
                {retryCount >= maxRetries ? '重试次数已达上限' : `重试 (${retryCount}/${maxRetries})`}
              </button>
              
              <button 
                onClick={this.reloadPage}
                className="bg-gray-600 hover:bg-gray-700 text-white px-4 py-2 rounded-lg"
              >
                刷新页面
              </button>
            </div>

            <details className="mt-4">
              <summary className="text-gray-400 cursor-pointer hover:text-gray-300">
                错误详情（点击查看）
              </summary>
              <pre className="mt-2 text-xs text-gray-500 bg-black/30 p-3 rounded overflow-auto max-h-40">
                {error?.message}
                {error?.stack && `\n\n${error.stack}`}
              </pre>
            </details>
            
            <div className="mt-4 text-xs text-gray-500">
              错误时间: {new Date(this.state.lastErrorTime).toLocaleString()}
            </div>
          </div>
        </div>
      );
    }

    return this.props.children;
  }
}

export default SafeErrorBoundary;
