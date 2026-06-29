import React, { useState, useEffect } from 'react';
import { useSearchParams, useNavigate } from 'react-router-dom';
import { useAuth } from '../contexts/useAuth';

type AuthMode = 'login' | 'register';
type LoginMethod = 'email' | 'phone' | 'nebula';

const AuthPage: React.FC = () => {
  const [searchParams, setSearchParams] = useSearchParams();
  const navigate = useNavigate();
  const { signIn, signInPhone, signUp, signUpPhone } = useAuth();
  const [mode, setMode] = useState<AuthMode>('login');
  const [loginMethod, setLoginMethod] = useState<LoginMethod>('email');
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  
  const [formData, setFormData] = useState({
    constellation: '',
    email: '',
    phone: '',
    nebulaId: '',
    password: '',
    confirmPassword: ''
  });

  // 根据URL参数设置初始模式
  useEffect(() => {
    const modeParam = searchParams.get('mode');
    if (modeParam === 'register' || modeParam === 'login') {
      setMode(modeParam as AuthMode);
    }
  }, [searchParams]);

  const constellations = [
    { value: 'Andromeda', label: 'Andromeda 仙女座', description: '守护智慧与美丽' },
    { value: 'Gemini', label: 'Gemini 双子座', description: '守护沟通与灵活' },
    { value: 'Virgo', label: 'Virgo 处女座', description: '守护完美与精确' },
    { value: 'Libra', label: 'Libra 天秤座', description: '守护平衡与和谐' },
    { value: 'Scorpio', label: 'Scorpio 天蝎座', description: '守护深度与变革' },
    { value: 'Cygnus', label: 'Cygnus 天鹅座', description: '守护优雅与高贵' },
    { value: 'Sagittarius', label: 'Sagittarius 射手座', description: '守护自由与探索' },
    { value: 'Cancer', label: 'Cancer 巨蟹座', description: '守护关怀与保护' },
    { value: 'Aquarius', label: 'Aquarius 水瓶座', description: '守护创新与未来' },
    { value: 'Leo', label: 'Leo 狮子座', description: '守护勇气与领导' },
    { value: 'Orion', label: 'Orion 猎户座', description: '守护力量与决心' },
    { value: 'Taurus', label: 'Taurus 金牛座', description: '守护稳定与财富' }
  ];

  // 切换模式时重置表单和状态
  const switchMode = (newMode: AuthMode) => {
    setMode(newMode);
    setFormData({
      constellation: '',
      email: '',
      phone: '',
      nebulaId: '',
      password: '',
      confirmPassword: ''
    });
    setError('');
    setSuccess('');
    // 更新URL参数
    setSearchParams({ mode: newMode });
  };

  // 注册成功后自动切换到登录模式
  const handleRegisterSuccess = (message: string) => {
    setSuccess(message);
    // 延迟3秒后自动切换到登录模式
    setTimeout(() => {
      switchMode('login');
      setSuccess('');
      setError('请使用您刚才注册的账户登录');
    }, 3000);
  };

  const handleInputChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
    const { name, value } = e.target;
    setFormData(prev => ({
      ...prev,
      [name]: value
    }));
    setError('');
    setSuccess('');
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setSuccess('');
    setIsLoading(true);

    try {
      if (mode === 'register') {
        // 注册逻辑
        if (formData.password !== formData.confirmPassword) {
          throw new Error('星云密钥确认不匹配，请重新输入');
        }
        
        if (formData.password.length < 8) {
          throw new Error('星云密钥长度不能少于8位');
        }

        if (!formData.constellation) {
          throw new Error('请选择您的守护星座');
        }
        
        // 使用真实的Supabase注册
        const constellation = constellations.find(c => c.value === formData.constellation);
        
        let email = '';
        let metadata = {};
        
        if (loginMethod === 'email') {
          // 邮箱注册
          if (!formData.email) {
            throw new Error('请输入邮箱地址');
          }
          email = formData.email;
          metadata = {
            account_type: 'email',
            constellation: formData.constellation,
            constellation_name: constellation?.label,
            constellation_description: constellation?.description
          };
        } else if (loginMethod === 'nebula') {
          // 星云ID注册，使用星座作为邮箱前缀
          if (!formData.nebulaId) {
            throw new Error('请输入星云ID');
          }
          email = `${formData.constellation.toLowerCase()}@example.com`;
          metadata = {
            account_type: 'nebula',
            nebula_id: formData.nebulaId,
            constellation: formData.constellation,
            constellation_name: constellation?.label,
            constellation_description: constellation?.description
          };
        } else if (loginMethod === 'phone') {
          // 手机注册
          if (!formData.phone) {
            throw new Error('请输入手机号码');
          }
          email = `${formData.phone}@phone.example.com`; // 临时邮箱格式
          metadata = {
            account_type: 'phone',
            phone: formData.phone,
            constellation: formData.constellation,
            constellation_name: constellation?.label,
            constellation_description: constellation?.description
          };
        }
        
        await signUp(email, formData.password, metadata);
        
        if (loginMethod === 'email') {
          handleRegisterSuccess('🌟 欢迎加入星云世界！邮箱注册成功，请检查您的邮箱进行验证，即将跳转到登录页面...');
        } else if (loginMethod === 'phone') {
          handleRegisterSuccess('🌟 欢迎加入星云世界！手机注册成功，请注意查收验证信息，即将跳转到登录页面...');
        } else {
          handleRegisterSuccess('🌟 欢迎加入星云世界！星云ID注册成功，请检查邮箱进行验证，即将跳转到登录页面...');
        }
      } else {
        // 登录逻辑
        let loginCredential = '';
        if (loginMethod === 'email') {
          loginCredential = formData.email;
        } else if (loginMethod === 'phone') {
          loginCredential = formData.phone;
        } else if (loginMethod === 'nebula') {
          // 星云账号登录，转换为邮箱格式
          loginCredential = `${formData.nebulaId.toLowerCase()}@example.com`;
        }
        
        if (!loginCredential || !formData.password) {
          throw new Error('请填写完整的登录信息');
        }
        
        // 使用真实的Supabase登录
        if (loginMethod === 'phone') {
          await signInPhone(loginCredential, formData.password);
        } else {
          await signIn(loginCredential, formData.password);
        }
        
        setSuccess('登录成功！欢迎回到星云世界！');
        
        // 登录成功后立即跳转到主页，无需延迟
        navigate('/');
      }
    } catch (err: any) {
      setError(err.message || '操作失败，请稍后重试');
    } finally {
      setIsLoading(false);
    }
  };

  const getLoginPlaceholder = () => {
    switch (loginMethod) {
      case 'email':
        return '请输入邮箱地址';
      case 'phone':
        return '请输入手机号码';
      case 'nebula':
        return '请输入星云账号ID';
      default:
        return '';
    }
  };

  const getLoginValue = () => {
    switch (loginMethod) {
      case 'email':
        return formData.email;
      case 'phone':
        return formData.phone;
      case 'nebula':
        return formData.nebulaId;
      default:
        return '';
    }
  };

  const getLoginInputName = () => {
    switch (loginMethod) {
      case 'email':
        return 'email';
      case 'phone':
        return 'phone';
      case 'nebula':
        return 'nebulaId';
      default:
        return 'email';
    }
  };

  const selectedConstellation = constellations.find(c => c.value === formData.constellation);

  return (
    <div className="min-h-screen pt-20 pb-16 px-4 sm:px-6 lg:px-8 flex items-center justify-center">
      <div className="max-w-md w-full">
        <div className="text-center mb-8">
          <h1 className="text-3xl font-bold text-white mb-2">
            {mode === 'login' ? '登录' : '创建'}
            <span className="bg-gradient-to-r from-blue-400 to-purple-500 bg-clip-text text-transparent ml-2">
              星云账号
            </span>
          </h1>
          <p className="text-gray-300">
            {mode === 'login' ? '使用您的星云账号登录数字宇宙' : '选择您的守护星座，开启数字宇宙之旅'}
          </p>
          
          {/* 模式切换 */}
          <div className="mt-4">
            {mode === 'login' ? (
              <p className="text-sm text-gray-400">
                还没有星云账号？
                <button
                  type="button"
                  onClick={() => switchMode('register')}
                  className="text-blue-400 hover:text-blue-300 ml-1 underline"
                >
                  立即注册
                </button>
              </p>
            ) : (
              <p className="text-sm text-gray-400">
                已有星云账号？
                <button
                  type="button"
                  onClick={() => switchMode('login')}
                  className="text-blue-400 hover:text-blue-300 ml-1 underline"
                >
                  立即登录
                </button>
              </p>
            )}
          </div>
        </div>

        <div className="bg-white/5 backdrop-blur-sm rounded-2xl border border-white/10 p-8">
          {/* 登录方式选择 */}
          {mode === 'login' && (
            <div className="mb-6">
              <label className="block text-sm font-medium text-gray-300 mb-3">
                选择登录方式
              </label>
              <div className="grid grid-cols-3 gap-2">
                <button
                  type="button"
                  onClick={() => setLoginMethod('nebula')}
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
                <button
                  type="button"
                  onClick={() => setLoginMethod('email')}
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
                  onClick={() => setLoginMethod('phone')}
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
              </div>
            </div>
          )}

          <form onSubmit={handleSubmit} className="space-y-6">
            {mode === 'register' ? (
              /* 注册表单 */
              <>
                <div>
                  <label className="block text-sm font-medium text-gray-300 mb-3">
                    选择守护星座 <span className="text-red-400">*</span>
                  </label>
                  <select
                    name="constellation"
                    required
                    value={formData.constellation}
                    onChange={handleInputChange}
                    className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white focus:ring-2 focus:ring-blue-500 appearance-none"
                  >
                    <option value="">请选择您的守护星座</option>
                    {constellations.map(constellation => (
                      <option key={constellation.value} value={constellation.value}>
                        {constellation.label}
                      </option>
                    ))}
                  </select>
                  {selectedConstellation && (
                    <div className="mt-3 p-3 bg-gradient-to-r from-blue-500/10 to-purple-500/10 rounded-lg border border-blue-400/30">
                      <p className="text-sm text-blue-300">
                        ✨ {selectedConstellation.description}
                      </p>
                    </div>
                  )}
                </div>
              </>
            ) : (
              /* 登录表单 */
              <div>
                <label className="block text-sm font-medium text-gray-300 mb-2">
                  {loginMethod === 'email' && '邮箱地址'}
                  {loginMethod === 'phone' && '手机号码'}
                  {loginMethod === 'nebula' && '星云账号ID'}
                  <span className="text-red-400 ml-1">*</span>
                </label>
                <input
                  type={loginMethod === 'email' ? 'email' : loginMethod === 'phone' ? 'tel' : 'text'}
                  name={getLoginInputName()}
                  required
                  value={getLoginValue()}
                  onChange={handleInputChange}
                  className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                  placeholder={getLoginPlaceholder()}
                />
              </div>
            )}

            <div>
              <label className="block text-sm font-medium text-gray-300 mb-2">
                {mode === 'register' ? '设置星云密钥' : '星云密钥'} <span className="text-red-400">*</span>
              </label>
              <input
                type="password"
                name="password"
                required
                minLength={mode === 'register' ? 8 : 1}
                value={formData.password}
                onChange={handleInputChange}
                className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                placeholder={mode === 'register' ? '请设置您的星云密钥（至少8位）' : '请输入您的星云密钥'}
              />
            </div>

            {mode === 'register' && (
              <div>
                <label className="block text-sm font-medium text-gray-300 mb-2">
                  确认星云密钥 <span className="text-red-400">*</span>
                </label>
                <input
                  type="password"
                  name="confirmPassword"
                  required
                  value={formData.confirmPassword}
                  onChange={handleInputChange}
                  className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                  placeholder="请再次输入星云密钥"
                />
              </div>
            )}

            {/* 错误和成功消息 */}
            {error && (
              <div className="p-4 bg-red-500/10 border border-red-400/30 rounded-lg">
                <p className="text-sm text-red-300">{error}</p>
              </div>
            )}
            
            {success && (
              <div className="p-4 bg-green-500/10 border border-green-400/30 rounded-lg">
                <p className="text-sm text-green-300">{success}</p>
              </div>
            )}

            <button
              type="submit"
              disabled={isLoading}
              className="w-full bg-gradient-to-r from-blue-600 to-purple-600 hover:from-blue-700 hover:to-purple-700 disabled:opacity-50 disabled:cursor-not-allowed text-white font-semibold py-3 px-6 rounded-lg transition-all duration-200 transform hover:scale-105"
            >
              {isLoading ? (
                <>
                  <span className="inline-block animate-spin mr-2">⭐</span>
                  {mode === 'login' ? '登录中...' : '创建中...'}
                </>
              ) : (
                mode === 'login' ? '登录星云世界' : '创建星云账号'
              )}
            </button>
            
            {mode === 'login' && (
              <div className="text-center">
                <button
                  type="button"
                  className="text-sm text-blue-400 hover:text-blue-300 underline"
                >
                  忘记星云密钥？
                </button>
              </div>
            )}
          </form>
        </div>
      </div>
    </div>
  );
};

export default AuthPage;
