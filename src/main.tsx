import { createRoot } from 'react-dom/client'
import { ErrorBoundary } from './components/ErrorBoundary.tsx'
import './index.css'
import App from './App.tsx'

// 暂时移除StrictMode以避免双重渲染导致的DOM错误
// StrictMode在开发环境会故意双重渲染组件来检测副作用
// 这可能导致DOM操作的竞态条件
createRoot(document.getElementById('root')!).render(
  <ErrorBoundary>
    <App />
  </ErrorBoundary>
)
