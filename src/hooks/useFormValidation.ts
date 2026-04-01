/**
 * useFormValidation - 安全的表单验证Hook
 * 提供统一的表单验证逻辑，包括用户ID格式验证
 */
import { useState, useCallback } from 'react';
import useSafeComponent from './useSafeComponent';

interface ValidationRule {
  test: (value: string) => boolean;
  message: string;
}

interface ValidationRules {
  [fieldName: string]: ValidationRule[];
}

interface FormErrors {
  [fieldName: string]: string;
}

export function useFormValidation(rules: ValidationRules) {
  const [errors, setErrors] = useState<FormErrors>({});
  const { safeSetState } = useSafeComponent();

  // 用户ID验证规则
  const USER_ID_RULES: ValidationRule[] = [
    {
      test: (value: string) => /^[a-zA-Z0-9_\u4e00-\u9fff-]+$/.test(value),
      message: '用户ID只能包含字母、数字、汉字、下划线和连字符'
    },
    {
      test: (value: string) => value.length >= 3 && value.length <= 30,
      message: '用户ID长度必须在3-30个字符之间'
    }
  ];

  // 邮箱验证规则
  const EMAIL_RULES: ValidationRule[] = [
    {
      test: (value: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value),
      message: '请输入有效的邮箱地址'
    }
  ];

  // 手机号验证规则
  const PHONE_RULES: ValidationRule[] = [
    {
      test: (value: string) => /^1[3-9]\d{9}$/.test(value),
      message: '请输入有效的中国大陆手机号码'
    }
  ];

  // 密码验证规则
  const PASSWORD_RULES: ValidationRule[] = [
    {
      test: (value: string) => value.length >= 8,
      message: '密码长度不能少于8位'
    }
  ];

  // 预定义规则集合
  const PREDEFINED_RULES = {
    userId: USER_ID_RULES,
    nebulaId: USER_ID_RULES, // 星云ID使用相同规则
    email: EMAIL_RULES,
    phone: PHONE_RULES,
    password: PASSWORD_RULES
  };

  // 验证单个字段
  const validateField = useCallback((fieldName: string, value: string): string | null => {
    const fieldRules = rules[fieldName] || PREDEFINED_RULES[fieldName as keyof typeof PREDEFINED_RULES] || [];
    
    for (const rule of fieldRules) {
      if (!rule.test(value)) {
        return rule.message;
      }
    }
    
    return null;
  }, [rules]);

  // 验证所有字段
  const validateAll = useCallback((formData: Record<string, string>): FormErrors => {
    const newErrors: FormErrors = {};
    
    Object.keys(formData).forEach(fieldName => {
      const error = validateField(fieldName, formData[fieldName]);
      if (error) {
        newErrors[fieldName] = error;
      }
    });
    
    return newErrors;
  }, [validateField]);

  // 设置字段错误
  const setFieldError = useCallback((fieldName: string, error: string) => {
    safeSetState(setErrors, prevErrors => ({
      ...prevErrors,
      [fieldName]: error
    }));
  }, [safeSetState]);

  // 清除字段错误
  const clearFieldError = useCallback((fieldName: string) => {
    safeSetState(setErrors, prevErrors => {
      const newErrors = { ...prevErrors };
      delete newErrors[fieldName];
      return newErrors;
    });
  }, [safeSetState]);

  // 清除所有错误
  const clearAllErrors = useCallback(() => {
    safeSetState(setErrors, {});
  }, [safeSetState]);

  // 实时验证处理
  const handleFieldChange = useCallback((fieldName: string, value: string) => {
    const error = validateField(fieldName, value);
    
    if (error) {
      setFieldError(fieldName, error);
    } else {
      clearFieldError(fieldName);
    }
  }, [validateField, setFieldError, clearFieldError]);

  // 表单提交验证
  const validateForSubmit = useCallback((formData: Record<string, string>): boolean => {
    const newErrors = validateAll(formData);
    safeSetState(setErrors, newErrors);
    return Object.keys(newErrors).length === 0;
  }, [validateAll, safeSetState]);

  return {
    errors,
    validateField,
    validateAll,
    setFieldError,
    clearFieldError,
    clearAllErrors,
    handleFieldChange,
    validateForSubmit,
    
    // 预定义验证器
    PREDEFINED_RULES
  };
}

export default useFormValidation;