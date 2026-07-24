'use client';

import { useEffect } from 'react';
import { useRouter } from 'next/navigation';

export default function UploadRedirectPage() {
  const router = useRouter();

  useEffect(() => {
    router.replace('/tsl-model/?tab=upload');
  }, [router]);

  return <div className="empty">Redirecting to TSL Model upload...</div>;
}
