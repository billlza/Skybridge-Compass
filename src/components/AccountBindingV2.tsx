import React, { useState, useEffect, useCallback, useRef } from 'react';
import { 
  sendVerificationCodeV2, 
  bindAccountV2, 
  unbindAccount,
  getUserBindingStatus
} from '../lib/supabase';
import { useAuth } from '../contexts/useAuth';
import { getPreferredNebulaId } from '../lib/userDisplay';

interface AccountBindingV2Props {
  onStatusUpdate?: () => void;
}

interface BindingStatus {
  user_id: string;
  nebula_id?: string;
  email?: {
    value: string;
    masked: string;
    is_bound: boolean;
  };
  phone?: {
    value: string;
    masked: string;
    is_bound: boolean;
  };
  account_type: string;
  created_at: string;
  updated_at: string;
}

interface BindingRecord {
  contact_type: 'email' | 'phone';
  action: 'bind' | 'unbind';
  contact_masked: string;
  created_at: string;
  ip_address?: string;
}

interface PendingVerification {
  contact_type: 'email' | 'phone';
  contact_masked: string;
  expires_at: string;
  created_at: string;
}

interface ProcessState {
  type: 'email' | 'phone' | null;
  action: 'bind' | 'unbind' | null;
  step: 'input' | 'verify' | 'complete';
  contact: string;
  code: string;
  isLoading: boolean;
  countdown: number;
  error: string;
  success: string;
  canResendAfter: number;
}

