import React, { Suspense, lazy } from 'react';
import { BrowserRouter as Router, Routes, Route, useLocation } from 'react-router-dom';
import { QueryClientProvider } from '@tanstack/react-query';
import { queryClient } from './lib/queryClient';
import { AuthProvider } from './contexts/AuthContext';
import { ErrorBoundary } from './components/ErrorBoundary';
import StarryBackground from './components/StarryBackground';
import Navigation from './components/Navigation';
import HomePage from './pages/HomePage';
import './App.css';

const Features = lazy(() => import('./pages/Features'));
const Downloads = lazy(() => import('./pages/Downloads'));
const Sinan = lazy(() => import('./pages/Sinan'));
const Contact = lazy(() => import('./pages/Contact'));
const SecureAuthPage = lazy(() => import('./pages/SecureAuthPage'));
const AuthCallback = lazy(() => import('./pages/AuthCallback'));
const CliLoginPage = lazy(() => import('./pages/CliLoginPage'));
const Privacy = lazy(() => import('./pages/Privacy'));
const Terms = lazy(() => import('./pages/Terms'));
const Help = lazy(() => import('./pages/Help'));
const Profile = lazy(() => import('./pages/Profile'));

function RouteFallback() {
  return (
    <div className="flex min-h-[60vh] items-center justify-center px-6 text-center text-slate-300">
      <div className="space-y-3">
        <div className="mx-auto h-12 w-12 animate-spin rounded-full border-4 border-slate-700 border-t-cyan-400" />
        <p>正在加载页面…</p>
      </div>
    </div>
  );
}

function RoutedBackground() {
  const location = useLocation();

  if (location.pathname === '/') {
    return null;
  }

  return <StarryBackground />;
}

function App() {
  return (
    <ErrorBoundary>
      <QueryClientProvider client={queryClient}>
        <AuthProvider>
          <Router>
            <div className="min-h-screen bg-black relative overflow-hidden">
              {/* Global background for non-home routes; the homepage owns its realtime cinematic field. */}
              <ErrorBoundary>
                <RoutedBackground />
              </ErrorBoundary>
              
              {/* Navigation */}
              <ErrorBoundary>
                <Navigation />
              </ErrorBoundary>
              
              {/* Main Content */}
              <main className="relative z-10">
                <ErrorBoundary>
                  <Suspense fallback={<RouteFallback />}>
                    <Routes>
                      <Route path="/" element={<HomePage />} />
                      <Route path="/features" element={<Features />} />
                      <Route path="/downloads" element={<Downloads />} />
                      <Route path="/sinan" element={<Sinan />} />
                      <Route path="/contact" element={<Contact />} />
                      <Route path="/auth" element={<SecureAuthPage />} />
                      <Route path="/auth/callback" element={<AuthCallback />} />
                      <Route path="/auth/cli" element={<CliLoginPage />} />
                      <Route path="/register" element={<SecureAuthPage />} />
                      <Route path="/profile" element={<Profile />} />
                      <Route path="/privacy" element={<Privacy />} />
                      <Route path="/terms" element={<Terms />} />
                      <Route path="/help" element={<Help />} />
                    </Routes>
                  </Suspense>
                </ErrorBoundary>
              </main>
            </div>
          </Router>
        </AuthProvider>
      </QueryClientProvider>
    </ErrorBoundary>
  );
}

export default App;
