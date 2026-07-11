import type { Metadata } from 'next';
import './globals.css';
import Nav from '../components/nav';
import { AuthProvider } from '../components/auth-provider';

export const metadata: Metadata = {
  title: 'SignMind Admin',
  description: 'Model management and prediction analysis for the SignMind AI backend',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <AuthProvider>
          <div className="shell">
            <Nav />
            <main className="main">{children}</main>
          </div>
        </AuthProvider>
      </body>
    </html>
  );
}

