/**
 * SecureAuthPage - 完全重构的安全认证页面
 * 这是一个全新的架构，使用我们的DOM安全基础设施，彻底解决DOM竞态条件问题
 */
import React, { useState, useCallback, useEffect } from 'react';
import { useSearchParams, useNavigate, useLocation } from 'react-router-dom';
import { useAuth } from '../contexts/AuthContext';
import useSafeComponent from '../hooks/useSafeComponent';
import useFormValidation from '../hooks/useFormValidation';
import SafeForm from '../components/SafeForm';
import SafeErrorBoundary from '../components/SafeErrorBoundary';
import { generateNebulaId } from '../lib/utils';
import {
  beginNebulaOAuth,
  consumePostAuthRedirect,
  rememberPostAuthRedirect,
  isNebulaOAuthConfigured,
  sanitizePostAuthRedirect,
  updateCurrentUserMetadata,
  upsertCurrentUserProfile
} from '../lib/supabase';

type AuthMode = 'login' | 'register';
type LoginMethod = 'email' | 'phone' | 'nebula';
type RegisterMethod = 'email' | 'constellation' | 'phone';

interface FormData {
  constellation: string;
  email: string;
  phone: string;
  nebulaId: string;
  fullName: string;
  verificationCode: string;
  password: string;
  confirmPassword: string;
}

const INITIAL_FORM_DATA: FormData = {
  constellation: '',
  email: '',
  phone: '',
  nebulaId: '',
  fullName: '',
  verificationCode: '',
  password: '',
  confirmPassword: ''
};

const WEBSITE_REGISTRATION_SOURCE = 'SkyBridge Compass Website';

