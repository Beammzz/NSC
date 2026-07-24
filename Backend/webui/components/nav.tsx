'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useAuth } from './auth-provider';

type NavItem = {
  href?: string;
  label: string;
  disabled?: boolean;
  badge?: string;
  matchPrefixes?: string[];
};

const navItems: NavItem[] = [
  { href: '/', label: 'Server dashboard' },
  {
    href: '/tsl-model/',
    label: 'TSL Model',
    matchPrefixes: ['/tsl-model', '/predictions', '/logs', '/settings', '/upload', '/tuning'],
  },
  { label: 'LLM Model', disabled: true, badge: 'Coming soon' },
  { href: '/learn/', label: 'Learning' },
  { href: '/dictionary/', label: 'Dictionary' },
  { href: '/users/', label: 'Users' },
];

export default function Nav() {
  const pathname = usePathname();
  const { user, logout } = useAuth();

  // Don't render nav on login page.
  if (pathname === '/login' || pathname === '/login/') {
    return null;
  }

  const isLinkActive = (item: NavItem) => {
    if (!item.href) return false;
    const cleanPath = pathname ? pathname.replace(/\/$/, '') : '';
    const cleanHref = item.href.replace(/\/$/, '');

    if (item.matchPrefixes) {
      return item.matchPrefixes.some((prefix) =>
        cleanPath === prefix || cleanPath.startsWith(`${prefix}/`)
      );
    }
    return cleanPath === cleanHref;
  };

  return (
    <nav className="sidebar">
      <div className="brand" style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
        <img src="/icon.png" alt="SignMind Logo" style={{ width: 32, height: 32, borderRadius: 6, objectFit: 'contain', filter: 'brightness(0) invert(1)' }} />
        <div>
          SignMind
          <small>AI backend admin</small>
        </div>
      </div>
      {navItems.map((item) => {
        if (item.disabled) {
          return (
            <div key={item.label} className="sidebar-disabled-item" title={`${item.label} is coming soon`}>
              <span>{item.label}</span>
              {item.badge && <span className="badge-coming-soon">{item.badge}</span>}
            </div>
          );
        }

        const active = isLinkActive(item);
        return (
          <Link
            key={item.href}
            href={item.href!}
            className={active ? 'active' : ''}
          >
            {item.label}
          </Link>
        );
      })}
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

