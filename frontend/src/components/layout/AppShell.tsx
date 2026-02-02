'use client';

import { useState, useCallback } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import SplashScreen from '@/components/ui/SplashScreen';
import Sidebar from '@/components/layout/Sidebar';
import { AuthModal } from '@/components/auth';
import { useAuth } from '@/contexts/AuthContext';
import { Bell, Globe, LogOut, Loader2 } from 'lucide-react';

export default function AppShell({ children }: { children: React.ReactNode }) {
  const [isLoading, setIsLoading] = useState(true);
  const [showAuthModal, setShowAuthModal] = useState(false);
  const [authMode, setAuthMode] = useState<'login' | 'register'>('login');
  const [showUserMenu, setShowUserMenu] = useState(false);

  const { session, isAuthenticated, isLoading: authLoading, signOut } = useAuth();

  // 打开登录模态框
  const openLogin = useCallback(() => {
    setAuthMode('login');
    setShowAuthModal(true);
  }, []);

  // 打开注册模态框
  const openRegister = useCallback(() => {
    setAuthMode('register');
    setShowAuthModal(true);
  }, []);

  // 关闭模态框
  const closeAuthModal = useCallback(() => {
    setShowAuthModal(false);
  }, []);

  // 登出
  const handleSignOut = useCallback(async () => {
    await signOut();
    setShowUserMenu(false);
  }, [signOut]);

  return (
    <>
      <AnimatePresence mode="wait">
        {isLoading && (
          <motion.div
            key="splash"
            exit={{ opacity: 0 }}
            className="fixed inset-0 z-50"
          >
            <SplashScreen onFinish={() => setIsLoading(false)} />
          </motion.div>
        )}
      </AnimatePresence>

      {!isLoading && (
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          className="flex h-screen w-full bg-background text-foreground overflow-hidden"
        >
          {/* Sidebar */}
          <Sidebar />

          {/* Main Content */}
          <main className="flex-1 flex flex-col relative overflow-hidden">
             {/* Header - Simple transparent header for mobile/actions */}
            <header className="h-16 flex items-center justify-between px-6 shrink-0 z-10">
                <div className="text-xl font-bold md:hidden">云桥司南</div>
                <div className="flex items-center gap-4 ml-auto">
                    <button className="p-2 hover:bg-white/10 rounded-full transition-colors" title="Change Language">
                        <Globe size={20} />
                    </button>
                    
                    {/* 连接状态 */}
                    <div className="flex items-center gap-2 px-3 py-1 bg-card/50 rounded-full border border-white/10 text-xs">
                        <span className={`w-2 h-2 rounded-full ${isAuthenticated ? 'bg-green-500' : 'bg-red-500'} animate-pulse`}></span>
                        {isAuthenticated ? '已登录' : '未连接'}
                    </div>
                    
                    {/* 通知 */}
                    <button className="p-2 hover:bg-white/10 rounded-full transition-colors relative">
                        <Bell size={20} />
                        <span className="absolute top-1 right-1 w-2 h-2 bg-red-500 rounded-full"></span>
                    </button>
                    
                    {/* 用户区域 */}
                    {authLoading ? (
                      <div className="p-2">
                        <Loader2 className="animate-spin text-white/60" size={20} />
                      </div>
                    ) : isAuthenticated && session ? (
                      <div className="relative">
                        <button 
                          onClick={() => setShowUserMenu(!showUserMenu)}
                          className="flex items-center gap-2 p-2 hover:bg-white/10 rounded-full transition-colors"
                        >
                          <div className="w-8 h-8 bg-gradient-to-br from-accent to-blue-500 rounded-full flex items-center justify-center">
                            <span className="text-sm font-semibold text-white">
                              {session.displayName.charAt(0).toUpperCase()}
                            </span>
                          </div>
                        </button>
                        
                        {/* 用户下拉菜单 */}
                        <AnimatePresence>
                          {showUserMenu && (
                            <motion.div
                              initial={{ opacity: 0, y: -10 }}
                              animate={{ opacity: 1, y: 0 }}
                              exit={{ opacity: 0, y: -10 }}
                              className="absolute right-0 top-full mt-2 w-64 bg-slate-800/95 backdrop-blur-xl border border-white/10 rounded-xl shadow-xl overflow-hidden"
                            >
                              <div className="p-4 border-b border-white/10">
                                <p className="font-semibold text-white">{session.displayName}</p>
                                <p className="text-sm text-white/60 truncate">{session.userIdentifier}</p>
                              </div>
                              <div className="p-2">
                                <button
                                  onClick={handleSignOut}
                                  className="w-full flex items-center gap-3 px-3 py-2 text-red-400 hover:bg-red-500/10 rounded-lg transition-colors"
                                >
                                  <LogOut size={18} />
                                  退出登录
                                </button>
                              </div>
                            </motion.div>
                          )}
                        </AnimatePresence>
                      </div>
                    ) : (
                      <div className="flex items-center gap-2">
                        <button 
                          onClick={openLogin}
                          className="px-4 py-2 text-sm text-white/80 hover:text-white transition-colors"
                        >
                          登录
                        </button>
                        <button 
                          onClick={openRegister}
                          className="px-4 py-2 text-sm bg-accent hover:bg-accent/90 text-white rounded-lg transition-colors"
                        >
                          注册
                        </button>
                      </div>
                    )}
                </div>
            </header>
            
            <div className="flex-1 overflow-auto p-6 pt-0">
                {children}
            </div>
          </main>
        </motion.div>
      )}

      {/* 认证模态框 */}
      <AuthModal 
        isOpen={showAuthModal} 
        onClose={closeAuthModal}
        initialMode={authMode}
      />
    </>
  );
}

