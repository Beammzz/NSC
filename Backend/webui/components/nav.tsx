'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useAuth } from './auth-provider';

const links = [
  { href: '/', label: 'Dashboard' },
  { href: '/predictions/', label: 'Predictions' },
  { href: '/logs/', label: 'AI Logs' },
  { href: '/upload/', label: 'Upload Model' },
  { href: '/users/', label: 'Users' },
];

export default function Nav() {
  const pathname = usePathname();
  const { user, logout } = useAuth();

  // Don't render nav on login page.
  if (pathname === '/login' || pathname === '/login/') {
    return null;
  }

  return (
    <nav className="sidebar">
      <div className="brand">
        SignMind
        <small>AI backend admin</small>
      </div>
      {links.map(({ href, label }) => (
        <Link
          key={href}
          href={href}
          className={pathname === href || pathname === href.replace(/\/$/, '') ? 'active' : ''}
        >
          {label}
        </Link>
      ))}
      {user && (
        <div className="sidebar-user">
          <div className="sidebar-user-info">
            <span className="sidebar-user-email">{user.email}</span>
            <span className={`chip ${user.role === 'admin' ? 'warning' : 'info'}`} style={{ fontSize: 10 }}>
              <span className="dot" />
              {user.role}
            </span>
          </div>
          <button className="secondary sidebar-logout" onClick={logout}>
            Sign Out
          </button>
        </div>
      )}
    </nav>
  );
}

