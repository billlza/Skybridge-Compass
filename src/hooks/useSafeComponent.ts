/**
 * DOM安全组件Hook - 防止DOM操作竞态条件的核心基础设施
 * 这个Hook提供系统级的DOM安全保护，确保所有组件都能安全地进行DOM操作
 */
import { useRef, useEffect, useCallback } from 'react';

interface SafeComponentState {
  isMounted: boolean;
  isSubmitting: boolean;
  timers: Set<NodeJS.Timeout>;
}

export function useSafeComponent() {
  // 使用useRef确保状态在组件生命周期中保持一致
  const stateRef = useRef<SafeComponentState>({
    isMounted: false,
    isSubmitting: false,
    timers: new Set()
  });

  // 安全的状态设置器，只在组件挂载时执行
  const safeSetState = useCallback(<T>(
    setter: React.Dispatch<React.SetStateAction<T>>, 
    value: T | ((prev: T) => T)
  ) => {
    if (stateRef.current.isMounted) {
      try {
        setter(value);
      } catch (error) {
        console.warn('Safe state update failed:', error);
      }
    }
  }, []);

  // 安全的异步操作执行器
  const safeAsyncOperation = useCallback(async <T>(
    operation: () => Promise<T>,
    onSuccess?: (result: T) => void,
    onError?: (error: Error) => void
  ): Promise<T | null> => {
    if (!stateRef.current.isMounted) {
      console.warn('Async operation blocked - component unmounted');
      return null;
    }

    try {
      const result = await operation();
      
      // 检查组件是否仍然挂载
      if (stateRef.current.isMounted && onSuccess) {
        onSuccess(result);
      }
      
      return result;
    } catch (error) {
      if (stateRef.current.isMounted && onError) {
        onError(error as Error);
      }
      throw error;
    }
  }, []);

  // 安全的定时器管理
  const safeSetTimeout = useCallback((callback: () => void, delay: number) => {
    if (!stateRef.current.isMounted) {
      return null;
    }

    const timeoutId = setTimeout(() => {
      // 移除已完成的定时器
      stateRef.current.timers.delete(timeoutId);
      
      // 只在组件仍然挂载时执行回调
      if (stateRef.current.isMounted) {
        try {
          callback();
        } catch (error) {
          console.warn('Safe timeout callback failed:', error);
        }
      }
    }, delay);

    // 跟踪定时器
    stateRef.current.timers.add(timeoutId);
    return timeoutId;
  }, []);

  // 提交操作保护
  const withSubmitProtection = useCallback(async <T>(
    operation: () => Promise<T>
  ): Promise<T | null> => {
    if (stateRef.current.isSubmitting || !stateRef.current.isMounted) {
      console.warn('Submit operation blocked - already submitting or unmounted');
      return null;
    }

    stateRef.current.isSubmitting = true;
    
    try {
      const result = await operation();
      return result;
    } finally {
      if (stateRef.current.isMounted) {
        stateRef.current.isSubmitting = false;
      }
    }
  }, []);

  // DOM元素安全操作
  const safeDOMOperation = useCallback((operation: () => void) => {
    if (!stateRef.current.isMounted) {
      console.warn('DOM operation blocked - component unmounted');
      return;
    }

    try {
      operation();
    } catch (error) {
      console.warn('Safe DOM operation failed:', error);
    }
  }, []);

  // 组件生命周期管理
  useEffect(() => {
    const state = stateRef.current;
    state.isMounted = true;

    return () => {
      // 立即标记为已卸载
      state.isMounted = false;
      state.isSubmitting = false;

      // 清理所有定时器
      state.timers.forEach(timerId => {
        try {
          clearTimeout(timerId);
        } catch (error) {
          console.warn('Timer cleanup failed:', error);
        }
      });
      state.timers.clear();
    };
  }, []);

  return {
    // 状态查询
    isMounted: () => stateRef.current.isMounted,
    isSubmitting: () => stateRef.current.isSubmitting,
    
    // 安全操作方法
    safeSetState,
    safeAsyncOperation,
    safeSetTimeout,
    withSubmitProtection,
    safeDOMOperation,

    // 状态引用（供高级用法）
    stateRef
  };
}

export default useSafeComponent;