const AccountBindingV2: React.FC<AccountBindingV2Props> = ({ onStatusUpdate }) => {
  const { user, userProfile } = useAuth();
  const countdownRef = useRef<NodeJS.Timeout | null>(null);
  const resendTimerRef = useRef<NodeJS.Timeout | null>(null);
  
  const [bindingStatus, setBindingStatus] = useState<BindingStatus | null>(null);
  const [bindingHistory, setBindingHistory] = useState<BindingRecord[]>([]);
  const [pendingVerifications, setPendingVerifications] = useState<PendingVerification[]>([]);
  const [loading, setLoading] = useState(true);
  
  const [processState, setProcessState] = useState<ProcessState>({
    type: null,
    action: null,
    step: 'input',
    contact: '',
    code: '',
    isLoading: false,
    countdown: 0,
    error: '',
    success: '',
    canResendAfter: 0
  });

  const displayedNebulaId = getPreferredNebulaId(
    user,
    userProfile,
    bindingStatus?.nebula_id
  );

  // 加载绑定状态
  const loadBindingStatus = useCallback(async () => {
    try {
      setLoading(true);
      const data = await getUserBindingStatus();
      setBindingStatus(data.binding_status);
      setBindingHistory(data.binding_history || []);
      setPendingVerifications(data.pending_verifications || []);
    } catch (error: any) {
      console.error('加载绑定状态失败:', error);
      setProcessState(prev => ({ ...prev, error: error.message }));
    } finally {
      setLoading(false);
    }
  }, []);

  // 初始化加载
  useEffect(() => {
    loadBindingStatus();
  }, [loadBindingStatus]);

  // 清理定时器
  useEffect(() => {
    return () => {
      if (countdownRef.current) clearInterval(countdownRef.current);
      if (resendTimerRef.current) clearInterval(resendTimerRef.current);
    };
  }, []);

  // 重置状态
  const resetProcessState = useCallback(() => {
    if (countdownRef.current) clearInterval(countdownRef.current);
    if (resendTimerRef.current) clearInterval(resendTimerRef.current);
    setProcessState({
      type: null,
      action: null,
      step: 'input',
      contact: '',
      code: '',
      isLoading: false,
      countdown: 0,
      error: '',
      success: '',
      canResendAfter: 0
    });
  }, []);

  // 开始绑定流程
  const startBinding = useCallback((type: 'email' | 'phone') => {
    setProcessState({
      type,
      action: 'bind',
      step: 'input',
      contact: '',
      code: '',
      isLoading: false,
      countdown: 0,
      error: '',
      success: '',
      canResendAfter: 0
    });
  }, []);

  // 开始解绑流程
  const startUnbinding = useCallback((type: 'email' | 'phone') => {
    const currentContact = type === 'email' 
      ? bindingStatus?.email?.value 
      : bindingStatus?.phone?.value;
    
    if (!currentContact) {
      setProcessState(prev => ({ 
        ...prev, 
        error: `您尚未绑定${type === 'email' ? '邮箱' : '手机号'}` 
      }));
      return;
    }

    setProcessState({
      type,
      action: 'unbind',
      step: 'verify',
      contact: currentContact,
      code: '',
      isLoading: false,
      countdown: 0,
      error: '',
      success: '',
      canResendAfter: 0
    });
  }, [bindingStatus]);

  // 验证输入格式
  const validateContact = useCallback((type: 'email' | 'phone', contact: string): string | null => {
    if (!contact.trim()) {
      return `请输入${type === 'email' ? '邮箱地址' : '手机号码'}`;
    }
    
    if (type === 'email') {
      const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
      if (!emailRegex.test(contact)) {
        return '邮箱格式不正确';
      }
    } else if (type === 'phone') {
      const phoneRegex = /^1[3-9]\d{9}$/;
      if (!phoneRegex.test(contact)) {
        return '手机号格式不正确，请输入11位中国大陆手机号';
      }
    }
    
    return null;
  }, []);

  // 发送验证码
  const handleSendCode = useCallback(async () => {
    if (!processState.type) return;
    
    const contact = processState.contact.trim();
    if (processState.action === 'bind') {
      const validationError = validateContact(processState.type, contact);
      if (validationError) {
        setProcessState(prev => ({ ...prev, error: validationError }));
        return;
      }
    }

    try {
      setProcessState(prev => ({ ...prev, isLoading: true, error: '' }));
      
      const result = await sendVerificationCodeV2(
        processState.type, 
        contact, 
        processState.action || 'bind'
      );
      
      setProcessState(prev => ({ 
        ...prev, 
        step: 'verify',
        success: result.message,
        countdown: 300, // 5分钟倒计时
        canResendAfter: result.can_resend_after || 60
      }));
      
      // 开始验证码倒计时
      countdownRef.current = setInterval(() => {
        setProcessState(prev => {
          if (prev.countdown <= 1) {
            if (countdownRef.current) clearInterval(countdownRef.current);
            return { ...prev, countdown: 0 };
          }
          return { ...prev, countdown: prev.countdown - 1 };
        });
      }, 1000);
      
      // 开始重发倒计时
      resendTimerRef.current = setInterval(() => {
        setProcessState(prev => {
          if (prev.canResendAfter <= 1) {
            if (resendTimerRef.current) clearInterval(resendTimerRef.current);
            return { ...prev, canResendAfter: 0 };
          }
          return { ...prev, canResendAfter: prev.canResendAfter - 1 };
        });
      }, 1000);
      
    } catch (error: any) {
      setProcessState(prev => ({ ...prev, error: error.message }));
    } finally {
      setProcessState(prev => ({ ...prev, isLoading: false }));
    }
  }, [processState, validateContact]);

  // 确认绑定
  const handleBind = useCallback(async () => {
    if (!processState.type || !processState.contact || !processState.code) {
      setProcessState(prev => ({ ...prev, error: '请填写完整信息' }));
      return;
    }

    try {
      setProcessState(prev => ({ ...prev, isLoading: true, error: '' }));
      
      const result = await bindAccountV2(
        processState.type,
        processState.contact,
        processState.code
      );
      
      setProcessState(prev => ({
        ...prev,
        step: 'complete',
        success: result.message
      }));
      
      // 刷新绑定状态
      await loadBindingStatus();
      onStatusUpdate?.();
      
      // 2秒后重置状态
      setTimeout(resetProcessState, 2000);
      
    } catch (error: any) {
      setProcessState(prev => ({ ...prev, error: error.message }));
    } finally {
      setProcessState(prev => ({ ...prev, isLoading: false }));
    }
  }, [processState, loadBindingStatus, onStatusUpdate, resetProcessState]);

  // 确认解绑
  const handleUnbind = useCallback(async () => {
    if (!processState.type || !processState.code) {
      setProcessState(prev => ({ ...prev, error: '请输入验证码' }));
      return;
    }

    try {
      setProcessState(prev => ({ ...prev, isLoading: true, error: '' }));
      
      const result = await unbindAccount(processState.type, processState.code);
      
      setProcessState(prev => ({
        ...prev,
        step: 'complete',
        success: result.message
      }));
      
      // 刷新绑定状态
      await loadBindingStatus();
      onStatusUpdate?.();
      
      // 2秒后重置状态
      setTimeout(resetProcessState, 2000);
      
    } catch (error: any) {
      setProcessState(prev => ({ ...prev, error: error.message }));
    } finally {
      setProcessState(prev => ({ ...prev, isLoading: false }));
    }
  }, [processState, loadBindingStatus, onStatusUpdate, resetProcessState]);

  // 格式化时间
  const formatTime = useCallback((seconds: number): string => {
    const minutes = Math.floor(seconds / 60);
    const remainingSeconds = seconds % 60;
    return `${minutes}:${remainingSeconds.toString().padStart(2, '0')}`;
  }, []);

  if (loading) {
    return (
      <div className="animate-pulse">
        <div className="h-8 bg-white/10 rounded mb-4"></div>
        <div className="space-y-4">
          <div className="h-32 bg-white/5 rounded-lg"></div>
          <div className="h-32 bg-white/5 rounded-lg"></div>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* 页面标题 */}
      <div className="flex items-center justify-between">
        <h2 className="text-xl font-semibold text-white">账户绑定管理</h2>
        <button
          onClick={loadBindingStatus}
          className="text-sm text-blue-400 hover:text-blue-300 transition-colors"
        >
          刷新状态
        </button>
      </div>

      {/* 错误和成功消息 */}
      {processState.error && (
        <div className="p-4 bg-red-500/10 border border-red-400/30 rounded-lg">
          <p className="text-sm text-red-300">{processState.error}</p>
        </div>
      )}
      
      {processState.success && (
        <div className="p-4 bg-green-500/10 border border-green-400/30 rounded-lg">
          <p className="text-sm text-green-300">{processState.success}</p>
        </div>
      )}

      {/* 星云ID显示 */}
      <div className="apple-glass-panel-strong apple-glass-sheen p-6">
        <div className="flex items-center justify-between">
          <div>
            <h3 className="text-white font-medium mb-1 flex items-center">
              <span className="text-2xl mr-2">✨</span>
              星云ID
            </h3>
            <p className="text-lg font-mono text-blue-400">
              {displayedNebulaId ?? '未生成'}
            </p>
            <p className="text-xs text-gray-500 mt-1">
              您的永久唯一标识符，生成后无法修改
            </p>
          </div>
        </div>
      </div>

      {/* 绑定状态卡片 */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        {/* 邮箱绑定 */}
        <div className="apple-glass-panel apple-glass-sheen p-6">
          <div className="flex items-center justify-between mb-4">
            <div className="flex items-center">
              <span className="text-xl mr-2">📧</span>
              <h3 className="text-white font-medium">邮箱绑定</h3>
            </div>
            <div className="flex items-center space-x-2">
              {bindingStatus?.email?.is_bound ? (
                <span className="apple-glass-chip px-2 py-1 text-green-400 text-xs rounded-full">已绑定</span>
              ) : (
                <span className="apple-glass-chip px-2 py-1 text-gray-400 text-xs rounded-full">未绑定</span>
              )}
            </div>
          </div>
          
          {bindingStatus?.email?.is_bound ? (
            <div className="space-y-3">
              <p className="text-gray-300 text-sm">{bindingStatus.email.masked}</p>
              <div className="flex space-x-2">
                <button
                  onClick={() => startUnbinding('email')}
                  className="px-3 py-1.5 bg-red-600/20 hover:bg-red-600/30 text-red-400 text-sm rounded-lg transition-colors"
                >
                  解绑邮箱
                </button>
              </div>
            </div>
          ) : (
            <div className="space-y-3">
              <p className="text-gray-400 text-sm">尚未绑定邮箱地址</p>
              <button
                onClick={() => startBinding('email')}
                className="px-3 py-1.5 bg-blue-600/20 hover:bg-blue-600/30 text-blue-400 text-sm rounded-lg transition-colors"
              >
                绑定邮箱
              </button>
            </div>
          )}
        </div>

        {/* 手机号绑定 */}
        <div className="apple-glass-panel apple-glass-sheen p-6">
          <div className="flex items-center justify-between mb-4">
            <div className="flex items-center">
              <span className="text-xl mr-2">📱</span>
              <h3 className="text-white font-medium">手机号绑定</h3>
            </div>
            <div className="flex items-center space-x-2">
              {bindingStatus?.phone?.is_bound ? (
                <span className="apple-glass-chip px-2 py-1 text-green-400 text-xs rounded-full">已绑定</span>
              ) : (
                <span className="apple-glass-chip px-2 py-1 text-gray-400 text-xs rounded-full">未绑定</span>
              )}
            </div>
          </div>
          
          {bindingStatus?.phone?.is_bound ? (
            <div className="space-y-3">
              <p className="text-gray-300 text-sm">{bindingStatus.phone.masked}</p>
              <div className="flex space-x-2">
                <button
                  onClick={() => startUnbinding('phone')}
                  className="px-3 py-1.5 bg-red-600/20 hover:bg-red-600/30 text-red-400 text-sm rounded-lg transition-colors"
                >
                  解绑手机
                </button>
              </div>
            </div>
          ) : (
            <div className="space-y-3">
              <p className="text-gray-400 text-sm">尚未绑定手机号码</p>
              <button
                onClick={() => startBinding('phone')}
                className="px-3 py-1.5 bg-blue-600/20 hover:bg-blue-600/30 text-blue-400 text-sm rounded-lg transition-colors"
              >
                绑定手机
              </button>
            </div>
          )}
        </div>
      </div>

      {/* 操作流程模态框 */}
      {processState.type && (
        <div className="fixed inset-0 bg-black/50 backdrop-blur-sm flex items-center justify-center z-50">
          <div className="apple-glass-modal apple-glass-sheen p-6 w-full max-w-md mx-4">
            <div className="flex items-center justify-between mb-4">
              <h3 className="text-lg font-semibold text-white">
                {processState.action === 'bind' ? '绑定' : '解绑'}
                {processState.type === 'email' ? '邮箱' : '手机号'}
              </h3>
              <button
                onClick={resetProcessState}
                className="text-gray-400 hover:text-white transition-colors"
              >
                ✕
              </button>
            </div>

            {/* 输入步骤 */}
            {processState.step === 'input' && processState.action === 'bind' && (
              <div className="space-y-4">
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-2">
                    {processState.type === 'email' ? '邮箱地址' : '手机号码'}
                  </label>
                  <input
                    type={processState.type === 'email' ? 'email' : 'tel'}
                    value={processState.contact}
                    onChange={(e) => setProcessState(prev => ({ 
                      ...prev, 
                      contact: e.target.value,
                      error: ''
                    }))}
                    placeholder={processState.type === 'email' ? '请输入邮箱地址' : '请输入11位手机号'}
                    className="w-full px-4 py-3 apple-glass-field border border-white/20 text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                  />
                </div>
                
                <button
                  onClick={handleSendCode}
                  disabled={processState.isLoading || !processState.contact.trim()}
                    className="w-full apple-glass-cta apple-glass-cta-primary apple-glass-sheen disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  {processState.isLoading ? '发送中...' : '发送验证码'}
                </button>
              </div>
            )}

            {/* 验证步骤 */}
            {processState.step === 'verify' && (
              <div className="space-y-4">
                <div className="text-center">
                  <p className="text-sm text-gray-300 mb-2">
                    验证码已发送到：
                  </p>
                  <p className="text-sm font-mono text-blue-400">
                    {processState.type === 'email' 
                      ? processState.contact.replace(/(.{2}).*(@.*)/, '$1***$2')
                      : processState.contact.replace(/(\d{3})\d{4}(\d{4})/, '$1****$2')
                    }
                  </p>
                  {processState.countdown > 0 && (
                    <p className="text-xs text-gray-500 mt-1">
                      验证码将在 {formatTime(processState.countdown)} 后过期
                    </p>
                  )}
                </div>
                
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-2">
                    验证码
                  </label>
                  <input
                    type="text"
                    value={processState.code}
                    onChange={(e) => setProcessState(prev => ({ 
                      ...prev, 
                      code: e.target.value.replace(/\D/g, '').slice(0, 6),
                      error: ''
                    }))}
                    placeholder="请输入6位验证码"
                    maxLength={6}
                    className="w-full px-4 py-3 apple-glass-field border border-white/20 text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500 focus:border-transparent text-center text-lg font-mono tracking-widest"
                  />
                </div>
                
                <div className="flex space-x-3">
                  <button
                    onClick={processState.action === 'bind' ? handleBind : handleUnbind}
                    disabled={processState.isLoading || processState.code.length !== 6}
                    className="flex-1 apple-glass-cta apple-glass-sheen bg-green-600 text-white disabled:opacity-50 disabled:cursor-not-allowed px-4 py-3"
                  >
                    {processState.isLoading ? '处理中...' : `确认${processState.action === 'bind' ? '绑定' : '解绑'}`}
                  </button>
                  
                  <button
                    onClick={handleSendCode}
                    disabled={processState.isLoading || processState.canResendAfter > 0}
                    className="apple-glass-cta apple-glass-sheen bg-gray-600 text-white disabled:opacity-50 disabled:cursor-not-allowed px-4 py-3"
                  >
                    {processState.canResendAfter > 0 ? `${processState.canResendAfter}s` : '重发'}
                  </button>
                </div>
              </div>
            )}

            {/* 完成步骤 */}
            {processState.step === 'complete' && (
              <div className="text-center py-8">
                <div className="text-6xl mb-4">✓</div>
                <p className="text-lg text-green-400">操作成功！</p>
              </div>
            )}
          </div>
        </div>
      )}

      {/* 绑定历史 */}
      {bindingHistory.length > 0 && (
        <div className="apple-glass-panel apple-glass-sheen p-6">
          <h3 className="text-white font-medium mb-4">最近操作记录</h3>
          <div className="space-y-2">
            {bindingHistory.slice(0, 5).map((record, index) => (
              <div key={index} className="flex items-center justify-between py-2 border-b border-white/5 last:border-b-0">
                <div className="flex items-center space-x-3">
                  <span className={`px-2 py-1 text-xs rounded-full ${
                    record.action === 'bind' 
                      ? 'bg-green-500/20 text-green-400' 
                      : 'bg-red-500/20 text-red-400'
                  }`}>
                    {record.action === 'bind' ? '绑定' : '解绑'}
                  </span>
                  <span className="text-sm text-gray-300">
                    {record.contact_type === 'email' ? '邮箱' : '手机号'}: {record.contact_masked}
                  </span>
                </div>
                <span className="text-xs text-gray-500">
                  {new Date(record.created_at).toLocaleString('zh-CN')}
                </span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
};

export default AccountBindingV2;
