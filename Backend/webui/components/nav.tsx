'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const links = [
  { href: '/', label: 'Dashboard' },
  { href: '/predictions/', label: 'Predictions' },
  { href: '/logs/', label: 'AI Logs' },
  { href: '/upload/', label: 'Upload Model' },
];

export default function Nav() {
  const pathname = usePathname();
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
    </nav>
  );
}
