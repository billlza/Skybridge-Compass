import React from 'react';

const serializeError = (error: any) => {
  if (error instanceof Error) {
    return error.message + '\n' + error.stack;
  }
  return JSON.stringify(error, null, 2);
};

export class ErrorBoundary extends React.Component<
  { children: React.ReactNode },
  { hasError: boolean; error: any; errorInfo: any }
> {
  constructor(props: { children: React.ReactNode }) {
    super(props);
    this.state = { hasError: false, error: null, errorInfo: null };
  }

  static getDerivedStateFromError(error: any) {
    return { hasError: true, error };
  }

  componentDidCatch(error: any, errorInfo: any) {
    console.error('ErrorBoundary caught an error:', error, errorInfo);
    this.setState({ errorInfo });
  }

  handleReset = () => {
    this.setState({ hasError: false, error: null, errorInfo: null });
  }

  render() {
    if (this.state.hasError) {
      return (
        <div className="min-h-screen bg-black flex items-center justify-center p-4">
          <div className="bg-red-900/20 border border-red-500/30 rounded-lg p-6 max-w-2xl w-full">
            <h2 className="text-red-400 text-xl font-semibold mb-4">️ 出现了一个错误
            </h2>
            <p className="text-gray-300 mb-4">
              抱歉，页面遇到了一个问题。您可以尝试刷新页面或联系技术支持。
            </p>
            <button 
              onClick={this.handleReset}
              className="bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg mb-4 mr-4"
            >
              重试
            </button>
            <button 
              onClick={() => window.location.reload()}
              className="bg-gray-600 hover:bg-gray-700 text-white px-4 py-2 rounded-lg mb-4"
            >
              刷新页面
            </button>
            <details className="mt-4">
              <summary className="text-gray-400 cursor-pointer hover:text-gray-300">
                错误详情（点击查看）
              </summary>
              <pre className="mt-2 text-xs text-gray-500 bg-black/30 p-3 rounded overflow-auto max-h-60">
                {serializeError(this.state.error)}
                {this.state.errorInfo && (
                  '\n\nComponent Stack:\n' + this.state.errorInfo.componentStack
                )}
              </pre>
            </details>
          </div>
        </div>
      );
    }

    return this.props.children;
  }
}