const SecureAuthPage: React.FC = () => {
  const [searchParams, setSearchParams] = useSearchParams();
  const navigate = useNavigate();
  const location = useLocation();
  const { signIn, signInNebula, signUp, sendOTP, verifyOTP } = useAuth();
  
  // 使用安全组件Hook
  const { 
    safeSetState, 
    safeAsyncOperation, 
    safeSetTimeout, 
    withSubmitProtection,
    isMounted
  } = useSafeComponent();

  // 表单验证
  const { 
    errors, 
    handleFieldChange, 
    validateForSubmit, 
    clearAllErrors,
    setFieldError
  } = useFormValidation({});

  // 状态管理
  const [mode, setMode] = useState<AuthMode>(() => {
    if (location.pathname === '/register') {
      return 'register';
    }
    return (searchParams.get('mode') as AuthMode) || 'login';
  });
  const [loginMethod, setLoginMethod] = useState<LoginMethod>('email');
  const [registerMethod, setRegisterMethod] = useState<RegisterMethod>('email');
  const [formData, setFormData] = useState<FormData>(INITIAL_FORM_DATA);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [phoneOtpSent, setPhoneOtpSent] = useState(false);
  const [phoneOtpCountdown, setPhoneOtpCountdown] = useState(0);
  const nebulaOAuthConfigured = isNebulaOAuthConfigured();
  const redirectAfterAuth = sanitizePostAuthRedirect(searchParams.get('redirect'));
  const usesPhoneOtp = (mode === 'login' && loginMethod === 'phone') || (mode === 'register' && registerMethod === 'phone');
  const usesNebulaBrowserAuth = mode === 'login' && loginMethod === 'nebula' && nebulaOAuthConfigured;
  const requiresPassword = !usesPhoneOtp && !usesNebulaBrowserAuth;

  useEffect(() => {
    if (phoneOtpCountdown <= 0) {
      return;
    }

    const timer = window.setTimeout(() => {
      setPhoneOtpCountdown(previous => Math.max(previous - 1, 0));
    }, 1000);

    return () => window.clearTimeout(timer);
  }, [phoneOtpCountdown]);

  useEffect(() => {
    const nextMode: AuthMode =
      location.pathname === '/register'
        ? 'register'
        : ((searchParams.get('mode') as AuthMode) || 'login');

    setMode(nextMode);
  }, [location.pathname, searchParams]);

  useEffect(() => {
    const callbackError = searchParams.get('error');

    if (callbackError) {
      safeSetState(setError, callbackError);
    }
  }, [searchParams, safeSetState]);

  useEffect(() => {
    if (redirectAfterAuth) {
      rememberPostAuthRedirect(redirectAfterAuth);
    }
  }, [redirectAfterAuth]);

  // 星座数据
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

  const resetPhoneOtpState = useCallback(() => {
    safeSetState(setPhoneOtpSent, false);
    safeSetState(setPhoneOtpCountdown, 0);
  }, [safeSetState]);

  const resetTransientAuthState = useCallback(() => {
    safeSetState(setIsLoading, false);
    safeSetState(setError, '');
    safeSetState(setSuccess, '');
    resetPhoneOtpState();
    clearAllErrors();
  }, [safeSetState, resetPhoneOtpState, clearAllErrors]);

  // 安全的模式切换
  const switchMode = useCallback((newMode: AuthMode) => {
    if (!isMounted()) {
      return;
    }
    
    safeSetState(setMode, newMode);
    safeSetState(setFormData, INITIAL_FORM_DATA);
    resetTransientAuthState();
    
    const nextParams = new URLSearchParams({ mode: newMode });
    if (redirectAfterAuth) {
      nextParams.set('redirect', redirectAfterAuth);
    }

    navigate(`/auth?${nextParams.toString()}`, { replace: true });
    setSearchParams(nextParams);
  }, [isMounted, safeSetState, resetTransientAuthState, navigate, setSearchParams, redirectAfterAuth]);

  const selectLoginMethod = useCallback((method: LoginMethod) => {
    if (!isMounted()) {
      return;
    }

    resetTransientAuthState();
    safeSetState(setLoginMethod, method);
  }, [isMounted, resetTransientAuthState, safeSetState]);

  const selectRegisterMethod = useCallback((method: RegisterMethod) => {
    if (!isMounted()) {
      return;
    }

    resetTransientAuthState();
    safeSetState(setRegisterMethod, method);
  }, [isMounted, resetTransientAuthState, safeSetState]);

  // 安全的输入处理
  const handleInputChange = useCallback((e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
    if (!isMounted()) {
      return;
    }

    const { name, value } = e.target;
    
    // 更新表单数据
    safeSetState(setFormData, prev => ({
      ...prev,
      [name]: value
    }));

    // 实时验证
    if (name === 'nebulaId' || name === 'email' || name === 'phone' || name === 'password') {
      handleFieldChange(name, value);
    }
    
    // 清除一般错误信息
    safeSetState(setError, '');
    safeSetState(setSuccess, '');
  }, [isMounted, safeSetState, handleFieldChange]);

  const syncWebsiteProfile = useCallback(async (profileData: Record<string, unknown>, metadata: Record<string, unknown>) => {
    await updateCurrentUserMetadata(metadata);
    await upsertCurrentUserProfile(profileData);
  }, []);

  const handleNebulaBrowserAuth = useCallback(async (flow: AuthMode) => {
    if (!isMounted()) {
      return;
    }

    safeSetState(setError, '');
    safeSetState(setSuccess, flow === 'login' ? '正在前往 Nebula 授权中心...' : '正在前往 Nebula 注册中心...');
    safeSetState(setIsLoading, true);

    try {
      rememberPostAuthRedirect(redirectAfterAuth);
      await beginNebulaOAuth(flow);
    } catch (err: any) {
      if (isMounted()) {
        safeSetState(setIsLoading, false);
        safeSetState(setSuccess, '');
        safeSetState(setError, err?.message || 'Nebula 授权启动失败');
      }
    }
  }, [isMounted, safeSetState, redirectAfterAuth]);

  const handleSendPhoneOtp = useCallback(async () => {
    if (!isMounted()) {
      return;
    }

    const normalizedPhone = formData.phone.trim();
    if (!/^1[3-9]\d{9}$/.test(normalizedPhone)) {
      safeSetState(setError, '请输入有效的中国大陆手机号码');
      return;
    }

    if (mode === 'register' && !formData.email.trim()) {
      safeSetState(setError, '请输入邮箱地址，用于跨端资料同步');
      return;
    }

    safeSetState(setIsLoading, true);
    safeSetState(setError, '');
    safeSetState(setSuccess, '');

    try {
      await sendOTP(normalizedPhone);
      if (!isMounted()) {
        return;
      }

      safeSetState(setPhoneOtpSent, true);
      safeSetState(setPhoneOtpCountdown, 60);
      safeSetState(setSuccess, '短信验证码已发送，请注意查收');
    } catch (err: any) {
      if (isMounted()) {
        safeSetState(setError, err.message || '短信验证码发送失败');
      }
    } finally {
      if (isMounted()) {
        safeSetState(setIsLoading, false);
      }
    }
  }, [formData.phone, formData.email, mode, isMounted, safeSetState, sendOTP]);

  // 注册成功后的处理
  const handleRegisterSuccess = useCallback((message: string) => {
    if (!isMounted()) return;
    
    safeSetState(setSuccess, message);
    
    // 使用安全定时器延迟切换到登录模式
    safeSetTimeout(() => {
      if (isMounted()) {
        switchMode('login');
        safeSetState(setSuccess, '');
        safeSetState(setError, '请使用您刚才注册的账户登录');
      }
    }, 3000);
  }, [isMounted, safeSetState, safeSetTimeout, switchMode]);

  // 登录成功后的安全导航
  const handleLoginSuccess = useCallback(() => {
    if (!isMounted()) return;

    safeSetState(setSuccess, '登录成功！正在跳转...');
    const nextLocation = redirectAfterAuth || consumePostAuthRedirect() || '/';
    rememberPostAuthRedirect(null);
    
    // 使用安全定时器进行导航
    safeSetTimeout(() => {
      if (isMounted()) {
        try {
          navigate(nextLocation, { replace: true });
        } catch (navError) {
          console.error('Navigation error:', navError);
          safeSetState(setError, '登录成功！请点击首页按钮或刷新页面');
        }
      }
    }, 1000); // 稳定的延迟时间
  }, [isMounted, safeSetState, safeSetTimeout, navigate, redirectAfterAuth]);

  // 主表单提交处理
  const handleSubmit = useCallback(async () => {
    if (!isMounted()) {
      return;
    }

    if (mode === 'login' && loginMethod === 'nebula' && nebulaOAuthConfigured) {
      await handleNebulaBrowserAuth('login');
      return;
    }

    const formDataForValidation: Record<string, string> = {};

    if (mode === 'login') {
      if (loginMethod === 'email') {
        formDataForValidation.email = formData.email;
        formDataForValidation.password = formData.password;
      } else if (loginMethod === 'phone') {
        formDataForValidation.phone = formData.phone;
      } else {
        formDataForValidation.nebulaId = formData.nebulaId;
        formDataForValidation.password = formData.password;
      }
    } else if (registerMethod === 'email') {
      formDataForValidation.email = formData.email;
      formDataForValidation.password = formData.password;
      formDataForValidation.confirmPassword = formData.confirmPassword;
    } else if (registerMethod === 'phone') {
      formDataForValidation.phone = formData.phone;
      formDataForValidation.email = formData.email;
    } else {
      formDataForValidation.constellation = formData.constellation;
      formDataForValidation.email = formData.email;
      formDataForValidation.password = formData.password;
      formDataForValidation.confirmPassword = formData.confirmPassword;
    }
    
    if (!validateForSubmit(formDataForValidation)) {
      return;
    }

    safeSetState(setError, '');
    safeSetState(setSuccess, '');
    safeSetState(setIsLoading, true);

    try {
      if (mode === 'register') {
        await handleRegisterFlow();
      } else {
        await handleLoginFlow();
      }
    } catch (err: any) {
      console.error('SecureAuthPage: Submit error:', err);
      safeSetState(setError, err.message || '操作失败，请稍后重试');
    } finally {
      if (isMounted()) {
        safeSetState(setIsLoading, false);
      }
    }
  }, [isMounted, safeSetState, validateForSubmit, formData, mode, loginMethod, registerMethod, nebulaOAuthConfigured, handleNebulaBrowserAuth]);

  // 注册流程处理
  const handleRegisterFlow = useCallback(async () => {
    const normalizedEmail = formData.email.trim().toLowerCase();
    const normalizedPhone = formData.phone.trim();
    const displayName = formData.fullName.trim() || normalizedEmail.split('@')[0] || '用户';

    if (registerMethod === 'phone') {
      if (!normalizedPhone) {
        throw new Error('请输入手机号码');
      }

      if (!phoneOtpSent) {
        throw new Error('请先发送短信验证码');
      }

      if (!formData.verificationCode.trim()) {
        throw new Error('请输入短信验证码');
      }

      if (!normalizedEmail) {
        throw new Error('请输入邮箱地址，用于跨端资料同步');
      }

      const verificationResult = await verifyOTP(normalizedPhone, formData.verificationCode.trim());
      const phoneNebulaId = generateNebulaId();
      const phoneMetadata = {
        account_type: 'phone',
        display_name: displayName,
        registration_source: WEBSITE_REGISTRATION_SOURCE,
        nebula_id: phoneNebulaId,
        full_name: formData.fullName.trim() || null
      };

      await syncWebsiteProfile(
        {
          email: normalizedEmail,
          phone: normalizedPhone,
          full_name: formData.fullName.trim() || null,
          nebula_id: phoneNebulaId,
          account_type: 'phone'
        },
        phoneMetadata
      );

      resetPhoneOtpState();
      handleRegisterSuccess(`手机注册成功！您的 Nebula ID 是：${phoneNebulaId}`);
      return verificationResult;
    }

    if (formData.password !== formData.confirmPassword) {
      throw new Error('星云密钥确认不匹配，请重新输入');
    }

    if (formData.password.length < 8) {
      throw new Error('星云密钥长度不能少于8位');
    }

    let email = '';
    let metadata: Record<string, unknown> = {};
    let profileData: Record<string, unknown> = {};
    const nebulaId = generateNebulaId();

    if (registerMethod === 'constellation') {
      if (!formData.constellation) {
        throw new Error('请选择您的守护星座');
      }

      if (!normalizedEmail) {
        throw new Error('请输入邮箱地址用于接收验证邮件');
      }

      const constellation = constellations.find(c => c.value === formData.constellation);
      email = normalizedEmail;
      metadata = {
        account_type: 'constellation',
        display_name: displayName,
        registration_source: WEBSITE_REGISTRATION_SOURCE,
        nebula_id: nebulaId,
        constellation: formData.constellation,
        constellation_name: constellation?.label,
        constellation_description: constellation?.description,
        full_name: formData.fullName.trim() || null
      };
      profileData = {
        email,
        account_type: 'constellation',
        nebula_id: nebulaId,
        constellation: formData.constellation,
        constellation_name: constellation?.label,
        constellation_description: constellation?.description,
        full_name: formData.fullName.trim() || null
      };
    } else {
      if (!normalizedEmail) {
        throw new Error('请输入邮箱地址');
      }

      email = normalizedEmail;
      metadata = {
        account_type: 'email',
        display_name: displayName,
        registration_source: WEBSITE_REGISTRATION_SOURCE,
        nebula_id: nebulaId,
        full_name: formData.fullName.trim() || null
      };
      profileData = {
        email,
        account_type: 'email',
        nebula_id: nebulaId,
        full_name: formData.fullName.trim() || null
      };
    }

    const authResult = await signUp(email, formData.password, metadata);

    if (authResult.session) {
      await syncWebsiteProfile(profileData, metadata);
    }

    if (isMounted()) {
      const successMessage =
        registerMethod === 'constellation'
          ? `欢迎加入星云世界！您的 Nebula ID 是：${nebulaId}，请检查邮箱完成验证。`
          : `注册成功！您的 Nebula ID 是：${nebulaId}，请检查邮箱完成验证。`;
      handleRegisterSuccess(successMessage);
    }
  }, [formData, registerMethod, constellations, signUp, verifyOTP, phoneOtpSent, isMounted, handleRegisterSuccess, resetPhoneOtpState, syncWebsiteProfile]);

  // 登录流程处理
  const handleLoginFlow = useCallback(async () => {
    if (loginMethod === 'phone') {
      if (!phoneOtpSent) {
        throw new Error('请先发送短信验证码');
      }

      if (!formData.verificationCode.trim()) {
        throw new Error('请输入短信验证码');
      }

      await verifyOTP(formData.phone.trim(), formData.verificationCode.trim());
      resetPhoneOtpState();
    } else {
      if (!formData.password) {
        throw new Error('请填写完整的登录信息');
      }

      if (loginMethod === 'nebula') {
        await signInNebula(formData.nebulaId, formData.password);
      } else {
        await signIn(formData.email, formData.password);
      }
    }

    // 登录成功处理
    if (isMounted()) {
      handleLoginSuccess();
    }
  }, [formData, loginMethod, phoneOtpSent, signIn, signInNebula, verifyOTP, resetPhoneOtpState, isMounted, handleLoginSuccess]);

  // 获取登录输入框的相关信息
  const getLoginInfo = useCallback(() => {
    switch (loginMethod) {
      case 'email':
        return {
          placeholder: '请输入邮箱地址',
          value: formData.email,
          name: 'email',
          type: 'email'
        };
      case 'phone':
        return {
          placeholder: '请输入手机号码',
          value: formData.phone,
          name: 'phone',
          type: 'tel'
        };
      case 'nebula':
        return {
          placeholder: '请输入星云账号ID',
          value: formData.nebulaId,
          name: 'nebulaId',
          type: 'text'
        };
      default:
        return {
          placeholder: '',
          value: '',
          name: 'email',
          type: 'text'
        };
    }
  }, [loginMethod, formData]);

  const selectedConstellation = constellations.find(c => c.value === formData.constellation);
  const loginInfo = getLoginInfo();

  return (
    <SafeErrorBoundary>
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

          <div className="apple-glass-panel apple-glass-sheen p-8">
            {mode === 'register' && nebulaOAuthConfigured && (
              <div className="mb-6 apple-glass-panel-strong apple-glass-sheen p-4">
                <p className="text-sm font-medium text-cyan-100">
                  已接入 Nebula 浏览器授权
                </p>
                <p className="mt-2 text-sm text-cyan-50/80">
                  这条路径与 macOS/iOS 的 Nebula PKCE 流程一致，会在浏览器内完成登录或注册，再把会话带回当前网站。
                </p>
                <button
                  type="button"
                  onClick={() => void handleNebulaBrowserAuth('register')}
                  disabled={isLoading}
                  className="mt-4 w-full apple-glass-cta apple-glass-sheen bg-cyan-400/15 text-sm text-cyan-100 hover:bg-cyan-400/25 disabled:cursor-not-allowed disabled:opacity-60"
                >
                  使用 Nebula 浏览器注册
                </button>
              </div>
            )}

            {/* 登录方式选择 */}
            {mode === 'login' && (
              <div className="mb-6">
                <label className="block text-sm font-medium text-gray-300 mb-3">
                  选择登录方式
                </label>
                <div className="grid grid-cols-3 gap-2">
                      <button
                        type="button"
                        onClick={() => selectLoginMethod('nebula')}
                    className={`p-3 rounded-lg text-sm font-medium transition-all ${
                      loginMethod === 'nebula'
                        ? 'apple-glass-panel-strong text-white'
                        : 'apple-glass-field text-gray-300 hover:bg-white/20'
                    }`}
                  >
                    <div className="flex flex-col items-center">
                      <div className="h-3 w-3 rounded-full bg-gradient-to-r from-blue-400 to-purple-500 mb-1" />
                      <span>星云</span>
                    </div>
                  </button>
                      <button
                        type="button"
                        onClick={() => selectLoginMethod('email')}
                    className={`p-3 rounded-lg text-sm font-medium transition-all ${
                      loginMethod === 'email'
                        ? 'apple-glass-panel-strong text-white'
                        : 'apple-glass-field text-gray-300 hover:bg-white/20'
                    }`}
                  >
                    <div className="flex flex-col items-center">
                      <span className="text-lg mb-1">📧</span>
                      <span>邮箱</span>
                    </div>
                  </button>
                      <button
                        type="button"
                        onClick={() => selectLoginMethod('phone')}
                    className={`p-3 rounded-lg text-sm font-medium transition-all ${
                      loginMethod === 'phone'
                        ? 'apple-glass-panel-strong text-white'
                        : 'apple-glass-field text-gray-300 hover:bg-white/20'
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

            <SafeForm onSubmit={handleSubmit}>
              {mode === 'register' ? (
                /* 注册表单 */
                <>
                  {/* 注册方法选择器 */}
                  <div className="mb-6">
                    <label className="block text-sm font-medium text-gray-300 mb-3">
                      选择注册方式
                    </label>
                    <div className="grid grid-cols-3 gap-2">
                      <button
                        type="button"
                        onClick={() => selectRegisterMethod('email')}
                        className={`p-3 rounded-lg text-sm font-medium transition-all ${
                          registerMethod === 'email'
                            ? 'apple-glass-panel-strong text-white'
                            : 'apple-glass-field text-gray-300 hover:bg-white/20'
                        }`}
                      >
                        <div className="flex flex-col items-center">
                          <span className="text-lg mb-1">📧</span>
                          <span>邮箱注册</span>
                        </div>
                      </button>
                      <button
                        type="button"
                        onClick={() => selectRegisterMethod('phone')}
                        className={`p-3 rounded-lg text-sm font-medium transition-all ${
                          registerMethod === 'phone'
                            ? 'apple-glass-panel-strong text-white'
                            : 'apple-glass-field text-gray-300 hover:bg-white/20'
                        }`}
                      >
                        <div className="flex flex-col items-center">
                          <span className="text-lg mb-1">📱</span>
                          <span>手机注册</span>
                        </div>
                      </button>
                      <button
                        type="button"
                        onClick={() => selectRegisterMethod('constellation')}
                        className={`p-3 rounded-lg text-sm font-medium transition-all ${
                          registerMethod === 'constellation'
                            ? 'apple-glass-panel-strong text-white'
                            : 'apple-glass-field text-gray-300 hover:bg-white/20'
                        }`}
                      >
                        <div className="flex flex-col items-center">
                          <span className="text-lg mb-1">🌟</span>
                          <span>星座注册</span>
                        </div>
                      </button>
                    </div>
                  </div>

                  {registerMethod === 'constellation' ? (
                    <>
                      <div className="mb-6">
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
                          <div className="mt-3 apple-glass-panel-strong apple-glass-sheen p-3 rounded-lg">
                            <p className="text-sm text-blue-300">
                              ✨ {selectedConstellation.description}
                            </p>
                            <p className="text-xs text-gray-400 mt-1">
                              系统将为您生成独特的星云ID，您可以使用邮箱或星云ID登录
                            </p>
                          </div>
                        )}
                      </div>
                      <div className="mb-6">
                        <label htmlFor="email" className="block text-sm font-medium text-gray-300 mb-2">
                          邮箱地址 <span className="text-red-400">*</span>
                        </label>
                        <input
                          type="email"
                          id="email"
                          name="email"
                          required
                          value={formData.email}
                          onChange={handleInputChange}
                          placeholder="请输入您的邮箱地址用于接收验证邮件（支持QQ、163、Gmail等）"
                          className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                        />
                      </div>
                    </>
                  ) : registerMethod === 'phone' ? (
                    <>
                      <div className="mb-6">
                        <label htmlFor="fullName" className="block text-sm font-medium text-gray-300 mb-2">
                          显示名称 <span className="text-red-400">*</span>
                        </label>
                        <input
                          type="text"
                          id="fullName"
                          name="fullName"
                          required
                          value={formData.fullName}
                          onChange={handleInputChange}
                          placeholder="请输入您的显示名称"
                          className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                        />
                      </div>
                      <div className="mb-6">
                        <label htmlFor="email" className="block text-sm font-medium text-gray-300 mb-2">
                          邮箱地址 <span className="text-red-400">*</span>
                        </label>
                        <input
                          type="email"
                          id="email"
                          name="email"
                          required
                          value={formData.email}
                          onChange={handleInputChange}
                          placeholder="请输入您的邮箱地址，用于跨端资料同步"
                          className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                        />
                      </div>
                      <div className="mb-6">
                        <label htmlFor="phone" className="block text-sm font-medium text-gray-300 mb-2">
                          手机号码 <span className="text-red-400">*</span>
                        </label>
                        <input
                          type="tel"
                          id="phone"
                          name="phone"
                          required
                          value={formData.phone}
                          onChange={handleInputChange}
                          placeholder="请输入您的手机号码（支持中国大陆手机号）"
                          className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                        />
                      </div>
                      <div className="mb-6">
                        <label htmlFor="verificationCode" className="block text-sm font-medium text-gray-300 mb-2">
                          短信验证码 <span className="text-red-400">*</span>
                        </label>
                        <div className="flex gap-3">
                          <input
                            type="text"
                            id="verificationCode"
                            name="verificationCode"
                            required
                            value={formData.verificationCode}
                            onChange={handleInputChange}
                            placeholder="请输入短信验证码"
                            className="flex-1 px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                          />
                          <button
                            type="button"
                            onClick={handleSendPhoneOtp}
                            disabled={isLoading || phoneOtpCountdown > 0}
                            className="whitespace-nowrap rounded-lg border border-blue-400/40 px-4 py-3 text-sm font-medium text-blue-200 transition hover:bg-blue-500/10 disabled:cursor-not-allowed disabled:opacity-50"
                          >
                            {phoneOtpCountdown > 0 ? `${phoneOtpCountdown}s` : phoneOtpSent ? '重新发送' : '发送验证码'}
                          </button>
                        </div>
                      </div>
                    </>
                  ) : (
                    <>
                      <div className="mb-6">
                        <label htmlFor="fullName" className="block text-sm font-medium text-gray-300 mb-2">
                          显示名称
                        </label>
                        <input
                          type="text"
                          id="fullName"
                          name="fullName"
                          value={formData.fullName}
                          onChange={handleInputChange}
                          placeholder="请输入您的显示名称（可选）"
                          className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                        />
                      </div>
                      <div className="mb-6">
                        <label htmlFor="email" className="block text-sm font-medium text-gray-300 mb-2">
                          邮箱地址 <span className="text-red-400">*</span>
                        </label>
                        <input
                          type="email"
                          id="email"
                          name="email"
                          required
                          value={formData.email}
                          onChange={handleInputChange}
                          placeholder="请输入您的邮箱地址（支持QQ、163、Gmail等）"
                          className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                        />
                      </div>
                    </>
                  )}
                </>
              ) : (
                /* 登录表单 */
                loginMethod === 'phone' ? (
                  <>
                    <div className="mb-6">
                      <label className="block text-sm font-medium text-gray-300 mb-2">
                        手机号码 <span className="text-red-400 ml-1">*</span>
                      </label>
                      <input
                        type="tel"
                        name="phone"
                        required
                        value={formData.phone}
                        onChange={handleInputChange}
                        className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                        placeholder="请输入已注册的手机号码"
                      />
                    </div>
                    <div className="mb-6">
                      <label className="block text-sm font-medium text-gray-300 mb-2">
                        短信验证码 <span className="text-red-400 ml-1">*</span>
                      </label>
                      <div className="flex gap-3">
                        <input
                          type="text"
                          name="verificationCode"
                          required
                          value={formData.verificationCode}
                          onChange={handleInputChange}
                          className="flex-1 px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                          placeholder="请输入短信验证码"
                        />
                        <button
                          type="button"
                          onClick={handleSendPhoneOtp}
                          disabled={isLoading || phoneOtpCountdown > 0}
                          className="whitespace-nowrap rounded-lg border border-blue-400/40 px-4 py-3 text-sm font-medium text-blue-200 transition hover:bg-blue-500/10 disabled:cursor-not-allowed disabled:opacity-50"
                        >
                          {phoneOtpCountdown > 0 ? `${phoneOtpCountdown}s` : phoneOtpSent ? '重新发送' : '发送验证码'}
                        </button>
                      </div>
                    </div>
                  </>
                ) : (
                  usesNebulaBrowserAuth ? (
                    <div className="mb-6 rounded-xl border border-blue-400/30 bg-blue-500/10 p-4">
                      <p className="text-sm font-medium text-blue-100">
                        Nebula 企业登录已切换为浏览器授权
                      </p>
                      <p className="mt-2 text-sm text-blue-50/80">
                        点击下方按钮后，将跳转到 Nebula 授权页，并按与 macOS/iOS 一致的 PKCE 流程完成登录。
                      </p>
                    </div>
                  ) : (
                    <div className="mb-6">
                      <label className="block text-sm font-medium text-gray-300 mb-2">
                        {loginMethod === 'email' && '邮箱地址'}
                        {loginMethod === 'nebula' && '星云账号ID'}
                        <span className="text-red-400 ml-1">*</span>
                      </label>
                      <input
                        type={loginInfo.type}
                        name={loginInfo.name}
                        required
                        value={loginInfo.value}
                        onChange={handleInputChange}
                        pattern={loginMethod === 'nebula' ? '[a-zA-Z0-9_-]+' : undefined}
                        minLength={loginMethod === 'nebula' ? 3 : undefined}
                        maxLength={loginMethod === 'nebula' ? 30 : undefined}
                        className="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                        placeholder={loginInfo.placeholder}
                        title={loginMethod === 'nebula' ? '星云ID只能包含字母、数字、下划线和连字符，长度在3-30个字符之间' : undefined}
                      />
                    </div>
                  )
                )
              )}

              {requiresPassword && (
                <div className="mb-6">
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
              )}

              {mode === 'register' && registerMethod !== 'phone' && (
                <div className="mb-6">
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

              {/* 验证错误显示 */}
              {Object.entries(errors).map(([field, message]) => (
                <div key={field} className="mb-4 p-4 bg-red-500/10 border border-red-400/30 rounded-lg">
                  <p className="text-sm text-red-300">{message}</p>
                </div>
              ))}

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
                  mode === 'login'
                    ? (loginMethod === 'phone' ? '验证并登录' : usesNebulaBrowserAuth ? '前往 Nebula 授权' : '登录星云世界')
                    : (registerMethod === 'phone' ? '验证并创建账号' : '创建星云账号')
                )}
              </button>
              
              {mode === 'login' && (
                <div className="text-center mt-4">
                  <button
                    type="button"
                    className="text-sm text-blue-400 hover:text-blue-300 underline"
                  >
                    忘记星云密钥？
                  </button>
                </div>
              )}
            </SafeForm>
          </div>
        </div>
      </div>
    </SafeErrorBoundary>
  );
};

export default SecureAuthPage;
