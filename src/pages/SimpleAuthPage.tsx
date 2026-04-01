import React, { useState, useMemo, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../contexts/AuthContext';

type LoginMethod = 'email' | 'phone' | 'nebula';

const SimpleAuthPage: React.FC = () => {
  const navigate = useNavigate();
  const { signIn, signInNebula, signInPhone } = useAuth();
  
  const [loginMethod, setLoginMethod] = useState<LoginMethod>('email');
  const [email, setEmail] = useState('');
  const [phone, setPhone] = useState('');
  const [nebulaId, setNebulaId] = useState('');
  const [password, setPassword] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');

  // 使用useMemo优化获取当前输入值的逻辑
  const currentCredential = useMemo(() => {
    switch (loginMethod) {
      case 'email': return email;
      case 'phone': return phone;
      case 'nebula': return nebulaId;
      default: return '';
    }
  }, [loginMethod, email, phone, nebulaId]);

  // 使用useCallback优化事件处理函数
  const handleMethodChange = useCallback((method: LoginMethod) => {
    // 使用React 18的批量更新，避免多次渲染
    React.startTransition(() => {
      setLoginMethod(method);
      setError('');
      setSuccess('');
    });
  }, []);

  const handleInputChange = useCallback((value: string) => {
    React.startTransition(() => {
      if (loginMethod === 'email') setEmail(value);
      else if (loginMethod === 'phone') setPhone(value);
      else if (loginMethod === 'nebula') setNebulaId(value);
    });
  }, [loginMethod]);

  const handleLogin = useCallback(async (e: React.FormEvent) => {
    e.preventDefault();
    
    if (!currentCredential || !password) {
      setError('请填写完整的登录信息');
      return;
    }

    setIsLoading(true);
    setError('');

    try {
      if (loginMethod === 'nebula') {
        await signInNebula(nebulaId, password);
      } else if (loginMethod === 'phone') {
        await signInPhone(currentCredential, password);
      } else {
        await signIn(currentCredential, password);
      }

      setSuccess('登录成功！正在跳转...');
      setTimeout(() => {
        navigate('/', { replace: true });
      }, 1000);

    } catch (err: any) {
      console.error('Login error:', err);
      setError(err.message || '登录失败，请稍后重试');
    } finally {
      setIsLoading(false);
    }
  }, [currentCredential, password, loginMethod, nebulaId, signInNebula, signInPhone, signIn, navigate]);

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
              <button
                type="button"
                onClick={() => handleMethodChange('email')}
                className={`p-3 rounded-lg text-sm font-medium transition-all ${
                  loginMethod === 'email'
                    ? 'bg-gradient-to-r from-blue-500 to-purple-500 text-white'
                    : 'bg-white/10 text-gray-300 hover:bg-white/20'
                }`}
              >
                <div className="flex flex-col items-center">
                  <span className="text-lg mb-1">📧</span>
                  <span>邮箱</span>
                </div>
              </button>
              <button
                type="button"
                onClick={() => handleMethodChange('phone')}
                className={`p-3 rounded-lg text-sm font-medium transition-all ${
                  loginMethod === 'phone'
                    ? 'bg-gradient-to-r from-blue-500 to-purple-500 text-white'
                    : 'bg-white/10 text-gray-300 hover:bg-white/20'
                }`}
              >
                <div className="flex flex-col items-center">
                  <span className="text-lg mb-1">📱</span>
                  <span>手机</span>
                </div>
              </button>
              <button
                type="button"
                onClick={() => handleMethodChange('nebula')}
                className={`p-3 rounded-lg text-sm font-medium transition-all ${
                  loginMethod === 'nebula'
                    ? 'bg-gradient-to-r from-blue-500 to-purple-500 text-white'
                    : 'bg-white/10 text-gray-300 hover:bg-white/20'
                }`}
              >
                <div className="flex flex-col items-center">
                  <div className="h-3 w-3 rounded-full bg-gradient-to-r from-blue-400 to-purple-500 mb-1" />
                  <span>星云</span>
                </div>
              </button>
            </div>
          </div>

          <form onSubmit={handleLogin}>
            {/* 登录输入框 - 统一处理 */}
            <div className="mb-6">
              <label className="block text-sm font-medium text-gray-300 mb-2">
                {loginMethod === 'email' && '邮箱地址'}
                {loginMethod === 'phone' && '手机号码'}
                {loginMethod === 'nebula' && '星云账号ID'}
                <span className="text-red-400 ml-1">*</span>
              </label>
              
              <input
                type={loginMethod === 'email' ? 'email' : loginMethod === 'phone' ? 'tel' : 'text'}
                required
                value={currentCredential}
                onChange={(e) => handleInputChange(e.target.value)}
                className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                placeholder={
                  loginMethod === 'email' ? '请输入邮箱地址' : 
                  loginMethod === 'phone' ? '请输入手机号码' : 
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
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                placeholder="请输入您的星云密钥"
              />
            </div>

            {/* 错误和成功消息 */}
            {error && (
              <div className="mb-6 p-4 bg-red-500/10 border border-red-400/30 rounded-lg">
                <p className="text-sm text-red-300">{error}</p>
              </div>
            )}
            
            {success && (
              <div className="mb-6 p-4 bg-green-500/10 border border-green-400/30 rounded-lg">
                <p className="text-sm text-green-300">{success}</p>
              </div>
            )}

            {/* 登录按钮 */}
            <button
              type="submit"
              disabled={isLoading}
              className="w-full bg-gradient-to-r from-blue-600 to-purple-600 hover:from-blue-700 hover:to-purple-700 disabled:opacity-50 disabled:cursor-not-allowed text-white font-semibold py-3 px-6 rounded-lg transition-all duration-200 transform hover:scale-105"
            >
              {isLoading ? (
                <>
                  <span className="inline-block animate-spin mr-2">⭐</span>
                  登录中...
                </>
              ) : (
                '登录星云世界'
              )}
            </button>
          </form>
        </div>
      </div>
    </div>
  );
};

export default SimpleAuthPage;
