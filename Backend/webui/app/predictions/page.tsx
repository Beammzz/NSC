'use client';

import { useEffect } from 'react';
import { useRouter } from 'next/navigation';

export default function PredictionsRedirectPage() {
  const router = useRouter();

  useEffect(() => {
    router.replace('/tsl-model/?tab=predictions');
  }, [router]);

  return <div className="empty">Redirecting to TSL Model predictions...</div>;
}
