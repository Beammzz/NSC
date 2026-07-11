'use client';

import { useEffect, useState } from 'react';
import { fetchStatus, putTuning, Status, Tuning } from '../lib/api';

export default function DashboardPage() {
  const [status, setStatus] = useState<Status | null>(null);
  const [loading, setLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | null>(null);

  // Tuning form state
  const [confThreshold, setConfThreshold] = useState<string>('');
  const [idleFrames, setIdleFrames] = useState<string>('');
  const [idleMotionStd, setIdleMotionStd] = useState<string>('');
  const [savingTuning, setSavingTuning] = useState<boolean>(false);
  const [notice, setNotice] = useState<{ type: 'success' | 'error'; text: string } | null>(null);

  async function loadStatus(showSpinner = false) {
    if (showSpinner) setLoading(true);
    try {
      const res = await fetchStatus();
      setStatus(res);
      setError(null);
      // Initialize form fields only when they are empty
      if (res.tuning && confThreshold === '') {
        setConfThreshold(String(res.tuning.confidence_threshold));
        setIdleFrames(String(res.tuning.idle_min_frames_with_hands));
        setIdleMotionStd(String(res.tuning.idle_motion_std_threshold));
      }
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

  async function handleSaveTuning(e: React.FormEvent) {
    e.preventDefault();
    setSavingTuning(true);
    setNotice(null);
    try {
      const c = parseFloat(confThreshold);
      const f = parseInt(idleFrames, 10);
      const m = parseFloat(idleMotionStd);

      const updated = await putTuning({
        confidence_threshold: isNaN(c) ? undefined : c,
        idle_min_frames_with_hands: isNaN(f) ? undefined : f,
        idle_motion_std_threshold: isNaN(m) ? undefined : m,
      });

      setStatus((prev) => (prev ? { ...prev, tuning: updated } : prev));
      setNotice({ type: 'success', text: 'Runtime tuning parameters updated successfully.' });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      setNotice({ type: 'error', text: `Failed to update tuning: ${msg}` });
    } finally {
      setSavingTuning(false);
    }
  }

  const t: Tuning | undefined = status?.tuning;

  return (
    <div>
      <h1>Dashboard</h1>
      <p className="subtitle">Real-time gateway status and runtime inference configuration</p>

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
              <h2>Active Model Overview</h2>
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

            <div className="card">
              <h2>Runtime Tuning Parameters</h2>
              {t ? (
                <form onSubmit={handleSaveTuning}>
                  <label className="field">
                    <span>Confidence Threshold</span>
                    <input
                      type="number"
                      step="0.01"
                      min="0"
                      max="1"
                      value={confThreshold}
                      onChange={(e) => setConfThreshold(e.target.value)}
                    />
                  </label>

                  <label className="field">
                    <span>Idle Min Frames With Hands</span>
                    <input
                      type="number"
                      step="1"
                      min="0"
                      value={idleFrames}
                      onChange={(e) => setIdleFrames(e.target.value)}
                    />
                  </label>

                  <label className="field">
                    <span>Idle Motion Std Threshold</span>
                    <input
                      type="number"
                      step="0.0001"
                      min="0"
                      value={idleMotionStd}
                      onChange={(e) => setIdleMotionStd(e.target.value)}
                    />
                  </label>

                  {notice && (
                    <div className={`notice ${notice.type}`} style={{ margin: '8px 0' }}>
                      {notice.text}
                    </div>
                  )}

                  <button type="submit" disabled={savingTuning}>
                    {savingTuning ? 'Saving...' : 'Apply Tuning'}
                  </button>
                </form>
              ) : (
                <div className="empty" style={{ padding: '8px' }}>
                  Cannot configure tuning while AI service is offline
                </div>
              )}
            </div>
          </div>
        </>
      )}
    </div>
  );
}
