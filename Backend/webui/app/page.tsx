'use client';

import Link from 'next/link';
import { useEffect, useState } from 'react';
import { fetchStatus, Status, Tuning } from '../lib/api';

export default function DashboardPage() {
  const [status, setStatus] = useState<Status | null>(null);
  const [loading, setLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | null>(null);

  async function loadStatus(showSpinner = false) {
    if (showSpinner) setLoading(true);
    try {
      const res = await fetchStatus();
      setStatus(res);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      if (showSpinner) setLoading(false);
    }
  }

  useEffect(() => {
    loadStatus(true);
    const interval = setInterval(() => loadStatus(false), 5000);
    return () => clearInterval(interval);
  }, []);

  const t: Tuning | undefined = status?.tuning;

  return (
    <div>
      <h1>Dashboard</h1>
      <p className="subtitle">Real-time gateway status and runtime inference environment</p>

      {error && (
        <div className="notice error">
          Failed to fetch status: {error}
        </div>
      )}

      {loading && !status ? (
        <div className="empty">Loading dashboard status...</div>
      ) : (
        <>
          <div className="grid">
            <div className="card">
              <h2>Environment</h2>
              <div className="row" style={{ marginBottom: 0 }}>
                <span className={`chip ${status?.env === 'Dev' ? 'info' : 'good'}`}>
                  <span className="dot" />
                  ENV: {status?.env || 'Unknown'}
                </span>
                <span className={`chip ${status?.ai_online ? 'good' : 'critical'}`}>
                  <span className="dot" />
                  AI: {status?.ai_online ? 'ONLINE' : 'OFFLINE'}
                </span>
                {status?.debug && (
                  <span className="chip warning">
                    <span className="dot" />
                    DEBUG MODE
                  </span>
                )}
              </div>
              {status?.ai_error && (
                <div style={{ marginTop: '8px', color: 'var(--status-critical)', fontSize: '12px' }}>
                  {status.ai_error}
                </div>
              )}
            </div>

            <div className="card">
              <h2>Predictions Logged</h2>
              <div className="stat">
                {status?.predictions_total ?? 0}
                <small>records in store</small>
              </div>
            </div>
          </div>

          <div className="grid">
            <div className="card">
              <div className="row" style={{ justifyContent: 'space-between', alignItems: 'center', marginBottom: '12px' }}>
                <h2 style={{ margin: 0 }}>Active Model Overview</h2>
                <Link href="/tsl-model/?tab=tuning" className="secondary" style={{ fontSize: '12px', padding: '4px 10px' }}>
                  Configure Tuning &rarr;
                </Link>
              </div>
              {t ? (
                <dl className="kv">
                  <dt>Model Loaded</dt>
                  <dd>
                    <span className={`chip ${t.model_loaded ? 'good' : 'warning'}`}>
                      <span className="dot" />
                      {t.model_loaded ? 'Yes' : 'No'}
                    </span>
                  </dd>
                  <dt>Num Classes</dt>
                  <dd>{t.num_classes}</dd>
                  <dt>Sequence Len</dt>
                  <dd>{t.sequence_len}</dd>
                  <dt>Feature Dim</dt>
                  <dd>{t.feature_dim}</dd>
                  <dt>Debug Mode (ENV-controlled)</dt>
                  <dd>{t.debug_mode ? 'Enabled' : 'Disabled'}</dd>
                </dl>
              ) : (
                <div className="empty" style={{ padding: '8px' }}>
                  Tuning data unavailable (AI service offline)
                </div>
              )}
            </div>
          </div>
        </>
      )}
    </div>
  );
}

