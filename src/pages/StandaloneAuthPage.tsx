import React, { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { signInWithNebulaId, supabase } from '../lib/supabase';

// 完全独立的登录页面，不依赖AuthContext
const StandaloneAuthPage: React.FC = () => {
  const navigate = useNavigate();
  
  // 使用单一状态对象管理所有状态
  const [state, setState] = useState({
    method: 'email' as 'email' | 'phone' | 'nebula',
    email: '',
    phone: '',
    nebulaId: '',
    password: '',
    loading: false,
    error: '',
    success: ''
  });

  // 统一的状态更新函数
  const updateState = (updates: Partial<typeof state>) => {
    setState(prev => ({ ...prev, ...updates }));
  };

  // 获取当前输入值
  const getCurrentInput = () => {
    switch (state.method) {
      case 'email': return state.email;
      case 'phone': return state.phone;
      case 'nebula': return state.nebulaId;
      default: return '';
    }
  };

  // 切换登录方式
  const switchMethod = (method: 'email' | 'phone' | 'nebula') => {
    updateState({ 
      method, 
      error: '', 
      success: '' 
    });
  };

  // 处理输入变化
  const handleInputChange = (value: string) => {
    const updates: any = { error: '', success: '' };
    
    if (state.method === 'email') updates.email = value;
    else if (state.method === 'phone') updates.phone = value;
    else if (state.method === 'nebula') updates.nebulaId = value;
    
    updateState(updates);
  };

  // 处理登录
  const handleLogin = async (e: React.FormEvent) => {
    e.preventDefault();
    
    const currentInput = getCurrentInput();
    if (!currentInput || !state.password) {
      updateState({ error: '请填写完整的登录信息' });
      return;
    }

    updateState({ loading: true, error: '' });

    try {
      if (state.method === 'nebula') {
        await signInWithNebulaId(state.nebulaId, state.password);
      } else if (state.method === 'phone') {
        const { error: authError } = await supabase.auth.signInWithPassword({
          phone: currentInput,
          password: state.password
        });

        if (authError) {
          throw authError;
        }
      } else {
        const { error: authError } = await supabase.auth.signInWithPassword({
          email: currentInput,
          password: state.password
        });

        if (authError) {
          throw authError;
        }
      }

      updateState({ success: '登录成功！正在跳转...', loading: false });
      
      // 延迟跳转
      setTimeout(() => {
        navigate('/', { replace: true });
      }, 1000);

    } catch (err: any) {
      console.error('Login error:', err);
      updateState({ 
        error: err.message || '登录失败，请稍后重试', 
        loading: false 
      });
    }
  };

  return (
    <div className="min-h-screen pt-20 pb-16 px-4 sm:px-6 lg:px-8 flex items-center justify-center">
      <div className="max-w-md w-full">
        <div className="text-center mb-8">
          <h1 className="text-3xl font-bold text-white mb-2">
            登录
            <span className="bg-gradient-to-r from-blue-400 to-purple-500 bg-clip-text text-transparent ml-2">
              星云账号
            </span>
          </h1>
          <p className="text-gray-300">
            使用您的星云账号登录数字宇宙
          </p>
        </div>

        <div className="bg-white/5 backdrop-blur-sm rounded-2xl border border-white/10 p-8">
          {/* 登录方式选择 */}
          <div className="mb-6">
            <label className="block text-sm font-medium text-gray-300 mb-3">
              选择登录方式
            </label>
            <div className="grid grid-cols-3 gap-2">
              {(['email', 'phone', 'nebula'] as const).map((method) => (
                <button
                  key={method}
                  type="button"
                  onClick={() => switchMethod(method)}
                  className={`p-3 rounded-lg text-sm font-medium transition-all ${
                    state.method === method
                      ? 'bg-gradient-to-r from-blue-500 to-purple-500 text-white'
                      : 'bg-white/10 text-gray-300 hover:bg-white/20'
                  }`}
                >
                  <div className="flex flex-col items-center">
                    <span className="text-lg mb-1">
                      {method === 'email' ? '📧' : method === 'phone' ? '📱' : '⭐'}
                    </span>
                    <span>
                      {method === 'email' ? '邮箱' : method === 'phone' ? '手机' : '星云'}
                    </span>
                  </div>
                </button>
              ))}
            </div>
          </div>

          <form onSubmit={handleLogin}>
            {/* 登录输入框 */}
            <div className="mb-6">
              <label className="block text-sm font-medium text-gray-300 mb-2">
                {state.method === 'email' ? '邮箱地址' : 
                 state.method === 'phone' ? '手机号码' : '星云账号ID'}
                <span className="text-red-400 ml-1">*</span>
              </label>
              <input
                type={state.method === 'email' ? 'email' : 'text'}
                required
                value={getCurrentInput()}
                onChange={(e) => handleInputChange(e.target.value)}
                className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                placeholder={
                  state.method === 'email' ? '请输入邮箱地址' : 
                  state.method === 'phone' ? '请输入手机号码' : 
                  '请输入星云账号ID'
                }
              />
            </div>

            {/* 密码输入框 */}
            <div className="mb-6">
              <label className="block text-sm font-medium text-gray-300 mb-2">
                星云密钥 <span className="text-red-400">*</span>
              </label>
              <input
                type="password"
                required
                value={state.password}
                onChange={(e) => updateState({ password: e.target.value })}
                className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                placeholder="请输入您的星云密钥"
              />
            </div>

            {/* 错误和成功消息 */}
            {state.error && (
              <div className="mb-6 p-4 bg-red-500/10 border border-red-400/30 rounded-lg">
                <p className="text-sm text-red-300">{state.error}</p>
              </div>
            )}
            
            {state.success && (
              <div className="mb-6 p-4 bg-green-500/10 border border-green-400/30 rounded-lg">
                <p className="text-sm text-green-300">{state.success}</p>
              </div>
            )}

            {/* 登录按钮 */}
            <button
              type="submit"
              disabled={state.loading}
              className="w-full bg-gradient-to-r from-blue-600 to-purple-600 hover:from-blue-700 hover:to-purple-700 disabled:opacity-50 disabled:cursor-not-allowed text-white font-semibold py-3 px-6 rounded-lg transition-all duration-200"
            >
              {state.loading ? '登录中...' : '登录星云世界'}
            </button>
          </form>
          
          <div className="mt-4 text-center">
            <p className="text-xs text-gray-500">
              独立版本 v1.0 - 不依赖AuthContext
            </p>
          </div>
        </div>
      </div>
    </div>
  );
};

export default StandaloneAuthPage;
