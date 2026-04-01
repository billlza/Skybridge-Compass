/**
 * SafeForm - 防DOM竞态条件的安全表单组件
 * 这是一个完全重构的表单组件，提供系统级的DOM安全保护
 */
import React, { useRef, useCallback, FormEvent, useEffect } from 'react';
import useSafeComponent from '../hooks/useSafeComponent';

interface SafeFormProps {
  onSubmit: (event: FormEvent<HTMLFormElement>) => Promise<void> | void;
  children: React.ReactNode;
  className?: string;
  noValidate?: boolean;
}

export const SafeForm: React.FC<SafeFormProps> = ({
  onSubmit,
  children,
  className = '',
  noValidate = true
}) => {
  const formRef = useRef<HTMLFormElement>(null);
  const { 
    withSubmitProtection, 
  } = useSafeComponent();

  // 安全的表单提交处理
  const handleSubmit = useCallback(async (event: FormEvent<HTMLFormElement>) => {
    // 最严格的事件处理
    try {
      event.preventDefault();
      event.stopPropagation();
      
      // 对原生事件进行额外保护
      if (event.nativeEvent) {
        try {
          if (typeof event.nativeEvent.stopImmediatePropagation === 'function') {
            event.nativeEvent.stopImmediatePropagation();
          }
        } catch (nativeError) {
          console.warn('Native event handling failed:', nativeError);
        }
      }
    } catch (eventError) {
      console.error('Event handling failed:', eventError);
      return;
    }

    // 使用提交保护执行表单处理
    await withSubmitProtection(async () => {
      try {
        await onSubmit(event);
      } catch (submitError) {
        console.error('Form submit handler failed:', submitError);
        throw submitError;
      }
    });
  }, [onSubmit, withSubmitProtection]);

  // 只在组件卸载时做最小清理，避免在重渲染时替换 React 管理的表单节点。
  useEffect(() => {
    return () => {
      const form = formRef.current;
      if (!form) return;

      try {
        (form as HTMLFormElement & { onsubmit: ((event: SubmitEvent) => void) | null }).onsubmit = null;
      } catch (cleanupError) {
        console.warn('Form cleanup failed:', cleanupError);
      }
    };
  }, []);

  return (
    <form
      ref={formRef}
      onSubmit={handleSubmit}
      className={className}
      noValidate={noValidate}
    >
      {children}
    </form>
  );
};

export default SafeForm;
