import type { Metadata } from 'next';
import './globals.css';
import Nav from '../components/nav';

export const metadata: Metadata = {
  title: 'SignMind Admin',
  description: 'Model management and prediction analysis for the SignMind AI backend',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <div className="shell">
          <Nav />
          <main className="main">{children}</main>
        </div>
      </body>
    </html>
  );
}
