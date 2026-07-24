'use client';

import { useEffect } from 'react';
import { useRouter } from 'next/navigation';

export default function LogsRedirectPage() {
  const router = useRouter();

  useEffect(() => {
    router.replace('/tsl-model/?tab=logs');
  }, [router]);

  return <div className="empty">Redirecting to TSL Model AI logs...</div>;
}
