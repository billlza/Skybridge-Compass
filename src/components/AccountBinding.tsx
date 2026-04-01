import React, { useState, useCallback, useRef } from 'react';
import { 
  generateNebulaId, 
  sendVerificationCode, 
  bindAccount, 
  unbindAccount 
} from '../lib/supabase';

interface AccountBindingProps {
  profile: any;
  onProfileUpdate: () => void;
}

interface BindingState {
  type: 'email' | 'phone' | null;
  action: 'bind' | 'unbind' | null;
  contact: string;
  code: string;
  isLoading: boolean;
  isVerifying: boolean;
  countdown: number;
  error: string;
  success: string;
}

const AccountBinding: React.FC<AccountBindingProps> = ({ profile, onProfileUpdate }) => {
  const countdownRef = useRef<NodeJS.Timeout | null>(null);
  
  const [state, setState] = useState<BindingState>({
    type: null,
    action: null,
    contact: '',
    code: '',
    isLoading: false,
    isVerifying: false,
    countdown: 0,
    error: '',
    success: ''
  });

  // 重置状态
  const resetState = useCallback(() => {
    if (countdownRef.current) {
      clearInterval(countdownRef.current);
    }
    setState({
      type: null,
      action: null,
      contact: '',
      code: '',
      isLoading: false,
      isVerifying: false,
      countdown: 0,
      error: '',
      success: ''
    });
  }, []);

  // 开始绑定流程
  const startBinding = useCallback((type: 'email' | 'phone') => {
    setState(prev => ({
      ...prev,
      type,
      action: 'bind',
      contact: '',
      code: '',
      error: '',
      success: ''
    }));
  }, []);

  // 开始解绑流程
  const startUnbinding = useCallback((type: 'email' | 'phone') => {
    const currentContact = type === 'email' ? profile.email : profile.phone;
    setState(prev => ({
      ...prev,
      type,
      action: 'unbind',
      contact: currentContact || '',
      code: '',
      error: '',
      success: ''
    }));
  }, [profile]);

  // 发送验证码
  const handleSendCode = useCallback(async () => {
    if (!state.type || !state.contact.trim()) {
      setState(prev => ({ ...prev, error: '请输入联系方式' }));
      return;
    }

    // 验证格式
    if (state.type === 'email') {
      const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
      if (!emailRegex.test(state.contact)) {
        setState(prev => ({ ...prev, error: '邮箱格式不正确' }));
        return;
      }
    } else if (state.type === 'phone') {
      const phoneRegex = /^1[3-9]\d{9}$/;
      if (!phoneRegex.test(state.contact)) {
        setState(prev => ({ ...prev, error: '手机号格式不正确' }));
        return;
      }
    }

    try {
      setState(prev => ({ ...prev, isLoading: true, error: '' }));
      
      await sendVerificationCode(state.type, state.contact);
      
      setState(prev => ({ ...prev, success: '验证码已发送', countdown: 60 }));
      
      // 开始倒计时
      countdownRef.current = setInterval(() => {
        setState(prev => {
          if (prev.countdown <= 1) {
            if (countdownRef.current) {
              clearInterval(countdownRef.current);
            }
            return { ...prev, countdown: 0 };
          }
          return { ...prev, countdown: prev.countdown - 1 };
        });
      }, 1000);
      
    } catch (error: any) {
      setState(prev => ({ ...prev, error: error.message }));
    } finally {
      setState(prev => ({ ...prev, isLoading: false }));
    }
  }, [state.type, state.contact]);

  // 执行绑定
  const handleBind = useCallback(async () => {
    if (!state.type || !state.contact.trim() || !state.code.trim()) {
      setState(prev => ({ ...prev, error: '请填写完整信息' }));
      return;
    }

    try {
      setState(prev => ({ ...prev, isVerifying: true, error: '' }));
      
      await bindAccount(state.type, state.contact, state.code);
      
      setState(prev => ({ ...prev, success: `${state.type === 'email' ? '邮箱' : '手机号'}绑定成功！` }));
      
      // 刷新用户资料
      onProfileUpdate();
      
      // 延迟重置状态
      setTimeout(resetState, 2000);
      
    } catch (error: any) {
      setState(prev => ({ ...prev, error: error.message }));
    } finally {
      setState(prev => ({ ...prev, isVerifying: false }));
    }
  }, [state.type, state.contact, state.code, onProfileUpdate, resetState]);

  // 执行解绑
  const handleUnbind = useCallback(async () => {
    if (!state.type || !state.code.trim()) {
      setState(prev => ({ ...prev, error: '请输入验证码' }));
      return;
    }

    try {
      setState(prev => ({ ...prev, isVerifying: true, error: '' }));
      
      await unbindAccount(state.type, state.code);
      
      setState(prev => ({ ...prev, success: `${state.type === 'email' ? '邮箱' : '手机号'}解绑成功！` }));
      
      // 刷新用户资料
      onProfileUpdate();
      
      // 延迟重置状态
      setTimeout(resetState, 2000);
      
    } catch (error: any) {
      setState(prev => ({ ...prev, error: error.message }));
    } finally {
      setState(prev => ({ ...prev, isVerifying: false }));
    }
  }, [state.type, state.code, onProfileUpdate, resetState]);

  // 生成星云ID
  const handleGenerateNebulaId = useCallback(async () => {
    try {
      setState(prev => ({ ...prev, isLoading: true, error: '' }));
      
      await generateNebulaId();
      
      setState(prev => ({ ...prev, success: '星云ID生成成功！' }));
      
      // 刷新用户资料
      onProfileUpdate();
      
    } catch (error: any) {
      setState(prev => ({ ...prev, error: error.message }));
    } finally {
      setState(prev => ({ ...prev, isLoading: false }));
    }
  }, [onProfileUpdate]);

  return (
    <div className="mt-8">
      <h2 className="text-lg font-semibold text-white mb-6">账户绑定管理</h2>
      
      {/* 错误和成功消息 */}
      {state.error && (
        <div className="mb-4 p-4 bg-red-500/10 border border-red-400/30 rounded-lg">
          <p className="text-sm text-red-300">{state.error}</p>
        </div>
      )}
      
      {state.success && (
        <div className="mb-4 p-4 bg-green-500/10 border border-green-400/30 rounded-lg">
          <p className="text-sm text-green-300">{state.success}</p>
        </div>
      )}

      {/* 星云ID */}
      <div className="bg-white/5 backdrop-blur-sm rounded-xl border border-white/10 p-6 mb-6">
        <div className="flex items-center justify-between">
          <div>
            <h3 className="text-white font-medium mb-1">星云ID</h3>
            <p className="text-gray-400 text-sm mb-2">
              {profile.nebula_id ? `您的星云ID：${profile.nebula_id}` : '尚未生成星云ID'}
            </p>
            <p className="text-gray-500 text-xs">
              星云ID是您的永久标识符，生成后无法更改
            </p>
          </div>
          {!profile.nebula_id && (
            <button
              onClick={handleGenerateNebulaId}
              disabled={state.isLoading}
              className="px-4 py-2 bg-gradient-to-r from-blue-600 to-purple-600 hover:from-blue-700 hover:to-purple-700 disabled:opacity-50 disabled:cursor-not-allowed text-white rounded-lg transition-all duration-200"
            >
              {state.isLoading ? '生成中...' : '生成星云ID'}
            </button>
          )}
        </div>
      </div>

      {/* 邮箱绑定 */}
      <div className="bg-white/5 backdrop-blur-sm rounded-xl border border-white/10 p-6 mb-6">
        <div className="flex items-center justify-between mb-4">
          <div>
            <h3 className="text-white font-medium mb-1">邮箱绑定</h3>
            <p className="text-gray-400 text-sm">
              {profile.email ? `已绑定：${profile.email}` : '尚未绑定邮箱'}
            </p>
          </div>
          <div className="space-x-2">
            {!profile.email ? (
              <button
                onClick={() => startBinding('email')}
                className="px-4 py-2 bg-green-600 hover:bg-green-700 text-white rounded-lg transition-colors duration-200"
              >
                绑定邮箱
              </button>
            ) : (
              <button
                onClick={() => startUnbinding('email')}
                className="px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded-lg transition-colors duration-200"
              >
                解绑邮箱
              </button>
            )}
          </div>
        </div>
        
        {/* 邮箱绑定表单 */}
        {state.type === 'email' && (
          <div className="mt-4 p-4 bg-white/5 rounded-lg border border-white/10">
            {state.action === 'bind' && (
              <div className="space-y-4">
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-2">
                    邮箱地址
                  </label>
                  <input
                    type="email"
                    value={state.contact}
                    onChange={(e) => setState(prev => ({ ...prev, contact: e.target.value }))}
                    placeholder="请输入邮箱地址"
                    className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                  />
                </div>
                
                <div className="flex space-x-3">
                  <button
                    onClick={handleSendCode}
                    disabled={state.isLoading || state.countdown > 0}
                    className="px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed text-white rounded-lg transition-colors duration-200"
                  >
                    {state.countdown > 0 ? `${state.countdown}秒后重发` : state.isLoading ? '发送中...' : '发送验证码'}
                  </button>
                </div>
                
                {state.countdown > 0 && (
                  <div className="space-y-4">
                    <div>
                      <label className="block text-sm font-medium text-gray-300 mb-2">
                        验证码
                      </label>
                      <input
                        type="text"
                        value={state.code}
                        onChange={(e) => setState(prev => ({ ...prev, code: e.target.value }))}
                        placeholder="请输入6位验证码"
                        maxLength={6}
                        className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                      />
                    </div>
                    
                    <div className="flex space-x-3">
                      <button
                        onClick={handleBind}
                        disabled={state.isVerifying || !state.code.trim()}
                        className="px-4 py-2 bg-green-600 hover:bg-green-700 disabled:opacity-50 disabled:cursor-not-allowed text-white rounded-lg transition-colors duration-200"
                      >
                        {state.isVerifying ? '绑定中...' : '确认绑定'}
                      </button>
                      <button
                        onClick={resetState}
                        disabled={state.isVerifying}
                        className="px-4 py-2 bg-gray-600 hover:bg-gray-700 disabled:cursor-not-allowed text-white rounded-lg transition-colors duration-200"
                      >
                        取消
                      </button>
                    </div>
                  </div>
                )}
              </div>
            )}
            
            {state.action === 'unbind' && (
              <div className="space-y-4">
                <p className="text-sm text-gray-300">
                  解绑邮箱：{state.contact}
                </p>
                
                <div className="flex space-x-3">
                  <button
                    onClick={handleSendCode}
                    disabled={state.isLoading || state.countdown > 0}
                    className="px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed text-white rounded-lg transition-colors duration-200"
                  >
                    {state.countdown > 0 ? `${state.countdown}秒后重发` : state.isLoading ? '发送中...' : '发送验证码'}
                  </button>
                </div>
                
                {state.countdown > 0 && (
                  <div className="space-y-4">
                    <div>
                      <label className="block text-sm font-medium text-gray-300 mb-2">
                        验证码
                      </label>
                      <input
                        type="text"
                        value={state.code}
                        onChange={(e) => setState(prev => ({ ...prev, code: e.target.value }))}
                        placeholder="请输入6位验证码"
                        maxLength={6}
                        className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                      />
                    </div>
                    
                    <div className="flex space-x-3">
                      <button
                        onClick={handleUnbind}
                        disabled={state.isVerifying || !state.code.trim()}
                        className="px-4 py-2 bg-red-600 hover:bg-red-700 disabled:opacity-50 disabled:cursor-not-allowed text-white rounded-lg transition-colors duration-200"
                      >
                        {state.isVerifying ? '解绑中...' : '确认解绑'}
                      </button>
                      <button
                        onClick={resetState}
                        disabled={state.isVerifying}
                        className="px-4 py-2 bg-gray-600 hover:bg-gray-700 disabled:cursor-not-allowed text-white rounded-lg transition-colors duration-200"
                      >
                        取消
                      </button>
                    </div>
                  </div>
                )}
              </div>
            )}
          </div>
        )}
      </div>

      {/* 手机号绑定 */}
      <div className="bg-white/5 backdrop-blur-sm rounded-xl border border-white/10 p-6">
        <div className="flex items-center justify-between mb-4">
          <div>
            <h3 className="text-white font-medium mb-1">手机号绑定</h3>
            <p className="text-gray-400 text-sm">
              {profile.phone ? `已绑定：${profile.phone}` : '尚未绑定手机号'}
            </p>
          </div>
          <div className="space-x-2">
            {!profile.phone ? (
              <button
                onClick={() => startBinding('phone')}
                className="px-4 py-2 bg-green-600 hover:bg-green-700 text-white rounded-lg transition-colors duration-200"
              >
                绑定手机
              </button>
            ) : (
              <button
                onClick={() => startUnbinding('phone')}
                className="px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded-lg transition-colors duration-200"
              >
                解绑手机
              </button>
            )}
          </div>
        </div>
        
        {/* 手机号绑定表单 */}
        {state.type === 'phone' && (
          <div className="mt-4 p-4 bg-white/5 rounded-lg border border-white/10">
            {state.action === 'bind' && (
              <div className="space-y-4">
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-2">
                    手机号码
                  </label>
                  <input
                    type="tel"
                    value={state.contact}
                    onChange={(e) => setState(prev => ({ ...prev, contact: e.target.value }))}
                    placeholder="请输入手机号码"
                    className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                  />
                </div>
                
                <div className="flex space-x-3">
                  <button
                    onClick={handleSendCode}
                    disabled={state.isLoading || state.countdown > 0}
                    className="px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed text-white rounded-lg transition-colors duration-200"
                  >
                    {state.countdown > 0 ? `${state.countdown}秒后重发` : state.isLoading ? '发送中...' : '发送验证码'}
                  </button>
                </div>
                
                {state.countdown > 0 && (
                  <div className="space-y-4">
                    <div>
                      <label className="block text-sm font-medium text-gray-300 mb-2">
                        验证码
                      </label>
                      <input
                        type="text"
                        value={state.code}
                        onChange={(e) => setState(prev => ({ ...prev, code: e.target.value }))}
                        placeholder="请输入6位验证码"
                        maxLength={6}
                        className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                      />
                    </div>
                    
                    <div className="flex space-x-3">
                      <button
                        onClick={handleBind}
                        disabled={state.isVerifying || !state.code.trim()}
                        className="px-4 py-2 bg-green-600 hover:bg-green-700 disabled:opacity-50 disabled:cursor-not-allowed text-white rounded-lg transition-colors duration-200"
                      >
                        {state.isVerifying ? '绑定中...' : '确认绑定'}
                      </button>
                      <button
                        onClick={resetState}
                        disabled={state.isVerifying}
                        className="px-4 py-2 bg-gray-600 hover:bg-gray-700 disabled:cursor-not-allowed text-white rounded-lg transition-colors duration-200"
                      >
                        取消
                      </button>
                    </div>
                  </div>
                )}
              </div>
            )}
            
            {state.action === 'unbind' && (
              <div className="space-y-4">
                <p className="text-sm text-gray-300">
                  解绑手机号：{state.contact}
                </p>
                
                <div className="flex space-x-3">
                  <button
                    onClick={handleSendCode}
                    disabled={state.isLoading || state.countdown > 0}
                    className="px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed text-white rounded-lg transition-colors duration-200"
                  >
                    {state.countdown > 0 ? `${state.countdown}秒后重发` : state.isLoading ? '发送中...' : '发送验证码'}
                  </button>
                </div>
                
                {state.countdown > 0 && (
                  <div className="space-y-4">
                    <div>
                      <label className="block text-sm font-medium text-gray-300 mb-2">
                        验证码
                      </label>
                      <input
                        type="text"
                        value={state.code}
                        onChange={(e) => setState(prev => ({ ...prev, code: e.target.value }))}
                        placeholder="请输入6位验证码"
                        maxLength={6}
                        className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                      />
                    </div>
                    
                    <div className="flex space-x-3">
                      <button
                        onClick={handleUnbind}
                        disabled={state.isVerifying || !state.code.trim()}
                        className="px-4 py-2 bg-red-600 hover:bg-red-700 disabled:opacity-50 disabled:cursor-not-allowed text-white rounded-lg transition-colors duration-200"
                      >
                        {state.isVerifying ? '解绑中...' : '确认解绑'}
                      </button>
                      <button
                        onClick={resetState}
                        disabled={state.isVerifying}
                        className="px-4 py-2 bg-gray-600 hover:bg-gray-700 disabled:cursor-not-allowed text-white rounded-lg transition-colors duration-200"
                      >
                        取消
                      </button>
                    </div>
                  </div>
                )}
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
};

export default AccountBinding;