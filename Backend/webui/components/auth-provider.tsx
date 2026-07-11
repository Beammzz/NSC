'use client';

import { createContext, useContext, useEffect, useState, ReactNode, useCallback } from 'react';
import { usePathname, useRouter } from 'next/navigation';
import { fetchMe, logout as apiLogout, AuthUser } from '../lib/api';

type AuthContextValue = {
  user: AuthUser | null;
  loading: boolean;
  logout: () => Promise<void>;
  refreshUser: () => Promise<void>;
};

const AuthContext = createContext<AuthContextValue>({
  user: null,
  loading: true,
  logout: async () => {},
  refreshUser: async () => {},
});

export function useAuth() {
  return useContext(AuthContext);
}

// Public paths that don't require authentication.
const PUBLIC_PATHS = ['/login', '/login/'];

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<AuthUser | null>(null);
  const [loading, setLoading] = useState(true);
  const pathname = usePathname();
  const router = useRouter();

  const isPublic = PUBLIC_PATHS.includes(pathname);

  const refreshUser = useCallback(async () => {
    try {
      const me = await fetchMe();
      setUser(me);
    } catch {
      setUser(null);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;

    async function checkAuth() {
      try {
        const me = await fetchMe();
        if (!cancelled) {
          setUser(me);
          setLoading(false);
          // If on login page and already authenticated, redirect to dashboard.
          if (isPublic) {
            router.replace('/');
          }
        }
      } catch {
        if (!cancelled) {
          setUser(null);
          setLoading(false);
          // If not on a public path, redirect to login.
          if (!isPublic) {
            router.replace('/login/');
          }
        }
      }
    }

    checkAuth();
    return () => { cancelled = true; };
  }, [pathname, isPublic, router]);

  const logout = useCallback(async () => {
    await apiLogout();
    setUser(null);
    router.replace('/login/');
  }, [router]);

  // Show nothing while checking auth (prevents flash of content).
  if (loading) {
    return (
      <div className="auth-loading">
        <div className="auth-spinner" />
      </div>
    );
  }

  // On protected pages without a user, show nothing (redirect is in flight).
  if (!user && !isPublic) {
    return (
      <div className="auth-loading">
        <div className="auth-spinner" />
      </div>
    );
  }

  return (
    <AuthContext.Provider value={{ user, loading, logout, refreshUser }}>
      {children}
    </AuthContext.Provider>
  );
}
