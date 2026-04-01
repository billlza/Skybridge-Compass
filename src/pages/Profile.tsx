import React, { useState, useEffect, useCallback, useRef } from 'react';
import { useAuth } from '../contexts/AuthContext';
import { useNavigate } from 'react-router-dom';
import { 
  getUserProfile, 
  updateUserCustomId, 
  checkUserIdAvailability 
} from '../lib/supabase';
import AccountBindingV2 from '../components/AccountBindingV2';
import { getPreferredNebulaId } from '../lib/userDisplay';

interface UserProfile {
  id: string;
  email: string;
  custom_user_id: string | null;
  nebula_id: string | null;
  constellation: string | null;
  constellation_name: string | null;
  constellation_description: string | null;
  account_type: string;
  phone: string | null;
  full_name: string | null;
  avatar_url: string | null;
  created_at: string;
  updated_at: string;
}

interface ValidationResult {
  isValid: boolean;
  isAvailable?: boolean;
  message: string;
}

const Profile: React.FC = () => {
  const { user, loading: authLoading, refreshProfile } = useAuth();
  const navigate = useNavigate();
  const isMountedRef = useRef(true);
  const checkTimeoutRef = useRef<NodeJS.Timeout | null>(null);
  
  const [profile, setProfile] = useState<UserProfile | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  
  // 用户ID修改相关状态
  const [isEditingId, setIsEditingId] = useState(false);
  const [newUserId, setNewUserId] = useState('');
  const [userIdValidation, setUserIdValidation] = useState<ValidationResult>({
    isValid: false,
    message: ''
  });
  const [isSavingId, setIsSavingId] = useState(false);
  const [isCheckingId, setIsCheckingId] = useState(false);
  const displayedNebulaId = getPreferredNebulaId(user, profile);

  // 加载用户资料
  const loadUserProfile = useCallback(async () => {
    if (!user || !isMountedRef.current) return;
    
    try {
      setLoading(true);
      setError('');
      
      const profileData = await getUserProfile();
      
      if (isMountedRef.current) {
        setProfile(profileData);
        setNewUserId(profileData.custom_user_id || '');
      }
    } catch (err: any) {
      if (isMountedRef.current) {
        setError(err.message || '加载用户资料失败');
      }
    } finally {
      if (isMountedRef.current) {
        setLoading(false);
      }
    }
  }, [user]);

  // 验证用户ID格式
  const validateUserIdFormat = useCallback((userId: string): ValidationResult => {
    if (!userId) {
      return { isValid: false, message: '用户ID不能为空' };
    }
    
    if (userId.length < 3) {
      return { isValid: false, message: '用户ID至少需要3个字符' };
    }
    
    if (userId.length > 30) {
      return { isValid: false, message: '用户ID不能超过30个字符' };
    }
    
    const userIdRegex = /^[a-zA-Z0-9_\u4e00-\u9fff-]+$/;
    if (!userIdRegex.test(userId)) {
      return { isValid: false, message: '用户ID只能包含字母、数字、汉字、下划线和连字符' };
    }
    
    return { isValid: true, message: '格式正确' };
  }, []);

  // 检查用户ID可用性
  const checkIdAvailability = useCallback(async (userId: string) => {
    if (!isMountedRef.current) return;
    
    // 首先验证格式
    const formatValidation = validateUserIdFormat(userId);
    if (!formatValidation.isValid) {
      setUserIdValidation(formatValidation);
      return;
    }
    
    // 如果是当前ID，跳过检查
    if (userId === profile?.custom_user_id) {
      setUserIdValidation({ 
        isValid: true, 
        isAvailable: true, 
        message: '这是您当前的用户ID' 
      });
      return;
    }
    
    try {
      setIsCheckingId(true);
      const result = await checkUserIdAvailability(userId);
      
      if (isMountedRef.current) {
        setUserIdValidation({
          isValid: result.available,
          isAvailable: result.available,
          message: result.reason
        });
      }
    } catch (err: any) {
      if (isMountedRef.current) {
        setUserIdValidation({
          isValid: false,
          isAvailable: false,
          message: err.message || '检查用户ID可用性失败'
        });
      }
    } finally {
      if (isMountedRef.current) {
        setIsCheckingId(false);
      }
    }
  }, [profile?.custom_user_id, validateUserIdFormat]);

  // 处理用户ID输入变化
  const handleUserIdChange = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    if (!isMountedRef.current) return;
    
    const value = e.target.value;
    setNewUserId(value);
    setSuccess('');
    setError('');
    
    // 清除之前的检查定时器
    if (checkTimeoutRef.current) {
      clearTimeout(checkTimeoutRef.current);
    }
    
    // 防抖：500ms后检查可用性
    checkTimeoutRef.current = setTimeout(() => {
      if (isMountedRef.current && value.trim()) {
        checkIdAvailability(value.trim());
      }
    }, 500);
  }, [checkIdAvailability]);

  // 保存用户ID
  const handleSaveUserId = useCallback(async () => {
    if (!isMountedRef.current || !newUserId.trim()) return;
    
    try {
      setIsSavingId(true);
      setError('');
      setSuccess('');
      
      const result = await updateUserCustomId(newUserId.trim());
      
      if (isMountedRef.current) {
        setSuccess('用户ID更新成功！');
        setIsEditingId(false);
        
        // 重新加载用户资料
        loadUserProfile();
        
        // 刷新AuthContext中的全局用户状态，确保主页等其他页面显示最新信息
        refreshProfile();
      }
    } catch (err: any) {
      if (isMountedRef.current) {
        setError(err.message || '更新用户ID失败');
      }
    } finally {
      if (isMountedRef.current) {
        setIsSavingId(false);
      }
    }
  }, [newUserId, loadUserProfile, refreshProfile]);

  // 取消编辑
  const handleCancelEdit = useCallback(() => {
    if (!isMountedRef.current) return;
    
    setIsEditingId(false);
    setNewUserId(profile?.custom_user_id || '');
    setUserIdValidation({ isValid: false, message: '' });
    setError('');
    setSuccess('');
  }, [profile?.custom_user_id]);

  // 组件挂载时检查登录状态和加载资料
  useEffect(() => {
    isMountedRef.current = true;
    
    if (!authLoading && !user) {
      navigate('/auth?mode=login');
      return;
    }
    
    if (user) {
      loadUserProfile();
    }
    
    return () => {
      isMountedRef.current = false;
      if (checkTimeoutRef.current) {
        clearTimeout(checkTimeoutRef.current);
      }
    };
  }, [user, authLoading, navigate, loadUserProfile]);

  // 格式化日期
  const formatDate = (dateString: string) => {
    return new Date(dateString).toLocaleString('zh-CN', {
      year: 'numeric',
      month: 'long',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    });
  };

  // 获取显示的用户标识
  const getDisplayUserId = () => {
    if (profile?.custom_user_id) {
      return profile.custom_user_id;
    }
    if (displayedNebulaId) {
      return displayedNebulaId;
    }
    return '未设置';
  };

  // 获取账户类型显示名称
  const getAccountTypeDisplay = () => {
    switch (profile?.account_type) {
      case 'email':
        return '邮箱账户';
      case 'phone':
        return '手机账户';
      case 'constellation':
        return '星座账户';
      default:
        return '未知类型';
    }
  };

  if (authLoading || loading) {
    return (
      <div className="min-h-screen pt-20 pb-16 px-4 sm:px-6 lg:px-8 flex items-center justify-center">
        <div className="text-center">
          <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-500 mx-auto mb-4"></div>
          <h2 className="text-xl font-semibold text-white mb-2">加载中...</h2>
          <p className="text-gray-400">正在获取您的资料信息</p>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen pt-20 pb-16 px-4 sm:px-6 lg:px-8">
      <div className="max-w-2xl mx-auto">
        {/* 页面标题 */}
        <div className="text-center mb-8">
          <h1 className="text-3xl font-bold text-white mb-2">
            个人资料
            <span className="bg-gradient-to-r from-blue-400 to-purple-500 bg-clip-text text-transparent ml-2">
              管理
            </span>
          </h1>
          <p className="text-gray-300">
            管理您的账户信息和个性化设置
          </p>
        </div>

        {/* 主要内容区域 */}
        <div className="apple-glass-panel apple-glass-sheen p-8">
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

          {profile && (
            <div className="space-y-6">
              {/* 基本信息 */}
              <div>
                <h2 className="text-lg font-semibold text-white mb-4">基本信息</h2>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div>
                    <label className="block text-sm font-medium text-gray-300 mb-2">
                      邮箱地址
                    </label>
                    <div className="px-4 py-3 apple-glass-field text-gray-300">
                      {profile.email || '未设置'}
                    </div>
                  </div>
                  
                  <div>
                    <label className="block text-sm font-medium text-gray-300 mb-2">
                      账户类型
                    </label>
                    <div className="px-4 py-3 apple-glass-field text-gray-300">
                      {getAccountTypeDisplay()}
                    </div>
                  </div>
                  
                  {profile.phone && (
                    <div>
                      <label className="block text-sm font-medium text-gray-300 mb-2">
                        手机号码
                      </label>
                      <div className="px-4 py-3 apple-glass-field text-gray-300">
                        {profile.phone}
                      </div>
                    </div>
                  )}
                  
                  <div>
                    <label className="block text-sm font-medium text-gray-300 mb-2">
                      注册时间
                    </label>
                    <div className="px-4 py-3 apple-glass-field text-gray-300">
                      {formatDate(profile.created_at)}
                    </div>
                  </div>
                </div>
              </div>

              {/* 星座信息 */}
              {profile.constellation && (
                <div>
                  <h2 className="text-lg font-semibold text-white mb-4">星座信息</h2>
                  <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div>
                      <label className="block text-sm font-medium text-gray-300 mb-2">
                        守护星座
                      </label>
                      <div className="px-4 py-3 apple-glass-field text-gray-300">
                        {profile.constellation_name || profile.constellation}
                      </div>
                    </div>
                    
                    {displayedNebulaId && (
                      <div>
                        <label className="block text-sm font-medium text-gray-300 mb-2">
                          星云ID
                        </label>
                        <div className="px-4 py-3 apple-glass-field text-gray-300">
                          {displayedNebulaId}
                        </div>
                      </div>
                    )}
                    
                    {profile.constellation_description && (
                      <div className="md:col-span-2">
                        <label className="block text-sm font-medium text-gray-300 mb-2">
                          星座描述
                        </label>
                        <div className="px-4 py-3 apple-glass-field text-gray-300">
                          {profile.constellation_description}
                        </div>
                      </div>
                    )}
                  </div>
                </div>
              )}

              {/* 用户ID管理 */}
              <div>
                <h2 className="text-lg font-semibold text-white mb-4">用户ID设置</h2>
                <div className="space-y-4">
                  <div>
                    <label className="block text-sm font-medium text-gray-300 mb-2">
                      当前用户ID
                    </label>
                    {!isEditingId ? (
                      <div className="flex items-center justify-between">
                        <div className="px-4 py-3 apple-glass-field text-gray-300 flex-1">
                          {getDisplayUserId()}
                        </div>
                        <button
                          onClick={() => setIsEditingId(true)}
                          className="ml-4 px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition-colors duration-200"
                        >
                          {profile.custom_user_id ? '修改' : '设置'}
                        </button>
                      </div>
                    ) : (
                      <div className="space-y-3">
                        <div className="relative">
                          <input
                            type="text"
                            value={newUserId}
                            onChange={handleUserIdChange}
                            placeholder="输入新的用户ID"
                            className="w-full px-4 py-3 apple-glass-field border border-white/20 text-white placeholder-gray-400 focus:ring-2 focus:ring-blue-500"
                            disabled={isSavingId}
                          />
                          {isCheckingId && (
                            <div className="absolute right-3 top-3">
                              <div className="animate-spin rounded-full h-5 w-5 border-b-2 border-blue-500"></div>
                            </div>
                          )}
                        </div>
                        
                        {/* 验证消息 */}
                        {userIdValidation.message && (
                          <div className={`text-sm p-2 rounded ${userIdValidation.isValid 
                            ? 'text-green-300 bg-green-500/10' 
                            : 'text-red-300 bg-red-500/10'
                          }`}>
                            {userIdValidation.message}
                          </div>
                        )}
                        
                        {/* 规则说明 */}
                        <div className="text-xs text-gray-400 space-y-1">
                          <p>用户ID规则：</p>
                          <ul className="list-disc list-inside space-y-1 ml-2">
                            <li>3-30个字符</li>
                            <li>只能包含字母、数字、汉字、下划线(_)和连字符(-)</li>
                            <li>设置后其他用户可以通过此ID找到您</li>
                          </ul>
                        </div>
                        
                        {/* 操作按钮 */}
                        <div className="flex space-x-3">
                          <button
                            onClick={handleSaveUserId}
                            disabled={!userIdValidation.isValid || isSavingId || isCheckingId}
                            className="px-4 py-2 bg-green-600 hover:bg-green-700 disabled:bg-gray-600 disabled:cursor-not-allowed text-white rounded-lg transition-colors duration-200"
                          >
                            {isSavingId ? '保存中...' : '保存'}
                          </button>
                          <button
                            onClick={handleCancelEdit}
                            disabled={isSavingId}
                            className="px-4 py-2 bg-gray-600 hover:bg-gray-700 disabled:cursor-not-allowed text-white rounded-lg transition-colors duration-200"
                          >
                            取消
                          </button>
                        </div>
                      </div>
                    )}
                  </div>
                </div>
              </div>

              {/* 高级账户绑定管理 */}
              <AccountBindingV2 
                onStatusUpdate={loadUserProfile} 
              />

              {/* 最后更新时间 */}
              <div className="pt-4 border-t border-white/10">
                <p className="text-sm text-gray-400">
                  最后更新：{formatDate(profile.updated_at)}
                </p>
              </div>
            </div>
          )}
        </div>

        {/* 返回按钮 */}
        <div className="mt-6 text-center">
          <button
            onClick={() => navigate('/')}
            className="px-6 py-2 bg-white/10 hover:bg-white/20 text-gray-300 hover:text-white rounded-lg transition-colors duration-200"
          >
            返回首页
          </button>
        </div>
      </div>
    </div>
  );
};

export default Profile;
